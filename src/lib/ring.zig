//! The shared-memory ring: one layout, used by every bulk data path.
//!
//! Block requests, audio frames, network payloads and GUI surface updates all
//! move through this. `design/00-vibeee.md` §6.8 calls it the single most
//! important internal contract in the system, and the reason is that a ring is
//! the only structure both sides of a privilege boundary can touch at once
//! without a syscall per item. Channels carry the small synchronous
//! request/reply; rings carry the bytes.
//!
//! **Single producer, single consumer.** Exactly one writer and one reader,
//! which is what lets the whole thing work with two counters and no lock: the
//! producer only ever advances `head`, the consumer only ever advances `tail`,
//! and neither writes the other's. A ring with two writers needs a lock, and a
//! lock across a privilege boundary is a hostage the untrusted side can hold.
//!
//! **The counters are byte totals, not offsets, and are allowed to wrap.**
//! Storing totals rather than positions is what distinguishes a full ring from
//! an empty one — with offsets they are the same state — and unsigned wrapping
//! arithmetic makes the wrap a non-event, since only the difference is ever
//! read. Capacity is a power of two so the offset is a mask rather than a
//! division, which matters on a core with a 40-cycle divide.
//!
//! **The header lives in memory the untrusted side can write.** Nothing here
//! may assume a counter is sane: every read clamps against capacity, so a
//! malicious `tail` can make the ring look empty or full, but cannot make the
//! kernel index outside the buffer. That is the difference between a peer that
//! can hurt itself and one that can hurt the system.

const std = @import("std");

/// Shared between the two sides. `extern` because it is written by a program
/// compiled separately from the one reading it.
pub const Header = extern struct {
    /// Total bytes ever written. Advanced by the producer only.
    head: u32,
    /// Total bytes ever read. Advanced by the consumer only.
    tail: u32,
    /// Bytes of payload, a power of two.
    capacity: u32,
    /// Set by the producer when it will write no more, so a consumer that
    /// drains the ring can tell "nothing yet" from "nothing ever again".
    closed: u32,
};

pub const Error = error{
    /// Capacity is zero, not a power of two, or does not match the buffer.
    BadCapacity,
};

pub const Ring = struct {
    header: *volatile Header,
    data: []u8,

    /// Bind a ring to memory that already holds a header and its payload.
    ///
    /// Validated rather than trusted: this is called on both sides, and the
    /// kernel side is given memory a user process can write.
    pub fn attach(header: *volatile Header, data: []u8) Error!Ring {
        const size = header.capacity;
        if (size == 0 or size & (size - 1) != 0) return error.BadCapacity;
        if (data.len < size) return error.BadCapacity;
        return .{ .header = header, .data = data[0..size] };
    }

    /// Lay out a fresh ring over `data`, whose length must be a power of two.
    pub fn init(header: *volatile Header, data: []u8) Error!Ring {
        const size: u32 = @intCast(data.len);
        if (size == 0 or size & (size - 1) != 0) return error.BadCapacity;
        header.capacity = size;
        header.head = 0;
        header.tail = 0;
        header.closed = 0;
        return .{ .header = header, .data = data };
    }

    fn capacity(self: Ring) u32 {
        return @intCast(self.data.len);
    }

    /// Bytes available to read.
    ///
    /// Clamped because `tail` belongs to the other side: a value ahead of
    /// `head` would otherwise underflow into a gigantic length and walk the
    /// reader off the end of the buffer.
    pub fn readable(self: Ring) u32 {
        const head = @atomicLoad(u32, &self.header.head, .acquire);
        const tail = @atomicLoad(u32, &self.header.tail, .acquire);
        const used = head -% tail;
        return @min(used, self.capacity());
    }

    pub fn writable(self: Ring) u32 {
        return self.capacity() - self.readable();
    }

    pub fn isEmpty(self: Ring) bool {
        return self.readable() == 0;
    }

    pub fn isClosed(self: Ring) bool {
        return @atomicLoad(u32, &self.header.closed, .acquire) != 0;
    }

    /// Mark the producer finished. The consumer may still drain what is left.
    pub fn close(self: Ring) void {
        @atomicStore(u32, &self.header.closed, 1, .release);
    }

    /// Copy in as much of `bytes` as fits, returning how much was taken.
    ///
    /// Partial writes rather than all-or-nothing: a stream producer should be
    /// able to make progress against a nearly full ring, and a caller that
    /// needs atomicity can check `writable` first.
    pub fn write(self: Ring, bytes: []const u8) u32 {
        const space = self.writable();
        const n = @min(@as(u32, @intCast(bytes.len)), space);
        if (n == 0) return 0;

        const head = @atomicLoad(u32, &self.header.head, .monotonic);
        const start = head & (self.capacity() - 1);
        // The payload may straddle the end of the buffer, in which case it
        // takes two copies. This is the only place wrapping is visible.
        const first = @min(n, self.capacity() - start);
        @memcpy(self.data[start..][0..first], bytes[0..first]);
        if (n > first) @memcpy(self.data[0 .. n - first], bytes[first..n]);

        // Release: the payload must be visible before the count that claims it
        // is. Without this the consumer may read the new head and copy out
        // bytes the producer has not written yet.
        @atomicStore(u32, &self.header.head, head +% n, .release);
        return n;
    }

    /// Copy out up to `buf.len` bytes, returning how many were taken.
    pub fn read(self: Ring, buf: []u8) u32 {
        const available = self.readable();
        const n = @min(@as(u32, @intCast(buf.len)), available);
        if (n == 0) return 0;

        const tail = @atomicLoad(u32, &self.header.tail, .monotonic);
        const start = tail & (self.capacity() - 1);
        const first = @min(n, self.capacity() - start);
        @memcpy(buf[0..first], self.data[start..][0..first]);
        if (n > first) @memcpy(buf[first..n], self.data[0 .. n - first]);

        @atomicStore(u32, &self.header.tail, tail +% n, .release);
        return n;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Fixture = struct {
    header: Header,
    data: [16]u8,

    fn ring(self: *Fixture) Ring {
        return Ring.init(&self.header, &self.data) catch unreachable;
    }
};

test "write then read round trips" {
    var f: Fixture = undefined;
    const r = f.ring();

    try std.testing.expectEqual(@as(u32, 5), r.write("hello"));
    try std.testing.expectEqual(@as(u32, 5), r.readable());
    try std.testing.expectEqual(@as(u32, 11), r.writable());

    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 5), r.read(&buf));
    try std.testing.expectEqualStrings("hello", buf[0..5]);
    try std.testing.expect(r.isEmpty());
}

