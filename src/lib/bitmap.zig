//! A picture packed one pixel to a bit, the leftmost in the top bit.
//!
//! What a font's glyph and an interface's icon both are: a row of bytes where
//! bit seven of the first byte is the leftmost pixel and bit zero of it is the
//! eighth. Six places worked that out for themselves, in two spellings, and
//! each had to get the direction right on its own; one of them shifts to test
//! a bit and another masks, which is the same arithmetic written twice.

const std = @import("std");

/// The bit within a byte that pixel `x` sits in, counting from the left.
pub fn maskFor(x: u3) u8 {
    return @as(u8, 0x80) >> x;
}

/// Whether pixel `x` of one byte is set.
pub fn litIn(byte: u8, x: u3) bool {
    return byte & maskFor(x) != 0;
}

/// Whether pixel `x` of a packed row is set. Past the end of the row is unset:
/// a picture narrower than what is asked of it has nothing there.
pub fn lit(row: []const u8, x: usize) bool {
    const at = x / 8;
    return at < row.len and litIn(row[at], @intCast(x % 8));
}

/// Set pixel `x` of a packed row, ignoring one past its end.
pub fn light(row: []u8, x: usize) void {
    const at = x / 8;
    if (at < row.len) row[at] |= maskFor(@intCast(x % 8));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the leftmost pixel is the top bit" {
    const row = [_]u8{ 0b1000_0001, 0b0100_0000 };

    try testing.expect(lit(&row, 0));
    try testing.expect(!lit(&row, 1));
    try testing.expect(lit(&row, 7));
    try testing.expect(!lit(&row, 8));
    try testing.expect(lit(&row, 9));
}

test "setting a pixel reads back as that pixel" {
    var row = [_]u8{ 0, 0 };
    for ([_]usize{ 0, 7, 9, 15 }) |x| light(&row, x);

    for (0..16) |x| {
        const wanted = x == 0 or x == 7 or x == 9 or x == 15;
        try testing.expectEqual(wanted, lit(&row, x));
    }
}

test "past the end of a row there is nothing, and nothing is written" {
    var row = [_]u8{0};
    try testing.expect(!lit(&row, 8));

    light(&row, 64);
    try testing.expectEqual(@as(u8, 0), row[0]);
}
