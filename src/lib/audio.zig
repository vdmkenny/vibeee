//! Sound, as numbers: what a sample is, how many of them a duration is,
//! and how loud they should be.
//!
//! Pure and host-tested. The service, the drivers and the tools all reason
//! about frames and periods, and doing that arithmetic in one place is what
//! keeps a buffer size, a period count and a duration from disagreeing.

const std = @import("std");

/// How one sample is stored. Sixteen-bit signed, little endian, which is
/// what every codec here converts and what every client produces.
pub const Format = enum(u8) {
    s16le = 0,

    pub fn bytesPerSample(self: Format) usize {
        return switch (self) {
            .s16le => 2,
        };
    }
};

/// The sample rates a stream may run at. Named rather than free, because a
/// codec accepts a set and a rate outside it is a configuration mistake
/// rather than something to resample silently.
pub const Rate = enum(u32) {
    hz8000 = 8000,
    hz16000 = 16000,
    hz22050 = 22050,
    hz44100 = 44100,
    hz48000 = 48000,
    _,

    pub fn hertz(self: Rate) u32 {
        return @intFromEnum(self);
    }

    pub fn of(hertz_value: u32) ?Rate {
        return switch (hertz_value) {
            8000, 16000, 22050, 44100, 48000 => @enumFromInt(hertz_value),
            else => null,
        };
    }
};

/// A stream's shape: how fast, how many channels, in what format. One
/// frame is one sample per channel, which is the unit everything above the
/// driver counts in.
pub const Shape = struct {
    rate: Rate = .hz48000,
    channels: u8 = 2,
    format: Format = .s16le,

    pub fn bytesPerFrame(self: Shape) usize {
        return self.format.bytesPerSample() * self.channels;
    }

    pub fn framesPerMs(self: Shape, ms: u32) usize {
        return (@as(usize, self.rate.hertz()) * ms) / 1000;
    }

    pub fn bytesPerMs(self: Shape, ms: u32) usize {
        return self.framesPerMs(ms) * self.bytesPerFrame();
    }

    /// How long a run of frames lasts, in milliseconds.
    pub fn msOfFrames(self: Shape, frames: usize) u32 {
        if (self.rate.hertz() == 0) return 0;
        return @intCast((frames * 1000) / self.rate.hertz());
    }

    pub fn valid(self: Shape) bool {
        return (self.channels == 1 or self.channels == 2) and Rate.of(self.rate.hertz()) != null;
    }
};

/// Loudness as a whole number of percent, which is what a tool prints, a
/// setting stores and a hardware step map is built against.
pub const Volume = struct {
    percent: u8 = 100,
    muted: bool = false,

    pub fn clamp(percent: u32) Volume {
        return .{ .percent = @intCast(@min(percent, 100)) };
    }

    /// One sample scaled in software. Fixed point over a percentage, which
    /// on this class of machine costs a multiply and a shift per sample and
    /// keeps the mixing path free of floating point entirely.
    pub fn apply(self: Volume, sample: i16) i16 {
        if (self.muted or self.percent == 0) return 0;
        if (self.percent >= 100) return sample;
        const scaled = @divTrunc(@as(i32, sample) * @as(i32, self.percent), 100);
        return @intCast(scaled);
    }

    /// Which of a codec's amplifier steps this percentage names. Codecs
    /// differ in how many steps they have, so the map is built from the
    /// step count the codec reports rather than from a constant.
    pub fn stepOf(self: Volume, steps: u8) u8 {
        if (steps == 0) return 0;
        const scaled = (@as(u32, self.percent) * steps) / 100;
        return @intCast(@min(scaled, steps));
    }
};

