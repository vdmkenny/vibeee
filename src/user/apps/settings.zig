//! Settings: the desktop's own control panel.
//!
//! Edits what `/etc/eeewm.cfg` holds and writes it back, so a change survives
//! a restart rather than lasting until the manager exits. The first real
//! application, and deliberately so: it needs nothing that does not already
//! work, and it exercises the toolkit, the window protocol and the filesystem
//! write path together under something a person would actually use.
//!
//! Applies changes live where it can. A theme picked from a list should be
//! visible before the file is saved, because the point of choosing one is
//! seeing it.

const std = @import("std");
const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const out = @import("ulib").out;

const wm = proto.wm;
const sound = proto.audio;
const rgb = @import("lib").rgb;
const str = @import("lib").str;
const theme = eui.theme;

const store = proto.settings;

var connection: proto.Connection = undefined;
var window: u8 = 0;
var ctx: eui.Context = undefined;

/// What the controls edit. The schema, not a copy of it: `cfg` and this app
/// change the same settings and a second field list is a second thing to keep
/// in step.
var current: store.Wm = .{};
var saved = true;

var pointer_x: i32 = 0;
var pointer_y: i32 = 0;
var buttons: eui.widget.Buttons = .{};

export fn _start() callconv(.c) noreturn {
    settingsMain();
}

fn settingsMain() noreturn {
    load();

    connection = proto.client.Connection.open("settings") catch {
        out.text("settings: no window manager is running\n");
        out.flush();
        sys.exit(1);
    };

    window = connection.createWindow(.{}, 260, 200) catch sys.exit(1);
    connection.setTitle(window, "Settings") catch {};

    run();
}

// ---------------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------------

fn load() void {
    current = store.load("wm");
    readVolume();
}

/// What the sound service says the default output is at.
///
/// Kept here rather than asked for on every pass: a paint happens whenever
/// the pointer moves, and a call into another process per motion is a cost
/// nothing about the picture justifies.
var volume: sound.VolumeInfo = .{ .percent = 0, .muted = 0 };
var has_sound = false;

fn readVolume() void {
    if (sound.master()) |level| {
        volume = level;
        has_sound = true;
    } else {
        has_sound = false;
    }
}

fn setVolume(percent: u8, muted: bool) void {
    if (!has_sound) return;
    if (!sound.setMaster(percent, muted)) return;
    readVolume();
    ctx.damage();
}

/// Hand the changes to `cfgd`, which is the only thing that writes them.
///
/// Only what differs is sent, and the service tells every watcher, so the
/// desktop finds out the same way a shell would.
fn save() void {
    store.save("wm", current) catch return;
    saved = true;
}

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

fn run() noreturn {
    while (true) {
        const event = connection.next(1_000_000) orelse continue;

        switch (event.tag) {
            .configure => resize(event.body.configure.w, event.body.configure.h),
            .ptr_motion => {
                pointer_x = event.body.motion.x;
                pointer_y = event.body.motion.y;
                redraw();
            },
            .ptr_button => {
                pointer_x = event.body.button.x;
                pointer_y = event.body.button.y;
                setButton(event.body.button.btn, event.body.button.down != 0);
                redraw();
            },
            .key => {
                ctx.postKey(@intCast(event.body.key.code), @bitCast(event.body.key.mods));
                if (event.body.key.down != 0) redraw();
            },
            .theme => {
                proto.client.applyTheme(&event.body.theme.name);
                ctx.damage();
                redraw();
            },
            .close_req => sys.exit(0),
            .overflow => redraw(),
            else => {},
        }
    }
}

/// A heading over a row of controls, and where the row starts.
fn group(y: *i32, area: eui.Rect, title: []const u8) i32 {
    ctx.label(.{ .x = area.x, .y = y.*, .w = area.w, .h = 16 }, title);
    y.* += 18;
    return y.*;
}

/// A setting just changed: mark the file stale and repaint, since the group
/// that changed has a sibling to un-select and the status line to update.
fn change() void {
    saved = false;
    ctx.damage();
}

