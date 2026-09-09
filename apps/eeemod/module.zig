//! A tracker module, as the file has it.
//!
//! The format is an Amiga one and reads like it: numbers are big endian,
//! lengths are counted in words rather than bytes, and what a file holds
//! is said by four letters two thirds of the way in rather than at the
//! front. Callers above this file see none of that.
//!
//! Nothing is copied and nothing is allocated. A module is a view over the
//! bytes the caller read, so instruments point into that block and pattern
//! cells are decoded as they are played. Decoding every cell up front
//! would hold about a quarter of a megabyte to avoid a shift and a mask a
//! few times a second.

const std = @import("std");

/// Rows in every pattern. The format stores a row number in six bits and
/// every tracker that wrote these files used sixty-four.
pub const ROWS = 64;

/// Instruments a file may describe, and places in the order it may play.
pub const INSTRUMENTS = 31;
pub const ORDER = 128;

/// The most channels this reads. Four is what the Amiga had and what
/// nearly every file uses; the signature can say six or eight.
pub const MAX_CHANNELS = 8;

/// Sizes on disk, each written from the one below it so a pattern is
/// always as long as its rows add up to.
const CELL_BYTES = 4;
fn rowBytes(channels: u8) usize {
    return @as(usize, channels) * CELL_BYTES;
}
fn patternBytes(channels: u8) usize {
    return ROWS * rowBytes(channels);
}

pub const Error = error{
    /// Not enough bytes to be a module of the shape its own header claims.
    TooShort,
    /// The header is there but says something impossible.
    Malformed,
};

// ---------------------------------------------------------------------------
// What a file holds
// ---------------------------------------------------------------------------

/// How many channels play at once and how many instruments the file
/// describes. One signature says both, so they are read together.
pub const Shape = struct {
    channels: u8 = 4,
    instruments: u8 = INSTRUMENTS,

    /// A file with no signature: fifteen instruments, and the pattern
    /// data starts where the signature would have been.
    pub const original = Shape{ .channels = 4, .instruments = 15 };
};

/// The signatures this reads, and what each one means.
///
/// A table rather than a switch: adding a signature is then one line in
/// one place.
const signatures = [_]struct { letters: *const [4:0]u8, shape: Shape }{
    // "M.K." is the one that made thirty-one instruments possible.
    // "M!K!" is the same for a song with more than sixty-four patterns.
    .{ .letters = "M.K.", .shape = .{} },
    .{ .letters = "M!K!", .shape = .{} },
    .{ .letters = "M&K!", .shape = .{} },
    .{ .letters = "FLT4", .shape = .{} },
    .{ .letters = "4CHN", .shape = .{} },
    .{ .letters = "6CHN", .shape = .{ .channels = 6 } },
    .{ .letters = "8CHN", .shape = .{ .channels = 8 } },
    .{ .letters = "FLT8", .shape = .{ .channels = 8 } },
    .{ .letters = "CD81", .shape = .{ .channels = 8 } },
    .{ .letters = "OKTA", .shape = .{ .channels = 8 } },
};

/// What a signature means, or none when it is not one this reads. The
/// oldest files have no signature at all.
fn shapeOf(letters: *const [4]u8) ?Shape {
    for (signatures) |known| {
        if (std.mem.eql(u8, letters, known.letters)) return known.shape;
    }
    return null;
}

/// One instrument: its samples, how loud it plays, how far off pitch it
/// is tuned, and which part of it repeats when a note is held.
pub const Instrument = struct {
    name: [22]u8 = @splat(0),
    /// The samples themselves, signed, as many as the header said and no
    /// more than the file actually carries.
    data: []const i8 = &.{},
    /// Where a held note repeats from, and how long the repeated part
    /// is. Both in samples; the file counts them in words.
    loop_from: usize = 0,
    loop_len: usize = 0,
    /// Eighths of a semitone off, as a signed nibble.
    finetune: i4 = 0,
    /// Sixty-four is as loud as it goes.
    volume: u8 = 0,

    /// Whether a note on this instrument repeats instead of ending.
    ///
    /// A loop of one word means there is no loop. Trackers use the first
    /// word for their own bookkeeping, so every instrument has one
    /// whether it repeats or not.
    pub fn holds(self: Instrument) bool {
        return self.loop_len > 2 and self.loop_from + self.loop_len <= self.data.len;
    }

    /// What is played: the whole sound, or everything up to the end of
    /// the loop. A held note never plays past its loop, so anything after
    /// it is not part of the sound.
    pub fn sounding(self: Instrument) []const i8 {
        if (!self.holds()) return self.data;
        return self.data[0 .. self.loop_from + self.loop_len];
    }
};

