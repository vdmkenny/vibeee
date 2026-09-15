//! Checking a volume and repairing what can be repaired.
//!
//! FAT records the same fact twice. A directory record holds a file's first
//! cluster and its size in bytes; the allocation table holds which clusters
//! are in use. Writing a file updates both, and nothing keeps them
//! consistent if power is lost between the two writes.
//!
//! `fat.zig` orders its writes as data, then chain, then record. Interrupted,
//! that leaves clusters marked used that no record names. The data in them
//! was never reachable, so nothing is lost; the space is, because nothing
//! will free it. Power loss is common on this machine, so it accumulates.
//!
//! This walks both sides and compares them. Every chain reachable from the
//! root is followed and its clusters marked, then the table is swept for
//! clusters marked used that the walk did not reach. Those are freed. A
//! chain longer than its record's size is cut back, a size larger than its
//! chain is reduced, and a chain that leaves the volume is ended at the last
//! valid cluster. `fat/verdict.zig` decides which of those applies.
//!
//! It does not guess. A cluster claimed by two chains cannot be assigned to
//! one without taking it from the other, and the medium does not record
//! which is correct. Those are counted and reported, and the caller should
//! keep the volume read-only rather than let further writes compound the
//! damage. The card can then be repaired on another machine, which is part
//! of why this filesystem was chosen.
//!
//! Memory use is proportional to the volume's size, not its contents: a bit
//! per cluster and a fixed stack of open directories. Every loop here is
//! bounded by the cluster count, so a corrupt volume costs one sweep rather
//! than hanging the machine.

const std = @import("std");
const block = @import("../block.zig");
const fat = @import("../fat.zig");
const table = @import("alloc.zig");
const verdict = @import("verdict.zig");

const Volume = fat.Volume;

/// How deep the walk goes. This system's longest path is shorter than this,
/// but a volume formatted elsewhere may nest further; anything below this
/// depth is left alone rather than walked on a stack that has run out.
const MAX_DEPTH = 32;

/// The number the format gives a volume's first cluster. Entries zero and
/// one are reserved, so a cluster's index in the bit set is its number less
/// this.
const FIRST_CLUSTER = 2;

pub const Error = fat.Error || std.mem.Allocator.Error;

/// What a check found, and what it did about it.
///
/// The shape is `lib/syscalls.zig`'s, because `check` prints exactly what is
/// counted here and two descriptions of it would drift.
pub const Findings = @import("lib").syscalls.CheckReport;

pub const Options = struct {
    /// Apply repairs. Off reports and writes nothing, which is what a
    /// volume mounted read-only gets.
    repair: bool = true,
};

/// Check `vol`, repairing if asked, and say what was found.
pub fn run(vol: *Volume, gpa: std.mem.Allocator, options: Options) Error!Findings {
    var found = Findings{};

    // First, because everything below reads the first copy and trusts it.
    // Power lost between the two writes of one entry is what leaves the
    // copies differing.
    found.mirrored = try mirrorCopies(vol, options.repair);

    // One bit per cluster. The sweep needs to know whether the walk reached
    // each cluster, and nothing smaller can record that.
    var reached = try std.DynamicBitSetUnmanaged.initEmpty(gpa, vol.cluster_count);
    defer reached.deinit(gpa);

    // On the heap: an iterator holds a sector buffer, and thirty-two of
    // them is more stack than a kernel thread has.
    const stack = try gpa.alloc(fat.Iterator, MAX_DEPTH);
    defer gpa.free(stack);

    var walk = Walk{ .vol = vol, .reached = &reached, .found = &found, .repair = options.repair };
    try walk.tree(stack);
    try walk.sweep();

    // Every free above kept the count in step, but after a repair it is
    // safer to recount than to trust the running total.
    if (!found.quiet()) vol.fat.free_known = null;

    return found;
}

