//! Key presses and the bytes they travel as, in both directions.
//!
//! A terminal turns a press into bytes for the program it is running; a
//! full-screen program running inside one has to turn those bytes back into a
//! press. Both halves are here and both read the same table, so a key cannot
//! be sendable and unreadable: adding one is a row, and the row is what
//! `send` writes and what `read` recognises.
//!
//! Two sources, because the window manager sends two things. A `text` event
//! carries what the layout produced, which is what a character key means; a
//! `key` event carries which physical key it was, which is what an arrow, a
//! function key or a control chord means. Using the wrong one for either is
//! how a terminal ends up sending `Ctrl+Q` on an AZERTY keyboard when the
//! person pressed the key printed `A`.
//!
//! Pure and host-tested, in both directions and against each other: every key
//! in the table is sent and read back, so the two halves are proved to be
//! inverses rather than assumed to be.

const std = @import("std");
const abi = @import("lib").syscalls;
const str = @import("lib").str;

const KeyCode = abi.KeyCode;
const Modifiers = abi.Modifiers;

/// Longest sequence any key produces, `CSI 1 ; 5 A` and the like.
///
/// Worked out by sending every key in the table with every modifier, at
/// compile time, rather than remembered as a number beside it: a key added
/// with a longer sequence would otherwise be cut off by a buffer sized for
/// the old longest, and nothing would say so.
pub const MAX = longest: {
    @setEvalBranchQuota(20_000);
    var most: usize = 1;
    for (TABLE) |row| {
        for ([_]bool{ false, true }) |application| {
            for ([_]Modifiers{ .{}, .{ .shift = true, .alt = true, .control = true } }) |mods| {
                var buf: [64]u8 = undefined;
                most = @max(most, key(row.code, mods, application, &buf).len);
            }
        }
    }
    break :longest most;
};

/// How a key's sequence is shaped.
///
/// A union rather than a family of tables, so the shape and what fills it stay
/// together and a key can only be one of them.
const Form = union(enum) {
    /// `CSI final`, or `SS3 final` in application mode, or `CSI 1 ; mod final`
    /// when a modifier is held.
    cursor: u8,
    /// `CSI n ~`, with the modifier as a second parameter.
    numbered: u8,
    /// A sequence with nowhere to put a modifier. The first four function keys
    /// are `SS3`, the rest are numbered; that split is not a choice, it is
    /// what every terminal since the VT220 does.
    fixed: []const u8,
    /// One byte.
    plain: u8,
    /// One byte, and a sequence of its own when shift is held rather than the
    /// modifier parameter every other key uses. Tab is the only one.
    plain_or_shifted: struct { plain: u8, shifted: []const u8 },
};

const Sequence = struct { code: KeyCode, form: Form };

/// Every key that travels as something other than its own character.
///
/// One list read in both directions. The alternative is a switch for sending
/// and a parser for receiving, which are the same knowledge written twice and
/// drift the moment a key is added to one of them.
const TABLE = [_]Sequence{
    .{ .code = .up, .form = .{ .cursor = 'A' } },
    .{ .code = .down, .form = .{ .cursor = 'B' } },
    .{ .code = .right, .form = .{ .cursor = 'C' } },
    .{ .code = .left, .form = .{ .cursor = 'D' } },
    .{ .code = .home, .form = .{ .cursor = 'H' } },
    .{ .code = .end, .form = .{ .cursor = 'F' } },

    .{ .code = .insert, .form = .{ .numbered = 2 } },
    .{ .code = .delete, .form = .{ .numbered = 3 } },
    .{ .code = .page_up, .form = .{ .numbered = 5 } },
    .{ .code = .page_down, .form = .{ .numbered = 6 } },

    .{ .code = .f1, .form = .{ .fixed = "\x1BOP" } },
    .{ .code = .f2, .form = .{ .fixed = "\x1BOQ" } },
    .{ .code = .f3, .form = .{ .fixed = "\x1BOR" } },
    .{ .code = .f4, .form = .{ .fixed = "\x1BOS" } },
    .{ .code = .f5, .form = .{ .numbered = 15 } },
    .{ .code = .f6, .form = .{ .numbered = 17 } },
    .{ .code = .f7, .form = .{ .numbered = 18 } },
    .{ .code = .f8, .form = .{ .numbered = 19 } },
    .{ .code = .f9, .form = .{ .numbered = 20 } },
    .{ .code = .f10, .form = .{ .numbered = 21 } },
    .{ .code = .f11, .form = .{ .numbered = 23 } },
    .{ .code = .f12, .form = .{ .numbered = 24 } },

    .{ .code = .enter, .form = .{ .plain = '\r' } },
    .{ .code = .kp_enter, .form = .{ .plain = '\r' } },
    .{ .code = .escape, .form = .{ .plain = 0x1B } },
    // DEL rather than BS. The choice is arbitrary and universal: every
    // terminal database maps the backspace key to 0x7F, and a terminal
    // sending 0x08 gets a shell that cannot delete.
    .{ .code = .backspace, .form = .{ .plain = 0x7F } },
    .{ .code = .tab, .form = .{ .plain_or_shifted = .{ .plain = '\t', .shifted = "\x1B[Z" } } },
};

