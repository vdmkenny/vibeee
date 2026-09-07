//! The escape-sequence state machine.
//!
//! Consumes bytes and reports what they mean. It knows nothing about a screen:
//! it turns a stream into printable characters, control characters, and
//! parsed sequences, and hands each to a terminal that decides what to do.
//!
//! Shared, because there are two terminals here and there is one grammar. The
//! kernel console draws into a text grid and `eterm` draws into a window, but
//! what `ESC [ 2 J` means is not either one's opinion, and a program writing
//! it should not have to know which is on the other end.
//!
//! Structured as an explicit state machine because that is what the input is.
//! An escape sequence arrives split across reads whenever the program on the
//! other end writes it in pieces, so parsing has to survive stopping anywhere.
//!
//! UTF-8 is decoded here too, for the same reason: a multi-byte character can
//! be split across reads.

const std = @import("std");

/// The private modes this system's terminals answer to beyond the DEC set.
///
/// Both terminals honour these, because a program should not have to know
/// which one is on the other end of its pipe.
pub const private_mode = struct {
    /// The program manages its own input line: it echoes and edits, so the
    /// terminal delivers keys as they are pressed and draws none of them
    /// itself. A shell's line editor asks for this, the same raw handling it
    /// asks the kernel console for with `ttyMode`, carried in-band so it
    /// reaches a terminal at the far end of a pipe just as well.
    ///
    /// Chosen next to bracketed paste (2004), which is the nearest thing in
    /// spirit: both are a program telling the terminal how to treat what is
    /// typed. Not a standard code; this system's own terminals are the only
    /// ones that will meet it.
    pub const app_line_edit = 2005;

    /// The sequences that turn it on and off, written once so the program
    /// that sends them and the terminals that read them cannot disagree.
    pub const app_line_edit_on = "\x1b[?2005h";
    pub const app_line_edit_off = "\x1b[?2005l";
};

/// Most numeric parameters a sequence may carry. The real limit is what SGR
/// uses, and sixteen is more than anything sends in one go.
pub const MAX_PARAMS = 16;

/// The longest intermediate or string payload kept. Longer ones are parsed and
/// discarded rather than buffered, since nothing acts on them.
pub const MAX_STRING = 64;

pub const Action = union(enum) {
    /// A character to put on the screen.
    print: u32,
    /// A C0 control that is not part of a sequence.
    control: u8,
    /// `CSI params... final`, with `private` set for the `?` forms.
    csi: Csi,
    /// `ESC final`, the two-character sequences.
    escape: u8,
    /// An operating system command, `ESC ] params ; text BEL`.
    osc: Osc,
};

pub const Csi = struct {
    params: [MAX_PARAMS]u32,
    count: usize,
    /// True for `CSI ? ...`, the DEC private modes.
    private: bool,
    /// The character before the final one, `SP` in `CSI SP q` and so on.
    intermediate: u8,
    final: u8,

    /// Parameter `index`, or `fallback` when it was omitted or zero.
    ///
    /// Omitted and zero mean the same thing in almost every sequence, which is
    /// why they are folded here rather than at each use.
    pub fn get(self: Csi, index: usize, fallback: u32) u32 {
        if (index >= self.count) return fallback;
        return if (self.params[index] == 0) fallback else self.params[index];
    }

    /// Parameter `index` with zero kept, for the sequences where zero is a
    /// distinct choice rather than an absent one.
    pub fn raw(self: Csi, index: usize) u32 {
        return if (index >= self.count) 0 else self.params[index];
    }
};

pub const Osc = struct {
    command: u32,
    text: []const u8,
};

const State = enum {
    ground,
    escape,
    csi,
    /// Consuming an OSC string, waiting for BEL or ST.
    osc,
    /// Consuming a string nothing acts on: DCS, PM, APC.
    ignore,
    /// The byte after `ESC (` and friends, a character-set choice.
    charset,
};

