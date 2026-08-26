//! What a thread *is*, separate from how it is scheduled.
//!
//! The struct, the priority bands, and the registry of every thread that
//! exists. Split from the scheduler because they answer different questions:
//! this file says what state a thread carries and how one is found by id; the
//! scheduler says which one runs next. Keeping them apart is what stopped
//! sched.zig from being the file every change had to touch.
//!
//! The registry includes dead threads that have not been collected. A corpse is
//! on no run queue, so anything searching the queues cannot see one, which is
//! why threads are found through here and not through them.

const std = @import("std");
const hal = @import("../hal.zig");
const handle = @import("../handle.zig");
const shm = @import("../shm.zig");
const wait = @import("../wait.zig");


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
pub fn sliceFor(priority: u8) u8 {
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
    /// scheduler switches to it, without that, a thread resumed after another
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
    /// thread is not freed on exit, it stays as a corpse until collected, or
    /// its status would be gone before anyone could read it.
    awaited: bool = false,
    /// Threads blocked in `waitFor` on this one.
    exit_queue: wait.Queue = .{},

    /// Who spawned this thread, or 0 for one the kernel started itself.
    /// Supervision is the whole reason it is recorded: `init` has to know
    /// which of its children died in order to decide whether to restart it.
    parent_id: u32 = 0,
    /// Where the next mapped shared-memory segment goes in this process's
    /// address space. Per process because the window is per address space.
    shm_window: shm.Mapper = .{},

    /// Woken when any child of *this* thread exits. One queue on the parent
    /// rather than an event per child, because a supervisor waits for whichever
    /// of its children dies first and does not know in advance which that is.
    child_exit: wait.Queue = .{},

    pub fn name(self: *const Thread) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn setName(self: *Thread, text: []const u8) void {
        const n = @min(text.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], text[0..n]);
        self.name_len = n;
    }

};
// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------

/// Every thread that exists, newest first, including dead ones not yet
/// collected. Threads are found by id through this, a supervisor naming a
/// child, a `wait` naming a process, and a corpse is invisible to a search of
/// the run queues, which is exactly when it most needs to be found.
var all: ?*Thread = null;

pub fn register(t: *Thread) void {
    t.all_next = all;
    all = t;
}

pub fn unregister(t: *Thread) void {
    var link = &all;
    while (link.*) |node| {
        if (node == t) {
            link.* = node.all_next;
            return;
        }
        link = &node.all_next;
    }
}

pub fn find(id: u32) ?*Thread {
    var node = all;
    while (node) |t| : (node = t.all_next) {
        if (t.id == id) return t;
    }
    return null;
}

/// Walk every thread. The caller holds interrupts off.
pub fn first() ?*Thread {
    return all;
}
