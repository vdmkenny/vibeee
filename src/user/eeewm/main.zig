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
const rest = @import("idle.zig");
const platform = @import("proto").platform;
const proto = @import("proto");
const region = @import("eui").region;
const ui = @import("eui").widget;
const sys = @import("sys");
const bindings = @import("ulib").bindings;
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
/// The channel clients call in on.
var service: u32 = 0;

var pointer_x: i32 = 0;
var pointer_y: i32 = 0;
var buttons: sys.Buttons = .{};

/// The display, held so the session can give it back before it says goodbye.
var display_handle: isize = 0;

/// Everything needs redrawing. Set by anything that changes the arrangement,
/// because working out what survived a retile costs more than repainting.
var dirty = true;

/// The open menu changed and nothing underneath it did.
///
/// A highlight moving one row, a slider dragged, a panel appearing over
/// pixels that are still good: none of that is a reason to redraw the
/// desktop, every window and the bar. Doing so is what a person sees as the
/// whole screen flashing, and on a display with one buffer they see it every
/// time the pointer crosses a row.
var overlay_dirty = false;

export fn _start() callconv(.c) noreturn {
    wmMain();
}

fn wmMain() noreturn {
    display_handle = sys.displayAcquire(&info) catch |err| {
        out.text(switch (err) {
            error.NoDisplay => "eeewm: no framebuffer. The machine booted in text mode; " ++
                "add `fb` to the kernel command line.\n",
            error.Busy => "eeewm: something already owns the display.\n",
            error.OutOfMemory => "eeewm: not enough memory to take the display.\n",
        });
        out.flush();
        sys.exit(1);
    };

    const pixels = sys.shmMap(@intCast(display_handle), .{ .writable = true }) orelse {
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

    openClipboard();

    const wanted = config.load();
    desktop.bounds = bar.contentArea(info.width, info.height);
    desktop.mfact = @splat(wanted.masterFraction());

    // Signalled by cfgd when anything in the wm domain changes, so a theme
    // chosen from a shell reaches the desktop without a restart. Zero when the
    // service is not up, which the poll below reads as nothing to hear.
    power_settings = proto.settings.load("power");
    last_input_us = sys.clockMicros();

    settings_event = proto.settings.watch("wm") catch 0;
    power_event = proto.settings.watch("power") catch 0;
    keyboard_event = proto.settings.watch("input") catch 0;
    listenTo(.keys, sys.watch(.keys));
    listenTo(.pointer, sys.watch(.pointer));
    listenTo(.children, sys.watch(.children));
    listenTo(.wm_settings, @intCast(settings_event));
    listenTo(.keyboard_settings, @intCast(keyboard_event));
    listenTo(.power_settings, @intCast(power_event));

    // The desktop paints its own ground, and only the parts of it that show:
    // filling the screen and then covering most of it again is the flash this
    // whole path exists to avoid.
    ctx = ui.Context.initOn(screen, .none);
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
    bare.subtract(bar.band(info.height));
    for (visible) |index| bare.subtract(desktop.windows[index].area);
    const wall = wallpaper();
    for (bare.items()) |piece| screen.fill(piece, wall);

    bar.paint(screen, info.width, info.height, &desktop);

    for (visible) |index| {
        paintWindow(index, desktop.focused == index);
    }

    // After the windows: a dropdown reaches over them.
    bar.paintOverlay(screen, info.width, info.height, &desktop);

    for (&desktop.windows) |*w| w.damage.clear();
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
        const damage = &desktop.windows[index].damage;
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
    const w = &desktop.windows[index];
    if (!w.mapped or !desktop.windows[index].surface.valid()) return;

    const content = w.area.inset(borderWidth());

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

        clients.blit(screen, desktop.windows[index].surface, content, on_screen);
    }
}




