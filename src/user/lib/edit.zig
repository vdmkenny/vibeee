//! Reading a line the way a person expects to type one: a cursor that moves,
//! a history that remembers, and a key that finishes the word.
//!
//! In `ulib` rather than in the shell because none of it is shell-specific,
//! and in userspace rather than in the kernel because completion is: the
//! kernel has no idea what names make sense at a prompt, and a line discipline
//! that tried to guess would be wrong for every program that is not a shell.
//!
//! Reads bytes rather than key events, so the same editor works at the console
//! with the terminal in raw mode and under a terminal emulator, where the keys
//! arrive down a pipe as the sequences that stand for them.

const std = @import("std");
const complete_mod = @import("complete.zig");
const sys = @import("sys");
const out = @import("out.zig");
const str = @import("lib").str;
const escapes = @import("lib").escapes;

/// Longest line, and how many are remembered. Both bounded because this runs
/// on a machine where a runaway buffer is the whole of memory.
pub const LINE_MAX = 256;
const HISTORY_MAX = 32;

/// Where the editor gets candidates when the completion key is pressed. The
/// sources belong to the caller, which is the only thing that knows what makes
/// sense at its own prompt.
pub const Sources = []const complete_mod.Source;

/// A line as it was typed, kept to be typed again.
const Remembered = struct {
    text: [LINE_MAX]u8 = @splat(0),
    len: usize = 0,

    fn slice(self: *const Remembered) []const u8 {
        return self.text[0..self.len];
    }

    fn set(self: *Remembered, text: []const u8) void {
        self.len = @min(text.len, self.text.len);
        @memcpy(self.text[0..self.len], text[0..self.len]);
    }
};

