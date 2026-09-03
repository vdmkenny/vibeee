//! One operation at a time on a shared resource.
//!
//! Reading or writing a medium can put the calling thread to sleep, and on a
//! card behind a USB reader every one does. Without this, another thread's
//! operation on the same resource runs in the gap and takes whatever state
//! the first was in the middle of changing. A resource is held while it is
//! worked on, and a thread that finds it held waits its turn, oldest first.
//!
//! Not specific to a volume or a mount: `vfs.Mount` holds one for its own
//! metadata, and `bcache.Cache` holds one for the lines several mounts of
//! one disk share, which is exactly the case a per-mount lock cannot cover.

const hal = @import("hal.zig");
const wait = @import("wait.zig");

pub const Error = error{
    /// The caller was asked to end while waiting its turn.
    Ending,
};

pub const Lock = struct {
    held: bool = false,
    waiting: wait.Queue = .{},

    /// Take it, waiting for whoever has it. A thread asked to end while
    /// waiting gets nothing and unwinds, like every other wait.
    pub fn hold(self: *Lock) Error!void {
        const flags = hal.saveAndDisableInterrupts();
        defer hal.restoreInterrupts(flags);
        while (self.held) {
            _ = wait.blockOn(&.{&self.waiting}, null) catch return error.Ending;
        }
        self.held = true;
    }

    pub fn release(self: *Lock) void {
        const flags = hal.saveAndDisableInterrupts();
        defer hal.restoreInterrupts(flags);
        self.held = false;
        _ = self.waiting.wakeOne();
    }
};
