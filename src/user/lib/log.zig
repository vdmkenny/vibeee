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
const out = @import("out.zig");
const str = @import("lib").str;
const style = @import("lib").style;
const sys = @import("sys");
const syscalls = @import("lib").syscalls;

/// The kernel's column, so a service's lines and the kernel's line up.
pub const KEY_WIDTH = 8;

/// How much a line is worth showing. Severity is the colour; this is the
/// other axis, whether the line is for a person following the boot or for a
/// person chasing a fault.
pub const Level = enum { detail, info };

/// The threshold comes from the kernel, once: `verbose` on the command line
/// decides for the whole boot, services included.
var shown: ?Level = null;

fn threshold() Level {
    if (shown) |level| return level;

    var buf: [8]u8 = undefined;
    const n = sys.sysinfo("log", &buf);
    const level: Level = if (n > 0 and str.eql(buf[0..@intCast(n)], "detail")) .detail else .info;
    shown = level;
    return level;
}

/// Whether the line being started is kept. Dim lines are detail: present for
/// the person chasing a fault, absent for the person using the machine.
fn levelOf(role: style.Role) Level {
    return if (role == .dim) .detail else .info;
}

var muted = false;
var muted_from: usize = 0;

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
pub fn begin(key: []const u8, role: style.Role) void {
    if (@intFromEnum(levelOf(role)) < @intFromEnum(threshold())) {
        // Built and then taken back rather than suppressed at each caller:
        // the pieces between `begin` and `end` are ordinary writes, and this
        // is the one place that sees the whole line.
        muted = true;
        muted_from = out.stream().mark();
    }

    ink.use(role);
    out.text(key);
    ink.plain();

    // At least one space, so a label as wide as the column does not run into
    // what it introduces.
    var n = key.len;
    while (n < KEY_WIDTH) : (n += 1) out.byte(' ');
    if (key.len >= KEY_WIDTH) out.byte(' ');
}

pub fn end() void {
    if (muted) {
        muted = false;
        out.stream().rewind(muted_from);
        return;
    }
    out.byte('\n');
    out.flush();
}