fn formOf(code: KeyCode) ?Form {
    for (TABLE) |row| {
        if (row.code == code) return row.form;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

/// What a key press sends, or an empty slice for one that sends nothing.
///
/// `application` is DECCKM: a full-window program sets it so its arrow keys
/// arrive as `SS3 A` and cannot be confused with a literal `Escape [ A` typed
/// by hand.
pub fn key(code: KeyCode, mods: Modifiers, application: bool, out: []u8) []const u8 {
    var w = Writer{ .buf = out };
    const form = formOf(code) orelse return w.done();

    switch (form) {
        .cursor => |final| w.cursorKey(final, mods, application),
        .numbered => |n| w.tilde(n, mods),
        .fixed => |bytes| w.text(bytes),
        .plain => |byte| w.byte(byte),
        .plain_or_shifted => |either| if (mods.shift)
            w.text(either.shifted)
        else
            w.byte(either.plain),
    }
    return w.done();
}

/// What a character key sends, given what the layout produced.
///
/// Control chords are decided here rather than from the keycode, so `Ctrl+C`
/// is the key printed `C` whatever the layout puts there.
pub fn text(codepoint: u32, mods: Modifiers, out: []u8) []const u8 {
    var w = Writer{ .buf = out };

    if (mods.control) {
        const code = controlFor(codepoint) orelse return w.done();
        // Alt prefixes with Escape, which is how every terminal sends Meta and
        // how readline and vim expect it.
        if (mods.alt) w.byte(0x1B);
        w.byte(code);
        return w.done();
    }

    if (codepoint < 0x20) return w.done();
    if (mods.alt) w.byte(0x1B);
    w.codepoint(codepoint);
    return w.done();
}

/// The control code a character produces when Ctrl is held.
///
/// The letters are the character with its top bits cleared, which is what the
/// name "control" meant: `Ctrl+A` is 1 because `A` is 65 and 65 mod 32 is 1.
fn controlFor(codepoint: u32) ?u8 {
    return switch (codepoint) {
        'a'...'z' => @intCast(codepoint - 'a' + 1),
        'A'...'Z' => @intCast(codepoint - 'A' + 1),
        '@', ' ' => 0,
        '[' => 0x1B,
        '\\' => 0x1C,
        ']' => 0x1D,
        '^' => 0x1E,
        '_', '-' => 0x1F,
        '?' => 0x7F,
        else => null,
    };
}

/// Which modifiers a sequence carries, as terminals pack them.
///
/// Three bits with the positions the format fixed, and the parameter that
/// appears in the sequence is one more than them so that nought can mean
/// "none at all". A packed struct rather than three shifts written out in one
/// direction and three masks in the other: the positions are stated once and
/// the two directions cannot disagree about them.
const Chord = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    control: bool = false,

    fn of(mods: Modifiers) Chord {
        return .{ .shift = mods.shift, .alt = mods.alt, .control = mods.control };
    }

    fn modifiers(self: Chord) Modifiers {
        return .{ .shift = self.shift, .alt = self.alt, .control = self.control };
    }

    /// What the sequence carries, or null for a key held on its own, which
    /// carries no parameter rather than a parameter meaning nothing. DEC counts
    /// from one and adds a weight per modifier: shift one, alt two, control
    /// four, the sum of the ones that are held.
    fn param(self: Chord) ?u8 {
        if (!self.shift and !self.alt and !self.control) return null;
        var carried: u8 = 1;
        if (self.shift) carried += 1;
        if (self.alt) carried += 2;
        if (self.control) carried += 4;
        return carried;
    }

    fn fromParam(carried: u32) Chord {
        // The weights are the fields in order, so the sum with the one taken
        // back off is the struct itself: shift lowest, then alt, then control.
        if (carried < 2) return .{};
        return @bitCast(@as(u3, @truncate(carried - 1)));
    }
};

// ---------------------------------------------------------------------------
// Reading
//
// The other direction, for a full-screen program running inside a terminal
// rather than on the machine's own screen: the keyboard belongs to whatever is
// compositing, and what arrives here is the bytes that terminal chose to send.
// ---------------------------------------------------------------------------

/// One press, as it arrived.
pub const Press = struct {
    code: KeyCode = .none,
    /// What the key produced, for a character key. Zero for one that is only
    /// a code, which is every row of the table.
    codepoint: u21 = 0,
    mods: Modifiers = .{},
    /// How many bytes it took, so a caller with several keys in its buffer
    /// knows where the next one starts.
    took: usize = 0,
};

/// What was found at the front of a stream.
///
/// Three answers rather than an optional, because "not yet" and "not a key"
/// need different things done about them: a caller that treated an unfinished
/// sequence as rubbish would eat the escape and read the rest as text, and one
/// that waited for more of something that will never become a key would stop
/// forever.
pub const Reading = union(enum) {
    got: Press,
    /// The beginning of a sequence whose rest has not arrived.
    partial,
    /// Nothing a key produces. The bytes are named so a stream cannot stall on
    /// them.
    skip: usize,
};

/// Whether more bytes may still arrive.
///
/// The one ambiguity the format has: a lone Escape is either the Escape key
/// or the beginning of a sequence, and the bytes cannot say which. A stream
/// that may yet deliver more waits; one that has stopped has its answer. Real
/// terminals settle it with a timeout for the same reason, and only the
/// caller knows which side of it a stream is on.
pub const More = enum { may_follow, thats_all };

/// Read the first key in `bytes`.
pub fn read(bytes: []const u8, more: More) Reading {
    if (bytes.len == 0) return .partial;

    if (bytes[0] == 0x1B) return escape(bytes, more);

    // A control code is a letter with its top bits cleared, so it comes back
    // as that letter and the modifier that cleared them. The ones the table
    // claims are keys in their own right and are found there first.
    if (plainKey(bytes[0])) |code| {
        return .{ .got = .{ .code = code, .took = 1 } };
    }
    if (bytes[0] < 0x20) {
        return .{ .got = .{
            .codepoint = @intCast(bytes[0] + 'a' - 1),
            .mods = .{ .control = true },
            .took = 1,
        } };
    }

    return character(bytes, .{});
}

/// The key a single byte is, if the table says one.
fn plainKey(byte: u8) ?KeyCode {
    for (TABLE) |row| {
        switch (row.form) {
            .plain => |b| if (b == byte) return row.code,
            .plain_or_shifted => |either| if (either.plain == byte) return row.code,
            else => {},
        }
    }
    return null;
}

/// One character, decoded from however many bytes it occupies.
fn character(bytes: []const u8, mods: Modifiers) Reading {
    const width = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .skip = 1 };
    if (bytes.len < width) return .partial;

    const cp = std.unicode.utf8Decode(bytes[0..width]) catch return .{ .skip = width };
    return .{ .got = .{ .codepoint = cp, .mods = mods, .took = width } };
}

