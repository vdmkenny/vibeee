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
const abi = @import("lib").syscalls;
const str = @import("lib").str;
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

    /// Which letter of the label opens it while the modifier is held. The
    /// first by default, which is what File, Edit and View all want and what
    /// anybody looking at a menu bar assumes.
    mnemonic: usize = 0,
};

/// Whether the letter `c` is the mnemonic of `label`, folded for case: a
/// person holding the key presses the letter they see, in whichever case
/// their keyboard is in.
fn mnemonicIs(label: []const u8, at: usize, c: u21) bool {
    if (at >= label.len or c > 0x7F) return false;
    return str.lower(label[at]) == str.lower(@intCast(c));
}



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
    // The letters show while the key that uses them is held, and not
    // otherwise: an underline that is always there is decoration, and one
    // that appears when it becomes useful is an answer.
    const marked = ctx.key_mods.alt;

    for (menus, 0..) |menu, index| {
        const width = Surface.textWidth(menu.label) + t.padding * 3;
        const title = Rect{ .x = x, .y = area.y, .w = width, .h = area.h - 1 };
        const is_open = state.open == index;

        if (titleClicked(ctx, title, menu.label, is_open, if (marked) menu.mnemonic else null)) {
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

/// What a key did to the bar.
pub const KeyResult = union(enum) {
    /// Nothing here wanted it; the caller should pass it on.
    ignored,
    /// The bar acted on it: a menu opened, closed, or the selection moved.
    taken,
    /// An item was chosen, by pressing Enter on it or by its own chord.
    chosen: u16,
};

/// Offer a key to the bar, whether or not a menu is open.
///
/// This is where a program's shortcuts live, because the shortcut is already
/// written next to the command it runs: an item saying `Ctrl+S` is matched
/// from that string rather than from a second table of keycodes in the
/// program, which is the table that goes stale. Nothing above here has to
/// know what a keycode is.
pub fn key(state: *State, code: KeyCode, mods: widget.Modifiers, menus: []const Menu) KeyResult {
    if (state.open == null) {
        // The modifier and a letter open the menu that letter names.
        if (mods.alt) {
            if (abi.letterOf(code)) |letter| {
                if (altKey(state, letter, menus)) return .taken;
            }
        }
        if (mods.control) {
            if (chordOf(code, mods, menus)) |id| return .{ .chosen = id };
        }
        return .ignored;
    }

    const index = state.open.?;
    if (index >= menus.len) return .ignored;

    var storage: [MAX_ITEMS]widget.MenuItem = undefined;
    const rows = rowsOf(menus[index].items, &storage);

    switch (state.list.key(code, rows)) {
        .cancelled => {
            close(state);
            return .taken;
        },
        .chosen => {
            const at = @min(state.list.selected, menus[index].items.len - 1);
            const id = menus[index].items[at].id;
            close(state);
            return .{ .chosen = id };
        },
        .moved => return .taken,
        .ignored => {},
    }

    // Left and right walk the strip, which the list itself has no idea about.
    switch (code) {
        .left => {
            state.open = if (index == 0) menus.len - 1 else index - 1;
            state.list.showAt(rowsOf(menus[state.open.?].items, &storage));
            return .taken;
        },
        .right => {
            state.open = if (index + 1 == menus.len) 0 else index + 1;
            state.list.showAt(rowsOf(menus[state.open.?].items, &storage));
            return .taken;
        },
        else => return .ignored,
    }
}

/// Which item, if any, declares this chord as its shortcut.
fn chordOf(code: KeyCode, mods: widget.Modifiers, menus: []const Menu) ?u16 {
    const letter = abi.letterOf(code) orelse return null;
    for (menus) |menu| {
        for (menu.items) |item| {
            if (item.shortcut.len == 0 or item.kind != .item) continue;
            if (matchesChord(item.shortcut, letter, mods)) return item.id;
        }
    }
    return null;
}

/// Whether a shortcut as written names the key that was pressed.
///
/// Spelled the way it is shown: "Ctrl+S", "Ctrl+Shift+S". The last character
/// is the key and what comes before it is what has to be held.
fn matchesChord(shortcut: []const u8, letter: u8, mods: widget.Modifiers) bool {
    if (shortcut.len == 0) return false;
    if (str.lower(shortcut[shortcut.len - 1]) != letter) return false;

    const wants_shift = str.contains(shortcut, "Shift");
    const wants_ctrl = str.contains(shortcut, "Ctrl");
    const wants_alt = str.contains(shortcut, "Alt");

    return wants_ctrl == mods.control and wants_shift == mods.shift and wants_alt == mods.alt;
}



/// The modifier and a letter: open the menu that letter names.
///
/// Offered before anything else sees the key, since a window whose document
/// takes every character would otherwise take these too. True when a menu was
/// opened, which is the caller's cue to stop passing the key on.
pub fn altKey(state: *State, letter: u21, menus: []const Menu) bool {
    for (menus, 0..) |menu, index| {
        if (!mnemonicIs(menu.label, menu.mnemonic, letter)) continue;

        var storage: [MAX_ITEMS]widget.MenuItem = undefined;
        state.open = index;
        state.list.showAt(rowsOf(menu.items, &storage));
        return true;
    }
    return false;
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
///
/// While the modifier is held the letter that opens it is underlined, which
/// is how a menu bar has always answered the question of which letter that
/// is: shown when it matters and out of the way when it does not.
fn titleClicked(
    ctx: *widget.Context,
    area: Rect,
    label: []const u8,
    open: bool,
    mnemonic: ?usize,
) bool {
    const t = theme.current();
    const over = hovering(ctx, area);

    const face = if (open) t.accent else if (over) t.surface_hot else t.surface;
    const ink = if (open) t.accent_text else t.text;
    ctx.surface.fill(area, face);
    ctx.surface.textCentred(area, label, ink);

    if (mnemonic) |at| {
        if (at < label.len) {
            const text_x = area.x + @divTrunc(area.w - Surface.textWidth(label), 2);
            const before = Surface.textWidth(label[0..at]);
            const letter = Surface.textWidth(label[at .. at + 1]);
            ctx.surface.fill(.{
                .x = text_x + before,
                .y = area.y + @divTrunc(area.h - Surface.textHeight(), 2) + Surface.textHeight(),
                .w = letter,
                .h = 1,
            }, ink);
        }
    }

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
