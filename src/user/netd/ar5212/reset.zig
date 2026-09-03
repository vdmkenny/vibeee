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
//! What is not here, and is owed before the radio transmits: the transmit
//! power tables, which need the store's calibration curves interpolated
//! per channel, and the spur-immunity settings a 5.3 store carries. A
//! receiver does not need either.

const lib = @import("lib");
const log = @import("ulib").log;
const pace = @import("pace.zig");
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
    store: lib.ar5212.Store,
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
    iq_measured: ?lib.ar5212.IqCorrection = null,
    noise: lib.ar5212.NoiseFloor = .{},
    /// The ceiling, in half decibels, on the frames the unit sends itself:
    /// acknowledgements and the like. The regulatory plan sets it.
    self_power: u6 = MAX_RATE_POWER,
    /// Whether the baseband is powered, which decides whether its
    /// registers may be touched.
    phy_powered: bool = false,

    pub fn isPcie(self: *const Chip) bool {
        return self.version.isPcie();
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
};

/// The reference's constants.
const MAX_RATE_POWER: u6 = 63;
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
    regs.put(.queue_disable, regs_mod.QueueMask.all);

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

    var settled = false;
    var looked: u32 = 0;
    while (looked < pace.DEFAULT_TRIES) : (looked += 1) {
        const now = regs.get(.reset_control, regs_mod.ResetControl);
        if (now.mac == mask.mac and now.baseband == mask.baseband) {
            settled = true;
            break;
        }
        pace.delay(10);
    }

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
    // told apart per frame, at the 40 MHz clock.
    const mode = regs_mod.PhyMode{ .radio_5112 = true, .rf_2ghz = true, .dynamic = true };
    const pll: regs_mod.PhyPll = .ofdm_40_5112;
    const current: regs_mod.PhyPll = @enumFromInt(regs.read(.phy_pll_control));

    if (current != pll) {
        regs.write(.phy_pll_control, @intFromEnum(pll));
        pace.delay(PLL_SETTLE_MICROS);
    }
    regs.put(.phy_turbo, regs_mod.PhyTurbo{});
    regs.put(.phy_mode, mode);
    return true;
}

/// The family's common table, written whole on a power-on reset and
/// without its timer and sleep registers on a channel change, which keeps
/// the beacon timers and the sleep state across the change.
fn writeCommon(regs: Regs, kind: Kind) void {
    for (tables.family.common) |row| {
        if (kind == .channel_change and lib.ar5212.survivesChannelChange(row.register)) continue;
        regs.writeAt(row.register, row.value);
    }
}

/// The OFDM timing coefficients for the carrier.
fn setDeltaSlope(regs: Regs, megahertz: u16) void {
    const slope = lib.ar5212.deltaSlope(megahertz);
    var timing = regs.get(.phy_timing3, regs_mod.PhyTiming3);
    timing.delta_slope_mantissa = slope.mantissa;
    timing.delta_slope_exponent = slope.exponent;
    regs.put(.phy_timing3, timing);
}

