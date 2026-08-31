//! A menu bar: named menus along a strip, each dropping a list of commands.
//!
//! Replaces the row of buttons an application would otherwise grow one of
//! every time it learned to do something. A window 800 pixels wide runs out of
//! room for buttons long before a program runs out of commands, and a menu
//! also gives every command a name, a place and a keyboard route without the
//! application arranging any of it.
//!
//! Built on `widget.Menu`, which already knows how to draw a list and be
//! driven by arrows. What this adds is the strip, which menu is open, and
//! turning a choice back into something the application named.

const draw = @import("draw.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const KeyCode = widget.KeyCode;
const Rect = draw.Rect;
const Surface = draw.Surface;

pub const Item = struct {
    label: []const u8,
    /// What the application calls this command. Returned when it is chosen, so
    /// the application switches on its own names rather than on row numbers
    /// that shift whenever a menu gains an entry.
    id: u16 = 0,
    kind: widget.MenuItem.Kind = .item,
    /// The chord that does the same thing, shown right-aligned. A menu is
    /// where people learn shortcuts.
    shortcut: []const u8 = "",

    pub const separator = Item{ .label = "", .kind = .separator };
};

pub const Menu = struct {
    label: []const u8,
    items: []const Item,
};

/// Most items one menu may hold, which bounds the row array built per pass.
pub const MAX_ITEMS = 16;

pub const State = struct {
    /// Which menu is dropped down, if any.
    open: ?usize = null,
    list: widget.Menu = .{},
    /// Set while the bar has keyboard focus, so arrows walk the menus rather
    /// than reaching whatever is below.
    focused: bool = false,
};

/// Draw the bar and run whatever is open. Returns the id chosen this pass.
///
/// Call it last in a pass: an open menu reaches over the window below it, and
/// anything drawn afterwards would draw over the menu instead.
pub fn run(ctx: *widget.Context, area: Rect, state: *State, menus: []const Menu) ?u16 {
    const t = theme.current();
    ctx.surface.fill(area, t.surface);
    ctx.surface.fill(.{ .x = area.x, .y = area.bottom() - 1, .w = area.w, .h = 1 }, t.line);

    var chosen: ?u16 = null;
    var x = area.x + t.padding;
    var storage: [MAX_ITEMS]widget.MenuItem = undefined;

    for (menus, 0..) |menu, index| {
        const width = Surface.textWidth(menu.label) + t.padding * 3;
        const title = Rect{ .x = x, .y = area.y, .w = width, .h = area.h - 1 };
        const is_open = state.open == index;

        if (titleClicked(ctx, title, menu.label, is_open)) {
            if (is_open) {
                close(state);
            } else {
                state.open = index;
                state.list.showAt(rowsOf(menu.items, &storage));
            }
        } else if (state.open != null and !is_open and hovering(ctx, title)) {
            // With one menu open, moving across the strip opens the next. What
            // every menu bar does, and what makes browsing them possible.
            state.open = index;
            state.list.showAt(rowsOf(menu.items, &storage));
        }

        if (is_open) chosen = dropdown(ctx, title, state, menu);
        x += width;
    }

    return chosen;
}

/// Offer a key to the bar. True when it was taken, so the caller knows not to
/// pass it on.
pub fn key(state: *State, code: KeyCode, menus: []const Menu) bool {
    const index = state.open orelse return false;
    if (index >= menus.len) return false;

    var storage: [MAX_ITEMS]widget.MenuItem = undefined;
    const rows = rowsOf(menus[index].items, &storage);

    switch (state.list.key(code, rows)) {
        .cancelled => {
            close(state);
            return true;
        },
        .moved, .chosen => return true,
        .ignored => {},
    }

    // Left and right walk the strip, which the list itself has no idea about.
    switch (code) {
        .left => {
            state.open = if (index == 0) menus.len - 1 else index - 1;
            state.list.showAt(rowsOf(menus[state.open.?].items, &storage));
            return true;
        },
        .right => {
            state.open = if (index + 1 == menus.len) 0 else index + 1;
            state.list.showAt(rowsOf(menus[state.open.?].items, &storage));
            return true;
        },
        else => return false,
    }
}

/// Open the first menu, for the key that summons the bar.
pub fn focus(state: *State, menus: []const Menu) void {
    if (menus.len == 0) return;
    state.open = 0;
    var storage: [MAX_ITEMS]widget.MenuItem = undefined;
    state.list.showAt(rowsOf(menus[0].items, &storage));
}

pub fn isOpen(state: *const State) bool {
    return state.open != null;
}

fn close(state: *State) void {
    state.open = null;
    state.list.hide();
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

/// The application's items as the list control's, which is a different type
/// because an application names its commands and the list only draws them.
fn rowsOf(items: []const Item, out: *[MAX_ITEMS]widget.MenuItem) []widget.MenuItem {
    const n = @min(items.len, MAX_ITEMS);
    for (items[0..n], 0..) |item, i| {
        out[i] = .{ .label = item.label, .kind = item.kind, .detail = item.shortcut };
    }
    return out[0..n];
}

fn hovering(ctx: *const widget.Context, area: Rect) bool {
    return area.contains(ctx.pointer_x, ctx.pointer_y);
}

/// A menu title in the strip. Drawn directly rather than as a button: it
/// stays down while its menu is open, and a button has no such state.
fn titleClicked(ctx: *widget.Context, area: Rect, label: []const u8, open: bool) bool {
    const t = theme.current();
    const over = hovering(ctx, area);

    const face = if (open) t.accent else if (over) t.surface_hot else t.surface;
    ctx.surface.fill(area, face);
    ctx.surface.textCentred(area, label, if (open) t.accent_text else t.text);
    ctx.addDamage(area);

    return over and ctx.pressedThisPass();
}

fn dropdown(ctx: *widget.Context, title: Rect, state: *State, menu: Menu) ?u16 {
    var storage: [MAX_ITEMS]widget.MenuItem = undefined;
    const rows = rowsOf(menu.items, &storage);

    const width = @max(widest(menu) + theme.current().padding * 6, title.w);
    var area = widget.Menu.sizeFor(rows, width);
    area.x = title.x;
    area.y = title.bottom();

    state.list.paint(ctx.surface, area, rows);
    ctx.addDamage(area);

    if (ctx.pressedThisPass()) {
        // A click outside dismisses rather than doing two things at once,
        // which is what makes an open menu modal.
        const row = widget.Menu.rowAt(area, rows, ctx.pointer_x, ctx.pointer_y) orelse {
            if (!hovering(ctx, title)) close(state);
            return null;
        };
        close(state);
        return menu.items[row].id;
    }

    if (ctx.pending_key != 0) {
        const code: KeyCode = @enumFromInt(ctx.pending_key);
        if (code == .enter or code == .space) {
            const row = @min(state.list.selected, menu.items.len - 1);
            if (menu.items[row].kind == .item) {
                ctx.pending_key = 0;
                close(state);
                return menu.items[row].id;
            }
        }
    }

    return null;
}

fn widest(menu: Menu) i32 {
    var out: i32 = 0;
    for (menu.items) |item| {
        var w = Surface.textWidth(item.label);
        if (item.shortcut.len > 0) w += Surface.textWidth(item.shortcut) + 24;
        out = @max(out, w);
    }
    return out;
}
