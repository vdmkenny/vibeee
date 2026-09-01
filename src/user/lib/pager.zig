//! The full-screen console: what every program that takes the whole screen
//! needs, and the read-only viewer built on it.
//!
//! Two layers. The lower one is the screen itself, which the pager, the
//! manual and the editor all use the same way: take the screen, draw a band
//! of rows, put a status bar on the last one, read a key. The upper one is
//! `view`, a reader that shows a text and lets somebody move around in it.
//!
//! Keys come from the keyboard where this program can claim it, and from
//! standard input where it cannot: on the machine's own screen the keyboard is
//! there for the taking, and in a window on a desktop it belongs to whatever
//! is compositing, which sends the keys down the same pipe the program's
//! output goes up. The claim, where there is one, is released when the process
//! exits, so the shell gets the keyboard back on its own.

const std = @import("std");
const sys = @import("sys");
const console = @import("console.zig");
const font = @import("lib").font;
const ink = @import("ink.zig");
const keys = @import("keys.zig");
const out = @import("out.zig");
const str = @import("lib").str;
const text = @import("lib").text;

/// What a viewer shows: whose text it is, the text itself, and whether the
/// tail was dropped on the way in, which the bar then says rather than
/// showing a cut file as if it were whole.
pub const Content = struct {
    title: []const u8,
    text: []const u8,
    truncated: bool = false,
};

/// The one text a viewer is showing. Where its lines are is `lib.text`'s
/// arithmetic, not this file's: a reader and an editor have to agree about
/// what a line is, and the rule for the last one is exactly the sort that
/// drifts when it is written twice.
const Reading = struct {
    content: Content = .{ .title = "", .text = "" },
    marks: [4096]u32 = @splat(0),
    count: usize = 0,

    fn index(self: *Reading) void {
        self.count = text.indexLines(self.content.text, &self.marks);
    }

    fn at(ctx: *const anyopaque, n: usize) []const u8 {
        const self: *const Reading = @ptrCast(@alignCast(ctx));
        return text.lineAt(self.content.text, &self.marks, self.count, n);
    }

    fn lines(self: *const Reading) Lines {
        return .{ .count = self.count, .ctx = self, .at = at };
    }
};

/// One viewer per process, which is what a tool is.
var reading: Reading = .{};

/// Form feed clears the console, which is the whole of the screen control
/// needed here.
const CLEAR = 0x0C;

/// Widest console the status bar has to fill. The grid the kernel keeps is
/// bounded too, and this is that bound.
pub const MAX_COLUMNS = 128;

// ---------------------------------------------------------------------------
// The screen
// ---------------------------------------------------------------------------

/// The screen a full-screen program draws on: how big it is, and how much of
/// it is text once the status bar has its row.
pub const Frame = struct {
    columns: usize,
    rows: usize,
    /// Text rows, which is every row but the bar's.
    window: usize,

    pub fn of(size: console.Size) Frame {
        return .{
            .columns = size.columns,
            .rows = size.rows,
            .window = if (size.rows > 1) size.rows - 1 else 1,
        };
    }
};

/// The size a page is laid out for, decided once when a viewer opens.
///
/// A viewer on the machine's own screen asks the kernel; one in a window asks
/// the terminal drawing that window, because the two are different sizes and
/// only the second knows the window's. Which applies is not a guess: a viewer
/// whose keys arrive down a pipe rather than from the keyboard it could not
/// claim is one in a window, and that is the one that asks the terminal.
var measured: ?console.Size = null;

pub fn frame() Frame {
    return Frame.of(measured orelse console.size());
}

fn measure() void {
    // Whether the keyboard is ours to read. Under a compositor it is not, and
    // a viewer there is in a window whose size only the terminal knows: it is
    // asked, and its answer arrives with the keys and lays the page out again.
    var scratch: [1]sys.KeyEvent = undefined;
    const windowed = sys.keyRead(&scratch, sys.POLL) == null;
    measured = if (windowed) console.terminalSize() else null;
}

/// Take the screen for drawing on, putting aside what was there.
pub fn takeScreen() void {
    console.takeScreen();
}

/// Give it back, and with it what was there before.
pub fn giveBackScreen() void {
    console.giveBackScreen();
}

/// Begin a frame: everything drawn after this replaces what was on screen.
pub fn begin() void {
    out.byte(CLEAR);
}

