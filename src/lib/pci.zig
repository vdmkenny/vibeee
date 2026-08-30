//! PCI configuration addressing, pure.
//!
//! The half of reaching configuration space that is arithmetic rather than
//! hardware: where a device sits on the bus (bus, device, function), and the
//! mechanism-one address its registers answer at. Kept pure so it is testable
//! on the host and shareable by every driver server that will use it, while
//! the port dance itself lives in userspace where the grant is.
//!
//! A location is one u16 in exactly the lanes mechanism one puts them in,
//! which is what lets a location travel as a plain number through a manifest
//! or a channel and be reconstituted without string parsing at the far end.

const std = @import("std");

pub const Location = packed struct(u16) {
    /// 0..7. The PCI way of saying there are eight "functions" behind a device.
    function: u3,
    /// 0..31. A device is a slot behind a bus; both are in the name.
    device: u5,
    /// 0..255.
    bus: u8,

    /// The mechanism-one address `register` answers at. Register addresses are
    /// dword-granular, so the low two bits do not exist and are not sent.
    pub fn address(self: Location, register: u8) u32 {
        return 0x8000_0000 |
            (@as(u32, self.bus) << 16) |
            (@as(u32, self.device) << 11) |
            (@as(u32, self.function) << 8) |
            (@as(u32, register) & 0xFC);
    }

    /// The compact BDF form used by the userspace PCI syscalls.
    pub fn encode(self: Location) u16 {
        return @bitCast(self);
    }

    pub fn fromComponents(bus: usize, device: usize, function: usize) ?Location {
        if (bus > std.math.maxInt(u8) or
            device > std.math.maxInt(u5) or
            function > std.math.maxInt(u3)) return null;
        return .{
            .bus = @intCast(bus),
            .device = @intCast(device),
            .function = @intCast(function),
        };
    }
};

pub const COMMAND_OFFSET: u8 = 0x04;
pub const BAR0_OFFSET: u8 = 0x10;
pub const HEADER_TYPE_OFFSET: u8 = 0x0E;
pub const INTERRUPT_LINE_OFFSET: u8 = 0x3C;
pub const INTERRUPT_PIN_OFFSET: u8 = 0x3D;

pub const BarSpace = enum(u1) { memory, io };
pub const MemoryBarKind = enum(u2) {
    bits32 = 0,
    below_one_megabyte = 1,
    bits64 = 2,
    reserved = 3,
};

pub const MemoryBar = packed struct(u32) {
    space: BarSpace,
    kind: MemoryBarKind,
    prefetchable: bool,
    address: u28,

    pub fn base(self: MemoryBar) u32 {
        return @as(u32, self.address) << 4;
    }
};

pub const IoBar = packed struct(u32) {
    io_space: bool,
    reserved: bool,
    address_dwords: u30,

    pub fn base(self: IoBar) u32 {
        return @as(u32, self.address_dwords) * @sizeOf(u32);
    }
};

/// The writable half of PCI configuration dword 1. The upper half is status
/// with write-one-to-clear bits, so command updates must write this word with
/// zeroes above it rather than echoing a dword read back.
pub const Command = packed struct(u16) {
    io_space: bool = false,
    memory_space: bool = false,
    bus_master: bool = false,
    special_cycles: bool = false,
    memory_write_invalidate: bool = false,
    vga_palette_snoop: bool = false,
    parity_response: bool = false,
    stepping: bool = false,
    serr_enable: bool = false,
    fast_back_to_back: bool = false,
    interrupt_disable: bool = false,
    _reserved: u5 = 0,
};

/// PCI configuration byte 0x3d. ACPI _PRT numbers the same pins from zero,
/// while configuration space numbers them from one.
/// Where the capability list starts, in the register whose low byte is the
/// pointer.
pub const CAPABILITIES_OFFSET: u8 = 0x34;

pub const CapabilityPointer = packed struct(u32) {
    pointer: u8,
    _rest: u24,
};

/// One capability list entry, as configuration space lays it out: what it
/// is, where the next one starts, and the two bytes each capability defines
/// for itself.
pub const Capability = packed struct(u32) {
    id: CapabilityId,
    next: u8,
    control: u16,
};

pub const CapabilityId = enum(u8) {
    power_management = 0x01,
    msi = 0x05,
    pcie = 0x10,
    _,
};

/// The PCI Express capability's Device Control and Device Status pair, for
/// the error-reporting enables a driver masks.
pub const PcieDeviceControl = packed struct(u32) {
    correctable_report: bool,
    non_fatal_report: bool,
    fatal_report: bool,
    unsupported_report: bool,
    _control: u12,
    _status: u16,

    /// Device Control's offset within the capability.
    pub const OFFSET: u8 = 0x08;
};

