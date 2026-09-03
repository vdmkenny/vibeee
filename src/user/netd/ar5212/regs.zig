//! The AR5212 family's registers: every offset the driver reaches, named,
//! and every word it reads or writes whole, as the packed struct of its
//! fields.
//!
//! The numbers are the reference's, FreeBSD's Atheros hardware layer pinned
//! under `third_party/ath_hal`. Each packed struct is pinned to the
//! reference's masks at compile time, so a field that drifts fails the
//! build rather than the radio. The initialisation tables reach registers
//! this file does not name, by offset; what is named is what the driver
//! reads or writes on its own.

const lib = @import("lib");
const std = @import("std");

/// Every register is a word, so one window serves the whole chip.
pub const R = enum(usize) {
    // DMA control and interrupts.
    control = 0x0008,
    rx_pointer = 0x000C,
    config = 0x0014,
    interrupt_enable = 0x0024,
    tx_config = 0x0030,
    rx_config = 0x0034,
    mib_control = 0x0040,
    interrupt_status = 0x0080,
    interrupt_status_2 = 0x008C,
    interrupt_mask = 0x00A0,
    interrupt_mask_0 = 0x00A4,
    interrupt_mask_1 = 0x00A8,
    interrupt_mask_2 = 0x00AC,
    /// The status register that clears on being read: the one an
    /// interrupt handler reads.
    interrupt_status_clearing = 0x00C0,
    interrupt_status_0_clearing = 0x00C4,
    interrupt_status_1_clearing = 0x00C8,
    interrupt_status_2_clearing = 0x00CC,

    // Queues. The per-queue registers are consecutive words from these.
    tx_pointer_0 = 0x0800,
    queue_enable = 0x0840,
    queue_disable = 0x0880,
    queue_status_0 = 0x0A00,
    dcu_queue_mask_0 = 0x1000,
    ifs_sifs = 0x1030,
    ifs_slot = 0x1070,
    ifs_eifs = 0x10B0,
    ifs_misc = 0x10F0,
    sequence_number = 0x1140,

    // Reset, sleep and the bus.
    reset_control = 0x4000,
    sleep_control = 0x4004,
    interrupt_pending = 0x4008,
    pci_config = 0x4010,
    gpio_control = 0x4014,
    gpio_out = 0x4018,
    gpio_in = 0x401C,
    silicon_revision = 0x4020,
    /// The PCI Express serialiser's settings, loaded a word at a time,
    /// and the register that takes them.
    pcie_serdes = 0x4080,
    pcie_serdes_load = 0x4084,

    // The calibration store's port.
    eeprom_address = 0x6000,
    eeprom_data = 0x6004,
    eeprom_command = 0x6008,
    eeprom_status = 0x600C,

    // The protocol control unit.
    station_id_low = 0x8000,
    station_id_high = 0x8004,
    bss_id_low = 0x8008,
    bss_id_high = 0x800C,
    slot_time = 0x8010,
    ack_cts_timeout = 0x8014,
    rssi_threshold = 0x8018,
    usec = 0x801C,
    beacon = 0x8020,
    cfp_period = 0x8024,
    timer0 = 0x8028,
    cfp_duration = 0x8038,
    rx_filter = 0x803C,
    multicast_filter_low = 0x8040,
    multicast_filter_high = 0x8044,
    diagnostics = 0x8048,
    tsf_low = 0x804C,
    tsf_high = 0x8050,
    default_antenna = 0x8058,
    sequence_mute_mask = 0x8060,
    sleep1 = 0x80D4,
    sleep3 = 0x80DC,
    bssid_mask_low = 0x80E0,
    bssid_mask_high = 0x80E4,
    self_power = 0x80E8,
    tsf_parameters = 0x8104,
    no_ack = 0x8108,
    phy_error_filter = 0x810C,
    qos_control = 0x8118,
    qos_select = 0x811C,
    misc_mode = 0x8120,
    rate_duration_0 = 0x8700,
    key_table_0 = 0x8800,

    // The baseband.
    phy_test = 0x9800,
    phy_turbo = 0x9804,
    phy_test_control = 0x9808,
    phy_timing3 = 0x9814,
    phy_chip_id = 0x9818,
    phy_active = 0x981C,
    phy_tx_xlna = 0x9828,
    phy_adc_control = 0x982C,
    phy_tx_xpa = 0x9834,
    phy_settling = 0x9844,
    phy_rx_gain = 0x9848,
    phy_desired_size = 0x9850,
    phy_agc_control = 0x9860,
    phy_cca = 0x9864,
    phy_sleep_counter_control = 0x9870,
    phy_sleep_counter_limit = 0x9874,
    phy_sleep_scale = 0x9878,
    phy_pll_control = 0x987C,
    phy_radio_revision_strobe = 0x9880,
    /// The analog shift register the banks are written through, and the
    /// low byte of the synthesizer word.
    phy_bank_data = 0x989C,
    /// The second bank's port, and the radio revision's select.
    phy_bank2 = 0x98D0,
    /// The high bits of the synthesizer word.
    phy_synth_high = 0x98D8,
    phy_antenna_control = 0x9910,
    phy_rx_delay = 0x9914,
    phy_timing_control4 = 0x9920,
    phy_timing5 = 0x9924,
    phy_frame_control = 0x9944,
    phy_tx_power_adjust = 0x994C,
    phy_antenna_switch_a = 0x9960,
    phy_antenna_switch_b = 0x9964,
    phy_noise_floor_threshold = 0x9968,
    phy_rf_bus_request = 0x997C,
    phy_heavy_clip = 0x99E0,
    phy_m_sleep = 0x99F0,
    phy_refclk_delay = 0x99F4,
    phy_refclk_powerdown = 0x99F8,
    phy_radio_revision = 0x9C00,
    phy_iq_power_i = 0x9C10,
    phy_iq_power_q = 0x9C14,
    phy_iq_correlation = 0x9C18,
    phy_rf_bus_grant = 0x9C20,
    phy_baseband_ready = 0x9C24,
    phy_mode = 0xA200,
    phy_cck_tx_control = 0xA204,
    phy_cck_detect = 0xA208,
    phy_gain_2ghz = 0xA20C,
    phy_dag_control_cck = 0xA228,
    phy_fast_adc = 0xA24C,
    phy_bluetooth = 0xA254,
};

