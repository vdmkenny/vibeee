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
const handle = @import("handle.zig");
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

    /// Open handles. Lives on the thread because a process is currently one
    /// thread; it moves to a Process struct when that stops being true.
    handles: handle.Table = .{},

    /// The address space this thread runs in.
    ///
    /// Kernel threads share the kernel's. A user process has its own, and the
    /// scheduler switches to it — without that, a thread resumed after another
    /// process ran would execute against whatever page directory happened to be
    /// loaded, which is at best the wrong memory and at worst freed.
    space: hal.AddressSpace = .{ .pd_phys = 0 },

    /// Floating-point and SIMD registers. Aligned because FXSAVE requires it,
    /// and placed last so the alignment does not pad the hot fields apart.
    fpu: hal.FpuState align(16) = @splat(0),

    /// Timer ticks spent running. The only per-thread cost measure available
    /// without a high-resolution clock read on every switch, which on this
    /// machine would cost more than it measures.
    cpu_ticks: u64 = 0,

    /// Working directory, always absolute and without a trailing slash except
    /// for "/" itself. Held per thread for the same reason handles are: a
    /// process is currently one thread.
    cwd_buf: [128]u8 = @splat(0),
    cwd_len: usize = 1,

    exit_status: i32 = 0,
    /// Set when another thread intends to collect this one's status. Such a
    /// thread is not freed on exit — it stays as a corpse until collected, or
    /// its status would be gone before anyone could read it.
    awaited: bool = false,
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

/// Page directory currently loaded, so a switch between threads sharing a space
/// does not reload CR3 and flush the TLB for nothing.
var active_space: usize = 0;

/// Give a thread its own address space, and record it as current if the caller
/// is that thread.
pub fn setAddressSpace(t: *Thread, space: hal.AddressSpace) void {
    t.space = space;
}

/// Note that the running thread has changed address space out of band, so the
/// scheduler does not skip a needed reload later.
pub fn noteAddressSpace(pd_phys: usize) void {
    active_space = pd_phys;
}

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
    t.handles.init();
    t.cwd_buf[0] = '/';
    t.cwd_len = 1;
    hal.initFpuState(&t.fpu);
    // Kernel space until something gives it one of its own.
    t.space = hal.kernelAddressSpace();
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
    exitWith(0);
}

pub fn exitWith(status: i32) noreturn {
    hal.disableInterrupts();
    if (current) |t| {
        t.exit_status = status;
        t.state = .dead;
        thread_count -= 1;
    }
    schedule();
    unreachable; // a dead thread is never rescheduled
}

/// Block until `child` exits, then return its status and free it.
///
/// Polling rather than a wait queue: with one waiter per child and a system
/// this size, a queue would be machinery without a customer. It becomes one
/// when something needs to wait on several children at once.
pub fn waitFor(child: *Thread) i32 {
    while (true) {
        const flags = hal.saveAndDisableInterrupts();
        if (child.state == .dead) {
            const status = child.exit_status;
            child.awaited = false;
            reap(child);
            hal.restoreInterrupts(flags);
            return status;
        }
        hal.restoreInterrupts(flags);
        sleepMicros(2_000);
    }
}

/// Create a thread whose status will be collected by its parent.
pub fn spawnAwaited(
    name: []const u8,
    priority: Priority,
    entry: *const fn (usize) callconv(.c) void,
    arg: usize,
    stack_size: usize,
) SpawnError!*Thread {
    const t = try create(name, priority, entry, arg, stack_size);
    t.awaited = true;

    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    active.push(t);
    return t;
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

    // Address space before stack: the incoming thread's kernel stack is mapped
    // in every space, but its user memory is only mapped in its own.
    if (target.space.pd_phys != 0 and target.space.pd_phys != active_space) {
        target.space.activate();
        active_space = target.space.pd_phys;
    }

    // Tell the CPU which kernel stack to use when this thread next traps.
    // Without this the value is whatever the last process to enter user mode
    // set, and a syscall lands on a stack belonging to a thread that may have
    // exited and had its memory reused.
    hal.setKernelStack(@intFromPtr(target.stack.ptr) + target.stack.len);

    if (prev) |p| {
        hal.saveFpu(&p.fpu);
        hal.switchContext(&p.sp, target.sp);
    } else {
        // First switch of all: no outgoing context worth saving, but the
        // architecture still needs somewhere to write it.
        var discard: usize = 0;
        hal.switchContext(&discard, target.sp);
    }

    // Execution resumes here as whichever thread was switched *to*, so the
    // state restored is its own.
    if (current) |c| hal.restoreFpu(&c.fpu);

    // A thread someone is waiting on keeps its stack and its status until
    // collected; freeing it here would destroy both.
    if (prev) |p| {
        if (p.state == .dead and !p.awaited) reap(p);
    }
}

/// Free a dead thread's resources. Runs on the *next* thread's stack, which is
/// why it cannot happen inside `exit`: a thread cannot free the stack it is
/// standing on.
fn reap(t: *Thread) void {
    // Anything still open would otherwise keep a mount busy forever.
    t.handles.closeAll();

    const gpa = heap.allocator;
    gpa.free(t.stack);
    gpa.destroy(t);
}

/// Called from the timer interrupt. Only accounting here — the actual switch
/// happens at interrupt exit, after the controller has been acknowledged.
pub fn onTick() void {
    if (!started) return;
    if (current) |t| {
        t.cpu_ticks += 1;
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

pub fn cwd() []const u8 {
    const t = current orelse return "/";
    return t.cwd_buf[0..t.cwd_len];
}

pub fn setCwd(path: []const u8) bool {
    const t = current orelse return false;
    if (path.len == 0 or path.len > t.cwd_buf.len) return false;
    @memcpy(t.cwd_buf[0..path.len], path);
    t.cwd_len = path.len;
    return true;
}

/// A child starts where its parent was, which is what makes `cd` then run a
/// program behave the way anyone expects.
pub fn inheritCwd(child: *Thread) void {
    const t = current orelse return;
    @memcpy(child.cwd_buf[0..t.cwd_len], t.cwd_buf[0..t.cwd_len]);
    child.cwd_len = t.cwd_len;
}

/// Snapshot of one thread, for reporting.
pub const Snapshot = struct {
    id: u32,
    name: []const u8,
    state: State,
    priority: u8,
    cpu_ticks: u64,
    is_current: bool,
};

/// Walk every live thread.
///
/// Iterating the queues rather than keeping a separate list: the queues already
/// hold every runnable thread, and a second list would be one more thing to
/// keep consistent for the sake of a report nobody reads in a hot loop.
pub fn forEachThread(context: anytype, comptime visit: fn (@TypeOf(context), Snapshot) void) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    if (current) |t| visit(context, snapshotOf(t, true));

    for (&queues) |*q| {
        for (&q.levels) |*level| {
            var node = level.head;
            while (node) |t| : (node = t.next) {
                if (t == current) continue;
                visit(context, snapshotOf(t, false));
            }
        }
    }

    var sleeper = sleepers;
    while (sleeper) |t| : (sleeper = t.next) {
        if (t == current) continue;
        visit(context, snapshotOf(t, false));
    }

    if (idle_thread) |t| {
        if (t != current) visit(context, snapshotOf(t, false));
    }
}

fn snapshotOf(t: *const Thread, is_current: bool) Snapshot {
    return .{
        .id = t.id,
        .name = t.name,
        .state = t.state,
        .priority = t.priority,
        .cpu_ticks = t.cpu_ticks,
        .is_current = is_current,
    };
}

pub fn totalTicks() u64 {
    return switch_count;
}
