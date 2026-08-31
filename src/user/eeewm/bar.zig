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

const draw = @import("eui").draw;
const layout = @import("layout.zig");
const status = @import("status.zig");
const popover = @import("eui").popover;
const slider = @import("eui").slider;
const audio = @import("proto").audio;
const eui_icon = @import("eui").icon;
const graph = @import("lib").audiograph;
const ipv4 = @import("lib").ipv4;
const net = @import("proto").net;
const sys = @import("sys");
const theme = @import("eui").theme;

const ui = @import("eui").widget;

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
    .{ .label = "eTerm", .action = .{ .run = .{ .path = "/bin/eterm", .name = "eterm" } } },
    .{ .label = "Pad", .action = .{ .run = .{ .path = "/bin/pad", .name = "pad" } } },
    .{ .label = "Monitor", .action = .{ .run = .{ .path = "/bin/monitor", .name = "monitor" } } },
    .{ .label = "Settings", .action = .{ .run = .{ .path = "/bin/settings", .name = "settings" } } },
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

fn tabWidth(width: i32, height: i32, count: u8) i32 {
    var buf: [status.MAX]status.Slot = undefined;
    const slots = statusSlots(width, height, &buf);
    const available = status.leftEdge(.{ .x = 0, .y = 0, .w = width, .h = 0 }, slots) -
        LAUNCH_WIDTH - ADD_WIDTH;
    const each = @divTrunc(available, @as(i32, count));
    return @max(TAB_MIN_WIDTH, @min(each, TAB_MAX_WIDTH));
}

fn launchRect(screen_h: i32) Rect {
    const t = theme.current();
    return .{ .x = 0, .y = strip(screen_h).y, .w = LAUNCH_WIDTH, .h = t.bar_height - 1 };
}

fn tabRect(width: i32, height: i32, count: u8, index: u8) Rect {
    const t = theme.current();
    const each = tabWidth(width, height, count);
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
    paintStatus(surface, width, height);
}

/// What the bar shows about the machine, and where.
///
/// One list, read by the painter and by the hit test, so a screen too narrow
/// for all of them drops the same one from both.
pub fn statusSlots(width: i32, height: i32, into: []status.Slot) []status.Slot {
    const area = Rect{ .x = 0, .y = strip(height).y, .w = width, .h = theme.current().bar_height };
    return status.place(area, &shown, into);
}

/// In the order they sit. What is furthest left goes first on a narrow
/// screen, which is why the clock is last.
const shown = [_]status.Indicator{ .network, .sound, .clock };

