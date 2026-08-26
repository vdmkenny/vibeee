//! Drawing the grid.
//!
//! Only what changed. A terminal repaints constantly, and at 100 by 30 cells
//! a full redraw is 3000 glyphs; on a 630 MHz core that is the difference
//! between output that keeps up with a program and output that does not.
//! What was last drawn is kept here and compared against, which makes the
//! damage exact rather than approximate.

const std = @import("std");
const eui = @import("eui");
const screen = @import("screen.zig");
const vt = @import("vt.zig");

const Cell = screen.Cell;
const Color = eui.draw.Color;
const Rect = eui.Rect;
const Surface = eui.Surface;

pub fn cellWidth() i32 {
    return @intCast(eui.draw.mono_font.width);
}

pub fn cellHeight() i32 {
    return @intCast(eui.draw.mono_font.height);
}

/// The last thing drawn, per cell, so a repaint touches only what moved.
pub const Shadow = struct {
    /// Zeroed by `invalidate` rather than by an initialiser, for the same
    /// reason the grids are: a written-out initial value is carried in the
    /// executable.
    cells: [screen.MAX_ROWS * screen.MAX_COLS]Cell = undefined,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    cursor_shown: bool = false,

    pub fn invalidate(self: *Shadow) void {
        // A character no cell can hold, so every comparison fails and the next
        // pass draws everything.
        self.cells = @splat(.{ .ch = 0xFFFF_FFFF });
    }
};

/// Draw the terminal into `area`, and return what changed.
///
/// The damage is one rectangle covering every altered row rather than a list:
/// a terminal's changes are usually a run of consecutive lines, and a list of
/// per-cell rectangles would cost more to send than the pixels it saved.
pub fn paint(
    surface: Surface,
    area: Rect,
    term: *vt.Terminal,
    shadow: *Shadow,
) ?Rect {
    const g = term.active();
    const cw = cellWidth();
    const ch = cellHeight();

    var top: ?i32 = null;
    var bottom: i32 = 0;

    const cursor_visible = !term.hidden;
    const cursor_moved = shadow.cursor_row != term.cursor.row or
        shadow.cursor_col != term.cursor.col or
        shadow.cursor_shown != cursor_visible;

    for (0..g.rows) |r| {
        var changed = false;

        for (0..g.cols) |c| {
            const cell = g.at(r, c).*;
            const was = &shadow.cells[r * screen.MAX_COLS + c];

            // The cursor cell is drawn inverted, so it has to be repainted
            // whenever the cursor arrives or leaves even if the cell itself is
            // unchanged.
            const under_cursor = cursor_visible and r == term.cursor.row and c == term.cursor.col;
            const was_cursor = shadow.cursor_shown and
                r == shadow.cursor_row and c == shadow.cursor_col;

            if (cell.eql(was.*) and under_cursor == was_cursor and !(cursor_moved and (under_cursor or was_cursor))) {
                continue;
            }

            drawCell(surface, area, cw, ch, @intCast(r), @intCast(c), cell, under_cursor);
            was.* = cell;
            changed = true;
        }

        if (changed) {
            const y = area.y + @as(i32, @intCast(r)) * ch;
            if (top == null) top = y;
            bottom = y + ch;
        }
    }

    shadow.cursor_row = term.cursor.row;
    shadow.cursor_col = term.cursor.col;
    shadow.cursor_shown = cursor_visible;

    const first = top orelse return null;
    return .{ .x = area.x, .y = first, .w = @as(i32, @intCast(g.cols)) * cw, .h = bottom - first };
}

