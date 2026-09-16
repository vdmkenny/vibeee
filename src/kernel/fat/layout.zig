//! A volume's geometry: where its tables, root and data area sit.
//!
//! `read` parses a boot sector (mount), `toBpb` writes one (format), `plan`
//! chooses a geometry for a size, `grown` for the same filesystem on a larger
//! volume. One definition, so format and mount agree.
//!
//! Arithmetic is done in 64 bits and narrowed after checking: fields come from
//! the medium, and their products overflow 32 bits.

const std = @import("std");
const block = @import("../block.zig");
const table = @import("alloc.zig");

/// Sector size as `u32`.
pub const SECTOR: u32 = block.SECTOR_SIZE;

pub const Kind = table.Kind;

pub const Error = error{
    /// Not a FAT volume, or one whose fields contradict each other.
    NotFat,
    /// A FAT volume this driver does not handle.
    Unsupported,
    /// Too small to hold a filesystem of the kind asked for.
    TooSmall,
};

/// The BIOS parameter block, as it sits in the boot sector.
pub const Bpb = extern struct {
    jump: [3]u8,
    oem: [8]u8,
    bytes_per_sector: u16 align(1),
    sectors_per_cluster: u8,
    reserved_sectors: u16 align(1),
    fat_count: u8,
    root_entries: u16 align(1),
    total_sectors_16: u16 align(1),
    media: u8,
    sectors_per_fat_16: u16 align(1),
    sectors_per_track: u16 align(1),
    heads: u16 align(1),
    hidden_sectors: u32 align(1),
    total_sectors_32: u32 align(1),
    // FAT32 extension; meaningless on FAT12/16.
    sectors_per_fat_32: u32 align(1),
    ext_flags: u16 align(1),
    version: u16 align(1),
    root_cluster: u32 align(1),
    fs_info: u16 align(1),
    backup_boot: u16 align(1),
};

/// The signature every boot sector ends with.
pub const BOOT_SIGNATURE: u16 = 0xAA55;
pub const SIGNATURE_AT = 510;

/// Media byte for a fixed disk.
const MEDIA_FIXED: u8 = 0xF8;

/// FAT32 FSInfo sector.
pub const FSINFO_SECTOR: u16 = 1;
/// FAT32 backup boot sector.
pub const BACKUP_BOOT_SECTOR: u16 = 6;

/// Reserved sectors per kind. FAT32 reserves room for FSInfo and the backup boot
/// sector.
fn reservedFor(kind: Kind) u16 {
    return switch (kind) {
        .fat12, .fat16 => 1,
        .fat32 => 32,
    };
}

/// Fixed root directory entries per kind. Zero on FAT32, whose root is a
/// cluster chain.
fn rootEntriesFor(kind: Kind) u16 {
    return switch (kind) {
        .fat12, .fat16 => 512,
        .fat32 => 0,
    };
}

/// Cluster count range per kind, as the specification defines it.
pub fn clusterRange(kind: Kind) struct { min: u32, max: u32 } {
    return switch (kind) {
        .fat12 => .{ .min = 1, .max = 4084 },
        .fat16 => .{ .min = 4085, .max = 65524 },
        // The top is what a twenty-eight bit entry can name, less the values
        // the format reserves at the end of the range.
        .fat32 => .{ .min = 65525, .max = 0x0FFF_FFF5 },
    };
}

