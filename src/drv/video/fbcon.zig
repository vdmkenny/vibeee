//! Framebuffer text console.
//!
//! Presents the same cell interface as the VGA text backend, so the console
//! layer above is unchanged — only the destination of a character differs.
//!
//! Glyphs come from the video ROM, copied out by stage2 before the mode change.
//! Embedding a font would cost four kilobytes and look less like the machine.
//!
//! Colour is the sixteen-entry VGA palette rather than anything richer,
//! because everything that draws here — the boot log, the panic screen — was
//! written against those sixteen and gains nothing from more.

const std = @import("std");
const bootinfo = @import("../../kernel/bootinfo.zig");
const hal = @import("../../kernel/hal.zig");

pub const GLYPH_WIDTH = 8;
pub const GLYPH_HEIGHT = 16;

/// The standard VGA palette, as XRGB8888.
const PALETTE = [16]u32{
    0x000000, 0x0000AA, 0x00AA00, 0x00AAAA,
    0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
    0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
    0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
};

var fb: [*]volatile u8 = undefined;
var font: [*]const u8 = undefined;
var pitch: usize = 0;
var pixel_width: usize = 0;
var pixel_height: usize = 0;
var bytes_per_pixel: usize = 4;

var columns: usize = 0;
var rows: usize = 0;
var ready = false;

/// Set up from what stage2 recorded. Returns false when there is no usable
/// framebuffer, leaving the caller to keep the text-mode backend.
pub fn init(bi: *const bootinfo.BootInfo) bool {
    if (!bi.hasFramebuffer() or bi.font_addr == 0) return false;
    // 32bpp only: stage2 asks for nothing else, and a console that silently
    // rendered garbage at another depth would be worse than staying in text.
    if (bi.fb_bpp != 32) return false;

    // A framebuffer normally sits at a physical address well above RAM, so it
    // has no linear-map address and must be mapped explicitly.
    const fb_virt = if (hal.isLinearPhys(bi.fb_addr))
        hal.physToVirt(bi.fb_addr)
    else
        hal.mapMmio(bi.fb_addr, @as(usize, bi.fb_pitch) * bi.fb_height) catch return false;

    fb = @ptrFromInt(fb_virt);
    font = @ptrFromInt(hal.physToVirt(bi.font_addr));
    pitch = bi.fb_pitch;
    pixel_width = bi.fb_width;
    pixel_height = bi.fb_height;
    bytes_per_pixel = 4;

    columns = pixel_width / GLYPH_WIDTH;
    rows = pixel_height / GLYPH_HEIGHT;
    ready = true;

    clearAll(PALETTE[0]);
    return true;
}

pub fn active() bool {
    return ready;
}

pub fn dimensions() struct { columns: usize, rows: usize } {
    return .{ .columns = columns, .rows = rows };
}

inline fn pixelAt(x: usize, y: usize) [*]volatile u8 {
    return fb + y * pitch + x * bytes_per_pixel;
}

fn putPixel(x: usize, y: usize, colour: u32) void {
    const p = pixelAt(x, y);
    p[0] = @truncate(colour);
    p[1] = @truncate(colour >> 8);
    p[2] = @truncate(colour >> 16);
    p[3] = 0;
}

fn clearAll(colour: u32) void {
    var y: usize = 0;
    while (y < pixel_height) : (y += 1) {
        var x: usize = 0;
        while (x < pixel_width) : (x += 1) putPixel(x, y, colour);
    }
}

/// Draw one character cell.
pub fn putAt(col: usize, row: usize, ch: u8, fg: u4, bg: u4) void {
    if (!ready or col >= columns or row >= rows) return;

    const glyph = font + @as(usize, ch) * GLYPH_HEIGHT;
    const fg_colour = PALETTE[fg];
    const bg_colour = PALETTE[bg];

    const x0 = col * GLYPH_WIDTH;
    const y0 = row * GLYPH_HEIGHT;

    var gy: usize = 0;
    while (gy < GLYPH_HEIGHT) : (gy += 1) {
        const bits = glyph[gy];
        var gx: usize = 0;
        while (gx < GLYPH_WIDTH) : (gx += 1) {
            // Bit 7 is the leftmost pixel.
            const lit = (bits >> @intCast(7 - gx)) & 1 != 0;
            putPixel(x0 + gx, y0 + gy, if (lit) fg_colour else bg_colour);
        }
    }
}

pub fn fill(ch: u8, fg: u4, bg: u4) void {
    if (!ready) return;
    // A blank cell is a solid rectangle, so the common case avoids the glyph
    // walk entirely — this runs on every clear and every panic.
    if (ch == ' ') {
        clearAll(PALETTE[bg]);
        return;
    }
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var col: usize = 0;
        while (col < columns) : (col += 1) putAt(col, row, ch, fg, bg);
    }
}

/// Scroll up one text row.
///
/// A raw copy of the pixels above, rather than redrawing glyphs: a full
/// redraw would mean rasterising two thousand characters, and this runs
/// every time the log reaches the bottom of the screen.
pub fn scroll(bg: u4) void {
    if (!ready) return;

    const row_bytes = pitch * GLYPH_HEIGHT;
    const moved = (rows - 1) * row_bytes;

    var i: usize = 0;
    while (i < moved) : (i += 1) fb[i] = fb[i + row_bytes];

    const colour = PALETTE[bg];
    var y = (rows - 1) * GLYPH_HEIGHT;
    while (y < rows * GLYPH_HEIGHT) : (y += 1) {
        var x: usize = 0;
        while (x < pixel_width) : (x += 1) putPixel(x, y, colour);
    }
}

/// No hardware cursor exists in a linear framebuffer. Drawing one would mean
/// tracking and restoring what is underneath; the console works without it, and
/// the terminal will draw its own.
pub fn setCursor(_: usize, _: usize) void {}
