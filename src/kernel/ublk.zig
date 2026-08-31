//! A block device whose driver is a process.
//!
//! The disk on a USB bus is driven from userspace, and the filesystem that
//! reads it lives here. This is the seam between them: a volume registered
//! with the block layer whose reads and writes are handed to a server
//! process and waited on, rather than issued to hardware.
//!
//! The shape is deliberately small. A shared data area carries the bytes,
//! so nothing is copied twice and the server's own DMA can land straight
//! in it. Everything else is a request, taken one at a time through the
//! ordinary syscall path: a queue this shallow does not earn a lock-free
//! ring, and a request that costs two syscalls is a rounding error beside
//! the transfer it describes.
//!
//! The caller blocks, with a deadline. A server that dies mid-request
//! leaves its callers failing rather than waiting: a filesystem told
//! nothing forever is worse than one told the disk is gone.

const std = @import("std");
const abi = @import("lib").volume;
const console = @import("console.zig");
const bcache = @import("bcache.zig");
const block = @import("block.zig");
const event = @import("event.zig");
const hal = @import("hal.zig");
const sched = @import("sched.zig");
const shm = @import("shm.zig");
const vfs = @import("vfs.zig");
const wait = @import("wait.zig");

/// How many volumes one machine plausibly carries: a card reader with a
/// few slots, and something in a socket.
pub const MAX_VOLUMES = abi.MAX_VOLUMES;

/// How many requests may be outstanding on one volume. Deep enough that
/// several readers do not serialise on each other, shallow enough that
/// the data area stays small.
pub const DEPTH = abi.DEPTH;

/// The largest transfer one request carries. A server that cannot manage
/// this much in one go says so when it attaches, and longer reads are
/// split here rather than in whatever asked for them.
pub const SLOT_BYTES = abi.SLOT_BYTES;

pub const Error = error{
    TooMany,
    OutOfMemory,
    BadGeometry,
};

/// The shape both sides agree about lives in `lib.volume`, so a server and
/// this file cannot come to hold different ideas of the same bytes.
pub const Op = abi.Op;
pub const Status = abi.Status;
pub const Flags = abi.Flags;
pub const Request = abi.Request;
pub const Attach = abi.Attach;

fn errorFor(status: Status) block.Error!void {
    return switch (status) {
        .ok => {},
        .timeout => block.Error.Timeout,
        .write_protected => block.Error.NotSupported,
        else => block.Error.IoError,
    };
}

const Slot = struct {
    /// The slot is spoken for. Not yet something the server may take:
    /// the request in it is still being written.
    busy: bool = false,
    /// The request is written and the server may have it.
    offered: bool = false,
    /// The server has it and has not answered.
    taken: bool = false,
    done: bool = false,
    request: Request = .{},
    status: Status = .ok,
    moved: u32 = 0,
    /// Where the caller waits for its own request and no other.
    queue: wait.Queue = .{},
};

const Volume = struct {
    live: bool = false,
    name: [16]u8 = @splat(0),
    name_len: u8 = 0,
    data: ?*shm.Segment = null,
    doorbell: ?*event.Event = null,
    slots: [DEPTH]Slot = @splat(.{}),
    sectors: u64 = 0,
    sector_bytes: u32 = 0,
    flags: Flags = .{},
    /// The device as the block layer holds it, cached, so the partition
    /// scan and everything after it go through one copy of it.
    published: block.Device = undefined,
    /// Where waiters queue when every slot is busy. One place rather than
    /// a spin: the depth is small and a burst of readers is normal.
    room: wait.Queue = .{},

    fn nameSlice(self: *const Volume) []const u8 {
        return self.name[0..@min(self.name_len, self.name.len)];
    }

    /// The server's data area as bytes this side can read and write.
    /// Contiguous by construction: the segment is allocated for DMA.
    fn area(self: *const Volume) []u8 {
        const seg = self.data orelse return &.{};
        const at: [*]u8 = @ptrFromInt(hal.physToVirt(shm.physBase(seg)));
        return at[0..seg.size];
    }

    fn slotArea(self: *const Volume, index: usize) []u8 {
        const all = self.area();
        const at = index * SLOT_BYTES;
        if (at + SLOT_BYTES > all.len) return &.{};
        return all[at..][0..SLOT_BYTES];
    }
};

var volumes: [MAX_VOLUMES]Volume = @splat(.{});

/// How long a caller waits before deciding the server is not coming back.
/// Generous: a card reader's own housekeeping stalls for seconds, and a
/// filesystem told the disk is gone cannot take it back.
///
/// Written as durations and turned into deadlines at the point of use,
/// because the blocking calls take a time and not an interval.
const READ_PATIENCE_US: u64 = 5_000_000;
const WRITE_PATIENCE_US: u64 = 15_000_000;

// ---------------------------------------------------------------------------
// The server's side
// ---------------------------------------------------------------------------

