//! The Atheros AR5212 family's pure vocabulary: the descriptor the silicon
//! reads and writes, the chains it walks, the rate codes it speaks, and the
//! baseband arithmetic the reference does in the open.
//!
//! Everything here is host-tested and touches no register. The driver in
//! `user/netd` hands these numbers to the hardware; what is here is the part
//! that can be checked without a radio in the room, against the reference
//! implementation, FreeBSD's Atheros hardware layer pinned under
//! `third_party/ath_hal`: descriptor bit positions, the synthesizer word for
//! a frequency, the OFDM delta-slope coefficients, the serialiser that packs
//! a field into an analog bank, the noise-floor history, and the I/Q
//! correction arithmetic.
//!
//! The descriptor is eight words, of which the first two mean the same thing
//! in both directions and the remaining six are read as a transmission's
//! instructions or as a reception's account of what arrived. That is what
//! the union says, and it is the reason a chain can be one array rather
//! than two. A field this file does not spell is one a caller must not
//! invent.

const std = @import("std");
const mac = @import("mac.zig");
const rates = @import("rates.zig");
const wifi = @import("wifi.zig");

// ---------------------------------------------------------------------------
// Descriptors
// ---------------------------------------------------------------------------

/// A descriptor is eight words on this generation, whichever way it is
/// used. The hardware requires four-byte alignment and reads them in order,
/// so the shape is `extern` rather than packed: these are words at fixed
/// offsets, not a bit string.
pub const DESC_BYTES = 32;

/// What the descriptor says a frame is, for the protocol unit's timing.
pub const FrameType = enum(u4) {
    normal = 0,
    atim = 1,
    ps_poll = 2,
    beacon = 3,
    probe_response = 4,
    chirp = 5,
    group_poll = 6,
    _,
};

/// The first word of a transmission's instructions.
///
/// Length counts the whole frame including the four-byte check sequence
/// the hardware appends, which is the one field a caller cannot omit.
pub const TxControl0 = packed struct(u32) {
    frame_length: u12 = 0,
    _12: u4 = 0,
    /// In half decibel-milliwatts, capped by the power table the reset
    /// programmed.
    transmit_power: u6 = 0,
    rts_cts_enable: bool = false,
    veol: bool = false,
    clear_destination_mask: bool = false,
    antenna_mode: u4 = 0,
    interrupt_request: bool = false,
    destination_index_valid: bool = false,
    cts_enable: bool = false,
};

/// The second word: how much of the buffer this descriptor covers, whether
/// another descriptor continues the same frame, and which key it is
/// ciphered with.
pub const TxControl1 = packed struct(u32) {
    buffer_length: u12 = 0,
    more: bool = false,
    destination_index: u7 = 0,
    frame_type: FrameType = .normal,
    no_acknowledgement: bool = false,
    compression: u2 = 0,
    compression_iv_length: u2 = 0,
    compression_icv_length: u2 = 0,
    _31: u1 = 0,
};

/// The third word: the protection exchange's duration, and how many times
/// each of the four rate series is tried.
pub const TxControl2 = packed struct(u32) {
    rts_cts_duration: u15 = 0,
    duration_update: bool = false,
    tries0: u4 = 0,
    tries1: u4 = 0,
    tries2: u4 = 0,
    tries3: u4 = 0,
};

/// The fourth word: the four rates of the retry series, and the rate a
/// protection frame goes at.
pub const TxControl3 = packed struct(u32) {
    rate0: RateCode = .none,
    rate1: RateCode = .none,
    rate2: RateCode = .none,
    rate3: RateCode = .none,
    rts_cts_rate: RateCode = .none,
    _25: u7 = 0,
};

/// Which rate a given step of the series was set to. The four fields are
/// reached by name for the same reason they are written that way.
pub fn rateOfStep(word: TxControl3, step: u2) RateCode {
    inline for (0..rates.SERIES) |which| {
        if (which == step) return @field(word, std.fmt.comptimePrint("rate{d}", .{which}));
    }
    unreachable;
}

/// The first status word a completed transmission leaves behind.
pub const TxStatus0 = packed struct(u32) {
    sent: bool = false,
    excessive_retries: bool = false,
    fifo_underrun: bool = false,
    filtered: bool = false,
    rts_failures: u4 = 0,
    data_failures: u4 = 0,
    virtual_collisions: u4 = 0,
    timestamp: u16 = 0,
};

/// The second: completion, the sequence number the hardware assigned, and
/// which series finally went.
pub const TxStatus1 = packed struct(u32) {
    done: bool = false,
    sequence: u12 = 0,
    ack_signal: u8 = 0,
    final_series: u2 = 0,
    compression_success: bool = false,
    transmit_antenna: bool = false,
    _25: u7 = 0,
};

/// The check bytes the hardware appends to every frame it sends. They are
/// not in the buffer, and they are counted in the length the frame states.
pub const CHECK_BYTES = 4;

/// The longest frame a descriptor can state, the check bytes included.
pub const MAX_FRAME = std.math.maxInt(u12) - CHECK_BYTES;

/// What a frame needs said about it before it can go out.
pub const Send = struct {
    /// The frame as it sits in the buffer: header and body, no check bytes.
    /// No longer than `MAX_FRAME`, which the buffer it came from proves.
    frame_bytes: u12,
    /// How fast to try, and how many goes at each. Worked down in order:
    /// the first is the hope and the last is the one that has to arrive.
    /// An empty series is a frame with no way to go out.
    series: rates.Series = .{},
    /// Half decibel-milliwatts, capped by the table the reset programmed.
    power: u6,
    kind: FrameType = .normal,
    /// Cleared for the group addresses, which nothing answers.
    acknowledged: bool = true,
    /// The key the body is ciphered with, or none to send it in clear.
    key: ?u7 = null,
    /// Which aerials the frame may leave by; zero leaves the choice made
    /// at reset standing.
    antenna: u4 = 0,

    /// What the hardware is told the frame measures: the buffer, plus the
    /// check bytes it appends itself.
    pub fn statedLength(self: Send) u12 {
        return self.frame_bytes + CHECK_BYTES;
    }
};

/// What a transmission left behind, both status words.
pub const Sent = struct {
    status0: TxStatus0,
    status1: TxStatus1,

    /// Whether the hardware is finished with the descriptor. Until it is,
    /// the rest of the words mean nothing.
    pub fn done(self: Sent) bool {
        return self.status1.done;
    }

    /// Why the frame did not go, or null if it did.
    pub fn failure(self: Sent) ?Failure {
        if (self.status0.sent) return null;
        if (self.status0.fifo_underrun) return .underrun;
        if (self.status0.excessive_retries) return .unanswered;
        if (self.status0.filtered) return .filtered;
        return .refused;
    }
};

/// The ways a frame fails to leave.
pub const Failure = enum {
    /// The descriptor was read slower than the air needed it.
    underrun,
    /// Every try went unacknowledged.
    unanswered,
    /// The hardware held the frame back rather than sending it.
    filtered,
    /// Finished, unsent, and for none of the stated reasons.
    refused,
};

/// A receive descriptor's second word: how much buffer it offers, and
/// whether the hardware raises an interrupt on filling it.
pub const RxControl1 = packed struct(u32) {
    buffer_length: u12 = 0,
    _12: u1 = 0,
    interrupt_request: bool = false,
    _14: u18 = 0,
};

/// What a reception says about the bytes it put in the buffer.
pub const RxStatus0 = packed struct(u32) {
    data_length: u12 = 0,
    more: bool = false,
    decompression_error: bool = false,
    _14: u1 = 0,
    rate: RateCode = .none,
    /// Decibels above the noise floor, as the baseband measured it.
    signal: u8 = 0,
    antenna: u4 = 0,
};

/// Whether the hardware has finished with a receive descriptor, and what
/// it thought of the frame.
///
/// `done` is the ownership bit in both directions: the driver clears it
/// before handing a descriptor over and the hardware sets it when it is
/// finished, so a descriptor with it clear belongs to the radio and must
/// not be touched.
/// Why the baseband gave up on a frame.
///
/// The two families are the two modulations: a radio failing every OFDM
/// frame and no CCK one is configured wrongly for one of them, and which
/// half is failing says which. Non-exhaustive, because the silicon has
/// codes this list does not name and one of those is still worth
/// reporting by its number.
pub const PhyError = enum(u8) {
    underrun = 0,
    timing = 1,
    parity = 2,
    rate = 3,
    length = 4,
    radar = 5,
    service = 6,
    transmit_override = 7,
    ofdm_timing = 17,
    ofdm_signal_parity = 18,
    ofdm_rate = 19,
    ofdm_length = 20,
    ofdm_power_drop = 21,
    ofdm_service = 22,
    ofdm_restart = 23,
    false_radar = 24,
    cck_timing = 25,
    cck_header_crc = 26,
    cck_rate = 27,
    cck_service = 30,
    cck_restart = 31,
    cck_length = 32,
    _,
};

/// Which modulation a reason belongs to. The two demodulators fail
/// separately and are made harder to convince separately, so a count of
/// failures is only useful once it is split this way.
pub const Modulation = enum { ofdm, cck, either };

pub fn modulationOf(why: PhyError) Modulation {
    return switch (why) {
        .ofdm_timing,
        .ofdm_signal_parity,
        .ofdm_rate,
        .ofdm_length,
        .ofdm_power_drop,
        .ofdm_service,
        .ofdm_restart,
        => .ofdm,
        .cck_timing,
        .cck_header_crc,
        .cck_rate,
        .cck_service,
        .cck_restart,
        .cck_length,
        => .cck,
        else => .either,
    };
}

pub const RxStatus1 = packed struct(u32) {
    done: bool = false,
    received: bool = false,
    check_sequence_error: bool = false,
    decrypt_check_error: bool = false,
    physical_error: bool = false,
    michael_error: bool = false,
    _6: u2 = 0,
    key_index_valid: bool = false,
    key_index: u7 = 0,
    timestamp: u15 = 0,
    key_cache_miss: bool = false,

    /// Whether the frame is worth passing up. Anything the hardware
    /// flagged is dropped: a radio hears a great deal that is not for it
    /// and not intact, and the count of those belongs in statistics
    /// rather than in the stack.
    /// Why the baseband gave up, or null for a frame it did not.
    ///
    /// The code sits where the key index goes, because the two never both
    /// apply: a frame that failed in the baseband was never decrypted and
    /// has no key to name.
    pub fn phyError(self: RxStatus1) ?PhyError {
        if (!self.physical_error) return null;
        const low: u8 = @intFromBool(self.key_index_valid);
        return @enumFromInt(low | (@as(u8, self.key_index) << 1));
    }

    pub fn intact(self: RxStatus1) bool {
        return self.received and !self.check_sequence_error and
            !self.decrypt_check_error and !self.physical_error and
            !self.michael_error;
    }

    /// The baseband's error code, which overlays the key index when the
    /// physical-error bit is set.
    pub fn physicalErrorCode(self: RxStatus1) u8 {
        const view: PhysicalErrorView = @bitCast(self);
        return view.code;
    }

    const PhysicalErrorView = packed struct(u32) {
        _0: u8,
        code: u8,
        _16: u16,
    };
};

/// The six words after the link and the buffer, read one way or the other.
/// One descriptor shape serves both directions because the silicon has
/// only one, and a union says that without costing a byte.
pub const Body = extern union {
    tx: extern struct {
        control0: u32 = 0,
        control1: u32 = 0,
        control2: u32 = 0,
        control3: u32 = 0,
        status0: u32 = 0,
        status1: u32 = 0,
    },
    rx: extern struct {
        control0: u32 = 0,
        control1: u32 = 0,
        status0: u32 = 0,
        status1: u32 = 0,
        _unused: [2]u32 = @splat(0),
    },
};

