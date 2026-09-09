//! Playing a module: where the song is, what each channel is doing, and
//! the effects that change it between rows.
//!
//! The song runs on ticks. A row lasts `speed` ticks, and on the first of
//! them the row's cells are read and their notes started; on the rest the
//! effects that move something a little at a time do their moving. How
//! long a tick lasts comes from the tempo.
//!
//! The sound itself is the shared mixer's. This decides which sample each
//! channel plays, how fast, and how loud, and hands that over as voices;
//! it never touches a sample. Nothing here allocates and nothing here
//! knows about a screen.

const std = @import("std");
const audio = @import("lib").audio;
const mod = @import("module.zig");

/// The Amiga's sampler clock. Dividing it by twice a period gives the
/// rate the samples came out at, which is what a period means.
const PAULA_HZ: u32 = 7093790;

/// A row lasts this many ticks, and a minute this many beats, until a
/// song says otherwise.
const DEFAULT_SPEED: u8 = 6;
const DEFAULT_TEMPO: u8 = 125;

/// Below this a speed command sets ticks per row; at or above it, tempo.
const TEMPO_FROM: u8 = 32;

/// The loudest an instrument goes, in the format's own counting.
const MAX_VOLUME: u8 = 64;

/// The pitches the hardware could reach. Sliding stops at these.
const MIN_PERIOD: u16 = 113;
const MAX_PERIOD: u16 = 856;

/// How far apart the channels are placed, in 256ths.
///
/// The Amiga put two channels hard left and two hard right, which is
/// tiring to listen to on headphones. Most players narrow it; this one
/// narrows it too, and says by how much rather than leaving it in an
/// expression.
const SPREAD: u16 = 160;

/// Notes in the period table: three octaves of twelve.
const NOTES = 36;

/// How many finetune settings an instrument can have.
const TUNINGS = 16;

/// The periods for every note at every finetune.
///
/// The published table is three octaves of measured values plus fifteen
/// more sets derived from them, each an eighth of a semitone apart. Built
/// here from the first set and that definition, because sixteen rows of
/// thirty-six numbers copied out is sixteen chances to mistype one.
const periods: [TUNINGS][NOTES]u16 = build: {
    @setEvalBranchQuota(20000);
    const base = [NOTES]u16{
        856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
        428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
        214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113,
    };

    var table: [TUNINGS][NOTES]u16 = undefined;
    for (&table, 0..) |*row, tuning| {
        // Finetunes run 0..7 then -8..-1, as a signed nibble does.
        const steps: f64 = if (tuning < 8) @floatFromInt(tuning) else @as(f64, @floatFromInt(tuning)) - 16.0;
        // An eighth of a semitone is a ninety-sixth of an octave, and a
        // higher note is a shorter period.
        const ratio = std.math.pow(f64, 2.0, -steps / 96.0);
        for (row, base) |*period, from| {
            period.* = @intFromFloat(@round(@as(f64, @floatFromInt(from)) * ratio));
        }
    }
    break :build table;
};

/// Which note a period is, or none when it is not one of them.
///
/// Some songs carry periods that are not in the table, so this finds the
/// nearest instead of insisting. Used by the effects that have to count
/// in semitones rather than in periods.
fn noteOf(period: u16, tuning: i4) usize {
    const row = &periods[@as(u4, @bitCast(tuning))];
    var nearest: usize = 0;
    var best: u16 = std.math.maxInt(u16);
    for (row, 0..) |candidate, index| {
        const apart = if (candidate > period) candidate - period else period - candidate;
        if (apart < best) {
            best = apart;
            nearest = index;
        }
    }
    return nearest;
}

/// A period this many semitones above `period`, held inside the table.
fn transposed(period: u16, tuning: i4, semitones: u8) u16 {
    const from = noteOf(period, tuning);
    const to = @min(from + semitones, NOTES - 1);
    return periods[@as(u4, @bitCast(tuning))][to];
}

/// The names of the twelve notes, sharps rather than flats, which is how
/// a tracker has always shown them.
const names = [12][2]u8{
    .{ 'C', '-' }, .{ 'C', '#' }, .{ 'D', '-' }, .{ 'D', '#' },
    .{ 'E', '-' }, .{ 'F', '-' }, .{ 'F', '#' }, .{ 'G', '-' },
    .{ 'G', '#' }, .{ 'A', '-' }, .{ 'A', '#' }, .{ 'B', '-' },
};

/// How a period is written in a pattern: the note, and which octave.
///
/// Here rather than in whatever draws it, because naming a note means
/// knowing which one a period is, and the table that says so is this
/// file's. A period of nothing is an empty cell.
pub fn spell(period: u16) [3]u8 {
    if (period == 0) return .{ '.', '.', '.' };
    const index = noteOf(period, 0);
    const octave: u8 = @intCast(1 + index / 12);
    return .{ names[index % 12][0], names[index % 12][1], '0' + octave };
}

/// A period as an instrument's own tuning has it.
fn tunedTo(period: u16, tuning: i4) u16 {
    if (tuning == 0) return period;
    return periods[@as(u4, @bitCast(tuning))][noteOf(period, 0)];
}

