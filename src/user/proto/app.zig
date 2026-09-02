//! The frame every windowed program runs in.
//!
//! Opening the connection, owning the window, pumping events, resizing the
//! surface, applying theme changes, running the draw pass and committing what
//! it damaged: every application did all of this itself, in almost the same
//! words, and four copies of a loop is four places for one of them to be
//! subtly wrong. The bug that motivated this was exactly that: one program's
//! copy forgot to hand unclaimed keys to its controls, and its lists ignored
//! the arrow keys while every other program's worked.
//!
//! A program brings hooks: a draw pass, and only the interceptions it
//! actually wants. Everything a hook declines falls through to the toolkit,
//! so the default behaviour of a program is the toolkit's behaviour.

const eui = @import("eui");
const sys = @import("sys");
const client = @import("client.zig");
const wm = @import("wm.zig");
const out = @import("ulib").out;

/// The connection and window, public because a program occasionally needs
/// them for what the frame does not do: a dialog window, a title change.
pub var connection: client.Connection = undefined;
pub var window: u8 = 0;

/// The one drawing context. Programs reach it through a pointer so state
/// like damage requests has one owner.
pub var ctx: eui.Context = undefined;

pub const KeyCode = eui.widget.KeyCode;
pub const Modifiers = eui.widget.Modifiers;

pub const Hooks = struct {
    /// Draw one pass. The context is begun and ended around the call, the
    /// ground is already painted, and what the controls damage is committed
    /// afterwards; the hook only says what is in the window.
    draw: *const fn () void,

    /// A key went down. True consumes it; false hands it to the controls,
    /// which is where arrows, tab and enter usually belong.
    key: ?*const fn (code: KeyCode, mods: Modifiers) bool = null,

    /// A character was typed. Same contract as `key`.
    text: ?*const fn (codepoint: u32) bool = null,

    /// First refusal on every event, for the program with a second window: a
    /// dialog's traffic is nobody else's business. True consumes the event.
    event: ?*const fn (ev: wm.Ev) bool = null,

    /// Asked to close, by the manager or the frame. True lets the window go;
    /// false keeps it, for a program with something unsaved to ask about
    /// first. Absent, the window goes. The manager's kill chord does not ask.
    close: ?*const fn () bool = null,

    /// The wait timed out. For a program whose numbers age: return true to
    /// draw a fresh pass.
    tick: ?*const fn () bool = null,

    /// How long the wait may sleep before `tick`. A program without a tick
    /// leaves this alone and sleeps until something happens.
    tick_us: usize = 1_000_000,

    /// Opens above the tiling rather than in it. For a program that is a
    /// tool rather than a place to work: a calculator wants to sit over
    /// what it is being used on, not take half the screen from it. Only
    /// where it starts, because Super+F docks it into the tiling and lifts
    /// it out again whatever it asked for.
    floating: bool = false,
};

var hooks: Hooks = undefined;

/// When the next periodic pass is due. Held here rather than in the loop so
/// that `retick` can bring it forward the moment the period shortens.
var next_tick_us: u64 = 0;

/// Change how often the wait may time out. For a program whose ticking is a
/// mode rather than a constant: meters on show want a lively wake, and the
/// same window on another pane should sleep until something happens.
pub fn retick(period_us: usize) void {
    hooks.tick_us = period_us;
    next_tick_us = sys.clockMicros() +| period_us;
}
var buttons: eui.widget.Buttons = .{};
var pointer_x: i32 = 0;
var pointer_y: i32 = 0;

/// Open the connection, create the window, and run forever.
///
/// `name` is what the manager knows the program as; `title` is what a person
/// reads on its tab.
fn clipboardGet() []const u8 {
    return connection.clipboardText();
}

fn clipboardPut(text: []const u8) void {
    connection.clipboardPut(text);
}

