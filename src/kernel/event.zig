//! Events — the kernel object userspace blocks on.
//!
//! An event is a counter with a wait queue. Signalling increments it and
//! releases one waiter; waiting consumes a count, or blocks if there is none.
//! Counting rather than a plain flag because a signal that arrives while
//! nobody is waiting must not be lost: a server that finishes work just before
//! its client calls `wait` would otherwise leave the client blocked forever on
//! something that already happened.
//!
//! `waitMany` is what makes this the *only* blocking primitive worth having.
//! A server with a channel, a ring and a timer has one blocking call rather
//! than three threads, which on a single-core machine with 512 MB is the
//! difference between a design that fits and one that does not.
//!
//! Events are reference counted because a handle to one can be duplicated into
//! a child, and either end may close first. `design/00-vibeee.md` §6.8.

const std = @import("std");
const hal = @import("hal.zig");
const heap = @import("heap.zig");
const wait = @import("wait.zig");

pub const Error = error{
    OutOfMemory,
    TooMany,
    TimedOut,
};

/// Most events one `waitMany` can cover, bounded by the waiter array it puts
/// on the caller's kernel stack.
pub const MAX_WAIT = wait.MAX_QUEUES;

pub const Event = struct {
    /// Unconsumed signals. Saturates rather than wrapping: an event signalled
    /// four billion times without a waiter is a bug in the signaller, and
    /// wrapping to zero would turn it into a hang somewhere else entirely.
    count: u32 = 0,
    queue: wait.Queue = .{},
    refs: u32 = 1,

    /// Release one waiter, or leave a count behind for the next one to arrive.
    pub fn signal(self: *Event) void {
        const flags = hal.saveAndDisableInterrupts();
        defer hal.restoreInterrupts(flags);
        self.signalLocked();
    }

    /// The same, for callers that already hold interrupts off — which every
    /// path that has just changed the state a waiter is watching does.
    pub fn signalLocked(self: *Event) void {
        if (self.count != std.math.maxInt(u32)) self.count += 1;
        _ = self.queue.wakeOne();
    }

    /// Consume one signal, blocking until there is one. Named to pair with
    /// `waitMany` below, which is the call that earns this design.
    pub fn waitOne(self: *Event, deadline_us: ?u64) Error!void {
        const flags = hal.saveAndDisableInterrupts();
        defer hal.restoreInterrupts(flags);

        while (self.count == 0) {
            _ = wait.blockOn(&.{&self.queue}, deadline_us) catch return error.TimedOut;
        }
        self.count -= 1;
    }

    /// Take a signal if one is already there, without blocking.
    pub fn poll(self: *Event) bool {
        const flags = hal.saveAndDisableInterrupts();
        defer hal.restoreInterrupts(flags);

        if (self.count == 0) return false;
        self.count -= 1;
        return true;
    }
};

/// Block until one of `events` is signalled, and consume that signal.
///
/// Returns the index of the event that fired. When several are already
/// signalled the lowest index wins, which makes priority a matter of argument
/// order and saves callers inventing their own scheme.
pub fn waitMany(events: []const *Event, deadline_us: ?u64) Error!usize {
    if (events.len == 0 or events.len > MAX_WAIT) return error.TooMany;

    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    var queues: [MAX_WAIT]*wait.Queue = undefined;
    for (events, 0..) |e, i| queues[i] = &e.queue;

    while (true) {
        for (events, 0..) |e, i| {
            if (e.count > 0) {
                e.count -= 1;
                return i;
            }
        }

        // The index the wakeup reports is a hint, not the answer: another
        // thread may have consumed that signal before this one ran. Looping
        // back to re-scan is what makes that harmless.
        _ = wait.blockOn(queues[0..events.len], deadline_us) catch return error.TimedOut;
    }
}

// ---------------------------------------------------------------------------
// Lifetime
// ---------------------------------------------------------------------------

pub fn create() Error!*Event {
    const e = heap.allocator.create(Event) catch return error.OutOfMemory;
    e.* = .{};
    return e;
}

pub fn retain(e: *Event) void {
    e.refs += 1;
}

/// Drop a reference, destroying the event when the last one goes.
pub fn release(e: *Event) void {
    if (e.refs > 1) {
        e.refs -= 1;
        return;
    }
    // Anything still blocked would never be woken again, so it is released
    // first. A waiter that comes back to a destroyed event sees its condition
    // unmet and its handle closed, which is the same answer by a shorter road.
    const flags = hal.saveAndDisableInterrupts();
    _ = e.queue.wakeAll();
    hal.restoreInterrupts(flags);

    heap.allocator.destroy(e);
}
