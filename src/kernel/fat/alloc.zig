//! The FAT table itself: reading entries, writing them, and allocating
//! clusters.
//!
//! Separate from the directory and file logic above it because it is the one
//! part that knows how the three widths differ. FAT12, FAT16 and FAT32 have
//! identical directories and identical chain semantics; all that changes is
//! how an entry is fetched and stored, and confining that here is what lets
//! FAT12 cost a branch rather than a second driver.
//!
//! **Every copy is written.** A volume normally carries two FATs, and other
//! systems are entitled to read either. Updating one and not the other
//! produces a filesystem that looks fine until something reads the copy we did
//! not maintain, which is the worst kind of corruption: silent, and only
//! visible on another machine.

const std = @import("std");
const block = @import("../block.zig");

/// Anything the FAT table needs to know about the volume it belongs to.
///
/// A view rather than a back-pointer to `Volume`: this module is a level below
/// files and directories and has no business reaching up into them.
pub const Table = struct {
    dev: *const block.Device,
    kind: Kind,
    bytes_per_sector: u32,
    first_fat_sector: u32,
    sectors_per_fat: u32,
    fat_count: u32,
    cluster_count: u32,

    /// One sector of scratch. Static rather than heap: a filesystem that
    /// allocates on every lookup is one that fails in low memory, which is
    /// exactly when something needs reading.
    cache: [SECTOR]u8 = @splat(0),
    cache_sector: u32 = INVALID_SECTOR,
    /// Where the search for a free cluster starts. Carried between calls so
    /// filling a volume stays roughly linear instead of rescanning from the
    /// beginning for every cluster.
    next_free_hint: u32 = 2,
    /// How many clusters are free, once the table has been walked. Every
    /// store keeps it current, so the question a shell and a file manager
    /// keep asking is answered from here rather than by walking the table
    /// again: on a card behind a USB reader that walk is seconds, and it was
    /// being taken every two.
    free_known: ?u32 = null,
    /// A run of sectors for the one walk, so the table is read in pieces
    /// rather than a sector at a time. Each read of a card is a round trip,
    /// and the difference on a table of hundreds of sectors is most of the
    /// wait.
    walk: [WALK_SECTORS * SECTOR]u8 = undefined,
};

pub const Kind = enum { fat12, fat16, fat32 };

pub const Error = error{ Io, CorruptChain, NoSpace, ReadOnly };

const SECTOR = block.SECTOR_SIZE;
const INVALID_SECTOR: u32 = 0xFFFF_FFFF;
/// How many sectors one read of the walk asks for.
const WALK_SECTORS = 8;

/// The first value that means "no more clusters", per width.
pub fn endOfChain(kind: Kind) u32 {
    return switch (kind) {
        .fat12 => 0x0FF8,
        .fat16 => 0xFFF8,
        .fat32 => 0x0FFF_FFF8,
    };
}

/// The value written to mark the last cluster of a chain.
fn terminator(kind: Kind) u32 {
    return switch (kind) {
        .fat12 => 0x0FFF,
        .fat16 => 0xFFFF,
        .fat32 => 0x0FFF_FFFF,
    };
}

fn byteOffset(kind: Kind, cluster: u32) u32 {
    return switch (kind) {
        .fat12 => cluster + (cluster / 2),
        .fat16 => cluster * 2,
        .fat32 => cluster * 4,
    };
}

fn loadSector(t: *Table, sector: u32) Error!void {
    if (t.cache_sector == sector) return;
    t.dev.read(sector, &t.cache) catch return error.Io;
    t.cache_sector = sector;
}

/// Write the cached sector back to every FAT copy.
fn storeSector(t: *Table, sector: u32) Error!void {
    const within_fat = sector - t.first_fat_sector;

    var copy: u32 = 0;
    while (copy < t.fat_count) : (copy += 1) {
        const target = t.first_fat_sector + copy * t.sectors_per_fat + within_fat;
        t.dev.write(target, &t.cache) catch return error.Io;
    }
}

/// Raw entry value for `cluster`, with no interpretation.
pub fn get(t: *Table, cluster: u32) Error!u32 {
    const offset = byteOffset(t.kind, cluster);
    const sector = t.first_fat_sector + offset / t.bytes_per_sector;
    const within = offset % t.bytes_per_sector;

    try loadSector(t, sector);

    return switch (t.kind) {
        .fat16 => std.mem.readInt(u16, t.cache[within..][0..2], .little),
        .fat32 => std.mem.readInt(u32, t.cache[within..][0..4], .little) & 0x0FFF_FFFF,
        .fat12 => blk: {
            // A FAT12 entry is 12 bits and can straddle a sector boundary, so
            // the two bytes are fetched separately rather than as a u16.
            const lo = t.cache[within];
            try loadSector(t, t.first_fat_sector + (offset + 1) / t.bytes_per_sector);
            const hi = t.cache[(offset + 1) % t.bytes_per_sector];
            const raw = @as(u16, lo) | (@as(u16, hi) << 8);
            break :blk if (cluster & 1 != 0) raw >> 4 else raw & 0x0FFF;
        },
    };
}