pub const Editor = struct {
    line: [LINE_MAX]u8 = @splat(0),
    len: usize = 0,
    /// Where the next character goes, which is not always the end.
    cursor: usize = 0,
    /// How wide the line was last drawn, so a shorter one erases the rest of
    /// what the longer one left behind.
    drawn: usize = 0,

    history: [HISTORY_MAX]Remembered = @splat(.{}),
    /// How many are remembered, and which is showing. Equal to the count means
    /// the line being typed, which is the one after the last.
    remembered: usize = 0,
    showing: usize = 0,

    sources: Sources = &.{},

    /// Read one line. Null at end of input, which is how a closed pipe and a
    /// terminal that has gone away both look.
    pub fn read(self: *Editor, prompt: []const u8) ?[]const u8 {
        // The editor echoes and edits, so it asks its terminal to keep its own
        // line discipline out of the way: keys as they are pressed, nothing
        // drawn but what is drawn here. Sent in-band rather than through
        // `ttyMode`, so it reaches whichever terminal is on the other end,
        // the kernel console or an emulator down a pipe, and touches neither
        // one's global state on behalf of the other.
        out.text(escapes.private_mode.app_line_edit_on);
        out.flush();
        defer {
            out.text(escapes.private_mode.app_line_edit_off);
            out.flush();
        }

        self.len = 0;
        self.cursor = 0;
        self.drawn = 0;
        self.showing = self.remembered;
        self.redraw(prompt);

        while (true) {
            const c = self.nextByte() orelse return null;
            switch (c) {
                '\r', '\n' => {
                    out.byte('\n');
                    out.flush();
                    self.remember();
                    return self.line[0..self.len];
                },
                // Backspace arrives as either, depending on what is typing.
                0x08, 0x7F => if (self.cursor > 0) {
                    self.cursor -= 1;
                    self.removeAtCursor();
                    self.redraw(prompt);
                },
                '\t' => self.finishWord(prompt),
                // Back over a word, and away with the line. The two
                // corrections every shell has answered since terminals had
                // no arrow keys, and the same two the toolkit's fields take.
                0x17 => {
                    const to = str.fieldBefore(self.line[0..self.len], self.cursor);
                    while (self.cursor > to) {
                        self.cursor -= 1;
                        self.removeAtCursor();
                    }
                    self.redraw(prompt);
                },
                0x15 => {
                    while (self.cursor > 0) {
                        self.cursor -= 1;
                        self.removeAtCursor();
                    }
                    self.redraw(prompt);
                },
                // Ctrl+C abandons the line, as everywhere else.
                0x03 => {
                    out.text("^C\n");
                    self.len = 0;
                    self.cursor = 0;
                    self.drawn = 0;
                    self.redraw(prompt);
                },
                0x1B => self.escape(prompt),
                else => if (c >= 0x20) {
                    self.insertAt(self.cursor, c);
                    self.redraw(prompt);
                },
            }
        }
    }

    fn nextByte(self: *Editor) ?u8 {
        _ = self;
        var byte: [1]u8 = undefined;
        return if (sys.read(sys.STDIN, &byte) > 0) byte[0] else null;
    }

    /// An escape sequence, which is how every key without a character arrives.
    fn escape(self: *Editor, prompt: []const u8) void {
        if (self.nextByte() != @as(?u8, '[')) return;
        const what = self.nextByte() orelse return;

        switch (what) {
            'A' => self.recall(prompt, .back),
            'B' => self.recall(prompt, .forward),
            'C' => self.moveTo(prompt, @min(self.cursor + 1, self.len)),
            'D' => self.moveTo(prompt, self.cursor -| 1),
            'H' => self.moveTo(prompt, 0),
            'F' => self.moveTo(prompt, self.len),
            // The sequences carrying a number end with a tilde, which has to
            // be consumed or it lands in the line.
            '0'...'9' => {
                while (self.nextByte()) |b| {
                    if (b == '~') break;
                }
                if (what == '3' and self.cursor < self.len) {
                    self.removeAtCursor();
                    self.redraw(prompt);
                }
            },
            else => {},
        }
    }

    fn moveTo(self: *Editor, prompt: []const u8, where: usize) void {
        if (where == self.cursor) return;
        self.cursor = where;
        self.redraw(prompt);
    }

    /// Put `c` at `at`, moving the rest of the line along. The cursor follows
    /// the insertion, which is what makes typing and completing the same act.
    fn insertAt(self: *Editor, at: usize, c: u8) void {
        if (self.len + 1 >= self.line.len) return;

        var i = self.len;
        while (i > at) : (i -= 1) self.line[i] = self.line[i - 1];
        self.line[at] = c;
        self.len += 1;
        self.cursor = at + 1;
    }

    fn removeAtCursor(self: *Editor) void {
        var i = self.cursor;
        while (i + 1 < self.len) : (i += 1) self.line[i] = self.line[i + 1];
        self.len -= 1;
    }

    const Direction = enum { back, forward };

    /// Step through what has been typed before, keeping the line being typed
    /// as the one past the end so walking forward returns to it.
    fn recall(self: *Editor, prompt: []const u8, dir: Direction) void {
        switch (dir) {
            .back => if (self.showing > 0) {
                self.showing -= 1;
            } else return,
            .forward => if (self.showing < self.remembered) {
                self.showing += 1;
            } else return,
        }

        const text = if (self.showing == self.remembered) "" else self.history[self.showing].slice();
        @memcpy(self.line[0..text.len], text);
        self.len = text.len;
        self.cursor = self.len;
        self.redraw(prompt);
    }

    /// Finish the word under the cursor as far as the candidates agree.
    ///
    /// As far as they agree, rather than to the first of them: filling in a
    /// guess the user then has to delete is worse than stopping where the
    /// answer stops being certain, and stopping there means the next keystroke
    /// narrows the choice instead of undoing one.
    fn finishWord(self: *Editor, prompt: []const u8) void {
        if (self.sources.len == 0) return;

        const ctx = complete_mod.contextAt(self.line[0..self.len], self.cursor);
        var found = complete_mod.Collector{ .word = ctx.word };
        complete_mod.resolve(self.sources, ctx, &found);

        const whole = found.resolve();

        // Nothing more to add and still a choice: the word is as far as the
        // candidates agree, and the next keystroke is what narrows them.
        if (whole.len <= ctx.word.len and !found.settledOne()) return;

        for (whole[ctx.word.len..]) |c| self.insertAt(self.cursor, c);

        // One answer is a finished word, and the next one starts after a
        // space. That holds even when the word was already the answer: typing
        // a name in full and pressing the key should say so, not do nothing.
        //
        // A single answer ending in a separator is not finished, though: it is
        // a directory, and the next keystroke belongs inside it.
        if (found.settledOne() and whole.len > 0 and whole[whole.len - 1] != '/') {
            self.insertAt(self.cursor, ' ');
        }
        self.redraw(prompt);
    }

    /// Keep a line worth keeping: not empty, and not the one just recalled.
    fn remember(self: *Editor) void {
        if (self.len == 0) return;

        const typed = self.line[0..self.len];
        if (self.remembered > 0 and std.mem.eql(u8, self.history[self.remembered - 1].slice(), typed)) return;

        if (self.remembered == HISTORY_MAX) {
            // Oldest out. A shift rather than a ring because the whole point
            // is walking them in order, and thirty-two of them is nothing.
            for (1..HISTORY_MAX) |i| self.history[i - 1] = self.history[i];
            self.remembered -= 1;
        }

        self.history[self.remembered].set(typed);
        self.remembered += 1;
    }

    /// Put the line back on the screen with the cursor where it belongs.
    ///
    /// The whole line every time: it is at most a couple of hundred cells, and
    /// the alternative is tracking what changed, which is where every subtle
    /// redraw bug in a line editor comes from.
    fn redraw(self: *Editor, prompt: []const u8) void {
        out.byte('\r');
        out.text(prompt);
        out.text(self.line[0..self.len]);

        // Cover whatever a longer line left behind, then come back.
        var erased = self.len;
        while (erased < self.drawn) : (erased += 1) out.byte(' ');
        self.drawn = self.len;

        out.byte('\r');
        out.text(prompt);
        out.text(self.line[0..self.cursor]);
        out.flush();
    }
};
