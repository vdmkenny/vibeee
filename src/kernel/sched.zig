//! O(1) scheduler.
//!
//! Two arrays of per-priority run queues — active and expired — plus a bitmap
//! of which priorities are occupied. Picking the next thread is one `@ctz` over
//! a single word, so scheduling costs the same with three threads or three
//! hundred. When the active array empties, the two arrays swap by pointer,
//! which is what makes the epoch boundary free.
//!
//! Deliberately not CFS: its red-black tree walk and 64-bit vruntime division
//! on every tick are a poor trade on a 630 MHz in-order core with no fast
//! divider. Nothing in the tick path here divides at all.
//!
//! 32 priorities rather than Linux's 140. The extra levels exist there to
//! separate 100 realtime bands from 40 nice levels; this system needs four
//! bands, and 32 fits one `u32` bitmap and one `@ctz` with no multi-word scan.
//!
//! See design/00-vibeee.md §6.4.

const std = @import("std");
const console = @import("console.zig");
const hal = @import("hal.zig");
const heap = @import("heap.zig");

pub const PRIORITY_LEVELS = 32;

/// Priority bands. Lower numbers win; the names exist so callers never write a
/// bare integer whose meaning depends on the table above.
pub const Priority = enum(u8) {
    /// Audio mixing, input dispatch. Latency matters more than throughput.
    realtime = 0,
    /// The compositor and the focused application.
    interactive = 8,
    /// Everything else.
    normal = 16,
    /// Background work that should never delay anything visible.
    batch = 24,
};

/// Time slice per band, in ticks. Interactive threads get short slices so the
/// system stays responsive; batch threads get long ones so they waste fewer
/// cycles on switching.
fn sliceFor(priority: u8) u8 {
    return switch (priority) {
        0...7 => 2, // realtime: 20 ms
        8...15 => 3, // interactive: 30 ms
        16...23 => 6, // normal: 60 ms
        else => 10, // batch: 100 ms
    };
}

pub const State = enum {
    ready,
    running,
    /// Waiting for a wakeup that is not time-based.
    blocked,
    /// Waiting until `wake_at`.
    sleeping,
    dead,
};

pub const Thread = struct {
    /// Saved stack pointer. Must be first: the context switch takes its address
    /// and nothing else in this struct is touched by assembly.
    sp: usize = 0,

    id: u32,
    name: []const u8,
    state: State = .ready,
    priority: u8,
    slice_left: u8 = 0,
    /// Monotonic microseconds at which a sleeping thread becomes runnable.
    wake_at: u64 = 0,
    stack: []u8,
    /// Intrusive link for whichever queue this thread is on.
    next: ?*Thread = null,
};

const Queue = struct {
    head: ?*Thread = null,
    tail: ?*Thread = null,

    fn push(self: *Queue, t: *Thread) void {
        t.next = null;
        if (self.tail) |tail| {
            tail.next = t;
        } else {
            self.head = t;
        }
        self.tail = t;
    }

    fn pop(self: *Queue) ?*Thread {
        const t = self.head orelse return null;
        self.head = t.next;
        if (self.head == null) self.tail = null;
        t.next = null;
        return t;
    }
};

const RunQueues = struct {
    /// Bit i set means level i has at least one thread.
    bitmap: u32 = 0,
    levels: [PRIORITY_LEVELS]Queue = @splat(.{}),

    fn push(self: *RunQueues, t: *Thread) void {
        const level = @min(t.priority, PRIORITY_LEVELS - 1);
        self.levels[level].push(t);
        self.bitmap |= @as(u32, 1) << @intCast(level);
    }

    /// Highest-priority thread, or null. This is the O(1) part: one bit scan,
    /// no search over levels.
    fn pop(self: *RunQueues) ?*Thread {
        if (self.bitmap == 0) return null;
        const level = @ctz(self.bitmap);
        const t = self.levels[level].pop();
        if (self.levels[level].head == null) {
            self.bitmap &= ~(@as(u32, 1) << @intCast(level));
        }
        return t;
    }
};

var queues: [2]RunQueues = .{ .{}, .{} };
var active: *RunQueues = &queues[0];
var expired: *RunQueues = &queues[1];

var sleepers: ?*Thread = null;
var current: ?*Thread = null;
var idle_thread: ?*Thread = null;
var next_id: u32 = 1;
var thread_count: usize = 0;
var switch_count: u64 = 0;
var started = false;

/// Set by the timer tick; acted on at interrupt exit, once the interrupt
/// controller has been acknowledged and it is safe to switch stacks.
var need_resched: bool = false;

pub const SpawnError = error{OutOfMemory};

pub fn spawn(
    name: []const u8,
    priority: Priority,
    entry: *const fn (usize) callconv(.c) void,
    arg: usize,
    stack_size: usize,
) SpawnError!*Thread {
    const t = try create(name, priority, entry, arg, stack_size);

    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    active.push(t);

    return t;
}

