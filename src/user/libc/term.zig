//! termios and the two ioctls a full-screen program needs.
//!
//! What an editor wants from a terminal is two things: keystrokes as they
//! happen rather than a line at a time, and the size of the screen. This is
//! those two, in the shape POSIX asks for them.
//!
//! The `termios` struct carries every field C code expects to find, and the
//! two flags that mean something here are honoured. The rest are kept as
//! written and handed back unchanged, so a program that saves the old settings
//! and restores them gets back exactly what it had.

const errno = @import("errno.zig");
const info = @import("ulib").info;
const str = @import("lib").str;
const sys = @import("sys");

pub const NCCS = 32;

pub const Termios = extern struct {
    c_iflag: c_uint = 0,
    c_oflag: c_uint = 0,
    c_cflag: c_uint = 0,
    c_lflag: c_uint = 0,
    c_line: u8 = 0,
    c_cc: [NCCS]u8 = @splat(0),
    c_ispeed: c_uint = 0,
    c_ospeed: c_uint = 0,
};

/// The two `c_lflag` bits that decide anything. Together they are the whole
/// difference between cooked and raw: a line discipline that assembles lines
/// and echoes them, or one that does neither.
pub const ICANON: c_uint = 0x0002;
pub const ECHO: c_uint = 0x0008;

/// Accepted and kept so a save-and-restore round trip is exact, but nothing
/// here reads them: this terminal does not translate, flow-control or map
/// anything on the way through.
pub const ISIG: c_uint = 0x0001;
pub const IXON: c_uint = 0x0400;
pub const ICRNL: c_uint = 0x0100;
pub const OPOST: c_uint = 0x0001;
pub const CS8: c_uint = 0x0030;
pub const IEXTEN: c_uint = 0x8000;
pub const BRKINT: c_uint = 0x0002;
pub const INPCK: c_uint = 0x0010;
pub const ISTRIP: c_uint = 0x0020;

pub const VMIN = 6;
pub const VTIME = 5;

pub const TCSANOW = 0;
pub const TCSADRAIN = 1;
pub const TCSAFLUSH = 2;

/// What was last set, so `tcgetattr` gives back what `tcsetattr` was given
/// rather than a fresh struct with the fields nobody here reads zeroed.
var current = Termios{
    .c_iflag = BRKINT | ICRNL | INPCK | ISTRIP | IXON,
    .c_oflag = OPOST,
    .c_cflag = CS8,
    .c_lflag = ICANON | ECHO | ISIG | IEXTEN,
};

export fn tcgetattr(fd: c_int, out: *Termios) callconv(.c) c_int {
    if (fd < 0) return @intCast(errno.fail(errno.EBADF));
    out.* = current;
    return 0;
}

export fn tcsetattr(fd: c_int, when: c_int, wanted: *const Termios) callconv(.c) c_int {
    _ = when; // Nothing is buffered on the way out, so there is nothing to drain.
    if (fd < 0) return @intCast(errno.fail(errno.EBADF));

    current = wanted.*;

    // Raw is the absence of both: a program that turned off line assembly but
    // left echo on would get characters as they arrive and a second copy of
    // each drawn by the terminal underneath whatever it is drawing itself.
    const cooked = current.c_lflag & (ICANON | ECHO) == (ICANON | ECHO);
    _ = sys.ttyMode(if (cooked) .cooked else .raw);
    return 0;
}

pub const TIOCGWINSZ = 0x5413;
pub const FIONREAD = 0x541B;

pub const Winsize = extern struct {
    ws_row: c_ushort = 0,
    ws_col: c_ushort = 0,
    ws_xpixel: c_ushort = 0,
    ws_ypixel: c_ushort = 0,
};

/// The whitelist, and it is short on purpose. `ioctl` is where a C library
/// becomes a grab bag; the two here are the ones a full-screen program cannot
/// do without, and anything else says so rather than returning a zero that
/// reads as success.
export fn ioctl(fd: c_int, request: c_ulong, ...) callconv(.c) c_int {
    _ = fd;

    var args = @cVaStart();
    defer @cVaEnd(&args);

    return switch (request) {
        TIOCGWINSZ => size(@cVaArg(&args, *Winsize)),
        else => @intCast(errno.fail(errno.ENOTTY)),
    };
}

/// The console's shape, asked of the console rather than guessed. A program
/// that got 80x24 on a 100x30 screen would draw a box in the wrong place and
/// have no way to find out.
fn size(out: *Winsize) c_int {
    var buf: [64]u8 = @splat(0);
    var it = str.split(info.ask("console", &buf), 'x');

    const columns = str.toUnsigned(it.next() orelse "");
    const rows = str.toUnsigned(it.next() orelse "");
    if (columns == 0 or rows == 0) return @intCast(errno.fail(errno.ENOTTY));

    out.* = .{ .ws_col = @intCast(columns), .ws_row = @intCast(rows) };
    return 0;
}
