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
    /// The cached sector holds entries the medium does not have yet. Stored
    /// when another sector takes its place, and by `flush`, which every call
    /// that changes the table ends with.
    dirty: bool = false,
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
/// A thirty-two bit entry. Only the low twenty-eight are the entry; the top
/// four are reserved and are preserved as found whenever one is written.
pub const Wide = packed struct(u32) {
    value: u28,
    reserved: u4,
};

/// The meaningful width of an entry, as a type.
///
/// FAT32 is named for its entry size rather than its values: every value the
/// format defines for it is twenty-eight bits wide.
fn Entry(comptime kind: Kind) type {
    return switch (kind) {
        .fat12 => u12,
        .fat16 => u16,
        .fat32 => u28,
    };
}

/// The three values an entry can hold that are not a cluster number.
pub const Sentinels = struct {
    /// This or above means the chain has ended.
    end_from: u32,
    /// What is written to end one.
    terminator: u32,
    /// A cluster the medium cannot hold data in. The one value that is
    /// neither free nor part of a chain, and the one a check must not
    /// reclaim.
    bad: u32,
};

/// All three sit at the top of the entry's range, in the same pattern at
/// every width: every bit set terminates a chain, that value less eight
/// marks a bad cluster, and that value less seven and above reads as an end.
/// Derived from the width rather than written out nine times, and pinned
/// below against the values the specification gives.
pub fn sentinels(width: Kind) Sentinels {
    return switch (width) {
        inline else => |kind| blk: {
            const top = std.math.maxInt(Entry(kind));
            break :blk .{ .terminator = top, .bad = top - 8, .end_from = top - 7 };
        },
    };
}

/// A sixteen or thirty-two bit entry at `at` in `bytes`. Twelve-bit ones
/// straddle bytes and sectors and are read where they are stored.
fn wideEntry(kind: Kind, bytes: []const u8, at: usize) u32 {
    return switch (kind) {
        .fat16 => std.mem.readInt(u16, bytes[at..][0..2], .little),
        .fat32 => @as(Wide, @bitCast(std.mem.readInt(u32, bytes[at..][0..4], .little))).value,
        .fat12 => unreachable,
    };
}

/// Where an entry for `cluster` starts, in bytes from the front of a table.
///
/// Also how much of a table `cluster` entries occupy, which is what sizing a
/// table needs: the two are the same number and are written down once.
pub fn byteOffset(kind: Kind, cluster: u32) u32 {
    return switch (kind) {
        .fat12 => cluster + (cluster / 2),
        .fat16 => cluster * 2,
        .fat32 => cluster * 4,
    };
}

fn loadSector(t: *Table, sector: u32) Error!void {
    if (t.cache_sector == sector) return;
    try flush(t);
    // The cache names no sector while a read is in flight: a read that fails
    // part way leaves the bytes of neither sector, and a cache still naming
    // the old one would hand those bytes out as its entries and write them
    // back to every copy on the next store.
    t.cache_sector = INVALID_SECTOR;
    t.dev.read(sector, &t.cache) catch return error.Io;
    t.cache_sector = sector;
}

/// Drop the cached sector, for a table whose sectors have moved on the
/// medium under it. Anything it held that the medium did not is lost, so
/// it is flushed first by whoever moves them.
pub fn forget(t: *Table) void {
    t.cache_sector = INVALID_SECTOR;
    t.dirty = false;
}

/// Write the cached sector to every copy of the table, when it holds
/// anything the medium does not.
pub fn flush(t: *Table) Error!void {
    if (!t.dirty) return;
    if (t.cache_sector == INVALID_SECTOR) {
        t.dirty = false;
        return;
    }
    try storeSector(t, t.cache_sector);
    t.dirty = false;
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
        .fat16, .fat32 => wideEntry(t.kind, &t.cache, within),
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
            t.dirty = true;
        },
        .fat32 => {
            // The reserved bits are read back and written out again
            // rather than zeroed. Other implementations read them.
            var entry: Wide = @bitCast(std.mem.readInt(u32, t.cache[within..][0..4], .little));
            entry.value = @truncate(value);
            std.mem.writeInt(u32, t.cache[within..][0..4], @bitCast(entry), .little);
            t.dirty = true;
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
            t.dirty = true;

            try loadSector(t, second_sector);
            t.cache[second_within] = @truncate(raw >> 8);
            t.dirty = true;
        },
    }
}

