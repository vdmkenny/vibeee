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
//! Four-way set associative. A fully associative cache would need a scan of
//! every entry per lookup, and a direct-mapped one thrashes badly when the FAT
//! and the data area happen to collide, which they will, since both are walked
//! in step. Four ways costs four comparisons and removes that failure mode.
//!
//! Write-through, deliberately. FAT has no journal, and the recovery strategy
//! (design/00-vibeee.md §7) is atomic double-buffered writes at the application
//! layer: write a copy, flush, flip a pointer. That only works if a completed
//! write has actually reached the medium. Write-back would open a window where
//! the application believes data landed and it has not, which is precisely the
//! failure the strategy exists to prevent.

const std = @import("std");
const block = @import("block.zig");
const console = @import("console.zig");

/// 64 sets × 4 ways × 512 B = 128 KiB. Small against the 48 MiB idle-RAM
/// budget, and comfortably larger than the working set of a FAT lookup.
const SETS = 64;
const WAYS = 4;
pub const CAPACITY_SECTORS = SETS * WAYS;

const Line = struct {
    lba: u64 = 0,
    valid: bool = false,
    /// Monotonic counter, for LRU within a set.
    used_at: u64 = 0,
    data: [block.SECTOR_SIZE]u8 = undefined,
};

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    writes: u64 = 0,
    invalidations: u64 = 0,

    pub fn hitRate(self: Stats) u64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return self.hits * 100 / total;
    }
};

pub const Cache = struct {
    backing: block.Device,
    lines: [SETS][WAYS]Line = @splat(@splat(.{})),
    clock: u64 = 0,
    stats: Stats = .{},

    fn setOf(lba: u64) usize {
        return @intCast(lba % SETS);
    }

    fn find(self: *Cache, lba: u64) ?*Line {
        for (&self.lines[setOf(lba)]) |*line| {
            if (line.valid and line.lba == lba) return line;
        }
        return null;
    }

    /// Pick a line to reuse: an invalid one if there is one, otherwise the
    /// least recently used in the set.
    fn victim(self: *Cache, lba: u64) *Line {
        const set = &self.lines[setOf(lba)];
        var oldest: *Line = &set[0];
        for (set) |*line| {
            if (!line.valid) return line;
            if (line.used_at < oldest.used_at) oldest = line;
        }
        return oldest;
    }

    fn touch(self: *Cache, line: *Line) void {
        self.clock += 1;
        line.used_at = self.clock;
    }

    fn readSector(self: *Cache, lba: u64, out: []u8) block.Error!void {
        if (self.find(lba)) |line| {
            self.stats.hits += 1;
            self.touch(line);
            @memcpy(out, &line.data);
            return;
        }

        self.stats.misses += 1;
        const line = self.victim(lba);

        // Fill the caller's buffer first, then the cache line from it: if the
        // read fails the line is left invalid rather than holding stale data
        // under a new LBA.
        try self.backing.ops.read(self.backing.ctx, lba, out);

        @memcpy(&line.data, out);
        line.lba = lba;
        line.valid = true;
        self.touch(line);
    }

    fn writeSector(self: *Cache, lba: u64, in: []const u8) block.Error!void {
        const w = self.backing.ops.write orelse return error.NotSupported;
        try w(self.backing.ctx, lba, in);
        self.stats.writes += 1;

        // Keep the cache coherent with what was just written, so a read-back
        // sees the new contents.
        const line = self.find(lba) orelse self.victim(lba);
        @memcpy(&line.data, in);
        line.lba = lba;
        line.valid = true;
        self.touch(line);
    }

    /// Drop everything. Called when removable media goes away: the sectors
    /// cached from the old medium describe nothing that is still there.
    pub fn invalidate(self: *Cache) void {
        for (&self.lines) |*set| {
            for (set) |*line| line.valid = false;
        }
        self.stats.invalidations += 1;
    }
};

// ---------------------------------------------------------------------------
// block.Device plumbing
// ---------------------------------------------------------------------------

fn read(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
    const self: *Cache = @ptrCast(@alignCast(ctx));
    var offset: usize = 0;
    var current = lba;
    while (offset < buf.len) : (offset += block.SECTOR_SIZE) {
        try self.readSector(current, buf[offset..][0..block.SECTOR_SIZE]);
        current += 1;
    }
}

fn write(ctx: *anyopaque, lba: u64, buf: []const u8) block.Error!void {
    const self: *Cache = @ptrCast(@alignCast(ctx));
    var offset: usize = 0;
    var current = lba;
    while (offset < buf.len) : (offset += block.SECTOR_SIZE) {
        try self.writeSector(current, buf[offset..][0..block.SECTOR_SIZE]);
        current += 1;
    }
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
var caches: [4]Cache = undefined;
var cache_count: usize = 0;

/// Wrap `dev` in a cache and return a device that reads through it.
pub fn wrap(dev: block.Device) ?block.Device {
    if (cache_count >= caches.len) return null;

    const cache = &caches[cache_count];
    cache_count += 1;
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

pub fn totalStats() Stats {
    var total = Stats{};
    for (caches[0..cache_count]) |*c| {
        total.hits += c.stats.hits;
        total.misses += c.stats.misses;
        total.writes += c.stats.writes;
        total.invalidations += c.stats.invalidations;
    }
    return total;
}

pub fn report() void {
    const s = totalStats();
    if (s.hits + s.misses == 0) return;
    console.debug("cache", "{d}% hit ({d} hit, {d} miss), {d} KiB", .{
        s.hitRate(),
        s.hits,
        s.misses,
        CAPACITY_SECTORS * block.SECTOR_SIZE / 1024,
    });
}
