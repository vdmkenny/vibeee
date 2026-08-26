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
const sched = @import("../sched.zig");

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

pub fn sys_ioport_grant(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const base = a.a0;
    const count = a.a1;
    if (count == 0 or base + count > PORTS) return Errno.inval.value();

    const t = sched.currentThread() orelse return Errno.perm.value();
    const bits = sched.ioBitmapFor(t) orelse return Errno.nomem.value();

    // Clear is allow, which is the opposite of how it reads, and is what the
    // CPU defines: a set bit traps.
    for (base..base + count) |port| {
        bits[port / 8] &= ~(@as(u8, 1) << @truncate(port % 8));
    }

    // The CPU reads the bitmap from inside the TSS, so the change has to be
    // copied there before the next instruction can benefit from it.
    sched.reloadIoBitmap(t);
    return 0;
}

/// Every port an x86 machine has.
const PORTS = 65536;