/// Everything about where a volume's parts are.
pub const Geometry = struct {
    kind: Kind,
    bytes_per_sector: u32,
    sectors_per_cluster: u32,
    reserved_sectors: u32,
    fat_count: u32,
    sectors_per_fat: u32,
    /// FAT12/16 only; zero on FAT32.
    root_entries: u32,
    root_dir_sectors: u32,
    /// FAT32 only; zero otherwise.
    root_cluster: u32,
    total_sectors: u32,

    first_fat_sector: u32,
    root_dir_sector: u32,
    first_data_sector: u32,
    cluster_count: u32,

    pub fn clusterSize(self: Geometry) u32 {
        return self.bytes_per_sector * self.sectors_per_cluster;
    }

    /// The first cluster number a volume has, and one past its last.
    pub fn firstCluster(_: Geometry) u32 {
        return 2;
    }

    pub fn pastLastCluster(self: Geometry) u32 {
        return self.cluster_count + self.firstCluster();
    }

    /// Where a cluster's data begins.
    pub fn sectorOf(self: Geometry, cluster: u32) u32 {
        const offset = @as(u64, cluster - self.firstCluster()) * self.sectors_per_cluster;
        return @intCast(self.first_data_sector + offset);
    }

    /// The boot sector this geometry is written as.
    pub fn toBpb(self: Geometry) Bpb {
        const narrow = self.kind != .fat32;
        return .{
            .jump = .{ 0xEB, 0x58, 0x90 },
            .oem = "vibeee  ".*,
            .bytes_per_sector = @intCast(self.bytes_per_sector),
            .sectors_per_cluster = @intCast(self.sectors_per_cluster),
            .reserved_sectors = @intCast(self.reserved_sectors),
            .fat_count = @intCast(self.fat_count),
            .root_entries = @intCast(self.root_entries),
            // The older layouts may record the total in either field; writing
            // it only in the wide one keeps one answer on the medium.
            .total_sectors_16 = 0,
            .media = MEDIA_FIXED,
            .sectors_per_fat_16 = if (narrow) @intCast(self.sectors_per_fat) else 0,
            .sectors_per_track = 63,
            .heads = 255,
            .hidden_sectors = 0,
            .total_sectors_32 = self.total_sectors,
            .sectors_per_fat_32 = if (narrow) 0 else self.sectors_per_fat,
            .ext_flags = 0,
            .version = 0,
            .root_cluster = self.root_cluster,
            .fs_info = if (narrow) 0 else FSINFO_SECTOR,
            .backup_boot = if (narrow) 0 else BACKUP_BOOT_SECTOR,
        };
    }

    /// The geometry a boot sector describes, or why it cannot be believed.
    ///
    /// `device_sectors` bounds the volume: everything above sizes its working
    /// set from the cluster count, so a medium must not be able to name more
    /// clusters than it has room for.
    pub fn read(bpb: *align(1) const Bpb, device_sectors: u64) Error!Geometry {
        if (bpb.bytes_per_sector != SECTOR) return error.Unsupported;
        if (bpb.sectors_per_cluster == 0 or bpb.fat_count == 0) return error.NotFat;
        // A power of two, or the cluster arithmetic below is wrong.
        if (!std.math.isPowerOfTwo(bpb.sectors_per_cluster)) return error.Unsupported;

        const sectors_per_fat: u32 = if (bpb.sectors_per_fat_16 != 0)
            bpb.sectors_per_fat_16
        else
            bpb.sectors_per_fat_32;
        if (sectors_per_fat == 0) return error.NotFat;

        const total_sectors: u32 = if (bpb.total_sectors_16 != 0)
            bpb.total_sectors_16
        else
            bpb.total_sectors_32;
        if (total_sectors == 0) return error.NotFat;
        if (total_sectors > device_sectors) return error.NotFat;

        const root_dir_sectors: u32 = (@as(u32, bpb.root_entries) * DIR_ENTRY_BYTES +
            bpb.bytes_per_sector - 1) / bpb.bytes_per_sector;

        const tables_end = @as(u64, bpb.reserved_sectors) +
            @as(u64, bpb.fat_count) * sectors_per_fat;
        const data_start = tables_end + root_dir_sectors;
        if (data_start >= total_sectors) return error.NotFat;

        const cluster_count = (total_sectors - @as(u32, @intCast(data_start))) /
            bpb.sectors_per_cluster;

        // FAT32 is identified structurally, not by cluster count. Formatters
        // will make a small FAT32 volume whose count falls in the FAT16
        // range, and reading its 32-bit entries as 16-bit ones yields chains
        // that end early. Both relocated fields are zero on FAT32 and never
        // zero otherwise.
        const kind: Kind = if (bpb.sectors_per_fat_16 == 0 and bpb.root_entries == 0)
            .fat32
        else if (cluster_count <= clusterRange(.fat12).max)
            .fat12
        else
            .fat16;

        const root_cluster: u32 = if (kind == .fat32) bpb.root_cluster else 0;
        if (kind == .fat32 and (root_cluster < 2 or root_cluster >= cluster_count + 2)) {
            return error.NotFat;
        }

        return .{
            .kind = kind,
            .bytes_per_sector = bpb.bytes_per_sector,
            .sectors_per_cluster = bpb.sectors_per_cluster,
            .reserved_sectors = bpb.reserved_sectors,
            .fat_count = bpb.fat_count,
            .sectors_per_fat = sectors_per_fat,
            .root_entries = bpb.root_entries,
            .root_dir_sectors = root_dir_sectors,
            .root_cluster = root_cluster,
            .total_sectors = total_sectors,
            .first_fat_sector = bpb.reserved_sectors,
            .root_dir_sector = @intCast(tables_end),
            .first_data_sector = @intCast(data_start),
            .cluster_count = cluster_count,
        };
    }
};

