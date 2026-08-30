//! ICMP echo, the two frames ping is made of.
//!
//! Pure, host-tested, and written as `eth.zig` writes frames: a table of
//! positions and functions that fill them, because a wire format is offsets
//! and an offset table is what cannot pad or reorder.

const std = @import("std");

pub const Kind = enum(u8) {
    echo_reply = 0,
    echo_request = 8,
    _,
};

/// Every position that matters inside an echo message.
pub const At = enum(u8) {
    kind = 0,
    code = 1,
    checksum = 2,
    ident = 4,
    sequence = 6,
    payload = 8,
};

pub const HEADER: usize = @intFromEnum(At.payload);

/// The bytes an echo carries, so a mangled reply is distinguishable from a
/// short one. Any recognisable constant does; this one spells the system.
pub const PATTERN = "vibeee ping     ";
pub const MESSAGE: usize = HEADER + PATTERN.len;

/// Fill `out` with one echo request. The caller owns identity and sequence;
/// the checksum is computed over the finished message.
pub fn request(out: *[MESSAGE]u8, ident: u16, sequence: u16) void {
    out[@intFromEnum(At.kind)] = @intFromEnum(Kind.echo_request);
    out[@intFromEnum(At.code)] = 0;
    write16(out, .checksum, 0);
    write16(out, .ident, ident);
    write16(out, .sequence, sequence);
    @memcpy(out[HEADER..], PATTERN);
    write16(out, .checksum, checksum(out));
}

/// Whether these bytes are the reply to the request `ident`/`sequence` name.
pub fn isReply(bytes: []const u8, ident: u16, sequence: u16) bool {
    if (bytes.len < MESSAGE) return false;
    if (bytes[@intFromEnum(At.kind)] != @intFromEnum(Kind.echo_reply)) return false;
    if (read16(bytes, .ident) != ident) return false;
    return read16(bytes, .sequence) == sequence;
}

/// The Internet checksum: the ones' complement of the ones' complement sum
/// of the message as sixteen-bit big-endian words, an odd tail padded with
/// zero. RFC 1071's arithmetic, in the only three lines it actually is.
pub fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        sum += std.mem.readInt(u16, bytes[i..][0..2], .big);
    }
    if (i < bytes.len) sum += @as(u32, bytes[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

fn write16(bytes: []u8, at: At, value: u16) void {
    std.mem.writeInt(u16, bytes[@intFromEnum(at)..][0..2], value, .big);
}

fn read16(bytes: []const u8, at: At) u16 {
    return std.mem.readInt(u16, bytes[@intFromEnum(at)..][0..2], .big);
}

test "a request checksums to zero when verified whole" {
    var frame: [MESSAGE]u8 = undefined;
    request(&frame, 0x1234, 7);
    // Verifying an Internet checksum means summing the whole message,
    // checksum field included, and landing on zero.
    try std.testing.expectEqual(@as(u16, 0), checksum(&frame));
    try std.testing.expectEqual(@as(u8, 8), frame[0]);
}

test "a reply matches only its own request" {
    var frame: [MESSAGE]u8 = undefined;
    request(&frame, 0x1234, 7);
    frame[@intFromEnum(At.kind)] = @intFromEnum(Kind.echo_reply);
    try std.testing.expect(isReply(&frame, 0x1234, 7));
    try std.testing.expect(!isReply(&frame, 0x1234, 8));
    try std.testing.expect(!isReply(&frame, 0x4321, 7));
    try std.testing.expect(!isReply(frame[0..4], 0x1234, 7));
}

test "the checksum handles an odd tail" {
    const odd = [_]u8{ 0x01, 0x02, 0x03 };
    // 0x0102 + 0x0300 = 0x0402; complement is 0xFBFD.
    try std.testing.expectEqual(@as(u16, 0xFBFD), checksum(&odd));
}
