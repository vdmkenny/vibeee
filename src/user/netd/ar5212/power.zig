//! Map2, normal-width 2.4 GHz power limits. References: ah_eeprom_v3.c
//! readEepromTargetPowerCalInfo/readEepromCTLInfo; ar5212_reset.c
//! GetTargetPowers/GetMaxEdgePower/SetRateTable; ah_regdomain.c getctl and
//! getantennareduction. Only the explicitly checked world SKUs are supported.

const std = @import("std");
const family = @import("family.zig");

pub const Error = error{ Unsupported, Invalid, Unreadable, Channel, BelowCalibration };
const CTLS = 32;
const EDGES = 8;
const CTL_INDEX = 0x128;
const CCK_OFFSET = 0x65 - 0x55;
const OFDM_OFFSET = 0x69 - 0x55;
const EDGE_OFFSET = 0x6F - 0x55;

pub const Target = struct {
    mhz: u16 = 0,
    half_dbm: [4]u6 = @splat(0),
};

pub const Edge = struct {
    mhz: u16 = 0,
    half_dbm: u6 = 0,
    inband: bool = false,
};

pub const Ctl = struct {
    code: u8 = 0,
    edges: [EDGES]Edge = @splat(.{}),
    count: u8 = 0,
};

pub const Limits = struct {
    cck: [2]Target = @splat(.{}),
    ofdm: [3]Target = @splat(.{}),
    cck_count: u8 = 0,
    ofdm_count: u8 = 0,
    ctls: [CTLS]Ctl = @splat(.{}),
};

fn word(source: anytype, store: *const family.Store, at: usize) Error!u16 {
    if (at < family.StoreAt.atheros_base or at >= store.checked_end) return error.Invalid;
    return source.word(@intCast(at)) orelse error.Unreadable;
}

pub fn read(source: anytype, store: *const family.Store) Error!Limits {
    if (store.map != 2 or !store.version.atLeast(.v5_0) or @intFromEnum(store.version) > @intFromEnum(family.StoreVersion.v5_4) or
        !store.calibration_modes[@intFromEnum(family.StoreMode.g)]) return error.Unsupported;
    try worldChannel(store.regulatory_domain, 2412);
    // The header and its CTL indices end at 0x138 (0x142 with 5.3 spurs). Calibration and targets
    // must not point into header words, even if those words checksum.
    const header_end: u16 = if (store.version.atLeast(.v5_3)) 0x142 else 0x138;
    if (store.target_powers_start < header_end or store.power_cal_start < header_end) return error.Invalid;
    var limits = Limits{};
    limits.cck_count = try readTargets(source, store, @as(usize, store.target_powers_start) + CCK_OFFSET, &limits.cck);
    limits.ofdm_count = try readTargets(source, store, @as(usize, store.target_powers_start) + OFDM_OFFSET, &limits.ofdm);
    var have_cck = false;
    var have_ofdm = false;
    for (&limits.ctls, 0..) |*ctl, i| {
        const pair = try word(source, store, CTL_INDEX + i / 2);
        ctl.code = @truncate(pair >> @as(u4, if (i % 2 == 0) 8 else 0));
        if (ctl.code == 0) continue;
        if (ctl.code == 0xFF) return error.Invalid;
        const mode = ctl.code & 0xF;
        if (mode != 1 and mode != 2) continue;
        const base = @as(usize, store.target_powers_start) + EDGE_OFFSET + i * 8;
        var ended = false;
        for (&ctl.edges, 0..) |*edge, j| {
            const shift: u4 = if (j % 2 == 0) 8 else 0;
            const fbin: u8 = @truncate((try word(source, store, base + j / 2)) >> shift);
            const packed_power: u8 = @truncate((try word(source, store, base + 4 + j / 2)) >> shift);
            if (fbin == 0 and packed_power == 0) {
                ended = true;
                continue;
            }
            if (ended or fbin == 0 or fbin == 0xFF or packed_power & 0x80 != 0) return error.Invalid;
            edge.* = .{ .mhz = 2300 + @as(u16, fbin), .half_dbm = @truncate(packed_power), .inband = packed_power & 0x40 != 0 };
            if (edge.half_dbm == 0 or (j != 0 and edge.mhz <= ctl.edges[j - 1].mhz)) return error.Invalid;
            ctl.count += 1;
        }
        if (ctl.count == 0) return error.Invalid;
        if (mode == 1) have_cck = true else have_ofdm = true;
    }
    // HAL defaults missing CTLs to 63. Do not invent approval for a board
    // whose relevant conformance data is absent.
    if (!have_cck or !have_ofdm) return error.Invalid;
    return limits;
}

