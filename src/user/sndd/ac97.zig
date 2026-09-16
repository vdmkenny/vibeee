//! The AC'97 controller of the Intel chipset line, and the codec on it.
//!
//! Two port windows: the mixer, which is the codec's register file seen
//! through the controller, and the bus master, which runs one DMA engine
//! per stream over a list of buffer descriptors. Both are reached over
//! I/O ports; register names and bits follow the Linux `intel8x0` driver,
//! which is the reference the emulator was written against too.
//!
//! Frames move by descriptor: each entry names one period, the engine
//! interrupts as it finishes each, and the service refills behind it.
//! Nothing polls; the pace of the machine's sound is the pace of these
//! interrupts.

const audio = @import("lib").audio;
const dev = @import("dev.zig");
const log = @import("ulib").log;
const pci = @import("ulib").pci;
const pcm = @import("pcm.zig");
const ports = @import("ulib").ports;
const sys = @import("sys");

pub const name = "ac97";
pub const vendor: u16 = 0x8086;
pub const device_id: u16 = 0x2415;

/// The codec's registers, through the mixer window.
const Mixer = enum(u16) {
    reset = 0x00,
    master = 0x02,
    pcm_out = 0x18,
    record_select = 0x1A,
    record_gain = 0x1C,
};

/// The bus master window's own registers, beside the two engines in it.
const Global = enum(u16) {
    control = 0x2C,
    status = 0x30,
};

/// Where each engine's registers begin in the bus master window.
fn engineOffset(direction: dev.Direction) u16 {
    return switch (direction) {
        .capture => 0x00,
        .playback => 0x10,
    };
}

/// A mixer volume: attenuation per side in steps of one and a half
/// decibels, zero loudest, and a mute over both.
const Volume = packed struct(u16) {
    right: u6 = 0,
    _6: u2 = 0,
    left: u6 = 0,
    _14: u1 = 0,
    muted: bool = false,

    fn both(attenuation: u6) Volume {
        return .{ .left = attenuation, .right = attenuation };
    }
};

/// Where each side records from.
const RecordSource = enum(u3) {
    mic = 0,
    cd = 1,
    video = 2,
    aux = 3,
    line = 4,
    stereo_mix = 5,
    mono_mix = 6,
    phone = 7,
};

const RecordSelect = packed struct(u16) {
    right: RecordSource = .mic,
    _3: u5 = 0,
    left: RecordSource = .mic,
    _11: u5 = 0,
};

/// One engine's registers, relative to its base.
const Engine = enum(u16) {
    /// Physical address of the descriptor list.
    list_base = 0x00,
    current_index = 0x04,
    last_valid = 0x05,
    status = 0x06,
    _remaining = 0x08,
    control = 0x0B,
};

const Control = packed struct(u8) {
    /// RPBM: the engine runs.
    run: bool = false,
    /// RR: reset this engine's registers.
    reset: bool = false,
    last_valid_interrupt: bool = false,
    fifo_error_interrupt: bool = false,
    /// IOCE: interrupt when a descriptor with the flag completes.
    completion_interrupt: bool = false,
    _5: u3 = 0,
};

const EngineStatus = packed struct(u16) {
    halted: bool = false,
    at_last_valid: bool = false,
    last_valid_done: bool = false,
    /// BCIS: a flagged descriptor completed. Write one to clear.
    completed: bool = false,
    fifo_error: bool = false,
    _5: u11 = 0,

    const ACK = EngineStatus{ .last_valid_done = true, .completed = true, .fifo_error = true };
};

const GlobalControl = packed struct(u32) {
    interrupts: bool = false,
    /// Deasserting cold reset is what lets the codec run at all.
    cold_reset: bool = false,
    warm_reset: bool = false,
    shut_off: bool = false,
    _4: u28 = 0,
};

const GlobalStatus = packed struct(u32) {
    _0: u8 = 0,
    /// The primary codec finished its own reset and answers reads.
    codec_ready: bool = false,
    _9: u23 = 0,
};

/// One buffer descriptor: where a period lives and how it announces
/// itself. Length counts sixteen-bit samples, not bytes.
const Descriptor = extern struct {
    address: u32 = 0,
    samples: u16 = 0,
    flags: DescriptorFlags = .{},
};

const DescriptorFlags = packed struct(u16) {
    _0: u14 = 0,
    /// BUP: play zeroes past the end rather than stale memory.
    underrun_pad: bool = false,
    /// IOC: interrupt when this descriptor completes.
    interrupt: bool = false,
};

