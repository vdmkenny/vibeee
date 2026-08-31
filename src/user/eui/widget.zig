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

const draw = @import("draw.zig");

const bar = @import("slider.zig");
const gauge = @import("meter.zig");
const icons = @import("icon.zig");
const foot = @import("footer.zig");
const rails = @import("rail.zig");
const theme = @import("theme.zig");
const scroll_mod = @import("scroll.zig");
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

    /// A character this pass, separate from the key that produced it: a text
    /// control wants what the layout made, and everything else wants to know
    /// which key was pressed. Zero for a key that produces no character.
    pending_text: u32 = 0,

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
    /// What this window's ground is painted with on a full redraw.
    ground: Ground = .surface,

    pub fn init(surface: Surface) Context {
        return .{ .surface = surface };
    }

    /// What a window's own ground is painted with when the whole of it has to
    /// be redrawn.
    ///
    /// Here rather than in every program, because every program had the same
    /// line and the way it fails is silent: a window that forgets it shows
    /// whatever the last thing to own those pixels drew, and one that paints
    /// it twice flickers. `.none` is for a program that paints every pixel
    /// itself, which a terminal does.
    pub const Ground = enum { surface, desktop, none };

    pub fn initOn(surface: Surface, ground: Ground) Context {
        return .{ .surface = surface, .ground = ground };
    }

    /// Start a pass. `x`, `y` and `buttons` are the pointer as it is now.
    pub fn begin(self: *Context, x: i32, y: i32, buttons: Buttons) void {
        if (self.pending) {
            self.damaged = true;
            self.pending = false;
        }

        // The ground first, before anything is drawn on it. Inside the pass
        // so it sees the damage this pass was given rather than what the
        // last one finished with.
        if (self.damaged) {
            const t = theme.current();
            switch (self.ground) {
                .surface => self.surface.fill(self.bounds(), t.surface),
                .desktop => self.surface.fill(self.bounds(), t.desktop),
                .none => {},
            }
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

    /// The whole of what this context draws on.
    pub fn bounds(self: *const Context) Rect {
        return .{ .x = 0, .y = 0, .w = self.surface.width, .h = self.surface.height };
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

    /// Offer a typed character to this pass.
    pub fn postText(self: *Context, codepoint: u32) void {
        self.pending_text = codepoint;
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

    /// Finish a pass, releasing state for controls that were not drawn.
    pub fn end(self: *Context) void {
        for (&self.entries) |*e| {
            if (e.used and !e.seen) e.* = .{};
        }
        self.damaged = false;
        self.pending_key = 0;
        self.pending_wheel = 0;
        self.pending_text = 0;

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

    // -----------------------------------------------------------------------
    // For control authors
    //
    // Controls large enough to live in their own file reach the pass machinery
    // through these. Nothing outside the toolkit should call them.
    // -----------------------------------------------------------------------

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

    /// Take the pending key if this control has focus.
    /// Take the wheel movement for this pass, if it has not been taken.
    pub fn takeWheel(self: *Context) i8 {
        const value = self.pending_wheel;
        self.pending_wheel = 0;
        return value;
    }

    /// Take the character for this pass, if `entry` has focus.
    pub fn takeTextFor(self: *Context, entry: *const Entry) ?u32 {
        if (self.focus != self.indexOf(entry) or self.pending_text == 0) return null;
        const cp = self.pending_text;
        self.pending_text = 0;
        return cp;
    }

    fn takeKey(self: *Context, index: usize) ?u8 {
        if (self.focus != index or self.pending_key == 0) return null;
        const code = self.pending_key;
        self.pending_key = 0;
        return code;
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

    pub fn indexOf(self: *const Context, entry: *const Entry) usize {
        return (@intFromPtr(entry) - @intFromPtr(&self.entries)) / @sizeOf(Entry);
    }

    pub fn takeKeyFor(self: *Context, entry: *const Entry) ?u8 {
        return self.takeKey(self.indexOf(entry));
    }

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
        /// Released on itself.
        ///
        /// The keyboard's equivalent is `activatedByKey`, kept separate
        /// because taking the key here would take it from a control that
        /// wanted to read it: a text area needs Enter to mean a new line.
        clicked: bool,
    };

    /// Give the keyboard to whatever control occupies `area`.
    ///
    /// For a window that opens with something already active: a file manager
    /// whose listing does not answer the arrow keys until it has been clicked
    /// is a file manager that looks broken for the first second of its life.
    /// Takes effect on the pass that draws the control there.
    pub fn focusAt(self: *Context, area: Rect) void {
        const entry = self.slotFor(area) orelse return;
        const index = self.indexOf(entry);
        if (self.focus == index) return;
        self.focus = index;
        self.focus_moved = true;
    }

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

        return .{
            .index = index,
            .over = over,
            .holding = self.pressed == index and self.buttons.left,
            .focused = self.focus == index,
            .clicked = over and self.pressed == index and self.releasedThisPass(),
        };
    }

    /// Whether the focused control was activated from the keyboard, which is
    /// the whole point of focus existing.
    ///
    /// Takes the key only when it is one of the two that mean "press this", so
    /// a control that reads the rest itself still gets them.
    pub fn activatedByKey(self: *Context, entry: *const Entry) bool {
        if (self.focus != self.indexOf(entry) or self.pending_key == 0) return false;

        const code = self.pending_key;
        if (code != @intFromEnum(KeyCode.enter) and code != @intFromEnum(KeyCode.space)) {
            return false;
        }
        self.pending_key = 0;
        return true;
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

    // -----------------------------------------------------------------------
    // Controls
    // -----------------------------------------------------------------------

    /// A push button. Returns true on the pass where it is released, having
    /// been pressed on itself.
    pub fn button(self: *Context, area: Rect, text: []const u8) bool {
        const entry = self.slotFor(area) orelse return false;
        const it = self.interact(entry, area);

        const activated = it.clicked or self.activatedByKey(entry);

        const visual: Visual = if (it.holding) .active else hotOr(it.over, .hot, .idle);
        if (self.needsPaint(entry, visual)) {
            entry.visual = visual;
            paintButton(self.surface, area, text, visual, it.focused);
            self.addDamage(area);
        }

        return activated;
    }

    /// One option out of a set where exactly one is chosen, drawn as a button
    /// that stays down. At this size that reads better than a radio dot and
    /// costs no extra width.
    ///
    /// Returns true on the pass where it is picked. The caller owns the
    /// selection, so a group is a loop over the options with `selected` taken
    /// from whatever the caller already stores.
    /// A row of toggles, one per tag of an enum, returning what is chosen
    /// after this pass.
    ///
    /// The type is the list. An enum already says what its choices are, so a
    /// caller naming them beside it would be naming them twice, and a choice
    /// added to the type turns up here without anyone being told.
    ///
    /// Each toggle is as wide as its own name needs: one fixed width either
    /// truncates the longest name or wastes the room the shortest does not use.
    pub fn choice(self: *Context, area: Rect, chosen: anytype) @TypeOf(chosen) {
        return self.choiceOf(area, chosen, &.{});
    }

    /// The same, with the words a person reads rather than the names the
    /// code uses. `labels` is indexed by the enum's own numbering; an empty
    /// list, or one too short, falls back to the tag.
    ///
    /// Two spellings of one list would drift, so the labels come from wherever
    /// the values are declared rather than being written out again here.
    pub fn choiceOf(self: *Context, area: Rect, chosen: anytype, labels: []const []const u8) @TypeOf(chosen) {
        const T = @TypeOf(chosen);
        const gap = theme.current().padding;

        var picked = chosen;
        var x = area.x;

        inline for (@typeInfo(T).@"enum".fields, 0..) |field, i| {
            const text = if (i < labels.len) labels[i] else field.name;
            const width = Surface.textWidth(text) + gap * 3;
            const value: T = @enumFromInt(field.value);
            if (self.toggle(.{ .x = x, .y = area.y, .w = width, .h = area.h }, text, chosen == value)) {
                picked = value;
            }
            x += width + gap;
        }
        return picked;
    }

    /// How a slider is drawn, beyond where it is.
    pub const SliderStyle = struct {
        /// What the filled part takes. The accent unless a caller has a
        /// reason to differ: three channels of a colour read apart when each
        /// is drawn in its own, and read as one control when they are not.
        fill: ?theme.Color = null,
    };

    /// A value along a range: dragged with the pointer, nudged with the
    /// arrows when focused.
    ///
    /// The geometry is `eui.slider`'s, so where the knob is drawn and what a
    /// press at a point asks for are the same arithmetic and the knob never
    /// jumps when it is grabbed.
    ///
    /// Returns what the value is after this pass, so a caller stores what it
    /// gets back the way it does with `choice`.
    pub fn slider(self: *Context, area: Rect, range: bar.Range, value: i32, style: SliderStyle) i32 {
        const entry = self.slotFor(area) orelse return range.clamp(value);
        const it = self.interact(entry, area);

        var next = range.clamp(value);
        // Held anywhere along it, the knob comes to the pointer: on a screen
        // this size, hunting for a nine pixel grip is worse than moving it.
        if (it.holding) next = bar.valueAt(area, range, self.pointer_x);

        if (it.focused and self.pending_key != 0) {
            const code = self.pending_key;
            if (code == @intFromEnum(KeyCode.left)) {
                next = range.clamp(next - bar.step(range));
                self.pending_key = 0;
            } else if (code == @intFromEnum(KeyCode.right)) {
                next = range.clamp(next + bar.step(range));
                self.pending_key = 0;
            }
        }

        const visual: Visual = if (it.holding) .active else hotOr(it.over, .hot, .idle);
        // The value is what the picture is of, so a change to it repaints
        // even when nothing about the pointer moved.
        if (self.needsPaint(entry, visual) or entry.detail != next) {
            entry.visual = visual;
            entry.detail = next;
            paintSlider(self.surface, area, range, next, visual, it.focused, style);
            self.addDamage(area);
        }

        return next;
    }

    pub fn toggle(self: *Context, area: Rect, text: []const u8, selected: bool) bool {
        const entry = self.slotFor(area) orelse return false;
        const it = self.interact(entry, area);

        const activated = it.clicked or self.activatedByKey(entry);

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

        return activated;
    }

    /// A checkbox. `checked` is the caller's state; the returned value is what
    /// it should be after this pass.
    pub fn checkbox(self: *Context, area: Rect, text: []const u8, checked: bool) bool {
        const entry = self.slotFor(area) orelse return checked;
        const it = self.interact(entry, area);

        const value = if (it.clicked or self.activatedByKey(entry)) !checked else checked;
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

    /// A vertical scrollbar. Returns where the view should scroll to.
    pub fn scrollbar(
        self: *Context,
        area: Rect,
        state: *scroll_mod.State,
        at: usize,
        total: usize,
        visible: usize,
    ) usize {
        return scroll_mod.vertical(self, area, state, at, total, visible);
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

    /// A look you can choose, drawn as a small picture of what it does: the
    /// ground it paints the desktop with, the strip its bar takes, and a mark
    /// in its highlight.
    ///
    /// A theme named in words makes somebody try each one to find out what it
    /// is; a tile shows them.
    pub const Sample = struct {
        label: []const u8,
        ground: draw.Color,
        strip: draw.Color,
        mark: draw.Color,
    };

    /// The design's tile, at a hundred per cent.
    pub const SAMPLE_WIDTH: i32 = 52;
    pub const SAMPLE_HEIGHT: i32 = 34;

    pub fn sampleHeight() i32 {
        return theme.enlarged(SAMPLE_HEIGHT) + theme.current().padding + Surface.textHeight();
    }

    /// A row of them. Returns which is chosen, which is `chosen` unless one
    /// was pressed this pass.
    pub fn samples(self: *Context, area: Rect, items: []const Sample, chosen: usize) usize {
        const t = theme.current();
        const tile_w = theme.enlarged(SAMPLE_WIDTH);
        const step = tile_w + t.padding;

        var picked = chosen;
        for (items, 0..) |item, index| {
            const at = Rect{
                .x = area.x + @as(i32, @intCast(index)) * step,
                .y = area.y,
                .w = tile_w,
                .h = sampleHeight(),
            };
            if (at.right() > area.right()) break;

            const entry = self.slotFor(at) orelse continue;
            const it = self.interact(entry, at);
            if (it.clicked or self.activatedByKey(entry)) picked = index;

            const visual: Visual = if (index == chosen)
                hotOr(it.over, .checked_hot, .checked)
            else
                hotOr(it.over, .hot, .idle);

            if (self.needsPaint(entry, visual)) {
                entry.visual = visual;
                paintSample(self.surface, at, item, index == chosen, it.focused);
                self.addDamage(at);
            }
        }
        return picked;
    }

    /// A row of colours to choose from. Returns which one is chosen, which is
    /// `chosen` unless one was pressed this pass.
    ///
    /// Colours rather than names: a person picking a highlight is picking
    /// what it looks like, and a list of words makes them try each one to
    /// find out.
    pub fn swatches(self: *Context, area: Rect, colours: []const draw.Color, chosen: usize) usize {
        const t = theme.current();
        const size = area.h;
        const step = size + t.padding;

        var picked = chosen;
        for (colours, 0..) |colour, index| {
            const at = Rect{
                .x = area.x + @as(i32, @intCast(index)) * step,
                .y = area.y,
                .w = size,
                .h = size,
            };
            if (at.right() > area.right()) break;

            const entry = self.slotFor(at) orelse continue;
            const it = self.interact(entry, at);
            if (it.clicked or self.activatedByKey(entry)) picked = index;

            const visual: Visual = if (index == chosen)
                hotOr(it.over, .checked_hot, .checked)
            else
                hotOr(it.over, .hot, .idle);

            if (self.needsPaint(entry, visual)) {
                entry.visual = visual;
                paintSwatch(self.surface, at, colour, index == chosen, it.over, it.focused);
                self.addDamage(at);
            }
        }
        return picked;
    }

    /// Static text. Repainted only when something has damaged it, since a
    /// label has no state of its own to change.
    /// The column of sections down the side of a window. Returns which one
    /// is chosen, which is `chosen` unless a row was clicked this pass.
    ///
    /// The whole column is drawn here rather than row by row by the caller,
    /// because the ground behind the rows, the hairline down its edge and
    /// the strip at its foot are one thing: a caller that had to remember to
    /// draw the hairline is a caller that will one day forget.
    pub fn rail(self: *Context, area: Rect, items: []const rails.Item, chosen: usize, caption: []const u8) usize {
        const t = theme.current();

        if (self.damaged) {
            self.surface.fill(area, t.surface_pressed);
            self.surface.fill(.{ .x = area.right(), .y = area.y, .w = 1, .h = area.h }, t.line);
            self.paintRailFooter(area, caption);
        }

        var picked = chosen;
        const indented = rails.marked(items);
        for (items, 0..) |item, index| {
            const at = rails.rowRect(area, index);
            const entry = self.slotFor(at) orelse continue;
            const it = self.interact(entry, at);

            if ((it.clicked or self.activatedByKey(entry)) and index != chosen) picked = index;

            const visual: Visual = if (index == chosen)
                hotOr(it.over, .checked_hot, .checked)
            else
                hotOr(it.over, .hot, .idle);

            if (self.needsPaint(entry, visual)) {
                entry.visual = visual;
                paintRailRow(self.surface, at, item, visual, indented, index + 1 < items.len);
                self.addDamage(at);
            }
        }
        return picked;
    }

    /// The strip along the bottom of a window. Returns which action was
    /// pressed, if any.
    ///
    /// `primary` is the one that does the thing the window is for, drawn
    /// filled so it is findable without reading: on a strip of two buttons,
    /// which one is Save should not be a sentence you have to parse.
    pub fn footer(
        self: *Context,
        area: Rect,
        message: []const u8,
        labels: []const []const u8,
        primary: usize,
    ) ?usize {
        const t = theme.current();
        const bar_rect = foot.strip(area);

        if (self.damaged) {
            self.surface.fill(bar_rect, t.bar);
            self.surface.fill(.{ .x = bar_rect.x, .y = bar_rect.y, .w = bar_rect.w, .h = 1 }, t.line);
        }

        var cells: [8]Rect = undefined;
        const buttons = foot.place(bar_rect, labels, &cells);

        self.footerMessage(foot.messageRect(bar_rect, buttons), message);

        var pressed: ?usize = null;
        for (buttons, 0..) |at, index| {
            const entry = self.slotFor(at) orelse continue;
            const it = self.interact(entry, at);
            if (it.clicked or self.activatedByKey(entry)) pressed = index;

            const visual: Visual = if (index == primary)
                hotOr(it.over, .checked_hot, .checked)
            else if (it.holding)
                .active
            else
                hotOr(it.over, .hot, .idle);

            if (self.needsPaint(entry, visual)) {
                entry.visual = visual;
                paintButton(self.surface, at, labels[index], visual, it.focused);
                self.addDamage(at);
            }
        }
        return pressed;
    }

    /// What the window has to say, on the bar's own ground rather than the
    /// window's: the strip is part of the chrome, not part of the pane.
    fn footerMessage(self: *Context, area: Rect, text: []const u8) void {
        const entry = self.slotFor(area) orelse return;
        entry.seen = true;

        const signature = fingerprint(text);
        if (self.damaged or entry.detail != signature) {
            entry.detail = signature;
            const t = theme.current();
            self.surface.fill(area, t.bar);
            self.surface.clipped(area).text(area.x, area.y, text, t.bar_text);
            self.addDamage(area);
        }
    }

    fn paintRailFooter(self: *Context, area: Rect, text: []const u8) void {
        if (text.len == 0) return;
        const t = theme.current();
        const strip = rails.footer(area);
        self.surface.fill(.{ .x = strip.x, .y = strip.y, .w = strip.w, .h = 1 }, t.line);
        self.surface.clipped(strip).text(
            strip.x + t.menu_padding,
            strip.y + t.padding + 1,
            text,
            t.text_dim,
        );
    }

    pub fn label(self: *Context, area: Rect, text: []const u8) void {
        self.labelIn(area, text, theme.current().text);
    }

    /// The same, in the quieter ink: a caption, a unit, the line under a
    /// heading that says what the heading is.
    pub fn labelDim(self: *Context, area: Rect, text: []const u8) void {
        self.labelIn(area, text, theme.current().text_dim);
    }

    pub fn labelIn(self: *Context, area: Rect, text: []const u8, ink: draw.Color) void {
        const entry = self.slotFor(area) orelse return;
        entry.seen = true;

        // Repainted when it has been drawn over, and when what it says has
        // changed: a label showing a count is still a label.
        const signature = fingerprint(text);
        if (self.damaged or entry.detail != signature) {
            entry.detail = signature;
            const t = theme.current();
            self.surface.fill(area, t.surface);
            self.surface.clipped(area).text(area.x, area.y, text, ink);
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
            // An edge, or an empty bar on a pale surface reads as a smudge
            // rather than as a bar with nothing in it.
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

/// A level read rather than set: the fill, the peak it has recently
/// touched, and the mark where it stops being loud.
///
/// Painted rather than run through a pass, because nothing about it answers
/// the pointer. Public for the same reason `paintSlider` is: the bar draws
/// them too and they must be the same picture.
pub fn paintMeter(surface: Surface, area: Rect, level: u8, peak: u8) void {
    const t = theme.current();

    surface.fill(area, t.surface_pressed);
    surface.frame(area, t.line);
    surface.fill(gauge.fill(area, level), if (gauge.over(level)) t.warning else t.accent);
    // The scale mark under the peak, so a peak sitting on the limit is still
    // legible as a peak.
    surface.fill(gauge.limit(area), t.warning);
    surface.fill(gauge.peak(area, peak), if (gauge.over(peak)) t.warning else t.text);
}

/// Public because a slider is wanted in places that have no widget pass to
/// run it: the window manager draws one in a bar menu and reads the pointer
/// itself, and it must be the same picture as the one an application gets.
pub fn paintSlider(surface: Surface, area: Rect, range: bar.Range, value: i32, visual: Visual, focused: bool, style: Context.SliderStyle) void {
    const t = theme.current();

    // The groove, then what is behind the knob, then the knob. Nothing is
    // painted twice: the fill stops where the grip starts.
    const groove = bar.track(area);
    surface.fill(groove, t.surface_pressed);
    surface.frame(groove, t.line);
    surface.fill(bar.filled(area, range, value), style.fill orelse t.accent);

    const grip = bar.knob(area, range, value);
    surface.fill(grip, switch (visual) {
        .active => t.surface_pressed,
        .hot => t.surface_hot,
        else => t.surface,
    });
    surface.frame(grip, if (focused or visual == .active) t.accent else t.border);
}

/// A rail row: a band of colour and a label, with no edge of its own.
///
/// Selection is the strong state and hover is the weak one, so a hovered row
/// that is not selected is only a lighter ground: a rail where hovering looked
/// like choosing would tell you that you had already clicked.
fn paintRailRow(surface: Surface, area: Rect, item: rails.Item, visual: Visual, indented: bool, divider: bool) void {
    const t = theme.current();
    const selected = visual == .checked or visual == .checked_hot;
    const ground = switch (visual) {
        // Already the chosen row: hovering it has nothing left to say.
        .checked, .checked_hot => t.accent,
        .hot => t.surface_hot,
        else => t.surface_pressed,
    };
    const ink = if (selected) t.accent_text else t.text;
    surface.fill(area, ground);

    const clipped = surface.clipped(area);
    if (item.icon) |which| {
        clipped.icon(
            area.x + t.menu_padding,
            area.y + @divTrunc(area.h - Surface.iconSize(), 2),
            which,
            ink,
        );
    }
    clipped.text(
        area.x + t.menu_padding + if (indented) markWidth() else 0,
        area.y + @divTrunc(area.h - Surface.textHeight(), 2),
        item.label,
        ink,
    );

    // A hairline between one section and the next, drawn by the row above it
    // so it is repainted whenever that row is: a divider left behind by a
    // highlight moving away is a line that slowly rubs out.
    if (divider) {
        surface.fill(.{ .x = area.x, .y = area.bottom() - 1, .w = area.w, .h = 1 }, t.line);
    }
}

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
/// The tile: the desktop's ground, the bar's strip across the top, and a
/// block of the highlight sitting on the ground the way a window would.
fn paintSample(surface: Surface, area: Rect, item: Context.Sample, chosen: bool, focused: bool) void {
    const t = theme.current();
    const tile = Rect{
        .x = area.x,
        .y = area.y,
        .w = area.w,
        .h = theme.enlarged(Context.SAMPLE_HEIGHT),
    };

    surface.fill(area, t.surface);

    // The border first, and everything else inside it. Painted the other way
    // round, a bar strip the colour of the border reads as a bar wider than
    // the desktop under it.
    const edge: i32 = if (chosen) 2 else 1;
    surface.fill(tile, if (chosen) t.accent else t.border);

    const inner = tile.inset(edge);
    surface.fill(inner, item.ground);

    const strip = theme.enlarged(7);
    surface.fill(.{ .x = inner.x, .y = inner.y, .w = inner.w, .h = strip }, item.strip);
    surface.fill(.{
        .x = inner.x + theme.enlarged(5),
        .y = inner.y + strip + theme.enlarged(4),
        .w = theme.enlarged(16),
        .h = theme.enlarged(8),
    }, item.mark);

    const label_y = tile.bottom() + t.padding;
    const width = Surface.textWidth(item.label);
    surface.text(
        tile.x + @divTrunc(tile.w - width, 2),
        label_y,
        item.label,
        if (chosen) t.text else t.text_dim,
    );

    if (focused) paintFocusRing(surface, inner, t.accent_text);
}

/// One colour, and whether it is the one in use.
///
/// The mark is a ring around the chosen colour rather than a tick inside it:
/// a tick has to be drawn in something, and on ten different colours there is
/// no something that works on all of them.
fn paintSwatch(surface: Surface, area: Rect, colour: draw.Color, chosen: bool, hot: bool, focused: bool) void {
    const t = theme.current();
    surface.fill(area, t.surface);

    const inner = if (chosen) area.inset(3) else area.inset(1);
    surface.fill(inner, colour);
    surface.frame(inner, t.line);

    if (chosen) surface.borderInset(area, 2, t.text);
    if (!chosen and hot) surface.frame(area, t.text_dim);
    if (focused) paintFocusRing(surface, area.inset(1), t.text);
}

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

/// A cheap hash of what a control would draw, for deciding whether to draw it.
///
/// Comparing the result against last pass is the only check that is both cheap
/// and right for a control whose contents change under it: a table refreshed
/// twice a second, a label showing a count.
pub const Fingerprint = struct {
    value: u32 = 2166136261,

    pub fn text(self: *Fingerprint, bytes: []const u8) void {
        for (bytes) |c| self.byte(c);
        // A separator, so two fields that ran together cannot hash the same as
        // the same characters split differently.
        self.byte(0);
    }

    pub fn number(self: *Fingerprint, value: usize) void {
        var v = value;
        var i: usize = 0;
        while (i < @sizeOf(usize)) : (i += 1) {
            self.byte(@truncate(v));
            v >>= 8;
        }
    }

    pub fn flag(self: *Fingerprint, value: bool) void {
        self.byte(@intFromBool(value));
    }

    fn byte(self: *Fingerprint, c: u8) void {
        self.value = (self.value ^ c) *% 16777619;
    }

    pub fn done(self: *const Fingerprint) i32 {
        return @bitCast(self.value);
    }
};

/// The fingerprint of one string, which is what a label needs.
pub fn fingerprint(bytes: []const u8) i32 {
    var h = Fingerprint{};
    h.text(bytes);
    return h.done();
}

/// How tall one row of a menu is. A theme value rather than a constant,
/// because it is a decision about how the interface feels rather than about
/// what fits.
pub fn rowHeight() i32 {
    return theme.current().menu_row_height;
}

/// A rule is not a row. It is a hairline with a little air either side, and
/// giving it the height of a row is what leaves the items around it looking
/// pushed off centre.
pub const SEPARATOR_HEIGHT: i32 = 9;

/// How tall one item sits.
pub fn heightOf(item: MenuItem) i32 {
    return if (item.kind == .separator) SEPARATOR_HEIGHT else rowHeight();
}

/// One row. A separator is a row that cannot be chosen rather than a special
/// case in the caller: the keyboard has to skip it, the pointer has to ignore
/// it, and both of those are the control's business.
pub const MenuItem = struct {
    label: []const u8 = "",
    kind: Kind = .item,
    /// Drawn right-aligned and dim: the chord that does the same thing. A menu
    /// is where people find out a command has a shortcut.
    detail: []const u8 = "",
    /// A picture before the label: what the row is, or a tick saying it is
    /// the one in use. The column exists for the whole menu or for none of
    /// it, so rows without a picture still line up with the rows that have
    /// one.
    mark: ?icons.Icon = null,

    pub const Kind = enum { item, separator, disabled };

    pub fn selectable(self: MenuItem) bool {
        return self.kind == .item;
    }
};

/// The picture column's width when a menu has one: the icon and the gap
/// after it.
/// The picture column: the icon and the gap after it. A function rather than
/// a constant, because both halves grow with the interface, and the same
/// shape indents anything that puts a picture before its contents.
pub fn markWidth() i32 {
    return Surface.iconSize() + theme.current().gap;
}

pub const Menu = struct {
    /// Which row is highlighted. Survives between passes: a menu that forgot
    /// where the selection was every frame could not be driven by keyboard.
    selected: usize = 0,
    open: bool = false,
    /// What the rows sit on. A role rather than a colour, so it follows the
    /// theme: a column of categories beside a list reads as a separate place
    /// when it is a shade darker, and as one long list when it is not.
    ground: Ground = .surface,
    /// How many columns the rows are dealt into, filling one column before
    /// starting the next.
    ///
    /// One by default, because that is what a menu is. More than one is for a
    /// panel wide enough that a single column of short rows would waste half
    /// of it, which is the launcher's problem once there are ten programs.
    /// Multi-column menus carry no separators: a rule across one column of
    /// two says nothing.
    columns: u8 = 1,

    pub fn show(self: *Menu) void {
        self.open = true;
        self.selected = 0;
    }

    pub fn hide(self: *Menu) void {
        self.open = false;
    }

    /// How large a menu needs to be, so a caller can place it before drawing
    /// it. Takes the items rather than a count, because a rule is shorter
    /// than a row and a menu that assumed otherwise would be too tall by the
    /// difference.
    pub fn sizeFor(items: []const MenuItem, width: i32) Rect {
        return sizeForColumns(items, width, 1);
    }

    pub fn sizeForColumns(items: []const MenuItem, width: i32, columns: u8) Rect {
        if (columns <= 1) {
            var height: i32 = 2;
            for (items) |item| height += heightOf(item);
            return .{ .x = 0, .y = 0, .w = width, .h = height };
        }
        return .{
            .x = 0,
            .y = 0,
            .w = width,
            .h = 2 + @as(i32, @intCast(perColumn(items.len, columns))) * rowHeight(),
        };
    }

    /// How many rows a column holds when `count` items are dealt into
    /// `columns`. The last column is the short one.
    fn perColumn(count: usize, columns: u8) usize {
        if (columns <= 1) return count;
        const cols: usize = columns;
        return (count + cols - 1) / cols;
    }

    /// Move the selection to whatever the pointer is over.
    ///
    /// Called before painting, so the highlight follows the cursor as well as
    /// the arrow keys: a menu whose highlight sat still while the pointer
    /// moved over it looks like a menu that has stopped responding.
    pub fn hover(self: *Menu, area: Rect, items: []const MenuItem, x: i32, y: i32) void {
        if (self.itemAt(area, items, x, y)) |row| self.selected = row;
    }

    pub fn paint(self: *const Menu, surface: Surface, area: Rect, items: []const MenuItem) void {
        const t = theme.current();
        // One row with a picture indents them all, so the labels line up
        // whether or not the row beside them has one.
        const indented = marked(items);

        surface.fill(area, switch (self.ground) {
            .surface => t.surface,
            .sunken => t.surface_pressed,
        });
        surface.frame(area, t.line);

        for (items, 0..) |item, row| {
            const line = self.itemRect(area, items, row);

            if (item.kind == .separator) {
                // A hairline centred in the row, rather than a row of drawn
                // characters: it is a rule, not text, and it should not look
                // like something that could be chosen.
                surface.fill(.{
                    .x = line.x + t.menu_padding,
                    .y = line.y + @divTrunc(line.h, 2),
                    .w = line.w - t.menu_padding * 2,
                    .h = 1,
                }, t.line);
                continue;
            }

            const highlighted = row == self.selected and item.selectable();
            if (highlighted) surface.fill(line, t.accent);

            const baseline = line.y + @divTrunc(line.h - Surface.textHeight(), 2);
            const clipped = surface.clipped(line);
            const ink = if (highlighted) t.accent_text else if (item.kind == .disabled) t.text_dim else t.text;

            if (item.mark) |which| {
                clipped.icon(
                    line.x + t.menu_padding,
                    line.y + @divTrunc(line.h - Surface.iconSize(), 2),
                    which,
                    ink,
                );
            }

            clipped.text(
                line.x + t.menu_padding + if (indented) markWidth() else 0,
                baseline,
                item.label,
                ink,
            );

            if (item.detail.len > 0) {
                clipped.text(
                    line.right() - t.menu_padding - Surface.textWidth(item.detail),
                    baseline,
                    item.detail,
                    if (highlighted) t.accent_text else t.text_dim,
                );
            }
        }
    }

    /// Whether any row carries a picture. A menu of plain rows is not
    /// indented for a column nothing uses.
    fn marked(items: []const MenuItem) bool {
        for (items) |item| {
            if (item.mark != null) return true;
        }
        return false;
    }

    /// Which row a point falls on, or null if it misses the menu or lands on
    /// something that cannot be chosen.
    pub fn rowAt(area: Rect, items: []const MenuItem, x: i32, y: i32) ?usize {
        if (!area.contains(x, y)) return null;

        var top = area.y + 1;
        for (items, 0..) |item, row| {
            const height = heightOf(item);
            if (y < top + height) return if (item.selectable()) row else null;
            top += height;
        }
        return null;
    }

    /// Which item a point falls on, whichever shape the menu has.
    pub fn itemAt(self: *const Menu, area: Rect, items: []const MenuItem, x: i32, y: i32) ?usize {
        if (self.columns <= 1) return rowAt(area, items, x, y);
        if (!area.contains(x, y)) return null;

        for (items, 0..) |item, index| {
            if (cellRect(area, items, self.columns, index).contains(x, y)) {
                return if (item.selectable()) index else null;
            }
        }
        return null;
    }

    pub const Ground = enum { surface, sunken };

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

    fn rowRect(area: Rect, items: []const MenuItem, row: usize) Rect {
        var top = area.y + 1;
        for (items[0..row]) |item| top += heightOf(item);
        return .{ .x = area.x + 1, .y = top, .w = area.w - 2, .h = heightOf(items[row]) };
    }

    /// The same, for a menu dealt into columns. Kept apart from `rowRect`
    /// rather than folded into it: a list and a grid answer differently and
    /// one function pretending to do both is how a hit test starts landing a
    /// column over.
    fn cellRect(area: Rect, items: []const MenuItem, columns: u8, index: usize) Rect {
        const rows = perColumn(items.len, columns);
        const width = @divTrunc(area.w - 2, @as(i32, columns));
        const column: i32 = @intCast(if (rows == 0) 0 else index / rows);
        const row: i32 = @intCast(if (rows == 0) 0 else index % rows);
        return .{
            .x = area.x + 1 + column * width,
            .y = area.y + 1 + row * rowHeight(),
            .w = width,
            .h = rowHeight(),
        };
    }

    /// Where one item is, whichever shape the menu has.
    pub fn itemRect(self: *const Menu, area: Rect, items: []const MenuItem, index: usize) Rect {
        return if (self.columns <= 1)
            rowRect(area, items, index)
        else
            cellRect(area, items, self.columns, index);
    }
};
