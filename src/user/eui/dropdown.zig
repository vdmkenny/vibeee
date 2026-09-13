//! A list to choose one entry from, closed until it is asked for.
//!
//! Where a row of toggles shows every value a setting may be, a list of more
//! than a few entries, or of entries a page wrote rather than the program,
//! is shown closed: a button that says the entry chosen, with the mark a
//! sorted column carries at its end saying there is a list under it. Pressed,
//! or given Enter or Space, it opens the list below itself, in the toolkit's
//! own menu, the chosen entry ticked; a row pressed or Enter on one chooses
//! it and closes the list, and a press anywhere else, or Escape, closes it
//! with the choice as it was. A list longer than the rows shown is scrolled,
//! by the keys, the wheel, or the bar at its side.
//!
//! One per program rather than one per control, as the context menu is: two
//! open at once is not a state any interface means to be in. The entries
//! are the caller's, and stay so while the list is open, which is as long as
//! the control that opened it is drawn: a control that goes takes its list
//! with it. The list is run and painted at the end of every pass, over
//! whatever the pass drew, so a program that draws a dropdown has nothing
//! more to do than draw it.
//!
//! Modal while it is open, as the context menu is: the press that chooses
//! a row does not also reach what is behind it, neither does the press that
//! dismisses it, and the keys pressed while it is open are its alone.

const std = @import("std");
const draw = @import("draw.zig");
const icons = @import("icon.zig");
const popover = @import("popover.zig");
const scroll = @import("scroll.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

/// The most entries a list offers; one given more offers its first this
/// many. A page's list of countries is a couple of hundred.
pub const ENTRIES_MAX = 256;

/// The most rows the open list shows at once, the rest being scrolled to.
pub const ROWS_MAX = 8;

var menu: widget.Menu = .{};
var items: [ENTRIES_MAX]widget.MenuItem = @splat(.{});
var count: usize = 0;
/// The first row shown, where the list is longer than the rows shown.
var first: usize = 0;
/// The row the highlight is on, among all the entries.
var at: usize = 0;
/// Where the control that opened the list is, which the list hangs under.
var anchor: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
/// Which control opened it, so the list closes with the control and answers
/// no other one drawn later in the same pass.
var owner: ?usize = null;
/// What was chosen, until the control that opened the list takes it on its
/// next pass.
var picked: ?Pick = null;
var bar: scroll.State = .{};

const Pick = struct { owner: usize, index: usize };

pub fn isOpen() bool {
    return owner != null;
}

pub fn openedBy(entry: usize) bool {
    return owner == entry;
}

pub fn close() void {
    owner = null;
}

/// The control: a button saying `entries[chosen]`, which opens the list of
/// them. Returns which entry is chosen after this pass, which is `chosen`
/// unless the list was chosen from since the control was last drawn. The
/// entries are the caller's, and stay so while the list is open.
pub fn run(ctx: *widget.Context, where: Rect, entries: []const []const u8, chosen: usize) usize {
    const entry = ctx.slotFor(where) orelse return chosen;
    const it = ctx.interact(entry, where);
    const index = ctx.indexOf(entry);

    var value = if (entries.len == 0) 0 else @min(chosen, entries.len - 1);
    if (picked) |pick| {
        if (pick.owner == index) {
            value = pick.index;
            picked = null;
        }
    }

    if (it.clicked or ctx.activatedByKey(entry)) {
        if (owner == index) close() else open(index, where, entries, value);
    }

    const opened = owner == index;
    const visual: widget.Visual = if (it.holding or opened) .active else if (it.over) .hot else .idle;
    // What it says is how it looks as much as the pointer is: a choice made
    // on the list is a repaint like any other.
    const look: i32 = @intCast(@min(value, std.math.maxInt(i32)));
    if (ctx.needsPaint(entry, visual) or entry.detail != look) {
        entry.visual = visual;
        entry.detail = look;
        paint(ctx.surface, where, if (value < entries.len) entries[value] else "", visual, it.focused);
        ctx.addDamage(where);
    }
    return value;
}

/// How tall the control is drawn: the height every control has.
pub fn height() i32 {
    return theme.current().control_height;
}

/// How wide the control needs to be to say its widest entry whole, with the
/// mark at its end.
pub fn widthFor(entries: []const []const u8) i32 {
    const t = theme.current();
    var widest: i32 = 0;
    for (entries) |text| widest = @max(widest, Surface.textWidth(text));
    return widest + t.padding * 2 + widget.markWidth();
}

/// Open the list under `where`, the control at `index`, with `chosen` ticked.
fn open(index: usize, where: Rect, entries: []const []const u8, chosen: usize) void {
    count = @min(entries.len, items.len);
    for (items[0..count], entries[0..count], 0..) |*item, text, i| {
        item.* = .{ .label = text, .mark = if (i == chosen) .check else null };
    }
    anchor = where;
    owner = index;
    at = if (count == 0) 0 else @min(chosen, count - 1);
    first = at -| (shown() - 1);
    bar = .{};
}

/// How many rows the open list shows.
fn shown() usize {
    return @min(count, ROWS_MAX);
}

/// The rows on show.
fn onShow() []const widget.MenuItem {
    return items[first..][0..shown()];
}

/// Where the list sits: under the control, kept on the surface, as wide as
/// the control or as its widest entry needs.
pub fn area(surface: Surface) Rect {
    const t = theme.current();
    var widest: i32 = anchor.w;
    for (items[0..count]) |item| {
        widest = @max(widest, Surface.textWidth(item.label) + widget.markWidth() + t.menu_padding * 2 + scroll.WIDTH);
    }
    const screen = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };
    const size = widget.Menu.sizeFor(onShow(), widest);
    return popover.place(anchor, size.w, size.h, screen, .below);
}