/// One directory record. Fixed by the format.
pub const DIR_ENTRY_BYTES = 32;

/// What a caller wants of a new filesystem. Anything left out is chosen.
pub const Wanted = struct {
    kind: ?Kind = null,
    sectors_per_cluster: ?u8 = null,
    fat_count: u8 = 2,
};

/// Cluster sizes to try, smallest first. A smaller cluster wastes less on a
/// short file; a larger one needs a smaller table to address the same volume.
const CLUSTER_SIZES = [_]u8{ 1, 2, 4, 8, 16, 32, 64, 128 };

/// A geometry for a volume of `total_sectors`.
pub fn plan(total_sectors: u32, wanted: Wanted) Error!Geometry {
    if (wanted.fat_count == 0) return error.Unsupported;
    if (wanted.sectors_per_cluster) |spc| {
        if (spc == 0 or !std.math.isPowerOfTwo(spc)) return error.Unsupported;
    }

    // Each kind in turn, largest first, and within a kind each cluster size
    // from the smallest. The first that fits is the one with the smallest
    // clusters that the kind can address, which wastes the least.
    const kinds = if (wanted.kind) |only| &[_]Kind{only} else &[_]Kind{ .fat32, .fat16, .fat12 };
    for (kinds) |kind| {
        for (CLUSTER_SIZES) |spc| {
            if (wanted.sectors_per_cluster) |only| {
                if (spc != only) continue;
            }
            const found = fit(.{
                .total_sectors = total_sectors,
                .kind = kind,
                .sectors_per_cluster = spc,
                .fat_count = wanted.fat_count,
                .reserved_sectors = reservedFor(kind),
                .root_entries = rootEntriesFor(kind),
                .min_clusters = clusterRange(kind).min,
            }) orelse continue;
            return found;
        }
    }
    return error.TooSmall;
}

/// Everything a geometry is fixed by, leaving the table size and the cluster
/// count to be solved for.
const Fixed = struct {
    total_sectors: u32,
    kind: Kind,
    sectors_per_cluster: u8,
    fat_count: u8,
    reserved_sectors: u16,
    root_entries: u16,
    /// The fewest clusters this is allowed to come out with.
    ///
    /// Choosing a kind holds it to the count its kind is defined by. Growing
    /// a volume does not: the kind is already on the medium, FAT32 says so in
    /// its own fields rather than by its count, and a count only rises.
    min_clusters: u32,
};