/// Two samples added without wrapping. Mixing that wraps turns a loud
/// moment into a click, which is worse than the clipping this does.
pub fn mix(a: i16, b: i16) i16 {
    const sum = @as(i32, a) + @as(i32, b);
    return @intCast(std.math.clamp(sum, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// A sine, generated a sample at a time from a fixed-point phase.
///
/// The one signal this system can make without a file, so it is what a
/// test tone and a notification beep are both built from. No floating
/// point: a quarter-wave table and linear interpolation between its
/// entries is inaudible from the real thing at these amplitudes and costs
/// an add and a lookup per sample.
pub const Tone = struct {
    /// Phase as a fraction of a full turn, in sixteen bits.
    phase: u16 = 0,
    /// How far the phase advances per frame.
    step: u16 = 0,
    amplitude: i16 = 8000,

    pub fn at(hertz: u32, shape: Shape, amplitude: i16) Tone {
        const turns = (@as(u64, hertz) << 16) / @max(1, shape.rate.hertz());
        return .{ .step = @truncate(turns), .amplitude = amplitude };
    }

    pub fn next(self: *Tone) i16 {
        const value = sine(self.phase);
        self.phase +%= self.step;
        const scaled = (@as(i32, value) * @as(i32, self.amplitude)) >> 15;
        return @intCast(scaled);
    }

    /// Fill a buffer of interleaved frames with this tone on every channel.
    pub fn fill(self: *Tone, into: []u8, shape: Shape) void {
        const frame_bytes = shape.bytesPerFrame();
        var cursor: usize = 0;
        while (cursor + frame_bytes <= into.len) : (cursor += frame_bytes) {
            const sample = self.next();
            var channel: usize = 0;
            while (channel < shape.channels) : (channel += 1) {
                const offset = cursor + channel * 2;
                std.mem.writeInt(i16, into[offset..][0..2], sample, .little);
            }
        }
    }
};

/// A quarter turn of a sine, in sixteen steps, at full scale. The other
/// three quarters are this one mirrored and negated, which is what keeps
/// the table small enough to sit in a driver.
const quarter = [17]i16{
    0,     3212,  6393,  9512,  12539, 15446, 18204, 20787,
    23170, 25330, 27245, 28898, 30273, 31357, 32138, 32610,
    32767,
};

/// The sine of a phase given as a fraction of a turn.
///
/// The quarter table read forwards climbs from zero to the peak and read
/// backwards falls again, so all four quarters are that one table with the
/// direction and the sign chosen between them.
fn sine(phase: u16) i16 {
    const quadrant: u2 = @truncate(phase >> 14);
    const within: u14 = @truncate(phase);
    const climbing = quadrant == 0 or quadrant == 2;
    const at: u14 = if (climbing) within else ~within;

    const value = interpolate(at);
    return if (quadrant < 2) value else -value;
}

/// A point between two table entries: sixteen intervals across a quarter
/// turn, straight lines between them.
fn interpolate(at: u14) i16 {
    const index = at >> 10;
    const fraction: i32 = at & 0x3FF;
    const from: i32 = quarter[index];
    const to: i32 = quarter[index + 1];
    return @intCast(from + @divTrunc((to - from) * fraction, 1024));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "a shape counts frames, bytes and milliseconds consistently" {
    const stereo = Shape{ .rate = .hz48000, .channels = 2 };
    try std.testing.expectEqual(@as(usize, 4), stereo.bytesPerFrame());
    try std.testing.expectEqual(@as(usize, 480), stereo.framesPerMs(10));
    try std.testing.expectEqual(@as(usize, 1920), stereo.bytesPerMs(10));
    try std.testing.expectEqual(@as(u32, 10), stereo.msOfFrames(480));

    const mono = Shape{ .rate = .hz8000, .channels = 1 };
    try std.testing.expectEqual(@as(usize, 2), mono.bytesPerFrame());
    try std.testing.expectEqual(@as(usize, 80), mono.framesPerMs(10));
}

test "only shapes a codec can carry are valid" {
    try std.testing.expect((Shape{}).valid());
    try std.testing.expect(!(Shape{ .channels = 3 }).valid());
    try std.testing.expect(!(Shape{ .rate = @enumFromInt(37000) }).valid());
    try std.testing.expectEqual(@as(?Rate, Rate.hz44100), Rate.of(44100));
    try std.testing.expectEqual(@as(?Rate, null), Rate.of(12345));
}

test "volume scales, mutes and maps onto a codec's own steps" {
    const full = Volume{ .percent = 100 };
    try std.testing.expectEqual(@as(i16, 1000), full.apply(1000));

    const half = Volume{ .percent = 50 };
    try std.testing.expectEqual(@as(i16, 500), half.apply(1000));
    try std.testing.expectEqual(@as(i16, -500), half.apply(-1000));

    const off = Volume{ .percent = 50, .muted = true };
    try std.testing.expectEqual(@as(i16, 0), off.apply(1000));

    // A codec with sixty-four steps, asked for three quarters.
    try std.testing.expectEqual(@as(u8, 48), (Volume{ .percent = 75 }).stepOf(64));
    try std.testing.expectEqual(@as(u8, 64), full.stepOf(64));
    try std.testing.expectEqual(@as(u8, 0), (Volume{ .percent = 0 }).stepOf(64));
}

test "mixing clips instead of wrapping" {
    try std.testing.expectEqual(@as(i16, 300), mix(100, 200));
    try std.testing.expectEqual(@as(i16, 32767), mix(30000, 30000));
    try std.testing.expectEqual(@as(i16, -32768), mix(-30000, -30000));
}

test "a tone is a sine of the frequency asked for" {
    const shape = Shape{ .rate = .hz48000, .channels = 2 };
    var tone = Tone.at(1000, shape, 32767);

    // A thousand cycles a second at forty-eight thousand frames a second
    // is forty-eight frames per cycle: the wave must cross zero going up
    // at the start of each one.
    var samples: [96]i16 = undefined;
    for (&samples) |*sample| sample.* = tone.next();

    try std.testing.expectEqual(@as(i16, 0), samples[0]);
    // A quarter cycle in, at its peak; three quarters in, at its trough.
    try std.testing.expect(samples[12] > 30000);
    try std.testing.expect(samples[36] < -30000);
    // And back to the start after a full cycle.
    try std.testing.expect(@abs(samples[48]) < 2000);
}

test "a tone fills every channel of every frame" {
    const shape = Shape{ .rate = .hz48000, .channels = 2 };
    var tone = Tone.at(1000, shape, 32767);
    var buffer: [64]u8 = @splat(0);
    tone.fill(&buffer, shape);

    // Both channels of one frame carry the same sample.
    var frame: usize = 0;
    while (frame < buffer.len / 4) : (frame += 1) {
        const left = std.mem.readInt(i16, buffer[frame * 4 ..][0..2], .little);
        const right = std.mem.readInt(i16, buffer[frame * 4 + 2 ..][0..2], .little);
        try std.testing.expectEqual(left, right);
    }

    // And the buffer is not silence.
    var loudest: i16 = 0;
    frame = 0;
    while (frame < buffer.len / 4) : (frame += 1) {
        const sample = std.mem.readInt(i16, buffer[frame * 4 ..][0..2], .little);
        if (@abs(sample) > @abs(loudest)) loudest = sample;
    }
    try std.testing.expect(@abs(loudest) > 10000);
}
