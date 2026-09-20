//! Extending a filesystem over the rest of its volume.
//!
//! The system image gives `/home` 16 MiB whatever the card's size.
//!
//! A larger volume needs a larger allocation table. The table precedes the
//! data, so the data area moves forward by the table's growth. Cluster numbers
//! do not change, so no chain or directory record is rewritten.
//!
//! Order: data, tables, boot sector. Until the boot sector is written the
//! volume describes the old layout.
//!
//! A power cut during the move destroys the volume: FAT has no journal.
//! `plan` reports whether a move is needed; the tool asks before starting.

const std = @import("std");
const block = @import("../block.zig");
const bulk = @import("bulk.zig");
const clean = @import("clean.zig");
const fat = @import("../fat.zig");
const layout = @import("layout.zig");
const table = @import("alloc.zig");

pub const Error = layout.Error || table.Error || bulk.Error || std.mem.Allocator.Error;

pub const Geometry = layout.Geometry;

/// What growing a volume would come to.
pub const Plan = struct {
    from: Geometry,
    to: Geometry,
    /// How far the data area moves. Zero means nothing moves, and the grow
    /// cannot lose anything.
    shift: u32,
    /// Clusters holding data that has to move.
    moving: u32,
    /// Clusters the volume gains.
    gained: u32,

    /// Whether carrying this out can lose data if it is interrupted.
    pub fn risky(self: Plan) bool {
        return self.shift != 0 and self.moving != 0;
    }
};

/// What growing `vol` to fill `total_sectors` would come to.
pub fn plan(vol: *fat.Volume, total_sectors: u32) Error!Plan {
    const from = geometryOf(vol);
    const to = try layout.grown(from, total_sectors);
    const shift = layout.shiftBetween(from, to);

    return .{
        .from = from,
        .to = to,
        .shift = shift,
        .moving = if (shift == 0) 0 else try countUsed(vol),
        .gained = to.cluster_count - from.cluster_count,
    };
}

/// Carry out a plan.
pub fn apply(vol: *fat.Volume, want: Plan) Error!void {
    const dev = vol.dev;
    if (dev.read_only) return error.ReadOnly;

    // The table is moved on the medium, so what its cache holds goes there
    // first, and the cache is dropped once the sectors it named have moved.
    try table.flush(&vol.fat);
    if (want.shift != 0) try moveEverything(vol, want);
    try growTables(dev, want);
    table.forget(&vol.fat);
    try writeBootSectors(dev, want.to);
    dev.flush() catch return error.Io;
}

/// The geometry a mounted volume has.
fn geometryOf(vol: *const fat.Volume) Geometry {
    return .{
        .kind = vol.kind,
        .bytes_per_sector = vol.bytes_per_sector,
        .sectors_per_cluster = vol.sectors_per_cluster,
        .reserved_sectors = vol.first_fat_sector,
        .fat_count = vol.fat_count,
        .sectors_per_fat = vol.sectors_per_fat,
        .root_entries = @intCast(vol.root_dir_sectors * layout.SECTOR /
            layout.DIR_ENTRY_BYTES),
        .root_dir_sectors = vol.root_dir_sectors,
        .root_cluster = vol.root_cluster,
        .total_sectors = vol.first_data_sector + vol.cluster_count * vol.sectors_per_cluster,
        .first_fat_sector = vol.first_fat_sector,
        .root_dir_sector = vol.root_dir_sector,
        .first_data_sector = vol.first_data_sector,
        .cluster_count = vol.cluster_count,
    };
}

/// How many of the volume's clusters hold something.
fn countUsed(vol: *fat.Volume) Error!u32 {
    var used: u32 = 0;
    var cluster: u32 = 2;
    while (cluster < vol.cluster_count + 2) : (cluster += 1) {
        if (try table.get(&vol.fat, cluster) != 0) used += 1;
    }
    return used;
}

