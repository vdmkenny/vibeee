//! Syscall dispatch.
//!
//! The table in `lib/syscalls.zig` is the contract; this file binds each entry
//! to an implementation. The binding is checked at comptime: a documented
//! syscall with no `sys_<name>` function fails the build, and so does a handler
//! with no table entry. The interface therefore cannot drift from its
//! documentation, because neither can exist alone.

const std = @import("std");
const abi = @import("lib").syscalls;
const channel_mod = @import("channel.zig");
const clock = @import("clock.zig");
const event_mod = @import("event.zig");
const console = @import("console.zig");
const exec = @import("exec.zig");
const fat = @import("fat.zig");
const path_mod = @import("path.zig");
const handles = @import("handle.zig");
const hal = @import("hal.zig");
const sched = @import("sched.zig");
const shutdown_mod = @import("shutdown.zig");
const svc = @import("svc.zig");
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
        console.debug("exit", "{s} (thread {d}) status {d}", .{ t.name(), t.id, status });
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
// IPC
//
// design/00-vibeee.md §6.8. Handlers stay thin: the objects enforce their own
// invariants, and everything here does is translate between handles and
// pointers on one side and kernel objects on the other.
// ---------------------------------------------------------------------------

/// Timeouts arrive as a u32 with two sentinel values (`abi.Timeout`), so a
/// caller can poll, block forever, or bound the wait without a second argument
/// saying which. Null here means no deadline.
fn deadlineFrom(timeout_us: usize) ?u64 {
    if (timeout_us == abi.Timeout.forever) return null;
    return clock.monotonicMicros() + timeout_us;
}

fn openFlags(raw: usize) abi.OpenFlags {
    return @bitCast(@as(u32, @truncate(raw)));
}

fn installHandle(h: handles.Handle) ?u32 {
    const table = currentHandles() orelse return null;
    const slot = table.alloc() orelse return null;
    table.entries[slot] = h;
    return slot;
}

fn getEvent(handle: u32) ?*event_mod.Event {
    const table = currentHandles() orelse return null;
    const h = table.get(handle) orelse return null;
    if (h.kind != .event) return null;
    return h.data.event;
}

fn getChannel(handle: u32, serving: bool) ?*channel_mod.Channel {
    const table = currentHandles() orelse return null;
    const h = table.get(handle) orelse return null;
    if (h.kind != .channel) return null;
    // A client cannot answer calls and a server cannot make them on its own
    // serving end; enforcing that here keeps the object free of the question.
    if (h.data.channel.serving != serving) return null;
    return h.data.channel.channel;
}

fn sys_event_create(_: Args) Result {
    const e = event_mod.create() catch return Errno.nomem.value();
    const slot = installHandle(.{
        .kind = .event,
        .rights = .{ .read = true, .write = true },
        .data = .{ .event = e },
    }) orelse {
        event_mod.release(e);
        return Errno.nomem.value();
    };
    return @intCast(slot);
}

fn sys_event_signal(a: Args) Result {
    const e = getEvent(@intCast(a.a0)) orelse return Errno.badf.value();
    e.signal();
    return 0;
}

fn sys_wait_many(a: Args) Result {
    const count = a.a1;
    if (count == 0 or count > event_mod.MAX_WAIT) return Errno.inval.value();

    const raw = userSlice(a, a.a0, count * @sizeOf(u32)) orelse return Errno.fault.value();

    // Copied out of user memory before any of it is used: re-reading the array
    // after validating it is how a process talks the kernel into waiting on an
    // object it no longer holds.
    var events: [event_mod.MAX_WAIT]*event_mod.Event = undefined;
    for (0..count) |i| {
        const handle = std.mem.readInt(u32, raw[i * 4 ..][0..4], .little);
        events[i] = getEvent(handle) orelse return Errno.badf.value();
    }

    const index = event_mod.waitMany(events[0..count], deadlineFrom(a.a2)) catch |err| {
        return switch (err) {
            error.TimedOut => Errno.timedout.value(),
            else => Errno.inval.value(),
        };
    };
    return @intCast(index);
}

fn sys_svc_register(a: Args) Result {
    var buf: [svc.MAX_NAME]u8 = undefined;
    const name = userSlice(a, a.a0, a.a1) orelse return Errno.fault.value();
    if (name.len == 0 or name.len > buf.len) return Errno.inval.value();
    @memcpy(buf[0..name.len], name);

    const ch = channel_mod.create() catch return Errno.nomem.value();
    errdefer channel_mod.release(ch);

    svc.register(buf[0..name.len], ch) catch |err| {
        channel_mod.release(ch);
        return switch (err) {
            error.AlreadyRegistered => Errno.exists.value(),
            error.BadName => Errno.inval.value(),
            error.TableFull => Errno.nomem.value(),
            else => Errno.inval.value(),
        };
    };

    // The registry holds one reference and the handle holds the one made at
    // creation, so the channel outlives either going away alone.
    const slot = installHandle(.{
        .kind = .channel,
        .rights = .{ .read = true, .write = true },
        .data = .{ .channel = .{ .channel = ch, .serving = true } },
    }) orelse {
        svc.unregister(buf[0..name.len]);
        channel_mod.release(ch);
        return Errno.nomem.value();
    };
    return @intCast(slot);
}

