//! The taskbar: what is open, where, and what the machine is doing.
//!
//! One tab per desktop, named after the window last used there rather than
//! numbered. A number tells you nothing about what is behind it; a name tells
//! you whether it is the thing you are looking for, which is the only question
//! anyone asks of a taskbar.
//!
//! A desktop holding more than one window shows a stack marker and opens a
//! menu of them. Choosing one switches desktop and focuses that window in a
//! single action, because those are never separately wanted.
//!
//! Server-drawn rather than a client: it is furniture, it must stay correct
//! while a client is wedged, and giving it a surface of its own would cost a
//! megabyte and a half to save nothing. design/10-gui.md §4.4.

const std = @import("std");
const draw = @import("eui").draw;
const layout = @import("layout.zig");
const str = @import("ulib").str;
const sys = @import("sys");
const theme = @import("eui").theme;

const ui = @import("eui").widget;

const glyphs = @import("lib").font.glyphs;
const settings = @import("config.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

/// Where the strip sits. One function answers it and everything else asks,
/// because the bar's position appears in painting, in hit testing, in where a
/// menu drops and in how much room the tiles get, and four copies of that
/// arithmetic is four chances to disagree.
pub fn strip(screen_h: i32) Rect {
    const height = theme.current().bar_height;
    return switch (settings.current().bar) {
        .top => .{ .x = 0, .y = 0, .w = 0, .h = height },
        .bottom => .{ .x = 0, .y = screen_h - height, .w = 0, .h = height },
    };
}

/// The area left for windows.
pub fn contentArea(screen_w: i32, screen_h: i32) Rect {
    const height = theme.current().bar_height;
    const top = settings.current().bar == .top;
    return .{
        .x = 0,
        .y = if (top) height else 0,
        .w = screen_w,
        .h = screen_h - height,
    };
}

/// Whether a point is on the bar. Vertical only: the strip spans the width.
pub fn contains(y: i32, screen_h: i32) bool {
    const area = strip(screen_h);
    return y >= area.y and y < area.y + area.h;
}

/// Widest a tab gets. Narrow enough that several fit, wide enough that a name
/// is usually legible rather than an ellipsis.
const TAB_MAX_WIDTH: i32 = 132;
const TAB_MIN_WIDTH: i32 = 56;
const CLOCK_WIDTH: i32 = 46;
/// The stack marker's column, shown only on a tab holding more than one.
const MARKER_WIDTH: i32 = 12;
/// The button that adds a desktop, after the last tab.
const ADD_WIDTH: i32 = 18;

/// The V button: the applications menu, top left. A classic start button,
/// because a tiling manager still needs a way to start something without
/// knowing a command name.
pub const LAUNCH_WIDTH: i32 = 26;

/// What the V menu offers: applications first, then what to do with the
/// session. A start menu that could only start things would leave no way to
/// stop, and on a machine with one screen there is nowhere else to go.
pub const Item = struct {
    label: []const u8,
    action: Kind,

    pub const Kind = union(enum) {
        /// Spawn a program: path, then argv[0].
        run: struct { path: []const u8, name: []const u8 },
        /// A drawn rule, not selectable.
        separator,
        /// Give the display back and return to the shell that started us.
        quit,
        reboot,
        power_off,
    };
};

pub const items = [_]Item{
    .{ .label = "eTerm", .action = .{ .run = .{ .path = "/ETERM", .name = "eterm" } } },
    .{ .label = "Pad", .action = .{ .run = .{ .path = "/PAD", .name = "pad" } } },
    .{ .label = "Monitor", .action = .{ .run = .{ .path = "/MONITOR", .name = "monitor" } } },
    .{ .label = "Settings", .action = .{ .run = .{ .path = "/SETTINGS", .name = "settings" } } },
    .{ .label = "", .action = .separator },
    .{ .label = "Exit to shell", .action = .quit },
    .{ .label = "Restart", .action = .reboot },
    .{ .label = "Shut down", .action = .power_off },
};

var launcher: ui.Menu = .{};

/// Which tab's menu is open, if any. Held here because it is the bar's own
/// state: nothing else needs to know a menu exists.
var menu_tab: ?u8 = null;
var window_menu: ui.Menu = .{};
/// The bar has keyboard focus, so arrows move between tabs rather than
/// reaching whatever window is focused.
var keyboard_focus = false;
var focus_tab: u8 = 0;

pub fn hasFocus() bool {
    return keyboard_focus;
}

pub fn menuOpen() bool {
    return menu_tab != null or launcher.open;
}

/// Open the applications menu, from the V button or a key.
pub fn openLauncher() void {
    var rows: [items.len]ui.MenuItem = undefined;
    launcher.showAt(menuItems(&rows));
    menu_tab = null;
    keyboard_focus = true;
}

fn menuItems(out: []ui.MenuItem) []ui.MenuItem {
    for (items, 0..) |item, i| {
        out[i] = .{
            .label = item.label,
            .kind = if (item.action == .separator) .separator else .item,
        };
    }
    return out[0..items.len];
}

/// Take keyboard control of the bar, starting on the current desktop's tab.
pub fn focus(desktop: *const layout.Desktop) void {
    keyboard_focus = true;
    focus_tab = desktop.tag;
    menu_tab = null;
}

pub fn unfocus() void {
    keyboard_focus = false;
    menu_tab = null;
}

// ---------------------------------------------------------------------------
// Geometry
//
// One place computes where a tab is, and both painting and hit testing use it.
// Two copies of this arithmetic is how a taskbar ends up activating the tab
// next to the one that was clicked.
// ---------------------------------------------------------------------------

fn tabWidth(width: i32, count: u8) i32 {
    const available = width - CLOCK_WIDTH - LAUNCH_WIDTH - ADD_WIDTH;
    const each = @divTrunc(available, @as(i32, count));
    return @max(TAB_MIN_WIDTH, @min(each, TAB_MAX_WIDTH));
}

fn launchRect(screen_h: i32) Rect {
    const t = theme.current();
    return .{ .x = 0, .y = strip(screen_h).y, .w = LAUNCH_WIDTH, .h = t.bar_height - 1 };
}

fn tabRect(width: i32, height: i32, count: u8, index: u8) Rect {
    const t = theme.current();
    const each = tabWidth(width, count);
    return .{
        .x = LAUNCH_WIDTH + @as(i32, index) * each,
        .y = strip(height).y,
        .w = each,
        .h = t.bar_height - 1,
    };
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

pub fn paint(surface: Surface, width: i32, height: i32, desktop: *const layout.Desktop) void {
    const t = theme.current();
    const area = strip(height);
    const top = settings.current().bar == .top;

    surface.fill(.{ .x = 0, .y = area.y, .w = width, .h = t.bar_height }, t.bar);
    // A hairline on whichever edge faces the windows, so the separation reads
    // the same whichever end the bar is at.
    surface.fill(.{
        .x = 0,
        .y = if (top) area.y + t.bar_height - 1 else area.y,
        .w = width,
        .h = 1,
    }, t.bar_line);

    paintLaunch(surface, height);

    var i: u8 = 0;
    while (i < desktop.count) : (i += 1) {
        paintTab(surface, tabRect(width, height, desktop.count, i), desktop, i);
    }

    paintAdd(surface, width, height, desktop);
    paintLayoutGlyph(surface, width, height, desktop);
    paintClock(surface, width, height);
}

fn addRect(width: i32, height: i32, desktop: *const layout.Desktop) Rect {
    const t = theme.current();
    const last = tabRect(width, height, desktop.count, desktop.count - 1);
    return .{ .x = last.right(), .y = strip(height).y, .w = ADD_WIDTH, .h = t.bar_height - 1 };
}

/// A plus, drawn rather than lettered: at this size two strokes read better
/// than a glyph, and it is unambiguous in any font.
fn paintAdd(surface: Surface, width: i32, height: i32, desktop: *const layout.Desktop) void {
    if (desktop.count >= layout.MAX_DESKTOPS) return;

    const t = theme.current();
    const area = addRect(width, height, desktop);
    const cx = area.x + @divTrunc(area.w, 2);
    const cy = area.y + @divTrunc(area.h, 2);

    surface.fill(.{ .x = cx - 4, .y = cy, .w = 9, .h = 1 }, t.bar_text);
    surface.fill(.{ .x = cx, .y = cy - 4, .w = 1, .h = 9 }, t.bar_text);
}

/// Menus, drawn after everything else.
///
/// A dropdown reaches below the bar and over the tiles, so painting it with
/// the strip would put it under whatever is drawn next. Overlays go last, by
/// definition.
pub fn paintOverlay(surface: Surface, width: i32, height: i32, desktop: *const layout.Desktop) void {
    if (menu_tab) |tab| {
        var buf: [layout.MAX_WINDOWS]usize = undefined;
        const list = desktop.windowsOn(tab, &buf);

        var rows: [layout.MAX_WINDOWS]ui.MenuItem = undefined;
        for (list, 0..) |index, k| rows[k] = .{ .label = desktop.windows[index].name() };

        window_menu.paint(surface, menuRect(width, height, desktop, tab), rows[0..list.len]);
    }

    if (launcher.open) {
        var rows: [items.len]ui.MenuItem = undefined;
        launcher.paint(surface, launchMenuRect(height), menuItems(&rows));
    }
}

/// The V button. A wordmark rather than an icon: at 133 DPI a glyph from the
/// font we already have is sharper than anything drawn by hand at this size.
fn paintLaunch(surface: Surface, height: i32) void {
    const t = theme.current();
    const area = launchRect(height);

    if (launcher.open) surface.fill(area, t.accent);
    surface.textCentred(area, "V", if (launcher.open) t.accent_text else t.bar_text);
    surface.fill(.{ .x = area.right() - 1, .y = area.y + 2, .w = 1, .h = area.h - 4 }, t.bar_line);
}

/// A menu drops away from the bar: down from a bar at the top, up from one at
/// the bottom. Dropping it off the screen would be the alternative.
fn dropFrom(anchor: Rect, height: i32, size: Rect) Rect {
    const t = theme.current();
    var area = size;
    area.x = anchor.x;
    area.y = switch (settings.current().bar) {
        .top => t.bar_height,
        .bottom => height - t.bar_height - area.h,
    };
    return area;
}

fn launchMenuRect(height: i32) Rect {
    return dropFrom(
        .{ .x = 0, .y = 0, .w = LAUNCH_WIDTH, .h = 0 },
        height,
        ui.Menu.sizeFor(items.len, TAB_MAX_WIDTH),
    );
}

fn paintTab(surface: Surface, area: Rect, desktop: *const layout.Desktop, index: u8) void {
    const t = theme.current();
    const current = desktop.tag == index;
    const held = keyboard_focus and focus_tab == index;

    if (current) surface.fill(area, t.accent);
    if (held and !current) surface.fill(area, t.surface_hot);

    const color = if (current) t.accent_text else t.bar_text;
    const count = desktop.countOn(index);

    // The name of what is there, not the number of where it is.
    const label = if (desktop.representative(index)) |w|
        desktop.windows[w].name()
    else
        "empty";

    const text_area = Rect{
        .x = area.x + t.padding,
        .y = area.y,
        .w = area.w - t.padding * 2 - (if (count > 1) MARKER_WIDTH else 0),
        .h = area.h,
    };

    const clipped = surface.clipped(text_area);
    clipped.text(
        text_area.x,
        area.y + @divTrunc(area.h - Surface.textHeight(), 2),
        if (label.len == 0) "untitled" else label,
        if (count == 0) t.text_dim else color,
    );

    if (count > 1) paintStackMarker(surface, area, color);

    // A hairline between tabs, so two adjacent ones do not read as one.
    surface.fill(.{ .x = area.right() - 1, .y = area.y + 2, .w = 1, .h = area.h - 4 }, t.bar_line);
}

/// A downward triangle: this tab holds more than one window and will open a
/// menu of them. The glyph rather than three drawn lines, now that the font
/// carries one that reads correctly at this size.
fn paintStackMarker(surface: Surface, area: Rect, color: draw.Color) void {
    surface.glyph(
        area.right() - MARKER_WIDTH,
        area.y + @divTrunc(area.h - Surface.textHeight(), 2),
        glyphs.triangle_down,
        color,
    );
}

fn paintLayoutGlyph(surface: Surface, width: i32, height: i32, desktop: *const layout.Desktop) void {
    const t = theme.current();
    const area = Rect{
        .x = width - CLOCK_WIDTH - 16,
        .y = strip(height).y,
        .w = 14,
        .h = t.bar_height - 1,
    };
    surface.textCentred(area, desktop.layout().glyph(), t.bar_text);
}

fn paintClock(surface: Surface, width: i32, height: i32) void {
    const t = theme.current();
    const area = Rect{ .x = width - CLOCK_WIDTH, .y = strip(height).y, .w = CLOCK_WIDTH - 4, .h = t.bar_height - 1 };

    const us = sys.realtimeMicros() orelse return;
    const minutes = @divFloor(@divFloor(us, 1_000_000), 60);

    var buf: [8]u8 = @splat(0);
    const hour: usize = @intCast(@divFloor(@mod(minutes, 1440), 60));
    const minute: usize = @intCast(@mod(minutes, 60));

    buf[0] = '0' + @as(u8, @intCast(hour / 10));
    buf[1] = '0' + @as(u8, @intCast(hour % 10));
    buf[2] = ':';
    buf[3] = '0' + @as(u8, @intCast(minute / 10));
    buf[4] = '0' + @as(u8, @intCast(minute % 10));

    surface.textCentred(area, buf[0..5], t.bar_text);
}

fn menuRect(width: i32, height: i32, desktop: *const layout.Desktop, tab: u8) Rect {
    const anchor = tabRect(width, height, desktop.count, tab);
    return dropFrom(
        anchor,
        height,
        ui.Menu.sizeFor(desktop.countOn(tab), @max(anchor.w, TAB_MAX_WIDTH)),
    );
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/// Route a click. Returns true if the bar consumed it.
pub const Action = union(enum) {
    none,
    /// The bar consumed the click and nothing else need happen.
    consumed,
    /// Close this window, asking its client first.
    close_window: usize,
    /// Close this desktop and everything on it.
    close_desktop: u8,
    /// End the session and hand the display back.
    quit,
    reboot,
    power_off,
};

pub fn click(x: i32, y: i32, width: i32, height: i32, right: bool, desktop: *layout.Desktop) Action {

    // A menu is modal while open: a click outside dismisses it rather than
    // doing two things at once.
    if (launcher.open) {
        var rows: [items.len]ui.MenuItem = undefined;
        const chosen = ui.Menu.rowAt(launchMenuRect(height), menuItems(&rows), x, y);
        launcher.hide();
        keyboard_focus = false;
        if (chosen) |row| return activate(row);
        return .consumed;
    }

    if (menu_tab) |tab| {
        var buf: [layout.MAX_WINDOWS]usize = undefined;
        const list = desktop.windowsOn(tab, &buf);
        const area = menuRect(width, height, desktop, tab);

        var rows: [layout.MAX_WINDOWS]ui.MenuItem = undefined;
        for (list, 0..) |index, k| rows[k] = .{ .label = desktop.windows[index].name() };

        if (ui.Menu.rowAt(area, rows[0..list.len], x, y)) |row| {
            menu_tab = null;
            // Right-click closes the window the row names; left-click goes to
            // it. Two verbs, one list, no second menu.
            if (right) return .{ .close_window = list[row] };
            desktop.viewWindow(list[row]);
            return .consumed;
        }
        menu_tab = null;
        return .consumed;
    }

    if (!contains(y, height)) return .none;

    if (launchRect(height).contains(x, y)) {
        openLauncher();
        return .consumed;
    }

    if (desktop.count < layout.MAX_DESKTOPS and addRect(width, height, desktop).contains(x, y)) {
        _ = desktop.addDesktop();
        return .consumed;
    }

    var i: u8 = 0;
    while (i < desktop.count) : (i += 1) {
        const area = tabRect(width, height, desktop.count, i);
        if (!area.contains(x, y)) continue;

        // Right-click closes the desktop; the marker opens its menu; the rest
        // of the tab switches to it.
        if (right) return .{ .close_desktop = i };

        if (desktop.countOn(i) > 1 and x >= area.right() - MARKER_WIDTH) {
            menu_tab = i;
            window_menu.show();
        } else {
            desktop.view(i);
        }
        return .consumed;
    }

    const glyph = Rect{
        .x = width - CLOCK_WIDTH - 16,
        .y = strip(height).y,
        .w = 14,
        .h = theme.current().bar_height,
    };
    if (glyph.contains(x, y)) {
        desktop.cycleLayout();
        return .consumed;
    }

    return .consumed;
}

/// Carry out a menu choice. Spawning happens here; anything that ends the
/// session is returned so the manager can put the display back first.
fn activate(index: usize) Action {
    if (index >= items.len) return .consumed;

    return switch (items[index].action) {
        .separator => .consumed,
        .run => |program| blk: {
            _ = sys.spawnDetached(program.path, &.{program.name});
            break :blk .consumed;
        },
        .quit => .quit,
        .reboot => .reboot,
        .power_off => .power_off,
    };
}

pub const KeyResult = enum { ignored, handled, released };

/// What a keyboard choice asked for, since `key` returns only whether it was
/// consumed. Collected by the manager after the call.
var pending: Action = .none;

pub fn takePending() Action {
    const action = pending;
    pending = .none;
    return action;
}

/// Drive the bar from the keyboard. Everything the mouse can do here, the
/// keyboard can: a taskbar reachable only by pointer is a taskbar that stops
/// working the moment the touchpad does.
pub fn key(code: sys.KeyCode, desktop: *layout.Desktop) KeyResult {
    if (!keyboard_focus) return .ignored;

    if (launcher.open) {
        var rows: [items.len]ui.MenuItem = undefined;
        switch (launcher.key(code, menuItems(&rows))) {
            .chosen => {
                const chosen = launcher.selected;
                launcher.hide();
                keyboard_focus = false;
                pending = activate(chosen);
                return .released;
            },
            .cancelled => {
                keyboard_focus = false;
                return .released;
            },
            .moved => return .handled,
            .ignored => return .ignored,
        }
    }

    if (menu_tab) |tab| return menuKey(code, desktop, tab);

    switch (code) {
        .left => {
            // Left from the first tab reaches the V button, so the whole bar
            // is one traversal rather than two islands.
            if (focus_tab == 0) {
                openLauncher();
            } else {
                focus_tab -= 1;
            }
        },
        .right => focus_tab = (focus_tab + 1) % desktop.count,
        .down => {
            if (desktop.countOn(focus_tab) > 1) {
                menu_tab = focus_tab;
                window_menu.show();
            }
        },
        .enter, .space => {
            desktop.view(focus_tab);
            unfocus();
            return .released;
        },
        .escape => {
            unfocus();
            return .released;
        },
        else => return .ignored,
    }
    return .handled;
}

fn menuKey(code: sys.KeyCode, desktop: *layout.Desktop, tab: u8) KeyResult {
    var buf: [layout.MAX_WINDOWS]usize = undefined;
    const list = desktop.windowsOn(tab, &buf);

    var rows: [layout.MAX_WINDOWS]ui.MenuItem = undefined;
    for (list, 0..) |index, k| rows[k] = .{ .label = desktop.windows[index].name() };

    switch (window_menu.key(code, rows[0..list.len])) {
        .chosen => {
            desktop.viewWindow(list[window_menu.selected]);
            unfocus();
            return .released;
        },
        .cancelled => {
            menu_tab = null;
            return .handled;
        },
        .moved => return .handled,
        .ignored => return .ignored,
    }
}