fn drawCell(
    surface: Surface,
    area: Rect,
    cw: i32,
    ch: i32,
    row: i32,
    col: i32,
    cell: Cell,
    under_cursor: bool,
) void {
    var fg = foreground(cell);
    var bg = background(cell);

    // Inverse and the cursor both swap, so a cursor on inverse text stays
    // readable rather than vanishing.
    if (cell.style.inverse != under_cursor) {
        const swap = fg;
        fg = bg;
        bg = swap;
    }

    const box = Rect{ .x = area.x + col * cw, .y = area.y + row * ch, .w = cw, .h = ch };
    surface.fill(box, bg);

    if (cell.style.hidden or cell.ch == ' ' or cell.ch == 0) {
        if (cell.style.underline) underline(surface, box, fg);
        return;
    }

    surface.glyphIn(eui.draw.mono_font, box.x, box.y, @intCast(cell.ch), fg);

    // Bold is drawn a second time one pixel right, which is what a bitmap face
    // with no bold cut can do. At eight pixels wide it reads as weight rather
    // than as a smear.
    if (cell.style.bold) {
        surface.clipped(box).glyphIn(eui.draw.mono_font, box.x + 1, box.y, @intCast(cell.ch), fg);
    }

    if (cell.style.underline) underline(surface, box, fg);
    if (cell.style.strike) {
        surface.fill(.{ .x = box.x, .y = box.y + @divTrunc(ch, 2), .w = cw, .h = 1 }, fg);
    }
}

fn underline(surface: Surface, box: Rect, color: Color) void {
    surface.fill(.{ .x = box.x, .y = box.bottom() - 1, .w = box.w, .h = 1 }, color);
}

fn foreground(cell: Cell) Color {
    const t = eui.theme.current();
    if (!cell.style.has_fg) return t.text;
    // Dim is a palette choice rather than a blend: the sixteen colours already
    // come in a normal and a bright pair, and using the darker of the two is
    // what the pair is for.
    if (cell.style.dim and cell.fg < 8) return palette(cell.fg);
    if (cell.style.bold and cell.fg < 8) return palette(cell.fg + 8);
    return palette(cell.fg);
}

fn background(cell: Cell) Color {
    const t = eui.theme.current();
    return if (!cell.style.has_bg) t.surface else palette(cell.bg);
}

/// The 256-colour palette, computed rather than tabulated.
///
/// A table would be a kilobyte of read-only data for something two lines of
/// arithmetic produce, and the cube and grey ramp are defined by arithmetic in
/// the first place.
pub fn palette(index: u8) Color {
    if (index < 16) return ANSI[index];

    if (index < 232) {
        const n = index - 16;
        return rgb(LEVELS[n / 36], LEVELS[(n / 6) % 6], LEVELS[n % 6]);
    }

    const grey: u8 = @intCast(8 + @as(u16, index - 232) * 10);
    return rgb(grey, grey, grey);
}

/// The six values the colour cube steps through. Not evenly spaced: the first
/// step is larger, which is what every terminal since xterm uses and what
/// makes dark colours in the cube distinguishable.
const LEVELS = [6]u8{ 0, 95, 135, 175, 215, 255 };

/// The first sixteen. Chosen to sit alongside the interface rather than to
/// match any one terminal: the same hues, a little less saturated, which is
/// what reads on a panel this small without glowing.
const ANSI = [16]Color{
    rgb(0x1C, 0x1F, 0x26), // black
    rgb(0xC0, 0x40, 0x40), // red
    rgb(0x50, 0xA0, 0x50), // green
    rgb(0xB0, 0x90, 0x30), // yellow
    rgb(0x40, 0x70, 0xC0), // blue
    rgb(0xA0, 0x50, 0xB0), // magenta
    rgb(0x40, 0xA0, 0xA0), // cyan
    rgb(0xC8, 0xC8, 0xC8), // white
    rgb(0x50, 0x58, 0x64), // bright black
    rgb(0xE0, 0x60, 0x60), // bright red
    rgb(0x70, 0xC8, 0x70), // bright green
    rgb(0xE0, 0xC0, 0x50), // bright yellow
    rgb(0x60, 0x98, 0xE0), // bright blue
    rgb(0xC8, 0x70, 0xD8), // bright magenta
    rgb(0x60, 0xC8, 0xC8), // bright cyan
    rgb(0xF0, 0xF0, 0xF0), // bright white
};

fn rgb(r: u8, g: u8, b: u8) Color {
    return (@as(Color, r) << 16) | (@as(Color, g) << 8) | @as(Color, b);
}