pub fn run(
    name: []const u8,
    title: []const u8,
    width: u16,
    height: u16,
    with: Hooks,
) noreturn {
    hooks = with;

    connection = client.Connection.open(name) catch {
        out.text(name);
        out.text(": no window manager is running\n");
        out.flush();
        sys.exit(1);
    };

    window = connection.createWindow(
        .{ .floating = with.floating },
        width,
        height,
    ) catch sys.exit(1);
    connection.setTitle(window, title) catch {};

    // Cut, copy and paste reach the manager's one clipboard, so text crosses
    // between windows rather than only within one. Without a manager the
    // toolkit keeps its own, which is what a program run on its own gets.
    ctx.clipboard = .{ .get = clipboardGet, .put = clipboardPut };

    // When the next periodic pass is due, for a program that has one. The
    // wait sleeps until then rather than for a fixed span, so a program with
    // nothing to tick sleeps until something happens instead of waking on a
    // timer it has no use for, which on a machine that runs on a battery is
    // the difference between a window at rest and a window keeping the CPU up.
    next_tick_us = sys.clockMicros() +| hooks.tick_us;

    while (true) {
        const timeout: usize = if (hooks.tick == null) sys.FOREVER else timeout: {
            const now = sys.clockMicros();
            if (now >= next_tick_us) break :timeout 0;
            break :timeout @intCast(@min(next_tick_us - now, @as(u64, sys.FOREVER) - 1));
        };

        const event = connection.next(timeout) orelse {
            // Woken with nothing to take. The periodic pass runs only once its
            // period has truly elapsed: a wake from a doorbell that had already
            // been answered finds the clock short of the deadline and waits
            // again, rather than running the tick early. The tick is where a
            // meter re-reads the machine and a listing re-stats its volumes,
            // so running it on every spare wake is what made a burst of input
            // crawl.
            if (hooks.tick) |tick| {
                const now = sys.clockMicros();
                if (now >= next_tick_us) {
                    next_tick_us = now +| hooks.tick_us;
                    if (tick()) redraw();
                }
            }
            continue;
        };

        if (hooks.event) |own| {
            if (own(event)) {
                // Whatever the hook did may have damaged this window: a
                // dialog closing sets the title and the status line. The
                // pass costs nothing when nothing changed.
                redraw();
                continue;
            }
        }

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
            .scroll => {
                ctx.postScroll(event.body.scroll.dy);
                redraw();
            },
            .key => {
                if (event.body.key.down == 0) continue;
                const code: KeyCode = @enumFromInt(event.body.key.code);
                const mods: Modifiers = @bitCast(event.body.key.mods);
                const taken = if (hooks.key) |own| own(code, mods) else false;
                if (!taken) ctx.postKey(@intCast(event.body.key.code), mods);
                redraw();
            },
            .text => {
                const taken = if (hooks.text) |own| own(event.body.text.cp) else false;
                if (!taken) ctx.postText(event.body.text.cp);
                redraw();
            },
            // The appearance arrives as two records; the connection folds
            // them and applies the whole each time, so either order and
            // either one alone leave the window drawn in what it knows.
            .theme, .look => {
                _ = connection.adoptLook(event);
                ctx.damageNow();
                redraw();
            },
            // Events were lost, so nothing on screen can be trusted.
            .overflow => {
                ctx.damageNow();
                redraw();
            },
            // A window that stays has a question to show, and the pass that
            // shows it runs now rather than on the next event.
            .close_req => if (mayClose()) sys.exit(0) else redraw(),
            else => {},
        }
    }
}

/// Whether the window may go now: the program's say, or yes.
fn mayClose() bool {
    const may = hooks.close orelse return true;
    return may();
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
    paint();
    connection.map(window) catch {};
}

fn redraw() void {
    const surface = connection.surfaceOf(window) orelse return;
    ctx.surface = surface.*;
    paint();
    // A control asked for a full pass mid-pass; give it one now rather than
    // on the next event, or the window sits half-drawn until the pointer
    // moves.
    if (ctx.pending) paint();
}

fn paint() void {
    ctx.begin(pointer_x, pointer_y, buttons);
    hooks.draw();
    ctx.end();
    connection.commit(window, ctx.damageList()) catch {};
}
