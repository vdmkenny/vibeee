//! Calls a driver server needs, and nothing else does.
//!
//! Its own group because the boundary matters: these are what let code outside
//! the kernel touch hardware, and keeping them together makes the whole of
//! that surface one file to read. `design/02-kernel-core.md` §9.
//!
//! Every call here needs `Caps.driver`, which a process only has because
//! something above it in the tree passed it down. A capability is intersected
//! at every spawn and can never widen, so granting one to a driver server does
//! not grant it to anything that server later starts.

const abi = @import("lib").syscalls;
const ctx = @import("context.zig");
const handles = @import("../handle.zig");
const irqevent = @import("../irqevent.zig");

const Args = ctx.Args;
const Result = ctx.Result;
const Errno = ctx.Errno;
const currentHandles = ctx.currentHandles;

pub fn sys_irq_attach(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const table = currentHandles() orelse return Errno.nomem.value();
    const slot = table.alloc() orelse return Errno.nomem.value();

    const line = irqevent.attach(@truncate(a.a0)) catch |err| {
        table.entries[slot] = .{};
        return switch (err) {
            error.Busy => Errno.busy.value(),
            error.Unsupported => Errno.inval.value(),
            error.OutOfMemory => Errno.nomem.value(),
        };
    };

    table.entries[slot] = .{
        .kind = .irq,
        .rights = .{ .read = true },
        .data = .{ .irq = line },
    };
    return @intCast(slot);
}

pub fn sys_irq_ack(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const table = currentHandles() orelse return Errno.badf.value();
    const h = table.get(@truncate(a.a0)) orelse return Errno.badf.value();
    if (h.kind != .irq) return Errno.badf.value();

    irqevent.acknowledge(h.data.irq);
    return 0;
}

/// Let the line through when a driver first waits on it.
///
/// Here rather than in `wait_many` because arming is what attaching deferred:
/// the line stays masked until someone is actually ready to be told about it.
pub fn armIfIrq(h: *handles.Handle) void {
    if (h.kind == .irq and !h.data.irq.armed) irqevent.arm(h.data.irq);
}
