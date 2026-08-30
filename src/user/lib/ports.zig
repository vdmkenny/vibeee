//! Port I/O, re-exported from the architecture layer.
//!
//! The instructions live in `user/arch/x86/ports.zig`; this keeps the name
//! every driver already imports while the assembly stays where assembly is
//! allowed to be.

const arch = @import("sys").ports;

pub const in8 = arch.in8;
pub const in16 = arch.in16;
pub const in32 = arch.in32;
pub const out8 = arch.out8;
pub const out16 = arch.out16;
pub const out32 = arch.out32;