// ---------------------------------------------------------------------------
// A cell
// ---------------------------------------------------------------------------

/// The four bytes of one cell, read as a single big-endian number.
///
/// A packed struct because the fields do not sit on byte boundaries: the
/// instrument number is split into two nibbles a byte and a half apart,
/// with two twelve-bit fields between them. Written out once here, so
/// nothing else has to shift or mask.
const Cell = packed struct(u32) {
    parameter: u8,
    effect: u4,
    instrument_low: u4,
    period: u12,
    instrument_high: u4,
};

/// One channel's cell in a row: which instrument, at what pitch, and
/// what effect to apply.
pub const Note = struct {
    /// The instrument to start, or none to keep the one the channel is
    /// already playing. Numbered from one.
    instrument: ?u8 = null,
    /// The pitch, as the Amiga period, or none to keep the channel's
    /// current pitch.
    period: ?u12 = null,
    command: Command = .none,

    pub fn read(bytes: *const [CELL_BYTES]u8) Note {
        const cell: Cell = @bitCast(std.mem.readInt(u32, bytes, .big));
        const instrument = (@as(u8, cell.instrument_high) << 4) | cell.instrument_low;
        return .{
            .instrument = if (instrument == 0) null else instrument,
            .period = if (cell.period == 0) null else cell.period,
            .command = Command.read(cell.effect, cell.parameter),
        };
    }
};

/// The shape of a vibrato or tremolo, and whether a new note restarts it.
pub const Waveform = struct {
    wave: Wave = .sine,
    /// Whether a new note puts the oscillation back to its start.
    retrigger: bool = true,

    pub const Wave = enum(u2) { sine, ramp_down, square, random };

    pub fn read(value: u4) Waveform {
        return .{
            .wave = @enumFromInt(@as(u2, @truncate(value))),
            .retrigger = value & 0b100 == 0,
        };
    }
};

/// How fast a vibrato or tremolo moves, and how far.
pub const Oscillation = struct { speed: u4 = 0, depth: u4 = 0 };

/// A volume slide, up or down but never both.
///
/// Kept as the two nibbles from the file rather than as a signed step: a
/// command that repeats the previous slide is only distinguishable from
/// one that slides by nothing when both nibbles are visible.
pub const Slide = struct {
    up: u4 = 0,
    down: u4 = 0,

    /// How much a tick of this moves the volume.
    pub fn step(self: Slide) i8 {
        // Both set is not legal. Trackers that wrote it meant the up
        // slide, so that is what this takes.
        if (self.up != 0) return @intCast(self.up);
        return -@as(i8, self.down);
    }
};

