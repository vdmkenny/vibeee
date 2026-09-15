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
//! an empty one, with offsets they are the same state, and unsigned wrapping
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
const spsc = @import("spsc.zig");

/// Shared between the two sides. `extern` because it is written by a program
/// compiled separately from the one reading it.
pub const Header = extern struct {
    /// Total bytes ever written. Advanced by the producer only.
    head: u32,
    /// Total bytes ever read. Advanced by the consumer only.
    tail: u32,
    /// Bytes of payload, a power of two.
    capacity: u32,
    /// What the producer has to say besides bytes, in one word so it is set
    /// and read atomically.
    flags: Flags,
};

/// The producer's word to the consumer, apart from the bytes.
///
/// A packed struct over the word rather than a bit for each meaning and a
/// mask to find it: what is being said is a set of facts, and this is the
/// set.
pub const Flags = packed struct(u32) {
    /// The producer will write no more, so a consumer that drains the ring
    /// can tell "nothing yet" from "nothing ever again".
    closed: bool = false,
    /// Something did not fit and was dropped. Sticky, and out of band, because
    /// the one place it cannot be said is inside the ring that had no room:
    /// a consumer that finds it set knows it missed something and has to take
    /// stock afresh rather than trust what it has seen.
    overflowed: bool = false,
    _unused: u30 = 0,

    fn word(self: Flags) u32 {
        return @bitCast(self);
    }
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
        header.flags = .{};
        return .{ .header = header, .data = data };
    }

    /// The bytes and the two indices, as the ring arithmetic sees them: the
    /// header's own words, and the payload.
    fn bytes(self: Ring) spsc.Ring {
        return .{ .head = &self.header.head, .tail = &self.header.tail, .data = self.data };
    }

    /// Bytes available to read. Clamped, because `tail` belongs to the
    /// other side; see `spsc.Ring.readable`.
    pub fn readable(self: Ring) u32 {
        return self.bytes().readable();
    }

    pub fn writable(self: Ring) u32 {
        return self.bytes().writable();
    }

    pub fn isEmpty(self: Ring) bool {
        return self.readable() == 0;
    }

    /// The flag word as the word it is, for the atomics that work on words.
    fn flagWord(self: Ring) *volatile u32 {
        return @ptrCast(&self.header.flags);
    }

    fn flags(self: Ring) Flags {
        return @bitCast(@atomicLoad(u32, self.flagWord(), .acquire));
    }

    /// Raise one fact in the word without disturbing the others, whoever else
    /// is setting them: the word is shared, and a plain store from each side
    /// would let one overwrite the other's.
    fn raise(self: Ring, fact: Flags) void {
        _ = @atomicRmw(u32, self.flagWord(), .Or, fact.word(), .release);
    }

    pub fn isClosed(self: Ring) bool {
        return self.flags().closed;
    }

    /// Mark the producer finished. The consumer may still drain what is left.
    pub fn close(self: Ring) void {
        self.raise(.{ .closed = true });
    }

    /// Say that something did not fit. For the producer, at the moment it had
    /// to drop a record rather than block on a consumer that was not keeping
    /// up.
    pub fn markOverflow(self: Ring) void {
        self.raise(.{ .overflowed = true });
    }

    /// Whether anything was dropped since this was last asked, taking the
    /// fact with it so the next answer is about what happens next.
    pub fn takeOverflow(self: Ring) bool {
        const clear = ~(Flags{ .overflowed = true }).word();
        const before: Flags = @bitCast(@atomicRmw(u32, self.flagWord(), .And, clear, .acq_rel));
        return before.overflowed;
    }

    /// Copy in as much of `bytes` as fits, returning how much was taken.
    ///
    /// Partial writes rather than all-or-nothing: a stream producer should be
    /// able to make progress against a nearly full ring, and a caller that
    /// needs atomicity can check `writable` first.
    pub fn write(self: Ring, payload: []const u8) u32 {
        return self.bytes().push(payload);
    }

    /// Copy out up to `buf.len` bytes, returning how many were taken.
    pub fn read(self: Ring, buf: []u8) u32 {
        return self.bytes().pop(buf);
    }
};

