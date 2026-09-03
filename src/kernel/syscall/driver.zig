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
const lib = @import("lib");
const ctx = @import("context.zig");
const handles = @import("../handle.zig");
const console = @import("../console.zig");
const hal = @import("../hal.zig");
const input = @import("../input.zig");
const event = @import("../event.zig");
const irqevent = @import("../irqevent.zig");
const ports = @import("../ports.zig");
const pmm = @import("../pmm.zig");
const pcicfg = @import("../pcicfg.zig");
const probe = @import("../probe.zig");
const sched = @import("../sched.zig");
const shm = @import("../shm.zig");
const ublk = @import("../ublk.zig");

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
    const selector = pciSelector(a.a0, a.a1) orelse return Errno.inval.value();
    return @intCast(pcicfg.read(selector));
}

pub fn sys_pci_write(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;
    const selector = pciSelector(a.a0, a.a1) orelse return Errno.inval.value();
    pcicfg.write(selector, @truncate(a.a2));
    return 0;
}

fn pciSelector(packed_location: usize, offset: usize) ?pcicfg.Selector {
    if (packed_location > std.math.maxInt(u16) or offset > std.math.maxInt(u8)) return null;
    // The three shifts are `Location`'s own layout, and the masks beside them
    // are its field widths restated. It is a packed struct, so the bytes say
    // which is which without being taken apart by hand.
    const at: lib.pci.Location = @bitCast(@as(u16, @intCast(packed_location)));
    return .{
        .bus = at.bus,
        .device = at.device,
        .function = at.function,
        .register = @truncate(offset >> 2),
    };
}

pub fn sys_claim_device(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const t = sched.currentThread() orelse return Errno.perm.value();
    const location = lib.pci.Location.fromComponents(a.a0, a.a1, a.a2) orelse return Errno.inval.value();
    probe.claimDevice(.{ location.bus, location.device, location.function }, t.id) catch |err| return switch (err) {
        error.NotFound => Errno.noent.value(),
        error.Busy => Errno.busy.value(),
    };
    return 0;
}

pub fn sys_release_device(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const t = sched.currentThread() orelse return Errno.perm.value();
    const location = lib.pci.Location.fromComponents(a.a0, a.a1, a.a2) orelse return Errno.inval.value();
    return if (probe.releaseDevice(.{ location.bus, location.device, location.function }, t.id)) 0 else Errno.noent.value();
}

/// Look at the bus again.
///
/// Nothing on PCI announces an arrival or a departure, so a device a firmware
/// method has just switched on is on the bus and in no table until something
/// walks it again. The walk itself belongs to whoever knows which buses this
/// machine has, which is not kernel core; this is the door to it.
pub fn sys_pci_rescan(_: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;
    return if (probe.rescan()) 0 else Errno.nosys.value();
}

