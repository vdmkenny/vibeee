//! The reset and channel-set pipeline, transcribed from the reference's
//! `ar5212Reset` for the AR2425 and AR2417: wake, chip reset, the PLL and
//! mode, the initialisation tables, the board's own values from the
//! calibration store, the analog banks, the synthesizer, the rate
//! durations, the baseband's activation, and the calibrations that
//! follow.
//!
//! Every 2.4 GHz channel is run as 11g. That is the reference's own
//! choice for these parts, which have no separate 11b path: a CCK channel
//! is turned into a dynamic one before the sequence starts.
//!
//! Normal-width map2 11g transmission requires validated amplifier curves,
//! CCK/OFDM targets, CTL edges and a supported EEPROM world-domain channel.

const lib = @import("lib");
const eeprom = @import("eeprom.zig");
const family = @import("family.zig");
const immunity_mod = @import("immunity.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pace = @import("pace.zig");
const power = @import("power.zig");
const regs_mod = @import("regs.zig");
const rf2425 = @import("rf2425.zig");
const std = @import("std");
const tables = @import("tables.zig");

const Regs = regs_mod.Regs;
const mac = lib.mac;

const name = "ar5212";

/// One radio's chip: its registers, what the store said, what it is, and
/// what the pipeline keeps between resets.
pub const Chip = struct {
    regs: Regs,
    store: family.Store,
    /// The amplifier's measured curves, read from the store on the first
    /// channel and kept: they are a walk over the whole calibration
    /// section, and nothing in them changes with the channel.
    curves: ?family.CalCurves = null,
    curves_read: bool = false,
    /// Why there are none, for saying so once.
    curves_why: ?family.NoCurves = null,
    amplifier_ready: bool = false,
    /// Whether the baseband has finished the gain calibration the last reset
    /// started. Separate from the table above because the two are learned at
    /// different moments: the table is written during the reset, and the
    /// calibration finishes whenever the room lets it.
    gain_ready: bool = false,
    power_limits: ?power.Limits = null,
    power_read: bool = false,
    power_ready: bool = false,
    power_mhz: u16 = 0,
    version: regs_mod.MacVersion,
    revision: u4,
    phy_revision: u8,
    radio_revision: u8,
    /// Whether the revision above was read from the analog part or stood
    /// in for. The part reports none while it is unpowered, which is what
    /// a thrown kill switch leaves it, so which of the two it was is the
    /// difference between a radio that is quiet and one that is not there.
    radio_revision_assumed: bool = false,
    part: rf2425.Part,
    mac: mac.Address,
    banks: rf2425.Banks = .{},
    /// The cell the protocol unit filters on and the association it holds;
    /// none until a join.
    bssid: mac.Address = @splat(0),
    association_id: u14 = 0,
    iq: IqState = .inactive,
    /// The correction measured on the current channel, once one has been.
    iq_measured: ?family.IqCorrection = null,
    noise: family.NoiseFloor = .{},
    /// How much noise the baseband is asked to ignore. Kept with the chip
    /// because a reset puts the registers it lives in back to what the
    /// tables say, so what was learned has to be applied again.
    immunity: immunity_mod.State = .{},
    /// The ceiling, in half decibels, on the frames the unit sends itself:
    /// acknowledgements and the like. The regulatory plan sets it.
    self_power: u6 = MAX_RATE_POWER,
    /// What to add to a power before it goes in a descriptor, so the
    /// figure lands where the amplifier's table expects to be indexed.
    power_offset: i16 = 0,
    /// Whether the baseband is powered, which decides whether its
    /// registers may be touched.
    phy_powered: bool = false,

    pub fn isPcie(self: *const Chip) bool {
        return self.version.isPcie();
    }

    pub fn txPermitted(self: *const Chip) bool {
        return self.amplifier_ready and self.power_ready and self.gain_ready;
    }
};

pub const IqState = enum { inactive, running, done };

/// Why a reset is happening. A channel change keeps the protocol unit's
/// timers and sequence number; a power-on reset starts everything over.
pub const Kind = enum { power_on, channel_change };

pub const ResetError = error{
    /// The chip did not wake.
    Asleep,
    ChipReset,
    /// The synthesizer refused the frequency.
    Synth,
    RadioPolicy,
};

/// The reference's constants.
const MAX_RATE_POWER: u6 = 63;
/// How long a reset waits for the baseband's gain calibration. A quiet room
/// finishes inside this; a loud one is left to the periodic calibration.
const GAIN_MICROS: u32 = 5_000;

const PLL_SETTLE_MICROS = 300;
const BASE_ACTIVATE_MICROS = 100;
const POWER_UP_MICROS = 2000;
const IQ_CAL_LOG_COUNT_MAX: u4 = 0xF;
const IQ_CAL_TRIES = 10;
const MAC_STOP_TRIES = 10;
/// The false-detect backoff every board gets, before the store's own.
const NO_FALSE_DETECT_BACKOFF: u7 = 2;
/// The reference's own literals for the QoS control registers, which it
/// marks as magic.
const QOS_CONTROL_VALUE: u32 = 0x100AA;
const QOS_SELECT_VALUE: u32 = 0x3210;

// ---------------------------------------------------------------------------
// Power
// ---------------------------------------------------------------------------

/// Ask the chip to stay awake and wait for it to report that it is.
///
/// A powered-down chip answers every read with all ones; written back,
/// that word enables the sleep performance counters' interrupt, which
/// nobody clears. So an implausible word is replaced rather than kept.
pub fn wake(regs: Regs) bool {
    var control = regs.get(.sleep_control, regs_mod.SleepControl);
    if (!control.plausible()) control = .{};
    control.enable = .wake;
    regs.put(.sleep_control, control);
    pace.delay(10);

    var waited: u32 = 0;
    var awake = false;
    while (waited < POWER_UP_MICROS / 50) : (waited += 1) {
        if (!regs.get(.pci_config, regs_mod.PciConfig).powered_down) {
            awake = true;
            break;
        }
        pace.delay(50);
        regs.put(.sleep_control, control);
    }
    if (!awake) return false;

    regs.set(.station_id_high, regs_mod.StationIdHigh, "power_save", false);
    return true;
}

/// Let the chip sleep, for a stop.
pub fn sleep(regs: Regs) void {
    regs.set(.station_id_high, regs_mod.StationIdHigh, "power_save", true);
    regs.set(.sleep_control, regs_mod.SleepControl, "enable", .sleep);
}

/// The PCI Express serialiser's settings for a part attached by it, as
/// the reference loads them at attach: the receiver off when the link
/// idles, the PLL and clock request off in the L1 state. Each is a word
/// the reference gives with no field names, so none are spelled here.
const PCIE_SERDES_SETTINGS = [_]u32{
    0x9248FC00, 0x24924924,
    0x28000039, 0x53160824,
    0xE5980579, 0x001DEFFF,
    0x1AAABE40, 0xBE105554,
    0x000E3007,
};

pub fn configurePcie(regs: Regs) void {
    for (PCIE_SERDES_SETTINGS) |setting| regs.write(.pcie_serdes, setting);
    regs.write(.pcie_serdes_load, 0);
}

// ---------------------------------------------------------------------------
// Reset
// ---------------------------------------------------------------------------

/// Stop the receive and transmit engines and wait for them to say so.
fn macStop(regs: Regs) bool {
    regs.set(.control, regs_mod.Control, "rx_disable", true);
    regs.holdQueues(regs_mod.QueueMask.all.queues);
    // However this leaves, the queues are let go of: one still held is one
    // that cannot be enabled again, and nothing would ever be sent.
    defer regs.releaseQueues();

    var rx_running = true;
    var tx_running = true;
    var frames_pending = false;
    var tries: u32 = 0;
    while (tries < MAC_STOP_TRIES) : (tries += 1) {
        if (rx_running and !regs.get(.control, regs_mod.Control).rx_enable) rx_running = false;
        if (tx_running and regs.get(.queue_enable, regs_mod.QueueMask).queues == 0) {
            tx_running = false;
            frames_pending = true;
        }
        if (frames_pending) {
            var pending: u32 = 0;
            for (0..regs_mod.QUEUES) |queue| {
                const status: regs_mod.QueueStatus = @bitCast(regs.readAt(regs_mod.queueStatus(@intCast(queue))));
                pending += status.pending_frames;
            }
            if (pending == 0) frames_pending = false;
        }
        if (!rx_running and !tx_running and !frames_pending) return true;
        pace.delay(50);
    }
    return false;
}

/// Write the reset word and wait for the engines to follow it.
fn setResetReg(chip: *Chip, wanted: regs_mod.ResetControl) bool {
    const regs = chip.regs;
    var mask = wanted;
    // Never the bus block on a card attached by PCI Express.
    if (chip.isPcie()) mask.pci = false;

    if (mask.mac or mask.pci) {
        if (!wake(regs)) return false;
        regs.put(.interrupt_enable, regs_mod.InterruptEnable{});
        regs.flush(.interrupt_enable);

        if (!macStop(regs)) {
            // Not stopped gracefully; be more forceful.
            pace.delay(15);
            regs.flush(.rx_pointer);
            mask.mac = true;
            mask.baseband = true;
            if (!chip.isPcie()) mask.pci = true;
        } else {
            mask.pci = false;
            pace.delay(15);
            regs.flush(.rx_pointer);
        }
    }

    regs.flush(.rx_pointer);
    regs.put(.reset_control, mask);
    // At least 128 clocks before a read when resetting the bus.
    pace.delay(15);

    const Settled = struct {
        regs: Regs,
        mask: regs_mod.ResetControl,

        fn ready(self: @This()) bool {
            const now = self.regs.get(.reset_control, regs_mod.ResetControl);
            return now.mac == self.mask.mac and now.baseband == self.mask.baseband;
        }
    };
    const settled = pace.looking(
        Settled{ .regs = regs, .mask = mask },
        Settled.ready,
        pace.DEFAULT_MICROS,
    );

    if (!mask.mac) {
        // Descriptors are read as the host writes them: no swapping.
        regs.put(.config, regs_mod.Config{});
        if (wake(regs)) regs.flush(.interrupt_status_clearing);
    }
    chip.phy_powered = !mask.baseband;
    return settled;
}

/// Put the chip through reset and out again, and set the PLL and the mode
/// for the channel, in the order the reference requires: the PLL may only
/// be set to 44 MHz with CCK or dynamic mode set, and turbo may not be set
/// with either.
pub fn chipReset(chip: *Chip, megahertz: ?u16) bool {
    const regs = chip.regs;
    if (!setResetReg(chip, .{ .mac = true, .baseband = true, .pci = true })) return false;
    if (!wake(regs)) return false;
    if (!setResetReg(chip, .{})) return false;

    if (megahertz == null) return true;

    // The 11g mode of a 2.4 GHz channel on this radio: both modulations,
    // told apart per frame, at the 44 MHz clock the band runs at. Forty is
    // the five gigahertz figure, and a baseband given it here is a tenth
    // out on every symbol and chip boundary: both demodulators start on
    // what they hear and both give up on the timing.
    const mode = regs_mod.PhyMode{ .radio_5112 = true, .rf_2ghz = true, .dynamic = true };
    const pll: regs_mod.PhyPll = .mhz44_5112;
    const current: regs_mod.PhyPll = @enumFromInt(regs.read(.phy_pll_control));

    // The clock first, then turbo, then the mode.
    //
    // The reference gives two orders and takes the other one for a channel
    // carrying CCK, which by its own macro a dynamic channel does: turbo,
    // mode, clock. That order is what the constraints it states are for,
    // turbo not being set beside CCK and the clock only moving to
    // forty-four megahertz while CCK or dynamic is set, and both orders
    // end at the same three register values.
    //
    // This part does not agree. Given the mode while the synthesiser is
    // still on whatever the chip reset left, and the clock moved
    // underneath it afterwards, its baseband keeps the timing it latched:
    // every OFDM frame it starts on fails on timing, its CCK demodulator
    // records neither a success nor a failure, and the radio hears nothing
    // at all. Clock first, and it hears the room.
    if (current != pll) {
        regs.write(.phy_pll_control, @intFromEnum(pll));
        pace.delay(PLL_SETTLE_MICROS);
    }
    regs.put(.phy_turbo, regs_mod.PhyTurbo{});
    regs.put(.phy_mode, mode);

    // Read back, because everything downstream is timed by this and
    // nothing else says it went wrong. A baseband clocked for the five
    // gigahertz band while listening to this one is a tenth out on every
    // symbol and chip boundary: both demodulators start on what they hear
    // and both give up on the timing, which reads as a radio in a silent
    // room. Set again if the mode write moved it, and said plainly if it
    // will not hold.
    const settled: regs_mod.PhyPll = @enumFromInt(regs.read(.phy_pll_control));
    if (settled != pll) {
        regs.write(.phy_pll_control, @intFromEnum(pll));
        pace.delay(PLL_SETTLE_MICROS);
        const again: regs_mod.PhyPll = @enumFromInt(regs.read(.phy_pll_control));
        if (again != pll) {
            sayClock(again);
            return false;
        }
    }
    return true;
}

/// The family's common table, written whole on a power-on reset and
/// without its timer and sleep registers on a channel change, which keeps
/// the beacon timers and the sleep state across the change.
fn writeCommon(regs: Regs, kind: Kind) void {
    for (tables.family.common) |row| {
        if (kind == .channel_change and family.survivesChannelChange(row.register)) continue;
        regs.writeAt(row.register, row.value);
    }
}

/// The OFDM timing coefficients for the carrier.
fn setDeltaSlope(regs: Regs, megahertz: u16) void {
    const slope = family.deltaSlope(megahertz);
    var timing = regs.get(.phy_timing3, regs_mod.PhyTiming3);
    timing.delta_slope_mantissa = slope.mantissa;
    timing.delta_slope_exponent = slope.exponent;
    regs.put(.phy_timing3, timing);
}

/// Called with DMA stopped and automatic responses inhibited. Per-rate power
/// (HAL's default, descriptor TPC off) covers every retry's actual modulation.
fn applyPower(chip: *Chip) void {
    const regs = chip.regs;
    chip.power_ready = false;
    regs.set(.diagnostics, regs_mod.Diagnostics, "ack_disable", true);
    regs.set(.diagnostics, regs_mod.Diagnostics, "cts_disable", true);
    if (!chip.amplifier_ready) return;
    if (!chip.power_read) {
        chip.power_read = true;
        chip.power_limits = power.read(eeprom.Port{ .regs = regs }, &chip.store) catch |err| {
            log.begin(name, .bad);
            out.text("the store does not say how much power this board may transmit at: ");
            out.text(reasonFor(err));
            out.text(". Nothing will be transmitted, because a radio that does not know its own limit cannot be held to one");
            log.end();
            return;
        };
    }
    const limits = if (chip.power_limits) |*p| p else return;
    const rates = power.rates(limits, &chip.store, chip.power_mhz, chip.self_power, chip.power_offset) catch |err| {
        log.begin(name, .warn);
        out.text("no power is approved for ");
        out.decimal(chip.power_mhz);
        out.text(" MHz: ");
        out.text(reasonFor(err));
        out.text(". Nothing will be transmitted here");
        log.end();
        return;
    };
    const words = rates.words();
    const registers = [_]regs_mod.R{ .phy_power_tx_rate1, .phy_power_tx_rate2, .phy_power_tx_rate3, .phy_power_tx_rate4 };
    for (registers, words) |register, value| regs.write(register, value);
    regs.put(.phy_power_tx_rate_max, regs_mod.RateMaxPower{
        .power = MAX_RATE_POWER,
        .from_descriptor = false,
    });
    const self = regs_mod.SelfPower{ .ack = rates.self_index, .cts = rates.self_index, .chirp = rates.self_index };
    regs.put(.self_power, self);
    for (registers, words) |register, value| {
        if (regs.read(register) != value) {
            log.fail(name, "the per-rate power registers did not take what they were given; nothing will be transmitted");
            return;
        }
    }
    if (regs.read(.self_power) != @as(u32, @bitCast(self)) or
        regs.read(.phy_power_tx_rate_max) != MAX_RATE_POWER)
    {
        log.fail(name, "the power for the frames the radio sends itself did not take; nothing will be transmitted");
        return;
    }
    chip.power_ready = true;

    // The indices are counted from the lowest power the board was
    // measured at, so the offset comes back off them to say what they are
    // in decibel-milliwatts, which is the figure a person set and a
    // regulator cares about.
    var highest: u6 = 0;
    for (rates.indices) |index| highest = @max(highest, index);

    // Only when it changes. A channel change happens five times a second
    // while the radio sweeps, and a line per change is not a report but a
    // flood: it pushes the boot, and anything else worth reading, out of
    // the log ring before anybody can look at it.
    if (said_power) |before| {
        if (before.highest == highest and before.self == rates.self_index) return;
    }
    said_power = .{ .highest = highest, .self = rates.self_index };

    log.begin(name, .dim);
    out.text("on ");
    out.decimal(chip.power_mhz);
    out.text(" MHz nothing goes out above ");
    sayDbm(highest, chip.power_offset);
    out.text(", and what the radio answers with goes out at ");
    sayDbm(rates.self_index, chip.power_offset);
    log.end();
}

/// What the last such line said, so the same thing is not said again.
var said_power: ?struct { highest: u6, self: u6 } = null;

/// What clock the baseband is running on, when it is not the one the band
/// needs. Said once: a radio that cannot be clocked for the band it is in
/// hears nothing, and nothing else in the log would say why.
var said_clock = false;

fn sayClock(got: regs_mod.PhyPll) void {
    if (said_clock) return;
    said_clock = true;
    log.begin(name, .bad);
    out.text("the baseband will not take the 44 MHz clock this band runs at; it reads 0x");
    out.hex(@intFromEnum(got), 8);
    out.text(", and at any other figure both demodulators give up on the timing of every frame");
    log.end();
}

/// A power index as decibel-milliwatts, to the half.
fn sayDbm(index: u6, offset: i16) void {
    const half = @as(i16, index) - offset;
    out.signed(@intCast(@divTrunc(half, 2)));
    if (@rem(half, 2) != 0) out.text(".5");
    out.text(" dBm");
}

/// Why the board's power limits could not be worked out, in words rather
/// than in the name of an error value.
fn reasonFor(why: power.Error) []const u8 {
    return switch (why) {
        error.Unsupported => "the store is of a kind or a regulatory domain this build has not been checked against",
        error.Invalid => "its conformance tables do not hold together",
        error.Unreadable => "a word of it did not come back",
        error.Channel => "the channel is not one the domain allows",
        error.BelowCalibration => "the limit is below the lowest power the board was measured at",
    };
}

/// Why the curves could not be read, in words rather than in the name of
/// an error value. Read off a machine's log by whoever has the machine.
fn whyNoCurves(why: ?family.NoCurves) []const u8 {
    const named = why orelse return "for a reason this build has no name for";
    return switch (named) {
        error.Uncalibrated => "it was never calibrated for this band",
        error.Layout => "it is of a version or a layout this build does not read",
        error.Misplaced => "this band's dataset is not where the ones before it end",
        error.Unreadable => "a word of it did not come back, or it reaches past what its own checksum covered",
        error.Disordered => "its channels or its powers do not climb, which is not a curve",
    };
}

/// Program the amplifier's table for this channel: what reading the
/// detector should give at each half decibel, and where one gain setting
/// gives way to the next.
///
/// Without it the amplifier runs on whatever the reset left, and a frame
/// goes out at a power nothing chose. The curves are measured per board
/// at a handful of channels; the table for the one in use is drawn
/// between the two nearest.
fn setAmplifier(chip: *Chip, megahertz: u16) void {
    const regs = chip.regs;
    chip.amplifier_ready = false;
    chip.power_offset = 0;

    if (!chip.curves_read) {
        chip.curves = eeprom.curves(regs, &chip.store, .g) catch |why| blk: {
            chip.curves_why = why;
            break :blk null;
        };
        chip.curves_read = true;
    }
    const curves = if (chip.curves) |*c| c else {
        if (!said_amplifier) {
            said_amplifier = true;
            log.begin(name, .bad);
            out.text("the store's amplifier curves cannot be read: ");
            out.text(whyNoCurves(chip.curves_why));
            out.text(". Nothing will be transmitted, because a radio that cannot set its own power cannot be held to a limit");
            log.end();
        }
        return;
    };

    // How far the baseband is told the gain settings overlap is its own
    // setting, and the table has to be drawn to match it.
    const boundaries = regs.get(.phy_power_boundaries, regs_mod.PowerBoundaries);
    const table = family.powerTable(curves, megahertz, boundaries.overlap) orelse {
        log.fail(name, "the store's amplifier curves do not make a table; nothing will be transmitted");
        return;
    };
    for (table.boundaries) |boundary| {
        if (boundary > std.math.maxInt(u6)) {
            log.fail(name, "the store's amplifier curves reach past what the hardware's own fields hold; nothing will be transmitted");
            return;
        }
    }

    regs.set(.phy_power_gains, regs_mod.PowerGains, "gains_less_one", @as(u2, @intCast(table.used - 1)));

    // Four readings to a word, in the order the baseband reads them.
    var word: usize = 0;
    while (word * 4 < family.PowerTable.ENTRIES) : (word += 1) {
        const at = word * 4;
        regs.writeAt(@intFromEnum(regs_mod.R.phy_power_table) + word * 4, @as(u32, table.pdadc[at]) |
            (@as(u32, table.pdadc[at + 1]) << 8) |
            (@as(u32, table.pdadc[at + 2]) << 16) |
            (@as(u32, table.pdadc[at + 3]) << 24));
    }

    const programmed = regs_mod.PowerBoundaries{
        .overlap = boundaries.overlap,
        .first = @intCast(table.boundaries[0]),
        .second = @intCast(table.boundaries[1]),
        .third = @intCast(table.boundaries[2]),
        .fourth = @intCast(table.boundaries[3]),
    };
    regs.put(.phy_power_boundaries, programmed);
    if (regs.read(.phy_power_boundaries) != @as(u32, @bitCast(programmed)) or
        regs.get(.phy_power_gains, regs_mod.PowerGains).gains_less_one != table.used - 1)
    {
        log.fail(name, "the amplifier's registers did not take what they were given; nothing will be transmitted");
        return;
    }

    // A power in a descriptor is an index into the table that was just
    // written, counted from the lowest power the curves were measured at.
    // Kept beside the ceiling rather than folded into it: the ceiling is
    // what the regulatory plan allows and is nobody else's to move.
    chip.power_offset = -table.floor_half_dbm;
    chip.amplifier_ready = true;

    // Said once. It is the same table on every channel of a band, and what
    // is worth knowing is that the amplifier is running on measured
    // figures rather than on whatever the reset left.
    if (!said_amplifier) {
        said_amplifier = true;
        log.begin(name, .key);
        out.text("amplifier: ");
        out.decimal(table.used);
        out.text(" gain settings measured over ");
        out.decimal(curves.channels);
        out.text(" channels, from ");
        out.signed(@divTrunc(table.floor_half_dbm, 2));
        out.text(" dBm");
        log.end();
    }
}

/// Said once, because it is the same answer on every channel.
var said_amplifier = false;

fn setBoardValues(chip: *Chip, megahertz: u16) void {
    const regs = chip.regs;
    const store = &chip.store;
    const section = store.section(.g);
    const band_2ghz = 1;
    const section_b = store.section(.b);

    var antenna = regs.get(.phy_antenna_control, regs_mod.PhyAntennaControl);
    antenna.enable = true;
    antenna._3 = 0;
    antenna.antenna_control = section.antenna_control[0];
    regs.put(.phy_antenna_control, antenna);

    // Both switch banks, from the section's controls; this radio uses the
    // 11g row for its 11b channels too. Fast diversity is on when the two
    // banks differ.
    const control = section.antenna_control;
    const switch_a = regs_mod.PhyAntennaSwitch{ .s1 = control[1], .s2 = control[2], .s3 = control[3], .s4 = control[4], .s5 = control[5] };
    const switch_b = regs_mod.PhyAntennaSwitch{ .s1 = control[6], .s2 = control[7], .s3 = control[8], .s4 = control[9], .s5 = control[10] };
    const same = @as(u32, @bitCast(switch_a)) == @as(u32, @bitCast(switch_b));
    regs.set(.phy_cck_detect, regs_mod.PhyCckDetect, "fast_diversity", !same);
    regs.put(.phy_antenna_switch_a, switch_a);
    regs.put(.phy_antenna_switch_b, switch_b);

    regs.put(.phy_noise_floor_threshold, regs_mod.PhyNoiseFloorThreshold{
        .threshold = @truncate(section.noise_floor_threshold),
        .enable = true,
    });

    regs.set(.phy_settling, regs_mod.PhySettling, "switch_settling", section.switch_settling);
    regs.set(.phy_desired_size, regs_mod.PhyDesiredSize, "adc", section.adc_desired_size);
    regs.set(.phy_desired_size, regs_mod.PhyDesiredSize, "pga", section_b.pga_desired_size);
    regs.set(.phy_rx_gain, regs_mod.PhyRxGain, "txrx_attenuation", section_b.txrx_attenuation);
    regs.put(.phy_tx_xpa, regs_mod.PhyXpa{
        .frame_to_xpa_on_a = section.tx_frame_to_xpa_on,
        .frame_to_xpa_on_b = section.tx_frame_to_xpa_on,
        .end_to_xpa_off_a = section.tx_end_to_xpa_off,
        .end_to_xpa_off_b = section.tx_end_to_xpa_off,
    });
    regs.set(.phy_tx_xlna, regs_mod.PhyXlna, "end_to_xlna_on", section.tx_end_to_xlna_on);
    regs.set(.phy_cca, regs_mod.PhyCca, "threshold62", @as(u7, @truncate(section.threshold62)));

    // A suspected clock spur causes false OFDM detects; back the weak
    // signal sensitivity off on the channels near it.
    var backoff: u8 = NO_FALSE_DETECT_BACKOFF;
    if (store.version.atLeast(.v3_3) and family.isSpurChannel(megahertz)) backoff += section.false_detect_backoff;
    regs.set(.phy_timing5, regs_mod.PhyTiming5, "cycle_power_threshold1", @as(u7, @truncate(backoff)));

    // The I/Q correction: what was measured on this channel, else what
    // the store says.
    const correction: family.IqCorrection = chip.iq_measured orelse .{
        .i = @bitCast(store.iq_cal_i[band_2ghz]),
        .q = @bitCast(store.iq_cal_q[band_2ghz]),
    };
    var timing4 = regs.get(.phy_timing_control4, regs_mod.PhyTimingControl4);
    timing4.iq_correction_i = correction.i;
    timing4.iq_correction_q = correction.q;
    timing4.iq_correction_enable = true;
    regs.put(.phy_timing_control4, timing4);

    if (store.version.atLeast(.v4_1)) {
        regs.set(.phy_gain_2ghz, regs_mod.PhyGain2GHz, "rxtx_margin", store.rxtx_margin[band_2ghz]);
    }
    if (store.version.atLeast(.v5_1)) regs.write(.phy_heavy_clip, 0);
}

/// The time an answer at each rate takes, which the protocol unit uses
/// for multi-rate retry.
fn setRateDurations(regs: Regs) void {
    for (family.RATE_DURATIONS) |entry| {
        regs.writeAt(regs_mod.rateDuration(entry.code), entry.micros);
    }
}

/// Count the values the radio did not keep, per table, and name the first
/// each table dropped.
///
/// Every comparison against the reference says what the radio is written;
/// none of them says what it holds afterwards. Which table lost them is
/// most of the answer, and what one of them holds instead is the rest: a
/// register reading zero was never written, and one reading something
/// else entirely is a register that does not answer with what it was
/// given, which several of these do not.
fn sayUnkeptWrites(regs: Regs, mode: tables.Mode, band: tables.Band) void {
    var modes = Tally{ .what = "modes" };
    var common = Tally{ .what = "common" };
    var gain = Tally{ .what = "gain" };

    for (tables.rf2425.modes) |row| modes.note(regs, row.register, row.value(mode));
    for (tables.rf2425.common) |row| common.note(regs, row.register, row.value);
    for (tables.rf2425.gain) |row| gain.note(regs, row.register, row.value(band));

    for ([_]Tally{ modes, common, gain }) |tally| tally.say();
}

const Mismatch = struct { register: u16, wanted: u32, holds: u32 };

/// One table's account of itself.
const Tally = struct {
    what: []const u8,
    held: usize = 0,
    looked: usize = 0,
    /// How many read back as nothing at all. A whole table of these is a
    /// range that does not answer reads rather than one that did not take
    /// the writes, and the two look identical one register at a time.
    silent: usize = 0,
    first: ?Mismatch = null,

    /// Read one back and count it, keeping the first that differed.
    fn note(self: *Tally, regs: Regs, register: u16, wanted: u32) void {
        self.looked += 1;
        const holds = regs.readAt(register);
        if (holds == 0) self.silent += 1;
        if (holds == wanted) {
            self.held += 1;
            return;
        }
        if (self.first == null) self.first = .{ .register = register, .wanted = wanted, .holds = holds };
    }

    /// A table that kept most of what it was given is a line nobody needs
    /// to read; one that did not is the whole question. A table that
    /// answers every read with nothing is neither: it is a range that does
    /// not answer reads, which several of these are by design, and saying
    /// it kept none of them would be reporting the instrument rather than
    /// the radio.
    fn say(self: Tally) void {
        if (self.silent == self.looked) {
            log.begin(name, .dim);
            out.text("the radio's ");
            out.text(self.what);
            out.text(" cannot be read back, so what it made of them is not knowable from here");
            log.end();
            return;
        }

        const most = self.held * 4 >= self.looked * 3;
        log.begin(name, if (most) .dim else .warn);
        out.text("the radio kept ");
        out.decimal(self.held);
        out.text(" of ");
        out.decimal(self.looked);
        out.text(" ");
        out.text(self.what);
        if (self.silent > 0) {
            out.text(", ");
            out.decimal(self.silent);
            out.text(" reading as nothing");
        }
        if (self.first) |bad| {
            out.text("; 0x");
            out.hex(bad.register, 4);
            out.text(" was given 0x");
            out.hex(bad.wanted, 8);
            out.text(" and holds 0x");
            out.hex(bad.holds, 8);
        }
        log.end();
    }
};

/// Activate the baseband and wait for it: the synthesizer's own settling
/// time, then the reference's check that the baseband is ready, since the
/// delay alone is not reliable on notebooks.
fn activatePhy(regs: Regs) void {
    // The delay register counts hundreds of nanoseconds; an 11g channel
    // divides by ten.
    const delay = regs.get(.phy_rx_delay, regs_mod.PhyRxDelay).delay / 10;
    regs.put(.phy_active, regs_mod.PhyActive{ .enable = true });
    pace.delay(delay + BASE_ACTIVATE_MICROS);

    const test_control = regs.read(.phy_test_control);
    regs.put(.phy_test_control, regs_mod.PhyTestControl.hold_tx);
    var looked: u32 = 0;
    while (looked < 20 and regs.get(.phy_baseband_ready, regs_mod.PhyBasebandReady).busy) : (looked += 1) {
        pace.delay(200);
    }
    regs.write(.phy_test_control, test_control);
}

/// The clocks a station keeps: no 32 kHz crystal in use, so the reference
/// clock runs the sleep logic.
fn setupClock(chip: *Chip) void {
    const regs = chip.regs;
    regs.set(.pci_config, regs_mod.PciConfig, "sleep_clock_rate", 0);
    regs.set(.pci_config, regs_mod.PciConfig, "sleep_clock_select", 0);
    regs.write(.tsf_parameters, 1);
    regs.write(.phy_sleep_counter_control, 0x1F);
    regs.write(.phy_sleep_counter_limit, 0x7F);
    regs.write(.phy_sleep_scale, switch (chip.part) {
        .ar2417 => 0x0A,
        .ar2425 => if (chip.store.talon) 0x32 else 0x0E,
    });
    regs.write(.phy_m_sleep, 0x0C);
    regs.write(.phy_refclk_delay, 0xFF);
    regs.write(.phy_refclk_powerdown, switch (chip.part) {
        .ar2417 => 0x14,
        .ar2425 => 0x18,
    });
    regs.set(.usec, regs_mod.Usec, "usec32", 31);
}

/// Whether the kill switch is silencing the radio at this moment.
///
/// The store names the pin and which of its two levels means silence.
/// Worth asking rather than assuming: a silenced radio hears nothing and
/// says nothing, which is what a radio somewhere very quiet also does,
/// and the two are otherwise indistinguishable from outside.
///
/// Answers false where the store names no switch, which is a radio
/// nothing can silence rather than one that is not silenced now.
pub fn killed(chip: *const Chip) bool {
    if (!chip.store.rf_kill) return false;
    const pin: u1 = @intFromBool(chip.regs.get(.gpio_in, regs_mod.GpioData).pin(chip.store.rf_silent.gpio));
    return pin == chip.store.rf_silent.polarity;
}

/// Read the pin the store names as the kill switch, and leave the
/// baseband alone.
///
/// The baseband has an input that silences it, and the board wires a pin
/// to it. Connecting the two is what the vendor's own driver does, and it
/// is left unconnected here: the pin sits in whichever state the board
/// leaves it, nothing on this system drives it, and a baseband wired to a
/// line nobody drives is a radio that may be silenced for its whole life
/// with every register reading correct. This machine's other operating
/// system has to be told to enable the card before it hears anything,
/// which is what a line resting in the silencing state looks like from
/// the far side.
///
/// What this system switches the radio by is the firmware's own method,
/// through `hw wireless`, which cuts its power rather than muting its
/// baseband. The pin is still configured as an input, because reading it
/// is how the radio reports what the switch is doing.
fn watchRfKill(chip: *Chip) void {
    const regs = chip.regs;
    var control = regs.get(.gpio_control, regs_mod.GpioControl);
    control.setPin(chip.store.rf_silent.gpio, .input);
    regs.put(.gpio_control, control);
    regs.set(.phy_test, regs_mod.PhyTest, "rf_silence", false);
}

/// The whole sequence. On a channel change the sequence number, the
/// timers and the sleep state survive; on a power-on reset nothing does.
pub fn reset(chip: *Chip, megahertz: u16, kind: Kind) ResetError!void {
    const regs = chip.regs;
    chip.amplifier_ready = false;
    chip.gain_ready = false;
    chip.power_ready = false;
    chip.power_mhz = megahertz;
    if (!wake(regs)) return ResetError.Asleep;

    // What a reset clears and the reference puts back afterwards.
    const saved_sequence = if (kind == .channel_change) regs.read(.sequence_number) else 0;
    var saved_antenna = regs.read(.default_antenna);
    if (saved_antenna == 0) saved_antenna = 1;
    const saved_station = regs.get(.station_id_high, regs_mod.StationIdHigh);
    const saved_pci = regs.get(.pci_config, regs_mod.PciConfig);
    const saved_gpio_control = regs.read(.gpio_control);
    const saved_gpio_out = regs.read(.gpio_out);

    if (!chipReset(chip, megahertz)) return ResetError.ChipReset;

    // Every 2.4 GHz channel is 11g on this radio.
    const mode: tables.Mode = .g;
    const band: tables.Band = .ghz2;

    // The baseband-to-analog shift that gives access to the radio.
    regs.put(.phy_test, regs_mod.PhyTest.analog_access);
    for (tables.family.modes) |row| regs.writeAt(row.register, row.value(mode));
    writeCommon(regs, kind);
    // Software CCMP must receive the original IV/ciphertext/MIC. Zero keys
    // alone select WEP40, not clear; use HAL ResetKeyCacheEntry's CLR type
    // and invalid MAC, plus the explicit decrypt/encrypt bypass bits.
    regs.set(.diagnostics, regs_mod.Diagnostics, "decrypt_disable", true);
    regs.set(.diagnostics, regs_mod.Diagnostics, "encrypt_disable", true);
    regs.set(.diagnostics, regs_mod.Diagnostics, "ack_disable", true);
    regs.set(.diagnostics, regs_mod.Diagnostics, "cts_disable", true);
    const key_log2 = chip.store.capabilities.key_cache_entries_log2;
    const key_entries: usize = if (key_log2 == 0) 128 else @min(@as(usize, 1) << key_log2, 128);
    for (0..key_entries) |entry| {
        const base = @intFromEnum(regs_mod.R.key_table_0) + entry * 32;
        for (0..8) |word| regs.writeAt(base + word * 4, if (word == 5) 7 else 0);
        if (regs.readAt(base + 20) != 7 or regs.readAt(base + 28) != 0) return ResetError.RadioPolicy;
    }
    rf2425.writeRegs(regs, mode, band);
    if (kind == .power_on) sayUnkeptWrites(regs, mode, band);

    if (chip.phy_revision >= regs_mod.PhyRevision.rev2) {
        regs.put(.phy_adc_control, regs_mod.PhyAdcControl{
            .off_input_buffer_gain = 2,
            .on_input_buffer_gain = 2,
            .off_power_down_dac = true,
            .off_power_down_adc = true,
        });
        const adjust = family.cckAdjust(chip.store.cck_ofdm_power_delta, chip.store.scaled_ch14_filter_cck_delta, megahertz);
        regs.put(.phy_tx_power_adjust, regs_mod.PhyTxPowerAdjust{
            .cck_gain_delta = adjust.gain_delta,
            .cck_pcdac_index = adjust.pcdac_index,
        });
        var dag = regs.get(.phy_dag_control_cck, regs_mod.PhyDagControlCck);
        dag.enable_rssi_threshold = false;
        dag.rssi_threshold = 2;
        regs.put(.phy_dag_control_cck, dag);
        regs.write(.sequence_mute_mask, 0x0F);
    }
    if (chip.phy_revision >= regs_mod.PhyRevision.rev3) regs.write(.phy_bluetooth, 0);

    regs.write(.phy_sleep_scale, 0x0E);
    if (chip.part == .ar2417) {
        // A clock-changing register, written only when it must change.
        const fast: u32 = if (megahertz == 2462 or megahertz == 2467) 0 else 1;
        if (regs.read(.phy_fast_adc) != fast) regs.write(.phy_fast_adc, fast);
    }

    rf2425.setRfRegs(regs, &chip.banks, mode, chip.part, chip.store.bias_g);
    setDeltaSlope(regs, megahertz);
    setBoardValues(chip, megahertz);
    // After the board's own values, not before them: both have an opinion
    // about how much power a single tone may carry before the baseband
    // disbelieves it, and what was learned in this room is the later
    // word. Applied first, it is written over while the software goes on
    // believing the radio is where it put it.
    if (kind == .power_on) chip.immunity.begin(regs) else chip.immunity.restore(regs);
    setAmplifier(chip, megahertz);

    if (kind == .channel_change) regs.write(.sequence_number, saved_sequence);

    regs.write(.station_id_low, std.mem.readInt(u32, chip.mac[0..4], .little));
    regs.put(.station_id_high, regs_mod.StationIdHigh{
        .address_high = std.mem.readInt(u16, chip.mac[4..6], .little),
        .base_rate_11b = saved_station.base_rate_11b,
        .use_default_antenna = saved_station.use_default_antenna,
        .rts_use_default_antenna = true,
        .michael_enable = false,
        // HAL's station lookup mode; bypass and invalid CLR keys keep it inert.
        .key_search_mode = true,
    });
    regs.write(.bssid_mask_low, std.math.maxInt(u32));
    regs.write(.bssid_mask_high, std.math.maxInt(u16));

    var pci = regs.get(.pci_config, regs_mod.PciConfig);
    pci.led_control = saved_pci.led_control;
    pci.led_mode = saved_pci.led_mode;
    pci.led_blink = saved_pci.led_blink;
    pci.led_slow = saved_pci.led_slow;
    regs.put(.pci_config, pci);
    regs.write(.gpio_control, saved_gpio_control);
    regs.write(.gpio_out, saved_gpio_out);
    regs.write(.default_antenna, saved_antenna);

    regs.write(.bss_id_low, std.mem.readInt(u32, chip.bssid[0..4], .little));
    regs.put(.bss_id_high, regs_mod.BssIdHigh{
        .address_high = std.mem.readInt(u16, chip.bssid[4..6], .little),
        .association_id = chip.association_id,
    });
    regs.put(.rssi_threshold, regs_mod.RssiThreshold.initial);
    // Cleared on write.
    regs.write(.interrupt_status, std.math.maxInt(u32));

    if (!rf2425.setChannel(regs, megahertz)) return ResetError.Synth;
    setRateDurations(regs);
    activatePhy(regs);

    // Calibrate the gain control and start a noise-floor measurement.
    var agc = regs.get(.phy_agc_control, regs_mod.PhyAgcControl);
    agc.calibrate = true;
    agc.noise_floor = true;
    regs.put(.phy_agc_control, agc);

    if (chip.iq != .done) {
        startIq(regs);
        chip.iq = .running;
    } else {
        chip.iq = .inactive;
    }

    // One queue control unit per DCU, in order.
    for (0..regs_mod.QUEUES) |i| regs.writeAt(regs_mod.dcuQueueMask(@intCast(i)), @as(u32, 1) << @intCast(i));

    regs.put(.interrupt_mask, regs_mod.Interrupts{
        .tx_ok = true,
        .tx_error = true,
        .tx_underrun = true,
        .rx_ok = true,
        .rx_error = true,
        .rx_overrun = true,
        .bus_error = true,
    });
    var mask2 = regs.get(.interrupt_mask_2, regs_mod.InterruptsS2);
    mask2.master_abort = true;
    mask2.system_error = true;
    mask2.parity_error = true;
    regs.put(.interrupt_mask_2, mask2);

    if (chip.store.rf_kill) watchRfKill(chip);

    // Long enough for a quiet room, where this finishes at once, and no
    // longer: a loud room does not finish it inside any patience worth
    // spending, and every reset would spend the whole of it. What it does
    // not finish here the periodic calibration picks up, so the wait costs
    // milliseconds rather than the transmitter costing a whole interval.
    chip.gain_ready = pace.until(regs, .phy_agc_control, regs_mod.PhyAgcControl, "calibrate", false, GAIN_MICROS);

    // Only on the way up, and only once. The measurement is started beside
    // the gain control above and read much later by the periodic
    // calibration, so nothing else is in a position to notice that it never
    // finished, and a receiver that measures no floor is one that is hearing
    // nothing to measure. Waited for here rather than on every channel
    // change, where the waiting would cost every hop the whole timeout.
    if (kind == .power_on and
        !pace.until(regs, .phy_agc_control, regs_mod.PhyAgcControl, "noise_floor", false, pace.DEFAULT_MICROS))
    {
        log.warn(name, "the noise floor never measured; the receiver hears nothing to measure");
    }

    setupClock(chip);

    // The beacon register starts timers, so it is written last: no beacons
    // and the TSF kept, everything else as it was.
    var beacon = regs.get(.beacon, regs_mod.BeaconControl);
    beacon.enable = false;
    beacon.reset_tsf = false;
    regs.put(.beacon, beacon);

    regs.write(.qos_control, QOS_CONTROL_VALUE);
    regs.write(.qos_select, QOS_SELECT_VALUE);
    regs.put(.no_ack, regs_mod.NoAck{ .two_bit_value = 2, .bit_offset = 5, .byte_offset = 0 });

    // Last, because the amplifier's table has been written by now and
    // the offset a power is counted from is known.
    applyPower(chip);
    const policy = regs.get(.diagnostics, regs_mod.Diagnostics);
    if (!policy.decrypt_disable or !policy.encrypt_disable or
        !policy.ack_disable or !policy.cts_disable) return ResetError.RadioPolicy;
    if (kind == .power_on and chip.txPermitted()) {
        log.note(name, "TX ready: map2 curves, CCK/OFDM targets, world CTLs and antenna limits validated");
    }
}

// ---------------------------------------------------------------------------
// Calibration
// ---------------------------------------------------------------------------

/// The noise floor the baseband last measured.
pub fn readNoiseFloor(regs: Regs) i16 {
    return regs.get(.phy_cca, regs_mod.PhyCca).noise_floor;
}

/// Read the noise floor, judge it against the store's threshold, fold it
/// into the history, and load what the history says back into the
/// baseband for the next measurement.
fn loadNoiseFloor(chip: *Chip) void {
    const regs = chip.regs;
    if (regs.get(.phy_agc_control, regs_mod.PhyAgcControl).noise_floor) {
        // The measurement did not finish in its window; keep what was.
        return;
    }

    var floor = readNoiseFloor(regs);
    if (floor > chip.store.section(.g).noise_floor_threshold) {
        // Above the threshold is not a floor but interference; the
        // history treats zero as implausible and starts over.
        floor = 0;
    }
    const load = chip.noise.add(floor);

    regs.set(.phy_cca, regs_mod.PhyCca, "max_cca_power", @as(i8, @intCast(load)));
    var agc = regs.get(.phy_agc_control, regs_mod.PhyAgcControl);
    agc.enable_noise_floor = false;
    agc.no_update_noise_floor = false;
    agc.noise_floor = true;
    regs.put(.phy_agc_control, agc);
    _ = pace.until(regs, .phy_agc_control, regs_mod.PhyAgcControl, "noise_floor", false, pace.DEFAULT_MICROS);

    // A high ceiling again, so the next measurement is not capped by the
    // median just loaded.
    regs.set(.phy_cca, regs_mod.PhyCca, "max_cca_power", -50);
    agc = regs.get(.phy_agc_control, regs_mod.PhyAgcControl);
    agc.enable_noise_floor = true;
    agc.no_update_noise_floor = true;
    agc.noise_floor = true;
    regs.put(.phy_agc_control, agc);
}

/// The periodic calibration: finish an I/Q measurement that was running
/// and apply it, start one when the channel has none, and on a long call
/// take the noise floor.
pub fn calibrate(chip: *Chip, long: bool) void {
    const regs = chip.regs;
    if (chip.iq == .running and !regs.get(.phy_timing_control4, regs_mod.PhyTimingControl4).do_iq_calibration) {
        chip.iq = .inactive;

        // The results are sometimes misgated; the reference reads them
        // again, up to ten times, until both powers are nonzero.
        var power_i: u32 = 0;
        var power_q: u32 = 0;
        var correlation: i32 = 0;
        var tries: u32 = 0;
        while (tries < IQ_CAL_TRIES) : (tries += 1) {
            power_i = regs.read(.phy_iq_power_i);
            power_q = regs.read(.phy_iq_power_q);
            correlation = @bitCast(regs.read(.phy_iq_correlation));
            if (power_i != 0 and power_q != 0) break;
            regs.set(.phy_timing_control4, regs_mod.PhyTimingControl4, "do_iq_calibration", true);
        }

        if (family.iqCorrection(power_i, power_q, correlation)) |correction| {
            var timing4 = regs.get(.phy_timing_control4, regs_mod.PhyTimingControl4);
            timing4.iq_correction_i = correction.i;
            timing4.iq_correction_q = correction.q;
            timing4.iq_correction_enable = true;
            regs.put(.phy_timing_control4, timing4);
            chip.iq = .done;
            chip.iq_measured = correction;
        }
    } else if (chip.iq == .inactive and chip.iq_measured == null) {
        // Nothing measured on this channel: either a run gave numbers the
        // arithmetic could make nothing of, or the channel has just
        // changed. Either way the radio is running on the store's own
        // figures rather than on this channel's, which is no reason to
        // stop trying to measure them.
        startIq(regs);
        chip.iq = .running;
    }

    // The gain calibration the reset started and did not wait out. Nothing
    // is transmitted until it has finished, so this is what lets a radio
    // that calibrated slowly start transmitting without another reset.
    if (!chip.gain_ready and !regs.get(.phy_agc_control, regs_mod.PhyAgcControl).calibrate) {
        chip.gain_ready = true;
    }

    if (long) loadNoiseFloor(chip);
}

/// Ask the baseband to measure how far its two mixing paths are out of
/// balance.
fn startIq(regs: Regs) void {
    var timing4 = regs.get(.phy_timing_control4, regs_mod.PhyTimingControl4);
    timing4.iq_calibration_log_count = IQ_CAL_LOG_COUNT_MAX;
    timing4.do_iq_calibration = true;
    regs.put(.phy_timing_control4, timing4);
}

/// What a channel change forgets: the correction measured on the last one,
/// and the fact that one was measured. A correction taken on another
/// channel is not one this channel is calibrated by, so what is owed is a
/// measurement rather than nothing.
pub fn forgetChannel(chip: *Chip) void {
    chip.iq_measured = null;
    chip.iq = .inactive;
}
