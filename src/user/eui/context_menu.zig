//! The menu a control opens.
//!
//! Where a menu bar says what a program can do, this says what can be done to
//! the thing under the pointer, or what the settings that bear on it are: both
//! are a short list of rows, so this is the toolkit's menu placed where the
//! click was and closed by the next one.
//!
//! One per program rather than one per control. Two open at once is not a
//! state any interface means to be in, and holding it here means a control
//! that opens one does not have to carry the machinery for keeping it.
//!
//! A row is a command or a setting. A setting keeps its values with it and
//! shows them in the toolkit's own toggle, the one the Settings program fills
//! its rows with, so a value reads the same wherever it is changed from.
//! Choosing either closes the menu.
//!
//! Modal while it is open: the click that chooses a row does not also reach
//! what is behind it, neither does the click that dismisses it, and the keys
//! pressed while it is open are its alone. It closes with the control that
//! opened it, on a pass that does not draw that control.

const std = @import("std");
const draw = @import("draw.zig");
const popover = @import("popover.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

/// Most rows one of these holds. A context menu is the short list of what
/// applies here; anything longer belongs in a menu bar.
pub const MAX_ITEMS = 8;

/// A row of the menu.
pub const Row = union(enum) {
    /// Something to be done: chosen, and the menu closes.
    command: widget.MenuItem,
    /// A setting and the values it may be, one of them at a time, changed
    /// where it stands by the toggle at the end of its row.
    setting: Setting,
    /// A rule across the menu.
    rule,

    /// What the row says, whichever it is.
    pub fn label(self: Row) []const u8 {
        return switch (self) {
            .command => |item| item.label,
            .setting => |setting| setting.label,
            .rule => "",
        };
    }

    /// Whether anything can be chosen on it at all.
    pub fn selectable(self: Row) bool {
        return switch (self) {
            .command => |item| item.selectable(),
            .rule => false,
            .setting => true,
        };
    }
};

/// A setting, as a row of the menu holds one.
pub const Setting = struct {
    label: []const u8 = "",
    /// What it may be, one word each, in the order they are drawn.
    values: []const []const u8 = &.{},
    /// Which of `values` it is now.
    at: usize = 0,

    /// The one after `at`, and the first after the last: what the keyboard
    /// steps a value to, where a pointer picks one out directly.
    pub fn stepped(self: Setting) usize {
        if (self.values.len == 0) return 0;
        return (self.at + 1) % self.values.len;
    }
};

/// What a pass of the menu answered.
pub const Chosen = union(enum) {
    /// The row that was chosen, of the rows it was given.
    row: usize,
    /// A setting's row, and which of its values was chosen.
    value: Pick,
};

/// A setting's value, picked out on the row it is drawn on.
pub const Pick = struct { row: usize, at: usize };

var menu: widget.Menu = .{};
var rows: [MAX_ITEMS]Row = @splat(.rule);
/// The rows as the menu's own machinery sees them: a setting is a row with a
/// label and nothing else, the toggle at its end being drawn over it after.
var items: [MAX_ITEMS]widget.MenuItem = @splat(.{});
var count: usize = 0;
var at_x: i32 = 0;
var at_y: i32 = 0;
/// Which control opened it, so a menu opened over one text field does not
/// answer another one drawn later in the same pass.
var owner: ?usize = null;

pub fn isOpen() bool {
    return owner != null;
}

pub fn openedBy(entry: usize) bool {
    return owner == entry;
}

/// Open at the pointer, listing `wanted`. The rows are copied: a menu
/// outlives the pass that opened it, and what it was given may not.
pub fn open(ctx: *widget.Context, entry: usize, wanted: []const Row) void {
    openAt(ctx.pointer_x, ctx.pointer_y, entry, wanted);
}

/// The same, somewhere in particular: what a control does when the keyboard
/// asks for the menu, since there is no pointer involved in that.
pub fn openAt(x: i32, y: i32, entry: usize, wanted: []const Row) void {
    count = @min(wanted.len, rows.len);
    @memcpy(rows[0..count], wanted[0..count]);
    for (items[0..count], rows[0..count]) |*item, row| item.* = itemOf(row);

    at_x = x;
    at_y = y;
    owner = entry;
    menu.selectFirst(items[0..count]);
}

/// A row as the menu's own machinery sees it.
fn itemOf(row: Row) widget.MenuItem {
    return switch (row) {
        .command => |command| command,
        .setting => |setting| .{ .label = setting.label },
        // A rule is a row that cannot be chosen, as it is everywhere else in
        // the toolkit, so that the keyboard skips it and the pointer does
        // without either of them knowing the shape of the row beside it.
        .rule => .{ .kind = .separator },
    };
}

pub fn close() void {
    owner = null;
}

/// Where it sits: from the pointer, kept on the surface.
pub fn area(surface: Surface) Rect {
    const screen = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };
    const size = widget.Menu.sizeFor(items[0..count], widthOf());
    return popover.place(
        .{ .x = at_x, .y = at_y, .w = 0, .h = 0 },
        size.w,
        size.h,
        screen,
        .below,
    );
}

