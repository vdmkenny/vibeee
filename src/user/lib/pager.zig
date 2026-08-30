//! The full-screen text viewer, shared by everything that shows a text a
//! screen at a time: the pager, the manual, and one day the editor's
//! reading half.
//!
//! The caller owns the bytes and hands them over whole; this owns the
//! screen, the line index, the keys and the status bar. Keys come from the
//! keyboard directly rather than through standard input, because standard
//! input is a line at a time and a viewer wants single keys. The claim is
//! released when the process exits, so the shell gets the keyboard back on
//! its own.

const sys = @import("sys");
const console = @import("console.zig");
const ink = @import("ink.zig");
const out = @import("out.zig");
const str = @import("lib").str;

/// What a viewer shows: whose text it is, the text itself, and whether the
/// tail was dropped on the way in, which the bar then says rather than
/// showing a cut file as if it were whole.
pub const Content = struct {
    title: []const u8,
    text: []const u8,
    truncated: bool = false,
};

/// Where each line starts, with one extra entry so the last line's end is
/// found the same way as every other line's. One viewer per process, which
/// is what a tool is.
var line_at: [4096]u32 = @splat(0);
var lines: usize = 0;
var shown: Content = undefined;

/// Form feed clears the console, which is the whole of the screen control
/// needed here.
const CLEAR = 0x0C;

/// Widest console the status bar has to fill. The grid the kernel keeps is
/// bounded too, and this is that bound.
const MAX_COLUMNS = 128;

/// Show the content and hold the screen until the reader quits.
///
/// The whole screen, and the shell's scrollback put aside rather than
/// scrolled away: quitting a viewer should leave what was there before it.
pub fn view(content: Content) void {
    shown = content;
    index();

    console.takeScreen();
    defer console.giveBackScreen();

    const size = console.size();
    // One row goes to the status line, which is what tells a reader whether
    // there is more below.
    const window = if (size.rows > 1) size.rows - 1 else 1;

    var top: usize = 0;
    while (true) {
        draw(top, window);
        switch (command()) {
            .quit => break,
            .down => top = forward(top, 1, window),
            .up => top = back(top, 1),
            .page_down => top = forward(top, window, window),
            .page_up => top = back(top, window),
            .top => top = 0,
            .bottom => top = if (lines > window) lines - window else 0,
            .none => {},
        }
    }
}

/// Record where every line starts.
fn index() void {
    lines = 0;
    var at: usize = 0;
    while (at < shown.text.len and lines < line_at.len - 1) {
        line_at[lines] = @intCast(at);
        lines += 1;
        while (at < shown.text.len and shown.text[at] != '\n') at += 1;
        at += 1;
    }
    line_at[lines] = @intCast(shown.text.len);
}

fn line(n: usize) []const u8 {
    if (n >= lines) return "";
    const from = line_at[n];
    var to = line_at[n + 1];
    // The index points at the next line's first byte, so step back over the
    // separator rather than printing it.
    if (to > from and shown.text[to - 1] == '\n') to -= 1;
    return shown.text[from..to];
}

fn draw(top: usize, window: usize) void {
    out.byte(CLEAR);

    var n: usize = 0;
    while (n < window and top + n < lines) : (n += 1) {
        out.text(line(top + n));
        out.byte('\n');
    }

    // The status line sits on the last row whether or not the text reached
    // it, so it is always in the same place to look at.
    while (n < window) : (n += 1) out.byte('\n');

    // Whatever the text was written in ends here. A line that set a colour
    // and did not clear it would otherwise colour the bar, and reversing an
    // inherited colour gives a bar in a different shade every screen.
    ink.plain();
    status(top, window);
    out.flush();
}

/// Where in the text the reader is, set apart by reversing the colours
/// rather than by picking one, which reads the same on any palette.
fn status(top: usize, window: usize) void {
    var buf: [MAX_COLUMNS]u8 = undefined;
    var bar = str.Builder{ .buf = &buf };

    bar.text(shown.title);
    bar.text("  ");
    bar.number(if (lines == 0) 0 else top + 1);
    bar.byte('-');
    bar.number(@min(top + window, lines));
    bar.text(" of ");
    bar.number(lines);
    if (shown.truncated) bar.text(" (truncated)");
    bar.text(if (top + window >= lines) "  end" else "  more");
    bar.text("   q to quit");

    // Padded to one short of the width: filling the last cell would wrap the
    // console onto another row and the bar would be two cells tall.
    ink.reverse();
    out.pad(bar.done(), console.size().columns - 1);
    ink.plain();
}

const Command = enum { quit, up, down, page_up, page_down, top, bottom, none };

/// Wait for a key and say what it means.
fn command() Command {
    var events: [8]sys.KeyEvent = undefined;
    while (true) {
        for (sys.keyRead(&events, 0)) |event| {
            if (event.pressed == 0) continue;
            return switch (@as(sys.KeyCode, @enumFromInt(event.code))) {
                .q, .escape => .quit,
                .down, .enter => .down,
                .up => .up,
                .space, .page_down => .page_down,
                .b, .page_up => .page_up,
                .home => .top,
                .end => .bottom,
                else => .none,
            };
        }
    }
}

fn forward(top: usize, by: usize, window: usize) usize {
    if (top + window >= lines) return top;
    return @min(top + by, lines - window);
}

fn back(top: usize, by: usize) usize {
    return if (top > by) top - by else 0;
}