/// A geometry for one set of fixed choices, or null if the volume cannot hold
/// them.
fn fit(given: Fixed) ?Geometry {
    const total_sectors = given.total_sectors;
    const kind = given.kind;
    const spc = given.sectors_per_cluster;
    const fat_count = given.fat_count;
    const reserved = given.reserved_sectors;
    const root_entries = given.root_entries;
    const root_dir_sectors = (@as(u32, root_entries) * DIR_ENTRY_BYTES + SECTOR - 1) / SECTOR;
    const range = clusterRange(kind);

    // The table's size and the cluster count each depend on the other: a
    // bigger table leaves fewer clusters, and fewer clusters need a smaller
    // table. Raising the table until it is big enough for the count it leaves
    // settles, because each round either stops or takes a sector from the
    // data area, and the data area is finite.
    var sectors_per_fat: u32 = 1;
    for (0..MAX_ROUNDS) |_| {
        const fixed = @as(u64, reserved) + @as(u64, fat_count) * sectors_per_fat + root_dir_sectors;
        if (fixed >= total_sectors) return null;

        const clusters: u32 = @intCast((total_sectors - fixed) / spc);
        if (clusters < given.min_clusters or clusters > range.max) return null;

        const needed = tableSectors(kind, clusters);
        if (needed <= sectors_per_fat) {
            const data_start: u32 = @intCast(fixed);
            return .{
                .kind = kind,
                .bytes_per_sector = SECTOR,
                .sectors_per_cluster = spc,
                .reserved_sectors = reserved,
                .fat_count = fat_count,
                .sectors_per_fat = sectors_per_fat,
                .root_entries = root_entries,
                .root_dir_sectors = root_dir_sectors,
                .root_cluster = if (kind == .fat32) 2 else 0,
                .total_sectors = total_sectors,
                .first_fat_sector = reserved,
                .root_dir_sector = @intCast(fixed - root_dir_sectors),
                .first_data_sector = data_start,
                .cluster_count = clusters,
            };
        }
        sectors_per_fat = needed;
    }
    return null;
}

/// How many rounds the table size is allowed to take to settle. It rises
/// every round that does not stop, so this is a bound on a loop that has
/// already converged, not a limit anybody reaches.
const MAX_ROUNDS = 8;

/// Sectors needed to hold entries for `clusters` clusters, plus the two
/// reserved entries at the front.
///
/// The bytes come from `fat/alloc.zig`, which owns how an entry is stored, so
/// the table's size and the place an entry is read from cannot disagree.
fn tableSectors(kind: Kind, clusters: u32) u32 {
    const entries = clusters + 2;
    const bytes = table.byteOffset(kind, entries);
    return (bytes + SECTOR - 1) / SECTOR;
}

const testing = std.testing;

/// A boot sector built from a geometry, for reading back.
fn roundTrip(geometry: Geometry) !Geometry {
    var sector: [block.SECTOR_SIZE]u8 = @splat(0);
    const bpb: *align(1) Bpb = @ptrCast(&sector);
    bpb.* = geometry.toBpb();
    return Geometry.read(bpb, geometry.total_sectors);
}

/// The same filesystem on a larger volume.
///
/// Everything a volume's contents depend on is kept: the kind, the cluster
/// size, the number of tables, the reserved sectors and the root. Only the
/// table's size and the cluster count change, and the table growing is what
/// moves the data area forward.
pub fn grown(old: Geometry, total_sectors: u32) Error!Geometry {
    if (total_sectors <= old.total_sectors) return error.TooSmall;

    var next = fit(.{
        .total_sectors = total_sectors,
        .kind = old.kind,
        .sectors_per_cluster = @intCast(old.sectors_per_cluster),
        .fat_count = @intCast(old.fat_count),
        .reserved_sectors = @intCast(old.reserved_sectors),
        .root_entries = @intCast(old.root_entries),
        .min_clusters = 1,
    }) orelse return error.TooSmall;

    // A root cluster is where it was: the data moves as a whole, so every
    // cluster keeps its number.
    next.root_cluster = old.root_cluster;
    return next;
}

/// How far the data area moves when `old` becomes `next`.
pub fn shiftBetween(old: Geometry, next: Geometry) u32 {
    return next.first_data_sector - old.first_data_sector;
}

