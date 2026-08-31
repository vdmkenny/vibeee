//! O(1) scheduler.
//!
//! Two arrays of per-priority run queues, active and expired, plus a bitmap
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

const event_mod = @import("event.zig");
const hal = @import("hal.zig");
const heap = @import("heap.zig");
const ports = @import("ports.zig");
const input = @import("input.zig");
const queue = @import("sched/queue.zig");
const thread_mod = @import("sched/thread.zig");
const console = @import("console.zig");
const wait = @import("wait.zig");

pub const Thread = thread_mod.Thread;
pub const State = thread_mod.State;
pub const Priority = thread_mod.Priority;
pub const PRIORITY_LEVELS = thread_mod.PRIORITY_LEVELS;

const sliceFor = thread_mod.sliceFor;

/// The run queues themselves live in `sched/queue.zig`, generic over the node
/// type so they can be unit-tested on the host, which is where the intrusive
/// double-push that once corrupted them is now covered.
const RunQueues = queue.Levels(Thread, PRIORITY_LEVELS);
const Queue = queue.Fifo(Thread);

var queues: [2]RunQueues = .{ .{}, .{} };
var active: *RunQueues = &queues[0];
var expired: *RunQueues = &queues[1];

var sleepers: ?*Thread = null;

/// Threads that have exited with nobody to collect them, waiting to be freed.
///
/// Freeing cannot happen in `exit`: a thread cannot free the stack it is
/// standing on. Nor immediately after the context switch, where the code runs
/// in the *resumed* thread's frame and `prev` names whatever that thread last
/// switched away from rather than the corpse. So the corpse is queued here and
/// collected at the top of a later `schedule`, by which point it is provably
/// off the CPU.
///
/// Linked through `next`, which a dead thread no longer needs for a run queue.
var to_reap: ?*Thread = null;

var current: ?*Thread = null;
var idle_thread: ?*Thread = null;
var next_id: u32 = 1;
var thread_count: usize = 0;
var switch_count: u64 = 0;
var started = false;

/// Whether the scheduler is running. The answer decides how a delay is made:
/// before `start` there is nothing to sleep on, so the only wait is a bounded
/// spin; after it, a wait sleeps and costs no CPU.
pub fn running() bool {
    return started;
}

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
    active.push(t, t.priority);

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
    thread_mod.register(t);
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
        // Claims that would otherwise outlive their claimant. The keyboard is
        // the one that matters: leaving it claimed by a dead process gives the
        // shell no input at all.
        if (input.keyOwner() == t.id) input.releaseKeys();

        // Stop claimed PCI functions before DMA handles can return their
        // frames to the allocator. Without an IOMMU, reversing this order lets
        // a dead device write into memory already handed to another process.
        @import("probe.zig").dropClaims(t.id);

        // Handles are a claim of the same kind, and they go here rather than
        // with the rest of the corpse. A pipe ends when its last writer closes,
        // and a writer that has exited has closed: leaving its handles open
        // until somebody collects the body means a reader waits not for the
        // writer to finish but for a third party to notice that it did, which
        // is a wait that need never end.
        t.handles.closeAll();
        if (find(t.parent_id)) |p| {
            _ = p.child_exit.wakeAll();
            // Interrupts are already off here, which is what `signalLocked`
            // is for.
            if (p.child_event) |ready| ready.signalLocked();
        }
        orphanChildren(t);
    }
    schedule();
    unreachable; // a dead thread is never rescheduled
}

