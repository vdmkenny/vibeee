//! SMBIOS/DMI table discovery.
//!
//! The kernel's job here is deliberately small: find the table and hand out the
//! raw bytes. Decoding the several dozen structure types belongs in userspace,
//! where `dmidecode` can be as thorough as it likes without any of it living in
//! kernel memory forever.
//!
//! On the target this is where the machine identifies itself — DMI product name
//! "701", which is what the Linux eeepc-laptop driver keys its quirks on, and
//! what tells this kernel it is running on the hardware it was designed for
//! rather than something that merely resembles it.

const std = @import("std");
const console = @import("../../kernel/console.zig");
const hal = @import("../../kernel/hal.zig");

/// The 32-bit entry point, anchored on "_SM_".
const EntryPoint = extern struct {
    anchor: [4]u8,
    checksum: u8,
    length: u8,
    major: u8,
    minor: u8,
    max_structure_size: u16 align(1),
    revision: u8,
    formatted: [5]u8,
    intermediate_anchor: [5]u8,
    intermediate_checksum: u8,
    table_length: u16 align(1),
    table_address: u32 align(1),
    structure_count: u16 align(1),
    bcd_revision: u8,
};

/// Header shared by every structure in the table.
pub const Header = extern struct {
    type: u8,
    length: u8,
    handle: u16 align(1),
};

pub const Info = struct {
    table: []const u8,
    structure_count: u16,
    major: u8,
    minor: u8,
};

var info: ?Info = null;

pub fn get() ?Info {
    return info;
}

/// Locate the table by scanning the BIOS ROM area.
///
/// 16-byte aligned between 0xF0000 and 0xFFFFF, which the specification
/// requires. UEFI machines pass the address in a configuration table instead,
/// but nothing this targets is UEFI.
pub fn init() void {
    const start: usize = 0xF0000;
    const end: usize = 0x100000;

    var p = start;
    while (p + @sizeOf(EntryPoint) <= end) : (p += 16) {
        const candidate: [*]const u8 = @ptrFromInt(hal.physToVirt(p));
        if (!std.mem.eql(u8, candidate[0..4], "_SM_")) continue;

        const ep: *align(1) const EntryPoint = @ptrCast(candidate);
        if (ep.length == 0 or ep.length > 64) continue;
        if (!checksumOk(candidate[0..ep.length])) continue;

        if (ep.table_address == 0 or ep.table_length == 0) continue;
        if (!hal.isLinearPhys(ep.table_address)) continue;

        const table: [*]const u8 = @ptrFromInt(hal.physToVirt(ep.table_address));
        info = .{
            .table = table[0..ep.table_length],
            .structure_count = ep.structure_count,
            .major = ep.major,
            .minor = ep.minor,
        };

        console.debug("smbios", "{d}.{d}, {d} structures, {d} bytes", .{
            ep.major, ep.minor, ep.structure_count, ep.table_length,
        });
        return;
    }
}

fn checksumOk(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum == 0;
}

/// Walk to the structure of a given type and return its string at `index`.
///
/// Strings follow a structure's formatted area as a run of NUL-terminated
/// bytes, numbered from one, terminated by a second NUL. Index zero means "no
/// string", which is why the numbering starts at one.
pub fn stringOf(structure_type: u8, index: u8) ?[]const u8 {
    const i = info orelse return null;
    if (index == 0) return null;

    var offset: usize = 0;
    while (offset + @sizeOf(Header) <= i.table.len) {
        const hdr: *align(1) const Header = @ptrCast(&i.table[offset]);
        if (hdr.length < @sizeOf(Header)) return null;

        // End-of-table marker.
        if (hdr.type == 127) return null;

        const strings_start = offset + hdr.length;
        if (hdr.type == structure_type) {
            return nthString(i.table, strings_start, index);
        }

        offset = endOfStrings(i.table, strings_start) orelse return null;
    }
    return null;
}