/// Move the root directory and every cluster in use forward by the shift.
///
/// Highest source address first, so a run is read before anything is written
/// over it: the destination of a run is always above its source, and the run
/// it lands on has already been moved.
fn moveEverything(vol: *fat.Volume, want: Plan) Error!void {
    var cluster = want.from.pastLastCluster();
    while (cluster > want.from.firstCluster()) {
        cluster -= 1;
        if (try table.get(&vol.fat, cluster) == 0) continue;
        try bulk.shiftUp(
            vol.dev,
            want.from.sectorOf(cluster),
            want.from.sectors_per_cluster,
            want.shift,
        );
    }

    // The older layouts keep the root in a fixed run between the tables and
    // the data, so it moves too, and it sits below every cluster.
    if (want.from.root_dir_sectors != 0) {
        try bulk.shiftUp(
            vol.dev,
            want.from.root_dir_sector,
            want.from.root_dir_sectors,
            want.shift,
        );
    }
}

/// Extend the first table over its new length and copy it to the others.
///
/// The entries already in it stay where they are, since no cluster is
/// renumbered. What is added is the clusters the volume has gained, which are
/// free and therefore zero.
fn growTables(dev: *const block.Device, want: Plan) Error!void {
    // The entries already there stay where they are, since no cluster is
    // renumbered. What is added is the clusters the volume has gained, which
    // are free and therefore zero.
    try bulk.clear(
        dev,
        want.to.first_fat_sector + want.from.sectors_per_fat,
        want.to.sectors_per_fat - want.from.sectors_per_fat,
    );

    // Every other copy, from the first, at the place the new size puts it.
    var copy: u32 = 1;
    while (copy < want.to.fat_count) : (copy += 1) {
        try bulk.copy(
            dev,
            want.to.first_fat_sector,
            want.to.first_fat_sector + copy * want.to.sectors_per_fat,
            want.to.sectors_per_fat,
        );
    }
}

/// The boot sector, last, because it is what says where everything is.
fn writeBootSectors(dev: *const block.Device, to: Geometry) Error!void {
    var sector: [layout.SECTOR]u8 = @splat(0);
    dev.read(0, &sector) catch return error.Io;

    const bpb: *align(1) layout.Bpb = @ptrCast(&sector);
    const before = bpb.*;
    bpb.* = to.toBpb();
    // What the volume was called and what wrote it are not this operation's
    // to change.
    bpb.oem = before.oem;
    bpb.jump = before.jump;
    bpb.hidden_sectors = before.hidden_sectors;
    std.mem.writeInt(u16, sector[layout.SIGNATURE_AT..][0..2], layout.BOOT_SIGNATURE, .little);

    dev.write(0, &sector) catch return error.Io;
    if (to.kind == .fat32 and to.reserved_sectors > layout.BACKUP_BOOT_SECTOR) {
        dev.write(layout.BACKUP_BOOT_SECTOR, &sector) catch return error.Io;
    }
}

const testing = std.testing;
const check = @import("check.zig");
const format = @import("format.zig");

/// A medium that can be formatted small and grown into.
const Card = struct {
    gpa: std.mem.Allocator,
    bytes: []u8,
    medium: block.Memory = undefined,
    dev: block.Device = undefined,

    fn init(gpa: std.mem.Allocator, sectors: u32) !*Card {
        const self = try gpa.create(Card);
        self.* = .{ .gpa = gpa, .bytes = try gpa.alloc(u8, sectors * layout.SECTOR) };
        @memset(self.bytes, 0x5A);
        self.medium = .{ .bytes = self.bytes };
        self.dev = self.medium.device("card");
        return self;
    }

    fn deinit(self: *Card) void {
        self.gpa.free(self.bytes);
        self.gpa.destroy(self);
    }

    /// The volume as it is now, whatever the boot sector says.
    fn mount(self: *Card) !fat.Volume {
        return fat.mount(&self.dev);
    }
};