/// Three channels, a reading of what they make, and a square of it.
///
/// Returns where the next thing goes. The colour applies as it is dragged,
/// because a wallpaper picker that showed the answer only after saving would
/// be a picker nobody could use.
fn wallpaper(area: eui.Rect) i32 {
    const t = theme.current();
    const row = t.control_height;
    const pad = t.padding;

    const swatch = eui.Rect{ .x = area.x, .y = area.y, .w = 72, .h = area.h };
    const chosen = current.wallpaper.orElse(t.desktop);
    ctx.surface.fill(swatch, chosen);
    ctx.surface.frame(swatch, t.border);

    var text: [8]u8 = undefined;
    var spelled = str.Builder{ .buf = &text };
    current.wallpaper.spell(&spelled);
    ctx.label(
        .{ .x = swatch.x, .y = swatch.bottom() + 2, .w = swatch.w, .h = 16 },
        if (current.wallpaper.set) spelled.done() else "theme",
    );

    const left = swatch.right() + pad * 2;
    const width = area.right() - left;

    // Read out of the colour rather than kept beside it, so what the sliders
    // show and what the wall is cannot come apart.
    var channels = [_]u8{ current.wallpaper.r, current.wallpaper.g, current.wallpaper.b };
    if (!current.wallpaper.set) {
        channels = .{
            @truncate(chosen >> 16),
            @truncate(chosen >> 8),
            @truncate(chosen),
        };
    }

    // A label, the slider, and what it reads. The number is there because
    // a colour is often copied from somewhere rather than found by eye.
    const label_w: i32 = 14;
    const value_w: i32 = 34;
    const names = [_][]const u8{ "R", "G", "B" };
    // Each channel in its own, muted to the palette rather than the pure
    // primary: three identical bars are three bars nobody can tell apart at
    // a glance, and a saturated red beside this accent is a different
    // interface.
    const tints = [_]u32{ 0xC04A3A, 0x3E9450, 0x3A6FD0 };

    var moved = false;
    for (&channels, 0..) |*channel, i| {
        const top = area.y + @as(i32, @intCast(i)) * (row + pad);
        ctx.label(.{ .x = left, .y = top + 4, .w = label_w, .h = 16 }, names[i]);

        const at = eui.Rect{
            .x = left + label_w,
            .y = top,
            .w = width - label_w - value_w - pad,
            .h = row,
        };

        var reading: [4]u8 = undefined;
        const digits = str.decimal(&reading, channel.*);
        ctx.label(
            .{ .x = at.right() + pad, .y = top + 4, .w = value_w, .h = 16 },
            reading[0..digits],
        );

        const wanted = ctx.slider(at, .{ .min = 0, .max = 255 }, channel.*, .{ .fill = tints[i] });
        if (wanted != channel.*) {
            channel.* = @intCast(wanted);
            moved = true;
        }
    }

    if (moved) {
        current.wallpaper = rgb.Colour.of(channels[0], channels[1], channels[2]);
        change();
    }

    return area.bottom() + 18;
}

fn setButton(index: u8, down: bool) void {
    switch (index) {
        0 => buttons.left = down,
        1 => buttons.right = down,
        2 => buttons.middle = down,
        else => {},
    }
}

fn resize(w: u16, h: u16) void {
    connection.attach(window, w, h) catch return;
    const surface = connection.surfaceOf(window) orelse return;

    ctx = eui.Context.init(surface.*);
    ctx.damageNow();
    draw();
    connection.map(window) catch {};
}

fn redraw() void {
    const surface = connection.surfaceOf(window) orelse return;
    ctx.surface = surface.*;
    draw();
    // A control that changed something asked for a clean pass; give it one now
    // rather than leaving the window half-updated until the next event.
    if (ctx.pending) draw();
}

/// Which part of the machine is being changed.
///
/// Listed as they gain something to hold: a heading over an empty pane is a
/// promise the machine has not kept, so a section appears here when there is
/// a setting under it and not before.
const Section = enum {
    display,
    audio,
    about,

    fn title(self: Section) []const u8 {
        return switch (self) {
            .display => "Display",
            .audio => "Audio",
            .about => "About",
        };
    }
};

var section: Section = .display;

/// The column of sections. As wide as the longest name and no wider: on a
/// screen this size the rail is room the pane does not get.
const RAIL_WIDTH: i32 = 96;

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const area = eui.Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };

    ctx.begin(pointer_x, pointer_y, buttons);
    // Inside the pass, so it sees the damage this pass was given rather than
    // what the last one finished with.
    if (ctx.damaged) surface.fill(area, t.surface);

    const foot = t.control_height + t.padding * 2;
    const rail = eui.Rect{ .x = 0, .y = 0, .w = RAIL_WIDTH, .h = area.h - foot };
    const pane = eui.Rect{
        .x = rail.right() + t.menu_padding,
        .y = t.menu_padding,
        .w = area.w - rail.w - t.menu_padding * 2,
        .h = rail.h - t.menu_padding,
    };

    drawRail(rail);
    surface.fill(.{ .x = rail.right(), .y = 0, .w = 1, .h = rail.h }, t.line);

    switch (section) {
        .display => drawDisplay(pane),
        .audio => drawAudio(pane),
        .about => drawAbout(pane),
    }

    drawFooter(area, foot);

}

