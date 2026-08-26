//! eTerm: a terminal window.
//!
//! Runs a shell over a pair of pipes and draws what it prints. There is no
//! pseudo-terminal: a pty is a pipe plus a line discipline plus a way to
//! signal a resize, and of those only the pipe belongs in the kernel. The line
//! discipline is here, where a terminal's own idea of what a line is belongs,
//! and a full-window program turns it off by switching to the alternate
//! screen, which is the first thing every such program does.
//!
//! One blocking call covers both sides. The shell's output and the window's
//! events are each an event handle, and `wait_many` takes both, so a terminal
//! sitting idle costs nothing.

const abi = @import("lib").syscalls;
const eui = @import("eui");
const keys = @import("keys.zig");
const proto = @import("proto");
const render = @import("render.zig");
const sys = @import("sys");
const out = @import("ulib").out;
const vt = @import("vt.zig");

const Rect = eui.Rect;

const SHELL = "/bin/vsh";

/// 15 percent, which is enough to see through and not enough to read through.
const TRANSPARENCY: u8 = 38;

var connection: proto.Connection = undefined;
var window: u8 = 0;

/// Undefined at load and brought up by `init` below: a global with a
/// written-out initial value is carried in the executable, and these two are a
/// hundred and fifty kilobytes of blank cells.
var terminal: vt.Terminal = undefined;
var shadow: render.Shadow = undefined;

/// The shell's end of each pipe, kept so they can be closed once it has them.
var to_shell: u32 = 0;
var from_shell: u32 = 0;
var shell_pid: u32 = 0;
var running = false;

/// What has been typed since the last Enter, echoed but not yet sent.
///
/// Only used in cooked mode. A line held here is one the shell has not seen,
/// which is what makes backspace possible at all: once a byte is in the pipe
/// there is no taking it back.
var line: [512]u8 = @splat(0);
var line_len: usize = 0;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ call etermMain
        \\ hlt
    );
}

export fn etermMain() callconv(.c) noreturn {
    terminal.init();
    shadow.invalidate();

    connection = proto.client.Connection.open("eterm") catch {
        out.text("eterm: no window manager is running\n");
        out.flush();
        sys.exit(1);
    };

    // Slightly translucent, so what is behind a terminal is still legible
    // through it. The one window that wants it: everything else is a document
    // or a control panel, where anything showing through is noise.
    window = connection.createTranslucent(.{}, 480, 320, TRANSPARENCY) catch sys.exit(1);
    connection.setTitle(window, "eTerm") catch {};

    startShell();
    run();
}

// ---------------------------------------------------------------------------
// The shell
// ---------------------------------------------------------------------------

fn startShell() void {
    const input = sys.pipe() orelse {
        show("eterm: cannot create a pipe\r\n");
        return;
    };
    const output = sys.pipe() orelse {
        _ = sys.close(input.read);
        _ = sys.close(input.write);
        show("eterm: cannot create a pipe\r\n");
        return;
    };

    to_shell = input.write;
    from_shell = output.read;

    const pid = sys.spawnStreams(SHELL, &.{"vsh"}, .{
        .flags = @bitCast(abi.SpawnFlags{ .detached = true }),
        .stdin = @intCast(input.read),
        .stdout = @intCast(output.write),
        .stderr = @intCast(output.write),
    });

    // The child has its own references now. Keeping these would mean the pipe
    // never reports end of file, because this process would still be counted
    // as a writer of the shell's output.
    _ = sys.close(input.read);
    _ = sys.close(output.write);

    if (pid < 0) {
        show("eterm: cannot start ");
        show(SHELL);
        show("\r\n");
        return;
    }

    shell_pid = @intCast(pid);
    running = true;
}

/// Text from the terminal itself, as though the shell had printed it.
fn show(text: []const u8) void {
    terminal.write(text);
}

fn toShell(bytes: []const u8) void {
    if (!running or bytes.len == 0) return;
    if (sys.write(to_shell, bytes) < 0) running = false;
}

/// Whether the terminal is assembling lines rather than passing keys straight
/// through.
///
/// Off on the alternate screen, which is what a full-window program switches
/// to. That is the signal rather than a mode of our own because it needs no
/// cooperation: every program that wants raw keys already sends it.
fn cooked() bool {
    return !terminal.on_alternate;
}

// ---------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------

fn run() noreturn {
    while (true) {
        // Both sides in one wait. The window's event ring and the shell's
        // output are each an event handle, so an idle terminal is a blocked
        // thread rather than a poll.
        var sources: [2]u32 = .{ connection.event_signal, from_shell };
        const count: usize = if (running) 2 else 1;
        _ = sys.waitMany(sources[0..count], 500_000);

        drain();
        while (connection.poll()) |event| handle(event);
        redraw();
    }
}

/// Whether the shell has written something, or has finished.
///
/// Asked before every read because a read of a pipe blocks: draining until it
/// came back empty would mean never returning to the window's events, and a
/// terminal that cannot be typed into.
fn readable() bool {
    var one: [1]u32 = .{from_shell};
    return sys.waitMany(&one, sys.POLL) >= 0;
}

