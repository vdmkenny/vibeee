//! eeewm: display server, compositor and tiling window manager.
//!
//! Owns the screen, arranges windows, draws the bar, and turns input into
//! either a window-manager action or an event for the focused window. One
//! process, because on this machine the alternative is IPC round trips on
//! every frame for no isolation worth having: everything here is already
//! unprivileged. design/10-gui.md §3.1.
//!
//! **Tiling, with tags.** Four tags, one on screen at a time. Windows on the
//! viewed tag tile without overlapping; floating windows sit above them, and
//! are the exception rather than a mode. Layout is per tag, so a tag can be a
//! terminal over a document while another is one thing full-screen.
//!
//! **One buffer, no vblank.** The VESA framebuffer offers neither page flipping
//! nor a vertical blank, and says so through `DisplayInfo.caps`, so drawing
//! goes straight into the scanout buffer. Painting is damage-driven: a pass
//! where nothing changed writes nothing, which is what keeps an idle desktop
//! free on a machine where a full repaint is 1.5 MB.

const std = @import("std");
const eui = @import("eui").draw;
const theme = @import("eui").theme;
const clients = @import("clients.zig");
const layout = @import("layout.zig");
const bar = @import("bar.zig");
const proto = @import("proto");
const ui = @import("eui").widget;
const sys = @import("sys");
const out = @import("ulib").out;

const Rect = eui.Rect;
const KeyCode = sys.KeyCode;


var screen: eui.Surface = undefined;
var info: sys.DisplayInfo = .{};
var desktop: layout.Desktop = .{};

/// Toolkit state for the focused window's content.
///
/// One context, not one per window: only the focused window takes input, and a
/// context per window would keep hover and focus state for controls nobody can
/// reach. Real clients will each own their own, in their own process.
var ctx: ui.Context = undefined;

/// Connected clients and the surfaces they have given us.
var table: clients.Table = .{};
var surfaces: [layout.MAX_WINDOWS]clients.Surface = @splat(.{});
/// The channel clients call in on.
var service: u32 = 0;

var pointer_x: i32 = 0;
var pointer_y: i32 = 0;
var buttons: sys.Buttons = .{};

/// Everything needs redrawing. Set by anything that changes the arrangement,
/// because working out what survived a retile costs more than repainting.
var dirty = true;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ call wmMain
        \\ hlt
    );
}

