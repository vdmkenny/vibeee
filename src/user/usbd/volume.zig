//! Offering a disk to the kernel's filesystems.
//!
//! A disk found on this bus is driven from here, and the filesystem that
//! reads it is in the kernel. The kernel takes it as a volume: it posts
//! requests, this rings them through to the device, and the answers go
//! back. The bytes never leave the shared area the kernel handed over, so
//! a transfer is copied once.
//!
//! Nothing polls. The kernel signals a doorbell when it posts, the bus's
//! own event loop waits on that doorbell alongside everything else, and a
//! disk nobody is reading costs nothing.

const abi = @import("lib").volume;
const log = @import("ulib").log;
const out = @import("ulib").out;
const str = @import("ulib").str;
const sys = @import("sys");
const umass = @import("umass.zig");

/// One offered disk: which volume the kernel calls it, and where its
/// shared area is mapped here.
pub const Offer = struct {
    live: bool = false,
    volume: usize = 0,
    /// The disk this serves, by the address the bus gave it.
    address: u7 = 0,
    doorbell: u32 = 0,
    area: [*]u8 = undefined,
    area_len: usize = 0,
    name: [8]u8 = @splat(0),
    name_len: u8 = 0,

    pub fn nameSlice(self: *const Offer) []const u8 {
        return self.name[0..@min(self.name_len, self.name.len)];
    }
};

var offers: [abi.MAX_VOLUMES]Offer = @splat(.{});

pub fn all() []const Offer {
    return &offers;
}

/// Offer a disk. Answering false leaves it driven but unmounted, which is
/// a disk that can still be read by whatever asks this service directly.
pub fn offer(disk: *umass.Disk) bool {
    const slot = free() orelse return false;
    const which = index(slot);

    slot.name_len = nameFor(&slot.name, which);

    var info = abi.Attach{
        .sectors = disk.sectors(),
        .sector_bytes = disk.sectorBytes(),
        .flags = .{ .removable = disk.inquiry.removable },
    };

    const volume = sys.volumeAttach(slot.nameSlice(), &info);
    if (volume < 0) {
        log.warn("usbd", "the kernel would not take the volume");
        return false;
    }

    const area = sys.shmMap(@intCast(info.data), .{ .writable = true }) orelse {
        sys.volumeDetach(@intCast(volume));
        log.warn("usbd", "the volume's shared area would not map");
        return false;
    };

    slot.* = .{
        .live = true,
        .volume = @intCast(volume),
        .address = disk.address,
        .doorbell = @intCast(info.doorbell),
        .area = area,
        .area_len = info.slots * info.slot_bytes,
        .name = slot.name,
        .name_len = slot.name_len,
    };

    say(slot, disk);
    return true;
}

/// Withdraw the offer for a disk that has gone. Whatever the kernel was
/// waiting for is failed rather than left to its deadline.
pub fn withdraw(address: u7) void {
    for (&offers) |*slot| {
        if (!slot.live or slot.address != address) continue;
        sys.volumeDetach(slot.volume);
        _ = sys.close(slot.doorbell);
        log.begin("usbd", .key);
        out.text(slot.nameSlice());
        out.text(" is gone");
        log.end();
        slot.* = .{};
    }
}

/// The doorbells to wait on, gathered for the event loop.
pub fn doorbells(into: []u32) usize {
    var count: usize = 0;
    for (&offers) |*slot| {
        if (!slot.live or count >= into.len) continue;
        into[count] = slot.doorbell;
        count += 1;
    }
    return count;
}

/// The offer a woken doorbell belongs to.
pub fn forDoorbell(handle: u32) ?*Offer {
    for (&offers) |*slot| {
        if (slot.live and slot.doorbell == handle) return slot;
    }
    return null;
}

/// Do everything the kernel has posted on this volume, and answer each.
/// Called because the doorbell rang, and it drains rather than taking one:
/// several readers waking at once should cost one wake, not several.
pub fn serve(slot: *Offer) void {
    const disk = umass.forAddress(slot.address) orelse {
        // The medium went while requests were queued. Everything waiting
        // is told so, rather than waiting out a deadline for a disk that
        // is not coming back.
        var request = abi.Request{};
        while (sys.volumeNext(slot.volume, &request)) {
            sys.volumeDone(slot.volume, request.tag, .no_medium, 0);
        }
        return;
    };

    var request = abi.Request{};
    while (sys.volumeNext(slot.volume, &request)) {
        const answer = carry(slot, disk, request);
        sys.volumeDone(slot.volume, request.tag, answer.status, answer.sectors);
    }
}

const Answer = struct { status: abi.Status, sectors: u32 };

fn carry(slot: *Offer, disk: *umass.Disk, request: abi.Request) Answer {
    if (request.op == .flush) {
        umass.flush(disk);
        return .{ .status = .ok, .sectors = 0 };
    }

    const size = disk.sectorBytes();
    const bytes = @as(usize, request.sectors) * size;
    const at = request.offset;
    if (at + bytes > slot.area_len) return .{ .status = .io_error, .sectors = 0 };

    const window = slot.area[at..][0..bytes];
    const result = switch (request.op) {
        .read => umass.read(disk, request.lba, window),
        .write => umass.write(disk, request.lba, window),
        .flush => unreachable,
    };

    result catch |err| return .{
        .status = switch (err) {
            umass.Error.Gone => .no_medium,
            else => .io_error,
        },
        .sectors = 0,
    };
    return .{ .status = .ok, .sectors = request.sectors };
}

fn free() ?*Offer {
    for (&offers) |*slot| {
        if (!slot.live) return slot;
    }
    return null;
}

fn index(slot: *const Offer) usize {
    return (@intFromPtr(slot) - @intFromPtr(&offers[0])) / @sizeOf(Offer);
}

/// What a volume is called: the same shape as every other disk on the
/// machine, so `disk` and `mount` need nothing new to name it.
fn nameFor(into: *[8]u8, which: usize) u8 {
    var text = str.Builder{ .buf = into };
    text.text("usb");
    text.number(which);
    return @intCast(text.done().len);
}

fn say(slot: *const Offer, disk: *const umass.Disk) void {
    log.begin("usbd", .key);
    out.text(slot.nameSlice());
    out.text(": ");
    var buf: [24]u8 = @splat(0);
    var text = str.Builder{ .buf = &buf };
    text.quantity(@intCast(disk.capacity.bytes_() / (1024 * 1024)), "MiB");
    out.text(text.done());
    out.text(", ready to mount");
    log.end();
}
