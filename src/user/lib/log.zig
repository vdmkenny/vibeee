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
const style = @import("lib").style;
const syscalls = @import("lib").syscalls;

/// The kernel's column, so a service's lines and the kernel's line up.
pub const KEY_WIDTH = 8;

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
    out.byte('\n');
    out.flush();
}
