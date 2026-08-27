//! What the interrupt handler may not do itself.
//!
//! uACPI dispatches a general-purpose event by handing a closure to
//! `uacpi_kernel_schedule_work`, and that closure runs AML. The handler that
//! schedules it is itself running inside the interpreter's dispatch, and the
//! interpreter does not survive being entered from inside itself: the closure
//! has to run later, on the one thread, from the top of the loop.
//!
//! So scheduling queues here, and the serve loop drains. The queue wakes the
//! same `wait_many` the loop already sleeps in.

const log = @import("ulib").log;
const sys = @import("sys");

const Item = struct {
    run: *const fn (?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
};

/// Deep enough for a burst of events; a machine that queues more than this
/// between two turns of the loop is dropping work, and says so.
const DEPTH = 32;

var queued: [DEPTH]Item = undefined;
var first: usize = 0;
var count: usize = 0;
var dropped = false;

/// Signalled on submit, waited on by the serve loop.
pub var event: u32 = 0;

pub fn init() void {
    const handle = sys.eventCreate();
    if (handle >= 0) event = @intCast(handle);
}

/// Called from inside uACPI's dispatch. Queues and wakes; nothing more.
pub fn submit(run: *const fn (?*anyopaque) callconv(.c) void, context: ?*anyopaque) bool {
    if (count == DEPTH) {
        if (!dropped) {
            dropped = true;
            log.warn("platd", "work queue overflow; an event was dropped");
        }
        return false;
    }

    queued[(first + count) % DEPTH] = .{ .run = run, .context = context };
    count += 1;

    if (event != 0) _ = sys.eventSignal(event);
    return true;
}

var draining = false;

/// Run everything waiting. Top of the loop only: the items are AML.
///
/// An item may queue further items; they run in the same pass. A drain that
/// finds a drain already running leaves the work to it.
pub fn drain() void {
    if (draining) return;
    draining = true;
    defer draining = false;

    while (count > 0) {
        const item = queued[first];
        first = (first + 1) % DEPTH;
        count -= 1;
        item.run(item.context);
    }
}
