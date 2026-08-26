//! A window, to prove the protocol.
//!
//! The smallest complete client: connect, create a window, take the size the
//! manager gives it, draw with `libeui`, commit, map, then react to what
//! arrives. Everything a real application does, with nothing in it that a real
//! application would not.

const std = @import("std");
const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const out = @import("ulib").out;
const str = @import("ulib").str;

const wm = proto.wm;

var connection: proto.Connection = undefined;
var window: u8 = 0;
var ctx: eui.Context = undefined;

var clicks: u32 = 0;
var checked = true;

/// Pointer position, in window coordinates. The manager sends it that way, so
/// a client never has to know where its window is.
var pointer_x: i32 = 0;
var pointer_y: i32 = 0;
var buttons: eui.widget.Buttons = .{};

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ call appMain
        \\ hlt
    );
}

export fn appMain() callconv(.c) noreturn {
    connection = proto.client.Connection.open("hello") catch |err| {
        out.text("hello: ");
        out.text(switch (err) {
            error.NoServer => "no window manager is running\n",
            error.VersionMismatch => "the window manager speaks a different protocol\n",
            else => "the window manager refused the connection\n",
        });
        out.flush();
        sys.exit(1);
    };

    window = connection.createWindow(.{}, 200, 120) catch {
        out.text("hello: cannot create a window\n");
        out.flush();
        sys.exit(1);
    };

    connection.setTitle(window, "Hello") catch {};

    // The first size arrives as a configure, because the manager decides
    // geometry and a tiling manager would only contradict anything we chose.
    run();
}

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
            // Events were dropped, so nothing about the current state can be
            // trusted; a full redraw is cheaper than working out what was lost.
            .overflow => redraw(),
            else => {},
        }
    }
}

fn setButton(index: u8, down: bool) void {
    switch (index) {
        0 => buttons.left = down,
        1 => buttons.right = down,
        2 => buttons.middle = down,
        else => {},
    }
}

/// Take a new size: allocate a surface for it and draw the first frame.
fn resize(w: u16, h: u16) void {
    connection.attach(window, w, h) catch return;

    const surface = connection.surfaceOf(window) orelse return;
    ctx = eui.Context.init(surface.*);
    ctx.damage();

    draw();
    connection.map(window) catch {};
}

fn redraw() void {
    const surface = connection.surfaceOf(window) orelse return;
    ctx.surface = surface.*;
    draw();
}

fn draw() void {
    const t = eui.theme.current();
    const surface = ctx.surface;

    const area = eui.Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };
    if (ctx.damaged) surface.fill(area, t.surface);

    ctx.begin(pointer_x, pointer_y, buttons);

    ctx.label(.{ .x = t.padding, .y = t.padding, .w = area.w - t.padding * 2, .h = 16 }, "A window of its own.");

    if (ctx.button(.{ .x = t.padding, .y = 32, .w = 110, .h = t.control_height }, "Press")) {
        clicks +%= 1;
        ctx.damage();
    }

    checked = ctx.checkbox(
        .{ .x = t.padding, .y = 32 + t.control_height + t.padding, .w = 110, .h = t.control_height },
        "Enabled",
        checked,
    );

    var buf: [24]u8 = @splat(0);
    var n = str.decimal(&buf, clicks);
    const suffix = if (clicks == 1) " press" else " presses";
    for (suffix) |c| {
        buf[n] = c;
        n += 1;
    }
    ctx.label(.{ .x = t.padding, .y = area.h - 24, .w = area.w - t.padding * 2, .h = 16 }, buf[0..n]);

    ctx.end();

    connection.commit(window, ctx.damageList()) catch {};
}
