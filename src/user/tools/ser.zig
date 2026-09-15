//! ser: the serial ports, and a terminal on one.
//!
//! A serial line tells you nothing about itself: both ends have to have
//! been told the same rate and the same character, and when they have not
//! the result is not silence but rubbish. So the listing says what each
//! port is set to, setting it is one argument, and the terminal says what
//! it opened with before the first byte arrives.

const ink = @import("ulib").ink;
const lib = @import("lib");
const out = @import("ulib").out;
const serial = @import("ulib").serial;
const std = @import("std");
const str = @import("ulib").str;
const sys = @import("sys");

const NAME = 7;
const ID = 11;
const LINE = 13;
const HELD = 8;

/// The key that leaves a terminal. A plain key rather than a chord,
/// because every chord worth having is a byte the far end wants: a serial
/// console is exactly the place somebody needs to send Ctrl+C.
const LEAVE = sys.KeyCode.f10;

/// How long `break` holds the line, which is long enough for the far end
/// to see it and short enough that nobody has to end it.
const BREAK_MS: u16 = 250;

pub fn run(args: []const []const u8) void {
    if (args.len == 0) return list();

    const index = serial.named(args[0]) catch {
        out.text("ser: no port called ");
        out.text(args[0]);
        out.byte('\n');
        out.flush();
        return;
    };
    const rest = args[1..];

    if (rest.len != 0 and std.mem.eql(u8, rest[0], "break")) return hold(index);
    const quietly = rest.len != 0 and std.mem.eql(u8, rest[0], "set");
    const wanted = if (quietly) rest[1..] else rest;

    var port = serial.Port.open(index) catch |err| return sayOpenFailure(err);
    defer port.close();

    if (wanted.len != 0) {
        const line = lineOf(wanted) orelse {
            out.text("ser: a line reads as a rate and a character, like 115200 8N1\n");
            out.flush();
            return;
        };
        port.set(line, serial.PRESENT) catch {
            out.text("ser: the device would not take that line\n");
            out.flush();
            return;
        };
    }
    if (quietly) return sayLine(&port);

    terminal(&port);
}

/// A rate and, where one was given, a character.
fn lineOf(args: []const []const u8) ?serial.Line {
    const rate = str.unsigned(args[0]) orelse return null;
    if (rate == 0 or rate > std.math.maxInt(u32)) return null;
    const shape = if (args.len > 1) args[1] else "8N1";
    return serial.Line.of(@intCast(rate), shape);
}

// ---------------------------------------------------------------------------
// The listing
// ---------------------------------------------------------------------------

fn list() void {
    const total = serial.count() catch {
        out.text("ser: the serial service is not answering\n");
        out.flush();
        return;
    };
    if (total == 0) {
        out.text("no serial ports\n");
        out.flush();
        return;
    }

    ink.use(.dim);
    out.pad("port", NAME);
    out.pad("id", ID);
    out.pad("line", LINE);
    out.pad("holding", HELD);
    out.text("state\n");
    ink.plain();

    var index: u32 = 0;
    while (true) : (index += 1) {
        const info = serial.at(index) catch break;
        // A sparse table: a row nothing occupies is one to skip.
        if (info.name_len == 0) continue;
        describe(info);
    }
    out.flush();
}

fn describe(info: serial.Info) void {
    var buf: [32]u8 = undefined;

    out.pad(info.nameSlice(), NAME);

    var id = str.Builder{ .buf = &buf };
    id.hex(info.vendor, 4);
    id.byte(':');
    id.hex(info.product, 4);
    ink.use(.dim);
    out.pad(id.done(), ID);
    ink.plain();

    out.pad(info.line.spell(&buf), LINE);
    var lines: [16]u8 = undefined;
    out.pad(lib.serial.spellHeld(info.held, &lines), HELD);

    if (info.taken != 0) {
        out.text("in use");
    } else if (info.reports == 0) {
        ink.write(.dim, "says nothing");
    } else {
        out.text(info.state.spell(&buf));
    }
    out.byte('\n');
}

fn sayLine(port: *serial.Port) void {
    var buf: [32]u8 = undefined;
    out.text(port.info.nameSlice());
    out.text(": ");
    out.text(port.info.line.spell(&buf));
    out.byte('\n');
    out.flush();
}

