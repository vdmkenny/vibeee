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
const bindings = @import("ulib").bindings;
const anchors = @import("proto").anchors;
const info = @import("ulib").info;
const dir = @import("ulib").dir;
const lib = @import("lib");
const opening = @import("proto").opening;
const paths = @import("ulib").paths;
const str = @import("lib").str;
const draw = @import("eui").draw;
const layout = @import("layout.zig");
const status = @import("status.zig");
const popover = @import("eui").popover;
const slider = @import("eui").slider;
const strip = @import("eui").strip;
const audio = @import("proto").audio;
const eui_icon = @import("eui").icon;
const eui_keys = @import("eui").keys;
const graph = @import("lib").audiograph;
const ipv4 = @import("lib").ipv4;
const net = @import("proto").net;
const platform = @import("proto").platform;
const sys = @import("sys");
const theme = @import("eui").theme;

const ui = @import("eui").widget;

const settings = @import("config.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

/// Where the band sits. One function answers it and everything else asks,
/// because the bar's position appears in painting, in hit testing, in where a
/// menu drops and in how much room the tiles get, and four copies of that
/// arithmetic is four chances to disagree.
pub fn band(screen_h: i32) Rect {
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
    const area = band(screen_h);
    return y >= area.y and y < area.y + area.h;
}

/// Widest a tab gets. Narrow enough that several fit, wide enough that a name
/// is usually legible rather than an ellipsis.
/// Chosen against a twelve pixel face, so they are asked for at whatever
/// size the interface is drawn: a tab that stayed a hundred and thirty-two
/// pixels wide while its label doubled would hold half a name.
fn tabMaxWidth() i32 {
    return theme.enlarged(132);
}
fn tabMinWidth() i32 {
    return theme.enlarged(56);
}
/// The stack marker's column, shown only on a tab holding more than one.
fn markerWidth() i32 {
    return theme.enlarged(12);
}
/// The button that adds a desktop, after the last tab.
fn addWidth() i32 {
    return theme.enlarged(18);
}

/// The V button: the applications menu, top left. A classic start button,
/// because a tiling manager still needs a way to start something without
/// knowing a command name.
pub fn launchWidth() i32 {
    return theme.enlarged(26);
}

/// What the V menu offers: applications first, then what to do with the
/// session. A start menu that could only start things would leave no way to
/// stop, and on a machine with one screen there is nowhere else to go.
/// What a thing in the launcher is for.
///
/// Listed as they gain something, like the settings sections: a category
/// with nothing under it is a heading the machine cannot fill. The list is
/// what makes a growing set of programs stay findable, because the answer to
/// "where is it" stops being "somewhere in this column".
pub const Category = enum {
    tools,
    system,
    session,

    pub fn parse(name: []const u8) ?Category {
        for (std.enums.values(Category)) |which| {
            if (std.mem.eql(u8, which.title(), name)) return which;
        }
        return null;
    }

    pub fn title(self: Category) []const u8 {
        return switch (self) {
            .tools => "Tools",
            .system => "System",
            .session => "Session",
        };
    }

    /// The picture beside the name. What the drawer holds rather than what
    /// one thing in it is: programs, the machine itself, and leaving.
    pub fn icon(self: Category) eui_icon.Icon {
        return switch (self) {
            .tools => .apps,
            .system => .sliders,
            .session => .power,
        };
    }
};

pub const Item = struct {
    label: []const u8,
    category: Category,
    /// The picture beside it. Null where nothing says it better than the
    /// name does.
    mark: ?eui_icon.Icon = null,
    action: Kind,

    pub const Kind = union(enum) {
        /// Spawn a program: path, then argv[0], then what to tell it. The
        /// argument is how one entry opens a program somewhere particular
        /// rather than wherever it opens by default.
        run: struct { path: []const u8, name: []const u8, arg: []const u8 = "" },
        /// A drawn rule, not selectable.
        separator,
        /// Give the display back and return to the shell that started us.
        quit,
        reboot,
        power_off,
    };
};

pub const items = [_]Item{
    .{ .label = "eTerm", .category = .tools, .mark = .terminal, .action = .{ .run = .{ .path = "/bin/eterm", .name = "eterm" } } },
    .{ .label = "Pad", .category = .tools, .mark = .document, .action = .{ .run = .{ .path = "/bin/pad", .name = "pad" } } },
    .{ .label = "Files", .category = .tools, .mark = .folder, .action = .{ .run = .{ .path = "/bin/efm", .name = "efm" } } },
    .{ .label = "Calc", .category = .tools, .mark = .calculator, .action = .{ .run = .{ .path = "/bin/calc", .name = "calc" } } },
    .{ .label = "Hero", .category = .tools, .mark = .document, .action = .{ .run = .{ .path = "/bin/hero", .name = "hero" } } },
    .{ .label = "Viewer", .category = .tools, .mark = .picture, .action = .{ .run = .{ .path = "/bin/eimg", .name = "eimg" } } },
    .{ .label = "Monitor", .category = .system, .mark = .chart, .action = .{ .run = .{ .path = "/bin/monitor", .name = "monitor" } } },
    .{ .label = "Settings", .category = .system, .mark = .sliders, .action = .{ .run = .{ .path = "/bin/settings", .name = "settings" } } },
    .{ .label = "About this computer", .category = .system, .mark = .about, .action = .{ .run = .{ .path = "/bin/settings", .name = "settings", .arg = "about" } } },
    .{ .label = "Exit to shell", .category = .session, .mark = .exit, .action = .quit },
    .{ .label = "Restart", .category = .session, .mark = .power, .action = .reboot },
    .{ .label = "Shut down", .category = .session, .mark = .power, .action = .power_off },
};

/// Whether a key produced a character somebody meant to type. Space counts;
/// anything below it is a control key wearing a codepoint.
fn printable(codepoint: u32) bool {
    return codepoint >= ' ' and codepoint < 0x7F;
}

/// What has been typed into the launcher's field.
///
/// Short on purpose: this is a name being narrowed down, not a sentence, and
/// a field that can hold more than a name invites one.
const Query = struct {
    buf: [24]u8 = @splat(0),
    len: usize = 0,

    fn slice(self: *const Query) []const u8 {
        return self.buf[0..self.len];
    }

    fn clear(self: *Query) bool {
        const had = self.len != 0;
        self.len = 0;
        return had;
    }

    fn push(self: *Query, c: u8) bool {
        if (self.len == self.buf.len) return false;
        self.buf[self.len] = c;
        self.len += 1;
        return true;
    }

    fn backspace(self: *Query) bool {
        if (self.len == 0) return false;
        self.len -= 1;
        return true;
    }
};

var launcher_query: Query = .{};

// ---------------------------------------------------------------------------
// Finding
//
// What somebody is looking for is as often a window they left open, or
// something the manager can already do, as it is a program. So typing looks
// in all three and ranks what comes back together, and each row says which
// source it came from. Browsing by category is what a growing list of
// programs is for; it is not what a search is for.
// ---------------------------------------------------------------------------

/// How many results are shown at once. The panel holds about this many rows,
/// and a ranked list whose tail nobody reads is a list that ranked for
/// nothing.
const MAX_FOUND = 12;

/// How many rows the panel ever holds: one category's worth, or a page of
/// results, whichever is more. One number, so every scratch array in here is
/// the same size and none of them can be the short one.
const MAX_LAUNCHER_ROWS = @max(MAX_FOUND, items.len);

const Found = struct {
    kind: Kind,
    label: []const u8,
    /// Where the row came from, in the words that place it: the category, the
    /// desktop, or the chord that does the same thing.
    note: []const u8,
    hit: ui.MenuItem.Run,
    mark: ?eui_icon.Icon,
    score: i32,
    at: usize,
    what: What,

    const Kind = enum {
        app,
        /// Something under /home, opened by whatever opens its sort of
        /// thing rather than by being named a program.
        file,
        /// A place inside a program, which is drawn with that program's own
        /// picture: what a result is inside is as much of the answer as what
        /// it is called.
        tab,
        win,
        run,

        /// The picture for a row that has none of its own. A window is a
        /// window whatever is in it, and something the keys can do is a key.
        fn mark(self: Kind) eui_icon.Icon {
            return switch (self) {
                .app, .tab => .apps,
                .win => .maximised,
                .run => .keyboard,
                // A file's picture comes from what it is, so a row that
                // reaches here is one whose sort was not recognised.
                .file => .document,
            };
        }
    };

    /// What choosing the row does.
    const What = union(enum) {
        /// The nth entry of `items`.
        entry: usize,
        /// A place inside a program: which program, and which of its places.
        place: struct { program: usize, anchor: usize },
        /// The nth window, which is focused and brought into view.
        window: usize,
        /// Something the manager can do, named by the same table the keys
        /// and the help pane read.
        verb: bindings.Action,
        /// The nth of the files gathered when the launcher opened.
        file: usize,
    };
};

var found: [MAX_FOUND]Found = undefined;
var found_count: usize = 0;
/// How many matched in all, which is not how many are shown: the footer says
/// both, so a list that stops at twelve says that it did.
var found_total: usize = 0;
/// How many things were looked at, so the footer can say what the search was
/// out of rather than just what it found.
var found_sources: usize = 0;

/// Offer one candidate to the list of results.
///
/// Insertion into a fixed row of the best so far, rather than a sort of
/// everything: the panel shows twelve, the sources hold a few dozen, and a
/// scratch array of every match would be the largest thing on this stack for
/// the sake of rows nobody sees.
fn offer(candidate: Found) void {
    found_total += 1;

    var at = found_count;
    while (at > 0) : (at -= 1) {
        const above = found[at - 1];
        if (!lessThan(candidate, above)) break;
        if (at < MAX_FOUND) found[at] = above;
    }

    if (at >= MAX_FOUND) return;
    found[at] = candidate;
    if (found_count < MAX_FOUND) found_count += 1;
}

fn lessThan(a: Found, b: Found) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.hit.at != b.hit.at) return a.hit.at < b.hit.at;
    if (a.label.len != b.label.len) return a.label.len < b.label.len;
    return a.at < b.at;
}