/// Where a queue's, a DCU's or a rate's own register sits: the base, then a
/// word per index.
pub fn txPointer(queue: u4) usize {
    return @intFromEnum(R.tx_pointer_0) + @as(usize, queue) * 4;
}

pub fn queueStatus(queue: u4) usize {
    return @intFromEnum(R.queue_status_0) + @as(usize, queue) * 4;
}

pub fn dcuQueueMask(dcu: u4) usize {
    return @intFromEnum(R.dcu_queue_mask_0) + @as(usize, dcu) * 4;
}

pub fn rateDuration(code: lib.ar5212.RateCode) usize {
    return @intFromEnum(R.rate_duration_0) + @as(usize, @intFromEnum(code)) * 4;
}

/// How many transmit queues and DCUs the family has.
pub const QUEUES = 10;

/// The typed face of the window: a word read as its struct, written from
/// one, or one field of it changed with the rest kept.
pub const Regs = struct {
    window: lib.mmio.Window(R, u32),

    pub fn read(self: Regs, register: R) u32 {
        return self.window.read(register);
    }

    pub fn write(self: Regs, register: R, value: u32) void {
        self.window.write(register, value);
    }

    pub fn writeAt(self: Regs, offset: usize, value: u32) void {
        self.window.writeAt(offset, value);
    }

    pub fn readAt(self: Regs, offset: usize) u32 {
        return self.window.readAt(offset);
    }

    pub fn get(self: Regs, register: R, comptime Word: type) Word {
        return @bitCast(self.window.read(register));
    }

    pub fn put(self: Regs, register: R, word: anytype) void {
        self.window.write(register, @bitCast(word));
    }

    /// Change one field of a word and write it back.
    pub fn set(self: Regs, register: R, comptime Word: type, comptime field: []const u8, value: anytype) void {
        var word: Word = @bitCast(self.window.read(register));
        @field(word, field) = value;
        self.window.write(register, @bitCast(word));
    }

    /// A read whose value is not wanted, to flush posted writes.
    pub fn flush(self: Regs, register: R) void {
        _ = self.window.read(register);
    }
};

// ---------------------------------------------------------------------------
// DMA control and interrupts
// ---------------------------------------------------------------------------

/// Which engines are running.
pub const Control = packed struct(u32) {
    _0: u2 = 0,
    rx_enable: bool = false,
    _3: u2 = 0,
    rx_disable: bool = false,
    software_interrupt: bool = false,
    _7: u25 = 0,
};

pub const Config = packed struct(u32) {
    swap_tx_descriptors: bool = false,
    swap_tx_buffers: bool = false,
    swap_rx_descriptors: bool = false,
    swap_rx_buffers: bool = false,
    swap_registers: bool = false,
    adhoc_indication: bool = false,
    _6: u2 = 0,
    phy_ok: bool = false,
    eeprom_busy: bool = false,
    clock_gate_disable: bool = false,
    _11: u6 = 0,
    master_request_threshold: u2 = 0,
    _19: u13 = 0,
};

/// Whether anything at all reaches the interrupt pin.
pub const InterruptEnable = packed struct(u32) {
    enabled: bool = false,
    _1: u31 = 0,
};

/// What the radio reports, and what it may be asked to report. One shape
/// for both, because a mask and a status are the same set of causes read
/// in the two directions.
pub const Interrupts = packed struct(u32) {
    rx_ok: bool = false,
    rx_descriptor: bool = false,
    rx_error: bool = false,
    rx_no_frame: bool = false,
    rx_end_of_list: bool = false,
    rx_overrun: bool = false,
    tx_ok: bool = false,
    tx_descriptor: bool = false,
    tx_error: bool = false,
    tx_no_frame: bool = false,
    tx_end_of_list: bool = false,
    tx_underrun: bool = false,
    mib: bool = false,
    software: bool = false,
    rx_phy_error: bool = false,
    rx_key_miss: bool = false,
    beacon_alert: bool = false,
    beacon_rssi: bool = false,
    beacon_missed: bool = false,
    bus_error: bool = false,
    beacon_not_ready: bool = false,
    rx_chirp: bool = false,
    rx_doppler: bool = false,
    beacon_misc: bool = false,
    gpio: bool = false,
    queue_cbr_overflow: bool = false,
    queue_cbr_underrun: bool = false,
    queue_trigger: bool = false,
    _28: u4 = 0,

    pub fn any(self: Interrupts) bool {
        return @as(u32, @bitCast(self)) != 0;
    }

    /// What a card that has gone away answers to every read.
    pub fn isAbsent(self: Interrupts) bool {
        return @as(u32, @bitCast(self)) == std.math.maxInt(u32);
    }
};

