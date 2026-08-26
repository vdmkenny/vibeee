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
/// One character cell as it currently appears on screen.
///
/// Kept so scrolling never reads the framebuffer back. The graphics aperture is
/// uncached on real hardware, where a read is a full bus round trip and a write
/// can be posted, so moving text by copying pixels costs far more than
/// redrawing the characters that changed.
const Cell = packed struct(u32) {
    cp: u21,
    fg: u4,
    bg: u4,
    _reserved: u3 = 0,

    /// A space draws the same whatever its foreground, so the colour is
    /// normalised away and blank-over-blank compares equal and repaints
    /// nothing. Most of a text console is blank.
    fn of(cp: u21, fg: u4, bg: u4) Cell {
        return .{ .cp = cp, .fg = if (cp == ' ') 0 else fg, .bg = bg };
    }

    fn same(self: Cell, other: Cell) bool {
        return @as(u32, @bitCast(self)) == @as(u32, @bitCast(other));
    }
};

/// Bounds the grid. A panel larger than this still displays; the console uses
/// as much of it as fits.
const MAX_COLUMNS = 128;
const MAX_ROWS = 48;

var cells: [MAX_COLUMNS * MAX_ROWS]Cell = @splat(Cell{ .cp = ' ', .fg = 0, .bg = 0 });

/// Whether the grid still describes the screen. `fillRect` paints pixels the
/// grid cannot represent, so after it the next scroll repaints every cell
/// rather than trusting a comparison.
var trust_grid = true;

var phys: usize = 0;
var pitch: usize = 0;
var pixel_width: usize = 0;
var pixel_height: usize = 0;

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

    phys = bi.fb_addr;
    pitch = bi.fb_pitch;
    pixel_width = bi.fb_width;
    pixel_height = bi.fb_height;

    // Pick the largest font that still leaves a usable console. Below roughly
    // 60 columns, wrapping makes the boot log and the panic screen unreadable,
    // so legibility gives way to fitting the text.
    font = &FONTS[0];
    for (&FONTS) |*candidate| {
        if (pixel_width / candidate.width >= 60 and pixel_height / candidate.height >= 20) {
            font = candidate;
        }
    }

    columns = @min(pixel_width / font.width, MAX_COLUMNS);
    rows = @min(pixel_height / font.height, MAX_ROWS);
    ready = true;

    setAll(Cell.of(' ', 0, 0));

    clearAll(PALETTE[0]);
    return true;
}

pub fn active() bool {
    return ready and !suspended;
}

pub const Grid = struct { columns: usize, rows: usize };

/// Where the framebuffer is and how far apart its scanlines are.
///
/// A pitch wider than the visible width is normal, and everything drawing to
/// the framebuffer has to honour it, so it belongs on the porting worksheet
/// next to the geometry.
pub const Layout = struct { addr: usize, pitch: usize };

pub fn layout() Layout {
    return .{ .addr = phys, .pitch = pitch };
}

pub fn dimensions() Grid {
    return .{ .columns = columns, .rows = rows };
}

/// One scanline as 32-bit pixels.
///
/// Every mode this driver accepts is 32 bits per pixel with a pitch that is a
/// whole number of them, so the cast always lands aligned. Addressing the
/// framebuffer a word at a time rather than a byte at a time is what makes it
/// usable on real hardware: the graphics aperture is uncached, so each access
/// is a bus transaction rather than a cache hit, and a byte-wise pixel costs
/// four of them.
inline fn lineAt(y: usize) [*]volatile u32 {
    return @ptrCast(@alignCast(fb + y * pitch));
}

fn putPixel(x: usize, y: usize, colour: u32) void {
    lineAt(y)[x] = colour & 0x00FF_FFFF;
}

fn clearAll(colour: u32) void {
    var y: usize = 0;
    while (y < pixel_height) : (y += 1) {
        const line = lineAt(y);
        var x: usize = 0;
        while (x < pixel_width) : (x += 1) line[x] = colour;
    }
}

/// Draw one character cell.
pub fn putAt(col: usize, row: usize, cp: u21, fg: u4, bg: u4) void {
    if (!ready or suspended or col >= columns or row >= rows) return;

    const cell = Cell.of(cp, fg, bg);
    cells[row * columns + col] = cell;
    drawCell(col, row, cell);
}

/// Paint a cell, without touching the grid. The caller has already recorded it.
fn drawCell(col: usize, row: usize, cell: Cell) void {
    const bits = font.glyph(cell.cp) orelse font.fallback();
    const fg_colour = PALETTE[cell.fg];
    const bg_colour = PALETTE[cell.bg];

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
    // Pixels the grid has no way to describe, so it no longer speaks for the
    // screen and the next scroll repaints unconditionally.
    trust_grid = false;
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

    const cell = Cell.of(ch, fg, bg);
    setAll(cell);

    // A blank cell is a solid rectangle, so the common case avoids the glyph
    // walk entirely, this runs on every clear and every panic.
    if (ch == ' ') {
        clearAll(PALETTE[bg]);
        return;
    }
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var col: usize = 0;
        while (col < columns) : (col += 1) drawCell(col, row, cell);
    }
}

/// Record `cell` in every position, and trust the grid again.
fn setAll(cell: Cell) void {
    @memset(cells[0 .. columns * rows], cell);
    trust_grid = true;
}

/// Scroll up one text row.
///
/// Rasterising the characters that moved, rather than copying the pixels above
/// them. Copying costs a framebuffer read per pixel, and on hardware where the
/// aperture is uncached those reads dominate everything else the console does.
pub fn scroll(bg: u4) void {
    if (!ready or suspended) return;

    // The text moves in RAM and only the cells whose contents actually changed
    // are repainted, so the framebuffer is written and never read. A boot log
    // leaves most of each line blank, and blank over blank repaints nothing.
    var row: usize = 0;
    while (row + 1 < rows) : (row += 1) {
        var col: usize = 0;
        while (col < columns) : (col += 1) {
            const incoming = cells[(row + 1) * columns + col];
            const at = &cells[row * columns + col];
            if (trust_grid and incoming.same(at.*)) continue;
            at.* = incoming;
            drawCell(col, row, incoming);
        }
    }

    const blank = Cell.of(' ', 0, bg);
    var col: usize = 0;
    while (col < columns) : (col += 1) {
        const at = &cells[(rows - 1) * columns + col];
        if (trust_grid and blank.same(at.*)) continue;
        at.* = blank;
        drawCell(col, rows - 1, blank);
    }
    trust_grid = true;
}

/// No hardware cursor exists in a linear framebuffer. Drawing one would mean
/// tracking and restoring what is underneath; the console works without it, and
/// the terminal will draw its own.
pub fn setCursor(_: usize, _: usize) void {}
