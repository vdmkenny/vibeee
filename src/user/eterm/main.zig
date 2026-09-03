//! eTerm: a terminal window.
//!
//! Runs a shell over a pair of pipes and draws what it prints. There is no
//! pseudo-terminal: a pty is a pipe plus a line discipline plus a way to
//! signal a resize, and of those only the pipe belongs in the kernel. The line
//! discipline is here, where a terminal's own idea of what a line is belongs.
//! A program that manages its own input turns it off: a full-window one by
//! switching to the alternate screen, a shell's line editor by sending the
//! private mode that means so. What the window's size is, and that it changed,
//! a program learns the same in-band way it learns anything from a terminal.
//!
//! One blocking call covers both sides. The shell's output and the window's
//! events are each an event handle, and `wait_many` takes both, so a terminal
//! sitting idle costs nothing. It reads the shell only when that wait wakes for
//! it: the readable event is a count the wait consumes, so a poll after it
//! answers no while the bytes wait in the pipe.

const abi = @import("lib").syscalls;
const eui = @import("eui");
const keys = @import("ulib").keys;
const proto = @import("proto");
const render = @import("render.zig");
const std = @import("std");
const sys = @import("sys");
const out = @import("ulib").out;
const vt = @import("vt.zig");

const Rect = eui.Rect;

const SHELL = "/bin/vsh";

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

export fn _start() callconv(.c) noreturn {
    etermMain();
}

