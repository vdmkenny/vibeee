//! The handles something waits on, as a set.
//!
//! A service that waits on several things keeps them in one array and hands
//! that array to the kernel. What makes the array worth a type of its own is
//! taking something out of it: a handle that has been closed must leave the
//! set before it is closed, because a closed handle makes the whole wait
//! return an error at once instead of blocking, and a loop that waits for
//! nothing runs flat out. A number that is closed first can also be handed
//! straight back out for something else, which would leave the set waiting on
//! whatever that turned out to be.

const std = @import("std");
const testing = std.testing;

pub fn WaitSet(comptime CAPACITY: usize) type {
    return struct {
        const Self = @This();

        pub const MAX = CAPACITY;

        handles: [CAPACITY]u32 = @splat(0),
        len: usize = 0,

        /// What to hand the kernel.
        pub fn slice(self: *const Self) []const u32 {
            return self.handles[0..self.len];
        }

        pub fn has(self: Self, handle: u32) bool {
            return std.mem.indexOfScalar(u32, self.handles[0..self.len], handle) != null;
        }

        /// Wait on one more thing. A handle already in the set is not added
        /// twice: one wake is one wake however many owners a line has, and a
        /// set that held it twice would report the same event under two
        /// different indexes. Answers whether there was room.
        pub fn add(self: *Self, handle: u32) bool {
            if (handle == 0) return false;
            if (self.has(handle)) return true;
            if (self.len == CAPACITY) return false;
            self.handles[self.len] = handle;
            self.len += 1;
            return true;
        }

        /// Stop waiting on something. The last entry fills the hole, because
        /// this is a set: what waits on what is not an order.
        pub fn remove(self: *Self, handle: u32) bool {
            const at = std.mem.indexOfScalar(u32, self.handles[0..self.len], handle) orelse return false;
            self.len -= 1;
            self.handles[at] = self.handles[self.len];
            return true;
        }
    };
}

test "a handle goes in once however often it is offered" {
    var set = WaitSet(4){};
    try testing.expect(set.add(7));
    try testing.expect(set.add(7));
    try testing.expectEqual(@as(usize, 1), set.slice().len);

    // Zero is not a handle, and never takes a place.
    try testing.expect(!set.add(0));
    try testing.expectEqual(@as(usize, 1), set.slice().len);
}

test "a handle taken out is gone, and the rest are still waited on" {
    var set = WaitSet(4){};
    for ([_]u32{ 3, 4, 5 }) |h| try testing.expect(set.add(h));

    try testing.expect(set.remove(4));
    try testing.expectEqual(@as(usize, 2), set.slice().len);
    try testing.expect(!set.has(4));
    // The other two are still there, which is the half that matters: a
    // removal that dropped a neighbour would stop the loop hearing it.
    try testing.expect(set.has(3));
    try testing.expect(set.has(5));

    // Taking out what was never in changes nothing.
    try testing.expect(!set.remove(9));
    try testing.expectEqual(@as(usize, 2), set.slice().len);
}

test "a full set refuses rather than overrunning, and has room again once something leaves" {
    var set = WaitSet(2){};
    try testing.expect(set.add(1));
    try testing.expect(set.add(2));
    try testing.expect(!set.add(3));

    try testing.expect(set.remove(1));
    try testing.expect(set.add(3));
    try testing.expect(set.has(2));
    try testing.expect(set.has(3));
}

test "removing the last entry leaves the set usable" {
    var set = WaitSet(3){};
    try testing.expect(set.add(11));
    try testing.expect(set.remove(11));
    try testing.expectEqual(@as(usize, 0), set.slice().len);
    try testing.expect(set.add(12));
    try testing.expect(set.has(12));
}
