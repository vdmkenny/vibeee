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

const Rect = draw.Rect;
const Surface = draw.Surface;

/// Widest a tab gets. Narrow enough that several fit, wide enough that a name
/// is usually legible rather than an ellipsis.
const TAB_MAX_WIDTH: i32 = 132;
const TAB_MIN_WIDTH: i32 = 56;
const CLOCK_WIDTH: i32 = 46;
/// The stack marker's column, shown only on a tab holding more than one.
const MARKER_WIDTH: i32 = 12;

/// The V button: the applications menu, top left. A classic start button,
/// because a tiling manager still needs a way to start something without
/// knowing a command name.
pub const LAUNCH_WIDTH: i32 = 26;

/// What the launcher offers. A fixed list until something enumerates
/// `/apps`, which is the right eventual source and not one that exists.
pub const App = struct { label: []const u8, path: []const u8, argv0: []const u8 };

pub const apps = [_]App{
    .{ .label = "Hello", .path = "/EHELLO", .argv0 = "ehello" },
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
    launcher.show();
    menu_tab = null;
    keyboard_focus = true;
}

fn appLabels(out: [][]const u8) [][]const u8 {
    for (apps, 0..) |app, i| out[i] = app.label;
    return out[0..apps.len];
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
    const available = width - CLOCK_WIDTH - LAUNCH_WIDTH;
    const each = @divTrunc(available, @as(i32, count));
    return @max(TAB_MIN_WIDTH, @min(each, TAB_MAX_WIDTH));
}

fn launchRect() Rect {
    const t = theme.current();
    return .{ .x = 0, .y = 0, .w = LAUNCH_WIDTH, .h = t.bar_height - 1 };
}