fn etermMain() noreturn {
    terminal.init();
    shadow.invalidate();

    connection = proto.client.Connection.open("eterm") catch {
        out.text("eterm: no window manager is running\n");
        out.flush();
        sys.exit(1);
    };

    window = connection.createWindow(.{}, 480, 320) catch sys.exit(1);
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

/// Keys typed faster than the shell is reading them.
///
/// A pipe write blocks when the pipe is full, and the shell only reads its
/// input at a prompt: while it is printing, its input pipe fills and stays
/// full. A terminal that blocked there would be waiting for a shell that was
/// itself waiting for the terminal to drain its output, which is two
/// processes holding each other still. So nothing is ever written unless the
/// pipe says it has room, and what does not fit waits here.
var pending: [1024]u8 = @splat(0);
var pending_len: usize = 0;

fn toShell(bytes: []const u8) void {
    if (!running or bytes.len == 0) return;

    const room = pending.len - pending_len;
    const n = @min(bytes.len, room);
    @memcpy(pending[pending_len..][0..n], bytes[0..n]);
    pending_len += n;
    // Past a kilobyte of unread typing the oldest is dropped rather than the
    // newest: what somebody is typing now is what they meant.
    if (n < bytes.len) pending_len = pending.len;

    flushToShell();
}

/// Whether the shell's input pipe has room. Asked rather than assumed,
/// because the answer is the difference between a write and a wait.
fn writable() bool {
    var one: [1]u32 = .{to_shell};
    return sys.waitMany(&one, sys.POLL) >= 0;
}

/// Push what is queued, as far as the pipe will take it.
fn flushToShell() void {
    while (running and pending_len > 0) {
        if (!writable()) return;

        const wrote = sys.write(to_shell, pending[0..pending_len]);
        if (wrote < 0) {
            running = false;
            return;
        }

        const n: usize = @intCast(wrote);
        if (n == 0) return;
        if (n < pending_len) {
            std.mem.copyForwards(u8, pending[0 .. pending_len - n], pending[n..pending_len]);
        }
        pending_len -= n;
    }
}

/// Whether the terminal is assembling lines rather than passing keys straight
/// through.
///
/// Off on the alternate screen, which is what a full-window program switches
/// to, and off when a program says it manages its own input line. Both are the
/// program's own signal rather than a mode of the terminal's, so nothing here
/// has to guess which program wants which: a full-window one switches screens,
/// a shell's editor sends the private mode, and a plain reader that does
/// neither gets the line discipline this terminal keeps for it.
fn cooked() bool {
    return !terminal.on_alternate and !terminal.app_line_edit;
}

// ---------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------

/// Where the shell's output sits in the wait, so a wake can be known for it.
const SHELL_OUTPUT = 1;

fn run() noreturn {
    while (true) {
        // Both sides in one wait. The window's event ring and the shell's
        // output are each an event handle, so an idle terminal is a blocked
        // thread rather than a poll.
        var sources: [3]u32 = .{ connection.event_signal, from_shell, to_shell };
        // The third source only while something is queued: the write end is
        // ready whenever the pipe has room, which is almost always, and
        // waiting on it with nothing to send would be a loop that never
        // sleeps.
        const count: usize = if (!running) 1 else if (pending_len > 0) 3 else 2;
        const woke = sys.waitMany(sources[0..count], 500_000);

        // Read the shell's output only when it is what woke us. The wake is
        // the proof there is something there, and it is the only proof: the
        // event that carried it is a count the wait has already taken, so
        // asking it again answers no while the bytes sit in the pipe. The
        // pipe re-signals itself while any remain, so what one wake leaves the
        // next one brings.
        if (woke == SHELL_OUTPUT) drain();
        while (connection.poll()) |event| handle(event);
        // Anything the shell would not take earlier goes now, if it will.
        flushToShell();
        redraw();
    }
}

/// Whether the shell has more waiting after a read, without blocking on a pipe
/// that has run dry.
///
/// Sound only mid-drain, where every read that left something behind has
/// re-signalled the pipe: the count it polls was last set by the pipe itself,
/// not spent by the wait that began the drain.
fn moreToRead() bool {
    var one: [1]u32 = .{from_shell};
    return sys.waitMany(&one, sys.POLL) >= 0;
}

var chunk: [1024]u8 = @splat(0);

fn drain() void {
    if (!running) return;

    // Bounded rather than until empty: a program printing without pause would
    // otherwise keep this loop from ever drawing what it had already read.
    //
    // The first read needs no check: this is only reached because the shell's
    // output is what woke the loop, so there is something there.
    var rounds: usize = 0;
    while (rounds < 8) : (rounds += 1) {
        if (rounds > 0 and !moreToRead()) return;

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

/// The shell is what the window is for: when it goes, so does the window,
/// the way a terminal has always closed on its shell's last word.
fn shellExited() void {
    running = false;
    _ = sys.close(from_shell);
    _ = sys.close(to_shell);
    sys.exit(0);
}

fn handle(event: proto.wm.Ev) void {
    switch (event.tag) {
        .configure => resize(event.body.configure.w, event.body.configure.h),
        .key => {
            if (event.body.key.down == 0) return;
            var buf: [keys.MAX]u8 = undefined;
            const code: abi.KeyCode = @enumFromInt(event.body.key.code);
            const mods: abi.Modifiers = @bitCast(event.body.key.mods);

            // Which key it was first: an arrow, a function key or Enter is
            // named by the key rather than by what the layout puts on it.
            const named = keys.key(code, mods, terminal.application_cursor, &buf);
            if (named.len > 0) return send(named, code, mods);

            // Otherwise what the layout made of it, chords included: a
            // terminal is where Ctrl+C is a character, and it is the key
            // printed C whatever the layout puts there.
            send(keys.text(event.body.key.codepoint, mods, &buf), code, mods);
        },
        .theme, .look => {
            _ = connection.adoptLook(event);
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

    // A full-screen program lays itself out to a size only this terminal
    // knows, so a window that changes size has to say so. It goes to the
    // program's input the way its keys do, and only to one that took the
    // alternate screen: a shell reading a line would choke on a report it
    // never asked for.
    if (terminal.on_alternate) {
        var buf: [vt.MAX_REPLY]u8 = undefined;
        toShell(terminal.sizeReport(&buf));
    }

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
        surface.fill(.{ .x = used_w, .y = 0, .w = area.w - used_w, .h = area.h }, t.terminal_ground);
    }
    if (used_h < area.h) {
        surface.fill(.{ .x = 0, .y = used_h, .w = area.w, .h = area.h - used_h }, t.terminal_ground);
    }

    const damage = render.paint(surface.*, area, &terminal, &shadow) orelse return;
    terminal.dirty = false;
    connection.commit(window, &.{damage}) catch {};
}
