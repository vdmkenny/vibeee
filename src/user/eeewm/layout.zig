//! The tiling model: tags, windows, and where each one goes.
//!
//! Pure geometry and bookkeeping. It owns no pixels and calls nothing that
//! draws, so the arrangement can be reasoned about, and eventually tested,
//! without a screen. design/10-gui.md §4.
//!
//! **Tags, not workspaces.** A window carries a tag and the screen views one,
//! dwm-style. Four of them, because every mapped client keeps its surface and
//! heap alive whether or not it is visible: nine tags invites nine resident
//! applications and blows the memory budget on a machine with 512 MB, and at
//! 800x480 more than about eight windows is not a workflow anyone has.
//!
//! **Tiled windows never overlap.** That is what makes hit testing a
//! point-in-rectangle test and compositing a walk of disjoint spans. Floating
//! windows are the exception, and they are exceptions on purpose: dialogs,
//! pickers and the launcher, which are transient and want to be above.

const std = @import("std");
const draw = @import("eui").draw;
const theme = @import("eui").theme;

const Rect = draw.Rect;

pub const TAGS = 4;
pub const MAX_WINDOWS = 16;

/// Smallest useful tile. The layout still splits below it rather than refusing
/// to, because refusing leaves a window with nowhere to be; the minimum is
/// what the stack stops subdividing at.
pub const MIN_TILE_W: i32 = 200;
pub const MIN_TILE_H: i32 = 100;

pub const Layout = enum {
    /// Master left, stack right. The default: one thing being worked on and a
    /// column of context.
    tall,
    /// Master top, stack bottom. For a terminal under a document.
    wide,
    /// Focused window fills the area, the rest hidden behind it.
    monocle,

    /// One letter for the bar, which has no room for a word.
    pub fn glyph(self: Layout) []const u8 {
        return switch (self) {
            .tall => "T",
            .wide => "W",
            .monocle => "M",
        };
    }

    pub fn next(self: Layout) Layout {
        return switch (self) {
            .tall => .wide,
            .wide => .monocle,
            .monocle => .tall,
        };
    }
};

pub const Window = struct {
    id: u32 = 0,
    title: [32]u8 = @splat(0),
    title_len: usize = 0,
    tag: u8 = 0,
    /// Above the tiles, positioned by hand rather than by the layout.
    floating: bool = false,
    /// Where it is now. Set by `arrange` for tiled windows and by dragging for
    /// floating ones.
    area: Rect = .{},
    used: bool = false,

    pub fn name(self: *const Window) []const u8 {
        return self.title[0..self.title_len];
    }

    fn setName(self: *Window, text: []const u8) void {
        const n = @min(text.len, self.title.len);
        @memcpy(self.title[0..n], text[0..n]);
        self.title_len = n;
    }
};

