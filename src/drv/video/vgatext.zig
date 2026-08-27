//! VGA text mode (80x25) at 0xB8000.
//!
//! A driver, not kernel core: text-mode video memory and the CRTC cursor ports
//! are IBM PC legacy, and a machine without them wants a different backend
//! behind the same interface.
//!
//! This is the dumbest possible output device, and that is exactly why the
//! panic path depends on it: it keeps working when everything else is broken,
//! and on a machine with no serial port it is the only early output there is.

const hal = @import("../../kernel/hal.zig");
const port = @import("../../arch/x86/port.zig");

pub const WIDTH: usize = 80;
pub const HEIGHT: usize = 25;

pub const Color = enum(u4) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_grey = 7,
    dark_grey = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_magenta = 13,
    yellow = 14,
    white = 15,
};

const CRTC_INDEX = 0x3D4;
const CRTC_DATA = 0x3D5;

/// Reached through the kernel linear map: paging is on before anything here
/// runs, and the identity mapping is gone.
const cells: [*]volatile u16 = @ptrFromInt(hal.physToVirt(0xB8000));

inline fn cell(ch: u8, fg: Color, bg: Color) u16 {
    const attr = @as(u16, @intFromEnum(fg)) | (@as(u16, @intFromEnum(bg)) << 4);
    return @as(u16, ch) | (attr << 8);
}

pub fn putAt(x: usize, y: usize, ch: u8, fg: Color, bg: Color) void {
    if (x >= WIDTH or y >= HEIGHT) return;
    cells[y * WIDTH + x] = cell(ch, fg, bg);
}

pub fn fill(ch: u8, fg: Color, bg: Color) void {
    const v = cell(ch, fg, bg);
    var i: usize = 0;
    while (i < WIDTH * HEIGHT) : (i += 1) cells[i] = v;
}

/// Move every row up by one and blank the last.
pub fn scroll(fg: Color, bg: Color) void {
    var i: usize = 0;
    while (i < (HEIGHT - 1) * WIDTH) : (i += 1) cells[i] = cells[i + WIDTH];
    const blank = cell(' ', fg, bg);
    while (i < HEIGHT * WIDTH) : (i += 1) cells[i] = blank;
}

/// Position the hardware cursor. Cosmetic, but it makes a hang visibly
/// different from a slow boot.
/// Show or hide the hardware cursor.
///
/// Bit 5 of the cursor-start register turns it off. What a full-screen program
/// asks for while it redraws, so the cursor is not seen skating across a
/// half-drawn screen on its way to where it belongs.
/// What is in a cell, read back out of the text buffer. The attribute byte
/// holds both colours: foreground low, background high.
pub fn cellAt(x: usize, y: usize) struct { ch: u8, fg: Color, bg: Color } {
    if (x >= WIDTH or y >= HEIGHT) return .{ .ch = ' ', .fg = .light_grey, .bg = .black };

    const raw = cells[y * WIDTH + x];
    return .{
        .ch = @truncate(raw),
        .fg = @enumFromInt(@as(u4, @truncate(raw >> 8))),
        .bg = @enumFromInt(@as(u4, @truncate(raw >> 12))),
    };
}

pub fn showCursor(visible: bool) void {
    port.outb(CRTC_INDEX, 0x0A);
    const start = port.inb(CRTC_DATA);
    port.outb(CRTC_INDEX, 0x0A);
    port.outb(CRTC_DATA, if (visible) start & ~@as(u8, 0x20) else start | 0x20);
}

pub fn setCursor(x: usize, y: usize) void {
    const pos: u16 = @intCast(@min(y, HEIGHT - 1) * WIDTH + @min(x, WIDTH - 1));
    port.outb(CRTC_INDEX, 0x0F);
    port.outb(CRTC_DATA, @truncate(pos & 0xFF));
    port.outb(CRTC_INDEX, 0x0E);
    port.outb(CRTC_DATA, @truncate((pos >> 8) & 0xFF));
}
