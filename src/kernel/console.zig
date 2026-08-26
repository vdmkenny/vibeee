//! Kernel console: cursor tracking, scrolling, formatting and the boot log.
//!
//! Device-independent. The cell-level work belongs to a backend, either
//! `drv/video/vgatext.zig` or `drv/video/fbcon.zig`, chosen at boot from what
//! the firmware provided. Both present the same cell interface, so nothing
//! here depends on which one is in use.

const std = @import("std");
const klog = @import("klog.zig");
const bootinfo = @import("bootinfo.zig");
const fbcon = @import("../drv/video/fbcon.zig");
const vgatext = @import("../drv/video/vgatext.zig");

pub const Color = vgatext.Color;

/// Code points the console draws that are not plain ASCII.
pub const BLOCK_UPPER_HALF: u21 = 0x2580;

/// Map a code point to the VGA text mode's CP437 byte.
///
/// Only the handful the kernel actually draws. Everything else falls back to
/// '?': a visible marker beats a blank, which reads as a bug in whatever
/// produced the text.
fn toCp437(cp: u21) u8 {
    return switch (cp) {
        0x00...0x7F => @intCast(cp),
        BLOCK_UPPER_HALF => 0xDF,
        0x2584 => 0xDC, // lower half block
        0x2588 => 0xDB, // full block
        else => '?',
    };
}

/// Console geometry. Fixed at 80x25 in text mode, and whatever the framebuffer
/// affords otherwise, so it cannot be a compile-time constant.
var columns: usize = vgatext.WIDTH;
var rows: usize = vgatext.HEIGHT;

pub fn width() usize {
    return columns;
}

pub fn height() usize {
    return rows;
}

/// Switch to the framebuffer if stage2 set a graphics mode.
///
/// Called early, before anything has been drawn: in graphics mode the text
/// buffer at 0xB8000 is not displayed, so output written before the switch
/// would simply vanish.
/// True when the console can address individual pixels.
pub fn hasPixels() bool {
    return fbcon.active();
}

pub const Size = fbcon.Size;

/// Stop drawing to the framebuffer because something else owns it now.
///
/// Output is still accepted and still mirrored to the serial port, so a kernel
/// message during a GUI session is not lost; it simply does not appear over
/// the top of whatever is on screen.
pub fn suspendFramebuffer() void {
    fbcon.setSuspended(true);
}

pub fn resumeFramebuffer() void {
    fbcon.setSuspended(false);
    clear();
}

pub const FbLayout = fbcon.Layout;

/// Where the framebuffer is, or a zero address in text mode.
pub fn framebufferLayout() FbLayout {
    return if (fbcon.active()) fbcon.layout() else .{ .addr = 0, .pitch = 0 };
}

/// Point the console at a framebuffer of a different shape, after a modeset.
pub fn adoptFramebuffer(phys: usize, pitch: usize, px_width: usize, px_height: usize) bool {
    if (!fbcon.active()) return false;
    if (!fbcon.adopt(phys, pitch, px_width, px_height)) return false;
    const dims = fbcon.dimensions();
    columns = dims.columns;
    rows = dims.rows;
    moveTo(0, 0);
    return true;
}

pub fn pixelSize() Size {
    return if (fbcon.active()) fbcon.pixelSize() else .{ .width = 0, .height = 0 };
}

pub fn cellSize() Size {
    return if (fbcon.active()) fbcon.cellSize() else .{ .width = 8, .height = 16 };
}

/// Fill a pixel rectangle. Does nothing in text mode.
pub fn fillPixelRect(x: usize, y: usize, w: usize, h: usize, colour: Color) void {
    if (fbcon.active()) fbcon.fillRect(x, y, w, h, @intFromEnum(colour));
}

/// Name of the active font, for the boot log.
pub fn fontName() []const u8 {
    return if (fbcon.active()) fbcon.fontName() else "VGA ROM 8x16";
}

pub fn useFramebuffer(bi: *const bootinfo.BootInfo) bool {
    if (!fbcon.init(bi)) return false;
    const dims = fbcon.dimensions();
    columns = dims.columns;
    rows = dims.rows;
    moveTo(0, 0);
    return true;
}

const backend = struct {
    fn putAt(x: usize, y: usize, cp: u21, front: Color, back: Color) void {
        if (fbcon.active()) {
            fbcon.putAt(x, y, cp, @intFromEnum(front), @intFromEnum(back));
        } else {
            vgatext.putAt(x, y, toCp437(cp), front, back);
        }
    }

    fn fill(cp: u21, front: Color, back: Color) void {
        if (fbcon.active()) {
            fbcon.fill(cp, @intFromEnum(front), @intFromEnum(back));
        } else {
            vgatext.fill(toCp437(cp), front, back);
        }
    }

    fn scroll(front: Color, back: Color) void {
        if (fbcon.active()) {
            fbcon.scroll(@intFromEnum(back));
        } else {
            vgatext.scroll(front, back);
        }
    }

    fn setCursor(x: usize, y: usize) void {
        if (!fbcon.active()) vgatext.setCursor(x, y);
    }
};

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
    col = @min(x, columns - 1);
    row = @min(y, rows - 1);
    backend.setCursor(col, row);
}