fn nthString(table: []const u8, start: usize, index: u8) ?[]const u8 {
    var pos = start;
    var n: u8 = 1;
    while (pos < table.len) {
        const len = std.mem.indexOfScalarPos(u8, table, pos, 0) orelse return null;
        if (len == pos) return null; // empty string means the set has ended
        if (n == index) return table[pos..len];
        n += 1;
        pos = len + 1;
    }
    return null;
}

fn endOfStrings(table: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos + 1 < table.len) {
        if (table[pos] == 0 and table[pos + 1] == 0) return pos + 2;
        pos += 1;
    }
    return null;
}

/// System information (type 1) fields, by string index.
pub fn systemManufacturer() ?[]const u8 {
    return stringOf(1, fieldAt(1, 0x04) orelse return null);
}

pub fn systemProduct() ?[]const u8 {
    return stringOf(1, fieldAt(1, 0x05) orelse return null);
}

pub fn biosVendor() ?[]const u8 {
    return stringOf(0, fieldAt(0, 0x04) orelse return null);
}

pub fn biosVersion() ?[]const u8 {
    return stringOf(0, fieldAt(0, 0x05) orelse return null);
}

/// Total installed memory and how it is fitted, from the Memory Device
/// structures (type 17).
///
/// Reported separately from what the allocator sees: the firmware knows what is
/// physically present, while the allocator knows what survived the memory map.
/// A discrepancy between them is worth being able to see.
pub const MemoryHardware = struct {
    total_mb: u32 = 0,
    devices: u8 = 0,
    speed_mhz: u16 = 0,
    /// SMBIOS memory type code; 0 when unknown.
    kind: u8 = 0,

    pub fn typeName(self: MemoryHardware) []const u8 {
        return switch (self.kind) {
            0x12 => "DDR",
            0x13 => "DDR2",
            0x14 => "DDR2 FB-DIMM",
            0x18 => "DDR3",
            0x1A => "DDR4",
            0x0F => "SDRAM",
            0x07 => "RAM",
            else => "",
        };
    }
};

pub fn memoryHardware() ?MemoryHardware {
    const i = info orelse return null;
    var result = MemoryHardware{};

    var offset: usize = 0;
    while (offset + @sizeOf(Header) <= i.table.len) {
        const hdr: *align(1) const Header = @ptrCast(&i.table[offset]);
        if (hdr.length < @sizeOf(Header) or hdr.type == 127) break;

        if (hdr.type == 17 and hdr.length > 0x0D) {
            const raw = @as(u16, i.table[offset + 0x0C]) | (@as(u16, i.table[offset + 0x0D]) << 8);
            // 0 means the slot is empty, 0xFFFF that the size is unknown.
            if (raw != 0 and raw != 0xFFFF) {
                // Bit 15 set means the value is kilobytes rather than megabytes.
                result.total_mb += if (raw & 0x8000 != 0)
                    @as(u32, raw & 0x7FFF) / 1024
                else
                    raw;
                result.devices += 1;

                if (hdr.length > 0x12 and result.kind == 0) result.kind = i.table[offset + 0x12];
                if (hdr.length > 0x16 and result.speed_mhz == 0) {
                    result.speed_mhz = @as(u16, i.table[offset + 0x15]) |
                        (@as(u16, i.table[offset + 0x16]) << 8);
                }
            }
        }

        offset = endOfStrings(i.table, offset + hdr.length) orelse break;
    }

    return if (result.devices > 0) result else null;
}

/// Read one byte from a structure's formatted area.
fn fieldAt(structure_type: u8, field_offset: usize) ?u8 {
    const i = info orelse return null;

    var offset: usize = 0;
    while (offset + @sizeOf(Header) <= i.table.len) {
        const hdr: *align(1) const Header = @ptrCast(&i.table[offset]);
        if (hdr.length < @sizeOf(Header) or hdr.type == 127) return null;

        if (hdr.type == structure_type) {
            if (field_offset >= hdr.length) return null;
            return i.table[offset + field_offset];
        }
        offset = endOfStrings(i.table, offset + hdr.length) orelse return null;
    }
    return null;
}
