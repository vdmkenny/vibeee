//! A MAC address, spelled the way every interface listing spells one.
//!
//! Pure, so it is host-testable and shared: the service narrates a link with
//! the same text a tool prints, and neither may drift to its own spelling.

const std = @import("std");

/// Six bytes, the name every interface answers to on a wire. Spelled out
/// here so the rest of the system says `mac.Address` rather than counting
/// bytes at each use.
pub const Address = [6]u8;

/// Everyone on the segment at once.
pub const broadcast: Address = @splat(0xFF);

pub fn eql(a: Address, b: Address) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Whether the address names a group rather than one station: the low bit
/// of the first byte, which broadcast also carries.
pub fn isGroup(a: Address) bool {
    return a[0] & 1 != 0;
}

/// Six bytes as hex pairs: "52:54:00:12:34:56".
pub fn text(mac: Address) [17]u8 {
    const hexdigits = "0123456789abcdef";
    var spelled: [17]u8 = undefined;
    for (mac, 0..) |byte, i| {
        spelled[i * 3] = hexdigits[byte >> 4];
        spelled[i * 3 + 1] = hexdigits[byte & 0xF];
        if (i < 5) spelled[i * 3 + 2] = ':';
    }
    return spelled;
}

test "a mac spells like a mac" {
    const spelled = text(.{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 });
    try std.testing.expectEqualStrings("52:54:00:12:34:56", &spelled);
}

test "every byte gets two digits" {
    const spelled = text(.{ 0x00, 0x0a, 0xff, 0x01, 0x20, 0x03 });
    try std.testing.expectEqualStrings("00:0a:ff:01:20:03", &spelled);
}