/// Look through everything for what has been typed.
///
/// Called when the query changes rather than when the panel is drawn: the
/// answer is the same until somebody types, and a search that runs every pass
/// is a search that runs sixty times a second for nothing.
fn refreshFound(desktop: *const layout.Desktop) void {
    found_count = 0;
    found_total = 0;
    found_sources = 0;

    const typed = launcher_query.slice();

    // Two columns is what a category of short names wants and what a ranked
    // list cannot have: a result carries where it came from as well as its
    // name, and half a panel is not wide enough for both.
    launcher.columns = if (typed.len == 0) LAUNCHER_COLUMNS else 1;

    if (typed.len == 0) return;

    var seq: usize = 0;

    for (items, 0..) |item, index| {
        if (item.action == .separator) continue;
        found_sources += 1;
        seq += 1;
        const hit = lib.find.match(item.label, typed) orelse continue;
        offer(.{
            .kind = .app,
            .label = item.label,
            .note = item.category.title(),
            .hit = runOf(hit),
            .mark = item.mark,
            .score = hit.score,
            .at = seq,
            .what = .{ .entry = index },
        });
    }

    // The places inside programs, which the programs themselves declare.
    // Somebody looking for the wallpaper is looking for a thing with a name,
    // not for the program that happens to contain it.
    for (anchors.all, 0..) |program, program_index| {
        for (program.anchors, 0..) |anchor, anchor_index| {
            found_sources += 1;
            seq += 1;
            const hit = lib.find.match(anchor.says, typed) orelse continue;
            offer(.{
                .kind = .tab,
                .label = anchor.says,
                .note = program.name,
                .hit = runOf(hit),
                .mark = program.mark,
                .score = hit.score,
                .at = seq,
                .what = .{ .place = .{ .program = program_index, .anchor = anchor_index } },
            });
        }
    }

    // What is in /home, drawn with the picture its sort of file gets and
    // said with the words the recogniser uses for it.
    for (files[0..file_count], 0..) |*one, index| {
        found_sources += 1;
        seq += 1;
        const hit = lib.find.match(one.name(), typed) orelse continue;
        offer(.{
            .kind = .file,
            .label = one.name(),
            .note = one.what.says(),
            .hit = runOf(hit),
            .mark = eui_icon.forFamily(one.what.family()),
            .score = hit.score,
            .at = seq,
            .what = .{ .file = index },
        });
    }

    for (desktop.windows, 0..) |window, index| {
        if (!window.used) continue;
        found_sources += 1;
        seq += 1;
        const name = desktop.windows[index].name();
        const hit = lib.find.match(name, typed) orelse continue;
        offer(.{
            .kind = .win,
            .label = name,
            .note = desktopSaid(window.tag),
            .hit = runOf(hit),
            .mark = Found.Kind.win.mark(),
            .score = hit.score,
            .at = seq,
            .what = .{ .window = index },
        });
    }

    // Everything the keyboard can do, findable by name. The chord comes with
    // it, so the launcher is also where somebody learns there was a key for
    // what they just went looking for.
    for (bindings.all) |binding| {
        found_sources += 1;
        seq += 1;
        const hit = lib.find.match(binding.says, typed) orelse continue;
        offer(.{
            .kind = .run,
            .label = binding.says,
            .note = binding.chord,
            .hit = runOf(hit),
            .mark = Found.Kind.run.mark(),
            .score = hit.score,
            .at = seq,
            .what = .{ .verb = binding.action },
        });
    }
}

fn runOf(hit: lib.find.Match) ui.MenuItem.Run {
    return .{ .at = @intCast(hit.at), .len = @intCast(hit.len) };
}

/// Which desktop a window is on, in the words and the numbers the tabs use.
fn desktopSaid(tag: u8) []const u8 {
    const names = comptime blk: {
        var out: [layout.MAX_DESKTOPS][]const u8 = undefined;
        for (&out, 0..) |*name, i| {
            name.* = std.fmt.comptimePrint("desktop {d}", .{layout.numberOf(@as(u8, @intCast(i)))});
        }
        break :blk out;
    };
    return names[@min(tag, names.len - 1)];
}

/// Which category the launcher is showing.
var launcher_category: Category = .tools;
/// The categories themselves are a list like any other, so they are one.
var launcher_rail: ui.Menu = .{ .ground = .sunken };

/// How many things are under a category, which is what makes the rail worth
/// reading rather than just worth clicking.
fn countIn(which: Category) usize {
    var n: usize = 0;
    for (items) |item| {
        if (item.category == which) n += 1;
    }
    return n;
}

/// The rail's rows: every category, with how much is behind it.
fn categoryItems(into: []ui.MenuItem) []ui.MenuItem {
    var n: usize = 0;
    for (std.enums.values(Category)) |which| {
        if (n == into.len or countIn(which) == 0) continue;
        // The name and its picture, and no count. A number beside a category
        // claims to say how much is in it, and what it would be counting is
        // this table rather than what is installed on the machine.
        into[n] = .{ .label = which.title(), .mark = which.icon() };
        n += 1;
    }
    return into[0..n];
}

/// What the launcher's own indices mean: the nth row of the shown category
/// is which entry of `items`.
var launcher: ui.Menu = .{ .columns = LAUNCHER_COLUMNS };

/// Which tab's menu is open, if any. Held here because it is the bar's own
/// state: nothing else needs to know a menu exists.
var menu_tab: ?u8 = null;
var window_menu: ui.Menu = .{};
/// The bar has keyboard focus, so arrows move between tabs rather than
/// reaching whatever window is focused.
var keyboard_focus = false;
var focus_tab: u8 = 0;
/// Which reading at the right end the keyboard is on, if it has walked past
/// the last tab. The bar is one traversal from the button at one end to the
/// clock at the other: a reading reachable only by pointer is a reading that
/// stops working when the touchpad does.
var focus_status: ?usize = null;

pub fn hasFocus() bool {
    return keyboard_focus;
}

/// Whether anything is open over the bar. Every panel it can put on the
/// screen counts: the caller uses this to decide whether the overlay has to
/// be drawn again, and one left out is one that disappears on the next
/// repaint.
pub fn menuOpen() bool {
    return menu_tab != null or launcher.open or sound_open or net_open or
        power_open or clock_open;
}