fn paintWindow(index: usize, focused: bool) void {
    const t = theme.current();
    const w = &desktop.windows[index];
    const area = w.area;
    if (area.isEmpty()) return;

    // A border is a comparison, and one window has nothing to be compared
    // with. Alone on its tag it is drawn in the colour of what would be
    // behind it, so there is nothing to see: a ring around the whole screen
    // says only that the desktop is doing what it always does.
    //
    // The focused ring is thicker and is drawn over the client's outermost
    // row rather than pushing it in. What the client was told its size was
    // cannot depend on whether it has focus or on how many windows share the
    // desktop, or the pixels it hands over stop lining up with the hole they
    // go in.
    const alone = desktop.aloneOnTag();
    const width = if (focused and !alone) t.border_width_focused else t.border_width;
    const content = area.inset(borderWidth());

    // A client that has given us a surface gets composited from it. One that
    // has not draws the manager's own placeholder, which is what the desktop
    // looks like before anything has connected.
    if (w.mapped and desktop.windows[index].surface.valid()) {
        clients.blit(screen, desktop.windows[index].surface, content, content);
        screen.borderInset(area, width, borderColour(focused, alone));
        return;
    }

    screen.borderInset(area, width, borderColour(focused, alone));
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
            // The number chips in the bar follow the modifier itself, both
            // edges: they appear when Super goes down and leave with it.
            if (bar.setSuperHeld(event.mods().super)) paintBar();

            // While the bar holds focus it takes everything, so plain arrows
            // walk tabs instead of reaching a window. Otherwise a chord with
            // the manager's modifier belongs to the manager and the rest
            // belongs to whoever has focus: without that split a client would
            // swallow Mod+q and the desktop would be unnavigable from inside a
            // full-screen application.
            stirred();

            if (bar.hasFocus()) {
                if (event.isPress()) handleKey(event);
            } else if (event.mods().super) {
                if (event.isPress()) handleKey(event);
            } else if (event.code == @intFromEnum(KeyCode.f1) and desktop.focused == null) {
                // Help, where every desktop has put it. Only with nothing
                // focused: a window on screen owns the key, and a program
                // with its own help would never see it otherwise.
                if (event.isPress()) {
                    _ = sys.spawnDetached("/bin/settings", &.{ "settings", "help" });
                }
            } else {
                postToFocused(.{
                    .tag = .key,
                    .body = .{ .key = .{
                        .code = event.code,
                        .down = event.pressed,
                        .mods = event.modifiers,
                    } },
                });
                // A chord is not typing. Alt and Control held mean the key
                // names a command, and a window that received the character
                // as well would insert it into whatever the command just
                // did. AltGr is not one of these: on a Belgian keyboard it
                // is how @ and the brackets are typed at all.
                const chord = event.mods().alt or event.mods().control;
                if (event.codepoint != 0 and event.isPress() and !chord) {
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

        if (overlay_dirty) {
            // The panel and the pointer, and nothing else on the screen.
            cursor.hide(screen);
            bar.paintOverlay(screen, info.width, info.height, &desktop);
            cursor.show(screen, pointer_x, pointer_y);
            overlay_dirty = false;
            moved = false;
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
const Source = enum {
    keys,
    pointer,
    children,
    channel,
    wm_settings,
    keyboard_settings,
    power_settings,
};

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
    //
    // Only the bar is repainted for it. Setting `dirty` here redrew the
    // desktop and every window to move a five character clock, which on the
    // panel was a visible full-screen wipe once a minute.
    if (sys.waitMany(waiting[0..count], untilSomethingIsDue()) < 0) {
        // A timeout means nothing happened: the clock turned, or the machine
        // has now been alone long enough for something to be done about it.
        settleIdle();
        checkPack();
        bar.refresh();
        paintBar();
    }
}

/// How long the one wait may last: whichever of the clock and the idle
/// timers falls first.
fn untilSomethingIsDue() usize {
    const clock = untilTheClockTurns();
    const step = rest.stepFor(power_settings, idleFor());
    const due = step.due_us orelse return clock;
    return @min(clock, @as(usize, @intCast(due)));
}

/// How long since anybody did anything.
fn idleFor() u64 {
    return sys.clockMicros() -| last_input_us;
}

/// Somebody is here: whatever was turned down comes back.
fn stirred() void {
    last_input_us = sys.clockMicros();
    if (screen_state != .awake) settleIdle();
}

/// Put the screen into whatever being left alone this long calls for.
///
/// The level chosen by hand is remembered rather than read back, because what
/// is read back while it is dimmed is the dimmed level: a machine that woke
/// twice would end up as dark as it could go.
fn settleIdle() void {
    const step = rest.stepFor(power_settings, idleFor());
    if (step.want == screen_state) return;

    const lamp = platform.backlight() orelse {
        screen_state = step.want;
        return;
    };

    if (screen_state == .awake) chosen_level = lamp.level;
    screen_state = step.want;

    _ = platform.setBacklight(@intCast(rest.levelFor(
        step.want,
        chosen_level,
        power_settings.dim_to,
        1,
    )));
}

/// What the pack says, and what was chosen to happen when it says it.
///
/// Read on the same wake as the clock, which is once a minute: a pack does
/// not fall five per cent between two of those, and asking oftener would be
/// asking the embedded controller for an answer nobody is waiting for.
fn checkPack() void {
    const cell = platform.battery() orelse return;
    const percent = platform.charge(cell) orelse return;
    if (!rest.packIsLow(percent, cell.state() == .discharging, power_settings.low_at)) {
        warned_low = false;
        return;
    }

    switch (power_settings.low_action) {
        .warn => {
            if (warned_low) return;
            warned_low = true;
            bar.warnBattery();
            paintBar();
        },
        .screen_off => {
            if (platform.backlight()) |lamp| {
                if (screen_state == .awake) chosen_level = lamp.level;
                screen_state = .off;
                _ = platform.setBacklight(0);
            }
        },
        .shut_down => sys.shutdown(sys.POWER_OFF),
    }
}

/// Repaint the bar and nothing else. It fills its own band, so nothing has
/// to be cleared first; only the cursor has to be lifted if it is in the way.
fn paintBar() void {
    const band = bar.band(info.height);
    const covered = cursor.covers(.{ .x = 0, .y = band.y, .w = info.width, .h = band.h });
    if (covered) cursor.hide(screen);
    bar.paint(screen, info.width, info.height, &desktop);
    if (bar.menuOpen()) bar.paintOverlay(screen, info.width, info.height, &desktop);
    if (covered) cursor.show(screen, pointer_x, pointer_y);
}

/// Microseconds until the clock on show reads differently.
///
/// The bar says minutes and its menu says seconds, so what the machine has to
/// wake for depends on which of them somebody is looking at. Nothing polls
/// either way: this is the deadline on the one wait.
/// When anybody last did anything, and what the screen is in because of it.
var last_input_us: u64 = 0;
var screen_state: rest.State = .awake;
/// The level somebody chose, kept while it is turned down: what is read back
/// from a dimmed panel is the dimmed level.
var chosen_level: u32 = 0;
var warned_low = false;

/// What the machine does when it is left alone and when the pack runs out.
var power_settings: proto.settings.Power = .{};

fn untilTheClockTurns() usize {
    const step: i64 = if (bar.clockOpen()) 1_000_000 else 60 * 1_000_000;
    const now = sys.realtimeMicros() orelse return @intCast(step);
    return @intCast(step - @mod(now, step));
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
        switch (bar.key(code, event.codepoint, mods, &desktop)) {
            .handled, .released => {
                apply(bar.takePending());
                dirty = true;
                return;
            },
            .ignored => {},
        }
    }

    if (!mods.super) return;

    // The numbers are a family rather than nine bindings: which desktop, and
    // whether to take the window along.
    if (@intFromEnum(code) >= @intFromEnum(KeyCode.n1) and @intFromEnum(code) <= @intFromEnum(KeyCode.n9)) {
        const tag: u8 = @intCast(@intFromEnum(code) - @intFromEnum(KeyCode.n1));
        if (mods.shift) desktop.moveToTag(tag) else desktop.view(tag);
        dirty = true;
        return;
    }

    // Everything else comes from the table the help pane reads, so a chord
    // that is listed is a chord that works and the other way round. The
    // switch is exhaustive: a binding added there without a handler here does
    // not build.
    const action = bindings.lookup(code, mods.shift) orelse return;
    perform(action);
}

/// Do one of the things the manager can do.
///
/// Reached from a chord and from the launcher, which finds these by name: a
/// list of what the keys do and a list of what can be asked for are the same
/// list, and two of them would drift the first time one grew a row.
fn perform(action: bindings.Action) void {
    switch (action) {
        .terminal => _ = sys.spawnDetached("/bin/eterm", &.{"eterm"}),
        .launcher => bar.openLauncher(&desktop),
        .focus_bar => bar.focus(&desktop),

        .focus_next => desktop.focusNext(1),
        .focus_previous => desktop.focusNext(-1),
        .zoom => desktop.zoom(),
        .maximise => _ = desktop.toggleMaximised(),
        .floating => desktop.toggleFloating(),
        .master_smaller => desktop.nudgeMaster(-0.05),
        .master_larger => desktop.nudgeMaster(0.05),

        .view_left => desktop.viewRelative(-1),
        .view_right => desktop.viewRelative(1),
        .send_left => desktop.sendRelative(-1),
        .send_right => desktop.sendRelative(1),
        .view_previous => desktop.viewPrevious(),
        .new_desktop => _ = desktop.addDesktop(),

        .close_window => if (desktop.focused) |index| requestClose(index),
        // The escape hatch for a window that will not go when asked.
        .kill_window => if (desktop.focused) |index| dropWindow(index),
        .close_desktop => closeDesktop(desktop.tag),

        .next_keymap => nextKeymap(),
        // A theme that cannot be changed on the machine it runs on is not
        // themable in any useful sense. The file decides the default; this
        // tries the others without editing it.
        .cycle_theme => {
            _ = theme.cycle();
            broadcastTheme();
        },
    }

    dirty = true;
}

fn handlePointer(event: sys.PointerEvent) void {
    stirred();
    pointer_x = event.x;
    pointer_y = event.y;

    // An open menu tracks the pointer. Nothing else does: motion is otherwise
    // just the cursor moving, and repainting for it is what made the display
    // flicker.
    if (bar.hover(event.x, event.y, info.width, info.height, &desktop)) overlay_dirty = true;
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
        const menu_before = bar.menuOpen();
        const action = bar.click(event.x, event.y, info.width, info.height, pressed_right, &desktop);
        if (action == .none and pressed_left) desktop.focusAt(event.x, event.y);
        apply(action);

        // Only when the desktop actually looks different. A click inside a
        // window belongs to the window, and repainting the screen for it is
        // what a person sees as the whole display flashing.
        //
        // A menu that is still open after the press changed only itself: the
        // volume was dragged, a row was chosen, a panel appeared over pixels
        // that are still good. A menu that has just closed is the one case
        // that needs the screen back, because what it covered is gone.
        const menu_after = bar.menuOpen();
        if (action != .none or desktop.focused != was_focused or (menu_before and !menu_after)) {
            dirty = true;
        } else if (menu_before or menu_after) {
            overlay_dirty = true;
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
        .clipboard => onClipboard(),
        .clipboard_put => onClipboardPut(req),
        .map => onMap(pid, req),
        .unmap, .destroy_win => onDestroy(pid, req),
        .bye => blk: {
            forgetClient(pid);
            break :blk .{ .rep = .{ .gen = table.generation } };
        },
    };
}

// ---------------------------------------------------------------------------
// The clipboard
//
// One buffer for the whole session, held here because the manager is the one
// process every window already talks to and the only one that outlives them
// all. Copying is a request, so the length written here is the manager's word
// rather than a client's; pasting is a read of mapped memory and costs
// nothing at all.
// ---------------------------------------------------------------------------

var clipboard_handle: u32 = 0;
var clipboard: []u8 = &.{};
var clipboard_out: [1]u32 = @splat(0);

fn clipboardHead() ?*wire.ClipHead {
    if (clipboard.len < @sizeOf(wire.ClipHead)) return null;
    return @ptrCast(@alignCast(clipboard.ptr));
}

fn openClipboard() void {
    const handle = sys.shmCreate(wire.CLIPBOARD_BYTES);
    if (handle < 0) return;
    const mapped = sys.shmMap(@intCast(handle), .{ .writable = true }) orelse return;

    clipboard_handle = @intCast(handle);
    clipboard = @as([*]u8, @ptrCast(mapped))[0..wire.CLIPBOARD_BYTES];
    if (clipboardHead()) |head| head.* = .{};
}

fn onClipboard() Answer {
    if (clipboard_handle == 0) {
        return .{ .rep = .{ .status = .no_room, .gen = table.generation } };
    }

    const head = clipboardHead() orelse
        return .{ .rep = .{ .status = .no_room, .gen = table.generation } };

    clipboard_out = .{clipboard_handle};
    return .{
        .rep = .{
            .gen = table.generation,
            .body = .{ .clip = .{
                .len = @intCast(head.len),
                .capacity = @intCast(clipboard.len - @sizeOf(wire.ClipHead)),
            } },
        },
        .handles = &clipboard_out,
    };
}

/// A client says how much it wrote. Clamped here, because every other window
/// reads this length to decide how far into the segment to look.
fn onClipboardPut(req: *const wire.Req) Answer {
    const head = clipboardHead() orelse
        return .{ .rep = .{ .status = .no_room, .gen = table.generation } };

    const room = clipboard.len - @sizeOf(wire.ClipHead);
    head.len = @min(req.body.clip.len, room);
    head.generation +%= 1;

    return .{ .rep = .{
        .gen = table.generation,
        .body = .{ .clip = .{ .len = @intCast(head.len), .capacity = @intCast(room) } },
    } };
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
    const index = desktop.open(
        "",
        flags.floating or flags.dialog,
        req.body.create.min_w,
        req.body.create.min_h,
    ) orelse return refuse(.no_room);

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
    if (desktop.windows[index].surface.handle != 0) _ = sys.close(desktop.windows[index].surface.handle);
    desktop.windows[index].surface = surface;
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
        desktop.windows[index].damage.add(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
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

    if (desktop.windows[index].surface.handle != 0) _ = sys.close(desktop.windows[index].surface.handle);
    desktop.windows[index].surface = .{};
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
var power_event: u32 = 0;
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

    // What to do when the machine is left alone. Taken up as soon as it is
    // chosen, so somebody setting it to never does not have to wait out the
    // old interval to find out whether it worked.
    if (power_event != 0 and sys.waitMany(&.{power_event}, sys.POLL) >= 0) {
        power_settings = proto.settings.load("power");
        stirred();
    }

    if (settings_event == 0) return false;
    if (sys.waitMany(&.{settings_event}, sys.POLL) < 0) return false;
    if (!config.reload()) return false;

    const wanted = config.current();
    desktop.mfact = @splat(wanted.masterFraction());
    desktop.setBounds(bar.contentArea(info.width, info.height));

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
        // Wherever it is: the launcher finds a window by name, and a window
        // found on another desktop is no use until that desktop is in view.
        .focus_window => |index| desktop.viewWindow(index),
        .verb => |what| perform(what),
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

    // The display goes back before anything is said, because the console
    // throws away whatever is written while it is suspended: a farewell
    // printed with the desktop still up is a farewell nobody reads.
    _ = sys.close(@intCast(display_handle));
    out.text("eeewm: the desktop has exited. Start it again with eeewm.\n");
    out.flush();
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
    if (desktop.windows[index].surface.handle != 0) _ = sys.close(desktop.windows[index].surface.handle);
    desktop.windows[index].surface = .{};
    desktop.close(index);
    dirty = true;
}

/// Close everything on a desktop, then the desktop itself.
pub fn closeDesktop(tag: u8) void {
    var buf: [layout.MAX_WINDOWS]usize = undefined;
    const list = desktop.windowsToClose(tag, &buf);
    for (list) |index| requestClose(index);

    // Nothing removes the desktop: it stops existing when its windows have
    // gone and nobody is looking at it. If we are looking at it, look at the
    // lowest desktop that still has something, or home.
    if (tag == desktop.tag) {
        const occupied_tags = desktop.occupied();
        for (0..layout.MAX_DESKTOPS) |t| {
            if (t != tag and occupied_tags[t]) {
                desktop.view(@intCast(t));
                dirty = true;
                return;
            }
        }
        desktop.view(0);
    }
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

/// How far a window's content sits inside its tile.
///
/// One number for every window, whatever its state. The compositor, the size
/// the client was told, and the coordinates a pointer event arrives in all
/// measure from this edge, and an edge that moved when a window took focus
/// would move it under three things that had not been told.
fn borderWidth() i32 {
    return theme.current().border_width;
}

/// What the ring around a window is drawn in.
fn borderColour(focused: bool, alone: bool) eui.Color {
    const t = theme.current();
    if (alone) return wallpaper();
    return if (focused) t.border_focused else t.border;
}

/// Where a window's client content goes: the tile, less its border.
fn contentRect(index: usize) Rect {
    return desktop.windows[index].area.inset(borderWidth());
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
