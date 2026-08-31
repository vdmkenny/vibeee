//! Drawing the grid.
//!
//! Only what changed. A terminal repaints constantly, and at 100 by 30 cells
//! a full redraw is 3000 glyphs; on a 630 MHz core that is the difference
//! between output that keeps up with a program and output that does not.
//! What was last drawn is kept here and compared against, which makes the
//! damage exact rather than approximate.

const eui = @import("eui");
const screen = @import("screen.zig");
const vt = @import("vt.zig");

const Cell = screen.Cell;
const Color = eui.draw.Color;
const Rect = eui.Rect;
const Surface = eui.Surface;

pub fn cellWidth() i32 {
    // The advance of a letter, not the font's bounding box: this face keeps
    // full-width East Asian glyphs in the same file, so the box is twice the
    // cell a Latin terminal wants.
    return @intCast(eui.draw.mono_font.advance('M'));
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

    // Line-drawing comes from the cell, not the font. The glyphs exist to
    // join exactly, and a face whose box set is full-width cannot join a
    // half-width grid; strokes from the cell's own geometry always meet.
    if (boxStrokes(cell.ch)) |strokes| {
        drawStrokes(surface, box, strokes, fg);
    } else if (arrowFor(cell.ch)) |which| {
        drawArrow(surface, box, which, fg);
    } else {
        surface.glyphIn(eui.draw.mono_font, box.x, box.y, @intCast(cell.ch), fg);
    }

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
    if (!cell.style.has_fg) return t.terminal_ink;
    // Dim is a palette choice rather than a blend: the sixteen colours already
    // come in a normal and a bright pair, and using the darker of the two is
    // what the pair is for.
    if (cell.style.dim and cell.fg < 8) return palette(cell.fg);
    if (cell.style.bold and cell.fg < 8) return palette(cell.fg + 8);
    return palette(cell.fg);
}

