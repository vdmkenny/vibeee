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

const std = @import("std");
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

/// One codepoint, as the UTF-8 the console reads.
///
/// Here rather than at each call site because encoding is not something a
/// program naming a glyph should have to think about, and hand-written escape
/// bytes are how two callers come to disagree about the same character.
pub fn glyph(cp: u21) void {
    var encoded: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &encoded) catch return;
    text(encoded[0..n]);
}

/// Write `s` padded to `width`, for aligned columns.
/// `mv: notes.txt: cannot move`, which is how every command says that
/// something it was given did not work.
///
/// One shape, because a person reading a pipeline's output should be able to
/// tell which command spoke and what it was talking about without learning a
/// different arrangement per command.
pub fn fault(tool: []const u8, what: []const u8, why: []const u8) void {
    text(tool);
    text(": ");
    if (what.len != 0) {
        text(what);
        text(": ");
    }
    text(why);
    byte('\n');
}

pub fn pad(s: []const u8, width: usize) void {
    text(s);
    var n = s.len;
    while (n < width) : (n += 1) byte(' ');
}

/// A number in a left-aligned field, the numeric counterpart of `pad`.
pub fn padNumber(value: usize, width: usize) void {
    var buf: [20]u8 = undefined;
    pad(str.decimal(&buf, value), width);
}

pub fn decimal(value: usize) void {
    var buf: [24]u8 = undefined;
    text(str.decimal(&buf, value));
}

/// Exactly `digits` hex digits, zero-filled. Fixed width rather than minimal,
/// because what this is for is addresses and registers, where the width is
/// what makes a column of them readable.
pub fn hex(value: usize, digits: usize) void {
    var buf: [24]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    writer.print("{[value]x:0>[digits]}", .{ .value = value, .digits = digits }) catch {};
    text(buf[0..writer.end]);
}

/// Write `value` right-aligned in `width` columns. Used for size columns,
/// where alignment is what makes a listing scannable.
/// A number that may be negative, which the readings taken off a radio
/// are: a signal strength and a noise floor are both decibels below a
/// milliwatt, and neither is ever positive on a working one.
pub fn signed(value: i32) void {
    if (value < 0) byte('-');
    decimal(@abs(value));
}

pub fn decimalRight(value: usize, width: usize) void {
    var buf: [20]u8 = undefined;
    const digits = str.decimal(&buf, value);
    var w = digits.len;
    while (w < width) : (w += 1) byte(' ');
    text(digits);
}