var chunk: [1024]u8 = @splat(0);

fn drain() void {
    if (!running) return;

    // Bounded rather than until empty: a program printing without pause would
    // otherwise keep this loop from ever drawing what it had already read.
    var rounds: usize = 0;
    while (rounds < 8) : (rounds += 1) {
        if (!readable()) return;

        const n = sys.read(from_shell, &chunk);
        if (n <= 0) {
            if (n == 0) shellExited();
            return;
        }

        terminal.write(chunk[0..@intCast(n)]);
        const answer = terminal.takeReply();
        if (answer.len > 0) toShell(answer);
    }
}

fn shellExited() void {
    running = false;
    _ = sys.close(from_shell);
    _ = sys.close(to_shell);
    show("\r\n[the shell exited]\r\n");
}

fn handle(event: proto.wm.Ev) void {
    switch (event.tag) {
        .configure => resize(event.body.configure.w, event.body.configure.h),
        .key => {
            if (event.body.key.down == 0) return;
            var buf: [keys.MAX]u8 = undefined;
            const code: abi.KeyCode = @enumFromInt(event.body.key.code);
            const mods: abi.Modifiers = @bitCast(event.body.key.mods);
            send(keys.key(code, mods, terminal.application_cursor, &buf), code, mods);
        },
        .text => {
            var buf: [keys.MAX]u8 = undefined;
            // A text event carries no modifier state of its own, so control
            // chords are recognised from the key event above and this path
            // handles what the layout produced.
            send(keys.text(event.body.text.cp, .{}, &buf), .none, .{});
        },
        .theme => {
            proto.client.applyTheme(&event.body.theme.name);
            shadow.invalidate();
        },
        .close_req => sys.exit(0),
        .overflow => shadow.invalidate(),
        else => {},
    }
}

/// Send what a key produced, through the line discipline when there is one.
fn send(bytes: []const u8, code: abi.KeyCode, mods: abi.Modifiers) void {
    if (bytes.len == 0) return;

    if (!cooked()) {
        toShell(bytes);
        return;
    }

    for (bytes) |byte| {
        switch (byte) {
            '\r' => {
                // The shell reads lines, so it gets one: everything typed plus
                // the newline it is waiting for.
                echo("\r\n");
                if (line_len < line.len) {
                    line[line_len] = '\n';
                    line_len += 1;
                }
                toShell(line[0..line_len]);
                line_len = 0;
            },
            0x7F, 0x08 => {
                if (line_len > 0) {
                    line_len -= 1;
                    // Back over the character, blank it, back again: the only
                    // way to erase with nothing but a cursor and a space.
                    echo("\x08 \x08");
                }
            },
            // Ctrl+C abandons the line. There are no signals to interrupt the
            // shell with, so the most this can do is discard what was typed,
            // and saying so beats a prompt that silently forgot.
            0x03 => {
                echo("^C\r\n");
                line_len = 0;
                toShell("\n");
            },
            0x15 => {
                while (line_len > 0) {
                    line_len -= 1;
                    echo("\x08 \x08");
                }
            },
            else => {
                if (byte < 0x20 and byte != '\t') continue;
                if (line_len < line.len) {
                    line[line_len] = byte;
                    line_len += 1;
                    echo(bytes[0..1]);
                }
            },
        }
    }

    _ = code;
    _ = mods;
}

/// Show what was typed. The shell cannot: it has not been given the line yet.
fn echo(text: []const u8) void {
    terminal.write(text);
}

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

fn resize(w: u16, h: u16) void {
    connection.attach(window, w, h) catch return;

    const cols = @divTrunc(@as(i32, w), render.cellWidth());
    const rows = @divTrunc(@as(i32, h), render.cellHeight());
    terminal.resize(@intCast(@max(cols, 1)), @intCast(@max(rows, 1)));
    shadow.invalidate();

    redraw();
    connection.map(window) catch {};
}

fn redraw() void {
    const surface = connection.surfaceOf(window) orelse return;
    const t = eui.theme.current();

    if (terminal.title_changed) {
        connection.setTitle(window, terminal.title[0..terminal.title_len]) catch {};
        terminal.title_changed = false;
    }

    const area = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };
    const grid = terminal.active();

    // The strip below and right of the last whole cell. Painted once per
    // resize rather than per pass, since nothing ever draws there.
    const used_w = @as(i32, @intCast(grid.cols)) * render.cellWidth();
    const used_h = @as(i32, @intCast(grid.rows)) * render.cellHeight();
    if (used_w < area.w) {
        surface.fill(.{ .x = used_w, .y = 0, .w = area.w - used_w, .h = area.h }, t.surface);
    }
    if (used_h < area.h) {
        surface.fill(.{ .x = 0, .y = used_h, .w = area.w, .h = area.h - used_h }, t.surface);
    }

    const damage = render.paint(surface.*, area, &terminal, &shadow) orelse return;
    terminal.dirty = false;

    connection.commit(window, &.{damage}) catch {};
}
