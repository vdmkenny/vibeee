//! Buffered output.
//!
//! Every write is a syscall, so emitting a report a character at a time would
//! cost thousands of traps. Buffering into one write per line keeps a full
//! system report to a couple of dozen.

const str = @import("str.zig");
const sys = @import("sys");

var buffer: [1024]u8 = [_]u8{0} ** 1024;
var used: usize = 0;

/// Where flushed bytes go. Standard output unless something has redirected it,
/// which is how the shell sends a command's output to a file without the
/// command knowing: a builtin writes through this the same way either way.
var sink: u32 = sys.STDOUT;

pub fn flush() void {
    if (used == 0) return;
    _ = sys.write(sink, buffer[0..used]);
    used = 0;
}

/// Send everything after this point to `handle`.
///
/// Flushes first: bytes buffered for the previous destination belong to it,
/// and letting them follow the switch would put the tail of one command's
/// output into another's file.
pub fn redirectTo(handle: u32) void {
    flush();
    sink = handle;
}

/// Append bytes, flushing when the buffer fills or a line completes.
///
/// Copies in runs rather than byte at a time: the common case is a whole word
/// or line with no newline in it, and a per-byte loop makes every string cost
/// its length in branches.
pub fn text(s: []const u8) void {
    text_(s);
}

fn text_(s: []const u8) void {
    var rest = s;
    while (rest.len > 0) {
        const space = buffer.len - used;
        if (space == 0) {
            flush();
            continue;
        }

        // Copy up to and including the next newline, so line-buffering still
        // holds without inspecting each byte twice.
        var take = @min(rest.len, space);
        var newline = false;
        for (rest[0..take], 0..) |c, i| {
            if (c == '\n') {
                take = i + 1;
                newline = true;
                break;
            }
        }

        @memcpy(buffer[used..][0..take], rest[0..take]);
        used += take;
        rest = rest[take..];

        if (newline) flush();
    }
}

/// Append a single byte. Cheaper than `text` for the one-character case, which
/// hexdump does thousands of times.
pub fn byte(c: u8) void {
    if (used == buffer.len) flush();
    buffer[used] = c;
    used += 1;
    if (c == '\n') flush();
}

/// Write a filename or path as it should be read, per `str.displayName`.
pub fn name(text_bytes: []const u8) void {
    if (!str.caseless(text_bytes)) {
        text(text_bytes);
        return;
    }
    for (text_bytes) |c| byte(if (c >= 'A' and c <= 'Z') c + 32 else c);
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
    text(buf[i..]);
}

const HEX_DIGITS = "0123456789abcdef";

pub fn hex(value: usize, digits: usize) void {
    var buf: [16]u8 = [_]u8{0} ** 16;
    const n = @min(digits, buf.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[i] = HEX_DIGITS[(value >> @intCast((n - 1 - i) * 4)) & 0xF];
    }
    text(buf[0..n]);
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