/// Everything that begins with Escape.
fn escape(bytes: []const u8, more: More) Reading {
    if (bytes.len == 1) return unfinished(more, .{ .code = .escape, .took = 1 });

    return switch (bytes[1]) {
        '[' => csi(bytes, more),
        'O' => single(bytes, more),
        // Escape and then a character is Alt holding that character, which is
        // how every terminal sends Meta.
        else => alt(bytes),
    };
}

/// `SS3 final`: the first four function keys, and the cursor keys as a
/// program that asked for application mode receives them.
fn single(bytes: []const u8, more: More) Reading {
    if (bytes.len < 3) return unfinished(more, .{ .code = .escape, .took = 1 });

    for (TABLE) |row| {
        switch (row.form) {
            .fixed => |seq| if (seq.len == 3 and seq[2] == bytes[2]) {
                return .{ .got = .{ .code = row.code, .took = 3 } };
            },
            .cursor => |final| if (final == bytes[2]) {
                return .{ .got = .{ .code = row.code, .took = 3 } };
            },
            else => {},
        }
    }
    return .{ .skip = 3 };
}

/// Escape and a character, which is that character with Alt held. The
/// character may itself be a control code, which is Alt and Ctrl together.
fn alt(bytes: []const u8) Reading {
    const rest = bytes[1..];
    if (rest[0] < 0x20) {
        return .{ .got = .{
            .codepoint = @intCast(rest[0] + 'a' - 1),
            .mods = .{ .control = true, .alt = true },
            .took = 2,
        } };
    }

    const inner = character(rest, .{ .alt = true });
    return switch (inner) {
        .got => |press| .{ .got = .{
            .code = press.code,
            .codepoint = press.codepoint,
            .mods = press.mods,
            .took = press.took + 1,
        } },
        .partial => .partial,
        .skip => |n| .{ .skip = n + 1 },
    };
}