/// The files a person might be looking for, gathered when the launcher
/// opens rather than while they type: a directory read per keystroke is a
/// seek per keystroke, and this machine's medium is behind a card reader.
///
/// Only under /home, and only two levels of it. Everything else on this
/// machine is the system's own, and somebody looking for the kernel is not
/// looking for it in a launcher.
const FILES_MAX = 64;
const FILE_PATH_MAX = 96;
const HOME = "/home";

const FoundFile = struct {
    path: [FILE_PATH_MAX]u8 = @splat(0),
    path_len: u8 = 0,
    /// Where the name starts within the path, so a row can say the name
    /// large and where it lives small without holding both.
    name_at: u8 = 0,
    what: lib.kind.Kind = .data,

    fn pathSlice(self: *const FoundFile) []const u8 {
        return self.path[0..self.path_len];
    }

    fn name(self: *const FoundFile) []const u8 {
        return self.path[self.name_at..self.path_len];
    }
};

var files: [FILES_MAX]FoundFile = @splat(.{});
var file_count: usize = 0;

fn gatherFiles() void {
    file_count = 0;
    walk(HOME, 1);
}

/// One directory, and its own directories to `depth` more.
fn walk(where: []const u8, depth: u8) void {
    var names: [1024]u8 = undefined;
    var listing = dir.Listing{};
    dir.read(where, &names, &listing) catch return;

    for (listing.items()) |entry| {
        if (file_count == files.len) return;
        if (std.mem.eql(u8, entry.name, dir.PARENT)) continue;

        var joined: [FILE_PATH_MAX]u8 = undefined;
        const path = paths.join(where, entry.name, &joined);
        if (path.len > FILE_PATH_MAX) continue;

        if (entry.is_dir) {
            if (depth > 0) walk(path, depth - 1);
            continue;
        }

        var one = FoundFile{
            .path_len = @intCast(path.len),
            .name_at = @intCast(path.len - entry.name.len),
            // By name rather than by bytes: this runs over every file under
            // /home when the launcher opens, and reading each of them would
            // be a seek apiece for an icon.
            .what = lib.kind.fromName(entry.name) orelse .data,
        };
        @memcpy(one.path[0..path.len], path);
        files[file_count] = one;
        file_count += 1;
    }
}

/// Open the applications menu, from the V button or a key.
pub fn openLauncher(desktop: *const layout.Desktop) void {
    _ = launcher_query.clear();
    gatherFiles();
    refreshFound(desktop);
    var rows: [MAX_LAUNCHER_ROWS]ui.MenuItem = undefined;
    launcher.showAt(menuItems(&rows));
    menu_tab = null;
    keyboard_focus = true;
}

/// The rows on show: everything in the chosen category, or everything the
/// query matches whatever category it is in.
///
/// Typing crosses categories on purpose. Somebody who types "set" is not
/// saying which drawer to look in, and a search that only looked in the
/// drawer already open would be a search that finds nothing most of the time.
fn menuItems(out: []ui.MenuItem) []ui.MenuItem {
    var n: usize = 0;

    if (launcher_query.slice().len == 0) {
        for (items) |item| {
            if (n == out.len) break;
            if (item.category != launcher_category) continue;
            out[n] = .{ .label = item.label, .mark = item.mark };
            n += 1;
        }
        return out[0..n];
    }

    // Ranked across every source, each row saying which it came from and
    // what in it matched.
    for (found[0..found_count]) |one| {
        if (n == out.len) break;
        out[n] = .{
            .label = one.label,
            .mark = one.mark orelse one.kind.mark(),
            .hit = one.hit,
            .detail = one.note,
        };
        n += 1;
    }

    if (n == 0 and out.len > 0) {
        out[0] = .{ .label = "Nothing matches", .kind = .disabled };
        n = 1;
    }
    return out[0..n];
}

/// What a row of the launcher does when it is chosen.
///
/// Two lists wear the same rows: one category in order, or what the query
/// found across every source. Which of them is on show decides what a row
/// number means, and nothing else in here has to know that.
fn launcherChoice(row: usize) ?Found.What {
    if (launcher_query.slice().len != 0) {
        if (row >= found_count) return null;
        return found[row].what;
    }

    var n: usize = 0;
    for (items, 0..) |item, index| {
        if (item.category != launcher_category) continue;
        if (n == row) return .{ .entry = index };
        n += 1;
    }
    return null;
}

/// The launcher, floating over the middle of the screen.
///
/// Not a menu hanging off the V button: it is the one panel a person opens
/// without pointing at anything, usually from the keyboard, and a panel that
/// appears where the eyes already are is a panel that is read faster than one
/// that appears in a corner. It floats over the desktop rather than replacing
/// it, so what you were doing is still there behind it.
const Launcher = struct {
    panel: Rect,
    /// Where a query is typed, and what it would find.
    field: Rect,
    rail: Rect,
    list: Rect,
    /// What is on show and what the keys do, along the bottom.
    footer: Rect,
};

/// The size the design fixes, at a hundred per cent. Small enough that the
/// desktop stays legible around it, wide enough for two columns of names.
/// The height is the most it may take rather than what it always takes: a
/// panel of empty grey under five apps is a panel that looks broken.
const LAUNCHER_WIDTH: i32 = 460;
const LAUNCHER_HEIGHT: i32 = 300;
const LAUNCHER_RAIL: i32 = 108;
const LAUNCHER_COLUMNS: u8 = 2;

/// How tall the panel wants to be: the field it is typed into, the rows it
/// has to show, and the strip along the bottom.
fn wantedHeight() i32 {
    const t = theme.current();
    const field_h = t.control_height + t.padding;
    const footer_h = Surface.textHeight() + t.padding * 2;

    const shown: i32 = if (launcher_query.slice().len == 0)
        // Browsing, in columns: the rail is as long as the longest of them.
        @intCast(@max(perColumn(countIn(launcher_category)), std.enums.values(Category).len))
    else
        // Ranked, one column, and at least the line that says there is
        // nothing rather than a panel with no body at all.
        @intCast(@max(found_count, 1));

    return field_h + shown * ui.rowHeight() + 2 + footer_h;
}

/// How many rows a category takes when it is dealt into the launcher's
/// columns, which is what decides how tall the list is.
fn perColumn(count: usize) usize {
    const columns: usize = LAUNCHER_COLUMNS;
    return (count + columns - 1) / columns;
}

fn launcherPanel(width: i32, height: i32) Launcher {
    const t = theme.current();

    // The design's size, or the screen's if that is smaller: a panel wider
    // than the machine it is on is a panel with its right half missing.
    const margin = t.menu_padding * 2;
    const panel_w = @min(theme.enlarged(LAUNCHER_WIDTH), width - margin);
    const most = @min(theme.enlarged(LAUNCHER_HEIGHT), height - band(height).h - margin);

    // As tall as what it is showing, and never taller than the design's own
    // size. The top stays where the tallest panel's top would be, so a list
    // that grows and shrinks as somebody types does not move the field they
    // are typing into.
    const panel_h = @min(most, wantedHeight());
    const panel = Rect{
        .x = @divTrunc(width - panel_w, 2),
        .y = @divTrunc(height - most, 2),
        .w = panel_w,
        .h = panel_h,
    };

    const field = Rect{ .x = panel.x, .y = panel.y, .w = panel.w, .h = t.control_height + t.padding };
    const rail_w = @min(theme.enlarged(LAUNCHER_RAIL), @divTrunc(panel.w, 3));
    const footer_h = Surface.textHeight() + t.padding * 2;
    const footer = Rect{
        .x = panel.x,
        .y = panel.bottom() - footer_h,
        .w = panel.w,
        .h = footer_h,
    };

    return .{
        .panel = panel,
        .field = field,
        .rail = .{ .x = panel.x, .y = field.bottom(), .w = rail_w, .h = footer.y - field.bottom() },
        .list = .{
            .x = panel.x + rail_w,
            .y = field.bottom(),
            .w = panel.w - rail_w,
            .h = footer.y - field.bottom(),
        },
        .footer = footer,
    };
}

/// Where the rows are drawn. A query takes the rail's room as well, because
/// what is on show is then everything that matches rather than one category.
fn launcherList(at: Launcher) Rect {
    if (launcher_query.slice().len == 0) return at.list;
    return .{ .x = at.rail.x, .y = at.rail.y, .w = at.panel.w, .h = at.rail.h };
}

