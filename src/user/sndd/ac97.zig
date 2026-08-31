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

/// The bus master window: two engines this driver runs, and the global
/// pair. Each engine's registers sit at a fixed offset from its base.
const ENGINE_PCM_IN: u16 = 0x00;
const ENGINE_PCM_OUT: u16 = 0x10;
const GLOBAL_CONTROL: u16 = 0x2C;
const GLOBAL_STATUS: u16 = 0x30;

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
    mixer_base: u16 = 0,
    bus_base: u16 = 0,
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
    device.mixer_base = @intCast(mixer_bar.base());
    device.bus_base = @intCast(bus_bar.base());

    if (sys.ioportGrant(device.mixer_base, 256) < 0 or
        sys.ioportGrant(device.bus_base, 64) < 0)
    {
        log.fail(name, "the port windows were refused");
        return false;
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
    ports.out32(device.bus_base + GLOBAL_CONTROL, @bitCast(GlobalControl{ .cold_reset = true }));

    if (!pcm.settles(100, 1000, {}, struct {
        fn ready(_: void) bool {
            const status: GlobalStatus = @bitCast(ports.in32(device.bus_base + GLOBAL_STATUS));
            return status.codec_ready;
        }
    }.ready)) {
        log.fail(name, "the codec never reported ready");
        return false;
    }

    // Any write to the reset register returns the mixer to defaults.
    ports.out16(device.mixer_base + @intFromEnum(Mixer.reset), 0);
    ports.out16(device.mixer_base + @intFromEnum(Mixer.master), 0x0000);
    ports.out16(device.mixer_base + @intFromEnum(Mixer.pcm_out), 0x0808);
    // Record from line-in, unity gain: what the emulator loops back and
    // what a bare machine's microphone pin arrives on.
    ports.out16(device.mixer_base + @intFromEnum(Mixer.record_select), 0x0404);
    ports.out16(device.mixer_base + @intFromEnum(Mixer.record_gain), 0x0000);
    return true;
}

fn engineBase(direction: dev.Direction) u16 {
    return device.bus_base + switch (direction) {
        .playback => ENGINE_PCM_OUT,
        .capture => ENGINE_PCM_IN,
    };
}

fn engineWrite8(direction: dev.Direction, register: Engine, value: u8) void {
    ports.out8(engineBase(direction) + @intFromEnum(register), value);
}

fn start(direction: dev.Direction) bool {
    if (!device.opened) return false;
    const base = engineBase(direction);

    // Reset the engine's registers, point it at its list, and mark every
    // descriptor valid: the ring wraps and the service stays ahead of it.
    engineWrite8(direction, .control, @bitCast(Control{ .reset = true }));
    _ = pcm.settles(100, 100, base, struct {
        fn ready(at: u16) bool {
            const control: Control = @bitCast(ports.in8(at + @intFromEnum(Engine.control)));
            return !control.reset;
        }
    }.ready);

    const list: u32 = switch (direction) {
        .playback => device.arena.physOf("out_list"),
        .capture => device.arena.physOf("in_list"),
    };
    ports.out32(base + @intFromEnum(Engine.list_base), list);

    // Silence the buffers so a first period plays nothing rather than
    // stale memory, and mark the whole ring valid: the engine wraps its
    // thirty-two descriptors freely, and `queued` keeps the last-valid
    // mark ahead of the play position so it never catches up and halts.
    switch (direction) {
        .playback => pcm.silence(&device.arena.at.out_frames),
        .capture => pcm.silence(&device.arena.at.in_frames),
    }
    engineWrite8(direction, .last_valid, BDL_ENTRIES - 1);
    device.progress[@intFromEnum(direction)].reset();
    engineWrite8(direction, .control, @bitCast(Control{
        .run = true,
        .completion_interrupt = true,
        .fifo_error_interrupt = true,
    }));
    return true;
}

fn stop(direction: dev.Direction) void {
    if (!device.opened) return;
    engineWrite8(direction, .control, @bitCast(Control{}));
    engineWrite8(direction, .control, @bitCast(Control{ .reset = true }));
}

/// One delivery: read each engine's status, count what completed since
/// last time by the hardware's own index, and acknowledge.
fn irq() dev.Completions {
    if (!device.opened) return .{};
    var done = dev.Completions{};

    inline for ([_]dev.Direction{ .playback, .capture }) |direction| {
        const base = engineBase(direction);
        const status: EngineStatus = @bitCast(ports.in16(base + @intFromEnum(Engine.status)));
        if (status.completed or status.last_valid_done or status.fifo_error) {
            const index = ports.in8(base + @intFromEnum(Engine.current_index));
            const advanced = device.progress[@intFromEnum(direction)].advance(index);
            switch (direction) {
                .playback => done.playback = advanced,
                .capture => done.capture = advanced,
            }
            ports.out16(base + @intFromEnum(Engine.status), @bitCast(EngineStatus.ACK));
        }
    }
    return done;
}

/// The engine may run up to and including this descriptor: the service's
/// free-running fill counter, masked into the thirty-two entry ring. Kept
/// ahead of the play position, so the engine always has somewhere to go.
fn queued(direction: dev.Direction, index: u32) void {
    if (!device.opened) return;
    engineWrite8(direction, .last_valid, @intCast(index % BDL_ENTRIES));
}

fn period(direction: dev.Direction, index: u32) []u8 {
    return switch (direction) {
        .playback => pcm.periodAt(&device.arena.at.out_frames, index),
        .capture => pcm.periodAt(&device.arena.at.in_frames, index),
    };
}

/// The codec's own attenuator: zero is loudest, each step one and a half
/// decibels, bit fifteen mutes. Mapped from percent through the shared
/// volume arithmetic.
fn setMaster(volume: audio.Volume) void {
    if (!device.opened) return;
    if (volume.muted) {
        ports.out16(device.mixer_base + @intFromEnum(Mixer.master), 0x8000);
        return;
    }
    const attenuation: u16 = 0x3F - volume.stepOf(0x3F);
    ports.out16(
        device.mixer_base + @intFromEnum(Mixer.master),
        attenuation << 8 | attenuation,
    );
}