pub const Parser = struct {
    state: State = .ground,

    params: [MAX_PARAMS]u32 = @splat(0),
    param_count: usize = 0,
    /// The sequence in hand named more parameters than are held. Read to
    /// its end and then dropped: what it asked for cannot be known, and a
    /// sequence acted on with its last parameter holding the digits of
    /// several would move the cursor somewhere nobody asked for.
    too_many: bool = false,
    private: bool = false,
    intermediate: u8 = 0,

    string: [MAX_STRING]u8 = @splat(0),
    string_len: usize = 0,
    /// The last byte was ESC, so an ST (`ESC \`) can end a string.
    string_escape: bool = false,

    /// Partially decoded UTF-8.
    pending: u32 = 0,
    pending_left: u8 = 0,

    /// Feed one byte. Returns what it completed, or null if more is needed.
    pub fn next(self: *Parser, byte: u8) ?Action {
        return switch (self.state) {
            .ground => self.ground(byte),
            .escape => self.escape(byte),
            .csi => self.csi(byte),
            .osc => self.consumeString(byte, true),
            .ignore => self.consumeString(byte, false),
            .charset => blk: {
                // The choice itself is ignored: the only sets anything selects
                // here are ASCII and the line-drawing set, and the font covers
                // the box-drawing characters directly.
                self.state = .ground;
                break :blk null;
            },
        };
    }

    fn ground(self: *Parser, byte: u8) ?Action {
        if (self.pending_left > 0) return self.continuation(byte);

        if (byte == 0x1B) {
            self.reset();
            self.state = .escape;
            return null;
        }
        if (byte < 0x20 or byte == 0x7F) return .{ .control = byte };
        if (byte < 0x80) return .{ .print = byte };

        // A leading byte: remember how many follow. An invalid one is shown as
        // a replacement character rather than dropped, so a stream that is not
        // UTF-8 still produces something a person can see.
        const length: u8 = if (byte & 0xE0 == 0xC0)
            1
        else if (byte & 0xF0 == 0xE0)
            2
        else if (byte & 0xF8 == 0xF0)
            3
        else
            return .{ .print = 0xFFFD };

        const mask: u8 = switch (length) {
            1 => 0x1F,
            2 => 0x0F,
            else => 0x07,
        };
        self.pending = byte & mask;
        self.pending_left = length;
        return null;
    }

    fn continuation(self: *Parser, byte: u8) ?Action {
        if (byte & 0xC0 != 0x80) {
            // A leading byte where a continuation belonged: the character
            // before it was truncated. Report that and re-read this one.
            self.pending_left = 0;
            self.pending = 0;
            return self.ground(byte) orelse .{ .print = 0xFFFD };
        }

        self.pending = (self.pending << 6) | (byte & 0x3F);
        self.pending_left -= 1;
        if (self.pending_left > 0) return null;

        const value = self.pending;
        self.pending = 0;
        return .{ .print = value };
    }

    fn escape(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            '[' => {
                self.state = .csi;
                return null;
            },
            ']' => {
                self.state = .osc;
                self.string_len = 0;
                return null;
            },
            'P', 'X', '^', '_' => {
                self.state = .ignore;
                self.string_len = 0;
                return null;
            },
            '(', ')', '*', '+' => {
                self.state = .charset;
                return null;
            },
            else => {
                self.state = .ground;
                return .{ .escape = byte };
            },
        }
    }

    fn csi(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            '0'...'9' => {
                if (self.param_count == 0) self.param_count = 1;
                const slot = @min(self.param_count - 1, MAX_PARAMS - 1);
                // Saturating: a parameter larger than the screen is already
                // clamped by whoever acts on it, and wrapping would turn a
                // huge number into a small valid one.
                self.params[slot] = self.params[slot] *| 10 +| (byte - '0');
                return null;
            },
            ';' => {
                // An omitted parameter still occupies its place, so `CSI ;5H`
                // has two of them and the second is the one that means 5.
                if (self.param_count == 0) self.param_count = 1;
                if (self.param_count < MAX_PARAMS) {
                    self.param_count += 1;
                    self.params[self.param_count - 1] = 0;
                } else {
                    self.too_many = true;
                }
                return null;
            },
            // Sub-parameters, as in `CSI 38:2:r:g:b m`. Treated as separators,
            // which gives the same answer for every sequence anything sends.
            ':' => return self.csi(';'),
            '?', '<', '=', '>' => {
                self.private = true;
                return null;
            },
            ' ', '!', '"', '$', '\'', '*', '+' => {
                self.intermediate = byte;
                return null;
            },
            0x40...0x7E => {
                self.state = .ground;
                if (self.too_many) return null;
                return .{ .csi = .{
                    .params = self.params,
                    .count = self.param_count,
                    .private = self.private,
                    .intermediate = self.intermediate,
                    .final = byte,
                } };
            },
            0x1B => {
                self.reset();
                self.state = .escape;
                return null;
            },
            // A control character inside a sequence is acted on where it
            // stands, which is what every real terminal does and what a
            // program that emits one expects.
            else => return if (byte < 0x20) .{ .control = byte } else null,
        }
    }

    fn consumeString(self: *Parser, byte: u8, report: bool) ?Action {
        if (self.string_escape) {
            self.string_escape = false;
            if (byte == '\\') return self.endString(report);
            // ESC then something else: the string is over and that something
            // starts a new sequence.
            self.state = .escape;
            return self.escape(byte);
        }

        switch (byte) {
            0x07 => return self.endString(report),
            0x1B => {
                self.string_escape = true;
                return null;
            },
            else => {
                if (self.string_len < MAX_STRING) {
                    self.string[self.string_len] = byte;
                    self.string_len += 1;
                }
                return null;
            },
        }
    }

    fn endString(self: *Parser, report: bool) ?Action {
        self.state = .ground;
        if (!report) return null;

        // `OSC n ; text`. Everything before the first semicolon is the number.
        const text = self.string[0..self.string_len];
        var command: u32 = 0;
        var rest = text;
        if (std.mem.indexOfScalar(u8, text, ';')) |i| {
            for (text[0..i]) |c| {
                if (c < '0' or c > '9') break;
                command = command *| 10 +| (c - '0');
            }
            rest = text[i + 1 ..];
        }

        return .{ .osc = .{ .command = command, .text = rest } };
    }

    fn reset(self: *Parser) void {
        self.params = @splat(0);
        self.param_count = 0;
        self.too_many = false;
        self.private = false;
        self.intermediate = 0;
        self.string_len = 0;
        self.string_escape = false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Everything the parser completed while reading `text`.
fn readAll(parser: *Parser, text: []const u8, into: []Action) []const Action {
    var n: usize = 0;
    for (text) |byte| {
        if (parser.next(byte)) |action| {
            if (n < into.len) into[n] = action;
            n += 1;
        }
    }
    return into[0..@min(n, into.len)];
}

test "a sequence's parameters come back in the places it named them" {
    var parser = Parser{};
    var actions: [4]Action = undefined;
    const got = readAll(&parser, "\x1b[3;5H", &actions);

    try testing.expectEqual(@as(usize, 1), got.len);
    const csi = got[0].csi;
    try testing.expectEqual(@as(u8, 'H'), csi.final);
    try testing.expectEqual(@as(usize, 2), csi.count);
    try testing.expectEqual(@as(u32, 3), csi.get(0, 1));
    try testing.expectEqual(@as(u32, 5), csi.get(1, 1));
    // An omitted parameter still occupies its place.
    const missing = readAll(&parser, "\x1b[;5H", &actions);
    try testing.expectEqual(@as(usize, 2), missing[0].csi.count);
    try testing.expectEqual(@as(u32, 1), missing[0].csi.get(0, 1));
    try testing.expectEqual(@as(u32, 5), missing[0].csi.get(1, 1));
}

test "a sequence naming more parameters than are held is dropped whole" {
    var parser = Parser{};
    var actions: [4]Action = undefined;

    // Exactly as many as there are places for is a sequence like any other.
    var full: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&full);
    try w.print("\x1b[", .{});
    for (0..MAX_PARAMS) |i| {
        if (i != 0) try w.print(";", .{});
        try w.print("{d}", .{i + 1});
    }
    try w.print("m", .{});
    const held = readAll(&parser, full[0..w.end], &actions);
    try testing.expectEqual(@as(usize, 1), held.len);
    try testing.expectEqual(MAX_PARAMS, held[0].csi.count);
    try testing.expectEqual(@as(u32, MAX_PARAMS), held[0].csi.raw(MAX_PARAMS - 1));

    // One more is a sequence this parser cannot say what it asked for, so
    // it is read to its end and nothing is acted on. The digits after the
    // last separator do not land in the parameter before them.
    const over = readAll(&parser, "\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17m", &actions);
    try testing.expectEqual(@as(usize, 0), over.len);

    // And the next sequence is read as itself.
    const after = readAll(&parser, "\x1b[7m", &actions);
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expectEqual(@as(u32, 7), after[0].csi.raw(0));
}

test "a control inside a sequence is acted on where it stands" {
    var parser = Parser{};
    var actions: [4]Action = undefined;
    const got = readAll(&parser, "\x1b[3\x0d;5H", &actions);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(@as(u8, 0x0d), got[0].control);
    try testing.expectEqual(@as(u32, 5), got[1].csi.get(1, 1));
}