/// The strip along the bottom: what is on show, and what the keys do.
///
/// The count is the honest one. A ranked list that stops at twelve says so,
/// because a search that quietly dropped the thing being looked for is worse
/// than one that says there was more.
fn paintLauncherFooter(surface: Surface, area: Rect) void {
    var said: [40]u8 = @splat(0);
    var line = str.Builder{ .buf = &said };

    if (launcher_query.slice().len == 0) {
        line.text(launcher_category.title());
        line.text(", ");
        line.number(countIn(launcher_category));
        line.text(" of ");
        line.number(items.len);
    } else {
        line.number(found_total);
        line.text(" of ");
        line.number(found_sources);
        line.text(" match");
    }

    const hints: []const eui_keys.Key = if (launcher_query.slice().len == 0)
        &BROWSE_KEYS
    else if (highlightedIsFile())
        &FIND_FILE_KEYS
    else
        &FIND_KEYS;

    // The same strip every window with keys along its bottom draws.
    eui_keys.bar(surface, area, hints, line.done());
}

/// Whether the row under the cursor is a file, which is what decides
/// whether the keys along the bottom mention the second thing it can do.
fn highlightedIsFile() bool {
    if (launcher.selected >= found_count) return false;
    return found[launcher.selected].kind == .file;
}

const BROWSE_KEYS = [_]eui_keys.Key{
    .{ .key = "tab", .label = "category" },
    .{ .key = "\u{21B5}", .label = "run" },
    .{ .key = "esc", .label = "close" },
};

const FIND_KEYS = [_]eui_keys.Key{
    .{ .key = "\u{21B5}", .label = "run" },
    .{ .key = "esc", .label = "close" },
};

/// What a file row can do, which is one thing more than anything else here.
const FIND_FILE_KEYS = [_]eui_keys.Key{
    .{ .key = "\u{21B5}", .label = "open" },
    .{ .key = "shift+\u{21B5}", .label = "folder" },
    .{ .key = "esc", .label = "close" },
};

/// The strip along the top: what typing would do, and what has been typed.
fn paintLauncherField(surface: Surface, area: Rect) void {
    const t = theme.current();
    surface.fill(area, t.surface_hot);
    surface.fill(.{ .x = area.x, .y = area.bottom() - 1, .w = area.w, .h = 1 }, t.line);

    const text_y = area.y + @divTrunc(area.h - Surface.textHeight(), 2);
    var x = area.x + t.menu_padding;

    surface.icon(x, Surface.iconTopFor(text_y), .search, t.text_dim);
    x += Surface.iconSize() + t.gap;

    const typed = launcher_query.slice();
    if (typed.len == 0) {
        surface.text(x, text_y, "type to find an app, a file, a window or a command", t.text_dim);
        return;
    }

    surface.text(x, text_y, typed, t.text);
    // The caret after what has been typed, so a query being edited looks like
    // a query being edited.
    surface.fill(.{
        .x = x + Surface.textWidth(typed) + 2,
        .y = text_y,
        .w = 2,
        .h = Surface.textHeight(),
    }, t.text);
}

/// The tag one step along the row of existing desktops, wrapping.
fn neighbourTab(desktop: *const layout.Desktop, tag: u8, step: i32) u8 {
    var buf: [layout.MAX_DESKTOPS]u8 = undefined;
    const list = desktop.activeList(&buf);
    if (list.len == 0) return tag;

    const at = desktop.positionOf(tag) orelse return list[0];
    const count: i32 = @intCast(list.len);
    return list[@intCast(@mod(@as(i32, @intCast(at)) + step + count, count))];
}

/// Take keyboard control of the bar, starting on the current desktop's tab.
pub fn focus(desktop: *const layout.Desktop) void {
    keyboard_focus = true;
    focus_tab = desktop.tag;
    focus_status = null;
    menu_tab = null;
}

pub fn unfocus() void {
    keyboard_focus = false;
    focus_status = null;
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
        launchWidth() - addWidth();
    const each = @divTrunc(available, @as(i32, count));
    return @max(tabMinWidth(), @min(each, tabMaxWidth()));
}

fn launchRect(screen_h: i32) Rect {
    const t = theme.current();
    return .{ .x = 0, .y = band(screen_h).y, .w = launchWidth(), .h = t.bar_height - 1 };
}

fn tabRect(width: i32, height: i32, count: u8, index: u8) Rect {
    const t = theme.current();
    const each = tabWidth(width, height, count);
    return .{
        .x = launchWidth() + @as(i32, index) * each,
        .y = band(height).y,
        .w = each,
        .h = t.bar_height - 1,
    };
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

pub fn paint(surface: Surface, width: i32, height: i32, desktop: *const layout.Desktop) void {
    const t = theme.current();
    const area = band(height);
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

    var tags: [layout.MAX_DESKTOPS]u8 = undefined;
    const shown = desktop.activeList(&tags);
    for (shown, 0..) |tag, position| {
        paintTab(
            surface,
            tabRect(width, height, @intCast(shown.len), @intCast(position)),
            desktop,
            tag,
        );
    }

    paintAdd(surface, width, height, desktop);
    paintStatus(surface, width, height);
}

/// What the bar shows about the machine, and where.
///
/// One list, read by the painter and by the hit test, so a screen too narrow
/// for all of them drops the same one from both.
pub fn statusSlots(width: i32, height: i32, into: []status.Slot) []status.Slot {
    const area = Rect{ .x = 0, .y = band(height).y, .w = width, .h = theme.current().bar_height };
    var wanted: [status.MAX]status.Indicator = undefined;
    return status.place(area, shownNow(&wanted), into);
}

/// In the order they sit, and only what this machine has: a desktop with no
/// pack should not carry an empty battery, and the row is the same list the
/// hit test reads. What is furthest left goes first on a narrow screen,
/// which is why the clock is last.
fn shownNow(into: []status.Indicator) []status.Indicator {
    var count: usize = 0;
    for ([_]status.Indicator{ .network, .sound, .battery, .clock }) |which| {
        if (count == into.len) break;
        // The power indicator stands for the pack and for the panel's lamp.
        // A machine with no battery but a backlight still has something to
        // change behind it, and hiding it would hide the brightness.
        if (which == .battery and pack == null and lamp == null) continue;
        into[count] = which;
        count += 1;
    }
    return into[0..count];
}

fn paintStatus(surface: Surface, width: i32, height: i32) void {
    const t = theme.current();
    var buf: [status.MAX]status.Slot = undefined;
    for (statusSlots(width, height, &buf)) |slot| {
        switch (slot.which) {
            .clock => {
                if (clock_open) surface.fill(slot.area, t.accent);
                paintClock(surface, slot.area, clock_open);
            },
            .network => paintNetwork(surface, slot.area),
            .sound => paintSound(surface, slot.area),
            .battery => paintBattery(surface, slot.area),
        }

        // Where the keyboard is, said the way every other control says it.
        if (keyboard_focus and focus_status != null) {
            const at = std.enums.values(status.Indicator)[focus_status.?];
            if (at == slot.which) ui.paintFocusRing(surface, slot.area.inset(1), t.accent);
        }
    }
}

fn addRect(width: i32, height: i32, desktop: *const layout.Desktop) Rect {
    const t = theme.current();
    var tags: [layout.MAX_DESKTOPS]u8 = undefined;
    const shown = desktop.activeList(&tags);
    const last = tabRect(width, height, @intCast(shown.len), @intCast(shown.len - 1));
    return .{ .x = last.right(), .y = band(height).y, .w = addWidth(), .h = t.bar_height - 1 };
}

/// A plus, drawn rather than lettered: at this size two strokes read better
/// than a glyph, and it is unambiguous in any font.
fn paintAdd(surface: Surface, width: i32, height: i32, desktop: *const layout.Desktop) void {
    if (desktop.firstInactive() == null) return;

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
        var rows: [MAX_LAUNCHER_ROWS]ui.MenuItem = undefined;
        const before = launcher.selected;
        const at = launcherPanel(width, height);

        var cat_rows: [MAX_LAUNCHER_ROWS]ui.MenuItem = undefined;
        const cats = categoryItems(&cat_rows);

        // Moving over a category shows it, which is what makes the rail
        // browsable rather than something to click through.
        const on_rail = if (launcher_query.slice().len == 0) ui.Menu.rowAt(at.rail, cats, x, y) else null;
        if (on_rail) |row| {
            launcher_rail.selected = row;
            if (Category.parse(cats[row].label)) |which| {
                if (which != launcher_category) {
                    launcher_category = which;
                    launcher.selected = 0;
                }
            }
            return true;
        }
        launcher.hover(launcherList(at), menuItems(&rows), x, y);
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
        sound_menu.hover(strip.below(soundPanel(width, height)), soundItems(&rows), x, y);
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
        const t = theme.current();
        var rows: [MAX_LAUNCHER_ROWS]ui.MenuItem = undefined;
        const at = launcherPanel(width, height);

        paintLauncherField(surface, at.field);

        var cat_rows: [MAX_LAUNCHER_ROWS]ui.MenuItem = undefined;
        // The rail goes when a query does the choosing: what is on show is
        // then everything that matches, and a category highlighted beside it
        // would be pointing at the wrong thing.
        if (launcher_query.slice().len == 0) {
            launcher_rail.paint(surface, at.rail, categoryItems(&cat_rows));
        }
        launcher.paint(surface, launcherList(at), menuItems(&rows));
        paintLauncherFooter(surface, at.footer);

        // One edge around the whole panel, drawn last so the parts inside it
        // cannot paint over it.
        surface.frame(at.panel, t.bar_line);
    }

    if (sound_open) paintSoundMenu(surface, width, height);
    if (net_open) paintNetMenu(surface, width, height);
    if (power_open) paintPowerMenu(surface, width, height);
    if (clock_open) paintClockMenu(surface, width, height);
}