comptime {
    if (@as(u16, @bitCast(Volume.both(8))) != 0x0808 or @as(u16, @bitCast(Volume{ .muted = true })) != 0x8000) {
        @compileError("the mixer volume bits drifted");
    }
    if (@as(u16, @bitCast(RecordSelect{ .left = .line, .right = .line })) != 0x0404) {
        @compileError("the record select bits drifted");
    }
    if (@sizeOf(Descriptor) != 8) @compileError("a buffer descriptor is eight bytes");
    if (@as(u8, @bitCast(Control{ .run = true })) != 0x01 or
        @as(u8, @bitCast(Control{ .completion_interrupt = true })) != 0x10)
    {
        @compileError("the engine control bits drifted");
    }
    if (@as(u16, @bitCast(EngineStatus{ .completed = true })) != 0x08) {
        @compileError("the engine status bits drifted");
    }
}

/// The engine walks a thirty-two entry descriptor list, its index wrapping
/// at thirty-two whatever the list holds. So the list is always thirty-two
/// long, its entries pointing round-robin at the smaller set of period
/// buffers: four laps of the buffers per lap of the list, and the list
/// never runs off its end.
const BDL_ENTRIES = 32;

const Arena = extern struct {
    out_list: [BDL_ENTRIES]Descriptor align(8) = @splat(.{}),
    in_list: [BDL_ENTRIES]Descriptor align(8) = @splat(.{}),
    out_frames: [dev.PERIODS * dev.PERIOD_FRAMES * 2]i16 = @splat(0),
    in_frames: [dev.PERIODS * dev.PERIOD_FRAMES * 2]i16 = @splat(0),
};

const Device = struct {
    mixer: ports.Window(Mixer) = .{ .base = 0 },
    global: ports.Window(Global) = .{ .base = 0 },
    arena: pcm.Dma(Arena) = undefined,
    opened: bool = false,
    /// One per direction, counting periods from the engine's own index.
    progress: [2]pcm.Progress = .{
        .{ .modulus = BDL_ENTRIES },
        .{ .modulus = BDL_ENTRIES },
    },
};

var device: Device = .{};

pub const ops = dev.PcmOps{
    .open = open,
    .start = start,
    .stop = stop,
    .irq = irq,
    .period = period,
    .queued = queued,
    .setMaster = setMaster,
};

fn open(loc: pci.Location) bool {
    const mixer_bar: pci.IoBar = @bitCast(pci.bar(loc, 0));
    const bus_bar: pci.IoBar = @bitCast(pci.bar(loc, 1));
    if (!mixer_bar.io_space or !bus_bar.io_space) {
        log.fail(name, "the controller's windows are not I/O");
        return false;
    }
    device.mixer = .{ .base = @intCast(mixer_bar.base()) };
    device.global = .{ .base = @intCast(bus_bar.base()) };

    for ([_]struct { base: u16, count: usize }{
        .{ .base = device.mixer.base, .count = 256 },
        .{ .base = device.global.base, .count = 64 },
    }) |window| {
        sys.ioportGrant(window.base, window.count) catch {
            log.fail(name, "the port windows were refused");
            return false;
        };
    }
    pci.enableIoAndMaster(loc);

    device.arena = pcm.Dma(Arena).alloc(name) orelse return false;

    if (!resetCodec()) return false;

    // Fixed at open: every descriptor names the period buffer its index
    // aliases to, always interrupts, and never changes. Only the engine's
    // last-valid mark moves, walked ahead of the play position each period.
    const out_base: u32 = device.arena.physOf("out_frames");
    const in_base: u32 = device.arena.physOf("in_frames");
    const period_bytes: u32 = @intCast(dev.periodBytes());
    for (0..BDL_ENTRIES) |i| {
        const step: u32 = @as(u32, @intCast(i % dev.PERIODS)) * period_bytes;
        device.arena.at.out_list[i] = .{
            .address = out_base + step,
            .samples = dev.PERIOD_FRAMES * 2,
            .flags = .{ .interrupt = true, .underrun_pad = true },
        };
        device.arena.at.in_list[i] = .{
            .address = in_base + step,
            .samples = dev.PERIOD_FRAMES * 2,
            .flags = .{ .interrupt = true },
        };
    }

    device.opened = true;
    log.say(name, .key, "codec ready, 48 kHz stereo");
    return true;
}

