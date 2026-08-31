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
const cursor = @import("cursor.zig");
const config = @import("config.zig");
const keymaps = @import("keymaps");
const proto = @import("proto");
const region = @import("eui").region;
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

export fn _start() callconv(.c) noreturn {
    wmMain();
}

fn wmMain() noreturn {
    const display = sys.displayAcquire(&info) catch |err| {
        out.text(switch (err) {
            error.NoDisplay => "eeewm: no framebuffer. The machine booted in text mode; " ++
                "add `fb` to the kernel command line.\n",
            error.Busy => "eeewm: something already owns the display.\n",
            error.OutOfMemory => "eeewm: not enough memory to take the display.\n",
        });
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

    const wanted = config.load();
    desktop.bounds = bar.contentArea(info.width, info.height);
    desktop.mfact = @splat(wanted.masterFraction());

    // Signalled by cfgd when anything in the wm domain changes, so a theme
    // chosen from a shell reaches the desktop without a restart. Zero when the
    // service is not up, which the poll below reads as nothing to hear.
    settings_event = proto.settings.watch("wm") catch 0;
    keyboard_event = proto.settings.watch("input") catch 0;
    listenTo(.keys, sys.watch(.keys));
    listenTo(.pointer, sys.watch(.pointer));
    listenTo(.children, sys.watch(.children));
    listenTo(.wm_settings, @intCast(settings_event));
    listenTo(.keyboard_settings, @intCast(keyboard_event));

    ctx = ui.Context.init(screen);
    bar.refresh();

    pointer_x = @divTrunc(info.width, 2);
    pointer_y = @divTrunc(info.height, 2);

    const registered = sys.svcRegister(proto.wm.SERVICE);
    if (registered < 0) {
        out.text("eeewm: cannot register the gui service\n");
        out.flush();
        sys.exit(1);
    }
    service = @intCast(registered);
    listenTo(.channel, registered);

    run();
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

/// What the desktop is painted with: the wallpaper somebody chose, or the
/// theme's own when nobody has. One question, asked wherever the ground
/// behind the windows is drawn.
fn wallpaper() u32 {
    return config.current().wallpaper.orElse(theme.current().desktop);
}

/// Repaint everything.
fn paint() void {
    // Whatever the cursor was covering is about to be drawn over, so the saved
    // pixels are stale and putting them back later would paint a hole.
    cursor.invalidate();

    var buf: [layout.MAX_WINDOWS]usize = undefined;
    const visible = desktop.visible(&buf);

    // The desktop, only where it is still visible once everything else has
    // been drawn. Filling the screen and then covering most of it again is a
    // flash of the desktop colour, every repaint, on a display with one
    // buffer. What the windows do not cover is arithmetic, so it is done
    // before anything is painted rather than paid for in pixels.
    var bare = region.Region.of(.{ .x = 0, .y = 0, .w = info.width, .h = info.height });
    bare.subtract(bar.strip(info.height));
    for (visible) |index| {
        const w = &desktop.windows[index];
        // A translucent window blends with what is behind it, so what is
        // behind it has to be there.
        if (w.transparency == 0) bare.subtract(w.area);
    }
    const wall = wallpaper();
    for (bare.items()) |piece| screen.fill(piece, wall);

    bar.paint(screen, info.width, info.height, &desktop);

    for (visible) |index| {
        paintWindow(index, desktop.focused == index);
    }

    // After the windows: a dropdown reaches over them.
    bar.paintOverlay(screen, info.width, info.height, &desktop);

    for (&window_damage) |*d| d.clear();
    cursor.show(screen, pointer_x, pointer_y);
}

/// Repaint only the windows that committed.
///
/// The common case by far: a terminal printing a line changes one tile, and
/// repainting the desktop, the bar and every other window for it is both slow
/// and visible as a flicker on a display with one buffer.
fn paintCommitted() void {
    var buf: [layout.MAX_WINDOWS]usize = undefined;
    const visible = desktop.visible(&buf);

    var lifted = false;
    // Windows that something below them has just drawn over, and which
    // therefore have to be put back on top.
    var restore: [layout.MAX_WINDOWS]bool = @splat(false);

    for (visible, 0..) |index, order| {
        const damage = &window_damage[index];
        if (damage.isEmpty()) continue;

        if (!lifted and cursor.covers(desktop.windows[index].area)) {
            cursor.hide(screen);
            lifted = true;
        }

        if (damage.all) {
            paintWindow(index, desktop.focused == index);
        } else {
            refreshWindow(index, damage.rects[0..damage.count]);
        }
        damage.clear();

        // `visible` is in drawing order, so anything after this one is above
        // it. A dialog floating over a window that redrew part of itself has
        // just been painted over.
        for (visible[order + 1 ..]) |above| {
            const overlap = desktop.windows[above].area.intersect(desktop.windows[index].area);
            if (!overlap.isEmpty()) restore[above] = true;
        }
    }

    for (visible) |index| {
        if (restore[index]) paintWindow(index, desktop.focused == index);
    }

    // A menu floats over the tiles, so anything repainted underneath one has
    // to be covered again.
    if (bar.menuOpen()) bar.paintOverlay(screen, info.width, info.height, &desktop);
    if (lifted) cursor.show(screen, pointer_x, pointer_y);
}

/// Bring the parts of a window that changed up to date, and nothing else.
fn refreshWindow(index: usize, damage: []const Rect) void {
    const t = theme.current();
    const w = &desktop.windows[index];
    if (!w.mapped or !surfaces[index].valid()) return;

    const border = if (desktop.focused == index) t.border_width_focused else t.border_width;
    const content = w.area.inset(border);

    for (damage) |r| {
        // The client counts from its own top left, which sits at the content
        // origin.
        const on_screen = (Rect{
            .x = content.x + r.x,
            .y = content.y + r.y,
            .w = r.w,
            .h = r.h,
        }).intersect(content);
        if (on_screen.isEmpty()) continue;

        // A translucent window blends with what is behind it, so what is
        // behind has to be put back first. Blending onto the last frame of the
        // window itself would darken it a little more every time.
        if (w.transparency != 0) screen.fill(on_screen, wallpaper());
        clients.blit(screen, surfaces[index], content, on_screen, w.transparency);
    }
}

/// What a window has committed since the last paint, in surface coordinates.
///
/// Kept rather than reduced to a flag because the flag was the flicker: a
/// window that redraws when the pointer merely crosses it was repainting its
/// whole area, and on a display with one buffer the erase is on screen before
/// the redraw catches up.
const Damage = struct {
    rects: [MAX_RECTS]Rect = @splat(.{}),
    count: usize = 0,
    /// Everything, because the window moved or was just mapped and there is no
    /// previous content to keep.
    all: bool = false,

    /// As many as a commit can carry.
    const MAX_RECTS = 3;

    fn isEmpty(self: Damage) bool {
        return self.count == 0 and !self.all;
    }

    fn add(self: *Damage, area: Rect) void {
        if (self.all or area.isEmpty()) return;

        if (self.count == MAX_RECTS) {
            // Past what a commit carries, everything merges into one box: the
            // bookkeeping would cost more than the pixels it saved.
            var all = self.rects[0];
            for (self.rects[1..self.count]) |r| all = all.unite(r);
            self.rects[0] = all.unite(area);
            self.count = 1;
            return;
        }

        self.rects[self.count] = area;
        self.count += 1;
    }

    fn whole(self: *Damage) void {
        self.all = true;
        self.count = 0;
    }

    fn clear(self: *Damage) void {
        self.* = .{};
    }
};

var window_damage: [layout.MAX_WINDOWS]Damage = @splat(.{});

fn paintWindow(index: usize, focused: bool) void {
    const t = theme.current();
    const w = &desktop.windows[index];
    const area = w.area;
    if (area.isEmpty()) return;

    const width = if (focused) t.border_width_focused else t.border_width;

    // Drawn inside the tile, so focusing a window never changes its size and
    // never disturbs its neighbours.
    screen.borderInset(area, width, if (focused) t.border_focused else t.border);

    // A client that has given us a surface gets composited from it. One that
    // has not draws the manager's own placeholder, which is what the desktop
    // looks like before anything has connected.
    const content = area.inset(width);
    if (w.mapped and surfaces[index].valid()) {
        // Filled first only when the window is translucent, where the blend
        // needs a backdrop. An opaque one covers every pixel it is about to
        // write, and filling it grey first is a flash of grey.
        if (w.transparency != 0) screen.fill(content, wallpaper());
        clients.blit(screen, surfaces[index], content, content, w.transparency);
        return;
    }

    screen.fill(content, t.surface);

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

    // Every pass repaints: the window frame was just drawn underneath, so the
    // toolkit's own damage tracking has nothing to go on.
    ctx.damageNow();
    ctx.begin(pointer_x, pointer_y, buttons);

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
// Input
// ---------------------------------------------------------------------------

fn run() noreturn {
    var pointer_events: [16]sys.PointerEvent = undefined;
    var key_events: [16]sys.KeyEvent = undefined;

    paint();

    while (true) {
        var acted = serve();

        if (settingsChanged()) acted = true;

        // Applications are this process's children, so their exits arrive
        // here. Collecting them is both how a window closed from inside an
        // application disappears and how the process table stays clean.
        while (sys.wait(0, sys.POLL)) |exited| {
            forgetClient(exited.pid);
            acted = true;
        }

        const keys = sys.keyRead(&key_events, sys.POLL);
        for (keys) |event| {
            // While the bar holds focus it takes everything, so plain arrows
            // walk tabs instead of reaching a window. Otherwise a chord with
            // the manager's modifier belongs to the manager and the rest
            // belongs to whoever has focus: without that split a client would
            // swallow Mod+q and the desktop would be unnavigable from inside a
            // full-screen application.
            if (bar.hasFocus()) {
                if (event.isPress()) handleKey(event);
            } else if (event.mods().super) {
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

        const moves = sys.pointerRead(&pointer_events, sys.POLL);
        var moved = false;
        for (moves) |event| {
            handlePointer(event);
            moved = true;
        }

        if (dirty) {
            // A layout change moves every tile, so each client is told its new
            // size before anything is drawn from its surface.
            for (0..layout.MAX_WINDOWS) |i| {
                if (desktop.windows[i].used) tellSize(i);
            }
            paint();
            dirty = false;
            continue;
        }

        if (acted) paintCommitted();

        // Moving the pointer redraws the pointer, and nothing else. Everything
        // it could have changed set `dirty` above.
        if (moved) {
            cursor.hide(screen);
            cursor.show(screen, pointer_x, pointer_y);
        }

        // Nothing left to do, so sleep until something happens rather than
        // asking again in a moment. Every source above has an event, so there
        // is nothing a timer would catch that this does not.
        if (!acted and !moved) idle();
    }
}

// ---------------------------------------------------------------------------
// Waiting
// ---------------------------------------------------------------------------

/// What the manager listens to. Each is a counting event, so a thing that
/// happens while the loop is busy is still there when it comes back round.
const Source = enum { keys, pointer, children, channel, wm_settings, keyboard_settings };

var sources: [@typeInfo(Source).@"enum".fields.len]u32 = @splat(0);
var listening: usize = 0;

/// Remember a source's event, if the kernel gave us one. A source that failed
/// is left out of the wait rather than waited on as handle zero.
fn listenTo(which: Source, handle: isize) void {
    if (handle < 0) return;
    sources[@intFromEnum(which)] = @intCast(handle);
    listening += 1;
}

/// Block until one of the sources has something, or until the clock in the bar
/// is due to change.
///
/// The whole loop above runs on polls, and this is what makes that correct: it
/// drains everything, finds nothing, and then sleeps here until there is
/// something to drain.
///
/// The timeout is not a poll. A poll is asking again in case something
/// happened; this is waiting for something that happens at a time already
/// known, and it is the difference between waking five times a second and
/// waking once a minute.
fn idle() void {
    var waiting: [sources.len]u32 = undefined;
    var count: usize = 0;
    for (sources) |handle| {
        if (handle == 0) continue;
        waiting[count] = handle;
        count += 1;
    }
    if (count == 0) return;

    // A timeout rather than a signal means nothing happened and the minute
    // turned, so the clock is wrong. The indicators beside it are asked at
    // the same time: they change on their own rather than in answer to
    // anything the manager did, and once a minute is often enough to notice
    // a cable pulled out.
    if (sys.waitMany(waiting[0..count], untilTheMinuteTurns()) < 0) {
        bar.refresh();
        dirty = true;
    }
}

/// Microseconds until the bar's clock reads differently.
fn untilTheMinuteTurns() usize {
    const MINUTE = 60 * 1_000_000;
    const now = sys.realtimeMicros() orelse return MINUTE;
    return MINUTE - @as(usize, @intCast(@mod(now, MINUTE)));
}

/// Bindings are by keycode, not by symbol: a shortcut lives at a place on the
/// keyboard, and binding by symbol would move every one of them when the
/// layout changes between US and AZERTY. design/10-gui.md §4.5.
fn handleKey(event: sys.KeyEvent) void {
    const mods = event.mods();
    const code: KeyCode = @enumFromInt(event.code);

    // The bar takes every key while it has focus, so arrows walk tabs rather
    // than reaching a window. Everything it can be told by pointer it can be
    // told by keyboard, which is the point of it holding focus at all.
    if (bar.hasFocus()) {
        switch (bar.key(code, &desktop)) {
            .handled, .released => {
                apply(bar.takePending());
                dirty = true;
                return;
            },
            .ignored => {},
        }
    }

    if (!mods.super) return;

    switch (code) {
        .n1, .n2, .n3, .n4, .n5, .n6, .n7, .n8, .n9 => {
            const tag: u8 = @intCast(@intFromEnum(code) - @intFromEnum(KeyCode.n1));
            if (mods.shift) desktop.moveToTag(tag) else desktop.view(tag);
        },
        .tab => desktop.viewPrevious(),
        .space => nextKeymap(),

        // Relative movement between desktops, and taking the focused window
        // along with shift. Bracket keys because they sit next to each other
        // and read as "that way".
        .bracket_left => {
            if (mods.shift) desktop.sendRelative(-1) else desktop.viewRelative(-1);
        },
        .bracket_right => {
            if (mods.shift) desktop.sendRelative(1) else desktop.viewRelative(1);
        },


        .j => desktop.focusNext(1),

        .h => desktop.nudgeMaster(-0.05),
        .l => desktop.nudgeMaster(0.05),

        .f => desktop.toggleFloating(),

        // The taskbar and the launcher, from the keyboard.
        .b => bar.focus(&desktop),
        .p => bar.openLauncher(),
        .n => _ = desktop.addDesktop(),
        .enter => {
            if (mods.shift) {
                desktop.zoom();
            } else {
                // What a tiling manager's Mod+Enter has always opened.
                _ = sys.spawnDetached("/bin/eterm", &.{"eterm"});
            }
        },
        // Shift+c asks the focused window to close; Shift+k takes it away
        // whether it agrees or not; Shift+w closes the whole desktop.
        .c => if (mods.shift) {
            if (desktop.focused) |index| requestClose(index);
        },
        .k => {
            // Shift takes a window away whether it agrees or not, which is the
            // escape hatch for one that will not go. Without shift it is just
            // focus movement.
            if (mods.shift) {
                if (desktop.focused) |index| dropWindow(index);
            } else {
                desktop.focusNext(-1);
            }
        },
        .w => {
            if (mods.shift) closeDesktop(desktop.tag);
        },

        // A theme that cannot be changed on the machine it runs on is not
        // themable in any useful sense. The file decides the default; this
        // tries the others without editing it.
        .grave => {
            _ = theme.cycle();
            broadcastTheme();
        },

        else => return,
    }

    dirty = true;
}

fn handlePointer(event: sys.PointerEvent) void {
    pointer_x = event.x;
    pointer_y = event.y;

    // An open menu tracks the pointer. Nothing else does: motion is otherwise
    // just the cursor moving, and repainting for it is what made the display
    // flicker.
    if (bar.hover(event.x, event.y, info.width, info.height, &desktop)) dirty = true;
    const was_down = buttons.left;
    const was_right = buttons.right;
    buttons = event.buttons;

    // Focus follows click, not hover: at this size and with a touchpad this
    // small, hovering over the wrong tile is something that happens by
    // accident several times a minute.
    const pressed_left = !was_down and buttons.left;
    const pressed_right = !was_right and buttons.right;

    if (pressed_left or pressed_right) {
        // The bar gets first refusal: a menu it has open is modal, and it
        // reaches below its own strip.
        const was_focused = desktop.focused;
        const action = bar.click(event.x, event.y, info.width, info.height, pressed_right, &desktop);
        if (action == .none and pressed_left) desktop.focusAt(event.x, event.y);
        apply(action);

        // Only when the desktop actually looks different. A click inside a
        // window belongs to the window, and repainting the screen for it is
        // what a person sees as the whole display flashing.
        if (action != .none or desktop.focused != was_focused or bar.menuOpen()) {
            dirty = true;
        }
    }

    // Whatever the bar did not take goes to the window under the pointer. A
    // click that focused a window is passed through as well, so a control
    // under it responds to the same press that gave it focus rather than
    // needing a second one.
    if (!bar.contains(event.y, info.height) and !bar.menuOpen()) {
        postPointer(event, buttons.left);
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
            forgetClient(pid);
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
                .theme = themeName(),
            } },
        },
        .handles = &hello_handles,
    };
}

fn onCreate(pid: u32, req: *const wire.Req) Answer {
    if (table.find(pid) == null) return refuse(.bad_request);

    // A dialog floats too. It is a separate flag because it also centres and
    // belongs to whatever raised it, but a dialog that got tiled would split
    // the window it was asked from in half.
    const flags = req.body.create.flags;
    const index = desktop.open("", flags.floating or flags.dialog) orelse
        return refuse(.no_room);

    const w = &desktop.windows[index];
    w.transparency = req.body.create.transparency;
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
    const commit = req.body.commit;

    // What the client says changed, not the whole window. A window redraws
    // whenever the pointer crosses it, and repainting all of it for that is
    // what a person sees as flicker.
    //
    // No rectangles means nothing changed, which is the common answer from a
    // toolkit whose controls all decided they looked the same as last pass.
    // A client that wants everything says so by naming everything.
    for (commit.rects[0..@min(commit.n, commit.rects.len)]) |r| {
        window_damage[index].add(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
    }
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

/// Move to the next keyboard layout.
///
/// Through the settings rather than straight at the kernel, because a layout
/// chosen with a chord and one chosen in a settings file should be the same
/// choice: `cfgd` applies it and writes it down, so it is still the layout
/// next time.
fn nextKeymap() void {
    const now = @intFromEnum(proto.settings.load("input").keymap);
    const next: proto.settings.Keymap = @enumFromInt((now + 1) % keymaps.count);

    proto.settings.set("input.keymap", @tagName(next)) catch return;

    dirty = true;
}

var settings_event: u32 = 0;
var keyboard_event: u32 = 0;

/// Take up a settings change somebody else made.
///
/// Checked without blocking, because the loop blocks once at the bottom on
/// every source at once, including this one.
fn settingsChanged() bool {
    // The keyboard is somebody else's to apply; all this has to do is redraw
    // the two letters in the bar that say which one it is.
    if (keyboard_event != 0 and sys.waitMany(&.{keyboard_event}, sys.POLL) >= 0) {
        if (config.reloadKeyboard()) dirty = true;
    }

    if (settings_event == 0) return false;
    if (sys.waitMany(&.{settings_event}, sys.POLL) < 0) return false;
    if (!config.reload()) return false;

    const wanted = config.current();
    desktop.mfact = @splat(wanted.masterFraction());
    desktop.bounds = bar.contentArea(info.width, info.height);

    // The theme is the desktop's, not this process's: a client draws its own
    // window and has to be told what changed under it.
    broadcastTheme();
    ctx.damage();
    dirty = true;
    return true;
}

/// The active theme's name, padded for the wire.
fn themeName() [16]u8 {
    var padded: [16]u8 = @splat(0);
    const name = theme.current().name;
    const n = @min(name.len, padded.len);
    @memcpy(padded[0..n], name[0..n]);
    return padded;
}

/// Tell every client the theme changed, so the desktop stays one desktop.
fn broadcastTheme() void {
    for (&table.clients) |*client| {
        if (client.pid == 0) continue;
        client.post(.{
            .tag = .theme,
            .t_us = @truncate(sys.clockMicros()),
            .body = .{ .theme = .{ .name = themeName() } },
        });
    }
}

/// Carry out whatever the bar decided.
///
/// Session actions come back here rather than being done in the bar, because
/// ending a session means handing the display back and letting the console
/// have it again, which is the manager's business and not the menu's.
fn apply(action: bar.Action) void {
    switch (action) {
        .none, .consumed => {},
        .close_window => |index| requestClose(index),
        .close_desktop => |tag| closeDesktop(tag),
        .quit => quit(),
        .reboot => sys.shutdown(sys.REBOOT),
        .power_off => sys.shutdown(sys.POWER_OFF),
    }
}

/// End the session: ask every client to go, give the display back, and exit.
///
/// The console gets the framebuffer again when the display handle closes, so
/// whatever started the manager finds a working terminal rather than a screen
/// still showing a desktop nobody is driving.
fn quit() noreturn {
    for (0..layout.MAX_WINDOWS) |i| {
        if (desktop.windows[i].used) requestClose(i);
    }
    sys.exit(0);
}

/// Ask a window to close, or close it if nothing owns it.
///
/// A client is asked rather than dropped: it may have something to save, and
/// taking its surface away gives it no chance to. One that ignores the request
/// is dealt with by `Mod+Shift+k`, which is the escape hatch for a program
/// that will not go.
fn requestClose(index: usize) void {
    const w = &desktop.windows[index];
    if (!w.used) return;

    if (w.client_pid == 0) {
        desktop.close(index);
        dirty = true;
        return;
    }

    const client = table.find(w.client_pid) orelse {
        dropWindow(index);
        return;
    };
    client.post(.{
        .tag = .close_req,
        .win = w.client_win,
        .t_us = @truncate(sys.clockMicros()),
    });
}

/// Let go of everything a client had.
///
/// Both for a client that says goodbye and for one that simply exits. The
/// second is the ordinary case rather than the exception: a program closed
/// from its own menu, or one that crashed, never gets to say anything, and a
/// window left behind by a process that no longer exists is a window nothing
/// can ever remove.
fn forgetClient(pid: u32) void {
    for (0..layout.MAX_WINDOWS) |i| {
        const w = &desktop.windows[i];
        if (w.used and w.client_pid == pid) dropWindow(i);
    }
    table.evict(pid);
}

/// Take a window away without asking. For a client that has gone, or one that
/// refused to.
fn dropWindow(index: usize) void {
    if (surfaces[index].handle != 0) _ = sys.close(surfaces[index].handle);
    surfaces[index] = .{};
    desktop.close(index);
    dirty = true;
}

/// Close everything on a desktop, then the desktop itself.
pub fn closeDesktop(tag: u8) void {
    var buf: [layout.MAX_WINDOWS]usize = undefined;
    const list = desktop.windowsToClose(tag, &buf);
    for (list) |index| requestClose(index);

    // Removed only once it is actually empty: a client that takes a moment to
    // exit should not have its desktop vanish from under it.
    desktop.removeDesktop(tag);
    dirty = true;
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

/// Send pointer input to whichever window is under the pointer.
///
/// Coordinates are made window-local before they go: a client knows how large
/// it is and nothing about where it sits, which is what lets the manager move
/// a tile without telling anyone.
fn postPointer(event: sys.PointerEvent, pressed: bool) void {
    const index = windowAt(event.x, event.y) orelse return;
    const w = &desktop.windows[index];
    if (w.client_pid == 0) return;

    const client = table.find(w.client_pid) orelse return;
    const inner = contentRect(index);

    const local_x: i16 = @intCast(event.x - inner.x);
    const local_y: i16 = @intCast(event.y - inner.y);
    const now: u32 = @truncate(sys.clockMicros());

    if (event.buttons_changed != 0) {
        client.post(.{
            .tag = .ptr_button,
            .win = w.client_win,
            .t_us = now,
            .body = .{ .button = .{
                .btn = 0,
                .down = @intFromBool(pressed),
                .x = local_x,
                .y = local_y,
            } },
        });
        return;
    }

    if (event.wheel != 0) {
        client.post(.{
            .tag = .scroll,
            .win = w.client_win,
            .t_us = now,
            .body = .{ .scroll = .{ .dy = event.wheel, .dx = 0 } },
        });
        return;
    }

    client.post(.{
        .tag = .ptr_motion,
        .win = w.client_win,
        .t_us = now,
        .body = .{ .motion = .{ .x = local_x, .y = local_y } },
    });
}

/// The topmost window containing a point, floating windows first.
fn windowAt(x: i32, y: i32) ?usize {
    var buf: [layout.MAX_WINDOWS]usize = undefined;
    const list = desktop.visible(&buf);

    var k = list.len;
    while (k > 0) {
        k -= 1;
        if (desktop.windows[list[k]].area.contains(x, y)) return list[k];
    }
    return null;
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
