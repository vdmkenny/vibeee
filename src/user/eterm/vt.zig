//! The terminal: what each sequence does to the screen.
//!
//! Extended VT100, which is the target `design/10-gui.md` §16 settles on: the
//! VT100 set plus the handful of later sequences that everything actually
//! uses. Enough for `kilo`, for a shell with colour, and for the parts of vim
//! that do not need a full terminfo.
//!
//! Anything unrecognised is dropped rather than printed. A terminal that
//! echoes the sequences it does not know produces a screen of noise, and the
//! program producing them has no way to find out.

const std = @import("std");
const parser = @import("parser.zig");
const str = @import("lib").str;
const screen = @import("screen.zig");

const Cell = screen.Cell;
const Csi = parser.Csi;
const Grid = screen.Grid;
const Pen = screen.Pen;
const Style = screen.Style;

/// Bytes the terminal wants to send back, for the sequences that ask a
/// question. Answered into a buffer rather than written directly, so the
/// emulator stays free of anything that can block.
pub const MAX_REPLY = 32;

pub const Terminal = struct {
    grid: Grid = undefined,
    /// The alternate screen, which full-window programs switch to so the
    /// shell's output is still there when they exit.
    alternate: Grid = undefined,
    on_alternate: bool = false,

    cursor: screen.Cursor = .{},
    /// Where DECSC put it. One slot per screen, because switching screens
    /// saves and restores as well.
    saved: screen.Cursor = .{},
    saved_alternate: screen.Cursor = .{},

    /// The scrolling region, inclusive, in rows.
    top: usize = 0,
    bottom: usize = 0,

    /// Every default here is the zero value, and the true defaults are set by
    /// `resize`. A terminal declared at module scope is then all zeroes at
    /// load, which is what keeps its two grids out of the executable.
    hidden: bool = false,
    no_autowrap: bool = false,
    /// Cursor keys send `SS3` rather than `CSI`. Set by DECCKM, which is how
    /// a full-window program tells its arrow keys apart from a shell's.
    application_cursor: bool = false,
    /// Paste is bracketed by `CSI 200~` and `CSI 201~`.
    bracketed_paste: bool = false,
    /// A line feed does not also return the carriage, LNM cleared.
    ///
    /// Off by default here, which is the opposite of a real terminal. There a
    /// pseudo-terminal turns a program's `\n` into `\r\n` on the way out;
    /// with a plain pipe there is nothing between the program and here to do
    /// it, so the terminal does. A program that wants a bare line feed asks
    /// with `CSI 20 l`.
    no_newline_mode: bool = false,
    /// Characters shift the rest of the line right rather than overwriting,
    /// IRM.
    insert_mode: bool = false,

    /// Set whenever anything changed, so a caller knows to redraw. Cleared by
    /// whoever acts on it.
    dirty: bool = false,
    /// The visible bell: a program rang, and the window should say so without
    /// a speaker.
    bell: bool = false,
    /// Set by OSC 0 and 2, the window title.
    title: [64]u8 = @splat(0),
    title_len: usize = 0,
    title_changed: bool = false,

    reply_buf: [MAX_REPLY]u8 = @splat(0),
    reply_len: usize = 0,

    state: parser.Parser = .{},

    /// Bring a terminal up. The two grids are zeroed here rather than by an
    /// initialiser, so they cost nothing in the executable.
    pub fn init(self: *Terminal) void {
        self.* = .{};
        self.grid.init();
        self.alternate.init();

        // A usable size before the window has said how big it is. Output can
        // arrive before the first configure does, and a terminal with no rows
        // would drop it: the shell prints its banner the moment it starts.
        self.resize(80, 24);
    }

    // -----------------------------------------------------------------------
    // Size
    // -----------------------------------------------------------------------

    pub fn resize(self: *Terminal, cols: usize, rows: usize) void {
        const c = std.math.clamp(cols, 2, screen.MAX_COLS);
        const r = std.math.clamp(rows, 2, screen.MAX_ROWS);
        if (c == self.grid.cols and r == self.grid.rows) return;

        // Content is kept where it lands rather than reflowed. Reflow needs
        // the line-continuation flags a terminal only has if it tracked them
        // from the start, and every terminal that does it badly is worse than
        // one that does not.
        self.grid.cols = c;
        self.grid.rows = r;
        self.alternate.cols = c;
        self.alternate.rows = r;

        self.top = 0;
        self.bottom = r - 1;
        self.cursor.row = @min(self.cursor.row, r - 1);
        self.cursor.col = @min(self.cursor.col, c - 1);
        self.dirty = true;
    }

    pub fn active(self: *Terminal) *Grid {
        return if (self.on_alternate) &self.alternate else &self.grid;
    }

    // -----------------------------------------------------------------------
    // Input
    // -----------------------------------------------------------------------

    pub fn write(self: *Terminal, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.state.next(byte)) |action| self.apply(action);
        }
    }

    /// Take what the terminal wants to send back.
    pub fn takeReply(self: *Terminal) []const u8 {
        const out = self.reply_buf[0..self.reply_len];
        self.reply_len = 0;
        return out;
    }

    fn reply(self: *Terminal, bytes: []const u8) void {
        const n = @min(bytes.len, self.reply_buf.len - self.reply_len);
        @memcpy(self.reply_buf[self.reply_len..][0..n], bytes[0..n]);
        self.reply_len += n;
    }

    fn replyNumber(self: *Terminal, value: usize) void {
        var buf: [12]u8 = undefined;
        self.reply(buf[0..str.decimal(&buf, value)]);
    }

    fn apply(self: *Terminal, action: parser.Action) void {
        self.dirty = true;
        switch (action) {
            .print => |ch| self.put(ch),
            .control => |c| self.control(c),
            .escape => |final| self.escape(final),
            .csi => |seq| self.csi(seq),
            .osc => |seq| self.osc(seq),
        }
    }

    // -----------------------------------------------------------------------
    // Printing
    // -----------------------------------------------------------------------

    fn put(self: *Terminal, ch: u32) void {
        const g = self.active();

        if (self.cursor.wrap_pending) {
            self.cursor.col = 0;
            self.lineFeed();
            self.cursor.wrap_pending = false;
        }

        if (self.insert_mode) {
            g.insertChars(self.cursor.row, self.cursor.col, 1, self.cursor.pen.blank());
        }
        g.at(self.cursor.row, self.cursor.col).* = self.cursor.pen.cell(ch);

        if (self.cursor.col + 1 < g.cols) {
            self.cursor.col += 1;
        } else if (!self.no_autowrap) {
            // Deferred: the wrap happens when the next character arrives, so
            // writing the last column and then moving the cursor does not
            // scroll a line that was never full.
            self.cursor.wrap_pending = true;
        }
    }

    fn control(self: *Terminal, c: u8) void {
        switch (c) {
            0x07 => self.bell = true,
            0x08 => {
                if (self.cursor.wrap_pending) {
                    self.cursor.wrap_pending = false;
                } else if (self.cursor.col > 0) {
                    self.cursor.col -= 1;
                }
            },
            0x09 => self.tab(),
            0x0A, 0x0B, 0x0C => {
                self.lineFeed();
                if (!self.no_newline_mode) self.cursor.col = 0;
                self.cursor.wrap_pending = false;
            },
            0x0D => {
                self.cursor.col = 0;
                self.cursor.wrap_pending = false;
            },
            else => {},
        }
    }

    fn tab(self: *Terminal) void {
        const g = self.active();
        // Fixed eight-column stops. Programs that set their own are rare and
        // every one of them also works with the default.
        const next = (self.cursor.col / 8 + 1) * 8;
        self.cursor.col = @min(next, g.cols - 1);
        self.cursor.wrap_pending = false;
    }

    fn lineFeed(self: *Terminal) void {
        if (self.cursor.row == self.bottom) {
            self.active().scrollUp(self.top, self.bottom, 1, self.cursor.pen.blank());
        } else if (self.cursor.row + 1 < self.active().rows) {
            self.cursor.row += 1;
        }
    }

    fn reverseLineFeed(self: *Terminal) void {
        if (self.cursor.row == self.top) {
            self.active().scrollDown(self.top, self.bottom, 1, self.cursor.pen.blank());
        } else if (self.cursor.row > 0) {
            self.cursor.row -= 1;
        }
    }

    // -----------------------------------------------------------------------
    // ESC
    // -----------------------------------------------------------------------

    fn escape(self: *Terminal, final: u8) void {
        switch (final) {
            '7' => self.saved = self.cursor,
            '8' => self.restoreCursor(),
            'D' => self.lineFeed(),
            'E' => {
                self.cursor.col = 0;
                self.lineFeed();
            },
            'M' => self.reverseLineFeed(),
            'c' => self.reset(),
            // Keypad application mode. Accepted so it does not fall through to
            // the screen, ignored because the keypad sends the same either way
            // on a keyboard with no separate one.
            '=', '>' => {},
            else => {},
        }
    }

    fn restoreCursor(self: *Terminal) void {
        const g = self.active();
        self.cursor = self.saved;
        self.cursor.row = @min(self.cursor.row, g.rows - 1);
        self.cursor.col = @min(self.cursor.col, g.cols - 1);
    }

    pub fn reset(self: *Terminal) void {
        const cols = self.grid.cols;
        const rows = self.grid.rows;

        self.init();
        self.grid.cols = cols;
        self.grid.rows = rows;
        self.alternate.cols = cols;
        self.alternate.rows = rows;
        self.bottom = rows - 1;
        self.dirty = true;
    }

    // -----------------------------------------------------------------------
    // CSI
    // -----------------------------------------------------------------------

    fn csi(self: *Terminal, seq: Csi) void {
        if (seq.private) {
            switch (seq.final) {
                'h' => self.setMode(seq, true),
                'l' => self.setMode(seq, false),
                else => {},
            }
            return;
        }

        const g = self.active();
        switch (seq.final) {
            'h' => self.setAnsiMode(seq, true),
            'l' => self.setAnsiMode(seq, false),
            'A' => self.moveUp(seq.get(0, 1)),
            'B' => self.moveDown(seq.get(0, 1)),
            'C' => self.moveRight(seq.get(0, 1)),
            'D' => self.moveLeft(seq.get(0, 1)),
            'E' => {
                self.moveDown(seq.get(0, 1));
                self.cursor.col = 0;
            },
            'F' => {
                self.moveUp(seq.get(0, 1));
                self.cursor.col = 0;
            },
            'G', '`' => self.goTo(self.cursor.row, at(seq, 0)),
            'H', 'f' => self.goTo(at(seq, 0), at(seq, 1)),
            'd' => self.goTo(at(seq, 0), self.cursor.col),
            'J' => self.eraseDisplay(seq.raw(0)),
            'K' => self.eraseLine(seq.raw(0)),
            'L' => g.scrollDown(@max(self.cursor.row, self.top), self.bottom, seq.get(0, 1), self.cursor.pen.blank()),
            'M' => g.scrollUp(@max(self.cursor.row, self.top), self.bottom, seq.get(0, 1), self.cursor.pen.blank()),
            'P' => g.deleteChars(self.cursor.row, self.cursor.col, seq.get(0, 1), self.cursor.pen.blank()),
            '@' => g.insertChars(self.cursor.row, self.cursor.col, seq.get(0, 1), self.cursor.pen.blank()),
            'S' => g.scrollUp(self.top, self.bottom, seq.get(0, 1), self.cursor.pen.blank()),
            'T' => g.scrollDown(self.top, self.bottom, seq.get(0, 1), self.cursor.pen.blank()),
            'X' => self.eraseChars(seq.get(0, 1)),
            'm' => self.style(seq),
            'n' => self.report(seq),
            'r' => self.setRegion(seq),
            's' => self.saved = self.cursor,
            'u' => self.restoreCursor(),
            else => {},
        }
    }

    fn moveUp(self: *Terminal, count: u32) void {
        const n: usize = @intCast(count);
        // Stops at the region's top rather than the screen's: a program that
        // set a region expects its cursor to stay inside it.
        const limit = if (self.cursor.row >= self.top) self.top else 0;
        self.cursor.row = if (self.cursor.row -| n < limit) limit else self.cursor.row - @min(n, self.cursor.row);
        self.cursor.wrap_pending = false;
    }

    fn moveDown(self: *Terminal, count: u32) void {
        const n: usize = @intCast(count);
        const limit = if (self.cursor.row <= self.bottom) self.bottom else self.active().rows - 1;
        self.cursor.row = @min(self.cursor.row + n, limit);
        self.cursor.wrap_pending = false;
    }

    fn moveRight(self: *Terminal, count: u32) void {
        self.cursor.col = @min(self.cursor.col + @as(usize, @intCast(count)), self.active().cols - 1);
        self.cursor.wrap_pending = false;
    }

    fn moveLeft(self: *Terminal, count: u32) void {
        self.cursor.col -|= @as(usize, @intCast(count));
        self.cursor.wrap_pending = false;
    }

    fn goTo(self: *Terminal, row: usize, col: usize) void {
        const g = self.active();
        self.cursor.row = @min(row, g.rows - 1);
        self.cursor.col = @min(col, g.cols - 1);
        self.cursor.wrap_pending = false;
    }

    fn eraseDisplay(self: *Terminal, mode: u32) void {
        const g = self.active();
        const blank = self.cursor.pen.blank();

        switch (mode) {
            0 => {
                @memset(g.row(self.cursor.row)[self.cursor.col..], blank);
                for (self.cursor.row + 1..g.rows) |r| @memset(g.row(r), blank);
            },
            1 => {
                for (0..self.cursor.row) |r| @memset(g.row(r), blank);
                @memset(g.row(self.cursor.row)[0 .. self.cursor.col + 1], blank);
            },
            // 3 erases scrollback, which is not kept, so it is the same as 2.
            2, 3 => g.clear(blank),
            else => {},
        }
    }

    fn eraseLine(self: *Terminal, mode: u32) void {
        const g = self.active();
        const blank = self.cursor.pen.blank();
        const line = g.row(self.cursor.row);

        switch (mode) {
            0 => @memset(line[self.cursor.col..], blank),
            1 => @memset(line[0 .. self.cursor.col + 1], blank),
            2 => @memset(line, blank),
            else => {},
        }
    }

    fn eraseChars(self: *Terminal, count: u32) void {
        const g = self.active();
        const line = g.row(self.cursor.row);
        const n = @min(@as(usize, @intCast(count)), line.len - self.cursor.col);
        @memset(line[self.cursor.col..][0..n], self.cursor.pen.blank());
    }

    fn setRegion(self: *Terminal, seq: Csi) void {
        const g = self.active();
        const first = @min(@as(usize, @intCast(seq.get(0, 1))) - 1, g.rows - 1);
        const last = @min(@as(usize, @intCast(seq.get(1, @intCast(g.rows)))) - 1, g.rows - 1);
        if (first >= last) return;

        self.top = first;
        self.bottom = last;
        // Setting a region homes the cursor, which is what makes the usual
        // "set region then draw" sequence work without an explicit move.
        self.goTo(first, 0);
    }

    fn report(self: *Terminal, seq: Csi) void {
        switch (seq.raw(0)) {
            5 => self.reply("\x1B[0n"),
            6 => {
                self.reply("\x1B[");
                self.replyNumber(self.cursor.row + 1);
                self.reply(";");
                self.replyNumber(self.cursor.col + 1);
                self.reply("R");
            },
            else => {},
        }
    }

    // -----------------------------------------------------------------------
    // SGR and modes
    // -----------------------------------------------------------------------

    fn style(self: *Terminal, seq: Csi) void {
        if (seq.count == 0) {
            self.cursor.pen = .{};
            return;
        }

        var i: usize = 0;
        while (i < seq.count) : (i += 1) {
            const pen = &self.cursor.pen;
            switch (seq.params[i]) {
                0 => pen.* = .{},
                1 => pen.style.bold = true,
                2 => pen.style.dim = true,
                3 => pen.style.italic = true,
                4 => pen.style.underline = true,
                5, 6 => pen.style.blink = true,
                7 => pen.style.inverse = true,
                8 => pen.style.hidden = true,
                9 => pen.style.strike = true,
                22 => {
                    pen.style.bold = false;
                    pen.style.dim = false;
                },
                23 => pen.style.italic = false,
                24 => pen.style.underline = false,
                25 => pen.style.blink = false,
                27 => pen.style.inverse = false,
                28 => pen.style.hidden = false,
                29 => pen.style.strike = false,
                30...37 => {
                    pen.fg = @intCast(seq.params[i] - 30);
                    pen.style.has_fg = true;
                },
                38 => i += self.extendedColor(seq, i, true),
                39 => pen.style.has_fg = false,
                40...47 => {
                    pen.bg = @intCast(seq.params[i] - 40);
                    pen.style.has_bg = true;
                },
                48 => i += self.extendedColor(seq, i, false),
                49 => pen.style.has_bg = false,
                // The bright pairs, which every colour-using program emits.
                90...97 => {
                    pen.fg = @intCast(seq.params[i] - 90 + 8);
                    pen.style.has_fg = true;
                },
                100...107 => {
                    pen.bg = @intCast(seq.params[i] - 100 + 8);
                    pen.style.has_bg = true;
                },
                else => {},
            }
        }
    }

    /// `38;5;n` and `38;2;r;g;b`, and the same for 48. Returns how many extra
    /// parameters were consumed.
    fn extendedColor(self: *Terminal, seq: Csi, start: usize, foreground: bool) usize {
        const pen = &self.cursor.pen;
        const kind = if (start + 1 < seq.count) seq.params[start + 1] else 0;

        switch (kind) {
            5 => {
                if (start + 2 >= seq.count) return 1;
                const index: u8 = @truncate(seq.params[start + 2]);
                if (foreground) {
                    pen.fg = index;
                    pen.style.has_fg = true;
                } else {
                    pen.bg = index;
                    pen.style.has_bg = true;
                }
                return 2;
            },
            2 => {
                if (start + 4 >= seq.count) return 1;
                // Reduced to the 6x6x6 cube. The panel is 18-bit colour and
                // the palette is what the rest of the interface uses; carrying
                // a third colour model through every cell would cost four
                // bytes each to look no different.
                const index = cubeIndex(
                    @truncate(seq.params[start + 2]),
                    @truncate(seq.params[start + 3]),
                    @truncate(seq.params[start + 4]),
                );
                if (foreground) {
                    pen.fg = index;
                    pen.style.has_fg = true;
                } else {
                    pen.bg = index;
                    pen.style.has_bg = true;
                }
                return 4;
            },
            else => return 1,
        }
    }

    /// The modes without a `?`, of which two matter here.
    fn setAnsiMode(self: *Terminal, seq: Csi, on: bool) void {
        for (seq.params[0..seq.count]) |mode| {
            switch (mode) {
                4 => self.insert_mode = on,
                20 => self.no_newline_mode = !on,
                else => {},
            }
        }
    }

    fn setMode(self: *Terminal, seq: Csi, on: bool) void {
        for (seq.params[0..seq.count]) |mode| {
            switch (mode) {
                1 => self.application_cursor = on,
                7 => self.no_autowrap = !on,
                25 => self.hidden = !on,
                47, 1047, 1049 => self.useAlternate(on, mode == 1049),
                2004 => self.bracketed_paste = on,
                else => {},
            }
        }
    }

    fn useAlternate(self: *Terminal, on: bool, save_cursor: bool) void {
        if (on == self.on_alternate) return;

        if (on) {
            if (save_cursor) self.saved = self.cursor;
            self.alternate.clear(self.cursor.pen.blank());
            self.on_alternate = true;
            self.saved_alternate = self.cursor;
            self.cursor.row = 0;
            self.cursor.col = 0;
        } else {
            self.on_alternate = false;
            if (save_cursor) self.restoreCursor() else self.cursor = self.saved_alternate;
        }
        self.top = 0;
        self.bottom = self.active().rows - 1;
    }

    fn osc(self: *Terminal, seq: parser.Osc) void {
        switch (seq.command) {
            // 0 sets both icon name and title, 2 sets the title. Nothing here
            // has an icon name, so they are the same.
            0, 2 => {
                const n = @min(seq.text.len, self.title.len);
                self.title = @splat(0);
                @memcpy(self.title[0..n], seq.text[0..n]);
                self.title_len = n;
                self.title_changed = true;
            },
            else => {},
        }
    }
};

/// A one-based position parameter as a zero-based index. Every addressing
/// sequence counts from one, and every array here counts from zero.
fn at(seq: Csi, index: usize) usize {
    return @as(usize, @intCast(seq.get(index, 1))) - 1;
}

/// The nearest entry in the 256-colour cube to a 24-bit colour.
fn cubeIndex(r: u8, g: u8, b: u8) u8 {
    // Grey gets the grey ramp, which has twenty-four steps against the cube's
    // six and is what most true-colour output near grey is aiming for.
    if (r == g and g == b) {
        if (r < 8) return 16;
        if (r > 248) return 231;
        return @intCast(232 + (@as(u16, r) - 8) * 24 / 247);
    }
    const level = struct {
        fn of(v: u8) u16 {
            return (@as(u16, v) * 5 + 127) / 255;
        }
    };
    return @intCast(16 + 36 * level.of(r) + 6 * level.of(g) + level.of(b));
}