/// The second secondary register: bus errors, and the beacon timers.
pub const InterruptsS2 = packed struct(u32) {
    queue_underrun: u10 = 0,
    _10: u6 = 0,
    master_abort: bool = false,
    system_error: bool = false,
    parity_error: bool = false,
    _19: u5 = 0,
    tim: bool = false,
    cab_end: bool = false,
    dtim_sync: bool = false,
    beacon_timeout: bool = false,
    cab_timeout: bool = false,
    dtim: bool = false,
    tsf_out_of_range: bool = false,
    tbtt: bool = false,
};

/// The receive DMA's configuration: how big its bursts are, and whether a
/// zero-length frame is written up, which the reference turns on only
/// when PHY errors are wanted.
pub const RxConfig = packed struct(u32) {
    dma_size: u3 = 0,
    _3: u1 = 0,
    zero_length_dma: bool = false,
    _5: u27 = 0,
};

pub const MibControl = packed struct(u32) {
    overflow_warning: bool = false,
    freeze: bool = false,
    clear: bool = false,
    strobe: bool = false,
    _4: u28 = 0,
};

/// One bit per transmit queue: which to start, stop or ask about.
pub const QueueMask = packed struct(u32) {
    queues: u10 = 0,
    _10: u22 = 0,

    pub const all = QueueMask{ .queues = std.math.maxInt(u10) };
};

pub const QueueStatus = packed struct(u32) {
    pending_frames: u2 = 0,
    _2: u6 = 0,
    cbr_expired: u8 = 0,
    _16: u16 = 0,
};

// ---------------------------------------------------------------------------
// Reset, sleep and the bus
// ---------------------------------------------------------------------------

/// Which engines a reset holds down. On a card attached by PCI Express the
/// bus block must never be reset: doing so takes the link down and the
/// machine with it, so the driver clears that bit on such a card before
/// every write of this word.
pub const ResetControl = packed struct(u32) {
    mac: bool = false,
    baseband: bool = false,
    _2: u2 = 0,
    pci: bool = false,
    _5: u27 = 0,
};

/// The sleep state machine's setting.
pub const SleepEnable = enum(u2) {
    /// Awake, and staying awake.
    wake = 0,
    sleep = 1,
    /// The hardware may sleep when it judges it can.
    normal = 2,
    _,
};

pub const SleepControl = packed struct(u32) {
    /// In units of 128 microseconds.
    duration: u16 = 0,
    enable: SleepEnable = .wake,
    duration_timing_policy: bool = false,
    duration_write_policy: bool = false,
    policy_mode: bool = false,
    mib_interrupt: bool = false,
    unknown: bool = false,
    _23: u9 = 0,

    /// Whether the word is one the chip could have written, rather than
    /// the all-ones a powered-down card answers with.
    pub fn plausible(self: SleepControl) bool {
        return self._23 == 0;
    }
};

pub const InterruptPending = packed struct(u32) {
    pending: bool = false,
    _1: u31 = 0,
};

pub const EepromSize = enum(u2) {
    kbit4 = 0,
    kbit8 = 1,
    kbit16 = 2,
    failed = 3,
};

pub const LedControl = enum(u2) {
    none = 0,
    pending = 1,
    associated = 2,
    _,
};

pub const PciConfig = packed struct(u32) {
    _0: u1 = 0,
    sleep_clock_select: u1 = 0,
    clock_run_enable: bool = false,
    eeprom_size: EepromSize = .kbit4,
    led_control: LedControl = .none,
    bus_select: u3 = 0,
    disable_cbe_fix: bool = false,
    sleep_interrupt_enable: bool = false,
    retry_fix_enable: bool = false,
    sleep_on_interrupt: bool = false,
    _14: u2 = 0,
    /// Set while the chip is powered down; a wake is complete when it
    /// clears.
    powered_down: bool = false,
    led_mode: u3 = 0,
    led_blink: u3 = 0,
    led_slow: bool = false,
    sleep_clock_rate: u2 = 0,
    _26: u6 = 0,
};

/// How a GPIO pin is driven.
pub const PinMode = enum(u2) {
    input = 0,
    _1 = 1,
    _2 = 2,
    output = 3,
};

pub const GpioControl = packed struct(u32) {
    pin0: PinMode = .input,
    pin1: PinMode = .input,
    pin2: PinMode = .input,
    pin3: PinMode = .input,
    pin4: PinMode = .input,
    pin5: PinMode = .input,
    interrupt_pin: u3 = 0,
    interrupt_enable: bool = false,
    interrupt_when_high: bool = false,
    _17: u15 = 0,

    pub fn setPin(self: *GpioControl, pin: u3, mode: PinMode) void {
        switch (pin) {
            0 => self.pin0 = mode,
            1 => self.pin1 = mode,
            2 => self.pin2 = mode,
            3 => self.pin3 = mode,
            4 => self.pin4 = mode,
            5 => self.pin5 = mode,
            else => {},
        }
    }
};

