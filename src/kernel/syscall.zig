//! Syscall dispatch.
//!
//! The table in `syscall_table.zig` is the contract; this file binds each entry
//! to an implementation. The binding is checked at comptime: a documented
//! syscall with no `sys_<name>` function fails the build, and so does a handler
//! with no table entry. The interface therefore cannot drift from its
//! documentation, because neither can exist alone.

const std = @import("std");
const abi = @import("syscall_table.zig");
const clock = @import("clock.zig");
const console = @import("console.zig");
const exec = @import("exec.zig");
const fat = @import("fat.zig");
const path_mod = @import("path.zig");
const handles = @import("handle.zig");
const hal = @import("hal.zig");
const sched = @import("sched.zig");
const shutdown_mod = @import("shutdown.zig");
const sysinfo = @import("sysinfo.zig");
const vfs = @import("vfs.zig");
const tty = @import("tty.zig");

pub const Errno = abi.Errno;

/// Arguments as the architecture delivers them, plus the process context the
/// handler needs. Keeping this architecture-neutral is what lets the handlers
/// below be portable.
pub const Args = struct {
    a0: usize = 0,
    a1: usize = 0,
    a2: usize = 0,
    a3: usize = 0,
    a4: usize = 0,
    /// True when the call came from user mode. Kernel-mode callers (the
    /// self-test, early init) skip user-pointer validation.
    from_user: bool = true,
};

/// Result register value: negative is `-errno`.
pub const Result = isize;

// ---------------------------------------------------------------------------
// Handlers. One `sys_<name>` per table entry, enforced below.
// ---------------------------------------------------------------------------

fn sys_exit(a: Args) Result {
    const status: i32 = @truncate(@as(isize, @bitCast(a.a0)));
    if (sched.currentThread()) |t| {
        console.debug("exit", "{s} (thread {d}) status {d}", .{ t.name, t.id, status });
    }
    // Never returns: the thread is unlinked and the next one is switched in.
    // The abandoned interrupt frame goes with the dying thread's stack.
    sched.exitWith(status);
}

fn sys_write(a: Args) Result {
    const h: u32 = @truncate(a.a0);
    if (h != abi.STDOUT and h != abi.STDERR) return Errno.badf.value();

    const buf = userSlice(a, a.a1, a.a2) orelse return Errno.fault.value();
    if (h == abi.STDERR) console.setColor(.light_red, .black);
    console.writeString(buf);
    if (h == abi.STDERR) console.setColor(.light_grey, .black);
    return @intCast(buf.len);
}

fn sys_read(a: Args) Result {
    const buf = userSlice(a, a.a1, a.a2) orelse return Errno.fault.value();
    if (buf.len == 0) return 0;

    const id: u32 = @truncate(a.a0);
    if (id == abi.STDIN) {
        // Block until a line is available. Sleeping rather than spinning
        // matters: a shell waiting at a prompt must not consume the CPU
        // everything else needs, and on a single core it would starve them.
        while (!tty.hasLine()) sched.sleepMicros(10_000);
        return @intCast(tty.read(buf));
    }

    const table = currentHandles() orelse return Errno.badf.value();
    const h = table.get(id) orelse return Errno.badf.value();
    if (h.kind != .file or !h.rights.read) return Errno.badf.value();

    const f = &h.data.file;
    const n = vfs.readAt(f.mount, f.entry, f.offset, buf) catch return Errno.io.value();
    f.offset += n;
    return @intCast(n);
}

fn sys_yield(_: Args) Result {
    sched.yield();
    return 0;
}

fn sys_sleep_us(a: Args) Result {
    sched.sleepMicros(a.a0);
    return 0;
}

fn sys_clock_us(a: Args) Result {
    const out = userSlice(a, a.a0, @sizeOf(u64)) orelse return Errno.fault.value();
    std.mem.writeInt(u64, out[0..8], clock.monotonicMicros(), .little);
    return 0;
}

fn sys_realtime_us(a: Args) Result {
    const out = userSlice(a, a.a0, @sizeOf(i64)) orelse return Errno.fault.value();
    if (!clock.valid()) return Errno.inval.value();
    std.mem.writeInt(i64, out[0..8], clock.realtimeMicros(), .little);
    return 0;
}

fn sys_getpid(_: Args) Result {
    const t = sched.currentThread() orelse return 0;
    return @intCast(t.id);
}

fn sys_log(a: Args) Result {
    const buf = userSlice(a, a.a0, a.a1) orelse return Errno.fault.value();
    if (buf.len == 0 or buf.len > 256) return Errno.inval.value();
    console.field("user", "{s}", .{buf});
    return 0;
}

fn sys_shutdown(a: Args) Result {
    const action: shutdown_mod.Action = switch (a.a0) {
        0 => .power_off,
        1 => .reboot,
        2 => .halt,
        else => return Errno.inval.value(),
    };
    shutdown_mod.shutdown(action);
}