/// The board's own values from the calibration store: antennas, the
/// noise-floor threshold, the settling and gain figures, the amplifier
/// timings, the false-detect backoff, and the I/Q correction.
///
/// The store's per-band pairs are indexed the reference's way: the second
/// entry for anything at 2.4 GHz, which for the settling, attenuation and
/// margin figures is what the 11b section holds.
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
    if (store.version.atLeast(.v3_3) and lib.ar5212.isSpurChannel(megahertz)) backoff += section.false_detect_backoff;
    regs.set(.phy_timing5, regs_mod.PhyTiming5, "cycle_power_threshold1", @as(u7, @truncate(backoff)));

    // The I/Q correction: what was measured on this channel, else what
    // the store says.
    const correction: lib.ar5212.IqCorrection = chip.iq_measured orelse .{
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
    for (lib.ar5212.RATE_DURATIONS) |entry| {
        regs.writeAt(regs_mod.rateDuration(entry.code), entry.micros);
    }
}

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
    rf2425.writeRegs(regs, mode, band);

    if (chip.phy_revision >= regs_mod.PhyRevision.rev2) {
        regs.put(.phy_adc_control, regs_mod.PhyAdcControl{
            .off_input_buffer_gain = 2,
            .on_input_buffer_gain = 2,
            .off_power_down_dac = true,
            .off_power_down_adc = true,
        });
        const adjust = lib.ar5212.cckAdjust(chip.store.cck_ofdm_power_delta, chip.store.scaled_ch14_filter_cck_delta, megahertz);
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

    // Transmit power: owed. The receiver does not need it.

    rf2425.setRfRegs(regs, &chip.banks, mode, chip.part, chip.store.bias_g);
    setDeltaSlope(regs, megahertz);
    setBoardValues(chip, megahertz);

    if (kind == .channel_change) regs.write(.sequence_number, saved_sequence);

    regs.write(.station_id_low, std.mem.readInt(u32, chip.mac[0..4], .little));
    regs.put(.station_id_high, regs_mod.StationIdHigh{
        .address_high = std.mem.readInt(u16, chip.mac[4..6], .little),
        .base_rate_11b = saved_station.base_rate_11b,
        .use_default_antenna = saved_station.use_default_antenna,
        .rts_use_default_antenna = true,
        .michael_enable = true,
        // A station looks keys up by the frame's key index.
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
        var timing4 = regs.get(.phy_timing_control4, regs_mod.PhyTimingControl4);
        timing4.iq_calibration_log_count = IQ_CAL_LOG_COUNT_MAX;
        timing4.do_iq_calibration = true;
        regs.put(.phy_timing_control4, timing4);
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

    if (!pace.until(regs, .phy_agc_control, regs_mod.PhyAgcControl, "calibrate", false, pace.DEFAULT_TRIES)) {
        log.warn(name, "offset calibration did not complete; noisy surroundings?");
    }

    // Only on the way up, and only once. The measurement is started beside
    // the gain control above and read much later by the periodic
    // calibration, so nothing else is in a position to notice that it never
    // finished, and a receiver that measures no floor is one that is hearing
    // nothing to measure. Waited for here rather than on every channel
    // change, where the waiting would cost every hop the whole timeout.
    if (kind == .power_on and
        !pace.until(regs, .phy_agc_control, regs_mod.PhyAgcControl, "noise_floor", false, pace.DEFAULT_TRIES))
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

    regs.put(.self_power, regs_mod.SelfPower{
        .ack = chip.self_power,
        .cts = chip.self_power,
        .chirp = chip.self_power,
    });
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
    _ = pace.until(regs, .phy_agc_control, regs_mod.PhyAgcControl, "noise_floor", false, pace.DEFAULT_TRIES);

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

        if (lib.ar5212.iqCorrection(power_i, power_q, correlation)) |correction| {
            var timing4 = regs.get(.phy_timing_control4, regs_mod.PhyTimingControl4);
            timing4.iq_correction_i = correction.i;
            timing4.iq_correction_q = correction.q;
            timing4.iq_correction_enable = true;
            regs.put(.phy_timing_control4, timing4);
            chip.iq = .done;
            chip.iq_measured = correction;
        }
    } else if (chip.iq == .done and chip.iq_measured == null) {
        var timing4 = regs.get(.phy_timing_control4, regs_mod.PhyTimingControl4);
        timing4.iq_calibration_log_count = IQ_CAL_LOG_COUNT_MAX;
        timing4.do_iq_calibration = true;
        regs.put(.phy_timing_control4, timing4);
        chip.iq = .running;
    }

    if (long) loadNoiseFloor(chip);
}

/// What a channel change forgets: the correction measured on the last one.
pub fn forgetChannel(chip: *Chip) void {
    chip.iq_measured = null;
}
