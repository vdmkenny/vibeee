//! The Ensoniq AudioPCI ES1370's registers and the AK4531 codec beside it.
//!
//! Beside the driver so every shape, the clock arithmetic and the codec's
//! setup are checked on the build machine. Values from the datasheet as
//! Linux's ens1370 and ak4531 drivers carry them.

const std = @import("std");
const audio = @import("lib").audio;

/// The window's registers, a dword each.
pub const Register = enum(u16) {
    control = 0x00,
    status = 0x04,
    /// Which page the paged registers below show.
    page = 0x0C,
    codec = 0x10,
    serial = 0x20,
    dac2_count = 0x28,
    adc_count = 0x2C,
    paged_0 = 0x30,
    paged_1 = 0x34,
    paged_2 = 0x38,
    paged_3 = 0x3C,
};

/// The I/O ports the window spans.
pub const WINDOW_PORTS = 0x40;

pub const Page = enum(u4) {
    dac = 0xC,
    adc = 0xD,
    _,
};

/// The registers that live behind the page register.
pub const Paged = enum {
    dac2_frame,
    dac2_size,
    adc_frame,
    adc_size,
    /// Where the chip reads when no engine names a buffer. Left at zero,
    /// the chip can write to address zero.
    phantom_frame,
    phantom_size,

    pub fn page(self: Paged) Page {
        return switch (self) {
            .dac2_frame, .dac2_size => .dac,
            .adc_frame, .adc_size, .phantom_frame, .phantom_size => .adc,
        };
    }

    pub fn register(self: Paged) Register {
        return switch (self) {
            .adc_frame => .paged_0,
            .adc_size => .paged_1,
            .dac2_frame, .phantom_frame => .paged_2,
            .dac2_size, .phantom_size => .paged_3,
        };
    }
};

/// The two engines this driver runs, and which registers and bits are each
/// one's.
pub const Engine = enum {
    dac2,
    adc,

    pub fn frame(self: Engine) Paged {
        return switch (self) {
            .dac2 => .dac2_frame,
            .adc => .adc_frame,
        };
    }

    pub fn size(self: Engine) Paged {
        return switch (self) {
            .dac2 => .dac2_size,
            .adc => .adc_size,
        };
    }

    pub fn count(self: Engine) Register {
        return switch (self) {
            .dac2 => .dac2_count,
            .adc => .adc_count,
        };
    }
};

/// The one clock DAC2 and the ADC both divide.
pub const CLOCK_HZ: u32 = 1_411_200;

/// The divider that makes `rate` exactly, or none where no whole divider
/// does.
pub fn divider(rate: audio.Rate) ?u13 {
    const hertz = rate.hertz();
    if (CLOCK_HZ % hertz != 0) return null;
    return @intCast(CLOCK_HZ / hertz - 2);
}

pub const Control = packed struct(u32) {
    serr_disabled: bool = false,
    /// The serial interface to the codec.
    codec_enabled: bool = false,
    joystick_enabled: bool = false,
    uart_enabled: bool = false,
    adc_enabled: bool = false,
    dac2_enabled: bool = false,
    dac1_enabled: bool = false,
    test_mode: bool = false,
    line_out: bool = false,
    record_mpeg: bool = false,
    voice_interrupts: bool = false,
    dac_sync: bool = false,
    dac1_rate: u2 = 0,
    mpeg_clock: bool = false,
    mpeg_i2s: bool = false,
    /// Divides `CLOCK_HZ`, less two, for DAC2 and the ADC.
    clock_divider: u13 = 0,
    open: bool = false,
    mic_bias: bool = false,
    adc_stopped: bool = false,

    pub fn enable(self: *Control, engine: Engine, on: bool) void {
        switch (engine) {
            .dac2 => self.dac2_enabled = on,
            .adc => self.adc_enabled = on,
        }
    }

    pub fn enabled(self: Control, engine: Engine) bool {
        return switch (engine) {
            .dac2 => self.dac2_enabled,
            .adc => self.adc_enabled,
        };
    }
};

