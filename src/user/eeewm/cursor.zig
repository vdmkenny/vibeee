//! The pointer, drawn by the manager.
//!
//! This display advertises no cursor plane, so the pointer is pixels like
//! everything else. What makes that bearable is putting back what it covered
//! rather than redrawing the screen: a mouse moved across the desktop
//! generates a motion event every few milliseconds, and repainting eight
//! hundred by four hundred and eighty pixels for each one is both far too slow
//! and visible as a flicker, because there is one buffer and the erase is on
//! screen before the redraw catches up.

const eui = @import("eui");

const Surface = eui.Surface;

const WIDTH = 8;
const HEIGHT = 12;

/// One larger each way, because the shadow pass draws a pixel down and right.
const SAVE_W = WIDTH + 1;
const SAVE_H = HEIGHT + 1;

const bits = [HEIGHT]u8{
    0b10000000, 0b11000000, 0b11100000, 0b11110000,
    0b11111000, 0b11111100, 0b11111110, 0b11111000,
    0b11011000, 0b10001100, 0b00001100, 0b00000110,
};

var backing: [SAVE_W * SAVE_H]u32 = undefined;
var saved = false;
var at_x: i32 = 0;
var at_y: i32 = 0;

/// Put back what the cursor covered.
///
/// Called before anything else draws, so what goes back is the screen as it
/// was and not a copy of the cursor.
pub fn hide(screen: Surface) void {
    if (!saved) return;
    saved = false;

    for (0..SAVE_H) |row| {
        for (0..SAVE_W) |col| {
            screen.set(
                at_x + @as(i32, @intCast(col)),
                at_y + @as(i32, @intCast(row)),
                backing[row * SAVE_W + col],
            );
        }
    }
}

/// Forget what was saved, because the screen under it has been redrawn and
/// putting the old pixels back would paint a hole.
pub fn invalidate() void {
    saved = false;
}

/// Draw the cursor at `x`, `y`, remembering what was there.
///
/// Outlined by drawing it black one pixel down and right first, so it stays
/// visible over any colour beneath it.
pub fn show(screen: Surface, x: i32, y: i32) void {
    at_x = x;
    at_y = y;

    for (0..SAVE_H) |row| {
        for (0..SAVE_W) |col| {
            backing[row * SAVE_W + col] = screen.get(
                x + @as(i32, @intCast(col)),
                y + @as(i32, @intCast(row)),
            );
        }
    }
    saved = true;

    for ([_]struct { dx: i32, dy: i32, color: eui.Color }{
        .{ .dx = 1, .dy = 1, .color = 0x000000 },
        .{ .dx = 0, .dy = 0, .color = 0xFFFFFF },
    }) |pass| {
        for (bits, 0..) |row, iy| {
            var ix: i32 = 0;
            while (ix < WIDTH) : (ix += 1) {
                if (row >> @intCast(7 - @as(u3, @intCast(ix))) & 1 == 0) continue;
                screen.set(x + ix + pass.dx, y + @as(i32, @intCast(iy)) + pass.dy, pass.color);
            }
        }
    }
}

/// Whether `area` overlaps where the cursor is drawn, so a caller repainting
/// part of the screen knows whether it has to lift the cursor first.
pub fn covers(area: eui.Rect) bool {
    if (!saved) return false;
    const box = eui.Rect{ .x = at_x, .y = at_y, .w = SAVE_W, .h = SAVE_H };
    return !box.intersect(area).isEmpty();
}
