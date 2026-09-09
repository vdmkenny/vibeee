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
const std = @import("std");
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

/// What the screen is showing, cell for cell.
///
/// The pair of these is the whole design: `cells` is what the console has
/// written, `shown` is what the framebuffer currently shows, and painting
/// is the act of bringing the second up to date with the first. Drawing is
/// therefore a difference, and a difference is only ever taken once per
/// `present`, however much was written in between.
///
/// The alternative -- drawing each cell as it is written -- costs a full
/// screen of glyph rasterising *per scrolled line*, because a scroll changes
/// every row. A program pouring a page of text then spends seconds moving
/// pixels and the machine looks dead while it does.
var shown: [MAX_COLUMNS * MAX_ROWS]Cell = @splat(Cell{ .cp = ' ', .fg = 0, .bg = 0 });

/// Whether `shown` can be trusted to name what is on the screen.
///
/// `fillRect` paints pixels the grid has no way to describe, so after it the
/// screen is unknown and the next present repaints every cell it is asked
/// about rather than comparing.
var shown_known = true;

/// Which columns of a row may differ from `painted`, as an inclusive range.
///
/// Rows rather than cells because a console writes in runs: a line of text
/// is one row, a scroll is every row. Two bytes a row is the whole
/// bookkeeping, which is what a machine with 512 MiB can spare.
const Dirty = struct {
    lo: u8 = 0,
    hi: u8 = 0,
    set: bool = false,

    fn one(self: *Dirty, col: usize) void {
        self.span(col, col);
    }

    fn span(self: *Dirty, lo: usize, hi: usize) void {
        if (!self.set) {
            self.lo = @as(u8, @truncate(lo));
            self.hi = @as(u8, @truncate(hi));
            self.set = true;
            return;
        }
        self.lo = @min(self.lo, @as(u8, @truncate(lo)));
        self.hi = @max(self.hi, @as(u8, @truncate(hi)));
    }

    /// The whole row: what a scroll or a fill leaves behind.
    fn whole(self: *Dirty) void {
        self.lo = 0;
        self.hi = std.math.maxInt(u8);
        self.set = true;
    }

    fn forget(self: *Dirty) void {
        self.set = false;
    }
};

var dirty: [MAX_ROWS]Dirty = @splat(.{});

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

    const fb_virt = mapped(bi.fb_addr, @as(usize, bi.fb_pitch) * bi.fb_height) orelse return false;

    fb = @ptrFromInt(fb_virt);
    rom_font = if (bi.font_addr != 0)
        @as([*]const u8, @ptrFromInt(hal.physToVirt(bi.font_addr)))
    else
        null;

    phys = bi.fb_addr;
    pitch = bi.fb_pitch;
    pixel_width = bi.fb_width;
    pixel_height = bi.fb_height;

    // The same choice a modeset makes later, from the same rule: this once
    // had a rule of its own that allowed twenty rows, so a panel picked the
    // large face at boot and the small one the moment anything set a mode.
    fitConsole();
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

/// The shape the boot log and the panic screen are written for.
///
/// Eighty columns because that is what everything printed here is composed
/// against, and thirty rows because a panic that scrolls its own cause off
/// the top is a panic nobody can act on. A font that leaves less than this
/// costs more legibility in wrapping than its larger glyphs gain, so a
/// netbook panel keeps the small face and the large one waits for a screen
/// with the room.
const MIN_COLUMNS = 80;
const MIN_ROWS = 30;

/// Choose a font for the current geometry and derive the character grid.
///
/// The largest font that still leaves a console of that shape, falling back to
/// the smallest when a panel cannot manage even that.
fn fitConsole() void {
    font = &FONTS[0];
    for (&FONTS) |*candidate| {
        if (pixel_width / candidate.width >= MIN_COLUMNS and
            pixel_height / candidate.height >= MIN_ROWS)
        {
            font = candidate;
        }
    }

    columns = @min(pixel_width / font.width, MAX_COLUMNS);
    rows = @min(pixel_height / font.height, MAX_ROWS);
}

/// The aperture this console has mapped, kept so a mode change within it
/// costs no new mapping. A framebuffer normally sits at a physical address
/// well above RAM, so it has no linear-map address and must be mapped
/// explicitly, and the kernel's window for such mappings is never given
/// back: every modeset that mapped afresh would spend four megabytes of it.
const Aperture = struct {
    phys: usize,
    len: usize,
    virt: usize,

    fn covers(self: Aperture, base: usize, len: usize) bool {
        return base >= self.phys and len <= self.len and base - self.phys <= self.len - len;
    }

    fn at(self: Aperture, base: usize) usize {
        return self.virt + (base - self.phys);
    }
};

var aperture: ?Aperture = null;