/// Copy the first allocation table over every other copy.
///
/// A volume normally carries two. `fat/alloc.zig` writes every copy on every
/// store, so they differ only if a write was interrupted between them.
/// Everything here reads the first, so the first is what the others are set
/// to.
fn mirrorCopies(vol: *Volume, repair: bool) fat.Error!u32 {
    if (vol.fat_count < 2) return 0;

    var differing: u32 = 0;
    var first: [block.SECTOR_SIZE]u8 = undefined;
    var other: [block.SECTOR_SIZE]u8 = undefined;

    var sector: u32 = 0;
    while (sector < vol.sectors_per_fat) : (sector += 1) {
        vol.dev.read(vol.first_fat_sector + sector, &first) catch return error.Io;

        var copy: u32 = 1;
        while (copy < vol.fat_count) : (copy += 1) {
            const at = vol.first_fat_sector + copy * vol.sectors_per_fat + sector;
            vol.dev.read(at, &other) catch return error.Io;
            if (std.mem.eql(u8, &first, &other)) continue;

            differing += 1;
            if (repair) vol.dev.write(at, &first) catch return error.Io;
        }
    }
    return differing;
}

const Walk = struct {
    vol: *Volume,
    /// Which clusters the walk reached, indexed from the volume's first
    /// cluster.
    reached: *std.DynamicBitSetUnmanaged,
    found: *Findings,
    repair: bool,

    fn mark(self: *Walk, cluster: u32) void {
        self.reached.set(cluster - FIRST_CLUSTER);
    }

    fn marked(self: *const Walk, cluster: u32) bool {
        return self.reached.isSet(cluster - FIRST_CLUSTER);
    }

    fn valid(self: *const Walk, cluster: u32) bool {
        return cluster >= FIRST_CLUSTER and cluster - FIRST_CLUSTER < self.vol.cluster_count;
    }

    fn writable(self: *const Walk) bool {
        return self.repair and !self.vol.dev.read_only;
    }

    /// Walk every directory reachable from the root, marking what each
    /// record claims and putting right what can be.
    fn tree(self: *Walk, stack: []fat.Iterator) fat.Error!void {
        // No directory record names the root, so its chain is marked here
        // or the sweep would reclaim the root directory. FAT12 and FAT16
        // keep the root in a fixed run of sectors with no cluster numbers.
        if (self.vol.kind == .fat32) {
            _ = try self.follow(self.vol.root_cluster, 0, true);
        }

        stack[0] = fat.rootIterator(self.vol);
        var depth: usize = 0;

        while (true) {
            const entry = stack[depth].next() catch |err| switch (err) {
                // Stop reading a directory whose chain is damaged rather
                // than failing the whole check. The damage is already
                // counted against the record that named it.
                error.CorruptChain => null,
                else => |e| return e,
            };

            const it = entry orelse {
                if (depth == 0) return;
                depth -= 1;
                continue;
            };

            const name = it.nameSlice();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            const answer = try self.inspect(it);

            if (!it.is_dir) continue;
            if (answer == .contested) continue;
            if (it.cluster == 0) continue;

            if (depth + 1 >= stack.len) {
                self.found.too_deep += 1;
                continue;
            }
            depth += 1;
            stack[depth] = fat.iterate(self.vol, it);
        }
    }

    /// Account for one record's clusters and repair any difference.
    ///
    /// Reading the chain and writing the repair happen here. Which repair
    /// applies is `fat/verdict.zig`'s, so that each case can be tested
    /// without a volume damaged to reach it.
    fn inspect(self: *Walk, entry: fat.Entry) fat.Error!verdict.Verdict {
        var record = entry;
        const cluster_size = self.vol.clusterSize();
        const claim = verdict.Claim{
            .is_dir = record.is_dir,
            .size = record.size,
            .first = record.cluster,
            .cluster_size = cluster_size,
        };

        const chain = if (record.cluster == 0)
            verdict.Chain{}
        else if (!self.valid(record.cluster))
            verdict.Chain{ .outcome = .strayed }
        else
            try self.follow(record.cluster, verdict.clustersFor(claim.size, cluster_size), record.is_dir);

        const answer = verdict.decide(claim, chain);
        switch (answer) {
            .agree => return answer,
            .contested => self.found.crossed += 1,
            .claims_nothing => self.found.resized += 1,
            .runs_short => self.found.resized += 1,
            .begins_nowhere, .breaks_at => {
                self.found.broken += 1;
                self.found.trimmed += 1;
            },
            .runs_long, .holds_unclaimed => self.found.trimmed += 1,
        }

        if (self.writable()) try self.apply(&record, answer, cluster_size);
        return answer;
    }

    /// Carry a verdict out on the medium.
    fn apply(self: *Walk, record: *fat.Entry, answer: verdict.Verdict, cluster_size: u32) fat.Error!void {
        switch (answer) {
            // Nothing to do, or nothing that can be done without guessing.
            .agree, .contested => {},

            // The record keeps no chain. Either it never named one that
            // could be followed, or its size accounts for none of what it
            // names, in which case the chain is freed first.
            .holds_unclaimed => {
                try table.freeChain(&self.vol.fat, record.cluster);
                try self.forget(record);
            },
            .begins_nowhere => try self.forget(record),

            .claims_nothing => {
                record.size = 0;
                try fat.commit(self.vol, record.*, record.mtime);
            },
            .runs_short => |clusters| {
                record.size = clusters * cluster_size;
                try fat.commit(self.vol, record.*, record.mtime);
            },
            // A chain that broke keeps every cluster walked, and the link
            // that broke it leads either off the volume or back into the
            // part being kept. Freeing what it points at would give away a
            // cluster of this same file.
            .breaks_at => |cut| try self.endAfter(record, cut, cluster_size, .keep),
            // A chain that ran long points at a tail belonging to nothing
            // else, which is the whole reason it is being cut.
            .runs_long => |cut| try self.endAfter(record, cut, cluster_size, .free),
        }
    }

    /// Point a record at nothing at all.
    fn forget(self: *Walk, record: *fat.Entry) fat.Error!void {
        record.cluster = 0;
        record.size = 0;
        record.forgetWalk();
        try fat.commit(self.vol, record.*, record.mtime);
    }

    /// Whether what follows the cut is this record's to give back.
    const Tail = enum { free, keep };

    /// End a record's chain after one cluster and set its size to match.
    ///
    /// The link is read before the cut and the tail freed after it. A
    /// failure between the two leaves clusters nothing points at, which the
    /// sweep reclaims; it never leaves a record naming freed clusters.
    fn endAfter(
        self: *Walk,
        record: *fat.Entry,
        cut: verdict.Cut,
        cluster_size: u32,
        tail_is: Tail,
    ) fat.Error!void {
        if (!self.valid(cut.after)) return;

        const tail = try table.get(&self.vol.fat, cut.after);
        try table.set(&self.vol.fat, cut.after, table.sentinels(self.vol.kind).terminator);
        if (tail_is == .free and self.valid(tail)) try table.freeChain(&self.vol.fat, tail);

        if (!record.is_dir) record.size = cut.clusters * cluster_size;
        record.forgetWalk();
        try fat.commit(self.vol, record.*, record.mtime);
    }

    /// Follow a chain from `first`, marking every cluster it claims.
    ///
    /// `needed` is how many clusters the record accounts for, so the cluster
    /// the chain should end at is recorded during the walk rather than found
    /// by a second one. `whole` ignores it and follows to the end, for a
    /// directory, which has no size to compare against.
    fn follow(self: *Walk, first: u32, needed: u32, whole: bool) fat.Error!verdict.Chain {
        var chain = verdict.Chain{};
        var cluster = first;

        while (true) {
            if (!self.valid(cluster)) {
                chain.outcome = .strayed;
                return chain;
            }

            if (self.marked(cluster)) {
                // Whether the cluster is this chain's own decides whether
                // the damage can be repaired. The walk that answers it runs
                // only on a volume where this has already happened.
                chain.outcome = if (try self.inChain(first, cluster, chain.length))
                    .looped
                else
                    .crossed;
                return chain;
            }

            self.mark(cluster);
            chain.length += 1;
            chain.last = cluster;
            if (!whole and chain.length == needed) chain.cut_after = cluster;

            // No valid chain is longer than the volume has clusters. The
            // bound keeps a corrupt table to a single sweep.
            if (chain.length > self.vol.cluster_count) {
                chain.outcome = .looped;
                return chain;
            }

            const value = try table.get(&self.vol.fat, cluster);
            if (value >= table.sentinels(self.vol.kind).end_from) return chain;
            cluster = value;
        }
    }

    /// Whether `target` is among the first `steps` clusters from `first`.
    ///
    /// Called only when a chain reaches a cluster something already claims,
    /// to tell a chain that looped back on itself from two records claiming
    /// one cluster. The first can be cut; the second cannot be decided.
    fn inChain(self: *Walk, first: u32, target: u32, steps: u32) fat.Error!bool {
        var cluster = first;
        var walked: u32 = 0;
        while (walked < steps) : (walked += 1) {
            if (cluster == target) return true;
            if (!self.valid(cluster)) return false;
            const value = try table.get(&self.vol.fat, cluster);
            if (value >= table.sentinels(self.vol.kind).end_from) return false;
            cluster = value;
        }
        return false;
    }

    /// Free every cluster the table marks used that the walk did not reach.
    ///
    /// No record points at them, so nothing can read them. Clusters a
    /// formatter marked defective are left alone: that is the one non-zero
    /// value which is meant to belong to no file.
    fn sweep(self: *Walk) fat.Error!void {
        // Unreached means lost only if everything reachable was reached. A
        // subtree too deep to enter makes the sweep's answer unsound.
        if (self.found.too_deep != 0) return;

        const bad = table.sentinels(self.vol.kind).bad;
        var cluster: u32 = FIRST_CLUSTER;
        while (cluster < self.vol.cluster_count + FIRST_CLUSTER) : (cluster += 1) {
            const value = try table.get(&self.vol.fat, cluster);
            if (value == 0 or value == bad) continue;
            if (self.marked(cluster)) continue;

            self.found.lost += 1;
            if (self.writable()) {
                try table.set(&self.vol.fat, cluster, 0);
                self.found.reclaimed += 1;
            }
        }
    }
};

