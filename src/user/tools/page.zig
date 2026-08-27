//! page, a pager: show a file a screen at a time and move around in it.
//!
//! The console scrolls and does not remember, so anything longer than the
//! screen is gone as soon as it is printed. This exists so a long report can
//! be read at all, which on a machine whose diagnostics are all long reports
//! is most of them.
//!
//! Keys come from the keyboard directly rather than through standard input,
//! because standard input is a line at a time and a pager wants single keys.
//! The claim is released when the process exits, so the shell gets the
//! keyboard back on its own.

const sys = @import("sys");
const console = @import("ulib").console;
const ink = @import("ulib").ink;
const out = @import("ulib").out;
const str = @import("ulib").str;

/// As much of a file as this will hold. Past it the tail is dropped, and said
/// so rather than silently shown as if it were the whole file.
var text: [32 * 1024]u8 = @splat(0);
var filled: usize = 0;
var truncated = false;

/// Where each line starts, with one extra entry so the last line's end is
/// found the same way as every other line's.
var line_at: [4096]u32 = @splat(0);
var lines: usize = 0;

/// Form feed clears the console, which is the whole of the screen control
/// needed here.
const CLEAR = 0x0C;

/// Widest console the status bar has to fill. The grid the kernel keeps is
/// bounded too, and this is that bound.
const MAX_COLUMNS = 128;

pub fn run(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: page <file>\n");
        out.flush();
        return;
    }

    if (!load(args[0])) return;
    index();

    // The whole screen, and the shell's scrollback put aside rather than
    // scrolled away: quitting a pager should leave what was there before it.
    console.takeScreen();
    defer console.giveBackScreen();

    const size = consoleSize();
    // One row goes to the status line, which is what tells a reader whether
    // there is more below.
    const window = if (size.rows > 1) size.rows - 1 else 1;

    var top: usize = 0;
    while (true) {
        draw(top, window, args[0]);
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

fn load(path: []const u8) bool {
    const handle = sys.open(path, .{});
    if (handle < 0) {
        out.text("page: ");
        out.text(path);
        out.text(": cannot open\n");
        out.flush();
        return false;
    }
    defer _ = sys.close(@intCast(handle));

    while (filled < text.len) {
        const n = sys.read(@intCast(handle), text[filled..]);
        if (n <= 0) break;
        filled += @intCast(n);
    }

    // A read that filled the buffer may have left more behind it.
    truncated = filled == text.len;
    return true;
}

/// Record where every line starts.
fn index() void {
    lines = 0;
    var at: usize = 0;
    while (at < filled and lines < line_at.len - 1) {
        line_at[lines] = @intCast(at);
        lines += 1;
        while (at < filled and text[at] != '\n') at += 1;
        at += 1;
    }
    line_at[lines] = @intCast(filled);
}

fn line(n: usize) []const u8 {
    if (n >= lines) return "";
    const from = line_at[n];
    var to = line_at[n + 1];
    // The index points at the next line's first byte, so step back over the
    // separator rather than printing it.
    if (to > from and text[to - 1] == '\n') to -= 1;
    return text[from..to];
}

fn draw(top: usize, window: usize, path: []const u8) void {
    out.byte(CLEAR);

    var n: usize = 0;
    while (n < window and top + n < lines) : (n += 1) {
        out.text(line(top + n));
        out.byte('\n');
    }

    // The status line sits on the last row whether or not the text reached it,
    // so it is always in the same place to look at.
    while (n < window) : (n += 1) out.byte('\n');

    status(top, window, path);
    out.flush();
}

/// Where in the file the reader is, set apart by reversing the colours rather
/// than by picking one, which reads the same on any palette.
fn status(top: usize, window: usize, path: []const u8) void {
    var buf: [MAX_COLUMNS]u8 = undefined;
    var bar = str.Builder{ .buf = &buf };

    bar.text(path);
    bar.text("  ");
    bar.number(if (lines == 0) 0 else top + 1);
    bar.byte('-');
    bar.number(@min(top + window, lines));
    bar.text(" of ");
    bar.number(lines);
    if (truncated) bar.text(" (truncated)");
    bar.text(if (top + window >= lines) "  end" else "  more");
    bar.text("   q to quit");

    // Padded to one short of the width: filling the last cell would wrap the
    // console onto another row and the bar would be two cells tall.
    ink.reverse();
    out.pad(bar.done(), consoleSize().columns - 1);
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

/// The console's shape, which decides how much fits on a screen.
fn consoleSize() console.Size {
    return console.size();
}
