//! Ordering between cached descriptor memory and device ownership changes.
//!
//! The target x86 chipset is cache coherent and already preserves the required
//! CPU ordering. A compiler memory barrier keeps descriptor accesses on the
//! correct side of each MMIO ownership handoff without emitting a full fence.

pub inline fn publish() void {
    asm volatile ("" ::: .{ .memory = true });
}

pub inline fn consume() void {
    asm volatile ("" ::: .{ .memory = true });
}