fn readTargets(source: anytype, store: *const family.Store, start: usize, into: []Target) Error!u8 {
    var at = start;
    var count: u8 = 0;
    var ended = false;
    for (into) |*target| {
        const first = try word(source, store, at);
        at += 1;
        const fbin: u8 = @truncate(first >> 8);
        // HAL consumes only one word when the channel byte is zero.
        if (fbin == 0) {
            if (first != 0) return error.Invalid;
            ended = true;
            continue;
        }
        if (ended or fbin == 0xFF) return error.Invalid;
        const second = try word(source, store, at);
        at += 1;
        target.* = .{
            .mhz = 2300 + @as(u16, fbin),
            .half_dbm = .{ @truncate(first >> 2), @truncate((first << 4) | (second >> 12)), @truncate(second >> 6), @truncate(second) },
        };
        if (count != 0 and target.mhz <= into[count - 1].mhz) return error.Invalid;
        for (target.half_dbm) |value| if (value == 0) return error.Invalid;
        count += 1;
    }
    if (count == 0) return error.Invalid;
    return count;
}

/// These SKUs share SD_NO_CTL and 20 dBm/0 dBi normal-width world bands.
/// WOR0/02 have passive channels 12/13; this driver has no 11d authorization
/// path, so it cannot initiate TX there. EU1 explicitly permits active 1-13.
fn worldChannel(domain: u16, mhz: u16) Error!void {
    const highest: u16 = switch (domain) {
        0x60, 0x66, 0x67, 0x69 => 2462,
        0x68 => 2472,
        else => return error.Unsupported,
    };
    if (mhz < 2412 or mhz > highest or (mhz - 2412) % 5 != 0) return error.Channel;
}

/// HAL's EEP_SCALE=100 ratio is truncated before the weighted sum. A single
/// division of the full interpolation expression differs at some channels.
fn targetsAt(targets: []const Target, mhz: u16) [4]u6 {
    if (mhz <= targets[0].mhz) return targets[0].half_dbm;
    for (targets[1..], 1..) |right, i| {
        if (mhz > right.mhz) continue;
        const left = targets[i - 1];
        const ratio = @as(u32, mhz - left.mhz) * 100 / (right.mhz - left.mhz);
        var result: [4]u6 = undefined;
        for (&result, 0..) |*value, rate| value.* = @intCast((ratio * right.half_dbm[rate] + (100 - ratio) * left.half_dbm[rate]) / 100);
        return result;
    }
    return targets[targets.len - 1].half_dbm;
}

fn edgePower(ctl: *const Ctl, mhz: u16) u6 {
    // HAL brackets/clamps first, then uses the lower edge's flag even when
    // outside the listed range. It does not interpolate edge powers.
    var lower: usize = 0;
    for (ctl.edges[0..ctl.count], 0..) |edge, i| {
        if (edge.mhz > mhz) break;
        lower = i;
    }
    const edge = ctl.edges[lower];
    return if (edge.mhz == mhz or edge.inband) edge.half_dbm else 63;
}

pub const Rates = struct {
    /// HAL indices: OFDM 0..7; CCK 1L,2L,2S,5L,5S,11L,11S at 8..14.
    /// XR is unused and programmed to the minimum supported-rate index.
    indices: [16]u6,
    self_index: u6,

    pub fn words(self: Rates) [4]u32 {
        const order = [_][4]usize{ .{ 0, 1, 2, 3 }, .{ 4, 5, 6, 7 }, .{ 8, 15, 9, 10 }, .{ 11, 12, 13, 14 } };
        var result: [4]u32 = @splat(0);
        for (order, 0..) |indices, i| {
            for (indices, 0..) |index, byte| result[i] |= @as(u32, self.indices[index]) << @intCast(byte * 8);
        }
        return result;
    }
};

