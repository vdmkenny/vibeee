//! A line of service output, in the shape the boot log uses.
//!
//! The kernel writes a coloured label column and then what happened. A service
//! that writes `name: something` instead reads as a different program's output
//! spliced into the middle of the log, which is exactly what it is and exactly
//! what it should not look like: the reader is following one boot.
//!
//! So the same column and the same colours, and the label is what the line is
//! about rather than how bad it is. Severity is the colour, which is what the
//! kernel does with its own.

const ink = @import("ink.zig");
const info = @import("info.zig");
const out = @import("out.zig");
const style = @import("lib").style;
const sys = @import("sys");
const syscalls = @import("lib").syscalls;

/// The kernel's column, so a service's lines and the kernel's line up.
pub const KEY_WIDTH = 8;

/// Who a line is for, which decides both whether it is shown and whether it
/// is kept.
///
/// `always` is a failure or a warning: worth a quiet boot's screen. `info`
/// is the boot's narration, one line per thing as it comes up: shown with
/// `verbose`, kept in the kernel log either way. `debug` is the tier beneath
/// it for chasing a fault: shown and kept only when `debug` was asked for,
/// which makes it the one level that costs nothing when it is off.
pub const Gate = enum { always, info, debug };

fn gateOf(role: style.Role) Gate {
    return switch (role) {
        .bad, .warn => .always,
        .dim => .debug,
        else => .info,
    };
}

/// The gates come from the kernel, once: `verbose` and `debug` on the command
/// line decide for the whole boot, services included, and the log tool reads
/// the ring they were kept in.
var known = false;
var show_info = false;
var show_debug = false;

fn gates() void {
    if (known) return;
    known = true;
    show_info = info.askNumber("log.verbose") != 0;
    show_debug = info.askNumber("log.debug") != 0;
}

fn shown(gate: Gate) bool {
    gates();
    return switch (gate) {
        .always => true,
        .info => show_info,
        .debug => show_debug,
    };
}

/// The whole of a line that is one piece of text.
pub fn say(key: []const u8, role: style.Role, message: []const u8) void {
    begin(key, role);
    out.text(message);
    end();
}

/// It worked, and the line says what it now is.
pub fn note(key: []const u8, message: []const u8) void {
    say(key, .key, message);
}

/// Worth looking at, and the service carried on.
pub fn warn(key: []const u8, message: []const u8) void {
    say(key, .warn, message);
}

/// It did not work.
pub fn fail(key: []const u8, message: []const u8) void {
    say(key, .bad, message);
}

/// The same, naming what the kernel said instead of guessing at it.
///
/// A service that reports "cannot register" has said the one thing the reader
/// already knew. The errno is the whole of the news.
pub fn failed(key: []const u8, message: []const u8, result: isize) void {
    begin(key, .bad);
    out.text(message);

    if (syscalls.Errno.of(result)) |errno| {
        out.text(": ");
        out.text(errno.reason());
    }
    end();
}

/// Start a line whose message is built from several pieces. What follows is
/// written with `out` until `end`.
///
/// Nothing that can log may run while a line is open: the pieces share one
/// stream, and a logger called mid-line flushes the half-built line inside
/// its own. Gather answers first, then say them.
///
/// The kernel's own log ring gets every line too, so the log tool can show a
/// quiet boot in full. `debug` lines are the exception, on both counts: with
/// `debug` off they are neither shown nor kept.
pub fn begin(key: []const u8, role: style.Role) void {
    tee_key = key;
    line_gate = gateOf(role);

    // Built and then taken back rather than suppressed at each caller: the
    // pieces between `begin` and `end` are ordinary writes, and this is the
    // one place that sees the whole line.
    if (!shown(line_gate)) {
        muted = true;
        muted_from = out.stream().mark();
    }

    ink.use(role);
    out.text(key);
    ink.plain();

    // The mark sits inside the line and after the colour codes: what is teed
    // into the kernel's ring is the plain text of the whole line, the column
    // padding included, and not the escapes that painted it.
    tee_from = out.stream().mark();

    // At least one space, so a label as wide as the column does not run into
    // what it introduces.
    var n = key.len;
    while (n < KEY_WIDTH) : (n += 1) out.byte(' ');
    if (key.len >= KEY_WIDTH) out.byte(' ');
}

/// How much of a line the kernel keeps: it is the same ceiling the kernel
/// puts on the syscall, and a line that runs over is kept in the ring cut to
/// it rather than dropped.
const TEE_MAX = 256;

var tee_key: []const u8 = "";
var tee_from: usize = 0;
var line_gate: Gate = .info;
var muted = false;
var muted_from: usize = 0;

/// Send the completed line into the kernel's log ring.
///
/// Skipped for a muted `debug` line: unasked-for detail is the one thing a
/// ring does not need. Everything else is kept whether or not it was shown.
fn tee() void {
    if (muted and line_gate == .debug) return;

    var line: [TEE_MAX]u8 = undefined;
    var n: usize = 0;
    const segment = out.stream().since(tee_from);

    n = @min(tee_key.len, line.len);
    @memcpy(line[0..n], tee_key[0..n]);
    const room = line.len -| n;
    const take = @min(segment.len, room);
    @memcpy(line[n..][0..take], segment[0..take]);
    n += take;

    _ = sys.log(line[0..n]);
}

pub fn end() void {
    if (muted) {
        // Tee before the flag comes down: the keeper's rule is about what the
        // line was, which at this moment is still "decided against".
        tee();
        out.stream().rewind(muted_from);
        muted = false;
        return;
    }
    tee();
    out.byte('\n');
    out.flush();
}