/// End it, with `text` on the status row.
///
/// The bar sits on the last row whether or not the text reached it, so it is
/// always in the same place to look at, and it is set apart by reversing the
/// colours rather than by picking one, which reads the same on any palette.
pub fn end(bar_text: []const u8) void {
    // Whatever the content was written in ends here. A line that set a
    // colour and did not clear it would otherwise colour the bar, and
    // reversing an inherited colour gives a bar in a different shade every
    // screen.
    ink.plain();
    ink.reverse();
    // Padded to one short of the width: filling the last cell would wrap the
    // console onto another row and the bar would be two cells tall.
    out.pad(bar_text, console.size().columns - 1);
    ink.plain();
    out.flush();
}

// ---------------------------------------------------------------------------
// The body
// ---------------------------------------------------------------------------

/// A text to draw, however the caller happens to hold it. A reader keeps a
/// slice and an editor keeps a document, and neither has to become the
/// other to be drawn.
pub const Lines = struct {
    count: usize,
    ctx: *const anyopaque,
    at: *const fn (ctx: *const anyopaque, n: usize) []const u8,

    fn line(self: Lines, n: usize) []const u8 {
        return if (n < self.count) self.at(self.ctx, n) else "";
    }
};

/// What to do with a byte the console would act on rather than draw.
pub const Controls = enum {
    /// Pass it through. What a reader wants: a coloured log stays
    /// coloured, and nothing in it is being pointed at.
    render,
    /// Draw a mark in its place. What an editor needs: a byte that took no
    /// cell, or several, would put every column after it somewhere the
    /// text is not, and the cursor with them.
    mark,
};

/// How a text is laid out: the choices a reader and an editor both offer,
/// held in one place so they mean the same thing in both.
pub const Layout = struct {
    /// A line wider than the screen is folded onto the next row rather than
    /// running off the side.
    wrap: bool = false,
    /// Each line is numbered in a column down the left.
    numbers: bool = false,
    controls: Controls = .render,
};

/// One cell of the text, for marking where a cursor is.
pub const Cell = struct {
    line: usize,
    column: usize,
};

/// How wide the number column is, including the space after it.
fn gutter(lines: Lines, layout: Layout) usize {
    if (!layout.numbers) return 0;
    return text.digits(lines.count) + 1;
}

/// How many rows one line occupies, which is one unless it is wrapped and
/// too wide to fit.
fn heightOf(lines: Lines, n: usize, layout: Layout, width: usize) usize {
    if (!layout.wrap) return 1;
    return text.rowsFor(text.characters(lines.line(n)), width);
}

/// Draw the text into the window, from line `top`, and mark `cursor` if it
/// is there.
///
/// One loop for both programs, because there is one answer to what a
/// screenful of text looks like: numbered or not, folded or not, and a
/// reversed cell where the cursor is.
pub fn body(
    lines: Lines,
    top: usize,
    left: usize,
    size: Frame,
    layout: Layout,
    cursor: ?Cell,
) void {
    const margin = gutter(lines, layout);
    // A column is kept back so a cursor at the end of a full line has a
    // cell of its own rather than wrapping the row.
    const width = if (size.columns > margin + 1) size.columns - margin - 1 else 1;

    var row: usize = 0;
    var n = top;
    while (row < size.window and n < lines.count) : (n += 1) {
        const line = lines.line(n);
        const height = heightOf(lines, n, layout, width);

        var piece: usize = 0;
        while (piece < height and row < size.window) : ({
            piece += 1;
            row += 1;
        }) {
            // The number goes beside the first row of a line only: a folded
            // line is one line however many rows it took.
            if (margin != 0) number(if (piece == 0) n + 1 else 0, margin);

            const from = if (layout.wrap) piece * width else left;
            const shown = text.window(line, from, width);

            const here = if (cursor) |c| at: {
                if (c.line != n) break :at null;
                if (c.column < from or c.column >= from + width) {
                    // The cursor is on this line but not in this piece,
                    // except at the very end of the last one, where it sits
                    // in the cell past the text.
                    const last = piece + 1 == height;
                    if (!(last and c.column == from + text.characters(shown))) break :at null;
                }
                break :at c.column - from;
            } else null;

            // A line that runs off the edge says so. Without it a cut line
            // and a line that happens to end there look the same, and the
            // difference is whether anything is missing.
            const carries_on = !layout.wrap and
                text.characters(line) > from + text.characters(shown);
            // Only where something is actually hidden: a short line under a
            // scrolled-right view has nothing off to its left, and saying it
            // does would be a hint that is not true.
            const carries_back = !layout.wrap and from > 0 and text.characters(line) > 0;
            if (carries_back and here != @as(?usize, 0)) {
                ink.mark(.dim, font.glyphs.arrow_left);
                const rest = text.window(shown, 1, width);
                if (here) |column| {
                    withCursor(rest, column - 1, layout.controls);
                } else {
                    plain(rest, layout.controls);
                }
            } else if (here) |column| {
                withCursor(shown, column, layout.controls);
            } else {
                plain(shown, layout.controls);
            }

            if (carries_on) {
                // The column kept back for a cursor at the end of a full
                // line is exactly where this belongs, so the hint costs no
                // text.
                if (text.characters(shown) < width) {
                    var pad = text.characters(shown);
                    while (pad < width) : (pad += 1) out.byte(' ');
                }
                ink.mark(.dim, font.glyphs.arrow_right);
            }
            out.byte('\n');
        }
    }

    while (row < size.window) : (row += 1) {
        if (margin != 0) number(0, margin);
        out.byte('\n');
    }
}

