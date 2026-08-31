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

const draw = @import("eui").draw;

const Rect = draw.Rect;

/// Desktops are created as they are needed rather than fixed at four. A
/// numbered row of empty slots is a menu of nothing; a row of named tabs is a
/// list of what is actually open, and it should be exactly as long as that.
/// The cap exists because every mapped client keeps its surface resident, not
/// because the model wants one.
pub const MAX_DESKTOPS = 9;
pub const MAX_WINDOWS = 16;

/// Below this a further split stops being usable, and a new window goes to a
/// new desktop instead of making every existing tile unreadable.
pub const SPLIT_LIMIT_W: i32 = 240;
pub const SPLIT_LIMIT_H: i32 = 140;

/// Smallest useful tile. The layout still splits below it rather than refusing
/// to, because refusing leaves a window with nowhere to be; the minimum is
/// what the stack stops subdividing at.
pub const MIN_TILE_W: i32 = 200;
pub const MIN_TILE_H: i32 = 100;

pub const Window = struct {
    id: u32 = 0,
    /// The client that owns it, or 0 for one the manager made itself.
    client_pid: u32 = 0,
    /// The client's window id, which is per client rather than global.
    client_win: u8 = 0,
    /// Set once the client has attached a surface and mapped the window.
    mapped: bool = false,
    /// What the layout last told the client its size was, so a `configure` is
    /// only sent when it actually changed.
    told_w: u16 = 0,
    told_h: u16 = 0,
    title: [32]u8 = @splat(0),
    title_len: usize = 0,
    tag: u8 = 0,
    /// Above the tiles, positioned by hand rather than by the layout.
    floating: bool = false,
    /// How much of what is behind shows through. Zero is opaque, which is what
    /// every window but a terminal asks for.
    transparency: u8 = 0,
    /// Where it is now. Set by `arrange` for tiled windows and by dragging for
    /// floating ones.
    area: Rect = .{},
    used: bool = false,

    pub fn name(self: *const Window) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn setTitle(self: *Window, text: []const u8) void {
        self.setName(text);
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

    /// Which desktop is on screen, and which was before it.
    tag: u8 = 0,
    previous_tag: u8 = 0,
    /// How many exist. Always at least one, and grown on demand.
    count: u8 = 1,

    /// Per desktop, because each wants its own shape.
    /// Master's share, per desktop. Bounded well away from zero and one: a
    /// master column of twelve pixels helps nobody.
    mfact: [MAX_DESKTOPS]f32 = @splat(0.58),
    /// The window each desktop last had focused, so its tab can be named after
    /// what the user was actually doing there.
    last_focused: [MAX_DESKTOPS]?usize = @splat(null),

    focused: ?usize = null,

    /// The whole area windows may occupy, below the bar.
    bounds: Rect = .{},

    /// Whether this desktop is showing one window at full size rather than
    /// the tiling it would otherwise have.
    ///
    /// Per desktop rather than per window, and it follows the focus: what is
    /// wanted is to look at one thing for a moment, and then at the next
    /// one, without putting the tiling back between them. Moving the focus
    /// while it is on is how you leaf through them.
    maximised: [MAX_DESKTOPS]bool = @splat(false),

    // -----------------------------------------------------------------------
    // Windows
    // -----------------------------------------------------------------------

    /// Find a window by the client that owns it and that client's id for it.
    pub fn byClient(self: *Desktop, pid: u32, win: u8) ?usize {
        for (&self.windows, 0..) |*w, i| {
            if (w.used and w.client_pid == pid and w.client_win == win) return i;
        }
        return null;
    }

    /// Drop everything a departed client owned.
    pub fn closeClient(self: *Desktop, pid: u32) void {
        for (&self.windows, 0..) |*w, i| {
            if (w.used and w.client_pid == pid) self.close(i);
        }
    }

    pub fn open(self: *Desktop, title: []const u8, floating: bool) ?usize {
        for (&self.windows, 0..) |*w, i| {
            if (w.used) continue;

            w.* = .{
                .id = self.next_id,
                .tag = self.placementFor(floating),
                .floating = floating,
                .used = true,
            };
            w.setName(title);
            self.next_id += 1;

            // A floating window has no tile to be given, so it is placed
            // centred once and left where the user puts it thereafter.
            if (floating) w.area = self.centred(320, 200);

            // Follow the window if the heuristic sent it elsewhere: a program
            // that opened somewhere invisible looks like a program that failed
            // to open.
            if (w.tag != self.tag) {
                self.last_focused[self.tag] = self.focused;
                self.previous_tag = self.tag;
                self.tag = w.tag;
            }

            self.focused = i;
            self.last_focused[w.tag] = i;
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

        // Every window takes the whole area rather than the focused one
        // taking it and the rest being moved: they are drawn in order and
        // the focused one is drawn last, so what is underneath is already
        // hidden and putting the tiling back is one flag away.
        if (self.maximised[self.tag]) {
            for (list) |i| self.windows[i].area = self.bounds;
            return;
        }

        self.split(list, .vertical);
    }

    /// Show one window at full size, or put the tiling back.
    ///
    /// A desktop holding one window is already showing it at full size, so
    /// there is nothing to toggle and the flag is left alone: a key that
    /// appeared to do nothing and then changed what the next window did
    /// would be worse than one that plainly does nothing.
    pub fn toggleMaximised(self: *Desktop) bool {
        var buf: [MAX_WINDOWS]usize = undefined;
        if (self.tiled(&buf).len < 2) return false;

        self.maximised[self.tag] = !self.maximised[self.tag];
        self.arrange();
        return true;
    }

    pub fn isMaximised(self: *const Desktop) bool {
        return self.maximised[self.tag];
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
        if (tag >= self.count or tag == self.tag) return;

        // Remembered before leaving, so coming back lands where it was left.
        self.last_focused[self.tag] = self.focused;

        self.previous_tag = self.tag;
        self.tag = tag;
        self.focused = self.validate(self.last_focused[tag]);
        self.focusFirst();
        self.arrange();
    }

    /// Switch to `tag` and focus `window` on it, which is what activating an
    /// entry in a tab's dropdown means.
    pub fn viewWindow(self: *Desktop, index: usize) void {
        if (index >= MAX_WINDOWS or !self.windows[index].used) return;

        const tag = self.windows[index].tag;
        if (tag != self.tag) {
            self.last_focused[self.tag] = self.focused;
            self.previous_tag = self.tag;
            self.tag = tag;
        }
        self.focused = index;
        self.last_focused[tag] = index;
        self.arrange();
    }

    fn validate(self: *const Desktop, index: ?usize) ?usize {
        const value = index orelse return null;
        if (value >= MAX_WINDOWS) return null;
        const w = self.windows[value];
        if (!w.used or w.tag != self.tag) return null;
        return value;
    }

    /// Add a desktop and switch to it. Returns false when there is no room.
    pub fn addDesktop(self: *Desktop) bool {
        if (self.count >= MAX_DESKTOPS) return false;
        self.count += 1;
        self.view(self.count - 1);
        return true;
    }

    /// Close every window on a desktop and remove it if it is not the last.
    ///
    /// The windows go through the caller, which knows how to ask a client to
    /// close rather than dropping it: a client with unsaved work deserves to
    /// be told, not have its surface taken away.
    pub fn windowsToClose(self: *const Desktop, tag: u8, out: []usize) []usize {
        return self.windowsOn(tag, out);
    }

    /// Remove an empty desktop, renumbering the ones after it.
    ///
    /// Windows on later desktops move down with them, so a tab does not change
    /// what it holds. The last desktop is never removed: a session with none
    /// has nowhere to put anything.
    pub fn removeDesktop(self: *Desktop, tag: u8) void {
        if (self.count <= 1 or tag >= self.count) return;
        if (self.countOn(tag) != 0) return;

        for (&self.windows) |*w| {
            if (w.used and w.tag > tag) w.tag -= 1;
        }

        var i: u8 = tag;
        while (i + 1 < self.count) : (i += 1) {
            self.maximised[i] = self.maximised[i + 1];
            self.mfact[i] = self.mfact[i + 1];
            self.last_focused[i] = self.last_focused[i + 1];
        }
        self.count -= 1;

        if (self.tag >= self.count) self.tag = self.count - 1;
        if (self.previous_tag >= self.count) self.previous_tag = 0;

        self.focused = null;
        self.focusFirst();
        self.arrange();
    }

    /// Drop trailing desktops that hold nothing.
    ///
    /// Only from the end, and never the one being viewed: renumbering a
    /// desktop out from under someone would move every tab they had learned
    /// the position of.
    pub fn pruneDesktops(self: *Desktop) void {
        const occupied_tags = self.occupied();
        while (self.count > 1) {
            const last = self.count - 1;
            if (occupied_tags[last] or self.tag == last) break;
            self.count -= 1;
        }
    }

    /// How many windows are on a desktop.
    pub fn countOn(self: *const Desktop, tag: u8) usize {
        var n: usize = 0;
        for (self.windows) |w| {
            if (w.used and w.tag == tag) n += 1;
        }
        return n;
    }

    /// The window whose name a desktop's tab should carry: whatever was last
    /// focused there, or failing that the first one on it.
    pub fn representative(self: *const Desktop, tag: u8) ?usize {
        if (self.last_focused[tag]) |index| {
            if (index < MAX_WINDOWS) {
                const w = self.windows[index];
                if (w.used and w.tag == tag) return index;
            }
        }
        for (self.windows, 0..) |w, i| {
            if (w.used and w.tag == tag) return i;
        }
        return null;
    }

    /// Every window on a desktop, for its dropdown.
    pub fn windowsOn(self: *const Desktop, tag: u8, out: []usize) []usize {
        var n: usize = 0;
        for (self.windows, 0..) |w, i| {
            if (!w.used or w.tag != tag) continue;
            if (n == out.len) break;
            out[n] = i;
            n += 1;
        }
        return out[0..n];
    }

    /// Where a new window should go.
    ///
    /// Splitting is right until the tiles stop being usable. Past that a new
    /// desktop is better than four unreadable columns, which is the judgement
    /// a person would make and the one a tiling manager should make for them.
    pub fn placementFor(self: *Desktop, floating: bool) u8 {
        // A dialog belongs with whatever raised it, whatever the crowding.
        if (floating) return self.tag;

        const here = self.countOn(self.tag);
        if (here == 0) return self.tag;

        const area = self.bounds;
        const fits = self.maximised[self.tag] or
            @divTrunc(area.w, @as(i32, @intCast(here + 1))) >= SPLIT_LIMIT_W;
        if (fits) return self.tag;

        // Full: the first empty desktop, or a new one.
        const occupied_tags = self.occupied();
        for (0..self.count) |i| {
            if (!occupied_tags[i]) return @intCast(i);
        }
        if (self.count < MAX_DESKTOPS) {
            self.count += 1;
            return self.count - 1;
        }
        return self.tag;
    }

    pub fn viewPrevious(self: *Desktop) void {
        self.view(self.previous_tag);
    }

    /// Move `step` desktops along, wrapping.
    ///
    /// Wrapping rather than stopping: with a handful of desktops the end is
    /// never far from the beginning, and a key that silently does nothing at
    /// the edge reads as a key that is broken.
    pub fn viewRelative(self: *Desktop, step: i32) void {
        if (self.count <= 1) return;
        const count: i32 = @intCast(self.count);
        const target = @mod(@as(i32, self.tag) + step + count, count);
        self.view(@intCast(target));
    }

    /// Send the focused window `step` desktops along and follow it there.
    ///
    /// Following is deliberate: a window that moved somewhere invisible looks
    /// like a window that vanished.
    pub fn sendRelative(self: *Desktop, step: i32) void {
        if (self.count <= 1) return;
        const index = self.focused orelse return;

        const count: i32 = @intCast(self.count);
        const target: u8 = @intCast(@mod(@as(i32, self.tag) + step + count, count));

        self.windows[index].tag = target;
        self.view(target);
        self.focused = index;
        self.last_focused[target] = index;
        self.arrange();
    }

    /// Send the focused window to `tag` and stop showing it here.
    pub fn moveToTag(self: *Desktop, tag: u8) void {
        if (tag >= MAX_DESKTOPS) return;
        if (tag >= self.count) self.count = tag + 1;
        const index = self.focused orelse return;
        self.windows[index].tag = tag;
        self.focused = null;
        self.focusFirst();
        self.arrange();
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
    pub fn occupied(self: *const Desktop) [MAX_DESKTOPS]bool {
        var out: [MAX_DESKTOPS]bool = @splat(false);
        for (self.windows) |w| {
            if (w.used and w.tag < MAX_DESKTOPS) out[w.tag] = true;
        }
        return out;
    }
};

/// Keep a split from collapsing or from swallowing the whole area.
fn clampSpan(value: i32, total: i32, minimum: i32) i32 {
    if (total <= minimum * 2) return @divTrunc(total, 2);
    return @max(minimum, @min(value, total - minimum));
}
