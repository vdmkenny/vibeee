//! A single-producer single-consumer byte ring over borrowed memory.
//!
//! The indices and the storage belong to somebody else, shared memory
//! between two processes, so this file is only the arithmetic: free-running
//! u32 indices over a power-of-two capacity, the producer publishing head
//! with a release store and the consumer publishing tail the same way. Each
//! side stores only its own index, which is the whole locking story.

const std = @import("std");

pub const Ring = struct {
    /// Written by the producer, read by the consumer.
    head: *u32,
    /// Written by the consumer, read by the producer.
    tail: *u32,
    /// Power-of-two length, so free-running indices wrap by masking.
    data: []u8,

    pub fn readable(self: Ring) u32 {
        const head = @atomicLoad(u32, self.head, .acquire);
        const tail = @atomicLoad(u32, self.tail, .monotonic);
        return head -% tail;
    }

    pub fn writable(self: Ring) u32 {
        return @as(u32, @intCast(self.data.len)) - self.readable();
    }

    /// Copy in as much of `bytes` as fits and publish it. Returns how much
    /// moved; a full ring moves nothing and the caller waits for the reader.
    pub fn push(self: Ring, bytes: []const u8) u32 {
        const room = self.writable();
        const n: u32 = @min(room, @as(u32, @intCast(bytes.len)));
        if (n == 0) return 0;

        const mask: u32 = @intCast(self.data.len - 1);
        var head = @atomicLoad(u32, self.head, .monotonic);
        for (bytes[0..n]) |b| {
            self.data[head & mask] = b;
            head +%= 1;
        }
        @atomicStore(u32, self.head, head, .release);
        return n;
    }

    /// Copy out as much as `into` holds and consume it. Returns how much.
    pub fn pop(self: Ring, into: []u8) u32 {
        const n = self.peek(into, 0);
        if (n != 0) self.skip(n);
        return n;
    }

    /// Copy out without consuming, starting `offset` bytes past the tail.
    /// For a consumer that must hand bytes onward before it may lose them:
    /// peek, offer, then `skip` exactly what was taken.
    pub fn peek(self: Ring, into: []u8, offset: u32) u32 {
        const have = self.readable();
        if (offset >= have) return 0;
        const n: u32 = @min(have - offset, @as(u32, @intCast(into.len)));
        if (n == 0) return 0;

        const mask: u32 = @intCast(self.data.len - 1);
        var at = @atomicLoad(u32, self.tail, .monotonic) +% offset;
        for (into[0..n]) |*b| {
            b.* = self.data[at & mask];
            at +%= 1;
        }
        return n;
    }

    /// Consume `n` bytes without reading them, completing a `peek`.
    pub fn skip(self: Ring, n: u32) void {
        const tail = @atomicLoad(u32, self.tail, .monotonic);
        @atomicStore(u32, self.tail, tail +% n, .release);
    }
};

test "bytes come out in the order they went in" {
    var head: u32 = 0;
    var tail: u32 = 0;
    var store: [8]u8 = undefined;
    const ring = Ring{ .head = &head, .tail = &tail, .data = &store };

    try std.testing.expectEqual(@as(u32, 5), ring.push("hello"));
    var got: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 5), ring.pop(&got));
    try std.testing.expectEqualStrings("hello", got[0..5]);
}

test "a full ring refuses and a drained ring frees the room" {
    var head: u32 = 0;
    var tail: u32 = 0;
    var store: [4]u8 = undefined;
    const ring = Ring{ .head = &head, .tail = &tail, .data = &store };

    try std.testing.expectEqual(@as(u32, 4), ring.push("abcdef"));
    try std.testing.expectEqual(@as(u32, 0), ring.push("x"));
    var got: [2]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 2), ring.pop(&got));
    try std.testing.expectEqualStrings("ab", &got);
    try std.testing.expectEqual(@as(u32, 2), ring.push("xy"));
    var rest: [4]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 4), ring.pop(&rest));
    try std.testing.expectEqualStrings("cdxy", &rest);
}

test "peek reads ahead without consuming until skip says so" {
    var head: u32 = 0;
    var tail: u32 = 0;
    var store: [8]u8 = undefined;
    const ring = Ring{ .head = &head, .tail = &tail, .data = &store };

    _ = ring.push("abcdef");
    var got: [4]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 4), ring.peek(&got, 0));
    try std.testing.expectEqualStrings("abcd", &got);
    try std.testing.expectEqual(@as(u32, 6), ring.readable());

    try std.testing.expectEqual(@as(u32, 2), ring.peek(got[0..2], 4));
    try std.testing.expectEqualStrings("ef", got[0..2]);

    ring.skip(2);
    try std.testing.expectEqual(@as(u32, 4), ring.readable());
    var rest: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 4), ring.pop(&rest));
    try std.testing.expectEqualStrings("cdef", rest[0..4]);
}

test "indices survive wrapping around the top of u32" {
    var head: u32 = std.math.maxInt(u32) - 1;
    var tail: u32 = std.math.maxInt(u32) - 1;
    var store: [4]u8 = undefined;
    const ring = Ring{ .head = &head, .tail = &tail, .data = &store };

    try std.testing.expectEqual(@as(u32, 3), ring.push("abc"));
    var got: [3]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 3), ring.pop(&got));
    try std.testing.expectEqualStrings("abc", &got);
    try std.testing.expectEqual(@as(u32, 1), head);
}