/// Create a thread without making it runnable. Used for the idle thread, which
/// must never sit in a run queue: it is always runnable, so it would starve
/// every lower-priority thread behind it.
fn create(
    name: []const u8,
    priority: Priority,
    entry: *const fn (usize) callconv(.c) void,
    arg: usize,
    stack_size: usize,
) SpawnError!*Thread {
    const gpa = heap.allocator;

    const t = gpa.create(Thread) catch return error.OutOfMemory;
    errdefer gpa.destroy(t);

    const stack = gpa.alignedAlloc(u8, .@"16", stack_size) catch return error.OutOfMemory;
    errdefer gpa.free(stack);

    t.* = .{
        .id = next_id,
        .name = name,
        .priority = @intFromEnum(priority),
        .slice_left = sliceFor(@intFromEnum(priority)),
        .stack = stack,
        .sp = hal.initThreadStack(stack, entry, arg, &threadExit),
    };
    next_id += 1;
    thread_count += 1;
    return t;
}

/// Where a thread lands when its entry function returns. Threads are not
/// required to call exit explicitly; falling off the end is a normal ending.
fn threadExit() callconv(.c) noreturn {
    exit();
}

pub fn exit() noreturn {
    hal.disableInterrupts();
    if (current) |t| {
        t.state = .dead;
        thread_count -= 1;
    }
    schedule();
    unreachable; // a dead thread is never rescheduled
}

pub fn yield() void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    if (current) |t| {
        if (t.state == .running) t.state = .ready;
    }
    schedule();
}

pub fn sleepUntil(deadline_us: u64) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    if (current) |t| {
        t.state = .sleeping;
        t.wake_at = deadline_us;
        t.next = sleepers;
        sleepers = t;
    }
    schedule();
}

pub fn sleepMicros(us: u64) void {
    sleepUntil(hal.monotonicMicros() + us);
}

/// Move any sleeper whose deadline has passed back to the run queues.
fn wakeSleepers(now: u64) void {
    var link = &sleepers;
    while (link.*) |t| {
        if (t.wake_at <= now) {
            link.* = t.next;
            t.state = .ready;
            t.next = null;
            active.push(t);
        } else {
            link = &t.next;
        }
    }
}

/// Pick the next thread and switch to it. Must be called with interrupts off.
fn schedule() void {
    wakeSleepers(hal.monotonicMicros());
    need_resched = false;

    const prev = current;

    // A thread that is still runnable goes back on a queue before we look for
    // the next one, so it is a candidate to be picked again when it is the only
    // one left.
    if (prev) |t| {
        switch (t.state) {
            .running, .ready => {
                t.state = .ready;
                // Out of slice: to the expired array, refilled. Otherwise it
                // keeps its remaining slice and stays in the current epoch.
                if (t.slice_left == 0) {
                    t.slice_left = sliceFor(t.priority);
                    expired.push(t);
                } else {
                    active.push(t);
                }
            },
            .sleeping, .blocked, .dead => {},
        }
    }

    var next = active.pop();
    if (next == null) {
        // Epoch boundary: everything runnable has spent its slice. Swapping
        // pointers is the whole cost of starting a new epoch.
        const tmp = active;
        active = expired;
        expired = tmp;
        next = active.pop();
    }

    const target = next orelse idle_thread orelse return;
    target.state = .running;
    current = target;

    if (prev == target) return;

    switch_count += 1;
    if (prev) |p| {
        hal.switchContext(&p.sp, target.sp);
    } else {
        // First switch of all: no outgoing context worth saving, but the
        // architecture still needs somewhere to write it.
        var discard: usize = 0;
        hal.switchContext(&discard, target.sp);
    }

    if (prev) |p| {
        if (p.state == .dead) reap(p);
    }
}

/// Free a dead thread's resources. Runs on the *next* thread's stack, which is
/// why it cannot happen inside `exit`: a thread cannot free the stack it is
/// standing on.
fn reap(t: *Thread) void {
    const gpa = heap.allocator;
    gpa.free(t.stack);
    gpa.destroy(t);
}

/// Called from the timer interrupt. Only accounting here — the actual switch
/// happens at interrupt exit, after the controller has been acknowledged.
pub fn onTick() void {
    if (!started) return;
    if (current) |t| {
        if (t.slice_left > 0) t.slice_left -= 1;
        if (t.slice_left == 0) need_resched = true;
    }
    if (sleepers != null) need_resched = true;
}

/// Called at interrupt exit, with interrupts still disabled.
pub fn onInterruptExit() void {
    if (!started or !need_resched) return;
    schedule();
}

/// The thread that runs when nothing else can. Halting rather than spinning is
/// what keeps the real machine cool and QEMU off a full host core.
fn idleLoop(_: usize) callconv(.c) void {
    while (true) hal.idle();
}

/// Hand the boot thread over to the scheduler. Does not return: the boot stack
/// becomes the idle thread's, and everything after this point runs as a thread.
pub fn start() !void {
    // Never enqueued: `schedule` falls back to it only when the run queues are
    // genuinely empty.
    idle_thread = try create("idle", .batch, idleLoop, 0, 4096);
    started = true;

    hal.disableInterrupts();
    schedule();
    hal.enableInterrupts();
}

pub const Stats = struct {
    threads: usize,
    switches: u64,
};

pub fn stats() Stats {
    return .{ .threads = thread_count, .switches = switch_count };
}

pub fn currentThread() ?*Thread {
    return current;
}
