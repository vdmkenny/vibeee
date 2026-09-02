//! The menu the other mouse button opens.
//!
//! Where a menu bar says what a program can do, this says what can be done to
//! the thing under the pointer. Both are the same list of rows, so this is the
//! toolkit's menu placed where the click was and closed by the next one.
//!
//! One per program rather than one per control. Two open at once is not a
//! state any interface means to be in, and holding it here means a control
//! that opens one does not have to carry the machinery for keeping it.
//!
//! Modal while it is open: the click that chooses a row does not also reach
//! what is behind it, and neither does the click that dismisses it.

const draw = @import("draw.zig");
const popover = @import("popover.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

/// Most rows one of these holds. A context menu is the short list of what
/// applies here; anything longer belongs in a menu bar.
pub const MAX_ITEMS = 8;

var menu: widget.Menu = .{};
var items: [MAX_ITEMS]widget.MenuItem = @splat(.{});
var count: usize = 0;
var at_x: i32 = 0;
var at_y: i32 = 0;
/// Which control opened it, so a menu opened over one text field does not
/// answer another one drawn later in the same pass.
var owner: ?usize = null;

pub fn isOpen() bool {
    return menu.open;
}

pub fn openedBy(entry: usize) bool {
    return menu.open and owner == entry;
}

/// Open at the pointer, listing `rows`. The rows are copied: a menu outlives
/// the pass that opened it, and what it was given may not.
pub fn open(ctx: *widget.Context, entry: usize, rows: []const widget.MenuItem) void {
    openAt(ctx.pointer_x, ctx.pointer_y, entry, rows);
}

/// The same, somewhere in particular: what a control does when the keyboard
/// asks for the menu, since there is no pointer involved in that.
pub fn openAt(x: i32, y: i32, entry: usize, rows: []const widget.MenuItem) void {
    count = @min(rows.len, items.len);
    @memcpy(items[0..count], rows[0..count]);

    at_x = x;
    at_y = y;
    owner = entry;
    menu.selected = 0;
    menu.show();
}

pub fn close() void {
    menu.hide();
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
    for (items[0..count]) |item| {
        var w = Surface.textWidth(item.label) + widget.markWidth();
        if (item.detail.len > 0) w += t.menu_padding * 2 + Surface.textWidth(item.detail);
        widest = @max(widest, w);
    }
    return widest + t.menu_padding * 2;
}

/// Draw it and answer the pass. Returns the row chosen, if one was.
///
/// Called last in a pass, like any menu: it reaches over what is under it, and
/// anything drawn afterwards would draw over the menu instead.
pub fn run(ctx: *widget.Context) ?usize {
    if (!menu.open) return null;

    const where = area(ctx.surface);
    var chosen: ?usize = null;

    // The highlight follows the pointer while it moves and the arrow keys
    // while it rests, as the menu bar's dropdowns do.
    if (ctx.pointer_moved) menu.hover(where, items[0..count], ctx.pointer_x, ctx.pointer_y);

    if (ctx.pressedThisPass() or ctx.rightPressedThisPass()) {
        chosen = menu.itemAt(where, items[0..count], ctx.pointer_x, ctx.pointer_y);
        close();
        ctx.damage();
        // The click belonged to the menu whether or not it landed on a row.
        ctx.pressed = null;
        return chosen;
    }

    if (ctx.pending_key != 0) {
        const code: widget.KeyCode = @enumFromInt(ctx.pending_key);
        switch (menu.key(code, items[0..count])) {
            .chosen => {
                chosen = menu.selected;
                ctx.pending_key = 0;
                close();
                ctx.damage();
                return chosen;
            },
            .cancelled => {
                ctx.pending_key = 0;
                close();
                ctx.damage();
                return null;
            },
            .moved => ctx.pending_key = 0,
            .ignored => {},
        }
    }

    menu.paint(ctx.surface, where, items[0..count]);
    ctx.addDamage(where);
    return null;
}