pub fn sys_dma_alloc(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const out = ctx.userWrite(a, a.a1, @sizeOf(u32)) orelse return Errno.fault.value();

    const seg = shm.createDma(a.a0) catch |err| return switch (err) {
        error.BadSize => Errno.inval.value(),
        else => Errno.nomem.value(),
    };

    const slot = ctx.installHandle(.{
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

pub fn sys_irq_attach(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const table = currentHandles() orelse return Errno.nomem.value();
    const slot = table.alloc() orelse return Errno.nomem.value();

    // The caller's number is the firmware's: a table said 9, and where 9
    // actually arrives is this machine's business, not the driver's.
    if (a.a0 > std.math.maxInt(u32)) return Errno.inval.value();
    const irq_number: u32 = @intCast(a.a0);
    const wired = hal.resolveIrq(irq_number);
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
        .rights = .{ .read = true },
        .data = .{ .irq = line },
    };
    return @intCast(slot);
}

pub fn sys_irq_ack(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const table = currentHandles() orelse return Errno.badf.value();
    const h = table.get(@truncate(a.a0)) orelse return Errno.badf.value();
    const line = switch (h.data) {
        .irq => |line| line,
        else => return Errno.badf.value(),
    };

    // `a1` says whether the pass that ended actually serviced anything,
    // which is what decides whether the line's other owners are woken: a
    // productive pass on a shared edge line may have been holding the wire
    // low across a neighbour's assertion.
    irqevent.acknowledge(line, a.a1 != 0);
    return 0;
}

/// Let the line through when a driver first waits on it.
///
/// Here rather than in `wait_many` because arming is what attaching deferred:
/// the line stays masked until someone is actually ready to be told about it.
pub fn armIfIrq(h: *handles.Handle) void {
    switch (h.data) {
        .irq => |line| if (!line.armed) irqevent.arm(line),
        else => {},
    }
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

    // In sixty-four bits, because both numbers are the caller's. Added in the
    // machine's own width, an aperture near the top of addressing carries its
    // end around past zero: the rounding then produces a span that is nowhere
    // near the request, the allocator is asked about the wrong frames, and
    // the mapping loop names memory the device does not own.
    const span = pageSpan(phys, len) orelse return Errno.inval.value();
    const base = span.base;
    const end = span.end;

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
        }) catch {
            // Nothing half done: the pages mapped so far go, and the window
            // takes its addresses back, since nothing else has taken from it.
            var back: usize = 0;
            while (back < offset) : (back += hal.PAGE_SIZE) t.space.unmap(at + back);
            t.shm_window.unreserve(at);
            return Errno.nomem.value();
        };
    }

    // The page the aperture starts in, plus how far into it the caller asked.
    return @intCast(at + (phys - base));
}

/// The whole pages `phys[0..len]` touches, or null when the range leaves the
/// address space. Worked out wider than an address so that no sum in it can
/// wrap, and handed back as addresses only once it is known they fit.
fn pageSpan(phys: usize, len: usize) ?struct { base: usize, end: usize } {
    const top: u64 = @as(u64, std.math.maxInt(usize)) + 1;
    const covers = std.math.add(u64, phys, len) catch return null;
    const end = std.mem.alignForward(u64, covers, hal.PAGE_SIZE);
    if (end > top) return null;
    return .{
        .base = std.mem.alignBackward(usize, phys, hal.PAGE_SIZE),
        .end = @intCast(end),
    };
}

// ---------------------------------------------------------------------------
// Volumes served by a process
// ---------------------------------------------------------------------------

/// Offer a volume the kernel's filesystems can mount, driven from here.
///
/// The disk on a bus this kernel does not drive is still a disk. What comes
/// back is an event to wait on and a shared area the bytes travel in: a
/// transfer lands in that area once and is copied once, rather than crossing
/// the boundary twice.
pub fn sys_volume_attach(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const name = ctx.userRead(a, a.a0, a.a1) orelse return Errno.fault.value();
    // Read for what the server asked for and written back with the handles it
    // was given, so it must be somewhere the caller could have written itself.
    const info_bytes = ctx.userWrite(a, a.a2, @sizeOf(ublk.Attach)) orelse return Errno.fault.value();

    var info: ublk.Attach = undefined;
    @memcpy(std.mem.asBytes(&info), info_bytes);

    const server = ctx.currentId();
    const index = ublk.attach(server, name, &info) catch |err| return switch (err) {
        error.BadGeometry => Errno.inval.value(),
        error.TooMany => Errno.nomem.value(),
        error.OutOfMemory => Errno.nomem.value(),
    };

    const pieces = ublk.parts(index, server) orelse return Errno.inval.value();

    const given = handOver(pieces) catch {
        ublk.detach(index, server);
        return Errno.nomem.value();
    };

    info.data = @intCast(given.data);
    info.doorbell = @intCast(given.doorbell);
    @memcpy(info_bytes, std.mem.asBytes(&info));

    ublk.publish(index, server);
    return @intCast(index);
}

/// The handle numbers the server is to use for each half.
const Given = struct { data: u32, doorbell: u32 };