const testing = std.testing;

/// A FAT32 volume in memory.
///
/// Built through the driver's own calls, so its contents are correct by
/// construction and each test damages exactly one thing. Small enough that a
/// table is a single sector, which is what keeps the mirror test cheap.
const Image = struct {
    gpa: std.mem.Allocator,
    bytes: []u8,
    fat_count: u8,
    dev: block.Device = undefined,

    const RESERVED = 1;
    const FAT_SECTORS = 1;
    const CLUSTERS = 60;
    /// The entry the format requires at the front of the table, holding the
    /// media descriptor in its low byte and ones above it.
    const MEDIA_ENTRY: u32 = 0x0FFF_FFF8;
    const BOOT_SIGNATURE: u16 = 0xAA55;

    fn readSectors(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
        const self: *Image = @ptrCast(@alignCast(ctx));
        const at = lba * block.SECTOR_SIZE;
        if (at + buf.len > self.bytes.len) return error.OutOfRange;
        @memcpy(buf, self.bytes[at..][0..buf.len]);
    }

    fn writeSectors(ctx: *anyopaque, lba: u64, buf: []const u8) block.Error!void {
        const self: *Image = @ptrCast(@alignCast(ctx));
        const at = lba * block.SECTOR_SIZE;
        if (at + buf.len > self.bytes.len) return error.OutOfRange;
        @memcpy(self.bytes[at..][0..buf.len], buf);
    }

    const ops = block.Ops{ .read = &readSectors, .write = &writeSectors };

    fn init(gpa: std.mem.Allocator, fat_count: u8) !*Image {
        const total = RESERVED + @as(u32, fat_count) * FAT_SECTORS + CLUSTERS;
        const self = try gpa.create(Image);
        self.* = .{
            .gpa = gpa,
            .bytes = try gpa.alloc(u8, total * block.SECTOR_SIZE),
            .fat_count = fat_count,
        };
        @memset(self.bytes, 0);
        self.dev = .{ .name = "mem", .ctx = self, .ops = &ops, .sectors = total };

        const bpb: *align(1) fat.Bpb = @ptrCast(&self.bytes[0]);
        bpb.* = .{
            .jump = .{ 0xEB, 0x58, 0x90 },
            .oem = "vibeee  ".*,
            .bytes_per_sector = block.SECTOR_SIZE,
            .sectors_per_cluster = 1,
            .reserved_sectors = RESERVED,
            .fat_count = fat_count,
            // Both zero is what makes the volume FAT32 rather than smaller.
            .root_entries = 0,
            .sectors_per_fat_16 = 0,
            .total_sectors_16 = 0,
            .media = 0xF8,
            .sectors_per_track = 0,
            .heads = 0,
            .hidden_sectors = 0,
            .total_sectors_32 = total,
            .sectors_per_fat_32 = FAT_SECTORS,
            .ext_flags = 0,
            .version = 0,
            .root_cluster = 2,
            .fs_info = 0,
            .backup_boot = 0,
        };
        std.mem.writeInt(u16, self.bytes[510..512], BOOT_SIGNATURE, .little);

        self.put(0, MEDIA_ENTRY);
        self.put(1, table.sentinels(.fat32).terminator);
        // The root directory is one cluster, allocated and ended.
        self.put(2, table.sentinels(.fat32).terminator);
        return self;
    }

    fn deinit(self: *Image) void {
        self.gpa.free(self.bytes);
        self.gpa.destroy(self);
    }

    /// Write a table entry into every copy, without going through the
    /// driver: these tests damage a volume, which the driver will not do.
    ///
    /// A volume damaged this way must be mounted again before it is checked.
    /// The driver caches one sector of the table, and a write behind it is
    /// answered from the cache rather than from the medium.
    fn put(self: *Image, cluster: u32, value: u32) void {
        var copy: u32 = 0;
        while (copy < self.fat_count) : (copy += 1) {
            const sector = RESERVED + copy * FAT_SECTORS;
            const at = sector * block.SECTOR_SIZE + cluster * 4;
            std.mem.writeInt(u32, self.bytes[at..][0..4], value, .little);
        }
    }

    fn volume(self: *Image) !fat.Volume {
        return fat.mount(&self.dev);
    }
};