pub const Desktop = struct {
    windows: [MAX_WINDOWS]Window = @splat(.{}),
    next_id: u32 = 1,

    /// Which tag is on screen, and which was before it, for Mod+Tab.
    tag: u8 = 0,
    previous_tag: u8 = 0,

    /// Per tag, because a tag is a workspace and each wants its own shape.
    layouts: [TAGS]Layout = @splat(.tall),
    /// Master's share of the screen, per tag. Bounded well away from zero and
    /// one: a master column of twelve pixels helps nobody.
    mfact: [TAGS]f32 = @splat(0.58),

    focused: ?usize = null,

    /// The whole area windows may occupy, below the bar.
    bounds: Rect = .{},

    pub fn layout(self: *const Desktop) Layout {
        return self.layouts[self.tag];
    }

    // -----------------------------------------------------------------------
    // Windows
    // -----------------------------------------------------------------------

    pub fn open(self: *Desktop, title: []const u8, floating: bool) ?usize {
        for (&self.windows, 0..) |*w, i| {
            if (w.used) continue;

            w.* = .{
                .id = self.next_id,
                .tag = self.tag,
                .floating = floating,
                .used = true,
            };
            w.setName(title);
            self.next_id += 1;

            // A floating window has no tile to be given, so it is placed
            // centred once and left where the user puts it thereafter.
            if (floating) w.area = self.centred(320, 200);

            self.focused = i;
            self.arrange();
            return i;
        }
        return null;
    }

    pub fn close(self: *Desktop, index: usize) void {
        if (index >= MAX_WINDOWS or !self.windows[index].used) return;
        self.windows[index] = .{};

        if (self.focused == index) self.focused = null;
        self.focusFirst();
        self.arrange();
    }

    fn centred(self: *const Desktop, w: i32, h: i32) Rect {
        return .{
            .x = self.bounds.x + @divTrunc(self.bounds.w - w, 2),
            .y = self.bounds.y + @divTrunc(self.bounds.h - h, 2),
            .w = w,
            .h = h,
        };
    }

    /// Windows on the current tag, in order, tiled ones first.
    pub fn visible(self: *Desktop, out: []usize) []usize {
        var n: usize = 0;
        for (&self.windows, 0..) |*w, i| {
            if (!w.used or w.tag != self.tag or w.floating) continue;
            if (n == out.len) break;
            out[n] = i;
            n += 1;
        }
        for (&self.windows, 0..) |*w, i| {
            if (!w.used or w.tag != self.tag or !w.floating) continue;
            if (n == out.len) break;
            out[n] = i;
            n += 1;
        }
        return out[0..n];
    }

    fn tiled(self: *Desktop, out: []usize) []usize {
        var n: usize = 0;
        for (&self.windows, 0..) |*w, i| {
            if (!w.used or w.tag != self.tag or w.floating) continue;
            if (n == out.len) break;
            out[n] = i;
            n += 1;
        }
        return out[0..n];
    }

    // -----------------------------------------------------------------------
    // Arrangement
    // -----------------------------------------------------------------------

    /// Give every tiled window on the current tag its rectangle.
    pub fn arrange(self: *Desktop) void {
        var buf: [MAX_WINDOWS]usize = undefined;
        const list = self.tiled(&buf);
        if (list.len == 0) return;

        switch (self.layout()) {
            .monocle => for (list) |i| {
                self.windows[i].area = self.bounds;
            },
            .tall => self.split(list, .vertical),
            .wide => self.split(list, .horizontal),
        }
    }

    const Axis = enum { vertical, horizontal };

    /// Master takes `mfact` of one axis; the rest share the remainder along
    /// the other. One window takes everything, which is what makes a single
    /// window look like monocle without being it.
    fn split(self: *Desktop, list: []const usize, axis: Axis) void {
        const area = self.bounds;

        if (list.len == 1) {
            self.windows[list[0]].area = area;
            return;
        }

        const fraction = self.mfact[self.tag];

        switch (axis) {
            .vertical => {
                const master_w = clampSpan(
                    @intFromFloat(@as(f32, @floatFromInt(area.w)) * fraction),
                    area.w,
                    MIN_TILE_W,
                );

                self.windows[list[0]].area = .{
                    .x = area.x,
                    .y = area.y,
                    .w = master_w,
                    .h = area.h,
                };
                stack(self, list[1..], .{
                    .x = area.x + master_w,
                    .y = area.y,
                    .w = area.w - master_w,
                    .h = area.h,
                }, .horizontal);
            },
            .horizontal => {
                const master_h = clampSpan(
                    @intFromFloat(@as(f32, @floatFromInt(area.h)) * fraction),
                    area.h,
                    MIN_TILE_H,
                );

                self.windows[list[0]].area = .{
                    .x = area.x,
                    .y = area.y,
                    .w = area.w,
                    .h = master_h,
                };
                stack(self, list[1..], .{
                    .x = area.x,
                    .y = area.y + master_h,
                    .w = area.w,
                    .h = area.h - master_h,
                }, .vertical);
            },
        }
    }

    /// Divide `area` equally among `list` along `axis`.
    ///
    /// The remainder goes to the last tile rather than being dropped: losing a
    /// pixel per window leaves a seam of desktop showing down the edge of the
    /// stack.
    fn stack(self: *Desktop, list: []const usize, area: Rect, axis: Axis) void {
        if (list.len == 0) return;

        const count: i32 = @intCast(list.len);

        for (list, 0..) |index, k| {
            const step: i32 = @intCast(k);
            const last = k + 1 == list.len;

            self.windows[index].area = switch (axis) {
                .vertical => blk: {
                    const each = @divTrunc(area.h, count);
                    break :blk .{
                        .x = area.x,
                        .y = area.y + step * each,
                        .w = area.w,
                        .h = if (last) area.h - step * each else each,
                    };
                },
                .horizontal => blk: {
                    const each = @divTrunc(area.w, count);
                    break :blk .{
                        .x = area.x + step * each,
                        .y = area.y,
                        .w = if (last) area.w - step * each else each,
                        .h = area.h,
                    };
                },
            };
        }
    }

    // -----------------------------------------------------------------------
    // Commands
    // -----------------------------------------------------------------------

    pub fn view(self: *Desktop, tag: u8) void {
        if (tag >= TAGS or tag == self.tag) return;
        self.previous_tag = self.tag;
        self.tag = tag;
        self.focused = null;
        self.focusFirst();
        self.arrange();
    }

    pub fn viewPrevious(self: *Desktop) void {
        self.view(self.previous_tag);
    }

    /// Send the focused window to `tag` and stop showing it here.
    pub fn moveToTag(self: *Desktop, tag: u8) void {
        if (tag >= TAGS) return;
        const index = self.focused orelse return;
        self.windows[index].tag = tag;
        self.focused = null;
        self.focusFirst();
        self.arrange();
    }

    pub fn setLayout(self: *Desktop, value: Layout) void {
        self.layouts[self.tag] = value;
        self.arrange();
    }

    pub fn cycleLayout(self: *Desktop) void {
        self.setLayout(self.layout().next());
    }

    /// Adjust master's share. Steps of 0.05 within 0.20 to 0.80, so it cannot
    /// be driven to a state with no way back.
    pub fn nudgeMaster(self: *Desktop, delta: f32) void {
        const value = self.mfact[self.tag] + delta;
        self.mfact[self.tag] = @max(0.20, @min(value, 0.80));
        self.arrange();
    }

    pub fn focusNext(self: *Desktop, step: i32) void {
        var buf: [MAX_WINDOWS]usize = undefined;
        const list = self.visible(&buf);
        if (list.len == 0) return;

        var at: usize = 0;
        if (self.focused) |current| {
            for (list, 0..) |index, k| {
                if (index == current) at = k;
            }
        }

        const count: i32 = @intCast(list.len);
        const moved = @mod(@as(i32, @intCast(at)) + step + count, count);
        self.focused = list[@intCast(moved)];
    }

    pub fn focusAt(self: *Desktop, x: i32, y: i32) void {
        var buf: [MAX_WINDOWS]usize = undefined;
        const list = self.visible(&buf);

        // Backwards, so the topmost window under the point wins: floating
        // windows are last in the list and therefore drawn last.
        var k = list.len;
        while (k > 0) {
            k -= 1;
            if (self.windows[list[k]].area.contains(x, y)) {
                self.focused = list[k];
                return;
            }
        }
    }

    pub fn toggleFloating(self: *Desktop) void {
        const index = self.focused orelse return;
        const w = &self.windows[index];

        w.floating = !w.floating;
        // Coming out of the tiling, it keeps the tile it had, shrunk a little
        // so it reads as lifted off rather than merely still there.
        if (w.floating) w.area = w.area.inset(16);
        self.arrange();
    }

    /// Promote the focused window to master, or the master to second place.
    pub fn zoom(self: *Desktop) void {
        var buf: [MAX_WINDOWS]usize = undefined;
        const list = self.tiled(&buf);
        if (list.len < 2) return;

        const index = self.focused orelse return;
        const target = if (list[0] == index) list[1] else index;

        const swap = self.windows[list[0]];
        self.windows[list[0]] = self.windows[target];
        self.windows[target] = swap;

        self.focused = list[0];
        self.arrange();
    }

    fn focusFirst(self: *Desktop) void {
        if (self.focused != null) return;
        var buf: [MAX_WINDOWS]usize = undefined;
        const list = self.visible(&buf);
        if (list.len > 0) self.focused = list[0];
    }

    /// Which tags have anything on them, for the bar's pips.
    pub fn occupied(self: *const Desktop) [TAGS]bool {
        var out: [TAGS]bool = @splat(false);
        for (self.windows) |w| {
            if (w.used and w.tag < TAGS) out[w.tag] = true;
        }
        return out;
    }
};

/// Keep a split from collapsing or from swallowing the whole area.
fn clampSpan(value: i32, total: i32, minimum: i32) i32 {
    if (total <= minimum * 2) return @divTrunc(total, 2);
    return @max(minimum, @min(value, total - minimum));
}
