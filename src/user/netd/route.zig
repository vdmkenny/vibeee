//! Which interface holds the route for traffic that has no route of its own.
//!
//! The choice is a policy over what the configuration asked for and what each
//! interface can currently do. Nothing of the stack is in it, so it is decided
//! here and applied by whoever holds the interfaces.

const std = @import("std");

/// Which interface should hold it: the one the configuration puts first among
/// those that can carry it, and nothing where none can.
///
/// `ranks` gives each interface its place in the configuration, or nothing
/// where it cannot carry traffic at all. An interface no slot claimed ranks
/// last and is still the answer when it is the only one: a radio that joined
/// a network nobody had written down is the only way off the machine, and a
/// route it cannot hold is a machine that reaches its own neighbours and
/// nothing beyond them.
pub fn holder(ranks: []const ?u8) ?usize {
    var best: ?usize = null;
    var best_rank: u8 = 0;
    for (ranks, 0..) |maybe, i| {
        const rank = maybe orelse continue;
        if (best != null and rank >= best_rank) continue;
        best_rank = rank;
        best = i;
    }
    return best;
}

const testing = std.testing;

test "nothing that can carry means nobody holds it" {
    try testing.expectEqual(@as(?usize, null), holder(&.{ null, null }));
}

test "the only interface that can carry takes it, however it ranks" {
    // The case a radio arrives in: joined, addressed, and claimed by no slot,
    // so it ranks last of all. Last of one is still first.
    try testing.expectEqual(@as(?usize, 1), holder(&.{ null, std.math.maxInt(u8) }));
}

test "the configuration decides between two that can carry" {
    try testing.expectEqual(@as(?usize, 1), holder(&.{ 3, 0 }));
    try testing.expectEqual(@as(?usize, 0), holder(&.{ 0, 3 }));
}

test "a claimed interface outranks an unclaimed one" {
    try testing.expectEqual(@as(?usize, 2), holder(&.{ std.math.maxInt(u8), null, 7 }));
}

test "interfaces the configuration cannot tell apart go to the first" {
    try testing.expectEqual(@as(?usize, 0), holder(&.{ 5, 5, 5 }));
}

test "the route follows the interfaces that come and go" {
    const wired = 0;
    const radio = std.math.maxInt(u8);
    const none: ?u8 = null;

    // Nothing has an address yet.
    try testing.expectEqual(@as(?usize, null), holder(&.{ none, none }));

    // The radio joins a network nobody wrote down. It is the only way off
    // the machine, so it holds the route however it ranks.
    try testing.expectEqual(@as(?usize, 1), holder(&.{ none, radio }));

    // A cable arrives. Its lease has not landed, so nothing changes yet.
    try testing.expectEqual(@as(?usize, 1), holder(&.{ none, radio }));

    // The lease lands, and the configuration prefers the wired port.
    try testing.expectEqual(@as(?usize, 0), holder(&.{ wired, radio }));

    // The cable comes out. The radio takes it back rather than the machine
    // keeping the route on a port with no carrier.
    try testing.expectEqual(@as(?usize, 1), holder(&.{ none, radio }));

    // The radio leaves the cell too, and nobody can hold it.
    try testing.expectEqual(@as(?usize, null), holder(&.{ none, none }));

    // The cable comes back on its own.
    try testing.expectEqual(@as(?usize, 0), holder(&.{ wired, none }));
}
