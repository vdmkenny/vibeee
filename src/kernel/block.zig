//! Block device abstraction and partition discovery.
//!
//! Kernel core defines the shape of a block device; drivers implement it and
//! the composition root introduces them. Nothing here knows about ATA, USB or
//! any other transport, which is what lets the same partition and filesystem
//! code serve the internal SSD, an SD card behind the USB reader, and a
//! ramdisk.

const std = @import("std");
const console = @import("console.zig");

pub const SECTOR_SIZE: usize = 512;

pub const Error = error{
    IoError,
    OutOfRange,
    NotSupported,
    Timeout,
};

pub const Ops = struct {
    read: *const fn (ctx: *anyopaque, lba: u64, buf: []u8) Error!void,
    write: ?*const fn (ctx: *anyopaque, lba: u64, buf: []const u8) Error!void = null,
    flush: ?*const fn (ctx: *anyopaque) Error!void = null,
};

pub const Device = struct {
    name: []const u8,
    ctx: *anyopaque,
    ops: *const Ops,
    /// Total addressable sectors.
    sectors: u64,
    /// Set for a partition; zero for a whole device.
    offset: u64 = 0,
    read_only: bool = false,
    /// Backed by memory, so everything written to it is gone at the next boot.
    ///
    /// Not a property anything here has to act on, and one a caller often has
    /// to: a program that saves a choice on a volatile volume has saved it
    /// until the machine is switched off, and should be able to say so rather
    /// than appear to have done what was asked.
    is_volatile: bool = false,
    /// The medium is gone and the entry is only still here because the
    /// table does not move: a device that was unplugged answers nothing
    /// and is skipped by every walk.
    retired: bool = false,
    /// Whether anything has been written since the device was registered.
    /// Nothing to commit means nothing to flush, and a drive asked to flush a
    /// cache it never filled can only answer with an error it does not owe.
    written: bool = false,

    /// Writing goes through a partition to the drive underneath, so the drive
    /// is what has to remember it, not the window onto it.
    fn markWritten(self: *const Device) void {
        const mutable: *Device = @constCast(self);
        mutable.written = true;
        // A partition is a window onto a drive, and the drive is what has
        // to remember it.
        const place = partitionOf(self) orelse return;
        @constCast(place.disk).written = true;
    }

    pub fn read(self: *const Device, lba: u64, buf: []u8) Error!void {
        if (buf.len % SECTOR_SIZE != 0) return error.NotSupported;
        const count = buf.len / SECTOR_SIZE;
        if (lba + count > self.sectors) return error.OutOfRange;
        return self.ops.read(self.ctx, self.offset + lba, buf);
    }

    pub fn write(self: *const Device, lba: u64, buf: []const u8) Error!void {
        if (self.read_only) return error.NotSupported;
        if (buf.len % SECTOR_SIZE != 0) return error.NotSupported;
        const count = buf.len / SECTOR_SIZE;
        if (lba + count > self.sectors) return error.OutOfRange;
        const w = self.ops.write orelse return error.NotSupported;
        try w(self.ctx, self.offset + lba, buf);
        self.markWritten();
    }

    pub fn flush(self: *const Device) Error!void {
        const f = self.ops.flush orelse return;
        return f(self.ctx);
    }

    pub fn bytes(self: *const Device) u64 {
        return self.sectors * SECTOR_SIZE;
    }
};

/// How many devices the table holds, whole disks and partitions alike. A
/// fixed table rather than a list: this machine has one internal disk and a
/// handful of removable ones, and a static bound removes an allocation from
/// the boot path.
pub const ROWS = 16;

/// The longest name a row holds: the sixteen bytes a published volume's
/// name may run to, plus the "p" and single digit a primary partition adds.
pub const NAME_MAX = 16 + 2;

pub const RegisterError = error{
    TableFull,
    NameTooLong,
};