pub const Status = packed struct(u32) {
    adc: bool = false,
    dac2: bool = false,
    dac1: bool = false,
    uart: bool = false,
    voice: bool = false,
    voice_source: u2 = 0,
    _7: u1 = 0,
    codec_writing: bool = false,
    codec_busy: bool = false,
    /// A codec register write is under way.
    codec_pending: bool = false,
    _11: u20 = 0,
    /// Any of the above.
    interrupt: bool = false,

    pub fn fired(self: Status, engine: Engine) bool {
        return switch (engine) {
            .dac2 => self.dac2,
            .adc => self.adc,
        };
    }
};

/// How one engine's samples are laid out.
pub const Format = packed struct(u2) {
    stereo: bool = false,
    sixteen_bit: bool = false,

    pub const STEREO_16 = Format{ .stereo = true, .sixteen_bit = true };
};

/// The serial interface control register: each engine's format, interrupt,
/// pause and loop.
pub const Serial = packed struct(u32) {
    dac1_format: Format = .{},
    dac2_format: Format = .{},
    adc_format: Format = .{},
    /// DAC2 holds its last sample when disabled.
    dac2_hold: bool = false,
    dac1_reload: bool = false,
    dac1_interrupt: bool = false,
    dac2_interrupt: bool = false,
    adc_interrupt: bool = false,
    dac1_paused: bool = false,
    dac2_paused: bool = false,
    /// Stop at the end of the buffer rather than loop.
    dac1_stops: bool = false,
    dac2_stops: bool = false,
    adc_stops: bool = false,
    dac2_start_increment: u3 = 0,
    /// How far DAC2 steps at the end of a loop: two for sixteen bits.
    dac2_end_increment: u3 = 0,
    _22: u10 = 0,

    /// An engine looping over sixteen-bit stereo frames.
    pub fn stereo16(self: *Serial, engine: Engine) void {
        switch (engine) {
            .dac2 => {
                self.dac2_format = Format.STEREO_16;
                self.dac2_start_increment = 0;
                self.dac2_end_increment = 2;
                self.dac2_paused = false;
                self.dac2_stops = false;
            },
            .adc => {
                self.adc_format = Format.STEREO_16;
                self.adc_stops = false;
            },
        }
    }

    pub fn interrupt(self: *Serial, engine: Engine, on: bool) void {
        switch (engine) {
            .dac2 => self.dac2_interrupt = on,
            .adc => self.adc_interrupt = on,
        }
    }

    /// This register with the interrupts `status` reports turned off, which
    /// written and then followed by the register itself acknowledges them.
    pub fn quieted(self: Serial, status: Status) Serial {
        var quiet = self;
        for ([_]Engine{ .dac2, .adc }) |engine| {
            if (status.fired(engine)) quiet.interrupt(engine, false);
        }
        return quiet;
    }
};

/// A sample count register: how many frames between interrupts, less one,
/// and how many are left.
pub const Count = packed struct(u32) {
    frames_less_one: u16 = 0,
    left: u16 = 0,
};

/// A frame size register: the buffer in dwords, less one, and where in it
/// the engine is.
pub const FrameSize = packed struct(u32) {
    dwords_less_one: u16 = 0,
    at_dword: u16 = 0,

    pub fn of(bytes: usize) FrameSize {
        return .{ .dwords_less_one = @intCast(bytes / 4 - 1) };
    }

    /// Which period of `period_bytes` the engine is in.
    pub fn period(self: FrameSize, period_bytes: usize) u32 {
        return @intCast(@as(usize, self.at_dword) * 4 / period_bytes);
    }
};

comptime {
    if (@bitOffsetOf(Control, "clock_divider") != 16) @compileError("the clock divider is bits 28:16");
    if (@bitOffsetOf(Serial, "dac2_end_increment") != 19) @compileError("the DAC2 end increment is bits 21:19");
}

// ---------------------------------------------------------------------------
// The AK4531 codec
// ---------------------------------------------------------------------------

pub const CodecRegister = enum(u8) {
    master_left = 0x00,
    master_right = 0x01,
    voice_left = 0x02,
    voice_right = 0x03,
    line_left = 0x08,
    line_right = 0x09,
    mono_out = 0x0F,
    output_1 = 0x10,
    output_2 = 0x11,
    input_left_1 = 0x12,
    input_right_1 = 0x13,
    input_left_2 = 0x14,
    input_right_2 = 0x15,
    power = 0x16,
    clock = 0x17,
    adc_input = 0x18,
    mic_gain = 0x19,
    _,
};

