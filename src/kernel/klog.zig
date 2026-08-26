//! What the kernel said, kept so someone can read it later.
//!
//! Every message goes here whether or not it was printed. A quiet boot shows
//! almost nothing on screen by design, and the machine still knows what
//! happened; without a record, finding out would mean rebooting with `verbose`
//! and hoping the fault repeats.
//!
//! A ring rather than a growing buffer: this has to work before there is a
//! heap, it must never be the reason a boot fails, and what matters most is
//! always the newest few thousand bytes. When it wraps, the oldest line goes.

const std = @import("std");

/// Eight kilobytes holds a verbose boot with room to spare, and is small
/// enough not to be worth thinking about against 512 MB.
pub const CAPACITY = 8 * 1024;

var buffer: [CAPACITY]u8 = undefined;
/// Where the next byte goes.
var head: usize = 0;
/// Total bytes ever written, so a reader knows whether the ring has wrapped
/// and how much of it is real.
var written: usize = 0;

pub fn append(bytes: []const u8) void {
    for (bytes) |b| {
        buffer[head] = b;
        head = (head + 1) % CAPACITY;
        written +|= 1;
    }
}

/// How much is currently held.
pub fn len() usize {
    return @min(written, CAPACITY);
}

/// Copy the record out, oldest first, and return how many bytes that was.
///
/// Truncated from the front when the caller's buffer is smaller: the newest
/// messages are the ones being looked for, and losing the start of a boot log
/// is better than losing the failure at the end of it.
pub fn copyOut(out: []u8) usize {
    const held = len();
    const take = @min(held, out.len);
    if (take == 0) return 0;

    // Where the bytes to copy begin, counting back from the write position.
    const start = (head + CAPACITY - take) % CAPACITY;
    const first = @min(take, CAPACITY - start);

    @memcpy(out[0..first], buffer[start..][0..first]);
    if (first < take) @memcpy(out[first..take], buffer[0 .. take - first]);
    return take;
}

test "a short record comes back whole" {
    reset();
    append("hello");
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("hello", out[0..copyOut(&out)]);
}

test "wrapping keeps the newest bytes" {
    reset();
    for (0..CAPACITY + 4) |i| append(&.{@as(u8, @intCast('a' + i % 26))});

    var out: [8]u8 = undefined;
    const n = copyOut(&out);
    try std.testing.expectEqual(@as(usize, 8), n);

    // The last eight written, in order.
    var want: [8]u8 = undefined;
    for (0..8) |i| want[i] = @intCast('a' + (CAPACITY + 4 - 8 + i) % 26);
    try std.testing.expectEqualSlices(u8, &want, out[0..n]);
}

test "a buffer smaller than the record keeps the end of it" {
    reset();
    append("abcdefgh");
    var out: [3]u8 = undefined;
    try std.testing.expectEqualStrings("fgh", out[0..copyOut(&out)]);
}

fn reset() void {
    head = 0;
    written = 0;
}