/// A period moved by `steps` and held to what the hardware could play.
fn slid(period: u16, steps: i32) u16 {
    const moved = @as(i32, period) + steps;
    return @intCast(std.math.clamp(moved, MIN_PERIOD, MAX_PERIOD));
}

/// A volume moved by `steps` and held inside the format's range.
fn louder(volume: u8, steps: i32) u8 {
    const moved = @as(i32, volume) + steps;
    return @intCast(std.math.clamp(moved, 0, MAX_VOLUME));
}

// ---------------------------------------------------------------------------
// Oscillators
// ---------------------------------------------------------------------------

/// A vibrato or a tremolo: the same machinery, told apart only by what it
/// is added to. One type rather than two, so a fix to the shape of the
/// wave is a fix to both.
const Oscillator = struct {
    waveform: mod.Waveform = .{},
    speed: u4 = 0,
    depth: u4 = 0,
    /// Where in the cycle it is, in sixty-fourths of a turn.
    at: u6 = 0,

    /// Take a new speed and depth, keeping whichever the command left at
    /// zero: a command with one nibble set changes only that nibble.
    fn set(self: *Oscillator, from: mod.Oscillation) void {
        if (from.speed != 0) self.speed = from.speed;
        if (from.depth != 0) self.depth = from.depth;
    }

    /// A new note restarts it, unless its waveform was told not to.
    fn restart(self: *Oscillator) void {
        if (self.waveform.retrigger) self.at = 0;
    }

    /// How far from the middle it is now, before the depth is applied.
    /// Full scale is 255, whichever shape it is.
    fn offset(self: Oscillator) i32 {
        // The phase counts sixty-four steps to the turn; the sine wants
        // a whole sixteen-bit turn.
        const turn = @as(u16, self.at) << 10;
        return switch (self.waveform.wave) {
            .sine => @divTrunc(@as(i32, audio.sine(turn)), 128),
            // Falls from the top to the bottom across the turn.
            .ramp_down => 255 - @divTrunc(@as(i32, self.at) * 510, 63),
            .square => if (self.at < 32) @as(i32, 255) else -255,
            // Nothing here is random; a shape nobody can predict is a
            // shape nobody can test, and the sine is what the trackers
            // that wrote these files fell back to.
            .random => @divTrunc(@as(i32, audio.sine(turn)), 128),
        };
    }

    fn advance(self: *Oscillator) void {
        self.at +%= self.speed;
    }
};

// ---------------------------------------------------------------------------
// A channel
// ---------------------------------------------------------------------------

/// One channel's state: what it is playing and what is being done to it.
const Channel = struct {
    instrument: u8 = 0,
    /// The pitch it is playing at, and the pitch a slide is heading for.
    period: u16 = 0,
    target: u16 = 0,
    volume: u8 = 0,
    tuning: i4 = 0,
    /// Zero is hard left, 255 hard right.
    panning: u8 = 128,

    /// What the last command of each kind asked for, since a command with
    /// no parameter repeats the one before it.
    slide_speed: u8 = 0,
    to_note_speed: u8 = 0,
    volume_slide: mod.Slide = .{},
    offset: u8 = 0,
    vibrato: Oscillator = .{},
    tremolo: Oscillator = .{},
    /// Whether a slide to a note steps in semitones.
    glissando: bool = false,
    /// How many times a pattern loop on this channel has left to run, and
    /// which row it goes back to.
    loop_row: u8 = 0,
    loop_left: u4 = 0,

    /// What the command in hand is doing to the pitch and the volume this
    /// tick, on top of the channel's own. Kept apart from `period` and
    /// `volume` so that a wobble does not walk them away from where the
    /// row put them.
    bend: i32 = 0,
    trim: i32 = 0,

    /// The pitch actually sounding, which is the channel's own plus
    /// whatever is bending it.
    fn sounding(self: Channel) u16 {
        return slid(self.period, self.bend);
    }

    /// One tick of a volume slide.
    fn slideVolume(self: *Channel, slide: mod.Slide) void {
        self.volume = louder(self.volume, slide.step());
    }

    /// One tick of a vibrato. The pitch is bent rather than moved, so the
    /// row still ends on the note it started.
    fn applyVibrato(self: *Channel) void {
        self.bend = @divTrunc(self.vibrato.offset() * @as(i32, self.vibrato.depth), 128);
        self.vibrato.advance();
    }

    /// One tick of a tremolo, which is the same for loudness.
    fn applyTremolo(self: *Channel) void {
        self.trim = @divTrunc(self.tremolo.offset() * @as(i32, self.tremolo.depth), 64);
        self.tremolo.advance();
    }

    /// Move the pitch towards where a slide is headed, and no further.
    fn slideToNote(self: *Channel) void {
        if (self.target == 0 or self.to_note_speed == 0) return;
        const speed: i32 = self.to_note_speed;
        if (self.period > self.target) {
            self.period = @max(self.target, slid(self.period, -speed));
        } else if (self.period < self.target) {
            self.period = @min(self.target, slid(self.period, speed));
        }
        // Stepping in semitones rather than smoothly, when asked.
        if (self.glissando) {
            self.period = periods[@as(u4, @bitCast(self.tuning))][noteOf(self.period, self.tuning)];
        }
    }

    /// The loudness actually sounding, from nothing to full.
    fn loudness(self: Channel) u8 {
        return louder(self.volume, self.trim);
    }
};