/// One descriptor as the hardware reads it.
pub const Desc = extern struct {
    /// The next descriptor's physical address, or zero to stop here.
    link: u32 = 0,
    /// The frame buffer's physical address.
    buffer: u32 = 0,
    body: Body = .{ .tx = .{} },

    /// Hand a receive descriptor to the radio: the buffer's length, an
    /// interrupt when it fills, no status, and the ownership bit clear.
    ///
    /// Volatile, because a descriptor is shared with something that reads
    /// and writes it without being asked. A plain pointer coerces, so a
    /// caller holding ordinary memory needs no cast and gets the ordering
    /// it would want anyway.
    pub fn armReceive(self: *volatile Desc, buffer_physical: u32, next_physical: u32, buffer_bytes: u12) void {
        self.link = next_physical;
        self.buffer = buffer_physical;
        self.body = .{ .rx = .{
            .control1 = @bitCast(RxControl1{ .buffer_length = buffer_bytes, .interrupt_request = true }),
        } };
    }

    /// Hand a transmit descriptor to the radio: where the frame is, how
    /// long, how fast, and how hard to try. The status words are cleared,
    /// so a reader can tell this frame's outcome from the last one's.
    pub fn armTransmit(self: *volatile Desc, buffer_physical: u32, next_physical: u32, send: Send) void {
        // The four steps of the series into the four pairs of fields the
        // two words hold, by name, so the four are written once.
        var tries = TxControl2{};
        var speeds = TxControl3{};
        const steps = send.series.slice();
        inline for (0..rates.SERIES) |step| {
            if (step < steps.len) {
                @field(tries, std.fmt.comptimePrint("tries{d}", .{step})) = steps[step].tries;
                @field(speeds, std.fmt.comptimePrint("rate{d}", .{step})) = RateCode.of(steps[step].rate);
            }
        }

        self.link = next_physical;
        self.buffer = buffer_physical;
        self.body = .{ .tx = .{
            .control0 = @bitCast(TxControl0{
                .frame_length = send.statedLength(),
                .transmit_power = send.power,
                .antenna_mode = send.antenna,
                .interrupt_request = true,
                .destination_index_valid = send.key != null,
            }),
            .control1 = @bitCast(TxControl1{
                .buffer_length = send.frame_bytes,
                .destination_index = send.key orelse 0,
                .frame_type = send.kind,
                .no_acknowledgement = !send.acknowledged,
            }),
            .control2 = @bitCast(@as(u32, @bitCast(tries))),
            .control3 = @bitCast(@as(u32, @bitCast(speeds))),
        } };
    }

    /// What a transmission reports, both status words.
    pub fn sent(self: *const volatile Desc) Sent {
        return .{
            .status0 = @bitCast(self.body.tx.status0),
            .status1 = @bitCast(self.body.tx.status1),
        };
    }

    /// What a reception reports, both status words.
    pub fn received(self: *const volatile Desc) struct { status0: RxStatus0, status1: RxStatus1 } {
        return .{
            .status0 = @bitCast(self.body.rx.status0),
            .status1 = @bitCast(self.body.rx.status1),
        };
    }
};

comptime {
    // The silicon's own shape, proved rather than trusted. A descriptor
    // that is not eight words in this order is one the hardware will read
    // as something else entirely.
    if (@sizeOf(Desc) != DESC_BYTES) @compileError("a 5212 descriptor is eight words");
    if (@offsetOf(Desc, "link") != 0 or @offsetOf(Desc, "buffer") != 4) {
        @compileError("the link and buffer words lead a descriptor");
    }
    if (@offsetOf(Desc, "body") != 8) @compileError("the body follows the first two words");
    if (@sizeOf(Body) != 24) @compileError("a descriptor body is six words either way");
    if (@alignOf(Desc) < 4) @compileError("the hardware reads descriptors word-aligned");

    // The bit positions the reference names.
    if (@as(u32, @bitCast(TxControl0{ .frame_length = 0xFFF })) != 0x0000_0FFF or
        @as(u32, @bitCast(TxControl0{ .transmit_power = 1 })) != 0x0001_0000 or
        @as(u32, @bitCast(TxControl0{ .interrupt_request = true })) != 0x2000_0000 or
        @as(u32, @bitCast(TxControl0{ .destination_index_valid = true })) != 0x4000_0000)
    {
        @compileError("the first transmit control word drifted");
    }
    if (@as(u32, @bitCast(TxControl1{ .more = true })) != 0x0000_1000 or
        @as(u32, @bitCast(TxControl1{ .destination_index = 1 })) != 0x0000_2000 or
        @as(u32, @bitCast(TxControl1{ .frame_type = .beacon })) != 0x0030_0000 or
        @as(u32, @bitCast(TxControl1{ .no_acknowledgement = true })) != 0x0100_0000)
    {
        @compileError("the second transmit control word drifted");
    }
    // The series the caller hands over and the pairs of fields these two
    // words hold are the same four, which is what lets one loop fill them
    // by name.
    if (rates.SERIES != 4) @compileError("the transmit control words hold four rates and four counts");

    if (@as(u32, @bitCast(TxControl2{ .tries0 = 1 })) != 0x0001_0000 or
        @as(u32, @bitCast(TxControl2{ .duration_update = true })) != 0x0000_8000)
    {
        @compileError("the third transmit control word drifted");
    }
    if (@as(u32, @bitCast(TxControl3{ .rate1 = .m54, .rate0 = .m1 })) != (0x0C << 5) | 0x1B or
        @as(u32, @bitCast(TxControl3{ .rts_cts_rate = .m54, .rate0 = .m1 })) != (0x0C << 20) | 0x1B)
    {
        @compileError("the fourth transmit control word drifted");
    }
    if (@as(u32, @bitCast(TxStatus0{ .filtered = true })) != 0x08 or
        @as(u32, @bitCast(TxStatus0{ .data_failures = 1 })) != 0x0100 or
        @as(u32, @bitCast(TxStatus1{ .done = true })) != 0x01 or
        @as(u32, @bitCast(TxStatus1{ .sequence = 0xFFF })) != 0x1FFE or
        @as(u32, @bitCast(TxStatus1{ .final_series = 3 })) != 0x0060_0000)
    {
        @compileError("the transmit status words drifted");
    }
    if (@as(u32, @bitCast(RxControl1{ .interrupt_request = true })) != 0x2000) {
        @compileError("the receive interrupt request bit drifted");
    }
    if (@as(u32, @bitCast(RxStatus0{ .rate = .m1 })) != (0x1B << 15) or
        @as(u32, @bitCast(RxStatus0{ .signal = 0xFF })) != 0x0FF0_0000 or
        @as(u32, @bitCast(RxStatus0{ .more = true })) != 0x1000)
    {
        @compileError("the first receive status word drifted");
    }
    if (@as(u32, @bitCast(RxStatus1{ .done = true })) != 0x01 or
        @as(u32, @bitCast(RxStatus1{ .received = true })) != 0x02 or
        @as(u32, @bitCast(RxStatus1{ .check_sequence_error = true })) != 0x04 or
        @as(u32, @bitCast(RxStatus1{ .decrypt_check_error = true })) != 0x08 or
        @as(u32, @bitCast(RxStatus1{ .physical_error = true })) != 0x10 or
        @as(u32, @bitCast(RxStatus1{ .michael_error = true })) != 0x20 or
        @as(u32, @bitCast(RxStatus1{ .key_index_valid = true })) != 0x100 or
        @as(u32, @bitCast(RxStatus1{ .key_index = 0x7F })) != 0xFE00 or
        @as(u32, @bitCast(RxStatus1{ .timestamp = 0x7FFF })) != 0x7FFF_0000 or
        @as(u32, @bitCast(RxStatus1{ .key_cache_miss = true })) != 0x8000_0000)
    {
        @compileError("the second receive status word drifted");
    }
}

// ---------------------------------------------------------------------------
// Chains
// ---------------------------------------------------------------------------

/// Where a chain's descriptors sit, and what each one's link should say.
///
/// A chain here is a circle the hardware does not know is one: every
/// descriptor names the next by physical address, and the last names the
/// first. The count is a compile-time number because a chain whose size is
/// not known until it runs is one whose wrap has to be checked at every
/// step. It is a power of two so the wrap is a mask rather than a
/// division, which is the only arithmetic on the packet path.
pub fn Chain(comptime slots: usize) type {
    if (slots < 2 or !std.math.isPowerOfTwo(slots)) {
        @compileError("a chain holds at least two descriptors, and a power of two of them");
    }

    return struct {
        pub const count = slots;
        const mask = slots - 1;

        /// The slot after this one, wrapping at the end.
        pub fn next(index: usize) usize {
            return (index + 1) & mask;
        }

        /// The physical address of one descriptor in a run of them laid
        /// end to end from `base`.
        pub fn addressOf(base: u32, index: usize) u32 {
            return base + @as(u32, @intCast((index & mask) * DESC_BYTES));
        }

        /// What descriptor `index` should name as its successor. The last
        /// names the first, so the hardware walking the chain never runs
        /// off the end of it and never needs telling where to go back to.
        pub fn linkFor(base: u32, index: usize) u32 {
            return addressOf(base, next(index));
        }

        /// Whether a run of this many descriptors starting at `base` fits
        /// below the four gigabyte line the hardware addresses within.
        pub fn addressable(base: u32) bool {
            const bytes = slots * DESC_BYTES;
            return base != 0 and base <= std.math.maxInt(u32) - @as(u32, @intCast(bytes - 1));
        }
    };
}

// ---------------------------------------------------------------------------
// Rates, as the hardware names them
// ---------------------------------------------------------------------------

/// The code the hardware names a legacy rate by, in a descriptor's rate
/// fields and in a reception's report. Not the standard's encoding but the
/// silicon's own, from the reference's rate tables; the three short
/// preamble forms are the codes the CCK rates take when the preamble is
/// halved, which the slowest rate cannot be.
pub const RateCode = enum(u5) {
    /// No rate: the code an unset field holds, which names nothing the
    /// reference lists.
    none = 0x00,
    m1 = 0x1B,
    m2 = 0x1A,
    m5_5 = 0x19,
    m11 = 0x18,
    m2_short = 0x1E,
    m5_5_short = 0x1D,
    m11_short = 0x1C,
    m6 = 0x0B,
    m9 = 0x0F,
    m12 = 0x0A,
    m18 = 0x0E,
    m24 = 0x09,
    m36 = 0x0D,
    m48 = 0x08,
    m54 = 0x0C,
    _,

    pub fn of(legacy: wifi.Legacy) RateCode {
        return switch (legacy) {
            .m1 => .m1,
            .m2 => .m2,
            .m5_5 => .m5_5,
            .m11 => .m11,
            .m6 => .m6,
            .m9 => .m9,
            .m12 => .m12,
            .m18 => .m18,
            .m24 => .m24,
            .m36 => .m36,
            .m48 => .m48,
            .m54 => .m54,
            _ => .m1,
        };
    }

    /// The rate a code names, or null for a code the reference does not
    /// list, which a reception may still report.
    pub fn rate(self: RateCode) ?wifi.Legacy {
        return switch (self) {
            .m1 => .m1,
            .m2, .m2_short => .m2,
            .m5_5, .m5_5_short => .m5_5,
            .m11, .m11_short => .m11,
            .m6 => .m6,
            .m9 => .m9,
            .m12 => .m12,
            .m18 => .m18,
            .m24 => .m24,
            .m36 => .m36,
            .m48 => .m48,
            .m54 => .m54,
            .none, _ => null,
        };
    }

    /// The code the same rate takes with a short preamble, for the rates
    /// that have one.
    pub fn short(self: RateCode) ?RateCode {
        return switch (self) {
            .m2 => .m2_short,
            .m5_5 => .m5_5_short,
            .m11 => .m11_short,
            else => null,
        };
    }
};

/// The rate the protocol unit answers a frame at this rate with: the
/// highest basic rate at or below it, from the reference's table.
pub fn controlRate(rate: wifi.Legacy) wifi.Legacy {
    return switch (rate) {
        .m1, .m2, .m5_5, .m11 => rate,
        .m6, .m9 => .m6,
        .m12, .m18 => .m12,
        else => .m24,
    };
}

// ---------------------------------------------------------------------------
// Baseband arithmetic
// ---------------------------------------------------------------------------

/// The word that tunes the RF2425's synthesizer to a 2.4 GHz frequency.
/// Two analog writes carry it: the low byte, then the next seven bits.
pub const SynthWord = packed struct(u16) {
    enable: bool = true,
    b_mode_synth: bool = false,
    a_mode_ref_sel: u2 = 0,
    /// The channel offset with its bits reversed, the way the analog
    /// shift register takes them.
    channel_sel: u8 = 0,
    fixed: bool = true,
    _13: u3 = 0,

    pub fn low(self: SynthWord) u8 {
        const halves: Halves = @bitCast(self);
        return halves.low;
    }

    pub fn high(self: SynthWord) u7 {
        const halves: Halves = @bitCast(self);
        return halves.high;
    }

    const Halves = packed struct(u16) { low: u8, high: u7, _15: u1 };
};

