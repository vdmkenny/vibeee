//! Intel gen3 display engine: GMA 900/950/3150.
//!
//! Firmware brings the panel up before the kernel runs, and on this generation
//! it does the hard parts correctly: the LVDS timing, the clock that feeds it
//! and the panel's power sequence. What it also does is hand the pipe a plane
//! smaller than the panel, stretch it with the panel fitter, and split the
//! display FIFO to suit that arrangement.
//!
//! So this drives what is left rather than programming a mode from nothing:
//! the plane grows to the size the timing already runs, the fitter goes off,
//! and the FIFO is retuned for the wider fetch. The clock and the timing are
//! never touched, and anything that would mean computing a clock is refused: a
//! wrong clock is a dark panel on a machine whose only diagnostic is that
//! panel. The change is then judged by the pipe's own underrun record and
//! undone if the hardware could not feed it, so a refused mode costs a blink
//! rather than a reboot.

const std = @import("std");
const clock = @import("../../../kernel/clock.zig");
const console = @import("../../../kernel/console.zig");
const hal = @import("../../../kernel/hal.zig");
const pci = @import("../../bus/pci.zig");
const probe = @import("../../../kernel/probe.zig");
const sched = @import("../../../kernel/sched.zig");
const modeset = @import("modeset.zig");

const Error = modeset.Error;
const Mode = modeset.Mode;
const Framebuffer = modeset.Framebuffer;

/// The parts of the family, where they differ.
///
/// One family for modeset purposes. They differ in clock limits, in the size
/// of the display FIFO and in where a few registers moved, not in the shape of
/// programming a pipe, a PLL and a plane, which is why the driver they all
/// share upstream is one driver.
const Part = enum {
    i915,
    i945,
    pineview,

    fn of(device: u16) ?Part {
        for (members) |member| {
            if (member.id == device) return member.part;
        }
        return null;
    }

    /// Lines of display FIFO shared by the planes, 64 bytes each, as the
    /// reference drivers count them: 95 on the 915 and 127 on the 945.
    /// Pineview's FIFO is larger than either, and the reference sizes its
    /// self refresh watermark from 512 lines, so the most the split's fields
    /// can name is a safe share for it.
    fn fifoLines(self: Part) u7 {
        return switch (self) {
            .i915 => 95,
            .i945, .pineview => 127,
        };
    }
};

const Member = struct { id: u16, part: Part };

const members = [_]Member{
    .{ .id = 0x2592, .part = .i915 }, // 915GM, Eee PC 701 and 900
    .{ .id = 0x2792, .part = .i915 }, // 915GMS
    .{ .id = 0x27A2, .part = .i945 }, // 945GM
    .{ .id = 0x27AE, .part = .i945 }, // 945GSE, Eee PC 901/1000, Aspire One AOA110/150, HP Mini 110
    .{ .id = 0xA011, .part = .pineview }, // Pineview M, Eee PC 1001PX/1015, Aspire One D255, HP Mini 210
    .{ .id = 0xA012, .part = .pineview }, // Pineview M, second id
};

/// The PCI device ids this backend answers for, derived from the membership
/// table so an id cannot be matched without also naming its part.
pub const devices = blk: {
    var ids: [members.len]u16 = undefined;
    for (members, 0..) |member, i| ids[i] = member.id;
    break :blk ids;
};

/// The register window is 512 KiB on this generation.
const MMIO_BYTES: usize = 512 * 1024;

// ---------------------------------------------------------------------------
// Register layout
// ---------------------------------------------------------------------------

/// One of the two display planes. Each pipe feeds the plane of its own letter,
/// and the FIFO split and the fetch watermarks name the plane, not the pipe.
const Plane = enum { a, b };

/// One pipe's register block, with the plane it feeds.
///
/// The two pipes are identical blocks at different offsets, so which one drives
/// the panel is data rather than a code path. The offsets within a block are
/// written once, in `pipeAt`, and the register dump lists every offset field
/// of this struct, so a register added here is dumped without further
/// ceremony.
const Pipe = struct {
    plane: Plane,
    dsl: u32,
    htotal: u32,
    hblank: u32,
    hsync: u32,
    vtotal: u32,
    vblank: u32,
    vsync: u32,
    src: u32,
    conf: u32,
    stat: u32,
    cntr: u32,
    base: u32,
    stride: u32,
    pos: u32,
    size: u32,
};

