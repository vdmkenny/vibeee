//! Syscall dispatch.
//!
//! The table in `syscall_table.zig` is the contract; this file binds each entry
//! to an implementation. The binding is checked at comptime: a documented
//! syscall with no `sys_<name>` function fails the build, and so does a handler
//! with no table entry. The interface therefore cannot drift from its
//! documentation, because neither can exist alone.

const std = @import("std");
const abi = @import("syscall_table.zig");
const console = @import("console.zig");
const hal = @import("hal.zig");
const sched = @import("sched.zig");
const shutdown_mod = @import("shutdown.zig");
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
    const status: isize = @bitCast(a.a0);
    if (sched.currentThread()) |t| {
        console.debug("exit", "{s} (thread {d}) status {d}", .{ t.name, t.id, status });
    }
    // Never returns: the thread is unlinked and the next one is switched in.
    // The abandoned interrupt frame goes with the dying thread's stack.
    sched.exit();
}

fn sys_write(a: Args) Result {
    const handle: u32 = @truncate(a.a0);
    if (handle != abi.STDOUT and handle != abi.STDERR) return Errno.badf.value();

    const buf = userSlice(a, a.a1, a.a2) orelse return Errno.fault.value();
    if (handle == abi.STDERR) console.setColor(.light_red, .black);
    console.writeString(buf);
    if (handle == abi.STDERR) console.setColor(.light_grey, .black);
    return @intCast(buf.len);
}

fn sys_read(a: Args) Result {
    const handle: u32 = @truncate(a.a0);
    if (handle != abi.STDIN) return Errno.badf.value();

    const buf = userSlice(a, a.a1, a.a2) orelse return Errno.fault.value();
    if (buf.len == 0) return 0;

    // Block until a line is available. Sleeping rather than spinning matters:
    // a shell waiting at a prompt must not consume the CPU that everything else
    // needs, and on a single core it would starve them entirely.
    while (!tty.hasLine()) sched.sleepMicros(10_000);

    return @intCast(tty.read(buf));
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
    std.mem.writeInt(u64, out[0..8], hal.monotonicMicros(), .little);
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