/// The two entries at the front of the table that are not clusters.
///
/// Named rather than numbered so that `setReserved` cannot be used for
/// anything else: the reason it is a separate call is that these writes are
/// not allocations.
pub const Reserved = enum(u32) {
    /// Holds the media descriptor, which nothing here reads.
    media = 0,
    /// The volume's clean and hard-error flags. See `fat/clean.zig`.
    flags = 1,
};

/// Read one of the reserved entries.
pub fn reserved(t: *Table, which: Reserved) Error!u32 {
    return get(t, @intFromEnum(which));
}

/// Write one of the reserved entries, leaving the free count alone.
///
/// `set` would treat a write of one of these as a cluster being claimed or
/// released, moving the free count by one on every mark. That count is what
/// tells a caller the volume is full.
pub fn setReserved(t: *Table, which: Reserved, value: u32) Error!void {
    try store(t, @intFromEnum(which), value);
    // A reserved entry is the volume's own state, the clean flag above all,
    // and is wanted on the medium the moment it is set.
    try flush(t);
}

/// The next cluster in a chain, or null at the end.
pub fn next(t: *Table, cluster: u32) Error!?u32 {
    const value = try get(t, cluster);
    if (value >= sentinels(t.kind).end_from) return null;

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
    // The count the table keeps is the answer to whether a search can
    // succeed. A full volume is told so from here rather than by walking the
    // whole table to find out, which on a card behind a reader is seconds
    // spent on every write that was going to fail.
    if (t.free_known) |known| {
        if (known == 0) return error.NoSpace;
    }

    const total = t.cluster_count + 2;
    var scanned: u32 = 0;
    var candidate = @max(t.next_free_hint, 2);

    while (scanned < t.cluster_count) : (scanned += 1) {
        if (candidate >= total) candidate = 2;

        if (try get(t, candidate) == 0) {
            try set(t, candidate, sentinels(t.kind).terminator);
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

        // A link that cannot be read ends the walk with the error, not with
        // success: the rest of the chain is still allocated, and a caller
        // told otherwise would forget it.
        const following = try get(t, cluster);
        try set(t, cluster, 0);
        if (following >= sentinels(t.kind).end_from or following < 2) break;
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
    // The walk reads the medium, so what the cache holds goes there first.
    try flush(t);
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
            if (wideEntry(t.kind, bytes, i * width) == 0) free += 1;
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
    writes: usize = 0,

    fn read(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        for (0..buf.len / SECTOR) |i| @memcpy(buf[i * SECTOR ..][0..SECTOR], &self.sectors[@intCast(lba + i)]);
    }

    fn write(ctx: *anyopaque, lba: u64, buf: []const u8) block.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.writes += 1;
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

test "a read that fails leaves the cache naming no sector" {
    var memory = Memory{};
    const dev = block.Device{ .name = "memory", .ctx = &memory, .ops = &Memory.ops, .sectors = 64 };
    var t = tableOver(&memory, &dev, .fat16, 2, 300);
    // Sector 1 of the table holds clusters up to 255; sector 2 the rest.
    try set(&t, 2, 0xFFFF);
    try testing.expectEqual(@as(u32, t.first_fat_sector), t.cache_sector);

    // A device that answers nothing for the second sector.
    const Failing = struct {
        fn read(_: *anyopaque, _: u64, _: []u8) block.Error!void {
            return error.IoError;
        }
    };
    const broken_ops = block.Ops{ .read = Failing.read, .write = Memory.write };
    const broken = block.Device{ .name = "broken", .ctx = &memory, .ops = &broken_ops, .sectors = 64 };
    t.dev = &broken;
    try testing.expectError(error.Io, get(&t, 280));
    try testing.expectEqual(INVALID_SECTOR, t.cache_sector);

    // Back on a working device, the first sector is read again rather than
    // taken from a cache that might hold anything.
    t.dev = &dev;
    try testing.expectEqual(@as(u32, 0xFFFF), try get(&t, 2));
}

test "a full volume refuses a cluster without walking the table again" {
    var memory = Memory{};
    const dev = block.Device{ .name = "memory", .ctx = &memory, .ops = &Memory.ops, .sectors = 64 };
    var t = tableOver(&memory, &dev, .fat16, 1, 4);
    for (2..6) |c| try set(&t, @intCast(c), 0xFFFF);
    try testing.expectEqual(@as(u32, 0), try freeCount(&t));

    // Nothing is read: the count answers.
    const Counting = struct {
        var reads: u32 = 0;
        fn read(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
            reads += 1;
            return Memory.read(ctx, lba, buf);
        }
    };
    const counting_ops = block.Ops{ .read = Counting.read, .write = Memory.write };
    const counted = block.Device{ .name = "counted", .ctx = &memory, .ops = &counting_ops, .sectors = 64 };
    t.dev = &counted;
    try testing.expectError(error.NoSpace, alloc(&t));
    try testing.expectEqual(@as(u32, 0), Counting.reads);
}

test "a chain that cannot be read is reported rather than half freed and called done" {
    var memory = Memory{};
    const dev = block.Device{ .name = "memory", .ctx = &memory, .ops = &Memory.ops, .sectors = 64 };
    var t = tableOver(&memory, &dev, .fat16, 2, 300);
    try set(&t, 2, 280);
    try set(&t, 280, 0xFFFF);

    const Failing = struct {
        fn read(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
            // The second sector of the table cannot be read.
            if (lba == 2) return error.IoError;
            return Memory.read(ctx, lba, buf);
        }
    };
    const failing_ops = block.Ops{ .read = Failing.read, .write = Memory.write };
    const failing = block.Device{ .name = "failing", .ctx = &memory, .ops = &failing_ops, .sectors = 64 };
    t.dev = &failing;
    try testing.expectError(error.Io, freeChain(&t, 2));
}

test "the three reserved values are the ones the format prints" {
    // The values are derived from the entry width above rather than written
    // out, so this is what checks the derivation. The numbers are the
    // specification's.
    try testing.expectEqual(@as(u32, 0x0FF8), sentinels(.fat12).end_from);
    try testing.expectEqual(@as(u32, 0x0FFF), sentinels(.fat12).terminator);
    try testing.expectEqual(@as(u32, 0x0FF7), sentinels(.fat12).bad);

    try testing.expectEqual(@as(u32, 0xFFF8), sentinels(.fat16).end_from);
    try testing.expectEqual(@as(u32, 0xFFFF), sentinels(.fat16).terminator);
    try testing.expectEqual(@as(u32, 0xFFF7), sentinels(.fat16).bad);

    try testing.expectEqual(@as(u32, 0x0FFF_FFF8), sentinels(.fat32).end_from);
    try testing.expectEqual(@as(u32, 0x0FFF_FFFF), sentinels(.fat32).terminator);
    try testing.expectEqual(@as(u32, 0x0FFF_FFF7), sentinels(.fat32).bad);
}

test "a thirty-two bit entry leaves the four bits that are not its own" {
    // The bits above an entry belong to whatever wrote them. Zeroing them
    // would write a value the format reserves, on a volume another system
    // may read.
    const found: Wide = @bitCast(@as(u32, 0xA000_0005));
    try testing.expectEqual(@as(u28, 5), found.value);
    try testing.expectEqual(@as(u4, 0xA), found.reserved);

    var changed = found;
    changed.value = 9;
    try testing.expectEqual(@as(u32, 0xA000_0009), @as(u32, @bitCast(changed)));
}

test "a run of appends stores the table sector once, when the call is done" {
    var memory = Memory{};
    const dev = block.Device{ .name = "t", .ctx = &memory, .ops = &Memory.ops, .sectors = 64 };
    var t = tableOver(&memory, &dev, .fat32, 4, 200);

    var last = try alloc(&t);
    for (0..15) |_| last = try append(&t, last);
    try testing.expectEqual(@as(usize, 0), memory.writes);

    try flush(&t);
    try testing.expectEqual(@as(usize, 1), memory.writes);
    try flush(&t);
    try testing.expectEqual(@as(usize, 1), memory.writes);

    // What reached the medium is the chain, read by a table that never
    // saw it being made.
    var fresh = tableOver(&memory, &dev, .fat32, 4, 200);
    var cluster: u32 = 2;
    var length: usize = 1;
    while (try next(&fresh, cluster)) |following| : (length += 1) cluster = following;
    try testing.expectEqual(@as(usize, 16), length);
}

test "the cached sector is stored before another takes its place" {
    var memory = Memory{};
    const dev = block.Device{ .name = "t", .ctx = &memory, .ops = &Memory.ops, .sectors = 64 };
    var t = tableOver(&memory, &dev, .fat32, 4, 400);

    // Cluster 2 is in the table's first sector; cluster 300 in its third.
    try set(&t, 2, sentinels(.fat32).terminator);
    try testing.expectEqual(@as(usize, 0), memory.writes);
    _ = try get(&t, 300);
    try testing.expectEqual(@as(usize, 1), memory.writes);
    try testing.expectEqual(sentinels(.fat32).terminator, try get(&t, 2));
}