/// Write one cell at an absolute position, bypassing the cursor. Used by the
/// panic screen, which paints a fixed layout rather than a scrolling log.
pub fn putAt(x: usize, y: usize, cp: u21, f: Color, b: Color) void {
    backend.putAt(x, y, cp, f, b);
}

fn newline() void {
    col = 0;
    row += 1;
    if (row >= rows) {
        backend.scroll(fg, bg);
        row = rows - 1;
    }
}

pub fn putChar(c: u8) void {
    if (mirror) |sink| sink(&[_]u8{c});
    switch (c) {
        '\n' => newline(),
        '\r' => col = 0,
        // Form feed clears the screen. The traditional meaning, and it saves
        // inventing a syscall for something a terminal has always done with a
        // byte: `clear` in the shell is one write.
        0x0C => clear(),
        '\t' => {
            const next = (col + 8) & ~@as(usize, 7);
            while (col < next and col < columns) : (col += 1) {
                backend.putAt(col, row, ' ', fg, bg);
            }
            if (col >= columns) newline();
        },
        8 => if (col > 0) {
            col -= 1;
            backend.putAt(col, row, ' ', fg, bg);
        },
        else => {
            backend.putAt(col, row, c, fg, bg);
            col += 1;
            if (col >= columns) newline();
        },
    }
}

pub fn writeString(s: []const u8) void {
    for (s) |c| putChar(c);
    backend.setCursor(col, row);
}

/// Optional second destination for everything written to the console.
///
/// Registered by the composition root when a serial port is found. The target
/// machine has none, but QEMU and most other hardware do, and having the boot
/// log arrive as text rather than pixels is the difference between reading it
/// and photographing it.
var mirror: ?*const fn ([]const u8) void = null;

pub fn setMirror(sink: *const fn ([]const u8) void) void {
    mirror = sink;
}

// ---------------------------------------------------------------------------
// Formatted output
// ---------------------------------------------------------------------------

/// std.Io.Writer adapter, so kernel code gets the normal `print("{d}", .{x})`
/// machinery.
///
/// The buffer is intentionally empty: every write goes straight through `drain`
/// to the backend. Buffering would mean a panic mid-format loses the last
/// partial line, exactly the line you need on a machine whose only diagnostic
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

/// One boot-log line: a coloured key column, then the value. Terse by design,
/// this is a system log, not narration.
fn logLine(key: []const u8, key_color: Color, comptime fmt: []const u8, args: anytype) void {
    recordLine(key, fmt, args);

    const saved = fg;
    setColor(key_color, bg);
    writeString(key);
    setColor(saved, bg);

    // At least one space, so a key exactly KEY_WIDTH long does not run into
    // its value.
    var n = key.len;
    while (n < KEY_WIDTH) : (n += 1) putChar(' ');
    if (key.len >= KEY_WIDTH) putChar(' ');

    printf(fmt, args);
    putChar('\n');
    backend.setCursor(col, row);
}

/// Verbose boot logging. Off by default: a working system should boot quietly,
/// and a self-test that passed is not news to a user. Enabled with `verbose` on
/// the kernel command line.
///
/// The checks themselves always run, only their success output is suppressed,
/// so a regression still surfaces as a `warn` or `fail` line.
var verbose = false;

pub fn setVerbose(on: bool) void {
    verbose = on;
}

pub fn isVerbose() bool {
    return verbose;
}

/// Keep a line whether or not it is printed.
///
/// A quiet boot shows almost nothing by design, and the machine should still
/// know what happened. Formatted into a scratch buffer rather than written
/// through the console's writer, which goes to the screen.
fn recordLine(key: []const u8, comptime fmt: []const u8, args: anytype) void {
    var scratch: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&scratch);

    w.print("{s}", .{key}) catch {};
    var n = key.len;
    while (n < KEY_WIDTH) : (n += 1) w.print(" ", .{}) catch {};
    w.print(fmt, args) catch {};
    w.print("\n", .{}) catch {};

    klog.append(scratch[0..w.end]);
}

/// A diagnostic line: recorded always, shown only in verbose mode.
pub fn debug(key: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!verbose) {
        recordLine(key, fmt, args);
        return;
    }
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
