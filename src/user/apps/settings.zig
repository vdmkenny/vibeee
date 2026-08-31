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

const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const out = @import("ulib").out;

const wm = proto.wm;
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

    // Every group is an enum field, so every group is one call: the tags are
    // the buttons, and a value added to the schema appears here untouched.
    const full = eui.Rect{ .x = pad, .y = y, .w = area.w - pad * 2, .h = row };

    y = group(&y, full, "Theme");
    // Applied on the spot rather than on save, because seeing it is the point
    // of choosing it.
    const wanted = ctx.choice(.{ .x = pad, .y = y, .w = full.w, .h = row }, current.theme);
    if (wanted != current.theme) {
        current.theme = wanted;
        if (theme.byName(@tagName(wanted))) |chosen| theme.use(chosen);
        change();
    }
    y += row + pad;

    y = group(&y, full, "Bar");
    const bar = ctx.choice(.{ .x = pad, .y = y, .w = full.w, .h = row }, current.bar);
    if (bar != current.bar) {
        current.bar = bar;
        change();
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
