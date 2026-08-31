//! Host-side unit tests.
//!
//! Anything portable, allocators, encoders, table generators, layout algebra
//! is tested natively here, with no emulator and no hardware in the loop. On a
//! project whose target machine has no serial port, pushing as much correctness
//! as possible into this file is what keeps hardware bring-up tractable.


test {
    _ = @import("kernel/bootinfo.zig");
    _ = @import("kernel/klog.zig");
    _ = @import("kernel/ports.zig");
    _ = @import("arch/x86/mtrr.zig");
    _ = @import("drv/video/modeset/modeset.zig");
    // Generic over its node type precisely so it can be tested here, off the
    // hardware: the run queues are where this system's worst bug lived.
    _ = @import("kernel/sched/queue.zig");
    _ = @import("lib");
    _ = @import("qr_test.zig");
    _ = @import("keymap_test.zig");
    _ = @import("user/eterm/vt_test.zig");
    _ = @import("user/eterm/render.zig");
    _ = @import("user/eui/text_test.zig");
    // The toolkit whole, rather than a list of its modules: a list is a
    // second place that has to be kept agreeing with the first, and the way
    // it fails is a module whose tests quietly stop running.
    _ = @import("user/eui/eui.zig");
    _ = @import("user/lib/bindings.zig");
    _ = @import("user/lib/command.zig");
    _ = @import("user/lib/env.zig");
    _ = @import("user/lib/table.zig");
    _ = @import("kernel/ublk.zig");
}
