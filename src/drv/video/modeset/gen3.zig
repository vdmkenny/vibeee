//! Intel gen3 display engine: GMA 900/950/3150.
//!
//! Firmware brings the panel up before the kernel runs, and on this generation
//! it does the hard parts correctly: the LVDS timing, the clock that feeds it
//! and the panel's power sequence. What it also does is hand the pipe a plane
//! smaller than the panel and switch the panel fitter on to stretch it.
//!
//! So this drives what is left rather than programming a mode from nothing.
//! Giving the pipe a plane the size of the timing it already runs, and turning
//! the fitter off, is the whole difference between a stretched image and a
//! native one, and it touches neither the clock nor the timing. Anything that
//! would mean computing a clock is refused: a wrong clock is a dark panel on a
//! machine whose only diagnostic is that panel.

const std = @import("std");
const hal = @import("../../../kernel/hal.zig");
const pci = @import("../../bus/pci.zig");
const probe = @import("../../../kernel/probe.zig");
const modeset = @import("modeset.zig");

const Error = modeset.Error;
const Mode = modeset.Mode;
const Framebuffer = modeset.Framebuffer;

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

/// The register window is 512 KiB on this generation.
const MMIO_BYTES: usize = 512 * 1024;

// ---------------------------------------------------------------------------
// Register layout
// ---------------------------------------------------------------------------

/// One pipe's register block.
///
/// The two pipes are identical blocks at different offsets, so which one drives
/// the panel is data rather than a code path. The offsets within a block are
/// written once, in `pipeAt`, and both pipes and the register dump derive from
/// them.
const Pipe = struct {
    htotal: u32,
    hblank: u32,
    hsync: u32,
    vtotal: u32,
    vblank: u32,
    vsync: u32,
    src: u32,
    conf: u32,
    cntr: u32,
    base: u32,
    stride: u32,
    pos: u32,
    size: u32,
};

/// A pipe from the addresses of its timing block and its plane block.
fn pipeAt(timing: u32, plane: u32) Pipe {
    return .{
        .htotal = timing + 0x00,
        .hblank = timing + 0x04,
        .hsync = timing + 0x08,
        .vtotal = timing + 0x0C,
        .vblank = timing + 0x10,
        .vsync = timing + 0x14,
        .src = timing + 0x1C,
        .conf = plane + 0x008,
        .cntr = plane + 0x180,
        .base = plane + 0x184,
        .stride = plane + 0x188,
        .pos = plane + 0x18C,
        .size = plane + 0x190,
    };
}

const pipe_a = pipeAt(0x60000, 0x70000);
const pipe_b = pipeAt(0x61000, 0x71000);

const DPLL_A = 0x06014;
const DPLL_B = 0x06018;
const FP_A0 = 0x06040;
const FP_B0 = 0x06048;
const LVDS = 0x61180;
const PFIT_CONTROL = 0x61230;
const PFIT_RATIOS = 0x61234;
const PP_STATUS = 0x61200;
const PP_CONTROL = 0x61204;
const BLC_PWM = 0x61254;
const VGACNTRL = 0x71400;

/// A register whose top bit enables the block it controls. A pipe, a plane and
/// the panel fitter all put it there.
const Enable = packed struct(u32) {
    _rest: u31,
    on: bool,
};

/// The LVDS port register, as far as this driver reads it.
const Lvds = packed struct(u32) {
    _rest: u30,
    /// Which pipe the port takes its pixels from.
    pipe_b: bool,
    on: bool,
};

/// A timing register: the active region and the whole line or frame, each held
/// as one less than the count.
const Timing = packed struct(u32) {
    active_less_one: u16,
    total_less_one: u16,

    fn active(self: Timing) u32 {
        return @as(u32, self.active_less_one) + 1;
    }
};

/// The plane's source size, held the way a timing register is.
const Source = packed struct(u32) {
    height_less_one: u16,
    width_less_one: u16,

    fn of(width: u16, height: u16) Source {
        return .{ .width_less_one = width - 1, .height_less_one = height - 1 };
    }
};

const Register = struct { name: []const u8, offset: u32 };

