//! Run queues: an intrusive FIFO, and the priority array built from them.
//!
//! Generic over the node type rather than hard-coded to `Thread`, for one
//! reason: it makes this file testable on the host. The worst scheduler bug
//! this system has had was a node pushed onto an intrusive list twice, which
//! links the node to itself and makes the queue hand out the same entry
//! forever. It presented as sleeps returning instantly and then as a hang,
//! nowhere near its cause, on a machine with no serial port. Tests at the
//! bottom of this file now cover exactly that.
//!
//! A node must carry two fields, checked at compile time:
//!
//!   * `next: ?*T`   — the link
//!   * `queued: bool` — whether it is on a queue right now
//!
//! Intrusive because the scheduler cannot allocate on the path that enqueues a
//! thread: it runs with interrupts off, inside the timer interrupt, and a
//! failure to allocate there has nowhere to go.

const std = @import("std");

fn checkNode(comptime T: type) void {
    if (!@hasField(T, "next")) @compileError(@typeName(T) ++ " needs a `next: ?*" ++ @typeName(T) ++ "` link");
    if (!@hasField(T, "queued")) @compileError(@typeName(T) ++ " needs a `queued: bool` flag");
}

/// A first-in, first-out queue of nodes.
pub fn Fifo(comptime T: type) type {
    checkNode(T);

    return struct {
        const Self = @This();

        head: ?*T = null,
        tail: ?*T = null,

        /// Enqueue, unless the node is already on a queue.
        ///
        /// The guard is not decoration — see the note at the top of this file.
        /// It is a silent no-op rather than a panic because the callers that
        /// could trip it run in the timer interrupt, where a panic would
        /// replace a recoverable mistake with a dead machine.
        pub fn push(self: *Self, node: *T) void {
            if (node.queued) return;
            node.queued = true;
            node.next = null;
            if (self.tail) |tail| {
                tail.next = node;
            } else {
                self.head = node;
            }
            self.tail = node;
        }

        pub fn pop(self: *Self) ?*T {
            const node = self.head orelse return null;
            self.head = node.next;
            if (self.head == null) self.tail = null;
            node.next = null;
            node.queued = false;
            return node;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head == null;
        }
    };
}

/// One FIFO per priority level, with a bitmap so the highest occupied level is
/// found without searching.
pub fn Levels(comptime T: type, comptime count: usize) type {
    if (count == 0 or count > 32) @compileError("levels must fit a u32 bitmap");

    return struct {
        const Self = @This();
        pub const LEVELS = count;

        /// Bit i set means level i has at least one node.
        bitmap: u32 = 0,
        levels: [count]Fifo(T) = @splat(.{}),

        pub fn push(self: *Self, node: *T, priority: u8) void {
            const level = @min(priority, count - 1);
            const before = self.levels[level].isEmpty();
            self.levels[level].push(node);

            // Only claim the level if something actually went on it: a node
            // already queued elsewhere is refused above, and setting the bit
            // anyway would advertise a level that pops nothing.
            if (before and !self.levels[level].isEmpty()) {
                self.bitmap |= @as(u32, 1) << @intCast(level);
            }
        }

        /// Highest-priority node, or null. This is the O(1) part: one bit scan,
        /// no search over levels.
        pub fn pop(self: *Self) ?*T {
            if (self.bitmap == 0) return null;
            const level = @ctz(self.bitmap);
            const node = self.levels[level].pop();
            if (self.levels[level].isEmpty()) {
                self.bitmap &= ~(@as(u32, 1) << @intCast(level));
            }
            return node;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.bitmap == 0;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Node = struct {
    id: u32,
    next: ?*Node = null,
    queued: bool = false,
};

test "fifo preserves order" {
    var a = Node{ .id = 1 };
    var b = Node{ .id = 2 };
    var c = Node{ .id = 3 };

    var q: Fifo(Node) = .{};
    q.push(&a);
    q.push(&b);
    q.push(&c);

    try std.testing.expectEqual(@as(u32, 1), q.pop().?.id);
    try std.testing.expectEqual(@as(u32, 2), q.pop().?.id);
    try std.testing.expectEqual(@as(u32, 3), q.pop().?.id);
    try std.testing.expect(q.pop() == null);
}

test "pushing the same node twice does not make it point at itself" {
    // The regression this file exists for. Before the guard, the second push
    // set `tail.next = node` where tail *was* the node, and every pop after
    // that returned it forever.
    var a = Node{ .id = 1 };

    var q: Fifo(Node) = .{};
    q.push(&a);
    q.push(&a);

    try std.testing.expectEqual(@as(u32, 1), q.pop().?.id);
    try std.testing.expect(a.next == null);
    try std.testing.expect(q.pop() == null);
}

test "a popped node can be pushed again" {
    var a = Node{ .id = 1 };
    var q: Fifo(Node) = .{};

    q.push(&a);
    _ = q.pop();
    q.push(&a);

    try std.testing.expectEqual(@as(u32, 1), q.pop().?.id);
    try std.testing.expect(q.isEmpty());
}

test "a node cannot be on two queues at once" {
    var a = Node{ .id = 1 };
    var first: Fifo(Node) = .{};
    var second: Fifo(Node) = .{};

    first.push(&a);
    second.push(&a);

    try std.testing.expect(!second.isEmpty() == false);
    try std.testing.expectEqual(@as(u32, 1), first.pop().?.id);
}

test "levels hand out the highest priority first" {
    var low = Node{ .id = 10 };
    var high = Node{ .id = 1 };
    var mid = Node{ .id = 5 };

    var q: Levels(Node, 32) = .{};
    q.push(&low, 20);
    q.push(&high, 0);
    q.push(&mid, 10);

    try std.testing.expectEqual(@as(u32, 1), q.pop().?.id);
    try std.testing.expectEqual(@as(u32, 5), q.pop().?.id);
    try std.testing.expectEqual(@as(u32, 10), q.pop().?.id);
    try std.testing.expect(q.isEmpty());
}

test "levels clear their bitmap bit when a level empties" {
    var a = Node{ .id = 1 };
    var q: Levels(Node, 32) = .{};

    q.push(&a, 7);
    try std.testing.expect(!q.isEmpty());
    _ = q.pop();
    try std.testing.expect(q.isEmpty());
    try std.testing.expect(q.pop() == null);
}

test "a refused double push does not advertise an empty level" {
    // Pushing an already-queued node must not set a bitmap bit for a level
    // that has nothing on it, or pop() finds the level and returns null while
    // claiming the queue was non-empty.
    var a = Node{ .id = 1 };
    var q: Levels(Node, 32) = .{};

    q.push(&a, 3);
    q.push(&a, 9);

    try std.testing.expectEqual(@as(u32, 1), q.pop().?.id);
    try std.testing.expect(q.isEmpty());
}

test "priority above the last level is clamped rather than out of bounds" {
    var a = Node{ .id = 1 };
    var q: Levels(Node, 32) = .{};

    q.push(&a, 200);
    try std.testing.expectEqual(@as(u32, 1), q.pop().?.id);
}