/// Register a volume, and hand back what the server needs to serve it.
pub fn attach(name: []const u8, info: *Attach) Error!usize {
    if (info.sector_bytes == 0 or info.sectors == 0) return Error.BadGeometry;
    if (info.sector_bytes > SLOT_BYTES) return Error.BadGeometry;

    const index = freeVolume() orelse return Error.TooMany;
    const volume = &volumes[index];

    const data = shm.createDma(DEPTH * SLOT_BYTES) catch return Error.OutOfMemory;
    errdefer shm.release(data);

    const doorbell = event.create() catch return Error.OutOfMemory;
    errdefer event.release(doorbell);

    volume.* = .{
        .live = true,
        .name_len = @intCast(@min(name.len, volume.name.len)),
        .data = data,
        .doorbell = doorbell,
        .sectors = info.sectors,
        .sector_bytes = info.sector_bytes,
        .flags = info.flags,
    };
    @memcpy(volume.name[0..volume.name_len], name[0..volume.name_len]);

    info.slots = DEPTH;
    info.slot_bytes = SLOT_BYTES;
    return index;
}

/// The handles the server holds. Kept apart from `attach` so the syscall
/// layer owns handle installation and this file owns the volume.
pub fn parts(index: usize) ?struct { data: *shm.Segment, doorbell: *event.Event } {
    if (index >= volumes.len or !volumes[index].live) return null;
    return .{
        .data = volumes[index].data.?,
        .doorbell = volumes[index].doorbell.?,
    };
}

/// Publish the volume to the block layer, once the server has its
/// handles. Separate from `attach` so a server that fails halfway leaves
/// nothing mountable behind.
///
/// Reading the partition table has to wait: the server is still inside
/// the call that got here, so the first read would be one it cannot
/// answer. A thread of its own does it, and blocks the way any other
/// reader would until the server reaches its loop.
pub fn publish(index: usize) void {
    if (index >= volumes.len or !volumes[index].live) return;
    const volume = &volumes[index];

    const raw = block.Device{
        .name = volume.nameSlice(),
        .ctx = volume,
        .ops = &OPS,
        .sectors = volume.sectors,
        .read_only = volume.flags.read_only,
        .is_volatile = false,
    };

    // Cached, for the same reason the internal disk is: a filesystem
    // reads its own metadata over and over, and every miss here is a
    // round trip through another process.
    volume.published = bcache.wrap(raw) orelse raw;
    block.register(volume.published);

    _ = sched.spawn("volume-scan", .normal, survey, index, 8 * 1024) catch {
        // Without the scan the volume is still there and still readable,
        // it just has no partitions listed. A medium with a filesystem
        // written straight onto it is unaffected.
        block.markWholeDiskUsable(&volume.published);
    };
}

/// Read the partition table, now that the server can answer.
fn survey(index: usize) callconv(.c) void {
    const volume = &volumes[index];
    if (volume.live) {
        // A medium with no partition table is a filesystem in its own
        // right, which is how most sticks and cards arrive.
        const found = block.scanPartitions(&volume.published);
        if (found == 0) block.markWholeDiskUsable(&volume.published);

        // Then put it where media go. A disk plugged in should arrive in
        // the same place as one that was there at boot.
        for (block.list(), 0..) |*dev, i| {
            if (dev.ctx != volume.published.ctx or !block.isMountCandidate(i)) continue;
            if (vfs.mountMedia(dev)) |where| {
                console.info("mount", "{s} on {s}", .{ where, dev.name });
            }
        }
    }
    sched.exit();
}

/// Take the next request, if there is one. The server waits on the
/// doorbell rather than asking repeatedly.
pub fn next(index: usize, into: *Request) bool {
    if (index >= volumes.len or !volumes[index].live) return false;
    const volume = &volumes[index];

    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    for (&volume.slots, 0..) |*slot, i| {
        if (!slot.busy or !slot.offered or slot.taken) continue;
        slot.taken = true;
        into.* = slot.request;
        into.tag = @intCast(i);
        return true;
    }
    return false;
}

/// Answer one request, and wake whoever is waiting for it.
pub fn done(index: usize, tag: u16, status: Status, moved: u32) void {
    if (index >= volumes.len or !volumes[index].live) return;
    const volume = &volumes[index];
    if (tag >= volume.slots.len) return;

    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    const slot = &volume.slots[tag];
    if (!slot.busy or !slot.taken) return;
    slot.status = status;
    slot.moved = moved;
    slot.done = true;
    _ = slot.queue.wakeOne();
}

/// The server is going away. Every waiter is told so rather than left
/// waiting out its deadline.
pub fn detach(index: usize) void {
    if (index >= volumes.len or !volumes[index].live) return;
    const volume = &volumes[index];

    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    for (&volume.slots) |*slot| {
        if (!slot.busy or slot.done) continue;
        slot.status = .no_medium;
        slot.done = true;
        _ = slot.queue.wakeOne();
    }
    volume.live = false;
    _ = volume.room.wakeAll();

    // The mounts go before the rows do: a mount pointing at a device that
    // answers nothing is worse than no mount at all.
    _ = vfs.abandon(volume.published.ctx);
    block.retire(volume.published.ctx);

    if (volume.doorbell) |bell| event.release(bell);
    if (volume.data) |seg| shm.release(seg);
    volume.doorbell = null;
    volume.data = null;
}