/// The synthesizer word for a 2.4 GHz frequency, or null for one this
/// radio has no band for.
pub fn synthWord(megahertz: u16) ?SynthWord {
    if (megahertz < 2312 or megahertz >= 4800) return null;
    const offset: u8 = @intCast(megahertz - 2272);
    return .{ .channel_sel = @bitReverse(offset) };
}

/// The OFDM delta-slope coefficients for a carrier frequency: the
/// mantissa and exponent the baseband's timing register takes, from the
/// reference's fixed-point rendering of 1e8 / carrier * clock / 40.
pub const DeltaSlope = struct { mantissa: u15, exponent: u4 };

pub fn deltaSlope(megahertz: u16) DeltaSlope {
    const SCALE_SHIFT = 24;
    const clock_scaled: u32 = 0x6400_0000;
    const coefficient = clock_scaled / megahertz;
    // The exponent places the leading bit; the mantissa is rounded to it.
    const leading = std.math.log2_int(u32, coefficient);
    const exponent: u5 = @intCast(14 - (@as(i32, leading) - SCALE_SHIFT));
    const rounding: u32 = @as(u32, 1) << @intCast(SCALE_SHIFT - exponent - 1);
    const mantissa = (coefficient + rounding) >> @intCast(SCALE_SHIFT - exponent);
    return .{ .mantissa = @intCast(mantissa), .exponent = @intCast(exponent - 16) };
}

/// Pack a field into an analog bank buffer, which is a bit stream the
/// radio's shift register takes eight bits per word at a time. The field's
/// bits go in reversed, from `first_bit` counted from one, in the byte
/// column the bank uses. This is the one place in the family where a value
/// becomes bits by hand, because the analog register file has no words to
/// name.
pub fn insertBankField(bank: []u32, value: u32, bits: u6, first_bit: u16, column: u2) void {
    var remaining: u32 = @bitReverse(value) >> @intCast(32 - @as(u6, bits));
    var entry: usize = (first_bit - 1) / 8;
    var position: u32 = (first_bit - 1) % 8;
    var left: u32 = bits;
    const shift: u5 = @intCast(@as(u32, column) * 8);
    while (left > 0) {
        const last: u32 = @min(8, position + left);
        const field_mask = ((@as(u32, 1) << @intCast(last)) - 1) ^ ((@as(u32, 1) << @intCast(position)) - 1);
        const mask = field_mask << shift;
        bank[entry] &= ~mask;
        bank[entry] |= ((remaining << @intCast(position)) << shift) & mask;
        left -|= 8 - position;
        remaining >>= @intCast(8 - position);
        position = 0;
        entry += 1;
    }
}

/// The noise floor as the driver keeps it: a short history of readings,
/// used only once a full window of plausible ones has been seen, and the
/// median of that window thereafter. A reading outside the plausible band
/// starts the window over.
pub const NoiseFloor = struct {
    /// What the baseband is told until it has measured better.
    pub const DEFAULT: i16 = -95;
    pub const HIGHEST_PLAUSIBLE: i16 = -62;
    pub const LOWEST_PLAUSIBLE: i16 = -125;
    pub const WINDOW = 5;

    history: [WINDOW]i16 = @splat(DEFAULT),
    index: u8 = 0,
    settling: bool = true,
    left: u8 = WINDOW,
    /// The value in use: the median once the window has filled.
    current: i16 = DEFAULT,

    /// Take one reading, and answer with the value to load into the
    /// baseband.
    pub fn add(self: *NoiseFloor, reading: i16) i16 {
        self.history[self.index] = reading;
        self.index = (self.index + 1) % WINDOW;
        if (self.settling) {
            if (reading < LOWEST_PLAUSIBLE or reading > HIGHEST_PLAUSIBLE) {
                self.left = WINDOW;
                return DEFAULT;
            }
            self.left -= 1;
            if (self.left > 0) return DEFAULT;
            self.settling = false;
        }
        self.current = median(self.history);
        return self.current;
    }

    fn median(values: [WINDOW]i16) i16 {
        var sorted = values;
        std.mem.sort(i16, &sorted, {}, std.sort.asc(i16));
        return sorted[WINDOW / 2];
    }
};

/// The I/Q mismatch correction the baseband computes from a calibration's
/// power and correlation measurements: a six-bit and a five-bit signed
/// coefficient, or null when the measurement is too small to trust.
pub const IqCorrection = struct { i: i6, q: i5 };

pub fn iqCorrection(power_i: u32, power_q: u32, correlation: i32) ?IqCorrection {
    // Prescaled, as the reference does, to stay within thirty-two bits.
    const i_denominator: u32 = (power_i / 2 + power_q / 2) / 128;
    const q_denominator: u32 = power_q / 128;
    if (i_denominator == 0 or q_denominator < 2) return null;

    // The reference keeps only the low byte of the negated correlation
    // before dividing; so does this.
    const flipped: i8 = @truncate(-%correlation);
    const i_raw = @divTrunc(@as(i64, flipped), @as(i64, i_denominator));
    const q_raw = @as(i64, power_i / q_denominator) - 128;
    return .{
        .i = @intCast(std.math.clamp(i_raw, -32, 31)),
        .q = @intCast(std.math.clamp(q_raw, -16, 15)),
    };
}

// ---------------------------------------------------------------------------
// What the reset sequence works out
// ---------------------------------------------------------------------------

/// The clock a spur is measured against on the RF2425 parts, in MHz.
pub const SPUR_CLOCK_MHZ = 32;

/// Whether a frequency sits near a harmonic of the reference clock, where
/// OFDM false detects need backing off: within ten megahertz of one.
pub fn isSpurChannel(megahertz: u16) bool {
    const offset = megahertz % SPUR_CLOCK_MHZ;
    return offset != 0 and (offset < 10 or offset > 22);
}

/// The CCK power adjustment relative to OFDM: the store's delta, in tenths
/// of a decibel, as the two fields the baseband takes. Channel fourteen
/// has its own filter allowance taken off the second.
pub const CckAdjust = struct { gain_delta: i6, pcdac_index: i6 };

pub fn cckAdjust(power_delta: u8, ch14_filter_delta: u5, megahertz: u16) CckAdjust {
    const delta: i32 = power_delta;
    const filtered: i32 = if (megahertz == 2484) delta - ch14_filter_delta else delta;
    return .{
        .gain_delta = @truncate(-delta),
        .pcdac_index = @truncate(-@divTrunc(filtered * 2, 10)),
    };
}

/// Whether a register in the common table holds a timer or the sleep
/// state, which a channel change keeps rather than rewrites.
pub fn survivesChannelChange(register: u16) bool {
    const BEACON = 0x8020;
    const CFP_DURATION = 0x8038;
    const SLEEP1 = 0x80D4;
    const SLEEP3 = 0x80DC;
    return (register >= BEACON and register <= CFP_DURATION) or (register >= SLEEP1 and register <= SLEEP3);
}

/// One entry of the rate-duration table: the time an answer at a rate
/// takes, which the protocol unit keeps per rate code for multi-rate
/// retry.
pub const RateDuration = struct { code: RateCode, micros: u16 };

/// The frame the unit times its answers by: an acknowledgement with its
/// check sequence.
pub const CONTROL_FRAME_BYTES = 14;

/// The whole table for the 2.4 GHz rates: every rate's own code, and the
/// short-preamble code of the CCK rates that have one.
pub const RATE_DURATIONS = blk: {
    var entries: [wifi.b_rates.len + wifi.g_rates.len + 3]RateDuration = undefined;
    var n: usize = 0;
    for (wifi.b_rates ++ wifi.g_rates) |rate| {
        const control = controlRate(rate);
        const code = RateCode.of(rate);
        entries[n] = .{ .code = code, .micros = control.airtime(CONTROL_FRAME_BYTES, false, true) };
        n += 1;
        if (code.short()) |short| {
            entries[n] = .{ .code = short, .micros = control.airtime(CONTROL_FRAME_BYTES, true, true) };
            n += 1;
        }
    }
    break :blk entries;
};

/// The radio's revision byte, as the baseband hands it back: its nibbles
/// swapped and its bits reversed.
pub fn radioRevision(raw: u8) u8 {
    const halves: Nibbles = @bitCast(raw);
    const swapped: u8 = @bitCast(Nibbles{ .low = halves.high, .high = halves.low });
    return @bitReverse(swapped);
}

const Nibbles = packed struct(u8) { low: u4, high: u4 };

// ---------------------------------------------------------------------------
// Transmit power: the amplifier's curve, from the store's calibration points
// ---------------------------------------------------------------------------
//
// The baseband does not take a power in decibels. It takes a table of a
// hundred and twenty-eight detector readings, one per half decibel, and the
// boundaries at which one gain setting of the amplifier gives way to the
// next. The store holds a handful of measured points per gain, at a handful
// of channels; the table is those points interpolated to the channel in use
// and filled in at every half decibel between them.
//
// All of it is arithmetic, so all of it is here and tested. What the driver
// does with the answer is write it to the baseband.

/// One gain setting's measured curve: the detector's reading at each of a
/// handful of powers.
pub const PdGain = struct {
    pub const MAX_POINTS = 5;

    /// Which gain setting of the amplifier this curve is for.
    gain: u16 = 0,
    points: u8 = 0,
    /// The detector's reading at each point.
    vpd: [MAX_POINTS]u16 = @splat(0),
    /// The power at each point, in quarter decibels.
    quarter_dbm: [MAX_POINTS]i16 = @splat(0),
};

/// The curves measured at one channel.
pub const CalChannel = struct {
    pub const MAX_GAINS = 4;

    max_quarter_dbm: i16 = 0,
    /// Highest gain setting first, which is the lowest power.
    per_gain: [MAX_GAINS]PdGain = @splat(.{}),
};

/// Every curve the store holds for a band.
pub const CalCurves = struct {
    pub const MAX_CHANNELS = 10;

    /// The channels measured, in ascending order.
    megahertz: [MAX_CHANNELS]u16 = @splat(0),
    channels: u8 = 0,
    per_channel: [MAX_CHANNELS]CalChannel = @splat(.{}),
};

/// What the baseband is given.
pub const PowerTable = struct {
    pub const ENTRIES = 128;

    /// One reading per half decibel.
    pdadc: [ENTRIES]u8 = @splat(0),
    /// Where each gain setting gives way to the next, in half decibels.
    boundaries: [CalChannel.MAX_GAINS]u16 = @splat(0),
    /// The gain settings used, lowest power first.
    gains: [CalChannel.MAX_GAINS]u16 = @splat(0),
    used: u8 = 0,
    /// The lowest power the curves were measured at, in half decibels. A
    /// power index into the table is counted from here, not from zero.
    floor_half_dbm: i16 = 0,
};

/// How far one gain setting's curve is carried past its boundary, in half
/// decibels: the reference stretches the last one by this much.
const GAIN_BOUNDARY_STRETCH: u16 = 4;

/// The most half-decibels one gain setting's curve covers.
const PWR_RANGE_HALF_DB = 64;

/// The highest reading the table holds.
const PDADC_MAX: u16 = 127;

/// Where a value sits in an ascending list: the entries either side of it,
/// or the same entry twice when it is one of them or outside the list.
fn bracket(comptime T: type, target: T, list: []const T) struct { lo: usize, hi: usize } {
    if (list.len == 0) return .{ .lo = 0, .hi = 0 };
    if (target < list[0]) return .{ .lo = 0, .hi = 0 };
    if (target >= list[list.len - 1]) return .{ .lo = list.len - 1, .hi = list.len - 1 };
    for (list, 0..) |value, i| {
        if (value == target) return .{ .lo = i, .hi = i };
        if (i + 1 < list.len and target < list[i + 1]) return .{ .lo = i, .hi = i + 1 };
    }
    return .{ .lo = list.len - 1, .hi = list.len - 1 };
}

/// A value read off the straight line between two measured points.
fn interpolate(target: i32, left: i32, right: i32, at_left: i32, at_right: i32) i32 {
    if (right == left) return at_left;
    return @divTrunc((target - left) * at_right + (right - target) * at_left, right - left);
}