/// The launcher button, which carries the system's own mark.
fn paintLaunch(surface: Surface, height: i32) void {
    const t = theme.current();
    const area = launchRect(height);

    if (launcher.open) surface.fill(area, t.accent);
    surface.icon(
        area.x + @divTrunc(area.w - Surface.iconSize(), 2),
        area.y + @divTrunc(area.h - Surface.iconSize(), 2),
        .logo,
        if (launcher.open) t.accent_text else t.bar_text,
    );
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

/// Whether the manager's modifier is down, for the number chips.
var super_held = false;

/// Record the modifier's state. True when it changed, which is the caller's
/// cue to repaint the bar.
pub fn setSuperHeld(held: bool) bool {
    if (super_held == held) return false;
    super_held = held;
    return true;
}

fn paintTab(surface: Surface, area: Rect, desktop: *const layout.Desktop, tag: u8) void {
    const index = tag;
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
        .w = area.w - t.padding * 2 - (if (count > 1) markerWidth() else 0),
        .h = area.h,
    };

    const clipped = surface.clipped(text_area);
    clipped.text(
        text_area.x,
        area.y + @divTrunc(area.h - Surface.textHeight(), 2),
        if (label.len == 0) "untitled" else label,
        // A desktop with nothing on it reads quieter, but only where quieter
        // is still legible: on the accent ground the dim ink is grey on blue,
        // and the tab you are looking at is the one that has to be readable.
        if (count == 0 and !current) t.text_dim else color,
    );

    if (super_held) {
        var digit: [1]u8 = .{'0' + layout.numberOf(tag)};
        surface.clipped(area).text(
            area.right() - markerWidth(),
            area.y + @divTrunc(area.h - Surface.textHeight(), 2),
            &digit,
            if (current) t.accent_text else t.text_dim,
        );
    } else
    // A desktop showing one window at full size says so, because otherwise
    // the tab of a stack of three and the tab of a stack of three with two
    // of them hidden are the same tab.
    if (count > 1) {
        if (desktop.tag == index and desktop.isMaximised()) {
            surface.icon(
                area.right() - markerWidth(),
                area.y + @divTrunc(area.h - Surface.iconSize(), 2),
                .maximised,
                color,
            );
        } else {
            paintStackMarker(surface, area, color);
        }
    }

    // A hairline between tabs, so two adjacent ones do not read as one. Full
    // height, because an inset one draws a notch into the accent rather than
    // an edge between two tabs.
    surface.fill(.{ .x = area.right() - 1, .y = area.y, .w = 1, .h = area.h }, t.bar_line);
}