/// What a pipe contributes to the dump, named for the pipe it belongs to so
/// one listing covers both.
fn pipeRegisters(comptime suffix: []const u8, comptime p: Pipe) [13]Register {
    return .{
        .{ .name = "htotal" ++ suffix, .offset = p.htotal },
        .{ .name = "hblank" ++ suffix, .offset = p.hblank },
        .{ .name = "hsync" ++ suffix, .offset = p.hsync },
        .{ .name = "vtotal" ++ suffix, .offset = p.vtotal },
        .{ .name = "vblank" ++ suffix, .offset = p.vblank },
        .{ .name = "vsync" ++ suffix, .offset = p.vsync },
        .{ .name = "src" ++ suffix, .offset = p.src },
        .{ .name = "conf" ++ suffix, .offset = p.conf },
        .{ .name = "cntr" ++ suffix, .offset = p.cntr },
        .{ .name = "base" ++ suffix, .offset = p.base },
        .{ .name = "stride" ++ suffix, .offset = p.stride },
        .{ .name = "pos" ++ suffix, .offset = p.pos },
        .{ .name = "size" ++ suffix, .offset = p.size },
    };
}

/// Everything the dump reports, in the order that reads best.
const registers = [_]Register{
    .{ .name = "dpll_a", .offset = DPLL_A },
    .{ .name = "fp_a0", .offset = FP_A0 },
    .{ .name = "dpll_b", .offset = DPLL_B },
    .{ .name = "fp_b0", .offset = FP_B0 },
} ++ pipeRegisters("_a", pipe_a) ++ pipeRegisters("_b", pipe_b) ++ [_]Register{
    .{ .name = "lvds", .offset = LVDS },
    .{ .name = "pfit_ctl", .offset = PFIT_CONTROL },
    .{ .name = "pfit_ratios", .offset = PFIT_RATIOS },
    .{ .name = "pp_status", .offset = PP_STATUS },
    .{ .name = "pp_control", .offset = PP_CONTROL },
    .{ .name = "blc_pwm", .offset = BLC_PWM },
    .{ .name = "vgacntrl", .offset = VGACNTRL },
};

// ---------------------------------------------------------------------------
// Reaching the adapter
// ---------------------------------------------------------------------------

/// A PCI base address register.
const Bar = packed struct(u32) {
    /// Set for a port range, clear for a memory window.
    is_io: bool,
    kind: u2,
    /// The graphics aperture is prefetchable and the register window is not,
    /// which is how one is told from the other without knowing the part.
    prefetchable: bool,
    address: u28,

    fn base(self: Bar) u32 {
        return @as(u32, self.address) << 4;
    }

    fn present(self: Bar) bool {
        return @as(u32, @bitCast(self)) != 0;
    }
};

/// The adapter's base registers, all six, read once.
fn bars(dev: probe.Device) [6]Bar {
    const addr = pci.Address{
        .bus = @truncate(dev.location[0]),
        .slot = @truncate(dev.location[1]),
        .func = @truncate(dev.location[2]),
    };

    var out: [6]Bar = undefined;
    for (&out, 0..) |*bar, i| {
        bar.* = @bitCast(pci.configRead32(addr, pci.BAR0_OFFSET + @as(u8, @intCast(i)) * 4));
    }
    return out;
}

/// The adapter's two windows, found once and kept.
const Windows = struct {
    /// Register window, where the display block lives.
    mmio: usize,
    /// Graphics aperture, which is what the plane reads its pixels from.
    aperture: u32,
};

var windows: ?Windows = null;

/// Decode the base registers, mapping the register window on first use.
fn open(dev: probe.Device) ?Windows {
    if (windows) |w| return w;

    var mmio_phys: ?u32 = null;
    var aperture: ?u32 = null;
    for (bars(dev)) |bar| {
        if (!bar.present() or bar.is_io) continue;
        if (bar.prefetchable) {
            if (aperture == null) aperture = bar.base();
        } else if (mmio_phys == null) {
            mmio_phys = bar.base();
        }
    }

    // Uncached: these are device registers, and a cached read would answer from
    // a line fetched at some earlier moment rather than from the hardware.
    const virt = hal.mapMmio(mmio_phys orelse return null, MMIO_BYTES, .uncached) catch return null;

    windows = .{ .mmio = virt, .aperture = aperture orelse return null };
    return windows;
}

fn read(comptime T: type, w: Windows, offset: u32) T {
    const at: *volatile u32 = @ptrFromInt(w.mmio + offset);
    return @bitCast(at.*);
}