fn sys_svc_connect(a: Args) Result {
    const name = userSlice(a, a.a0, a.a1) orelse return Errno.fault.value();
    if (name.len == 0 or name.len > svc.MAX_NAME) return Errno.inval.value();

    const ch = svc.lookup(name) catch return Errno.noent.value();
    const slot = installHandle(.{
        .kind = .channel,
        .rights = .{ .read = true, .write = true },
        .data = .{ .channel = .{ .channel = ch, .serving = false } },
    }) orelse {
        channel_mod.release(ch);
        return Errno.nomem.value();
    };
    return @intCast(slot);
}

fn sys_call(a: Args) Result {
    const ch = getChannel(@intCast(a.a0), false) orelse return Errno.badf.value();

    const request = userSlice(a, a.a1, a.a2) orelse return Errno.fault.value();
    if (request.len > abi.MAX_PAYLOAD) return Errno.inval.value();
    const out = userSlice(a, a.a3, a.a4) orelse return Errno.fault.value();

    var answer: channel_mod.Message = .{};
    channel_mod.call(ch, request, &answer, null) catch |err| {
        return switch (err) {
            error.Disconnected => Errno.pipe.value(),
            error.TimedOut => Errno.timedout.value(),
            error.TooLarge => Errno.inval.value(),
            else => Errno.io.value(),
        };
    };

    const n = @min(answer.len, out.len);
    @memcpy(out[0..n], answer.data[0..n]);
    return @intCast(n);
}

fn sys_recv(a: Args) Result {
    const ch = getChannel(@intCast(a.a0), true) orelse return Errno.badf.value();
    const out = userSlice(a, a.a1, a.a2) orelse return Errno.fault.value();
    const token_out = userSlice(a, a.a3, @sizeOf(u32)) orelse return Errno.fault.value();

    const got = channel_mod.recv(ch, deadlineFrom(a.a4)) catch |err| {
        return switch (err) {
            error.TimedOut => Errno.timedout.value(),
            error.Busy => Errno.nomem.value(),
            else => Errno.io.value(),
        };
    };

    std.mem.writeInt(u32, token_out[0..4], got.token, .little);
    const n = @min(got.message.len, out.len);
    @memcpy(out[0..n], got.message.data[0..n]);
    return @intCast(n);
}

fn sys_reply(a: Args) Result {
    const ch = getChannel(@intCast(a.a0), true) orelse return Errno.badf.value();
    const payload = userSlice(a, a.a2, a.a3) orelse return Errno.fault.value();
    if (payload.len > abi.MAX_PAYLOAD) return Errno.inval.value();

    channel_mod.reply(ch, @intCast(a.a1), payload) catch |err| {
        return switch (err) {
            error.BadToken => Errno.inval.value(),
            error.TooLarge => Errno.inval.value(),
            else => Errno.io.value(),
        };
    };
    return 0;
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
            "handler `" ++ decl.name ++ "` has no entry in lib/syscalls.zig; " ++
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

fn writeDirent(out: []u8, entry: fat.Entry) ?usize {
    const record = abi.Dirent{
        .size = entry.size,
        .mtime = entry.mtime,
        .is_dir = entry.is_dir,
        .name = entry.nameSlice(),
    };
    return record.encode(out);
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

    if (openFlags(a.a2).directory) {
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

    const count = abi.Argv.unpack(packed_args, &storage, &slices) catch return Errno.inval.value();

    const flags: abi.SpawnFlags = @bitCast(@as(u32, @truncate(a.a4)));

    if (flags.detached) {
        const id = exec.spawnAsync(path, slices[0..count]) catch |err| return spawnErrno(err);
        return @intCast(id);
    }
    return exec.spawn(path, slices[0..count]) catch |err| return spawnErrno(err);
}

fn spawnErrno(err: exec.Error) Result {
    return switch (err) {
        error.NotFound => Errno.noent.value(),
        error.BadImage => Errno.inval.value(),
        error.OutOfMemory => Errno.nomem.value(),
    };
}

fn sys_wait(a: Args) Result {
    const status_out = userSlice(a, a.a2, @sizeOf(i32)) orelse return Errno.fault.value();

    const exited = sched.waitChild(@intCast(a.a0), deadlineFrom(a.a1)) catch |err| {
        return switch (err) {
            error.NoChildren => Errno.child.value(),
            error.TimedOut => Errno.timedout.value(),
        };
    };

    std.mem.writeInt(i32, status_out[0..4], exited.status, .little);
    return @intCast(exited.id);
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