/// A pipe from the plane it feeds and the addresses of its timing block and
/// its plane block.
fn pipeAt(plane: Plane, timing: u32, block: u32) Pipe {
    return .{
        .plane = plane,
        .htotal = timing + 0x00,
        .hblank = timing + 0x04,
        .hsync = timing + 0x08,
        .vtotal = timing + 0x0C,
        .vblank = timing + 0x10,
        .vsync = timing + 0x14,
        .src = timing + 0x1C,
        .dsl = block + 0x000,
        .conf = block + 0x008,
        .stat = block + 0x024,
        .cntr = block + 0x180,
        .base = block + 0x184,
        .stride = block + 0x188,
        .pos = block + 0x18C,
        .size = block + 0x190,
    };
}

const pipe_a = pipeAt(.a, 0x60000, 0x70000);
const pipe_b = pipeAt(.b, 0x61000, 0x71000);

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
const DSPARB = 0x70030;
const DSPFW3 = 0x7003C;
const FW_BLC = 0x20D8;
const FW_BLC2 = 0x20DC;
const FW_BLC_SELF = 0x20E0;
const INSTPM = 0x20C0;

/// A register whose top bit enables the block it controls. A pipe, a plane and
/// the panel fitter all put it there.
const Enable = packed struct(u32) {
    _rest: u31,
    on: bool,
};

