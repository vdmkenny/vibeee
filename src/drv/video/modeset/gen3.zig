//! Intel gen3 display engine: GMA 900/950/3150.
//!
//! Read-only. Nothing here programs a mode yet. What it does is report what
//! firmware left in the display registers, which on this generation is the
//! only trustworthy source for the panel's real timings: the machine boots
//! with a mode already set, and the registers that hold it are the same ones a
//! native modeset has to write.
//!
//! Reading is safe in a way that writing is not. A wrong offset here shows an
//! implausible value on screen; a wrong offset in a modeset leaves a panel
//! dark on a machine whose only diagnostic is that panel.

const std = @import("std");
const hal = @import("../../../kernel/hal.zig");
const pci = @import("../../bus/pci.zig");
const probe = @import("../../../kernel/probe.zig");

/// The 915, 945 and Pineview families.
///
/// One family for modeset purposes. They differ in clock limits and in where a
/// few registers moved, not in the shape of programming a pipe, a PLL and a
/// plane, which is why the driver they all share upstream is one driver.
pub const devices = [_]u16{
    0x2592, // 915GM, Eee PC 701 and 900
    0x2792, // 915GMS
    0x27A2, // 945GM
    0x27AE, // 945GSE, Eee PC 901/1000, Aspire One AOA110/150, HP Mini 110
    0xA011, // Pineview M, Eee PC 1001PX/1015, Aspire One D255, HP Mini 210
    0xA012, // Pineview M, second id
};

pub fn fits(dev: probe.Device) probe.Confidence {
    if (dev.vendor != 0x8086) return .no;
    for (devices) |id| {
        if (dev.device == id) return .exact;
    }
    return .no;
}

/// The MMIO window is 512 KiB on this generation.
const MMIO_BYTES: usize = 512 * 1024;

/// Display registers, by the names the hardware documentation uses.
///
/// Pipe B's timing block sits one 0x1000 page above pipe A's, and its plane
/// one above pipe A's plane, which is why both are listed rather than
/// computed: on a laptop the panel may hang off either pipe, and which one it
/// is has to be read rather than assumed.
const Register = struct { name: []const u8, offset: u32 };

const registers = [_]Register{
    .{ .name = "dpll_a", .offset = 0x06014 },
    .{ .name = "fp_a0", .offset = 0x06040 },
    .{ .name = "dpll_b", .offset = 0x06018 },
    .{ .name = "fp_b0", .offset = 0x06048 },

    .{ .name = "htotal_a", .offset = 0x60000 },
    .{ .name = "hblank_a", .offset = 0x60004 },
    .{ .name = "hsync_a", .offset = 0x60008 },
    .{ .name = "vtotal_a", .offset = 0x6000C },
    .{ .name = "vblank_a", .offset = 0x60010 },
    .{ .name = "vsync_a", .offset = 0x60014 },
    .{ .name = "src_a", .offset = 0x6001C },

    .{ .name = "htotal_b", .offset = 0x61000 },
    .{ .name = "hblank_b", .offset = 0x61004 },
    .{ .name = "hsync_b", .offset = 0x61008 },
    .{ .name = "vtotal_b", .offset = 0x6100C },
    .{ .name = "vblank_b", .offset = 0x61010 },
    .{ .name = "vsync_b", .offset = 0x61014 },
    .{ .name = "src_b", .offset = 0x6101C },

    .{ .name = "conf_a", .offset = 0x70008 },
    .{ .name = "conf_b", .offset = 0x71008 },

    .{ .name = "dspacntr", .offset = 0x70180 },
    .{ .name = "dspabase", .offset = 0x70184 },
    .{ .name = "dspastride", .offset = 0x70188 },
    .{ .name = "dspbcntr", .offset = 0x71180 },
    .{ .name = "dspbbase", .offset = 0x71184 },
    .{ .name = "dspbstride", .offset = 0x71188 },

    .{ .name = "lvds", .offset = 0x61180 },
    .{ .name = "pfit_ctl", .offset = 0x61230 },
    .{ .name = "pfit_ratios", .offset = 0x61234 },
    .{ .name = "pp_status", .offset = 0x61200 },
    .{ .name = "pp_control", .offset = 0x61204 },
    .{ .name = "blc_pwm", .offset = 0x61254 },
    .{ .name = "vgacntrl", .offset = 0x71400 },
};

/// A base address register, decoded far enough to tell the two windows apart.
const Bar = struct {
    raw: u32,

    fn isMemory(self: Bar) bool {
        return self.raw & 1 == 0;
    }

    /// The graphics aperture is prefetchable and the register window is not,
    /// which is how one is told from the other without knowing the part.
    fn prefetchable(self: Bar) bool {
        return self.raw & 0x8 != 0;
    }

    fn base(self: Bar) u32 {
        return self.raw & 0xFFFF_FFF0;
    }
};

/// Report the adapter's base registers and the display block's state.
pub fn inspect(dev: probe.Device, w: *std.Io.Writer) void {
    // The host test build checks the matching table above natively, and has no
    // architecture backend with which to map a device window.
    if (comptime hal.available) readRegisters(dev, w);
}

fn readRegisters(dev: probe.Device, w: *std.Io.Writer) void {
    const addr = pci.Address{
        .bus = @truncate(dev.location[0]),
        .slot = @truncate(dev.location[1]),
        .func = @truncate(dev.location[2]),
    };

    var mmio_base: u32 = 0;
    var i: u8 = 0;
    while (i < 6) : (i += 1) {
        const bar = Bar{ .raw = pci.configRead32(addr, pci.BAR0_OFFSET + i * 4) };
        if (bar.raw == 0) continue;

        w.print("bar{d}     {x:0>8} {s}{s}\n", .{
            i,
            bar.base(),
            if (bar.isMemory()) "mem" else "io",
            if (bar.isMemory() and bar.prefetchable()) " prefetch" else "",
        }) catch {};

        if (mmio_base == 0 and bar.isMemory() and !bar.prefetchable()) {
            mmio_base = bar.base();
        }
    }

    if (mmio_base == 0) {
        w.print("no register window among the base registers\n", .{}) catch {};
        return;
    }

    // Uncached: these are device registers, and a cached read would answer
    // from a line fetched at some earlier moment rather than from the hardware.
    const virt = hal.mapMmio(mmio_base, MMIO_BYTES, .uncached) catch {
        w.print("register window at {x:0>8} could not be mapped\n", .{mmio_base}) catch {};
        return;
    };

    for (registers) |reg| {
        const at: *volatile u32 = @ptrFromInt(virt + reg.offset);
        w.print("{s}", .{reg.name}) catch {};
        var pad = reg.name.len;
        while (pad < 12) : (pad += 1) w.print(" ", .{}) catch {};
        w.print("{x:0>8}\n", .{at.*}) catch {};
    }
}