fn sys_sysinfo(a: Args) Result {
    const key = userSlice(a, a.a0, a.a1) orelse return Errno.fault.value();
    const out = userSlice(a, a.a2, a.a3) orelse return Errno.fault.value();
    if (key.len == 0 or key.len > 64) return Errno.inval.value();

    const n = sysinfo.query(key, out) catch |err| return switch (err) {
        error.UnknownKey => Errno.inval.value(),
        error.NoSpace => Errno.nomem.value(),
    };
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// Pointer validation
// ---------------------------------------------------------------------------

/// Validate a user pointer/length pair and return it as a slice.
///
/// The whole range must sit below the kernel base, and the length must not
/// wrap. The slice is produced once and used once: re-reading the pointer after
/// checking it is how time-of-check/time-of-use bugs get in.
fn userSlice(a: Args, ptr: usize, len: usize) ?[]u8 {
    if (len == 0) return &.{};
    if (ptr == 0) return null;

    const end = std.math.add(usize, ptr, len) catch return null;
    if (a.from_user and (ptr >= hal.KERNEL_BASE or end > hal.KERNEL_BASE)) return null;

    const p: [*]u8 = @ptrFromInt(ptr);
    return p[0..len];
}

// ---------------------------------------------------------------------------
// Dispatch, generated from the table
// ---------------------------------------------------------------------------

const Handler = *const fn (Args) Result;

/// Bind table entries to handlers, and prove the binding is total.
const handlers: [abi.table.len]Handler = blk: {
    var out: [abi.table.len]Handler = undefined;
    for (abi.table, 0..) |sc, i| {
        const fn_name = "sys_" ++ sc.name;
        if (!@hasDecl(@This(), fn_name)) @compileError(
            "syscall '" ++ sc.name ++ "' is in the table but has no handler `" ++ fn_name ++ "`",
        );
        out[i] = &@field(@This(), fn_name);
    }
    break :blk out;
};

// Every `sys_*` function must appear in the table. Catches the opposite
// mistake: an implemented call nobody documented, which userspace would have
// no way to learn about.
comptime {
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        if (!std.mem.startsWith(u8, decl.name, "sys_")) continue;
        if (abi.find(decl.name["sys_".len..]) == null) @compileError(
            "handler `" ++ decl.name ++ "` has no entry in syscall_table.zig; " ++
                "an undocumented syscall is unusable",
        );
    }
}

// Force analysis of the binding table. Zig is lazy: without this the
// completeness checks above only fire once something calls dispatch(), which
// would make them useless exactly when a syscall is half-added.
comptime {
    _ = handlers;
}