/// Fill one gain's detector readings at every half decibel from `floor` to
/// `ceiling`, reading between the measured points and beyond the ends.
/// False when there are too few points to draw a line through.
fn fillVpd(gain: *const PdGain, floor: i16, ceiling: i16, into: *[PWR_RANGE_HALF_DB]u16) bool {
    const points = gain.points;
    if (points < 2) return false;

    const powers = gain.quarter_dbm[0..points];
    var step: usize = 0;
    // The measured powers are in quarter decibels and the steps are halves.
    var power: i16 = floor *| 2;
    while (step <= @as(usize, @intCast(@max(ceiling - floor, 0)))) : (step += 1) {
        if (step >= PWR_RANGE_HALF_DB) break;
        const near = bracket(i16, power, powers);
        // At the ends the line is carried on rather than stopped.
        const hi = @max(near.hi, 1);
        const lo = @min(near.lo, points - 2);
        into[step] = @intCast(std.math.clamp(
            interpolate(power, powers[lo], powers[hi], gain.vpd[lo], gain.vpd[hi]),
            0,
            std.math.maxInt(u16),
        ));
        power +|= 2;
    }
    return true;
}

/// The amplifier's table for a channel, from the curves either side of it.
///
/// `overlap_half_db` is how far the baseband is told the gain settings
/// overlap, which it holds in a register of its own.
pub fn powerTable(curves: *const CalCurves, megahertz: u16, overlap_half_db: u16) ?PowerTable {
    if (curves.channels == 0) return null;
    const near = bracket(u16, megahertz, curves.megahertz[0..curves.channels]);
    const left = &curves.per_channel[near.lo];
    const right = &curves.per_channel[near.hi];

    var out = PowerTable{};
    var floor: [CalChannel.MAX_GAINS]i16 = @splat(0);
    var ceiling: [CalChannel.MAX_GAINS]i16 = @splat(0);
    var curve: [CalChannel.MAX_GAINS][PWR_RANGE_HALF_DB]u16 = @splat(@splat(0));

    // Backwards, because the highest gain setting is the lowest power.
    var which: usize = CalChannel.MAX_GAINS;
    while (which > 0) {
        which -= 1;
        const on_left = &left.per_gain[which];
        const on_right = &right.per_gain[which];
        const points = on_left.points;
        if (points == 0) continue;

        const used = out.used;
        out.gains[used] = on_left.gain;
        // The lower of the two channels' ends, so the curve covers both.
        floor[used] = @divTrunc(@min(on_left.quarter_dbm[0], on_right.quarter_dbm[0]), 2);
        ceiling[used] = @divTrunc(@min(
            on_left.quarter_dbm[points - 1],
            on_right.quarter_dbm[points - 1],
        ), 2);

        var on_the_left: [PWR_RANGE_HALF_DB]u16 = @splat(0);
        var on_the_right: [PWR_RANGE_HALF_DB]u16 = @splat(0);
        if (!fillVpd(on_left, floor[used], ceiling[used], &on_the_left)) continue;
        if (!fillVpd(on_right, floor[used], ceiling[used], &on_the_right)) continue;

        const span: usize = @intCast(@max(ceiling[used] - floor[used], 0));
        for (0..@min(span, PWR_RANGE_HALF_DB)) |step| {
            curve[used][step] = @intCast(std.math.clamp(interpolate(
                megahertz,
                curves.megahertz[near.lo],
                curves.megahertz[near.hi],
                on_the_left[step],
                on_the_right[step],
            ), 0, std.math.maxInt(u16)));
        }
        out.used += 1;
    }
    if (out.used == 0) return null;

    out.floor_half_dbm = floor[0];

    var at: usize = 0;
    for (0..out.used) |gain| {
        // The last gain setting has no successor to meet, so its curve is
        // carried a little past its end.
        out.boundaries[gain] = if (gain == out.used - 1)
            @intCast(@max(ceiling[gain] + GAIN_BOUNDARY_STRETCH, 0))
        else
            @intCast(@max(@divTrunc(ceiling[gain] + floor[gain + 1], 2), 0));

        // Where this gain's curve starts, which is below its own floor when
        // the setting before it stopped short.
        var step: i32 = if (gain == 0)
            0
        else
            (@as(i32, out.boundaries[gain - 1]) - floor[gain]) - overlap_half_db;

        // Below the measured points the curve is carried on at the slope it
        // starts with, never below nothing.
        const rising: i32 = @max(@as(i32, curve[gain][1]) - @as(i32, curve[gain][0]), 1);
        while (step < 0 and at < PowerTable.ENTRIES) : (step += 1) {
            const value = @as(i32, curve[gain][0]) + step * rising;
            out.pdadc[at] = @intCast(std.math.clamp(value, 0, PDADC_MAX));
            at += 1;
        }

        const span: i32 = ceiling[gain] - floor[gain];
        const wanted: i32 = @as(i32, out.boundaries[gain]) + overlap_half_db - floor[gain];
        const measured = @min(wanted, span);
        while (step < measured and at < PowerTable.ENTRIES) : (step += 1) {
            out.pdadc[at] = @intCast(@min(curve[gain][@intCast(step)], PDADC_MAX));
            at += 1;
        }

        // Past the measured points, likewise carried on at the slope it ends
        // with, never above what the table can hold.
        if (span >= 2) {
            const falling: i32 = @max(
                @as(i32, curve[gain][@intCast(span - 1)]) - @as(i32, curve[gain][@intCast(span - 2)]),
                1,
            );
            while (step < wanted and at < PowerTable.ENTRIES) : (step += 1) {
                const value = @as(i32, curve[gain][@intCast(span - 1)]) + (step - measured) * falling;
                out.pdadc[at] = @intCast(std.math.clamp(value, 0, PDADC_MAX));
                at += 1;
            }
        }
    }

    // A boundary for every setting, and a reading for every half decibel:
    // the last of each stands for whatever is past the end.
    for (out.used..CalChannel.MAX_GAINS) |gain| {
        out.boundaries[gain] = out.boundaries[gain - 1];
    }
    while (at < PowerTable.ENTRIES) : (at += 1) {
        out.pdadc[at] = if (at == 0) 0 else out.pdadc[at - 1];
    }
    return out;
}

// ---------------------------------------------------------------------------
// The calibration store
// ---------------------------------------------------------------------------

/// The store's version word: a major and a minor the reference compares
/// as one number, so a later minor of an earlier major stays earlier.
pub const StoreVersion = enum(u16) {
    v3_0 = 0x3000,
    v3_1 = 0x3001,
    v3_2 = 0x3002,
    v3_3 = 0x3003,
    v3_4 = 0x3004,
    v4_0 = 0x4000,
    v4_1 = 0x4001,
    v4_2 = 0x4002,
    v4_3 = 0x4003,
    v4_6 = 0x4006,
    v5_0 = 0x5000,
    v5_1 = 0x5001,
    v5_3 = 0x5003,
    v5_4 = 0x5004,
    _,

    pub fn atLeast(self: StoreVersion, floor: StoreVersion) bool {
        return @intFromEnum(self) >= @intFromEnum(floor);
    }

    pub fn major(self: StoreVersion) u4 {
        const halves: VersionHalves = @bitCast(@intFromEnum(self));
        return halves.major;
    }

    pub fn minor(self: StoreVersion) u12 {
        const halves: VersionHalves = @bitCast(@intFromEnum(self));
        return halves.minor;
    }

    const VersionHalves = packed struct(u16) { minor: u12, major: u4 };
};

/// Word offsets into the store.
pub const StoreAt = struct {
    pub const talon = 0x0B;
    pub const rf_silent = 0x0F;
    pub const size_lower = 0x1B;
    pub const size_upper = 0x1C;
    /// The station address: three words, highest first.
    pub const mac_top = 0x1F;
    pub const magic = 0x3D;
    pub const protect = 0x3F;
    pub const regulatory_domain = 0xBF;
    /// Where the vendor's own area begins; the checksum runs from here.
    pub const atheros_base = 0xC0;
    pub const version = 0xC1;
    pub const capabilities = 0xC9;
    pub const regulatory_capabilities = 0xCA;
    pub const regulatory_capabilities_before_4_0 = 0xCF;
    pub const bias_2ghz_before_3_3 = 0xEC;
    pub const end = 0x400;
};

pub const STORE_MAGIC: u16 = 0x5AA5;

/// Where the header's parts sit; the layout moved at version 3.3.
const HeaderMap = struct { modes: u16, gains: u16, sections: [3]u16 };
const HEADER_3_0 = HeaderMap{ .modes = 0xC2, .gains = 0xC4, .sections = .{ 0xC5, 0xD0, 0xDA } };
const HEADER_3_3 = HeaderMap{ .modes = 0xC2, .gains = 0xC3, .sections = .{ 0xD4, 0xF2, 0x10D } };

/// The three moded sections of the header, in the store's order.
pub const StoreMode = enum(u2) { a = 0, b = 1, g = 2 };

// The header's words, each as the reference reads it.
const ModesWord = packed struct(u16) {
    a_mode: bool = false,
    b_mode: bool = false,
    g_mode: bool = false,
    turbo2_disable: bool = false,
    turbo2w_max_power5: u7 = 0,
    device_type: u3 = 0,
    rf_kill: bool = false,
    turbo5_disable: bool = false,
};
const GainsWord = packed struct(u16) { ghz2: i8 = 0, ghz5: i8 = 0 };
const MapWord = packed struct(u16) { ear_start: u12 = 0, disable_xr2: bool = false, disable_xr5: bool = false, map: u2 = 0 };
const TargetsWord = packed struct(u16) { target_powers_start: u12 = 0, _12: u2 = 0, crystal_32khz: bool = false, _15: u1 = 0 };
const SizeUpperWord = packed struct(u16) { _0: u4 = 0, high: u12 = 0 };

// A moded section's words, in order. Antenna settings straddle words, so
// a field with `_high` and `_low` halves is joined on reading.
const SectionWord0 = packed struct(u16) { antenna0_high: u2 = 0, txrx_attenuation: u6 = 0, switch_settling: u7 = 0, _15: u1 = 0 };
const SectionWord1 = packed struct(u16) { antenna2: u6 = 0, antenna1: u6 = 0, antenna0_low: u4 = 0 };
const SectionWord2 = packed struct(u16) { antenna5_high: u4 = 0, antenna4: u6 = 0, antenna3: u6 = 0 };
const SectionWord3 = packed struct(u16) { antenna8_high: u2 = 0, antenna7: u6 = 0, antenna6: u6 = 0, antenna5_low: u2 = 0 };
const SectionWord4 = packed struct(u16) { antenna10: u6 = 0, antenna9: u6 = 0, antenna8_low: u4 = 0 };
const SectionWord5 = packed struct(u16) { bias: u8 = 0, adc_desired_size: i8 = 0 };
const Bias24Byte = packed struct(u8) { db: u3 = 0, _3: u1 = 0, ob: u3 = 0, _7: u1 = 0 };
const BiasAByte = packed struct(u8) { ob3_high: u2 = 0, db4: u3 = 0, ob4: u3 = 0 };
const SectionWord5a = packed struct(u16) { db1: u3 = 0, ob1: u3 = 0, db2: u3 = 0, ob2: u3 = 0, db3: u3 = 0, ob3_low: u1 = 0 };
const SectionWord6 = packed struct(u16) { threshold62: u8 = 0, tx_end_to_xlna_on: u8 = 0 };
const SectionWord7 = packed struct(u16) { tx_frame_to_xpa_on: u8 = 0, tx_end_to_xpa_off: u8 = 0 };
const SectionWord8 = packed struct(u16) { noise_floor_threshold: i8 = 0, pga_desired_size: i8 = 0 };
const SectionWord9 = packed struct(u16) { xpd: bool = false, xgain: u4 = 0, xlna_gain: u8 = 0, fixed_bias: bool = false, _14: u2 = 0 };
const SectionWord10 = packed struct(u16) { low: u6 = 0, false_detect_backoff: u7 = 0, gain_i_low: u3 = 0 };
const Bias2GHzField = packed struct(u6) { ob: u3 = 0, db: u3 = 0 };
const SectionWord11G = packed struct(u16) { gain_i_high: u3 = 0, cck_ofdm_power_delta: u8 = 0, scaled_ch14_filter_cck_delta: u5 = 0 };
const SectionWord11A = packed struct(u16) { gain_i_high: u3 = 0, iq_cal_q: u5 = 0, iq_cal_i: u6 = 0, _14: u2 = 0 };
const SectionWord11B = packed struct(u16) { gain_i_high: u3 = 0, _3: u13 = 0 };
const PierMarginWord = packed struct(u16) { pier: u8 = 0, rxtx_margin: u6 = 0, _14: u2 = 0 };
const GPowersWord = packed struct(u16) { turbo2w_max_power2: u7 = 0, xr_target_power2: u6 = 0, _13: u3 = 0 };
const IqWord = packed struct(u16) { iq_cal_q: u5 = 0, iq_cal_i: u6 = 0, _11: u5 = 0 };
const GainDeltaWord = packed struct(u16) { cck_ofdm_gain_delta: u8 = 0, switch_settling_turbo: u7 = 0, txrx_attenuation_turbo_low: u1 = 0 };
const AMarginWord = packed struct(u16) { rxtx_margin: u6 = 0, switch_settling_turbo: u7 = 0, txrx_attenuation_turbo_low: u3 = 0 };

