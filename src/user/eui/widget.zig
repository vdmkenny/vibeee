//! libeui controls: the shared widget set.
//!
//! This is the `comctl` of the system. Anything that puts an interface on
//! screen, the compositor's own furniture included, draws it from here, so a
//! button looks and behaves the same everywhere and a new application gets the
//! whole look by asking for controls rather than by drawing rectangles.
//!
//! **Immediate-mode API, retained-mode painting.** Nuklear's calling
//! convention is the good part: a control is a function call that returns
//! whether it was activated, so there is no widget tree to keep in sync with
//! the program's own state. Nuklear's repaint model is the bad part on this
//! machine: redrawing everything every frame costs 1.5 MB of writes at 800x480
//! and the memory bandwidth to do that sixty times a second does not exist
//! here.
//!
//! So the calls are immediate and the painting is not. A control is identified
//! by where it is, its visual state is remembered between passes, and it is
//! only drawn when that state changes or when something else has damaged the
//! area under it. A pass over an interface where nothing happened writes no
//! pixels at all.

const std = @import("std");
const draw = @import("draw.zig");

const theme = @import("theme.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

pub const Buttons = @import("lib").syscalls.Buttons;
pub const Modifiers = @import("lib").syscalls.Modifiers;

/// Keys the toolkit acts on itself, matching kernel/input.zig KeyCode.
pub const KeyCode = @import("lib").syscalls.KeyCode;

/// How a control looks right now. Kept per control so a pass can tell whether
/// anything needs redrawing.
const Visual = enum { idle, hot, active, checked, checked_hot };

/// One control's identity and remembered state.
///
/// Identified by position rather than by a name or an index: a control is
/// where it is on screen, two controls cannot occupy the same place, and it
/// spares every caller inventing stable ids.
const Entry = struct {
    x: i16 = 0,
    y: i16 = 0,
    used: bool = false,
    visual: Visual = .idle,
    /// Whatever the control needs to notice a change beyond its visual state:
    /// the filled width of a progress bar, for instance. Compared, not
    /// interpreted.
    detail: i32 = 0,
    /// Cleared at the start of each pass; anything not touched has gone away.
    seen: bool = false,
    /// Can take keyboard focus. A label cannot; a button can.
    focusable: bool = false,
};

const MAX_WIDGETS = 64;

/// Damage rectangles kept before the list collapses to its bounding box.
/// Sixteen matches what the compositor caps a frame at (design §10.3).
const MAX_DAMAGE = 16;

pub const Context = struct {
    surface: Surface,

    /// Where the pointer is and what is held, as of this pass.
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    buttons: Buttons = .{},
    /// Buttons as of the previous pass, so a press and a release can be told
    /// apart from a button merely being held.
    previous: Buttons = .{},

    /// The control the pointer went down on. A click belongs to it until the
    /// button comes back up, which is what lets someone press a button, drag
    /// away and release without activating it.
    pressed: ?usize = null,

    /// Keyboard state for this pass. A key is consumed by whichever control
    /// has focus, so a pass sees it at most once.
    pending_key: u8 = 0,
    key_mods: Modifiers = .{},

    /// The control with keyboard focus, as an index into `entries`. Kept
    /// across passes: focus is state, and losing it every frame would make Tab
    /// useless.
    focus: ?usize = null,
    /// Set when focus moved this pass, so the control losing it repaints too.
    focus_moved: bool = false,

    /// Force everything to redraw, because something outside the toolkit
    /// painted over it.
    damaged: bool = true,

    /// What changed this pass, in screen coordinates. A compositor sends these
    /// rather than the whole surface: design/10-gui.md §10.3, and the
    /// difference between an idle interface costing nothing and costing a
    /// megabyte and a half a frame.
    damage_rects: [MAX_DAMAGE]Rect = @splat(.{}),
    damage_count: usize = 0,
    damage_overflowed: bool = false,

    entries: [MAX_WIDGETS]Entry = @splat(.{}),

    pub fn init(surface: Surface) Context {
        return .{ .surface = surface };
    }

    /// Start a pass. `x`, `y` and `buttons` are the pointer as it is now.
    pub fn begin(self: *Context, x: i32, y: i32, buttons: Buttons) void {
        self.previous = self.buttons;
        self.buttons = buttons;
        self.pointer_x = x;
        self.pointer_y = y;

        self.damage_count = 0;
        self.damage_overflowed = false;
        self.focus_moved = false;

        for (&self.entries) |*e| e.seen = false;
    }

    /// Offer a key to this pass. Tab and Shift+Tab move focus; anything else
    /// is left for the focused control to act on.
    pub fn postKey(self: *Context, code: u8, mods: Modifiers) void {
        if (code == @intFromEnum(KeyCode.tab)) {
            self.moveFocus(if (mods.shift) .backward else .forward);
            return;
        }
        self.pending_key = code;
        self.key_mods = mods;
    }

    /// Record that `area` needs sending to the screen.
    ///
    /// Overlapping rectangles are merged when they touch, and the whole list
    /// collapses to one bounding rectangle once it overflows: past a certain
    /// number of small rectangles the bookkeeping costs more than the pixels.
    pub fn addDamage(self: *Context, area: Rect) void {
        if (area.isEmpty()) return;

        for (self.damage_rects[0..self.damage_count]) |*existing| {
            if (!existing.intersect(area).isEmpty()) {
                existing.* = existing.unite(area);
                return;
            }
        }

        if (self.damage_count == MAX_DAMAGE) {
            self.damage_overflowed = true;
            var all = self.damage_rects[0];
            for (self.damage_rects[1..]) |r| all = all.unite(r);
            self.damage_rects[0] = all.unite(area);
            self.damage_count = 1;
            return;
        }

        self.damage_rects[self.damage_count] = area;
        self.damage_count += 1;
    }

    /// What changed this pass.
    pub fn damageList(self: *const Context) []const Rect {
        return self.damage_rects[0..self.damage_count];
    }

    const Direction = enum { forward, backward };

    fn moveFocus(self: *Context, direction: Direction) void {
        var order: [MAX_WIDGETS]usize = undefined;
        var n: usize = 0;
        for (&self.entries, 0..) |*e, i| {
            if (e.used and e.focusable) {
                order[n] = i;
                n += 1;
            }
        }
        if (n == 0) return;

        // Tab order follows position, top to bottom then left to right, which
        // is the order the interface reads in. Insertion order would follow
        // whatever the drawing code happened to do first.
        var i: usize = 1;
        while (i < n) : (i += 1) {
            var j = i;
            while (j > 0 and self.before(order[j], order[j - 1])) : (j -= 1) {
                const swap = order[j];
                order[j] = order[j - 1];
                order[j - 1] = swap;
            }
        }

        var at: usize = 0;
        if (self.focus) |current| {
            for (order[0..n], 0..) |index, k| {
                if (index == current) at = k;
            }
            at = switch (direction) {
                .forward => (at + 1) % n,
                .backward => (at + n - 1) % n,
            };
        }

        self.focus = order[at];
        self.focus_moved = true;
    }

    fn before(self: *const Context, a: usize, b: usize) bool {
        const ea = self.entries[a];
        const eb = self.entries[b];
        if (ea.y != eb.y) return ea.y < eb.y;
        return ea.x < eb.x;
    }

    /// Take the pending key if this control has focus.
    fn takeKey(self: *Context, index: usize) ?u8 {
        if (self.focus != index or self.pending_key == 0) return null;
        const code = self.pending_key;
        self.pending_key = 0;
        return code;
    }

    /// Finish a pass, releasing state for controls that were not drawn.
    pub fn end(self: *Context) void {
        for (&self.entries) |*e| {
            if (e.used and !e.seen) e.* = .{};
        }
        self.damaged = false;

        if (!self.buttons.left) self.pressed = null;
    }

    /// Repaint everything on the next pass.
    pub fn damage(self: *Context) void {
        self.damaged = true;
    }

    fn pressedThisPass(self: *const Context) bool {
        return self.buttons.left and !self.previous.left;
    }

    fn releasedThisPass(self: *const Context) bool {
        return !self.buttons.left and self.previous.left;
    }

    fn slotFor(self: *Context, area: Rect) ?*Entry {
        const x: i16 = @intCast(@max(@min(area.x, 32767), -32768));
        const y: i16 = @intCast(@max(@min(area.y, 32767), -32768));

        var free: ?*Entry = null;
        for (&self.entries) |*e| {
            if (e.used and e.x == x and e.y == y) return e;
            if (!e.used and free == null) free = e;
        }

        const slot = free orelse return null;
        slot.* = .{ .x = x, .y = y, .used = true };
        return slot;
    }

    fn indexOf(self: *const Context, entry: *const Entry) usize {
        return (@intFromPtr(entry) - @intFromPtr(&self.entries)) / @sizeOf(Entry);
    }

    // -----------------------------------------------------------------------
    // Controls
    // -----------------------------------------------------------------------

    /// A push button. Returns true on the pass where it is released, having
    /// been pressed on itself.
    pub fn button(self: *Context, area: Rect, text: []const u8) bool {
        const entry = self.slotFor(area) orelse return false;
        entry.seen = true;
        entry.focusable = true;

        const over = area.contains(self.pointer_x, self.pointer_y);
        const index = self.indexOf(entry);

        if (over and self.pressedThisPass()) {
            self.pressed = index;
            // Clicking also focuses, so the keyboard picks up where the
            // pointer left off rather than somewhere else entirely.
            if (self.focus != index) {
                self.focus = index;
                self.focus_moved = true;
            }
        }

        const holding = self.pressed == index and self.buttons.left;
        var activated = over and self.pressed == index and self.releasedThisPass();

        // Enter or Space activates the focused control, which is the whole
        // point of focus existing.
        if (self.takeKey(index)) |code| {
            if (code == @intFromEnum(KeyCode.enter) or code == @intFromEnum(KeyCode.space)) activated = true;
        }

        const focused = self.focus == index;
        const visual: Visual = if (holding) .active else if (over) .hot else .idle;

        if (visual != entry.visual or self.damaged or self.focus_moved) {
            entry.visual = visual;
            paintButton(self.surface, area, text, visual, focused);
            self.addDamage(area);
        }

        return activated;
    }

    /// A checkbox. `checked` is the caller's state; the returned value is what
    /// it should be after this pass.
    pub fn checkbox(self: *Context, area: Rect, text: []const u8, checked: bool) bool {
        const entry = self.slotFor(area) orelse return checked;
        entry.seen = true;
        entry.focusable = true;

        const over = area.contains(self.pointer_x, self.pointer_y);
        const index = self.indexOf(entry);

        if (over and self.pressedThisPass()) {
            self.pressed = index;
            if (self.focus != index) {
                self.focus = index;
                self.focus_moved = true;
            }
        }

        var value = checked;
        if (over and self.pressed == index and self.releasedThisPass()) value = !value;

        if (self.takeKey(index)) |code| {
            if (code == @intFromEnum(KeyCode.enter) or code == @intFromEnum(KeyCode.space)) value = !value;
        }

        const focused = self.focus == index;
        const visual: Visual = if (value)
            (if (over) .checked_hot else .checked)
        else
            (if (over) .hot else .idle);

        if (visual != entry.visual or self.damaged or self.focus_moved) {
            entry.visual = visual;
            paintCheckbox(self.surface, area, text, value, over, focused);
            self.addDamage(area);
        }

        return value;
    }

    /// Static text. Repainted only when something has damaged it, since a
    /// label has no state of its own to change.
    pub fn label(self: *Context, area: Rect, text: []const u8) void {
        const entry = self.slotFor(area) orelse return;
        entry.seen = true;

        // A label has no state of its own, so it repaints only when something
        // else has drawn over it.
        if (self.damaged) {
            const t = theme.current();
            self.surface.fill(area, t.surface);
            self.surface.text(area.x, area.y, text, t.text);
            self.addDamage(area);
        }
    }

    /// A filled bar, for anything with a proportion to show.
    pub fn progress(self: *Context, area: Rect, fraction: u8) void {
        const entry = self.slotFor(area) orelse return;
        entry.seen = true;

        // Compared on the filled width rather than the percentage: what shows
        // is pixels, and two percentages that round to the same width need no
        // repaint.
        const filled = @divTrunc(area.w * @as(i32, @min(fraction, 100)), 100);

        if (self.damaged or entry.detail != filled) {
            entry.detail = filled;
            const t = theme.current();
            self.surface.fill(area, t.surface_pressed);
            self.surface.fill(.{ .x = area.x, .y = area.y, .w = filled, .h = area.h }, t.accent);
            self.surface.frame(area, t.line);
            self.addDamage(area);
        }
    }
};

// ---------------------------------------------------------------------------
// Painting
//
// Separate from the control functions so the look lives in one place: changing
// how a button is drawn should not mean touching how it behaves.
// ---------------------------------------------------------------------------

fn paintButton(surface: Surface, area: Rect, text: []const u8, visual: Visual, focused: bool) void {
    const t = theme.current();

    const face = switch (visual) {
        .active => t.surface_pressed,
        .hot => t.surface_hot,
        else => t.surface,
    };

    surface.fill(area, face);
    surface.frame(area, if (focused) t.accent else t.line);
    surface.textCentred(area, text, t.text);

    if (focused) paintFocusRing(surface, area.inset(2));
}

/// A dotted rectangle marking keyboard focus. Dotted rather than solid so it
/// reads as focus rather than as a border the control always had.
fn paintFocusRing(surface: Surface, area: Rect) void {
    const color = theme.current().text_dim;

    var x = area.x;
    while (x < area.right()) : (x += 2) {
        surface.set(x, area.y, color);
        surface.set(x, area.bottom() - 1, color);
    }
    var y = area.y;
    while (y < area.bottom()) : (y += 2) {
        surface.set(area.x, y, color);
        surface.set(area.right() - 1, y, color);
    }
}

fn paintCheckbox(surface: Surface, area: Rect, text: []const u8, checked: bool, hot: bool, focused: bool) void {
    const t = theme.current();
    surface.fill(area, t.surface);

    const size: i32 = 12;
    const box = Rect{
        .x = area.x + 1,
        .y = area.y + @divTrunc(area.h - size, 2),
        .w = size,
        .h = size,
    };

    // Filled with the accent when set, rather than ticked: at twelve pixels a
    // check mark is a smudge, and a solid block reads at a glance.
    surface.fill(box, if (checked) t.accent else if (hot) t.surface_hot else t.surface_pressed);
    surface.frame(box, if (focused) t.accent else t.line);

    if (checked) {
        surface.fill(box.inset(3), t.accent_text);
        surface.fill(box.inset(4), t.accent);
    }

    surface.text(
        box.right() + t.padding,
        area.y + @divTrunc(area.h - draw.Surface.textHeight(), 2),
        text,
        t.text,
    );

    if (focused) paintFocusRing(surface, area);
}

// ---------------------------------------------------------------------------
// Menu
//
// A list of choices with one highlighted. Two things wanted it, a taskbar
// dropdown and an application launcher, which is the threshold at which it
// stops being drawing and starts being a control.
// ---------------------------------------------------------------------------

pub const ROW_HEIGHT: i32 = 18;

pub const Menu = struct {
    /// Which row is highlighted. Survives between passes: a menu that forgot
    /// where the selection was every frame could not be driven by keyboard.
    selected: usize = 0,
    open: bool = false,

    pub fn show(self: *Menu) void {
        self.open = true;
        self.selected = 0;
    }

    pub fn hide(self: *Menu) void {
        self.open = false;
    }

    /// How large a menu of `count` rows needs to be, so a caller can place it
    /// before drawing it.
    pub fn sizeFor(count: usize, width: i32) Rect {
        return .{
            .x = 0,
            .y = 0,
            .w = width,
            .h = @as(i32, @intCast(count)) * ROW_HEIGHT + 2,
        };
    }

    pub fn paint(self: *const Menu, surface: Surface, area: Rect, items: []const []const u8) void {
        const t = theme.current();

        surface.fill(area, t.surface);
        surface.frame(area, t.line);

        for (items, 0..) |text, row| {
            const line = rowRect(area, row);
            const highlighted = row == self.selected;
            if (highlighted) surface.fill(line, t.accent);

            const clipped = surface.clipped(line);
            clipped.text(
                line.x + t.padding,
                line.y + @divTrunc(line.h - Surface.textHeight(), 2),
                text,
                if (highlighted) t.accent_text else t.text,
            );
        }
    }

    /// Which row a point falls on, or null if it misses the menu entirely.
    pub fn rowAt(area: Rect, count: usize, x: i32, y: i32) ?usize {
        if (!area.contains(x, y)) return null;
        const row: usize = @intCast(@max(@divTrunc(y - area.y - 1, ROW_HEIGHT), 0));
        return if (row < count) row else null;
    }

    pub const KeyAction = enum { ignored, moved, chosen, cancelled };

    /// Drive the selection. The caller acts on `chosen`, because only it knows
    /// what the rows mean.
    pub fn key(self: *Menu, code: KeyCode, count: usize) KeyAction {
        if (count == 0) return .cancelled;

        switch (code) {
            .up => {
                self.selected = if (self.selected == 0) count - 1 else self.selected - 1;
                return .moved;
            },
            .down => {
                self.selected = (self.selected + 1) % count;
                return .moved;
            },
            .enter, .space => return .chosen,
            .escape => {
                self.hide();
                return .cancelled;
            },
            else => return .ignored,
        }
    }

    fn rowRect(area: Rect, row: usize) Rect {
        return .{
            .x = area.x + 1,
            .y = area.y + 1 + @as(i32, @intCast(row)) * ROW_HEIGHT,
            .w = area.w - 2,
            .h = ROW_HEIGHT,
        };
    }
};
