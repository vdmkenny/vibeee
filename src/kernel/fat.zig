//! FAT12/16/32 reader.
//!
//! The only on-disk filesystem vibeee uses (design/00-vibeee.md §7). The
//! decisive property is not performance: it is that any other machine can read
//! the card. On hardware this old, being able to pull the SD out and fix it
//! elsewhere is worth more than anything a private format would buy.
//!
//! Read support first. Writing needs free-cluster allocation, FAT-chain
//! extension and directory-entry updates, and none of that should be written
//! before reading is known to be correct.
//!
//! All three widths are handled because they differ only in how a FAT entry is
//! fetched — the directory and cluster-chain logic above that is identical, so
//! supporting FAT16 costs a branch rather than a second driver.

const std = @import("std");
const block = @import("block.zig");

pub const Error = error{
    NotFat,
    Unsupported,
    NotFound,
    IsDirectory,
    NotDirectory,
    CorruptChain,
    Io,
    NoSpace,
};

pub const Kind = enum { fat12, fat16, fat32 };

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

pub const Entry = struct {
    name: [12]u8,
    name_len: usize,
    is_dir: bool,
    size: u32,
    cluster: u32,

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

    /// One sector of scratch for FAT lookups, and one cluster's worth for
    /// directory scans. Static per volume: the kernel heap exists, but a
    /// filesystem that allocates on every lookup is a filesystem that fails in
    /// low memory, which is exactly when you need to read something.
    fat_cache: [block.SECTOR_SIZE]u8 = undefined,
    fat_cache_sector: u32 = 0xFFFF_FFFF,

    pub fn clusterSize(self: *const Volume) u32 {
        return self.bytes_per_sector * self.sectors_per_cluster;
    }

    fn firstSectorOfCluster(self: *const Volume, cluster: u32) u32 {
        return self.first_data_sector + (cluster - 2) * self.sectors_per_cluster;
    }

    /// Follow the allocation chain one link.
    fn nextCluster(self: *Volume, cluster: u32) Error!?u32 {
        const offset: u32 = switch (self.kind) {
            .fat12 => cluster + (cluster / 2),
            .fat16 => cluster * 2,
            .fat32 => cluster * 4,
        };
        const sector = self.first_fat_sector + offset / self.bytes_per_sector;
        const within = offset % self.bytes_per_sector;

        try self.loadFatSector(sector);

        const value: u32 = switch (self.kind) {
            .fat16 => std.mem.readInt(u16, self.fat_cache[within..][0..2], .little),
            .fat32 => std.mem.readInt(u32, self.fat_cache[within..][0..4], .little) & 0x0FFF_FFFF,
            .fat12 => blk: {
                // A FAT12 entry is 12 bits and can straddle a sector boundary,
                // so the two bytes are fetched separately rather than as a u16.
                const lo = self.fat_cache[within];
                try self.loadFatSector(self.first_fat_sector + (offset + 1) / self.bytes_per_sector);
                const hi = self.fat_cache[(offset + 1) % self.bytes_per_sector];
                const raw = @as(u16, lo) | (@as(u16, hi) << 8);
                break :blk if (cluster & 1 != 0) raw >> 4 else raw & 0x0FFF;
            },
        };

        const end_of_chain: u32 = switch (self.kind) {
            .fat12 => 0x0FF8,
            .fat16 => 0xFFF8,
            .fat32 => 0x0FFF_FFF8,
        };
        if (value >= end_of_chain) return null;

        // A chain pointing outside the volume is corruption; following it would
        // read arbitrary sectors and loop forever.
        if (value < 2 or value >= self.cluster_count + 2) return error.CorruptChain;
        return value;
    }

    fn loadFatSector(self: *Volume, sector: u32) Error!void {
        if (self.fat_cache_sector == sector) return;
        self.dev.read(sector, &self.fat_cache) catch return error.Io;
        self.fat_cache_sector = sector;
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

    // The cluster count is what defines the FAT width — not the partition type
    // byte, not the OEM string. This is the specification's own rule and the
    // only reliable one.
    const kind: Kind = if (cluster_count < 4085)
        .fat12
    else if (cluster_count < 65525)
        .fat16
    else
        .fat32;

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
    };
}

/// Decode the 8.3 name in a directory entry into "NAME.EXT".
fn decodeName(raw: *const [11]u8, out: *[12]u8) usize {
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
                // 0xE5 marks a deleted entry.
                if (raw.name[0] == 0xE5) continue;
                // Long-filename entries are skipped: the short name beside them
                // is enough for now, and LFN reassembly is a separate concern.
                if (raw.attr & ATTR_LONG_NAME == ATTR_LONG_NAME) continue;
                if (raw.attr & ATTR_VOLUME_ID != 0) continue;

                var entry = Entry{
                    .name = undefined,
                    .name_len = 0,
                    .is_dir = raw.attr & ATTR_DIRECTORY != 0,
                    .size = raw.size,
                    .cluster = raw.firstCluster(),
                };
                entry.name_len = decodeName(&raw.name, &entry.name);
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

/// Look up a name in the root directory.
///
/// Flat for now: no path walking, because nothing yet needs subdirectories and
/// an untested path parser is a liability.
pub fn lookup(vol: *Volume, name: []const u8) Error!Entry {
    var it = rootIterator(vol);
    while (try it.next()) |entry| {
        if (nameMatches(entry.nameSlice(), name)) return entry;
    }
    return error.NotFound;
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
