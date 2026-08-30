//! What a radio can be tuned to and how fast it may talk.
//!
//! Pure and host-tested, and deliberately wider than any one radio. Band,
//! channel width, and a rate that is either a legacy rate or a
//! modulation-and-coding index cover 802.11b, g and n alike: a driver fills
//! in the values its silicon has, and a later radio changes which values
//! appear rather than the vocabulary the service, the settings and the
//! tools are written against.

const std = @import("std");

pub const Band = enum(u8) {
    /// 802.11b/g/n.
    ghz2 = 0,
    /// 802.11a/n and above.
    ghz5 = 1,

    pub fn parse(text: []const u8) ?Band {
        return std.meta.stringToEnum(Band, text);
    }

    pub fn spell(self: Band) []const u8 {
        return @tagName(self);
    }
};

/// How wide a channel is. Twenty megahertz is every legacy rate and the
/// mandatory high-throughput width; forty is high throughput's optional
/// bonded pair.
pub const Width = enum(u8) {
    mhz20 = 0,
    mhz40 = 1,

    pub fn megahertz(self: Width) u16 {
        return switch (self) {
            .mhz20 => 20,
            .mhz40 => 40,
        };
    }
};

/// A tuning: which channel, in which band, how wide.
pub const Channel = struct {
    number: u8,
    band: Band = .ghz2,
    width: Width = .mhz20,

    /// The channel's centre, in megahertz. The 2.4 GHz band counts in five
    /// megahertz steps from 2407 and then makes an exception of channel 14;
    /// the 5 GHz band counts the same way from 5000 with no exceptions.
    pub fn megahertz(self: Channel) ?u16 {
        return switch (self.band) {
            .ghz2 => switch (self.number) {
                1...13 => 2407 + @as(u16, self.number) * 5,
                14 => 2484,
                else => null,
            },
            .ghz5 => switch (self.number) {
                1...196 => 5000 + @as(u16, self.number) * 5,
                else => null,
            },
        };
    }

    /// The channel a frequency names, or null where none does.
    pub fn ofMegahertz(mhz: u16) ?Channel {
        if (mhz == 2484) return .{ .number = 14, .band = .ghz2 };
        if (mhz >= 2412 and mhz <= 2472 and (mhz - 2407) % 5 == 0) {
            return .{ .number = @intCast((mhz - 2407) / 5), .band = .ghz2 };
        }
        if (mhz >= 5005 and mhz <= 5980 and mhz % 5 == 0) {
            return .{ .number = @intCast((mhz - 5000) / 5), .band = .ghz5 };
        }
        return null;
    }
};

/// The channels this system will tune to in the 2.4 GHz band without being
/// told otherwise. Thirteen is the European set; a card's own regulatory
/// domain narrows it further at scan time, and never widens it.
pub const ghz2_channels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 };

/// How a rate is carried on the air.
pub const Modulation = enum {
    /// The 802.11b rates, direct sequence and complementary code keying.
    dsss,
    /// The 802.11a/g rates.
    ofdm,
    /// High throughput, indexed rather than named.
    ht,
};

/// A legacy rate, valued as 802.11 encodes it in a supported-rates element:
/// units of five hundred kilobits. The encoding is the enum, so a rate set
/// read off the air needs no table to become these.
pub const Legacy = enum(u8) {
    m1 = 2,
    m2 = 4,
    m5_5 = 11,
    m11 = 22,
    m6 = 12,
    m9 = 18,
    m12 = 24,
    m18 = 36,
    m24 = 48,
    m36 = 72,
    m48 = 96,
    m54 = 108,
    _,

    pub fn kbps(self: Legacy) u32 {
        return @as(u32, @intFromEnum(self)) * 500;
    }

    pub fn modulation(self: Legacy) Modulation {
        return switch (self) {
            .m1, .m2, .m5_5, .m11 => .dsss,
            else => .ofdm,
        };
    }

    /// The rate a supported-rates element names, with the basic-rate flag
    /// stripped: the high bit says a rate is required, not which it is.
    pub fn ofElement(byte: u8) Legacy {
        return @enumFromInt(byte & 0x7F);
    }

    pub fn isBasic(byte: u8) bool {
        return byte & 0x80 != 0;
    }
};

/// Every rate an 802.11b radio has, slowest first.
pub const b_rates = [_]Legacy{ .m1, .m2, .m5_5, .m11 };

/// The rates 802.11g adds.
pub const g_rates = [_]Legacy{ .m6, .m9, .m12, .m18, .m24, .m36, .m48, .m54 };

