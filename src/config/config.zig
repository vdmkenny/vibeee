//! Image configuration: the options, presets, `.config` files, the plan of
//! what an image holds, and the menu editor behind `make menuconfig`.
//!
//! Host code, used by `tools/imageconfig.zig`. `build.zig` reads the processor
//! list from `lib`.

pub const options = @import("options.zig");
pub const presets = @import("presets.zig");
pub const dotconfig = @import("dotconfig.zig");
pub const plan = @import("plan.zig");
pub const keys = @import("keys.zig");
pub const screen = @import("screen.zig");
pub const menu = @import("menu.zig");

test {
    _ = @import("options.zig");
    _ = @import("presets.zig");
    _ = @import("dotconfig.zig");
    _ = @import("plan.zig");
    _ = @import("keys.zig");
    _ = @import("screen.zig");
    _ = @import("menu.zig");
}