/// As wide as its widest row, since these rows are short and a fixed width
/// would be wrong for every one of them.
fn widthOf() i32 {
    const t = theme.current();
    var widest: i32 = 0;
    for (items[0..count], rows[0..count]) |item, row| {
        var w = Surface.textWidth(item.label) + widget.markWidth();
        switch (row) {
            .command => if (item.detail.len > 0) {
                w += t.menu_padding * 2 + Surface.textWidth(item.detail);
            },
            .setting => |setting| w += t.menu_padding * 2 + widget.togglesWidth(setting.values),
            .rule => {},
        }
        widest = @max(widest, w);
    }
    return widest + t.menu_padding * 2;
}

/// Draw the setting rows' toggles over the rows the menu has painted, and
/// answer the value one was clicked on, if any was.
fn settings(ctx: *widget.Context, where: Rect) ?Pick {
    const t = theme.current();
    var picked: ?Pick = null;

    for (rows[0..count], 0..) |row, index| {
        const setting = switch (row) {
            .setting => |it| it,
            else => continue,
        };
        const line = menu.itemRect(where, items[0..count], index);
        const wide = widget.togglesWidth(setting.values);
        // A hair shorter than the row, so the row's own highlight reads
        // around the toggle rather than under it.
        const height = @min(t.control_height, line.h - 2);
        const at = Rect{
            .x = line.right() - t.menu_padding - wide,
            .y = line.y + @divTrunc(line.h - height, 2),
            .w = wide,
            .h = height,
        };
        if (ctx.toggles(at, setting.values, setting.at)) |value| {
            picked = .{ .row = index, .at = value };
        }
    }
    return picked;
}

/// The setting the highlight is on, where there is one.
fn settingAt(index: usize) ?Setting {
    if (index >= count) return null;
    return switch (rows[index]) {
        .setting => |setting| setting,
        else => null,
    };
}

/// What the left and right arrows do, which is what they mean on a row of
/// toggles: step the setting the highlight is on to the value beside it.
fn stepped(code: widget.KeyCode) ?Pick {
    const setting = settingAt(menu.selected) orelse return null;
    if (setting.values.len < 2) return null;
    const by: usize = switch (code) {
        .right => 1,
        .left => setting.values.len - 1,
        else => return null,
    };
    return .{ .row = menu.selected, .at = (setting.at + by) % setting.values.len };
}

/// Close it, and say what the pass came to.
fn closed(ctx: *widget.Context, chosen: ?Chosen) ?Chosen {
    close();
    ctx.damage();
    // The click belonged to the menu whether or not it landed on a row.
    ctx.pressed = null;
    return chosen;
}

/// Paint it, over whatever it hangs over.
fn paint(ctx: *widget.Context, where: Rect) void {
    menu.paint(ctx.surface, where, items[0..count]);
    ctx.addDamage(where);
}

