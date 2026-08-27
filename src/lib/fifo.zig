//! A fixed-depth queue of typed elements, for one process talking to itself.
//!
//! The shared-memory ring in `ring.zig` is for bytes crossing a privilege
//! boundary and pays for that in atomics and hostile-peer clamps. This is the
//! other queue: elements of one type, one address space, no concurrency
//! beyond what the caller already rules out. What it offers over an array is
//! the two overflow policies a bounded queue can honestly have, refuse the
//! new or drop the old, each stated at the call site.

const std = @import("std");

pub fn Fifo(comptime T: type, comptime depth: usize) type {
    return struct {
        items: [depth]T = undefined,
        first: usize = 0,
        count: usize = 0,

        const Self = @This();

        /// Take the new element, or refuse it when full. For queues where
        /// losing work is worse than making the producer wait or fail.
        pub fn push(self: *Self, item: T) bool {
            if (self.count == depth) return false;
            self.items[(self.first + self.count) % depth] = item;
            self.count += 1;
            return true;
        }

        /// Take the new element, dropping the oldest when full. For queues of
        /// perishable things, where the newest is the one worth keeping.
        pub fn pushDropOldest(self: *Self, item: T) void {
            if (self.count == depth) {
                self.first = (self.first + 1) % depth;
                self.count -= 1;
            }
            _ = self.push(item);
        }

        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            const item = self.items[self.first];
            self.first = (self.first + 1) % depth;
            self.count -= 1;
            return item;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }
    };
}

test "refusing push keeps the oldest" {
    var q = Fifo(u8, 2){};
    try std.testing.expect(q.push(1));
    try std.testing.expect(q.push(2));
    try std.testing.expect(!q.push(3));
    try std.testing.expectEqual(@as(?u8, 1), q.pop());
    try std.testing.expectEqual(@as(?u8, 2), q.pop());
    try std.testing.expectEqual(@as(?u8, null), q.pop());
}

test "dropping push keeps the newest" {
    var q = Fifo(u8, 2){};
    q.pushDropOldest(1);
    q.pushDropOldest(2);
    q.pushDropOldest(3);
    try std.testing.expectEqual(@as(?u8, 2), q.pop());
    try std.testing.expectEqual(@as(?u8, 3), q.pop());
    try std.testing.expect(q.isEmpty());
}
