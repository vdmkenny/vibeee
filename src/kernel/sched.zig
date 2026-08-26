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
const hal = @import("hal.zig");
const handle = @import("handle.zig");
const heap = @import("heap.zig");
const wait = @import("wait.zig");

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
    /// Copied, not borrowed. A thread outlives the caller's stack frame, and
    /// programs are named after a path the loader assembled in a buffer that
    /// is gone by the time anything reads the name back.
    name_buf: [16]u8 = @splat(0),
    name_len: usize = 0,
    state: State = .ready,
    priority: u8,
    slice_left: u8 = 0,
    /// Monotonic microseconds at which a sleeping thread becomes runnable.
    wake_at: u64 = 0,
    stack: []u8,
    /// Intrusive link for whichever queue this thread is on.
    next: ?*Thread = null,
    /// On a run queue right now. See `Queue.push`.
    queued: bool = false,
    /// Link in the registry of every thread that exists. A separate field from
    /// `next` because a thread is on at most one run queue but is always here,
    /// including as a corpse waiting to be collected.
    all_next: ?*Thread = null,

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
    /// Threads blocked in `waitFor` on this one.
    exit_queue: wait.Queue = .{},

    /// Who spawned this thread, or 0 for one the kernel started itself.
    /// Supervision is the whole reason it is recorded: `init` has to know
    /// which of its children died in order to decide whether to restart it.
    parent_id: u32 = 0,
    /// Woken when any child of *this* thread exits. One queue on the parent
    /// rather than an event per child, because a supervisor waits for whichever
    /// of its children dies first and does not know in advance which that is.
    child_exit: wait.Queue = .{},

    pub fn name(self: *const Thread) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn setName(self: *Thread, text: []const u8) void {
        const n = @min(text.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], text[0..n]);
        self.name_len = n;
    }

};

const Queue = struct {
    head: ?*Thread = null,
    tail: ?*Thread = null,

    /// Enqueue, unless the thread is already on a queue.
    ///
    /// The guard is not decoration. These are intrusive lists: a node pushed
    /// twice ends up pointing at itself, and the resulting cycle makes the
    /// scheduler hand out one thread forever. That failure is silent, arrives
    /// far from its cause, and on a machine with no serial port is close to
    /// undiagnosable — so it is made impossible here rather than relied upon
    /// not to happen.
    fn push(self: *Queue, t: *Thread) void {
        if (t.queued) return;
        t.queued = true;
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
        t.queued = false;
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

/// Threads that have exited with nobody to collect them, waiting to be freed.
///
/// Freeing cannot happen in `exit`: a thread cannot free the stack it is
/// standing on. It also cannot happen immediately after the context switch —
/// the code there runs in the *resumed* thread's frame, where `prev` names
/// whatever that thread last switched away from, not the corpse. So the corpse
/// is queued here and collected at the top of a later `schedule`, by which
/// point it is provably off the CPU.
///
/// Linked through `next`, which a dead thread no longer needs for a run queue.
var to_reap: ?*Thread = null;

/// Every thread that exists, newest first, including dead ones not yet
/// collected. Threads are found by id through this — a supervisor naming a
/// child, a `wait` naming a process — and a corpse is invisible to a search
/// of the run queues, which is exactly when it most needs to be found.
var all_threads: ?*Thread = null;

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
        .priority = @intFromEnum(priority),
        .slice_left = sliceFor(@intFromEnum(priority)),
        .stack = stack,
        .sp = hal.initThreadStack(stack, entry, arg, &threadExit),
    };
    t.setName(name);
    t.handles.init();
    t.cwd_buf[0] = '/';
    t.cwd_len = 1;
    t.parent_id = if (current) |c| c.id else 0;
    t.all_next = all_threads;
    all_threads = t;
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
        // A thread nobody will wait for is queued for collection now. One that
        // is awaited stays as a corpse until its parent takes the status.
        if (!t.awaited) {
            t.next = to_reap;
            to_reap = t;
        }
        // Before scheduling away: this thread never runs again, so anything
        // waiting on it must be released now or it never will be.
        _ = t.exit_queue.wakeAll();
        if (find(t.parent_id)) |p| _ = p.child_exit.wakeAll();
        orphanChildren(t);
    }
    schedule();
    unreachable; // a dead thread is never rescheduled
}

/// The first userspace process. Orphans are re-parented onto it, and it is
/// expected to collect them — the arrangement every Unix uses, for the reason
/// every Unix has it: a corpse nobody collects keeps its stack and its status
/// forever, and a supervisor that crashes would otherwise take the memory of
/// everything it started with it.
var init_id: u32 = 0;

