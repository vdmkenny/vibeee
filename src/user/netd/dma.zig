//! Ordering between cached descriptor memory and device ownership changes.
//!
//! The fence itself is the architecture's business and lives in
//! `user/arch/x86/barrier.zig`; the names here are the ring code's
//! vocabulary for the two directions of a handoff.

const barrier = @import("sys").barrier;

pub const publish = barrier.publish;
pub const consume = barrier.consume;