/// The codec register write: which register, and its value.
pub const CodecWrite = packed struct(u16) {
    value: u8,
    register: CodecRegister,
};

/// A volume register: attenuation in steps of two decibels, and a mute.
pub const Level = packed struct(u8) {
    attenuation: u5 = 0,
    _5: u2 = 0,
    muted: bool = false,

    /// An input's level at unity: its zero is twelve decibels of gain.
    pub const INPUT_UNITY = Level{ .attenuation = 6 };
};

/// The master volume's steps, as the service's volume curve reads them.
pub const MASTER = audio.Attenuator{ .steps = 31, .quarter_db = 8 };

pub const Power = packed struct(u8) {
    /// Out of reset.
    running: bool = false,
    /// Powered up.
    powered: bool = false,
    _2: u6 = 0,
};

/// Output mixer switch 2: what reaches the line out.
pub const Output2 = packed struct(u8) {
    mono1: bool = false,
    mono2: bool = false,
    voice_right: bool = false,
    voice_left: bool = false,
    aux_right: bool = false,
    aux_left: bool = false,
    _6: u2 = 0,
};

/// Input mixer switch 1: what each side of the recording mixer takes.
pub const Input1 = packed struct(u8) {
    mic: bool = false,
    cd_right: bool = false,
    cd_left: bool = false,
    line_right: bool = false,
    line_left: bool = false,
    fm_right: bool = false,
    fm_left: bool = false,
    _7: u1 = 0,
};

fn write(register: CodecRegister, value: anytype) CodecWrite {
    return .{ .register = register, .value = @bitCast(value) };
}

/// Out of reset and powered, then the clock, then every register this
/// driver relies on: the DACs to the line out at unity, the master at full,
/// the line in to the recording mixer at unity, and the rest of the mixer
/// silent. The codec powers up with everything muted.
pub const SETUP = [_]CodecWrite{
    write(.power, Power{ .powered = true }),
    write(.power, Power{ .powered = true, .running = true }),
    write(.clock, @as(u8, 0)),
    write(.master_left, Level{}),
    write(.master_right, Level{}),
    write(.voice_left, Level.INPUT_UNITY),
    write(.voice_right, Level.INPUT_UNITY),
    write(.line_left, Level.INPUT_UNITY),
    write(.line_right, Level.INPUT_UNITY),
    write(.mono_out, Level{ .attenuation = 7, .muted = true }),
    write(.output_1, @as(u8, 0)),
    write(.output_2, Output2{ .voice_left = true, .voice_right = true }),
    write(.input_left_1, Input1{ .line_left = true }),
    write(.input_right_1, Input1{ .line_right = true }),
    write(.input_left_2, @as(u8, 0)),
    write(.input_right_2, @as(u8, 0)),
    write(.adc_input, @as(u8, 0)),
    write(.mic_gain, @as(u8, 0)),
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn word(value: anytype) u32 {
    return @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(value))), @bitCast(value));
}

test "register words are the datasheet's" {
    try testing.expectEqual(@as(u32, 0x0000_0002), word(Control{ .codec_enabled = true }));
    try testing.expectEqual(@as(u32, 0x0000_0020), word(Control{ .dac2_enabled = true }));
    try testing.expectEqual(@as(u32, 0x0000_0010), word(Control{ .adc_enabled = true }));
    try testing.expectEqual(@as(u32, 0x1FFF_0000), word(Control{ .clock_divider = 0x1FFF }));
    try testing.expectEqual(@as(u32, 0x8000_0000), word(Control{ .adc_stopped = true }));
    try testing.expectEqual(@as(u32, 0x8000_0000), word(Status{ .interrupt = true }));
    try testing.expectEqual(@as(u32, 0x0000_0400), word(Status{ .codec_pending = true }));
    try testing.expectEqual(@as(u32, 0x0000_0002), word(Status{ .dac2 = true }));
    try testing.expectEqual(@as(u32, 0x0000_000C), word(Serial{ .dac2_format = Format.STEREO_16 }));
    try testing.expectEqual(@as(u32, 0x0000_0030), word(Serial{ .adc_format = Format.STEREO_16 }));
    try testing.expectEqual(@as(u32, 0x0000_0200), word(Serial{ .dac2_interrupt = true }));
    try testing.expectEqual(@as(u32, 0x0000_0400), word(Serial{ .adc_interrupt = true }));
    try testing.expectEqual(@as(u32, 0x0000_4000), word(Serial{ .dac2_stops = true }));
    try testing.expectEqual(@as(u32, 0x0010_0000), word(Serial{ .dac2_end_increment = 2 }));
    try testing.expectEqual(@as(u32, 0x0000_07FF), word(FrameSize.of(8192)));
    try testing.expectEqual(@as(u16, 0x1600 | 0x03), word(CodecWrite{ .register = .power, .value = 0x03 }));
}

