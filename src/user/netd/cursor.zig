//! Where a cursor stands in a ring a device also writes.
//!
//! Not `lib.ring`, which is the shared-memory ring two processes move bytes
//! through: that one counts byte totals across a privilege boundary and
//! assumes nothing about the counters it is handed. This is the index a
//! driver keeps into a ring of descriptors the hardware walks beside it.
//!
//! Every ring here is a circle the hardware and this service walk in the
//! same direction: the service advances a read index, the device a write
//! one, and how much is in between is what may be reaped. The arithmetic
//! is one subtraction, and it is the one every driver gets wrong, because
//! for the whole of every lap after the first the write index is *behind*
//! the read one -- the ordinary case, not the awkward one. Taken below zero
//! on a `usize` that is a panic in a safe build and nonsense in the one
//! that ships.
//!
//! Nothing here touches memory or a device: it is index arithmetic, so it
//! is tested on the host where it can actually be run.

/// A position in a ring of `modulus` entries, and the only arithmetic
/// allowed on one.
///
/// `modulus` is not required to be a power of two: a status ring of 160
/// entries is as good a shape as a FIFO of 8192 bytes, and a mask that
/// assumed otherwise would silently alias two ends of one onto each other.
pub fn Cursor(comptime modulus: usize) type {
    if (modulus == 0) @compileError("a ring of nothing is not a ring");

    return struct {
        const Self = @This();

        /// How many entries the ring holds.
        pub const MODULUS = modulus;

        at: usize = 0,

        /// Move on one entry.
        pub fn next(self: *Self) void {
            self.advance(1);
        }

        /// Move on `by` entries, landing back at the start as often as it
        /// takes.
        pub fn advance(self: *Self, by: usize) void {
            self.at = wrapped(self.at +% by, modulus);
        }

        /// How much is in the ring: from `tail` up to this cursor, the
        /// long way round when this lap has already passed it.
        pub fn used(self: Self, tail: usize) usize {
            return usedBetween(self.at, tail, modulus);
        }

        /// How much room is left, keeping one entry back so a full ring
        /// and an empty one do not look the same to the device.
        pub fn room(self: Self, tail: usize) usize {
            return roomBetween(self.at, tail, modulus);
        }

        /// How far this cursor is from the end of the ring: how much a
        /// copy may take in one piece before it wraps.
        pub fn toEnd(self: Self) usize {
            return modulus - self.at;
        }
    };
}

/// `value` brought back inside a ring of `modulus`.
pub fn wrapped(value: usize, comptime modulus: usize) usize {
    return value % modulus;
}

/// How much of a ring is filled: `head` has moved on from `tail`, and the
/// distance is measured the way a lap measures it.
pub fn usedBetween(head: usize, tail: usize, comptime modulus: usize) usize {
    return if (head >= tail) head - tail else modulus - (tail - head);
}

/// How much room is left, less one: a ring whose head has caught its tail
/// is indistinguishable from an empty one to most devices, so a driver
/// that fills it to the brim has no way to say which.
pub fn roomBetween(head: usize, tail: usize, comptime modulus: usize) usize {
    return modulus - 1 - usedBetween(head, tail, modulus);
}

test "a cursor comes back round" {
    var cursor = Cursor(64){};
    try std.testing.expectEqual(@as(usize, 0), cursor.at);
    cursor.next();
    try std.testing.expectEqual(@as(usize, 1), cursor.at);
    cursor.advance(63);
    try std.testing.expectEqual(@as(usize, 0), cursor.at);
}

test "how much is in the ring is measured the way a lap is" {
    // Before the first wrap: the obvious answer.
    try std.testing.expectEqual(@as(usize, 5), usedBetween(5, 0, 64));
    // After one: the head is behind the tail, which is every lap but the
    // first and the case a plain subtraction takes below zero.
    try std.testing.expectEqual(@as(usize, 5), usedBetween(2, 61, 64));
    try std.testing.expectEqual(@as(usize, 1), usedBetween(0, 63, 64));
    // Empty and full.
    try std.testing.expectEqual(@as(usize, 0), usedBetween(7, 7, 64));
    try std.testing.expectEqual(@as(usize, 63), usedBetween(6, 7, 64));
}

test "room keeps one entry back so a full ring is not an empty one" {
    try std.testing.expectEqual(@as(usize, 63), roomBetween(0, 0, 64));
    try std.testing.expectEqual(@as(usize, 0), roomBetween(6, 7, 64));
    // A ring that is not a power of two measures the same way.
    try std.testing.expectEqual(@as(usize, 4), usedBetween(3, 159, 160));
}

const std = @import("std");