test "a planned geometry reads back as itself" {
    // The property the formatter rests on: what is written is what mounting
    // will make of it. A formatter and a driver that disagreed here would
    // produce volumes only one of them could read.
    const sizes = [_]u32{ 128, 1000, 4096, 40_000, 100_000, 1 << 20, 8 << 20, 64 << 20 };
    for (sizes) |sectors| {
        const planned = plan(sectors, .{}) catch continue;
        const read = try roundTrip(planned);
        try testing.expectEqual(planned, read);
    }
}

test "a planned geometry is the kind its cluster count calls for" {
    const sizes = [_]u32{ 128, 1000, 4096, 40_000, 100_000, 1 << 20, 8 << 20 };
    for (sizes) |sectors| {
        const planned = plan(sectors, .{}) catch continue;
        const range = clusterRange(planned.kind);
        try testing.expect(planned.cluster_count >= range.min);
        try testing.expect(planned.cluster_count <= range.max);
    }
}

test "a planned table is big enough for the clusters it leaves" {
    // The circular part: the table has to address every cluster that is left
    // once the table itself is taken out of the volume.
    var sectors: u32 = 64;
    while (sectors < 2 << 20) : (sectors = sectors * 3 / 2 + 1) {
        const planned = plan(sectors, .{}) catch continue;
        try testing.expect(tableSectors(planned.kind, planned.cluster_count) <= planned.sectors_per_fat);
    }
}

test "a planned volume fits on the medium it was planned for" {
    var sectors: u32 = 64;
    while (sectors < 2 << 20) : (sectors = sectors * 3 / 2 + 1) {
        const planned = plan(sectors, .{}) catch continue;
        try testing.expect(planned.total_sectors <= sectors);

        // The last cluster's last sector is on the volume.
        const last = planned.pastLastCluster() - 1;
        const end = @as(u64, planned.sectorOf(last)) + planned.sectors_per_cluster;
        try testing.expect(end <= planned.total_sectors);
    }
}

test "a kind asked for is the kind planned, or the volume cannot hold it" {
    for ([_]Kind{ .fat12, .fat16, .fat32 }) |kind| {
        var sectors: u32 = 64;
        while (sectors < 4 << 20) : (sectors = sectors * 2) {
            const planned = plan(sectors, .{ .kind = kind }) catch continue;
            try testing.expectEqual(kind, planned.kind);
        }
    }
}

test "a volume too small for a filesystem is refused" {
    try testing.expectError(error.TooSmall, plan(1, .{}));
    try testing.expectError(error.TooSmall, plan(8, .{}));
    // And one too small for the kind named, however big it is otherwise.
    try testing.expectError(error.TooSmall, plan(64, .{ .kind = .fat32 }));
}

test "a boot sector that contradicts itself is refused" {
    var sector: [block.SECTOR_SIZE]u8 = @splat(0);
    const bpb: *align(1) Bpb = @ptrCast(&sector);
    const good = try plan(40_000, .{});

    bpb.* = good.toBpb();
    bpb.sectors_per_cluster = 0;
    try testing.expectError(error.NotFat, Geometry.read(bpb, 40_000));

    bpb.* = good.toBpb();
    bpb.sectors_per_cluster = 3;
    try testing.expectError(error.Unsupported, Geometry.read(bpb, 40_000));

    bpb.* = good.toBpb();
    bpb.fat_count = 0;
    try testing.expectError(error.NotFat, Geometry.read(bpb, 40_000));

    // Larger than the medium it sits on.
    bpb.* = good.toBpb();
    try testing.expectError(error.NotFat, Geometry.read(bpb, 100));

    // Tables that leave no room for a single cluster.
    bpb.* = good.toBpb();
    bpb.reserved_sectors = std.math.maxInt(u16);
    try testing.expectError(error.NotFat, Geometry.read(bpb, 40_000));
}