test "the paged registers sit where the datasheet puts them" {
    try testing.expectEqual(Page.dac, Paged.dac2_frame.page());
    try testing.expectEqual(Register.paged_2, Paged.dac2_frame.register());
    try testing.expectEqual(Register.paged_3, Paged.dac2_size.register());
    try testing.expectEqual(Page.adc, Paged.adc_frame.page());
    try testing.expectEqual(Register.paged_0, Paged.adc_frame.register());
    try testing.expectEqual(Page.adc, Paged.phantom_frame.page());
    try testing.expectEqual(Register.paged_2, Paged.phantom_frame.register());
}

test "each engine names its own registers and bits" {
    var serial = Serial{};
    serial.stereo16(.dac2);
    serial.interrupt(.dac2, true);
    try testing.expectEqual(@as(u32, 0x0010_020C), word(serial));
    serial.stereo16(.adc);
    serial.interrupt(.adc, true);
    serial.interrupt(.dac2, false);
    try testing.expectEqual(@as(u32, 0x0010_043C), word(serial));

    var control = Control{};
    control.enable(.adc, true);
    try testing.expect(control.enabled(.adc) and !control.enabled(.dac2));
    try testing.expect((Status{ .dac2 = true }).fired(.dac2));
    try testing.expectEqual(Paged.adc_size, Engine.adc.size());
    try testing.expectEqual(Register.dac2_count, Engine.dac2.count());
}

test "an interrupt is acknowledged by quieting only the engines that raised it" {
    var serial = Serial{};
    serial.stereo16(.dac2);
    serial.interrupt(.dac2, true);
    serial.interrupt(.adc, true);
    const quiet = serial.quieted(.{ .interrupt = true, .dac2 = true });
    try testing.expect(!quiet.dac2_interrupt and quiet.adc_interrupt);
    try testing.expectEqual(serial.dac2_format, quiet.dac2_format);
    try testing.expectEqual(serial, serial.quieted(.{}));
}

test "the clock divides to 44.1 kHz exactly and to 48 kHz not at all" {
    try testing.expectEqual(@as(?u13, 30), divider(.hz44100));
    try testing.expectEqual(@as(?u13, 62), divider(.hz22050));
    try testing.expectEqual(@as(?u13, null), divider(.hz48000));
    try testing.expectEqual(@as(?u13, null), divider(.hz8000));
}

test "an engine's place in its buffer names the period it is in" {
    const at: FrameSize = @bitCast(@as(u32, (300 << 16) | 2047));
    try testing.expectEqual(@as(u32, 1), at.period(1024));
    try testing.expectEqual(@as(u32, 0), (FrameSize{ .at_dword = 255 }).period(1024));
    try testing.expectEqual(@as(u32, 1), (FrameSize{ .at_dword = 256 }).period(1024));
}

test "the codec is set up as Linux's driver sets it, with the mixer routed" {
    const expected = [_]u16{
        0x1602, 0x1603, 0x1700,
        0x0000, 0x0100, 0x0206,
        0x0306, 0x0806, 0x0906,
        0x0F87, 0x1000, 0x110C,
        0x1210, 0x1308, 0x1400,
        0x1500, 0x1800, 0x1900,
    };
    try testing.expectEqual(expected.len, SETUP.len);
    for (expected, SETUP) |want, got| try testing.expectEqual(want, word(got));
}
