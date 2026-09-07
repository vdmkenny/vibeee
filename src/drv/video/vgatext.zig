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

/// One cell of the text buffer: the character, then the two colours in the
/// attribute byte above it.
///
/// A shape rather than the shifts on either side of it. What was packed in one
/// place and taken apart in another is one cast each way now, and a third
/// place that wrote the layout out as literals reads the same struct.
pub const Cell = packed struct(u16) {
    character: u8 = ' ',
    foreground: Color = .light_grey,
    background: Color = .black,
};

pub fn putAt(x: usize, y: usize, ch: u8, fg: Color, bg: Color) void {
    if (x >= WIDTH or y >= HEIGHT) return;
    cells[y * WIDTH + x] = @bitCast(Cell{
        .character = ch,
        .foreground = fg,
        .background = bg,
    });
}

pub fn fill(ch: u8, fg: Color, bg: Color) void {
    const v: u16 = @bitCast(Cell{ .character = ch, .foreground = fg, .background = bg });
    var i: usize = 0;
    while (i < WIDTH * HEIGHT) : (i += 1) cells[i] = v;
}

/// Move every row up by one and blank the last.
pub fn scroll(fg: Color, bg: Color) void {
    var i: usize = 0;
    while (i < (HEIGHT - 1) * WIDTH) : (i += 1) cells[i] = cells[i + WIDTH];
    const blank: u16 = @bitCast(Cell{ .foreground = fg, .background = bg });
    while (i < HEIGHT * WIDTH) : (i += 1) cells[i] = blank;
}

/// Position the hardware cursor. Cosmetic, but it makes a hang visibly
/// different from a slow boot.
/// Show or hide the hardware cursor.
///
/// Bit 5 of the cursor-start register turns it off. What a full-screen program
/// asks for while it redraws, so the cursor is not seen skating across a
/// half-drawn screen on its way to where it belongs.
/// What is in a cell, read back out of the text buffer.
pub fn cellAt(x: usize, y: usize) Cell {
    if (x >= WIDTH or y >= HEIGHT) return .{};
    return @bitCast(cells[y * WIDTH + x]);
}

pub fn showCursor(visible: bool) void {
    hal.outb(CRTC_INDEX, 0x0A);
    const start = hal.inb(CRTC_DATA);
    hal.outb(CRTC_INDEX, 0x0A);
    hal.outb(CRTC_DATA, if (visible) start & ~@as(u8, 0x20) else start | 0x20);
}

pub fn setCursor(x: usize, y: usize) void {
    const pos: u16 = @intCast(@min(y, HEIGHT - 1) * WIDTH + @min(x, WIDTH - 1));
    hal.outb(CRTC_INDEX, 0x0F);
    hal.outb(CRTC_DATA, @truncate(pos & 0xFF));
    hal.outb(CRTC_INDEX, 0x0E);
    hal.outb(CRTC_DATA, @truncate((pos >> 8) & 0xFF));
}