// ---------------------------------------------------------------------------
// The filesystem's side
// ---------------------------------------------------------------------------

const OPS = block.Ops{ .read = readBlocks, .write = writeBlocks, .flush = flushVolume };

fn readBlocks(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
    const volume: *Volume = @ptrCast(@alignCast(ctx));
    try each(volume, lba, buf.len, .read, buf, &.{});
}

fn writeBlocks(ctx: *anyopaque, lba: u64, buf: []const u8) block.Error!void {
    const volume: *Volume = @ptrCast(@alignCast(ctx));
    if (volume.flags.read_only) return block.Error.NotSupported;
    try each(volume, lba, buf.len, .write, &.{}, buf);
}

fn flushVolume(ctx: *anyopaque) block.Error!void {
    const volume: *Volume = @ptrCast(@alignCast(ctx));
    const slot_index = try claim(volume);
    defer freeSlot(volume, slot_index);
    volume.slots[slot_index].request = .{ .op = .flush, .offset = @intCast(slot_index * SLOT_BYTES) };
    try run(volume, slot_index, WRITE_PATIENCE_US);
}

/// Split a transfer into what one slot carries, and do each piece. The
/// pieces are sequential: a filesystem read is one caller's, and running
/// its halves at once would need its buffer split too.
fn each(
    volume: *Volume,
    lba: u64,
    bytes: usize,
    op: Op,
    into: []u8,
    from: []const u8,
) block.Error!void {
    const sector = volume.sector_bytes;
    if (sector == 0 or bytes % sector != 0) return block.Error.NotSupported;

    const per_slot = SLOT_BYTES / sector;
    var at: usize = 0;
    var where = lba;

    while (at < bytes) {
        const sectors = @min((bytes - at) / sector, per_slot);
        const chunk = sectors * sector;

        const slot_index = try claim(volume);
        defer freeSlot(volume, slot_index);

        const area = volume.slotArea(slot_index);
        if (area.len < chunk) return block.Error.IoError;

        if (op == .write) @memcpy(area[0..chunk], from[at..][0..chunk]);
        volume.slots[slot_index].request = .{
            .op = op,
            .sectors = @intCast(sectors),
            .lba = where,
            .offset = @intCast(slot_index * SLOT_BYTES),
        };

        try run(volume, slot_index, if (op == .write) WRITE_PATIENCE_US else READ_PATIENCE_US);
        if (op == .read) @memcpy(into[at..][0..chunk], area[0..chunk]);

        at += chunk;
        where += sectors;
    }
}

/// Take a slot, waiting for one if every slot is busy.
fn claim(volume: *Volume) block.Error!usize {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    while (volume.live) {
        for (&volume.slots, 0..) |*slot, i| {
            if (slot.busy) continue;
            slot.* = .{ .busy = true, .queue = slot.queue };
            return i;
        }
        _ = wait.blockOn(&.{&volume.room}, sched.deadlineIn(READ_PATIENCE_US)) catch
            return block.Error.Timeout;
    }
    return block.Error.IoError;
}

fn freeSlot(volume: *Volume, index: usize) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    volume.slots[index].busy = false;
    volume.slots[index].offered = false;
    volume.slots[index].taken = false;
    volume.slots[index].done = false;
    _ = volume.room.wakeOne();
}

/// Ring the doorbell and wait for this slot's answer.
fn run(volume: *Volume, index: usize, patience_us: u64) block.Error!void {
    const doorbell = volume.doorbell orelse return block.Error.IoError;
    const deadline = sched.deadlineIn(patience_us);

    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    // The request is only offered once it is written, and the doorbell
    // only rings once it is offered: a slot marked busy but not yet
    // filled must never be something the server can take.
    const slot = &volume.slots[index];
    slot.offered = true;
    doorbell.signal();
    while (!slot.done) {
        if (!volume.live) return block.Error.IoError;
        _ = wait.blockOn(&.{&slot.queue}, deadline) catch return block.Error.Timeout;
    }
    return errorFor(slot.status);
}

fn freeVolume() ?usize {
    for (&volumes, 0..) |*volume, i| {
        if (!volume.live) return i;
    }
    return null;
}

comptime {
    if (SLOT_BYTES % block.SECTOR_SIZE != 0) @compileError("a slot holds whole sectors");
}

test "a status becomes the block error a filesystem can act on" {
    try errorFor(.ok);
    try std.testing.expectError(block.Error.Timeout, errorFor(.timeout));
    try std.testing.expectError(block.Error.NotSupported, errorFor(.write_protected));
    try std.testing.expectError(block.Error.IoError, errorFor(.no_medium));
    try std.testing.expectError(block.Error.IoError, errorFor(.aborted));
}
