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

const std = @import("std");
const ctx = @import("context.zig");
const handles = @import("../handle.zig");
const console = @import("../console.zig");
const hal = @import("../hal.zig");
const irqevent = @import("../irqevent.zig");
const ports = @import("../ports.zig");
const pmm = @import("../pmm.zig");
const pcicfg = @import("../pcicfg.zig");
const probe = @import("../probe.zig");
const sched = @import("../sched.zig");
const shm = @import("../shm.zig");

const Args = ctx.Args;
const Result = ctx.Result;
const Errno = ctx.Errno;
const currentHandles = ctx.currentHandles;

/// Contiguous DMA memory, the promise `shm_create` deliberately does not
/// make. A device engine addresses its rings as one base plus offsets, so the
/// backing has to be one physical run, and the caller has to know where it
/// starts: the physical base is written to `phys_out`.
///
/// Everything else is an ordinary segment: it maps with `shm_map`, travels
/// through channels as a handle, and its frames come back to the allocator
/// when the last reference closes. Cached, because on these machines
/// coherency is the chipset's job and an uncached ring would pay a cache
/// miss on every descriptor a driver touches.
pub fn sys_pci_read(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;
    return @intCast(pcicfg.read(pciSelector(a.a0, a.a1)));
}

pub fn sys_pci_write(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;
    pcicfg.write(pciSelector(a.a0, a.a1), @truncate(a.a2));
    return 0;
}

fn pciSelector(packed_location: usize, offset: usize) pcicfg.Selector {
    return .{
        .bus = @truncate(packed_location >> 8),
        .device = @truncate((packed_location >> 3) & 0x1F),
        .function = @truncate(packed_location & 0x7),
        .register = @truncate((offset & 0xFC) >> 2),
    };
}

pub fn sys_claim_device(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const t = sched.currentThread() orelse return Errno.perm.value();
    const location = [3]u16{ @truncate(a.a0), @truncate(a.a1), @truncate(a.a2) };
    if (!probe.markDriven(location, t.id)) return Errno.noent.value();
    return 0;
}

pub fn sys_dma_alloc(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const out = ctx.userSlice(a, a.a1, @sizeOf(u32)) orelse return Errno.fault.value();

    const seg = shm.createDma(a.a0) catch |err| return switch (err) {
        error.BadSize => Errno.inval.value(),
        else => Errno.nomem.value(),
    };

    const slot = ctx.installHandle(.{
        .kind = .shm,
        .rights = .{ .read = true, .write = true },
        .data = .{ .shm = seg },
    }) orelse {
        shm.release(seg);
        return Errno.nomem.value();
    };

    // The address is the hardware's, not the process's: two mappings of the
    // same segment differ, and a DMA engine does not care about mapping.
    std.mem.writeInt(u32, out[0..4], @intCast(shm.physBase(seg)), .little);
    return @intCast(slot);
}

pub fn sys_irq_attach(a: Args) Result {    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const table = currentHandles() orelse return Errno.nomem.value();
    const slot = table.alloc() orelse return Errno.nomem.value();

    // The caller's number is the firmware's: a table said 9, and where 9
    // actually arrives is this machine's business, not the driver's.
    const wired = hal.resolveIrq(@truncate(a.a0));
    if (wired.gsi != a.a0) console.debug("irq", "{d} arrives on line {d}", .{ a.a0, wired.gsi });

    const line = irqevent.attach(wired.gsi) catch |err| {
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
    if (count == 0 or base + count > ports.COUNT) return Errno.inval.value();

    const t = sched.currentThread() orelse return Errno.perm.value();
    const set = sched.portsFor(t) orelse return Errno.nomem.value();
    set.allow(base, count);

    // The CPU reads the bitmap from inside the TSS, so the change has to be
    // copied there before the next instruction can benefit from it.
    sched.reloadPorts(t);
    return 0;
}

pub fn sys_map_device(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const phys = a.a0;
    const len = a.a1;
    if (len == 0) return Errno.inval.value();

    const t = sched.currentThread() orelse return Errno.perm.value();

    const base = std.mem.alignBackward(usize, phys, hal.PAGE_SIZE);
    const end = std.mem.alignForward(usize, phys + len, hal.PAGE_SIZE);

    // Refusing the allocator's memory, which is not the same as refusing RAM.
    // A device aperture lives above it and the firmware's tables live inside
    // it: both are physically addressable and neither is the allocator's, and
    // a process that has to read the tables cannot be told they are RAM and
    // therefore out of bounds. What must never be handed over is a frame the
    // allocator believes it still owns.
    if (pmm.isManaged(base, end)) return Errno.inval.value();

    const at = t.shm_window.reserve(end - base) catch return Errno.nomem.value();

    var offset: usize = 0;
    while (offset < end - base) : (offset += hal.PAGE_SIZE) {
        t.space.map(at + offset, base + offset, .{
            .writable = true,
            // The frames are the device's, so tearing the address space down
            // must unmap them without freeing them.
            .shared = true,
            .uncached = true,
        }) catch return Errno.nomem.value();
    }

    // The page the aperture starts in, plus how far into it the caller asked.
    return @intCast(at + (phys - base));
}
