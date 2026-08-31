//! High Definition Audio: the controller, and the codec behind it.
//!
//! Two halves that barely resemble each other. The controller is a bus
//! master with one DMA engine per stream, each walking a cyclic list of
//! period buffers and interrupting as it finishes one: the same shape
//! every PCM engine here has, and it shares `pcm.zig` with the others.
//!
//! The codec is a graph of widgets reached by sending verbs down a ring
//! and reading answers back up another. Nothing about the analog path is
//! assumed: the widgets are enumerated, an output pin with a converter
//! behind it is found by walking connections, and that path is what gets
//! powered, unmuted and pointed at a stream. A codec whose graph differs
//! is followed rather than guessed at, which is what lets one driver
//! serve both the emulator's codec and the machine's own.
//!
//! Register names and bit values follow the HDA specification, which is
//! public, and agree with the emulator's own header.

const audio = @import("lib").audio;
const dev = @import("dev.zig");
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const pcm = @import("pcm.zig");
const sys = @import("sys");

pub const name = "hda";

/// The register aperture: the controller's own file, then one descriptor
/// per stream. Sixteen kilobytes covers every stream a part of this class
/// has.
const MMIO_BYTES: usize = 16 * 1024;

/// Traffic class select, in configuration space. Class zero is what the
/// specification's snooping and interrupt delivery assume, and firmware
/// does not always leave it there.
const TCSEL_OFFSET: u8 = 0x44;

// ---------------------------------------------------------------------------
// Controller registers
// ---------------------------------------------------------------------------

const R32 = enum(usize) {
    global_control = 0x08,
    interrupt_control = 0x20,
    interrupt_status = 0x24,
    corb_base_low = 0x40,
    corb_base_high = 0x44,
    rirb_base_low = 0x50,
    rirb_base_high = 0x54,
    immediate_command = 0x60,
    immediate_response = 0x64,
    position_base_low = 0x70,
    position_base_high = 0x74,
};

const R16 = enum(usize) {
    capabilities = 0x00,
    state_change = 0x0E,
    corb_write = 0x48,
    corb_read = 0x4A,
    rirb_write = 0x58,
    response_interval = 0x5A,
    immediate_status = 0x68,
};

const R8 = enum(usize) {
    corb_control = 0x4C,
    corb_size = 0x4E,
    rirb_control = 0x5C,
    rirb_status = 0x5D,
    rirb_size = 0x5E,
};

/// One stream descriptor's registers, relative to its own base.
const Stream = enum(usize) {
    control = 0x00,
    status = 0x03,
    position = 0x04,
    buffer_length = 0x08,
    last_valid = 0x0C,
    format = 0x12,
    list_base_low = 0x18,
    list_base_high = 0x1C,
};

const STREAM_BASE: usize = 0x80;
const STREAM_STRIDE: usize = 0x20;

const Words = lib.mmio.Window(R32, u32);
const Halves = lib.mmio.Window(R16, u16);
const Bytes = lib.mmio.Window(R8, u8);

const GlobalControl = packed struct(u32) {
    /// Held low, the whole link is in reset; released, the codecs
    /// enumerate themselves.
    running: bool = false,
    flush: bool = false,
    _2: u6 = 0,
    accept_unsolicited: bool = false,
    _9: u23 = 0,
};

const Capabilities = packed struct(u16) {
    addresses_64bit: bool = false,
    serial_outputs: u2 = 0,
    bidirectional_streams: u5 = 0,
    input_streams: u4 = 0,
    output_streams: u4 = 0,
};

const InterruptControl = packed struct(u32) {
    streams: u30 = 0,
    controller: bool = false,
    global: bool = false,
};

const CorbControl = packed struct(u8) {
    interrupt: bool = false,
    running: bool = false,
    _2: u6 = 0,
};

const RirbControl = packed struct(u8) {
    interrupt: bool = false,
    running: bool = false,
    overrun_interrupt: bool = false,
    _3: u5 = 0,
};

/// The stream descriptor's control word, which the hardware exposes as
/// three bytes. Written whole, as the specification's own layout.
const StreamControl = packed struct(u24) {
    reset: bool = false,
    running: bool = false,
    completion_interrupt: bool = false,
    fifo_error_interrupt: bool = false,
    descriptor_error_interrupt: bool = false,
    _5: u11 = 0,
    stripe: u2 = 0,
    traffic_priority: bool = false,
    bidirectional_output: bool = false,
    /// Which stream tag the codec's converter is told to listen for.
    tag: u4 = 0,
};

const StreamStatus = packed struct(u8) {
    _0: u2 = 0,
    /// A descriptor with the interrupt flag completed. Write one to clear.
    completed: bool = false,
    fifo_error: bool = false,
    descriptor_error: bool = false,
    fifo_ready: bool = false,
    _6: u2 = 0,

    const ACK = StreamStatus{ .completed = true, .fifo_error = true, .descriptor_error = true };
};

