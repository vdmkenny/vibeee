//! FPU and SSE state.
//!
//! The kernel is built without x87 or SSE, but user programs are not: the
//! compiler emits `xorps` and `movaps` to zero and copy structures, and the GUI
//! blitters will want SSE2 deliberately. Without CR4.OSFXSR set those
//! instructions raise an invalid-opcode fault, which is a confusing way to
//! discover the feature was never enabled.
//!
//! State is saved and restored on every context switch rather than lazily on
//! first use. Lazy switching trades a fault per thread against a copy per
//! switch, and at 512 bytes and roughly a hundred cycles the copy is cheaper
//! than the fault handling would be on a single-core machine that switches a
//! few hundred times a second. It is also much harder to get wrong.

const std = @import("std");
const cpu = @import("cpu.zig");

/// FXSAVE writes 512 bytes and requires 16-byte alignment.
pub const STATE_SIZE = 512;
pub const State = [STATE_SIZE]u8;

/// A valid initial image, captured once from a freshly initialised FPU.
///
/// Needed because FXRSTOR of zeroes is not valid — MXCSR has reserved bits that
/// must be zero and a mask field that must not be — so a new thread cannot
/// simply start with a blank area.
var template: State align(16) = @splat(0);
var available = false;

pub fn enable() void {
    const features = cpu.Features.detect();
    if (!features.fxsr or !features.sse) return;

    asm volatile (
    // CR0: clear EM so SSE is not trapped as emulated, set MP so FWAIT
    // behaves, clear TS so no device-not-available fault on first use.
        \\ movl %%cr0, %%eax
        \\ andl $0xFFFFFFF3, %%eax
        \\ orl  $0x00000002, %%eax
        \\ movl %%eax, %%cr0
        // CR4: OSFXSR enables SSE and FXSAVE; OSXMMEXCPT routes SIMD
        // exceptions to vector 19 rather than an invalid opcode.
        \\ movl %%cr4, %%eax
        \\ orl  $0x00000600, %%eax
        \\ movl %%eax, %%cr4
        \\ fninit
        ::: .{ .eax = true, .memory = true });

    save(&template);
    available = true;
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
