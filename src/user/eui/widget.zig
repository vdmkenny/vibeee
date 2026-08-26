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
const glyphs = @import("lib").font.glyphs;
const tbl = @import("table.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

pub const Buttons = @import("lib").syscalls.Buttons;
pub const Modifiers = @import("lib").syscalls.Modifiers;

/// Keys the toolkit acts on itself, matching kernel/input.zig KeyCode.
pub const KeyCode = @import("lib").syscalls.KeyCode;

/// How a control looks right now. Kept per control so a pass can tell whether
/// anything needs redrawing.
pub const Visual = enum { idle, hot, active, checked, checked_hot };

/// One control's identity and remembered state.
///
/// Identified by position rather than by a name or an index: a control is
/// where it is on screen, two controls cannot occupy the same place, and it
/// spares every caller inventing stable ids.
pub const Entry = struct {
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

    /// Wheel notches this pass, negative for away from the user. Consumed by
    /// whichever control the pointer is over, since that is what a wheel means.
    pending_wheel: i8 = 0,

    /// The control with keyboard focus, as an index into `entries`. Kept
    /// across passes: focus is state, and losing it every frame would make Tab
    /// useless.
    focus: ?usize = null,
    /// Set when focus moved this pass, so the control losing it repaints too.
    focus_moved: bool = false,

    /// Everything must redraw this pass.
    damaged: bool = true,
    /// Damage asked for during a pass, which applies to the next one.
    ///
    /// Separate from `damaged` because a control that changes something
    /// asks for a repaint *after* the pass has already decided what to draw:
    /// folding the two together loses the request, and the caller sees a
    /// window whose controls updated and whose background did not.
    pending: bool = false,

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
        if (self.pending) {
            self.damaged = true;
            self.pending = false;
        }
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

    /// Offer wheel movement to this pass.
    pub fn postScroll(self: *Context, dy: i8) void {
        self.pending_wheel +|= dy;
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
    /// Take the wheel movement for this pass, if it has not been taken.
    pub fn takeWheel(self: *Context) i8 {
        const value = self.pending_wheel;
        self.pending_wheel = 0;
        return value;
    }

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
        self.pending_key = 0;
        self.pending_wheel = 0;

        if (!self.buttons.left) self.pressed = null;
    }

    /// Repaint everything on the next pass.
    ///
    /// Takes effect at the next `begin`, so a control asking for it mid-pass
    /// gets a whole clean pass rather than half of one.
    pub fn damage(self: *Context) void {
        self.pending = true;
    }

    /// Repaint everything in *this* pass. For a caller that knows before it
    /// starts, such as one that has just been resized.
    pub fn damageNow(self: *Context) void {
        self.damaged = true;
    }

    pub fn pressedThisPass(self: *const Context) bool {
        return self.buttons.left and !self.previous.left;
    }

    pub fn releasedThisPass(self: *const Context) bool {
        return !self.buttons.left and self.previous.left;
    }

    pub fn slotFor(self: *Context, area: Rect) ?*Entry {
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
    // For control authors
    //
    // Controls large enough to live in their own file reach the pass machinery
    // through these. Nothing outside the toolkit should call them.
    // -----------------------------------------------------------------------

    pub fn takeKeyFor(self: *Context, entry: *const Entry) ?u8 {
        return self.takeKey(self.indexOf(entry));
    }

    // -----------------------------------------------------------------------
    // Controls
    // -----------------------------------------------------------------------

    /// What a pass did to a control.
    ///
    /// The pointer and keyboard handling every activatable control shares
    /// lives in one place: a control that gets any part of it subtly wrong is
    /// a control that behaves unlike the rest of the toolkit for no reason a
    /// person could guess.
    pub const Interaction = struct {
        index: usize,
        over: bool,
        /// Held down on itself, so it should look pressed.
        holding: bool,
        focused: bool,
        /// Released on itself, or activated from the keyboard.
        activated: bool,
    };

    pub fn interact(self: *Context, entry: *Entry, area: Rect) Interaction {
        entry.seen = true;
        entry.focusable = true;

        const index = self.indexOf(entry);
        const over = area.contains(self.pointer_x, self.pointer_y);

        if (over and self.pressedThisPass()) {
            self.pressed = index;
            // Clicking also focuses, so the keyboard picks up where the
            // pointer left off rather than somewhere else entirely.
            if (self.focus != index) {
                self.focus = index;
                self.focus_moved = true;
            }
        }

        var activated = over and self.pressed == index and self.releasedThisPass();

        // Enter or Space activates the focused control, which is the whole
        // point of focus existing.
        if (self.takeKey(index)) |code| {
            if (code == @intFromEnum(KeyCode.enter) or code == @intFromEnum(KeyCode.space)) activated = true;
        }

        return .{
            .index = index,
            .over = over,
            .holding = self.pressed == index and self.buttons.left,
            .focused = self.focus == index,
            .activated = activated,
        };
    }

    /// Whether a control has to be drawn this pass.
    ///
    /// One that looks the way it did last pass is left alone, which is what
    /// keeps the damage list short enough to be worth sending.
    pub fn needsPaint(self: *const Context, entry: *const Entry, visual: Visual) bool {
        return visual != entry.visual or self.damaged or self.focus_moved;
    }

    fn hotOr(over: bool, comptime on: Visual, comptime off: Visual) Visual {
        return if (over) on else off;
    }

    /// A push button. Returns true on the pass where it is released, having
    /// been pressed on itself.
    pub fn button(self: *Context, area: Rect, text: []const u8) bool {
        const entry = self.slotFor(area) orelse return false;
        const it = self.interact(entry, area);

        const visual: Visual = if (it.holding) .active else hotOr(it.over, .hot, .idle);
        if (self.needsPaint(entry, visual)) {
            entry.visual = visual;
            paintButton(self.surface, area, text, visual, it.focused);
            self.addDamage(area);
        }

        return it.activated;
    }

    /// One option out of a set where exactly one is chosen, drawn as a button
    /// that stays down. At this size that reads better than a radio dot and
    /// costs no extra width.
    ///
    /// Returns true on the pass where it is picked. The caller owns the
    /// selection, so a group is a loop over the options with `selected` taken
    /// from whatever the caller already stores.
    pub fn toggle(self: *Context, area: Rect, text: []const u8, selected: bool) bool {
        const entry = self.slotFor(area) orelse return false;
        const it = self.interact(entry, area);

        const visual: Visual = if (selected)
            hotOr(it.over, .checked_hot, .checked)
        else if (it.holding)
            .active
        else
            hotOr(it.over, .hot, .idle);

        if (self.needsPaint(entry, visual)) {
            entry.visual = visual;
            paintButton(self.surface, area, text, visual, it.focused);
            self.addDamage(area);
        }

        return it.activated;
    }

    /// A checkbox. `checked` is the caller's state; the returned value is what
    /// it should be after this pass.
    pub fn checkbox(self: *Context, area: Rect, text: []const u8, checked: bool) bool {
        const entry = self.slotFor(area) orelse return checked;
        const it = self.interact(entry, area);

        const value = if (it.activated) !checked else checked;
        const visual: Visual = if (value)
            hotOr(it.over, .checked_hot, .checked)
        else
            hotOr(it.over, .hot, .idle);

        if (self.needsPaint(entry, visual)) {
            entry.visual = visual;
            paintCheckbox(self.surface, area, text, value, it.over, it.focused);
            self.addDamage(area);
        }

        return value;
    }

    /// A scrolling table of rows. Returns the row activated this pass, or null.
    pub fn table(
        self: *Context,
        area: Rect,
        state: *tbl.State,
        columns: []const tbl.Column,
        rows: []const tbl.Row,
    ) ?usize {
        return tbl.run(self, area, state, columns, rows);
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
    const on = visual == .checked or visual == .checked_hot;

    const face = switch (visual) {
        .active => t.surface_pressed,
        .checked, .checked_hot => t.accent,
        .hot => t.surface_hot,
        else => t.surface,
    };
    const ink = if (on) t.accent_text else t.text;

    surface.fill(area, face);
    // A selected control under the pointer takes a stronger edge: there is no
    // lighter accent to shift to, and it still has to answer the pointer.
    surface.frame(area, switch (visual) {
        .checked_hot => t.text,
        else => if (focused) t.accent else t.line,
    });
    surface.textCentred(area, text, ink);

    if (focused) paintFocusRing(surface, area.inset(2), if (on) t.accent_text else t.text_dim);
}

/// A dotted rectangle marking keyboard focus. Dotted rather than solid so it
/// reads as focus rather than as a border the control always had.
fn paintFocusRing(surface: Surface, area: Rect, color: draw.Color) void {
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

    // A filled square rather than a tick: this face carries no check mark, and
    // a glyph the font lacks draws as a notdef box, which reads as an error.
    if (checked) surface.fill(box.inset(3), t.accent_text);

    surface.text(
        box.right() + t.padding,
        area.y + @divTrunc(area.h - draw.Surface.textHeight(), 2),
        text,
        t.text,
    );

    if (focused) paintFocusRing(surface, area, t.text_dim);
}

// ---------------------------------------------------------------------------
// Menu
//
// A list of choices with one highlighted. Two things wanted it, a taskbar
// dropdown and an application launcher, which is the threshold at which it
// stops being drawing and starts being a control.
// ---------------------------------------------------------------------------

pub const ROW_HEIGHT: i32 = 19;

/// One row. A separator is a row that cannot be chosen rather than a special
/// case in the caller: the keyboard has to skip it, the pointer has to ignore
/// it, and both of those are the control's business.
pub const MenuItem = struct {
    label: []const u8 = "",
    kind: Kind = .item,

    pub const Kind = enum { item, separator, disabled };

    pub fn selectable(self: MenuItem) bool {
        return self.kind == .item;
    }
};

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

    pub fn paint(self: *const Menu, surface: Surface, area: Rect, items: []const MenuItem) void {
        const t = theme.current();

        surface.fill(area, t.surface);
        surface.frame(area, t.line);

        for (items, 0..) |item, row| {
            const line = rowRect(area, row);

            if (item.kind == .separator) {
                // A hairline centred in the row, rather than a row of drawn
                // characters: it is a rule, not text, and it should not look
                // like something that could be chosen.
                surface.fill(.{
                    .x = line.x + t.padding,
                    .y = line.y + @divTrunc(line.h, 2),
                    .w = line.w - t.padding * 2,
                    .h = 1,
                }, t.line);
                continue;
            }

            const highlighted = row == self.selected and item.selectable();
            if (highlighted) surface.fill(line, t.accent);

            const clipped = surface.clipped(line);
            clipped.text(
                line.x + t.padding,
                line.y + @divTrunc(line.h - Surface.textHeight(), 2),
                item.label,
                if (highlighted) t.accent_text else if (item.kind == .disabled) t.text_dim else t.text,
            );
        }
    }

    /// Which row a point falls on, or null if it misses the menu or lands on
    /// something that cannot be chosen.
    pub fn rowAt(area: Rect, items: []const MenuItem, x: i32, y: i32) ?usize {
        if (!area.contains(x, y)) return null;
        const row: usize = @intCast(@max(@divTrunc(y - area.y - 1, ROW_HEIGHT), 0));
        if (row >= items.len or !items[row].selectable()) return null;
        return row;
    }

    pub const KeyAction = enum { ignored, moved, chosen, cancelled };

    /// Drive the selection. The caller acts on `chosen`, because only it knows
    /// what the rows mean.
    pub fn key(self: *Menu, code: KeyCode, items: []const MenuItem) KeyAction {
        if (items.len == 0) return .cancelled;

        switch (code) {
            .up => {
                self.step(items, -1);
                return .moved;
            },
            .down => {
                self.step(items, 1);
                return .moved;
            },
            .enter, .space => {
                return if (items[@min(self.selected, items.len - 1)].selectable()) .chosen else .ignored;
            },
            .escape => {
                self.hide();
                return .cancelled;
            },
            else => return .ignored,
        }
    }

    /// Move the selection, skipping anything that cannot be chosen.
    ///
    /// Bounded by the item count so a menu of nothing but separators cannot
    /// spin here forever.
    fn step(self: *Menu, items: []const MenuItem, direction: i32) void {
        const count: i32 = @intCast(items.len);
        var at: i32 = @intCast(@min(self.selected, items.len - 1));

        var tries: i32 = 0;
        while (tries < count) : (tries += 1) {
            at = @mod(at + direction + count, count);
            if (items[@intCast(at)].selectable()) {
                self.selected = @intCast(at);
                return;
            }
        }
    }

    /// Start on the first row that can actually be chosen.
    pub fn showAt(self: *Menu, items: []const MenuItem) void {
        self.open = true;
        self.selected = 0;
        for (items, 0..) |item, i| {
            if (item.selectable()) {
                self.selected = i;
                return;
            }
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