/// The stream format, shared by the descriptor and the codec's converter:
/// both must be told the same thing or the link carries nonsense.
const Format = packed struct(u16) {
    channels_less_one: u4 = 1,
    /// One is sixteen bits, which is the only width this system moves.
    bits: u3 = 1,
    _7: u1 = 0,
    divisor: u3 = 0,
    multiplier: u3 = 0,
    /// Zero counts from forty-eight kilohertz, one from forty-four one.
    base_44100: bool = false,
    _15: u1 = 0,

    /// Sixteen-bit stereo at the base rate, which is the one shape this
    /// system moves.
    const standard = Format{ .channels_less_one = 1, .bits = 1 };
};

/// One buffer descriptor: a period's address, its length, and whether
/// finishing it interrupts.
const Descriptor = extern struct {
    address_low: u32 = 0,
    address_high: u32 = 0,
    length: u32 = 0,
    flags: DescriptorFlags = .{},
};

const DescriptorFlags = packed struct(u32) {
    interrupt: bool = false,
    _1: u31 = 0,
};

comptime {
    if (@sizeOf(Descriptor) != 16) @compileError("a buffer descriptor is sixteen bytes");
    if (@as(u16, @bitCast(Format.standard)) != 0x0011) @compileError("the stream format drifted");
    if (@as(u8, @bitCast(StreamStatus.ACK)) != 0x1C) @compileError("the stream status bits drifted");
    if (@as(u24, @bitCast(StreamControl{ .running = true })) != 0x02) {
        @compileError("the stream control bits drifted");
    }
    if (@as(u32, @bitCast(GlobalControl{ .running = true })) != 0x01) {
        @compileError("the global control bits drifted");
    }
}

/// The command ring, the response ring, and the period buffers, in one
/// allocation. The rings are the sizes the specification fixes; the two
/// hundred and fifty six entries are not negotiable in either direction.
const CORB_ENTRIES = 256;
const RIRB_ENTRIES = 256;

const Arena = extern struct {
    corb: [CORB_ENTRIES]u32 align(128) = @splat(0),
    /// Each response is the answer and the state that came with it.
    rirb: [RIRB_ENTRIES]Response align(128) = @splat(.{}),
    out_list: [dev.PERIODS]Descriptor align(128) = @splat(.{}),
    in_list: [dev.PERIODS]Descriptor align(128) = @splat(.{}),
    out_frames: [dev.PERIODS * dev.PERIOD_FRAMES * 2]i16 align(128) = @splat(0),
    in_frames: [dev.PERIODS * dev.PERIOD_FRAMES * 2]i16 align(128) = @splat(0),
};

const Response = extern struct {
    value: u32 = 0,
    /// Which codec answered, and whether it spoke unasked.
    extended: u32 = 0,
};

// ---------------------------------------------------------------------------
// The codec's vocabulary
// ---------------------------------------------------------------------------

/// The verbs this driver sends. The wide ones carry an eight-bit payload
/// and the two narrow ones sixteen, which is the whole of the encoding.
const Verb = enum(u20) {
    get_parameter = 0xF00,
    get_connections = 0xF02,
    get_pin_sense = 0xF09,
    set_connection = 0x701,
    set_stream_format = 0x002,
    set_amplifier = 0x003,
    set_stream_channel = 0x706,
    set_pin_control = 0x707,
    set_power_state = 0x705,
    set_external_amplifier = 0x70C,

    /// Narrow verbs are the two that carry a whole word of payload.
    fn narrow(self: Verb) bool {
        return self == .set_stream_format or self == .set_amplifier;
    }
};

/// The parameters read with `get_parameter`.
const Parameter = enum(u8) {
    vendor_device = 0x00,
    subordinate_nodes = 0x04,
    function_group_type = 0x05,
    widget_capabilities = 0x09,
    pin_capabilities = 0x0C,
    input_amplifier = 0x0D,
    connection_list_length = 0x0E,
    output_amplifier = 0x12,
};

/// What an amplifier can do: where its scale starts, how many steps it
/// has, how big they are, and whether it can be silenced outright.
const AmplifierCaps = packed struct(u32) {
    offset: u7 = 0,
    _7: u1 = 0,
    steps: u7 = 0,
    _15: u1 = 0,
    step_size: u7 = 0,
    _23: u8 = 0,
    mutable: bool = false,
};

/// What a widget is, from its capability word.
const WidgetKind = enum(u4) {
    output_converter = 0x0,
    input_converter = 0x1,
    mixer = 0x2,
    selector = 0x3,
    pin = 0x4,
    power = 0x5,
    volume_knob = 0x6,
    beep = 0x7,
    _,
};

