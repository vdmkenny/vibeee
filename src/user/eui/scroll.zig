//! Scrollbars.
//!
//! A control in its own right rather than something each scrolling view draws
//! for itself: a table and a text area scroll identically, and two
//! implementations would disagree about where the thumb sits long before
//! either of them was wrong on its own.
//!
//! Draggable, because a scrollbar that only showed a position would be a
//! progress bar. Clicking the track pages, which is the gesture people who do
//! not drag use instead.

const std = @import("std");
const draw = @import("draw.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;

/// Wide enough to hit with a touchpad on a panel this size, narrow enough that
/// it costs a table one column.
pub const WIDTH: i32 = 9;

/// The shortest the thumb is allowed to get. A document long enough to make it
/// a single pixel is a document whose scrollbar cannot be grabbed.
const MIN_THUMB: i32 = 12;

pub const State = struct {
    /// How far down the thumb the pointer went, so a drag moves the thumb with
    /// the pointer rather than snapping its top to it.
    grab: ?Grab = null,
};

/// A thumb being dragged: where the pointer was when it was taken, and
/// where the view stood then.
///
/// Both, rather than where in the thumb the pointer took hold: the thumb's
/// position on screen is a rounded-down division, and mapping that pixel
/// back multiplies its rounding by the whole length of the document. A
/// grab that had not moved the pointer stepped the view backwards.
const Grab = struct {
    at_y: i32,
    from: usize,
};

/// Draw a vertical scrollbar and run it. Returns where the view should be
/// scrolled to, in the same units the caller counts in.
///
/// `total` is how many of those units there are and `visible` how many fit.
/// When everything fits, nothing is drawn and `scroll` comes back unchanged:
/// a scrollbar for a view that cannot scroll is a control that does nothing
/// and takes up room saying so.
pub fn vertical(
    ctx: *widget.Context,
    area: Rect,
    state: *State,
    scroll: usize,
    total: usize,
    visible: usize,
) usize {
    if (total <= visible or area.h <= 0) {
        state.grab = null;
        return scroll;
    }

    const limit = total - visible;
    const at = @min(scroll, limit);

    const span = thumbHeight(area.h, total, visible);
    const room = area.h - span;
    const offset = @divTrunc(room * @as(i32, @intCast(at)), @as(i32, @intCast(limit)));
    const thumb = Rect{ .x = area.x, .y = area.y + offset, .w = area.w, .h = span };

    var out = at;
    const over = area.contains(ctx.pointer_x, ctx.pointer_y);

    if (ctx.pressedThisPass() and over) {
        if (thumb.contains(ctx.pointer_x, ctx.pointer_y)) {
            state.grab = .{ .at_y = ctx.pointer_y, .from = at };
        } else {
            // The track pages towards the pointer, which is what a click
            // beside the thumb has meant since scrollbars existed.
            out = if (ctx.pointer_y < thumb.y) at -| visible else @min(at + visible, limit);
        }
    }

    if (!ctx.buttons.left) state.grab = null;

    if (state.grab) |held| {
        // Where the view stood when the thumb was taken, plus what the
        // pointer has moved since, in the units the caller counts in.
        const moved = ctx.pointer_y - held.at_y;
        const shift: i32 = if (room <= 0) 0 else @divTrunc(moved * @as(i32, @intCast(limit)), room);
        out = @intCast(std.math.clamp(
            @as(i32, @intCast(held.from)) + shift,
            0,
            @as(i32, @intCast(limit)),
        ));
    }

    // The thumb where it will be, since that is what the caller draws next.
    const shown = if (out == at) thumb else Rect{
        .x = area.x,
        .y = area.y + @divTrunc(room * @as(i32, @intCast(out)), @as(i32, @intCast(limit))),
        .w = area.w,
        .h = span,
    };
    const hot = over or state.grab != null;

    // Repainted when it says something different: a bar refilled on every
    // pass is the one thing dirtying a frame in which nothing moved, and on
    // a panel this size that is a flush of the whole column for nothing.
    if (ctx.slotFor(area)) |entry| {
        const visual: widget.Visual = if (hot) .hot else .idle;
        if (ctx.needsPaint(entry, visual) or entry.detail != shown.y) {
            entry.visual = visual;
            entry.detail = shown.y;
            paint(ctx, area, shown, hot);
        }
    } else {
        paint(ctx, area, shown, hot);
    }
    return out;
}

fn thumbHeight(height: i32, total: usize, visible: usize) i32 {
    const proportional = @divTrunc(height * @as(i32, @intCast(visible)), @as(i32, @intCast(total)));
    return std.math.clamp(proportional, @min(MIN_THUMB, height), height);
}

fn paint(ctx: *widget.Context, area: Rect, thumb: Rect, hot: bool) void {
    const t = theme.current();

    // The thumb is drawn in the dim text colour rather than the hairline one.
    // A scrollbar says where you are in a document, and one that has to be
    // hunted for against its own track is not saying it.
    ctx.surface.fill(area, t.surface_pressed);
    ctx.surface.fill(thumb.inset(1), if (hot) t.accent else t.text_dim);
    ctx.addDamage(area);
}