/// Store `value` in `cluster`'s entry, in every FAT copy, and keep the free
/// count in step: a cluster claimed is one fewer, one released is one more.
pub fn set(t: *Table, cluster: u32, value: u32) Error!void {
    const before = try get(t, cluster);
    try store(t, cluster, value);
    if (t.free_known) |*known| {
        if (before == 0 and value != 0) {
            known.* -|= 1;
        } else if (before != 0 and value == 0) {
            known.* +|= 1;
        }
    }
}

fn store(t: *Table, cluster: u32, value: u32) Error!void {
    const offset = byteOffset(t.kind, cluster);
    const sector = t.first_fat_sector + offset / t.bytes_per_sector;
    const within = offset % t.bytes_per_sector;

    try loadSector(t, sector);

    switch (t.kind) {
        .fat16 => {
            std.mem.writeInt(u16, t.cache[within..][0..2], @truncate(value), .little);
            try storeSector(t, sector);
        },
        .fat32 => {
            // The top four bits are reserved and must be preserved, not zeroed:
            // they are not ours, and other implementations do look at them.
            const existing = std.mem.readInt(u32, t.cache[within..][0..4], .little);
            const merged = (existing & 0xF000_0000) | (value & 0x0FFF_FFFF);
            std.mem.writeInt(u32, t.cache[within..][0..4], merged, .little);
            try storeSector(t, sector);
        },
        .fat12 => {
            // Twelve bits spanning two bytes that may be in different sectors,
            // so each byte is read, modified and written on its own.
            const second_sector = t.first_fat_sector + (offset + 1) / t.bytes_per_sector;
            const second_within = (offset + 1) % t.bytes_per_sector;

            const lo_byte = t.cache[within];
            try loadSector(t, second_sector);
            const hi_byte = t.cache[second_within];

            var raw = @as(u16, lo_byte) | (@as(u16, hi_byte) << 8);
            if (cluster & 1 != 0) {
                raw = (raw & 0x000F) | @as(u16, @truncate(value << 4));
            } else {
                raw = (raw & 0xF000) | @as(u16, @truncate(value & 0x0FFF));
            }

            try loadSector(t, sector);
            t.cache[within] = @truncate(raw);
            try storeSector(t, sector);

            try loadSector(t, second_sector);
            t.cache[second_within] = @truncate(raw >> 8);
            try storeSector(t, second_sector);
        },
    }
}

/// The next cluster in a chain, or null at the end.
pub fn next(t: *Table, cluster: u32) Error!?u32 {
    const value = try get(t, cluster);
    if (value >= endOfChain(t.kind)) return null;

    // A chain pointing outside the volume is corruption; following it would
    // read arbitrary sectors and loop forever.
    if (value < 2 or value >= t.cluster_count + 2) return error.CorruptChain;
    return value;
}

/// Claim a free cluster and mark it as the end of a chain.
///
/// The search resumes from where the last one stopped and wraps once, so a
/// volume fills roughly in order and a full one is detected in a single sweep
/// rather than by scanning from cluster 2 every time.
pub fn alloc(t: *Table) Error!u32 {
    const total = t.cluster_count + 2;
    var scanned: u32 = 0;
    var candidate = @max(t.next_free_hint, 2);

    while (scanned < t.cluster_count) : (scanned += 1) {
        if (candidate >= total) candidate = 2;

        if (try get(t, candidate) == 0) {
            try set(t, candidate, terminator(t.kind));
            t.next_free_hint = candidate + 1;
            return candidate;
        }
        candidate += 1;
    }
    return error.NoSpace;
}

/// Append a fresh cluster to the chain ending at `last`.
pub fn append(t: *Table, last: u32) Error!u32 {
    const fresh = try alloc(t);
    try set(t, last, fresh);
    return fresh;
}

/// Release a whole chain starting at `first`.
///
/// Walks before freeing each link, because zeroing an entry destroys the
/// pointer to the rest of the chain.
pub fn freeChain(t: *Table, first: u32) Error!void {
    var cluster = first;
    var guard: u32 = 0;

    while (cluster >= 2 and cluster < t.cluster_count + 2) {
        // A corrupt filesystem can contain a loop. Bounding the walk by the
        // cluster count means a bad chain costs one sweep rather than hanging
        // the machine.
        guard += 1;
        if (guard > t.cluster_count) return error.CorruptChain;

        const following = get(t, cluster) catch break;
        try set(t, cluster, 0);
        if (following >= endOfChain(t.kind) or following < 2) break;
        cluster = following;
    }
}

