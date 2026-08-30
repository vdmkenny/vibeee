//! Link root.
//!
//! Exists so the compilation unit is rooted at `src/`, which is what lets
//! `kernel/` and `arch/` import each other. It pulls in the architecture's
//! entry stub; everything else is reached from there.
//!
//! Selecting the entry module by architecture here (rather than in build.zig)
//! keeps the build file free of per-architecture file paths.

const builtin = @import("builtin");

comptime {
    switch (builtin.cpu.arch) {
        .x86 => {
            _ = @import("arch/x86/boot.zig");
            _ = @import("arch/x86/flatboot.zig");
            _ = @import("arch/x86/multiboot.zig");
        },
        .arm, .thumb => {
            // The skeleton of design/12-arm-port.md §4.1: a boot stub that
            // brings up the PL011 and proves the machine speaks. It is not
            // the kernel yet; kmain and the HAL arrive in the later steps.
            _ = @import("arch/arm/boot.zig");
        },
        else => @compileError("vibeee has no entry stub for this architecture"),
    }
}

/// Zig's panic entry point, in the same module that holds the entry stub: a
/// panic before any of the kernel is reachable still has to say something.
/// The x86 answer is the kernel's full panic screen; the arm skeleton's is a
/// line on the serial port.
pub const panic = switch (builtin.cpu.arch) {
    .x86 => @import("kernel/main.zig").panic,
    .arm, .thumb => @import("arch/arm/boot.zig").panic,
    else => @compileError("vibeee has no panic handler for this architecture"),
};