fn drawRail(rail: eui.Rect) void {
    const t = theme.current();
    if (ctx.damaged) ctx.surface.fill(rail, t.surface_pressed);

    var y = rail.y + t.padding;
    for (std.enums.values(Section)) |which| {
        const at = eui.Rect{ .x = rail.x, .y = y, .w = rail.w, .h = t.menu_row_height };
        if (ctx.toggle(at, which.title(), which == section) and which != section) {
            section = which;
            // A different pane entirely, so the whole window is repainted
            // rather than the row that was pressed.
            ctx.damage();
        }
        y += t.menu_row_height;
    }
}

fn drawDisplay(pane: eui.Rect) void {
    const t = theme.current();
    const row = t.control_height;
    var y = pane.y;
    const full = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = row };

    y = group(&y, full, "Theme");
    // Applied on the spot rather than on save, because seeing it is the point
    // of choosing it.
    const wanted = ctx.choice(.{ .x = pane.x, .y = y, .w = full.w, .h = row }, current.theme);
    if (wanted != current.theme) {
        current.theme = wanted;
        if (theme.byName(@tagName(wanted))) |chosen| theme.use(chosen);
        change();
    }
    y += row + t.padding;

    y = group(&y, full, "Bar");
    const bar = ctx.choice(.{ .x = pane.x, .y = y, .w = full.w, .h = row }, current.bar);
    if (bar != current.bar) {
        current.bar = bar;
        change();
    }
    y += row + t.padding;

    // The wall behind everything. Three channels rather than a list of
    // colours: the panel is one flat colour and which one is a matter of
    // taste that a list of six would only get near.
    y = group(&y, full, "Wallpaper");
    _ = wallpaper(.{ .x = pane.x, .y = y, .w = full.w, .h = row * 3 + t.padding * 2 });
}

fn drawAudio(pane: eui.Rect) void {
    const t = theme.current();
    const row = t.control_height;
    var y = pane.y;
    const full = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = row };

    y = group(&y, full, "Volume");
    if (!has_sound) {
        ctx.label(.{ .x = pane.x, .y = y, .w = full.w, .h = 16 }, "Nothing is serving sound.");
        return;
    }

    const level = ctx.slider(
        .{ .x = pane.x, .y = y, .w = full.w - 84, .h = row },
        .{ .min = 0, .max = 100 },
        volume.percent,
        .{},
    );
    if (ctx.toggle(.{ .x = pane.x + full.w - 78, .y = y, .w = 78, .h = row }, "Mute", volume.muted != 0)) {
        setVolume(volume.percent, volume.muted == 0);
    } else if (level != volume.percent) {
        setVolume(@intCast(level), volume.muted != 0);
    }
}

fn drawAbout(pane: eui.Rect) void {
    var y = pane.y;
    const full = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = 16 };

    y = group(&y, full, "vibeee");
    ctx.label(.{ .x = pane.x, .y = y, .w = full.w, .h = 16 }, "0.1.0");
}

fn drawFooter(area: eui.Rect, foot: i32) void {
    const t = theme.current();
    const row = t.control_height;
    const top = area.h - foot;

    ctx.surface.fill(.{ .x = 0, .y = top, .w = area.w, .h = 1 }, t.line);

    // Saved settings take effect when the manager next starts, except the
    // theme and the wall, which are live. Saying so beats a person wondering
    // why the bar did not move.
    ctx.label(
        .{ .x = t.menu_padding, .y = top + t.padding + 4, .w = area.w - 180, .h = 16 },
        if (saved) "The bar moves when the manager next starts." else "Unsaved changes.",
    );

    if (ctx.button(.{ .x = area.w - 168, .y = top + t.padding, .w = 76, .h = row }, "Save")) {
        save();
        ctx.damage();
    }

    if (ctx.button(.{ .x = area.w - 86, .y = top + t.padding, .w = 76, .h = row }, "Close")) {
        sys.exit(0);
    }

    ctx.end();
    connection.commit(window, ctx.damageList()) catch {};
}
