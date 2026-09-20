//! The block cache's lines: what is held, how a run is served from them and
//! from the backing, and when a run leaves them alone.
//!
//! Pure, and tested on the host against a medium of a few sectors. The lock
//! and the device the cache presents are `bcache.zig`'s.
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
const block = @import("../block.zig");

/// 64 sets × 4 ways × 512 B = 128 KiB. Small against the 48 MiB idle-RAM
/// budget, and comfortably larger than the working set of a FAT lookup.
const SETS = 64;
const WAYS = 4;
pub const CAPACITY_SECTORS = SETS * WAYS;

/// A run longer than this goes straight between the caller and the backing
/// and leaves the lines to the table, the directories and the small files.
/// Filled from a copy, the lines held data nobody reads twice and lost the
/// table's sectors, which every write call then read from the medium again.
/// Write-through keeps every line what the medium holds, so a read served
/// from the medium is never behind a line.
pub const BYPASS_SECTORS = 16;

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
    /// Sectors moved straight between the caller and the backing, leaving
    /// the lines as they were.
    bypassed: u64 = 0,

    pub fn hitRate(self: Stats) u64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return self.hits * 100 / total;
    }

    pub fn add(self: *Stats, other: Stats) void {
        self.hits += other.hits;
        self.misses += other.misses;
        self.writes += other.writes;
        self.invalidations += other.invalidations;
        self.bypassed += other.bypassed;
    }
};