/// Where `len` bytes of framebuffer at `phys` can be written: through the
/// linear map when it is RAM, through the aperture already mapped when it
/// lies within it, and through a fresh mapping otherwise.
fn mapped(base: usize, len: usize) ?usize {
    if (hal.isLinearPhys(base)) return hal.physToVirt(base);
    if (aperture) |have| {
        if (have.covers(base, len)) return have.at(base);
    }
    const virt = hal.mapMmio(base, len, .cached) catch return null;
    aperture = .{ .phys = base, .len = len, .virt = virt };
    return virt;
}

/// Point the console at a framebuffer of a different shape.
///
/// For after a modeset: the pixels sit in the same aperture, but the geometry
/// changed underneath, and everything from the font down to the cell grid is
/// derived from it.
pub fn adopt(new_phys: usize, new_pitch: usize, width: usize, height: usize) bool {
    if (!ready) return false;

    const virt = mapped(new_phys, new_pitch * height) orelse return false;

    fb = @ptrFromInt(virt);
    phys = new_phys;
    pitch = new_pitch;
    pixel_width = width;
    pixel_height = height;

    const was_columns = columns;
    const was_rows = rows;
    fitConsole();

    // The screen is this machine's diagnostic, so a mode change carries what
    // was on it across rather than starting blank: the grid already holds every
    // cell, it only has to be laid out for the new width and drawn again.
    clearAll(PALETTE[0]);
    reflow(was_columns, was_rows);
    return true;
}