/// A high-throughput rate: which coding index, across how many spatial
/// streams, at which width and guard interval. A driver for a radio
/// without high throughput simply never produces one, and nothing above
/// the driver changes when one that does arrives.
pub const Mcs = struct {
    /// Zero through seven within one stream.
    index: u3 = 0,
    /// One stream up to four; index 8 and above on the air are simply this
    /// index with more streams.
    streams: u3 = 1,
    width: Width = .mhz20,
    /// The short guard interval, four hundred nanoseconds instead of eight
    /// hundred, which a pair of radios may agree on.
    short_guard: bool = false,

    /// One stream's throughput, in kilobits, for each index. Two tables
    /// rather than arithmetic because the coding rates behind them are not
    /// a sequence, and a table read off the standard cannot drift.
    const per_stream = struct {
        const mhz20_long = [8]u32{ 6500, 13000, 19500, 26000, 39000, 52000, 58500, 65000 };
        const mhz20_short = [8]u32{ 7200, 14400, 21700, 28900, 43300, 57800, 65000, 72200 };
        const mhz40_long = [8]u32{ 13500, 27000, 40500, 54000, 81000, 108000, 121500, 135000 };
        const mhz40_short = [8]u32{ 15000, 30000, 45000, 60000, 90000, 120000, 135000, 150000 };
    };

    pub fn kbps(self: Mcs) u32 {
        const table = switch (self.width) {
            .mhz20 => if (self.short_guard) per_stream.mhz20_short else per_stream.mhz20_long,
            .mhz40 => if (self.short_guard) per_stream.mhz40_short else per_stream.mhz40_long,
        };
        return table[self.index] * @as(u32, @max(1, self.streams));
    }
};

/// What a frame was sent at, or is to be sent at.
pub const Rate = union(enum) {
    legacy: Legacy,
    ht: Mcs,

    pub fn kbps(self: Rate) u32 {
        return switch (self) {
            .legacy => |rate| rate.kbps(),
            .ht => |rate| rate.kbps(),
        };
    }

    pub fn modulation(self: Rate) Modulation {
        return switch (self) {
            .legacy => |rate| rate.modulation(),
            .ht => .ht,
        };
    }

    /// Megabits, rounded down, for a listing that has one column for it.
    pub fn mbps(self: Rate) u16 {
        return @intCast(self.kbps() / 1000);
    }
};

/// How a network protects itself, in the order of preference a joiner
/// should have.
pub const Security = enum(u8) {
    /// No protection at all.
    open = 0,
    /// Wired-equivalent privacy, broken for two decades. Named so a scan
    /// can say what a network is, never so this system will join one.
    wep = 1,
    wpa2_psk = 2,
    wpa3_sae = 3,
    /// Something this system can read the advertisement of but not join.
    unsupported = 255,

    pub fn joinable(self: Security) bool {
        return switch (self) {
            .open, .wpa2_psk => true,
            else => false,
        };
    }

    pub fn spell(self: Security) []const u8 {
        return switch (self) {
            .open => "open",
            .wep => "wep",
            .wpa2_psk => "wpa2",
            .wpa3_sae => "wpa3",
            .unsupported => "unsupported",
        };
    }
};

/// A network's name. Thirty-two bytes, and not text: an SSID is arbitrary
/// octets, and a name that will not print is still a name.
pub const Ssid = struct {
    bytes: [MAX]u8 = @splat(0),
    len: u8 = 0,

    pub const MAX = 32;

    pub fn of(name: []const u8) ?Ssid {
        if (name.len > MAX) return null;
        var out = Ssid{ .len = @intCast(name.len) };
        @memcpy(out.bytes[0..name.len], name);
        return out;
    }

    pub fn slice(self: *const Ssid) []const u8 {
        return self.bytes[0..@min(self.len, MAX)];
    }

    pub fn eql(self: Ssid, other: Ssid) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }

    /// A zero-length name is what an access point advertises when it is
    /// hiding, and what a probe request carries when it is asking for
    /// every network at once.
    pub fn isHidden(self: Ssid) bool {
        return self.len == 0;
    }
};

