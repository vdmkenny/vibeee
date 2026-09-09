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

    /// Worked out in sixty-four bits, because a `usize` here is thirty-two:
    /// a rate times a duration in milliseconds passes four billion at a
    /// minute and a half of audio, and the answer would wrap.
    pub fn framesPerMs(self: Shape, ms: u32) usize {
        return @intCast((@as(u64, self.rate.hertz()) * ms) / 1000);
    }

    pub fn bytesPerMs(self: Shape, ms: u32) usize {
        return self.framesPerMs(ms) * self.bytesPerFrame();
    }

    /// How long a run of frames lasts, in milliseconds. In sixty-four bits
    /// for the same reason as `framesPerMs`.
    pub fn msOfFrames(self: Shape, frames: usize) u32 {
        if (self.rate.hertz() == 0) return 0;
        return @intCast((@as(u64, frames) * 1000) / self.rate.hertz());
    }

    pub fn valid(self: Shape) bool {
        return (self.channels == 1 or self.channels == 2) and Rate.of(self.rate.hertz()) != null;
    }
};

test "a duration long enough to pass four billion frame-hertz still converts" {
    const shape = Shape{ .rate = .hz48000, .channels = 2 };
    // A minute and a half at 48 kHz: the product of rate and milliseconds
    // is past what thirty-two bits hold.
    try std.testing.expectEqual(@as(usize, 48000 * 90), shape.framesPerMs(90_000));
    try std.testing.expectEqual(@as(u32, 90_000), shape.msOfFrames(48000 * 90));
}

/// What fraction of full scale a percentage is worth.
///
/// Loudness is heard on a log scale, so the fraction is cubed and the
/// slider reads as sixty decibels spread over its travel: half way is
/// eighteen decibels down, a quarter of the way thirty-six, a tenth sixty
/// and at the edge of hearing.
fn fractionOf(percent: usize) f64 {
    const part = @as(f64, @floatFromInt(percent)) / 100.0;
    return part * part * part;
}

/// Amplitude for every percentage below full, in `Amplitude.UNITY` fixed
/// point. Full is the identity and is not stored.
const amplitudes: [100]u16 = built: {
    var table: [100]u16 = undefined;
    for (&table, 0..) |*entry, percent| {
        entry.* = @intFromFloat(@round(fractionOf(percent) * @as(f64, Amplitude.UNITY)));
    }
    break :built table;
};

/// Attenuation for every percentage below full, in quarter decibels.
/// Percent zero is silence rather than an attenuation, and is never read.
const attenuations: [100]u16 = built: {
    var table: [100]u16 = undefined;
    table[0] = std.math.maxInt(u16);
    for (table[1..], 1..) |*entry, percent| {
        entry.* = @intFromFloat(@round(-80.0 * @log10(fractionOf(percent))));
    }
    break :built table;
};

/// A volume resolved to a multiplier. Taking it once lifts the percentage
/// out of the loop that uses it.
pub const Amplitude = enum(u32) {
    silent = 0,
    unity = UNITY,
    _,

    /// Full scale. Sixteen fraction bits keeps a scaled sample inside a
    /// thirty-two bit multiply.
    pub const UNITY: u32 = 1 << BITS;
    const BITS: u5 = 16;

    /// One sample scaled.
    pub fn apply(self: Amplitude, sample: i16) i16 {
        return switch (self) {
            .silent => 0,
            .unity => sample,
            _ => scaled(sample, @intCast(@intFromEnum(self))),
        };
    }
};

/// One sample against a factor already taken off an amplitude. A multiply
/// and a shift, no floating point.
inline fn scaled(sample: i16, factor: i32) i16 {
    return @intCast((@as(i32, sample) * factor) >> Amplitude.BITS);
}

/// A codec's own attenuator, as the part reports it.
pub const Attenuator = struct {
    /// The loudest step. Zero is the quietest.
    steps: u8 = 0,
    /// What one step is worth, in quarter decibels.
    quarter_db: u8 = 0,
};

/// Loudness as a whole number of percent, which is what a tool prints, a
/// setting stores and a hardware step map is built against.
pub const Volume = struct {
    percent: u8 = 100,
    muted: bool = false,

    pub fn clamp(percent: u32) Volume {
        return .{ .percent = @intCast(@min(percent, 100)) };
    }

    /// The multiplier this volume asks for.
    pub fn amplitude(self: Volume) Amplitude {
        if (self.muted or self.percent == 0) return .silent;
        if (self.percent >= 100) return .unity;
        return @enumFromInt(amplitudes[self.percent]);
    }

    /// Which of an attenuator's steps sits closest to the attenuation this
    /// volume asks for. Both sides of the percentage come off the one
    /// curve, so a hardware attenuator and a software multiplier land on
    /// the same loudness.
    pub fn stepOf(self: Volume, attenuator: Attenuator) u8 {
        if (attenuator.steps == 0 or attenuator.quarter_db == 0) return 0;
        if (self.muted or self.percent == 0) return 0;
        if (self.percent >= 100) return attenuator.steps;

        const per_step: u32 = attenuator.quarter_db;
        const wanted = (attenuations[self.percent] + per_step / 2) / per_step;
        return attenuator.steps - @as(u8, @intCast(@min(wanted, attenuator.steps)));
    }
};