pub const GpioData = packed struct(u32) {
    pins: u6 = 0,
    _6: u26 = 0,

    pub fn pin(self: GpioData, which: u3) bool {
        return which < 6 and (self.pins >> which) & 1 == 1;
    }
};

/// The MAC generations the family's version field names. Part numbers
/// where the reference gives one, its codename otherwise.
pub const MacVersion = enum(u4) {
    crete = 0,
    maui1 = 1,
    maui2 = 2,
    spirit = 3,
    oahu = 4,
    ar5212 = 5,
    ar2413 = 7,
    ar5424 = 9,
    ar5413 = 10,
    ar2415 = 11,
    ar2425 = 14,
    ar2417 = 15,
    _,

    /// Whether this generation is one the transcribed sequences were
    /// written for.
    pub fn known(self: MacVersion) bool {
        return switch (self) {
            .ar2425, .ar2417 => true,
            else => false,
        };
    }

    /// Whether the part is attached by PCI Express, which decides whether
    /// the bus block may ever be reset.
    pub fn isPcie(self: MacVersion) bool {
        return self == .ar5424 or self == .ar2425;
    }

    pub fn spell(self: MacVersion) []const u8 {
        return switch (self) {
            .ar5212 => "AR5212",
            .ar2413 => "AR2413",
            .ar5424 => "AR5424",
            .ar5413 => "AR5413",
            .ar2415 => "AR2415",
            .ar2425 => "AR2425",
            .ar2417 => "AR2417",
            else => "unknown",
        };
    }
};

pub const SiliconRevision = packed struct(u32) {
    revision: u4 = 0,
    version: MacVersion = .crete,
    _8: u24 = 0,
};

// ---------------------------------------------------------------------------
// The calibration store's port
// ---------------------------------------------------------------------------

pub const EepromCommand = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    reset: bool = false,
    _3: u29 = 0,
};

pub const EepromStatus = packed struct(u32) {
    read_error: bool = false,
    read_complete: bool = false,
    write_error: bool = false,
    write_complete: bool = false,
    _4: u28 = 0,
};

// ---------------------------------------------------------------------------
// The protocol control unit
// ---------------------------------------------------------------------------

pub const StationIdHigh = packed struct(u32) {
    address_high: u16 = 0,
    access_point: bool = false,
    adhoc: bool = false,
    power_save: bool = false,
    key_search_disable: bool = false,
    pcf: bool = false,
    use_default_antenna: bool = false,
    update_default_antenna: bool = false,
    rts_use_default_antenna: bool = false,
    ack_cts_6mb: bool = false,
    base_rate_11b: bool = false,
    default_antenna_self: bool = false,
    michael_enable: bool = false,
    key_search_mode: bool = false,
    preserve_sequence: bool = false,
    cbc_iv_endian: bool = false,
    multicast_key_search: bool = false,
};

pub const BssIdHigh = packed struct(u32) {
    address_high: u16 = 0,
    association_id: u16 = 0,
};

pub const RssiThreshold = packed struct(u32) {
    rssi: u8 = 0,
    beacon_miss: u8 = 0,
    _16: u16 = 0,

    /// The reference's starting value: seven missed beacons, and a warning
    /// threshold of one.
    pub const initial = RssiThreshold{ .rssi = 0x81, .beacon_miss = 0x07 };
};

pub const Usec = packed struct(u32) {
    usec: u7 = 0,
    usec32: u7 = 0,
    tx_latency: u9 = 0,
    rx_latency: u6 = 0,
    _29: u3 = 0,
};

pub const BeaconControl = packed struct(u32) {
    period: u16 = 0,
    tim_offset: u7 = 0,
    enable: bool = false,
    reset_tsf: bool = false,
    _25: u7 = 0,
};

/// Which frames the protocol unit keeps rather than discards.
pub const RxFilter = packed struct(u32) {
    unicast: bool = false,
    multicast: bool = false,
    broadcast: bool = false,
    control: bool = false,
    beacon: bool = false,
    promiscuous: bool = false,
    _6: u1 = 0,
    probe_request: bool = false,
    /// Frames the baseband could not decode. A receiver is told about
    /// these separately from traffic, and told nothing at all unless the
    /// error filter below names which kinds it cares about.
    phy_error: bool = false,
    radar_error: bool = false,
    _10: u22 = 0,
};

/// Which kinds of undecodable frame the baseband reports at all.
///
/// Empty is the quiet setting and the one a driver wanting only traffic
/// leaves it at. Naming a kind is what makes the count of them mean
/// anything: a receiver hearing a band it cannot decode says so here and
/// nowhere else.
pub const PhyErrorFilter = packed struct(u32) {
    _0: u5 = 0,
    radar: bool = false,
    _6: u11 = 0,
    ofdm: bool = false,
    _18: u7 = 0,
    cck: bool = false,
    _26: u6 = 0,
};

