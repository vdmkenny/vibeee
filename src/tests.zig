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
    // What stands between a stray user pointer and a dead machine. Split from
    // the paging code it belongs to precisely so it can be asked here, against
    // tables built by hand, rather than only on a machine that would stop.
    _ = @import("arch/x86/pagetable.zig");
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
    // Both halves of the terminal key codec, and the proof they are inverses:
    // a key that can be sent and not read is one that works on the machine's
    // own screen and does nothing inside a terminal window.
    _ = @import("user/lib/keys.zig");
    _ = @import("user/lib/console.zig");
    _ = @import("user/lib/table.zig");
    // Every decision about a program image, away from the frames and the
    // mappings it would otherwise take to ask one: the files worth asking
    // about are the ones no linker would produce.
    _ = @import("kernel/elf/plan.zig");
    // The long-name assembler, which is the most exposed parser here: it runs
    // over bytes from whatever medium somebody puts in the machine.
    _ = @import("kernel/fat.zig");
    _ = @import("kernel/ublk.zig");
}