/// Re-lay the grid for a new geometry and draw all of it.
///
/// The rows move because the stride changed, and source and destination are the
/// same array, so the order matters: a wider console pushes every row further
/// along and has to be walked from the end, a narrower one pulls them back and
/// has to be walked from the start. Each row goes through a line buffer, which
/// makes the overlap within a row a non-question.
fn reflow(was_columns: usize, was_rows: usize) void {
    const kept_rows = @min(was_rows, rows);
    const kept_columns = @min(was_columns, columns);
    const blank = Cell.of(' ', 0, 0);

    var line: [MAX_COLUMNS]Cell = undefined;
    var moved: usize = 0;
    while (moved < kept_rows) : (moved += 1) {
        const y = if (columns > was_columns) kept_rows - 1 - moved else moved;
        @memcpy(line[0..kept_columns], cells[y * was_columns ..][0..kept_columns]);
        @memset(cells[y * columns ..][0..columns], blank);
        @memcpy(cells[y * columns ..][0..kept_columns], line[0..kept_columns]);
    }

    // Rows the new geometry added start blank.
    var below = kept_rows;
    while (below < rows) : (below += 1) {
        @memset(cells[below * columns ..][0..columns], blank);
    }

    // The stride changed, so every row moved: the whole screen is suspect.
    shown_known = false;
    markWhole();
    present();
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
/// What is in a cell. For saving the screen before a full-screen program
/// draws over it, which is the only thing that reads the grid back out.
pub fn cellAt(col: usize, row: usize) struct { cp: u21, fg: u4, bg: u4 } {
    if (col >= columns or row >= rows) return .{ .cp = ' ', .fg = 0, .bg = 0 };

    const cell = cells[row * columns + col];
    return .{ .cp = cell.cp, .fg = cell.fg, .bg = cell.bg };
}

pub fn putAt(col: usize, row: usize, cp: u21, fg: u4, bg: u4) void {
    if (!ready or suspended or col >= columns or row >= rows) return;

    const cell = Cell.of(cp, fg, bg);
    cells[row * columns + col] = cell;
    dirty[row].one(col);
    if (col == Cursor.col and row == Cursor.row) Cursor.painted = false;
}

/// Bring the screen up to date with the grid, once.
///
/// Everything that changes what the console shows ends here, and nothing else
/// paints: writing a character records it, scrolling moves the record, and
/// this is the one pass that rasterises what actually differs. Called at the
/// end of a write rather than during it, so a write of four thousand lines
/// costs one screen of drawing rather than four thousand.
pub fn present() void {
    if (!ready or suspended) return;
    Cursor.lift();

    var row: usize = 0;
    while (row < rows) : (row += 1) {
        const span = &dirty[row];
        if (!span.set) continue;
        span.forget();

        const last = @min(@as(usize, span.hi), columns - 1);
        var col: usize = span.lo;
        while (col <= last) : (col += 1) {
            const at = row * columns + col;
            const cell = cells[at];
            // Blank over blank is the common case and the cheap one: a mostly
            // empty screen repaints a handful of glyphs and nothing else.
            // Untaken while the screen is unknown, because the framebuffer
            // then holds pixels this grid cannot name.
            if (shown_known and shown[at].same(cell)) continue;
            shown[at] = cell;
            drawCell(col, row, cell);
        }
    }

    shown_known = true;
    Cursor.paint();
}

/// Every cell of every row may differ: what a scroll, a fill or a new
/// geometry leaves behind.
fn markWhole() void {
    for (&dirty) |*span| span.whole();
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
    Cursor.lift();
    if (!ready or suspended) return;
    // Pixels the grid has no way to describe, so it no longer speaks for the
    // screen and the next present repaints what it is asked about rather
    // than comparing.
    shown_known = false;
    markWhole();
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
    Cursor.lift();

    const cell = Cell.of(ch, fg, bg);
    setAll(cell);

    // A blank cell is a solid rectangle, so the common case avoids the glyph
    // walk entirely, this runs on every clear and every panic.
    if (ch == ' ') {
        clearAll(PALETTE[bg]);
        @memset(shown[0 .. columns * rows], Cell.of(' ', 0, bg));
        shown_known = true;
        for (&dirty) |*span| span.forget();
        return;
    }
    present();
}

/// Record `cell` in every position, and say the whole screen may differ.
fn setAll(cell: Cell) void {
    @memset(cells[0 .. columns * rows], cell);
    markWhole();
}

/// Scroll up one text row.
///
/// Rasterising the characters that moved, rather than copying the pixels above
/// them. Copying costs a framebuffer read per pixel, and on hardware where the
/// aperture is uncached those reads dominate everything else the console does.
pub fn scroll(bg: u4) void {
    shift(bg, 1);
}

/// Move the text up `count` rows.
///
/// The framebuffer is written and never read: on hardware where the aperture
/// is uncached a read is a full bus round trip, so moving text by copying
/// pixels costs more than rasterising what changed. The record moves in RAM
/// in one pass however many rows it moves, and the drawing happens once, in
/// `present`, however much a single write scrolled.
pub fn shift(bg: u4, count: usize) void {
    if (!ready or suspended or count == 0) return;
    Cursor.lift();

    if (count >= rows) {
        setAll(Cell.of(' ', 0, bg));
        return;
    }

    const width = columns;
    var row: usize = 0;
    while (row + count < rows) : (row += 1) {
        @memcpy(cells[row * width ..][0..width], cells[(row + count) * width ..][0..width]);
    }
    const blank = Cell.of(' ', 0, bg);
    while (row < rows) : (row += 1) {
        @memset(cells[row * width ..][0..width], blank);
    }

    markWhole();
}

/// No hardware cursor exists in a linear framebuffer. Drawing one would mean
/// tracking and restoring what is underneath; the console works without it, and
/// the terminal will draw its own.
/// Where the cursor is, and whether it is on the screen right now.
///
/// Text mode has a cursor in hardware; a framebuffer has whatever is drawn, so
/// this draws one. A block with the cell's colours swapped, rather than an
/// underline: at sixteen pixels an underline is a row or two of dim pixels
/// against a dark panel, and on this machine that is a cursor nobody can find.
const Cursor = struct {
    var col: usize = 0;
    var row: usize = 0;
    /// Whether a program wants it seen. A full-screen program turns it off
    /// while it redraws, so it is not watched skating across a half-drawn
    /// screen on its way to where it belongs.
    var wanted = true;
    /// Whether it is currently painted, so it is not erased twice or left
    /// behind by something that repainted the whole screen underneath it.
    var painted = false;

    /// The colours the console is writing in, which is what the block is drawn
    /// with rather than the cell's own.
    ///
    /// A blank cell has no foreground: the grid normalises it away, because a
    /// space draws the same whatever colour it is not drawn in. Swapping such
    /// a cell's own colours therefore gives black on black, and a cursor at
    /// the end of a line is exactly where it always sits.
    var fg: u4 = 7;
    var bg: u4 = 0;

    fn paint() void {
        if (!wanted or painted) return;
        if (col >= columns or row >= rows) return;

        drawCell(col, row, .{ .cp = cells[row * columns + col].cp, .fg = bg, .bg = fg });
        painted = true;
    }

    fn erase() void {
        if (!painted) return;
        painted = false;
        if (col >= columns or row >= rows) return;

        drawCell(col, row, cells[row * columns + col]);
    }

    /// Take the cursor off the screen before something moves the screen out
    /// from under it.
    ///
    /// Erasing rather than forgetting, because `scroll` repaints only the
    /// cells whose contents changed and the cursor is in none of them: it is
    /// drawn straight to the framebuffer and lives nowhere in the grid, so a
    /// cell that scrolled to identical content is stepped over and keeps the
    /// block that was drawn on top of it. That is how a command leaves a
    /// stray cursor behind on every line it scrolled.
    fn lift() void {
        erase();
    }
};

pub fn setCursor(to_col: usize, to_row: usize, fg: u4, bg: u4) void {
    Cursor.erase();
    Cursor.col = to_col;
    Cursor.row = to_row;
    Cursor.fg = fg;
    Cursor.bg = bg;
    Cursor.paint();
}

pub fn showCursor(visible: bool) void {
    if (visible) {
        Cursor.wanted = true;
        Cursor.paint();
    } else {
        Cursor.erase();
        Cursor.wanted = false;
    }
}
