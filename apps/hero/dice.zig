//! The dice: Hero's second window, floating over the sheet.
//!
//! A roll is a moment with a few choices in it, which die, how many, what
//! bonus, and for a d20 test whether it is rolled with advantage or
//! disadvantage, and the prompt sheet across the foot of the window has room
//! for one answer, not four. So the dice get a window of their own, opened
//! filled in by whatever asked for the roll: Enter on a skill, a tile's save,
//! an attack, or the Roll menu for anything at all. The window rolls, shows
//! every die that fell and which was kept, and hands the outcome back to the
//! program, which writes the journal line; it never touches the file itself.
//!
//! Its own window rather than a pane, for the reason the file dialog is: the
//! manager already floats and centres a dialog over what raised it, and a
//! roll wants to sit over the sheet it is about, movable, with the sheet
//! still readable behind it.

const std = @import("std");
const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const str = @import("lib").str;
const hero = @import("journal.zig");

const theme = eui.theme;
const Rect = eui.Rect;
const Surface = eui.Surface;

/// The dice a table has. The value is the faces, so the number a die shows
/// is drawn straight from the tag.
pub const Face = enum(u8) {
    d4 = 4,
    d6 = 6,
    d8 = 8,
    d10 = 10,
    d12 = 12,
    d20 = 20,
    d100 = 100,

    pub fn faces(self: Face) u8 {
        return @intFromEnum(self);
    }

    pub fn word(self: Face) []const u8 {
        return @tagName(self);
    }

    /// The die a damage line names, or none for a number of faces no die has.
    pub fn of(count: u8) ?Face {
        return std.enums.fromInt(Face, count);
    }
};

const FACE_WORDS = blk: {
    var words: [std.enums.values(Face).len][]const u8 = undefined;
    for (std.enums.values(Face), 0..) |face, i| words[i] = face.word();
    break :blk words;
};

const MODE_WORDS = [_][]const u8{ "Normal", "Advantage", "Disadvantage" };

comptime {
    std.debug.assert(MODE_WORDS.len == std.enums.values(hero.Roll).len);
}

/// The most dice one roll throws. A fireball is eight; the window shows them
/// all across its width, and a roll beyond it is two rolls.
pub const MAX_DICE = 8;

/// The window's size, which is what its rows add up to at the toolkit's
/// metrics: a title and a line under it, the palette, the two steppers, the
/// modes, the tiles, and the foot.
pub const WIDTH: u16 = 420;
pub const HEIGHT: u16 = 262;

/// What a roll is for. The window shows the words and hands them back with
/// the outcome, so the program can write the line without asking again.
pub const Setup = struct {
    title: []const u8 = "Dice",
    sub: []const u8 = "",
    face: Face = .d20,
    count: u8 = 1,
    bonus: i16 = 0,
    mode: hero.Roll = .normal,
    /// Whether the roll is an attack, which offers its damage next.
    attack: bool = false,
};

/// What fell: the dice as they landed, the one kept where a mode chose,
/// and the total the bonus makes of it.
pub const Outcome = struct {
    title: []const u8,
    face: Face,
    count: u8,
    bonus: i16,
    mode: hero.Roll,
    /// How many dice fell: the count, or two for a d20 test with a mode.
    thrown: u8,
    values: [MAX_DICE]u8,
    /// Which of the values was kept, for a d20 test with a mode; the sum
    /// of them all otherwise.
    kept: ?usize,
    total: i32,

    /// Whether this was a d20 test rather than a handful of dice: one d20,
    /// where advantage and disadvantage mean something.
    pub fn isTest(self: Outcome) bool {
        return self.face == .d20 and self.count == 1;
    }

    /// The die kept, for the journal's `roll` line.
    pub fn die(self: Outcome) u8 {
        return self.values[self.kept orelse 0];
    }

    /// The dice as they fell, `4 6`, for the journal's `dice` line.
    pub fn fallen(self: Outcome, buf: []u8) []const u8 {
        var line = str.Builder{ .buf = buf };
        for (self.values[0..self.thrown], 0..) |v, i| {
            if (i > 0) line.byte(' ');
            line.number(v);
        }
        return line.done();
    }
};