/// Draw it and answer the pass. Returns what was chosen, if anything was.
///
/// Called last in a pass, like any menu: it reaches over what is under it, and
/// anything drawn afterwards would draw over the menu instead.
pub fn run(ctx: *widget.Context) ?Chosen {
    if (owner == null) return null;

    const where = area(ctx.surface);

    // The highlight follows the pointer while it moves and the arrow keys
    // while it rests, as the menu bar's dropdowns do.
    if (ctx.pointer_moved) menu.hover(where, items[0..count], ctx.pointer_x, ctx.pointer_y);

    // Painted before the pass is answered, and the toggles over it: a menu
    // that stays open for a value's release is on the screen for it.
    paint(ctx, where);
    if (settings(ctx, where)) |pick| return closed(ctx, .{ .value = pick });

    if (ctx.pressedThisPass() or ctx.rightPressedThisPass()) {
        const under = menu.itemAt(where, items[0..count], ctx.pointer_x, ctx.pointer_y);
        // A press on a setting is its toggle's to answer, and it answers when
        // the press is let go, so the menu stays open for that.
        if (under) |row| if (settingAt(row) != null) return null;
        if (under) |row| if (rows[row].selectable()) return closed(ctx, .{ .row = row });
        return closed(ctx, null);
    }

    // The context keeps the keys pressed while the menu is open apart from
    // the ones for the controls behind it.
    if (ctx.menu_key != .none) {
        switch (menu.key(ctx.menu_key, items[0..count])) {
            .chosen => {
                const row = menu.selected;
                ctx.menu_key = .none;
                // Enter on a setting steps it to the value after the one it
                // has, which is what a pointer does in one press on the
                // toggle beside it.
                if (settingAt(row)) |setting| {
                    return closed(ctx, .{ .value = .{ .row = row, .at = setting.stepped() } });
                }
                return closed(ctx, .{ .row = row });
            },
            .cancelled => {
                ctx.menu_key = .none;
                return closed(ctx, null);
            },
            .moved => ctx.menu_key = .none,
            .ignored => if (stepped(ctx.menu_key)) |pick| {
                ctx.menu_key = .none;
                return closed(ctx, .{ .value = pick });
            },
        }
    }

    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A surface and a context to draw on, with the faces text is measured in.
fn forTesting(pixels: []draw.Color, width: usize) widget.Context {
    draw.useLinked();
    const side: i32 = @intCast(width);
    return .init(Surface.init(pixels.ptr, side, @intCast(@divTrunc(pixels.len, width)), side));
}

test "the keys pressed while it is open are its, and no control's" {
    var pixels: [64 * 64]draw.Color = @splat(.{});
    var ctx = widget.Context.init(Surface.init(&pixels, 64, 64, 64));
    openAt(0, 0, 3, &.{.{ .command = .{ .label = "one" } }});
    defer close();

    ctx.postKey(.down, .{});
    ctx.postText('a');
    try testing.expectEqual(widget.KeyCode.down, ctx.menu_key);
    try testing.expectEqual(widget.KeyCode.none, ctx.pending_key);
    try testing.expectEqual(@as(u32, 0), ctx.pending_text);

    close();
    ctx.postKey(.down, .{});
    try testing.expectEqual(widget.KeyCode.down, ctx.pending_key);
}

test "a setting's row is as wide as its label and its toggle together" {
    // Room for the row as it asks to be: a surface narrower than that places
    // it narrower, which is the screen's say and not the row's.
    var pixels: [320 * 240]draw.Color = @splat(.{});
    var held = forTesting(&pixels, 320);
    const ctx = &held;
    const values = &.{ "off", "on" };
    openAt(0, 0, 0, &.{.{ .setting = .{ .label = "Pictures", .values = values, .at = 1 } }});
    defer close();

    const wanted = Surface.textWidth("Pictures") + widget.markWidth() + widget.togglesWidth(values);
    try testing.expect(area(ctx.surface).w >= wanted);
}

test "the arrows step the setting the highlight is on, and Enter takes it round" {
    var pixels: [64 * 64]draw.Color = @splat(.{});
    var held = forTesting(&pixels, 64);
    const ctx = &held;
    const shades = [_]Row{
        .{ .setting = .{ .label = "Page theme", .values = &.{ "auto", "light", "dark" } } },
    };
    openAt(0, 0, 1, &shades);
    defer close();

    ctx.postKey(.right, .{});
    try testing.expectEqual(Chosen{ .value = .{ .row = 0, .at = 1 } }, run(ctx).?);

    // Stepping closed it, so it is opened again: the last value stepped on
    // comes round to the first.
    openAt(0, 0, 1, &shades);
    ctx.postKey(.enter, .{});
    try testing.expectEqual(Chosen{ .value = .{ .row = 0, .at = 1 } }, run(ctx).?);
}

test "it closes with the control that opened it" {
    var pixels: [64 * 64]draw.Color = @splat(.{});
    var ctx = widget.Context.init(Surface.init(&pixels, 64, 64, 64));
    const key = Rect{ .x = 8, .y = 8, .w = 16, .h = 16 };

    ctx.begin(0, 0, .{});
    const entry = ctx.slotFor(key).?;
    entry.seen = true;
    openAt(key.x, key.bottom(), ctx.indexOf(entry), &.{.{ .command = .{ .label = "one" } }});
    defer close();
    ctx.end();
    try testing.expect(isOpen());

    // A pass that does not draw the control.
    ctx.begin(0, 0, .{});
    ctx.end();
    try testing.expect(!isOpen());
}
