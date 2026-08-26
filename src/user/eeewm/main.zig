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
const layout = @import("layout.zig");
const bar = @import("bar.zig");
const ui = @import("eui").widget;
const sys = @import("sys");
const out = @import("ulib").out;

const Rect = eui.Rect;
const KeyCode = sys.KeyCode;

const SERVICE = "gui";

var screen: eui.Surface = undefined;
var info: sys.DisplayInfo = .{};
var desktop: layout.Desktop = .{};

/// Toolkit state for the focused window's content.
///
/// One context, not one per window: only the focused window takes input, and a
/// context per window would keep hover and focus state for controls nobody can
/// reach. Real clients will each own their own, in their own process.
var ctx: ui.Context = undefined;

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

    _ = sys.svcRegister(SERVICE);

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

    // Client content goes here once there is a protocol to receive it. Until
    // then the window draws its own, through the same toolkit an application
    // would use, which is what keeps that toolkit exercised rather than merely
    // present.
    const inner = area.inset(width + t.padding);
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
        var acted = false;

        const keys = sys.keyRead(&key_events, sys.POLL);
        for (keys) |event| {
            if (!event.isPress()) continue;
            handleKey(event);
            acted = true;
        }

        const moves = sys.pointerRead(&pointer_events, if (acted) sys.POLL else 200_000);
        for (moves) |event| {
            handlePointer(event);
            acted = true;
        }

        if (!acted) continue;
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
                _ = desktop.open("Terminal", false);
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
