//! Buffered output.
//!
//! Every write is a syscall, so emitting a report a character at a time would
//! cost thousands of traps. Buffering into one write per line keeps a full
//! system report to a couple of dozen.

const sys = @import("../syscall.zig");

var buffer: [1024]u8 = undefined;
var used: usize = 0;

pub fn flush() void {
    if (used == 0) return;
    _ = sys.write(sys.STDOUT, buffer[0..used]);
    used = 0;
}

pub fn text(s: []const u8) void {
    for (s) |c| {
        if (used == buffer.len) flush();
        buffer[used] = c;
        used += 1;
        if (c == '\n') flush();
    }
}

/// Write `s` padded to `width`, for aligned columns.
pub fn pad(s: []const u8, width: usize) void {
    text(s);
    var n = s.len;
    while (n < width) : (n += 1) text(" ");
}

pub fn decimal(value: usize) void {
    var buf: [20]u8 = undefined;
    var i = buf.len;
    var v = value;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
    }
    text(buf[i..]);
}

pub fn hex(value: usize, digits: usize) void {
    const table = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < digits) : (i += 1) {
        buf[i] = table[(value >> @intCast((digits - 1 - i) * 4)) & 0xF];
    }
    text(buf[0..digits]);
}
