//! The bytes an NTP exchange is made of.
//!
//! Kept apart from the service that sends them, because everything that can
//! be got wrong here can be got wrong without a network: the epoch, the
//! fixed-point fraction, and which fields a reply must have before it is
//! worth believing. A machine of this age has usually lost the battery that
//! kept its clock, so this is the only thing standing between it and a
//! filesystem full of files from 1970.
//!
//! SNTP, which is the client half of NTP and all a machine that asks once an
//! hour has ever needed (RFC 4330).

const std = @import("std");

/// NTP counts seconds from 1900; everything else here counts from 1970.
pub const EPOCH_DELTA: u64 = 2_208_988_800;

pub const PORT: u16 = 123;

/// The packet, which is the same shape in both directions.
pub const Packet = extern struct {
    /// Leap indicator, version and mode, packed into one byte.
    flags: u8 = 0,
    stratum: u8 = 0,
    poll: i8 = 0,
    precision: i8 = 0,

    root_delay: u32 = 0,
    root_dispersion: u32 = 0,
    reference_id: u32 = 0,

    reference: Timestamp = .{},
    originate: Timestamp = .{},
    receive: Timestamp = .{},
    transmit: Timestamp = .{},

    pub const BYTES = 48;

    /// A client's question: version 4, mode 3, and nothing else worth saying.
    pub fn request() Packet {
        return .{ .flags = (4 << 3) | 3 };
    }

    pub fn mode(self: Packet) u3 {
        return @truncate(self.flags);
    }

    pub fn version(self: Packet) u3 {
        return @truncate(self.flags >> 3);
    }

    pub fn leap(self: Packet) u2 {
        return @truncate(self.flags >> 6);
    }

    pub fn bytes(self: *const Packet) []const u8 {
        return std.mem.asBytes(self)[0..BYTES];
    }

    pub fn parse(raw: []const u8) ?Packet {
        if (raw.len < BYTES) return null;
        var out: Packet = undefined;
        @memcpy(std.mem.asBytes(&out)[0..BYTES], raw[0..BYTES]);
        return out;
    }
};

/// Seconds since 1900 and a binary fraction of a second, both big-endian on
/// the wire.
pub const Timestamp = extern struct {
    seconds: u32 = 0,
    fraction: u32 = 0,

    pub fn micros(self: Timestamp) ?i64 {
        const seconds = @byteSwap(self.seconds);
        if (seconds == 0) return null;
        if (seconds < EPOCH_DELTA) return null;

        const fraction = @byteSwap(self.fraction);
        // The fraction is a binary fraction of a second: multiply before
        // dividing, in 64 bits, or every reading lands on a whole second.
        const sub = (@as(u64, fraction) * 1_000_000) >> 32;
        const unix = @as(u64, seconds) - EPOCH_DELTA;
        return @intCast(unix * 1_000_000 + sub);
    }
};

/// Why a reply was not believed.
///
/// An error set rather than an optional, because "the server is
/// unsynchronised" and "that was not an answer to our question" call for
/// different next moves: one server is worth asking again later, the other is
/// answering somebody else's question.
pub const Refusal = error{
    TooShort,
    NotAServer,
    WrongVersion,
    Unsynchronised,
    /// The leap indicator's alarm condition: the server's own clock is unset.
    Alarm,
    NoTimestamp,
};

pub fn why(refusal: Refusal) []const u8 {
    return switch (refusal) {
        error.TooShort => "the reply was too short to be one",
        error.NotAServer => "that was not a server's answer",
        error.WrongVersion => "the server answered in a version we did not ask",
        error.Unsynchronised => "the server is not synchronised to anything",
        error.Alarm => "the server says its own clock is unset",
        error.NoTimestamp => "the reply carries no time",
    };
}

/// What a reply says the time is, or why it is not worth believing.
///
/// Every check here is one a wrong answer would otherwise pass: an
/// unsynchronised server answers with stratum 0 and a plausible-looking
/// timestamp, and a machine that took it would set its clock from a server
/// that does not know the time either.
pub fn timeFrom(datagram: []const u8) Refusal!i64 {
    const packet = Packet.parse(datagram) orelse return error.TooShort;

    if (packet.mode() != 4) return error.NotAServer;
    if (packet.version() < 3 or packet.version() > 4) return error.WrongVersion;
    if (packet.leap() == 3) return error.Alarm;
    if (packet.stratum == 0 or packet.stratum > 15) return error.Unsynchronised;

    return packet.transmit.micros() orelse error.NoTimestamp;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn answer(stratum: u8, seconds: u32, fraction: u32, flags: u8) [Packet.BYTES]u8 {
    var packet = Packet{ .flags = flags, .stratum = stratum };
    packet.transmit = .{ .seconds = @byteSwap(seconds), .fraction = @byteSwap(fraction) };
    var raw: [Packet.BYTES]u8 = undefined;
    @memcpy(&raw, packet.bytes());
    return raw;
}

test "a question says what it is" {
    const asked = Packet.request();
    try testing.expectEqual(@as(u3, 4), asked.version());
    try testing.expectEqual(@as(u3, 3), asked.mode());
    try testing.expectEqual(@as(usize, 48), asked.bytes().len);
}

test "an answer becomes microseconds since 1970" {
    // 2024-01-01 00:00:00 UTC is 1704067200 in Unix time.
    const raw = answer(2, @intCast(1_704_067_200 + EPOCH_DELTA), 0, (4 << 3) | 4);
    const when = try timeFrom(&raw);
    try testing.expectEqual(@as(i64, 1_704_067_200 * 1_000_000), when);
}

test "the fraction is a fraction of a second" {
    // Half a second is the top bit of the fraction.
    const raw = answer(2, @intCast(1_704_067_200 + EPOCH_DELTA), 1 << 31, (4 << 3) | 4);
    const when = try timeFrom(&raw);
    try testing.expectEqual(@as(i64, 1_704_067_200 * 1_000_000 + 500_000), when);
}

test "a server that does not know the time is not believed" {
    const good: u32 = @intCast(1_704_067_200 + EPOCH_DELTA);

    // Stratum zero: the server is telling us it is unsynchronised, however
    // plausible its timestamp looks.
    try testing.expectError(error.Unsynchronised, timeFrom(&answer(0, good, 0, (4 << 3) | 4)));

    // Leap indicator 3: the alarm condition, which means the same thing.
    try testing.expectError(error.Alarm, timeFrom(&answer(2, good, 0, (3 << 6) | (4 << 3) | 4)));

    // Mode 3 is a question, not an answer: a reply that is somebody else's
    // request is not a reply.
    try testing.expectError(error.NotAServer, timeFrom(&answer(2, good, 0, (4 << 3) | 3)));

    // A timestamp before the NTP epoch is not a time.
    try testing.expectError(error.NoTimestamp, timeFrom(&answer(2, 0, 0, (4 << 3) | 4)));
}

test "a short datagram is refused rather than read past" {
    var stub: [16]u8 = @splat(0);
    try testing.expectError(error.TooShort, timeFrom(&stub));
}