/// One line's number in the left column, or blanks for a folded line's
/// later rows and for the empty space below the text.
fn number(n: usize, margin: usize) void {
    var buf: [16]u8 = undefined;
    var built = str.Builder{ .buf = &buf };
    if (n != 0) built.number(n);

    ink.use(.dim);
    var pad = built.done().len;
    while (pad + 1 < margin) : (pad += 1) out.byte(' ');
    out.text(built.done());
    out.byte(' ');
    ink.plain();
}

/// One row with the cursor shown in it.
///
/// A reversed cell rather than the console's own: the screen is redrawn
/// whole every keystroke, so a cursor drawn into the text lands in the
/// right place by construction and needs nothing kept in step with it.
fn withCursor(line: []const u8, at: usize, controls: Controls) void {
    plain(text.window(line, 0, at), controls);

    const on = text.window(line, at, 1);
    ink.reverse();
    // Past the end of the text the cursor has no character to sit on, so
    // it sits on a space.
    if (on.len == 0) out.byte(' ') else plain(on, controls);
    ink.plain();

    plain(text.window(line, at + 1, line.len), controls);
}

/// Text, with whatever the caller wants done about the bytes a console
/// would act on rather than draw.
fn plain(line: []const u8, controls: Controls) void {
    if (controls == .render) {
        out.text(line);
        return;
    }

    var at: usize = 0;
    while (at < line.len) {
        const width = text.charWidth(line, at);
        const byte = line[at];
        if (byte < 0x20 or byte == 0x7F) {
            // One mark, one cell, whatever the byte would have done.
            ink.mark(.dim, font.glyphs.bullet);
        } else {
            out.text(line[at..][0..width]);
        }
        at += width;
    }
}

/// Move `top` so the cursor is on screen, counting folded rows when they
/// are folded. A cursor one row below the window moves it one row.
pub fn follow(lines: Lines, top: usize, size: Frame, layout: Layout, at: Cell) usize {
    if (!layout.wrap) return text.follow(top, size.window, at.line);
    if (at.line < top) return at.line;

    const margin = gutter(lines, layout);
    const width = if (size.columns > margin + 1) size.columns - margin - 1 else 1;

    // Walk the window down until the cursor's line fits inside it. Bounded
    // by the lines between: a screenful at worst, and usually one step.
    var start = top;
    while (start <= at.line) {
        var rows: usize = 0;
        var n = start;
        while (n < at.line) : (n += 1) rows += heightOf(lines, n, layout, width);
        rows += 1 + at.column / width;
        if (rows <= size.window) return start;
        start += 1;
    }
    return at.line;
}