const RegulatoryCapabilities = packed struct(u16) {
    _0: u6 = 0,
    fcc_midband: bool = false,
    kk_u1_even: bool = false,
    kk_u2: bool = false,
    kk_midband: bool = false,
    kk_u1_odd: bool = false,
    kk_new_11a: bool = false,
    _12: u2 = 0,
    kk_u1_odd_before_4_0: bool = false,
    kk_new_11a_before_4_0: bool = false,
};

/// What the card may do, from version 5.1 on; zero before.
pub const Capabilities = packed struct(u16) {
    compression_disabled: bool = false,
    aes_disabled: bool = false,
    fast_frames_disabled: bool = false,
    burst_disabled: bool = false,
    max_queues: u5 = 0,
    heavy_clip: bool = false,
    _10: u2 = 0,
    key_cache_entries_log2: u4 = 0,
};

/// How the kill switch reaches the chip, when the store says there is one.
pub const RfSilent = packed struct(u16) {
    _0: u1 = 0,
    polarity: u1 = 0,
    gpio: u3 = 0,
    _5: u11 = 0,
};

/// The output and driver bias of a band, as the analog bank takes them.
pub const Bias = struct { ob: u3 = 0, db: u3 = 0 };

/// One moded section of the header.
pub const ModeSection = struct {
    switch_settling: u7 = 0,
    txrx_attenuation: u6 = 0,
    antenna_control: [11]u6 = @splat(0),
    adc_desired_size: i8 = 0,
    pga_desired_size: i8 = 0,
    tx_end_to_xlna_on: u8 = 0,
    threshold62: u8 = 0,
    tx_end_to_xpa_off: u8 = 0,
    tx_frame_to_xpa_on: u8 = 0,
    noise_floor_threshold: i16 = 0,
    xlna_gain: u8 = 0,
    xgain: u4 = 0,
    xpd: bool = false,
    false_detect_backoff: u7 = 0,
    gain_i: u6 = 0,
};

/// What the driver keeps of the store: the header, and the few words
/// outside it a reset or a join needs. The power calibration curves, the
/// conformance limits and the spur table are not read; transmit power
/// is what a later pass owes.
pub const Store = struct {
    version: StoreVersion,
    protect: u16,
    regulatory_domain: u16,
    a_mode: bool,
    b_mode: bool,
    g_mode: bool,
    turbo2_disable: bool,
    turbo5_disable: bool,
    rf_kill: bool,
    device_type: u3,
    antenna_gain_2ghz: i8,
    antenna_gain_5ghz: i8,
    map: u2 = 0,
    crystal_32khz: bool = false,
    sections: [3]ModeSection = @splat(.{}),
    /// The bias each 2.4 GHz mode's section names, which the RF2425's
    /// sixth bank is patched with.
    bias_b: Bias = .{},
    bias_g: Bias = .{},
    /// The bias pair of later stores, by band index: 5 GHz then 2.4.
    bias_2ghz: [2]Bias = @splat(.{}),
    bias_5ghz: [4]Bias = @splat(.{}),
    /// Indexed by band: 5 GHz then 2.4 GHz.
    iq_cal_i: [2]u6 = @splat(0),
    iq_cal_q: [2]u5 = @splat(0),
    /// Indexed by section.
    rxtx_margin: [3]u6 = @splat(0),
    fixed_bias_5ghz: bool = false,
    fixed_bias_2ghz: bool = false,
    cck_ofdm_power_delta: u8 = 15,
    scaled_ch14_filter_cck_delta: u5 = 15,
    cck_ofdm_gain_delta: u8 = 15,
    regulatory_capabilities: u16 = 0,
    capabilities: Capabilities = .{},
    rf_silent: RfSilent = .{},
    talon: bool = false,
    mac: mac.Address,

    pub fn section(self: *const Store, mode: StoreMode) *const ModeSection {
        return &self.sections[@intFromEnum(mode)];
    }
};

pub const StoreError = error{
    /// A word did not come back.
    Unreadable,
    /// Older than the format this file reads.
    Version,
    Checksum,
    /// The station address is unwritten.
    Address,
};

/// The number the reference's later versions give a section it has no
/// value for.
const GAIN_I_DEFAULT: u6 = 10;

/// Read the store through `source`, whose `word(offset)` gives one
/// sixteen-bit word or null when the store does not answer. Pure over
/// that one call, so a synthetic store can be read on the host.
pub fn readStore(source: anytype) StoreError!Store {
    const version: StoreVersion = @enumFromInt(try readWord(source, StoreAt.version));
    if (!version.atLeast(.v3_0)) return StoreError.Version;
    const protect = try readWord(source, StoreAt.protect);

    // The vendor's area must add up before any of it is believed.
    const upper: SizeUpperWord = @bitCast(try readWord(source, StoreAt.size_upper));
    var words: u32 = StoreAt.end - StoreAt.atheros_base;
    if (@as(u16, @bitCast(upper)) != 0) {
        const lower = try readWord(source, StoreAt.size_lower);
        words = ((@as(u32, upper.high) << 16) | lower) -| StoreAt.atheros_base;
        if (words == 0 or words > StoreAt.end - StoreAt.atheros_base) return StoreError.Checksum;
    }
    var sum: u16 = 0;
    for (0..words) |i| sum ^= try readWord(source, @intCast(StoreAt.atheros_base + i));
    if (sum != 0xFFFF) return StoreError.Checksum;

    const map = if (version.atLeast(.v3_3)) HEADER_3_3 else HEADER_3_0;

    const modes: ModesWord = @bitCast(try readWord(source, map.modes));
    var store = Store{
        .version = version,
        .protect = protect,
        .regulatory_domain = 0,
        .a_mode = modes.a_mode,
        .b_mode = modes.b_mode,
        .g_mode = modes.g_mode,
        .turbo2_disable = if (version.atLeast(.v4_0)) modes.turbo2_disable else true,
        .turbo5_disable = modes.turbo5_disable,
        .rf_kill = modes.rf_kill,
        .device_type = modes.device_type,
        .antenna_gain_2ghz = 0,
        .antenna_gain_5ghz = 0,
        .mac = @splat(0),
    };

    var at: u16 = map.gains;
    const gains: GainsWord = @bitCast(try readWord(source, at));
    at += 1;
    store.antenna_gain_5ghz = gains.ghz5;
    store.antenna_gain_2ghz = gains.ghz2;
    if (version.atLeast(.v4_0)) {
        const mapping: MapWord = @bitCast(try readWord(source, at));
        at += 1;
        store.map = mapping.map;
        const targets: TargetsWord = @bitCast(try readWord(source, at));
        store.crystal_32khz = targets.crystal_32khz;
    }

    for ([_]StoreMode{ .a, .b, .g }) |mode| {
        try readSection(source, &store, map, mode);
    }

    if (!version.atLeast(.v3_3)) {
        const b: Bias2GHzField = @bitCast(@as(u6, @truncate(try readWord(source, StoreAt.bias_2ghz_before_3_3))));
        store.bias_2ghz[0] = .{ .ob = b.ob, .db = b.db };
        const g: Bias2GHzField = @bitCast(@as(u6, @truncate(try readWord(source, StoreAt.bias_2ghz_before_3_3 + 1))));
        store.bias_2ghz[1] = .{ .ob = g.ob, .db = g.db };
    }

    // Early stores measured the noise floor and the signal threshold on a
    // different scale; the reference overrides them.
    if (!version.atLeast(.v3_3)) {
        store.sections[0].noise_floor_threshold = -54;
        store.sections[1].noise_floor_threshold = -1;
        store.sections[2].noise_floor_threshold = -1;
        store.sections[0].threshold62 = 15;
        store.sections[1].threshold62 = 28;
        store.sections[2].threshold62 = 28;
    }

    const capability_at: u16 = if (version.atLeast(.v4_0)) StoreAt.regulatory_capabilities else StoreAt.regulatory_capabilities_before_4_0;
    store.regulatory_capabilities = try readWord(source, capability_at);
    if (!store.a_mode) {
        const regulatory: RegulatoryCapabilities = @bitCast(store.regulatory_capabilities);
        store.a_mode = if (version.atLeast(.v4_0)) regulatory.kk_new_11a else regulatory.kk_new_11a_before_4_0;
    }
    if (version.atLeast(.v5_1)) store.capabilities = @bitCast(try readWord(source, StoreAt.capabilities));

    store.regulatory_domain = try readWord(source, StoreAt.regulatory_domain);

    // The address, highest word first, each word most significant byte
    // first. An unwritten store reads as all zeroes or all ones, and
    // neither is an address.
    var total: u32 = 0;
    for (0..3) |i| {
        const w = try readWord(source, @intCast(StoreAt.mac_top - i));
        total += w;
        std.mem.writeInt(u16, store.mac[i * 2 ..][0..2], w, .big);
    }
    if (total == 0 or total == 3 * 0xFFFF) return StoreError.Address;

    if (store.rf_kill) store.rf_silent = @bitCast(try readWord(source, StoreAt.rf_silent));
    if (version.atLeast(.v5_4)) store.talon = (try readWord(source, StoreAt.talon)) == 1;
    return store;
}

fn readWord(source: anytype, offset: u16) StoreError!u16 {
    return source.word(offset) orelse StoreError.Unreadable;
}