/// How many clusters are unused: what the walk found, kept current since.
pub fn freeCount(t: *Table) Error!u32 {
    if (t.free_known) |known| return known;
    const counted = try countFree(t);
    t.free_known = counted;
    return counted;
}

/// Walk the whole table once. Sixteen and thirty-two bit entries are read
/// in runs of sectors and counted in place; twelve-bit ones straddle sectors
/// and belong to volumes so small that one entry at a time is fine.
fn countFree(t: *Table) Error!u32 {
    var free: u32 = 0;
    const past_last = t.cluster_count + 2;

    if (t.kind == .fat12) {
        var cluster: u32 = 2;
        while (cluster < past_last) : (cluster += 1) {
            if (try get(t, cluster) == 0) free += 1;
        }
        return free;
    }

    const width: u32 = if (t.kind == .fat16) 2 else 4;
    const per_sector = SECTOR / width;
    var sector: u32 = 0;
    while (sector < t.sectors_per_fat) {
        const run: u32 = @min(WALK_SECTORS, t.sectors_per_fat - sector);
        const bytes = t.walk[0 .. run * SECTOR];
        t.dev.read(t.first_fat_sector + sector, bytes) catch return error.Io;

        var i: u32 = 0;
        while (i < run * per_sector) : (i += 1) {
            const cluster = sector * per_sector + i;
            if (cluster >= past_last) return free;
            if (cluster < 2) continue;
            const at = i * width;
            const value: u32 = if (width == 2)
                std.mem.readInt(u16, bytes[at..][0..2], .little)
            else
                std.mem.readInt(u32, bytes[at..][0..4], .little) & 0x0FFF_FFFF;
            if (value == 0) free += 1;
        }
        sector += run;
    }
    return free;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A volume in memory, for proving the table without a medium.
const Memory = struct {
    sectors: [64][SECTOR]u8 = @splat(@splat(0)),

    fn read(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        for (0..buf.len / SECTOR) |i| @memcpy(buf[i * SECTOR ..][0..SECTOR], &self.sectors[@intCast(lba + i)]);
    }

    fn write(ctx: *anyopaque, lba: u64, buf: []const u8) block.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        for (0..buf.len / SECTOR) |i| @memcpy(&self.sectors[@intCast(lba + i)], buf[i * SECTOR ..][0..SECTOR]);
    }

    const ops = block.Ops{ .read = read, .write = write };
};

fn tableOver(memory: *Memory, dev: *const block.Device, kind: Kind, sectors_per_fat: u32, cluster_count: u32) Table {
    _ = memory;
    return .{
        .dev = dev,
        .kind = kind,
        .bytes_per_sector = SECTOR,
        .first_fat_sector = 1,
        .sectors_per_fat = sectors_per_fat,
        .fat_count = 1,
        .cluster_count = cluster_count,
    };
}

test "the free count is walked once and follows every store" {
    var memory = Memory{};
    const dev = block.Device{ .name = "memory", .ctx = &memory, .ops = &Memory.ops, .sectors = 64 };
    // FAT16, one sector of table: clusters 2 to 99, the first ten claimed
    // before anything has counted.
    var t = tableOver(&memory, &dev, .fat16, 1, 98);
    for (2..12) |c| try set(&t, @intCast(c), 0xFFFF);

    try testing.expectEqual(@as(u32, 88), try freeCount(&t));
    // Claimed and released, the count moves without a second walk.
    try testing.expectEqual(@as(u32, 12), try alloc(&t));
    try testing.expectEqual(@as(u32, 87), try freeCount(&t));
    try freeChain(&t, 12);
    try testing.expectEqual(@as(u32, 88), try freeCount(&t));
    // Storing what is already there moves nothing.
    try set(&t, 2, 0xFFFF);
    try testing.expectEqual(@as(u32, 88), try freeCount(&t));
    // The walk agrees with the count it was keeping.
    t.free_known = null;
    try testing.expectEqual(@as(u32, 88), try freeCount(&t));
}

test "a thirty-two bit table is counted in runs and past its last cluster nothing counts" {
    var memory = Memory{};
    const dev = block.Device{ .name = "memory", .ctx = &memory, .ops = &Memory.ops, .sectors = 64 };
    // Twelve sectors of table, more than one run, over two thousand
    // clusters; the entries past the last cluster are left as the format
    // leaves them, which is zero, and must not be counted as free.
    var t = tableOver(&memory, &dev, .fat32, 12, 1000);
    try set(&t, 2, 0x0FFF_FFFF);
    try set(&t, 500, 0x0FFF_FFFF);
    try set(&t, 1001, 0x0FFF_FFFF);
    try testing.expectEqual(@as(u32, 997), try freeCount(&t));
    try freeChain(&t, 500);
    try testing.expectEqual(@as(u32, 998), try freeCount(&t));
    t.free_known = null;
    try testing.expectEqual(@as(u32, 998), try freeCount(&t));
}
