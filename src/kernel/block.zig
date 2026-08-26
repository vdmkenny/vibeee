//! Block device abstraction and partition discovery.
//!
//! Kernel core defines the shape of a block device; drivers implement it and
//! the composition root introduces them. Nothing here knows about ATA, USB or
//! any other transport — which is what lets the same partition and filesystem
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
        return w(self.ctx, self.offset + lba, buf);
    }

    pub fn flush(self: *const Device) Error!void {
        const f = self.ops.flush orelse return;
        return f(self.ctx);
    }

    pub fn bytes(self: *const Device) u64 {
        return self.sectors * SECTOR_SIZE;
    }
};

/// Registered devices, whole disks and partitions alike. A fixed table rather
/// than a list: this machine has one internal disk and a handful of removable
/// ones, and a static bound removes an allocation from the boot path.
var devices: [16]Device = undefined;
var device_count: usize = 0;

pub fn register(dev: Device) void {
    if (device_count >= devices.len) {
        console.warn("block: device table full, dropping {s}", .{dev.name});
        return;
    }
    devices[device_count] = dev;
    device_count += 1;
}

pub fn list() []const Device {
    return devices[0..device_count];
}

pub fn find(name: []const u8) ?*const Device {
    for (devices[0..device_count]) |*d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}

// ---------------------------------------------------------------------------
// MBR partitions
// ---------------------------------------------------------------------------

const MBR_SIGNATURE: u16 = 0xAA55;
const PARTITION_TABLE_OFFSET = 0x1BE;

pub const PartitionType = enum(u8) {
    empty = 0x00,
    fat16 = 0x06,
    fat32_chs = 0x0B,
    fat32_lba = 0x0C,
    fat16_lba = 0x0E,
    linux = 0x83,
    efi_system = 0xEF,
    _,

    pub fn isFat(self: PartitionType) bool {
        return switch (self) {
            .fat16, .fat32_chs, .fat32_lba, .fat16_lba => true,
            else => false,
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

/// Names for partitions, built as "<disk>p<n>". Static storage because a
/// Device holds a slice and partitions outlive any scratch buffer.
var name_storage: [16][16]u8 = undefined;
var names_used: usize = 0;

fn partitionName(disk: []const u8, index: usize) []const u8 {
    if (names_used >= name_storage.len) return "part";
    const buf = &name_storage[names_used];
    names_used += 1;
    return std.fmt.bufPrint(buf, "{s}p{d}", .{ disk, index + 1 }) catch "part";
}

/// True if sector 0 looks like a filesystem boot sector rather than a
/// partition table.
///
/// Removable media is very often "superfloppy" formatted — a filesystem
/// starting at sector 0 with no partition table at all — and such a sector
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
        console.debug("block", "{s}: no boot signature, treating as unpartitioned", .{disk.name});
        return 0;
    }

    if (looksLikeBootSector(&sector)) {
        console.debug("block", "{s}: filesystem at sector 0, no partition table", .{disk.name});
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

        found += 1;
        register(.{
            .name = partitionName(disk.name, i),
            .ctx = disk.ctx,
            .ops = disk.ops,
            .sectors = raw.sectors,
            .offset = disk.offset + raw.lba_first,
            .read_only = disk.read_only,
        });

        console.debug("block", "{s}p{d} type {x:0>2} lba {d} +{d} ({d} MiB)", .{
            disk.name,
            i + 1,
            raw.type,
            raw.lba_first,
            raw.sectors,
            @as(u64, raw.sectors) * SECTOR_SIZE / (1024 * 1024),
        });
    }

    return found;
}

/// Devices with no partition table that should still be considered for
/// mounting. Tracked separately so the mount pass can tell "whole disk holding
/// a filesystem" from "whole disk that merely contains partitions".
var whole_disk_usable: [16]bool = @splat(false);

pub fn markWholeDiskUsable(disk: *const Device) void {
    for (devices[0..device_count], 0..) |*d, i| {
        if (d == disk or std.mem.eql(u8, d.name, disk.name)) {
            whole_disk_usable[i] = true;
            return;
        }
    }
}

pub fn isMountCandidate(index: usize) bool {
    if (index >= device_count) return false;
    // Partitions always; whole disks only when they hold a filesystem directly.
    return devices[index].offset != 0 or whole_disk_usable[index];
}

pub fn partitionTypeOf(disk: *const Device, index: usize) ?PartitionType {
    var sector: [SECTOR_SIZE]u8 = undefined;
    disk.read(0, &sector) catch return null;
    if (std.mem.readInt(u16, sector[510..512], .little) != MBR_SIGNATURE) return null;
    if (index >= 4) return null;
    const raw: *align(1) const RawEntry = @ptrCast(&sector[PARTITION_TABLE_OFFSET + index * 16]);
    return @enumFromInt(raw.type);
}
