//! Line discipline: turns key events into lines of text for `read`.
//!
//! Sits between the input core and the read syscall. Editing happens here
//! rather than in each program, so every prompt, the shell, a password field,
//! anything that reads a line, behaves the same way.
//!
//! Two modes. Cooked delivers a line at a time, after Enter, and echoes as it
//! goes: what a program that only wants an answer needs. Raw delivers each
//! keystroke as it happens and echoes nothing, with the keys that produce no
//! character arriving as the escape sequences a terminal sends for them: what
//! a program drawing its own input line needs, because it has to know where
//! the cursor went and the kernel must not draw over it.
//!
//! The rules live in `Discipline`, which knows nothing about where keys come
//! from or where what is typed goes, so they are checked on the host. The one
//! instance is fed from the input core and echoes to the console.

const std = @import("std");
const lib = @import("lib");
const abi = lib.syscalls;
const console = @import("console.zig");
const event_mod = @import("event.zig");
const input = @import("input.zig");

/// Long enough for a command line, short enough that a stuck key cannot eat
/// memory. Input past the limit is refused rather than silently truncating
/// what the user typed.
const LINE_MAX = 256;

/// Bytes waiting for a reader. One line at most, since a line is refused
/// past LINE_MAX; and in raw mode the whole input queue drained at once, at
/// the four bytes a keystroke can be, which comes to the same number.
const READY_MAX = LINE_MAX;

/// What a key with no character of its own sends, which is what every terminal
/// sends for it. Written once here so the kernel and the editors that read it
/// cannot disagree about what an arrow key looks like.
fn sequenceFor(code: abi.KeyCode) ?[]const u8 {
    return switch (code) {
        .up => "\x1b[A",
        .down => "\x1b[B",
        .right => "\x1b[C",
        .left => "\x1b[D",
        .home => "\x1b[H",
        .end => "\x1b[F",
        .delete => "\x1b[3~",
        .page_up => "\x1b[5~",
        .page_down => "\x1b[6~",
        else => null,
    };
}

/// The line discipline's state and rules.
pub const Discipline = struct {
    mode: abi.TtyMode = .cooked,
    /// The line being edited, in cooked mode.
    line: [LINE_MAX]u8 = undefined,
    line_len: usize = 0,
    /// Bytes ready to be read: completed lines in cooked mode, keystrokes as
    /// they came in raw mode. A queue rather than a buffer and two indexes,
    /// so draining it is the queue's business and a reader can never leave
    /// it stuck at its end.
    ready: lib.fifo.Fifo(u8, READY_MAX) = .{},

    /// Choose the mode, returning the one that was in effect.
    pub fn setMode(self: *Discipline, wanted: abi.TtyMode) abi.TtyMode {
        const was = self.mode;
        self.mode = wanted;
        // A half-typed line belongs to the mode it was typed in.
        self.line_len = 0;
        self.ready = .{};
        return was;
    }

    fn room(self: *const Discipline) usize {
        return READY_MAX - self.ready.count;
    }

    /// Queue bytes for the reader, all of them or none: half an escape
    /// sequence or half a UTF-8 character would be read as something else.
    fn deliver(self: *Discipline, bytes: []const u8) bool {
        if (bytes.len > self.room()) return false;
        for (bytes) |b| _ = self.ready.push(b);
        return true;
    }

    /// Take one key press, returning what it echoes: nothing, a character
    /// just typed, or the sequence for erasing one. The bytes are static or
    /// in the line buffer, and stand until the next call.
    pub fn feed(self: *Discipline, code: abi.KeyCode, codepoint: u32) []const u8 {
        // Raw mode has nothing to edit: every keystroke goes straight through,
        // as its character or as the sequence that stands for it.
        if (self.mode == .raw) {
            if (sequenceFor(code)) |seq| {
                _ = self.deliver(seq);
                return "";
            }
            if (codepoint == 0) return "";

            var utf8: [4]u8 = undefined;
            const scalar = std.math.cast(u21, codepoint) orelse return "";
            const n = std.unicode.utf8Encode(scalar, &utf8) catch return "";
            _ = self.deliver(utf8[0..n]);
            return "";
        }

        // Editing keys that produce no character.
        if (code == .backspace) {
            if (self.line_len == 0) return "";
            // Step back over a whole UTF-8 sequence, not one byte, or erasing
            // an accented character leaves half of it behind.
            var back: usize = 1;
            while (back < self.line_len and (self.line[self.line_len - back] & 0xC0) == 0x80) back += 1;
            self.line_len -= back;
            return "\x08 \x08";
        }

        if (codepoint == 0) return "";

        if (codepoint == '\n' or codepoint == '\r') {
            // The line and its newline go together or not at all. No room
            // means a line is still waiting to be read; this one stays where
            // it is, whole, until that one has gone.
            if (self.line_len + 1 > self.room()) return "";
            _ = self.deliver(self.line[0..self.line_len]);
            _ = self.deliver("\n");
            self.line_len = 0;
            return "\n";
        }

        // Ctrl+C abandons the line, matching what every terminal does.
        if (codepoint == 3) {
            self.line_len = 0;
            self.ready = .{};
            return "^C\n";
        }

        var utf8: [4]u8 = undefined;
        const scalar = std.math.cast(u21, codepoint) orelse return "";
        const n = std.unicode.utf8Encode(scalar, &utf8) catch return "";
        // The newline Enter adds has to fit as well.
        if (self.line_len + n >= LINE_MAX) return "";

        const start = self.line_len;
        @memcpy(self.line[start..][0..n], utf8[0..n]);
        self.line_len += n;
        return self.line[start..self.line_len];
    }

    /// True when something is waiting to be read.
    pub fn hasReady(self: *const Discipline) bool {
        return !self.ready.isEmpty();
    }

    /// Take up to `buf.len` ready bytes, returning how many.
    pub fn read(self: *Discipline, buf: []u8) usize {
        var n: usize = 0;
        while (n < buf.len) : (n += 1) {
            buf[n] = self.ready.pop() orelse break;
        }
        return n;
    }
};

