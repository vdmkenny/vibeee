//! A count of who is holding something the kernel shares.
//!
//! Five kinds of object here outlive the handle that made them: an event, a
//! channel, a shared segment, a pipe and an interrupt line. Each is destroyed
//! when the last holder lets go, and each is let go of from whatever thread
//! happened to close the handle.
//!
//! So the count changes with interrupts off. Two holders letting go from
//! either side of a preemption must not both read the count they started from:
//! one sees two and leaves, the other sees two and leaves, and the object
//! stands with nobody holding it and nobody left to free it. The count is
//! small enough that a lock would cost more than the flag, and no holder keeps
//! it for longer than a handful of instructions.

const hal = @import("hal.zig");

pub const RefCount = struct {
    /// One hold: whoever made the object has it.
    count: u32 = 1,

    /// Take a hold.
    pub fn hold(self: *RefCount) void {
        const flags = hal.saveAndDisableInterrupts();
        defer hal.restoreInterrupts(flags);
        self.holdWithin();
    }

    /// Let one go, answering whether that was the last. What happens then is
    /// the caller's: only it knows what has to be woken, unhooked or freed.
    pub fn drop(self: *RefCount) bool {
        const flags = hal.saveAndDisableInterrupts();
        defer hal.restoreInterrupts(flags);
        return self.dropWithin();
    }

    /// The same two, for a holder already inside its own interrupts-off
    /// region. An object an interrupt handler can reach has to take itself
    /// apart while that handler cannot run, and that is one region across the
    /// count and the teardown rather than two with a gap between them.
    pub fn holdWithin(self: *RefCount) void {
        self.count += 1;
    }

    pub fn dropWithin(self: *RefCount) bool {
        self.count -= 1;
        return self.count == 0;
    }
};
