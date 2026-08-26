//! FAT12/16/32: volumes, directories and files.
//!
//! The only on-disk filesystem vibeee uses (design/00-vibeee.md §7). The
//! decisive property is not performance: it is that any other machine can read
//! the card. On hardware this old, being able to pull the SD out and fix it
//! elsewhere is worth more than anything a private format would buy.
//!
//! All three widths are handled because they differ only in how a FAT entry is
//! fetched. The directory and cluster-chain logic above that is identical, so
//! supporting FAT16 costs a branch rather than a second driver, and the part
//! that differs is confined to `fat/alloc.zig`.
//!
//! Creating a file writes a short 8.3 name. Long names are read but not
//! written: producing them means generating VFAT records and a unique `~1`
//! alias, and a wrong alias makes other systems disagree about what a file is
//! called.

const std = @import("std");
const block = @import("block.zig");
const civil = @import("lib").civil;
const table = @import("fat/alloc.zig");

pub const Error = error{
    NotFat,
    Unsupported,
    NotFound,
    IsDirectory,
    NotDirectory,
    Exists,
    NotEmpty,
    NameTooLong,
} || table.Error;

pub const Kind = table.Kind;

/// BIOS Parameter Block. Field order is fixed by the on-disk format.
const Bpb = extern struct {
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

const ATTR_READ_ONLY = 0x01;
const ATTR_HIDDEN = 0x02;
const ATTR_SYSTEM = 0x04;
const ATTR_VOLUME_ID = 0x08;
const ATTR_DIRECTORY = 0x10;
const ATTR_LONG_NAME = ATTR_READ_ONLY | ATTR_HIDDEN | ATTR_SYSTEM | ATTR_VOLUME_ID;

const DirEntry = extern struct {
    name: [11]u8,
    attr: u8,
    nt_reserved: u8,
    create_tenths: u8,
    create_time: u16 align(1),
    create_date: u16 align(1),
    access_date: u16 align(1),
    cluster_high: u16 align(1),
    write_time: u16 align(1),
    write_date: u16 align(1),
    cluster_low: u16 align(1),
    size: u32 align(1),

    fn firstCluster(self: *const DirEntry) u32 {
        return (@as(u32, self.cluster_high) << 16) | self.cluster_low;
    }
};

/// FAT packs a timestamp into two 16-bit words: the date as year-since-1980,
/// month and day; the time as hour, minute and *half* seconds. The odd
/// resolution is the format's, not ours.
///
/// The format records no timezone. Every implementation writes whatever its
/// local clock says and every reader takes it at face value, so a stamp is a
/// wall-clock reading whose zone is unknowable. We read and write ours as UTC,
/// which is self-consistent and makes files we create agree with our own clock;
/// a volume written elsewhere will be off by that machine's offset, and no
/// amount of care here can recover it.
const FatStamp = struct { date: u16, time: u16 };

fn epochFromFat(date: u16, time: u16) i64 {
    // An all-zero date is what a formatter writes when it has no clock. There
    // is no such day as 1980-00-00, so it cannot be confused with a real one.
    if (date == 0) return 0;

    return civil.toEpoch(.{
        .year = 1980 + (date >> 9),
        .month = @intCast((date >> 5) & 0x0F),
        .day = @intCast(date & 0x1F),
        .hour = @intCast(time >> 11),
        .minute = @intCast((time >> 5) & 0x3F),
        .second = @intCast((time & 0x1F) * 2),
    });
}

/// The inverse, for stamping entries the write path creates.
///
/// Dates before 1980 cannot be represented, so they clamp to the format's
/// epoch rather than wrapping into a plausible-looking wrong year.
fn fatFromEpoch(seconds: i64) FatStamp {
    const c = civil.fromEpoch(seconds);
    if (c.year < 1980 or c.year > 2107) return .{ .date = 0, .time = 0 };

    return .{
        .date = (@as(u16, c.year - 1980) << 9) |
            (@as(u16, c.month) << 5) |
            @as(u16, c.day),
        .time = (@as(u16, c.hour) << 11) |
            (@as(u16, c.minute) << 5) |
            @as(u16, c.second / 2),
    };
}

/// Long names are capped rather than allowed the full 255 UTF-16 characters
/// the format permits: an Entry is passed by value, and 255 characters of
/// UTF-8 would make every directory step copy half a kilobyte.
pub const MAX_NAME = 128;

pub const Entry = struct {
    name: [MAX_NAME]u8,
    name_len: usize,
    is_dir: bool,
    size: u32,
    cluster: u32,
    /// Seconds since the Unix epoch, or 0 when the entry carries no date.
    /// Normalised here so nothing above this layer has to know FAT packs a
    /// timestamp into two 16-bit words with a 1980 epoch and 2-second
    /// resolution.
    mtime: i64 = 0,

    /// Where this entry's 32-byte record lives on disk: the sector, and which
    /// record within it. Recorded at lookup so that changing a file's size or
    /// timestamp is one sector read and write, rather than a second walk of
    /// the directory to find the record again. Zero for the synthetic entry
    /// that stands for a volume's root.
    dir_sector: u32 = 0,
    dir_index: u32 = 0,

    pub fn nameSlice(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Volume = struct {
    dev: *const block.Device,
    kind: Kind,
    bytes_per_sector: u32,
    sectors_per_cluster: u32,
    first_fat_sector: u32,
    sectors_per_fat: u32,
    fat_count: u32,
    /// FAT12/16 only: the fixed-size root directory.
    root_dir_sector: u32,
    root_dir_sectors: u32,
    /// FAT32 only.
    root_cluster: u32,
    first_data_sector: u32,
    cluster_count: u32,

    /// The FAT table itself, and everything that knows how the three widths
    /// differ. See `fat/alloc.zig`.
    fat: table.Table = undefined,

    pub fn clusterSize(self: *const Volume) u32 {
        return self.bytes_per_sector * self.sectors_per_cluster;
    }

    fn firstSectorOfCluster(self: *const Volume, cluster: u32) u32 {
        return self.first_data_sector + (cluster - 2) * self.sectors_per_cluster;
    }

    /// Follow the allocation chain one link.
    fn nextCluster(self: *Volume, cluster: u32) Error!?u32 {
        return table.next(&self.fat, cluster);
    }
};

/// Recognise and describe the filesystem on `dev`.
pub fn mount(dev: *const block.Device) Error!Volume {
    var sector: [block.SECTOR_SIZE]u8 = undefined;
    dev.read(0, &sector) catch return error.Io;

    const bpb: *align(1) const Bpb = @ptrCast(&sector);

    if (std.mem.readInt(u16, sector[510..512], .little) != 0xAA55) return error.NotFat;
    if (bpb.bytes_per_sector != block.SECTOR_SIZE) return error.Unsupported;
    if (bpb.sectors_per_cluster == 0 or bpb.fat_count == 0) return error.NotFat;
    // Must be a power of two, or cluster arithmetic below is wrong.
    if (bpb.sectors_per_cluster & (bpb.sectors_per_cluster - 1) != 0) return error.Unsupported;

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

    const root_dir_sectors = (@as(u32, bpb.root_entries) * 32 + bpb.bytes_per_sector - 1) /
        bpb.bytes_per_sector;
    const first_data_sector = bpb.reserved_sectors +
        @as(u32, bpb.fat_count) * sectors_per_fat + root_dir_sectors;
    if (first_data_sector >= total_sectors) return error.NotFat;

    const cluster_count = (total_sectors - first_data_sector) / bpb.sectors_per_cluster;

    // FAT32 is identified structurally, not by cluster count.
    //
    // The specification says the count decides the width, and that describes
    // what a correct formatter produces, but formatters will happily create a
    // small FAT32 volume whose count falls in the FAT16 range, and reading its
    // 32-bit FAT entries as 16-bit ones yields a chain that ends early. The
    // reliable signal is that `sectors_per_fat_16` and `root_entries` are zero
    // on FAT32 and never zero otherwise, because FAT32 relocated both fields.
    //
    // Only once FAT32 is ruled out does the count distinguish 12 from 16.
    const kind: Kind = if (bpb.sectors_per_fat_16 == 0 and bpb.root_entries == 0)
        .fat32
    else if (cluster_count < 4085)
        .fat12
    else
        .fat16;

    return .{
        .dev = dev,
        .kind = kind,
        .bytes_per_sector = bpb.bytes_per_sector,
        .sectors_per_cluster = bpb.sectors_per_cluster,
        .first_fat_sector = bpb.reserved_sectors,
        .sectors_per_fat = sectors_per_fat,
        .fat_count = bpb.fat_count,
        .root_dir_sector = bpb.reserved_sectors + @as(u32, bpb.fat_count) * sectors_per_fat,
        .root_dir_sectors = root_dir_sectors,
        .root_cluster = if (kind == .fat32) bpb.root_cluster else 0,
        .first_data_sector = first_data_sector,
        .cluster_count = cluster_count,
        .fat = .{
            .dev = dev,
            .kind = kind,
            .bytes_per_sector = bpb.bytes_per_sector,
            .first_fat_sector = bpb.reserved_sectors,
            .sectors_per_fat = sectors_per_fat,
            .fat_count = bpb.fat_count,
            .cluster_count = cluster_count,
        },
    };
}

/// A VFAT long-name entry. Occupies the same 32 bytes as a directory entry,
/// distinguished by its attribute byte.
const LfnEntry = extern struct {
    sequence: u8,
    name_1: [10]u8,
    attr: u8,
    type: u8,
    /// Checksum of the 8.3 name this belongs to. Without checking it, orphaned
    /// long-name entries left by another operating system would be attached to
    /// whatever short entry happened to follow.
    checksum: u8,
    name_2: [12]u8,
    cluster_low: u16 align(1),
    name_3: [4]u8,
};

const LFN_LAST = 0x40;
const LFN_SEQ_MASK = 0x1F;
/// Each long-name entry carries 13 UTF-16 code units.
const LFN_CHARS = 13;
const LFN_MAX_ENTRIES = 20;

/// The checksum the 8.3 name must produce for a long name to belong to it.
fn shortNameChecksum(name: *const [11]u8) u8 {
    var sum: u8 = 0;
    for (name) |c| {
        sum = (sum >> 1) +% (sum << 7) +% c;
    }
    return sum;
}

/// Pull the 13 UTF-16 code units out of one long-name entry, in order.
fn lfnChars(e: *align(1) const LfnEntry, out: *[LFN_CHARS]u16) void {
    var n: usize = 0;
    for (0..5) |i| {
        out[n] = std.mem.readInt(u16, e.name_1[i * 2 ..][0..2], .little);
        n += 1;
    }
    for (0..6) |i| {
        out[n] = std.mem.readInt(u16, e.name_2[i * 2 ..][0..2], .little);
        n += 1;
    }
    for (0..2) |i| {
        out[n] = std.mem.readInt(u16, e.name_3[i * 2 ..][0..2], .little);
        n += 1;
    }
}

/// Accumulates long-name fragments while scanning a directory.
///
/// Entries appear in reverse order and immediately before their 8.3 entry, so
/// fragments are written into their final position by sequence number rather
/// than appended.
const LfnBuilder = struct {
    units: [LFN_MAX_ENTRIES * LFN_CHARS]u16 = undefined,
    count: usize = 0,
    checksum: u8 = 0,
    valid: bool = false,

    fn reset(self: *LfnBuilder) void {
        self.count = 0;
        self.valid = false;
    }

    fn add(self: *LfnBuilder, e: *align(1) const LfnEntry) void {
        const seq = e.sequence & LFN_SEQ_MASK;
        if (seq == 0 or seq > LFN_MAX_ENTRIES) {
            self.reset();
            return;
        }

        if (e.sequence & LFN_LAST != 0) {
            // First entry encountered is the *last* fragment, and it tells us
            // how many there are in total.
            self.count = @as(usize, seq) * LFN_CHARS;
            self.checksum = e.checksum;
            self.valid = true;
        } else if (!self.valid or e.checksum != self.checksum) {
            // A fragment from a different name, or one with no terminator seen:
            // the sequence is broken, so discard it rather than assemble a name
            // out of unrelated pieces.
            self.reset();
            return;
        }

        var chars: [LFN_CHARS]u16 = undefined;
        lfnChars(e, &chars);
        const base = (@as(usize, seq) - 1) * LFN_CHARS;
        if (base + LFN_CHARS > self.units.len) {
            self.reset();
            return;
        }
        @memcpy(self.units[base..][0..LFN_CHARS], &chars);
    }

    /// Write the assembled name as UTF-8. Returns null if it does not belong to
    /// this short entry, or does not fit.
    fn finish(self: *LfnBuilder, short: *const [11]u8, out: *[MAX_NAME]u8) ?usize {
        if (!self.valid or self.count == 0) return null;
        if (self.checksum != shortNameChecksum(short)) return null;

        var n: usize = 0;
        for (self.units[0..self.count]) |unit| {
            // 0x0000 terminates, 0xFFFF is padding.
            if (unit == 0 or unit == 0xFFFF) break;

            // Surrogate pairs are not reassembled: they encode characters
            // outside the Basic Multilingual Plane, which no filename this
            // system creates will contain, and mis-decoding one would produce
            // an invalid UTF-8 name rather than a wrong one.
            if (unit >= 0xD800 and unit <= 0xDFFF) return null;

            var buf: [3]u8 = undefined;
            const len = std.unicode.utf8Encode(unit, &buf) catch return null;
            if (n + len >= out.len) return null;
            @memcpy(out[n..][0..len], buf[0..len]);
            n += len;
        }
        return if (n > 0) n else null;
    }
};

/// Decode the 8.3 name in a directory entry into "NAME.EXT".
fn decodeName(raw: *const [11]u8, out: *[MAX_NAME]u8) usize {
    var n: usize = 0;
    for (raw[0..8]) |c| {
        if (c == ' ') break;
        out[n] = c;
        n += 1;
    }
    var ext_len: usize = 0;
    for (raw[8..11]) |c| {
        if (c == ' ') break;
        ext_len += 1;
    }
    if (ext_len > 0) {
        out[n] = '.';
        n += 1;
        for (raw[8 .. 8 + ext_len]) |c| {
            out[n] = c;
            n += 1;
        }
    }
    return n;
}

/// Case-insensitive comparison against an 8.3 name.
fn nameMatches(entry: []const u8, wanted: []const u8) bool {
    if (entry.len != wanted.len) return false;
    for (entry, wanted) |a, b| {
        if (std.ascii.toUpper(a) != std.ascii.toUpper(b)) return false;
    }
    return true;
}

pub const Iterator = struct {
    vol: *Volume,
    /// Zero while walking a FAT12/16 fixed root directory.
    cluster: u32,
    sector_in_cluster: u32,
    /// Absolute sector, used for the fixed root directory.
    sector: u32,
    sectors_left: u32,
    index_in_sector: u32,
    buffer: [block.SECTOR_SIZE]u8 = undefined,
    loaded: bool = false,
    done: bool = false,
    lfn: LfnBuilder = .{},

    pub fn next(self: *Iterator) Error!?Entry {
        while (!self.done) {
            if (!self.loaded) {
                self.vol.dev.read(self.sector, &self.buffer) catch return error.Io;
                self.loaded = true;
                self.index_in_sector = 0;
            }

            const per_sector = block.SECTOR_SIZE / @sizeOf(DirEntry);
            while (self.index_in_sector < per_sector) {
                const off = self.index_in_sector * @sizeOf(DirEntry);
                const raw: *align(1) const DirEntry = @ptrCast(&self.buffer[off]);
                self.index_in_sector += 1;

                // 0x00 means no entry here and none after it.
                if (raw.name[0] == 0x00) {
                    self.done = true;
                    return null;
                }
                // 0xE5 marks a deleted entry. Any long name accumulated so far
                // belonged to it.
                if (raw.name[0] == 0xE5) {
                    self.lfn.reset();
                    continue;
                }

                // Long-name fragments precede the entry they describe.
                if (raw.attr & ATTR_LONG_NAME == ATTR_LONG_NAME) {
                    self.lfn.add(@ptrCast(raw));
                    continue;
                }

                if (raw.attr & ATTR_VOLUME_ID != 0) {
                    self.lfn.reset();
                    continue;
                }

                var entry = Entry{
                    .name = undefined,
                    .name_len = 0,
                    .dir_sector = self.sector,
                    // Already advanced past this record, so the index is one
                    // behind the cursor.
                    .dir_index = self.index_in_sector - 1,
                    .is_dir = raw.attr & ATTR_DIRECTORY != 0,
                    .size = raw.size,
                    .cluster = raw.firstCluster(),
                    .mtime = epochFromFat(raw.write_date, raw.write_time),
                };

                // Prefer the long name; fall back to 8.3 when there is none, or
                // when the fragments do not check out against this entry.
                entry.name_len = self.lfn.finish(&raw.name, &entry.name) orelse
                    decodeName(&raw.name, &entry.name);
                self.lfn.reset();

                return entry;
            }

            try self.advanceSector();
        }
        return null;
    }

    fn advanceSector(self: *Iterator) Error!void {
        self.loaded = false;

        if (self.cluster == 0) {
            // Fixed-size root directory: a plain run of sectors.
            self.sectors_left -= 1;
            if (self.sectors_left == 0) {
                self.done = true;
                return;
            }
            self.sector += 1;
            return;
        }

        self.sector_in_cluster += 1;
        if (self.sector_in_cluster < self.vol.sectors_per_cluster) {
            self.sector += 1;
            return;
        }

        const next_cluster = try self.vol.nextCluster(self.cluster) orelse {
            self.done = true;
            return;
        };
        self.cluster = next_cluster;
        self.sector_in_cluster = 0;
        self.sector = self.vol.firstSectorOfCluster(next_cluster);
    }
};

/// Iterate a subdirectory, given its first cluster.
pub fn directoryIterator(vol: *Volume, cluster: u32) Iterator {
    return .{
        .vol = vol,
        .cluster = cluster,
        .sector_in_cluster = 0,
        .sector = vol.firstSectorOfCluster(cluster),
        .sectors_left = 0,
        .index_in_sector = 0,
    };
}

/// An iterator over whatever directory `entry` names.
///
/// A subdirectory's ".." entry records cluster 0 when it refers to the root,
/// because the root has no cluster number on FAT12/16, so that case is mapped
/// back to the root iterator rather than followed literally.
pub fn iterate(vol: *Volume, entry: Entry) Iterator {
    if (entry.cluster < 2) return rootIterator(vol);
    return directoryIterator(vol, entry.cluster);
}

pub fn rootIterator(vol: *Volume) Iterator {
    if (vol.kind == .fat32) {
        return .{
            .vol = vol,
            .cluster = vol.root_cluster,
            .sector_in_cluster = 0,
            .sector = vol.firstSectorOfCluster(vol.root_cluster),
            .sectors_left = 0,
            .index_in_sector = 0,
        };
    }
    return .{
        .vol = vol,
        .cluster = 0,
        .sector_in_cluster = 0,
        .sector = vol.root_dir_sector,
        .sectors_left = vol.root_dir_sectors,
        .index_in_sector = 0,
    };
}

/// Look up a single name in one directory.
///
/// Takes the iterator by value: the caller keeps its own position, which is
/// what lets a path walk descend without losing where it was.
pub fn lookupIn(dir: Iterator, name: []const u8) Error!Entry {
    var it = dir;
    while (try it.next()) |entry| {
        if (nameMatches(entry.nameSlice(), name)) return entry;
    }
    return error.NotFound;
}

/// Look up a path from the root. Kept as the short name most callers use.
pub const lookup = lookupPath;

/// Walk a slash-separated path from the root.
///
/// Empty components are skipped, so a doubled or trailing slash is harmless
/// rather than an error, the alternative is rejecting paths that every other
/// system accepts. "." and ".." are honoured because FAT stores them as real
/// directory entries.
pub fn lookupPath(vol: *Volume, path: []const u8) Error!Entry {
    var it = rootIterator(vol);
    var found: ?Entry = null;

    var rest = path;
    while (rest.len > 0) {
        while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        if (rest.len == 0) break;

        var end: usize = 0;
        while (end < rest.len and rest[end] != '/') end += 1;
        const component = rest[0..end];
        rest = rest[end..];

        // A component after a plain file is a path through something that is
        // not a directory, which is an error rather than a miss.
        if (found) |f| {
            if (!f.is_dir) return error.NotDirectory;
        }

        const entry = try lookupIn(it, component);
        found = entry;
        if (entry.is_dir) it = iterate(vol, entry);
    }

    return found orelse error.NotFound;
}

/// Read from `offset` in a file. Returns the number of bytes read.
///
/// Walks the cluster chain from the start each time. That is O(n) in the
/// offset, which is acceptable while reads are sequential and files are small;
/// a handle that remembered its last cluster would make it O(1) for the
/// sequential case, and is the obvious change when it matters.
pub fn readAt(vol: *Volume, entry: Entry, offset: u64, buf: []u8) Error!usize {
    if (entry.is_dir) return error.IsDirectory;
    if (offset >= entry.size) return 0;

    const cluster_size = vol.clusterSize();
    var cluster = entry.cluster;
    if (cluster < 2) return error.CorruptChain;

    // Skip whole clusters until the one containing `offset`.
    var skip = offset / cluster_size;
    while (skip > 0) : (skip -= 1) {
        cluster = try vol.nextCluster(cluster) orelse return error.CorruptChain;
    }

    var within: u32 = @intCast(offset % cluster_size);
    var remaining: usize = @intCast(@min(entry.size - offset, buf.len));
    var written: usize = 0;

    var sector_buf: [block.SECTOR_SIZE]u8 = undefined;

    while (remaining > 0) {
        const first = vol.firstSectorOfCluster(cluster);

        var s: u32 = within / block.SECTOR_SIZE;
        var in_sector: u32 = within % block.SECTOR_SIZE;

        while (s < vol.sectors_per_cluster and remaining > 0) : (s += 1) {
            vol.dev.read(first + s, &sector_buf) catch return error.Io;
            const available = block.SECTOR_SIZE - in_sector;
            const take = @min(remaining, available);
            @memcpy(buf[written..][0..take], sector_buf[in_sector..][0..take]);
            written += take;
            remaining -= take;
            in_sector = 0;
        }

        if (remaining == 0) break;
        within = 0;
        cluster = try vol.nextCluster(cluster) orelse return error.CorruptChain;
    }

    return written;
}

/// Read a whole file into `buf`. Returns the number of bytes read.
pub fn readFile(vol: *Volume, entry: Entry, buf: []u8) Error!usize {
    if (entry.is_dir) return error.IsDirectory;
    if (entry.size > buf.len) return error.NoSpace;
    if (entry.size == 0) return 0;

    var remaining = entry.size;
    var written: usize = 0;
    var cluster = entry.cluster;
    if (cluster < 2) return error.CorruptChain;

    var sector_buf: [block.SECTOR_SIZE]u8 = undefined;

    while (remaining > 0) {
        const first = vol.firstSectorOfCluster(cluster);

        var s: u32 = 0;
        while (s < vol.sectors_per_cluster and remaining > 0) : (s += 1) {
            vol.dev.read(first + s, &sector_buf) catch return error.Io;
            const take = @min(remaining, block.SECTOR_SIZE);
            @memcpy(buf[written..][0..take], sector_buf[0..take]);
            written += take;
            remaining -= take;
        }

        if (remaining == 0) break;
        cluster = try vol.nextCluster(cluster) orelse return error.CorruptChain;
    }

    return written;
}

// ---------------------------------------------------------------------------
// Writing
//
// Sizes and timestamps reach the disk through `commit`, which the caller
// invokes once when it is done rather than after every write: a directory
// sector rewritten per call would cost more than the data itself.
// ---------------------------------------------------------------------------

/// Write `data` at `offset`, growing the file if needed.
///
/// Returns the new size, which the caller must store back into the directory
/// entry with `commit`. Split that way because a handle writing sequentially
/// should update its entry once when it closes, not once per write: a
/// directory sector rewritten on every call would dominate the cost of writing
/// a file and wear the SSD for nothing.
pub fn writeAt(vol: *Volume, entry: *Entry, offset: u64, data: []const u8) Error!usize {
    if (entry.is_dir) return error.IsDirectory;
    if (data.len == 0) return 0;

    const cluster_size = vol.clusterSize();

    // A file with no clusters yet gets its first one here, which is also what
    // makes an empty file cost nothing until something is written to it.
    if (entry.cluster < 2) {
        entry.cluster = try table.alloc(&vol.fat);
    }

    var cluster = entry.cluster;

    // Walk to the cluster holding `offset`, extending the chain if the file is
    // being written past its end.
    var skip = offset / cluster_size;
    while (skip > 0) : (skip -= 1) {
        cluster = try vol.nextCluster(cluster) orelse try table.append(&vol.fat, cluster);
    }

    var within: u32 = @intCast(offset % cluster_size);
    var remaining = data.len;
    var done: usize = 0;

    var sector_buf: [block.SECTOR_SIZE]u8 = undefined;

    while (remaining > 0) {
        const first = vol.firstSectorOfCluster(cluster);

        var s: u32 = within / block.SECTOR_SIZE;
        var in_sector: u32 = within % block.SECTOR_SIZE;

        while (s < vol.sectors_per_cluster and remaining > 0) : (s += 1) {
            const available = block.SECTOR_SIZE - in_sector;
            const take = @min(remaining, available);

            // A partial sector must be read before it is written, or the bytes
            // either side of the update are replaced with whatever the buffer
            // happened to hold.
            if (take != block.SECTOR_SIZE) {
                vol.dev.read(first + s, &sector_buf) catch return error.Io;
            }

            @memcpy(sector_buf[in_sector..][0..take], data[done..][0..take]);
            vol.dev.write(first + s, &sector_buf) catch return error.Io;

            done += take;
            remaining -= take;
            in_sector = 0;
        }

        if (remaining == 0) break;
        within = 0;
        cluster = try vol.nextCluster(cluster) orelse try table.append(&vol.fat, cluster);
    }

    const end = offset + done;
    if (end > entry.size) entry.size = @intCast(end);
    return done;
}

/// Write an entry's size, first cluster and modification time back to disk.
pub fn commit(vol: *Volume, entry: Entry, mtime: i64) Error!void {
    if (entry.dir_sector == 0) return error.NotFound;

    var sector: [block.SECTOR_SIZE]u8 = undefined;
    vol.dev.read(entry.dir_sector, &sector) catch return error.Io;

    const off = entry.dir_index * @sizeOf(DirEntry);
    const raw: *align(1) DirEntry = @ptrCast(&sector[off]);

    raw.size = entry.size;
    raw.cluster_low = @truncate(entry.cluster);
    raw.cluster_high = @truncate(entry.cluster >> 16);

    const stamp = fatFromEpoch(mtime);
    raw.write_date = stamp.date;
    raw.write_time = stamp.time;
    raw.access_date = stamp.date;

    vol.dev.write(entry.dir_sector, &sector) catch return error.Io;
}

/// Drop everything a file holds, leaving it empty but still present.
pub fn truncate(vol: *Volume, entry: *Entry) Error!void {
    if (entry.is_dir) return error.IsDirectory;

    if (entry.cluster >= 2) try table.freeChain(&vol.fat, entry.cluster);
    entry.cluster = 0;
    entry.size = 0;
}

// ---------------------------------------------------------------------------
// Creating entries
// ---------------------------------------------------------------------------

/// Where a new directory record will go.
const Slot = struct { sector: u32, index: u32 };

/// Pack a name into the 8.3 form, upper-cased.
///
/// Fails on anything that will not fit, which is what tells the caller a long
/// name is needed. Never truncates: a name silently shortened is a different
/// file, and the volume would disagree with every other system about what it
/// is called.
fn encodeShortName(name: []const u8, out: *[11]u8) Error!void {
    @memset(out, ' ');

    var stem_len: usize = 0;
    var ext_len: usize = 0;
    var in_ext = false;

    for (name) |c| {
        if (c == '.') {
            // Only the last dot separates the extension, and a leading dot is
            // not a name we can represent at all.
            if (in_ext or stem_len == 0) return error.NameTooLong;
            in_ext = true;
            continue;
        }
        if (!isShortNameChar(c)) return error.NameTooLong;

        const upper = if (c >= 'a' and c <= 'z') c - 32 else c;
        if (in_ext) {
            if (ext_len >= 3) return error.NameTooLong;
            out[8 + ext_len] = upper;
            ext_len += 1;
        } else {
            if (stem_len >= 8) return error.NameTooLong;
            out[stem_len] = upper;
            stem_len += 1;
        }
    }

    if (stem_len == 0) return error.NameTooLong;
    // 0xE5 marks a deleted record, so a name genuinely starting with that byte
    // is stored as 0x05 by convention.
    if (out[0] == 0xE5) out[0] = 0x05;
}

fn isShortNameChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '$', '%', '\'', '-', '_', '@', '~', '`', '!', '(', ')', '{', '}', '^', '#', '&' => true,
        else => false,
    };
}

const RECORDS_PER_SECTOR = block.SECTOR_SIZE / @sizeOf(DirEntry);

/// A run of consecutive free records, and where to carry on writing.
///
/// A long name needs its records adjacent and in order, so the search is for a
/// run rather than for a slot. The walker is kept because the run may cross a
/// sector, and continuing the walk is the only way to know which sector comes
/// next in a cluster chain.
const Run = struct {
    walk: Iterator,
    index: u32,
};

/// Find `needed` consecutive free records in `dir`, extending it if it is full.
///
/// Free means never used (0x00) or deleted (0xE5). A FAT12/16 root directory
/// is a fixed run of sectors and cannot grow, which is the one case where a
/// volume with free space still cannot take another file.
fn findFreeRun(vol: *Volume, dir: Iterator, needed: usize) Error!Run {
    var walk = dir;
    var sector_buf: [block.SECTOR_SIZE]u8 = undefined;

    var start: ?Run = null;
    var found: usize = 0;

    while (!walk.done) {
        vol.dev.read(walk.sector, &sector_buf) catch return error.Io;

        var i: u32 = 0;
        while (i < RECORDS_PER_SECTOR) : (i += 1) {
            const first = sector_buf[i * @sizeOf(DirEntry)];
            if (first == 0x00 or first == 0xE5) {
                if (start == null) start = .{ .walk = walk, .index = i };
                found += 1;
                if (found == needed) return start.?;
            } else {
                start = null;
                found = 0;
            }
        }

        const last_cluster = walk.cluster;
        walk.advanceSector() catch return error.Io;

        if (walk.done and last_cluster != 0) {
            // A cluster-chained directory can grow. The fresh cluster is
            // zeroed first: uninitialised records would be read as entries.
            const fresh = try table.append(&vol.fat, last_cluster);
            try zeroCluster(vol, fresh);

            var extended = walk;
            extended.done = false;
            extended.cluster = fresh;
            extended.sector = vol.firstSectorOfCluster(fresh);
            extended.sector_in_cluster = 0;
            extended.sectors_left = vol.sectors_per_cluster;
            extended.loaded = false;

            // A fresh cluster is entirely free, so a run that started earlier
            // continues into it and one that did not starts here.
            if (start == null) start = .{ .walk = extended, .index = 0 };
            walk = extended;
        }
    }
    return error.NoSpace;
}

/// Write consecutive records starting at `run`.
///
/// One sector at a time, so a run crossing a boundary costs two writes rather
/// than one per record.
fn writeRun(vol: *Volume, run: Run, records: []const [32]u8) Error!Slot {
    var walk = run.walk;
    var index = run.index;
    var written: usize = 0;
    var last = Slot{ .sector = walk.sector, .index = index };

    var sector_buf: [block.SECTOR_SIZE]u8 = undefined;

    while (written < records.len) {
        vol.dev.read(walk.sector, &sector_buf) catch return error.Io;

        while (index < RECORDS_PER_SECTOR and written < records.len) : (index += 1) {
            @memcpy(sector_buf[index * @sizeOf(DirEntry) ..][0..@sizeOf(DirEntry)], &records[written]);
            last = .{ .sector = walk.sector, .index = index };
            written += 1;
        }

        vol.dev.write(walk.sector, &sector_buf) catch return error.Io;

        if (written < records.len) {
            walk.advanceSector() catch return error.Io;
            if (walk.done) return error.NoSpace;
            index = 0;
        }
    }

    // Where the short record landed, which is what the caller needs to find
    // the file again.
    return last;
}

fn zeroCluster(vol: *Volume, cluster: u32) Error!void {
    var blank: [block.SECTOR_SIZE]u8 = @splat(0);
    const first = vol.firstSectorOfCluster(cluster);

    var s: u32 = 0;
    while (s < vol.sectors_per_cluster) : (s += 1) {
        vol.dev.write(first + s, &blank) catch return error.Io;
    }
}

/// Whether a name can be stored as it is written.
///
/// Case is the usual reason it cannot: 8.3 has nowhere to record it, so a name
/// with any lowercase in it needs long-name records to survive a round trip
/// even when it is short enough to fit.
fn fitsShortName(name: []const u8) bool {
    var probe: [11]u8 = undefined;
    encodeShortName(name, &probe) catch return false;

    var back: [MAX_NAME]u8 = undefined;
    const n = decodeName(&probe, &back);
    return std.mem.eql(u8, back[0..n], name);
}

/// Invent a unique 8.3 alias for a long name: `LONGNA~1.TXT`.
///
/// Every long name needs one, because that is what a system reading only 8.3
/// will see, and two files in a directory cannot share it.
fn shortAlias(dir: Iterator, name: []const u8, out: *[11]u8) Error!void {
    @memset(out, ' ');

    // The stem takes what it can of the leading characters; the extension is
    // whatever follows the last dot.
    var stem: usize = 0;
    var dot: ?usize = null;
    for (name, 0..) |c, i| {
        if (c == '.') dot = i;
    }

    for (name[0 .. dot orelse name.len]) |c| {
        if (stem == 6) break;
        if (!isShortNameChar(c)) continue;
        out[stem] = if (c >= 'a' and c <= 'z') c - 32 else c;
        stem += 1;
    }
    if (stem == 0) {
        out[0] = 'F';
        stem = 1;
    }

    if (dot) |at| {
        var ext: usize = 0;
        for (name[at + 1 ..]) |c| {
            if (ext == 3) break;
            if (!isShortNameChar(c)) continue;
            out[8 + ext] = if (c >= 'a' and c <= 'z') c - 32 else c;
            ext += 1;
        }
    }

    // `~1` through `~99`, which is as far as anything sensible goes. A
    // directory holding a hundred names that all shorten alike is one where
    // refusing is better than searching.
    var n: u32 = 1;
    while (n <= 99) : (n += 1) {
        var suffix: [3]u8 = undefined;
        var len: usize = 0;
        suffix[len] = '~';
        len += 1;
        if (n >= 10) {
            suffix[len] = '0' + @as(u8, @intCast(n / 10));
            len += 1;
        }
        suffix[len] = '0' + @as(u8, @intCast(n % 10));
        len += 1;

        const at = @min(stem, 8 - len);
        @memcpy(out[at..][0..len], suffix[0..len]);

        var back: [MAX_NAME]u8 = undefined;
        const back_len = decodeName(out, &back);
        _ = lookupIn(dir, back[0..back_len]) catch |err| switch (err) {
            error.NotFound => return,
            else => return err,
        };
    }
    return error.NoSpace;
}

/// How many long-name records a name needs.
fn longNameRecords(name: []const u8) usize {
    return (name.len + LFN_CHARS - 1) / LFN_CHARS;
}

/// Build one long-name record: 13 characters of the name, in UTF-16.
///
/// Unused positions after the terminator are 0xFFFF, which is what every
/// implementation writes and what some of them check for.
fn buildLongRecord(name: []const u8, index: usize, last: bool, checksum: u8) LfnEntry {
    var chars: [LFN_CHARS]u16 = @splat(0xFFFF);
    const start = index * LFN_CHARS;

    for (0..LFN_CHARS) |i| {
        const at = start + i;
        if (at < name.len) {
            // Latin-1 into UTF-16 directly. Names above that need a decoder,
            // and nothing here creates one yet.
            chars[i] = name[at];
        } else if (at == name.len) {
            chars[i] = 0;
        }
    }

    var e = LfnEntry{
        .sequence = @intCast(index + 1),
        .name_1 = undefined,
        .attr = ATTR_LONG_NAME,
        .type = 0,
        .checksum = checksum,
        .name_2 = undefined,
        .cluster_low = 0,
        .name_3 = undefined,
    };
    if (last) e.sequence |= LFN_LAST;

    for (0..5) |i| std.mem.writeInt(u16, e.name_1[i * 2 ..][0..2], chars[i], .little);
    for (0..6) |i| std.mem.writeInt(u16, e.name_2[i * 2 ..][0..2], chars[5 + i], .little);
    for (0..2) |i| std.mem.writeInt(u16, e.name_3[i * 2 ..][0..2], chars[11 + i], .little);

    return e;
}

/// Create an empty file called `name` in `dir`.
///
/// The entry starts with no clusters at all: an empty file should cost a
/// directory record and nothing else, and `writeAt` allocates the first
/// cluster when there is finally something to put in it.
pub fn createFile(vol: *Volume, dir: Iterator, name: []const u8, mtime: i64) Error!Entry {
    return create(vol, dir, name, mtime, false);
}

/// Create an empty directory called `name` in `dir`.
///
/// Unlike a file it costs a cluster immediately, because a directory that
/// exists must already hold its own `.` and `..`: a system reading one with no
/// cluster would see a directory it cannot enter.
pub fn createDirectory(vol: *Volume, dir: Iterator, name: []const u8, mtime: i64) Error!Entry {
    return create(vol, dir, name, mtime, true);
}

fn create(vol: *Volume, dir: Iterator, name: []const u8, mtime: i64, is_dir: bool) Error!Entry {
    if (name.len == 0 or name.len > MAX_NAME) return error.NameTooLong;
    if (lookupIn(dir, name)) |_| return error.Exists else |err| switch (err) {
        error.NotFound => {},
        else => return err,
    }

    // A name that survives the 8.3 round trip is stored as itself. Anything
    // else, and that includes anything with lowercase in it, needs long-name
    // records and an alias for systems that read only the short form.
    var short: [11]u8 = undefined;
    const long = !fitsShortName(name);
    if (long) try shortAlias(dir, name, &short) else try encodeShortName(name, &short);

    const long_records = if (long) longNameRecords(name) else 0;
    if (long_records > LFN_MAX_ENTRIES) return error.NameTooLong;

    // A directory's cluster is allocated before its record, so a failure part
    // way leaves a lost cluster rather than a directory nothing can enter.
    var cluster: u32 = 0;
    if (is_dir) {
        cluster = try table.alloc(&vol.fat);
        try zeroCluster(vol, cluster);
        try writeDotEntries(vol, cluster, parentCluster(vol, dir), mtime);
    }
    errdefer if (is_dir) table.freeChain(&vol.fat, cluster) catch {};

    var records: [LFN_MAX_ENTRIES + 1][32]u8 = undefined;
    const checksum = shortNameChecksum(&short);

    // The records run last fragment first, so reading forward reaches the
    // pieces in reverse and the short entry comes last.
    for (0..long_records) |i| {
        const index = long_records - 1 - i;
        const record = buildLongRecord(name, index, index == long_records - 1, checksum);
        @memcpy(&records[i], std.mem.asBytes(&record));
    }

    const stamp = fatFromEpoch(mtime);
    const entry_record = DirEntry{
        .name = short,
        .attr = if (is_dir) ATTR_DIRECTORY else 0,
        .nt_reserved = 0,
        .create_tenths = 0,
        .create_time = stamp.time,
        .create_date = stamp.date,
        .access_date = stamp.date,
        .cluster_high = @truncate(cluster >> 16),
        .write_time = stamp.time,
        .write_date = stamp.date,
        .cluster_low = @truncate(cluster),
        .size = 0,
    };
    @memcpy(&records[long_records], std.mem.asBytes(&entry_record));

    const total = long_records + 1;
    const run = try findFreeRun(vol, dir, total);
    const slot = try writeRun(vol, run, records[0..total]);

    var entry = Entry{
        .name = undefined,
        .name_len = 0,
        .is_dir = is_dir,
        .size = 0,
        .cluster = cluster,
        .mtime = mtime,
        .dir_sector = slot.sector,
        .dir_index = slot.index,
    };

    if (long) {
        entry.name_len = @min(name.len, MAX_NAME);
        @memcpy(entry.name[0..entry.name_len], name[0..entry.name_len]);
    } else {
        entry.name_len = decodeName(&short, &entry.name);
    }
    return entry;
}

/// What a new directory's `..` should point at.
///
/// Zero when the parent is the root, whichever way this volume stores its
/// root: that is the convention, and a `..` naming the root's own cluster is
/// something other systems read as a loop.
fn parentCluster(vol: *Volume, dir: Iterator) u32 {
    if (dir.cluster == 0) return 0;
    if (vol.kind == .fat32 and dir.cluster == vol.root_cluster) return 0;
    return dir.cluster;
}

/// Write the `.` and `..` a directory must begin with.
fn writeDotEntries(vol: *Volume, cluster: u32, parent: u32, mtime: i64) Error!void {
    var sector_buf: [block.SECTOR_SIZE]u8 = @splat(0);
    const stamp = fatFromEpoch(mtime);

    const pair = [_]struct { name: *const [11]u8, cluster: u32 }{
        .{ .name = ".          ", .cluster = cluster },
        .{ .name = "..         ", .cluster = parent },
    };

    for (pair, 0..) |it, i| {
        const record = DirEntry{
            .name = it.name.*,
            .attr = ATTR_DIRECTORY,
            .nt_reserved = 0,
            .create_tenths = 0,
            .create_time = stamp.time,
            .create_date = stamp.date,
            .access_date = stamp.date,
            .cluster_high = @truncate(it.cluster >> 16),
            .write_time = stamp.time,
            .write_date = stamp.date,
            .cluster_low = @truncate(it.cluster),
            .size = 0,
        };
        @memcpy(sector_buf[i * @sizeOf(DirEntry) ..][0..@sizeOf(DirEntry)], std.mem.asBytes(&record));
    }

    vol.dev.write(vol.firstSectorOfCluster(cluster), &sector_buf) catch return error.Io;
}

/// Remove a file: free its clusters and mark its record deleted.
pub fn unlink(vol: *Volume, entry: Entry) Error!void {
    if (entry.is_dir) return error.IsDirectory;
    if (entry.dir_sector == 0) return error.NotFound;

    if (entry.cluster >= 2) try table.freeChain(&vol.fat, entry.cluster);

    var sector_buf: [block.SECTOR_SIZE]u8 = undefined;
    vol.dev.read(entry.dir_sector, &sector_buf) catch return error.Io;

    // 0xE5 in the first byte is what marks a record free. Any long-name records
    // in front of it are left behind: a reader checks their checksum against
    // the short entry that follows, so orphans are ignored rather than
    // attached to whatever record lands there next.
    sector_buf[entry.dir_index * @sizeOf(DirEntry)] = 0xE5;
    vol.dev.write(entry.dir_sector, &sector_buf) catch return error.Io;
}

/// Free clusters on the volume, for `df`.
pub fn freeClusters(vol: *Volume) Error!u32 {
    return table.freeCount(&vol.fat);
}
