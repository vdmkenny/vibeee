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
};

/// "00:03.0" as a location, or null when the text is not that shape.
pub fn parse(text: []const u8) ?Location {
    if (text.len < 7) return null;
    if (text[2] != ':' or text[5] != '.') return null;
    if (!std.ascii.isHex(text[0]) or !std.ascii.isHex(text[1])) return null;
    if (!std.ascii.isHex(text[3]) or !std.ascii.isHex(text[4])) return null;
    if (!std.ascii.isDigit(text[6])) return null;

    return .{
        .bus = std.fmt.parseInt(u8, text[0..2], 16) catch return null,
        .device = @intCast(std.fmt.parseInt(u8, text[3..5], 16) catch return null),
        .function = @intCast(std.fmt.parseInt(u8, text[6..7], 10) catch return null),
    };
}

comptime {
    // A location is one word, so it can travel as a number.
    if (@sizeOf(Location) != 2) @compileError("a PCI location must be one word");
}

const testing = std.testing;

test "the lanes of a location are the ones mechanism one expects" {
    const loc = Location{ .bus = 0x21, .device = 0x0F, .function = 5 };

    // Bit 31 selects configuration space, and the bus, device and function
    // lanes are laid out per the specification.
    try testing.expectEqual(@as(u32, 0x8000_0000 | (0x21 << 16) | (0x0F << 11) | (5 << 8)), loc.address(0));
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

    try testing.expect(parse("1c:1f.7").? .function == 7);
    try testing.expectEqual(parse("00:03"), null);
    try testing.expectEqual(parse("zz:03.0"), null);
}