pub const Diagnostics = packed struct(u32) {
    cache_ack: bool = false,
    ack_disable: bool = false,
    cts_disable: bool = false,
    encrypt_disable: bool = false,
    decrypt_disable: bool = false,
    rx_disable: bool = false,
    _6: u1 = 0,
    corrupt_fcs: bool = false,
    channel_info: bool = false,
    scrambler_seed_enable: bool = false,
    scrambler_seed: u7 = 0,
    frames_nonzero_version: bool = false,
    observation_point: u2 = 0,
    rx_clear_high: bool = false,
    ignore_carrier_sense: bool = false,
    channel_idle: bool = false,
    phear_me: bool = false,
    _24: u8 = 0,
};

/// The power the protocol unit sends its own frames at, in half decibels.
pub const SelfPower = packed struct(u32) {
    ack: u6 = 0,
    _6: u2 = 0,
    cts: u6 = 0,
    _14: u2 = 0,
    chirp: u6 = 0,
    _22: u2 = 0,
    doppler: u4 = 0,
    _28: u4 = 0,
};

pub const NoAck = packed struct(u32) {
    two_bit_value: u4 = 0,
    bit_offset: u3 = 0,
    byte_offset: u2 = 0,
    _9: u23 = 0,
};

// ---------------------------------------------------------------------------
// The baseband
// ---------------------------------------------------------------------------

/// The baseband's analog access word. The reference writes the whole
/// register; the two values it uses are named here.
pub const PhyTest = packed struct(u32) {
    /// The baseband-to-analog shift setting that gives access to the
    /// radio.
    analog_shift: u3 = 0,
    _3: u10 = 0,
    rf_silence: bool = false,
    _14: u18 = 0,

    pub const analog_access = PhyTest{ .analog_shift = 7 };
};

pub const PhyTurbo = packed struct(u32) {
    turbo_mode: bool = false,
    short_symbols: bool = false,
    mimo: bool = false,
    _3: u29 = 0,
};

pub const PhyTestControl = packed struct(u32) {
    _0: u11 = 0,
    tx_hold: u3 = 0,
    _14: u18 = 0,

    pub const hold_tx = PhyTestControl{ .tx_hold = 7 };
};

pub const PhyTiming3 = packed struct(u32) {
    _0: u13 = 0,
    delta_slope_exponent: u4 = 0,
    delta_slope_mantissa: u15 = 0,
};

pub const PhyActive = packed struct(u32) {
    enable: bool = false,
    _1: u31 = 0,
};

pub const PhyAdcControl = packed struct(u32) {
    off_input_buffer_gain: u2 = 0,
    _2: u11 = 0,
    off_power_down_dac: bool = false,
    off_power_down_bandgap: bool = false,
    off_power_down_adc: bool = false,
    on_input_buffer_gain: u2 = 0,
    _18: u14 = 0,
};

pub const PhySettling = packed struct(u32) {
    agc: u7 = 0,
    switch_settling: u7 = 0,
    _14: u18 = 0,
};

pub const PhyRxGain = packed struct(u32) {
    _0: u12 = 0,
    txrx_attenuation: u6 = 0,
    txrx_rf_max: u5 = 0,
    _23: u9 = 0,
};

pub const PhyDesiredSize = packed struct(u32) {
    adc: i8 = 0,
    pga: i8 = 0,
    _16: u4 = 0,
    total: u8 = 0,
    _28: u4 = 0,
};

pub const PhyAgcControl = packed struct(u32) {
    calibrate: bool = false,
    noise_floor: bool = false,
    _2: u13 = 0,
    enable_noise_floor: bool = false,
    filter_calibration: bool = false,
    no_update_noise_floor: bool = false,
    _18: u14 = 0,
};

/// The clear-channel word: the signal threshold, the measured noise
/// floor, and the ceiling loaded for the next measurement.
pub const PhyCca = packed struct(u32) {
    _0: u1 = 0,
    max_cca_power: i8 = 0,
    _9: u3 = 0,
    threshold62: u7 = 0,
    noise_floor: i9 = 0,
    _28: u4 = 0,
};

pub const PhyRxDelay = packed struct(u32) {
    /// In hundreds of nanoseconds.
    delay: u14 = 0,
    _14: u18 = 0,
};

pub const PhyTimingControl4 = packed struct(u32) {
    iq_correction_q: i5 = 0,
    iq_correction_i: i6 = 0,
    iq_correction_enable: bool = false,
    iq_calibration_log_count: u4 = 0,
    do_iq_calibration: bool = false,
    _17: u11 = 0,
    enable_pilot_mask: bool = false,
    enable_channel_mask: bool = false,
    enable_spur_filter: bool = false,
    _31: u1 = 0,
};

pub const PhyTiming5 = packed struct(u32) {
    _0: u1 = 0,
    cycle_power_threshold1: u7 = 0,
    _8: u24 = 0,
};

pub const PhyTxPowerAdjust = packed struct(u32) {
    _0: u6 = 0,
    cck_gain_delta: i6 = 0,
    _12: u6 = 0,
    cck_pcdac_index: i6 = 0,
    _24: u8 = 0,
};

/// The reference keeps bits one and two of this word across a write and
/// clears bit three; the struct names them so a caller can do the same.
pub const PhyAntennaControl = packed struct(u32) {
    enable: bool = false,
    _1: u2 = 0,
    _3: u1 = 0,
    antenna_control: u6 = 0,
    _10: u22 = 0,
};