fn readSection(source: anytype, store: *Store, map: HeaderMap, mode: StoreMode) StoreError!void {
    const version = store.version;
    const section = &store.sections[@intFromEnum(mode)];
    var at = map.sections[@intFromEnum(mode)];

    const w0: SectionWord0 = @bitCast(try readWord(source, at));
    at += 1;
    section.switch_settling = w0.switch_settling;
    section.txrx_attenuation = w0.txrx_attenuation;

    const w1: SectionWord1 = @bitCast(try readWord(source, at));
    at += 1;
    section.antenna_control[0] = (@as(u6, w0.antenna0_high) << 4) | w1.antenna0_low;
    section.antenna_control[1] = w1.antenna1;
    section.antenna_control[2] = w1.antenna2;

    const w2: SectionWord2 = @bitCast(try readWord(source, at));
    at += 1;
    section.antenna_control[3] = w2.antenna3;
    section.antenna_control[4] = w2.antenna4;

    const w3: SectionWord3 = @bitCast(try readWord(source, at));
    at += 1;
    section.antenna_control[5] = (@as(u6, w2.antenna5_high) << 2) | w3.antenna5_low;
    section.antenna_control[6] = w3.antenna6;
    section.antenna_control[7] = w3.antenna7;

    const w4: SectionWord4 = @bitCast(try readWord(source, at));
    at += 1;
    section.antenna_control[8] = (@as(u6, w3.antenna8_high) << 4) | w4.antenna8_low;
    section.antenna_control[9] = w4.antenna9;
    section.antenna_control[10] = w4.antenna10;

    const w5: SectionWord5 = @bitCast(try readWord(source, at));
    at += 1;
    section.adc_desired_size = w5.adc_desired_size;
    switch (mode) {
        .a => {
            const a: BiasAByte = @bitCast(w5.bias);
            store.bias_5ghz[3] = .{ .ob = a.ob4, .db = a.db4 };
            const w5a: SectionWord5a = @bitCast(try readWord(source, at));
            at += 1;
            store.bias_5ghz[2] = .{ .ob = (@as(u3, a.ob3_high) << 1) | w5a.ob3_low, .db = w5a.db3 };
            store.bias_5ghz[1] = .{ .ob = w5a.ob2, .db = w5a.db2 };
            store.bias_5ghz[0] = .{ .ob = w5a.ob1, .db = w5a.db1 };
        },
        .b => {
            const b: Bias24Byte = @bitCast(w5.bias);
            store.bias_b = .{ .ob = b.ob, .db = b.db };
        },
        .g => {
            const g: Bias24Byte = @bitCast(w5.bias);
            store.bias_g = .{ .ob = g.ob, .db = g.db };
        },
    }

    const w6: SectionWord6 = @bitCast(try readWord(source, at));
    at += 1;
    section.tx_end_to_xlna_on = w6.tx_end_to_xlna_on;
    section.threshold62 = w6.threshold62;

    const w7: SectionWord7 = @bitCast(try readWord(source, at));
    at += 1;
    section.tx_end_to_xpa_off = w7.tx_end_to_xpa_off;
    section.tx_frame_to_xpa_on = w7.tx_frame_to_xpa_on;

    const w8: SectionWord8 = @bitCast(try readWord(source, at));
    at += 1;
    section.pga_desired_size = w8.pga_desired_size;
    section.noise_floor_threshold = w8.noise_floor_threshold;

    const w9: SectionWord9 = @bitCast(try readWord(source, at));
    at += 1;
    section.xlna_gain = w9.xlna_gain;
    section.xgain = w9.xgain;
    section.xpd = w9.xpd;
    if (version.atLeast(.v4_0)) switch (mode) {
        .a => store.fixed_bias_5ghz = w9.fixed_bias,
        .g => store.fixed_bias_2ghz = w9.fixed_bias,
        .b => {},
    };

    if (version.atLeast(.v3_3)) {
        const w10: SectionWord10 = @bitCast(try readWord(source, at));
        at += 1;
        section.false_detect_backoff = w10.false_detect_backoff;
        switch (mode) {
            .b, .g => {
                const bias: Bias2GHzField = @bitCast(w10.low);
                store.bias_2ghz[if (mode == .b) 0 else 1] = .{ .ob = bias.ob, .db = bias.db };
            },
            .a => {},
        }
        if (version.atLeast(.v3_4)) {
            const w11 = try readWord(source, at);
            at += 1;
            switch (mode) {
                .g => {
                    const g: SectionWord11G = @bitCast(w11);
                    section.gain_i = (@as(u6, g.gain_i_high) << 3) | w10.gain_i_low;
                    store.cck_ofdm_power_delta = g.cck_ofdm_power_delta;
                    if (version.atLeast(.v4_6)) store.scaled_ch14_filter_cck_delta = g.scaled_ch14_filter_cck_delta;
                },
                .a => {
                    const a: SectionWord11A = @bitCast(w11);
                    section.gain_i = (@as(u6, a.gain_i_high) << 3) | w10.gain_i_low;
                    if (version.atLeast(.v4_0)) {
                        store.iq_cal_i[0] = a.iq_cal_i;
                        store.iq_cal_q[0] = a.iq_cal_q;
                    }
                },
                .b => {
                    const b: SectionWord11B = @bitCast(w11);
                    section.gain_i = (@as(u6, b.gain_i_high) << 3) | w10.gain_i_low;
                },
            }
        } else {
            section.gain_i = GAIN_I_DEFAULT;
        }
    } else {
        section.gain_i = GAIN_I_DEFAULT;
    }

    if (!version.atLeast(.v4_0)) return;
    switch (mode) {
        .b => {
            // Two calibration piers, then the third with the margin.
            at += 1;
            const third: PierMarginWord = @bitCast(try readWord(source, at));
            if (version.atLeast(.v4_1)) store.rxtx_margin[1] = third.rxtx_margin;
        },
        .g => {
            at += 1;
            at += 1;
            const third: PierMarginWord = @bitCast(try readWord(source, at));
            at += 1;
            if (version.atLeast(.v4_1)) store.rxtx_margin[2] = third.rxtx_margin;
            const iq: IqWord = @bitCast(try readWord(source, at));
            at += 1;
            store.iq_cal_i[1] = iq.iq_cal_i;
            store.iq_cal_q[1] = iq.iq_cal_q;
            if (version.atLeast(.v4_2)) {
                const delta: GainDeltaWord = @bitCast(try readWord(source, at));
                store.cck_ofdm_gain_delta = delta.cck_ofdm_gain_delta;
            }
        },
        .a => {
            if (version.atLeast(.v4_1)) {
                const margin: AMarginWord = @bitCast(try readWord(source, at));
                store.rxtx_margin[0] = margin.rxtx_margin;
            }
        },
    }
}