/// What a cell asks its channel to do.
///
/// One value per effect, so the player switches over them exhaustively.
/// An effect the player does not handle fails the build rather than
/// playing the wrong note.
pub const Command = union(enum) {
    none,
    /// Play the note, then this many semitones above it, then that
    /// many, evenly spaced across the row.
    arpeggio: struct { first: u4, second: u4 },
    slide_up: u8,
    slide_down: u8,
    /// Slide towards the note in the cell and stop there. Zero repeats
    /// the previous slide.
    slide_to_note: u8,
    vibrato: Oscillation,
    /// Continue the slide to the note, and slide the volume as well.
    slide_to_note_and_volume: Slide,
    /// Continue the vibrato, and slide the volume as well.
    vibrato_and_volume: Slide,
    tremolo: Oscillation,
    /// Zero is hard left, 128 is centre, 255 is hard right.
    set_panning: u8,
    /// Start the sound this far in, in steps of 256 samples.
    sample_offset: u8,
    volume_slide: Slide,
    /// Continue the song from this place in the order.
    position_jump: u8,
    set_volume: u8,
    /// Stop this pattern and start the next at this row.
    pattern_break: u8,
    /// Ticks per row below 32, beats per minute above it.
    set_speed: u8,

    /// A hardware filter this machine does not have.
    set_filter: bool,
    fine_slide_up: u4,
    fine_slide_down: u4,
    /// Whether a slide to a note steps in semitones rather than smoothly.
    set_glissando: bool,
    set_vibrato_waveform: Waveform,
    set_finetune: i4,
    /// Zero marks the start of a loop; anything else jumps back to that
    /// mark and repeats that many times.
    loop_pattern: u4,
    set_tremolo_waveform: Waveform,
    /// Start the sound again every this many ticks.
    retrigger: u4,
    fine_volume_up: u4,
    fine_volume_down: u4,
    /// Silence the channel after this many ticks of the row.
    cut: u4,
    /// Wait this many ticks before starting the sound.
    delay_note: u4,
    /// Hold this row for this many extra rows' worth of time.
    delay_pattern: u4,
    /// Negate the looped part of the sound as it plays.
    invert_loop: u4,

    /// The command a cell's effect number and parameter mean.
    pub fn read(effect: u4, parameter: u8) Command {
        const high: u4 = @truncate(parameter >> 4);
        const low: u4 = @truncate(parameter);
        const slide = Slide{ .up = high, .down = low };
        const swing = Oscillation{ .speed = high, .depth = low };

        return switch (effect) {
            0x0 => if (parameter == 0) .none else .{ .arpeggio = .{ .first = high, .second = low } },
            0x1 => .{ .slide_up = parameter },
            0x2 => .{ .slide_down = parameter },
            0x3 => .{ .slide_to_note = parameter },
            0x4 => .{ .vibrato = swing },
            0x5 => .{ .slide_to_note_and_volume = slide },
            0x6 => .{ .vibrato_and_volume = slide },
            0x7 => .{ .tremolo = swing },
            0x8 => .{ .set_panning = parameter },
            0x9 => .{ .sample_offset = parameter },
            0xA => .{ .volume_slide = slide },
            0xB => .{ .position_jump = parameter },
            0xC => .{ .set_volume = parameter },
            // The row is stored as two decimal digits in one byte, so
            // row 32 is written 0x32.
            0xD => .{ .pattern_break = @min(ROWS - 1, @as(u8, high) * 10 + @as(u8, low)) },
            0xE => readExtended(high, low),
            0xF => .{ .set_speed = parameter },
        };
    }

    /// The commands that use the first nibble of the parameter to say
    /// which one they are, leaving the second nibble as the argument.
    fn readExtended(which: u4, value: u4) Command {
        return switch (which) {
            0x0 => .{ .set_filter = value == 0 },
            0x1 => .{ .fine_slide_up = value },
            0x2 => .{ .fine_slide_down = value },
            0x3 => .{ .set_glissando = value != 0 },
            0x4 => .{ .set_vibrato_waveform = Waveform.read(value) },
            0x5 => .{ .set_finetune = @bitCast(value) },
            0x6 => .{ .loop_pattern = value },
            0x7 => .{ .set_tremolo_waveform = Waveform.read(value) },
            // Nothing is documented at eight.
            0x8 => .none,
            0x9 => .{ .retrigger = value },
            0xA => .{ .fine_volume_up = value },
            0xB => .{ .fine_volume_down = value },
            0xC => .{ .cut = value },
            0xD => .{ .delay_note = value },
            0xE => .{ .delay_pattern = value },
            0xF => .{ .invert_loop = value },
        };
    }
};

// ---------------------------------------------------------------------------
// The file
// ---------------------------------------------------------------------------

