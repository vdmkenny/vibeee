//! The Ensoniq AudioPCI ES1370 and its AK4531 codec: the PCI sound card of
//! a great many machines of the late nineties, and QEMU's `ES1370`. The
//! register and codec shapes are in `es1370/regs.zig`.
//!
//! One port window. DAC2 plays and the ADC records, each looping over its
//! buffer of periods and interrupting after every period's frames. Both run
//! off one clock divided from 1.4112 MHz, which makes 44.1 kHz exactly and
//! 48 kHz not at all, so this device declares 44.1 kHz and the service
//! converts. Nothing polls: a period is counted from the engine's own place
//! in its buffer when its interrupt comes.

const audio = @import("lib").audio;
const dev = @import("dev.zig");
const log = @import("ulib").log;
const pci = @import("ulib").pci;
const pcm = @import("pcm.zig");
const ports = @import("ulib").ports;
const regs = @import("es1370/regs.zig");
const sys = @import("sys");

pub const name = "es1370";

const RATE = audio.Rate.hz44100;
const DIVIDER = regs.divider(RATE).?;

/// How long a codec write may take to go out: it is clocked serially.
const CODEC_ATTEMPTS = 50;
const CODEC_PAUSE_US = 1_000;

const Arena = extern struct {
    out_frames: [dev.PERIODS * dev.PERIOD_FRAMES * 2]i16 = @splat(0),
    in_frames: [dev.PERIODS * dev.PERIOD_FRAMES * 2]i16 = @splat(0),
    /// Where the chip's phantom frame pointer is kept aimed.
    phantom: [16]u8 = @splat(0),
};

const Device = struct {
    window: ports.Window(regs.Register) = .{ .base = 0 },
    arena: pcm.Dma(Arena) = undefined,
    control: regs.Control = .{},
    serial: regs.Serial = .{},
    opened: bool = false,
    /// One per direction, counting periods from the engine's own place.
    progress: [2]pcm.Progress = @splat(.{ .modulus = dev.PERIODS }),
};

var device: Device = .{};

pub const ops = dev.PcmOps{
    .rate = RATE,
    .open = open,
    .start = start,
    .stop = stop,
    .irq = irq,
    .period = period,
    .queued = queued,
    .setMaster = setMaster,
};

fn engineOf(direction: dev.Direction) regs.Engine {
    return switch (direction) {
        .playback => .dac2,
        .capture => .adc,
    };
}

fn writePaged(register: regs.Paged, value: u32) void {
    device.window.write(.page, @as(u32, @intFromEnum(register.page())));
    device.window.write(register.register(), value);
}

fn readPaged(comptime T: type, register: regs.Paged) T {
    device.window.write(.page, @as(u32, @intFromEnum(register.page())));
    return device.window.read(T, register.register());
}

fn open(loc: pci.Location) bool {
    const bar: pci.IoBar = @bitCast(pci.bar(loc, 0));
    if (!bar.io_space or bar.base() == 0) {
        log.fail(name, "the card's window is not I/O");
        return false;
    }
    device.window = .{ .base = @intCast(bar.base()) };
    sys.ioportGrant(device.window.base, regs.WINDOW_PORTS) catch {
        log.fail(name, "the port window was refused");
        return false;
    };
    pci.enableIoAndMaster(loc);

    device.arena = pcm.Dma(Arena).alloc(name) orelse return false;

    // Everything off, the codec's interface on, the clock at the one rate
    // this driver runs.
    device.control = .{ .codec_enabled = true, .clock_divider = DIVIDER };
    device.serial = .{};
    device.window.write(.control, device.control);
    device.window.write(.serial, device.serial);
    writePaged(.phantom_frame, device.arena.physOf("phantom"));
    writePaged(.phantom_size, 0);

    for (regs.SETUP) |step| {
        if (!codec(step)) {
            log.fail(name, "the codec did not take its setup");
            return false;
        }
    }

    device.opened = true;
    log.say(name, .key, "codec ready, 44.1 kHz stereo");
    return true;
}

/// One codec register, once the one before it has gone out.
fn codec(step: regs.CodecWrite) bool {
    const idle = pcm.settles(CODEC_ATTEMPTS, CODEC_PAUSE_US, {}, struct {
        fn idle(_: void) bool {
            return !device.window.read(regs.Status, .status).codec_pending;
        }
    }.idle);
    if (idle) device.window.write(.codec, step);
    return idle;
}

fn start(direction: dev.Direction) bool {
    if (!device.opened) return false;
    stop(direction);

    const engine = engineOf(direction);
    const frames = pcm.framesOf(device.arena.at, direction);
    pcm.silence(frames);
    writePaged(engine.frame(), pcm.framesAddress(device.arena, direction));
    writePaged(engine.size(), @bitCast(regs.FrameSize.of(@sizeOf(@TypeOf(frames.*)))));

    device.serial.stereo16(engine);
    device.serial.interrupt(engine, true);
    device.window.write(.serial, device.serial);
    device.window.write(engine.count(), regs.Count{ .frames_less_one = dev.PERIOD_FRAMES - 1 });

    device.progress[@intFromEnum(direction)].reset();
    device.control.enable(engine, true);
    device.window.write(.control, device.control);
    return true;
}

fn stop(direction: dev.Direction) void {
    if (!device.opened) return;
    const engine = engineOf(direction);
    device.control.enable(engine, false);
    device.serial.interrupt(engine, false);
    device.window.write(.control, device.control);
    device.window.write(.serial, device.serial);
}

/// One delivery. An engine's interrupt is acknowledged by turning its
/// enable off and on again; the periods it finished are counted from where
/// the engine now is in its buffer.
fn irq() dev.Completions {
    if (!device.opened) return .{};
    const status = device.window.read(regs.Status, .status);
    if (!status.interrupt) return .{};

    device.window.write(.serial, device.serial.quieted(status));
    device.window.write(.serial, device.serial);

    var done = dev.Completions{};
    for ([_]dev.Direction{ .playback, .capture }) |direction| {
        const engine = engineOf(direction);
        if (!status.fired(engine) or !device.control.enabled(engine)) continue;
        const at = readPaged(regs.FrameSize, engine.size());
        done.set(direction, device.progress[@intFromEnum(direction)].advance(at.period(dev.periodBytes())));
    }
    return done;
}

/// The engines loop over their whole buffers, so there is no mark to move.
fn queued(_: dev.Direction, _: u32) void {}

fn period(direction: dev.Direction, index: u32) []u8 {
    return pcm.period(device.arena.at, direction, index);
}

/// The codec's master attenuator, both sides alike.
fn setMaster(volume: audio.Volume) void {
    if (!device.opened) return;
    const level = regs.Level{
        .attenuation = @intCast(regs.MASTER.steps - volume.stepOf(regs.MASTER)),
        .muted = volume.muted or volume.percent == 0,
    };
    for ([_]regs.CodecRegister{ .master_left, .master_right }) |side| {
        _ = codec(.{ .register = side, .value = @bitCast(level) });
    }
}