export fn wmMain() callconv(.c) noreturn {
    const display = sys.displayAcquire(&info) orelse {
        out.text("eeewm: cannot take the display; is it in graphics mode?\n");
        out.flush();
        sys.exit(1);
    };

    const pixels = sys.shmMap(@intCast(display), .{ .writable = true }) orelse {
        out.text("eeewm: cannot map the scanout buffer\n");
        out.flush();
        sys.exit(1);
    };

    screen = eui.Surface.init(
        @ptrCast(@alignCast(pixels)),
        info.width,
        info.height,
        info.stride_px,
    );

    const t = theme.current();
    desktop.bounds = .{
        .x = 0,
        .y = t.bar_height,
        .w = info.width,
        .h = info.height - t.bar_height,
    };

    ctx = ui.Context.init(screen);

    pointer_x = @divTrunc(info.width, 2);
    pointer_y = @divTrunc(info.height, 2);

    const registered = sys.svcRegister(proto.wm.SERVICE);
    if (registered < 0) {
        out.text("eeewm: cannot register the gui service\n");
        out.flush();
        sys.exit(1);
    }
    service = @intCast(registered);

    // Stand-ins until the client protocol exists. Real clients will open
    // windows over a channel; the arrangement, focus and input paths below do
    // not know the difference.
    _ = desktop.open("Terminal", false);
    _ = desktop.open("Files", false);
    desktop.view(1);
    _ = desktop.open("Editor", false);
    desktop.view(0);

    run();
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

fn paint() void {
    const t = theme.current();

    screen.fill(.{ .x = 0, .y = 0, .w = info.width, .h = info.height }, t.desktop);
    bar.paint(screen, info.width, &desktop);

    var buf: [layout.MAX_WINDOWS]usize = undefined;
    for (desktop.visible(&buf)) |index| {
        paintWindow(index, desktop.focused == index);
    }

    drawCursor();
}

fn paintWindow(index: usize, focused: bool) void {
    const t = theme.current();
    const w = &desktop.windows[index];
    const area = w.area;
    if (area.isEmpty()) return;

    const width = if (focused) t.border_width_focused else t.border_width;

    screen.fill(area, t.surface);
    // Drawn inside the tile, so focusing a window never changes its size and
    // never disturbs its neighbours.
    screen.borderInset(area, width, if (focused) t.border_focused else t.border);

    // A client that has given us a surface gets composited from it. One that
    // has not draws the manager's own placeholder, which is what the desktop
    // looks like before anything has connected.
    const content = area.inset(width);
    if (w.mapped and surfaces[index].valid()) {
        clients.blit(screen, surfaces[index], content, content);
        return;
    }

    const inner = content.inset(t.padding);
    screen.text(inner.x, inner.y, w.name(), t.text);

    var size: [24]u8 = @splat(0);
    screen.text(inner.x, inner.y + 16, describe(&size, area), t.text_dim);

    if (focused) paintContent(inner);
}

/// The focused window's contents, drawn with libeui.
fn paintContent(area: Rect) void {
    const t = theme.current();
    if (area.h < 120) return;

    const row = Rect{
        .x = area.x,
        .y = area.y + 40,
        .w = @min(area.w, 200),
        .h = t.control_height,
    };

    ctx.begin(pointer_x, pointer_y, buttons);
    // Every pass repaints: the window frame was just drawn underneath, so the
    // toolkit's own damage tracking has nothing to go on.
    ctx.damage();

    if (ctx.button(row, "Do something")) clicks +%= 1;

    checked = ctx.checkbox(
        .{ .x = row.x, .y = row.bottom() + t.padding, .w = row.w, .h = t.control_height },
        "An option",
        checked,
    );

    ctx.progress(
        .{ .x = row.x, .y = row.bottom() + t.control_height + t.padding * 2, .w = row.w, .h = 10 },
        @intCast(@min(clicks * 20, 100)),
    );

    ctx.end();
}

var clicks: u32 = 0;
var checked = true;

/// "800x458", so the tiling is legible without a ruler.
fn describe(buf: []u8, area: Rect) []const u8 {
    const str = @import("ulib").str;
    var n = str.decimal(buf, @intCast(@max(area.w, 0)));
    buf[n] = 'x';
    n += 1;
    n += str.decimal(buf[n..], @intCast(@max(area.h, 0)));
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// The cursor
// ---------------------------------------------------------------------------

const CURSOR_W = 8;
const CURSOR_H = 12;

const cursor_bits = [CURSOR_H]u8{
    0b10000000, 0b11000000, 0b11100000, 0b11110000,
    0b11111000, 0b11111100, 0b11111110, 0b11111000,
    0b11011000, 0b10001100, 0b00001100, 0b00000110,
};

/// Drawn rather than composited: this display advertises no cursor plane.
/// Outlined by drawing it black one pixel down and right first, so it stays
/// visible over any colour beneath it.
fn drawCursor() void {
    for ([_]struct { dx: i32, dy: i32, color: eui.Color }{
        .{ .dx = 1, .dy = 1, .color = 0x000000 },
        .{ .dx = 0, .dy = 0, .color = 0xFFFFFF },
    }) |pass| {
        for (cursor_bits, 0..) |row, iy| {
            var ix: i32 = 0;
            while (ix < CURSOR_W) : (ix += 1) {
                if (row >> @intCast(7 - @as(u3, @intCast(ix))) & 1 == 0) continue;
                screen.set(
                    pointer_x + ix + pass.dx,
                    pointer_y + @as(i32, @intCast(iy)) + pass.dy,
                    pass.color,
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

fn run() noreturn {
    var pointer_events: [16]sys.PointerEvent = undefined;
    var key_events: [16]sys.KeyEvent = undefined;

    paint();

    while (true) {
        var acted = serve();

        const keys = sys.keyRead(&key_events, sys.POLL);
        for (keys) |event| {
            // A chord with the manager's modifier belongs to the manager;
            // everything else belongs to whoever has focus. Without that split
            // a client would swallow Mod+q and the desktop would be
            // unnavigable from inside a full-screen application.
            if (event.mods().super) {
                if (event.isPress()) handleKey(event);
            } else {
                postToFocused(.{
                    .tag = .key,
                    .body = .{ .key = .{
                        .code = event.code,
                        .down = event.pressed,
                        .mods = event.modifiers,
                    } },
                });
                if (event.codepoint != 0 and event.isPress()) {
                    postToFocused(.{
                        .tag = .text,
                        .body = .{ .text = .{ .cp = event.codepoint } },
                    });
                }
            }
            acted = true;
        }

        const moves = sys.pointerRead(&pointer_events, if (acted) sys.POLL else 200_000);
        for (moves) |event| {
            handlePointer(event);
            acted = true;
        }

        if (!acted) continue;

        // A layout change moves every tile, so each client is told its new
        // size before anything is drawn from its surface.
        for (0..layout.MAX_WINDOWS) |i| {
            if (desktop.windows[i].used) tellSize(i);
        }

        paint();
    }
}

/// Bindings are by keycode, not by symbol: a shortcut lives at a place on the
/// keyboard, and binding by symbol would move every one of them when the
/// layout changes between US and AZERTY. design/10-gui.md §4.5.
fn handleKey(event: sys.KeyEvent) void {
    const mods = event.mods();
    const code: KeyCode = @enumFromInt(event.code);

    if (!mods.super) return;

    switch (code) {
        .n1, .n2, .n3, .n4 => {
            const tag: u8 = @intCast(@intFromEnum(code) - @intFromEnum(KeyCode.n1));
            if (mods.shift) desktop.moveToTag(tag) else desktop.view(tag);
        },
        .tab => desktop.viewPrevious(),

        .t => desktop.setLayout(.tall),
        .w => desktop.setLayout(.wide),
        .m => desktop.setLayout(.monocle),

        .j => desktop.focusNext(1),
        .k => desktop.focusNext(-1),

        .h => desktop.nudgeMaster(-0.05),
        .l => desktop.nudgeMaster(0.05),

        .f => desktop.toggleFloating(),
        .enter => {
            if (mods.shift) {
                desktop.zoom();
            } else {
                // Until eTerm exists, the demo client is what Mod+Enter
                // launches: it proves the whole path rather than adding
                // another placeholder the manager drew itself.
                _ = sys.spawnDetached("/EHELLO", &.{"ehello"});
            }
        },
        .c => if (mods.shift) {
            if (desktop.focused) |index| desktop.close(index);
        },

        // Not in the design's table, but a theme that cannot be changed from
        // the machine it runs on is not themable in any useful sense.
        .grave => _ = theme.cycle(),

        else => return,
    }

    dirty = true;
}

fn handlePointer(event: sys.PointerEvent) void {
    pointer_x = event.x;
    pointer_y = event.y;
    const was_down = buttons.left;
    buttons = event.buttons;

    // Focus follows click, not hover: at this size and with a touchpad this
    // small, hovering over the wrong tile is something that happens by
    // accident several times a minute.
    if (!was_down and buttons.left) {
        if (event.y < theme.current().bar_height) {
            bar.click(event.x, &desktop);
        } else {
            desktop.focusAt(event.x, event.y);
        }
    }
}

// ---------------------------------------------------------------------------
// Serving clients
//
// The other half of the loop. Requests arrive on one channel from every
// client; the kernel attests who sent each one, so a client cannot act for
// another and no per-client channel is needed to tell them apart.
// ---------------------------------------------------------------------------

const wire = proto.wm;

/// Handle every request waiting, without blocking.
fn serve() bool {
    var handled = false;

    while (true) {
        var message: sys.Message = .{};
        const request = sys.recv(service, &message, sys.POLL) orelse break;
        handled = true;

        const req: *const wire.Req = @ptrCast(@alignCast(&message.data));
        const reply = dispatch(message.sender, req, &message);

        var answer = sys.Message.init(std.mem.asBytes(&reply.rep), reply.handles);
        _ = sys.replyMsg(service, request.token, &answer);
    }

    return handled;
}

const Answer = struct {
    rep: wire.Rep,
    handles: []const u32 = &.{},
};

fn dispatch(pid: u32, req: *const wire.Req, message: *const sys.Message) Answer {
    return switch (req.tag) {
        .hello => onHello(pid, req),
        .create_win => onCreate(pid, req),
        .attach => onAttach(pid, req, message),
        .commit => onCommit(pid, req),
        .set_title => onTitle(pid, req),
        .map => onMap(pid, req),
        .unmap, .destroy_win => onDestroy(pid, req),
        .bye => blk: {
            desktop.closeClient(pid);
            table.evict(pid);
            dirty = true;
            break :blk .{ .rep = .{ .gen = table.generation } };
        },
    };
}

var hello_handles: [2]u32 = @splat(0);

fn onHello(pid: u32, req: *const wire.Req) Answer {
    if (req.body.hello.proto != wire.VERSION) {
        return .{ .rep = .{ .status = .bad_version, .gen = table.generation } };
    }

    const client = table.admit(pid, &req.body.hello.app_name) orelse {
        return .{ .rep = .{ .status = .no_room, .gen = table.generation } };
    };

    hello_handles = .{ client.events_handle, client.signal };

    return .{
        .rep = .{
            .gen = table.generation,
            .body = .{ .hello = .{
                .screen_w = @intCast(info.width),
                .screen_h = @intCast(info.height),
                .caps = 0,
            } },
        },
        .handles = &hello_handles,
    };
}

fn onCreate(pid: u32, req: *const wire.Req) Answer {
    if (table.find(pid) == null) return refuse(.bad_request);

    const index = desktop.open("", req.body.create.flags.floating) orelse
        return refuse(.no_room);

    const w = &desktop.windows[index];
    w.client_pid = pid;
    // The client's id for the window, which is per client rather than global:
    // the slot index is ours and would collide across clients.
    w.client_win = @intCast(index);
    dirty = true;

    // The size is the server's decision in a tiling manager, so the client is
    // told rather than asked. It finds out through `configure`.
    tellSize(index);

    return .{ .rep = .{
        .gen = table.generation,
        .body = .{ .create = .{ .win = w.client_win } },
    } };
}

fn onAttach(pid: u32, req: *const wire.Req, message: *const sys.Message) Answer {
    const index = desktop.byClient(pid, req.win) orelse return refuse(.no_window);
    if (message.handle_count < 1) return refuse(.bad_request);

    const handle = message.handles[0];
    const surface = clients.adoptSurface(
        handle,
        req.body.attach.w,
        req.body.attach.h,
        req.body.attach.stride_px,
    ) orelse return refuse(.no_room);

    // The previous surface is released only now, so there is never a moment
    // with nothing to composite from.
    if (surfaces[index].handle != 0) _ = sys.close(surfaces[index].handle);
    surfaces[index] = surface;
    dirty = true;

    return .{ .rep = .{ .gen = table.generation } };
}

fn onCommit(pid: u32, req: *const wire.Req) Answer {
    const index = desktop.byClient(pid, req.win) orelse return refuse(.no_window);
    _ = index;
    _ = req.body.commit;

    // Every commit repaints the window in full for now. Honouring the damage
    // rectangles is the optimisation this protocol exists to allow, and it
    // needs a per-window damage list the paint pass consults rather than the
    // whole-screen flag below.
    dirty = true;
    return .{ .rep = .{ .gen = table.generation } };
}

fn onTitle(pid: u32, req: *const wire.Req) Answer {
    const index = desktop.byClient(pid, req.win) orelse return refuse(.no_window);
    const n = @min(req.body.title.len, req.body.title.text.len);
    desktop.windows[index].setTitle(req.body.title.text[0..n]);
    dirty = true;
    return .{ .rep = .{ .gen = table.generation } };
}

fn onMap(pid: u32, req: *const wire.Req) Answer {
    const index = desktop.byClient(pid, req.win) orelse return refuse(.no_window);
    desktop.windows[index].mapped = true;
    dirty = true;
    return .{ .rep = .{ .gen = table.generation } };
}

fn onDestroy(pid: u32, req: *const wire.Req) Answer {
    const index = desktop.byClient(pid, req.win) orelse return refuse(.no_window);

    if (surfaces[index].handle != 0) _ = sys.close(surfaces[index].handle);
    surfaces[index] = .{};
    desktop.close(index);
    dirty = true;

    return .{ .rep = .{ .gen = table.generation } };
}

fn refuse(status: wire.Status) Answer {
    return .{ .rep = .{ .status = status, .gen = table.generation } };
}

/// Tell a window's client what size it is, if that has changed.
fn tellSize(index: usize) void {
    const w = &desktop.windows[index];
    if (w.client_pid == 0) return;

    const inner = contentRect(index);
    const width: u16 = @intCast(@max(inner.w, 0));
    const height: u16 = @intCast(@max(inner.h, 0));
    if (width == w.told_w and height == w.told_h) return;

    w.told_w = width;
    w.told_h = height;

    const client = table.find(w.client_pid) orelse return;
    client.post(.{
        .tag = .configure,
        .win = w.client_win,
        .t_us = @truncate(sys.clockMicros()),
        .body = .{ .configure = .{ .w = width, .h = height } },
    });
}

/// Where a window's client content goes: the tile, less its border.
fn contentRect(index: usize) Rect {
    const t = theme.current();
    const w = &desktop.windows[index];
    const width = if (desktop.focused == index) t.border_width_focused else t.border_width;
    return w.area.inset(width);
}

/// Send input to whichever client owns the focused window.
fn postToFocused(event: wire.Ev) void {
    const index = desktop.focused orelse return;
    const w = &desktop.windows[index];
    if (w.client_pid == 0) return;

    const client = table.find(w.client_pid) orelse return;
    var copy = event;
    copy.win = w.client_win;
    copy.t_us = @truncate(sys.clockMicros());
    client.post(copy);
}
