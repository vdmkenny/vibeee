//! IPv4 addresses, asked and spelled.
//!
//! Pure, so it is host-testable and shared by the service and the tools. An
//! address is a u32 whose bytes read in the wire order: "10.0.2.2" is
//! 0x0A000202, because the first dotted number is the highest byte, which is
//! the order the wire and a person's spelling already agree on.

const std = @import("std");
const str = @import("str.zig");

/// An address with its prefix length: "192.168.178.50/24", the shape
/// interface configuration speaks. All zero means unset, which is how a
/// config field says "no static address, ask DHCP".
pub const Cidr = packed struct(u40) {
    addr: u32 = 0,
    prefix: u8 = 0,

    /// The network mask the prefix describes.
    pub fn mask(self: Cidr) u32 {
        if (self.prefix == 0) return 0;
        if (self.prefix >= 32) return 0xFFFF_FFFF;
        return ~(@as(u32, 0xFFFF_FFFF) >> @intCast(self.prefix));
    }

    pub const accepts = "an address and prefix, a.b.c.d/nn; unset asks DHCP";

    pub fn parse(dotted: []const u8) ?Cidr {
        const slash = std.mem.indexOfScalar(u8, dotted, '/') orelse return null;
        const addr = ipv4Parse(dotted[0..slash]) orelse return null;
        const prefix = std.fmt.parseInt(u8, dotted[slash + 1 ..], 10) catch return null;
        if (prefix == 0 or prefix > 32) return null;
        return .{ .addr = addr, .prefix = prefix };
    }

    pub fn spell(self: Cidr, into: *str.Builder) void {
        var field: [15]u8 = undefined;
        into.text(text(self.addr, &field));
        into.byte('/');
        into.number(self.prefix);
    }
};

/// One address as a setting spells it: "192.168.178.1".
///
/// A type rather than a bare word, because the file writes it dotted and the
/// loader asks the type how. An address that may not have been chosen is
/// `?Address`, so nothing written and something written wrong are two
/// different answers rather than both being a zero.
pub const Address = packed struct(u32) {
    addr: u32 = 0,

    pub const accepts = "an address, a.b.c.d; unset takes what the lease offers";

    pub fn parse(dotted: []const u8) ?Address {
        return .{ .addr = ipv4Parse(str.trim(dotted)) orelse return null };
    }

    pub fn spell(self: Address, into: *str.Builder) void {
        var field: [15]u8 = undefined;
        into.text(text(self.addr, &field));
    }
};

/// Up to two addresses, comma separated: what a name-server list is.
pub const Pair = packed struct(u64) {
    first: u32 = 0,
    second: u32 = 0,

    pub fn isSet(self: Pair) bool {
        return self.first != 0;
    }

    pub const accepts = "up to two addresses, comma separated";

    pub fn parse(listed: []const u8) ?Pair {
        if (str.trim(listed).len == 0) return .{};
        var out = Pair{};
        var at: usize = 0;
        var parts = std.mem.splitScalar(u8, listed, ',');
        while (parts.next()) |part| {
            if (at == 2) return null;
            const addr = ipv4Parse(str.trim(part)) orelse return null;
            if (at == 0) out.first = addr else out.second = addr;
            at += 1;
        }
        return if (at == 0) .{} else out;
    }

    pub fn spell(self: Pair, into: *str.Builder) void {
        var field: [15]u8 = undefined;
        if (self.first != 0) into.text(text(self.first, &field));
        if (self.second != 0) {
            into.byte(',');
            into.text(text(self.second, &field));
        }
    }
};

/// `parse` under a name the container types can reach once they shadow it.
fn ipv4Parse(dotted: []const u8) ?u32 {
    return parse(dotted);
}

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

