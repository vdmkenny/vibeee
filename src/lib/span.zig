//! Ranges of an address space, and where a new one fits among them.
//!
//! What a process's shared-memory window is made of: each mapping takes a
//! span, and the next mapping goes at the lowest address with room for it.
//! Nothing here is about memory: the arithmetic is the same for any set of
//! ranges that must not overlap.

const std = @import("std");

pub const Span = struct {
    at: usize,
    len: usize,

    /// One past the last address. Saturating, so a span reaching the top
    /// of the address space ends at the top rather than at zero.
    pub fn end(self: Span) usize {
        return self.at +| self.len;
    }

    pub fn overlaps(self: Span, other: Span) bool {
        return self.at < other.end() and other.at < self.end();
    }
};

/// The lowest address in `[from, to)` where `len` bytes fit without
/// overlapping any of `taken`, in whatever order those come. Null when
/// nothing fits.
pub fn firstFit(taken: []const Span, len: usize, from: usize, to: usize) ?usize {
    var at = from;
    // Each span in the way moves the candidate to its end, and the walk
    // starts over, since a span passed earlier may now be in the way.
    var moved = true;
    while (moved) {
        moved = false;
        for (taken) |span| {
            if (span.overlaps(.{ .at = at, .len = len })) {
                at = span.end();
                moved = true;
            }
        }
    }
    if (len > to or at > to - len) return null;
    return at;
}

test "an empty window gives its first address" {
    try std.testing.expectEqual(@as(?usize, 100), firstFit(&.{}, 10, 100, 200));
}

test "a hole between spans is filled, whatever order the spans come in" {
    const taken = [_]Span{ .{ .at = 200, .len = 100 }, .{ .at = 0, .len = 100 } };
    try std.testing.expectEqual(@as(?usize, 100), firstFit(&taken, 100, 0, 1000));
    try std.testing.expectEqual(@as(?usize, 300), firstFit(&taken, 101, 0, 1000));
}

test "a span let go is where the next one of its size lands" {
    var taken = [_]Span{ .{ .at = 0, .len = 100 }, .{ .at = 100, .len = 100 }, .{ .at = 200, .len = 100 } };
    try std.testing.expectEqual(@as(?usize, 300), firstFit(&taken, 100, 0, 1000));
    taken[1] = taken[2];
    try std.testing.expectEqual(@as(?usize, 100), firstFit(taken[0..2], 100, 0, 1000));
}

test "nothing fits past the end, and the top of the address space does not wrap" {
    const taken = [_]Span{.{ .at = 0, .len = 900 }};
    try std.testing.expectEqual(@as(?usize, null), firstFit(&taken, 101, 0, 1000));
    try std.testing.expectEqual(@as(?usize, 900), firstFit(&taken, 100, 0, 1000));

    const top = std.math.maxInt(usize);
    const high = [_]Span{.{ .at = top - 100, .len = 100 }};
    try std.testing.expectEqual(@as(?usize, null), firstFit(&high, 200, top - 150, top));
    try std.testing.expectEqual(@as(?usize, null), firstFit(&.{}, 0, top, 10));
}