pub fn dispatch(number: usize, args: Args) Result {
    if (number >= handlers.len) return Errno.nosys.value();
    return handlers[number](args);
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

const OPEN_DIRECTORY: u32 = 1 << 0;

/// Wire format for a directory entry, shared by readdir and stat.
///
/// Packed by hand rather than as an extern struct so the layout is stated
/// once, here, and userspace can decode it without agreeing on Zig's rules.
const DIRENT_HEADER = 10; // u32 size, i32 mtime, u8 flags, u8 name_len
const DIRENT_FLAG_DIR: u8 = 1 << 0;

fn writeDirent(out: []u8, entry: fat.Entry) ?usize {
    const total = DIRENT_HEADER + entry.name_len;
    if (out.len < total) return null;

    std.mem.writeInt(u32, out[0..4], entry.size, .little);
    // Signed, and 32-bit: FAT cannot express a date outside 1980-2107, so the
    // 2038 problem cannot arise through this path, and a signed field leaves
    // room for a future filesystem that can express dates before 1970.
    std.mem.writeInt(i32, out[4..8], @truncate(entry.mtime), .little);
    out[8] = if (entry.is_dir) DIRENT_FLAG_DIR else 0;
    out[9] = @intCast(entry.name_len);
    @memcpy(out[DIRENT_HEADER..][0..entry.name_len], entry.nameSlice());
    return total;
}

fn currentHandles() ?*handles.Table {
    const t = sched.currentThread() orelse return null;
    return &t.handles;
}

/// Copy a user path out and make it absolute.
///
/// Copied first because the caller's memory must not be read twice: a path
/// validated and then re-read is the classic time-of-check bug.
fn userPath(a: Args, ptr: usize, len: usize, buf: []u8) ?[]const u8 {
    const raw = userSlice(a, ptr, len) orelse return null;
    if (raw.len == 0 or raw.len > path_mod.MAX) return null;

    var scratch: [path_mod.MAX]u8 = undefined;
    @memcpy(scratch[0..raw.len], raw);

    return path_mod.resolve(scratch[0..raw.len], buf) catch null;
}

fn sys_open(a: Args) Result {
    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();

    const table = currentHandles() orelse return Errno.nomem.value();
    const slot = table.alloc() orelse return Errno.nomem.value();
    const h = &table.entries[slot];

    if (a.a2 & OPEN_DIRECTORY != 0) {
        const it = vfs.openDir(path) catch return Errno.noent.value();
        const r = vfs.resolve(path) catch return Errno.noent.value();
        r.mount.open_files += 1;
        h.* = .{
            .kind = .directory,
            .rights = .{ .read = true },
            .data = .{ .directory = .{ .mount = r.mount, .iterator = it } },
        };
        return @intCast(slot);
    }

    const opened = vfs.open(path) catch return Errno.noent.value();
    h.* = .{
        .kind = .file,
        .rights = .{ .read = true, .seek = true },
        .data = .{ .file = .{ .mount = opened.mount, .entry = opened.entry } },
    };
    return @intCast(slot);
}

fn sys_close(a: Args) Result {
    const table = currentHandles() orelse return Errno.badf.value();
    return if (table.close(@truncate(a.a0))) 0 else Errno.badf.value();
}

fn sys_seek(a: Args) Result {
    const table = currentHandles() orelse return Errno.badf.value();
    const h = table.get(@truncate(a.a0)) orelse return Errno.badf.value();
    if (h.kind != .file) return Errno.badf.value();

    const f = &h.data.file;
    const displacement: isize = @bitCast(a.a1);

    const base: i64 = switch (a.a2) {
        0 => 0,
        1 => @intCast(f.offset),
        2 => @intCast(f.entry.size),
        else => return Errno.inval.value(),
    };

    const target = base + displacement;
    if (target < 0) return Errno.inval.value();

    // Seeking past the end is allowed and simply reads nothing, which is what
    // callers computing an offset before checking the size expect.
    f.offset = @intCast(target);
    return @intCast(f.offset);
}

fn sys_readdir(a: Args) Result {
    const table = currentHandles() orelse return Errno.badf.value();
    const h = table.get(@truncate(a.a0)) orelse return Errno.badf.value();
    if (h.kind != .directory) return Errno.badf.value();

    const out = userSlice(a, a.a1, a.a2) orelse return Errno.fault.value();
    const d = &h.data.directory;
    if (d.exhausted) return 0;

    const entry = (d.iterator.next() catch return Errno.io.value()) orelse {
        d.exhausted = true;
        return 0;
    };

    const n = writeDirent(out, entry) orelse return Errno.nomem.value();
    return @intCast(n);
}

fn sys_stat(a: Args) Result {
    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();
    const out = userSlice(a, a.a2, a.a3) orelse return Errno.fault.value();

    const entry = vfs.stat(path) catch return Errno.noent.value();
    const n = writeDirent(out, entry) orelse return Errno.nomem.value();
    return @intCast(n);
}

fn sys_spawn(a: Args) Result {
    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();
    const packed_args = userSlice(a, a.a2, a.a3) orelse return Errno.fault.value();

    // Arguments are copied out of user memory before anything else happens.
    // Leaving them there would mean the loader reading pages that the child's
    // own address space is about to replace.
    var storage: [exec.MAX_ARG_BYTES]u8 = undefined;
    var slices: [exec.MAX_ARGS][]const u8 = undefined;

    const count = unpackArgs(packed_args, &storage, &slices) catch return Errno.inval.value();

    const status = exec.spawn(path, slices[0..count]) catch |err| return switch (err) {
        error.NotFound => Errno.noent.value(),
        error.BadImage => Errno.inval.value(),
        error.OutOfMemory => Errno.nomem.value(),
    };
    return status;
}

/// Decode the packed argument block: u16 count, then each argument as a u16
/// length followed by its bytes.
///
/// A length-prefixed block rather than an array of pointers: pointers would
/// each need validating against the caller's address space separately, and one
/// contiguous copy is both simpler and harder to get wrong.
fn unpackArgs(
    input: []const u8,
    storage: []u8,
    out: [][]const u8,
) error{Malformed}!usize {
    if (input.len < 2) return 0;

    const count = std.mem.readInt(u16, input[0..2], .little);
    if (count > out.len) return error.Malformed;

    var pos: usize = 2;
    var used: usize = 0;

    for (0..count) |i| {
        if (pos + 2 > input.len) return error.Malformed;
        const len = std.mem.readInt(u16, input[pos..][0..2], .little);
        pos += 2;
        if (pos + len > input.len) return error.Malformed;
        if (used + len > storage.len) return error.Malformed;

        @memcpy(storage[used..][0..len], input[pos..][0..len]);
        out[i] = storage[used..][0..len];
        used += len;
        pos += len;
    }

    return count;
}

fn sys_chdir(a: Args) Result {
    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();

    // Must exist and be a directory. "/" is always valid and has no entry to
    // look up, so it is accepted without one.
    if (path.len > 1) {
        const entry = vfs.stat(path) catch return Errno.noent.value();
        if (!entry.is_dir) return Errno.inval.value();
    }

    return if (sched.setCwd(path)) 0 else Errno.inval.value();
}

fn sys_getcwd(a: Args) Result {
    const out = userSlice(a, a.a0, a.a1) orelse return Errno.fault.value();
    const dir = sched.cwd();
    if (dir.len > out.len) return Errno.nomem.value();
    @memcpy(out[0..dir.len], dir);
    return @intCast(dir.len);
}