var discipline: Discipline = .{};

/// Choose the mode, returning the one that was in effect.
pub fn setMode(wanted: abi.TtyMode) abi.TtyMode {
    return discipline.setMode(wanted);
}

fn emit(bytes: []const u8) void {
    if (bytes.len > 0) console.writeString(bytes);
}

/// Consume pending key events into the line discipline.
///
/// Called from the read path rather than from the interrupt handler: the
/// handler should do as little as possible, and echoing to the console from
/// interrupt context would mean the console lock, once there is one, is taken
/// at unpredictable moments.
fn pump() void {
    while (input.poll()) |event| {
        if (!event.pressed) continue;
        emit(discipline.feed(event.code, event.codepoint));
    }
}

/// True when a complete line, or in raw mode any keystroke, is waiting.
pub fn hasLine() bool {
    pump();
    return discipline.hasReady();
}

/// What a reader blocks on while nothing is ready: the input core's word
/// that a key has been queued for the line discipline. Counting, so a key
/// that lands between the reader looking and the reader sleeping is not
/// lost.
pub fn ready() *event_mod.Event {
    return input.lineReady();
}

/// Read up to `buf.len` bytes of what is ready.
///
/// Returns 0 when nothing is ready. The caller decides whether to block on
/// `ready`, since blocking belongs to the scheduler rather than here.
pub fn read(buf: []u8) usize {
    pump();
    return discipline.read(buf);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn feedText(d: *Discipline, text: []const u8) void {
    for (text) |c| _ = d.feed(.none, c);
}

test "raw mode keeps delivering however many keystrokes have gone through" {
    var d = Discipline{};
    _ = d.setMode(.raw);
    var buf: [8]u8 = undefined;

    // Far more than the ready queue holds, one at a time: what the reader
    // has taken is room again.
    for (0..4 * READY_MAX) |_| {
        try std.testing.expectEqualStrings("", d.feed(.none, 'a'));
        try std.testing.expectEqual(@as(usize, 1), d.read(&buf));
        try std.testing.expectEqual(@as(u8, 'a'), buf[0]);
    }

    _ = d.feed(.enter, '\n');
    _ = d.feed(.none, 3);
    try std.testing.expectEqual(@as(usize, 2), d.read(&buf));
    try std.testing.expectEqualStrings("\n\x03", buf[0..2]);
    try std.testing.expect(!d.hasReady());
}

test "raw mode sends the terminal's sequence for a key with no character" {
    var d = Discipline{};
    _ = d.setMode(.raw);
    _ = d.feed(.up, 0);
    _ = d.feed(.delete, 0);
    _ = d.feed(.shift_left, 0);
    var buf: [16]u8 = undefined;
    const n = d.read(&buf);
    try std.testing.expectEqualStrings("\x1b[A\x1b[3~", buf[0..n]);
}

test "raw mode refuses a keystroke that does not fit, whole" {
    var d = Discipline{};
    _ = d.setMode(.raw);
    for (0..READY_MAX - 2) |_| _ = d.feed(.none, 'a');

    // Two bytes left: an arrow key is three and must not leave a partial
    // sequence; an accented letter is two and fits exactly.
    _ = d.feed(.left, 0);
    _ = d.feed(.none, 0xE9);
    _ = d.feed(.none, 'z');

    var buf: [READY_MAX + 8]u8 = undefined;
    const n = d.read(&buf);
    try std.testing.expectEqual(@as(usize, READY_MAX), n);
    try std.testing.expectEqualStrings("a\xC3\xA9", buf[n - 3 .. n]);
}

test "cooked mode echoes as it goes and delivers the line after enter" {
    var d = Discipline{};
    try std.testing.expectEqualStrings("h", d.feed(.h, 'h'));
    try std.testing.expectEqualStrings("i", d.feed(.i, 'i'));
    try std.testing.expect(!d.hasReady());
    try std.testing.expectEqualStrings("\n", d.feed(.enter, '\r'));
    try std.testing.expect(d.hasReady());

    var buf: [8]u8 = undefined;
    const n = d.read(&buf);
    try std.testing.expectEqualStrings("hi\n", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), d.read(&buf));
}

