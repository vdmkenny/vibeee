//! What a radio can be tuned to and how fast it may talk.
//!
//! Pure and host-tested, and deliberately wider than any one radio. Band,
//! channel width, and a rate that is either a legacy rate or a
//! modulation-and-coding index cover 802.11b, g and n alike: a driver fills
//! in the values its silicon has, and a later radio changes which values
//! appear rather than the vocabulary the service, the settings and the
//! tools are written against.

const std = @import("std");
const str = @import("str.zig");

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

    /// The slowest rate every station in the band must understand. What a
    /// frame goes at while there is no agreement yet about anything
    /// faster, which is every frame that arranges the agreement.
    pub fn slowest(self: Band) Legacy {
        return switch (self) {
            .ghz2 => .m1,
            .ghz5 => .m6,
        };
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

    /// How long a frame of `bytes` takes on the air at this rate, in
    /// microseconds: the preamble and header the physical layer puts in
    /// front, then the payload at the rate, then the short gap before an
    /// answer when `with_sifs`. The 802.11b rates halve their preamble when
    /// told to, except the slowest, which has no short form.
    pub fn airtime(self: Legacy, bytes: u32, short_preamble: bool, with_sifs: bool) u16 {
        const bits = bytes * 8;
        var micros: u32 = 0;
        switch (self.modulation()) {
            .dsss => {
                const PREAMBLE_BITS = 144;
                const HEADER_BITS = 48;
                const SIFS = 10;
                var plcp: u32 = PREAMBLE_BITS + HEADER_BITS;
                if (short_preamble and self != .m1) plcp /= 2;
                micros = plcp + (bits * 1000) / self.kbps();
                if (with_sifs) micros += SIFS;
            },
            .ofdm, .ht => {
                const PREAMBLE_MICROS = 20;
                const SERVICE_AND_TAIL_BITS = 22;
                const SYMBOL_MICROS = 4;
                const SIFS = 16;
                const bits_per_symbol = (self.kbps() * SYMBOL_MICROS) / 1000;
                const symbols = (SERVICE_AND_TAIL_BITS + bits + bits_per_symbol - 1) / bits_per_symbol;
                micros = PREAMBLE_MICROS + symbols * SYMBOL_MICROS;
                if (with_sifs) micros += SIFS;
            },
        }
        return @intCast(micros);
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

    pub const accepts = "a network name, up to 32 characters";

    /// Nothing written is no network named, which is how a slot says it
    /// has nothing to join rather than that it wants a hidden one.
    pub fn parse(text: []const u8) ?Ssid {
        const trimmed = str.trim(text);
        if (trimmed.len == 0) return Ssid{};
        return of(trimmed);
    }

    pub fn spell(self: Ssid, into: *str.Builder) void {
        into.text(self.slice());
    }
};

/// The eight to sixty-three characters a protected network is joined with.
pub const Passphrase = struct {
    bytes: [MAX]u8 = @splat(0),
    len: u8 = 0,

    pub const MIN = 8;
    pub const MAX = 63;

    pub fn of(text: []const u8) ?Passphrase {
        if (text.len < MIN or text.len > MAX) return null;
        var out = Passphrase{ .len = @intCast(text.len) };
        @memcpy(out.bytes[0..text.len], text);
        return out;
    }

    pub fn slice(self: *const Passphrase) []const u8 {
        return self.bytes[0..@min(self.len, MAX)];
    }
};

/// The secret a protected network is joined with, as configuration holds
/// it.
///
/// Two spellings, and the second is the better one to write down. A
/// passphrase becomes a key only once the network's name is known,
/// because the derivation is salted with it: the same words are a
/// different key on a different network. The derived key can therefore be
/// stored in place of the words, and it is worth doing, because an image
/// built for a machine that sits in a cupboard is a file somebody may
/// read, and a key opens the one network while a passphrase is often the
/// words its owner uses elsewhere.
pub const Psk = union(enum) {
    /// No secret, which is what an open network needs and what a slot
    /// that joins nothing has.
    none,
    /// The words, to be derived against the network's name when joining.
    passphrase: Passphrase,
    /// The derived key itself.
    key: [KEY_BYTES]u8,

    pub const KEY_BYTES = 32;
    const HEX_DIGITS = KEY_BYTES * 2;

    pub const accepts = "a passphrase of 8 to 63 characters, or 64 hex digits";

    pub fn parse(text: []const u8) ?Psk {
        const trimmed = str.trim(text);
        if (trimmed.len == 0) return .none;

        // A key is unambiguous: nothing else is exactly that many hex
        // digits, and a passphrase of that length would be unusual enough
        // that reading it as a key is the safer guess.
        if (trimmed.len == HEX_DIGITS) {
            if (decodeKey(trimmed)) |key| return .{ .key = key };
        }
        return .{ .passphrase = Passphrase.of(trimmed) orelse return null };
    }

    pub fn spell(self: Psk, into: *str.Builder) void {
        switch (self) {
            .none => {},
            .passphrase => |p| into.text(p.slice()),
            .key => |k| {
                for (k) |octet| {
                    into.byte(std.fmt.digitToChar(octet >> 4, .lower));
                    into.byte(std.fmt.digitToChar(octet & 0xF, .lower));
                }
            },
        }
    }

    fn decodeKey(text: []const u8) ?[KEY_BYTES]u8 {
        var out: [KEY_BYTES]u8 = @splat(0);
        for (&out, 0..) |*octet, i| {
            const high = std.fmt.charToDigit(text[i * 2], 16) catch return null;
            const low = std.fmt.charToDigit(text[i * 2 + 1], 16) catch return null;
            octet.* = (high << 4) | low;
        }
        return out;
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

// ---------------------------------------------------------------------------
// What a radio may do, and how loudly
// ---------------------------------------------------------------------------

/// Transmit power as this family of silicon spells it: half decibel
/// milliwatts in six bits, so a little over thirty-one dBm at the top of
/// the range.
pub const Power = struct {
    half_dbm: u6 = 0,

    /// The highest the field can hold, which is the highest the hardware
    /// will accept being told.
    pub const maximum = Power{ .half_dbm = std.math.maxInt(u6) };

    pub fn ofDbm(value: u8) Power {
        const halved: u16 = @as(u16, value) * 2;
        return .{ .half_dbm = @intCast(@min(halved, @as(u16, std.math.maxInt(u6)))) };
    }

    pub fn dbm(self: Power) u8 {
        return self.half_dbm / 2;
    }

    pub fn atMost(self: Power, limit: Power) Power {
        return .{ .half_dbm = @min(self.half_dbm, limit.half_dbm) };
    }
};

/// Whose channel plan a radio is following.
pub const Domain = enum {
    /// The Americas: eleven channels in this band.
    fcc,
    /// Europe and most elsewhere: thirteen.
    etsi,
    /// Japan, which has the fourteenth.
    mkk,

    pub fn highestChannel(self: Domain) u8 {
        return switch (self) {
            .fcc => 11,
            .etsi => 13,
            .mkk => 14,
        };
    }

    /// The conducted power the plan permits. All three agree in this band
    /// at a hundred milliwatts; what separates them is how many channels
    /// there are, and the figure is named here so a plan that later
    /// disagrees has somewhere to say so.
    pub fn limit(self: Domain) Power {
        return switch (self) {
            .fcc, .etsi, .mkk => Power.ofDbm(20),
        };
    }
};

/// Which plan the radio obeys.
///
/// A card's calibration store names the domain it was built for as a
/// vendor code, and this system has no table turning those codes into
/// plans. So the card's own word is read as the plan no regulator
/// forbids rather than guessed at, and an operator who knows better says
/// so. That is what the other two cases are for, and why neither is a
/// default.
pub const Regulatory = union(enum) {
    /// The narrowest plan of the three, which every regulator permits.
    conservative,
    /// A plan named by whoever operates the machine.
    domain: Domain,
    /// No plan at all: every channel the band defines, at the highest
    /// power the silicon accepts. For a bench, a screened room, or
    /// spectrum the operator holds. A radio running under this says so
    /// every time it starts, because nothing else in the system will.
    unrestricted,

    pub fn highestChannel(self: Regulatory) u8 {
        return switch (self) {
            .conservative => Domain.fcc.highestChannel(),
            .domain => |d| d.highestChannel(),
            .unrestricted => ghz2_channels[ghz2_channels.len - 1] + 1,
        };
    }

    pub fn allows(self: Regulatory, channel: u8) bool {
        return channel >= 1 and channel <= self.highestChannel();
    }

    /// The most this plan permits being transmitted at.
    pub fn limit(self: Regulatory) Power {
        return switch (self) {
            .conservative => Domain.fcc.limit(),
            .domain => |d| d.limit(),
            .unrestricted => Power.maximum,
        };
    }

    pub const accepts = "conservative | fcc | etsi | mkk | unrestricted";

    pub fn parse(text: []const u8) ?Regulatory {
        const trimmed = str.trim(text);
        if (trimmed.len == 0) return .conservative;
        if (std.mem.eql(u8, trimmed, "conservative")) return .conservative;
        if (std.mem.eql(u8, trimmed, "unrestricted")) return .unrestricted;
        if (std.meta.stringToEnum(Domain, trimmed)) |d| return .{ .domain = d };
        return null;
    }

    pub fn spell(self: Regulatory, into: *str.Builder) void {
        switch (self) {
            .conservative => into.text("conservative"),
            .domain => |d| into.text(@tagName(d)),
            .unrestricted => into.text("unrestricted"),
        }
    }
};

/// What the radio is told to transmit at.
///
/// Ordinarily the plan decides, and that is the first case. The second is
/// for the times a plan's ceiling does not reach: a machine behind enough
/// concrete that the router hears nothing, or a bench measuring what the
/// silicon actually does. It is taken as given rather than clamped,
/// because clamping it would make it the same setting as the first one,
/// and a driver asked to exceed a plan says which plan it exceeded.
pub const TxPower = union(enum) {
    /// Whatever the regulatory plan allows.
    regulatory,
    /// A fixed number of decibel milliwatts.
    fixed: u8,
    /// The highest the silicon will accept being told, which is a case of
    /// its own rather than a number: the field holds half decibels, so
    /// the top of it is not a whole one and asking for it in whole ones
    /// lands half a decibel short.
    maximum,

    pub fn resolve(self: TxPower, plan: Regulatory) Power {
        return switch (self) {
            .regulatory => plan.limit(),
            .fixed => |d| Power.ofDbm(d),
            .maximum => Power.maximum,
        };
    }

    /// Whether this asks for more than the plan permits, which is a thing
    /// a radio should say out loud rather than do quietly.
    pub fn exceeds(self: TxPower, plan: Regulatory) bool {
        return self.resolve(plan).half_dbm > plan.limit().half_dbm;
    }

    pub const accepts = "regulatory | max | a number of dBm";

    pub fn parse(text: []const u8) ?TxPower {
        const trimmed = str.trim(text);
        if (trimmed.len == 0) return .regulatory;
        if (std.mem.eql(u8, trimmed, "regulatory")) return .regulatory;
        if (std.mem.eql(u8, trimmed, "max")) return .maximum;
        const dbm = std.fmt.parseInt(u8, trimmed, 10) catch return null;
        return .{ .fixed = dbm };
    }

    pub fn spell(self: TxPower, into: *str.Builder) void {
        switch (self) {
            .regulatory => into.text("regulatory"),
            .fixed => |d| into.number(d),
            .maximum => into.text("max"),
        }
    }
};

test "power is held the way the silicon takes it, and saturates there" {
    try std.testing.expectEqual(@as(u6, 40), Power.ofDbm(20).half_dbm);
    try std.testing.expectEqual(@as(u8, 20), Power.ofDbm(20).dbm());
    // Above what six bits hold, the answer is what six bits hold.
    try std.testing.expectEqual(Power.maximum.half_dbm, Power.ofDbm(200).half_dbm);
    try std.testing.expectEqual(@as(u6, 10), Power.ofDbm(30).atMost(Power.ofDbm(5)).half_dbm);
}

test "a plan says how far up the band goes" {
    try std.testing.expectEqual(@as(u8, 11), Domain.fcc.highestChannel());
    try std.testing.expectEqual(@as(u8, 13), Domain.etsi.highestChannel());
    try std.testing.expectEqual(@as(u8, 14), Domain.mkk.highestChannel());

    const conservative: Regulatory = .conservative;
    try std.testing.expect(conservative.allows(11));
    try std.testing.expect(!conservative.allows(12));
    try std.testing.expect(!conservative.allows(0));

    const europe = Regulatory{ .domain = .etsi };
    try std.testing.expect(europe.allows(13));
    try std.testing.expect(!europe.allows(14));

    // Nothing is out of bounds when there is no plan.
    const none: Regulatory = .unrestricted;
    try std.testing.expect(none.allows(14));
    try std.testing.expectEqual(Power.maximum.half_dbm, none.limit().half_dbm);
}

test "a plan reads and writes back as what it was" {
    var buf: [32]u8 = undefined;
    for ([_]Regulatory{ .conservative, .{ .domain = .fcc }, .{ .domain = .mkk }, .unrestricted }) |plan| {
        var built = str.Builder{ .buf = &buf };
        plan.spell(&built);
        const spelled = built.done();
        const back = Regulatory.parse(spelled) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(std.meta.Tag(Regulatory), plan), @as(std.meta.Tag(Regulatory), back));
        try std.testing.expectEqual(plan.highestChannel(), back.highestChannel());
    }
    // Nothing written is the safe plan, and a word nobody defined is refused.
    try std.testing.expectEqual(@as(std.meta.Tag(Regulatory), .conservative), @as(std.meta.Tag(Regulatory), Regulatory.parse("").?));
    try std.testing.expectEqual(@as(?Regulatory, null), Regulatory.parse("wherever"));
}

test "asked for more than the plan allows, the setting says so" {
    const plan = Regulatory{ .domain = .etsi };

    const ordinary: TxPower = .regulatory;
    try std.testing.expectEqual(Power.ofDbm(20).half_dbm, ordinary.resolve(plan).half_dbm);
    try std.testing.expect(!ordinary.exceeds(plan));

    // The stairwell: more than the plan permits, taken as asked.
    const pushed = TxPower{ .fixed = 30 };
    try std.testing.expectEqual(Power.ofDbm(30).half_dbm, pushed.resolve(plan).half_dbm);
    try std.testing.expect(pushed.exceeds(plan));

    // Under no plan there is nothing to exceed.
    try std.testing.expect(!pushed.exceeds(.unrestricted));

    const loudest = TxPower.parse("max") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Power.maximum.half_dbm, loudest.resolve(plan).half_dbm);
    try std.testing.expect(loudest.exceeds(plan));
    try std.testing.expectEqual(@as(u8, 14), TxPower.parse("14").?.fixed);
    try std.testing.expectEqual(@as(?TxPower, null), TxPower.parse("loud"));
}

test "a network name is a setting like any other" {
    var buf: [64]u8 = undefined;
    const named = Ssid.parse("home network") orelse return std.testing.expect(false);
    try std.testing.expectEqualStrings("home network", named.slice());

    var built = str.Builder{ .buf = &buf };
    named.spell(&built);
    try std.testing.expectEqualStrings("home network", built.done());

    // Nothing named is not the same as a hidden network being asked for.
    try std.testing.expect(Ssid.parse("").?.isHidden());
    try std.testing.expectEqual(@as(?Ssid, null), Ssid.parse("x" ** 33));
}

test "a secret is read as a key when it can only be one" {
    const key_text = "0123456789abcdef" ** 4;
    const parsed = Psk.parse(key_text) orelse return std.testing.expect(false);
    try std.testing.expectEqual(@as(std.meta.Tag(Psk), .key), @as(std.meta.Tag(Psk), parsed));
    try std.testing.expectEqual(@as(u8, 0x01), parsed.key[0]);
    try std.testing.expectEqual(@as(u8, 0xef), parsed.key[Psk.KEY_BYTES - 1]);

    var buf: [128]u8 = undefined;
    var built = str.Builder{ .buf = &buf };
    parsed.spell(&built);
    try std.testing.expectEqualStrings(key_text, built.done());
}

test "words are words, and too few of them are refused" {
    const words = Psk.parse("correct horse battery") orelse return std.testing.expect(false);
    try std.testing.expectEqual(@as(std.meta.Tag(Psk), .passphrase), @as(std.meta.Tag(Psk), words));
    try std.testing.expectEqualStrings("correct horse battery", words.passphrase.slice());

    try std.testing.expectEqual(@as(std.meta.Tag(Psk), .none), @as(std.meta.Tag(Psk), Psk.parse("").?));
    // Below the standard's floor is not a secret this can be used with.
    try std.testing.expectEqual(@as(?Psk, null), Psk.parse("short"));
    // A key's length is one past what words may be, so a string that is
    // neither is refused rather than truncated into one of them.
    try std.testing.expectEqual(@as(?Psk, null), Psk.parse("z" ** 64));
    // One shorter is words, whatever it looks like.
    const hex_shaped = Psk.parse("0123456789abcdef" ** 3 ++ "0123456789abcde") orelse
        return std.testing.expect(false);
    try std.testing.expectEqual(@as(std.meta.Tag(Psk), .passphrase), @as(std.meta.Tag(Psk), hex_shaped));
}

test "airtime follows the physical layer's arithmetic for both modulations" {
    // An acknowledgement, fourteen bytes, and the gap before it.
    try std.testing.expectEqual(@as(u16, 314), Legacy.m1.airtime(14, false, true));
    try std.testing.expectEqual(@as(u16, 60), Legacy.m6.airtime(14, false, true));
    // A short preamble halves the slow rates' overhead, but the slowest
    // rate has none.
    try std.testing.expectEqual(@as(u16, 96 + 56 + 10), Legacy.m2.airtime(14, true, true));
    try std.testing.expectEqual(@as(u16, 314), Legacy.m1.airtime(14, true, true));
    // Without the gap, the frame alone.
    try std.testing.expectEqual(@as(u16, 44), Legacy.m6.airtime(14, false, false));
}