/// A file of `size` bytes in the root, through the calls that make one.
fn makeFile(vol: *fat.Volume, name: []const u8, size: u32) !fat.Entry {
    var entry = try fat.createFile(vol, fat.rootIterator(vol), name, 0);
    try fat.resize(vol, &entry, size, 0);
    return entry;
}

fn find(vol: *fat.Volume, name: []const u8) !fat.Entry {
    return fat.lookupIn(fat.rootIterator(vol), name);
}

test "a volume nothing is wrong with is left alone" {
    const image = try Image.init(testing.allocator, 1);
    defer image.deinit();
    var vol = try image.volume();
    _ = try makeFile(&vol, "a.txt", 900);
    _ = try makeFile(&vol, "b.txt", 100);

    const found = try run(&vol, testing.allocator, .{});
    try testing.expect(found.quiet());
    try testing.expect(found.sound());
}

test "a cluster nothing points at is given back" {
    const image = try Image.init(testing.allocator, 1);
    defer image.deinit();
    var vol = try image.volume();
    _ = try makeFile(&vol, "a.txt", 100);

    // What an interrupted write leaves: a cluster marked used before the
    // record that would have named it was written.
    image.put(30, table.sentinels(.fat32).terminator);
    vol = try image.volume();

    const found = try run(&vol, testing.allocator, .{});
    try testing.expectEqual(@as(u32, 1), found.lost);
    try testing.expectEqual(@as(u32, 1), found.reclaimed);
    try testing.expectEqual(@as(u32, 0), try table.get(&vol.fat, 30));
}