comptime {
    // The header words against the shifts the reference reads them with.
    if (@as(u16, @bitCast(ModesWord{ .rf_kill = true })) != 0x4000 or
        @as(u16, @bitCast(ModesWord{ .turbo2w_max_power5 = 0x7F })) != 0x07F0 or
        @as(u16, @bitCast(ModesWord{ .device_type = 7 })) != 0x3800 or
        @as(u16, @bitCast(MapWord{ .map = 3 })) != 0xC000 or
        @as(u16, @bitCast(TargetsWord{ .crystal_32khz = true })) != 0x4000)
    {
        @compileError("the store's header words drifted");
    }
    if (@as(u16, @bitCast(SectionWord0{ .switch_settling = 0x7F })) != 0x7F00 or
        @as(u16, @bitCast(SectionWord0{ .txrx_attenuation = 0x3F })) != 0x00FC or
        @as(u16, @bitCast(SectionWord1{ .antenna0_low = 0xF })) != 0xF000 or
        @as(u16, @bitCast(SectionWord1{ .antenna1 = 0x3F })) != 0x0FC0 or
        @as(u16, @bitCast(SectionWord2{ .antenna3 = 0x3F })) != 0xFC00 or
        @as(u16, @bitCast(SectionWord3{ .antenna6 = 0x3F })) != 0x3F00 or
        @as(u16, @bitCast(SectionWord4{ .antenna9 = 0x3F })) != 0x0FC0 or
        @as(u16, @bitCast(SectionWord9{ .xlna_gain = 0xFF })) != 0x1FE0 or
        @as(u16, @bitCast(SectionWord9{ .fixed_bias = true })) != 0x2000 or
        @as(u16, @bitCast(SectionWord10{ .false_detect_backoff = 0x7F })) != 0x1FC0 or
        @as(u16, @bitCast(SectionWord11G{ .cck_ofdm_power_delta = 0xFF })) != 0x07F8 or
        @as(u16, @bitCast(SectionWord11G{ .scaled_ch14_filter_cck_delta = 0x1F })) != 0xF800 or
        @as(u16, @bitCast(SectionWord11A{ .iq_cal_i = 0x3F })) != 0x3F00 or
        @as(u16, @bitCast(PierMarginWord{ .rxtx_margin = 0x3F })) != 0x3F00 or
        @as(u16, @bitCast(IqWord{ .iq_cal_i = 0x3F })) != 0x07E0 or
        @as(u8, @bitCast(Bias24Byte{ .ob = 7 })) != 0x70 or
        @as(u8, @bitCast(BiasAByte{ .ob4 = 7 })) != 0xE0)
    {
        @compileError("the store's section words drifted");
    }
    if (@as(u16, @bitCast(Capabilities{ .max_queues = 0x1F })) != 0x01F0 or
        @as(u16, @bitCast(Capabilities{ .key_cache_entries_log2 = 0xF })) != 0xF000 or
        @as(u16, @bitCast(RfSilent{ .gpio = 7 })) != 0x001C or
        @as(u16, @bitCast(RfSilent{ .polarity = 1 })) != 0x0002)
    {
        @compileError("the store's capability words drifted");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Eight = Chain(8);

test "a chain wraps at its end and nowhere else" {
    try testing.expectEqual(@as(usize, 1), Eight.next(0));
    try testing.expectEqual(@as(usize, 7), Eight.next(6));
    try testing.expectEqual(@as(usize, 0), Eight.next(7));
}

test "descriptors sit one after another, and the last links back to the first" {
    const base: u32 = 0x0020_0000;
    try testing.expectEqual(base, Eight.addressOf(base, 0));
    try testing.expectEqual(base + DESC_BYTES, Eight.addressOf(base, 1));
    try testing.expectEqual(base + 7 * DESC_BYTES, Eight.addressOf(base, 7));

    try testing.expectEqual(base + DESC_BYTES, Eight.linkFor(base, 0));
    try testing.expectEqual(base, Eight.linkFor(base, 7));

    var at: usize = 3;
    for (0..Eight.count) |_| at = Eight.next(at);
    try testing.expectEqual(@as(usize, 3), at);
}

test "a run that would cross the address limit is refused" {
    try testing.expect(Eight.addressable(0x0020_0000));
    try testing.expect(!Eight.addressable(0));
    try testing.expect(!Eight.addressable(0xFFFF_FFF0));
    try testing.expect(Eight.addressable(0xFFFF_FF00));
}

test "an armed receive descriptor belongs to the radio, names its buffer, and claims nothing" {
    var desc: Desc = .{};
    desc.armReceive(0x0030_0000, 0x0020_0020, 2048);

    try testing.expectEqual(@as(u32, 0x0020_0020), desc.link);
    try testing.expectEqual(@as(u32, 0x0030_0000), desc.buffer);
    const control: RxControl1 = @bitCast(desc.body.rx.control1);
    try testing.expectEqual(@as(u12, 2048), control.buffer_length);
    try testing.expect(control.interrupt_request);

    const report = desc.received();
    try testing.expect(!report.status1.done);
    try testing.expectEqual(@as(u12, 0), report.status0.data_length);
}

test "an armed transmit descriptor states the frame with its check bytes and the buffer without them" {
    var desc: Desc = .{};
    // Stale status from whatever went out of this slot last.
    desc.body = .{ .tx = .{ .status0 = 0xFFFF_FFFF, .status1 = 0xFFFF_FFFF } };

    desc.armTransmit(0x0040_0000, 0, .{ .frame_bytes = 100, .series = rates.only(.m1, 4), .power = 30 });

    try testing.expectEqual(@as(u32, 0), desc.link);
    try testing.expectEqual(@as(u32, 0x0040_0000), desc.buffer);

    const control0: TxControl0 = @bitCast(desc.body.tx.control0);
    const control1: TxControl1 = @bitCast(desc.body.tx.control1);
    try testing.expectEqual(@as(u12, 104), control0.frame_length);
    try testing.expectEqual(@as(u12, 100), control1.buffer_length);
    try testing.expectEqual(@as(u6, 30), control0.transmit_power);
    try testing.expect(control0.interrupt_request);
    try testing.expect(!control1.more);

    // Arming clears what the last frame left, so its outcome cannot be
    // read as this one's.
    try testing.expect(!desc.sent().done());
}

test "a transmit descriptor names its key only when it has one, and asks for no answer to a group frame" {
    var plain: Desc = .{};
    plain.armTransmit(0, 0, .{ .frame_bytes = 60, .series = rates.only(.m6, 4), .power = 20 });
    var ctl0: TxControl0 = @bitCast(plain.body.tx.control0);
    var ctl1: TxControl1 = @bitCast(plain.body.tx.control1);
    try testing.expect(!ctl0.destination_index_valid);
    try testing.expectEqual(@as(u7, 0), ctl1.destination_index);
    try testing.expect(!ctl1.no_acknowledgement);

    var ciphered: Desc = .{};
    ciphered.armTransmit(0, 0, .{
        .frame_bytes = 60,
        .series = rates.only(.m6, 1),
        .power = 20,
        .key = 3,
        .acknowledged = false,
        .kind = .beacon,
    });
    ctl0 = @bitCast(ciphered.body.tx.control0);
    ctl1 = @bitCast(ciphered.body.tx.control1);
    try testing.expect(ctl0.destination_index_valid);
    try testing.expectEqual(@as(u7, 3), ctl1.destination_index);
    try testing.expect(ctl1.no_acknowledgement);
    try testing.expectEqual(FrameType.beacon, ctl1.frame_type);

    const ctl2: TxControl2 = @bitCast(ciphered.body.tx.control2);
    const ctl3: TxControl3 = @bitCast(ciphered.body.tx.control3);
    try testing.expectEqual(@as(u4, 1), ctl2.tries0);
    try testing.expectEqual(RateCode.m6, ctl3.rate0);
}

test "a whole retry series lands in the two words that hold it, in order" {
    var series = rates.Series{};
    series.append(.{ .rate = .m54, .tries = 1 }) catch unreachable;
    series.append(.{ .rate = .m24, .tries = 2 }) catch unreachable;
    series.append(.{ .rate = .m1, .tries = 3 }) catch unreachable;

    var desc: Desc = .{};
    desc.armTransmit(0, 0, .{ .frame_bytes = 200, .series = series, .power = 40 });

    const tries: TxControl2 = @bitCast(desc.body.tx.control2);
    const speeds: TxControl3 = @bitCast(desc.body.tx.control3);
    try testing.expectEqual(@as(u4, 1), tries.tries0);
    try testing.expectEqual(@as(u4, 2), tries.tries1);
    try testing.expectEqual(@as(u4, 3), tries.tries2);
    // A step that was never given is a step the hardware must not take.
    try testing.expectEqual(@as(u4, 0), tries.tries3);
    try testing.expectEqual(RateCode.none, speeds.rate3);

    // And each step can be read back by its place, which is how a
    // completed frame says which rate carried it.
    try testing.expectEqual(RateCode.m54, rateOfStep(speeds, 0));
    try testing.expectEqual(RateCode.m24, rateOfStep(speeds, 1));
    try testing.expectEqual(RateCode.m1, rateOfStep(speeds, 2));
    try testing.expectEqual(wifi.Legacy.m24, rateOfStep(speeds, 1).rate().?);
}

test "a finished transmission tells a sent frame from each way of failing" {
    const cases = [_]struct { status0: TxStatus0, want: ?Failure }{
        .{ .status0 = .{ .sent = true }, .want = null },
        .{ .status0 = .{ .fifo_underrun = true }, .want = .underrun },
        .{ .status0 = .{ .excessive_retries = true }, .want = .unanswered },
        .{ .status0 = .{ .filtered = true }, .want = .filtered },
        .{ .status0 = .{}, .want = .refused },
    };
    for (cases) |case| {
        const report = Sent{ .status0 = case.status0, .status1 = .{ .done = true } };
        try testing.expect(report.done());
        try testing.expectEqual(case.want, report.failure());
    }

    // Nothing is known until the hardware says it is finished.
    try testing.expect(!(Sent{ .status0 = .{}, .status1 = .{} }).done());
}

test "a completed reception reports its length, rate and signal, and whether it is worth keeping" {
    var desc: Desc = .{};
    desc.armReceive(0x0030_0000, 0x0020_0020, 2048);
    desc.body.rx.status0 = @bitCast(RxStatus0{ .data_length = 1500, .rate = .m54, .signal = 40 });
    desc.body.rx.status1 = @bitCast(RxStatus1{ .done = true, .received = true });

    const good = desc.received();
    try testing.expect(good.status1.done);
    try testing.expectEqual(@as(u12, 1500), good.status0.data_length);
    try testing.expectEqual(wifi.Legacy.m54, good.status0.rate.rate().?);
    try testing.expectEqual(@as(u8, 40), good.status0.signal);
    try testing.expect(good.status1.intact());

    for ([_]RxStatus1{
        .{ .done = true, .received = true, .check_sequence_error = true },
        .{ .done = true, .received = true, .physical_error = true },
        .{ .done = true, .received = true, .michael_error = true },
        .{ .done = true, .received = true, .decrypt_check_error = true },
        .{ .done = true, .received = false },
    }) |status| {
        try testing.expect(!status.intact());
    }

    // A physical error's code overlays the key index.
    const failed = RxStatus1{ .done = true, .physical_error = true, .key_index_valid = true, .key_index = 0x11 };
    try testing.expectEqual(@as(u8, 0x23), failed.physicalErrorCode());
}

test "one descriptor serves both directions, over the same six words" {
    var desc: Desc = .{};
    desc.body = .{ .tx = .{
        .control0 = @bitCast(TxControl0{ .frame_length = 64, .transmit_power = 20 }),
        .control1 = @bitCast(TxControl1{ .buffer_length = 60 }),
    } };

    const control0: TxControl0 = @bitCast(desc.body.tx.control0);
    try testing.expectEqual(@as(u12, 64), control0.frame_length);
    try testing.expectEqual(@as(u6, 20), control0.transmit_power);
    try testing.expectEqual(desc.body.tx.control0, desc.body.rx.control0);
}

test "rate codes and rates name each other, and short preambles have their own codes" {
    for (wifi.b_rates ++ wifi.g_rates) |rate| {
        try testing.expectEqual(rate, RateCode.of(rate).rate().?);
    }
    try testing.expectEqual(@as(?wifi.Legacy, null), RateCode.none.rate());
    try testing.expectEqual(@as(?wifi.Legacy, null), @as(RateCode, @enumFromInt(0x1F)).rate());
    try testing.expectEqual(RateCode.m11_short, RateCode.m11.short().?);
    try testing.expectEqual(wifi.Legacy.m11, RateCode.m11_short.rate().?);
    try testing.expectEqual(@as(?RateCode, null), RateCode.m1.short());
    try testing.expectEqual(@as(?RateCode, null), RateCode.m54.short());

    try testing.expectEqual(wifi.Legacy.m6, controlRate(.m9));
    try testing.expectEqual(wifi.Legacy.m12, controlRate(.m18));
    try testing.expectEqual(wifi.Legacy.m24, controlRate(.m54));
    try testing.expectEqual(wifi.Legacy.m5_5, controlRate(.m5_5));
}

test "the synthesizer word for channel six is the reference's, in its two halves" {
    const word = synthWord(2437).?;
    try testing.expectEqual(@as(u16, 0x1A51), @as(u16, @bitCast(word)));
    try testing.expectEqual(@as(u8, 0x51), word.low());
    try testing.expectEqual(@as(u7, 0x1A), word.high());
    try testing.expectEqual(@as(?SynthWord, null), synthWord(5180));
}

test "the delta slope coefficients match the reference's arithmetic" {
    const six = deltaSlope(2437);
    try testing.expectEqual(@as(u15, 21514), six.mantissa);
    try testing.expectEqual(@as(u4, 3), six.exponent);
    const one = deltaSlope(2412);
    try testing.expectEqual(@as(u15, 21737), one.mantissa);
    try testing.expectEqual(@as(u4, 3), one.exponent);
    const upper = deltaSlope(5180);
    try testing.expectEqual(@as(u15, 20243), upper.mantissa);
    try testing.expectEqual(@as(u4, 4), upper.exponent);
}

test "a field packed into an analog bank lands reversed, at its bit, in its column" {
    var bank: [30]u32 = @splat(0);
    // The output bias at bit 193 sits at the start of word twenty-four;
    // the driver bias at bit 190 straddles the top of word twenty-three.
    insertBankField(&bank, 5, 3, 193, 0);
    insertBankField(&bank, 3, 3, 190, 0);
    try testing.expectEqual(@as(u32, 5), bank[24]);
    try testing.expectEqual(@as(u32, 0xC0), bank[23]);
    // Packing again replaces rather than accumulates.
    insertBankField(&bank, 0, 3, 193, 0);
    try testing.expectEqual(@as(u32, 0), bank[24]);
    // A column shifts the whole field up a byte.
    insertBankField(&bank, 5, 3, 193, 1);
    try testing.expectEqual(@as(u32, 5 << 8), bank[24]);
}

test "the noise floor is believed only after a window of plausible readings" {
    var floor = NoiseFloor{};
    for ([_]i16{ -90, -92, -91, -93 }) |reading| {
        try testing.expectEqual(NoiseFloor.DEFAULT, floor.add(reading));
    }
    // The fifth fills the window: the median is used from here on.
    try testing.expectEqual(@as(i16, -92), floor.add(-94));
    try testing.expectEqual(@as(i16, -92), floor.current);
    try testing.expectEqual(@as(i16, -93), floor.add(-96));

    // A reading outside the plausible band starts a fresh window.
    var fresh = NoiseFloor{};
    _ = fresh.add(-90);
    _ = fresh.add(-90);
    try testing.expectEqual(NoiseFloor.DEFAULT, fresh.add(0));
    try testing.expect(fresh.settling);
    try testing.expectEqual(@as(u8, NoiseFloor.WINDOW), fresh.left);
}

test "the I/Q correction follows the reference's prescaled division and clamps" {
    const some = iqCorrection(768, 512, -40).?;
    try testing.expectEqual(@as(i6, 8), some.i);
    try testing.expectEqual(@as(i5, 15), some.q);
    // Too little power to measure anything.
    try testing.expectEqual(@as(?IqCorrection, null), iqCorrection(0, 0, 0));
    try testing.expectEqual(@as(?IqCorrection, null), iqCorrection(512, 200, 0));
}

test "a synthetic calibration store reads back, word layouts and all" {
    var image: [StoreAt.end]u16 = @splat(0);
    image[StoreAt.version] = @intFromEnum(StoreVersion.v5_4);
    image[StoreAt.protect] = 0x0001;
    image[HEADER_3_3.modes] = @bitCast(ModesWord{ .b_mode = true, .g_mode = true, .rf_kill = true, .turbo2_disable = true, .turbo5_disable = true, .device_type = 5 });
    image[HEADER_3_3.gains] = @bitCast(GainsWord{ .ghz2 = 6, .ghz5 = -2 });
    image[HEADER_3_3.gains + 1] = @bitCast(MapWord{ .map = 2 });
    image[HEADER_3_3.gains + 2] = @bitCast(TargetsWord{ .crystal_32khz = true });

    // The 11g section, every word.
    var at = HEADER_3_3.sections[2];
    image[at] = @bitCast(SectionWord0{ .switch_settling = 0x28, .txrx_attenuation = 0x12, .antenna0_high = 0b10 });
    at += 1;
    image[at] = @bitCast(SectionWord1{ .antenna0_low = 0b0011, .antenna1 = 0x21, .antenna2 = 0x22 });
    at += 1;
    image[at] = @bitCast(SectionWord2{ .antenna3 = 0x23, .antenna4 = 0x24, .antenna5_high = 0b1010 });
    at += 1;
    image[at] = @bitCast(SectionWord3{ .antenna5_low = 0b01, .antenna6 = 0x26, .antenna7 = 0x27, .antenna8_high = 0b11 });
    at += 1;
    image[at] = @bitCast(SectionWord4{ .antenna8_low = 0b0100, .antenna9 = 0x29, .antenna10 = 0x2A });
    at += 1;
    image[at] = @bitCast(SectionWord5{ .adc_desired_size = -34, .bias = @bitCast(Bias24Byte{ .ob = 5, .db = 3 }) });
    at += 1;
    image[at] = @bitCast(SectionWord6{ .tx_end_to_xlna_on = 0x0E, .threshold62 = 28 });
    at += 1;
    image[at] = @bitCast(SectionWord7{ .tx_end_to_xpa_off = 0x0F, .tx_frame_to_xpa_on = 0x0B });
    at += 1;
    image[at] = @bitCast(SectionWord8{ .pga_desired_size = -10, .noise_floor_threshold = -1 });
    at += 1;
    image[at] = @bitCast(SectionWord9{ .xlna_gain = 0x30, .xgain = 4, .xpd = true, .fixed_bias = true });
    at += 1;
    image[at] = @bitCast(SectionWord10{ .low = @bitCast(Bias2GHzField{ .ob = 4, .db = 2 }), .false_detect_backoff = 6, .gain_i_low = 0b010 });
    at += 1;
    image[at] = @bitCast(SectionWord11G{ .gain_i_high = 0b101, .cck_ofdm_power_delta = 15, .scaled_ch14_filter_cck_delta = 7 });
    at += 1;
    // Two pier words the reader steps over, then the third with the margin.
    at += 2;
    image[at] = @bitCast(PierMarginWord{ .pier = 0, .rxtx_margin = 0x11 });
    at += 1;
    image[at] = @bitCast(IqWord{ .iq_cal_i = 0x2A, .iq_cal_q = 0x0B });
    at += 1;
    image[at] = @bitCast(GainDeltaWord{ .cck_ofdm_gain_delta = 9 });

    // The 11b section: its bias, its noise floor, its margin.
    at = HEADER_3_3.sections[1];
    image[at + 5] = @bitCast(SectionWord5{ .bias = @bitCast(Bias24Byte{ .ob = 6, .db = 1 }) });
    image[at + 8] = @bitCast(SectionWord8{ .noise_floor_threshold = -5 });
    image[at + 10] = @bitCast(SectionWord10{ .low = @bitCast(Bias2GHzField{ .ob = 1, .db = 1 }) });
    image[at + 13] = @bitCast(PierMarginWord{ .rxtx_margin = 0x05 });

    image[StoreAt.capabilities] = @bitCast(Capabilities{ .max_queues = 10, .key_cache_entries_log2 = 7 });
    image[StoreAt.regulatory_domain] = 0x0069;
    image[StoreAt.mac_top] = 0x0011;
    image[StoreAt.mac_top - 1] = 0x2233;
    image[StoreAt.mac_top - 2] = 0x4455;
    image[StoreAt.rf_silent] = @bitCast(RfSilent{ .gpio = 3, .polarity = 1 });
    image[StoreAt.talon] = 1;

    // The vendor's area must xor to all ones; the last word makes it so.
    var sum: u16 = 0;
    for (image[StoreAt.atheros_base..StoreAt.end]) |w| sum ^= w;
    image[StoreAt.end - 1] = sum ^ 0xFFFF;

    const Image = struct {
        words: []const u16,
        pub fn word(self: @This(), offset: u16) ?u16 {
            return if (offset < self.words.len) self.words[offset] else null;
        }
    };
    const store = try readStore(Image{ .words = &image });

    try testing.expectEqual(StoreVersion.v5_4, store.version);
    try testing.expectEqual(@as(u4, 5), store.version.major());
    try testing.expectEqual(@as(u12, 4), store.version.minor());
    try testing.expect(store.b_mode and store.g_mode and !store.a_mode);
    try testing.expect(store.rf_kill and store.turbo2_disable and store.turbo5_disable);
    try testing.expectEqual(@as(u3, 5), store.device_type);
    try testing.expectEqual(@as(i8, 6), store.antenna_gain_2ghz);
    try testing.expectEqual(@as(i8, -2), store.antenna_gain_5ghz);
    try testing.expectEqual(@as(u2, 2), store.map);
    try testing.expect(store.crystal_32khz);

    const g = store.section(.g);
    try testing.expectEqual(@as(u7, 0x28), g.switch_settling);
    try testing.expectEqual(@as(u6, 0x12), g.txrx_attenuation);
    try testing.expectEqualSlices(u6, &[_]u6{ 0x23, 0x21, 0x22, 0x23, 0x24, 0x29, 0x26, 0x27, 0x34, 0x29, 0x2A }, &g.antenna_control);
    try testing.expectEqual(@as(i8, -34), g.adc_desired_size);
    try testing.expectEqual(@as(u8, 0x0E), g.tx_end_to_xlna_on);
    try testing.expectEqual(@as(u8, 28), g.threshold62);
    try testing.expectEqual(@as(u8, 0x0F), g.tx_end_to_xpa_off);
    try testing.expectEqual(@as(u8, 0x0B), g.tx_frame_to_xpa_on);
    try testing.expectEqual(@as(i8, -10), g.pga_desired_size);
    try testing.expectEqual(@as(i16, -1), g.noise_floor_threshold);
    try testing.expectEqual(@as(u8, 0x30), g.xlna_gain);
    try testing.expectEqual(@as(u4, 4), g.xgain);
    try testing.expect(g.xpd);
    try testing.expectEqual(@as(u7, 6), g.false_detect_backoff);
    try testing.expectEqual(@as(u6, 0x2A), g.gain_i);

    try testing.expectEqual(Bias{ .ob = 5, .db = 3 }, store.bias_g);
    try testing.expectEqual(Bias{ .ob = 6, .db = 1 }, store.bias_b);
    try testing.expectEqual(Bias{ .ob = 4, .db = 2 }, store.bias_2ghz[1]);
    try testing.expectEqual(Bias{ .ob = 1, .db = 1 }, store.bias_2ghz[0]);
    try testing.expect(store.fixed_bias_2ghz);
    try testing.expectEqual(@as(u8, 15), store.cck_ofdm_power_delta);
    try testing.expectEqual(@as(u5, 7), store.scaled_ch14_filter_cck_delta);
    try testing.expectEqual(@as(u6, 0x11), store.rxtx_margin[2]);
    try testing.expectEqual(@as(u6, 0x05), store.rxtx_margin[1]);
    try testing.expectEqual(@as(u6, 0x2A), store.iq_cal_i[1]);
    try testing.expectEqual(@as(u5, 0x0B), store.iq_cal_q[1]);
    try testing.expectEqual(@as(u8, 9), store.cck_ofdm_gain_delta);
    try testing.expectEqual(@as(i16, -5), store.section(.b).noise_floor_threshold);

    try testing.expectEqual(@as(u5, 10), store.capabilities.max_queues);
    try testing.expectEqual(@as(u4, 7), store.capabilities.key_cache_entries_log2);
    try testing.expectEqual(@as(u16, 0x69), store.regulatory_domain);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 }, &store.mac);
    try testing.expectEqual(@as(u3, 3), store.rf_silent.gpio);
    try testing.expectEqual(@as(u1, 1), store.rf_silent.polarity);
    try testing.expect(store.talon);

    // A torn store, an old one, and one with no address, each refused.
    image[StoreAt.end - 1] ^= 1;
    try testing.expectError(StoreError.Checksum, readStore(Image{ .words = &image }));
    image[StoreAt.end - 1] ^= 1;
    image[StoreAt.version] = 0x2000;
    try testing.expectError(StoreError.Version, readStore(Image{ .words = &image }));
    image[StoreAt.version] = @intFromEnum(StoreVersion.v5_4);
    image[StoreAt.mac_top] = 0;
    image[StoreAt.mac_top - 1] = 0;
    image[StoreAt.mac_top - 2] = 0;
    try testing.expectError(StoreError.Address, readStore(Image{ .words = &image }));
}