/// Five six-bit switch settings, one word per bank.
pub const PhyAntennaSwitch = packed struct(u32) {
    s1: u6 = 0,
    s2: u6 = 0,
    s3: u6 = 0,
    s4: u6 = 0,
    s5: u6 = 0,
    _30: u2 = 0,
};

pub const PhyNoiseFloorThreshold = packed struct(u32) {
    threshold: i9 = 0,
    enable: bool = false,
    _10: u22 = 0,
};

/// When the power amplifier switches, relative to a frame's ends, for the
/// two antennas.
pub const PhyXpa = packed struct(u32) {
    frame_to_xpa_on_a: u8 = 0,
    frame_to_xpa_on_b: u8 = 0,
    end_to_xpa_off_a: u8 = 0,
    end_to_xpa_off_b: u8 = 0,
};

pub const PhyXlna = packed struct(u32) {
    _0: u8 = 0,
    end_to_xlna_on: u8 = 0,
    _16: u16 = 0,
};

/// The values the phase-locked loop takes, from the reference.
pub const PhyPll = enum(u32) {
    ofdm_40 = 0xAA,
    cck_44 = 0xAB,
    ofdm_40_5112 = 0xEA,
    cck_44_5112 = 0xEB,
    ofdm_40_5413 = 0x04,
    _,
};

pub const PhyMode = packed struct(u32) {
    /// Complementary code keying rather than OFDM.
    cck: bool = false,
    rf_2ghz: bool = false,
    /// Both modulations, told apart per frame.
    dynamic: bool = false,
    radio_5112: bool = false,
    _4: u1 = 0,
    half: bool = false,
    quarter: bool = false,
    _7: u1 = 0,
    dynamic_cck_disable: bool = false,
    _9: u23 = 0,
};

pub const PhyCckTxControl = packed struct(u32) {
    _0: u4 = 0,
    /// Channel spreading for channel fourteen.
    japan: bool = false,
    _5: u27 = 0,
};

pub const PhyCckDetect = packed struct(u32) {
    weak_signal_threshold: u6 = 0,
    _6: u7 = 0,
    fast_diversity: bool = false,
    _14: u18 = 0,
};

pub const PhyGain2GHz = packed struct(u32) {
    _0: u18 = 0,
    rxtx_margin: u6 = 0,
    _24: u8 = 0,
};

pub const PhyDagControlCck = packed struct(u32) {
    _0: u9 = 0,
    enable_rssi_threshold: bool = false,
    rssi_threshold: u7 = 0,
    _17: u15 = 0,
};

pub const PhyRfBus = packed struct(u32) {
    granted: bool = false,
    _1: u31 = 0,

    pub const request = PhyRfBus{ .granted = true };
};

/// The register the reference polls after activating the baseband.
pub const PhyBasebandReady = packed struct(u32) {
    _0: u4 = 0,
    busy: bool = false,
    _5: u27 = 0,
};

/// The revision the baseband reports. Compared as a number: each revision
/// carries the ones before it.
pub const PhyRevision = struct {
    pub const rev2: u8 = 0x42;
    pub const rev3: u8 = 0x43;
    pub const rev4: u8 = 0x44;
};

pub const PhyRadioRevision = packed struct(u32) {
    _0: u24 = 0,
    value: u8 = 0,
};

// ---------------------------------------------------------------------------
// The pins: every packed struct against the reference's mask
// ---------------------------------------------------------------------------

fn pinLayout(comptime Word: type, comptime word: Word, comptime expected: u32) void {
    if (@as(u32, @bitCast(word)) != expected) {
        @compileError("the " ++ @typeName(Word) ++ " layout drifted from the reference");
    }
}