pub fn rates(limits: *const Limits, store: *const family.Store, mhz: u16, user_limit: u6, offset: i16) Error!Rates {
    try worldChannel(store.regulatory_domain, mhz);
    if (limits.cck_count == 0 or limits.cck_count > limits.cck.len or
        limits.ofdm_count == 0 or limits.ofdm_count > limits.ofdm.len) return error.Invalid;
    const cck = targetsAt(limits.cck[0..limits.cck_count], mhz);
    const ofdm = targetsAt(limits.ofdm[0..limits.ofdm_count], mhz);
    var edge_cck: u6 = 63;
    var edge_ofdm: u6 = 63;
    var have_cck = false;
    var have_ofdm = false;
    for (&limits.ctls) |*ctl| {
        if (ctl.count == 0) continue;
        if (ctl.count > EDGES) return error.Invalid;
        switch (ctl.code & 0xF) {
            1 => {
                have_cck = true;
                edge_cck = @min(edge_cck, edgePower(ctl, mhz));
            },
            2 => {
                have_ofdm = true;
                edge_ofdm = @min(edge_ofdm, edgePower(ctl, mhz));
            },
            else => {},
        }
    }
    if (!have_cck or !have_ofdm) return error.Invalid;
    // ath_hal_getantennareduction: max(EEPROM gain - 2*allowed gain, 0).
    // Checked world bands allow 0 dBi and 20 dBm; never let a user override
    // exceed this board/domain ceiling or increase it for negative gain.
    const reduction = @max(@as(i16, store.antenna_gain_2ghz), 0);
    const regulatory: u6 = @intCast(@max(40 - reduction, 0));
    const g = @min(user_limit, regulatory, edge_ofdm, ofdm[0]);
    const b = @min(user_limit, regulatory, edge_cck, cck[0]);
    var conducted: [16]u6 = .{
        g, g,               g,               g,               g,               @min(g, ofdm[1]), @min(g, ofdm[2]), @min(g, ofdm[3]),
        b, @min(b, cck[1]), @min(b, cck[1]), @min(b, cck[2]), @min(b, cck[2]), @min(b, cck[3]),  @min(b, cck[3]),  0,
    };
    conducted[15] = std.mem.min(u6, conducted[0..15]);
    var result: Rates = undefined;
    for (conducted, &result.indices) |value, *index| {
        const adjusted = @as(i32, value) + offset;
        // Clamping a negative index to zero would transmit ABOVE the limit.
        if (adjusted < 0) return error.BelowCalibration;
        index.* = @intCast(@min(adjusted, 63));
    }
    // ACK/CTS can answer either modulation; use the lowest validated limit.
    result.self_index = result.indices[15];
    return result;
}

const testing = std.testing;

const Image = struct {
    words: [family.StoreAt.end]u16 = @splat(0),

    pub fn word(self: *const Image, at: u16) ?u16 {
        return if (at < self.words.len) self.words[at] else null;
    }

    fn checksum(self: *Image) void {
        self.words[family.StoreAt.end - 1] = 0;
        var sum: u16 = 0;
        for (self.words[family.StoreAt.atheros_base..]) |w| sum ^= w;
        self.words[family.StoreAt.end - 1] = sum ^ 0xFFFF;
    }

    fn fixture() Image {
        var image = Image{};
        image.words[0xC1] = 0x5003;
        image.words[0xC2] = 4; // g dataset only, attach may advertise b.
        image.words[0xC3] = 6; // 3 dBi antenna; 2.4 GHz is the low byte.
        image.words[0xC4] = 0x8000; // Map2.
        image.words[0xC5] = 0x180; // Group5 target start.
        image.words[0xC8] = 0x1500; // Calibration start in bits 4..15.
        image.words[0xBF] = 0x60; // Actual notebook's WOR0 domain.
        image.words[0x1F] = 0x0011;
        image.words[0x1E] = 0x2233;
        image.words[0x1D] = 0x4455;
        image.words[0x10D + 9] = 0x10; // g xgain=8, highest gain only.
        image.words[0x150] = 0xA270; // Calibration piers: low byte first.
        // pwr_I=0,Vpd_I=20; four deltas pwr_t2=10,Vpd=10.
        const curve = [_]u16{ 0xA280, 0x2A8A, 0xA8AA, 0x0002 };
        @memcpy(image.words[0x152..0x156], &curve);
        @memcpy(image.words[0x156..0x15A], &curve);
        // Targets: first word fbin in HIGH byte, powers straddle words.
        // CCK [36,34,30,28] at 2412; [32,30,26,24] at 2462.
        image.words[0x190] = 0x7092;
        image.words[0x191] = 0x279C;
        image.words[0x192] = 0xA281;
        image.words[0x193] = 0xE698;
        // OFDM [38,34,30,26], [34,30,26,22], [30,26,22,18].
        image.words[0x194] = 0x709A;
        image.words[0x195] = 0x279A;
        image.words[0x196] = 0x8989;
        image.words[0x197] = 0xE696;
        image.words[0x198] = 0xA279;
        image.words[0x199] = 0xA592;
        // CTL indices high byte first. Empty slot 2 must still cost 8 words.
        image.words[0x128] = 0x1112; // FCC CCK, OFDM.
        image.words[0x129] = 0x0032; // ETSI OFDM in slot 3.
        image.words[0x19A] = 0x70A2;
        image.words[0x19E] = 0x6020; // CCK 32 half-dBm, lower edge inband.
        image.words[0x1A2] = 0x70A2;
        image.words[0x1A6] = 0x6424; // FCC OFDM 36.
        image.words[0x1B2] = 0x70A2;
        image.words[0x1B6] = 0x5C1C; // ETSI OFDM 28; SD_NO_CTL takes minimum.
        image.checksum();
        return image;
    }
};