test "the reset's arithmetic: spur channels, the CCK adjustment, what survives a change" {
    // Channel one sits at 2412, twelve past a harmonic of the clock: no
    // spur. Channel five at 2432 is on one: none either. Channel six at
    // 2437 is five past: a spur.
    try testing.expect(!isSpurChannel(2412));
    try testing.expect(!isSpurChannel(2432));
    try testing.expect(isSpurChannel(2437));
    try testing.expect(isSpurChannel(2457));

    const plain = cckAdjust(15, 15, 2437);
    try testing.expectEqual(@as(i6, -15), plain.gain_delta);
    try testing.expectEqual(@as(i6, -3), plain.pcdac_index);
    const fourteen = cckAdjust(15, 15, 2484);
    try testing.expectEqual(@as(i6, -15), fourteen.gain_delta);
    try testing.expectEqual(@as(i6, 0), fourteen.pcdac_index);

    try testing.expect(survivesChannelChange(0x8020));
    try testing.expect(survivesChannelChange(0x8038));
    try testing.expect(survivesChannelChange(0x80D8));
    try testing.expect(!survivesChannelChange(0x803C));
    try testing.expect(!survivesChannelChange(0x8000));

    try testing.expectEqual(@as(u8, 0x84), radioRevision(0x12));
    try testing.expectEqual(@as(u8, 0xA2), radioRevision(0x54));
}

test "the rate-duration table times an acknowledgement at each rate's control rate" {
    try testing.expectEqual(@as(usize, 15), RATE_DURATIONS.len);
    var found_short = false;
    for (RATE_DURATIONS) |entry| {
        switch (entry.code) {
            .m1 => try testing.expectEqual(@as(u16, 314), entry.micros),
            // Two megabits with a short preamble: half the overhead.
            .m2_short => {
                try testing.expectEqual(@as(u16, 96 + 56 + 10), entry.micros);
                found_short = true;
            },
            // Fifty-four megabits answers at twenty-four.
            .m54 => try testing.expectEqual(wifi.Legacy.m24.airtime(CONTROL_FRAME_BYTES, false, true), entry.micros),
            else => {},
        }
    }
    try testing.expect(found_short);
}

test "the amplifier's table is the store's points filled in at every half decibel" {
    // Two channels measured the same, so the interpolation between them is
    // the identity and the arithmetic can be followed by hand. Two gain
    // settings, each a straight line: the detector reads one more for every
    // half decibel.
    var gains = CalChannel{};
    gains.per_gain[3] = .{
        .gain = 3,
        .points = 4,
        .quarter_dbm = .{ 0, 40, 80, 120, 0 },
        .vpd = .{ 0, 20, 40, 60, 0 },
    };
    gains.per_gain[2] = .{
        .gain = 1,
        .points = 4,
        .quarter_dbm = .{ 80, 120, 160, 200, 0 },
        .vpd = .{ 30, 50, 70, 90, 0 },
    };

    var curves = CalCurves{ .channels = 2 };
    curves.megahertz[0] = 2412;
    curves.megahertz[1] = 2462;
    curves.per_channel[0] = gains;
    curves.per_channel[1] = gains;

    const table = powerTable(&curves, 2437, 2).?;

    // Both settings are used, highest gain first, and the floor is the
    // lowest power anything was measured at.
    try testing.expectEqual(@as(u8, 2), table.used);
    try testing.expectEqual(@as(u16, 3), table.gains[0]);
    try testing.expectEqual(@as(u16, 1), table.gains[1]);
    try testing.expectEqual(@as(i16, 0), table.floor_half_dbm);

    // The first setting gives way halfway between where it ends and where
    // the next begins; the last is carried a little past its end.
    try testing.expectEqual(@as(u16, 50), table.boundaries[0]);
    try testing.expectEqual(@as(u16, 104), table.boundaries[1]);
    // A boundary for every setting, the last standing for the rest.
    try testing.expectEqual(@as(u16, 104), table.boundaries[3]);

    // The first setting's own readings, up to its boundary and the overlap.
    try testing.expectEqual(@as(u8, 0), table.pdadc[0]);
    try testing.expectEqual(@as(u8, 51), table.pdadc[51]);
    // Then the second setting takes over, starting where the boundary and
    // the overlap put it rather than at its own first point.
    try testing.expectEqual(@as(u8, 38), table.pdadc[52]);
    try testing.expectEqual(@as(u8, 89), table.pdadc[103]);
    // Past its last measured point the line is carried on at its own slope.
    try testing.expectEqual(@as(u8, 89), table.pdadc[104]);
    try testing.expectEqual(@as(u8, 94), table.pdadc[109]);
    // And the rest of the table holds what the end of it held.
    try testing.expectEqual(@as(u8, 94), table.pdadc[127]);
}

test "a table is refused where there is nothing measured to build one from" {
    var empty = CalCurves{};
    try testing.expectEqual(@as(?PowerTable, null), powerTable(&empty, 2437, 2));

    // A channel with no usable curve is no better than none.
    empty.channels = 1;
    empty.megahertz[0] = 2412;
    try testing.expectEqual(@as(?PowerTable, null), powerTable(&empty, 2412, 2));

    // One point is not a line, so nothing can be read between them.
    var thin = CalCurves{ .channels = 1 };
    thin.megahertz[0] = 2412;
    thin.per_channel[0].per_gain[3] = .{ .gain = 3, .points = 1, .quarter_dbm = .{ 40, 0, 0, 0, 0 }, .vpd = .{ 20, 0, 0, 0, 0 } };
    try testing.expectEqual(@as(?PowerTable, null), powerTable(&thin, 2412, 2));
}

test "the curve is read between the two channels either side of the one wanted" {
    // The same setting measured differently at each end of the band: at the
    // middle the reading is the average of the two.
    var low = CalChannel{};
    low.per_gain[3] = .{ .gain = 3, .points = 2, .quarter_dbm = .{ 0, 120, 0, 0, 0 }, .vpd = .{ 0, 60, 0, 0, 0 } };
    var high = CalChannel{};
    high.per_gain[3] = .{ .gain = 3, .points = 2, .quarter_dbm = .{ 0, 120, 0, 0, 0 }, .vpd = .{ 20, 80, 0, 0, 0 } };

    var curves = CalCurves{ .channels = 2 };
    curves.megahertz[0] = 2400;
    curves.megahertz[1] = 2500;
    curves.per_channel[0] = low;
    curves.per_channel[1] = high;

    // At the low end it is the low channel's own curve.
    const at_low = powerTable(&curves, 2400, 0).?;
    try testing.expectEqual(@as(u8, 0), at_low.pdadc[0]);
    // Halfway, twenty higher at the bottom of the curve is ten higher here.
    const middle = powerTable(&curves, 2450, 0).?;
    try testing.expectEqual(@as(u8, 10), middle.pdadc[0]);
    // At the high end, the high channel's.
    const at_high = powerTable(&curves, 2500, 0).?;
    try testing.expectEqual(@as(u8, 20), at_high.pdadc[0]);
}