/// Where the bar that scrolls a long list stands, inside the list's edge.
fn barRect(where: Rect) Rect {
    return .{ .x = where.right() - 1 - scroll.WIDTH, .y = where.y + 1, .w = scroll.WIDTH, .h = where.h - 2 };
}

/// Bring the highlight to `row`, and the rows shown along with it.
fn highlight(row: usize) void {
    if (count == 0) return;
    at = @min(row, count - 1);
    if (at < first) first = at;
    if (at >= first + shown()) first = at + 1 - shown();
}

/// Close the list, and say what the pass came to: the row chosen, or none.
fn closed(ctx: *widget.Context, chosen: ?usize) void {
    if (chosen) |row| picked = .{ .owner = owner.?, .index = row };
    close();
    ctx.damage();
    // The press belonged to the list whether or not it landed on a row.
    ctx.pressed = null;
}

/// Run the open list, if there is one, and paint it. Called at the end of
/// every pass by the context, so that it reaches over what the pass drew.
pub fn finish(ctx: *widget.Context) void {
    if (owner == null) return;
    if (count == 0) return closed(ctx, null);

    var where = area(ctx.surface);
    const long = count > shown();

    // The wheel over the list moves the rows shown; the bar beside them
    // moves them too, and is a control of its own.
    if (where.contains(ctx.pointer_x, ctx.pointer_y)) {
        const turned = ctx.takeWheel();
        if (turned != 0) {
            const most = count - shown();
            first = @intCast(std.math.clamp(@as(i32, @intCast(first)) + turned, 0, @as(i32, @intCast(most))));
        }
    }
    if (long) first = ctx.scrollbar(barRect(where), &bar, first, count, shown());
    first = @min(first, count - shown());
    if (at < first or at >= first + shown()) at = first;
    where = area(ctx.surface);

    // The highlight follows the pointer while it moves and the keys while
    // it rests, as the menu bar's dropdowns do. Both are answered before
    // the list is painted, so that what is painted is where they left it.
    if (ctx.pointer_moved) {
        if (menu.itemAt(where, onShow(), ctx.pointer_x, ctx.pointer_y)) |row| at = first + row;
    }
    if (ctx.pressedThisPass() or ctx.rightPressedThisPass()) {
        if (!(long and barRect(where).contains(ctx.pointer_x, ctx.pointer_y))) {
            if (menu.itemAt(where, onShow(), ctx.pointer_x, ctx.pointer_y)) |row| return closed(ctx, first + row);
            return closed(ctx, null);
        }
    }

    // The context keeps the keys pressed while the list is open apart from
    // the ones for the controls behind it.
    const key = ctx.menu_key;
    ctx.menu_key = .none;
    switch (key) {
        .up => highlight(at -| 1),
        .down => highlight(at + 1),
        .page_up => highlight(at -| shown()),
        .page_down => highlight(at + shown()),
        .home => highlight(0),
        .end => highlight(count - 1),
        .enter, .space => return closed(ctx, at),
        .escape => return closed(ctx, null),
        else => {},
    }

    where = area(ctx.surface);
    menu.selected = at - first;
    menu.paint(ctx.surface, where, onShow());
    if (long) {
        // Painted over the rows, which the menu painted whole.
        _ = ctx.scrollbar(barRect(where), &bar, first, count, shown());
    }
    ctx.addDamage(where);
}

