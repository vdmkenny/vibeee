//! Standard output: one buffered stream, and the shorthands for writing to it.
//!
//! The buffering is `ulib.stream`'s, because a stream to standard output and a
//! stream to a file are the same thing pointed at different handles. What is
//! here is the part that is specific to *this* stream: that there is one of
//! it, that a program need not carry it around to write a line, and that the
//! shell can point it somewhere else.
//!
//! The buffer is static because this stream exists before a program has had a
//! chance to allocate anything: the first thing many of them do is print.

const str = @import("lib").str;
const stream_mod = @import("stream.zig");
const sys = @import("sys");

var buffer: [1024]u8 = @splat(0);
var standard = stream_mod.Stream.init(sys.STDOUT, &buffer, .line);

/// The stream itself, for a caller that wants to hand it somewhere expecting
/// one rather than call through the shorthands below.
pub fn stream() *stream_mod.Stream {
    return &standard;
}

pub fn flush() void {
    standard.flush();
}

/// Send everything after this point to `handle`.
///
/// Flushes first: bytes buffered for the previous destination belong to it,
/// and letting them follow the switch would put the tail of one command's
/// output into another's file.
pub fn redirectTo(handle: u32) void {
    standard.flush();
    standard.handle = handle;
}

pub fn text(s: []const u8) void {
    standard.write(s);
}

/// Append a single byte. Cheaper than `text` for the one-character case, which
/// hexdump does thousands of times.
pub fn byte(c: u8) void {
    standard.writeByte(c);
}

/// Write `s` padded to `width`, for aligned columns.
pub fn pad(s: []const u8, width: usize) void {
    text(s);
    var n = s.len;
    while (n < width) : (n += 1) byte(' ');
}

/// A number in a left-aligned field, the numeric counterpart of `pad`.
pub fn padNumber(value: usize, width: usize) void {
    var buf: [20]u8 = @splat(0);
    const n = str.decimal(&buf, value);
    pad(buf[0..n], width);
}

pub fn decimal(value: usize) void {
    var buf: [24]u8 = undefined;
    text(str.number(&buf, value, 10, .lower));
}

/// Exactly `digits` hex digits, zero-filled. Fixed width rather than minimal,
/// because what this is for is addresses and registers, where the width is
/// what makes a column of them readable.
pub fn hex(value: usize, digits: usize) void {
    var buf: [24]u8 = undefined;
    const written = str.number(&buf, value, 16, .lower);

    var leading = digits -| written.len;
    while (leading > 0) : (leading -= 1) byte('0');
    text(written);
}

/// Write `value` right-aligned in `width` columns. Used for size columns,
/// where alignment is what makes a listing scannable.
pub fn decimalRight(value: usize, width: usize) void {
    var buf: [20]u8 = [_]u8{0} ** 20;
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
    const digits = buf.len - i;
    var w = digits;
    while (w < width) : (w += 1) byte(' ');
    text(buf[i..]);
}
