//! Framebuffer text console.
//!
//! Presents the same cell interface as the VGA text backend, so the console
//! layer above is unchanged, only the destination of a character differs.
//!
//! Glyphs come from a bitmap font compiled into the kernel (Spleen by default),
//! with the video ROM's own font as a fallback when none is built in. A
//! purpose-designed console font is markedly more legible than the VGA ROM's,
//! which matters on a 7-inch panel at 133 DPI where every glyph is about three
//! millimetres tall.
//!
//! Bitmaps rather than a scalable face: at sixteen pixels a hand-tuned bitmap
//! beats anything a rasteriser produces, and there is no hinting to get wrong.
//!
//! Colour is the sixteen-entry VGA palette rather than anything richer,
//! because everything that draws here, the boot log, the panic screen, was
//! written against those sixteen and gains nothing from more.

const bootinfo = @import("../../kernel/bootinfo.zig");
const fontlib = @import("lib").font;
const hal = @import("../../kernel/hal.zig");

/// Available fonts, largest last. Selected at boot from the screen size.
const FONTS = [_]fontlib.Font{
    fontlib.spleen_8x16,
    fontlib.spleen_12x24,
};

/// The standard VGA palette, as XRGB8888.
const PALETTE = [16]u32{
    0x000000, 0x0000AA, 0x00AA00, 0x00AAAA,
    0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
    0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
    0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
};

var fb: [*]volatile u8 = undefined;
var font: *const fontlib.Font = &FONTS[0];
/// The video ROM's font, used only if no font was compiled in.
var rom_font: ?[*]const u8 = null;
var pitch: usize = 0;
var pixel_width: usize = 0;
var pixel_height: usize = 0;
var bytes_per_pixel: usize = 4;

var columns: usize = 0;
var rows: usize = 0;
var ready = false;
/// Set while a userspace compositor owns the framebuffer. Drawing is skipped
/// rather than the backend being torn down, so the console can be handed back
/// without re-detecting the hardware.
var suspended = false;

pub fn setSuspended(value: bool) void {
    suspended = value;
}

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
        hal.mapMmio(bi.fb_addr, @as(usize, bi.fb_pitch) * bi.fb_height, .cached) catch return false;

    fb = @ptrFromInt(fb_virt);
    rom_font = if (bi.font_addr != 0)
        @as([*]const u8, @ptrFromInt(hal.physToVirt(bi.font_addr)))
    else
        null;

    pitch = bi.fb_pitch;
    pixel_width = bi.fb_width;
    pixel_height = bi.fb_height;
    bytes_per_pixel = 4;

    // Pick the largest font that still leaves a usable console. Below roughly
    // 60 columns, wrapping makes the boot log and the panic screen unreadable,
    // so legibility gives way to fitting the text.
    font = &FONTS[0];
    for (&FONTS) |*candidate| {
        if (pixel_width / candidate.width >= 60 and pixel_height / candidate.height >= 20) {
            font = candidate;
        }
    }

    columns = pixel_width / font.width;
    rows = pixel_height / font.height;
    ready = true;

    clearAll(PALETTE[0]);
    return true;
}

pub fn active() bool {
    return ready and !suspended;
}

pub const Grid = struct { columns: usize, rows: usize };

pub fn dimensions() Grid {
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
pub fn putAt(col: usize, row: usize, cp: u21, fg: u4, bg: u4) void {
    if (!ready or suspended or col >= columns or row >= rows) return;

    const bits = font.glyph(cp) orelse font.fallback();
    const fg_colour = PALETTE[fg];
    const bg_colour = PALETTE[bg];

    const x0 = col * font.width;
    const y0 = row * font.height;

    var gy: usize = 0;
    while (gy < font.height) : (gy += 1) {
        const row_start = gy * font.row_bytes;
        var gx: usize = 0;
        while (gx < font.width) : (gx += 1) {
            // Rows are big-endian across bytes: bit 7 of the first byte is the
            // leftmost pixel, so a 12-pixel glyph continues into the next byte.
            const byte = bits[row_start + gx / 8];
            const lit = (byte >> @intCast(7 - (gx % 8))) & 1 != 0;
            putPixel(x0 + gx, y0 + gy, if (lit) fg_colour else bg_colour);
        }
    }
}

/// Fill a rectangle in pixels, ignoring the character grid.
///
/// Exists so the panic screen can draw a QR code without depending on a glyph.
/// Rendering modules as half-block characters works only while the font happens
/// to carry them: a font without them substitutes a notdef box and produces a
/// symbol that looks plausible and does not scan, the worst possible failure
/// for a diagnostic whose only job is to be read off a photograph.
pub fn fillRect(x: usize, y: usize, w: usize, h: usize, colour_index: u4) void {
    if (!ready or suspended) return;
    const colour = PALETTE[colour_index];

    const x_end = @min(x + w, pixel_width);
    const y_end = @min(y + h, pixel_height);

    var py = y;
    while (py < y_end) : (py += 1) {
        var px = x;
        while (px < x_end) : (px += 1) putPixel(px, py, colour);
    }
}

pub const Size = struct { width: usize, height: usize };

pub fn pixelSize() Size {
    return .{ .width = pixel_width, .height = pixel_height };
}

pub fn cellSize() Size {
    return .{ .width = font.width, .height = font.height };
}

pub fn fontName() []const u8 {
    return font.name;
}

pub fn fill(ch: u21, fg: u4, bg: u4) void {
    if (!ready or suspended) return;
    // A blank cell is a solid rectangle, so the common case avoids the glyph
    // walk entirely, this runs on every clear and every panic.
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
    if (!ready or suspended) return;

    const row_bytes = pitch * font.height;
    const moved = (rows - 1) * row_bytes;

    var i: usize = 0;
    while (i < moved) : (i += 1) fb[i] = fb[i + row_bytes];

    const colour = PALETTE[bg];
    var y = (rows - 1) * font.height;
    while (y < rows * font.height) : (y += 1) {
        var x: usize = 0;
        while (x < pixel_width) : (x += 1) putPixel(x, y, colour);
    }
}

/// No hardware cursor exists in a linear framebuffer. Drawing one would mean
/// tracking and restoring what is underneath; the console works without it, and
/// the terminal will draw its own.
pub fn setCursor(_: usize, _: usize) void {}