fn paintStatus(surface: Surface, width: i32, height: i32) void {
    var buf: [status.MAX]status.Slot = undefined;
    for (statusSlots(width, height, &buf)) |slot| {
        switch (slot.which) {
            .clock => paintClock(surface, slot.area),
            .network => paintNetwork(surface, slot.area),
            .sound => paintSound(surface, slot.area),
            // Drawn once it has something true to say and a menu to say it
            // in; the row already keeps its room.
            .battery => {},
        }
    }
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
/// Move an open menu's highlight to whatever the pointer is over.
///
/// True when it changed, so the manager knows to repaint. Motion does not
/// otherwise repaint anything, which is what keeps moving the pointer cheap.
pub fn hover(x: i32, y: i32, width: i32, height: i32, desktop: *const layout.Desktop) bool {
    if (menu_tab) |tab| {
        var buf: [layout.MAX_WINDOWS]usize = undefined;
        const list = desktop.windowsOn(tab, &buf);

        var rows: [layout.MAX_WINDOWS]ui.MenuItem = undefined;
        for (list, 0..) |index, k| rows[k] = .{ .label = desktop.windows[index].name() };

        const before = window_menu.selected;
        window_menu.hover(menuRect(width, height, desktop, tab), rows[0..list.len], x, y);
        return window_menu.selected != before;
    }

    if (launcher.open) {
        var rows: [items.len]ui.MenuItem = undefined;
        const before = launcher.selected;
        launcher.hover(launchMenuRect(height), menuItems(&rows), x, y);
        return launcher.selected != before;
    }

    if (net_open) {
        var rows: [MAX_IFACES + 2]ui.MenuItem = undefined;
        const before = net_menu.selected;
        net_menu.hover(netPanel(width, height), netItems(&rows), x, y);
        return net_menu.selected != before;
    }

    if (sound_open) {
        var rows: [MAX_PORTS + 4]ui.MenuItem = undefined;
        const before = sound_menu.selected;
        sound_menu.hover(soundRows(soundPanel(width, height)), soundItems(&rows), x, y);
        return sound_menu.selected != before;
    }

    return false;
}

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

    if (sound_open) paintSoundMenu(surface, width, height);
    if (net_open) paintNetMenu(surface, width, height);
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
    var rows: [items.len]ui.MenuItem = undefined;
    return dropFrom(
        .{ .x = 0, .y = 0, .w = LAUNCH_WIDTH, .h = 0 },
        height,
        ui.Menu.sizeFor(menuItems(&rows), TAB_MAX_WIDTH),
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

    // A desktop showing one window at full size says so, because otherwise
    // the tab of a stack of three and the tab of a stack of three with two
    // of them hidden are the same tab.
    if (count > 1) {
        if (desktop.tag == index and desktop.isMaximised()) {
            surface.icon(
                area.right() - MARKER_WIDTH,
                area.y + @divTrunc(area.h - @as(i32, @intCast(eui_icon.HEIGHT)), 2),
                .maximised,
                color,
            );
        } else {
            paintStackMarker(surface, area, color);
        }
    }

    // A hairline between tabs, so two adjacent ones do not read as one.
    surface.fill(.{ .x = area.right() - 1, .y = area.y + 2, .w = 1, .h = area.h - 4 }, t.bar_line);
}

/// Three short rules, the mark everything uses for "there is a list behind
/// this". Drawn rather than taken from the font: at this size a glyph is a
/// smudge, and three rules are three rules at any size.
fn paintStackMarker(surface: Surface, area: Rect, color: draw.Color) void {
    const width = MARKER_WIDTH - 3;
    const x = area.right() - MARKER_WIDTH + 1;
    const spacing = 3;
    var y = area.y + @divTrunc(area.h - (spacing * 2 + 1), 2);

    for (0..3) |_| {
        surface.fill(.{ .x = x, .y = y, .w = width, .h = 1 }, color);
        y += spacing;
    }
}

/// Which keyboard layout the keys mean, in the two letters the layout gives
/// for the purpose. Always shown: a machine whose keycaps disagree with its
/// layout is one where this is the first thing worth checking.
// ---------------------------------------------------------------------------
// Network
//
// What the machine is connected to, behind the one icon that says whether it
// is connected at all. The rows report rather than act, because there is
// nothing here to change that the settings do not own; the last row goes
// where those are.
// ---------------------------------------------------------------------------

var net_menu: ui.Menu = .{};
var net_open = false;
var ifaces: [MAX_IFACES]net.Iface = undefined;
var iface_addrs: [MAX_IFACES]net.AddressInfo = undefined;
var iface_texts: [MAX_IFACES][15]u8 = undefined;
var iface_count: usize = 0;

const MAX_IFACES = 4;
const NET_WIDTH: i32 = 216;

fn readNetwork() void {
    iface_count = @min(net.interfaceCount(), MAX_IFACES);
    for (0..iface_count) |i| {
        ifaces[i] = net.interfaceAt(i) orelse .{};
        iface_addrs[i] = net.addressOf(i) orelse .{};
    }
}

/// Whether anything is up and addressed, which is what the bar's icon says.
fn networkUp() bool {
    for (0..iface_count) |i| {
        if (ifaces[i].up != 0 and iface_addrs[i].addr != 0) return true;
    }
    return false;
}

fn netItems(into: []ui.MenuItem) []ui.MenuItem {
    var count: usize = 0;
    for (0..iface_count) |i| {
        if (count == into.len) break;
        const address = iface_addrs[i].addr;
        into[count] = .{
            .label = net.nameOf(&ifaces[i]),
            // The rows say what is; changing it is the settings' business.
            .kind = .disabled,
            .mark = .ethernet,
            .detail = if (address != 0)
                ipv4.text(address, &iface_texts[i])
            else if (ifaces[i].up != 0) "no address" else "no link",
        };
        count += 1;
    }

    if (count == 0 and into.len > 0) {
        into[count] = .{ .label = "No interfaces", .kind = .disabled, .mark = .ethernet };
        count += 1;
    }

    if (count + 2 <= into.len) {
        into[count] = .{ .kind = .separator };
        into[count + 1] = .{ .label = "Settings", .mark = .sliders };
        count += 2;
    }
    return into[0..count];
}

fn netPanel(width: i32, height: i32) Rect {
    var buf: [status.MAX]status.Slot = undefined;
    const slots = statusSlots(width, height, &buf);

    var anchor = Rect{ .x = width, .y = strip(height).y, .w = 0, .h = theme.current().bar_height };
    for (slots) |slot| {
        if (slot.which == .network) anchor = slot.area;
    }

    var rows: [MAX_IFACES + 2]ui.MenuItem = undefined;
    const list = netItems(&rows);

    return popover.place(
        anchor,
        NET_WIDTH,
        ui.Menu.sizeFor(list, NET_WIDTH).h,
        .{ .x = 0, .y = 0, .w = width, .h = height },
        if (settings.current().bar == .top) .below else .above,
    );
}

fn paintNetwork(surface: Surface, area: Rect) void {
    const t = theme.current();
    const ink = if (net_open)
        t.accent_text
    else if (networkUp()) t.bar_text else t.text_dim;

    if (net_open) surface.fill(area, t.accent);
    surface.icon(
        area.x + @divTrunc(area.w - @as(i32, @intCast(eui_icon.WIDTH)), 2),
        area.y + @divTrunc(area.h - @as(i32, @intCast(eui_icon.HEIGHT)), 2),
        .ethernet,
        ink,
    );
}

fn paintNetMenu(surface: Surface, width: i32, height: i32) void {
    var rows: [MAX_IFACES + 2]ui.MenuItem = undefined;
    net_menu.paint(surface, netPanel(width, height), netItems(&rows));
}

// ---------------------------------------------------------------------------
// Sound
//
// The level and the outputs, behind the one icon in the bar that says whether
// the machine can be heard. What is asked of the service is cached, because a
// paint happens whenever the pointer moves and the answers change only when
// somebody changes them.
// ---------------------------------------------------------------------------

var sound_menu: ui.Menu = .{};
var sound_open = false;
var level: audio.VolumeInfo = .{ .percent = 0, .muted = 0 };
/// What to go back to. Silence is a level of zero rather than a flag beside
/// one, so unmuting has to remember what it was before it was nothing.
var level_before_silence: u8 = 50;
/// Which port each row names, filled by the same walk that builds the rows.
/// A rule names none. Kept beside the rows rather than worked out again,
/// because a second walk that disagreed would pick the wrong output.
var row_ports: [MAX_PORTS + 4]u16 = @splat(graph.NONE);
var sound_ports: [MAX_PORTS]audio.PortInfo = undefined;
var sound_port_count: usize = 0;

/// Enough for the outputs and inputs a machine of this size has, plus the
/// programs playing through them.
const MAX_PORTS = 12;
const SOUND_WIDTH: i32 = 224;

/// The strip above the rows: the icon, the slider and the percentage, inside
/// the same inset the rows below it use.
fn soundLevelHeight() i32 {
    const t = theme.current();
    return t.control_height + t.menu_padding * 2;
}

pub fn refresh() void {
    readSound();
    readNetwork();
}

fn readSound() void {
    level = audio.master() orelse .{ .percent = 0, .muted = 0 };
    sound_port_count = audio.ports(&sound_ports).len;
}

pub fn soundOpen() bool {
    return sound_open;
}

/// Whether the machine is making no sound, whichever way it was silenced.
fn silent() bool {
    return level.muted != 0 or level.percent == 0;
}

/// Silence it, or put it back to what it was. Mute is a level of zero here
/// rather than a flag beside a level, because a slider reading seventy on a
/// machine making no noise is a slider that is lying.
fn toggleSilence() void {
    const ok = if (silent()) blk: {
        const back = if (level_before_silence == 0) 50 else level_before_silence;
        break :blk audio.setMaster(back, false);
    } else blk: {
        level_before_silence = level.percent;
        break :blk audio.setMaster(0, true);
    };
    if (ok) readSound();
}

/// The rows: what can be played out of, then what can be recorded from. A
/// port is marked when it is the one in use. Silencing is the picture beside
/// the slider rather than a row of its own, because it is a thing done to
/// the level and it belongs where the level is.
fn soundItems(into: []ui.MenuItem) []ui.MenuItem {
    var count: usize = 0;
    row_ports = @splat(graph.NONE);

    const put = struct {
        fn one(list: []ui.MenuItem, at: *usize, item: ui.MenuItem, port: u16) void {
            if (at.* == list.len) return;
            list[at.*] = item;
            if (at.* < row_ports.len) row_ports[at.*] = port;
            at.* += 1;
        }
    }.one;

    for ([_]graph.Direction{ .sink, .source }) |want| {
        var any = false;
        // By pointer: the name is a slice into the table, and a slice into a
        // copy that goes out of scope with the loop is a row with no label.
        for (sound_ports[0..sound_port_count]) |*port| {
            if (port.direction != want) continue;
            // A rule between the groups, never above the first: the strip
            // above them is already a boundary.
            if (!any and count > 0) put(into, &count, .{ .kind = .separator }, graph.NONE);
            any = true;
            put(into, &count, .{
                .label = audio.nameOf(port),
                // The tick says which one the machine is using; the others
                // carry nothing, and the column keeps them lined up.
                .mark = if (port.default != 0) .check else null,
            }, port.id);
        }
    }

    return into[0..count];
}

fn soundPanel(width: i32, height: i32) Rect {
    var buf: [status.MAX]status.Slot = undefined;
    const slots = statusSlots(width, height, &buf);

    var anchor = Rect{ .x = width, .y = strip(height).y, .w = 0, .h = theme.current().bar_height };
    for (slots) |slot| {
        if (slot.which == .sound) anchor = slot.area;
    }

    var rows: [MAX_PORTS + 4]ui.MenuItem = undefined;
    const list = soundItems(&rows);
    const rows_high = ui.Menu.sizeFor(list, SOUND_WIDTH).h;

    return popover.place(
        anchor,
        SOUND_WIDTH,
        soundLevelHeight() + rows_high,
        .{ .x = 0, .y = 0, .w = width, .h = height },
        if (settings.current().bar == .top) .below else .above,
    );
}

/// The groove, inside the panel's level strip.
/// The picture left of the slider, which is what silences it. Sized to the
/// picture column rather than to the picture, so it is a target a touchpad
/// can hit.
fn soundMuteRect(panel: Rect) Rect {
    const t = theme.current();
    return .{
        .x = panel.x + t.menu_padding,
        .y = panel.y + t.menu_padding,
        .w = ui.MARK_WIDTH,
        .h = t.control_height,
    };
}

fn soundTrack(panel: Rect) Rect {
    const t = theme.current();
    const left = panel.x + t.menu_padding + ui.MARK_WIDTH;
    // Room on the right for "100%", which is the widest the number gets,
    // with the gap before it and the panel's inset after.
    const number = ui.GAP + Surface.textWidth("100%") + t.menu_padding;
    return .{
        .x = left,
        .y = panel.y + t.menu_padding,
        .w = panel.right() - number - left,
        .h = t.control_height,
    };
}

fn soundRows(panel: Rect) Rect {
    return .{
        .x = panel.x,
        .y = panel.y + soundLevelHeight(),
        .w = panel.w,
        .h = panel.h - soundLevelHeight(),
    };
}

fn paintSound(surface: Surface, area: Rect) void {
    const t = theme.current();
    const which = eui_icon.volume(level.percent, level.muted != 0);
    const inside = sound_open;

    if (inside) surface.fill(area, t.accent);
    surface.icon(
        area.x + @divTrunc(area.w - @as(i32, @intCast(eui_icon.WIDTH)), 2),
        area.y + @divTrunc(area.h - @as(i32, @intCast(eui_icon.HEIGHT)), 2),
        which,
        if (inside) t.accent_text else t.bar_text,
    );
}

fn paintSoundMenu(surface: Surface, width: i32, height: i32) void {
    const t = theme.current();
    const panel = soundPanel(width, height);

    // The strip: the panel's own ground, the icon, the slider and the number.
    const strip_area = Rect{ .x = panel.x, .y = panel.y, .w = panel.w, .h = soundLevelHeight() };
    surface.fill(strip_area, t.surface);
    surface.frame(strip_area, t.line);

    const button = soundMuteRect(panel);
    surface.icon(
        button.x,
        button.y + @divTrunc(button.h - @as(i32, @intCast(eui_icon.HEIGHT)), 2),
        eui_icon.volume(level.percent, level.muted != 0),
        t.text,
    );

    const groove = soundTrack(panel);
    ui.paintSlider(surface, groove, .{ .min = 0, .max = 100 }, level.percent, .idle, false, .{});

    var text: [5]u8 = @splat(0);
    const spelled = percentText(&text, level.percent);
    surface.text(
        panel.right() - t.menu_padding - Surface.textWidth(spelled),
        panel.y + @divTrunc(soundLevelHeight() - Surface.textHeight(), 2),
        spelled,
        t.text,
    );

    var rows: [MAX_PORTS + 4]ui.MenuItem = undefined;
    sound_menu.paint(surface, soundRows(panel), soundItems(&rows));
}

/// What a row of the sound menu does. Every row names a port, and choosing
/// one makes it the default in its own direction.
///
/// Reads what the walk that built the rows left in `row_ports`, which the
/// hit test has just done.
fn chooseSound(row: usize) void {
    if (row >= row_ports.len) return;
    const port = row_ports[row];
    if (port == graph.NONE) return;
    if (audio.makeDefault(port)) readSound();
}

fn percentText(buf: []u8, value: u8) []const u8 {
    var n: usize = 0;
    if (value >= 100) {
        buf[n] = '1';
        n += 1;
    }
    if (value >= 10) {
        buf[n] = '0' + @as(u8, @intCast(value / 10 % 10));
        n += 1;
    }
    buf[n] = '0' + @as(u8, @intCast(value % 10));
    buf[n + 1] = '%';
    return buf[0 .. n + 2];
}

fn paintClock(surface: Surface, area: Rect) void {
    const t = theme.current();
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
    // Every row is a window's name, so what the size depends on is how many
    // there are rather than what they say.
    var rows: [layout.MAX_WINDOWS]ui.MenuItem = @splat(.{});
    const count = @min(@as(usize, desktop.countOn(tab)), rows.len);
    return dropFrom(
        anchor,
        height,
        ui.Menu.sizeFor(rows[0..count], @max(anchor.w, TAB_MAX_WIDTH)),
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

    if (net_open) {
        var rows: [MAX_IFACES + 2]ui.MenuItem = undefined;
        const list = netItems(&rows);
        const chosen = ui.Menu.rowAt(netPanel(width, height), list, x, y);
        net_open = false;
        // The one row that acts is the last: where the settings are.
        if (chosen) |row| {
            if (list[row].kind == .item) {
                _ = sys.spawnDetached("/bin/settings", &.{"settings"});
            }
        }
        return .consumed;
    }

    if (sound_open) {
        const panel = soundPanel(width, height);

        if (soundMuteRect(panel).contains(x, y)) {
            toggleSilence();
            return .consumed;
        }

        // The groove: dragging the level is the thing this menu is opened
        // for most often, and it stays open while it is done. Setting a
        // level on a silenced machine is asking to hear that level, so it
        // stops being silent and keeps where the pointer put it.
        const groove = soundTrack(panel);
        if (groove.contains(x, y)) {
            const wanted = slider.valueAt(groove, .{ .min = 0, .max = 100 }, x);
            if (audio.setMaster(@intCast(wanted), false)) readSound();
            return .consumed;
        }

        var rows: [MAX_PORTS + 4]ui.MenuItem = undefined;
        const list = soundItems(&rows);
        if (ui.Menu.rowAt(soundRows(panel), list, x, y)) |row| {
            chooseSound(row);
            return .consumed;
        }

        sound_open = false;
        return .consumed;
    }

    if (!contains(y, height)) return .none;

    var status_buf: [status.MAX]status.Slot = undefined;
    if (status.at(statusSlots(width, height, &status_buf), x, y)) |which| {
        switch (which) {
            .sound => {
                readSound();
                sound_open = true;
                sound_menu.show();
            },
            .network => {
                readNetwork();
                net_open = true;
                net_menu.show();
            },
            else => {},
        }
        return .consumed;
    }

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