fn tabRect(width: i32, count: u8, index: u8) Rect {
    const t = theme.current();
    const each = tabWidth(width, count);
    return .{
        .x = LAUNCH_WIDTH + @as(i32, index) * each,
        .y = 0,
        .w = each,
        .h = t.bar_height - 1,
    };
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

pub fn paint(surface: Surface, width: i32, desktop: *const layout.Desktop) void {
    const t = theme.current();

    surface.fill(.{ .x = 0, .y = 0, .w = width, .h = t.bar_height }, t.bar);
    // A hairline rather than a bevel: it separates without spending a row on
    // looking like it does.
    surface.fill(.{ .x = 0, .y = t.bar_height - 1, .w = width, .h = 1 }, t.bar_line);

    paintLaunch(surface);

    var i: u8 = 0;
    while (i < desktop.count) : (i += 1) {
        paintTab(surface, tabRect(width, desktop.count, i), desktop, i);
    }

    paintLayoutGlyph(surface, width, desktop);
    paintClock(surface, width);
}

/// Menus, drawn after everything else.
///
/// A dropdown reaches below the bar and over the tiles, so painting it with
/// the strip would put it under whatever is drawn next. Overlays go last, by
/// definition.
pub fn paintOverlay(surface: Surface, width: i32, desktop: *const layout.Desktop) void {
    if (menu_tab) |tab| {
        var buf: [layout.MAX_WINDOWS]usize = undefined;
        const list = desktop.windowsOn(tab, &buf);

        var labels: [layout.MAX_WINDOWS][]const u8 = undefined;
        for (list, 0..) |index, k| labels[k] = desktop.windows[index].name();

        window_menu.paint(surface, menuRect(width, desktop, tab), labels[0..list.len]);
    }

    if (launcher.open) {
        var labels: [apps.len][]const u8 = undefined;
        launcher.paint(surface, launchMenuRect(), appLabels(&labels));
    }
}

/// The V button. A wordmark rather than an icon: at 133 DPI a glyph from the
/// font we already have is sharper than anything drawn by hand at this size.
fn paintLaunch(surface: Surface) void {
    const t = theme.current();
    const area = launchRect();

    if (launcher.open) surface.fill(area, t.accent);
    surface.textCentred(area, "V", if (launcher.open) t.accent_text else t.bar_text);
    surface.fill(.{ .x = area.right() - 1, .y = 2, .w = 1, .h = area.h - 4 }, t.bar_line);
}

fn launchMenuRect() Rect {
    const t = theme.current();
    var area = ui.Menu.sizeFor(apps.len, TAB_MAX_WIDTH);
    area.x = 0;
    area.y = t.bar_height;
    return area;
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
    surface.fill(.{ .x = area.right() - 1, .y = 2, .w = 1, .h = area.h - 4 }, t.bar_line);
}

/// Three stacked lines: this tab holds more than one window and will open a
/// menu of them.
fn paintStackMarker(surface: Surface, area: Rect, color: draw.Color) void {
    const x = area.right() - MARKER_WIDTH;
    const y = area.y + @divTrunc(area.h, 2) - 3;

    var row: i32 = 0;
    while (row < 3) : (row += 1) {
        surface.fill(.{ .x = x, .y = y + row * 3, .w = 7, .h = 1 }, color);
    }
}

fn paintLayoutGlyph(surface: Surface, width: i32, desktop: *const layout.Desktop) void {
    const t = theme.current();
    const area = Rect{
        .x = width - CLOCK_WIDTH - 16,
        .y = 0,
        .w = 14,
        .h = t.bar_height - 1,
    };
    surface.textCentred(area, desktop.layout().glyph(), t.bar_text);
}

fn paintClock(surface: Surface, width: i32) void {
    const t = theme.current();
    const area = Rect{ .x = width - CLOCK_WIDTH, .y = 0, .w = CLOCK_WIDTH - 4, .h = t.bar_height - 1 };

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

fn menuRect(width: i32, desktop: *const layout.Desktop, tab: u8) Rect {
    const t = theme.current();
    const anchor = tabRect(width, desktop.count, tab);

    var area = ui.Menu.sizeFor(desktop.countOn(tab), @max(anchor.w, TAB_MAX_WIDTH));
    area.x = anchor.x;
    area.y = t.bar_height;
    return area;
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/// Route a click. Returns true if the bar consumed it.
pub fn click(x: i32, y: i32, width: i32, desktop: *layout.Desktop) bool {
    const t = theme.current();

    // A menu is modal while open: a click outside dismisses it rather than
    // doing two things at once.
    if (launcher.open) {
        if (ui.Menu.rowAt(launchMenuRect(), apps.len, x, y)) |row| launch(row);
        launcher.hide();
        keyboard_focus = false;
        return true;
    }

    if (menu_tab) |tab| {
        var buf: [layout.MAX_WINDOWS]usize = undefined;
        const list = desktop.windowsOn(tab, &buf);
        const area = menuRect(width, desktop, tab);

        if (ui.Menu.rowAt(area, list.len, x, y)) |row| desktop.viewWindow(list[row]);
        menu_tab = null;
        return true;
    }

    if (y >= t.bar_height) return false;

    if (launchRect().contains(x, y)) {
        openLauncher();
        return true;
    }

    var i: u8 = 0;
    while (i < desktop.count) : (i += 1) {
        const area = tabRect(width, desktop.count, i);
        if (!area.contains(x, y)) continue;

        // The marker opens the menu; the rest of the tab switches to it.
        if (desktop.countOn(i) > 1 and x >= area.right() - MARKER_WIDTH) {
            menu_tab = i;
            window_menu.show();
        } else {
            desktop.view(i);
        }
        return true;
    }

    const glyph = Rect{ .x = width - CLOCK_WIDTH - 16, .y = 0, .w = 14, .h = t.bar_height };
    if (glyph.contains(x, y)) {
        desktop.cycleLayout();
        return true;
    }

    return true;
}

fn launch(index: usize) void {
    if (index >= apps.len) return;
    _ = sys.spawnDetached(apps[index].path, &.{apps[index].argv0});
}

pub const KeyResult = enum { ignored, handled, released };

/// Drive the bar from the keyboard. Everything the mouse can do here, the
/// keyboard can: a taskbar reachable only by pointer is a taskbar that stops
/// working the moment the touchpad does.
pub fn key(code: sys.KeyCode, desktop: *layout.Desktop) KeyResult {
    if (!keyboard_focus) return .ignored;

    if (launcher.open) {
        switch (launcher.key(code, apps.len)) {
            .chosen => {
                launch(launcher.selected);
                launcher.hide();
                keyboard_focus = false;
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

    switch (window_menu.key(code, list.len)) {
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