/// Signal strength as a scan reports it: the radio's own margin over its
/// noise floor, which is what every radio can actually answer, plus the
/// decibel-milliwatt figure when the driver knows its noise floor.
pub const Signal = struct {
    /// Decibels above the noise floor. Zero when unknown.
    snr_db: u8 = 0,
    /// Absolute strength, negative and typically -30 to -95. Zero when the
    /// driver cannot say.
    dbm: i8 = 0,

    /// Four bars, the way a status indicator wants it: -55 and better is
    /// full, then twelve decibels a bar.
    pub fn bars(self: Signal) u2 {
        if (self.dbm == 0) return if (self.snr_db >= 30) 3 else @intCast(@min(2, self.snr_db / 12));
        if (self.dbm >= -55) return 3;
        if (self.dbm >= -67) return 2;
        if (self.dbm >= -79) return 1;
        return 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "channels and frequencies name each other, both bands" {
    try std.testing.expectEqual(@as(?u16, 2412), (Channel{ .number = 1 }).megahertz());
    try std.testing.expectEqual(@as(?u16, 2437), (Channel{ .number = 6 }).megahertz());
    try std.testing.expectEqual(@as(?u16, 2472), (Channel{ .number = 13 }).megahertz());
    // Channel fourteen is the band's one exception, and Japan's alone.
    try std.testing.expectEqual(@as(?u16, 2484), (Channel{ .number = 14 }).megahertz());
    try std.testing.expectEqual(@as(?u16, 5180), (Channel{ .number = 36, .band = .ghz5 }).megahertz());

    for (ghz2_channels) |number| {
        const channel = Channel{ .number = number };
        const back = Channel.ofMegahertz(channel.megahertz().?).?;
        try std.testing.expectEqual(number, back.number);
        try std.testing.expectEqual(Band.ghz2, back.band);
    }

    try std.testing.expectEqual(@as(?u16, null), (Channel{ .number = 0 }).megahertz());
    try std.testing.expectEqual(@as(?Channel, null), Channel.ofMegahertz(2413));
}

test "a legacy rate is its own wire encoding" {
    try std.testing.expectEqual(@as(u32, 1000), Legacy.m1.kbps());
    try std.testing.expectEqual(@as(u32, 5500), Legacy.m5_5.kbps());
    try std.testing.expectEqual(@as(u32, 54000), Legacy.m54.kbps());
    try std.testing.expectEqual(Modulation.dsss, Legacy.m11.modulation());
    try std.testing.expectEqual(Modulation.ofdm, Legacy.m6.modulation());

    // A basic rate arrives with its high bit set and is the same rate.
    try std.testing.expect(Legacy.isBasic(0x82));
    try std.testing.expectEqual(Legacy.m1, Legacy.ofElement(0x82));
    try std.testing.expect(!Legacy.isBasic(0x0C));
    try std.testing.expectEqual(Legacy.m6, Legacy.ofElement(0x0C));
}

test "high throughput rates follow the standard's tables" {
    try std.testing.expectEqual(@as(u32, 6500), (Mcs{ .index = 0 }).kbps());
    try std.testing.expectEqual(@as(u32, 65000), (Mcs{ .index = 7 }).kbps());
    try std.testing.expectEqual(@as(u32, 72200), (Mcs{ .index = 7, .short_guard = true }).kbps());
    try std.testing.expectEqual(@as(u32, 135000), (Mcs{ .index = 7, .width = .mhz40 }).kbps());
    try std.testing.expectEqual(
        @as(u32, 150000),
        (Mcs{ .index = 7, .width = .mhz40, .short_guard = true }).kbps(),
    );
    // Two streams is twice one, which is what index eight and above mean.
    try std.testing.expectEqual(@as(u32, 130000), (Mcs{ .index = 7, .streams = 2 }).kbps());
}

test "a rate answers in megabits whichever kind it is" {
    try std.testing.expectEqual(@as(u16, 54), (Rate{ .legacy = .m54 }).mbps());
    try std.testing.expectEqual(@as(u16, 65), (Rate{ .ht = .{ .index = 7 } }).mbps());
    try std.testing.expectEqual(Modulation.ht, (Rate{ .ht = .{} }).modulation());
}

test "a network name holds arbitrary octets and knows when it is hidden" {
    const named = Ssid.of("home network").?;
    try std.testing.expectEqualStrings("home network", named.slice());
    try std.testing.expect(!named.isHidden());
    try std.testing.expect(named.eql(Ssid.of("home network").?));
    try std.testing.expect(!named.eql(Ssid.of("other").?));

    try std.testing.expect((Ssid{}).isHidden());
    try std.testing.expectEqual(@as(?Ssid, null), Ssid.of("x" ** 33));
    const raw = Ssid.of(&[_]u8{ 0xFF, 0x00, 0x41 }).?;
    try std.testing.expectEqual(@as(u8, 3), raw.len);
}

test "security says what may be joined" {
    try std.testing.expect(Security.open.joinable());
    try std.testing.expect(Security.wpa2_psk.joinable());
    try std.testing.expect(!Security.wep.joinable());
    try std.testing.expect(!Security.wpa3_sae.joinable());
    try std.testing.expectEqualStrings("wpa2", Security.wpa2_psk.spell());
}

test "signal strength becomes bars" {
    try std.testing.expectEqual(@as(u2, 3), (Signal{ .dbm = -40 }).bars());
    try std.testing.expectEqual(@as(u2, 2), (Signal{ .dbm = -60 }).bars());
    try std.testing.expectEqual(@as(u2, 1), (Signal{ .dbm = -70 }).bars());
    try std.testing.expectEqual(@as(u2, 0), (Signal{ .dbm = -90 }).bars());
    // With no absolute figure the margin answers instead.
    try std.testing.expectEqual(@as(u2, 3), (Signal{ .snr_db = 35 }).bars());
    try std.testing.expectEqual(@as(u2, 1), (Signal{ .snr_db = 15 }).bars());
}