test "a cluster the medium cannot hold data in is not given back" {
    const image = try Image.init(testing.allocator, 1);
    defer image.deinit();
    var vol = try image.volume();

    const bad = table.sentinels(.fat32).bad;
    image.put(30, bad);
    vol = try image.volume();

    const found = try run(&vol, testing.allocator, .{});
    try testing.expect(found.quiet());
    try testing.expectEqual(bad, try table.get(&vol.fat, 30));
}

test "a chain longer than its record is cut back to it" {
    const image = try Image.init(testing.allocator, 1);
    defer image.deinit();
    var vol = try image.volume();
    const entry = try makeFile(&vol, "a.txt", 512);

    // Two more clusters hung off the end, the record still saying one.
    const first = entry.cluster;
    const tail = try table.alloc(&vol.fat);
    const further = try table.alloc(&vol.fat);
    try table.set(&vol.fat, first, tail);
    try table.set(&vol.fat, tail, further);
    vol = try image.volume();

    const found = try run(&vol, testing.allocator, .{});
    try testing.expectEqual(@as(u32, 1), found.trimmed);
    try testing.expectEqual(@as(u32, 0), found.lost);
    try testing.expectEqual(table.sentinels(.fat32).terminator, try table.get(&vol.fat, first));
    try testing.expectEqual(@as(u32, 0), try table.get(&vol.fat, tail));
    try testing.expectEqual(@as(u32, 0), try table.get(&vol.fat, further));
}