test "fills exactly to capacity" {
    var f: Fixture = undefined;
    const r = f.ring();

    // 16 bytes into a 16-byte ring: full is distinguishable from empty only
    // because the counters are totals rather than offsets.
    try std.testing.expectEqual(@as(u32, 16), r.write("0123456789abcdef"));
    try std.testing.expectEqual(@as(u32, 0), r.writable());
    try std.testing.expectEqual(@as(u32, 16), r.readable());
    try std.testing.expectEqual(@as(u32, 0), r.write("x"));
}

test "payload straddling the end of the buffer" {
    var f: Fixture = undefined;
    const r = f.ring();
    var buf: [16]u8 = undefined;

    // Advance most of the way round, then write across the seam.
    _ = r.write("0123456789ab");
    _ = r.read(buf[0..12]);

    try std.testing.expectEqual(@as(u32, 8), r.write("STRADDLE"));
    try std.testing.expectEqual(@as(u32, 8), r.read(&buf));
    try std.testing.expectEqualStrings("STRADDLE", buf[0..8]);
}

test "counters wrapping past 2^32 are a non-event" {
    var f: Fixture = undefined;
    var r = f.ring();

    // Park the counters just below the wrap. Only their difference is ever
    // read, so crossing it must change nothing.
    r.header.head = 0xFFFF_FFFC;
    r.header.tail = 0xFFFF_FFFC;

    try std.testing.expectEqual(@as(u32, 8), r.write("wraparnd"));
    try std.testing.expectEqual(@as(u32, 8), r.readable());

    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 8), r.read(&buf));
    try std.testing.expectEqualStrings("wraparnd", &buf);
    try std.testing.expect(r.isEmpty());
}

test "a hostile tail cannot make the reader run off the buffer" {
    var f: Fixture = undefined;
    var r = f.ring();

    _ = r.write("hello");
    // The other side owns tail and may write anything. Ahead of head, it would
    // underflow to a length near 2^32 without the clamp.
    r.header.tail = r.header.head +% 1000;
    try std.testing.expect(r.readable() <= 16);

    var buf: [64]u8 = undefined;
    _ = r.read(&buf); // must not fault or copy out of bounds
}

test "close is visible to a consumer that has drained" {
    var f: Fixture = undefined;
    const r = f.ring();

    _ = r.write("bye");
    r.close();

    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 3), r.read(&buf));
    try std.testing.expect(r.isEmpty());
    try std.testing.expect(r.isClosed());
}

test "rejects a capacity that is not a power of two" {
    var header: Header = undefined;
    var data: [12]u8 = undefined;
    try std.testing.expectError(error.BadCapacity, Ring.init(&header, &data));
}
