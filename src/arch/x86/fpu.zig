//! FPU and SSE state.
//!
//! The kernel is built without x87 or SSE, but user programs are not: the
//! compiler emits `xorps` and `movaps` to zero and copy structures where the
//! target has SSE, and x87 for floating point where it does not. Without
//! CR4.OSFXSR the SSE instructions raise an invalid-opcode fault.
//!
//! State is saved and restored on every context switch rather than lazily on
//! first use. Lazy switching trades a fault per thread against a copy per
//! switch, and at 512 bytes and roughly a hundred cycles the copy is cheaper
//! than the fault handling would be on a single-core machine that switches a
//! few hundred times a second. It is also much harder to get wrong.

const cpu = @import("cpu.zig");

/// FXSAVE writes 512 bytes and requires 16-byte alignment.
pub const STATE_SIZE = 512;
pub const State = [STATE_SIZE]u8;

/// A valid initial image, captured once from a freshly initialised FPU.
///
/// Needed because FXRSTOR of zeroes is not valid: MXCSR has reserved bits that
/// must be zero and a mask field that must not be, so a new thread cannot
/// simply start with a blank area.
var template: State align(16) = @splat(0);
var available = false;

pub fn enable() void {
    const features = cpu.Features.detect();
    // FXSAVE carries the x87 and MMX state with FXSR alone, which every
    // processor from the Pentium II has. SSE adds its own state to the same
    // area where the processor has it.
    if (!features.fxsr) return;

    var cr0: cpu.Cr0 = @bitCast(cpu.readCr0());
    cr0.emulation = false;
    cr0.monitor_coprocessor = true;
    cr0.task_switched = false;
    cpu.writeCr0(@bitCast(cr0));

    var cr4: cpu.Cr4 = @bitCast(cpu.readCr4());
    cr4.os_fxsr = true;
    // Reserved before SSE: setting it on a Pentium II faults.
    cr4.os_xmm_exceptions = features.sse;
    cpu.writeCr4(@bitCast(cr4));

    asm volatile ("fninit");
    available = true;
    save(&template);
}

pub fn isAvailable() bool {
    return available;
}

pub fn save(state: *State) void {
    if (!available) return;
    asm volatile ("fxsave (%[dst])"
        :
        : [dst] "r" (state),
        : .{ .memory = true });
}

pub fn restore(state: *const State) void {
    if (!available) return;
    asm volatile ("fxrstor (%[src])"
        :
        : [src] "r" (state),
        : .{ .memory = true });
}

/// Give a new thread a valid starting state.
pub fn initState(state: *State) void {
    @memcpy(state, &template);
}