test "raw map2 EEPROM through calibrated per-rate register words matches HAL layout" {
    const image = Image.fixture();
    var store = try family.readStore(&image);
    store.b_mode = true; // Runtime override must not skip a phantom b dataset.
    try testing.expectEqual(@as(u12, 0x180), store.target_powers_start);
    const curves = try family.readCurves(&image, &store, .g);
    const amplifier = family.powerTable(&curves, 2437, 2).?;
    try testing.expectEqual(@as(i16, 0), amplifier.floor_half_dbm);
    try testing.expectEqual(@as(u16, 44), amplifier.boundaries[0]);
    try testing.expectEqual(@as(u8, 20), amplifier.pdadc[0]);
    try testing.expectEqual(@as(u8, 30), amplifier.pdadc[10]);
    const limits = try read(&image, &store);
    try testing.expectEqualDeep([_]u6{ 36, 34, 30, 28 }, limits.cck[0].half_dbm);
    try testing.expectEqualDeep([_]u6{ 30, 26, 22, 18 }, limits.ofdm[2].half_dbm);
    try testing.expectEqual(@as(u8, 0x32), limits.ctls[3].code);
    // HAL: regulatory=40-max(6-0,0)=34; g=min(34,28,34)=28;
    // b=min(34,32,34)=32; high rates capped by their interpolated target.
    const result = try rates(&limits, &store, 2437, 63, 0);
    try testing.expectEqualDeep([_]u6{ 28, 28, 28, 28, 28, 28, 26, 22, 32, 32, 32, 28, 28, 26, 26, 22 }, result.indices);
    try testing.expectEqualDeep([_]u32{ 0x1C1C1C1C, 0x161A1C1C, 0x20201620, 0x1A1A1C1C }, result.words());
    try testing.expectEqual(@as(u6, 22), result.self_index);
    const offset = try rates(&limits, &store, 2437, 63, -4);
    try testing.expectEqual(@as(u6, 24), offset.indices[0]);
    try testing.expectEqual(@as(u6, 18), offset.self_index);
    const user = try rates(&limits, &store, 2437, 10, 0);
    try testing.expectEqualDeep([_]u6{10} ** 16, user.indices);
    try testing.expectError(error.BelowCalibration, rates(&limits, &store, 2437, 3, -4));
    store.antenna_gain_2ghz = 20;
    const antenna = try rates(&limits, &store, 2437, 63, 0);
    try testing.expectEqualDeep([_]u6{20} ** 16, antenna.indices);
    store.antenna_gain_2ghz = -8;
    const negative_gain = try rates(&limits, &store, 2437, 63, 0);
    try testing.expectEqualDeep(result, negative_gain);
}