comptime {
    pinLayout(Control, .{ .rx_enable = true }, 0x0000_0004);
    pinLayout(Control, .{ .rx_disable = true }, 0x0000_0020);
    pinLayout(Config, .{ .adhoc_indication = true }, 0x0000_0020);
    pinLayout(Config, .{ .phy_ok = true }, 0x0000_0100);
    pinLayout(InterruptEnable, .{ .enabled = true }, 0x0000_0001);
    pinLayout(Interrupts, .{ .rx_ok = true }, 0x0000_0001);
    pinLayout(Interrupts, .{ .rx_overrun = true }, 0x0000_0020);
    pinLayout(Interrupts, .{ .tx_ok = true }, 0x0000_0040);
    pinLayout(Interrupts, .{ .tx_underrun = true }, 0x0000_0800);
    pinLayout(Interrupts, .{ .mib = true }, 0x0000_1000);
    pinLayout(Interrupts, .{ .rx_phy_error = true }, 0x0000_4000);
    pinLayout(Interrupts, .{ .beacon_alert = true }, 0x0001_0000);
    pinLayout(Interrupts, .{ .beacon_missed = true }, 0x0004_0000);
    pinLayout(Interrupts, .{ .bus_error = true }, 0x0008_0000);
    pinLayout(Interrupts, .{ .beacon_misc = true }, 0x0080_0000);
    pinLayout(Interrupts, .{ .gpio = true }, 0x0100_0000);
    pinLayout(Interrupts, .{ .queue_trigger = true }, 0x0800_0000);
    pinLayout(InterruptsS2, .{ .master_abort = true }, 0x0001_0000);
    pinLayout(InterruptsS2, .{ .parity_error = true }, 0x0004_0000);
    pinLayout(InterruptsS2, .{ .tim = true }, 0x0100_0000);
    pinLayout(InterruptsS2, .{ .tbtt = true }, 0x8000_0000);
    pinLayout(RxConfig, .{ .zero_length_dma = true }, 0x0000_0010);
    pinLayout(MibControl, .{ .freeze = true, .clear = true }, 0x0000_0006);
    pinLayout(QueueMask, QueueMask.all, 0x0000_03FF);
    pinLayout(QueueStatus, .{ .pending_frames = 3 }, 0x0000_0003);
    pinLayout(ResetControl, .{ .mac = true, .baseband = true, .pci = true }, 0x0000_0013);
    pinLayout(SleepControl, .{ .enable = .sleep }, 0x0001_0000);
    pinLayout(SleepControl, .{ .enable = .normal }, 0x0002_0000);
    pinLayout(SleepControl, .{ .mib_interrupt = true }, 0x0020_0000);
    pinLayout(SleepControl, .{ .unknown = true }, 0x0040_0000);
    pinLayout(InterruptPending, .{ .pending = true }, 0x0000_0001);
    pinLayout(PciConfig, .{ .sleep_clock_select = 1 }, 0x0000_0002);
    pinLayout(PciConfig, .{ .eeprom_size = .failed }, 0x0000_0018);
    pinLayout(PciConfig, .{ .led_control = .associated }, 0x0000_0040);
    pinLayout(PciConfig, .{ .retry_fix_enable = true }, 0x0000_1000);
    pinLayout(PciConfig, .{ .powered_down = true }, 0x0001_0000);
    pinLayout(PciConfig, .{ .led_mode = 7 }, 0x000E_0000);
    pinLayout(PciConfig, .{ .led_blink = 7 }, 0x0070_0000);
    pinLayout(PciConfig, .{ .led_slow = true }, 0x0080_0000);
    pinLayout(PciConfig, .{ .sleep_clock_rate = 3 }, 0x0300_0000);
    pinLayout(GpioControl, .{ .pin1 = .output }, 0x0000_000C);
    pinLayout(GpioControl, .{ .interrupt_pin = 7 }, 0x0000_7000);
    pinLayout(GpioControl, .{ .interrupt_enable = true }, 0x0000_8000);
    pinLayout(GpioControl, .{ .interrupt_when_high = true }, 0x0001_0000);
    pinLayout(SiliconRevision, .{ .version = .ar2425 }, 0x0000_00E0);
    pinLayout(SiliconRevision, .{ .revision = 0xF }, 0x0000_000F);
    pinLayout(EepromCommand, .{ .read = true }, 0x0000_0001);
    pinLayout(EepromStatus, .{ .read_complete = true }, 0x0000_0002);
    pinLayout(EepromStatus, .{ .read_error = true }, 0x0000_0001);
    pinLayout(StationIdHigh, .{ .access_point = true }, 0x0001_0000);
    pinLayout(StationIdHigh, .{ .power_save = true }, 0x0004_0000);
    pinLayout(StationIdHigh, .{ .use_default_antenna = true }, 0x0020_0000);
    pinLayout(StationIdHigh, .{ .rts_use_default_antenna = true }, 0x0080_0000);
    pinLayout(StationIdHigh, .{ .base_rate_11b = true }, 0x0200_0000);
    pinLayout(StationIdHigh, .{ .michael_enable = true }, 0x0800_0000);
    pinLayout(StationIdHigh, .{ .key_search_mode = true }, 0x1000_0000);
    pinLayout(BssIdHigh, .{ .association_id = 1 }, 0x0001_0000);
    pinLayout(RssiThreshold, RssiThreshold.initial, 0x0000_0781);
    pinLayout(Usec, .{ .usec32 = 0x7F }, 0x0000_3F80);
    pinLayout(Usec, .{ .tx_latency = 1 }, 0x0000_4000);
    pinLayout(Usec, .{ .rx_latency = 1 }, 0x0080_0000);
    pinLayout(BeaconControl, .{ .enable = true }, 0x0080_0000);
    pinLayout(BeaconControl, .{ .reset_tsf = true }, 0x0100_0000);
    pinLayout(RxFilter, .{ .beacon = true }, 0x0000_0010);
    pinLayout(RxFilter, .{ .phy_error = true }, 0x0000_0100);
    pinLayout(RxFilter, .{ .radar_error = true }, 0x0000_0200);
    pinLayout(PhyErrorFilter, .{ .radar = true }, 0x0000_0020);
    pinLayout(PhyErrorFilter, .{ .ofdm = true }, 0x0002_0000);
    pinLayout(PhyErrorFilter, .{ .cck = true }, 0x0200_0000);
    pinLayout(RxFilter, .{ .probe_request = true }, 0x0000_0080);
    pinLayout(Diagnostics, .{ .rx_disable = true }, 0x0000_0020);
    pinLayout(Diagnostics, .{ .scrambler_seed = 0x7F }, 0x0001_FC00);
    pinLayout(Diagnostics, .{ .phear_me = true }, 0x0080_0000);
    pinLayout(SelfPower, .{ .cts = 0x3F }, 0x0000_3F00);
    pinLayout(SelfPower, .{ .chirp = 0x3F }, 0x003F_0000);
    pinLayout(NoAck, .{ .bit_offset = 7 }, 0x0000_0070);
    pinLayout(NoAck, .{ .byte_offset = 3 }, 0x0000_0180);
    pinLayout(PhyTest, PhyTest.analog_access, 0x0000_0007);
    pinLayout(PhyTest, .{ .rf_silence = true }, 0x0000_2000);
    pinLayout(PhyTurbo, .{ .turbo_mode = true, .short_symbols = true }, 0x0000_0003);
    pinLayout(PhyTestControl, PhyTestControl.hold_tx, 0x0000_3800);
    pinLayout(PhyTiming3, .{ .delta_slope_exponent = 0xF }, 0x0001_E000);
    pinLayout(PhyTiming3, .{ .delta_slope_mantissa = 0x7FFF }, 0xFFFE_0000);
    pinLayout(PhyActive, .{ .enable = true }, 0x0000_0001);
    pinLayout(PhyAdcControl, .{ .off_power_down_dac = true }, 0x0000_2000);
    pinLayout(PhyAdcControl, .{ .off_power_down_adc = true }, 0x0000_8000);
    pinLayout(PhyAdcControl, .{ .on_input_buffer_gain = 3 }, 0x0003_0000);
    pinLayout(PhySettling, .{ .switch_settling = 0x7F }, 0x0000_3F80);
    pinLayout(PhyRxGain, .{ .txrx_attenuation = 0x3F }, 0x0003_F000);
    pinLayout(PhyDesiredSize, .{ .pga = -1 }, 0x0000_FF00);
    pinLayout(PhyAgcControl, .{ .calibrate = true, .noise_floor = true }, 0x0000_0003);
    pinLayout(PhyAgcControl, .{ .enable_noise_floor = true }, 0x0000_8000);
    pinLayout(PhyAgcControl, .{ .no_update_noise_floor = true }, 0x0002_0000);
    pinLayout(PhyCca, .{ .threshold62 = 0x7F }, 0x0007_F000);
    pinLayout(PhyCca, .{ .noise_floor = -1 }, 0x0FF8_0000);
    pinLayout(PhyCca, .{ .max_cca_power = -50 }, (@as(u32, 0x1FF) & (@as(u32, @bitCast(@as(i32, -50))) << 1)));
    pinLayout(PhyRxDelay, .{ .delay = 0x3FFF }, 0x0000_3FFF);
    pinLayout(PhyTimingControl4, .{ .iq_correction_q = -1 }, 0x0000_001F);
    pinLayout(PhyTimingControl4, .{ .iq_correction_i = -1 }, 0x0000_07E0);
    pinLayout(PhyTimingControl4, .{ .iq_correction_enable = true }, 0x0000_0800);
    pinLayout(PhyTimingControl4, .{ .iq_calibration_log_count = 0xF }, 0x0000_F000);
    pinLayout(PhyTimingControl4, .{ .do_iq_calibration = true }, 0x0001_0000);
    pinLayout(PhyTiming5, .{ .cycle_power_threshold1 = 0x7F }, 0x0000_00FE);
    pinLayout(PhyTxPowerAdjust, .{ .cck_gain_delta = -1 }, 0x0000_0FC0);
    pinLayout(PhyTxPowerAdjust, .{ .cck_pcdac_index = -1 }, 0x00FC_0000);
    pinLayout(PhyAntennaControl, .{ .enable = true, .antenna_control = 0x3F }, 0x0000_03F1);
    pinLayout(PhyAntennaSwitch, .{ .s5 = 0x3F }, 0x3F00_0000);
    pinLayout(PhyNoiseFloorThreshold, .{ .enable = true }, 0x0000_0200);
    pinLayout(PhyXpa, .{ .end_to_xpa_off_a = 0xFF }, 0x00FF_0000);
    pinLayout(PhyXlna, .{ .end_to_xlna_on = 0xFF }, 0x0000_FF00);
    pinLayout(PhyMode, .{ .cck = true, .rf_2ghz = true, .dynamic = true, .radio_5112 = true }, 0x0000_000F);
    pinLayout(PhyMode, .{ .dynamic_cck_disable = true }, 0x0000_0100);
    pinLayout(PhyCckTxControl, .{ .japan = true }, 0x0000_0010);
    pinLayout(PhyCckDetect, .{ .fast_diversity = true }, 0x0000_2000);
    pinLayout(PhyGain2GHz, .{ .rxtx_margin = 0x3F }, 0x00FC_0000);
    pinLayout(PhyDagControlCck, .{ .enable_rssi_threshold = true }, 0x0000_0200);
    pinLayout(PhyDagControlCck, .{ .rssi_threshold = 0x7F }, 0x0001_FC00);
    pinLayout(PhyRfBus, PhyRfBus.request, 0x0000_0001);
    pinLayout(PhyBasebandReady, .{ .busy = true }, 0x0000_0010);
    pinLayout(PhyRadioRevision, .{ .value = 0xFF }, 0xFF00_0000);
}
