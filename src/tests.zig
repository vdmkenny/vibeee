//! Host-side unit tests.
//!
//! Anything portable — allocators, encoders, table generators, layout algebra —
//! is tested natively here, with no emulator and no hardware in the loop. On a
//! project whose target machine has no serial port, pushing as much correctness
//! as possible into this file is what keeps hardware bring-up tractable.

const std = @import("std");

test {
    _ = @import("kernel/bootinfo.zig");
    _ = @import("qr_test.zig");
}