fn write(comptime T: type, w: Windows, offset: u32, value: T) void {
    const at: *volatile u32 = @ptrFromInt(w.mmio + offset);
    at.* = @bitCast(value);
}

/// The pipe the panel is on.
///
/// Read rather than assumed: firmware picks, and it does not always pick the
/// first one.
fn panelPipe(w: Windows) ?Pipe {
    const lvds = read(Lvds, w, LVDS);
    if (lvds.on) return if (lvds.pipe_b) pipe_b else pipe_a;

    if (read(Enable, w, pipe_b.conf).on) return pipe_b;
    if (read(Enable, w, pipe_a.conf).on) return pipe_a;
    return null;
}

// ---------------------------------------------------------------------------
// Driving it
// ---------------------------------------------------------------------------

/// The size the panel's timing already runs at.
///
/// Read from the pipe rather than from a table of machines: a gen3 adapter in
/// a 1024x600 netbook has its own timing programmed the same way this one does,
/// so the panel describes itself and nothing here needs to know which machine
/// it is in.
pub fn native(dev: probe.Device) ?Mode {
    if (comptime !hal.available) return null;

    const w = open(dev) orelse return null;
    const pipe = panelPipe(w) orelse return null;

    return .{
        .width = @intCast(read(Timing, w, pipe.htotal).active()),
        .height = @intCast(read(Timing, w, pipe.vtotal).active()),
    };
}

/// Bytes a plane's stride has to be a multiple of.
const STRIDE_ALIGN: u32 = 64;

/// Give the panel the whole plane instead of a scaled part of it.
///
/// Refused unless the request matches the timing already running, because
/// anything else would mean programming a clock. See the note at the top.
pub fn set(dev: probe.Device, want: Mode) Error!Framebuffer {
    if (comptime !hal.available) return error.Unsupported;
    if (want.bpp != 32) return error.Unsupported;

    const w = open(dev) orelse return error.Hardware;
    const pipe = panelPipe(w) orelse return error.Hardware;

    if (want.width != read(Timing, w, pipe.htotal).active()) return error.Unsupported;
    if (want.height != read(Timing, w, pipe.vtotal).active()) return error.Unsupported;
    if (!read(Enable, w, pipe.cntr).on) return error.Hardware;

    var fitter = read(Enable, w, PFIT_CONTROL);
    fitter.on = false;
    write(Enable, w, PFIT_CONTROL, fitter);

    // Rounded up because the plane's stride has a granularity, which a width
    // that is not a multiple of sixteen pixels would otherwise miss. The extra
    // bytes are padding at the end of each line, which is why a framebuffer's
    // pitch is reported rather than assumed to be its width.
    const pitch = std.mem.alignForward(u32, @as(u32, want.width) * 4, STRIDE_ALIGN);
    write(Source, w, pipe.src, Source.of(want.width, want.height));
    write(u32, w, pipe.stride, pitch);


    // Writing the base arms the plane: the registers above are double buffered
    // and take effect together at the next vertical blank.
    write(u32, w, pipe.base, read(u32, w, pipe.base));

    return .{
        .phys = w.aperture,
        .pitch = pitch,
        .width = want.width,
        .height = want.height,
        .bpp = 32,
    };
}

/// Report the adapter's base registers and the display block's state.
pub fn inspect(dev: probe.Device, out: *std.Io.Writer) void {
    // The host test build checks the matching table above natively, and has no
    // architecture backend with which to map a device window.
    if (comptime hal.available) readRegisters(dev, out);
}

fn readRegisters(dev: probe.Device, out: *std.Io.Writer) void {
    for (bars(dev), 0..) |bar, i| {
        if (!bar.present()) continue;
        out.print("bar{d}     {x:0>8} {s}{s}\n", .{
            i,
            bar.base(),
            if (bar.is_io) "io" else "mem",
            if (!bar.is_io and bar.prefetchable) " prefetch" else "",
        }) catch {};
    }

    const w = open(dev) orelse {
        out.print("no register window among the base registers\n", .{}) catch {};
        return;
    };

    for (registers) |item| {
        out.print("{s}", .{item.name}) catch {};
        var pad = item.name.len;
        while (pad < 12) : (pad += 1) out.print(" ", .{}) catch {};
        out.print("{x:0>8}\n", .{read(u32, w, item.offset)}) catch {};
    }
}
