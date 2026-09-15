//! The pointer.
//!
//! Carried by the display where the adapter has a plane for it, and drawn by
//! the manager where it does not. Which one is decided once, when the screen
//! is taken, and every caller below says the same thing either way.
//!
//! **Carried.** The display engine composites the pointer as it reads the
//! screen out, so moving it is one call and nothing is drawn: no pixels read,
//! none written, and no pass over the screen. The picture goes to the plane
//! once, and again when the theme changes what colour it is.
//!
//! **Drawn.** What makes that bearable is putting back what it covered rather
//! than redrawing the screen: a mouse moved across the desktop generates a
//! motion event every few milliseconds, and repainting eight hundred by four
//! hundred and eighty pixels for each one is both far too slow and visible as
//! a flicker, because there is one buffer and the erase is on screen before
//! the redraw catches up. Saving what it covered means reading the
//! framebuffer, which is write-combining memory: quick to write and slow to
//! read. This is the only thing in the system that reads it, which is why a
//! plane is worth having.

const eui = @import("eui");
const bitmap = @import("lib").bitmap;
const rgb = @import("lib").rgb;
const sys = @import("sys");

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

/// Where the pointer comes from.
const Carrier = enum {
    /// The display's own plane. Nothing below this line draws anything.
    plane,
    /// The manager, into the framebuffer.
    hand,
};

var carrier: Carrier = .hand;

var backing: [SAVE_W * SAVE_H]eui.Color = @splat(.{});
var saved = false;
var at_x: i32 = 0;
var at_y: i32 = 0;

/// What the pointer is drawn in, and the outline that keeps it visible on a
/// background of its own colour.
var ink: eui.Color = eui.Color.hex(0xFFFFFF);
var edge: eui.Color = eui.Color.hex(0x000000);

/// Take the display's plane where it has one.
///
/// Called once, with what taking the screen said about it. A plane that
/// refuses the picture leaves the pointer drawn by hand, which is the same
/// place a machine without a plane starts.
pub fn adopt(info: sys.DisplayInfo) void {
    carrier = if (info.caps.hw_cursor) .plane else .hand;
    give();
}

/// Tell the plane what the pointer looks like, where the plane is carrying it.
///
/// Once, and again whenever the theme changes its colours. Refused, the
/// pointer goes back to being drawn: better one drawn by hand than none at
/// all.
fn give() void {
    if (carrier != .plane) return;

    var picture: [SAVE_W * SAVE_H]rgb.Blended = @splat(.clear);
    draw(struct {
        fn at(x: usize, y: usize, colour: eui.Color, into: []rgb.Blended) void {
            into[y * SAVE_W + x] = .solid(colour);
        }
    }.at, &picture);

    // The point is the pointer's tip, which is the corner it is drawn from.
    sys.Cursor.image(&picture, SAVE_W, 0, 0) catch {
        carrier = .hand;
    };
}

/// Walk the pointer's pixels, edge first so the fill draws over it.
///
/// One description of what a pointer looks like, whether it goes to a plane
/// or onto the screen: two passes of the same bitmap, the second a pixel up
/// and left of the first.
fn draw(comptime put: anytype, into: anytype) void {
    const passes = [_]struct { dx: usize, dy: usize, colour: eui.Color }{
        .{ .dx = 1, .dy = 1, .colour = edge },
        .{ .dx = 0, .dy = 0, .colour = ink },
    };
    for (passes) |pass| {
        for (bits, 0..) |row, y| {
            for (0..WIDTH) |x| {
                if (!bitmap.litIn(row, @intCast(x))) continue;
                put(x + pass.dx, y + pass.dy, pass.colour, into);
            }
        }
    }
}

/// Put back what the pointer covered.
///
/// Called before anything else draws, so what goes back is the screen as it
/// was and not a copy of the pointer. Nothing at all where the display
/// carries it: the engine composites it over whatever is drawn.
pub fn hide(screen: Surface) void {
    if (carrier == .plane or !saved) return;
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

pub fn setColour(fill: eui.Color, outline: eui.Color) void {
    ink = fill;
    edge = outline;
    give();
}

/// Put the pointer at `x`, `y`, remembering what was there where it is drawn.
pub fn show(screen: Surface, x: i32, y: i32) void {
    if (carrier == .plane) {
        // The whole cost of a movement: no pixels read, none written.
        sys.Cursor.move(x, y) catch {
            // Nothing carries it any more, so it goes back to being drawn.
            // One pass without a pointer, and then it is there again.
            carrier = .hand;
        };
        return;
    }

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

    draw(struct {
        fn at(dx: usize, dy: usize, colour: eui.Color, onto: Surface) void {
            onto.set(at_x + @as(i32, @intCast(dx)), at_y + @as(i32, @intCast(dy)), colour);
        }
    }.at, screen);
}

/// Whether `area` overlaps where the pointer is drawn, so a caller repainting
/// part of the screen knows whether it has to lift it first.
///
/// Never where the display carries it: there is nothing on the screen to
/// lift.
pub fn covers(area: eui.Rect) bool {
    if (carrier == .plane or !saved) return false;
    const box = eui.Rect{ .x = at_x, .y = at_y, .w = SAVE_W, .h = SAVE_H };
    return !area.intersect(box).isEmpty();
}