test "a grown volume keeps everything its contents depend on" {
    // A cluster's number means where its data is, so the cluster size, the
    // reserved sectors and the root must all survive a grow. Only the table
    // and the count may change.
    const starts = [_]u32{ 2048, 20_000, 70_000, 200_000 };
    for (starts) |sectors| {
        const old = plan(sectors, .{}) catch continue;
        for ([_]u32{ 2, 4, 64 }) |times| {
            const next = grown(old, sectors * times) catch continue;
            try testing.expectEqual(old.kind, next.kind);
            try testing.expectEqual(old.sectors_per_cluster, next.sectors_per_cluster);
            try testing.expectEqual(old.fat_count, next.fat_count);
            try testing.expectEqual(old.reserved_sectors, next.reserved_sectors);
            try testing.expectEqual(old.root_entries, next.root_entries);
            try testing.expectEqual(old.root_cluster, next.root_cluster);

            // More room than before, and the data area never moves backwards.
            try testing.expect(next.cluster_count > old.cluster_count);
            try testing.expect(next.first_data_sector >= old.first_data_sector);
            try testing.expectEqual(
                shiftBetween(old, next),
                next.first_data_sector - old.first_data_sector,
            );
        }
    }
}

test "a grown geometry reads back as itself" {
    const old = try plan(200_000, .{ .kind = .fat32 });
    const next = try grown(old, 2_000_000);
    var sector: [SECTOR]u8 = @splat(0);
    const bpb: *align(1) Bpb = @ptrCast(&sector);
    bpb.* = next.toBpb();
    try testing.expectEqual(next, try Geometry.read(bpb, next.total_sectors));
}

test "a volume is not grown to a size it already has or exceeds" {
    const old = try plan(20_000, .{});
    try testing.expectError(error.TooSmall, grown(old, old.total_sectors));
    try testing.expectError(error.TooSmall, grown(old, old.total_sectors - 1));
}

test "growing past what a kind can address is refused" {
    // A FAT16 volume cannot become a large one by growing: past its range the
    // count no longer names a kind it is. Changing width would renumber every
    // cluster, which is not a grow.
    const old = try plan(70_000, .{ .kind = .fat16 });
    try testing.expectEqual(Kind.fat16, old.kind);
    try testing.expectError(error.TooSmall, grown(old, 1 << 30));
}

test "a small FAT32 volume grows, though its count is below the kind's range" {
    // FAT32 says what it is in its own fields, not by its cluster count, and
    // other formatters do make small ones: the card this system ships on
    // carries a sixteen megabyte FAT32 volume for /home. `plan` will not make
    // one, so this is built the way such a volume arrives.
    var sector: [SECTOR]u8 = @splat(0);
    const bpb: *align(1) Bpb = @ptrCast(&sector);
    bpb.* = .{
        .jump = .{ 0xEB, 0x58, 0x90 },
        .oem = "mkfs.fat".*,
        .bytes_per_sector = SECTOR,
        .sectors_per_cluster = 1,
        .reserved_sectors = 32,
        .fat_count = 2,
        .root_entries = 0,
        .total_sectors_16 = 0,
        .media = 0xF8,
        .sectors_per_fat_16 = 0,
        .sectors_per_track = 63,
        .heads = 255,
        .hidden_sectors = 0,
        .total_sectors_32 = 32_768,
        .sectors_per_fat_32 = 256,
        .ext_flags = 0,
        .version = 0,
        .root_cluster = 2,
        .fs_info = 1,
        .backup_boot = 6,
    };

    const small = try Geometry.read(bpb, 32_768);
    try testing.expectEqual(Kind.fat32, small.kind);
    try testing.expect(small.cluster_count < clusterRange(.fat32).min);

    // Onto a card of eight gigabytes, which is what this is for.
    const next = try grown(small, 16_000_000);
    try testing.expectEqual(Kind.fat32, next.kind);
    try testing.expectEqual(small.sectors_per_cluster, next.sectors_per_cluster);
    try testing.expect(next.cluster_count > small.cluster_count);
    try testing.expect(shiftBetween(small, next) > 0);

    // And it still reads back as FAT32 rather than as the kind its count says.
    bpb.* = next.toBpb();
    try testing.expectEqual(Kind.fat32, (try Geometry.read(bpb, next.total_sectors)).kind);
}