/// Fill a volume with files whose contents say which file they are, so that
/// a byte landing in the wrong place after a move is caught.
fn fill(vol: *fat.Volume, count: usize) !void {
    var name: [16]u8 = undefined;
    for (0..count) |i| {
        const named = try std.fmt.bufPrint(&name, "file{d}.txt", .{i});
        var entry = try fat.createFile(vol, fat.rootIterator(vol), named, 0);
        var body: [600]u8 = undefined;
        @memset(&body, @intCast('a' + i % 26));
        _ = try fat.writeAt(vol, &entry, 0, &body);
        try fat.commit(vol, entry, 0);
    }
}

fn expectFilled(vol: *fat.Volume, count: usize) !void {
    var name: [16]u8 = undefined;
    for (0..count) |i| {
        const named = try std.fmt.bufPrint(&name, "file{d}.txt", .{i});
        const entry = try fat.lookupPath(vol, named);
        var read: [600]u8 = undefined;
        const got = try fat.readFile(vol, entry, &read);
        try testing.expectEqual(@as(usize, 600), got);
        for (read[0..got]) |b| try testing.expectEqual(@as(u8, @intCast('a' + i % 26)), b);
    }
}

test "a volume grown into the rest of its medium keeps what was on it" {
    // The case this exists for: a filesystem made at one size on a medium
    // that is much larger.
    const card = try Card.init(testing.allocator, 300_000);
    defer card.deinit();

    // Formatted over a fraction of it.
    const small = try layout.plan(70_000, .{ .kind = .fat32 });
    try format.write(&card.dev, small);

    var volume = try card.mount();
    try fill(&volume, 8);
    try expectFilled(&volume, 8);
    const free_before = try fat.freeClusters(&volume);

    const want = try plan(&volume, 300_000);
    try testing.expect(want.gained > 0);
    // The table has to grow, so the data area moves and the files with it.
    try testing.expect(want.shift > 0);
    try testing.expect(want.risky());
    try apply(&volume, want);

    // Mounted again, it is the larger volume and still holds everything.
    var grown_volume = try card.mount();
    try testing.expectEqual(want.to.cluster_count, grown_volume.cluster_count);
    try testing.expect(grown_volume.cluster_count > small.cluster_count);
    try expectFilled(&grown_volume, 8);
    try testing.expect(try fat.freeClusters(&grown_volume) > free_before);

    // And nothing about it is inconsistent.
    const found = try check.run(&grown_volume, testing.allocator, .{});
    try testing.expect(found.quiet());
}

test "a volume grown twice keeps what was on it both times" {
    const card = try Card.init(testing.allocator, 300_000);
    defer card.deinit();
    try format.write(&card.dev, try layout.plan(70_000, .{ .kind = .fat32 }));

    var volume = try card.mount();
    try fill(&volume, 4);

    for ([_]u32{ 150_000, 300_000 }) |size| {
        var current = try card.mount();
        const want = plan(&current, size) catch continue;
        try apply(&current, want);

        var after = try card.mount();
        try expectFilled(&after, 4);
        try testing.expect((try check.run(&after, testing.allocator, .{})).quiet());
    }
}

test "an empty volume grows with nothing to move" {
    const card = try Card.init(testing.allocator, 300_000);
    defer card.deinit();
    const small = try layout.plan(70_000, .{ .kind = .fat32 });
    try format.write(&card.dev, small);

    var volume = try card.mount();
    const want = try plan(&volume, 300_000);

    // Only the root's cluster is in use on FAT32, and nothing at all below.
    const used: u32 = if (small.kind == .fat32) 1 else 0;
    try testing.expectEqual(used, want.moving);

    try apply(&volume, want);
    var after = try card.mount();
    try testing.expect((try check.run(&after, testing.allocator, .{})).quiet());
}

test "a volume already filling its medium is not grown" {
    const card = try Card.init(testing.allocator, 20_000);
    defer card.deinit();
    try format.write(&card.dev, try layout.plan(20_000, .{}));

    var volume = try card.mount();
    try testing.expectError(error.TooSmall, plan(&volume, 20_000));
}

