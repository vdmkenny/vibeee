//! The console, as a program needs to know it.
//!
//! Its shape, which decides how much fits on a screen and therefore how any
//! full-screen program lays itself out. In `ulib` because three separate
//! places were asking the same question and parsing the same answer, and
//! because a program written in Zig should reach it the same way a program
//! written in C reaches it through `ioctl`.

const info = @import("info.zig");
const sys = @import("sys");
const out = @import("out.zig");
const std = @import("std");
const str = @import("lib").str;

pub const Size = struct {
    columns: usize,
    rows: usize,

    /// What to assume when nothing answers. The smallest terminal anybody has
    /// ever standardised on, so a layout built against it fits anywhere.
    pub const fallback = Size{ .columns = 80, .rows = 24 };
};

/// Take the whole screen, putting aside what was on it.
///
/// What a full-screen program does on the way in, so that what it draws over
/// is a blank screen rather than the shell's scrollback, and so that leaving
/// puts the scrollback back exactly as it was.
pub fn takeScreen() void {
    out.text("\x1b[?1049h");
    out.flush();
}

/// Give it back, and with it everything that was on it.
pub fn giveBackScreen() void {
    out.text("\x1b[?1049l");
    out.flush();
}

/// How many cells the console has. Asked of the console rather than assumed:
/// a program that drew an 80x24 box on a 100x30 screen would leave a border of
/// stale pixels and have no way to find out.
pub fn size() Size {
    var buf: [64]u8 = @splat(0);
    var it = str.split(info.ask("console", &buf), 'x');

    const columns = str.toUnsigned(it.next() orelse "");
    const rows = str.toUnsigned(it.next() orelse "");
    if (columns == 0 or rows == 0) return Size.fallback;

    return .{ .columns = columns, .rows = rows };
}

/// How big the terminal on the other end of the standard streams is, asked of
/// it rather than of the kernel.
///
/// The size the kernel reports is the machine's own screen. A program in a
/// window on a desktop is not on that screen: it is as big as its window, and
/// only the terminal drawing that window knows. So it is asked, the way a
/// terminal is asked anything, with a sequence it answers: `CSI 18 t` out,
/// `CSI 8 ; rows ; cols t` back.
///
/// Waited for here, once, before a full-screen program has drawn anything:
/// there is nothing else in the stream yet, so the answer is the only thing
/// coming and reading for it races nothing. A later change of size arrives the
/// same way the keys do and is taken there. Null when nothing answers before
/// the deadline, which is the machine's own console: it is not a window and
/// has nothing to say, and the caller keeps the size the kernel gave.
pub fn terminalSize() ?Size {
    out.text("\x1b[18t");
    out.flush();

    var buf: [32]u8 = undefined;
    var have: usize = 0;
    while (have < buf.len) {
        // A short wait: a terminal answers at once, and the console never will.
        if (sys.waitMany(&[_]u32{sys.STDIN}, 200_000) < 0) return null;
        const n = sys.read(sys.STDIN, buf[have..]);
        if (n <= 0) return null;
        have += @intCast(n);
        switch (reportInFront(buf[0..have])) {
            .size => |found| return found.dimensions,
            .partial => {},
            .none => return null,
        }
    }
    return null;
}

/// A size the terminal reported, and how many bytes it took, so a reader with
/// more behind it in the stream knows where the rest begins.
pub const Report = struct { dimensions: Size, length: usize };

/// What the front of a stream is, as far as a terminal's size report goes.
///
/// `size` for a whole `CSI 8 ; rows ; cols t`, `partial` for the start of one
/// still arriving, and `none` for anything that is not one. The three are kept
/// apart because a reader does different things with each: take the size,
/// wait for the rest, or hand the bytes on to be read as a key.
pub const Front = union(enum) {
    size: Report,
    partial,
    none,
};

pub fn reportInFront(bytes: []const u8) Front {
    // `CSI 8` is the whole of what marks one: no key sequence begins with the
    // parameter eight, so recognising it never swallows one.
    const head = "\x1b[8";
    const shared = @min(bytes.len, head.len);
    if (!std.mem.eql(u8, bytes[0..shared], head[0..shared])) return .none;
    if (bytes.len < head.len) return .partial;

    const end = std.mem.indexOfScalarPos(u8, bytes, 2, 't') orelse return .partial;

    var it = str.split(bytes[2..end], ';');
    if (str.toUnsigned(it.next() orelse "") != 8) return .none;
    const rows = str.toUnsigned(it.next() orelse "");
    const columns = str.toUnsigned(it.next() orelse "");
    if (rows == 0 or columns == 0) return .none;

    return .{ .size = .{ .dimensions = .{ .columns = columns, .rows = rows }, .length = end + 1 } };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a size report is read out of the front of a stream" {
    switch (reportInFront("\x1b[8;24;80t")) {
        .size => |r| {
            try testing.expectEqual(@as(usize, 80), r.dimensions.columns);
            try testing.expectEqual(@as(usize, 24), r.dimensions.rows);
            try testing.expectEqual("\x1b[8;24;80t".len, r.length);
        },
        else => return error.NotARead,
    }

    // With a key sequence behind it: only the report is taken, and its length
    // says where the key begins.
    switch (reportInFront("\x1b[8;20;60t\x1b[A")) {
        .size => |r| try testing.expectEqual(@as(usize, 10), r.length),
        else => return error.NotARead,
    }
}

test "a report still arriving is waited for, not mistaken for a key" {
    for ([_][]const u8{ "\x1b", "\x1b[", "\x1b[8", "\x1b[8;20", "\x1b[8;20;60" }) |part| {
        try testing.expect(reportInFront(part) == .partial);
    }
}

test "what is not a report is left for the key reader" {
    // A key sequence starts with the escape but never the parameter eight.
    try testing.expect(reportInFront("\x1b[A") == .none);
    try testing.expect(reportInFront("\x1b[1;5A") == .none);
    try testing.expect(reportInFront("q") == .none);
    // A window op that is not the size one.
    try testing.expect(reportInFront("\x1b[9;1;1t") == .none);
    // Malformed: the marker but no numbers.
    try testing.expect(reportInFront("\x1b[8;;t") == .none);
}