/// What the window is asked for next, once an event has been handled.
pub const Wish = enum { nothing, close, damage };

/// One die, from a generator seeded by the clock the first time it is asked.
var generator: std.Random.DefaultPrng = undefined;
var seeded = false;

pub fn rollDie(faces: u8) u8 {
    if (!seeded) {
        const seed: u64 = @bitCast(sys.realtimeMicros() orelse @as(i64, @intCast(sys.clockMicros())));
        generator = std.Random.DefaultPrng.init(seed);
        seeded = true;
    }
    return generator.random().intRangeAtMost(u8, 1, @max(faces, 1));
}

pub const Window = struct {
    window: u8 = 0,
    showing: bool = false,
    ctx: eui.Context = undefined,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    buttons: eui.widget.Buttons = .{},

    setup: Setup = .{},
    title_storage: [64]u8 = @splat(0),
    sub_storage: [96]u8 = @splat(0),

    /// The last roll, until the next; null before the first.
    outcome: ?Outcome = null,
    /// An outcome the program has not yet taken and written.
    landed: ?Outcome = null,
    wish: Wish = .nothing,
    /// The die glyph in the corner, the program's own picture.
    glyph: ?eui.icon.Glyph = null,

    /// Open the window, or refill it when it is already open.
    pub fn show(self: *Window, connection: *proto.client.Connection, setup: Setup) !void {
        self.setup = setup;
        self.setup.title = keep(&self.title_storage, setup.title);
        self.setup.sub = keep(&self.sub_storage, setup.sub);
        self.setup.count = @max(1, @min(setup.count, MAX_DICE));
        self.outcome = null;
        self.landed = null;
        self.wish = .nothing;

        if (self.showing) {
            self.ctx.damage();
            self.draw(connection);
            return;
        }
        self.window = try connection.createWindow(.{ .dialog = true }, WIDTH, HEIGHT);
        try connection.setTitle(self.window, "Dice");
        self.showing = true;
    }

    pub fn hide(self: *Window, connection: *proto.client.Connection) void {
        if (!self.showing) return;
        connection.destroyWindow(self.window) catch {};
        self.showing = false;
    }

    pub fn owns(self: *const Window, event: proto.wm.Ev) bool {
        return self.showing and event.win == self.window;
    }

    /// The outcome of the last roll, once, for the program to write down.
    pub fn take(self: *Window) ?Outcome {
        defer self.landed = null;
        return self.landed;
    }

    /// Handle one event for the window. What the window wants afterwards is
    /// in `wish`: to be closed, or to be refilled with the attack's damage.
    pub fn handle(self: *Window, connection: *proto.client.Connection, event: proto.wm.Ev) void {
        self.wish = .nothing;
        switch (event.tag) {
            .configure => {
                connection.attach(self.window, event.body.configure.w, event.body.configure.h) catch return;
                const surface = connection.surfaceOf(self.window) orelse return;
                self.ctx = eui.Context.init(surface.*);
                self.ctx.damageNow();
                self.draw(connection);
                connection.map(self.window) catch {};
                return;
            },
            .ptr_motion => {
                self.pointer_x = event.body.motion.x;
                self.pointer_y = event.body.motion.y;
            },
            .ptr_button => {
                self.pointer_x = event.body.button.x;
                self.pointer_y = event.body.button.y;
                switch (event.body.button.btn) {
                    0 => self.buttons.left = event.body.button.down != 0,
                    1 => self.buttons.right = event.body.button.down != 0,
                    2 => self.buttons.middle = event.body.button.down != 0,
                    else => {},
                }
            },
            .scroll => self.ctx.postScroll(event.body.scroll.dy),
            .key => {
                if (event.body.key.down == 0) return;
                // Escape leaves. Enter is the strong button: the roll, and
                // once one has landed, done. Up and down nudge the bonus.
                const code = std.enums.fromInt(sys.KeyCode, event.body.key.code);
                if (code == .escape or (code == .enter and self.outcome != null)) {
                    self.wish = .close;
                    return;
                }
                if (code == .enter) {
                    self.roll();
                } else if (code == .up) {
                    self.setup.bonus +|= 1;
                } else if (code == .down) {
                    self.setup.bonus -|= 1;
                } else {
                    self.ctx.postKey(@intCast(event.body.key.code), @bitCast(event.body.key.mods));
                }
                self.ctx.damage();
            },
            .text => {
                // The letters of the modes, and R to roll again, as the
                // prompt sheet's choices answer to theirs.
                switch (event.body.text.cp) {
                    'r', 'R' => self.roll(),
                    'n', 'N' => self.setMode(.normal),
                    'a', 'A' => self.setMode(.advantage),
                    'd', 'D' => self.setMode(.disadvantage),
                    else => self.ctx.postText(event.body.text.cp),
                }
                self.ctx.damage();
            },
            .theme, .look => {
                _ = connection.adoptLook(event);
                self.ctx.damage();
            },
            .close_req => {
                self.wish = .close;
                return;
            },
            .overflow => self.ctx.damage(),
            else => return,
        }

        self.draw(connection);
        if (self.ctx.wantsPass()) self.draw(connection);
    }

    /// Whether advantage and disadvantage mean anything: one d20.
    fn modesApply(self: *const Window) bool {
        return self.setup.face == .d20 and self.setup.count == 1;
    }

    fn setMode(self: *Window, mode: hero.Roll) void {
        if (self.modesApply()) self.setup.mode = mode;
    }

    /// Throw the dice. A d20 test with a mode throws two and keeps one; a
    /// handful is summed. What fell waits in `landed` for the program.
    fn roll(self: *Window) void {
        const s = self.setup;
        var outcome = Outcome{
            .title = s.title,
            .face = s.face,
            .count = s.count,
            .bonus = s.bonus,
            .mode = if (self.modesApply()) s.mode else .normal,
            .thrown = s.count,
            .values = @splat(0),
            .kept = null,
            .total = 0,
        };
        if (outcome.isTest() and outcome.mode != .normal) {
            outcome.values[0] = rollDie(20);
            outcome.values[1] = rollDie(20);
            outcome.thrown = 2;
            const higher: usize = if (outcome.values[0] >= outcome.values[1]) 0 else 1;
            outcome.kept = if (outcome.mode == .advantage) higher else 1 - higher;
            outcome.total = @as(i32, outcome.values[outcome.kept.?]) + s.bonus;
        } else {
            var sum: i32 = 0;
            for (0..s.count) |i| {
                outcome.values[i] = rollDie(s.face.faces());
                sum += outcome.values[i];
            }
            if (outcome.isTest()) outcome.kept = 0;
            outcome.total = sum + s.bonus;
        }
        self.outcome = outcome;
        self.landed = outcome;
        self.ctx.damage();
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    fn draw(self: *Window, connection: *proto.client.Connection) void {
        const surface = connection.surfaceOf(self.window) orelse return;
        self.ctx.surface = surface.*;
        const ctx = &self.ctx;
        const t = theme.current();
        const whole = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };
        const area = whole.inset(t.padding);

        ctx.begin(self.pointer_x, self.pointer_y, self.buttons);
        if (ctx.damaged) surface.fill(whole, t.surface);

        // The title, with the window's name in the corner, and the line
        // under it that says where the bonus comes from.
        var y = area.y;
        if (ctx.damaged) {
            surface.title(area.x, y, self.setup.title, t.text);
            const name_w = Surface.textWidth("Dice");
            const beside = Surface.besideTitle(y);
            surface.text(area.right() - name_w, beside, "Dice", t.text_dim);
            if (self.glyph) |g| surface.picture(area.right() - name_w - 18, beside + 2, g, t.text_dim);
            surface.text(area.x, y + Surface.titleHeight(), self.setup.sub, t.text_dim);
        }
        y += Surface.titleHeight() + Surface.textHeight() + t.gap;

        // The palette: which die.
        const before_face = self.setup.face;
        self.setup.face = ctx.choiceOf(.{ .x = area.x, .y = y, .w = area.w, .h = t.control_height }, self.setup.face, &FACE_WORDS);
        if (self.setup.face != before_face) self.outcome = null;
        y += t.control_height + t.gap;

        // How many, and the bonus.
        const stepper_w = eui.stepper.width(t.control_height);
        var x = area.x;
        ctx.labelDim(.{ .x = x, .y = y, .w = Surface.textWidth("Dice") + t.gap, .h = t.control_height }, "Dice");
        x += Surface.textWidth("Dice") + t.gap;
        const count = ctx.stepper(.{ .x = x, .y = y, .w = stepper_w, .h = t.control_height }, .{ .min = 1, .max = MAX_DICE }, self.setup.count);
        if (count != self.setup.count) {
            self.setup.count = @intCast(count);
            self.outcome = null;
        }
        x += stepper_w + t.gap * 2;
        ctx.labelDim(.{ .x = x, .y = y, .w = Surface.textWidth("Bonus") + t.gap, .h = t.control_height }, "Bonus");
        x += Surface.textWidth("Bonus") + t.gap;
        const bonus = ctx.stepper(.{ .x = x, .y = y, .w = stepper_w, .h = t.control_height }, .{ .min = -20, .max = 40 }, self.setup.bonus);
        if (bonus != self.setup.bonus) {
            self.setup.bonus = @intCast(bonus);
            self.outcome = null;
        }
        y += t.control_height + t.gap;

        // With: the modes, or the reason there are none.
        const with_w = Surface.textWidth("With") + t.gap;
        ctx.labelDim(.{ .x = area.x, .y = y, .w = with_w, .h = t.control_height }, "With");
        if (self.modesApply()) {
            const before_mode = self.setup.mode;
            self.setup.mode = ctx.choiceOf(.{ .x = area.x + with_w, .y = y, .w = area.w - with_w, .h = t.control_height }, self.setup.mode, &MODE_WORDS);
            if (self.setup.mode != before_mode) self.outcome = null;
        } else {
            ctx.labelDim(.{ .x = area.x + with_w, .y = y, .w = area.w - with_w, .h = t.control_height }, "Advantage and disadvantage are for one d20");
        }
        y += t.control_height + t.gap;

        // The dice as they fell, and the total.
        const foot_y = area.bottom() - t.control_height;
        self.drawDice(surface.*, .{ .x = area.x, .y = y, .w = area.w, .h = foot_y - t.gap - y });

        // The foot: what became of the roll, and the buttons.
        const rolled = self.outcome != null;
        const first: []const u8 = if (rolled) "Roll again" else "Roll";
        const last: []const u8 = if (rolled) "Done" else "Cancel";
        const first_w = eui.footer.buttonWidth(first);
        const last_w = eui.footer.buttonWidth(last);
        var bx = area.right() - last_w;
        if (ctx.buttonAs(.{ .x = bx, .y = foot_y, .w = last_w, .h = t.control_height }, last, if (rolled) .strong else .quiet)) self.wish = .close;
        if (rolled and self.setup.attack) {
            const dmg_w = eui.footer.buttonWidth("Damage");
            bx -= dmg_w + t.gap;
            if (ctx.button(.{ .x = bx, .y = foot_y, .w = dmg_w, .h = t.control_height }, "Damage")) self.wish = .damage;
        }
        bx -= first_w + t.gap;
        if (ctx.buttonAs(.{ .x = bx, .y = foot_y, .w = first_w, .h = t.control_height }, first, if (rolled) .plain else .strong)) self.roll();
        ctx.labelDim(.{ .x = area.x, .y = foot_y, .w = bx - t.gap - area.x, .h = t.control_height }, if (rolled) "In the journal" else "Enter rolls, Escape leaves");

        ctx.end();
        connection.commit(self.window, ctx.damageList()) catch {};
    }

    /// A tile per die, the kept one ringed in the accent and a dropped one
    /// dimmed, then the total and the sum it came from.
    fn drawDice(self: *Window, surface: Surface, area: Rect) void {
        const t = theme.current();
        if (!self.ctx.damaged) return;
        surface.fill(area, t.surface);

        const side: i32 = @min(area.h, 56);
        const shown: usize = if (self.outcome) |o| o.thrown else self.setup.count;
        const tile_w: i32 = if (shown > 5) 40 else side;
        var x = area.x;
        for (0..shown) |i| {
            const box = Rect{ .x = x, .y = area.y, .w = tile_w, .h = side };
            var num: [4]u8 = @splat(0);
            if (self.outcome) |o| {
                const dropped = o.kept != null and o.kept.? != i and o.isTest() and o.mode != .normal;
                surface.fill(box, if (dropped) t.surface else t.surface_hot);
                if (o.kept != null and o.kept.? == i and o.isTest()) {
                    surface.frame(box, t.accent);
                    surface.frame(box.inset(1), t.accent);
                } else {
                    surface.frame(box, t.line);
                }
                const value = str.number(&num, o.values[i], 10, .lower);
                const ink = if (dropped) t.text_dim else t.text;
                surface.title(box.x + @divTrunc(box.w - Surface.titleWidth(value), 2), box.y + 6, value, ink);
                if (o.isTest() and o.mode != .normal) {
                    const cap: []const u8 = if (dropped) "dropped" else "kept";
                    surface.text(box.x + @divTrunc(box.w - Surface.textWidth(cap), 2), box.bottom() - Surface.textHeight() - 4, cap, t.text_dim);
                }
            } else {
                surface.fill(box, t.surface_hot);
                surface.frame(box, t.line);
                const word = self.setup.face.word();
                surface.text(box.x + @divTrunc(box.w - Surface.textWidth(word), 2), box.y + @divTrunc(box.h - Surface.textHeight(), 2), word, t.text_dim);
            }
            x += tile_w + t.gap;
        }

        // The total beside them.
        x += t.gap;
        surface.text(x, area.y, "Total", t.text_dim);
        var sum_buf: [64]u8 = @splat(0);
        if (self.outcome) |o| {
            var total_buf: [8]u8 = @splat(0);
            var total = str.Builder{ .buf = &total_buf };
            total.integer(o.total);
            surface.title(x, area.y + Surface.textHeight(), total.done(), t.text);
            surface.text(x, area.y + Surface.textHeight() + Surface.titleHeight(), self.sumLine(&sum_buf, o), t.text_dim);
        } else {
            surface.title(x, area.y + Surface.textHeight(), "-", t.text_dim);
        }
    }

    /// `17 + 4`, or `4 + 6 + 3`: the sum the total came from.
    fn sumLine(self: *const Window, buf: []u8, o: Outcome) []const u8 {
        _ = self;
        var line = str.Builder{ .buf = buf };
        if (o.kept) |k| {
            line.number(o.values[k]);
        } else {
            for (o.values[0..o.thrown], 0..) |v, i| {
                if (i > 0) line.text(" + ");
                line.number(v);
            }
        }
        if (o.bonus != 0) {
            line.text(if (o.bonus < 0) " - " else " + ");
            line.number(@abs(o.bonus));
        }
        return line.done();
    }
};

/// Copy a caller's words into storage the window owns, since the caller's
/// buffer is rewritten by the next question.
fn keep(storage: []u8, text: []const u8) []const u8 {
    const n = @min(text.len, storage.len);
    @memcpy(storage[0..n], text[0..n]);
    return storage[0..n];
}