pub fn setInit(id: u32) void {
    init_id = id;
}

pub fn initId() u32 {
    return init_id;
}

/// Re-parent this thread's children before it goes.
///
/// If `init` is alive and is not the thread that is dying, the children become
/// its problem and it will reap them. If there is no `init` — early boot, or
/// `init` itself exiting — they are marked uncollectable instead, so the
/// scheduler frees each one the moment it dies rather than leaving a zombie
/// with no possible parent.
fn orphanChildren(parent: *Thread) void {
    const adopter: ?*Thread = if (init_id != 0 and init_id != parent.id) find(init_id) else null;
    const adopter_alive = if (adopter) |a| a.state != .dead else false;

    var node = all_threads;
    while (node) |t| {
        const next_node = t.all_next;
        // `init` itself is a child of whichever kernel thread started it, and
        // adopting it onto itself would make it its own parent — a one-node
        // cycle that no walk of the tree can terminate on.
        if (t.parent_id == parent.id and t != parent and t.id != init_id) {
            if (adopter_alive) {
                t.parent_id = init_id;
                // Already dead: init has to be told, or it will sit waiting for
                // an exit that happened before the adoption.
                if (t.state == .dead) {
                    if (adopter) |a| _ = a.child_exit.wakeAll();
                }
            } else {
                t.parent_id = 0;
                t.awaited = false;
                if (t.state == .dead) reap(t);
            }
        }
        node = next_node;
    }
}

pub const Exited = struct { id: u32, status: i32 };

pub const WaitError = error{
    /// The caller has no child matching the request, now or ever.
    NoChildren,
    TimedOut,
};

/// Collect a child that has exited, blocking until one does.
///
/// `id` of zero means any child, which is what a supervisor wants: it waits for
/// whichever of its services dies first rather than guessing.
pub fn waitChild(id: u32, deadline_us: ?u64) WaitError!Exited {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    const parent = current orelse return error.NoChildren;

    while (true) {
        var live: usize = 0;
        var node = all_threads;
        while (node) |t| : (node = t.all_next) {
            if (t.parent_id != parent.id or t == parent) continue;
            if (id != 0 and t.id != id) continue;

            if (t.state == .dead) {
                const exited = Exited{ .id = t.id, .status = t.exit_status };
                t.awaited = false;
                reap(t);
                return exited;
            }
            live += 1;
        }

        // Nothing to wait for is an answer, not a reason to block forever.
        if (live == 0) return error.NoChildren;

        _ = wait.blockOn(&.{&parent.child_exit}, deadline_us) catch return error.TimedOut;
    }
}