const WidgetCaps = packed struct(u32) {
    stereo: bool = false,
    input_amplifier: bool = false,
    output_amplifier: bool = false,
    amplifier_override: bool = false,
    format_override: bool = false,
    stripe: bool = false,
    processing: bool = false,
    unsolicited: bool = false,
    connection_list: bool = false,
    digital: bool = false,
    power_control: bool = false,
    left_right_swap: bool = false,
    content_protection: bool = false,
    _13: u3 = 0,
    delay: u4 = 0,
    kind: WidgetKind = .output_converter,
    _24: u8 = 0,
};

const PinCaps = packed struct(u32) {
    impedance_sense: bool = false,
    trigger_required: bool = false,
    presence_detect: bool = false,
    headphone_drive: bool = false,
    output: bool = false,
    input: bool = false,
    balanced: bool = false,
    hdmi: bool = false,
    _8: u8 = 0,
    external_amplifier: bool = false,
    _17: u15 = 0,
};

/// What a pin is doing: which directions are live, and whether it drives
/// headphones.
const PinControl = packed struct(u8) {
    voltage_reference: u3 = 0,
    _3: u2 = 0,
    input: bool = false,
    output: bool = false,
    headphone: bool = false,
};

/// How loud an amplifier is opened at first. Zero on this hardware is the
/// quietest step rather than the loudest, so a path left at zero is a
/// silent machine; every amplifier is opened at its own full scale and the
/// graph's own volume attenuates from there.
const FULL: ?u8 = null;

/// The amplifier verb's payload: which amplifier, which channels, which
/// input index, and the gain or the mute.
const Amplifier = packed struct(u16) {
    gain: u7 = 0,
    mute: bool = false,
    index: u4 = 0,
    right: bool = false,
    left: bool = false,
    input: bool = false,
    output: bool = false,

    const output_open = Amplifier{ .output = true, .left = true, .right = true };
    const input_open = Amplifier{ .input = true, .left = true, .right = true };
};