/// Give the server a handle to each half of the volume it just attached.
///
/// Each handle takes its own reference. The volume holds one for as long as it
/// is attached, and detaching it must not free memory the server is still
/// mapping and still signalling through.
///
/// Both or neither: a server holding one half of a volume it cannot serve is
/// worse than one that failed to attach.
fn handOver(pieces: ublk.Parts) error{NoRoom}!Given {
    shm.retain(pieces.data);
    const data = ctx.installHandle(.{
        .rights = .{ .read = true, .write = true },
        .data = .{ .shm = pieces.data },
    }) orelse {
        shm.release(pieces.data);
        return error.NoRoom;
    };
    // The handle owns that reference now, so unwinding goes through the table
    // rather than around it.
    errdefer ctx.closeHandle(data);

    event.retain(pieces.doorbell);
    const doorbell = ctx.installHandle(.{
        .rights = .{ .read = true, .write = true },
        .data = .{ .event = pieces.doorbell },
    }) orelse {
        event.release(pieces.doorbell);
        return error.NoRoom;
    };

    return .{ .data = data, .doorbell = doorbell };
}

/// Take the next request on a volume this process serves. Never blocks: the
/// server waits on its event and drains what is there.
pub fn sys_volume_next(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    const into = ctx.userWrite(a, a.a1, @sizeOf(ublk.Request)) orelse return Errno.fault.value();

    const request = ublk.next(a.a0, ctx.currentId()) orelse return 0;

    @memcpy(into, std.mem.asBytes(&request));
    return 1;
}

/// Answer a request, waking whatever asked for it.
pub fn sys_volume_done(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;
    if (a.a1 > std.math.maxInt(u16)) return Errno.inval.value();

    ublk.done(a.a0, ctx.currentId(), @intCast(a.a1), @enumFromInt(@as(u8, @truncate(a.a2))), @intCast(a.a3));
    return 0;
}

/// Withdraw a volume, failing everything still waiting on it.
pub fn sys_volume_detach(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;

    ublk.detach(a.a0, ctx.currentId());
    return 0;
}

// ---------------------------------------------------------------------------
// Input from a device this process drives
// ---------------------------------------------------------------------------

/// Report keys from a keyboard reached over a bus the kernel does not drive.
///
/// What a key means stays here: the layout, the modifiers, the composition
/// and the layout-switch key are the same for every keyboard, and a driver
/// that worked them out itself would be a second opinion on what the machine
/// is typing.
pub fn sys_key_post(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;
    if (a.a1 > MAX_REPORTS) return Errno.inval.value();

    const bytes = ctx.userRead(a, a.a0, a.a1 * @sizeOf(lib.syscalls.KeyReport)) orelse
        return Errno.fault.value();

    for (0..a.a1) |i| {
        var report: lib.syscalls.KeyReport = undefined;
        @memcpy(std.mem.asBytes(&report), bytes[i * @sizeOf(lib.syscalls.KeyReport) ..][0..@sizeOf(lib.syscalls.KeyReport)]);
        input.postKey(report.code, report.pressed != 0);
    }
    return @intCast(a.a1);
}

/// Report movement from a pointing device reached the same way.
pub fn sys_pointer_post(a: Args) Result {
    if (ctx.require(.{ .driver = true })) |denied| return denied;
    if (a.a1 > MAX_REPORTS) return Errno.inval.value();

    const bytes = ctx.userRead(a, a.a0, a.a1 * @sizeOf(lib.syscalls.PointerReport)) orelse
        return Errno.fault.value();

    for (0..a.a1) |i| {
        var report: lib.syscalls.PointerReport = undefined;
        @memcpy(std.mem.asBytes(&report), bytes[i * @sizeOf(lib.syscalls.PointerReport) ..][0..@sizeOf(lib.syscalls.PointerReport)]);
        input.postPointer(.{
            .dx = report.dx,
            .dy = report.dy,
            .wheel = report.wheel,
            .buttons = report.buttons,
            .buttons_changed = report.buttons_changed != 0,
        });
    }
    return @intCast(a.a1);
}

/// How many reports one call may carry. A keyboard produces at most a
/// handful per interrupt, and a bound is what keeps a bad count from
/// walking a caller's address space.
const MAX_REPORTS = 64;
