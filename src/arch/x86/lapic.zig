//! The local APIC.
//!
//! What acknowledges an interrupt once the IOAPIC is delivering them. The
//! 8259s are acknowledged by writing to a port; the LAPIC by writing to a
//! register in its own memory-mapped page, and the two are not
//! interchangeable: acknowledging the wrong one leaves the line asserted and
//! nothing else is ever delivered.
//!
//! Only what interrupt delivery needs. The LAPIC timer, IPIs and the
//! performance counters are all here in hardware and none of them have a
//! caller on a machine with one core.

const cpu = @import("cpu.zig");
const paging = @import("paging.zig");

/// Register offsets, in bytes from the base.
const ID = 0x020;
const VERSION = 0x030;
/// Task priority: which interrupts are allowed through at all.
const TPR = 0x080;
const EOI = 0x0B0;
/// Spurious interrupt vector, whose bit 8 is the software enable.
const SPURIOUS = 0x0F0;

/// The MSR carrying the base address and the hardware enable.
const APIC_BASE_MSR = 0x1B;
const MSR_ENABLE: u64 = 1 << 11;

/// Delivered when an interrupt is withdrawn between being raised and being
/// taken. Needs a vector even though the handler does nothing, and the low
/// four bits must be set on older parts.
pub const SPURIOUS_VECTOR: u8 = 0xFF;

var base: ?[*]volatile u32 = null;

pub fn active() bool {
    return base != null;
}

/// Map the LAPIC and enable it. False if it cannot be reached, in which case
/// the caller stays on the 8259s.
pub fn init(phys: u32) bool {
    if (phys == 0) return false;

    const virt = paging.mapMmio(phys, 0x1000, .uncached) catch return false;
    base = @ptrFromInt(virt);

    // The firmware normally leaves it enabled, but a machine that came out of
    // a mode where it was not would deliver nothing at all.
    const current = cpu.readMsr(APIC_BASE_MSR);
    if (current & MSR_ENABLE == 0) cpu.writeMsr(APIC_BASE_MSR, current | MSR_ENABLE);

    // Accept every priority. There is one core and nothing to defer to.
    write(TPR, 0);
    // Bit 8 is the software enable, which is separate from the one in the MSR
    // and is what actually lets interrupts through.
    write(SPURIOUS, @as(u32, 0x100) | SPURIOUS_VECTOR);
    return true;
}

pub fn id() u8 {
    return @truncate(read(ID) >> 24);
}

/// Acknowledge the interrupt being handled.
pub fn eoi() void {
    write(EOI, 0);
}

fn read(offset: usize) u32 {
    const regs = base orelse return 0;
    return regs[offset / 4];
}

fn write(offset: usize, value: u32) void {
    const regs = base orelse return;
    regs[offset / 4] = value;
}