comptime {
    if (@as(u16, @bitCast(Amplifier.output_open)) != 0xB000 or
        @as(u16, @bitCast(Amplifier.input_open)) != 0x7000)
    {
        @compileError("the amplifier payload drifted");
    }
    if (@as(u8, @bitCast(PinControl{ .output = true })) != 0x40) {
        @compileError("the pin control bits drifted");
    }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// One direction's analog path through the codec, as the walk found it.
const Path = struct {
    /// The converter that carries the stream.
    converter: u8 = 0,
    /// The pin that reaches the outside world.
    pin: u8 = 0,
    found: bool = false,
};

const Device = struct {
    words: Words = .{ .base = undefined },
    halves: Halves = .{ .base = undefined },
    bytes: Bytes = .{ .base = undefined },
    base: [*]volatile u8 = undefined,

    arena: pcm.Dma(Arena) = undefined,
    opened: bool = false,

    /// Which codec answered the state-change register.
    codec: u4 = 0,
    /// Where the output streams begin, which is after the input ones.
    output_stream: u8 = 0,
    input_stream: u8 = 0,

    /// The command ring's write pointer and the response ring's read
    /// pointer, both ours to keep.
    corb_write: u8 = 0,
    rirb_read: u8 = 0,
    /// Set when the response ring stopped answering and the immediate
    /// command registers took over for the rest of this run.
    immediate: bool = false,

    playback: Path = .{},
    capture: Path = .{},

    play_progress: pcm.Progress = .{ .modulus = dev.PERIODS },
    record_progress: pcm.Progress = .{ .modulus = dev.PERIODS },

    /// The output amplifier's step count, read from the codec rather than
    /// assumed: parts differ, and a volume map built on a guess is wrong
    /// on every part but one.
    volume_steps: u8 = 0,
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

// ---------------------------------------------------------------------------
// Bring-up
// ---------------------------------------------------------------------------

pub fn open(loc: pci.Location) bool {
    const base = pci.memoryBase(loc, 0) orelse {
        log.fail(name, "the controller exposes no register aperture");
        return false;
    };
    const aperture = sys.mapDevice(base, MMIO_BYTES) orelse {
        log.fail(name, "cannot map registers");
        return false;
    };
    pci.enableMemoryAndMaster(loc);

    device.base = @ptrCast(aperture);
    device.words = .{ .base = device.base };
    device.halves = .{ .base = device.base };
    device.bytes = .{ .base = device.base };

    // Traffic class zero, which is what snooping and interrupt delivery
    // are specified against and not always what firmware left behind.
    const tcsel = pci.read(loc, TCSEL_OFFSET);
    pci.write(loc, TCSEL_OFFSET, tcsel & ~@as(u32, 0x07));

    device.arena = pcm.Dma(Arena).alloc(name) orelse return false;

    if (!resetLink()) return false;
    if (!startRings()) return false;
    if (!findPaths()) return false;

    describeStreams();
    prepareLists();

    device.opened = true;
    sayIdentity();
    return true;
}

/// Hold the link down, let it go, and wait for the codecs to announce
/// themselves. A codec needs half a millisecond to enumerate, and the
/// specification says so; waiting less finds no codec on a good machine.
fn resetLink() bool {
    device.words.write(.global_control, @bitCast(GlobalControl{}));
    if (!pcm.settles(100, 100, {}, struct {
        fn ready(_: void) bool {
            const control: GlobalControl = @bitCast(device.words.read(.global_control));
            return !control.running;
        }
    }.ready)) {
        log.fail(name, "the link stayed out of reset");
        return false;
    }

    device.words.write(.global_control, @bitCast(GlobalControl{ .running = true }));
    if (!pcm.settles(100, 100, {}, struct {
        fn ready(_: void) bool {
            const control: GlobalControl = @bitCast(device.words.read(.global_control));
            return control.running;
        }
    }.ready)) {
        log.fail(name, "the link did not come out of reset");
        return false;
    }
    sys.sleepMicros(1000);

    const present = device.halves.read(.state_change);
    if (present == 0) {
        log.fail(name, "no codec announced itself");
        return false;
    }
    // The lowest codec that answered: this system drives one, and which
    // address it sits at is the machine's business rather than an
    // assumption worth making.
    device.codec = @intCast(@ctz(present));

    device.words.write(.global_control, @bitCast(GlobalControl{
        .running = true,
        .accept_unsolicited = true,
    }));
    return true;
}

/// The command and response rings, which is how anything is said to a
/// codec at all.
fn startRings() bool {
    device.bytes.write(.corb_control, @bitCast(CorbControl{}));
    device.bytes.write(.rirb_control, @bitCast(RirbControl{}));

    // Both rings are the full two hundred and fifty six entries, which is
    // the size selector every part of this class supports.
    const full_size: u8 = 0x02;
    device.bytes.write(.corb_size, full_size);
    device.bytes.write(.rirb_size, full_size);

    device.words.write(.corb_base_low, device.arena.physOf("corb"));
    device.words.write(.corb_base_high, 0);
    device.words.write(.rirb_base_low, device.arena.physOf("rirb"));
    device.words.write(.rirb_base_high, 0);

    // The read pointer's reset is a handshake: raise the bit, wait for the
    // hardware to agree, lower it, wait again.
    const reset_bit: u16 = 0x8000;
    device.halves.write(.corb_read, reset_bit);
    _ = pcm.settles(100, 100, {}, struct {
        fn ready(_: void) bool {
            return device.halves.read(.corb_read) & 0x8000 != 0;
        }
    }.ready);
    device.halves.write(.corb_read, 0);
    if (!pcm.settles(100, 100, {}, struct {
        fn ready(_: void) bool {
            return device.halves.read(.corb_read) & 0x8000 == 0;
        }
    }.ready)) {
        log.warn(name, "the command ring's pointer would not reset");
    }

    device.halves.write(.corb_write, 0);
    device.corb_write = 0;

    // The response ring's pointer clears itself.
    device.halves.write(.rirb_write, reset_bit);
    device.rirb_read = 0;
    device.halves.write(.response_interval, 1);

    device.bytes.write(.rirb_control, @bitCast(RirbControl{ .interrupt = true, .running = true }));
    device.bytes.write(.corb_control, @bitCast(CorbControl{ .running = true }));
    return true;
}

/// Where this controller keeps its input and output stream descriptors.
fn describeStreams() void {
    const caps: Capabilities = @bitCast(device.halves.read(.capabilities));
    // Input descriptors come first, then output ones: the output engine
    // this driver runs is the first of those.
    device.input_stream = 0;
    device.output_stream = caps.input_streams;
}

fn streamWindow(index: u8) usize {
    return STREAM_BASE + @as(usize, index) * STREAM_STRIDE;
}

fn streamWrite32(index: u8, register: Stream, value: u32) void {
    const at: *volatile u32 = @ptrCast(@alignCast(device.base + streamWindow(index) + @intFromEnum(register)));
    at.* = value;
}

fn streamRead32(index: u8, register: Stream) u32 {
    const at: *const volatile u32 = @ptrCast(@alignCast(device.base + streamWindow(index) + @intFromEnum(register)));
    return at.*;
}

fn streamWrite16(index: u8, register: Stream, value: u16) void {
    const at: *volatile u16 = @ptrCast(@alignCast(device.base + streamWindow(index) + @intFromEnum(register)));
    at.* = value;
}

fn streamWrite8(index: u8, register: Stream, value: u8) void {
    device.base[streamWindow(index) + @intFromEnum(register)] = value;
}

fn streamRead8(index: u8, register: Stream) u8 {
    return device.base[streamWindow(index) + @intFromEnum(register)];
}

/// The control word occupies three bytes, so it is written as its high
/// byte and then its low word rather than as a word the aperture has no
/// room for.
///
/// That order is the whole of the handshake. The stream tag lives in the
/// high byte and the run bit in the low word, and the controller tells the
/// codecs a stream started the moment the run bit lands. Written the other
/// way round it announces stream zero, which names no converter, and the
/// engine turns with nothing listening.
fn streamControl(index: u8, control: StreamControl) void {
    const bits: u24 = @bitCast(control);
    device.base[streamWindow(index) + @intFromEnum(Stream.control) + 2] = @truncate(bits >> 16);
    streamWrite16(index, .control, @truncate(bits));
}

/// Both descriptor lists, fixed at open: each entry names one period
/// buffer and interrupts when the engine finishes it. The list is cyclic,
/// so the engine wraps on its own and never needs a mark walked forward.
fn prepareLists() void {
    const out_base = device.arena.physOf("out_frames");
    const in_base = device.arena.physOf("in_frames");
    const period_bytes: u32 = @intCast(dev.periodBytes());

    for (0..dev.PERIODS) |i| {
        const step: u32 = @as(u32, @intCast(i)) * period_bytes;
        device.arena.at.out_list[i] = .{
            .address_low = out_base + step,
            .length = period_bytes,
            .flags = .{ .interrupt = true },
        };
        device.arena.at.in_list[i] = .{
            .address_low = in_base + step,
            .length = period_bytes,
            .flags = .{ .interrupt = true },
        };
    }
}

// ---------------------------------------------------------------------------
// Talking to the codec
// ---------------------------------------------------------------------------

/// One verb, and the codec's answer. The command ring is tried first; a
/// ring that stops answering hands the rest of the run to the immediate
/// command registers, which every part of this class also has.
fn command(node: u8, verb: Verb, payload: u16) ?u32 {
    const encoded: u32 = if (verb.narrow())
        (@as(u32, @intFromEnum(verb)) << 16) | payload
    else
        (@as(u32, @intFromEnum(verb)) << 8) | (payload & 0xFF);

    const word = (@as(u32, device.codec) << 28) | (@as(u32, node) << 20) | encoded;

    if (!device.immediate) {
        if (throughRings(word)) |answer| return answer;
        log.warn(name, "the response ring stopped answering; using immediate commands");
        device.immediate = true;
    }
    return immediately(word);
}

fn throughRings(word: u32) ?u32 {
    device.corb_write +%= 1;
    device.arena.at.corb[device.corb_write] = word;
    device.halves.write(.corb_write, device.corb_write);

    // A verb is answered in microseconds; a tenth of a second is patience
    // enough to call a codec dead.
    if (!pcm.settles(1000, 100, {}, struct {
        fn ready(_: void) bool {
            const written: u8 = @truncate(device.halves.read(.rirb_write));
            return written != device.rirb_read;
        }
    }.ready)) return null;

    device.rirb_read +%= 1;
    const answer = device.arena.at.rirb[device.rirb_read].value;
    // Whatever the ring reported is consumed, so a later answer is not
    // read as this one's.
    device.bytes.write(.rirb_status, 0x05);
    return answer;
}

/// The immediate command path: one register in, one out, a busy bit
/// between them.
fn immediately(word: u32) ?u32 {
    const busy: u16 = 0x0001;
    const valid: u16 = 0x0002;

    if (!pcm.settles(1000, 100, {}, struct {
        fn ready(_: void) bool {
            return device.halves.read(.immediate_status) & 0x0001 == 0;
        }
    }.ready)) return null;

    // The valid bit is cleared by writing it back, so an answer left from
    // a previous verb cannot be mistaken for this one's.
    device.halves.write(.immediate_status, valid);
    device.words.write(.immediate_command, word);
    device.halves.write(.immediate_status, busy);

    if (!pcm.settles(1000, 100, {}, struct {
        fn ready(_: void) bool {
            return device.halves.read(.immediate_status) & 0x0002 != 0;
        }
    }.ready)) return null;

    return device.words.read(.immediate_response);
}

fn parameter(node: u8, which: Parameter) ?u32 {
    return command(node, .get_parameter, @intFromEnum(which));
}

/// The range of child nodes a node has: where they start and how many.
fn children(node: u8) ?struct { first: u8, count: u8 } {
    const answer = parameter(node, .subordinate_nodes) orelse return null;
    const count: u8 = @truncate(answer);
    if (count == 0) return null;
    return .{ .first = @truncate(answer >> 16), .count = count };
}

// ---------------------------------------------------------------------------
// Finding the analog path
// ---------------------------------------------------------------------------

/// Walk the codec until an output pin with a converter behind it is
/// found, and an input pin with one in front of it. Nothing is assumed
/// about which node numbers those are: this is the whole reason a codec
/// this driver has never seen still plays.
fn findPaths() bool {
    const root = children(0) orelse {
        log.fail(name, "the codec described no function groups");
        return false;
    };

    var group: u8 = root.first;
    const group_end = root.first + root.count;
    while (group < group_end) : (group += 1) {
        const kind = parameter(group, .function_group_type) orelse continue;
        // One is the audio function group; the others are modems and
        // vendor things this system has nothing to say to.
        if (kind & 0xFF != 0x01) continue;

        // The group and everything under it, awake.
        _ = command(group, .set_power_state, 0);
        sys.sleepMicros(10_000);

        const widgets = children(group) orelse continue;
        if (walkWidgets(widgets.first, widgets.count)) return true;
    }

    log.fail(name, "the codec has no output this driver can reach");
    return false;
}

fn walkWidgets(first: u8, count: u8) bool {
    var pin: u8 = first;
    const end = first + count;

    // Output first: a pin that leaves the machine, and whatever converter
    // reaches it. Pins are searched in order, so the codec's own idea of
    // which comes first decides, rather than this driver's.
    while (pin < end) : (pin += 1) {
        const caps: WidgetCaps = @bitCast(parameter(pin, .widget_capabilities) orelse continue);
        if (caps.kind != .pin) continue;

        const pin_caps: PinCaps = @bitCast(parameter(pin, .pin_capabilities) orelse continue);
        if (!pin_caps.output) continue;

        if (converterBehind(pin, first, end, .output_converter)) |converter| {
            device.playback = .{ .converter = converter, .pin = pin, .found = true };
            openOutput(pin, pin_caps);
            break;
        }
    }

    // Then input, which this system offers as the microphone node. A
    // codec with no capture path is not a failure: it simply has nothing
    // to say into the graph.
    pin = first;
    while (pin < end) : (pin += 1) {
        const caps: WidgetCaps = @bitCast(parameter(pin, .widget_capabilities) orelse continue);
        if (caps.kind != .pin) continue;

        const pin_caps: PinCaps = @bitCast(parameter(pin, .pin_capabilities) orelse continue);
        if (!pin_caps.input) continue;

        if (converterAhead(pin, first, end)) |converter| {
            device.capture = .{ .converter = converter, .pin = pin, .found = true };
            openInput(pin);
            break;
        }
    }

    return device.playback.found;
}

/// The converter feeding a pin: the pin's own connections, then one level
/// through a mixer or selector, which is as deep as these codecs put a
/// converter from a jack.
fn converterBehind(pin: u8, first: u8, end: u8, wanted: WidgetKind) ?u8 {
    var connections: [8]u8 = undefined;
    const direct = connectionsOf(pin, &connections);

    for (direct, 0..) |node, index| {
        const caps: WidgetCaps = @bitCast(parameter(node, .widget_capabilities) orelse continue);
        if (caps.kind == wanted) {
            selectConnection(pin, @intCast(index));
            return node;
        }
    }

    // One level deeper, through whatever mixes or selects between them.
    for (direct, 0..) |node, index| {
        if (node < first or node >= end) continue;
        const caps: WidgetCaps = @bitCast(parameter(node, .widget_capabilities) orelse continue);
        if (caps.kind != .mixer and caps.kind != .selector) continue;

        var inner: [8]u8 = undefined;
        const deeper = connectionsOf(node, &inner);
        for (deeper, 0..) |candidate, inner_index| {
            const inner_caps: WidgetCaps = @bitCast(parameter(candidate, .widget_capabilities) orelse continue);
            if (inner_caps.kind != wanted) continue;

            selectConnection(pin, @intCast(index));
            selectConnection(node, @intCast(inner_index));
            // The thing in between must pass sound rather than mute it.
            openAmplifier(node, .input, @intCast(inner_index), FULL);
            _ = command(node, .set_power_state, 0);
            return candidate;
        }
    }
    return null;
}

/// The converter a pin feeds, which is the same walk read backwards: an
/// input converter lists the pins it can take, rather than the other way
/// about.
fn converterAhead(pin: u8, first: u8, end: u8) ?u8 {
    var node: u8 = first;
    while (node < end) : (node += 1) {
        const caps: WidgetCaps = @bitCast(parameter(node, .widget_capabilities) orelse continue);
        if (caps.kind != .input_converter) continue;

        var connections: [8]u8 = undefined;
        for (connectionsOf(node, &connections), 0..) |source, index| {
            if (source != pin) continue;
            selectConnection(node, @intCast(index));
            return node;
        }
    }
    return null;
}

/// A widget's connection list. The short form packs four entries into a
/// word, which is what every widget this system meets uses.
fn connectionsOf(node: u8, into: []u8) []u8 {
    const length = parameter(node, .connection_list_length) orelse return into[0..0];
    // The high bit says the entries are wide; this driver reads the short
    // form, which is what these codecs publish.
    if (length & 0x80 != 0) return into[0..0];

    const count: u8 = @truncate(length & 0x7F);
    var found: usize = 0;
    var index: u8 = 0;
    while (index < count and found < into.len) : (index += 4) {
        const answer = command(node, .get_connections, index) orelse break;
        var byte: u5 = 0;
        while (byte < 4 and index + byte < count and found < into.len) : (byte += 1) {
            into[found] = @truncate(answer >> (@as(u5, byte) * 8));
            found += 1;
        }
    }
    return into[0..found];
}

fn selectConnection(node: u8, index: u8) void {
    _ = command(node, .set_connection, index);
}

/// How many steps a node's amplifier has, which decides what "loud" means
/// for it. Parts differ, so it is read rather than assumed.
fn amplifierSteps(node: u8, which: Parameter) u8 {
    const caps: AmplifierCaps = @bitCast(parameter(node, which) orelse return 0);
    return caps.steps;
}

/// Open one amplifier: unmuted, at the gain asked for, or at the node's
/// own full scale when none is.
fn openAmplifier(node: u8, direction: enum { input, output }, index: u4, gain: ?u8) void {
    const which: Parameter = switch (direction) {
        .input => .input_amplifier,
        .output => .output_amplifier,
    };
    const steps = amplifierSteps(node, which);

    var setting = switch (direction) {
        .input => Amplifier.input_open,
        .output => Amplifier.output_open,
    };
    setting.index = index;
    setting.gain = @truncate(gain orelse steps);
    _ = command(node, .set_amplifier, @bitCast(setting));
}

/// Wake a pin, point it outward, and open every amplifier between it and
/// the air.
fn openOutput(pin: u8, caps: PinCaps) void {
    _ = command(pin, .set_power_state, 0);

    var control = PinControl{ .output = true };
    // A pin that can drive headphones is told to: the machine's own
    // speakers are wired to one on some parts, and driving it costs
    // nothing where they are not.
    if (caps.headphone_drive) control.headphone = true;
    _ = command(pin, .set_pin_control, @as(u8, @bitCast(control)));

    // The external amplifier, where the part has one. Speakers on this
    // class of machine are commonly behind it and silent without it.
    if (caps.external_amplifier) _ = command(pin, .set_external_amplifier, 0x02);

    openAmplifier(pin, .output, 0, FULL);

    // The converter's own amplifier is the one a volume setting moves, so
    // its step count is what the volume map is built against.
    _ = command(device.playback.converter, .set_power_state, 0);
    device.volume_steps = amplifierSteps(device.playback.converter, .output_amplifier);
    openAmplifier(device.playback.converter, .output, 0, FULL);
}

fn openInput(pin: u8) void {
    _ = command(pin, .set_power_state, 0);
    // Input enabled, with the bias voltage an electret microphone needs.
    const control = PinControl{ .input = true, .voltage_reference = 0x4 };
    _ = command(pin, .set_pin_control, @as(u8, @bitCast(control)));
    openAmplifier(pin, .input, 0, FULL);
    _ = command(device.capture.converter, .set_power_state, 0);
    openAmplifier(device.capture.converter, .input, 0, FULL);
}

// ---------------------------------------------------------------------------
// Streams
// ---------------------------------------------------------------------------

/// The tag the converter and the descriptor must agree on. One each way,
/// and never zero, which the specification reserves for silence.
const PLAYBACK_TAG: u4 = 1;
const CAPTURE_TAG: u4 = 2;

fn indexOf(direction: dev.Direction) u8 {
    return switch (direction) {
        .playback => device.output_stream,
        .capture => device.input_stream,
    };
}

fn pathOf(direction: dev.Direction) Path {
    return switch (direction) {
        .playback => device.playback,
        .capture => device.capture,
    };
}

fn start(direction: dev.Direction) bool {
    if (!device.opened) return false;
    const path = pathOf(direction);
    if (!path.found) return false;

    const index = indexOf(direction);
    const tag: u4 = switch (direction) {
        .playback => PLAYBACK_TAG,
        .capture => CAPTURE_TAG,
    };

    // Reset the engine: raise the bit, wait for it, lower it, wait again.
    streamControl(index, .{ .reset = true });
    _ = pcm.settles(100, 100, index, struct {
        fn ready(at: u8) bool {
            return streamRead8(at, .control) & 0x01 != 0;
        }
    }.ready);
    streamControl(index, .{});
    if (!pcm.settles(100, 100, index, struct {
        fn ready(at: u8) bool {
            return streamRead8(at, .control) & 0x01 == 0;
        }
    }.ready)) {
        log.warn(name, "a stream engine would not reset");
        return false;
    }

    const frames = switch (direction) {
        .playback => &device.arena.at.out_frames,
        .capture => &device.arena.at.in_frames,
    };
    pcm.silence(frames);

    const list = switch (direction) {
        .playback => device.arena.physOf("out_list"),
        .capture => device.arena.physOf("in_list"),
    };
    streamWrite32(index, .list_base_low, list);
    streamWrite32(index, .list_base_high, 0);
    streamWrite32(index, .buffer_length, @intCast(dev.PERIODS * dev.periodBytes()));
    streamWrite16(index, .last_valid, dev.PERIODS - 1);
    streamWrite16(index, .format, @bitCast(Format.standard));
    streamWrite8(index, .status, @bitCast(StreamStatus.ACK));

    // The converter carries this tag, and the descriptor announces it: the
    // link matches frames to engines by nothing else.
    _ = command(path.converter, .set_stream_format, @bitCast(Format.standard));
    _ = command(path.converter, .set_stream_channel, @as(u16, tag) << 4);

    switch (direction) {
        .playback => device.play_progress.reset(),
        .capture => device.record_progress.reset(),
    }

    // The controller's interrupts, then the engine's own.
    var control: InterruptControl = @bitCast(device.words.read(.interrupt_control));
    control.global = true;
    control.controller = true;
    control.streams |= @as(u30, 1) << @intCast(index);
    device.words.write(.interrupt_control, @bitCast(control));

    streamControl(index, .{
        .running = true,
        .completion_interrupt = true,
        .fifo_error_interrupt = true,
        .descriptor_error_interrupt = true,
        .tag = tag,
    });
    return true;
}

fn stop(direction: dev.Direction) void {
    if (!device.opened) return;
    const index = indexOf(direction);

    streamControl(index, .{});
    _ = pcm.settles(100, 100, index, struct {
        fn ready(at: u8) bool {
            return streamRead8(at, .control) & 0x02 == 0;
        }
    }.ready);

    var control: InterruptControl = @bitCast(device.words.read(.interrupt_control));
    control.streams &= ~(@as(u30, 1) << @intCast(index));
    device.words.write(.interrupt_control, @bitCast(control));
}

/// One delivery: whichever engines flagged a completion, counted by where
/// the hardware says it now is.
fn irq() dev.Completions {
    if (!device.opened) return .{};

    const pending = device.words.read(.interrupt_status);
    if (pending == 0) return .{};

    var done = dev.Completions{};

    if (device.playback.found and pending & (@as(u32, 1) << @intCast(device.output_stream)) != 0) {
        done.playback = advanceOf(device.output_stream, &device.play_progress);
    }
    if (device.capture.found and pending & (@as(u32, 1) << @intCast(device.input_stream)) != 0) {
        done.capture = advanceOf(device.input_stream, &device.record_progress);
    }
    return done;
}

/// How many periods an engine finished, from its position in the buffer.
/// Position rather than a tally: an interrupt that coalesced two periods
/// is one delivery, and the position says so where a count would not.
fn advanceOf(index: u8, progress: *pcm.Progress) u8 {
    const status: StreamStatus = @bitCast(streamRead8(index, .status));
    if (!status.completed and !status.fifo_error and !status.descriptor_error) return 0;

    const position = streamRead32(index, .position);
    const slot: u32 = @intCast(position / dev.periodBytes());
    streamWrite8(index, .status, @bitCast(StreamStatus.ACK));
    return progress.advance(slot);
}

fn period(direction: dev.Direction, index: u32) []u8 {
    return switch (direction) {
        .playback => pcm.periodAt(&device.arena.at.out_frames, index),
        .capture => pcm.periodAt(&device.arena.at.in_frames, index),
    };
}

/// The descriptor list is cyclic and the engine wraps on its own, so
/// there is no mark to walk forward.
fn queued(_: dev.Direction, _: u32) void {}

/// The converter's own amplifier, which is where a volume belongs: the
/// step count came from the codec at open, so a part with a different
/// scale is served correctly rather than approximately.
fn setMaster(volume: audio.Volume) void {
    if (!device.opened or !device.playback.found) return;

    var setting = Amplifier.output_open;
    if (volume.muted) {
        setting.mute = true;
    } else {
        setting.gain = @truncate(volume.stepOf(device.volume_steps));
    }
    _ = command(device.playback.converter, .set_amplifier, @bitCast(setting));
}

fn sayIdentity() void {
    const id = parameter(0, .vendor_device) orelse 0;
    log.begin(name, .key);
    out.text("codec 0x");
    out.hex(id, 8);
    out.text(", out ");
    out.decimal(device.playback.pin);
    out.text("<-");
    out.decimal(device.playback.converter);
    if (device.capture.found) {
        out.text(", in ");
        out.decimal(device.capture.pin);
        out.text("->");
        out.decimal(device.capture.converter);
    }
    out.text(", ");
    out.decimal(device.volume_steps);
    out.text(" volume steps");
    log.end();
}