/// Three short rules, the mark everything uses for "there is a list behind
/// this". Drawn rather than taken from the font: at this size a glyph is a
/// smudge, and three rules are three rules at any size.
fn paintStackMarker(surface: Surface, area: Rect, color: draw.Color) void {
    const width = markerWidth() - 3;
    const x = area.right() - markerWidth() + 1;
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
fn netWidth() i32 {
    return theme.enlarged(216);
}

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

    var anchor = Rect{ .x = width, .y = band(height).y, .w = 0, .h = theme.current().bar_height };
    for (slots) |slot| {
        if (slot.which == .network) anchor = slot.area;
    }

    var rows: [MAX_IFACES + 2]ui.MenuItem = undefined;
    const list = netItems(&rows);

    return popover.place(
        anchor,
        netWidth(),
        ui.Menu.sizeFor(list, netWidth()).h,
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
        area.x + @divTrunc(area.w - Surface.iconSize(), 2),
        area.y + @divTrunc(area.h - Surface.iconSize(), 2),
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
fn soundWidth() i32 {
    return theme.enlarged(224);
}

/// The strip above the rows: the icon, the slider and the percentage, inside
/// the same inset the rows below it use.
pub fn refresh() void {
    readSound();
    readNetwork();
    readPower();
}

// ---------------------------------------------------------------------------
// Battery
//
// What is left, and whether it is filling or emptying. The menu behind it
// carries the backlight, which is the one power setting a person changes
// often enough to want it in the bar.
// ---------------------------------------------------------------------------

var pack: ?platform.Battery = null;
var charge: u32 = 0;

fn readBattery() void {
    pack = platform.battery();
    charge = if (pack) |p| platform.charge(p) orelse 0 else 0;
}

fn paintBattery(surface: Surface, area: Rect) void {
    const t = theme.current();

    if (power_open) surface.fill(area, t.accent);

    // No pack, but a lamp: the picture says what the menu is about rather
    // than drawing an empty battery on a machine that has none.
    const p = pack orelse {
        if (lamp == null) return;
        surface.icon(
            area.x + @divTrunc(area.w - Surface.iconSize(), 2),
            area.y + @divTrunc(area.h - Surface.iconSize(), 2),
            .display,
            if (power_open) t.accent_text else t.bar_text,
        );
        return;
    };

    const icon_x = area.x + t.menu_padding;
    const icon_y = area.y + @divTrunc(area.h - Surface.iconSize(), 2);

    // Low enough that it is a thing to act on takes the warning colour, which
    // is the firmware's own threshold rather than a number chosen here.
    const low = p.low != 0 and p.remaining != platform.Battery.UNKNOWN and p.remaining <= p.low;
    const critical = p.critical != 0 or low;
    const ink = if (power_open)
        t.accent_text
    else if (critical)
        t.warning
    else
        t.bar_text;

    const which = eui_icon.battery(p.state() == .charging, critical);
    surface.icon(icon_x, icon_y, which, ink);

    // The charge inside the outline the picture leaves hollow. The bolt and
    // the bang fill their own cell, so neither gets a level drawn through it.
    if (eui_icon.holdsCharge(which)) {
        const inside = eui_icon.battery_inside;
        const filled = @divTrunc(@as(i32, inside.w) * @as(i32, @intCast(@min(charge, 100))), 100);
        if (filled > 0) surface.fill(.{
            .x = icon_x + inside.x,
            .y = icon_y + inside.y,
            .w = filled,
            .h = inside.h,
        }, ink);
    }

    var text: [5]u8 = @splat(0);
    const spelled = percentText(&text, @intCast(@min(charge, 100)));
    surface.text(
        area.right() - t.menu_padding - Surface.textWidth(spelled),
        area.y + @divTrunc(area.h - Surface.textHeight(), 2),
        spelled,
        ink,
    );
}

// ---------------------------------------------------------------------------
// The power menu
//
// What the pack is doing, and the one thing about power a person changes
// often enough to want it two clicks away: how bright the panel is.
// ---------------------------------------------------------------------------

var power_open = false;
var power_menu: ui.Menu = .{};
var lamp: ?platform.Backlight = null;

/// The level to come back to when the lamp is pressed a second time.
var lamp_was: u32 = 0;

fn readPower() void {
    readBattery();
    lamp = platform.backlight();
}

/// The level as the panel counts them. Not a percentage: the steps are the
/// panel's, and a percentage rounded onto sixteen of them makes some of them
/// unreachable.
fn lampText(buf: []u8) []const u8 {
    const panel = lamp orelse return "";
    var line = str.Builder{ .buf = buf };
    line.number(panel.level);
    line.text(" of ");
    line.number(panel.max);
    return line.done();
}

fn setLamp(step: u32) void {
    lamp = platform.setBacklight(step) orelse lamp;
}

/// Down to the dimmest the panel still shows something, and back again.
///
/// The dimmest is one rather than zero: a backlight at zero is a black screen,
/// and a control that can turn the screen off from the bar is a control that
/// will turn the screen off by accident.
fn toggleDim() void {
    const panel = lamp orelse return;
    if (panel.level > 1) {
        lamp_was = panel.level;
        setLamp(1);
    } else {
        setLamp(if (lamp_was > 1) lamp_was else panel.max);
    }
}

fn powerItems(into: []ui.MenuItem) []ui.MenuItem {
    var count: usize = 0;

    if (pack) |p| {
        if (count < into.len) {
            into[count] = .{
                .label = p.stateLabel(),
                .kind = .disabled,
                .mark = .battery,
                .detail = chargeText(),
            };
            count += 1;
        }
        if (p.runtimeLeft()) |left| {
            if (count < into.len) {
                into[count] = .{ .label = "Time left", .kind = .disabled, .detail = leftText(left) };
                count += 1;
            }
        }
        if (p.health()) |percent| {
            if (count < into.len) {
                into[count] = .{ .label = "Health", .kind = .disabled, .detail = healthText(percent) };
                count += 1;
            }
        }
    } else if (count < into.len) {
        into[count] = .{ .label = "No battery", .kind = .disabled, .mark = .battery };
        count += 1;
    }

    if (count + 2 <= into.len) {
        into[count] = .{ .kind = .separator };
        into[count + 1] = .{ .label = "Power settings", .mark = .sliders };
        count += 2;
    }
    return into[0..count];
}

var charge_text: [8]u8 = @splat(0);
var left_text: [16]u8 = @splat(0);
var health_text: [8]u8 = @splat(0);

fn chargeText() []const u8 {
    return percentText(&charge_text, @intCast(@min(charge, 100)));
}

fn leftText(left: platform.Battery.Left) []const u8 {
    var line = str.Builder{ .buf = &left_text };
    line.duration(@as(usize, left.hours) * 3600 + @as(usize, left.minutes) * 60);
    return line.done();
}

fn healthText(percent: u32) []const u8 {
    return percentText(&health_text, @intCast(@min(percent, 100)));
}

fn powerWidth() i32 {
    return theme.enlarged(210);
}

fn powerPanel(width: i32, height: i32) Rect {
    var buf: [status.MAX]status.Slot = undefined;
    const slots = statusSlots(width, height, &buf);

    var anchor = Rect{ .x = width, .y = band(height).y, .w = 0, .h = theme.current().bar_height };
    for (slots) |slot| {
        if (slot.which == .battery) anchor = slot.area;
    }

    var rows: [8]ui.MenuItem = undefined;
    const rows_high = ui.Menu.sizeFor(powerItems(&rows), powerWidth()).h;

    return popover.place(
        anchor,
        powerWidth(),
        (if (lamp != null) strip.height() else 0) + rows_high,
        .{ .x = 0, .y = 0, .w = width, .h = height },
        if (settings.current().bar == .top) .below else .above,
    );
}

/// Where the rows start: under the strip when there is a panel to dim, and at
/// the top when there is not. A machine with no backlight gets no groove for
/// a level it cannot set.
fn powerRows(panel: Rect) Rect {
    return if (lamp == null) panel else strip.below(panel);
}

fn paintPowerMenu(surface: Surface, width: i32, height: i32) void {
    const t = theme.current();
    const panel = powerPanel(width, height);

    if (lamp) |panel_light| {
        const bar_area = strip.of(panel);
        var buf: [16]u8 = @splat(0);
        const spelled = lampText(&buf);

        surface.fill(bar_area, t.surface);
        surface.frame(bar_area, t.line);

        const button = strip.button(bar_area);
        surface.icon(
            button.x,
            button.y + @divTrunc(button.h - Surface.iconSize(), 2),
            .display,
            t.text,
        );

        const groove = strip.track(bar_area, spelled);
        ui.paintSlider(
            surface,
            groove,
            .{ .min = 1, .max = @intCast(panel_light.max) },
            @intCast(panel_light.level),
            .idle,
            false,
            .{},
        );

        const number = strip.reading(bar_area, spelled);
        surface.text(number.x, number.y, spelled, t.text);
    }

    var rows: [8]ui.MenuItem = undefined;
    power_menu.paint(surface, powerRows(panel), powerItems(&rows));
}

fn readSound() void {
    level = audio.master() orelse .{ .percent = 0, .muted = 0 };
    sound_port_count = audio.ports(&sound_ports).len;
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

    var anchor = Rect{ .x = width, .y = band(height).y, .w = 0, .h = theme.current().bar_height };
    for (slots) |slot| {
        if (slot.which == .sound) anchor = slot.area;
    }

    var rows: [MAX_PORTS + 4]ui.MenuItem = undefined;
    const list = soundItems(&rows);
    const rows_high = ui.Menu.sizeFor(list, soundWidth()).h;

    return popover.place(
        anchor,
        soundWidth(),
        strip.height() + rows_high,
        .{ .x = 0, .y = 0, .w = width, .h = height },
        if (settings.current().bar == .top) .below else .above,
    );
}

fn paintSound(surface: Surface, area: Rect) void {
    const t = theme.current();
    const which = eui_icon.volume(level.percent, level.muted != 0);
    const inside = sound_open;

    if (inside) surface.fill(area, t.accent);
    surface.icon(
        area.x + @divTrunc(area.w - Surface.iconSize(), 2),
        area.y + @divTrunc(area.h - Surface.iconSize(), 2),
        which,
        if (inside) t.accent_text else t.bar_text,
    );
}

fn paintSoundMenu(surface: Surface, width: i32, height: i32) void {
    const t = theme.current();
    const panel = soundPanel(width, height);
    const bar_area = strip.of(panel);

    var text: [5]u8 = @splat(0);
    const spelled = percentText(&text, level.percent);

    surface.fill(bar_area, t.surface);
    surface.frame(bar_area, t.line);

    // The picture is the mute: pressing what says how loud it is is how a
    // person silences it.
    const button = strip.button(bar_area);
    surface.icon(
        button.x,
        button.y + @divTrunc(button.h - Surface.iconSize(), 2),
        eui_icon.volume(level.percent, level.muted != 0),
        t.text,
    );

    const groove = strip.track(bar_area, spelled);
    ui.paintSlider(surface, groove, .{ .min = 0, .max = 100 }, level.percent, .idle, false, .{});

    const number = strip.reading(bar_area, spelled);
    surface.text(number.x, number.y, spelled, t.text);

    var rows: [MAX_PORTS + 4]ui.MenuItem = undefined;
    sound_menu.paint(surface, strip.below(panel), soundItems(&rows));
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

// ---------------------------------------------------------------------------
// The clock's menu
//
// The bar has room for five characters, and five characters cannot say which
// day it is or whether the clock has ever been set. On a machine whose
// backup battery died years ago, both of those are things somebody looking at
// the clock actually wants to know.
// ---------------------------------------------------------------------------

var clock_open = false;
var clock_menu: ui.Menu = .{};

/// The lines, held rather than built into the rows: a menu item borrows the
/// text it is given, so the text has to outlive the call that draws it.
var clock_date: [40]u8 = @splat(0);
var clock_time: [16]u8 = @splat(0);
var clock_date_len: usize = 0;
var clock_time_len: usize = 0;
var clock_source: [40]u8 = @splat(0);
var clock_source_len: usize = 0;

pub fn clockOpen() bool {
    return clock_open;
}

/// Read the clock and spell it out. Called whenever the menu is drawn, since
/// the whole point of it is a reading that moves.
fn readClock() void {
    clock_date_len = 0;
    clock_time_len = 0;

    const us = sys.realtimeMicros() orelse return;
    const seconds = @divFloor(us, 1_000_000);
    const when = lib.civil.fromEpoch(seconds);

    var date = str.Builder{ .buf = &clock_date };
    date.text(lib.civil.dayNameFull(seconds));
    date.text(" ");
    date.number(when.day);
    date.text(" ");
    date.text(lib.civil.monthNameFull(when.month));
    date.text(" ");
    date.number(@intCast(when.year));
    clock_date_len = date.done().len;

    var clock = str.Builder{ .buf = &clock_time };
    twoDigits(&clock, when.hour);
    clock.byte(':');
    twoDigits(&clock, when.minute);
    clock.byte(':');
    twoDigits(&clock, when.second);
    clock.text(" UTC");
    clock_time_len = clock.done().len;
}

fn twoDigits(into: *str.Builder, value: u8) void {
    into.byte('0' + value / 10);
    into.byte('0' + value % 10);
}

/// Where the reading came from, asked once when the menu opens.
///
/// It changes when the time service lands an answer, not while somebody is
/// looking at a menu, and it costs a call to another process.
///
/// Said as a sentence rather than as the token the kernel keeps. "ntp" is
/// what the clock calls its source; "from a time server" is what it means,
/// and this is the one place a person reads it.
fn readClockSource() void {
    clock_source_len = 0;

    var raw: [16]u8 = @splat(0);
    const said = info.ask("clock", &raw);
    if (said.len == 0) return;

    var line = str.Builder{ .buf = &clock_source };
    if (std.mem.eql(u8, said, "ntp")) {
        line.text("Set from a time server");
    } else if (std.mem.eql(u8, said, "rtc")) {
        line.text("Set from the hardware clock");
    } else if (std.mem.eql(u8, said, "userspace")) {
        line.text("Set by hand");
    } else {
        line.text("Set from ");
        line.text(said);
    }
    clock_source_len = line.done().len;
}

fn clockItems(into: []ui.MenuItem) []ui.MenuItem {
    var n: usize = 0;

    if (clock_date_len == 0) {
        into[n] = .{ .label = "The clock has not been set", .kind = .disabled, .mark = .clock };
        return into[0 .. n + 1];
    }

    into[n] = .{ .label = clock_date[0..clock_date_len], .kind = .disabled, .mark = .clock };
    n += 1;
    into[n] = .{ .label = clock_time[0..clock_time_len], .kind = .disabled };
    n += 1;

    if (clock_source_len > 0 and n < into.len) {
        into[n] = .{ .kind = .separator };
        n += 1;
        into[n] = .{ .label = clock_source[0..clock_source_len], .kind = .disabled };
        n += 1;
    }
    return into[0..n];
}

fn clockPanel(width: i32, height: i32) Rect {
    var buf: [status.MAX]status.Slot = undefined;
    const slots = statusSlots(width, height, &buf);

    var anchor = Rect{ .x = width, .y = band(height).y, .w = 0, .h = theme.current().bar_height };
    for (slots) |slot| {
        if (slot.which == .clock) anchor = slot.area;
    }

    var rows: [4]ui.MenuItem = undefined;
    const shown = clockItems(&rows);
    const size = ui.Menu.sizeFor(shown, clockWidth(shown));

    return popover.place(
        anchor,
        size.w,
        size.h,
        .{ .x = 0, .y = 0, .w = width, .h = height },
        if (settings.current().bar == .top) .below else .above,
    );
}

/// As wide as the longest line it holds. A date is as long as its month's
/// name, so a fixed width would be too wide in May and too narrow in
/// September.
fn clockWidth(rows: []const ui.MenuItem) i32 {
    const t = theme.current();
    var widest: i32 = 0;
    for (rows) |row| {
        var w = Surface.textWidth(row.label) + ui.markWidth();
        if (row.detail.len > 0) w += t.menu_padding + Surface.textWidth(row.detail);
        widest = @max(widest, w);
    }
    return widest + t.menu_padding * 2;
}

fn paintClockMenu(surface: Surface, width: i32, height: i32) void {
    readClock();
    var rows: [4]ui.MenuItem = undefined;
    clock_menu.paint(surface, clockPanel(width, height), clockItems(&rows));
}

fn paintClock(surface: Surface, area: Rect, open: bool) void {
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

    surface.textCentred(area, buf[0..5], if (open) t.accent_text else t.bar_text);
}

fn menuRect(width: i32, height: i32, desktop: *const layout.Desktop, tab: u8) Rect {
    var tags: [layout.MAX_DESKTOPS]u8 = undefined;
    const shown = desktop.activeList(&tags);
    const position = desktop.positionOf(tab) orelse 0;
    const anchor = tabRect(width, height, @intCast(shown.len), @intCast(position));
    // Every row is a window's name, so what the size depends on is how many
    // there are rather than what they say.
    var rows: [layout.MAX_WINDOWS]ui.MenuItem = @splat(.{});
    const count = @min(@as(usize, desktop.countOn(tab)), rows.len);
    return dropFrom(
        anchor,
        height,
        ui.Menu.sizeFor(rows[0..count], @max(anchor.w, tabMaxWidth())),
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
    /// Show this window: the launcher found it by name, wherever it is.
    focus_window: usize,
    /// Something the keys can already do, named in the launcher instead.
    verb: bindings.Action,
    /// End the session and hand the display back.
    quit,
    reboot,
    power_off,
};

pub fn click(x: i32, y: i32, width: i32, height: i32, right: bool, desktop: *layout.Desktop) Action {

    // A menu is modal while open: a click outside dismisses it rather than
    // doing two things at once.
    if (launcher.open) {
        var rows: [MAX_LAUNCHER_ROWS]ui.MenuItem = undefined;
        const at = launcherPanel(width, height);
        if (launcher_query.slice().len == 0 and at.rail.contains(x, y)) return .consumed;
        const chosen = launcher.itemAt(launcherList(at), menuItems(&rows), x, y);
        launcher.hide();
        keyboard_focus = false;
        // The row is the nth of the category being shown, not the nth of
        // everything: the mapping is the one the list was built with.
        if (chosen) |row| {
            if (launcherChoice(row)) |choice| return activate(choice);
        }
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

    // Nothing in the clock's menu acts. It is a reading, and any click puts
    // it away.
    if (clock_open) {
        clock_open = false;
        return .consumed;
    }

    if (power_open) {
        const panel = powerPanel(width, height);

        if (lamp) |panel_light| {
            const bar_area = strip.of(panel);
            if (strip.button(bar_area).contains(x, y)) {
                toggleDim();
                return .consumed;
            }

            var buf: [16]u8 = @splat(0);
            const groove = strip.track(bar_area, lampText(&buf));
            if (groove.contains(x, y)) {
                const range = slider.Range{ .min = 1, .max = @intCast(panel_light.max) };
                setLamp(@intCast(slider.valueAt(groove, range, x)));
                return .consumed;
            }
        }

        var rows: [8]ui.MenuItem = undefined;
        const list = powerItems(&rows);
        const chosen = ui.Menu.rowAt(powerRows(panel), list, x, y);
        power_open = false;
        // The one row that acts is the last: where the settings are.
        if (chosen) |row| {
            if (list[row].kind == .item) {
                _ = sys.spawnDetached("/bin/settings", &.{ "settings", "power" });
            }
        }
        return .consumed;
    }

    if (sound_open) {
        const panel = soundPanel(width, height);

        const bar_area = strip.of(panel);
        if (strip.button(bar_area).contains(x, y)) {
            toggleSilence();
            return .consumed;
        }

        // The groove: dragging the level is the thing this menu is opened
        // for most often, and it stays open while it is done. Setting a
        // level on a silenced machine is asking to hear that level, so it
        // stops being silent and keeps where the pointer put it.
        var text: [5]u8 = @splat(0);
        const groove = strip.track(bar_area, percentText(&text, level.percent));
        if (groove.contains(x, y)) {
            const wanted = slider.valueAt(groove, .{ .min = 0, .max = 100 }, x);
            if (audio.setMaster(@intCast(wanted), false)) readSound();
            return .consumed;
        }

        var rows: [MAX_PORTS + 4]ui.MenuItem = undefined;
        const list = soundItems(&rows);
        if (ui.Menu.rowAt(strip.below(panel), list, x, y)) |row| {
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
            .battery => {
                readPower();
                power_open = true;
                power_menu.show();
            },
            .clock => {
                readClock();
                readClockSource();
                clock_open = true;
                clock_menu.show();
            },
        }
        return .consumed;
    }

    if (launchRect(height).contains(x, y)) {
        openLauncher(desktop);
        return .consumed;
    }

    if (desktop.firstInactive() != null and addRect(width, height, desktop).contains(x, y)) {
        _ = desktop.addDesktop();
        return .consumed;
    }

    var tags: [layout.MAX_DESKTOPS]u8 = undefined;
    const shown = desktop.activeList(&tags);
    for (shown, 0..) |tag, position| {
        const area = tabRect(width, height, @intCast(shown.len), @intCast(position));
        if (!area.contains(x, y)) continue;

        // Right-click closes the desktop; the marker opens its menu; the rest
        // of the tab switches to it.
        if (right) return .{ .close_desktop = tag };

        if (desktop.countOn(tag) > 1 and x >= area.right() - markerWidth()) {
            menu_tab = tag;
            window_menu.show();
        } else {
            desktop.view(tag);
        }
        return .consumed;
    }

    return .consumed;
}

/// Carry out a menu choice. Spawning happens here; anything that ends the
/// session is returned so the manager can put the display back first.
fn activate(choice: Found.What) Action {
    return switch (choice) {
        .entry => |index| activateEntry(index),
        .place => |where| blk: {
            const program = anchors.all[where.program];
            _ = sys.spawnDetached(
                program.path,
                &.{ program.name, program.anchors[where.anchor].arg },
            );
            break :blk .consumed;
        },
        .window => |index| .{ .focus_window = index },
        .verb => |what| .{ .verb = what },
        .file => |index| blk: {
            if (index < file_count) _ = opening.start(files[index].pathSlice());
            break :blk .consumed;
        },
    };
}

/// Show where a file lives, in the file manager, at the folder holding it.
/// Anything that is not a file is opened as it would have been: there is
/// nowhere else to show a window or a key.
fn reveal(choice: Found.What) Action {
    const which = switch (choice) {
        .file => |index| index,
        else => return activate(choice),
    };
    if (which >= file_count) return .consumed;

    const path = files[which].pathSlice();
    const folder = path[0..@max(files[which].name_at -| 1, 1)];
    _ = sys.spawnDetached("/bin/efm", &.{ "efm", folder });
    return .consumed;
}

fn activateEntry(index: usize) Action {
    if (index >= items.len) return .consumed;

    return switch (items[index].action) {
        .separator => .consumed,
        .run => |program| blk: {
            if (program.arg.len == 0) {
                _ = sys.spawnDetached(program.path, &.{program.name});
            } else {
                _ = sys.spawnDetached(program.path, &.{ program.name, program.arg });
            }
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
pub fn key(code: sys.KeyCode, codepoint: u32, mods: sys.Modifiers, desktop: *layout.Desktop) KeyResult {
    if (!keyboard_focus) return .ignored;

    if (launcher.open) {
        var rows: [MAX_LAUNCHER_ROWS]ui.MenuItem = undefined;

        // Typing narrows the list. This is what the panel is for: reaching a
        // program by naming it rather than by finding it, which is the whole
        // difference between a launcher and a menu.
        if (code == .backspace) {
            if (launcher_query.backspace()) {
                launcher.selected = 0;
                refreshFound(desktop);
            }
            return .handled;
        }
        if (printable(codepoint)) {
            if (launcher_query.push(@intCast(codepoint))) {
                launcher.selected = 0;
                refreshFound(desktop);
            }
            return .handled;
        }
        // Escape clears a query before it closes the panel: one keystroke to
        // undo a search is what a person expects, and closing on the first
        // press throws away the panel as well.
        if (code == .escape and launcher_query.clear()) {
            launcher.selected = 0;
            refreshFound(desktop);
            return .handled;
        }

        // Left and right walk the categories, and so does tab, which is
        // what the drawings show: the rail is a list too, and a launcher
        // reachable only by pointer stops working when the touchpad does.
        //
        // The list itself needs no left and right. Its rows are dealt down
        // one column before the next, so the down arrow that reaches the
        // bottom of the first column reaches the top of the second.
        const forward = code == .right or code == .tab;
        if (launcher_query.slice().len == 0 and (forward or code == .left)) {
            const all = std.enums.values(Category);
            const at = @intFromEnum(launcher_category);
            const step: usize = if (forward) 1 else all.len - 1;
            launcher_category = all[(at + step) % all.len];
            launcher_rail.selected = @intFromEnum(launcher_category);
            launcher.selected = 0;
            return .handled;
        }

        switch (launcher.key(code, menuItems(&rows))) {
            .chosen => {
                const chosen = launcher.selected;
                launcher.hide();
                keyboard_focus = false;
                if (launcherChoice(chosen)) |choice| {
                    // Held with shift, a file opens where it lives rather
                    // than in whatever opens it: the answer to "where is
                    // that?" as often as to "show me that".
                    pending = if (mods.shift) reveal(choice) else activate(choice);
                }
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
    if (statusMenuOpen()) return statusMenuKey(code);
    if (focus_status) |which| return statusKey(code, desktop, which);

    switch (code) {
        .left => {
            // Left from the first tab reaches the V button, so the whole bar
            // is one traversal rather than two islands.
            if (desktop.positionOf(focus_tab) orelse 0 == 0) {
                openLauncher(desktop);
            } else {
                focus_tab = neighbourTab(desktop, focus_tab, -1);
            }
        },
        // Right from the last tab reaches the readings, which is the other
        // end of the same traversal.
        .right => {
            if (onLastTab(desktop)) {
                focus_status = 0;
            } else {
                focus_tab = neighbourTab(desktop, focus_tab, 1);
            }
        },
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

fn onLastTab(desktop: *const layout.Desktop) bool {
    var buf: [layout.MAX_DESKTOPS]u8 = undefined;
    const list = desktop.activeList(&buf);
    if (list.len == 0) return true;
    return (desktop.positionOf(focus_tab) orelse 0) == list.len - 1;
}

/// The keyboard is on one of the readings at the right end.
fn statusKey(code: sys.KeyCode, desktop: *layout.Desktop, which: usize) KeyResult {
    switch (code) {
        .left => {
            if (which == 0) {
                focus_status = null;
                focus_tab = desktop.tag;
            } else {
                focus_status = which - 1;
            }
        },
        .right => focus_status = @min(which + 1, status.MAX - 1),
        .enter, .space, .down => openStatus(std.enums.values(status.Indicator)[which]),
        .escape => {
            unfocus();
            return .released;
        },
        else => return .ignored,
    }
    return .handled;
}

/// Open whatever a reading has to say, whichever way it was asked.
fn openStatus(which: status.Indicator) void {
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
        .battery => {
            readPower();
            power_open = true;
            power_menu.show();
        },
        .clock => {
            readClock();
            readClockSource();
            clock_open = true;
            clock_menu.show();
        },
    }
}

/// The pack has reached the level somebody asked to be told about.
///
/// The warning is the reading itself, opened where the reading lives: a
/// message that said "battery low" and nothing else would send somebody to
/// this panel anyway.
pub fn warnBattery() void {
    if (power_open) return;
    openStatus(.battery);
}

fn statusMenuOpen() bool {
    return sound_open or net_open or power_open or clock_open;
}

/// Every one of these panels reads rather than acts, bar the one row that
/// leads to the settings, so the keys they take are the ones that put them
/// away and the one that follows that row.
fn statusMenuKey(code: sys.KeyCode) KeyResult {
    switch (code) {
        .escape, .left => {
            closeStatusMenus();
            return .handled;
        },
        .enter, .space => {
            const to = if (power_open) "power" else if (sound_open) "audio" else "";
            closeStatusMenus();
            if (to.len == 0) {
                _ = sys.spawnDetached("/bin/settings", &.{"settings"});
            } else {
                _ = sys.spawnDetached("/bin/settings", &.{ "settings", to });
            }
            unfocus();
            return .released;
        },
        else => return .ignored,
    }
}

fn closeStatusMenus() void {
    sound_open = false;
    net_open = false;
    power_open = false;
    clock_open = false;
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