/// Deassert cold reset, wait for the codec, and set its analog path to a
/// known loudness: master and PCM at full, unmuted; software owns taste.
fn resetCodec() bool {
    device.global.write(.control, GlobalControl{ .cold_reset = true });

    if (!pcm.settles(100, 1000, {}, struct {
        fn ready(_: void) bool {
            return device.global.read(GlobalStatus, .status).codec_ready;
        }
    }.ready)) {
        log.fail(name, "the codec never reported ready");
        return false;
    }

    // Any write to the reset register returns the mixer to defaults.
    device.mixer.write(.reset, @as(u16, 0));
    device.mixer.write(.master, Volume{});
    // The PCM gain register's zero is gain; eight steps down is unity.
    device.mixer.write(.pcm_out, Volume.both(8));
    // Record from line-in, unity gain: what the emulator loops back and
    // what a bare machine's microphone pin arrives on.
    device.mixer.write(.record_select, RecordSelect{ .left = .line, .right = .line });
    device.mixer.write(.record_gain, Volume{});
    return true;
}

/// One engine's registers, as a window of their own.
fn engine(direction: dev.Direction) ports.Window(Engine) {
    return .{ .base = device.global.base + engineOffset(direction) };
}

fn start(direction: dev.Direction) bool {
    if (!device.opened) return false;
    const registers = engine(direction);

    // Reset the engine's registers, point it at its list, and mark every
    // descriptor valid: the ring wraps and the service stays ahead of it.
    registers.write(.control, Control{ .reset = true });
    _ = pcm.settles(100, 100, registers, struct {
        fn ready(at: ports.Window(Engine)) bool {
            return !at.read(Control, .control).reset;
        }
    }.ready);

    registers.write(.list_base, @as(u32, switch (direction) {
        .playback => device.arena.physOf("out_list"),
        .capture => device.arena.physOf("in_list"),
    }));

    // Silence the buffers so a first period plays nothing rather than
    // stale memory, and mark the whole ring valid: the engine wraps its
    // thirty-two descriptors freely, and `queued` keeps the last-valid
    // mark ahead of the play position so it never catches up and halts.
    pcm.silence(pcm.framesOf(device.arena.at, direction));
    registers.write(.last_valid, @as(u8, BDL_ENTRIES - 1));
    device.progress[@intFromEnum(direction)].reset();
    registers.write(.control, Control{
        .run = true,
        .completion_interrupt = true,
        .fifo_error_interrupt = true,
    });
    return true;
}

fn stop(direction: dev.Direction) void {
    if (!device.opened) return;
    engine(direction).write(.control, Control{});
    engine(direction).write(.control, Control{ .reset = true });
}

/// One delivery: read each engine's status, count what completed since
/// last time by the hardware's own index, and acknowledge.
fn irq() dev.Completions {
    if (!device.opened) return .{};
    var done = dev.Completions{};

    for ([_]dev.Direction{ .playback, .capture }) |direction| {
        const registers = engine(direction);
        const status = registers.read(EngineStatus, .status);
        if (status.completed or status.last_valid_done or status.fifo_error) {
            const index = registers.read(u8, .current_index);
            done.set(direction, device.progress[@intFromEnum(direction)].advance(index));
            registers.write(.status, EngineStatus.ACK);
        }
    }
    return done;
}

/// The engine may run up to and including this descriptor: the service's
/// free-running fill counter, masked into the thirty-two entry ring. Kept
/// ahead of the play position, so the engine always has somewhere to go.
fn queued(direction: dev.Direction, index: u32) void {
    if (!device.opened) return;
    engine(direction).write(.last_valid, @as(u8, @intCast(index % BDL_ENTRIES)));
}

fn period(direction: dev.Direction, index: u32) []u8 {
    return pcm.period(device.arena.at, direction, index);
}

/// The master attenuator: sixty-three steps of one and a half decibels,
/// zero loudest.
const master = audio.Attenuator{ .steps = 0x3F, .quarter_db = 6 };

/// Set the codec's own attenuator: the step the shared volume curve asks
/// for, counted down from loudest, or the mute.
fn setMaster(volume: audio.Volume) void {
    if (!device.opened) return;
    if (volume.muted) return device.mixer.write(.master, Volume{ .muted = true });
    device.mixer.write(.master, Volume.both(@intCast(master.steps - volume.stepOf(master))));
}