/// Block until `child` exits, then return its status and free it.
pub fn waitFor(child: *Thread) i32 {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    // Checked before blocking, under the same interrupts-off window that the
    // block happens in: a child that exited between the caller deciding to
    // wait and getting here has already emptied its queue.
    while (child.state != .dead) {
        wait.block(&child.exit_queue);
    }

    const status = child.exit_status;
    child.awaited = false;
    reap(child);
    return status;
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

/// A deadline `us` from now, in the form the blocking calls take.
pub fn deadlineIn(us: u64) u64 {
    return hal.monotonicMicros() + us;
}

// ---------------------------------------------------------------------------
// Blocking
//
// The primitives `wait.zig` builds on. They live here rather than there because
// only the scheduler may touch thread state and the run queues; `wait.zig` owns
// the queue discipline and calls in.
// ---------------------------------------------------------------------------

/// Take the calling thread off the run queues until something unblocks it.
///
/// With a deadline it also goes on the sleeper list, so a wait that nobody
/// satisfies still ends. Interrupts must already be disabled by the caller —
/// see the lost-wakeup rule in `wait.zig`.
pub fn blockCurrent(deadline_us: ?u64) void {
    const t = current orelse return;

    if (deadline_us) |deadline| {
        t.state = .sleeping;
        t.wake_at = deadline;
        t.next = sleepers;
        sleepers = t;
    } else {
        t.state = .blocked;
    }

    schedule();
}

/// Make a blocked or sleeping thread runnable again.
///
/// Idempotent: waking a thread that is already runnable is a no-op rather than
/// an error, because two queues can fire for the same waiter in the same
/// interrupts-off window and neither knows about the other.
pub fn unblock(t: *Thread) void {
    switch (t.state) {
        .blocked => {},
        // A thread blocked with a deadline is on the sleeper list, and leaving
        // it there would let `wakeSleepers` push it onto the run queues a
        // second time.
        .sleeping => removeSleeper(t),
        else => return,
    }

    t.state = .ready;
    t.next = null;
    active.push(t);
}

fn removeSleeper(t: *Thread) void {
    var link = &sleepers;
    while (link.*) |s| {
        if (s == t) {
            link.* = s.next;
            return;
        }
        link = &s.next;
    }
}

/// Move any sleeper whose deadline has passed back to the run queues.
fn wakeSleepers(now: u64) void {
    var link = &sleepers;
    while (link.*) |t| {
        if (t.wake_at <= now) {
            // Off the sleeper list before going on a run queue: both are
            // threaded through the same `next` field, so a thread on two lists
            // at once corrupts whichever is walked second.
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
    need_resched = false;
    collectCorpses();

    const prev = current;

    // The outgoing thread is dealt with *before* sleepers are woken, and the
    // order is load-bearing. `wakeSleepers` enqueues whatever is due, and the
    // calling thread is frequently the thread whose own sleep has just
    // elapsed: waking first would leave it `.ready` and already queued, and
    // the branch below would then queue it a second time. A node pushed onto
    // an intrusive list twice links to itself, and a run queue with a cycle in
    // it hands out the same thread forever — which looks like sleeps returning
    // instantly, and then like a hang.
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

    wakeSleepers(hal.monotonicMicros());

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

}

/// Free anything queued by `exitWith`, except whatever is running right now.
///
/// The exclusion matters: a thread that has just exited calls `schedule` from
/// its own stack, and that call must not free it out from under itself. It is
/// still on the list, and the next `schedule` — made by some other thread —
/// collects it.
fn collectCorpses() void {
    var link = &to_reap;
    while (link.*) |t| {
        if (t == current) {
            link = &t.next;
            continue;
        }
        link.* = t.next;
        t.next = null;
        reap(t);
    }
}

/// Free a dead thread's resources. Runs on the *next* thread's stack, which is
/// why it cannot happen inside `exit`: a thread cannot free the stack it is
/// standing on.
fn reap(t: *Thread) void {
    dequeueCorpse(t);

    // Anything still open would otherwise keep a mount busy forever.
    t.handles.closeAll();

    // The address space goes here rather than at the waiting parent, so a
    // process whose parent never collects it still gives its memory back. Safe
    // because `schedule` has already loaded the incoming thread's page
    // directory by the time this runs: the space being freed is not the one
    // the CPU is standing on.
    if (t.space.pd_phys != 0 and t.space.pd_phys != hal.kernelAddressSpace().pd_phys) {
        t.space.destroy();
    }

    unregister(t);

    const gpa = heap.allocator;
    gpa.free(t.stack);
    gpa.destroy(t);
}

/// Take a thread off the collection list, so a parent collecting it directly
/// cannot race the scheduler into a double free.
fn dequeueCorpse(t: *Thread) void {
    var link = &to_reap;
    while (link.*) |node| {
        if (node == t) {
            link.* = node.next;
            return;
        }
        link = &node.next;
    }
}

fn unregister(t: *Thread) void {
    var link = &all_threads;
    while (link.*) |node| {
        if (node == t) {
            link.* = node.all_next;
            return;
        }
        link = &node.all_next;
    }
}

pub fn find(id: u32) ?*Thread {
    var node = all_threads;
    while (node) |t| : (node = t.all_next) {
        if (t.id == id) return t;
    }
    return null;
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
    parent_id: u32,
    name: []const u8,
    state: State,
    priority: u8,
    cpu_ticks: u64,
    is_current: bool,
};

/// Walk every thread, including corpses that have exited but not been
/// collected — a supervisor's job is largely about those, so hiding them from
/// the one tool that lists threads would be the wrong economy.
pub fn forEachThread(context: anytype, comptime visit: fn (@TypeOf(context), Snapshot) void) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    var node = all_threads;
    while (node) |t| : (node = t.all_next) {
        visit(context, snapshotOf(t, t == current));
    }
}

fn snapshotOf(t: *const Thread, is_current: bool) Snapshot {
    return .{
        .id = t.id,
        .parent_id = t.parent_id,
        .name = t.name(),
        .state = t.state,
        .priority = t.priority,
        .cpu_ticks = t.cpu_ticks,
        .is_current = is_current,
    };
}

pub fn totalTicks() u64 {
    return switch_count;
}
