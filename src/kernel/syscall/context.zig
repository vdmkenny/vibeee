//! What every syscall handler needs, and nothing else.
//!
//! Split out so the handler groups can share it without importing each other,
//! and without importing the dispatcher that imports them, which would be a
//! cycle. `syscall.zig` re-exports the parts the architecture layer needs, so
//! nothing outside this directory has to know the split exists.

const std = @import("std");
const abi = @import("lib").syscalls;
const clock = @import("../clock.zig");
const handles = @import("../handle.zig");
const hal = @import("../hal.zig");
const path_mod = @import("../path.zig");
const sched = @import("../sched.zig");

pub const Errno = abi.Errno;

/// Arguments as the architecture delivers them, plus the process context the
/// handler needs. Keeping this architecture-neutral is what lets the handlers
/// be portable.
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

/// The shape every handler has; what the dispatcher binds table entries to.
pub const Handler = *const fn (Args) Result;

/// Validate a user pointer/length pair and return it as a slice.
///
/// The whole range must sit below the kernel base, and the length must not
/// wrap. The slice is produced once and used once: re-reading the pointer after
/// checking it is how time-of-check/time-of-use bugs get in.
pub fn userSlice(a: Args, ptr: usize, len: usize) ?[]u8 {
    if (len == 0) return &.{};
    if (ptr == 0) return null;

    const end = std.math.add(usize, ptr, len) catch return null;
    if (a.from_user and (ptr >= hal.KERNEL_BASE or end > hal.KERNEL_BASE)) return null;

    const p: [*]u8 = @ptrFromInt(ptr);
    return p[0..len];
}

/// Copy a user path out and make it absolute.
///
/// Copied first because the caller's memory must not be read twice: a path
/// validated and then re-read is the classic time-of-check bug.
pub fn userPath(a: Args, ptr: usize, len: usize, buf: []u8) ?[]const u8 {
    const raw = userSlice(a, ptr, len) orelse return null;
    if (raw.len == 0 or raw.len > path_mod.MAX) return null;

    var scratch: [path_mod.MAX]u8 = undefined;
    @memcpy(scratch[0..raw.len], raw);

    return path_mod.resolve(scratch[0..raw.len], buf) catch null;
}

pub fn currentHandles() ?*handles.Table {
    const t = sched.currentThread() orelse return null;
    return &t.handles;
}

/// Claim the lowest free handle for `h`.
pub fn installHandle(h: handles.Handle) ?u32 {
    const table = currentHandles() orelse return null;
    const slot = table.alloc() orelse return null;
    table.entries[slot] = h;
    return slot;
}

/// Timeouts arrive as a u32 with two sentinel values (`abi.Timeout`), so a
/// caller can poll, block forever, or bound the wait without a second argument
/// saying which. Null here means no deadline.
pub fn deadlineFrom(timeout_us: usize) ?u64 {
    if (timeout_us == abi.Timeout.forever) return null;
    return clock.monotonicMicros() + timeout_us;
}

/// What the calling process is allowed to do.
///
/// Everything before there is a process, which is the boot self-test and early
/// init: they are the kernel, and the kernel is not something to hold back
/// from itself.
pub fn currentCaps() abi.Caps {
    const t = sched.currentThread() orelse return abi.Caps.all;
    return t.caps;
}

/// Refuse unless the caller holds every capability named.
pub fn require(wanted: abi.Caps) ?Result {
    return if (currentCaps().has(wanted)) null else Errno.perm.value();
}
