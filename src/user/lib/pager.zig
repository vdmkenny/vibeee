//! The full-screen console: what every program that takes the whole screen
//! needs, and the read-only viewer built on it.
//!
//! Two layers. The lower one is the screen itself, which the pager, the
//! manual and the editor all use the same way: take the screen, draw a band
//! of rows, put a status bar on the last one, read a key. The upper one is
//! `view`, a reader that shows a text and lets somebody move around in it.
//!
//! Keys come from the keyboard directly rather than through standard input,
//! because standard input is a line at a time and a full-screen program
//! wants single keys. The claim is released when the process exits, so the
//! shell gets the keyboard back on its own.

const sys = @import("sys");
const console = @import("console.zig");
const ink = @import("ink.zig");
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

/// Where each line starts, with one extra entry so the last line's end is
/// found the same way as every other line's. One viewer per process, which
/// is what a tool is.
var line_at: [4096]u32 = @splat(0);
var lines: usize = 0;
var shown: Content = undefined;

/// Where the lines are is `lib.text`'s arithmetic, not this file's: a
/// reader and an editor have to agree about what a line is, and the rule
/// for the last one is exactly the sort that drifts when it is written
/// twice.

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

pub fn frame() Frame {
    return Frame.of(console.size());
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

/// Wait for one key press, which is what a full-screen program's loop turns
/// on. The read blocks in the kernel, so a program at rest costs nothing.
pub fn key() sys.KeyEvent {
    var events: [8]sys.KeyEvent = undefined;
    while (true) {
        for (sys.keyRead(&events, sys.FOREVER)) |event| {
            if (event.pressed != 0) return event;
        }
    }
}

/// Show the content and hold the screen until the reader quits.
///
/// The whole screen, and the shell's scrollback put aside rather than
/// scrolled away: quitting a viewer should leave what was there before it.
pub fn view(content: Content) void {
    shown = content;
    index();

    takeScreen();
    defer giveBackScreen();

    const window = frame().window;

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

fn index() void {
    lines = text.indexLines(shown.text, &line_at);
}

fn line(n: usize) []const u8 {
    return text.lineAt(shown.text, &line_at, lines, n);
}

fn draw(top: usize, window: usize) void {
    begin();

    var n: usize = 0;
    while (n < window and top + n < lines) : (n += 1) {
        out.text(line(top + n));
        out.byte('\n');
    }
    while (n < window) : (n += 1) out.byte('\n');

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

    end(bar.done());
}

const Command = enum { quit, up, down, page_up, page_down, top, bottom, none };

/// Wait for a key and say what it means to a reader.
fn command() Command {
    while (true) {
        const event = key();
        const meant: Command = switch (@as(sys.KeyCode, @enumFromInt(event.code))) {
            .q, .escape => .quit,
            .down, .enter => .down,
            .up => .up,
            .space, .page_down => .page_down,
            .b, .page_up => .page_up,
            .home => .top,
            .end => .bottom,
            else => .none,
        };
        if (meant != .none) return meant;
    }
}

fn forward(top: usize, by: usize, window: usize) usize {
    if (top + window >= lines) return top;
    return @min(top + by, lines - window);
}

fn back(top: usize, by: usize) usize {
    return if (top > by) top - by else 0;
}
