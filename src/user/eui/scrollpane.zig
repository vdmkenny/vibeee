//! A pane that scrolls when what is in it does not fit.
//!
//! Every window on a screen this size will one day hold more than fits: a
//! longer list, a larger interface scale, a translation with longer words. A
//! pane that answered that by drawing off its own bottom edge would be a pane
//! with a part nobody can reach, so the answer belongs here rather than in the
//! panes: wrap what is drawn, and anything too tall becomes something that
//! scrolls.
//!
//! Used around the drawing rather than instead of it. `begin` narrows the
//! surface so nothing inside can paint outside the pane, and hands back where
//! to start drawing; `end` puts the surface back and draws the bar. What a
//! caller changes to become scrollable is two lines and where its first row
//! starts.
//!
//! How tall the contents are is what the caller drew last time. Measuring
//! twice would mean laying every pane out twice, and a pane whose height is
//! one pass out of date is a pane whose bar settles on the next frame.

const draw = @import("draw.zig");
const scroll = @import("scroll.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

pub const State = struct {
    /// How far down the contents have been pushed, in pixels.
    offset: i32 = 0,
    /// What the caller drew last pass, which is what the bar is sized from.
    content_h: i32 = 0,
    bar: scroll.State = .{},

    pub fn scrollable(self: *const State, area: Rect) bool {
        return self.content_h > area.h;
    }
};

/// What the caller draws into.
pub const View = struct {
    /// The area left for contents once the bar has taken its width.
    area: Rect,
    /// How far the contents have been pushed up.
    offset: i32,
    /// The surface as it was, put back by `end`.
    saved: Surface,
    /// Whether the pass was laid out with room for a bar, so `end` can tell
    /// that what was just drawn disagrees with what was assumed.
    barred: bool,

    /// Where the first row goes.
    pub fn top(self: View) i32 {
        return self.area.y - self.offset;
    }

    /// Whether a row at `y` this tall is on screen at all.
    ///
    /// Worth asking before drawing it. What is scrolled past is not merely
    /// invisible: it is clipped away after costing a control's worth of the
    /// pass's bookkeeping, and a long enough list would spend all of it on
    /// rows nobody can see.
    pub fn shows(self: View, y: i32, h: i32) bool {
        return y + h > self.area.y and y < self.area.bottom();
    }
};

/// Narrow the surface to `area` and return where to draw.
pub fn begin(ctx: *widget.Context, area: Rect, state: *State) View {
    const scrollable = state.scrollable(area);

    // The bar sits on the pane's own edge, with the contents ending where it
    // begins: a gap between them reads as a margin the pane does not have.
    const inner = Rect{
        .x = area.x,
        .y = area.y,
        .w = if (scrollable) area.w - scroll.WIDTH else area.w,
        .h = area.h,
    };

    // Held inside what there is to show. A pane that grew shorter with the
    // offset left where it was would open on nothing.
    const limit = @max(state.content_h - area.h, 0);
    state.offset = @max(0, @min(state.offset, limit));

    const saved = ctx.surface;
    ctx.surface = ctx.surface.clipped(area);

    return .{ .area = inner, .offset = state.offset, .saved = saved, .barred = scrollable };
}

/// Put the surface back, take the wheel, and draw the bar.
///
/// `content_h` is how tall what was just drawn turned out to be: the caller
/// knows where it stopped, and nothing else does.
pub fn end(ctx: *widget.Context, state: *State, view: View, content_h: i32) void {
    ctx.surface = view.saved;
    state.content_h = content_h;

    const scrollable = state.scrollable(view.area);

    // What was drawn disagrees with what the pass was laid out for: the
    // contents turned out taller than the pane, or no longer are. Neither can
    // be known before drawing, so the pane is drawn again with the answer.
    if (scrollable != view.barred) ctx.damage();

    if (!scrollable) {
        state.offset = 0;
        return;
    }

    const step = theme.enlarged(STEP);
    const limit = @max(content_h - view.area.h, 0);

    // The page keys, if nothing inside wanted them. Drawn contents get first
    // refusal because this runs after them, so a document that scrolls itself
    // still does.
    if (ctx.pending_key != 0) {
        const code: widget.KeyCode = @enumFromInt(ctx.pending_key);
        const page: i32 = @max(view.area.h - theme.enlarged(STEP), theme.enlarged(STEP));
        const moved: ?i32 = switch (code) {
            .page_down => @min(state.offset + page, limit),
            .page_up => @max(state.offset - page, 0),
            else => null,
        };
        if (moved) |to| {
            ctx.pending_key = 0;
            if (to != state.offset) {
                state.offset = to;
                ctx.damage();
            }
        }
    }

    const wheel = ctx.takeWheel();
    if (wheel != 0) {
        const moved = if (wheel < 0)
            @min(state.offset + step, limit)
        else
            @max(state.offset - step, 0);
        if (moved != state.offset) {
            state.offset = moved;
            ctx.damage();
        }
    }

    const bar = Rect{
        .x = view.area.right(),
        .y = view.area.y,
        .w = scroll.WIDTH,
        .h = view.area.h,
    };

    // The bar counts in pixels here, which is what a pane of mixed contents
    // has instead of rows: the proportions are the same either way.
    const dragged = ctx.scrollbar(
        bar,
        &state.bar,
        @intCast(state.offset),
        @intCast(content_h),
        @intCast(view.area.h),
    );
    if (dragged != state.offset) {
        state.offset = @intCast(@min(dragged, @as(usize, @intCast(limit))));
        ctx.damage();
    }
}

/// How far one notch of the wheel moves it. Three rows of text, which is what
/// a wheel means everywhere else.
const STEP: i32 = 48;