fn hold(index: u32) void {
    var port = serial.Port.open(index) catch |err| return sayOpenFailure(err);
    defer port.close();

    port.breaking(BREAK_MS) catch {
        out.text("ser: the device will not hold the line at break\n");
        out.flush();
        return;
    };
    out.text("held at break\n");
    out.flush();
}

fn sayOpenFailure(err: serial.Error) void {
    out.text(switch (err) {
        error.NoService => "ser: the serial service is not answering\n",
        error.End => "ser: there is no such port\n",
        error.Taken => "ser: another program has that port\n",
        error.Refused => "ser: the port would not open\n",
    });
    out.flush();
}

// ---------------------------------------------------------------------------
// The terminal
// ---------------------------------------------------------------------------

/// Bytes both ways until the key that leaves, or until the port goes.
///
/// A character at a time rather than a line at a time, because the far
/// end is a machine that may well be waiting on a single keystroke, and
/// because it is the far end that decides whether what was typed comes
/// back to be shown.
fn terminal(port: *serial.Port) void {
    const keys = sys.watch(.keys) catch {
        out.text("ser: no keyboard to read\n");
        out.flush();
        return;
    };

    // The first read claims the keyboard: from here every key comes to
    // this process rather than feeding the shell underneath.
    var events: [8]sys.KeyEvent = undefined;
    if (sys.keyRead(&events, sys.POLL) == null) {
        out.text("ser: another program is holding the keyboard\n");
        out.flush();
        return;
    }

    var buf: [32]u8 = undefined;
    ink.use(.dim);
    out.text(port.info.nameSlice());
    out.text(" at ");
    out.text(port.info.line.spell(&buf));
    out.text(", F10 leaves\n");
    ink.plain();
    out.flush();

    while (true) {
        // Whatever is already there before waiting: the port may have
        // answered while the last keystroke was being sent.
        pour(port);
        if (port.ended()) break;

        var sources: [2]u32 = .{ port.waitHandle(), @intCast(keys) };
        const woke = sys.waitMany(&sources, sys.FOREVER) catch continue;
        if (woke != 1) continue;

        for (sys.keyRead(&events, sys.POLL) orelse break) |event| {
            if (!event.pressed) continue;
            if (event.code == LEAVE) {
                out.byte('\n');
                out.flush();
                return;
            }
            typed(port, event);
        }
    }

    ink.use(.dim);
    out.text("\nthe port is gone\n");
    ink.plain();
    out.flush();
}

/// One keystroke onto the wire. What is sent is what was typed: the far
/// end decides what a carriage return means and whether it comes back.
fn typed(port: *serial.Port, event: sys.KeyEvent) void {
    if (event.code == .enter) return sendAll(port, "\r");
    if (event.code == .backspace) return sendAll(port, "\x7F");
    if (event.codepoint == 0) return;

    var utf8: [4]u8 = undefined;
    const cp: u21 = @intCast(event.codepoint & 0x1F_FFFF);
    const n = std.unicode.utf8Encode(cp, &utf8) catch return;
    sendAll(port, utf8[0..n]);
}

/// Everything, however full the ring is: a keystroke that went nowhere is
/// worse than a moment's wait, and the wait is on the port rather than on
/// the clock.
fn sendAll(port: *serial.Port, bytes: []const u8) void {
    var sent: u32 = 0;
    while (sent < bytes.len) {
        sent += port.write(bytes[sent..]);
        if (sent >= bytes.len) return;
        if (port.ended()) return;
        _ = sys.waitMany(&[_]u32{port.waitHandle()}, sys.FOREVER) catch return;
    }
}

/// Whatever arrived, onto the screen.
fn pour(port: *serial.Port) void {
    var buf: [256]u8 = undefined;
    var wrote = false;
    while (true) {
        const got = port.read(&buf);
        if (got == 0) break;
        out.text(buf[0..got]);
        wrote = true;
    }
    // Said out of band, because the one place it cannot be said is among
    // the bytes that had nowhere to go.
    if (port.lost()) {
        ink.write(.dim, "\n[bytes lost]\n");
        wrote = true;
    }
    if (wrote) out.flush();
}
