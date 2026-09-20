//! Block cache.
//!
//! Wraps a `block.Device` and presents the same interface, so every consumer,
//! FAT, the partition scanner, the ELF loader, benefits without knowing it
//! exists.
//!
//! This matters more on the target than it would elsewhere. Reads are PIO, so
//! every sector costs 256 `insw` operations plus polling, all of it on the CPU
//! rather than a DMA engine. Filesystem access re-reads the same handful of
//! sectors constantly: the FAT itself, the directory, the boot sector. Caching
//! those turns a chain walk from one transfer per link into one transfer per
//! *sector of FAT*, which for a small file is usually one.
//!
//! What is held and how a run is served is `bcache/lines.zig`'s, pure and
//! host-tested. Here is the lock around it and the device it presents.

const std = @import("std");
const block = @import("block.zig");
const console = @import("console.zig");
const lock_mod = @import("lock.zig");
const lines = @import("bcache/lines.zig");

pub const CAPACITY_SECTORS = lines.CAPACITY_SECTORS;
pub const Stats = lines.Stats;

pub const Cache = struct {
    backing: block.Device,
    table: lines.Lines = .{},
    lock: lock_mod.Lock = .{},

    /// Held for the whole operation, backing reads included: picking a
    /// line and filling it are two steps around a wait for the medium, and
    /// a second caller let in between them can pick the very line the
    /// first is still filling, for a different sector entirely.
    fn readRun(self: *Cache, lba: u64, out: []u8) block.Error!void {
        self.lock.hold() catch return block.Error.IoError;
        defer self.lock.release();
        return self.table.readRun(self.backing, lba, out);
    }

    fn writeRun(self: *Cache, lba: u64, in: []const u8) block.Error!void {
        self.lock.hold() catch return block.Error.IoError;
        defer self.lock.release();
        return self.table.writeRun(self.backing, lba, in);
    }

    /// Drop everything. Called when removable media goes away: the sectors
    /// cached from the old medium describe nothing that is still there.
    pub fn invalidate(self: *Cache) void {
        self.table.invalidate();
    }
};

// ---------------------------------------------------------------------------
// block.Device plumbing
// ---------------------------------------------------------------------------

fn read(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
    const self: *Cache = @ptrCast(@alignCast(ctx));
    return self.readRun(lba, buf);
}

fn write(ctx: *anyopaque, lba: u64, buf: []const u8) block.Error!void {
    const self: *Cache = @ptrCast(@alignCast(ctx));
    return self.writeRun(lba, buf);
}

fn flush(ctx: *anyopaque) block.Error!void {
    const self: *Cache = @ptrCast(@alignCast(ctx));
    // Nothing is held dirty here, write-through means the backing device is
    // always current, so this only has to reach the device's own cache.
    const f = self.backing.ops.flush orelse return;
    return f(self.backing.ctx);
}

const ops = block.Ops{ .read = read, .write = write, .flush = flush };

/// Storage for caches. One per whole disk; partitions share their disk's cache,
/// which is what makes a lookup on one partition warm the FAT for the other.
/// A cache whose device has gone is given back and taken again by the next
/// arrival, so a card plugged in and out all day never runs the pool dry.
var caches: [4]Cache = undefined;
var taken: [caches.len]bool = @splat(false);

/// Wrap `dev` in a cache and return a device that reads through it.
pub fn wrap(dev: block.Device) ?block.Device {
    const index = std.mem.indexOfScalar(bool, &taken, false) orelse return null;
    taken[index] = true;

    const cache = &caches[index];
    cache.* = .{ .backing = dev };

    return .{
        .name = dev.name,
        .ctx = cache,
        .ops = &ops,
        .sectors = dev.sectors,
        .offset = dev.offset,
        .read_only = dev.read_only,
    };
}

/// Give a cache back, once its device has retired. A context that is not a
/// cache's, a device that was never wrapped, is nothing to give back.
pub fn release(ctx: *anyopaque) void {
    for (&caches, &taken) |*cache, *held| {
        if (@as(*anyopaque, @ptrCast(cache)) != ctx) continue;
        held.* = false;
        return;
    }
}

pub fn totalStats() Stats {
    var total = Stats{};
    for (&caches, taken) |*c, held| {
        if (!held) continue;
        total.add(c.table.stats);
    }
    return total;
}

pub fn report() void {
    const s = totalStats();
    if (s.hits + s.misses == 0) return;
    console.debug("cache", "{d}% hit ({d} hit, {d} miss, {d} bypassed), {d} KiB", .{
        s.hitRate(),
        s.hits,
        s.misses,
        s.bypassed,
        CAPACITY_SECTORS * block.SECTOR_SIZE / 1024,
    });
}