/// Scale every sample into `out`, which is a different buffer of at least
/// the same length.
pub fn scale(by: Amplitude, samples: []const i16, out: []i16) void {
    const into = out[0..samples.len];
    switch (by) {
        .silent => @memset(into, 0),
        .unity => @memcpy(into, samples),
        _ => {
            const factor: i32 = @intCast(@intFromEnum(by));
            for (into, samples) |*slot, sample| slot.* = scaled(sample, factor);
        },
    }
}

/// Add every sample, scaled, to what `out` already holds.
pub fn blend(by: Amplitude, samples: []const i16, out: []i16) void {
    const into = out[0..samples.len];
    switch (by) {
        .silent => {},
        .unity => for (into, samples) |*slot, sample| {
            slot.* = mix(slot.*, sample);
        },
        _ => {
            const factor: i32 = @intCast(@intFromEnum(by));
            for (into, samples) |*slot, sample| slot.* = mix(slot.*, scaled(sample, factor));
        },
    }
}

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
        return @intCast((@as(i32, value) * @as(i32, self.amplitude)) >> 15);
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
///
/// Public because a sine is a sine: a tone is made of one, and so is the
/// wobble a tracker puts on a note, and the second of those should not
/// carry a table of its own.
pub fn sine(phase: u16) i16 {
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

test "a volume resolves to a multiplier on the loudness curve" {
    const full = Volume{ .percent = 100 };
    try std.testing.expectEqual(Amplitude.unity, full.amplitude());
    try std.testing.expectEqual(@as(i16, 1000), full.amplitude().apply(1000));

    // Half the slider is an eighth of the amplitude, eighteen decibels down.
    const half = (Volume{ .percent = 50 }).amplitude();
    try std.testing.expectEqual(@as(i16, 125), half.apply(1000));
    try std.testing.expectEqual(@as(i16, -125), half.apply(-1000));

    try std.testing.expectEqual(Amplitude.silent, (Volume{ .percent = 50, .muted = true }).amplitude());
    try std.testing.expectEqual(Amplitude.silent, (Volume{ .percent = 0 }).amplitude());
    try std.testing.expectEqual(@as(i16, 0), Amplitude.silent.apply(1000));
}

test "the curve rises without a flat or a backward step" {
    // One percent is a hundred and twenty decibels down, below what the
    // fixed point holds.
    try std.testing.expectEqual(Amplitude.silent, (Volume{ .percent = 1 }).amplitude());

    var last: u32 = 0;
    for (2..100) |percent| {
        const here = @intFromEnum((Volume{ .percent = @intCast(percent) }).amplitude());
        try std.testing.expect(here > last);
        try std.testing.expect(here < Amplitude.UNITY);
        last = here;
    }
}

test "an attenuator lands on the same loudness the multiplier does" {
    // The AC97 master: sixty-three steps of one and a half decibels.
    const ac97 = Attenuator{ .steps = 0x3F, .quarter_db = 6 };

    try std.testing.expectEqual(@as(u8, 0x3F), (Volume{ .percent = 100 }).stepOf(ac97));
    try std.testing.expectEqual(@as(u8, 0), (Volume{ .percent = 0 }).stepOf(ac97));
    try std.testing.expectEqual(@as(u8, 0), (Volume{ .percent = 80, .muted = true }).stepOf(ac97));

    // Eighteen decibels down is twelve steps of one and a half.
    try std.testing.expectEqual(@as(u8, 0x3F - 12), (Volume{ .percent = 50 }).stepOf(ac97));
    // Sixty decibels down is forty.
    try std.testing.expectEqual(@as(u8, 0x3F - 40), (Volume{ .percent = 10 }).stepOf(ac97));
    // Past what the part can attenuate, so its quietest step.
    try std.testing.expectEqual(@as(u8, 0), (Volume{ .percent = 1 }).stepOf(ac97));

    // A finer part reaches the same loudness on more steps.
    const fine = Attenuator{ .steps = 0x4B, .quarter_db = 1 };
    try std.testing.expectEqual(@as(u8, 0x4B - 72), (Volume{ .percent = 50 }).stepOf(fine));

    // A part that reports nothing is left alone.
    try std.testing.expectEqual(@as(u8, 0), (Volume{ .percent = 50 }).stepOf(.{}));
}

test "a buffer scales and blends without consulting the percentage per sample" {
    const source = [_]i16{ 1000, -1000, 32767, -32768 };
    var out: [4]i16 = undefined;

    scale(.unity, &source, &out);
    try std.testing.expectEqualSlices(i16, &source, &out);

    scale(.silent, &source, &out);
    try std.testing.expectEqualSlices(i16, &[_]i16{ 0, 0, 0, 0 }, &out);

    const half = (Volume{ .percent = 50 }).amplitude();
    scale(half, &source, &out);
    for (out, source) |got, sample| try std.testing.expectEqual(half.apply(sample), got);

    // Blending adds to what is already there, and clips instead of wrapping.
    out = .{ 100, 100, 32767, -32768 };
    blend(.unity, &source, &out);
    try std.testing.expectEqualSlices(i16, &[_]i16{ 1100, -900, 32767, -32768 }, &out);

    out = .{ 100, 100, 100, 100 };
    blend(.silent, &source, &out);
    try std.testing.expectEqualSlices(i16, &[_]i16{ 100, 100, 100, 100 }, &out);
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

// ---------------------------------------------------------------------------
// How loud it actually is
//
// A volume is what was asked for; a level is what came out. Only the second
// tells you the machine is making a sound, which is the question somebody
// opens a meter to answer.
// ---------------------------------------------------------------------------

/// How far a sample is from silence, whichever side of it.
///
/// The most negative sample has no positive twin, so it is held at the
/// largest positive one rather than wrapping to itself: a meter that read
/// zero at full scale would be worse than one a count out.
pub fn magnitude(sample: i16) u16 {
    if (sample == std.math.minInt(i16)) return std.math.maxInt(i16);
    return @intCast(@abs(sample));
}

/// The loudest of one channel of an interleaved block, as a percentage of
/// full scale.
///
/// Peak rather than average: an average over a period is a number that
/// barely moves, and what a meter is watched for is the moment something
/// got loud.
pub fn level(samples: []const i16, channels: usize, channel: usize) u8 {
    if (channels == 0 or channel >= channels) return 0;

    var loudest: u16 = 0;
    var at = channel;
    while (at < samples.len) : (at += channels) {
        loudest = @max(loudest, magnitude(samples[at]));
    }
    return @intCast(@as(u32, loudest) * 100 / std.math.maxInt(i16));
}

/// A peak that falls back rather than sticking.
///
/// It rises to whatever it just heard and comes down a step at a time, so it
/// marks the loudest of the last moment rather than the loudest since the
/// machine was switched on.
pub fn falling(peak: u8, now: u8, step: u8) u8 {
    if (now >= peak) return now;
    return if (peak > step) peak - step else 0;
}

test "magnitude is the distance from silence, either way" {
    try std.testing.expectEqual(@as(u16, 0), magnitude(0));
    try std.testing.expectEqual(@as(u16, 1000), magnitude(1000));
    try std.testing.expectEqual(@as(u16, 1000), magnitude(-1000));
    // The one sample with no positive twin is held rather than wrapped.
    try std.testing.expectEqual(@as(u16, 32767), magnitude(-32768));
    try std.testing.expectEqual(@as(u16, 32767), magnitude(32767));
}

test "a level is the loudest of its own channel and no other" {
    // Interleaved: left quiet, right loud.
    const frames = [_]i16{ 0, 32767, 100, 20000, -50, 30000 };
    try std.testing.expectEqual(@as(u8, 0), level(&frames, 2, 0));
    try std.testing.expectEqual(@as(u8, 100), level(&frames, 2, 1));

    const silence = [_]i16{ 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u8, 0), level(&silence, 2, 0));

    // A channel that is not there, and a block that is not interleaved.
    try std.testing.expectEqual(@as(u8, 0), level(&frames, 2, 2));
    try std.testing.expectEqual(@as(u8, 0), level(&frames, 0, 0));
    try std.testing.expectEqual(@as(u8, 100), level(&frames, 1, 0));
}

test "half scale reads as about half" {
    const half = [_]i16{ 16383, 16383 };
    const reading = level(&half, 2, 0);
    try std.testing.expect(reading >= 48 and reading <= 51);
}

test "a peak rises at once and comes down a step at a time" {
    try std.testing.expectEqual(@as(u8, 80), falling(20, 80, 5));
    try std.testing.expectEqual(@as(u8, 75), falling(80, 10, 5));
    try std.testing.expectEqual(@as(u8, 70), falling(75, 10, 5));
    // And settles at silence rather than under it.
    try std.testing.expectEqual(@as(u8, 0), falling(3, 0, 5));
    try std.testing.expectEqual(@as(u8, 0), falling(0, 0, 5));
}

// ---------------------------------------------------------------------------
// Playing several sounds at once
//
// A stream carries one thing. A program that makes sounds rather than plays a
// file makes several at a time and has to add them together itself, and the
// adding is the same work whoever is doing it: read each source at whatever
// rate it was recorded, scale it for each ear, sum, and hand over one stream.
// ---------------------------------------------------------------------------

/// Where a voice's samples come from.
///
/// Kept in the shape the file had rather than widened on the way in. Sounds
/// recorded eight bits deep are what a game of that age ships, and widening
/// every one of them at load time spends the memory of the whole set at once
/// to save a subtraction per sample.
pub const Samples = union(enum) {
    /// Eight bits, unsigned, silence in the middle of the range. What a
    /// wav file and a game's effects are stored as.
    unsigned_eight: []const u8,
    /// Eight bits, signed, silence at zero. What a tracker module and the
    /// hardware it was written for use.
    signed_eight: []const i8,
    /// Sixteen bits, signed. What everything else here uses.
    sixteen: []const i16,

    pub fn count(self: Samples) usize {
        return switch (self) {
            inline else => |s| s.len,
        };
    }

    /// The sample at `index`, as the rest of this module counts them.
    /// Silence past the end, so a caller that has not yet noticed a voice
    /// finished reads nothing rather than another voice's memory.
    pub fn at(self: Samples, index: usize) i16 {
        return switch (self) {
            .unsigned_eight => |s| if (index < s.len)
                (@as(i16, s[index]) - 128) << 8
            else
                0,
            .signed_eight => |s| if (index < s.len) @as(i16, s[index]) << 8 else 0,
            .sixteen => |s| if (index < s.len) s[index] else 0,
        };
    }
};

/// How loud a voice is on one side, in two hundred and fifty-sixths.
///
/// Full is 255 rather than 256 so the whole range fits a byte and silence
/// is zero. The loudest a voice can be is then a two hundred and
/// fifty-sixth under the sample it came from, a thirtieth of a decibel,
/// which is inaudible.
pub const Gain = u8;
pub const FULL_GAIN: Gain = 255;

/// How many bits of a source position are the fraction.
///
/// The position is counted in source samples, and a source recorded at a
/// rate the output does not divide advances by a fraction of one per
/// output frame. Sixteen bits of fraction put the error in a step at one
/// part in sixty-five thousand, which over the longest sound anybody plays
/// this way is a small part of one sample./// How many bits of a source position are the fraction.
///
/// The position is counted in source samples, and a source recorded at a
/// rate the output does not divide advances by a fraction of one per
/// output frame. Sixteen bits of fraction put the error in a step at one
/// part in sixty-five thousand, which over the longest sound anybody
/// plays this way is a small part of one sample.
const FRACTION_BITS: u5 = 16;
const FRACTION_ONE: u32 = 1 << FRACTION_BITS;

/// How many of those bits the line between two samples is drawn with.
///
/// Eight, so the multiply that draws it fits a thirty-two bit number: a
/// difference of two samples is seventeen bits and this is eight, where
/// the full fraction would be thirty-three and cost a wide multiply on
/// every sample of every voice. What it gives up is a two hundred and
/// fifty-sixth of the distance between two samples, which is a fraction
/// of the step rather than of the signal.
const BLEND_BITS: u5 = 8;

/// A position in a source, or a distance through one: whole samples and a
/// fraction of the next.
///
/// Two thirty-two bit halves rather than one sixty-four bit number. This
/// is added to for every frame of every voice, and on a thirty-two bit
/// machine a sixty-four bit add and shift are several instructions each
/// where these are one.
pub const Step = struct {
    whole: usize = 0,
    fraction: u32 = 0,

    /// Move on by `by`, carrying the fraction into the whole.
    pub fn advance(self: *Step, by: Step) void {
        self.fraction += by.fraction;
        self.whole += by.whole + (self.fraction >> FRACTION_BITS);
        self.fraction &= FRACTION_ONE - 1;
    }

    /// Move on by `frames` of it at once, for a voice nobody is listening
    /// to: a channel turned down still has to arrive where it would have
    /// been when it is turned back up.
    pub fn skip(self: *Step, by: Step, frames: usize) void {
        const fraction = @as(u64, by.fraction) * frames + self.fraction;
        self.whole += by.whole * frames + @as(usize, @intCast(fraction >> FRACTION_BITS));
        self.fraction = @intCast(fraction & (FRACTION_ONE - 1));
    }
};

/// A position `sample` samples into a source, for a voice that starts
/// somewhere other than the beginning.
pub fn position(sample: usize) Step {
    return .{ .whole = sample };
}

/// How far a source advances per output frame.
///
/// Worked out in sixty-four bits and split once: a rate shifted by sixteen
/// passes what thirty-two hold above about sixty-five kilohertz, and a
/// rate is configurable. Nothing on the sample path is that wide.
pub fn stepFor(from: u32, to: u32) Step {
    if (to == 0) return .{ .whole = 1 };
    const fixed = (@as(u64, from) << FRACTION_BITS) / to;
    return .{
        .whole = @intCast(fixed >> FRACTION_BITS),
        .fraction = @intCast(fixed & (FRACTION_ONE - 1)),
    };
}

/// One sound being played: where it is, how fast it moves, how loud.
pub const Voice = struct {
    samples: Samples,
    /// Where the next output frame is read from.
    at: Step = .{},
    /// How far it moves per output frame.
    step: Step = .{ .whole = 1 },
    left: Gain = FULL_GAIN,
    right: Gain = FULL_GAIN,
    /// Whether reaching the end starts it again rather than ending it.
    looping: bool = false,
    /// Where a looping voice goes back to, in source samples.
    ///
    /// Not always the start: an instrument is often an attack followed by
    /// a body that holds, and a note held for a while is that attack once
    /// and then the body over and over. What is past the end of `samples`
    /// is never played, so a source with a tail beyond its loop is handed
    /// over cut to the loop's end.
    loop_from: usize = 0,

    /// A voice reading `samples` recorded at `from` hertz and played into
    /// a stream running at `to`.
    pub fn resampled(samples: Samples, from: u32, to: u32) Voice {
        return .{ .samples = samples, .step = stepFor(from, to) };
    }

    /// Where this voice loops back to, held inside what it was given: a
    /// loop starting past the end is one with nothing in it, and the
    /// whole of the source is a better answer than none of it.
    fn loopStart(self: Voice, total: usize) usize {
        return if (self.loop_from < total) self.loop_from else 0;
    }

    /// Whether it has run off the end of what it was given.
    ///
    /// A voice with no samples is finished however it was asked to loop:
    /// going round nothing is not going round.
    pub fn finished(self: Voice) bool {
        const total = self.samples.count();
        if (total == 0) return true;
        return !self.looping and self.at.whole >= total;
    }

    /// Whether anything would be heard from it.
    pub fn silent(self: Voice) bool {
        return self.left == 0 and self.right == 0;
    }
};

/// A sum brought back to one sample, held at the ends rather than wrapped.
fn held(sum: i32) i16 {
    return @intCast(std.math.clamp(sum, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// One source sample as the mixing counts them, whatever it was stored as.
///
/// Written per element type rather than per union tag, so the loop that
/// calls it has already chosen which and does not ask again.
inline fn widened(value: anytype) i32 {
    return switch (@TypeOf(value)) {
        // Unsigned, silence in the middle of the range.
        u8 => (@as(i32, value) - 128) << 8,
        i8 => @as(i32, value) << 8,
        i16 => @as(i32, value),
        else => @compileError("a sample is eight or sixteen bits"),
    };
}

/// How many output frames are summed before they are brought back to
/// samples. Small enough to sit on a stack, large enough that choosing
/// which source a voice reads happens once for a great many samples.
const CHUNK_FRAMES = 256;

/// Several voices summed into one interleaved stereo stream.
///
/// The count is a compile-time number because it is a budget: a program
/// decides how many sounds may be going at once, and one that decided at
/// runtime would be one that allocates on the path a sound comes out of.
/// Voices are addressed by slot, so a caller can change or stop one it
/// started without keeping a handle to it.
pub fn Mixer(comptime slots: usize) type {
    return struct {
        const Self = @This();

        pub const count = slots;

        voices: [slots]?Voice = @splat(null),

        pub fn start(self: *Self, slot: usize, voice: Voice) void {
            if (slot >= slots) return;
            self.voices[slot] = voice;
        }

        pub fn stop(self: *Self, slot: usize) void {
            if (slot >= slots) return;
            self.voices[slot] = null;
        }

        pub fn stopAll(self: *Self) void {
            self.voices = @splat(null);
        }

        pub fn playing(self: *const Self, slot: usize) bool {
            if (slot >= slots) return false;
            return self.voices[slot] != null;
        }

        /// How loud a voice already playing is, on each side. Nothing when
        /// that slot is silent: a sound that finished is not made louder.
        pub fn setGain(self: *Self, slot: usize, left: Gain, right: Gain) void {
            if (slot >= slots) return;
            if (self.voices[slot]) |*voice| {
                voice.left = left;
                voice.right = right;
            }
        }

        /// How fast a voice already playing moves through its samples.
        /// For a caller that bends a note while it sounds: the position
        /// is kept, so the pitch changes without the sound restarting.
        pub fn setStep(self: *Self, slot: usize, step: Step) void {
            if (slot >= slots) return;
            if (self.voices[slot]) |*voice| voice.step = step;
        }

        /// The first slot with nothing in it, or none when all are busy.
        pub fn free(self: *const Self) ?usize {
            for (self.voices, 0..) |voice, slot| {
                if (voice == null) return slot;
            }
            return null;
        }

        /// Fill `out` with every voice summed, and forget the ones that
        /// finished doing it.
        ///
        /// `out` is interleaved stereo and is replaced rather than added
        /// to, so a caller need not clear it first.
        ///
        /// A chunk of frames at a time, and within a chunk a voice at a
        /// time. Which of the source shapes a voice reads is then chosen
        /// once for a few hundred samples rather than for every one of
        /// them, and the loop that reads it indexes an ordinary slice.
        /// The sum is held in a wider number until the chunk is done,
        /// since clipping each addition as it goes would turn a pair of
        /// loud sounds into a different sound.
        pub fn fill(self: *Self, out: []i16) void {
            var live: [slots]*Voice = undefined;
            var on: usize = 0;
            const frames = out.len / 2;

            for (&self.voices) |*maybe| {
                const voice = if (maybe.*) |*one| one else continue;
                if (voice.samples.count() == 0) continue;
                // A voice turned all the way down is moved on without
                // being read: it has to be where it would have been when
                // somebody turns it back up, and that is one multiply
                // rather than a pass over every sample.
                if (voice.silent()) {
                    voice.at.skip(voice.step, frames);
                    continue;
                }
                live[on] = voice;
                on += 1;
            }

            if (on == 0) {
                @memset(out, 0);
            } else {
                var done: usize = 0;
                while (done < out.len) {
                    const take = @min(out.len - done, CHUNK_FRAMES * 2);
                    var wide: [CHUNK_FRAMES * 2]i32 = @splat(0);
                    const summing = wide[0..take];

                    for (live[0..on]) |voice| add(voice, summing);
                    for (summing, out[done..][0..take]) |sum, *into| into.* = held(sum);
                    done += take;
                }
            }

            for (&self.voices) |*maybe| {
                if (maybe.*) |voice| {
                    if (voice.finished()) maybe.* = null;
                }
            }
        }

        /// One voice added into a chunk, with its source shape chosen
        /// before the loop rather than inside it.
        fn add(voice: *Voice, out: []i32) void {
            switch (voice.samples) {
                inline else => |samples| addFrom(voice, samples, out),
            }
        }

        fn addFrom(voice: *Voice, samples: anytype, out: []i32) void {
            const total = samples.len;
            const left: i32 = voice.left;
            const right: i32 = voice.right;

            var frame: usize = 0;
            while (frame + 1 < out.len) : (frame += 2) {
                if (voice.at.whole >= total) {
                    if (!voice.looping) return;
                    // Back to the loop's start, keeping the fraction: a
                    // loop that rounded to a whole sample each turn would
                    // drift away from its own pitch.
                    const from = voice.loopStart(total);
                    voice.at.whole = from + (voice.at.whole - from) % (total - from);
                }

                const here = widened(samples[voice.at.whole]);
                const after = next: {
                    const beyond = voice.at.whole + 1;
                    if (beyond < total) break :next widened(samples[beyond]);
                    if (voice.looping) break :next widened(samples[voice.loopStart(total)]);
                    break :next here;
                };

                // The line between the two, drawn with the top of the
                // fraction so the multiply stays narrow.
                const along: i32 = @intCast(voice.at.fraction >> (FRACTION_BITS - BLEND_BITS));
                const sample = here + (((after - here) * along) >> BLEND_BITS);

                out[frame] += (sample * left) >> 8;
                out[frame + 1] += (sample * right) >> 8;
                voice.at.advance(voice.step);
            }
        }
    };
}

test "an eight bit sample reads as the signed one it stands for" {
    const unsigned = Samples{ .unsigned_eight = &.{ 128, 129, 127 } };
    try std.testing.expectEqual(@as(i16, 0), unsigned.at(0));
    try std.testing.expectEqual(@as(i16, 256), unsigned.at(1));
    try std.testing.expectEqual(@as(i16, -256), unsigned.at(2));
    // Past the end is silence, not whatever follows it in memory.
    try std.testing.expectEqual(@as(i16, 0), unsigned.at(3));
    try std.testing.expectEqual(@as(usize, 3), unsigned.count());

    // The same three levels stored the other way, silence at zero.
    const signed = Samples{ .signed_eight = &.{ 0, 1, -1 } };
    try std.testing.expectEqual(@as(i16, 0), signed.at(0));
    try std.testing.expectEqual(@as(i16, 256), signed.at(1));
    try std.testing.expectEqual(@as(i16, -256), signed.at(2));
    try std.testing.expectEqual(@as(i16, 0), signed.at(3));

    // The ends of each reach the same place.
    try std.testing.expectEqual(@as(i16, -32768), (Samples{ .unsigned_eight = &.{0} }).at(0));
    try std.testing.expectEqual(@as(i16, -32768), (Samples{ .signed_eight = &.{-128} }).at(0));
}

test "a source at the output's own rate advances one sample a frame" {
    try std.testing.expectEqual(Step{ .whole = 1, .fraction = 0 }, stepFor(48000, 48000));
    // Half the rate advances half as fast, and the fraction is exact.
    try std.testing.expectEqual(Step{ .whole = 0, .fraction = FRACTION_ONE / 2 }, stepFor(24000, 48000));
    try std.testing.expectEqual(Step{ .whole = 2, .fraction = 0 }, stepFor(96000, 48000));

    // A rate nothing divides gives a step under one with a fraction.
    const doom = stepFor(11025, 48000);
    try std.testing.expectEqual(@as(usize, 0), doom.whole);
    try std.testing.expect(doom.fraction > 0 and doom.fraction < FRACTION_ONE);

    // A stream running at nothing is not a reason to divide by zero.
    try std.testing.expectEqual(Step{ .whole = 1, .fraction = 0 }, stepFor(11025, 0));
}

test "a position carries its fraction into the whole as it moves" {
    var at = Step{};
    const half = Step{ .fraction = FRACTION_ONE / 2 };
    at.advance(half);
    try std.testing.expectEqual(@as(usize, 0), at.whole);
    try std.testing.expectEqual(FRACTION_ONE / 2, at.fraction);
    at.advance(half);
    try std.testing.expectEqual(@as(usize, 1), at.whole);
    try std.testing.expectEqual(@as(u32, 0), at.fraction);

    // And skipping many frames at once arrives in the same place as
    // stepping through them, which is what a channel turned down needs.
    var stepped = Step{};
    var skipped = Step{};
    const odd = Step{ .whole = 2, .fraction = 12345 };
    for (0..500) |_| stepped.advance(odd);
    skipped.skip(odd, 500);
    try std.testing.expectEqual(stepped, skipped);
}

/// What a voice at full gain makes of a sample. The mixer tests compare
/// against this rather than against the sample itself.
fn atFullGain(sample: i32) i16 {
    return @intCast((sample * @as(i32, FULL_GAIN)) >> 8);
}

test "one voice comes out on both sides at what it was scaled to" {
    var mixer = Mixer(4){};
    const source = Samples{ .sixteen = &.{ 1000, 2000 } };
    mixer.start(0, .{ .samples = source, .left = FULL_GAIN, .right = 0 });

    var out: [4]i16 = @splat(0);
    mixer.fill(&out);
    // Left carries it a two hundred and fifty-sixth under, right is silent.
    try std.testing.expectEqual(@as(i16, (1000 * 255) >> 8), out[0]);
    try std.testing.expectEqual(@as(i16, 0), out[1]);
    try std.testing.expectEqual(@as(i16, (2000 * 255) >> 8), out[2]);
    try std.testing.expectEqual(@as(i16, 0), out[3]);
}

test "a voice that ran out is forgotten rather than read past" {
    var mixer = Mixer(2){};
    mixer.start(1, .{ .samples = .{ .sixteen = &.{ 100, 200 } } });
    try std.testing.expect(mixer.playing(1));

    var out: [8]i16 = @splat(0);
    mixer.fill(&out);
    try std.testing.expect(!mixer.playing(1));
    // Two frames of sound, then silence rather than whatever came next.
    try std.testing.expect(out[0] != 0 and out[2] != 0);
    try std.testing.expectEqual(@as(i16, 0), out[4]);
    try std.testing.expectEqual(@as(i16, 0), out[6]);
}

test "a looping voice keeps going and keeps its fraction" {
    var mixer = Mixer(1){};
    mixer.start(0, .{
        .samples = .{ .sixteen = &.{ 1000, -1000 } },
        .step = .{ .whole = 1 },
        .looping = true,
    });

    var out: [16]i16 = @splat(0);
    mixer.fill(&out);
    try std.testing.expect(mixer.playing(0));
    // It alternates the whole way through rather than stopping at two.
    var frame: usize = 0;
    while (frame < out.len) : (frame += 4) {
        try std.testing.expect(out[frame] > 0);
        try std.testing.expect(out[frame + 2] < 0);
    }
}

test "a sample between two is drawn as the line between them" {
    // A source read four times for every sample it has, so three frames
    // in four land between two of them.
    var mixer = Mixer(1){};
    mixer.start(0, .{
        .samples = .{ .sixteen = &.{ 0, 1000 } },
        .step = .{ .fraction = FRACTION_ONE / 4 },
    });

    var out: [8]i16 = @splat(0);
    mixer.fill(&out);

    // On the first sample, then a quarter, a half and three quarters of
    // the way to the second.
    try std.testing.expectEqual(atFullGain(0), out[0]);
    try std.testing.expectEqual(atFullGain(250), out[2]);
    try std.testing.expectEqual(atFullGain(500), out[4]);
    try std.testing.expectEqual(atFullGain(750), out[6]);
}

test "past the last sample there is nothing to draw a line to" {
    // A voice that ends holds its last sample rather than reading on.
    var ending = Mixer(1){};
    ending.start(0, .{
        .samples = .{ .sixteen = &.{ 0, 1000 } },
        .at = .{ .whole = 1, .fraction = FRACTION_ONE / 2 },
        .step = .{ .fraction = FRACTION_ONE / 4 },
    });
    var out: [2]i16 = @splat(0);
    ending.fill(&out);
    try std.testing.expectEqual(atFullGain(1000), out[0]);

    // One that holds draws the line back to where it loops.
    var holding = Mixer(1){};
    holding.start(0, .{
        .samples = .{ .sixteen = &.{ 0, 1000 } },
        .at = .{ .whole = 1, .fraction = FRACTION_ONE / 2 },
        .step = .{ .fraction = FRACTION_ONE / 4 },
        .looping = true,
    });
    holding.fill(&out);
    try std.testing.expectEqual(atFullGain(500), out[0]);
}

test "a voice played at its own rate lands on its samples exactly" {
    var mixer = Mixer(1){};
    mixer.start(0, .{ .samples = .{ .sixteen = &.{ 1000, -1000, 500 } }, .step = .{ .whole = 1 } });
    var out: [6]i16 = @splat(0);
    mixer.fill(&out);
    try std.testing.expectEqual(atFullGain(1000), out[0]);
    try std.testing.expectEqual(atFullGain(-1000), out[2]);
    try std.testing.expectEqual(atFullGain(500), out[4]);
}

test "a voice loops its body and plays its attack only once" {
    var mixer = Mixer(1){};
    // Two samples of attack, then a body of one that holds.
    mixer.start(0, .{
        .samples = .{ .sixteen = &.{ 1000, 2000, 3000 } },
        .looping = true,
        .loop_from = 2,
    });

    var out: [12]i16 = @splat(0);
    mixer.fill(&out);
    try std.testing.expectEqual(atFullGain(1000), out[0]);
    try std.testing.expectEqual(atFullGain(2000), out[2]);
    // From here it is the body, every frame, rather than the attack again.
    try std.testing.expectEqual(atFullGain(3000), out[4]);
    try std.testing.expectEqual(atFullGain(3000), out[6]);
    try std.testing.expectEqual(atFullGain(3000), out[8]);
    try std.testing.expect(mixer.playing(0));
}

test "a loop starting past the end goes back to the beginning instead" {
    var mixer = Mixer(1){};
    mixer.start(0, .{
        .samples = .{ .sixteen = &.{ 100, 200 } },
        .looping = true,
        .loop_from = 9,
    });

    var out: [8]i16 = @splat(0);
    mixer.fill(&out);
    try std.testing.expect(out[0] > 0 and out[2] > 0);
    try std.testing.expect(out[4] > 0 and out[6] > 0);
    try std.testing.expect(mixer.playing(0));
}

test "voices are summed, and a total over the top is flattened rather than wrapped" {
    var mixer = Mixer(4){};
    const loud = Samples{ .sixteen = &.{ 30000, 30000 } };
    mixer.start(0, .{ .samples = loud });
    mixer.start(1, .{ .samples = loud });
    mixer.start(2, .{ .samples = loud });

    var out: [4]i16 = @splat(0);
    mixer.fill(&out);
    // Three of those is past full scale, and it comes out held there.
    try std.testing.expectEqual(@as(i16, std.math.maxInt(i16)), out[0]);
    try std.testing.expectEqual(@as(i16, std.math.maxInt(i16)), out[1]);
}

test "a sum that goes over the top and back again comes out where it belongs" {
    var mixer = Mixer(4){};
    const up = Samples{ .sixteen = &.{ 30000, 30000 } };
    const down = Samples{ .sixteen = &.{ -30000, -30000 } };
    mixer.start(0, .{ .samples = up });
    mixer.start(1, .{ .samples = up });
    mixer.start(2, .{ .samples = down });

    var out: [2]i16 = @splat(0);
    mixer.fill(&out);
    // Added one pair at a time the first two would have been held at full
    // scale and the third would take it down to under three thousand.
    // Added together they come to one loud sound, to within the sample
    // the scaling rounds away.
    const one: i32 = atFullGain(30000);
    try std.testing.expect(@abs(@as(i32, out[0]) - one) <= 2);
}

test "a slot that is silent takes no gain, and a slot that is not is not disturbed" {
    var mixer = Mixer(2){};
    mixer.setGain(0, 10, 10);
    try std.testing.expect(!mixer.playing(0));

    mixer.start(0, .{ .samples = .{ .sixteen = &.{ 1000, 1000 } } });
    mixer.setGain(0, 0, FULL_GAIN);
    var out: [2]i16 = @splat(0);
    mixer.fill(&out);
    try std.testing.expectEqual(@as(i16, 0), out[0]);
    try std.testing.expect(out[1] > 0);

    // A slot that does not exist is ignored rather than a crash.
    mixer.start(9, .{ .samples = .{ .sixteen = &.{1000} } });
    mixer.setGain(9, 1, 1);
    mixer.stop(9);
    try std.testing.expect(!mixer.playing(9));
}

test "a voice bent while it plays keeps its place" {
    var mixer = Mixer(1){};
    const source = Samples{ .sixteen = &.{ 100, 200, 300, 400, 500, 600 } };
    mixer.start(0, .{ .samples = source, .step = .{ .whole = 1 } });

    var out: [4]i16 = @splat(0);
    mixer.fill(&out);
    // Two samples in, and now moving twice as fast.
    mixer.setStep(0, .{ .whole = 2 });
    mixer.fill(&out);
    // It carries on from the third sample rather than starting again.
    try std.testing.expectEqual(atFullGain(300), out[0]);
    try std.testing.expectEqual(atFullGain(500), out[2]);

    // A slot with nothing in it is not bent into existence.
    mixer.setStep(0, .{ .whole = 1 });
    mixer.setStep(9, .{ .whole = 1 });
}

test "a voice can start part way into its source" {
    var mixer = Mixer(1){};
    mixer.start(0, .{
        .samples = .{ .sixteen = &.{ 100, 200, 300, 400 } },
        .at = position(2),
    });
    var out: [4]i16 = @splat(0);
    mixer.fill(&out);
    try std.testing.expect(out[0] > out[2] * 0); // third sample, then fourth
    try std.testing.expectEqual(atFullGain(300), out[0]);
    try std.testing.expectEqual(atFullGain(400), out[2]);
}

test "the first free slot is the one a caller is given, and none when full" {
    var mixer = Mixer(2){};
    try std.testing.expectEqual(@as(?usize, 0), mixer.free());
    mixer.start(0, .{ .samples = .{ .sixteen = &.{1000} } });
    try std.testing.expectEqual(@as(?usize, 1), mixer.free());
    mixer.start(1, .{ .samples = .{ .sixteen = &.{1000} } });
    try std.testing.expectEqual(@as(?usize, null), mixer.free());
    mixer.stopAll();
    try std.testing.expectEqual(@as(?usize, 0), mixer.free());
}

test "a voice with nothing in it ends instead of dividing by zero" {
    var mixer = Mixer(1){};
    mixer.start(0, .{ .samples = .{ .sixteen = &.{} }, .looping = true });
    var out: [4]i16 = @splat(0);
    mixer.fill(&out);
    try std.testing.expect(!mixer.playing(0));
    try std.testing.expectEqual(@as(i16, 0), out[0]);
}
