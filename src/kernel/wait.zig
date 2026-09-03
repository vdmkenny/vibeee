//! Blocking, and the only mechanism for it.
//!
//! A thread that needs to wait for something goes on one or more queues and
//! off the run queues entirely, so it costs nothing per tick. That is the whole
//! reason this exists: the alternative, which the scheduler used before events,
//! is polling with a short sleep, and on a 630 MHz core a dozen pollers waking
//! every two milliseconds is real time spent deciding to go back to sleep.
//!
//! One mechanism rather than several. Everything that blocks, waiting for a
//! child, for a channel reply, for a ring to have room, is a `Queue` plus a
//! predicate, and `blockOn` is where a thread stops running. `design/00-vibeee.md`
//! §6.8 states events are the only blocking primitive; this is that, and the
//! event object in `event.zig` is a thin counting latch on top.
//!
//! **The waiter node lives on the blocking thread's kernel stack.** It is safe
//! because a blocked thread does not return through that frame until it has
//! been woken and removed itself from every queue, so the node outlives every
//! reference to it. It is also what makes waiting allocation-free, which
//! matters because blocking is on the path of every syscall that can wait.
//!
//! **The lost-wakeup rule**: check your condition and call `blockOn` with
//! interrupts already disabled, and do not re-enable them in between. A wakeup
//! that arrives in that gap would otherwise find nobody queued and be dropped,
//! and the thread would sleep forever waiting for an event that already
//! happened.

const std = @import("std");
const sched = @import("sched.zig");

/// Most queues a single `blockOn` can cover, which is the same number the
/// `wait_many` call takes: the waiters live on this stack.
pub const MAX_QUEUES = @import("lib").limits.MAX_WAIT_HANDLES;

/// One thread's membership of one queue.
pub const Waiter = struct {
    thread: *sched.Thread,
    queue: ?*Queue = null,
    prev: ?*Waiter = null,
    next: ?*Waiter = null,
    /// Set by whoever wakes this waiter, so the blocked thread learns which of
    /// the queues it was on is the one that fired.
    woken: bool = false,
};

/// A list of threads waiting on one condition.
///
/// Doubly linked because a thread blocked on several queues has to be removed
/// from all of them the moment any one fires, and a singly linked list would
/// make that a scan per queue.
pub const Queue = struct {
    head: ?*Waiter = null,

    fn push(self: *Queue, w: *Waiter) void {
        w.queue = self;
        w.prev = null;
        w.next = self.head;
        if (self.head) |h| h.prev = w;
        self.head = w;
    }

    fn remove(self: *Queue, w: *Waiter) void {
        if (w.queue != self) return;
        if (w.prev) |p| p.next = w.next else self.head = w.next;
        if (w.next) |n| n.prev = w.prev;
        w.queue = null;
        w.prev = null;
        w.next = null;
    }

    /// Wake the longest-waiting thread. Returns false if none was waiting.
    ///
    /// Must be called with interrupts disabled: it moves a thread onto the run
    /// queues, which the timer interrupt also touches.
    pub fn wakeOne(self: *Queue) bool {
        // The tail is the oldest, the head the newest, so walking to the end
        // makes waiting fair. Queues here are short, one or two waiters is
        // the norm, so the walk is cheaper than a second tail pointer to
        // maintain on every insertion and removal.
        var last = self.head orelse return false;
        while (last.next) |n| last = n;

        self.remove(last);
        last.woken = true;
        sched.unblock(last.thread);
        return true;
    }

    pub fn wakeAll(self: *Queue) usize {
        var count: usize = 0;
        while (self.wakeOne()) count += 1;
        return count;
    }

    pub fn isEmpty(self: *const Queue) bool {
        return self.head == null;
    }
};

pub const Timeout = error{TimedOut};

/// Block the caller until one of `queues` wakes it, or `deadline_us` passes.
///
/// Returns the index of the queue that fired. Interrupts must already be
/// disabled and the caller's condition re-checked, see the lost-wakeup rule
/// above. They are still disabled on return.
pub fn blockOn(queues: []const *Queue, deadline_us: ?u64) Timeout!usize {
    std.debug.assert(queues.len > 0 and queues.len <= MAX_QUEUES);
    const self = sched.currentThread() orelse unreachable;

    // A thread that has been asked to end does not start a new wait. Every
    // caller already unwinds on a timeout, releasing whatever it holds, and
    // that is exactly the path a kill needs: the thread reaches the end of the
    // syscall, where it can be ended safely, instead of blocking again on
    // something that may never arrive.
    if (self.killed) return error.TimedOut;

    var waiters: [MAX_QUEUES]Waiter = undefined;
    for (queues, 0..) |q, i| {
        waiters[i] = .{ .thread = self };
        q.push(&waiters[i]);
    }

    sched.blockCurrent(deadline_us);

    // Back here means woken, timed out, or both. Leaving a stale waiter on a
    // queue would let a later signal write through a stack frame that has
    // since been reused, so every queue is left before anything else happens.
    var fired: ?usize = null;
    for (queues, 0..) |q, i| {
        if (waiters[i].woken and fired == null) fired = i;
        q.remove(&waiters[i]);
    }

    if (self.killed) return error.TimedOut;
    return fired orelse error.TimedOut;
}

/// Block on a single queue with no deadline.
pub fn block(queue: *Queue) void {
    _ = blockOn(&.{queue}, null) catch {};
}