fn background(cell: Cell) Color {
    const t = eui.theme.current();
    return if (!cell.style.has_bg) t.terminal_ground else palette(cell.bg);
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

/// The first sixteen, as the drawings set them: soft, a little desaturated,
/// and light enough to sit on a warm near-black without glowing. The green
/// and the blue are the two the design names, and the rest are pitched to
/// keep them company rather than to match any one terminal.
const ANSI = [16]Color{
    rgb(0x14, 0x14, 0x0F), // black, the ground itself
    rgb(0xC8, 0x85, 0x85), // red
    rgb(0x8F, 0xBF, 0x8F), // green
    rgb(0xC8, 0xB8, 0x7F), // yellow
    rgb(0x7F, 0xA8, 0xD8), // blue
    rgb(0xBF, 0x8F, 0xBF), // magenta
    rgb(0x8F, 0xBF, 0xBF), // cyan
    rgb(0xD8, 0xD8, 0xD0), // white
    rgb(0x60, 0x60, 0x58), // bright black
    rgb(0xE0, 0xA0, 0xA0), // bright red
    rgb(0xAF, 0xD8, 0xAF), // bright green
    rgb(0xE0, 0xD0, 0x9F), // bright yellow
    rgb(0x9F, 0xC4, 0xEC), // bright blue
    rgb(0xD8, 0xAF, 0xD8), // bright magenta
    rgb(0xAF, 0xD8, 0xD8), // bright cyan
    rgb(0xF0, 0xF0, 0xE8), // bright white
};

fn rgb(r: u8, g: u8, b: u8) Color {
    return (@as(Color, r) << 16) | (@as(Color, g) << 8) | @as(Color, b);
}

/// Which arms a line-drawing character has, or null for one that is not.
///
/// The single-line set plus the doubles folded onto it: at one pixel a
/// double line is a smear, and a tree drawn with either reads the same.
pub const Strokes = packed struct(u4) {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
};

/// The four arrows, drawn rather than set.
///
/// A monospaced subset need not carry them, and a prompt's arrow that falls
/// back to a hyphen is a prompt that looks broken. Drawn from the cell, it is
/// there whatever the face has.
pub const Arrow = enum { left, right, up, down };

pub fn arrowFor(cp: u32) ?Arrow {
    return switch (cp) {
        0x2190 => .left,
        0x2191 => .up,
        0x2192 => .right,
        0x2193 => .down,
        else => null,
    };
}

fn drawArrow(surface: Surface, box: Rect, which: Arrow, color: Color) void {
    const mid_x = box.x + @divTrunc(box.w, 2);
    const mid_y = box.y + @divTrunc(box.h, 2);

    // The head is a fraction of the cell rather than a fixed three pixels: at
    // six pixels wide, three would reach halfway back along the shaft and
    // read as a cross.
    const head = @max(@min(@divTrunc(box.w, 3), @divTrunc(box.h, 3)), 1);

    switch (which) {
        .left, .right => {
            surface.fill(.{ .x = box.x + 1, .y = mid_y, .w = box.w - 2, .h = 1 }, color);
            var step: i32 = 1;
            while (step <= head) : (step += 1) {
                const x = if (which == .right) box.right() - 1 - step else box.x + step;
                surface.fill(.{ .x = x, .y = mid_y - step, .w = 1, .h = 1 }, color);
                surface.fill(.{ .x = x, .y = mid_y + step, .w = 1, .h = 1 }, color);
            }
        },
        .up, .down => {
            surface.fill(.{ .x = mid_x, .y = box.y + 1, .w = 1, .h = box.h - 2 }, color);
            var step: i32 = 1;
            while (step <= head) : (step += 1) {
                const y = if (which == .down) box.bottom() - 1 - step else box.y + step;
                surface.fill(.{ .x = mid_x - step, .y = y, .w = 1, .h = 1 }, color);
                surface.fill(.{ .x = mid_x + step, .y = y, .w = 1, .h = 1 }, color);
            }
        },
    }
}

pub fn boxStrokes(cp: u32) ?Strokes {
    return switch (cp) {
        0x2500, 0x2550 => .{ .left = true, .right = true },
        0x2502, 0x2551 => .{ .up = true, .down = true },
        0x250C, 0x2554 => .{ .right = true, .down = true },
        0x2510, 0x2557 => .{ .left = true, .down = true },
        0x2514, 0x255A => .{ .right = true, .up = true },
        0x2518, 0x255D => .{ .left = true, .up = true },
        0x251C, 0x2560 => .{ .right = true, .up = true, .down = true },
        0x2524, 0x2563 => .{ .left = true, .up = true, .down = true },
        0x252C, 0x2566 => .{ .left = true, .right = true, .down = true },
        0x2534, 0x2569 => .{ .left = true, .right = true, .up = true },
        0x253C, 0x256C => .{ .left = true, .right = true, .up = true, .down = true },
        else => null,
    };
}

/// Each arm runs from the cell's centre to its edge, so neighbouring cells'
/// arms meet without either knowing the other is there.
fn drawStrokes(surface: Surface, box: Rect, strokes: Strokes, color: Color) void {
    const mid_x = box.x + @divTrunc(box.w, 2);
    const mid_y = box.y + @divTrunc(box.h, 2);

    if (strokes.left) surface.fill(.{ .x = box.x, .y = mid_y, .w = mid_x - box.x + 1, .h = 1 }, color);
    if (strokes.right) surface.fill(.{ .x = mid_x, .y = mid_y, .w = box.right() - mid_x, .h = 1 }, color);
    if (strokes.up) surface.fill(.{ .x = mid_x, .y = box.y, .w = 1, .h = mid_y - box.y + 1 }, color);
    if (strokes.down) surface.fill(.{ .x = mid_x, .y = mid_y, .w = 1, .h = box.bottom() - mid_y }, color);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = @import("std").testing;

test "every line character continues through the joints" {
    // A tee is the tee of its three arms, which is what makes a tree's spine
    // read as one line: the vertical of |- must carry both up and down.
    const tee = boxStrokes(0x251C).?;
    try testing.expect(tee.up and tee.down and tee.right and !tee.left);

    const corner = boxStrokes(0x2514).?;
    try testing.expect(corner.up and corner.right and !corner.down and !corner.left);

    const cross = boxStrokes(0x253C).?;
    try testing.expect(cross.up and cross.down and cross.left and cross.right);
}

test "doubles fold onto singles and letters stay the font's" {
    try testing.expectEqual(boxStrokes(0x2500), boxStrokes(0x2550));
    try testing.expectEqual(boxStrokes(0x255A), boxStrokes(0x2514));
    try testing.expectEqual(@as(?Strokes, null), boxStrokes('A'));
    try testing.expectEqual(@as(?Strokes, null), boxStrokes(0x2192));
}

test "the arrows are drawn rather than looked up" {
    try testing.expectEqual(Arrow.right, arrowFor(0x2192).?);
    try testing.expectEqual(Arrow.left, arrowFor(0x2190).?);
    try testing.expectEqual(@as(?Arrow, null), arrowFor('>'));
    // A box character is the line set's, not the arrow set's.
    try testing.expectEqual(@as(?Arrow, null), arrowFor(0x2500));
}
