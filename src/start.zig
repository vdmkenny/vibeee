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
        else => @compileError("vibeee has no entry stub for this architecture"),
    }
}

pub const panic = @import("kernel/main.zig").panic;
