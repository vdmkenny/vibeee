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
const hal = @import("hal.zig");

/// Sixteen kilobytes holds a verbose boot, the services' lines included,
/// with room to spare, and is small enough not to be worth thinking about
/// against 512 MB.
pub const CAPACITY = 16 * 1024;

/// The record itself, apart from the guard around it, so that what it
/// keeps and how it wraps can be checked on the host.
pub const Ring = struct {
    buffer: []u8,
    /// Where the next byte goes.
    head: usize = 0,
    /// Total bytes ever written, so a reader knows whether the ring has
    /// wrapped and how much of it is real.
    written: usize = 0,

    pub fn append(self: *Ring, bytes: []const u8) void {
        for (bytes) |b| {
            self.buffer[self.head] = b;
            self.head = (self.head + 1) % self.buffer.len;
            self.written +|= 1;
        }
    }

    /// How much is currently held.
    pub fn len(self: *const Ring) usize {
        return @min(self.written, self.buffer.len);
    }

    /// Copy the record out, oldest first, and return how many bytes that
    /// was.
    ///
    /// Truncated from the front when the caller's buffer is smaller: the
    /// newest messages are the ones being looked for, and losing the start
    /// of a boot log is better than losing the failure at the end of it.
    pub fn copyOut(self: *const Ring, out: []u8) usize {
        const held = self.len();
        const take = @min(held, out.len);
        if (take == 0) return 0;

        // Where the bytes to copy begin, counting back from the write
        // position.
        const capacity = self.buffer.len;
        const start = (self.head + capacity - take) % capacity;
        const first = @min(take, capacity - start);

        @memcpy(out[0..first], self.buffer[start..][0..first]);
        if (first < take) @memcpy(out[first..take], self.buffer[0 .. take - first]);
        return take;
    }
};

var buffer: [CAPACITY]u8 = undefined;
var record: Ring = .{ .buffer = &buffer };

/// Add to the record. Lines come from interrupt context as well as from
/// threads, and two writers on one ring would interleave their bytes, so an
/// append is one step nothing can get inside.
pub fn append(bytes: []const u8) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    record.append(bytes);
}

/// Add a line to the record: the bytes and the newline after them in one
/// step, so nothing else's line lands between the two.
pub fn appendLine(bytes: []const u8) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    record.append(bytes);
    record.append("\n");
}

/// How much is currently held.
pub fn len() usize {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    return record.len();
}

/// Copy the record out, oldest first, and return how many bytes that was.
pub fn copyOut(out: []u8) usize {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    return record.copyOut(out);
}

test "a short record comes back whole" {
    var space: [64]u8 = undefined;
    var ring = Ring{ .buffer = &space };
    ring.append("hello");
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("hello", out[0..ring.copyOut(&out)]);
}

test "wrapping keeps the newest bytes" {
    var space: [CAPACITY]u8 = undefined;
    var ring = Ring{ .buffer = &space };
    for (0..CAPACITY + 4) |i| ring.append(&.{@as(u8, @intCast('a' + i % 26))});

    var out: [8]u8 = undefined;
    const n = ring.copyOut(&out);
    try std.testing.expectEqual(@as(usize, 8), n);

    // The last eight written, in order.
    var want: [8]u8 = undefined;
    for (0..8) |i| want[i] = @intCast('a' + (CAPACITY + 4 - 8 + i) % 26);
    try std.testing.expectEqualSlices(u8, &want, out[0..n]);
}

test "a buffer smaller than the record keeps the end of it" {
    var space: [64]u8 = undefined;
    var ring = Ring{ .buffer = &space };
    ring.append("abcdefgh");
    var out: [3]u8 = undefined;
    try std.testing.expectEqualStrings("fgh", out[0..ring.copyOut(&out)]);
}
