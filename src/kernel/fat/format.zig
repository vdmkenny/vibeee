//! Writing a new filesystem onto a volume.
//!
//! Chooses a geometry with `fat/layout.zig`, then writes the boot sector, the
//! allocation tables and an empty root directory. The data area past the root
//! is not cleared; no chain reaches it.
//!
//! The volume is left marked clean.

const std = @import("std");
const block = @import("../block.zig");
const bulk = @import("bulk.zig");
const layout = @import("layout.zig");
const table = @import("alloc.zig");

pub const Error = layout.Error || table.Error || bulk.Error;

pub const Wanted = layout.Wanted;
pub const Geometry = layout.Geometry;

/// Media descriptor for a fixed disk. Stored in the low byte of FAT entry 0.
const MEDIA_FIXED: u8 = 0xF8;

/// Make a filesystem on `dev` covering the whole of it.
pub fn create(dev: *const block.Device, wanted: Wanted) Error!Geometry {
    const sectors = std.math.cast(u32, dev.sectors) orelse std.math.maxInt(u32);
    const geometry = try layout.plan(sectors, wanted);
    try write(dev, geometry);
    return geometry;
}

/// Write `geometry` onto `dev` as an empty filesystem.
pub fn write(dev: *const block.Device, geometry: Geometry) Error!void {
    if (dev.read_only) return error.ReadOnly;

    try bulk.clear(dev, 0, geometry.reserved_sectors);
    try writeBootSector(dev, geometry, 0);
    if (geometry.kind == .fat32) {
        try writeBootSector(dev, geometry, layout.BACKUP_BOOT_SECTOR);
        try writeFsInfo(dev, geometry);
    }

    try clearTables(dev, geometry);
    try writeFirstEntries(dev, geometry);
    try clearRoot(dev, geometry);

    dev.flush() catch return error.Io;
}

fn writeBootSector(dev: *const block.Device, geometry: Geometry, at: u32) Error!void {
    var sector: [block.SECTOR_SIZE]u8 = @splat(0);
    const bpb: *align(1) layout.Bpb = @ptrCast(&sector);
    bpb.* = geometry.toBpb();
    std.mem.writeInt(u16, sector[layout.SIGNATURE_AT..][0..2], layout.BOOT_SIGNATURE, .little);
    dev.write(at, &sector) catch return error.Io;
}

/// FAT32's free-cluster hint. This driver counts the table instead; the hint is
/// written for other systems.
fn writeFsInfo(dev: *const block.Device, geometry: Geometry) Error!void {
    var sector: [block.SECTOR_SIZE]u8 = @splat(0);
    const info: *align(1) FsInfo = @ptrCast(&sector);
    info.* = .{
        // The root directory is the one cluster in use.
        .free_clusters = geometry.cluster_count - 1,
        .next_free = geometry.root_cluster + 1,
    };
    std.mem.writeInt(u16, sector[layout.SIGNATURE_AT..][0..2], layout.BOOT_SIGNATURE, .little);
    dev.write(layout.FSINFO_SECTOR, &sector) catch return error.Io;
}

/// FSInfo sector layout. The gap between the signatures is reserved and zero.
const FsInfo = extern struct {
    lead_signature: u32 align(1) = 0x4161_5252,
    reserved: [480]u8 = @splat(0),
    struct_signature: u32 align(1) = 0x6141_7272,
    free_clusters: u32 align(1),
    next_free: u32 align(1),
};

fn clearTables(dev: *const block.Device, geometry: Geometry) Error!void {
    var copy: u32 = 0;
    while (copy < geometry.fat_count) : (copy += 1) {
        const at = geometry.first_fat_sector + copy * geometry.sectors_per_fat;
        try bulk.clear(dev, at, geometry.sectors_per_fat);
    }
}

/// The reserved entries at the front of every table.
///
/// Entry 0: media descriptor in the low byte, ones above. Entry 1: all ones,
/// which sets the clean and no-error flags. FAT32 entry 2: end of chain, for the
/// one-cluster root directory.
fn writeFirstEntries(dev: *const block.Device, geometry: Geometry) Error!void {
    var entries = tableOf(dev, geometry);
    const ends = table.sentinels(geometry.kind).terminator;

    try table.setReserved(&entries, .media, (ends & ~@as(u32, 0xFF)) | MEDIA_FIXED);
    try table.setReserved(&entries, .flags, ends);
    if (geometry.kind == .fat32) try table.set(&entries, geometry.root_cluster, ends);
    try table.flush(&entries);
}

fn clearRoot(dev: *const block.Device, geometry: Geometry) Error!void {
    return switch (geometry.kind) {
        // Fixed sectors before the data area.
        .fat12, .fat16 => bulk.clear(dev, geometry.root_dir_sector, geometry.root_dir_sectors),
        // One cluster, allocated by `writeFirstEntries`.
        .fat32 => bulk.clear(
            dev,
            geometry.sectorOf(geometry.root_cluster),
            geometry.sectors_per_cluster,
        ),
    };
}

/// A table over `dev`, for writing the reserved entries.
fn tableOf(dev: *const block.Device, geometry: Geometry) table.Table {
    return .{
        .dev = dev,
        .kind = geometry.kind,
        .bytes_per_sector = geometry.bytes_per_sector,
        .first_fat_sector = geometry.first_fat_sector,
        .sectors_per_fat = geometry.sectors_per_fat,
        .fat_count = geometry.fat_count,
        .cluster_count = geometry.cluster_count,
    };
}

const testing = std.testing;
const fat = @import("../fat.zig");
const check = @import("check.zig");
const clean = @import("clean.zig");