/// The source address of a packet, in host order.
///
/// The one order this library speaks: `parse` produces it, `text` prints it,
/// and every address a caller holds is in it. A header on the wire is
/// big-endian, so reading one is a conversion and not a copy, and a caller
/// that skips the conversion answers "not the host we asked" for every
/// address whose octets are not a palindrome. Kept here so there is one
/// place that knows which way round an address on a wire is.
pub fn source(packet: []const u8) ?u32 {
    if (packet.len < SOURCE_END) return null;
    return std.mem.readInt(u32, packet[SOURCE_AT..][0..4], .big);
}

/// Where the source address sits in a header, and how much of one there is
/// before options. Twenty bytes, the fixed part: everything before them is
/// where every header begins.
const SOURCE_AT = 12;
const SOURCE_END = 20;

/// The shortest a header can be: no options. What a caller checks a length
/// against before it reads one.
pub const HEADER_MIN = SOURCE_END;

/// The address and a port, "10.0.2.2:6666", for everything that names a
/// conversation's far end. Needs no more than twenty-one bytes.
pub fn textWithPort(addr: u32, port: u16, field: *[21]u8) []const u8 {
    var w = std.Io.Writer.fixed(field);
    w.print("{d}.{d}.{d}.{d}:{d}", .{
        @as(u8, @truncate(addr >> 24)),
        @as(u8, @truncate(addr >> 16)),
        @as(u8, @truncate(addr >> 8)),
        @as(u8, @truncate(addr)),
        port,
    }) catch return field[0..0];
    return w.buffered();
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
test "a cidr parses, masks and spells" {
    const c = Cidr.parse("192.168.178.50/24").?;
    try std.testing.expectEqual(@as(u32, 0xC0A8B232), c.addr);
    try std.testing.expectEqual(@as(u8, 24), c.prefix);
    try std.testing.expectEqual(@as(u32, 0xFFFFFF00), c.mask());
    var buf: [24]u8 = undefined;
    var b = str.Builder{ .buf = &buf };
    c.spell(&b);
    try std.testing.expectEqualStrings("192.168.178.50/24", b.done());
}

test "a cidr refuses what is not one" {
    try std.testing.expectEqual(null, Cidr.parse("192.168.178.50"));
    try std.testing.expectEqual(null, Cidr.parse("192.168.178.50/0"));
    try std.testing.expectEqual(null, Cidr.parse("192.168.178.50/33"));
    try std.testing.expectEqual(null, Cidr.parse("banana/24"));
}

test "an address is one address, and nothing else is" {
    try std.testing.expectEqual(@as(u32, 0xC0A8B201), Address.parse("192.168.178.1").?.addr);
    try std.testing.expectEqual(null, Address.parse("not an address"));

    // Nothing written is not an address either. Whether one was chosen is the
    // field's question, asked as `?Address`, and not this one's.
    try std.testing.expectEqual(null, Address.parse(""));
}

test "a packet's source comes back in the order addresses are held in" {
    // 192.168.178.1 on the wire: big-endian, the opposite of how `parse`
    // spells the same address back.
    var packet: [20]u8 = @splat(0);
    packet[0] = 0x45;
    packet[12] = 192;
    packet[13] = 168;
    packet[14] = 178;
    packet[15] = 1;

    const from = source(&packet) orelse return error.TestFailed;
    try std.testing.expectEqual(parse("192.168.178.1").?, from);

    // A short header is not an address, and a caller that reads one anyway
    // is how a length becomes a number with no meaning.
    try std.testing.expectEqual(@as(?u32, null), source(packet[0..13]));
}

test "a pair holds one or two addresses" {
    const one = Pair.parse("1.2.3.4").?;
    try std.testing.expectEqual(@as(u32, 0x01020304), one.first);
    try std.testing.expectEqual(@as(u32, 0), one.second);
    const two = Pair.parse("1.2.3.4, 5.6.7.8").?;
    try std.testing.expectEqual(@as(u32, 0x05060708), two.second);
    try std.testing.expectEqual(null, Pair.parse("1.2.3.4,5.6.7.8,9.9.9.9"));
    try std.testing.expect(!Pair.parse("").?.isSet());
}