/// The device table, and the rules for a row in it. Pure, so the row and
/// name discipline is checked on the host; the module's one instance below
/// is what the kernel uses.
const Table = struct {
    rows: [ROWS]Device = undefined,
    /// Each row's name, kept with the row. A Device holds a slice, and a row
    /// outlives whatever buffer its registrant built the name in. A row
    /// reused for a new device reuses its name storage with it, so a machine
    /// where media come and go all day never runs out of names.
    names: [ROWS][NAME_MAX]u8 = undefined,
    /// Devices with no partition table that should still be considered for
    /// mounting. Tracked separately so the mount pass can tell "whole disk
    /// holding a filesystem" from "whole disk that merely contains
    /// partitions".
    whole_disk_usable: [ROWS]bool = @splat(false),
    count: usize = 0,

    fn list(self: *const Table) []const Device {
        return self.rows[0..self.count];
    }

    /// The row the next device takes: a retired one first, so that plugging
    /// and unplugging never grows the table, else the first never used.
    /// Null when the table is full.
    fn freeRow(self: *const Table) ?usize {
        for (self.list(), 0..) |*d, i| {
            if (d.retired) return i;
        }
        return if (self.count < ROWS) self.count else null;
    }

    /// Put a device in the table under the table's own copy of its name,
    /// returning the row it took.
    fn place(self: *Table, dev: Device) RegisterError!*const Device {
        if (dev.name.len > NAME_MAX) return error.NameTooLong;
        const row = self.freeRow() orelse return error.TableFull;

        const name = self.names[row][0..dev.name.len];
        @memcpy(name, dev.name);
        self.rows[row] = dev;
        self.rows[row].name = name;
        self.whole_disk_usable[row] = false;
        if (row == self.count) self.count += 1;
        return &self.rows[row];
    }

    /// Retire every row sharing a context.
    fn retire(self: *Table, ctx: *anyopaque) void {
        for (self.rows[0..self.count], 0..) |*d, i| {
            if (d.retired or d.ctx != ctx) continue;
            d.retired = true;
            self.whole_disk_usable[i] = false;
        }
    }

    fn find(self: *const Table, name: []const u8) ?*const Device {
        for (self.list()) |*d| {
            if (!d.retired and std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    fn markWholeDiskUsable(self: *Table, disk: *const Device) void {
        for (self.list(), 0..) |*d, i| {
            if (d == disk or std.mem.eql(u8, d.name, disk.name)) {
                self.whole_disk_usable[i] = true;
                return;
            }
        }
    }

    fn isMountCandidate(self: *const Table, index: usize) bool {
        if (index >= self.count or self.rows[index].retired) return false;
        // Partitions always; whole disks only when they hold a filesystem
        // directly.
        return self.rows[index].offset != 0 or self.whole_disk_usable[index];
    }

    /// A partition's place, or null for a whole device. Partitions carry
    /// their parent's context, which is the link between them, and the scan
    /// names a partition after the disk it came from, so the number is read
    /// back from the name that named it.
    fn partitionOf(self: *const Table, part: *const Device) ?Partition {
        if (part.offset == 0) return null;
        for (self.list()) |*disk| {
            if (disk.offset != 0 or disk.retired or disk.ctx != part.ctx) continue;
            if (part.name.len <= disk.name.len + 1) return null;
            if (!std.mem.startsWith(u8, part.name, disk.name)) return null;
            if (part.name[disk.name.len] != 'p') return null;
            const number = std.fmt.parseInt(u8, part.name[disk.name.len + 1 ..], 10) catch return null;
            return .{ .disk = disk, .number = number };
        }
        return null;
    }
};

var table: Table = .{};

/// Put a device in the table, or say why it could not be. A device that is
/// quietly not there is worse than one the log says was dropped.
fn admit(dev: Device) bool {
    _ = table.place(dev) catch |err| {
        switch (err) {
            error.TableFull => console.warn("block: device table full, dropping {s}", .{dev.name}),
            error.NameTooLong => console.warn("block: name too long, dropping {s}", .{dev.name}),
        }
        return false;
    };
    return true;
}

pub fn register(dev: Device) void {
    _ = admit(dev);
}

/// The medium behind these devices is gone. Everything sharing the
/// context goes: a whole disk and the partitions cut from it are one
/// medium, and half of one is no use to anybody.
///
/// The caller unmounts first. Retiring a device something still reads
/// would leave that reader holding a row that answers nothing.
pub fn retire(ctx: *anyopaque) void {
    table.retire(ctx);
}

pub fn list() []const Device {
    return table.list();
}

pub fn find(name: []const u8) ?*const Device {
    return table.find(name);
}

// ---------------------------------------------------------------------------
// MBR partitions
// ---------------------------------------------------------------------------

const MBR_SIGNATURE: u16 = 0xAA55;
const PARTITION_TABLE_OFFSET = 0x1BE;

pub const PartitionType = enum(u8) {
    empty = 0x00,
    fat16 = 0x06,
    /// NTFS, and also HPFS and exFAT, which all share the byte.
    ntfs = 0x07,
    fat32_chs = 0x0B,
    fat32_lba = 0x0C,
    fat16_lba = 0x0E,
    linux = 0x83,
    /// On this machine's firmware, the partition the BIOS writes its POST
    /// cache into. Left alone by decision, not by inability.
    efi_system = 0xEF,
    _,

    pub fn isFat(self: PartitionType) bool {
        return switch (self) {
            .fat16, .fat32_chs, .fat32_lba, .fat16_lba => true,
            else => false,
        };
    }

    /// Why a partition of this type holds nothing this can mount. Null when it
    /// is one that can be.
    pub fn whyUnreadable(self: PartitionType) ?[]const u8 {
        return switch (self) {
            .fat16, .fat32_chs, .fat32_lba, .fat16_lba => null,
            .empty => "empty",
            .ntfs => "ntfs, no driver",
            .linux => "linux, no driver",
            .efi_system => "firmware's, left alone",
            _ => "not a filesystem this reads",
        };
    }
};

const RawEntry = extern struct {
    status: u8,
    chs_first: [3]u8,
    type: u8,
    chs_last: [3]u8,
    lba_first: u32 align(1),
    sectors: u32 align(1),
};

/// A partition's name: its disk's, then "p" and its number, counted from one
/// the way the table does. Refused when it would not fit a row, since a name
/// cut short would name some other partition.
fn partitionName(buf: *[NAME_MAX]u8, disk: []const u8, number: usize) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "{s}p{d}", .{ disk, number }) catch error.NameTooLong;
}

/// True if sector 0 looks like a filesystem boot sector rather than a
/// partition table.
///
/// Removable media is very often "superfloppy" formatted, a filesystem
/// starting at sector 0 with no partition table at all, and such a sector
/// still carries the 0xAA55 signature. Reading its BPB bytes as a partition
/// table produces convincing nonsense, so the two cases have to be told apart
/// by content: a boot sector begins with a jump instruction and declares a
/// plausible sector size and media descriptor.
fn looksLikeBootSector(sector: *const [SECTOR_SIZE]u8) bool {
    const jump_short = sector[0] == 0xEB and sector[2] == 0x90;
    const jump_near = sector[0] == 0xE9;
    if (!jump_short and !jump_near) return false;

    const bytes_per_sector = std.mem.readInt(u16, sector[11..13], .little);
    if (bytes_per_sector != 512 and bytes_per_sector != 1024 and
        bytes_per_sector != 2048 and bytes_per_sector != 4096) return false;

    const sectors_per_cluster = sector[13];
    if (sectors_per_cluster == 0 or sectors_per_cluster & (sectors_per_cluster - 1) != 0) return false;

    // 0xF0 for removable media, 0xF8 for fixed disks; other values are legacy
    // floppy geometries.
    return sector[21] >= 0xF0;
}

/// Read the MBR and register each non-empty partition as its own device.
/// Returns how many partitions were registered.
///
/// Only the primary table: extended partitions are not used by our own image
/// layout, and adding them before anything needs them would be untested code.
pub fn scanPartitions(disk: *const Device) usize {
    var sector: [SECTOR_SIZE]u8 = undefined;
    disk.read(0, &sector) catch {
        console.warn("block: cannot read sector 0 of {s}", .{disk.name});
        return 0;
    };

    const signature = std.mem.readInt(u16, sector[510..512], .little);
    if (signature != MBR_SIGNATURE) {
        console.info("block", "{s}: no boot signature, treating as unpartitioned", .{disk.name});
        return 0;
    }

    if (looksLikeBootSector(&sector)) {
        console.info("block", "{s}: filesystem at sector 0, no partition table", .{disk.name});
        return 0;
    }

    var found: usize = 0;

    for (0..4) |i| {
        const raw: *align(1) const RawEntry = @ptrCast(&sector[PARTITION_TABLE_OFFSET + i * 16]);
        if (raw.type == 0 or raw.sectors == 0) continue;

        // A partition claiming to extend past the disk is a corrupt or hostile
        // table; skipping it beats handing out a device that reads garbage.
        if (raw.lba_first >= disk.sectors or
            @as(u64, raw.lba_first) + raw.sectors > disk.sectors)
        {
            console.warn("block: {s} partition {d} extends past the disk", .{ disk.name, i + 1 });
            continue;
        }

        // Built on the stack and copied into the row it takes: the table
        // owns the names of its rows.
        var name_buf: [NAME_MAX]u8 = undefined;
        const name = partitionName(&name_buf, disk.name, i + 1) catch {
            console.warn("block: {s} partition {d}: name does not fit", .{ disk.name, i + 1 });
            continue;
        };
        if (!admit(.{
            .name = name,
            .ctx = disk.ctx,
            .ops = disk.ops,
            .sectors = raw.sectors,
            .offset = disk.offset + raw.lba_first,
            .read_only = disk.read_only,
        })) continue;
        found += 1;

        // Named rather than numbered where the type is one we know, and said
        // outright when it holds something this cannot read: a partition that
        // simply never appears leaves a reader wondering whether the disk was
        // seen at all.
        const kind: PartitionType = @enumFromInt(raw.type);
        console.info("block", "{s}p{d} type {x:0>2} lba {d} +{d} ({d} MiB){s}{s}", .{
            disk.name,
            i + 1,
            raw.type,
            raw.lba_first,
            raw.sectors,
            @as(u64, raw.sectors) * SECTOR_SIZE / (1024 * 1024),
            if (kind.whyUnreadable() == null) "" else ", ",
            kind.whyUnreadable() orelse "",
        });
    }

    return found;
}

pub fn markWholeDiskUsable(disk: *const Device) void {
    table.markWholeDiskUsable(disk);
}

/// The signature the partition table carries, which is how a medium is
/// told apart from another of the same size and shape. The boot loader
/// records the one it read from, so this is what matches a disk to it.
pub fn signatureOf(disk: *const Device) ?u32 {
    var sector: [SECTOR_SIZE]u8 = undefined;
    disk.read(0, &sector) catch return null;
    if (std.mem.readInt(u16, sector[510..512], .little) != MBR_SIGNATURE) return null;
    return std.mem.readInt(u32, sector[0x1B8..][0..4], .little);
}

/// Where a partition sits: the disk it was cut from, and which of that
/// disk's it is.
pub const Partition = struct {
    disk: *const Device,
    /// Counting the way the table does, from one.
    number: u8,
};

/// A partition's place, or null for a whole device.
pub fn partitionOf(part: *const Device) ?Partition {
    return table.partitionOf(part);
}

pub fn isMountCandidate(index: usize) bool {
    return table.isMountCandidate(index);
}

pub fn partitionTypeOf(disk: *const Device, index: usize) ?PartitionType {
    var sector: [SECTOR_SIZE]u8 = undefined;
    disk.read(0, &sector) catch return null;
    if (std.mem.readInt(u16, sector[510..512], .little) != MBR_SIGNATURE) return null;
    if (index >= 4) return null;
    const raw: *align(1) const RawEntry = @ptrCast(&sector[PARTITION_TABLE_OFFSET + index * 16]);
    return @enumFromInt(raw.type);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A device that answers nothing, for tests of the table alone.
const test_ops = Ops{ .read = struct {
    fn read(_: *anyopaque, _: u64, _: []u8) Error!void {
        return error.IoError;
    }
}.read };

fn testDisk(ctx: *anyopaque, name: []const u8) Device {
    return .{ .name = name, .ctx = ctx, .ops = &test_ops, .sectors = 100 };
}

test "a row reused after its medium is gone reuses its name with it" {
    var t = Table{};
    var medium: u8 = 0;
    var name_buf: [NAME_MAX]u8 = undefined;

    // Many more insertions than the table has rows: every pass takes the
    // three rows the previous pass retired.
    for (0..3 * ROWS) |_| {
        const disk = try t.place(testDisk(&medium, "hd0"));
        var first = testDisk(&medium, try partitionName(&name_buf, disk.name, 1));
        first.offset = 1;
        const p1 = try t.place(first);
        var second = testDisk(&medium, try partitionName(&name_buf, disk.name, 2));
        second.offset = 11;
        const p2 = try t.place(second);

        try std.testing.expectEqualStrings("hd0p1", p1.name);
        try std.testing.expectEqualStrings("hd0p2", p2.name);
        try std.testing.expectEqual(p1, t.find("hd0p1").?);

        const where = t.partitionOf(p2) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(disk, where.disk);
        try std.testing.expectEqual(@as(u8, 2), where.number);

        t.retire(&medium);
        try std.testing.expectEqual(@as(?*const Device, null), t.find("hd0p1"));
    }
    try std.testing.expectEqual(@as(usize, 3), t.count);
}

test "a name is the table's own copy, not the registrant's buffer" {
    var t = Table{};
    var medium: u8 = 0;
    var scratch: [NAME_MAX]u8 = undefined;
    @memcpy(scratch[0..3], "rd0");
    const placed = try t.place(testDisk(&medium, scratch[0..3]));
    @memcpy(scratch[0..3], "xxx");
    try std.testing.expectEqualStrings("rd0", placed.name);
}

test "a name that does not fit a row is refused rather than cut short" {
    var t = Table{};
    var medium: u8 = 0;
    const long = "v" ** (NAME_MAX + 1);
    try std.testing.expectError(error.NameTooLong, t.place(testDisk(&medium, long)));
    try std.testing.expectEqual(@as(usize, 0), t.count);

    var name_buf: [NAME_MAX]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, partitionName(&name_buf, "v" ** (NAME_MAX - 1), 1));
    const longest = "v" ** (NAME_MAX - 2);
    try std.testing.expectEqualStrings(longest ++ "p4", try partitionName(&name_buf, longest, 4));
}

test "a full table refuses the next device" {
    var t = Table{};
    var medium: u8 = 0;
    for (0..ROWS) |_| _ = try t.place(testDisk(&medium, "hd0"));
    try std.testing.expectError(error.TableFull, t.place(testDisk(&medium, "hd1")));
    try std.testing.expectEqual(@as(usize, ROWS), t.count);
}

test "only a partition, or a whole disk said to hold a filesystem, is mounted" {
    var t = Table{};
    var medium: u8 = 0;
    const disk = try t.place(testDisk(&medium, "hd0"));
    var part = testDisk(&medium, "hd0p1");
    part.offset = 1;
    _ = try t.place(part);

    try std.testing.expect(!t.isMountCandidate(0));
    try std.testing.expect(t.isMountCandidate(1));
    t.markWholeDiskUsable(disk);
    try std.testing.expect(t.isMountCandidate(0));
    t.retire(&medium);
    try std.testing.expect(!t.isMountCandidate(0));
    try std.testing.expect(!t.isMountCandidate(1));
    try std.testing.expect(!t.isMountCandidate(ROWS));
}