test "a record claiming more than its chain holds is brought down" {
    const image = try Image.init(testing.allocator, 1);
    defer image.deinit();
    var vol = try image.volume();
    var entry = try makeFile(&vol, "a.txt", 512);

    entry.size = 4096;
    try fat.commit(&vol, entry, 0);
    vol = try image.volume();

    const found = try run(&vol, testing.allocator, .{});
    try testing.expectEqual(@as(u32, 1), found.resized);

    const after = try find(&vol, "a.txt");
    try testing.expectEqual(@as(u32, 512), after.size);
}

test "a chain leaving the volume is ended at the last cluster on it" {
    const image = try Image.init(testing.allocator, 1);
    defer image.deinit();
    var vol = try image.volume();
    var entry = try makeFile(&vol, "a.txt", 1024);
    _ = &entry;

    // The second cluster now points past the end of the volume.
    const second = (try table.next(&vol.fat, entry.cluster)).?;
    image.put(second, 5000);
    vol = try image.volume();

    const found = try run(&vol, testing.allocator, .{});
    try testing.expectEqual(@as(u32, 1), found.broken);
    try testing.expectEqual(@as(u32, 1), found.trimmed);
    try testing.expectEqual(table.sentinels(.fat32).terminator, try table.get(&vol.fat, second));

    const after = try find(&vol, "a.txt");
    try testing.expectEqual(@as(u32, 1024), after.size);
}

test "cutting a chain that loops does not give away its own clusters" {
    // The trap in the loop case: the link that closes the loop points back
    // into the part of the chain being kept, so freeing what follows the cut
    // would take a cluster of this same file.
    const image = try Image.init(testing.allocator, 1);
    defer image.deinit();
    var vol = try image.volume();
    var entry = try makeFile(&vol, "a.txt", 1024);
    _ = &entry;

    const first = entry.cluster;
    const second = (try table.next(&vol.fat, first)).?;
    image.put(second, first);
    vol = try image.volume();

    _ = try run(&vol, testing.allocator, .{});

    // Both clusters are still the file's, and the chain now ends.
    const after = try find(&vol, "a.txt");
    try testing.expectEqual(first, after.cluster);
    try testing.expectEqual(second, (try table.next(&vol.fat, first)).?);
    try testing.expectEqual(@as(?u32, null), try table.next(&vol.fat, second));

    // And a second check finds nothing left to do.
    const again = try run(&vol, testing.allocator, .{});
    try testing.expect(again.quiet());
}