test "a volume that cannot be written is refused before anything is" {
    const card = try Card.init(testing.allocator, 300_000);
    defer card.deinit();
    try format.write(&card.dev, try layout.plan(70_000, .{ .kind = .fat32 }));

    var volume = try card.mount();
    const want = try plan(&volume, 300_000);

    card.dev.read_only = true;
    const before = try testing.allocator.dupe(u8, card.bytes);
    defer testing.allocator.free(before);

    try testing.expectError(error.ReadOnly, apply(&volume, want));
    try testing.expectEqualSlices(u8, before, card.bytes);
}

test "growing leaves the volume clean and its tables agreeing" {
    const card = try Card.init(testing.allocator, 300_000);
    defer card.deinit();
    try format.write(&card.dev, try layout.plan(70_000, .{ .kind = .fat32, .fat_count = 2 }));

    var volume = try card.mount();
    try fill(&volume, 3);
    const want = try plan(&volume, 300_000);
    try apply(&volume, want);

    var after = try card.mount();
    try testing.expectEqual(clean.State.clean, try clean.state(&after.fat));

    const size = want.to.sectors_per_fat * layout.SECTOR;
    const first = card.bytes[want.to.first_fat_sector * layout.SECTOR ..][0..size];
    const second = card.bytes[(want.to.first_fat_sector + want.to.sectors_per_fat) *
        layout.SECTOR ..][0..size];
    try testing.expectEqualSlices(u8, first, second);
}

test "a FAT16 volume grows within the range its width can address" {
    // The other shape: a volume whose kind is decided by its cluster count.
    // It can grow, but only as far as that count may go.
    const card = try Card.init(testing.allocator, 60_000);
    defer card.deinit();
    try format.write(&card.dev, try layout.plan(20_000, .{ .kind = .fat16 }));

    var volume = try card.mount();
    try testing.expectEqual(layout.Kind.fat16, volume.kind);
    try fill(&volume, 5);

    const want = try plan(&volume, 60_000);
    try apply(&volume, want);

    var after = try card.mount();
    try testing.expectEqual(layout.Kind.fat16, after.kind);
    try expectFilled(&after, 5);
    try testing.expect((try check.run(&after, testing.allocator, .{})).quiet());
}

test "a grow that would take a volume past its width is refused" {
    const card = try Card.init(testing.allocator, 4_000_000);
    defer card.deinit();
    try format.write(&card.dev, try layout.plan(20_000, .{ .kind = .fat16 }));

    var volume = try card.mount();
    try testing.expectError(error.TooSmall, plan(&volume, 4_000_000));
}

test "data moving onto where it already is arrives intact" {
    // The case the order of the move exists for. When there is more data than
    // the tables grow by, the place a cluster is going is a place another
    // cluster still occupies. Going from the top down is what makes that
    // safe, and a volume with only a few files never reaches it.
    const gpa = testing.allocator;
    const card = try Card.init(gpa, 150_000);
    defer card.deinit();
    try format.write(&card.dev, try layout.plan(70_000, .{ .kind = .fat32 }));

    // A pattern that differs every sector, so a sector landing at the wrong
    // offset is caught rather than matching its neighbour.
    const size = 1_500_000;
    const body = try gpa.alloc(u8, size);
    defer gpa.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i / layout.SECTOR);

    var volume = try card.mount();
    var entry = try fat.createFile(&volume, fat.rootIterator(&volume), "big.bin", 0);
    try testing.expectEqual(size, try fat.writeAt(&volume, &entry, 0, body));
    try fat.commit(&volume, entry, 0);

    const want = try plan(&volume, 150_000);
    // More data than the move shifts by, which is what makes it overlap.
    try testing.expect(want.moving * want.from.sectors_per_cluster > want.shift);
    try apply(&volume, want);

    var after = try card.mount();
    const found = try fat.lookupPath(&after, "big.bin");
    try testing.expectEqual(@as(u32, size), found.size);

    const read = try gpa.alloc(u8, size);
    defer gpa.free(read);
    try testing.expectEqual(size, try fat.readFile(&after, found, read));
    try testing.expectEqualSlices(u8, body, read);

    try testing.expect((try check.run(&after, gpa, .{})).quiet());
}