/// A line typed into the status bar: a filename, a search, anything a
/// full-screen program has to ask for without leaving the screen.
///
/// The editing is a one-line document's, because that is what it is: the
/// same insert, the same backspace, the same rule about not landing inside
/// a character. A prompt that wrote its own would be a second answer to a
/// question already answered.
///
/// The caller drives it, so the program keeps one drawing path: while a
/// prompt is up, keys go to it and the bar shows it, and everything behind
/// stays on screen.
pub const Prompt = struct {
    line: text.Document,
    label: []const u8,

    pub const Answer = enum { typing, accepted, cancelled };

    /// A prompt over the caller's storage. `index` needs two entries: a
    /// one-line document has one line and the mark past its end.
    pub fn over(label: []const u8, bytes: []u8, marks: []u32, initial: []const u8) Prompt {
        var self = Prompt{
            .line = .{ .bytes = bytes, .line_at = marks },
            .label = label,
        };
        self.line.load(initial);
        self.line.move(.line_end);
        return self;
    }

    pub fn key(self: *Prompt, event: sys.KeyEvent) Answer {
        const code: sys.KeyCode = @enumFromInt(event.code);
        switch (code) {
            .enter => return .accepted,
            .escape => return .cancelled,
            .backspace => _ = self.line.backspace(),
            .delete => _ = self.line.delete(),
            .left => self.line.move(.left),
            .right => self.line.move(.right),
            .home => self.line.move(.line_start),
            .end => self.line.move(.line_end),
            else => {
                if (event.codepoint >= 0x20 and event.codepoint != 0x7F) {
                    _ = self.line.insert(@intCast(event.codepoint));
                }
            },
        }
        return .typing;
    }

    pub fn answer(self: *const Prompt) []const u8 {
        return self.line.contents();
    }

    /// The bar to draw while this is up, with the cursor marked by the one
    /// character a bar can spare for it.
    pub fn bar(self: *const Prompt, into: []u8) []const u8 {
        var built = str.Builder{ .buf = into };
        built.text(self.label);
        const typed = self.answer();
        const at = self.line.cursor.column;
        built.text(typed[0..@min(at, typed.len)]);
        // The bar is one row of one colour, so the cursor is a character
        // rather than a reversed cell.
        built.byte('_');
        if (at < typed.len) built.text(typed[at..]);
        return built.done();
    }
};

/// What waiting on the reader produced.
///
/// A press to act on, word that the window changed size, or the end of input.
/// The middle one is why this is not just a key: a full-screen program has to
/// redraw when its window resizes, and the only way it hears of one is a fresh
/// size arriving in the same stream its keys do.
pub const Input = union(enum) {
    press: sys.KeyEvent,
    resized,
    ended,
};

/// Wait for the reader to say something. The read blocks in the kernel, so a
/// program at rest costs nothing.
///
/// Two places it can come from, and which one applies is not this program's to
/// choose. On the machine's own screen the keyboard is there to be claimed and
/// the events arrive whole. Inside a terminal window the keyboard belongs to
/// whatever is compositing, and what arrives is the bytes that terminal sends:
/// the same presses spelled the way every terminal has spelled them since the
/// VT220, and the window's size whenever it changes.
pub fn input() Input {
    var events: [8]sys.KeyEvent = undefined;
    while (true) {
        const raw = sys.keyRead(&events, sys.FOREVER) orelse return fromTerminal();
        for (raw) |event| {
            if (event.pressed != 0) return .{ .press = event };
        }
    }
}

/// The next key, for a caller that only cares about keys. A resize is folded
/// into the size the next frame will use and otherwise passed over.
pub fn key() ?sys.KeyEvent {
    while (true) {
        switch (input()) {
            .press => |event| return event,
            .resized => {},
            .ended => return null,
        }
    }
}

/// What arrived on the standard input, decoded back into a press or a resize.
///
/// Held across calls because one read brings several things: a held arrow
/// delivers a run of presses, and answering only the first would drop the rest.
var pending: [64]u8 = undefined;
var have: usize = 0;

fn fromTerminal() Input {
    var asked_again = false;

    while (true) {
        // What is already here, before anything is waited for: a buffer with a
        // whole key or a whole report in it has no reason to block.
        if (have > 0) {
            // A size report is the terminal answering how big its window is,
            // whether this program asked or the window just changed. It is not
            // a key and is taken out of the stream before the keys are read.
            switch (console.reportInFront(pending[0..have])) {
                .size => |size| {
                    measured = size.dimensions;
                    take(size.length);
                    return .resized;
                },
                .partial => {
                    asked_again = false;
                    if (fill()) |ended| return ended;
                    continue;
                },
                .none => {},
            }

            const more: keys.More = if (asked_again) .thats_all else .may_follow;
            switch (keys.read(pending[0..have], more)) {
                .got => |press| {
                    take(press.took);
                    return .{ .press = .{
                        .code = @intFromEnum(press.code),
                        .codepoint = press.codepoint,
                        .modifiers = @bitCast(press.mods),
                        .pressed = 1,
                    } };
                },
                .skip => |n| {
                    take(n);
                    continue;
                },
                // A sequence that has not finished. One more read settles it,
                // and a second nothing settles it the other way: a lone escape
                // is the Escape key, which is what a terminal's own timeout
                // decides and for the same reason.
                .partial => if (asked_again) {
                    asked_again = false;
                    continue;
                },
            }
        }

        if (fill()) |ended| return ended;
        asked_again = true;
    }
}