/// A pipe's status register, as far as this driver reads it. The record is
/// sticky and cleared by writing it back set, so writing the whole register
/// back with the flag raised acknowledges it.
const PipeStat = packed struct(u32) {
    _rest: u31,
    fifo_ran_dry: bool,
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

    fn total(self: Timing) u32 {
        return @as(u32, self.total_less_one) + 1;
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

/// The plane's own displayed size, which is not the pipe's source size and
/// does not hold its halves the same way round: width low, height high.
const PlaneSize = packed struct(u32) {
    width_less_one: u16,
    height_less_one: u16,

    fn of(width: u16, height: u16) PlaneSize {
        return .{ .width_less_one = width - 1, .height_less_one = height - 1 };
    }
};

/// How the FIFO's lines are split: plane A owns the start, the cursor owns the
/// end, and plane B owns whatever lies between.
const Dsparb = packed struct(u32) {
    a_end: u7,
    c_start: u7,
    _rest: u18 = 0,

    /// The whole FIFO to the one plane that fetches. Firmware reserves shares
    /// for both planes and the hardware cursor; the reference gives a disabled
    /// plane exactly nothing, and the cursor is off.
    fn wholeTo(fetching: Plane, lines: u7) Dsparb {
        return switch (fetching) {
            .a => .{ .a_end = lines, .c_start = lines },
            .b => .{ .a_end = 0, .c_start = lines },
        };
    }

    /// The lines a plane owns, read the way the reference reads the split.
    fn share(self: Dsparb, plane: Plane) u7 {
        return switch (plane) {
            .a => self.a_end,
            .b => self.c_start - self.a_end,
        };
    }
};

/// The planes' fetch watermarks: the FIFO level at which refill begins. Too
/// low a level with too slow a memory and the FIFO runs dry mid line.
const FwBlc = packed struct(u32) {
    plane_a: u6,
    _a: u2 = 0,
    /// Fetch eight lines per request rather than one.
    burst_a: bool,
    _b: u7 = 0,
    plane_b: u6,
    _c: u2 = 0,
    burst_b: bool,
    _d: u7 = 0,

    /// The reference's watermark for a plane that fetches nothing.
    const idle: u6 = 1;

    /// The computed level to the plane that fetches, the idle level to the
    /// other, bursts on both.
    fn forFetching(fetching: Plane, mark: u6) FwBlc {
        return .{
            .plane_a = if (fetching == .a) mark else idle,
            .burst_a = true,
            .plane_b = if (fetching == .b) mark else idle,
            .burst_b = true,
        };
    }

    fn level(self: FwBlc, plane: Plane) u6 {
        return switch (plane) {
            .a => self.plane_a,
            .b => self.plane_b,
        };
    }
};

const FwBlc2 = packed struct(u32) {
    cursor: u5,
    _a: u3 = 0,
    burst: bool,
    _b: u23 = 0,
};

const Register = struct { name: []const u8, offset: u32 };

/// The fields of `Pipe` that hold a register offset, by name. The plane tag is
/// the one field that does not.
const pipe_register_names = blk: {
    var names: []const []const u8 = &.{};
    for (std.meta.fields(Pipe)) |field| {
        if (field.type == u32) names = names ++ &[_][]const u8{field.name};
    }
    break :blk names;
};

/// What a pipe contributes to the dump: every register of `Pipe`, named for
/// the pipe it belongs to, derived from the struct so the two cannot drift.
fn pipeRegisters(comptime suffix: []const u8, comptime p: Pipe) [pipe_register_names.len]Register {
    var out: [pipe_register_names.len]Register = undefined;
    inline for (pipe_register_names, 0..) |name, i| {
        out[i] = .{ .name = name ++ suffix, .offset = @field(p, name) };
    }
    return out;
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
    .{ .name = "dsparb", .offset = DSPARB },
    .{ .name = "fw_blc", .offset = FW_BLC },
    .{ .name = "fw_blc2", .offset = FW_BLC2 },
    .{ .name = "fw_self", .offset = FW_BLC_SELF },
    .{ .name = "instpm", .offset = INSTPM },
    .{ .name = "dspfw3", .offset = DSPFW3 },
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
    var out: [6]Bar = undefined;
    for (&out, 0..) |*bar, i| {
        bar.* = @bitCast(pci.configRead32(dev.location, pci.BAR0_OFFSET + @as(u8, @intCast(i)) * 4));
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

/// A value for one of the masked registers, where the high half names which
/// low bits the write may touch and the rest are left alone.
fn masked(bit: u4, on: bool) u32 {
    const b = @as(u32, 1) << bit;
    return (b << 16) | (if (on) b else 0);
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

/// Bits per pixel the plane is driven at. The plane's pixel format is left as
/// firmware programmed it, and every framebuffer this kernel draws is 32 bits
/// deep, so this is the adapter's choice and the only depth it offers.
const BPP: u8 = 32;

/// The depth a request gets, or null when the plane cannot be driven at the
/// depth asked for. A request with no preference gets the adapter's choice.
fn depthFor(want: u8) ?u8 {
    if (want == Mode.adapter_choice or want == BPP) return BPP;
    return null;
}

/// Give the panel the whole plane instead of a scaled part of it.
///
/// Refused unless the request matches the timing already running, because
/// anything else would mean programming a clock. See the note at the top.
pub fn set(dev: probe.Device, want: Mode) Error!Framebuffer {
    if (comptime !hal.available) return error.Unsupported;
    const bpp = depthFor(want.bpp) orelse return error.Unsupported;
    const part = Part.of(dev.device) orelse return error.Unsupported;

    const w = open(dev) orelse return error.Hardware;
    const pipe = panelPipe(w) orelse return error.Hardware;

    if (want.width != read(Timing, w, pipe.htotal).active()) return error.Unsupported;
    if (want.height != read(Timing, w, pipe.vtotal).active()) return error.Unsupported;

    const cntr = read(Enable, w, pipe.cntr);
    if (!cntr.on) return error.Hardware;

    // Everything about to change, saved raw, so a change the hardware rejects
    // can be undone without a reboot.
    const saved = Saved{
        .pfit = read(u32, w, PFIT_CONTROL),
        .dsparb = read(u32, w, DSPARB),
        .size = read(u32, w, pipe.size),
        .pos = read(u32, w, pipe.pos),
        .src = read(u32, w, pipe.src),
        .stride = read(u32, w, pipe.stride),
        .fw_blc = read(u32, w, FW_BLC),
        .fw_blc2 = read(u32, w, FW_BLC2),
        .self_refresh = selfRefreshOn(w, part),
    };

    acknowledgeUnderrun(w, pipe);

    // The plane's geometry registers are not double buffered and the pipe
    // latches its fetch schedule at start, so both stop before the geometry
    // moves, the way the reference drivers do it.
    planeOff(w, pipe, cntr);
    pipeOff(w, pipe);

    // The FIFO machinery before the geometry that raises its demand. Both
    // reference drivers retune it on every mode change; the firmware's
    // settings are sized for the firmware's own smaller plane.
    //
    // Self refresh stays off: the reference found it broken with a linear
    // framebuffer on this part, and ours is always linear. Left on with the
    // firmware's wakeup watermark, the memory sleeps too long for the wider
    // fetch and the plane starves.
    setSelfRefresh(w, part, false);

    // The split and the watermarks name the plane the panel's pipe feeds,
    // whichever one firmware chose.
    const lines = part.fifoLines();
    write(Dsparb, w, DSPARB, Dsparb.wholeTo(pipe.plane, lines));

    const total_khz: u32 = @as(u32, read(Timing, w, pipe.htotal).total()) *
        read(Timing, w, pipe.vtotal).total() * want.refresh / 1000;
    write(FwBlc, w, FW_BLC, FwBlc.forFetching(pipe.plane, watermark(total_khz, lines)));
    write(FwBlc2, w, FW_BLC2, .{ .cursor = 2, .burst = true });

    // Geometry, with nothing fetching. The fitter goes first so the timing's
    // every pixel is the plane's own rather than a scaled copy.
    var fitter = read(Enable, w, PFIT_CONTROL);
    fitter.on = false;
    write(Enable, w, PFIT_CONTROL, fitter);

    const pitch = std.mem.alignForward(u32, @as(u32, want.width) * (bpp / 8), STRIDE_ALIGN);
    write(PlaneSize, w, pipe.size, PlaneSize.of(want.width, want.height));
    write(u32, w, pipe.pos, 0);
    write(Source, w, pipe.src, Source.of(want.width, want.height));
    write(u32, w, pipe.stride, pitch);

    pipeOn(w, pipe);
    planeOn(w, pipe, cntr);

    // A few frames in the new mode before judging it. The record is sticky and
    // a starved plane misses on its first line, so this is generous already.
    var settled: u32 = 0;
    while (settled < 3) : (settled += 1) waitFrame();

    // The pipe judges its own trial: an underrun means the mode cannot be fed
    // and everything goes back, anything else means it holds and stays. The
    // reading is worth reporting only when it convicts, and then in full,
    // because the next person to see it will be on a machine nobody has run
    // this on before.
    const stat = read(PipeStat, w, pipe.stat);
    if (stat.fifo_ran_dry) {
        console.warn("video: fifo ran dry at {d}x{d}; mode put back", .{
            want.width, want.height,
        });
        console.info("video", "native: fwblc {x:0>8} dsparb {x:0>8} self {}, was {x:0>8} {x:0>8}", .{
            read(u32, w, FW_BLC),   read(u32, w, DSPARB),
            selfRefreshOn(w, part), saved.fw_blc,
            saved.dsparb,
        });
        console.info("video", "native: size {x:0>8} src {x:0>8} stride {x:0>8} cntr {x:0>8}", .{
            read(u32, w, pipe.size),   read(u32, w, pipe.src),
            read(u32, w, pipe.stride), read(u32, w, pipe.cntr),
        });
        revert(w, pipe, part, cntr, saved);
        return error.Hardware;
    }

    return .{
        .phys = w.aperture,
        .pitch = pitch,
        .width = want.width,
        .height = want.height,
        .bpp = bpp,
    };
}

/// What `set` changes, as the hardware held it beforehand.
const Saved = struct {
    pfit: u32,
    dsparb: u32,
    size: u32,
    pos: u32,
    src: u32,
    stride: u32,
    fw_blc: u32,
    fw_blc2: u32,
    self_refresh: bool,
};

/// Put back everything `set` changed, around the same plane restart.
fn revert(w: Windows, pipe: Pipe, part: Part, cntr: Enable, saved: Saved) void {
    planeOff(w, pipe, cntr);
    pipeOff(w, pipe);

    write(u32, w, PFIT_CONTROL, saved.pfit);
    write(u32, w, DSPARB, saved.dsparb);
    write(u32, w, pipe.size, saved.size);
    write(u32, w, pipe.pos, saved.pos);
    write(u32, w, pipe.src, saved.src);
    write(u32, w, pipe.stride, saved.stride);
    write(u32, w, FW_BLC, saved.fw_blc);
    write(u32, w, FW_BLC2, saved.fw_blc2);
    setSelfRefresh(w, part, saved.self_refresh);

    pipeOn(w, pipe);
    planeOn(w, pipe, cntr);
    waitFrame();
    acknowledgeUnderrun(w, pipe);
}

/// Disable the plane and let the frame in flight finish. Writing the base
/// register is what arms a plane change.
fn planeOff(w: Windows, pipe: Pipe, cntr: Enable) void {
    var off = cntr;
    off.on = false;
    write(Enable, w, pipe.cntr, off);
    write(u32, w, pipe.base, read(u32, w, pipe.base));
    waitFrame();
}

/// Enable the plane again and arm the change.
fn planeOn(w: Windows, pipe: Pipe, cntr: Enable) void {
    write(Enable, w, pipe.cntr, cntr);
    write(u32, w, pipe.base, read(u32, w, pipe.base));
}

/// Stop the pipe and wait until its scanline counter freezes, which is the
/// hardware's own statement that scanout has ended. The reference does the
/// same before touching geometry: the pipe latches its per-line fetch
/// schedule when it starts, so geometry changed under a running pipe is fed
/// at the old width however the FIFO is tuned.
fn pipeOff(w: Windows, pipe: Pipe) void {
    var conf = read(Enable, w, pipe.conf);
    conf.on = false;
    write(Enable, w, pipe.conf, conf);

    var last = read(u32, w, pipe.dsl);
    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        waitMicros(1_000);
        const now = read(u32, w, pipe.dsl);
        if (now == last) return;
        last = now;
    }
}

/// Start the pipe again and give it a frame to relatch its schedule.
fn pipeOn(w: Windows, pipe: Pipe) void {
    var conf = read(Enable, w, pipe.conf);
    conf.on = true;
    write(Enable, w, pipe.conf, conf);
    waitFrame();
}

/// Clear the sticky underrun record so the next reading is about now.
fn acknowledgeUnderrun(w: Windows, pipe: Pipe) void {
    var stat = read(PipeStat, w, pipe.stat);
    stat.fifo_ran_dry = true;
    write(PipeStat, w, pipe.stat, stat);
}

/// Where the memory controller's display self refresh is switched.
///
/// It moved between the parts, register and bit both. Said once per part, so
/// the reading and the switching cannot come to name different bits: they were
/// two switches over the same three parts, each typing the position again.
const SelfRefresh = struct {
    reg: u32,
    bit: u5,
    /// Whether the register takes a masked write, where the top half says
    /// which bits the bottom half is about. Pineview's is a plain register,
    /// read and written back.
    masked_write: bool,

    fn mask(self: SelfRefresh) u32 {
        return @as(u32, 1) << self.bit;
    }

    fn of(part: Part) SelfRefresh {
        return switch (part) {
            .i915 => .{ .reg = INSTPM, .bit = 12, .masked_write = true },
            .i945 => .{ .reg = FW_BLC_SELF, .bit = 15, .masked_write = true },
            .pineview => .{ .reg = DSPFW3, .bit = 30, .masked_write = false },
        };
    }
};

/// Whether the memory controller's display self refresh is on.
fn selfRefreshOn(w: Windows, part: Part) bool {
    const where = SelfRefresh.of(part);
    return read(u32, w, where.reg) & where.mask() != 0;
}

/// Switch the memory controller's display self refresh.
fn setSelfRefresh(w: Windows, part: Part, on: bool) void {
    const where = SelfRefresh.of(part);
    if (where.masked_write) return write(u32, w, where.reg, masked(@intCast(where.bit), on));

    const now = read(u32, w, where.reg);
    write(u32, w, where.reg, if (on) now | where.mask() else now & ~where.mask());
}

/// A plane's fetch watermark, from the reference's small-buffer method: the
/// lines the panel drains during the memory's worst-case latency, plus a
/// guard, taken from the lines the plane owns. Floored at the burst length
/// and capped at what the field holds.
fn watermark(pixel_khz: u32, fifo_lines: u32) u6 {
    // Five microseconds, the reference's pessimal figure, in tenths.
    const latency = 50;
    const burst = 8;
    const bytes = (pixel_khz * 4 * latency + 9999) / 10000;
    const need = (bytes + 63) / 64 + 2;
    if (fifo_lines <= need + burst) return burst;
    return @intCast(@min(fifo_lines - need, std.math.maxInt(u6)));
}

/// Let a display frame finish.
///
/// The reference drivers wait a flat interval where a vertical blank has to
/// have passed and never poll for one; at sixty hertz this is nearly two
/// frames, so it covers a refresh wherever in the frame it starts. A spin
/// rather than a sleep because a mode is set from early boot, before there is
/// a scheduler to sleep on.
fn waitFrame() void {
    waitMicros(30_000);
}

fn waitMicros(us: u64) void {
    // Sleep when there is something to sleep on: a mode change from userspace
    // must not burn the core for the panel's settle time. Early boot has no
    // scheduler yet, so the bounded spin is the only clock that exists there.
    if (sched.running()) {
        sched.sleepMicros(us);
        return;
    }
    const until = clock.monotonicMicros() + us;
    while (clock.monotonicMicros() < until) {}
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

// ---------------------------------------------------------------------------
// What can be checked without the adapter
// ---------------------------------------------------------------------------

test "a request with no depth preference gets the adapter's choice" {
    try std.testing.expectEqual(@as(?u8, BPP), depthFor(Mode.adapter_choice));
}

test "a request for the depth the plane runs is honoured" {
    try std.testing.expectEqual(@as(?u8, BPP), depthFor(32));
}

test "a request for another depth is refused rather than half honoured" {
    try std.testing.expectEqual(@as(?u8, null), depthFor(16));
    try std.testing.expectEqual(@as(?u8, null), depthFor(24));
}

test "every id the backend answers for names its part" {
    for (devices) |id| try std.testing.expect(Part.of(id) != null);
    try std.testing.expectEqual(@as(?Part, null), Part.of(0xFFFF));
}

test "the FIFO is sized by part" {
    try std.testing.expectEqual(@as(u7, 95), Part.of(0x2592).?.fifoLines());
    try std.testing.expectEqual(@as(u7, 127), Part.of(0x27AE).?.fifoLines());
}

test "the fetching plane owns the whole FIFO and the other plane none" {
    for ([_]Plane{ .a, .b }) |fetching| {
        const split = Dsparb.wholeTo(fetching, 127);
        for ([_]Plane{ .a, .b }) |plane| {
            const expected: u7 = if (plane == fetching) 127 else 0;
            try std.testing.expectEqual(expected, split.share(plane));
        }
    }
}

test "the fetching plane gets the computed watermark and the idle plane the minimum" {
    for ([_]Plane{ .a, .b }) |fetching| {
        const marks = FwBlc.forFetching(fetching, 40);
        for ([_]Plane{ .a, .b }) |plane| {
            const expected: u6 = if (plane == fetching) 40 else FwBlc.idle;
            try std.testing.expectEqual(expected, marks.level(plane));
        }
        try std.testing.expect(marks.burst_a and marks.burst_b);
    }
}

test "the watermark leaves the latency's worth of lines free, within the field's reach" {
    // 800x480 at 60 Hz on the 701: 29.58 MHz, 592 bytes in five microseconds,
    // ten lines plus the guard of two, so the level sits twelve below the
    // share.
    try std.testing.expectEqual(@as(u6, 60 - 12), watermark(29_580, 60));
    // A whole FIFO's share puts the level past what the field can hold, and
    // the field's maximum is what the plane gets.
    try std.testing.expectEqual(@as(u6, std.math.maxInt(u6)), watermark(29_580, 95));
    try std.testing.expectEqual(@as(u6, std.math.maxInt(u6)), watermark(29_580, 127));
    // A share too small to hold the latency's worth is floored at the burst.
    try std.testing.expectEqual(@as(u6, 8), watermark(29_580, 20));
}