/// The PCI Express capability's Link Control and Link Status pair, for the
/// power-management states a driver refuses.
pub const PcieLinkControl = packed struct(u32) {
    /// Active-state link power management: L0s and L1 entry. Zero keeps the
    /// link in L0, awake, for silicon whose low-power states hang.
    aspm: u2,
    _control: u14,
    _status: u16,

    /// Link Control's offset within the capability.
    pub const OFFSET: u8 = 0x10;
};

pub const InterruptPin = enum(u8) {
    none = 0,
    inta = 1,
    intb = 2,
    intc = 3,
    intd = 4,
    _,

    pub fn acpiIndex(self: InterruptPin) ?u2 {
        return switch (self) {
            .inta => 0,
            .intb => 1,
            .intc => 2,
            .intd => 3,
            else => null,
        };
    }
};

/// "00:03.0" as a location, or null when the text is not that shape.
pub fn parse(text: []const u8) ?Location {
    if (text.len != 7) return null;
    if (text[2] != ':' or text[5] != '.') return null;
    if (!std.ascii.isHex(text[0]) or !std.ascii.isHex(text[1])) return null;
    if (!std.ascii.isHex(text[3]) or !std.ascii.isHex(text[4])) return null;
    if (!std.ascii.isDigit(text[6])) return null;

    const bus = std.fmt.parseInt(u8, text[0..2], 16) catch return null;
    const device = std.fmt.parseInt(u8, text[3..5], 16) catch return null;
    const function = std.fmt.parseInt(u8, text[6..7], 10) catch return null;
    return Location.fromComponents(bus, device, function);
}

/// The location, spelled the way `parse` reads it: "03:00.0".
pub fn spell(at: Location, into: *[8]u8) []const u8 {
    var w = std.Io.Writer.fixed(into);
    w.print("{x:0>2}:{x:0>2}.{d}", .{ at.bus, at.device, at.function }) catch return "";
    return into[0..w.end];
}

comptime {
    // A location is one word, so it can travel as a number.
    if (@sizeOf(Location) != 2) @compileError("a PCI location must be one word");
    if (@sizeOf(Command) != 2) @compileError("the PCI command register must be one word");
    if (@sizeOf(MemoryBar) != 4 or @sizeOf(IoBar) != 4) {
        @compileError("a PCI BAR must be one dword");
    }
    if (@bitOffsetOf(Command, "bus_master") != 2 or
        @bitOffsetOf(Command, "interrupt_disable") != 10)
    {
        @compileError("PCI command fields do not match configuration space");
    }
}

const testing = std.testing;

test "the lanes of a location are the ones mechanism one expects" {
    const loc = Location{ .bus = 0x21, .device = 0x0F, .function = 5 };

    // Bit 31 selects configuration space, and the bus, device and function
    // lanes are laid out per the specification.
    try testing.expectEqual(@as(u32, 0x8000_0000 | (0x21 << 16) | (0x0F << 11) | (5 << 8)), loc.address(0));
    try testing.expectEqual(@as(u16, 0x217D), loc.encode());
}

test "location components are range checked" {
    try testing.expect(Location.fromComponents(255, 31, 7) != null);
    try testing.expect(Location.fromComponents(256, 0, 0) == null);
    try testing.expect(Location.fromComponents(0, 32, 0) == null);
    try testing.expect(Location.fromComponents(0, 0, 8) == null);
}

test "register addresses are dword-granular" {
    const loc = Location{ .bus = 0, .device = 3, .function = 0 };

    // The low two bits of a register do not exist in mechanism one.
    try testing.expectEqual(loc.address(0x10), loc.address(0x13));
    try testing.expectEqual(@as(u32, 0x8000_00FC | (3 << 11)), loc.address(0xFC));
}

test "a location parses from its printed form" {
    const loc = parse("00:03.0");
    try testing.expect(loc != null);
    try testing.expectEqual(@as(u8, 0), loc.?.bus);
    try testing.expectEqual(@as(u8, 3), loc.?.device);
    try testing.expectEqual(@as(u8, 0), loc.?.function);

    try testing.expect(parse("1c:1f.7").?.function == 7);
    try testing.expectEqual(parse("00:03"), null);
    try testing.expectEqual(parse("zz:03.0"), null);
    try testing.expectEqual(parse("00:20.0"), null);
    try testing.expectEqual(parse("00:03.8"), null);
    try testing.expectEqual(parse("00:03.0extra"), null);
}

test "PCI interrupt pins translate to ACPI indices" {
    try std.testing.expectEqual(@as(?u2, 0), InterruptPin.inta.acpiIndex());
    try std.testing.expectEqual(@as(?u2, 3), InterruptPin.intd.acpiIndex());
    try std.testing.expectEqual(@as(?u2, null), InterruptPin.none.acpiIndex());
}