test "a chain that turns back on itself is cut where it does" {
    const image = try Image.init(testing.allocator, 1);
    defer image.deinit();
    var vol = try image.volume();
    var entry = try makeFile(&vol, "a.txt", 1024);
    _ = &entry;

    // The second cluster points back at the first.
    const second = (try table.next(&vol.fat, entry.cluster)).?;
    image.put(second, entry.cluster);
    vol = try image.volume();

    const found = try run(&vol, testing.allocator, .{});
    try testing.expectEqual(@as(u32, 1), found.broken);
    try testing.expectEqual(@as(u32, 0), found.crossed);
    try testing.expect(found.sound());
    try testing.expectEqual(table.sentinels(.fat32).terminator, try table.get(&vol.fat, second));
}

test "a cluster two files claim is reported and not touched" {
    const image = try Image.init(testing.allocator, 1);
    defer image.deinit();
    var vol = try image.volume();
    var first = try makeFile(&vol, "a.txt", 512);
    const second = try makeFile(&vol, "b.txt", 512);

    // Point the first file at the second's cluster as well.
    const shared = second.cluster;
    first.cluster = shared;
    try fat.commit(&vol, first, 0);
    vol = try image.volume();

    const found = try run(&vol, testing.allocator, .{});
    try testing.expectEqual(@as(u32, 1), found.crossed);
    try testing.expect(!found.sound());

    // The shared cluster is still where it was, and still ends its chain.
    try testing.expectEqual(table.sentinels(.fat32).terminator, try table.get(&vol.fat, shared));
    const after = try find(&vol, "a.txt");
    try testing.expectEqual(shared, after.cluster);
}

test "tables that disagree are brought back into step" {
    const image = try Image.init(testing.allocator, 2);
    defer image.deinit();
    var vol = try image.volume();
    _ = try makeFile(&vol, "a.txt", 512);

    // Power lost between the two writes of one entry leaves the second copy
    // holding what the first held before.
    const second_fat = Image.RESERVED + Image.FAT_SECTORS;
    const at = second_fat * block.SECTOR_SIZE + 3 * 4;
    std.mem.writeInt(u32, image.bytes[at..][0..4], 0, .little);
    vol = try image.volume();

    const found = try run(&vol, testing.allocator, .{});
    try testing.expect(found.mirrored > 0);

    const first_copy = image.bytes[Image.RESERVED * block.SECTOR_SIZE ..][0..block.SECTOR_SIZE];
    const other_copy = image.bytes[second_fat * block.SECTOR_SIZE ..][0..block.SECTOR_SIZE];
    try testing.expectEqualSlices(u8, first_copy, other_copy);
}

test "a check that is not repairing reports and writes nothing" {
    const image = try Image.init(testing.allocator, 1);
    defer image.deinit();
    var vol = try image.volume();
    _ = try makeFile(&vol, "a.txt", 100);
    image.put(30, table.sentinels(.fat32).terminator);
    vol = try image.volume();

    const before = try testing.allocator.dupe(u8, image.bytes);
    defer testing.allocator.free(before);

    const found = try run(&vol, testing.allocator, .{ .repair = false });
    try testing.expectEqual(@as(u32, 1), found.lost);
    try testing.expectEqual(@as(u32, 0), found.reclaimed);
    try testing.expectEqualSlices(u8, before, image.bytes);
}

test "a directory is walked, and what hangs below it is accounted for" {
    const image = try Image.init(testing.allocator, 1);
    defer image.deinit();
    var vol = try image.volume();

    const dir = try fat.createDirectory(&vol, fat.rootIterator(&vol), "sub", 0);
    var inner = try fat.createFile(&vol, fat.iterate(&vol, dir), "deep.txt", 0);
    try fat.resize(&vol, &inner, 900, 0);

    // A file below the root is reached, so none of its clusters read as lost.
    const found = try run(&vol, testing.allocator, .{});
    try testing.expect(found.quiet());
    try testing.expectEqual(@as(u32, 0), found.lost);
}