test "HAL target ratio rounding and CTL exact inband out-of-band behavior" {
    const targets = [_]Target{
        .{ .mhz = 2412, .half_dbm = @splat(40) },
        .{ .mhz = 2472, .half_dbm = @splat(10) },
    };
    // ratio=floor(5*100/60)=8, result=floor((8*10+92*40)/100)=37.
    try testing.expectEqual(@as(u6, 37), targetsAt(&targets, 2417)[0]);
    try testing.expectEqual(@as(u6, 40), targetsAt(&targets, 2400)[0]);
    try testing.expectEqual(@as(u6, 10), targetsAt(&targets, 2484)[0]);
    var ctl = Ctl{ .count = 2 };
    ctl.edges[0] = .{ .mhz = 2412, .half_dbm = 28 };
    ctl.edges[1] = .{ .mhz = 2462, .half_dbm = 24 };
    try testing.expectEqual(@as(u6, 28), edgePower(&ctl, 2412));
    try testing.expectEqual(@as(u6, 24), edgePower(&ctl, 2462));
    try testing.expectEqual(@as(u6, 63), edgePower(&ctl, 2437));
    try testing.expectEqual(@as(u6, 63), edgePower(&ctl, 2400));
    ctl.edges[0].inband = true;
    try testing.expectEqual(@as(u6, 28), edgePower(&ctl, 2437));
    try testing.expectEqual(@as(u6, 28), edgePower(&ctl, 2400));
    try testing.expectEqual(@as(u6, 63), edgePower(&ctl, 2472));
    ctl.edges[1].inband = true;
    try testing.expectEqual(@as(u6, 24), edgePower(&ctl, 2472));
}

test "invalid power data and unsupported modes or channels never enable TX" {
    var image = Image.fixture();
    var store = try family.readStore(&image);
    const limits = try read(&image, &store);
    try testing.expectError(error.Channel, rates(&limits, &store, 2467, 40, 0));
    try testing.expectError(error.Channel, rates(&limits, &store, 2484, 40, 0));
    try testing.expectError(error.Channel, rates(&limits, &store, 5180, 40, 0));
    store.regulatory_domain = 0x68;
    _ = try rates(&limits, &store, 2472, 40, 0);
    store.regulatory_domain = 0xFFFF;
    try testing.expectError(error.Unsupported, read(&image, &store));
    store.regulatory_domain = 0x60;
    store.map = 1;
    try testing.expectError(error.Unsupported, read(&image, &store));
    store.map = 2;
    store.version = .v4_6;
    try testing.expectError(error.Unsupported, read(&image, &store));
    store.version = .v5_3;
    store.checked_end = 0x1B6;
    try testing.expectError(error.Invalid, read(&image, &store));
    store.checked_end = family.StoreAt.end;
    store.target_powers_start = 0xFFF;
    try testing.expectError(error.Invalid, read(&image, &store));
    store.target_powers_start = 0x180;
    image.words[0x128] = 0;
    try testing.expectError(error.Invalid, read(&image, &store)); // No CCK CTL.
    image = Image.fixture();
    image.words[0x19A] = 0x7070;
    try testing.expectError(error.Invalid, read(&image, &store)); // Duplicate edges.
    image = Image.fixture();
    image.words[0x192] = 0x7081;
    try testing.expectError(error.Invalid, read(&image, &store)); // Duplicate targets.
    image = Image.fixture();
    image.words[0x190] = 0;
    try testing.expectError(error.Invalid, read(&image, &store)); // Torn target list.
    image = Image.fixture();
    image.words[0x191] = 0;
    try testing.expectError(error.Invalid, read(&image, &store)); // Missing rate targets.
}

test "HAL target list consumes one word per absent pier and indices saturate" {
    var image = Image.fixture();
    const store = try family.readStore(&image);
    image.words[0x192] = 0;
    image.words[0x196] = 0;
    image.words[0x197] = 0;
    const limits = try read(&image, &store);
    try testing.expectEqual(@as(u8, 1), limits.cck_count);
    try testing.expectEqual(@as(u8, 1), limits.ofdm_count);
    const zero = try rates(&limits, &store, 2437, 0, 0);
    try testing.expectEqualDeep([_]u6{0} ** 16, zero.indices);
    const saturated = try rates(&limits, &store, 2437, 63, 63);
    try testing.expectEqualDeep([_]u6{63} ** 16, saturated.indices);
}