/// One segment carrying a ring each way.
///
/// A service that hands a program both halves of a conversation grants one
/// piece of shared memory holding two rings, and both sides then work out
/// where each ring sits. Two sides computing the same offsets separately
/// is the kind of arithmetic that is wrong in one of them, so it is
/// written once, here, where it can be run.
///
/// Which ring is which direction is the protocol's to name: this says
/// only that there are two and where they are.
pub const Duplex = struct {
    /// In the order they sit in the segment.
    ring: [2]Ring,

    /// Where the bytes begin: both sets of counters first, each in a slot
    /// of its own so neither side's writes land in the other's.
    pub const HEADERS: usize = 64;

    /// How large a segment of this shape is, for a ring of `capacity`
    /// bytes each way.
    pub fn bytes(capacity: u32) usize {
        return HEADERS + 2 * @as(usize, capacity);
    }

    /// Lay fresh rings over a new segment, which the side that made it
    /// does once.
    pub fn make(base: [*]u8, capacity: u32) Error!Duplex {
        return over(base, capacity, Ring.init);
    }

    /// Bind to rings that are already there, which is what the side that
    /// was granted the segment does.
    pub fn attach(base: [*]u8, capacity: u32) Error!Duplex {
        return over(base, capacity, Ring.attach);
    }

    fn over(
        base: [*]u8,
        capacity: u32,
        comptime bind: fn (*volatile Header, []u8) Error!Ring,
    ) Error!Duplex {
        if (2 * @sizeOf(Header) > HEADERS) return error.BadCapacity;
        var both: Duplex = undefined;
        for (&both.ring, 0..) |*one, which| {
            const header: *volatile Header = @ptrCast(@alignCast(base + which * @sizeOf(Header)));
            const data = (base + HEADERS + which * capacity)[0..capacity];
            one.* = try bind(header, data);
        }
        return both;
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

test "an overflow is remembered until the consumer asks, then forgotten" {
    var f: Fixture = undefined;
    const r = f.ring();

    try std.testing.expect(!r.takeOverflow());

    // Fill it, then a record that cannot fit.
    _ = r.write("0123456789abcdef");
    try std.testing.expectEqual(@as(u32, 0), r.write("x"));
    r.markOverflow();

    // Set now, and only once: the taking clears it.
    try std.testing.expect(r.takeOverflow());
    try std.testing.expect(!r.takeOverflow());

    // Neither fact disturbs the other.
    r.markOverflow();
    r.close();
    try std.testing.expect(r.isClosed());
    try std.testing.expect(r.takeOverflow());
    try std.testing.expect(r.isClosed());
}

test "the flag word is the header's fourth word and starts clear" {
    var f: Fixture = undefined;
    _ = f.ring();
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Header));
    try std.testing.expectEqual(@as(u32, 0), (Flags{}).word());
    try std.testing.expectEqual(@as(u32, 1), (Flags{ .closed = true }).word());
    try std.testing.expectEqual(@as(u32, 2), (Flags{ .overflowed = true }).word());
}

test "a segment carries a ring each way, and neither reaches the other" {
    const CAPACITY = 16;
    var store: [Duplex.bytes(CAPACITY)]u8 align(8) = @splat(0);

    const made = try Duplex.make(&store, CAPACITY);
    try std.testing.expectEqual(@as(u32, 4), made.ring[0].write("away"));
    try std.testing.expectEqual(@as(u32, 5), made.ring[1].write("back!"));

    // The other side finds the same two rings without being told where
    // they are, which is the whole point of the shape.
    const found = try Duplex.attach(&store, CAPACITY);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 4), found.ring[0].read(&buf));
    try std.testing.expectEqualStrings("away", buf[0..4]);
    try std.testing.expectEqual(@as(u32, 5), found.ring[1].read(&buf));
    try std.testing.expectEqualStrings("back!", buf[0..5]);

    // Filling one to the brim leaves the other empty: their payloads do
    // not overlap, and neither do their counters.
    _ = made.ring[0].write("0123456789abcdef");
    try std.testing.expectEqual(@as(u32, 0), made.ring[0].writable());
    try std.testing.expectEqual(@as(u32, 16), found.ring[1].writable());
    try std.testing.expect(found.ring[1].isEmpty());

    // And closing one says nothing about the other.
    made.ring[0].close();
    try std.testing.expect(found.ring[0].isClosed());
    try std.testing.expect(!found.ring[1].isClosed());
}

test "a duplex segment is as large as it says and no larger" {
    try std.testing.expectEqual(@as(usize, 64 + 2 * 4096), Duplex.bytes(4096));
    try std.testing.expect(2 * @sizeOf(Header) <= Duplex.HEADERS);

    // A capacity that is not a power of two is refused by the rings
    // themselves rather than laid out and discovered later.
    var store: [Duplex.bytes(24)]u8 align(8) = @splat(0);
    try std.testing.expectError(error.BadCapacity, Duplex.make(&store, 24));
}
