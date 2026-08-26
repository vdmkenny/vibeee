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
const config = @import("ulib").config;
const out = @import("ulib").out;
const str = @import("ulib").str;

const wm = proto.wm;
const theme = eui.theme;

const PATH = "/etc/eeewm.cfg";

var connection: proto.Connection = undefined;
var window: u8 = 0;
var ctx: eui.Context = undefined;

/// What the file says, and what the controls edit.
const Settings = struct {
    theme: [16]u8 = @splat(0),
    bar: Bar = .top,
    layout: Layout = .tall,
    master: u8 = 58,

    const Bar = enum { top, bottom };
    const Layout = enum { tall, wide, monocle };
};

var settings: Settings = .{};
var saved = true;

var pointer_x: i32 = 0;
var pointer_y: i32 = 0;
var buttons: eui.widget.Buttons = .{};

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ call settingsMain
        \\ hlt
    );
}

export fn settingsMain() callconv(.c) noreturn {
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
// The file
// ---------------------------------------------------------------------------

var file_buffer: [512]u8 = @splat(0);

fn load() void {
    _ = config.load(PATH, &settings, &file_buffer);
    // The manager already told us its theme at connect time, so an empty or
    // missing file still shows what is actually in use.
    if (nameLength() == 0) setThemeName(theme.current().name);
}

fn nameLength() usize {
    var n: usize = 0;
    while (n < settings.theme.len and settings.theme[n] != 0) n += 1;
    return n;
}

fn themeName() []const u8 {
    return settings.theme[0..nameLength()];
}

fn setThemeName(name: []const u8) void {
    settings.theme = @splat(0);
    const n = @min(name.len, settings.theme.len);
    @memcpy(settings.theme[0..n], name[0..n]);
}

/// Write the file back.
///
/// Rewritten whole rather than edited in place: it is a few hundred bytes, and
/// a partial update of a config file is a config file nobody can predict.
fn save() void {
    const handle = sys.open(PATH, .{ .write = true, .create = true, .truncate = true });
    if (handle < 0) return;
    defer _ = sys.close(@intCast(handle));

    var buf: [512]u8 = @splat(0);
    var text = str.Builder{ .buf = &buf };

    text.text("# Written by Settings.\n\ntheme  = ");
    text.text(themeName());
    text.text("\nbar    = ");
    text.text(@tagName(settings.bar));
    text.text("\nlayout = ");
    text.text(@tagName(settings.layout));
    text.text("\nmaster = ");
    text.number(settings.master);
    text.byte('\n');

    _ = sys.write(@intCast(handle), text.done());
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

/// A setting just changed: mark the file stale and repaint, since the group
/// that changed has a sibling to un-select and the status line to update.
fn change() void {
    saved = false;
    ctx.damage();
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

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const area = eui.Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };

    ctx.begin(pointer_x, pointer_y, buttons);
    // Inside the pass, so it sees the damage this pass was given rather than
    // what the last one finished with.
    if (ctx.damaged) surface.fill(area, t.surface);

    const pad = t.padding;
    const row = t.control_height;
    var y: i32 = pad;

    ctx.label(.{ .x = pad, .y = y, .w = area.w - pad * 2, .h = 16 }, "Theme");
    y += 18;

    // Applied on the spot rather than on save, because seeing it is the point
    // of choosing it.
    var x: i32 = pad;
    for (theme.all) |candidate| {
        const width = eui.Surface.textWidth(candidate.name) + pad * 3;
        const on = std.mem.eql(u8, themeName(), candidate.name);
        if (ctx.toggle(.{ .x = x, .y = y, .w = width, .h = row }, candidate.name, on) and !on) {
            theme.use(candidate);
            setThemeName(candidate.name);
            change();
        }
        x += width + 4;
    }
    y += row + pad;

    ctx.label(.{ .x = pad, .y = y, .w = area.w - pad * 2, .h = 16 }, "Bar");
    y += 18;

    x = pad;
    inline for (@typeInfo(Settings.Bar).@"enum".fields) |field| {
        const on = settings.bar == @as(Settings.Bar, @enumFromInt(field.value));
        if (ctx.toggle(.{ .x = x, .y = y, .w = 76, .h = row }, field.name, on) and !on) {
            settings.bar = @enumFromInt(field.value);
            change();
        }
        x += 80;
    }
    y += row + pad;

    ctx.label(.{ .x = pad, .y = y, .w = area.w - pad * 2, .h = 16 }, "Layout");
    y += 18;

    x = pad;
    inline for (@typeInfo(Settings.Layout).@"enum".fields) |field| {
        const width = eui.Surface.textWidth(field.name) + pad * 3;
        const on = settings.layout == @as(Settings.Layout, @enumFromInt(field.value));
        if (ctx.toggle(.{ .x = x, .y = y, .w = width, .h = row }, field.name, on) and !on) {
            settings.layout = @enumFromInt(field.value);
            change();
        }
        x += width + 4;
    }
    y += row + pad;

    // Saved settings take effect when the manager next starts, except the
    // theme, which is live. Saying so beats a person wondering why the bar did
    // not move.
    ctx.label(
        .{ .x = pad, .y = area.h - row - pad - 18, .w = area.w - pad * 2, .h = 16 },
        if (saved) "Bar and layout apply on restart." else "Unsaved changes.",
    );

    if (ctx.button(.{ .x = pad, .y = area.h - row - pad, .w = 76, .h = row }, "Save")) {
        save();
        ctx.damage();
    }

    if (ctx.button(.{ .x = pad + 80, .y = area.h - row - pad, .w = 76, .h = row }, "Close")) {
        sys.exit(0);
    }

    ctx.end();
    connection.commit(window, ctx.damageList()) catch {};
}
