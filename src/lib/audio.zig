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
    /// Unsigned, silence at the middle of the range.
    eight: []const u8,
    /// Signed, silence at zero, which is what everything else here uses.
    sixteen: []const i16,

    pub fn count(self: Samples) usize {
        return switch (self) {
            .eight => |s| s.len,
            .sixteen => |s| s.len,
        };
    }

    /// The sample at `index`, as the rest of this module counts them.
    /// Silence past the end, so a caller that has not yet noticed a voice
    /// finished reads nothing rather than another voice's memory.
    pub fn at(self: Samples, index: usize) i16 {
        return switch (self) {
            .eight => |s| if (index < s.len)
                (@as(i16, s[index]) - 128) << 8
            else
                0,
            .sixteen => |s| if (index < s.len) s[index] else 0,
        };
    }
};

/// How loud a voice is on one side, in two hundred and fifty-sixths.
///
/// Full is 255 rather than 256 so that the whole range fits a byte and
/// silence is zero. That leaves the loudest a voice can be a two hundred
/// and fifty-sixth under the sample it came from, which is a thirtieth of
/// a decibel and audible to nobody.
pub const Gain = u8;
pub const FULL_GAIN: Gain = 255;

/// How many bits of a source position are the fraction.
///
/// The position is counted in source samples, and a source recorded at a
/// rate the output does not divide advances by a fraction of one per
/// output frame. Sixteen bits of fraction put the error in a step at one
/// part in sixty-five thousand, which over the longest sound anybody plays
/// this way is a small part of one sample.
const STEP_BITS: u6 = 16;
const STEP_ONE: u64 = 1 << STEP_BITS;

/// One sound being played: where it is, how fast it moves, how loud.
pub const Voice = struct {
    samples: Samples,
    /// Where the next output frame is read from, in source samples, with
    /// `STEP_BITS` of fraction.
    at: u64 = 0,
    /// How far `at` moves per output frame, in the same fixed point.
    step: u64 = STEP_ONE,
    left: Gain = FULL_GAIN,
    right: Gain = FULL_GAIN,
    /// Whether reaching the end starts it again rather than ending it.
    looping: bool = false,

    /// A voice reading `samples` recorded at `from` hertz and played into
    /// a stream running at `to`.
    pub fn resampled(samples: Samples, from: u32, to: u32) Voice {
        return .{ .samples = samples, .step = stepFor(from, to) };
    }

    /// Whether it has run off the end of what it was given.
    ///
    /// A voice with no samples is finished however it was asked to loop:
    /// going round nothing is not going round.
    pub fn finished(self: Voice) bool {
        const total = self.samples.count();
        if (total == 0) return true;
        return !self.looping and (self.at >> STEP_BITS) >= total;
    }
};

/// How far a source advances per output frame, in the fixed point above.
///
/// Worked out in sixty-four bits: a rate shifted by sixteen passes what
/// thirty-two hold at anything above about sixty-five kilohertz, and a
/// rate is a number somebody can configure.
pub fn stepFor(from: u32, to: u32) u64 {
    if (to == 0) return STEP_ONE;
    return (@as(u64, from) << STEP_BITS) / to;
}

/// Several voices summed into one interleaved stereo stream.
///
/// The count is a compile-time number because it is a budget: a program
/// decides how many sounds may be going at once, and one that decided at
/// runtime would be one that allocates on the path a sound comes out of.
/// Voices are addressed by slot, which is what lets a caller change or
/// stop one it started without holding a handle to it.
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
        /// to, so a caller need not clear it first. Summed in a wider
        /// number and brought back once at the end: clipping each addition
        /// as it goes turns a pair of loud sounds into a different sound,
        /// where clipping the total only flattens what was over the top.
        pub fn fill(self: *Self, out: []i16) void {
            @memset(out, 0);

            for (&self.voices) |*maybe| {
                const voice = if (maybe.*) |*v| v else continue;
                self.render(voice, out);
                if (voice.finished()) maybe.* = null;
            }
        }

        fn render(_: *Self, voice: *Voice, out: []i16) void {
            const total = voice.samples.count();
            if (total == 0) return;

            var frame: usize = 0;
            while (frame + 1 < out.len) : (frame += 2) {
                var index = voice.at >> STEP_BITS;
                if (index >= total) {
                    if (!voice.looping) return;
                    // Back to the start, keeping the fraction: a loop that
                    // rounded to a whole sample each turn would drift.
                    voice.at %= @as(u64, total) << STEP_BITS;
                    index = voice.at >> STEP_BITS;
                }

                const sample: i32 = voice.samples.at(@intCast(index));
                out[frame] = mix(out[frame], @intCast((sample * voice.left) >> 8));
                out[frame + 1] = mix(out[frame + 1], @intCast((sample * voice.right) >> 8));
                voice.at += voice.step;
            }
        }
    };
}

test "an eight bit sample reads as the signed one it stands for" {
    const quiet = Samples{ .eight = &.{ 128, 129, 127 } };
    try std.testing.expectEqual(@as(i16, 0), quiet.at(0));
    try std.testing.expectEqual(@as(i16, 256), quiet.at(1));
    try std.testing.expectEqual(@as(i16, -256), quiet.at(2));
    // Past the end is silence, not somebody else's memory.
    try std.testing.expectEqual(@as(i16, 0), quiet.at(3));
    try std.testing.expectEqual(@as(usize, 3), quiet.count());
}

test "a source at the output's own rate advances one sample a frame" {
    try std.testing.expectEqual(STEP_ONE, stepFor(48000, 48000));
    // Half the rate advances half as fast, and the fraction is exact.
    try std.testing.expectEqual(STEP_ONE / 2, stepFor(24000, 48000));
    try std.testing.expectEqual(STEP_ONE * 2, stepFor(96000, 48000));
    // A rate nothing divides still gives a step under one.
    const doom = stepFor(11025, 48000);
    try std.testing.expect(doom > 0 and doom < STEP_ONE);
    // A stream running at nothing is not a reason to divide by zero.
    try std.testing.expectEqual(STEP_ONE, stepFor(11025, 0));
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
        .step = STEP_ONE,
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

    // A slot nobody has is neither played nor a crash.
    mixer.start(9, .{ .samples = .{ .sixteen = &.{1000} } });
    mixer.setGain(9, 1, 1);
    mixer.stop(9);
    try std.testing.expect(!mixer.playing(9));
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