/// `CSI` and what follows: the cursor keys, the numbered keys, and Shift+Tab.
fn csi(bytes: []const u8, more: More) Reading {
    var at: usize = 2;
    var first: u32 = 0;
    var second: u32 = 0;
    var reading_second = false;

    while (at < bytes.len) : (at += 1) {
        const c = bytes[at];
        switch (c) {
            '0'...'9' => {
                const digit = c - '0';
                if (reading_second) {
                    second = second * 10 + digit;
                } else {
                    first = first * 10 + digit;
                }
            },
            ';' => reading_second = true,
            else => return ended(c, at + 1, first, Chord.fromParam(second).modifiers()),
        }
    }
    return unfinished(more, .{ .code = .escape, .took = 1 });
}

/// What an unfinished sequence is, given whether anything more is coming.
///
/// A stream that has stopped mid-sequence never had a key there; what it did
/// have is the Escape that started it, which is what a person pressing Escape
/// on its own sends.
fn unfinished(more: More, escape_key: Press) Reading {
    return switch (more) {
        .may_follow => .partial,
        .thats_all => .{ .got = escape_key },
    };
}

/// The byte that ends a `CSI` sequence decides which key it was.
fn ended(ending: u8, took: usize, number: u32, mods: Modifiers) Reading {
    // Shift+Tab is a sequence of its own rather than a modified Tab, which is
    // the one exception to the modifier encoding.
    if (ending == 'Z') {
        return .{ .got = .{ .code = .tab, .mods = .{ .shift = true }, .took = took } };
    }

    for (TABLE) |row| {
        switch (row.form) {
            .cursor => |c| if (ending == c) {
                return .{ .got = .{ .code = row.code, .mods = mods, .took = took } };
            },
            .numbered => |n| if (ending == '~' and n == number) {
                return .{ .got = .{ .code = row.code, .mods = mods, .took = took } };
            },
            else => {},
        }
    }
    return .{ .skip = took };
}

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn byte(self: *Writer, c: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }

    fn text(self: *Writer, s: []const u8) void {
        for (s) |c| self.byte(c);
    }

    fn number(self: *Writer, value: u32) void {
        var buf: [12]u8 = undefined;
        self.text(buf[0..str.decimal(&buf, value)]);
    }

    fn codepoint(self: *Writer, cp: u32) void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return;
        self.text(buf[0..n]);
    }

    /// `CSI final`, or `SS3 final` in application mode, or `CSI 1 ; mod final`
    /// when a modifier is held. A modified cursor key is always `CSI`, because
    /// `SS3` has nowhere to put the parameter.
    fn cursorKey(self: *Writer, ending: u8, mods: Modifiers, application: bool) void {
        if (Chord.of(mods).param()) |carried| {
            self.text("\x1B[1;");
            self.number(carried);
            self.byte(ending);
            return;
        }
        self.text(if (application) "\x1BO" else "\x1B[");
        self.byte(ending);
    }

    /// `CSI n ~`, the numbered keys, with the modifier as a second parameter.
    fn tilde(self: *Writer, n: u32, mods: Modifiers) void {
        self.text("\x1B[");
        self.number(n);
        if (Chord.of(mods).param()) |carried| {
            self.byte(';');
            self.number(carried);
        }
        self.byte('~');
    }

    fn done(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Whether reading `sent` back gives a key that would send exactly `sent`.
///
/// The property that actually holds, and the strongest one that can: two keys
/// may share a sequence, and Enter and the keypad's Enter do. A byte stream
/// cannot tell those apart and no reader could, so the test is that nothing is
/// lost rather than that the same row comes back.
fn survives(sent: []const u8, mods: Modifiers, application: bool) !void {
    const press = switch (read(sent, .thats_all)) {
        .got => |p| p,
        else => return error.KeyDidNotSurvive,
    };
    try testing.expectEqual(sent.len, press.took);

    var again: [MAX]u8 = undefined;
    try testing.expectEqualStrings(sent, key(press.code, mods, application, &again));
}

test "every key in the table survives being sent and read back" {
    // The whole reason both halves are here: a key that can be sent and not
    // read is a key that works on the machine's own screen and does nothing
    // inside a terminal window.
    var buf: [MAX]u8 = undefined;

    for (TABLE) |row| {
        for ([_]Modifiers{ .{}, .{ .shift = true }, .{ .control = true }, .{ .shift = true, .alt = true } }) |mods| {
            const sent = key(row.code, mods, false, &buf);
            if (sent.len == 0) continue;
            try survives(sent, mods, false);
        }
    }
}

test "a key sent in application mode survives too" {
    var buf: [MAX]u8 = undefined;
    for (TABLE) |row| {
        const sent = key(row.code, .{}, true, &buf);
        if (sent.len == 0) continue;
        try survives(sent, .{}, true);
    }
}

test "two keys sharing a sequence read back as the one that sends it" {
    // Enter and the keypad's Enter are the same carriage return on the wire.
    // Nothing can separate them, so the reader names the first and the test
    // says so rather than pretending otherwise.
    var buf: [MAX]u8 = undefined;
    try testing.expectEqualStrings("\r", key(.enter, .{}, false, &buf));
    try testing.expectEqualStrings("\r", key(.kp_enter, .{}, false, &buf));

    switch (read("\r", .thats_all)) {
        .got => |press| try testing.expectEqual(KeyCode.enter, press.code),
        else => return error.NotRead,
    }
}

test "a modifier is carried through the sequence and back" {
    var buf: [MAX]u8 = undefined;

    const held = Modifiers{ .control = true, .shift = true };
    const sent = key(.up, held, false, &buf);
    try testing.expectEqualStrings("\x1B[1;6A", sent);

    const press = switch (read(sent, .thats_all)) {
        .got => |p| p,
        else => return error.KeyDidNotSurvive,
    };
    try testing.expectEqual(KeyCode.up, press.code);
    try testing.expect(press.mods.control);
    try testing.expect(press.mods.shift);
    try testing.expect(!press.mods.alt);
}

test "shift and tab is its own sequence rather than a modified tab" {
    var buf: [MAX]u8 = undefined;
    try testing.expectEqualStrings("\x1B[Z", key(.tab, .{ .shift = true }, false, &buf));
    try testing.expectEqualStrings("\t", key(.tab, .{}, false, &buf));

    switch (read("\x1B[Z", .thats_all)) {
        .got => |press| {
            try testing.expectEqual(KeyCode.tab, press.code);
            try testing.expect(press.mods.shift);
        },
        else => return error.KeyDidNotSurvive,
    }
}

test "an ordinary character comes back as itself" {
    switch (read("q", .thats_all)) {
        .got => |press| {
            try testing.expectEqual(@as(u21, 'q'), press.codepoint);
            try testing.expectEqual(KeyCode.none, press.code);
            try testing.expectEqual(@as(usize, 1), press.took);
        },
        else => return error.NotRead,
    }

    // More than one byte, and only the first key is taken.
    switch (read("ab", .thats_all)) {
        .got => |press| try testing.expectEqual(@as(usize, 1), press.took),
        else => return error.NotRead,
    }

    // A character outside ASCII takes as many bytes as it occupies.
    switch (read("é", .thats_all)) {
        .got => |press| {
            try testing.expectEqual(@as(u21, 0xE9), press.codepoint);
            try testing.expectEqual(@as(usize, 2), press.took);
        },
        else => return error.NotRead,
    }
}

test "a control chord comes back as its letter and the modifier" {
    var buf: [MAX]u8 = undefined;
    const sent = text('c', .{ .control = true }, &buf);
    try testing.expectEqualStrings("\x03", sent);

    switch (read(sent, .thats_all)) {
        .got => |press| {
            try testing.expectEqual(@as(u21, 'c'), press.codepoint);
            try testing.expect(press.mods.control);
        },
        else => return error.NotRead,
    }

    // Alt as well, which is Escape and then the control code.
    const both = text('c', .{ .control = true, .alt = true }, &buf);
    switch (read(both, .thats_all)) {
        .got => |press| {
            try testing.expectEqual(@as(u21, 'c'), press.codepoint);
            try testing.expect(press.mods.control);
            try testing.expect(press.mods.alt);
            try testing.expectEqual(@as(usize, 2), press.took);
        },
        else => return error.NotRead,
    }
}

test "alt and a character is escape and that character" {
    var buf: [MAX]u8 = undefined;
    const sent = text('x', .{ .alt = true }, &buf);
    try testing.expectEqualStrings("\x1Bx", sent);

    switch (read(sent, .thats_all)) {
        .got => |press| {
            try testing.expectEqual(@as(u21, 'x'), press.codepoint);
            try testing.expect(press.mods.alt);
            try testing.expectEqual(@as(usize, 2), press.took);
        },
        else => return error.NotRead,
    }
}

test "a sequence that has not finished arriving is waited for" {
    // A reader that took these for rubbish would eat the escape and read what
    // followed as text: an arrow key would arrive as a bracket and a letter.
    try testing.expect(read("", .may_follow) == .partial);
    try testing.expect(read("\x1B", .may_follow) == .partial);
    try testing.expect(read("\x1B[", .may_follow) == .partial);
    try testing.expect(read("\x1B[1", .may_follow) == .partial);
    try testing.expect(read("\x1B[1;5", .may_follow) == .partial);
    try testing.expect(read("\x1BO", .may_follow) == .partial);

    // And one that has finished is not.
    try testing.expect(read("\x1B[A", .may_follow) == .got);
}

test "a sequence that stopped arriving was the escape that started it" {
    // The format's one ambiguity, and the reason the caller has to say which
    // side of it a stream is on: pressing Escape on its own sends exactly the
    // byte an arrow key starts with.
    for ([_][]const u8{ "\x1B", "\x1B[", "\x1B[1;5", "\x1BO" }) |stopped| {
        switch (read(stopped, .thats_all)) {
            .got => |press| {
                try testing.expectEqual(KeyCode.escape, press.code);
                try testing.expectEqual(@as(usize, 1), press.took);
            },
            else => return error.EscapeWasLost,
        }
    }
}

test "a sequence that is not a key is named rather than left to stall" {
    // Something no key here produces. The bytes have to be accounted for, or
    // a reader sits on them forever asking what they are.
    switch (read("\x1B[99~", .thats_all)) {
        .skip => |n| try testing.expectEqual(@as(usize, 5), n),
        else => return error.ShouldNotBeAKey,
    }
    switch (read("\x1BOZ", .thats_all)) {
        .skip => |n| try testing.expectEqual(@as(usize, 3), n),
        else => return error.ShouldNotBeAKey,
    }

    // A byte that is not the start of any character.
    switch (read("\xFF", .thats_all)) {
        .skip => |n| try testing.expectEqual(@as(usize, 1), n),
        else => return error.ShouldNotBeAKey,
    }
}

test "a stream of keys is read one at a time" {
    // What a reader actually gets: several presses in one read from a pipe.
    const stream = "\x1B[Aq\x1B[6~\r";
    var at: usize = 0;
    var found: [4]KeyCode = undefined;
    var n: usize = 0;

    while (at < stream.len) {
        switch (read(stream[at..], .may_follow)) {
            .got => |press| {
                found[n] = press.code;
                n += 1;
                at += press.took;
            },
            .skip => |took| at += took,
            .partial => break,
        }
    }

    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(KeyCode.up, found[0]);
    try testing.expectEqual(KeyCode.none, found[1]);
    try testing.expectEqual(KeyCode.page_down, found[2]);
    try testing.expectEqual(KeyCode.enter, found[3]);
}

test "no key appears in the table twice" {
    // A second row for a key already there would be dead: the first found is
    // the one sent, so the second could never be reached.
    for (TABLE, 0..) |row, i| {
        for (TABLE[i + 1 ..]) |other| try testing.expect(row.code != other.code);
    }
}

test "the sequences that carry a modifier belong to one key each" {
    // Two rows claiming one of these would send the same bytes for two keys
    // and read back as whichever came first, which is only acceptable where
    // it is deliberate: the plain forms, where Enter and the keypad's Enter
    // share a carriage return.
    for (TABLE, 0..) |row, i| {
        for (TABLE[i + 1 ..]) |other| {
            const same = switch (row.form) {
                .cursor => |c| switch (other.form) {
                    .cursor => |d| c == d,
                    else => false,
                },
                .numbered => |n| switch (other.form) {
                    .numbered => |m| n == m,
                    else => false,
                },
                .fixed => |s| switch (other.form) {
                    .fixed => |t| std.mem.eql(u8, s, t),
                    else => false,
                },
                else => false,
            };
            try testing.expect(!same);
        }
    }
}
