//! The request to end, for a program that outlives a command.
//!
//! A service is asked to go before it is made to: its supervisor raises the
//! event this hands out, the service finishes what it holds and exits, and
//! only one that has not gone by the supervisor's deadline is ended outright.
//! The event sits in the same `wait_many` as everything else the program
//! listens to, so answering costs nothing until it is asked.

const sys = @import("sys");

/// The event raised when this process is asked to end, or zero when the
/// kernel would not give one, in which case the program is ended when its
/// time comes rather than asked.
pub fn event() u32 {
    const handle = sys.watch(.quit);
    return if (handle < 0) 0 else @intCast(handle);
}
