//! IPv4 addresses, asked and spelled.
//!
//! Pure, so it is host-testable and shared by the service and the tools. An
//! address is a u32 whose bytes read in the wire order: "10.0.2.2" is
//! 0x0A000202, because the first dotted number is the highest byte, which is
//! the order the wire and a person's spelling already agree on.

const std = @import("std");

/// "10.0.2.2" as the four dotted numbers of one word.
pub fn parse(dotted: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var at: usize = 0;
    var numbers = std.mem.splitScalar(u8, dotted, '.');
    while (numbers.next()) |part| {
        if (at == 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        const value = std.fmt.parseInt(u8, part, 10) catch return null;
        octets[at] = value;
        at += 1;
    }
    if (at != 4) return null;

    return (@as(u32, octets[0]) << 24) |
        (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) |
        octets[3];
}

/// The address, dotted, as the slice of `field` that spells it. An address
/// needs no more than fifteen bytes; the caller owns the field.
pub fn text(addr: u32, field: *[15]u8) []const u8 {
    var w = std.Io.Writer.fixed(field);
    w.print("{d}.{d}.{d}.{d}", .{
        addr >> 24 & 0xFF, addr >> 16 & 0xFF, addr >> 8 & 0xFF, addr & 0xFF,
    }) catch return "";
    return field[0..w.end];
}

/// Whether the address is one of RFC 1918's private: the 10/8, 172.16/12
/// and 192.168/16 blocks. Only those three: a loopback or link-local
/// address answers false, because it is another RFC's business.
pub fn isPrivate(addr: u32) bool {
    if ((addr >> 24) == 10) return true;
    if ((addr >> 20) == 0xAC1) return true; // 172.16 through 172.31
    if ((addr >> 16) == 0xC0A8) return true; // 192.168
    return false;
}

test "an address parses and spells back" {
    try std.testing.expectEqual(@as(u32, 0x0A000202), parse("10.0.2.2").?);
    try std.testing.expectEqual(@as(u32, 0xC0A80001), parse("192.168.0.1").?);
}

test "wild, empty and long octets are not addresses" {
    try std.testing.expectEqual(null, parse("10.0.2"));
    try std.testing.expectEqual(null, parse("10.0.2.2.5"));
    try std.testing.expectEqual(null, parse("10.0.2.999"));
    try std.testing.expectEqual(null, parse("10..2.2"));
    try std.testing.expectEqual(null, parse("hello"));
}

test "the spelling is the dotted form" {
    var field: [15]u8 = @splat(0);
    try std.testing.expectEqualStrings("10.0.2.2", text(0x0A000202, &field));
    try std.testing.expectEqualStrings("192.168.0.1", text(0xC0A80001, &field));
}

test "private addresses are the RFC 1918 blocks, and only those" {
    try std.testing.expect(isPrivate(0x0A000202)); // 10.0.2.2
    try std.testing.expect(isPrivate(0xC0A80001)); // 192.168.0.1
    try std.testing.expect(isPrivate(0xAC100505)); // 172.16.5.5
    try std.testing.expect(isPrivate(0xAC1FFFFF)); // 172.31.255.255, the far edge
    try std.testing.expect(!isPrivate(0xAC200001)); // 172.32.0.1, one past
    try std.testing.expect(!isPrivate(0x08080808)); // 8.8.8.8
    try std.testing.expect(!isPrivate(0xA9FE0101)); // 169.254.1.1, link-local
    try std.testing.expect(!isPrivate(0x7F000001)); // 127.0.0.1
}