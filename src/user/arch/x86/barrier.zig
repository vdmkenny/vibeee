//! Ordering between plain memory and a device-visible handoff.
//!
//! This chipset is cache coherent and the CPU already keeps the required
//! order; what must be held in place is the compiler, which would otherwise
//! move descriptor writes past the volatile store that hands them over. On
//! another architecture these become real fences, which is why they live in
//! an architecture directory rather than beside the rings that use them.

pub inline fn publish() void {
    asm volatile ("" ::: .{ .memory = true });
}

pub inline fn consume() void {
    asm volatile ("" ::: .{ .memory = true });
}
