//! Kernel console: cursor tracking, scrolling, formatting and the boot log.
//!
//! Device-independent. The cell-level work belongs to a backend — currently
//! `drv/video/vgatext.zig`, later the framebuffer console once the display
//! driver is up. Both present the same cell interface, so nothing here changes.

const std = @import("std");
const backend = @import("../drv/video/vgatext.zig");

pub const Color = backend.Color;
pub const COLUMNS = backend.WIDTH;
pub const ROWS = backend.HEIGHT;

/// Width of the key column in the boot log. Defined once so `field`, `warn`
/// and `fail` cannot drift out of alignment with each other.
const KEY_WIDTH = 8;

var row: usize = 0;
var col: usize = 0;
var fg: Color = .light_grey;
var bg: Color = .black;

pub fn init() void {
    setColor(.light_grey, .black);
    clear();
}

pub fn setColor(f: Color, b: Color) void {
    fg = f;
    bg = b;
}

pub fn clear() void {
    backend.fill(' ', fg, bg);
    moveTo(0, 0);
}

/// Paint the whole screen one colour and home the cursor.
pub fn fill(background: Color, foreground: Color) void {
    setColor(foreground, background);
    clear();
}

pub fn moveTo(x: usize, y: usize) void {
    col = @min(x, COLUMNS - 1);
    row = @min(y, ROWS - 1);
    backend.setCursor(col, row);
}

/// Write one cell at an absolute position, bypassing the cursor. Used by the
/// panic screen, which paints a fixed layout rather than a scrolling log.
pub fn putAt(x: usize, y: usize, ch: u8, f: Color, b: Color) void {
    backend.putAt(x, y, ch, f, b);
}

fn newline() void {
    col = 0;
    row += 1;
    if (row >= ROWS) {
        backend.scroll(fg, bg);
        row = ROWS - 1;
    }
}

pub fn putChar(c: u8) void {
    switch (c) {
        '\n' => newline(),
        '\r' => col = 0,
        '\t' => {
            const next = (col + 8) & ~@as(usize, 7);
            while (col < next and col < COLUMNS) : (col += 1) {
                backend.putAt(col, row, ' ', fg, bg);
            }
            if (col >= COLUMNS) newline();
        },
        8 => if (col > 0) {
            col -= 1;
            backend.putAt(col, row, ' ', fg, bg);
        },
        else => {
            backend.putAt(col, row, c, fg, bg);
            col += 1;
            if (col >= COLUMNS) newline();
        },
    }
}

pub fn writeString(s: []const u8) void {
    for (s) |c| putChar(c);
    backend.setCursor(col, row);
}

// ---------------------------------------------------------------------------
// Formatted output
// ---------------------------------------------------------------------------

/// std.Io.Writer adapter, so kernel code gets the normal `print("{d}", .{x})`
/// machinery.
///
/// The buffer is intentionally empty: every write goes straight through `drain`
/// to the backend. Buffering would mean a panic mid-format loses the last
/// partial line — exactly the line you need on a machine whose only diagnostic
/// is the screen.
var console_writer: std.Io.Writer = .{
    .vtable = &.{ .drain = drain },
    .buffer = &.{},
};

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    if (w.end > 0) {
        for (w.buffer[0..w.end]) |c| putChar(c);
        w.end = 0;
    }
    const head = data[0 .. data.len - 1];
    const pattern = data[head.len];

    var written: usize = 0;
    for (head) |bytes| {
        for (bytes) |c| putChar(c);
        written += bytes.len;
    }
    var i: usize = 0;
    while (i < splat) : (i += 1) {
        for (pattern) |c| putChar(c);
    }
    return written + pattern.len * splat;
}

/// Float formatting is never used in the kernel: it is built without x87/SSE
/// (see build.zig), so a float here is a link error rather than a runtime
/// surprise.
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    console_writer.print(fmt, args) catch {};
    backend.setCursor(col, row);
}

// ---------------------------------------------------------------------------
// Boot log
// ---------------------------------------------------------------------------

/// One boot-log line: a coloured key column, then the value. Terse by design —
/// this is a system log, not narration.
fn logLine(key: []const u8, key_color: Color, comptime fmt: []const u8, args: anytype) void {
    const saved = fg;
    setColor(key_color, bg);
    writeString(key);
    setColor(saved, bg);

    var n = key.len;
    while (n < KEY_WIDTH) : (n += 1) putChar(' ');

    printf(fmt, args);
    putChar('\n');
    backend.setCursor(col, row);
}

/// Verbose boot logging. Off by default: a working system should boot quietly,
/// and a self-test that passed is not news to a user. Enabled with `verbose` on
/// the kernel command line.
///
/// The checks themselves always run — only their success output is suppressed,
/// so a regression still surfaces as a `warn` or `fail` line.
var verbose = false;

pub fn setVerbose(on: bool) void {
    verbose = on;
}

pub fn isVerbose() bool {
    return verbose;
}

/// A diagnostic line: shown only in verbose mode.
pub fn debug(key: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!verbose) return;
    logLine(key, .light_cyan, fmt, args);
}

/// A line worth showing a user regardless of verbosity.
pub fn field(key: []const u8, comptime fmt: []const u8, args: anytype) void {
    logLine(key, .light_cyan, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    logLine("warn", .yellow, fmt, args);
}

pub fn fail(comptime fmt: []const u8, args: anytype) void {
    logLine("fail", .light_red, fmt, args);
}