pub const Module = struct {
    title: [20]u8 = @splat(0),
    shape: Shape = .{},
    instruments: [INSTRUMENTS]Instrument = @splat(.{}),
    /// Which pattern plays at each place in the song, and how many
    /// places there are.
    order: [ORDER]u8 = @splat(0),
    length: u8 = 0,
    /// Where a song restarts when it runs off the end.
    restart: u8 = 0,
    /// How many patterns are stored: one past the highest the order
    /// names, since nothing above that is in the file.
    patterns: u8 = 0,
    /// Every pattern's cells, laid out as the file has them.
    cells: []const u8 = &.{},

    /// One channel's cell.
    ///
    /// Anything out of range gives an empty cell. Some songs jump to a
    /// pattern that is not stored, and playing on is better than
    /// stopping.
    pub fn note(self: *const Module, pattern: usize, row: usize, channel: usize) Note {
        if (pattern >= self.patterns or row >= ROWS or channel >= self.shape.channels) return .{};
        const at = pattern * patternBytes(self.shape.channels) +
            row * rowBytes(self.shape.channels) + channel * CELL_BYTES;
        if (at + CELL_BYTES > self.cells.len) return .{};
        return Note.read(self.cells[at..][0..CELL_BYTES]);
    }

    /// The instrument a note names, or none if the file does not
    /// describe it.
    pub fn instrument(self: *const Module, number: u8) ?*const Instrument {
        if (number == 0 or number > self.shape.instruments) return null;
        return &self.instruments[number - 1];
    }

    /// The title, without its padding.
    pub fn name(self: *const Module) []const u8 {
        return trimmed(&self.title);
    }

    /// Read `bytes` as a module. The result points into `bytes`, so they
    /// must outlive it.
    pub fn read(bytes: []const u8) Error!Module {
        var self = Module{};

        // The signature sits after the header of a thirty-one instrument
        // file, so look for it at that offset.
        const with_31 = header(INSTRUMENTS);
        self.shape = found: {
            if (bytes.len >= with_31 + 4) {
                if (shapeOf(bytes[with_31..][0..4])) |shape| break :found shape;
            }
            break :found Shape.original;
        };

        const described = self.shape.instruments;
        const heading = header(described);
        // Only count the signature when there is one. A file without it
        // starts its patterns where it would have been.
        const after = heading + @as(usize, if (described == INSTRUMENTS) 4 else 0);
        if (bytes.len < after) return Error.TooShort;

        @memcpy(&self.title, bytes[0..20]);

        // How long each sample is meant to be. Local rather than stored
        // on the instrument: it differs from what the file actually
        // carries, and is only needed while handing the samples out.
        var promised: [INSTRUMENTS]usize = @splat(0);
        var at: usize = 20;
        for (self.instruments[0..described], promised[0..described]) |*one, *length| {
            length.* = readInstrument(one, bytes[at..][0..30]);
            at += 30;
        }

        self.length = bytes[at];
        self.restart = bytes[at + 1];
        @memcpy(&self.order, bytes[at + 2 ..][0..ORDER]);
        if (self.length == 0 or self.length > ORDER) return Error.Malformed;

        // Nothing above the highest pattern in the order is stored.
        var highest: u8 = 0;
        for (self.order) |which| highest = @max(highest, which);
        self.patterns = highest +| 1;

        const stored = @as(usize, self.patterns) * patternBytes(self.shape.channels);
        if (bytes.len < after + stored) return Error.TooShort;
        self.cells = bytes[after..][0..stored];

        // The samples follow the patterns, in instrument order. A file
        // shorter than its headers promise gives each instrument what is
        // actually there: a song is still worth playing with its last
        // sample missing.
        var sounds = bytes[after + stored ..];
        for (self.instruments[0..described], promised[0..described]) |*one, length| {
            const take = @min(length, sounds.len);
            one.data = @ptrCast(sounds[0..take]);
            sounds = sounds[take..];
        }
        return self;
    }

    /// How many bytes come before the pattern data, signature aside.
    fn header(instruments: u8) usize {
        return 20 + @as(usize, instruments) * 30 + 1 + 1 + ORDER;
    }
};

