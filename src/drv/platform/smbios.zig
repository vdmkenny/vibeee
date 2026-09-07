//! SMBIOS/DMI table discovery.
//!
//! The kernel's job here is deliberately small: find the table and hand out the
//! raw bytes. Decoding the several dozen structure types belongs in userspace,
//! where `dmidecode` can be as thorough as it likes without any of it living in
//! kernel memory forever.
//!
//! On the target this is where the machine identifies itself: DMI product name
//! "701", which is what the Linux eeepc-laptop driver keys its quirks on, and
//! what tells this kernel it is running on the hardware it was designed for
//! rather than something that merely resembles it.

const std = @import("std");
const console = @import("../../kernel/console.zig");
const hal = @import("../../kernel/hal.zig");
const firmware = @import("lib").firmware;

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
        if (!firmware.checksumOk(candidate[0..ep.length])) continue;

        if (ep.table_address == 0 or ep.table_length == 0) continue;
        if (!hal.isLinearPhys(ep.table_address)) continue;

        const table: [*]const u8 = @ptrFromInt(hal.physToVirt(ep.table_address));
        info = .{
            .table = table[0..ep.table_length],
            .structure_count = ep.structure_count,
            .major = ep.major,
            .minor = ep.minor,
        };

        console.info("smbios", "{d}.{d}, {d} structures, {d} bytes", .{
            ep.major, ep.minor, ep.structure_count, ep.table_length,
        });
        return;
    }
}

/// Walk to the structure of a given type and return its string at `index`.
///
/// Strings follow a structure's formatted area as a run of NUL-terminated
/// bytes, numbered from one, terminated by a second NUL. Index zero means "no
/// string", which is why the numbering starts at one.
pub fn stringOf(structure_type: u8, index: u8) ?[]const u8 {
    if (index == 0) return null;
    var walk = Walk.over(info orelse return null);
    while (walk.next()) |it| {
        if (it.header.type == structure_type) return nthString(walk.table, it.strings, index);
    }
    return null;
}

/// One structure the table holds: its header, its formatted area, and where
/// the strings after it begin.
const Structure = struct {
    header: Header,
    fields: []const u8,
    strings: usize,
};

/// A walk over the table's structures.
///
/// One walk rather than the three that were here, each re-deriving where a
/// structure ends and each deciding for itself what a header too short to be
/// one means. They had already come to differ about that.
const Walk = struct {
    table: []const u8,
    at: usize = 0,

    fn over(i: Info) Walk {
        return .{ .table = i.table };
    }

    fn next(self: *Walk) ?Structure {
        if (self.at + @sizeOf(Header) > self.table.len) return null;

        const header: Header = @bitCast(self.table[self.at..][0..@sizeOf(Header)].*);
        // A header shorter than a header, or the end-of-table marker: either
        // way there is nothing after this one.
        if (header.length < @sizeOf(Header) or header.type == END_OF_TABLE) return null;
        if (self.at + header.length > self.table.len) return null;

        const strings = self.at + header.length;
        const it = Structure{
            .header = header,
            .fields = self.table[self.at..strings],
            .strings = strings,
        };

        self.at = endOfStrings(self.table, strings) orelse self.table.len;
        return it;
    }
};

/// The structure type that says the table has ended.
const END_OF_TABLE: u8 = 127;

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

/// Base board (type 2) fields, for quirks keyed on the board rather than the
/// system as sold.
pub fn boardManufacturer() ?[]const u8 {
    return stringOf(2, fieldAt(2, 0x04) orelse return null);
}

pub fn boardProduct() ?[]const u8 {
    return stringOf(2, fieldAt(2, 0x05) orelse return null);
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

/// One fitted module, as the firmware describes it. Named fields rather than
/// offsets counted out at each read: the offsets are the specification's, and
/// counting them again per field is how one comes to be off by a byte.
const MemoryDevice = extern struct {
    header: Header,
    array_handle: u16 align(1),
    error_handle: u16 align(1),
    total_width: u16 align(1),
    data_width: u16 align(1),
    /// Megabytes, or kilobytes when the top bit is set. Zero is an empty slot
    /// and all ones is a size the firmware does not know.
    size: u16 align(1),
    form_factor: u8,
    device_set: u8,
    device_locator: u8,
    bank_locator: u8,
    kind: u8,
    detail: u16 align(1),
    speed_mhz: u16 align(1),

    const KILOBYTES: u16 = 0x8000;
    const UNKNOWN_SIZE: u16 = 0xFFFF;

    fn megabytes(self: MemoryDevice) u32 {
        if (self.size & KILOBYTES == 0) return self.size;
        return @as(u32, self.size & ~KILOBYTES) / 1024;
    }
};

/// The structure type a fitted module is described by.
const MEMORY_DEVICE: u8 = 17;

comptime {
    // The offsets are the specification's, so the struct has to sit at them
    // with nothing added between: 0x0C is the size and 0x15 the speed.
    if (@offsetOf(MemoryDevice, "size") != 0x0C or
        @offsetOf(MemoryDevice, "kind") != 0x12 or
        @offsetOf(MemoryDevice, "speed_mhz") != 0x15)
    {
        @compileError("a Memory Device's fields have moved off the offsets SMBIOS gives them");
    }
}

pub fn memoryHardware() ?MemoryHardware {
    var result = MemoryHardware{};
    var walk = Walk.over(info orelse return null);

    while (walk.next()) |it| {
        if (it.header.type != MEMORY_DEVICE) continue;
        // A firmware that stops the structure short of a field has not
        // described it, and reading past what it wrote is reading the next
        // structure's bytes.
        if (it.fields.len < @sizeOf(MemoryDevice)) continue;

        const module: MemoryDevice = @bitCast(it.fields[0..@sizeOf(MemoryDevice)].*);
        if (module.size == 0 or module.size == MemoryDevice.UNKNOWN_SIZE) continue;

        result.total_mb += module.megabytes();
        result.devices += 1;
        if (result.kind == 0) result.kind = module.kind;
        if (result.speed_mhz == 0) result.speed_mhz = module.speed_mhz;
    }

    return if (result.devices > 0) result else null;
}

/// Read one byte from a structure's formatted area.
fn fieldAt(structure_type: u8, field_offset: usize) ?u8 {
    var walk = Walk.over(info orelse return null);
    while (walk.next()) |it| {
        if (it.header.type != structure_type) continue;
        if (field_offset >= it.fields.len) return null;
        return it.fields[field_offset];
    }
    return null;
}
