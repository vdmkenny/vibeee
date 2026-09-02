//! A list with a capacity fixed at compile time.
//!
//! The shape this system reaches for constantly: an array sized once and a
//! count of how much of it is in use. Nothing here allocates, because most of
//! the places that need it cannot, an interrupt routing table read before
//! there is a heap, a directory listing built on a sixteen-kilobyte stack.
//!
//! Written once and generically because it can be. Copied out per type, which
//! is what C leaves you, the bound check is what eventually goes missing from
//! one of them: `append` is the only place a length grows, so there is one
//! place for that to be right.

const std = @import("std");

pub fn Bounded(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const CAPACITY = capacity;
        pub const Error = error{Full};

        /// Undefined past `len`. Reading it is the caller's mistake, which is
        /// why `slice` exists and this is not meant to be indexed directly.
        items: [capacity]T = undefined,
        len: usize = 0,

        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        /// The same, writable, for a caller that sorts or edits in place.
        pub fn mutable(self: *Self) []T {
            return self.items[0..self.len];
        }

        /// Add one. Fails rather than dropping it silently: a caller that
        /// wants to stop at the bound says so with `catch break`, and one that
        /// does not find out it was truncated.
        pub fn append(self: *Self, value: T) Error!void {
            if (self.len == capacity) return error.Full;
            self.items[self.len] = value;
            self.len += 1;
        }

        pub fn at(self: *const Self, index: usize) ?T {
            return if (index < self.len) self.items[index] else null;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len == capacity;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Take one out and close the gap, for a list whose order is read.
        pub fn remove(self: *Self, index: usize) void {
            if (index >= self.len) return;
            std.mem.copyForwards(T, self.items[index .. self.len - 1], self.items[index + 1 .. self.len]);
            self.len -= 1;
        }

        /// Take one out and put the last in its place, for a list whose
        /// order means nothing: cheaper than closing the gap.
        pub fn swapRemove(self: *Self, index: usize) void {
            if (index >= self.len) return;
            self.len -= 1;
            self.items[index] = self.items[self.len];
        }
    };
}

test "append fills to the bound and then refuses" {
    var list = Bounded(u8, 3){};
    try list.append(1);
    try list.append(2);
    try list.append(3);

    try std.testing.expectError(error.Full, list.append(4));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, list.slice());
}

test "clear keeps the capacity and drops the contents" {
    var list = Bounded(u32, 4){};
    try list.append(7);
    list.clear();

    try std.testing.expect(list.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), list.slice().len);
    try list.append(9);
    try std.testing.expectEqual(@as(?u32, 9), list.at(0));
}

test "removing keeps the order, or fills the gap with the last" {
    var list = Bounded(u8, 4){};
    for ([_]u8{ 1, 2, 3, 4 }) |v| try list.append(v);

    list.remove(1);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 4 }, list.slice());
    list.swapRemove(0);
    try std.testing.expectEqualSlices(u8, &.{ 4, 3 }, list.slice());
    // Past the end is nothing to take out.
    list.remove(5);
    try std.testing.expectEqual(@as(usize, 2), list.slice().len);
}

test "indexing past the end answers null rather than reading past it" {
    var list = Bounded(u8, 2){};
    try list.append(5);
    try std.testing.expectEqual(@as(?u8, 5), list.at(0));
    try std.testing.expectEqual(@as(?u8, null), list.at(1));
}