/// A blank medium of `sectors` sectors.
const Blank = struct {
    gpa: std.mem.Allocator,
    bytes: []u8,
    medium: block.Memory = undefined,
    dev: block.Device = undefined,

    fn init(gpa: std.mem.Allocator, sectors: u32) !*Blank {
        const self = try gpa.create(Blank);
        self.* = .{ .gpa = gpa, .bytes = try gpa.alloc(u8, sectors * block.SECTOR_SIZE) };
        // Filled with a pattern, not zeros, so the formatter is tested against
        // old contents.
        @memset(self.bytes, 0xA5);
        self.medium = .{ .bytes = self.bytes };
        self.dev = self.medium.device("blank");
        return self;
    }

    fn deinit(self: *Blank) void {
        self.gpa.free(self.bytes);
        self.gpa.destroy(self);
    }
};

/// Sizes covering all three kinds, small enough to format in a test.
const SIZES = [_]u32{ 512, 2048, 20_000, 70_000, 200_000 };

test "a volume just formatted mounts as what was written" {
    for (SIZES) |sectors| {
        const disk = try Blank.init(testing.allocator, sectors);
        defer disk.deinit();

        const written = create(&disk.dev, .{}) catch continue;
        const volume = try fat.mount(&disk.dev);

        try testing.expectEqual(written.kind, volume.kind);
        try testing.expectEqual(written.cluster_count, volume.cluster_count);
        try testing.expectEqual(written.first_data_sector, volume.first_data_sector);
        try testing.expectEqual(written.sectors_per_fat, volume.sectors_per_fat);
    }
}

test "a volume just formatted is empty, clean, and has nothing wrong with it" {
    for (SIZES) |sectors| {
        const disk = try Blank.init(testing.allocator, sectors);
        defer disk.deinit();
        const written = create(&disk.dev, .{}) catch continue;

        var volume = try fat.mount(&disk.dev);

        // Nothing in the root.
        var it = fat.rootIterator(&volume);
        try testing.expectEqual(@as(?fat.Entry, null), try it.next());

        // Every cluster free but the root's, on FAT32; all of them otherwise.
        const used: u32 = if (written.kind == .fat32) 1 else 0;
        try testing.expectEqual(written.cluster_count - used, try fat.freeClusters(&volume));

        // Clean on FAT16 and FAT32. FAT12 records nothing.
        const expected: clean.State = if (written.kind == .fat12) .unrecorded else .clean;
        try testing.expectEqual(expected, try clean.state(&volume.fat));

        // The check finds nothing.
        const found = try check.run(&volume, testing.allocator, .{});
        try testing.expect(found.quiet());
    }
}

test "a volume just formatted holds files, and still checks out" {
    for (SIZES) |sectors| {
        const disk = try Blank.init(testing.allocator, sectors);
        defer disk.deinit();
        _ = create(&disk.dev, .{}) catch continue;

        var volume = try fat.mount(&disk.dev);
        var entry = try fat.createFile(&volume, fat.rootIterator(&volume), "hello.txt", 0);
        const written = "the volume works";
        try testing.expectEqual(written.len, try fat.writeAt(&volume, &entry, 0, written));
        try fat.commit(&volume, entry, 0);

        const dir = try fat.createDirectory(&volume, fat.rootIterator(&volume), "sub", 0);
        _ = try fat.createFile(&volume, fat.iterate(&volume, dir), "below.txt", 0);

        var read: [32]u8 = undefined;
        const found = try fat.lookupPath(&volume, "hello.txt");
        const got = try fat.readFile(&volume, found, &read);
        try testing.expectEqualStrings(written, read[0..got]);

        const report = try check.run(&volume, testing.allocator, .{});
        try testing.expect(report.quiet());
    }
}

test "each kind can be asked for, and is what comes back" {
    // A named width is honoured or refused, never substituted.
    const cases = [_]struct { kind: layout.Kind, sectors: u32 }{
        .{ .kind = .fat12, .sectors = 2048 },
        .{ .kind = .fat16, .sectors = 70_000 },
        .{ .kind = .fat32, .sectors = 200_000 },
    };
    for (cases) |case| {
        const disk = try Blank.init(testing.allocator, case.sectors);
        defer disk.deinit();

        _ = try create(&disk.dev, .{ .kind = case.kind });
        const volume = try fat.mount(&disk.dev);
        try testing.expectEqual(case.kind, volume.kind);
    }
}

test "a medium too small to hold a filesystem is refused" {
    const disk = try Blank.init(testing.allocator, 4);
    defer disk.deinit();
    try testing.expectError(error.TooSmall, create(&disk.dev, .{}));
}

test "a volume that cannot be written is refused before anything is" {
    const disk = try Blank.init(testing.allocator, 20_000);
    defer disk.deinit();
    disk.dev.read_only = true;

    const before = try testing.allocator.dupe(u8, disk.bytes);
    defer testing.allocator.free(before);

    try testing.expectError(error.ReadOnly, create(&disk.dev, .{}));
    try testing.expectEqualSlices(u8, before, disk.bytes);
}

test "formatting leaves every copy of the table saying the same thing" {
    const disk = try Blank.init(testing.allocator, 70_000);
    defer disk.deinit();
    const written = try create(&disk.dev, .{ .fat_count = 2 });

    const size = written.sectors_per_fat * block.SECTOR_SIZE;
    const first = disk.bytes[written.first_fat_sector * block.SECTOR_SIZE ..][0..size];
    const second = disk.bytes[(written.first_fat_sector + written.sectors_per_fat) *
        block.SECTOR_SIZE ..][0..size];
    try testing.expectEqualSlices(u8, first, second);
}