/// Read one instrument's thirty bytes and return how long its sample is
/// meant to be. The format counts lengths in words, and this is the only
/// place that knows it.
fn readInstrument(into: *Instrument, bytes: *const [30]u8) usize {
    @memcpy(&into.name, bytes[0..22]);
    into.finetune = @bitCast(@as(u4, @truncate(bytes[24])));
    into.volume = @min(bytes[25], 64);
    into.loop_from = words(bytes[26..28]);
    into.loop_len = words(bytes[28..30]);
    return words(bytes[22..24]);
}

/// A big-endian count of words, in samples.
fn words(field: *const [2]u8) usize {
    return @as(usize, std.mem.readInt(u16, field, .big)) * 2;
}

/// A fixed-width field's text, without trailing nulls or spaces. Files
/// exist written with either.
pub fn trimmed(field: []const u8) []const u8 {
    var end: usize = 0;
    for (field, 0..) |byte, i| {
        if (byte != 0 and byte != ' ') end = i + 1;
    }
    return field[0..end];
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// A module built in memory. These tests are about the file layout, so a
/// real song would only add noise.
fn built(comptime channels: u8, comptime patterns: u8) [16384]u8 {
    var bytes: [16384]u8 = @splat(0);
    @memcpy(bytes[0..5], "tune ");

    // One instrument: two words long, full volume, no loop.
    @memcpy(bytes[20..24], "bass");
    bytes[42] = 0; // length high
    bytes[43] = 2; // two words
    bytes[44] = 0; // finetune
    bytes[45] = 64; // volume

    bytes[950] = patterns; // song length
    bytes[951] = 127; // restart
    var i: usize = 0;
    while (i < patterns) : (i += 1) bytes[952 + i] = @intCast(i);

    const letters: *const [4]u8 = switch (channels) {
        4 => "M.K.",
        6 => "6CHN",
        else => "8CHN",
    };
    @memcpy(bytes[1080..1084], letters);
    return bytes;
}

test "the signature says how many channels and instruments" {
    var four = built(4, 1);
    const module = try Module.read(&four);
    try testing.expectEqual(@as(u8, 4), module.shape.channels);
    try testing.expectEqual(@as(u8, 31), module.shape.instruments);
    try testing.expectEqualStrings("tune", module.name());

    var six = built(6, 1);
    const wider = try Module.read(&six);
    try testing.expectEqual(@as(u8, 6), wider.shape.channels);
}

test "a file with no signature reads as the older shape" {
    var bytes: [4096]u8 = @splat(0);
    bytes[600 - 130] = 1; // song length, where fifteen instruments put it
    // Nothing at 1080, so nothing names a shape.
    const module = try Module.read(&bytes);
    try testing.expectEqual(@as(u8, 15), module.shape.instruments);
    try testing.expectEqual(@as(u8, 4), module.shape.channels);
}

test "a cell's fields are read from the bytes they are split across" {
    // Instrument 31 (0x1F), period 428, effect C, parameter 0x40.
    const bytes = [_]u8{ 0x11, 0xAC, 0xFC, 0x40 };
    const note = Note.read(&bytes);
    try testing.expectEqual(@as(?u8, 31), note.instrument);
    try testing.expectEqual(@as(?u12, 428), note.period);
    try testing.expectEqual(Command{ .set_volume = 0x40 }, note.command);
}

test "an empty cell asks for nothing" {
    const note = Note.read(&[_]u8{ 0, 0, 0, 0 });
    try testing.expectEqual(@as(?u8, null), note.instrument);
    try testing.expectEqual(@as(?u12, null), note.period);
    try testing.expectEqual(Command.none, note.command);
}

test "each effect number reads as its own command" {
    try testing.expectEqual(
        Command{ .arpeggio = .{ .first = 4, .second = 7 } },
        Command.read(0x0, 0x47),
    );
    // Arpeggio with no parameter is not an arpeggio.
    try testing.expectEqual(Command.none, Command.read(0x0, 0x00));
    try testing.expectEqual(Command{ .slide_up = 0x0A }, Command.read(0x1, 0x0A));
    try testing.expectEqual(
        Command{ .vibrato = .{ .speed = 4, .depth = 8 } },
        Command.read(0x4, 0x48),
    );
    try testing.expectEqual(
        Command{ .volume_slide = .{ .up = 0, .down = 2 } },
        Command.read(0xA, 0x02),
    );
    // A break to row 32 is written as the digits three and two.
    try testing.expectEqual(Command{ .pattern_break = 32 }, Command.read(0xD, 0x32));
    try testing.expectEqual(Command{ .set_speed = 6 }, Command.read(0xF, 0x06));
}

test "an extended effect uses a nibble to say which it is" {
    try testing.expectEqual(Command{ .fine_slide_up = 3 }, Command.read(0xE, 0x13));
    try testing.expectEqual(Command{ .cut = 2 }, Command.read(0xE, 0xC2));
    try testing.expectEqual(Command{ .delay_note = 4 }, Command.read(0xE, 0xD4));
    // A finetune of fifteen is minus one, being a signed nibble.
    try testing.expectEqual(Command{ .set_finetune = -1 }, Command.read(0xE, 0x5F));
    const wave = Command.read(0xE, 0x46);
    try testing.expectEqual(Waveform.Wave.square, wave.set_vibrato_waveform.wave);
    try testing.expect(!wave.set_vibrato_waveform.retrigger);
}

test "a volume slide goes one way even when both nibbles are set" {
    try testing.expectEqual(@as(i8, 3), (Slide{ .up = 3 }).step());
    try testing.expectEqual(@as(i8, -5), (Slide{ .down = 5 }).step());
    try testing.expectEqual(@as(i8, 0), (Slide{}).step());
    // Both is not legal, and what was meant is the one that raises it.
    try testing.expectEqual(@as(i8, 2), (Slide{ .up = 2, .down = 7 }).step());
}

test "the pattern count comes from the order, not the file size" {
    var bytes = built(4, 3);
    bytes[952] = 0;
    bytes[953] = 5;
    bytes[954] = 2;
    const module = try Module.read(&bytes);
    try testing.expectEqual(@as(u8, 6), module.patterns);
    try testing.expectEqual(@as(u8, 3), module.length);
}

test "a cell outside the song reads as empty" {
    var bytes = built(4, 1);
    const module = try Module.read(&bytes);
    try testing.expectEqual(Command.none, module.note(99, 0, 0).command);
    try testing.expectEqual(Command.none, module.note(0, 999, 0).command);
    try testing.expectEqual(Command.none, module.note(0, 0, 7).command);
}

test "an instrument only loops when its loop is longer than one word" {
    var one = Instrument{ .data = &[_]i8{0} ** 100, .loop_from = 10, .loop_len = 40 };
    try testing.expect(one.holds());
    try testing.expectEqual(@as(usize, 50), one.sounding().len);

    // A loop of one word is how the format says there is none.
    one.loop_len = 2;
    try testing.expect(!one.holds());
    try testing.expectEqual(@as(usize, 100), one.sounding().len);

    // A loop that runs off the end of what the file carried is not one.
    one.loop_from = 90;
    one.loop_len = 40;
    try testing.expect(!one.holds());
}

test "a name is read without its padding" {
    try testing.expectEqualStrings("space_debris", trimmed("space_debris\x00\x00\x00"));
    try testing.expectEqualStrings("bass", trimmed("bass    "));
    try testing.expectEqualStrings("", trimmed("\x00\x00\x00"));
}

test "a file shorter than its header promises is refused" {
    var bytes: [200]u8 = @splat(0);
    try testing.expectError(Error.TooShort, Module.read(&bytes));
}

test "a song with no length is refused" {
    var bytes = built(4, 1);
    bytes[950] = 0;
    try testing.expectError(Error.Malformed, Module.read(&bytes));
}