/// What a channel is doing, for a caller that wants to show it.
pub const Meter = struct {
    /// Zero when the channel is silent.
    volume: u8 = 0,
    period: u16 = 0,
    instrument: u8 = 0,
};

// ---------------------------------------------------------------------------
// The player
// ---------------------------------------------------------------------------

pub const Player = struct {
    module: *const mod.Module,
    /// Frames a second the mixer is running at.
    rate: u32,
    voices: audio.Mixer(mod.MAX_CHANNELS) = .{},
    channels: [mod.MAX_CHANNELS]Channel = @splat(.{}),

    /// Where in the song: which place in the order, which row of that
    /// pattern, and which tick of that row.
    place: u8 = 0,
    row: u8 = 0,
    tick: u8 = 0,

    speed: u8 = DEFAULT_SPEED,
    tempo: u8 = DEFAULT_TEMPO,

    /// Where the row after this one is, when a command has said. Both
    /// commands can appear in one row, and together they mean "that place
    /// at that row".
    jump_to: ?u8 = null,
    break_to: ?u8 = null,
    /// Rows' worth of extra time this row is being held for.
    delay_rows: u4 = 0,

    /// Whether the song has run off the end. It keeps playing from the
    /// restart position; this only says that it has been round once.
    looped: bool = false,

    /// Frames still owed on the tick in hand, so that a render broken
    /// into blocks picks up where the last one stopped.
    owed: u32 = 0,

    pub fn init(module: *const mod.Module, rate: u32) Player {
        var self = Player{ .module = module, .rate = rate };
        self.reset();
        return self;
    }

    /// Back to the top of the song with every channel silent.
    pub fn reset(self: *Player) void {
        self.voices.stopAll();
        self.channels = @splat(.{});
        for (self.channels[0..self.module.shape.channels], 0..) |*channel, index| {
            channel.panning = panningOf(index);
        }
        self.place = 0;
        self.row = 0;
        self.tick = 0;
        self.speed = DEFAULT_SPEED;
        self.tempo = DEFAULT_TEMPO;
        self.jump_to = null;
        self.break_to = null;
        self.delay_rows = 0;
        self.looped = false;
        self.owed = 0;
    }

    /// Which pattern is playing.
    pub fn pattern(self: *const Player) u8 {
        return self.module.order[@min(self.place, mod.ORDER - 1)];
    }

    /// What each channel is doing, for a caller drawing meters.
    pub fn meter(self: *const Player, channel: usize) Meter {
        if (channel >= self.module.shape.channels) return .{};
        const one = &self.channels[channel];
        return .{
            .volume = if (self.voices.playing(channel)) one.loudness() else 0,
            .period = one.period,
            .instrument = one.instrument,
        };
    }

    /// How many frames one tick lasts.
    ///
    /// A tick is a fiftieth of a second at the default tempo, and tempo
    /// scales it: two and a half ticks per beat, and `tempo` beats a
    /// minute. Worked out in one place so the sums agree.
    pub fn framesPerTick(self: *const Player) u32 {
        const beats: u32 = @max(self.tempo, 32);
        return (self.rate * 5) / (beats * 2);
    }

    /// Fill `out` with the song, moving through it as it goes.
    ///
    /// `out` is interleaved stereo at the rate this was made with. Ticks
    /// are handled at their boundaries and the mixing runs in whatever
    /// blocks fall between, so a caller hands over whatever size buffer
    /// suits it and hears the same song.
    pub fn render(self: *Player, out: []i16) void {
        var at: usize = 0;
        while (at + 1 < out.len) {
            if (self.owed == 0) {
                self.advanceTick();
                self.owed = self.framesPerTick();
            }
            const frames = @min(self.owed, (out.len - at) / 2);
            if (frames == 0) break;
            self.voices.fill(out[at..][0 .. frames * 2]);
            self.owed -= @intCast(frames);
            at += frames * 2;
        }
    }

    // -----------------------------------------------------------------------
    // Ticking
    // -----------------------------------------------------------------------

    fn advanceTick(self: *Player) void {
        if (self.tick == 0) self.startRow() else self.continueRow();
        self.applyToVoices();

        self.tick += 1;
        if (self.tick < self.speed) return;
        self.tick = 0;

        // A delayed row is played again rather than moved past, without
        // its cells being read a second time.
        if (self.delay_rows > 0) {
            self.delay_rows -= 1;
            self.tick = 1;
            return;
        }
        self.nextRow();
    }

    /// Read the row's cells and act on everything that happens at once.
    fn startRow(self: *Player) void {
        const which = self.pattern();
        for (self.channels[0..self.module.shape.channels], 0..) |*channel, index| {
            const note = self.module.note(which, self.row, index);
            self.begin(channel, index, note);
        }
    }

    /// Do whatever the row's commands do a little of on every tick.
    fn continueRow(self: *Player) void {
        const which = self.pattern();
        for (self.channels[0..self.module.shape.channels], 0..) |*channel, index| {
            const note = self.module.note(which, self.row, index);
            self.during(channel, index, note.command);
        }
    }

    /// Move to the next row, honouring anything that said where to go.
    fn nextRow(self: *Player) void {
        if (self.jump_to != null or self.break_to != null) {
            self.row = self.break_to orelse 0;
            if (self.jump_to) |place| {
                self.place = place;
            } else {
                // A break with no jump goes to the next place in the order.
                self.place +|= 1;
            }
            self.jump_to = null;
            self.break_to = null;
        } else {
            self.row += 1;
            if (self.row < mod.ROWS) return;
            self.row = 0;
            self.place +|= 1;
        }

        if (self.place >= self.module.length) {
            self.place = if (self.module.restart < self.module.length) self.module.restart else 0;
            self.looped = true;
        }
    }

    // -----------------------------------------------------------------------
    // What a row asks for
    // -----------------------------------------------------------------------

    /// Act on one cell at the start of its row.
    fn begin(self: *Player, channel: *Channel, index: usize, note: mod.Note) void {
        channel.bend = 0;
        channel.trim = 0;

        // An instrument named without a note loads its volume and tuning
        // without starting anything.
        if (note.instrument) |number| {
            if (self.module.instrument(number)) |instrument| {
                channel.instrument = number;
                channel.volume = instrument.volume;
                channel.tuning = instrument.finetune;
            }
        }

        // A slide to a note takes the cell's pitch as its destination
        // rather than playing it.
        const sliding = switch (note.command) {
            .slide_to_note, .slide_to_note_and_volume => true,
            else => false,
        };

        // Where in the sample the note starts. Remembered, because the
        // command repeats the last offset when given none.
        if (note.command == .sample_offset) {
            if (note.command.sample_offset != 0) channel.offset = note.command.sample_offset;
        }
        const from: usize = if (note.command == .sample_offset)
            @as(usize, channel.offset) * 256
        else
            0;

        if (note.period) |period| {
            const pitch = tunedTo(period, channel.tuning);
            if (sliding) {
                channel.target = pitch;
            } else {
                channel.period = pitch;
                channel.target = pitch;
                channel.vibrato.restart();
                channel.tremolo.restart();
                // A note held back starts when its delay runs out.
                if (note.command != .delay_note) self.strike(channel, index, from);
            }
        }

        self.atRowStart(channel, note.command);
    }

    /// The commands that happen once, at the start of their row.
    ///
    /// Switched over exhaustively: an effect added to the format is a
    /// build that stops here rather than a note that comes out wrong.
    fn atRowStart(self: *Player, channel: *Channel, command: mod.Command) void {
        switch (command) {
            .none => {},

            // Remembered now, done on the ticks that follow.
            .arpeggio, .vibrato_and_volume, .slide_to_note_and_volume => {},

            .slide_up, .slide_down => |speed| {
                if (speed != 0) channel.slide_speed = speed;
            },
            .slide_to_note => |speed| {
                if (speed != 0) channel.to_note_speed = speed;
            },
            .vibrato => |swing| channel.vibrato.set(swing),
            .tremolo => |swing| channel.tremolo.set(swing),

            .set_panning => |where| channel.panning = where,
            // Handled before the note was struck.
            .sample_offset => {},
            .volume_slide => |slide| {
                if (slide.up != 0 or slide.down != 0) channel.volume_slide = slide;
            },

            .position_jump => |place| self.jump_to = place,
            .set_volume => |level| channel.volume = @min(level, MAX_VOLUME),
            .pattern_break => |row| self.break_to = @min(row, mod.ROWS - 1),
            .set_speed => |value| {
                if (value == 0) {
                    // Nothing stops a song this way; the trackers that
                    // wrote it meant the slowest speed.
                    self.speed = 1;
                } else if (value < TEMPO_FROM) {
                    self.speed = value;
                } else {
                    self.tempo = value;
                }
            },

            // A filter on hardware this system does not have.
            .set_filter => {},
            .fine_slide_up => |by| channel.period = slid(channel.period, -@as(i32, by)),
            .fine_slide_down => |by| channel.period = slid(channel.period, by),
            .set_glissando => |on| channel.glissando = on,
            .set_vibrato_waveform => |wave| channel.vibrato.waveform = wave,
            .set_tremolo_waveform => |wave| channel.tremolo.waveform = wave,
            .set_finetune => |tuning| channel.tuning = tuning,
            .loop_pattern => |count| self.loopPattern(channel, count),
            // Remembered now, done on the ticks that follow.
            .retrigger, .cut, .delay_note => {},
            .fine_volume_up => |by| channel.volume = louder(channel.volume, by),
            .fine_volume_down => |by| channel.volume = louder(channel.volume, -@as(i32, by)),
            .delay_pattern => |rows| self.delay_rows = rows,
            // Playing a sample backwards means writing into it, and the
            // samples here are the file's own bytes, read only. Almost
            // nothing uses it.
            .invert_loop => {},
        }
    }

    /// Mark where a loop starts, or go back to it.
    fn loopPattern(self: *Player, channel: *Channel, count: u4) void {
        if (count == 0) {
            channel.loop_row = self.row;
            return;
        }
        if (channel.loop_left == 0) channel.loop_left = count;
        channel.loop_left -= 1;
        if (channel.loop_left > 0 or count > 0) {
            // Jumping back is a break to a row of this same pattern,
            // which is what the two together already say.
            if (channel.loop_left > 0) {
                self.break_to = channel.loop_row;
                self.jump_to = self.place;
            }
        }
    }

    /// The commands that move something a little on every tick after the
    /// first. Exhaustive for the same reason as the row's own.
    fn during(self: *Player, channel: *Channel, index: usize, command: mod.Command) void {
        switch (command) {
            .none => {},

            .arpeggio => |steps| {
                // Three even parts to the row: the note, then each of the
                // two above it, over and over.
                const semitones: u8 = switch (self.tick % 3) {
                    1 => steps.first,
                    2 => steps.second,
                    else => 0,
                };
                channel.bend = if (semitones == 0)
                    0
                else
                    @as(i32, transposed(channel.period, channel.tuning, semitones)) -
                        @as(i32, channel.period);
            },

            .slide_up => channel.period = slid(channel.period, -@as(i32, channel.slide_speed)),
            .slide_down => channel.period = slid(channel.period, channel.slide_speed),

            .slide_to_note => channel.slideToNote(),
            .slide_to_note_and_volume => |slide| {
                channel.slideToNote();
                channel.slideVolume(slide);
            },

            .vibrato => channel.applyVibrato(),
            .vibrato_and_volume => |slide| {
                channel.applyVibrato();
                channel.slideVolume(slide);
            },
            .tremolo => channel.applyTremolo(),

            .volume_slide => channel.slideVolume(channel.volume_slide),

            .retrigger => |every| {
                if (every != 0 and self.tick % every == 0) self.strike(channel, index, 0);
            },
            .cut => |after| {
                if (self.tick == after) channel.volume = 0;
            },
            .delay_note => |after| {
                if (self.tick == after) self.strike(channel, index, 0);
            },

            // Everything else happened once, at the start of the row.
            .set_panning,
            .sample_offset,
            .position_jump,
            .set_volume,
            .pattern_break,
            .set_speed,
            .set_filter,
            .fine_slide_up,
            .fine_slide_down,
            .set_glissando,
            .set_vibrato_waveform,
            .set_tremolo_waveform,
            .set_finetune,
            .loop_pattern,
            .fine_volume_up,
            .fine_volume_down,
            .delay_pattern,
            .invert_loop,
            => {},
        }
    }

    /// Start the channel's instrument from `from` samples in.
    fn strike(self: *Player, channel: *Channel, index: usize, from: usize) void {
        const instrument = self.module.instrument(channel.instrument) orelse {
            self.voices.stop(index);
            return;
        };
        const sounding = instrument.sounding();
        if (sounding.len == 0 or from >= sounding.len) {
            self.voices.stop(index);
            return;
        }

        self.voices.start(index, .{
            .samples = .{ .signed_eight = sounding },
            .at = audio.position(from),
            .step = self.stepFor(channel.sounding()),
            .looping = instrument.holds(),
            .loop_from = instrument.loop_from,
        });
    }

    /// How far a voice moves through its samples per output frame.
    ///
    /// A period says the Amiga's clock was divided by twice it, so the
    /// samples came out at that rate. The mixer wants the ratio of that
    /// rate to the one it is running at, which is the same division done
    /// once: no rate is worked out and rounded on the way.
    fn stepFor(self: *const Player, period: u16) u64 {
        if (period == 0) return 0;
        return audio.stepFor(PAULA_HZ, 2 * @as(u32, period) * self.rate);
    }

    /// Hand the channels' pitch and loudness to the mixer.
    ///
    /// Once per tick rather than per command, so a row whose commands
    /// touch the same channel twice writes one answer, and every effect
    /// says what it wants by changing the channel rather than by
    /// reaching into the voices.
    fn applyToVoices(self: *Player) void {
        for (self.channels[0..self.module.shape.channels], 0..) |*channel, index| {
            if (!self.voices.playing(index)) continue;
            self.voices.setStep(index, self.stepFor(channel.sounding()));
            const gains = spread(channel.loudness(), channel.panning, self.module.shape.channels);
            self.voices.setGain(index, gains.left, gains.right);
        }
    }
};