/// A boot sector built field by field, for asking what `mount` makes of one
/// no formatter would produce.
fn craft(bytes: []u8, changes: fat.Bpb) void {
    @memset(bytes, 0);
    const bpb: *align(1) fat.Bpb = @ptrCast(&bytes[0]);
    bpb.* = changes;
    std.mem.writeInt(u16, bytes[510..512], Image.BOOT_SIGNATURE, .little);
}

/// The fields a plausible volume has, for a case to change one of.
fn plausible() fat.Bpb {
    return .{
        .jump = .{ 0xEB, 0x58, 0x90 },
        .oem = "crafted ".*,
        .bytes_per_sector = block.SECTOR_SIZE,
        .sectors_per_cluster = 1,
        .reserved_sectors = 1,
        .fat_count = 2,
        .root_entries = 0,
        .sectors_per_fat_16 = 0,
        .total_sectors_16 = 0,
        .media = 0xF8,
        .sectors_per_track = 0,
        .heads = 0,
        .hidden_sectors = 0,
        .total_sectors_32 = 64,
        .sectors_per_fat_32 = 1,
        .ext_flags = 0,
        .version = 0,
        .root_cluster = 2,
        .fs_info = 0,
        .backup_boot = 0,
    };
}

test "a boot sector no formatter would write is refused, not trapped on" {
    // A boot sector is bytes off a medium anybody can write. Each of these
    // is a field pushed to where the arithmetic over it stops being
    // arithmetic, and each must come back as an answer.
    const gpa = testing.allocator;
    const bytes = try gpa.alloc(u8, 4 * block.SECTOR_SIZE);
    defer gpa.free(bytes);

    var fake = Image{ .gpa = gpa, .bytes = bytes, .fat_count = 1 };
    fake.dev = .{ .name = "crafted", .ctx = &fake, .ops = &Image.ops, .sectors = 4 };

    const cases = [_]struct { what: []const u8, bpb: fat.Bpb }{
        .{ .what = "tables whose total size does not fit in thirty-two bits", .bpb = blk: {
            var b = plausible();
            b.fat_count = 16;
            b.sectors_per_fat_32 = 0x1000_0000;
            break :blk b;
        } },
        .{ .what = "one table larger than the volume", .bpb = blk: {
            var b = plausible();
            b.sectors_per_fat_32 = std.math.maxInt(u32);
            break :blk b;
        } },
        .{ .what = "more reserved sectors than there are sectors", .bpb = blk: {
            var b = plausible();
            b.reserved_sectors = std.math.maxInt(u16);
            break :blk b;
        } },
        .{ .what = "a root directory larger than the volume", .bpb = blk: {
            var b = plausible();
            b.root_entries = std.math.maxInt(u16);
            b.sectors_per_fat_16 = 1;
            break :blk b;
        } },
        .{ .what = "no tables at all", .bpb = blk: {
            var b = plausible();
            b.fat_count = 0;
            break :blk b;
        } },
        .{ .what = "a cluster that is not a power of two", .bpb = blk: {
            var b = plausible();
            b.sectors_per_cluster = 3;
            break :blk b;
        } },
        .{ .what = "a root at a cluster the volume does not have", .bpb = blk: {
            var b = plausible();
            b.root_cluster = std.math.maxInt(u32);
            break :blk b;
        } },
        .{ .what = "a root below the first cluster there is", .bpb = blk: {
            var b = plausible();
            b.root_cluster = 1;
            break :blk b;
        } },
    };

    for (cases) |case| {
        craft(bytes, case.bpb);
        const volume = fat.mount(&fake.dev) catch continue;
        // Mounted rather than refused is allowed, but then everything it
        // says about itself has to be inside the medium it came from.
        try testing.expect(volume.first_data_sector <= fake.dev.sectors);
        try testing.expect(volume.cluster_count <= fake.dev.sectors);
    }
}