/// Read more into the buffer, or say the input has ended.
///
/// `ended` when the stream closed, and also when the buffer is full of
/// something that is neither a key nor a report: nothing in it will ever
/// become one, so waiting for more would be waiting forever.
fn fill() ?Input {
    if (have == pending.len) {
        have = 0;
        return .ended;
    }
    const n = sys.read(sys.STDIN, pending[have..]);
    if (n <= 0) return .ended;
    have += @intCast(n);
    return null;
}

/// Drop what has been answered for, keeping what came after it.
fn take(n: usize) void {
    const used = @min(n, have);
    std.mem.copyForwards(u8, pending[0 .. have - used], pending[used..have]);
    have -= used;
}

/// Show the content and hold the screen until the reader quits.
///
/// The whole screen, and the shell's scrollback put aside rather than
/// scrolled away: quitting a viewer should leave what was there before it.
pub fn view(content: Content) void {
    reading.content = content;
    reading.index();

    takeScreen();
    defer giveBackScreen();
    measure();
    defer measured = null;

    var top: usize = 0;
    var layout = Layout{};

    while (true) {
        const size = frame();
        draw(top, size, layout);
        switch (command()) {
            .quit => break,
            .down => top = forward(top, 1, size.window),
            .up => top = back(top, 1),
            .page_down => top = forward(top, size.window, size.window),
            .page_up => top = back(top, size.window),
            .top => top = 0,
            .bottom => top = if (reading.count > size.window) reading.count - size.window else 0,
            .wrap => layout.wrap = !layout.wrap,
            .numbers => layout.numbers = !layout.numbers,
            // The size changed under it; the next pass draws to the new one.
            .redraw => {},
            .none => {},
        }
    }
}

fn draw(top: usize, size: Frame, layout: Layout) void {
    begin();
    body(reading.lines(), top, 0, size, layout, null);

    var buf: [MAX_COLUMNS]u8 = undefined;
    var bar = str.Builder{ .buf = &buf };

    bar.text(reading.content.title);
    bar.text("  ");
    bar.number(if (reading.count == 0) 0 else top + 1);
    bar.byte('-');
    bar.number(@min(top + size.window, reading.count));
    bar.text(" of ");
    bar.number(reading.count);
    if (reading.content.truncated) bar.text(" (truncated)");
    bar.text(if (top + size.window >= reading.count) "  end" else "  more");
    bar.text("   w wrap   n numbers   q quit");

    end(bar.done());
}

const Command = enum { quit, up, down, page_up, page_down, top, bottom, wrap, numbers, redraw, none };

/// Wait for something to act on and say what it means to a reader.
fn command() Command {
    while (true) {
        const meant: Command = switch (input()) {
            // A window that changed size is a page to lay out again.
            .resized => .redraw,
            // Input that ended is a reader with nothing left to wait for,
            // which is the same as being told to leave.
            .ended => .quit,
            .press => |event| meaning(event),
        };
        if (meant != .none) return meant;
    }
}

/// What a press means to a reader.
///
/// A letter is judged by what it produced, a movement key by which key it was.
/// The two are separate because a viewer is reached two ways: on the machine's
/// own keyboard, where a press carries both, and down a terminal's pipe, where
/// a letter arrives as its character and a movement key as the code the
/// terminal sends for it. Reading the letter from the character makes `q` quit
/// whichever way it came.
fn meaning(event: sys.KeyEvent) Command {
    switch (event.codepoint) {
        'q' => return .quit,
        'w' => return .wrap,
        'n' => return .numbers,
        'b' => return .page_up,
        ' ' => return .page_down,
        else => {},
    }
    return switch (@as(sys.KeyCode, @enumFromInt(event.code))) {
        .escape => .quit,
        .down, .enter => .down,
        .up => .up,
        .page_down => .page_down,
        .page_up => .page_up,
        .home => .top,
        .end => .bottom,
        else => .none,
    };
}

fn forward(top: usize, by: usize, window: usize) usize {
    if (top + window >= reading.count) return top;
    return @min(top + by, reading.count - window);
}

fn back(top: usize, by: usize) usize {
    return if (top > by) top - by else 0;
}