/// Where a channel sits between the ears.
///
/// The Amiga alternated hard left and hard right; this keeps that order
/// but brings them in towards the middle.
fn panningOf(index: usize) u8 {
    const left = index % 4 == 0 or index % 4 == 3;
    const from: u16 = 128;
    return @intCast(if (left) from - SPREAD / 2 else from + SPREAD / 2);
}

/// How much of the output one channel may use.
///
/// Not a whole share each. Channels carry different parts and reach their
/// peaks at different moments, so a sum of four peaks as loudly as about
/// two of them: giving each a quarter would leave half the range unused
/// and the song quiet. The square root of the count is that, and the
/// mixer flattens the rare moment when they do line up.
fn headroom(channels: u8) u32 {
    return std.math.sqrt(@as(u32, @max(channels, 1)) - 1) + 1;
}

/// A channel's loudness split between the ears, and between the channels.
fn spread(volume: u8, panning: u8, channels: u8) struct { left: audio.Gain, right: audio.Gain } {
    const share = headroom(channels);
    const level: u32 = (@as(u32, @min(volume, MAX_VOLUME)) * audio.FULL_GAIN) / (MAX_VOLUME * share);
    const right: u32 = panning;
    const left: u32 = 255 - right;
    return .{
        .left = @intCast((level * left) / 255),
        .right = @intCast((level * right) / 255),
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// A module with one pattern, built in memory, so a test says what the
/// notes are rather than carrying a file to say it.
const Song = struct {
    /// One cell and where it goes, named so both builders take the same
    /// type rather than two anonymous ones that will not unify.
    const Placed = struct { row: u8, channel: u8, note: [4]u8 };

    bytes: [8192]u8 = @splat(0),
    module: mod.Module = .{},
    /// One sample per instrument, long enough to play for a while.
    sound: [256]i8 = @splat(0),

    fn make(cells: []const Placed) Song {
        return Song.of(1, cells);
    }

    fn of(positions: u8, cells: []const Placed) Song {
        var self = Song{};
        @memcpy(self.bytes[0..4], "test");
        // Instrument one: sixty-four words, full volume, no loop.
        self.bytes[42] = 0;
        self.bytes[43] = 64;
        self.bytes[45] = 64;
        self.bytes[950] = positions;
        self.bytes[951] = 0; // restart at the top
        // Every position plays the one pattern this builds.
        for (0..positions) |place| self.bytes[952 + place] = 0;
        @memcpy(self.bytes[1080..1084], "M.K.");

        const patterns = 1084;
        for (cells) |one| {
            const at = patterns + @as(usize, one.row) * 16 + @as(usize, one.channel) * 4;
            @memcpy(self.bytes[at..][0..4], &one.note);
        }
        self.module = mod.Module.read(&self.bytes) catch unreachable;
        return self;
    }

    /// Handed out separately so the module points at this copy rather than
    /// at the one `make` returned.
    fn player(self: *Song, rate: u32) Player {
        self.module = mod.Module.read(&self.bytes) catch unreachable;
        return Player.init(&self.module, rate);
    }
};

/// The four bytes of a cell, from what it means.
fn cell(instrument: u8, period: u12, effect: u4, parameter: u8) [4]u8 {
    return .{
        (instrument & 0xF0) | @as(u8, @intCast(period >> 8)),
        @truncate(period),
        (instrument << 4) | effect,
        parameter,
    };
}

test "the period table is the published one, and its finetunes derive from it" {
    // Three octaves of C at finetune zero.
    try testing.expectEqual(@as(u16, 856), periods[0][0]);
    try testing.expectEqual(@as(u16, 428), periods[0][12]);
    try testing.expectEqual(@as(u16, 214), periods[0][24]);
    try testing.expectEqual(@as(u16, 113), periods[0][35]);

    // An eighth of a semitone up shortens the period, and down lengthens
    // it, by the amounts the published table gives.
    try testing.expectEqual(@as(u16, 850), periods[1][0]);
    try testing.expectEqual(@as(u16, 862), periods[15][0]);
    try testing.expectEqual(@as(u16, 907), periods[8][0]);
}

test "a period is written as its note and octave" {
    try testing.expectEqualStrings("C-1", &spell(856));
    try testing.expectEqualStrings("C-2", &spell(428));
    try testing.expectEqualStrings("C-3", &spell(214));
    try testing.expectEqualStrings("B-3", &spell(113));
    try testing.expectEqualStrings("A-2", &spell(254));
    // Nothing playing is an empty cell rather than a note.
    try testing.expectEqualStrings("...", &spell(0));
}

test "a period reads as the note it is nearest, even when it is not exact" {
    try testing.expectEqual(@as(usize, 0), noteOf(856, 0));
    try testing.expectEqual(@as(usize, 12), noteOf(428, 0));
    // Songs carry periods that are not in the table.
    try testing.expectEqual(@as(usize, 12), noteOf(430, 0));
    try testing.expectEqual(@as(usize, 24), noteOf(213, 0));
}

test "transposing counts in semitones and stops at the top of the table" {
    // C to E is four semitones.
    try testing.expectEqual(periods[0][4], transposed(856, 0, 4));
    try testing.expectEqual(periods[0][7], transposed(856, 0, 7));
    // Past the end holds at the highest note rather than reading past it.
    try testing.expectEqual(periods[0][35], transposed(113, 0, 12));
}

test "a slide stops at the pitches the hardware could reach" {
    try testing.expectEqual(@as(u16, 400), slid(428, -28));
    try testing.expectEqual(MIN_PERIOD, slid(120, -100));
    try testing.expectEqual(MAX_PERIOD, slid(800, 100));
}

test "a volume slide stops at silence and at full" {
    try testing.expectEqual(@as(u8, 40), louder(32, 8));
    try testing.expectEqual(@as(u8, 0), louder(4, -8));
    try testing.expectEqual(MAX_VOLUME, louder(60, 8));
}

test "a tick is a fiftieth of a second at the default tempo" {
    var song = Song.make(&.{});
    var play = song.player(48000);
    // Six ticks a row, 125 beats a minute: 48000 * 5 / 250.
    try testing.expectEqual(@as(u32, 960), play.framesPerTick());

    play.tempo = 250;
    try testing.expectEqual(@as(u32, 480), play.framesPerTick());
}

test "a row lasts as many ticks as the speed says" {
    var song = Song.make(&.{});
    var play = song.player(48000);
    try testing.expectEqual(@as(u8, 0), play.row);

    for (0..DEFAULT_SPEED) |_| play.advanceTick();
    try testing.expectEqual(@as(u8, 1), play.row);
    for (0..DEFAULT_SPEED) |_| play.advanceTick();
    try testing.expectEqual(@as(u8, 2), play.row);
}

test "a note starts its instrument at the pitch the cell asked for" {
    var song = Song.make(&.{.{ .row = 0, .channel = 0, .note = cell(1, 428, 0, 0) }});
    var play = song.player(48000);
    play.advanceTick();

    try testing.expect(play.voices.playing(0));
    try testing.expectEqual(@as(u16, 428), play.channels[0].period);
    try testing.expectEqual(@as(u8, 1), play.channels[0].instrument);
    // Middle C on the Amiga came out at about 8287 samples a second, so
    // against 48000 the source moves about a sixth of a sample a frame.
    const step = play.stepFor(428);
    try testing.expect(step > 11000 and step < 11700);
}

test "a set volume command is obeyed at once" {
    var song = Song.make(&.{
        .{ .row = 0, .channel = 0, .note = cell(1, 428, 0xC, 20) },
    });
    var play = song.player(48000);
    play.advanceTick();
    try testing.expectEqual(@as(u8, 20), play.channels[0].volume);
}

test "a volume slide moves a little on every tick but the first" {
    var song = Song.make(&.{
        .{ .row = 0, .channel = 0, .note = cell(1, 428, 0xC, 40) },
        .{ .row = 1, .channel = 0, .note = cell(0, 0, 0xA, 0x02) },
    });
    var play = song.player(48000);
    for (0..DEFAULT_SPEED) |_| play.advanceTick();
    try testing.expectEqual(@as(u8, 40), play.channels[0].volume);

    // The row's first tick sets it up and the five after it slide.
    for (0..DEFAULT_SPEED) |_| play.advanceTick();
    try testing.expectEqual(@as(u8, 40 - 5 * 2), play.channels[0].volume);
}

test "a slide to a note stops when it gets there" {
    var song = Song.make(&.{
        .{ .row = 0, .channel = 0, .note = cell(1, 428, 0, 0) },
        // Slide towards 214, fast enough to overshoot if it did not stop.
        .{ .row = 1, .channel = 0, .note = cell(0, 214, 3, 100) },
    });
    var play = song.player(48000);
    for (0..DEFAULT_SPEED * 2) |_| play.advanceTick();
    try testing.expectEqual(@as(u16, 214), play.channels[0].period);
}

test "an arpeggio bends the pitch and leaves the note where it was" {
    var song = Song.make(&.{
        .{ .row = 0, .channel = 0, .note = cell(1, 856, 0, 0x47) },
    });
    var play = song.player(48000);
    play.advanceTick(); // tick 0: the note
    try testing.expectEqual(@as(i32, 0), play.channels[0].bend);

    play.advanceTick(); // tick 1: four semitones up
    try testing.expectEqual(periods[0][4], play.channels[0].sounding());
    play.advanceTick(); // tick 2: seven
    try testing.expectEqual(periods[0][7], play.channels[0].sounding());
    play.advanceTick(); // tick 3: back to the note
    try testing.expectEqual(@as(u16, 856), play.channels[0].sounding());

    // And the channel's own pitch never moved.
    try testing.expectEqual(@as(u16, 856), play.channels[0].period);
}

test "a vibrato bends the pitch without walking it away" {
    var song = Song.make(&.{
        .{ .row = 0, .channel = 0, .note = cell(1, 428, 4, 0x48) },
    });
    var play = song.player(48000);
    for (0..DEFAULT_SPEED) |_| play.advanceTick();

    try testing.expectEqual(@as(u16, 428), play.channels[0].period);
    // It moved off the note at some point in the row.
    try testing.expect(play.channels[0].vibrato.at != 0);
}

test "a pattern break moves to the next place at the row it names" {
    var song = Song.make(&.{
        .{ .row = 0, .channel = 0, .note = cell(0, 0, 0xD, 0x10) },
    });
    var play = song.player(48000);
    for (0..DEFAULT_SPEED) |_| play.advanceTick();
    // One position long, so the next place is past the end and the song
    // starts again, at the row the break named.
    try testing.expectEqual(@as(u8, 10), play.row);
    try testing.expect(play.looped);
}

test "a position jump moves to the place it names" {
    var song = Song.of(3, &.{
        .{ .row = 0, .channel = 0, .note = cell(0, 0, 0xB, 2) },
    });
    var play = song.player(48000);
    for (0..DEFAULT_SPEED) |_| play.advanceTick();
    // Without the jump this would be the second row of the first place.
    try testing.expectEqual(@as(u8, 2), play.place);
    try testing.expectEqual(@as(u8, 0), play.row);
}

test "a song that runs off the end starts again where it says to" {
    var song = Song.of(2, &.{
        .{ .row = 0, .channel = 0, .note = cell(0, 0, 0xD, 0) },
    });
    var play = song.player(48000);
    for (0..DEFAULT_SPEED) |_| play.advanceTick();
    try testing.expectEqual(@as(u8, 1), play.place);
    try testing.expect(!play.looped);

    for (0..DEFAULT_SPEED) |_| play.advanceTick();
    try testing.expectEqual(@as(u8, 0), play.place);
    try testing.expect(play.looped);
}

test "a speed command sets ticks below thirty-two and tempo above it" {
    var song = Song.make(&.{
        .{ .row = 0, .channel = 0, .note = cell(0, 0, 0xF, 3) },
        .{ .row = 1, .channel = 0, .note = cell(0, 0, 0xF, 200) },
    });
    var play = song.player(48000);
    play.advanceTick();
    try testing.expectEqual(@as(u8, 3), play.speed);

    for (0..3) |_| play.advanceTick();
    try testing.expectEqual(@as(u8, 200), play.tempo);
    // And the speed it was set to is still what a row lasts.
    try testing.expectEqual(@as(u8, 3), play.speed);
}

test "a cut silences the channel part way through its row" {
    var song = Song.make(&.{
        .{ .row = 0, .channel = 0, .note = cell(1, 428, 0xE, 0xC2) },
    });
    var play = song.player(48000);
    play.advanceTick();
    play.advanceTick();
    try testing.expect(play.channels[0].volume > 0);
    play.advanceTick(); // tick two
    try testing.expectEqual(@as(u8, 0), play.channels[0].volume);
}

test "a delayed note does not start until its tick" {
    var song = Song.make(&.{
        .{ .row = 0, .channel = 0, .note = cell(1, 428, 0xE, 0xD3) },
    });
    var play = song.player(48000);
    play.advanceTick();
    try testing.expect(!play.voices.playing(0));
    play.advanceTick();
    play.advanceTick();
    try testing.expect(!play.voices.playing(0));
    play.advanceTick(); // tick three
    try testing.expect(play.voices.playing(0));
}

test "rendering fills what it is given and moves the song along" {
    var song = Song.make(&.{
        .{ .row = 0, .channel = 0, .note = cell(1, 428, 0xC, 64) },
    });
    var play = song.player(48000);
    // Two ticks' worth, which is short of a row.
    var out: [960 * 2 * 2]i16 = @splat(0);
    play.render(&out);
    try testing.expectEqual(@as(u8, 0), play.row);
    try testing.expectEqual(@as(u8, 2), play.tick);

    // And on to the end of the row.
    play.render(&out);
    play.render(&out);
    try testing.expectEqual(@as(u8, 1), play.row);
}

test "a channel gets the share of the output that its count leaves it" {
    // Four channels peak about as loudly as two, so each gets a half.
    try testing.expectEqual(@as(u32, 2), headroom(4));
    try testing.expectEqual(@as(u32, 3), headroom(6));
    try testing.expectEqual(@as(u32, 3), headroom(8));
    // One channel gets all of it, and no count divides by nothing.
    try testing.expectEqual(@as(u32, 1), headroom(1));
    try testing.expectEqual(@as(u32, 1), headroom(0));

    // Half of full, centred, is a quarter on each side.
    const one = spread(MAX_VOLUME, 128, 4);
    try testing.expect(one.left > 55 and one.left < 70);
    try testing.expect(one.right > 55 and one.right < 70);
}

test "a channel's loudness is split between the ears by where it sits" {
    const middle = spread(64, 128, 4);
    try testing.expect(middle.left > 0 and middle.right > 0);
    try testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(middle.left)),
        @as(f32, @floatFromInt(middle.right)),
        2,
    );

    const leftward = spread(64, panningOf(0), 4);
    try testing.expect(leftward.left > leftward.right);
    const rightward = spread(64, panningOf(1), 4);
    try testing.expect(rightward.right > rightward.left);

    // Silence is silent on both sides.
    const quiet = spread(0, 128, 4);
    try testing.expectEqual(@as(audio.Gain, 0), quiet.left);
    try testing.expectEqual(@as(audio.Gain, 0), quiet.right);
}

test "the channels alternate left and right the way the hardware did" {
    try testing.expect(panningOf(0) < 128);
    try testing.expect(panningOf(1) > 128);
    try testing.expect(panningOf(2) > 128);
    try testing.expect(panningOf(3) < 128);
    // And it repeats for a file with more of them.
    try testing.expectEqual(panningOf(0), panningOf(4));
}