pub const Lines = struct {
    lines: [SETS][WAYS]Line = @splat(@splat(.{})),
    clock: u64 = 0,
    stats: Stats = .{},

    fn setOf(lba: u64) usize {
        return @intCast(lba % SETS);
    }

    fn find(self: *Lines, lba: u64) ?*Line {
        for (&self.lines[setOf(lba)]) |*line| {
            if (line.valid and line.lba == lba) return line;
        }
        return null;
    }

    fn victim(self: *Lines, lba: u64) *Line {
        const set = &self.lines[setOf(lba)];
        var oldest: *Line = &set[0];
        for (set) |*line| {
            if (!line.valid) return line;
            if (line.used_at < oldest.used_at) oldest = line;
        }
        return oldest;
    }

    fn touch(self: *Lines, line: *Line) void {
        self.clock += 1;
        line.used_at = self.clock;
    }

    /// Read `count` sectors from `lba`, a run at a time. What the lines
    /// hold is copied out; the sectors between hits are read from the
    /// backing in one call per run rather than one per sector, which on a
    /// card behind a USB reader is one round trip instead of many. A run
    /// longer than `BYPASS_SECTORS` is read from the backing whole and
    /// leaves the lines as they were.
    pub fn readRun(self: *Lines, backing: block.Device, lba: u64, out: []u8) block.Error!void {
        const count = out.len / block.SECTOR_SIZE;
        if (count > BYPASS_SECTORS) {
            self.stats.bypassed += count;
            return backing.ops.read(backing.ctx, lba, out);
        }

        var i: usize = 0;
        while (i < count) {
            if (self.find(lba + i)) |line| {
                self.stats.hits += 1;
                self.touch(line);
                @memcpy(out[i * block.SECTOR_SIZE ..][0..block.SECTOR_SIZE], &line.data);
                i += 1;
                continue;
            }

            // The misses from here to the next sector the lines hold.
            var run: usize = 1;
            while (i + run < count and self.find(lba + i + run) == null) : (run += 1) {}
            self.stats.misses += run;

            // The caller's buffer is filled first, then the lines from it:
            // a read that fails leaves the lines as they were rather than
            // holding stale data under new numbers.
            const bytes = out[i * block.SECTOR_SIZE ..][0 .. run * block.SECTOR_SIZE];
            try backing.ops.read(backing.ctx, lba + i, bytes);
            for (0..run) |k| {
                self.fill(lba + i + k, bytes[k * block.SECTOR_SIZE ..][0..block.SECTOR_SIZE]);
            }
            i += run;
        }
    }

    /// Write `count` sectors from `lba` through to the backing in one call,
    /// and keep the lines coherent with what was written, so a read-back
    /// sees the new contents: a short run goes into its lines, a long one
    /// leaves no line behind it.
    pub fn writeRun(self: *Lines, backing: block.Device, lba: u64, in: []const u8) block.Error!void {
        const w = backing.ops.write orelse return error.NotSupported;
        try w(backing.ctx, lba, in);

        const count = in.len / block.SECTOR_SIZE;
        self.stats.writes += count;
        if (count > BYPASS_SECTORS) {
            // No line for what was written, and none left behind saying
            // what the sectors held before.
            for (0..count) |k| {
                if (self.find(lba + k)) |line| line.valid = false;
            }
            self.stats.bypassed += count;
            return;
        }
        for (0..count) |k| {
            self.fill(lba + k, in[k * block.SECTOR_SIZE ..][0..block.SECTOR_SIZE]);
        }
    }

    /// Put a sector's contents in a line: its own if it has one, otherwise
    /// the line its set can best spare.
    fn fill(self: *Lines, lba: u64, data: *const [block.SECTOR_SIZE]u8) void {
        const line = self.find(lba) orelse self.victim(lba);
        @memcpy(&line.data, data);
        line.lba = lba;
        line.valid = true;
        self.touch(line);
    }

    /// Drop everything. For removable media that has gone: the sectors
    /// held from the old medium describe nothing that is still there.
    pub fn invalidate(self: *Lines) void {
        for (&self.lines) |*set| {
            for (set) |*line| line.valid = false;
        }
        self.stats.invalidations += 1;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A medium of a few sectors, each holding its own number.
const Memory = struct {
    sectors: [128][block.SECTOR_SIZE]u8 = @splat(@splat(0)),
    reads: usize = 0,
    writes: usize = 0,

    fn numbered() Memory {
        var m = Memory{};
        for (&m.sectors, 0..) |*sector, i| @memset(sector, @intCast(i));
        return m;
    }

    fn read(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        for (0..buf.len / block.SECTOR_SIZE) |i| {
            @memcpy(buf[i * block.SECTOR_SIZE ..][0..block.SECTOR_SIZE], &self.sectors[@intCast(lba + i)]);
        }
    }

    fn write(ctx: *anyopaque, lba: u64, buf: []const u8) block.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        for (0..buf.len / block.SECTOR_SIZE) |i| {
            @memcpy(&self.sectors[@intCast(lba + i)], buf[i * block.SECTOR_SIZE ..][0..block.SECTOR_SIZE]);
        }
    }

    const ops = block.Ops{ .read = Memory.read, .write = Memory.write };

    fn device(self: *Memory) block.Device {
        return .{ .name = "memory", .ctx = self, .ops = &Memory.ops, .sectors = self.sectors.len };
    }
};

test "a short read fills lines and a long one leaves them alone" {
    var memory = Memory.numbered();
    const dev = memory.device();
    var table = Lines{};

    var few: [4 * block.SECTOR_SIZE]u8 = undefined;
    try table.readRun(dev, 0, &few);
    try testing.expectEqual(@as(u8, 3), few[3 * block.SECTOR_SIZE]);
    for (0..4) |i| try testing.expect(table.find(i) != null);

    var many: [32 * block.SECTOR_SIZE]u8 = undefined;
    try table.readRun(dev, 40, &many);
    try testing.expectEqual(@as(u8, 71), many[31 * block.SECTOR_SIZE]);
    for (40..72) |i| try testing.expect(table.find(i) == null);
    try testing.expectEqual(@as(usize, 2), memory.reads);
    try testing.expectEqual(@as(u64, 32), table.stats.bypassed);

    // Read again, the short run comes from the lines.
    try table.readRun(dev, 0, &few);
    try testing.expectEqual(@as(usize, 2), memory.reads);
    try testing.expectEqual(@as(u64, 4), table.stats.hits);
}

test "a long write leaves no line behind it, and a short one keeps its line current" {
    var memory = Memory.numbered();
    const dev = memory.device();
    var table = Lines{};

    var one: [block.SECTOR_SIZE]u8 = undefined;
    try table.readRun(dev, 50, &one);
    try testing.expect(table.find(50) != null);

    // Sectors 40 to 71 rewritten in one run: a line for 50 would say 50
    // where the medium now says 200.
    var many: [32 * block.SECTOR_SIZE]u8 = undefined;
    @memset(&many, 200);
    try table.writeRun(dev, 40, &many);
    try testing.expect(table.find(50) == null);
    try table.readRun(dev, 50, &one);
    try testing.expectEqual(@as(u8, 200), one[0]);

    // A short write goes into its line as well as to the medium.
    var two: [2 * block.SECTOR_SIZE]u8 = undefined;
    @memset(&two, 7);
    try table.writeRun(dev, 10, &two);
    try testing.expectEqual(@as(u8, 7), table.find(10).?.data[0]);
    try testing.expectEqual(@as(u8, 7), memory.sectors[11][0]);
}

test "a read that fails leaves the lines as they were" {
    var memory = Memory.numbered();
    var dev = memory.device();
    var table = Lines{};

    var one: [block.SECTOR_SIZE]u8 = undefined;
    try table.readRun(dev, 5, &one);

    const Failing = struct {
        fn read(_: *anyopaque, _: u64, _: []u8) block.Error!void {
            return block.Error.IoError;
        }
        const ops = block.Ops{ .read = read };
    };
    dev.ops = &Failing.ops;
    var few: [4 * block.SECTOR_SIZE]u8 = undefined;
    try testing.expectError(block.Error.IoError, table.readRun(dev, 20, &few));
    try testing.expect(table.find(20) == null);
    try testing.expect(table.find(5) != null);
}