/// The closed control: a button's face and edge, its entry at the left and
/// the mark at the right.
fn paint(surface: Surface, where: Rect, text: []const u8, visual: widget.Visual, focused: bool) void {
    const t = theme.current();
    const face = switch (visual) {
        .active => t.surface_pressed,
        .hot => t.surface_hot,
        else => t.surface,
    };
    surface.fillRounded(where, t.corner_radius, .all, face);
    surface.frameRounded(where, t.corner_radius, .all, if (focused) t.accent else t.line);

    const mark = widget.markWidth();
    const baseline = where.y + @divTrunc(where.h - Surface.textHeight(), 2);
    const room = where.w - t.padding * 2 - mark;
    if (room > 0) surface.textFitted(where.x + t.padding, baseline, room, text, t.text);
    surface.icon(where.right() - t.padding - Surface.iconSize(), Surface.iconTopFor(baseline), .sort_down, t.text);

    if (focused) widget.paintFocusRing(surface, where.inset(2), t.text_dim);
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

const fruit = [_][]const u8{ "apple", "pear", "plum", "fig", "date", "lime", "kiwi", "yuzu", "sloe", "quince" };

/// A pass with the control drawn at `where`, saying `chosen`.
fn pass(ctx: *widget.Context, where: Rect, chosen: usize, buttons: widget.Buttons) usize {
    ctx.begin(where.x + 4, where.y + 4, buttons);
    const value = run(ctx, where, &fruit, chosen);
    ctx.end();
    return value;
}

test "a press on the control opens the list, and one on a row chooses it" {
    var pixels: [320 * 240]draw.Color = @splat(.{});
    var held = forTesting(&pixels, 320);
    const ctx = &held;
    const where = Rect{ .x = 8, .y = 8, .w = 120, .h = 24 };

    try testing.expectEqual(@as(usize, 1), pass(ctx, where, 1, .{}));
    _ = pass(ctx, where, 1, .{ .left = true });
    try testing.expect(!isOpen());
    // Released on itself: the list opens, with the chosen entry ticked.
    _ = pass(ctx, where, 1, .{});
    try testing.expect(isOpen());
    try testing.expectEqual(@as(?icons.Icon, .check), items[1].mark);

    // A press on the third row, which is under the second, chooses it: the
    // control says so on its next pass.
    const list = area(ctx.surface);
    const row = menu.itemRect(list, onShow(), 2);
    ctx.begin(row.x + 4, row.y + 4, .{ .left = true });
    _ = run(ctx, where, &fruit, 1);
    ctx.end();
    try testing.expect(!isOpen());
    try testing.expectEqual(@as(usize, 2), pass(ctx, where, 1, .{}));
}

test "the keys walk the list and take a row, and Escape leaves the choice as it was" {
    var pixels: [320 * 240]draw.Color = @splat(.{});
    var held = forTesting(&pixels, 320);
    const ctx = &held;
    const where = Rect{ .x = 8, .y = 8, .w = 120, .h = 24 };
    _ = pass(ctx, where, 0, .{});
    _ = pass(ctx, where, 0, .{ .left = true });
    _ = pass(ctx, where, 0, .{});
    try testing.expect(isOpen());

    ctx.postKey(.down, .{});
    _ = pass(ctx, where, 0, .{});
    ctx.postKey(.down, .{});
    _ = pass(ctx, where, 0, .{});
    try testing.expectEqual(@as(usize, 2), at);
    ctx.postKey(.enter, .{});
    _ = pass(ctx, where, 0, .{});
    try testing.expect(!isOpen());
    try testing.expectEqual(@as(usize, 2), pass(ctx, where, 0, .{}));

    _ = pass(ctx, where, 2, .{ .left = true });
    _ = pass(ctx, where, 2, .{});
    try testing.expect(isOpen());
    ctx.postKey(.up, .{});
    _ = pass(ctx, where, 2, .{});
    ctx.postKey(.escape, .{});
    _ = pass(ctx, where, 2, .{});
    try testing.expect(!isOpen());
    try testing.expectEqual(@as(usize, 2), pass(ctx, where, 2, .{}));
}

test "a long list shows a few rows and scrolls to keep the highlight among them" {
    var pixels: [320 * 240]draw.Color = @splat(.{});
    var held = forTesting(&pixels, 320);
    const ctx = &held;
    const where = Rect{ .x = 8, .y = 8, .w = 120, .h = 24 };
    _ = pass(ctx, where, 9, .{});
    _ = pass(ctx, where, 9, .{ .left = true });
    _ = pass(ctx, where, 9, .{});
    try testing.expect(isOpen());
    try testing.expectEqual(@as(usize, ROWS_MAX), shown());
    // Opened on the last entry, the rows shown end with it.
    try testing.expectEqual(fruit.len - ROWS_MAX, first);
    ctx.postKey(.home, .{});
    _ = pass(ctx, where, 9, .{});
    try testing.expectEqual(@as(usize, 0), first);
    try testing.expectEqual(@as(usize, 0), at);
    close();
}

test "it closes with the control that opened it" {
    var pixels: [320 * 240]draw.Color = @splat(.{});
    var held = forTesting(&pixels, 320);
    const ctx = &held;
    const where = Rect{ .x = 8, .y = 8, .w = 120, .h = 24 };
    _ = pass(ctx, where, 0, .{});
    _ = pass(ctx, where, 0, .{ .left = true });
    _ = pass(ctx, where, 0, .{});
    try testing.expect(isOpen());

    // A pass that does not draw the control.
    ctx.begin(0, 0, .{});
    ctx.end();
    try testing.expect(!isOpen());
}