/// The first userspace process. Orphans are re-parented onto it, and it is
/// expected to collect them, the arrangement every Unix uses, for the reason
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
/// its problem and it will reap them. If there is no `init`, early boot, or
/// `init` itself exiting, they are marked uncollectable instead, so the
/// scheduler frees each one the moment it dies rather than leaving a zombie
/// with no possible parent.
fn orphanChildren(parent: *Thread) void {
    const adopter: ?*Thread = if (init_id != 0 and init_id != parent.id) find(init_id) else null;
    const adopter_alive = if (adopter) |a| a.state != .dead else false;

    var node = thread_mod.first();
    while (node) |t| {
        const next_node = t.all_next;
        // `init` itself is a child of whichever kernel thread started it, and
        // adopting it onto itself would make it its own parent, a one-node
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
        var node = thread_mod.first();
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
        // `wait.block` has nowhere to report a refusal to block, so the caller
        // checks. Stopping the wait leaves the child an orphan, which init
        // adopts like any other.
        if (currentKilled()) {
            child.awaited = false;
            return KILLED_STATUS;
        }
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
    active.push(t, t.priority);
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
/// satisfies still ends. Interrupts must already be disabled by the caller,
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
    active.push(t, t.priority);
    // A woken IRQ owner can be the only path to acknowledging a deferred
    // level interrupt, and completion held at the controller should be held
    // for the wake, not for the rest of a tick.
    need_resched = true;
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
            active.push(t, t.priority);
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
    // it hands out the same thread forever, which looks like sleeps returning
    // instantly, and then like a hang.
    if (prev) |t| {
        switch (t.state) {
            .running, .ready => {
                t.state = .ready;
                // Out of slice: to the expired array, refilled. Otherwise it
                // keeps its remaining slice and stays in the current epoch.
                if (t.slice_left == 0) {
                    t.slice_left = sliceFor(t.priority);
                    expired.push(t, t.priority);
                } else {
                    active.push(t, t.priority);
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
    console.tracePid(target.id);

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
    applyIoBitmap(target);

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
/// still on the list, and the next `schedule`, made by some other thread
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
    if (t.child_event) |ready| {
        event_mod.release(ready);
        t.child_event = null;
    }

    if (t.ports) |set| {
        heap.allocator.destroy(set);
        t.ports = null;
        // The next allocation could land on the same address, so a stale owner
        // would skip the copy and leave a process with someone else's ports.
        if (io_bitmap_owner == t) io_bitmap_owner = null;
    }

    dequeueCorpse(t);

    // The address space goes here rather than at the waiting parent, so a
    // process whose parent never collects it still gives its memory back. Safe
    // because `schedule` has already loaded the incoming thread's page
    // directory by the time this runs: the space being freed is not the one
    // the CPU is standing on.
    if (t.space.pd_phys != 0 and t.space.pd_phys != hal.kernelAddressSpace().pd_phys) {
        t.space.destroy();
    }

    thread_mod.unregister(t);

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

/// Whose grants are currently in the machine's I/O bitmap.
///
/// Remembered across a switch to a process with no grants, so returning to a
/// driver server costs a store rather than eight kilobytes. Cleared when that
/// process dies, since the next one to be allocated could land on the same
/// address.
var io_bitmap_owner: ?*Thread = null;

fn applyIoBitmap(target: *Thread) void {
    const set = target.ports orelse {
        hal.denyIoPorts();
        return;
    };

    if (io_bitmap_owner == target) {
        hal.enableIoBitmap();
        return;
    }

    hal.loadIoBitmap(set.bytes());
    io_bitmap_owner = target;
}

/// The port set a thread is granted in, created on first use.
///
/// Not put into effect here: the caller is about to change it, and a copy
/// taken before that would be a copy of the denials it is removing.
pub fn portsFor(t: *Thread) ?*ports.PortSet {
    if (t.ports) |existing| return existing;

    const set = heap.allocator.create(ports.PortSet) catch return null;
    set.* = .{};
    t.ports = set;
    return set;
}

/// Put a thread's grants into effect, after they have been changed.
pub fn reloadPorts(t: *Thread) void {
    const set = t.ports orelse return;
    hal.loadIoBitmap(set.bytes());
    io_bitmap_owner = t;
}

/// What the running thread is called, for a message about it.
pub fn currentName() []const u8 {
    const t = current orelse return "the kernel";
    return t.name();
}

pub const find = thread_mod.find;

/// Ask a thread to end.
///
/// Marks rather than terminates. A thread part way through a syscall holds
/// kernel state on its own stack, waiter nodes, an in-flight call record, and
/// tearing it down from the outside would abandon all of it. Marked, it dies
/// on its own next return to userspace, having unwound everything the ordinary
/// way. One that is blocked or sleeping is woken so that return happens now
/// rather than whenever the thing it was waiting for arrives.
pub fn kill(id: u32) error{ NotFound, Refused }!void {
    const t = find(id) orelse return error.NotFound;
    if (t.state == .dead) return error.NotFound;

    // `init` adopts orphans, and the idle thread is what runs when nothing
    // else can. Neither has a replacement.
    if (t.id == init_id) return error.Refused;
    if (idle_thread) |idle| {
        if (t == idle) return error.Refused;
    }
    // A kernel thread has no return to userspace, which is the only place the
    // flag is acted on. Accepting would report a success that never happens.
    if (t.space.pd_phys == 0) return error.Refused;

    t.killed = true;
    unblock(t);
}

/// Whether the running thread has been asked to end.
pub fn currentKilled() bool {
    const t = current orelse return false;
    return t.killed;
}

/// Whether a thread with this id still exists and has not exited.
///
/// A dead thread stays findable until its corpse is collected, which is why
/// "exists" alone would not do: the whole point of the question is usually
/// to let go of something that was released by an exit.
pub fn threadAlive(id: u32) bool {
    const t = find(id) orelse return false;
    return t.state != .dead;
}

/// End every userspace thread except `self`, and wait for them to go.
///
/// The shutdown sequence: services and driver processes hold resources that
/// only exit releases: interrupt lines, device claims, DMA memory, the
/// display, so the machine is stopped by stopping them, one tidy exit at a
/// time, rather than by pulling the floor out from under them. Killing is one
/// pass and exiting is another: a blocked thread only learns it is dead once
/// it is woken, and only acts on it at its next return to userspace.
///
/// Waiting sleeps rather than spins, and is bounded: a thread that will not
/// unwind must not become a shutdown that never ends.
///
/// Returns how many were left behind when the deadline ran out, which is
/// worth saying rather than assuming zero.
pub fn stopAllBut(self_id: u32) usize {
    const deadline = deadlineIn(STOP_DEADLINE_US);
    var left = killSweep(self_id);
    while (left > 0 and hal.monotonicMicros() < deadline) {
        sleepMicros(5_000);
        // A thread that had not yet noticed its end could have started one
        // last child in the meantime; swept again so nothing slips out of
        // the shutdown.
        left = killSweep(self_id);
    }
    return left;
}

/// Mark every remaining userspace thread except `self_id`, and say how many
/// are still waiting to unwind. Idempotent: the sweep may run again while
/// the first round is still exiting.
fn killSweep(self_id: u32) usize {
    var left: usize = 0;
    var node = thread_mod.first();
    while (node) |t| : (node = t.all_next) {
        if (t.state == .dead or t.id == self_id) continue;
        // Kernel threads have no return to userspace, which is the only
        // place the flag is acted on; the idle thread must live.
        if (t.space.pd_phys == 0) continue;
        if (idle_thread) |idle| {
            if (t == idle) continue;
        }
        left += 1;
        if (!t.killed) {
            t.killed = true;
            unblock(t);
        }
    }
    return left;
}

/// How long a shutdown waits for the last services to exit.
const STOP_DEADLINE_US = 2_000_000;

/// The names of the userspace threads still with us, excluding `self_id`,
/// which is who a shutdown names when some would not leave.
pub fn liveThreadNames(self_id: u32, into: [][]const u8) usize {
    var n: usize = 0;
    var node = thread_mod.first();
    while (node) |t| : (node = t.all_next) {
        if (t.state == .dead or t.id == self_id) continue;
        if (t.space.pd_phys == 0) continue;
        if (idle_thread) |idle| {
            if (t == idle) continue;
        }
        if (n < into.len) into[n] = t.name();
        n += 1;
    }
    return n;
}

/// Called from the timer interrupt. Only accounting here, the actual switch
/// happens at interrupt exit, after the controller has been acknowledged.
/// Whether `id` is `ancestor` or one of its descendants, by the parent
/// chain. Bounded: a chain deeper than the thread table is a cycle.
pub fn descendsFrom(id: u32, ancestor: u32) bool {
    var at = id;
    var hops: u8 = 0;
    while (hops < 32) : (hops += 1) {
        if (at == ancestor) return true;
        const t = find(at) orelse return false;
        if (t.parent_id == 0) return false;
        at = t.parent_id;
    }
    return false;
}

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
///
/// `from_user` says whether the interrupted code was Ring 3. It is the only
/// moment a thread is known to hold no kernel state, which makes it the one
/// place a thread interrupted in a loop that never syscalls can be ended.
pub fn onInterruptExit(from_user: bool) void {
    if (!started) return;
    if (from_user and currentKilled()) exitWith(KILLED_STATUS);
    if (!need_resched) return;
    // A line being rendered finishes first. `need_resched` stays set, so the
    // switch happens at the next interrupt after the hold is released.
    if (no_preempt) return;
    schedule();
}

/// Held while the console renders one write, so two processes' lines come out
/// whole rather than interleaved mid-word. One core, so a flag is the whole
/// mechanism: the holder is the running thread, and nothing else runs until
/// it clears the flag.
pub var no_preempt: bool = false;

/// What a killed process reports to whoever waits for it.
///
/// 128 plus the number the same fate carries elsewhere, which is the long
/// standing convention and, more importantly here, keeps it positive: `spawn`
/// returns the child's status and an error in the same signed word, so a
/// negative status would be indistinguishable from a spawn that never
/// happened.
pub const KILLED_STATUS: i32 = 128 + 9;

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
/// collected, a supervisor's job is largely about those, so hiding them from
/// the one tool that lists threads would be the wrong economy.
pub fn forEachThread(context: anytype, comptime visit: fn (@TypeOf(context), Snapshot) void) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    var node = thread_mod.first();
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