test "backspace erases a whole character, not one byte of it" {
    var d = Discipline{};
    try std.testing.expectEqualStrings("\xC3\xA9", d.feed(.none, 0xE9));
    try std.testing.expectEqualStrings("\x08 \x08", d.feed(.backspace, 0));
    try std.testing.expectEqualStrings("", d.feed(.backspace, 0));
    _ = d.feed(.none, 'x');
    _ = d.feed(.enter, '\n');
    var buf: [8]u8 = undefined;
    const n = d.read(&buf);
    try std.testing.expectEqualStrings("x\n", buf[0..n]);
}

test "control c abandons the line and whatever was waiting" {
    var d = Discipline{};
    feedText(&d, "ab\ncd");
    try std.testing.expectEqualStrings("^C\n", d.feed(.none, 3));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), d.read(&buf));
    _ = d.feed(.enter, '\n');
    try std.testing.expectEqualStrings("\n", buf[0..d.read(&buf)]);
}

test "a line past the limit is refused rather than cut" {
    var d = Discipline{};
    for (0..LINE_MAX + 20) |_| _ = d.feed(.none, 'a');
    try std.testing.expectEqual(@as(usize, LINE_MAX - 1), d.line_len);
    try std.testing.expectEqualStrings("", d.feed(.none, 'b'));
    _ = d.feed(.enter, '\n');
    var buf: [READY_MAX + 8]u8 = undefined;
    const n = d.read(&buf);
    try std.testing.expectEqual(@as(usize, LINE_MAX), n);
    try std.testing.expectEqual(@as(u8, '\n'), buf[n - 1]);
}

test "a line waits, whole, while an unread one fills the queue" {
    var d = Discipline{};
    for (0..LINE_MAX - 1) |_| _ = d.feed(.none, 'a');
    _ = d.feed(.enter, '\n');

    // The queue is full. Enter on the next line is refused, and the line
    // stays typed.
    _ = d.feed(.none, 'x');
    try std.testing.expectEqualStrings("", d.feed(.enter, '\n'));
    try std.testing.expectEqual(@as(usize, 1), d.line_len);

    var buf: [READY_MAX]u8 = undefined;
    try std.testing.expectEqual(@as(usize, READY_MAX), d.read(&buf));
    try std.testing.expectEqualStrings("\n", d.feed(.enter, '\n'));
    try std.testing.expectEqualStrings("x\n", buf[0..d.read(&buf)]);
}

test "changing mode drops what was half typed and reports the old mode" {
    var d = Discipline{};
    feedText(&d, "ab");
    try std.testing.expectEqual(abi.TtyMode.cooked, d.setMode(.raw));
    _ = d.feed(.none, 'c');
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("c", buf[0..d.read(&buf)]);
    try std.testing.expectEqual(abi.TtyMode.raw, d.setMode(.cooked));
    try std.testing.expect(!d.hasReady());
}
