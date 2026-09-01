//! The companion controller: full and low speed devices.
//!
//! A high speed controller hands a slow device's port to a companion
//! rather than driving it, so a keyboard or a mouse plugged into a machine
//! of this era is this controller's and not the fast one's. It is the
//! older design and much the simpler one: registers in I/O space, a frame
//! list the controller walks once a millisecond, and descriptors that are
//! four words each.
//!
//! The seam above is the same `HcOps` the high speed controller
//! implements, so the bus, enumeration and every class driver are
//! unchanged by which of them a device turns out to be on. The chipset
//! carries four companions behind one fast controller, so the driver is
//! one body over four units, each bound to its own ops table at compile
//! time.

const device = @import("ulib").device;
const hc = @import("hc.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const ports = @import("ulib").ports;
const std = @import("std");
const sys = @import("sys");
const table = @import("ulib").table;
const usb = @import("lib").usb;

pub const name = "uhci";

/// The register file is thirty-two bytes of I/O space, and every
/// controller of this kind has exactly two ports.
const IO_BYTES: usize = 32;
const PORTS: u8 = 2;

// ---------------------------------------------------------------------------
// Registers
// ---------------------------------------------------------------------------

const Reg = enum(u16) {
    command = 0x00,
    status = 0x02,
    interrupts = 0x04,
    frame_number = 0x06,
    frame_base = 0x08,
    start_of_frame = 0x0C,
    port1 = 0x10,
    port2 = 0x12,
};

const Command = packed struct(u16) {
    running: bool = false,
    reset: bool = false,
    global_reset: bool = false,
    global_suspend: bool = false,
    global_resume: bool = false,
    software_debug: bool = false,
    /// The frame list is ours to schedule from, rather than the
    /// firmware's. Set once the driver owns the self.controller.
    configured: bool = false,
    /// Sixty-four byte packets rather than thirty-two.
    max_packet_64: bool = false,
    _8: u8 = 0,
};

const Status = packed struct(u16) {
    /// A descriptor that asked to interrupt has finished.
    transfer: bool = false,
    transfer_error: bool = false,
    resume_detect: bool = false,
    host_system_error: bool = false,
    /// The controller found its own schedule malformed and stopped.
    process_error: bool = false,
    halted: bool = false,
    _6: u10 = 0,

    /// Everything worth acknowledging, written back to clear.
    const ACK = Status{
        .transfer = true,
        .transfer_error = true,
        .resume_detect = true,
        .host_system_error = true,
        .process_error = true,
    };
};

const Interrupts = packed struct(u16) {
    timeout: bool = false,
    resume_enabled: bool = false,
    on_complete: bool = false,
    short_packet: bool = false,
    _4: u12 = 0,
};

const Port = packed struct(u16) {
    connected: bool = false,
    /// Write one to clear.
    connection_changed: bool = false,
    enabled: bool = false,
    /// Write one to clear.
    enable_changed: bool = false,
    line_status: u2 = 0,
    resume_detect: bool = false,
    /// Reads as one always; writing zero here is what clears the change
    /// bits by accident, so it is carried through every write.
    _reserved_one: bool = true,
    low_speed: bool = false,
    reset: bool = false,
    _10: u2 = 0,
    suspend_port: bool = false,
    _13: u3 = 0,

    /// The bits that clear when written back, so a read-modify-write does
    /// not acknowledge a change nobody looked at.
    const CHANGES = Port{ .connection_changed = true, .enable_changed = true };

    fn quiet(self: Port) Port {
        var copy = self;
        copy.connection_changed = false;
        copy.enable_changed = false;
        copy._reserved_one = true;
        return copy;
    }

    fn changed(self: Port) bool {
        return self.connection_changed or self.enable_changed;
    }
};

comptime {
    if (@as(u16, @bitCast(Command{ .running = true })) != 0x0001 or
        @as(u16, @bitCast(Command{ .reset = true })) != 0x0002 or
        @as(u16, @bitCast(Command{ .configured = true })) != 0x0040)
    {
        @compileError("the command register's bits drifted");
    }
    if (@as(u16, @bitCast(Status{ .halted = true })) != 0x0020) {
        @compileError("the halted bit drifted");
    }
    if (@as(u16, @bitCast(Port{ ._reserved_one = false })) != 0x0000 or
        @as(u16, @bitCast(Port{ .connected = true, ._reserved_one = false })) != 0x0001 or
        @as(u16, @bitCast(Port{ .enabled = true, ._reserved_one = false })) != 0x0004 or
        @as(u16, @bitCast(Port{ .low_speed = true, ._reserved_one = false })) != 0x0100 or
        @as(u16, @bitCast(Port{ .reset = true, ._reserved_one = false })) != 0x0200)
    {
        @compileError("the port register's bits drifted");
    }
}

/// Where the firmware's own input emulation is switched off. Not a
/// capability list like the fast controller's: one fixed word in
/// configuration space, which is written to say the driver has the
/// controller now.
const LEGACY_OFFSET: u8 = 0xC0;
/// Every status bit set, which clears them, and every trap disabled.
const LEGACY_RELEASE: u16 = 0x8F00;

// ---------------------------------------------------------------------------
// The schedule
// ---------------------------------------------------------------------------

/// What a link word points at, and whether the controller should follow
/// it before moving sideways.
const Link = packed struct(u32) {
    terminate: bool = true,
    /// The target is a queue head rather than a descriptor.
    queue: bool = false,
    /// Follow this link before the horizontal one.
    depth_first: bool = false,
    _3: u1 = 0,
    address: u28 = 0,

    fn toTransfer(physical: u32, depth: bool) Link {
        return .{ .terminate = false, .queue = false, .depth_first = depth, .address = @intCast(physical >> 4) };
    }

    fn toQueue(physical: u32) Link {
        return .{ .terminate = false, .queue = true, .address = @intCast(physical >> 4) };
    }

    const none = Link{};
};

const Pid = enum(u8) {
    setup = 0x2D,
    in = 0x69,
    out = 0xE1,
};

/// The second word of a descriptor: what became of the transfer, and what
/// the controller should do about it.
const Control = packed struct(u32) {
    /// How many bytes actually moved, less one. Reads as 0x7FF when
    /// nothing did.
    moved: u11 = 0,
    _11: u6 = 0,
    bitstuff_error: bool = false,
    /// A timeout or a bad checksum: the device did not answer properly.
    crc_timeout: bool = false,
    /// The device is not ready and the transfer should be tried again.
    /// Not a failure: an interrupt endpoint answers this until it has
    /// something to say.
    nak: bool = false,
    babble: bool = false,
    buffer_error: bool = false,
    /// The device said no.
    stalled: bool = false,
    active: bool = false,
    /// Interrupt when this descriptor finishes.
    interrupt_on_complete: bool = false,
    isochronous: bool = false,
    low_speed: bool = false,
    /// How many times to retry before giving up. Zero means forever,
    /// which is what an endpoint being polled wants.
    error_limit: u2 = 0,
    short_packet_detect: bool = false,
    _30: u2 = 0,

    /// Nothing moved at all, which the controller writes as every bit of
    /// the length field set rather than as zero.
    const NOTHING: u11 = 0x7FF;

    fn failed(self: Control) bool {
        return self.stalled or self.crc_timeout or self.babble or
            self.buffer_error or self.bitstuff_error;
    }

    /// How many bytes this descriptor carried.
    fn bytes(self: Control) usize {
        if (self.moved == NOTHING) return 0;
        return @as(usize, self.moved) + 1;
    }
};

/// The third word: who the transfer is for and how big it may be.
const Token = packed struct(u32) {
    pid: Pid = .in,
    address: u7 = 0,
    endpoint: u4 = 0,
    toggle: bool = false,
    _20: u1 = 0,
    /// The largest packet, less one. A transfer of nothing is written as
    /// every bit set, the same convention the length field uses.
    length: u11 = 0,

    const NOTHING: u11 = 0x7FF;

    fn sized(bytes: usize) u11 {
        return if (bytes == 0) NOTHING else @intCast(bytes - 1);
    }
};

/// One transfer descriptor: sixteen bytes, aligned to sixteen, which is
/// what the link word's shape requires.
const Transfer = extern struct {
    link: Link = Link.none,
    control: Control = .{},
    token: Token = .{},
    buffer: u32 = 0,
};

/// A queue head: two words, a list to walk sideways and a chain of
/// descriptors to walk down.
const QueueHead = extern struct {
    link: Link = Link.none,
    element: Link = Link.none,
    /// To sixteen bytes, because everything in the schedule is aligned
    /// that way and the pool is an array of these.
    _pad: [2]u32 = @splat(0),
};

comptime {
    if (@sizeOf(Transfer) != 16) @compileError("a transfer descriptor is sixteen bytes");
    if (@sizeOf(QueueHead) != 16) @compileError("a queue head is sixteen bytes");
    if (@as(u32, @bitCast(Control{ .active = true })) != 0x0080_0000) {
        @compileError("the active bit drifted");
    }
    if (@as(u32, @bitCast(Control{ .stalled = true })) != 0x0040_0000) {
        @compileError("the stalled bit drifted");
    }
    if (@as(u32, @bitCast(Control{ .nak = true })) != 0x0008_0000) {
        @compileError("the negative acknowledgement bit drifted");
    }
    if (@as(u32, @bitCast(Token{ .pid = .setup })) != 0x2D or
        @as(u32, @bitCast(Token{ .pid = .out })) != 0xE1 or
        @as(u32, @bitCast(Token{ .pid = .in, .address = 1 })) != 0x169 or
        @as(u32, @bitCast(Token{ .pid = .in, .endpoint = 1 })) != 0x8069 or
        @as(u32, @bitCast(Token{ .pid = .in, .toggle = true })) != 0x8_0069 or
        @as(u32, @bitCast(Token{ .pid = .in, .length = 7 })) != 0xE0_0069)
    {
        @compileError("the token's fields drifted");
    }
    if (@as(u32, @bitCast(Link{ .queue = true, .terminate = false })) != 0x02) {
        @compileError("the link word's bits drifted");
    }
}

/// How many stages one control transfer needs: setup, data, status.
const STAGES = 3;

/// The largest control answer a device gives during enumeration, and the
/// largest transfer this controller carries in one descriptor chain.
const BUFFER_BYTES = 1024;

/// How many interrupt endpoints may be watched at once.
const WATCHES = 4;

/// The largest report a watched endpoint may carry.
const REPORT_BYTES = 16;

/// A full speed control endpoint takes at most sixty-four bytes and a low
/// speed one at most eight, so a chain of this many descriptors covers
/// the longest answer either can give.
const CHAIN = BUFFER_BYTES / 8 + STAGES;

const Arena = extern struct {
    /// The frame list: a thousand and twenty-four entries the controller
    /// walks one per millisecond, every one pointing at the same place.
    frames: [1024]Link align(4096) = @splat(Link.none),
    /// The head everything transferred on demand hangs from.
    queue: QueueHead align(16) = .{},
    /// One head per watched endpoint, chained behind the first.
    watches: [WATCHES]QueueHead align(16) = @splat(.{}),
    chain: [CHAIN]Transfer align(16) = @splat(.{}),
    watch_tds: [WATCHES]Transfer align(16) = @splat(.{}),
    buffer: [BUFFER_BYTES]u8 align(16) = @splat(0),
    reports: [WATCHES][REPORT_BYTES]u8 align(16) = @splat(@splat(0)),
};

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const Device = struct {
    base: u16 = 0,
    location: pci.Location = .{ .bus = 0, .device = 0, .function = 0 },
    arena: device.Dma(Arena) = undefined,
    opened: bool = false,
    /// The one clean rebuild a stop is answered with.
    rebuilt: bool = false,
    irq: u32 = 0,
};

const Watch = struct {
    live: bool = false,
    pipe: usb.Pipe = .{},
    report_bytes: u8 = 0,
};

/// One controller and everything watched through it.
const Unit = struct {
    controller: Device = .{},
    watches: [WATCHES]Watch = @splat(.{}),
};

/// The high speed controller's companions come four to the chipset, and
/// four is the budget until silicon carries more.
pub const MAX_UNITS = 4;

var units: [MAX_UNITS]Unit = @splat(.{});

// ---------------------------------------------------------------------------
// Register access
// ---------------------------------------------------------------------------

fn read16(self: *Unit, register: Reg) u16 {
    return ports.in16(self.controller.base + @intFromEnum(register));
}

fn write16(self: *Unit, register: Reg, value: u16) void {
    ports.out16(self.controller.base + @intFromEnum(register), value);
}

fn portRegister(index: u8) Reg {
    return if (index == 0) .port1 else .port2;
}

fn portRead(self: *Unit, index: u8) Port {
    return @bitCast(read16(self, portRegister(index)));
}

fn portWrite(self: *Unit, index: u8, value: Port) void {
    write16(self, portRegister(index), @bitCast(value));
}

// ---------------------------------------------------------------------------
// Bring-up
// ---------------------------------------------------------------------------

fn open(self: *Unit, loc: pci.Location) bool {
    if (self.controller.opened) return false;
    const window: pci.IoBar = @bitCast(pci.bar(loc, 4));
    if (!window.io_space) {
        log.fail(name, "the controller exposes no register ports");
        return false;
    }
    const base = window.base();
    if (base == 0 or sys.ioportGrant(@intCast(base), IO_BYTES) < 0) {
        log.fail(name, "cannot reach the controller's registers");
        return false;
    }

    self.controller.base = @intCast(base);
    self.controller.location = loc;

    // The firmware has been driving this controller to make a USB
    // keyboard look like an old one. Saying so before the first trapped
    // word, the command write included, is what stops its management code
    // from fighting us for the ports.
    takeFromFirmware(loc);
    pci.enableIoAndMaster(loc);

    if (!reset(self)) return false;

    self.controller.arena = device.Dma(Arena).alloc(name) orelse return false;
    startSchedule(self);
    self.controller.opened = true;

    log.begin(name, .key);
    out.decimal(PORTS);
    out.text(" ports, full and low speed");
    log.end();
    return true;
}

fn takeFromFirmware(loc: pci.Location) void {
    // One word, written rather than negotiated: every status bit set,
    // which clears them, and every trap disabled. The fast controller's
    // handshake has no counterpart here.
    const existing = pci.read(loc, LEGACY_OFFSET);
    const written = (existing & 0xFFFF_0000) | LEGACY_RELEASE;
    pci.write(loc, LEGACY_OFFSET, written);
}

fn reset(self: *Unit) bool {
    // Stop first. A controller reset while it is running leaves the
    // frame list half walked and the ports in a state nothing describes.
    write16(self, .command, @bitCast(Command{}));
    write16(self, .interrupts, @bitCast(Interrupts{}));

    write16(self, .command, @bitCast(Command{ .global_reset = true }));
    // The bus reset the specification asks for: ten milliseconds of it,
    // and every device on the bus is back at address zero afterwards.
    sys.sleepMicros(15_000);
    write16(self, .command, @bitCast(Command{}));
    sys.sleepMicros(10_000);

    write16(self, .command, @bitCast(Command{ .reset = true }));
    if (!device.settles(200, 1_000, self, struct {
        fn ready(unit: *Unit) bool {
            const now: Command = @bitCast(read16(unit, .command));
            return !now.reset;
        }
    }.ready)) {
        log.fail(name, "the controller would not reset");
        return false;
    }
    return true;
}

fn startSchedule(self: *Unit) void {
    const arena = self.controller.arena.at;

    // Everything hangs off one head, and every frame points at it: the
    // controller visits the same schedule a thousand times a second and
    // finds nothing to do in it until something is queued.
    arena.queue = .{ .link = Link.none, .element = Link.none };
    for (&arena.watches) |*head| head.* = .{};
    chain(self);

    write16(self, .frame_base, 0);
    ports.out32(self.controller.base + @intFromEnum(Reg.frame_base), self.controller.arena.physOf("frames"));
    write16(self, .frame_number, 0);
    ports.out8(self.controller.base + @intFromEnum(Reg.start_of_frame), 64);

    write16(self, .status, @bitCast(Status.ACK));
    write16(self, .interrupts, @bitCast(Interrupts{
        .timeout = true,
        .on_complete = true,
        .short_packet = true,
    }));
    write16(self, .command, @bitCast(Command{ .running = true, .configured = true, .max_packet_64 = true }));

    // The ports carry power already: this controller has no switch for
    // it, which is why there is nothing here to turn on.
}

// ---------------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------------

fn portCount() u8 {
    return PORTS;
}

fn portState(self: *Unit, index: u8) hc.PortState {
    if (!self.controller.opened or index >= PORTS) return .{};
    const port = portRead(self, index);
    return .{
        .connected = port.connected,
        .enabled = port.enabled,
        .speed = if (port.low_speed) .low else .full,
        .changed = port.changed(),
    };
}

fn resetPort(self: *Unit, index: u8) hc.PortState {
    if (!self.controller.opened or index >= PORTS) return .{};

    var port = portRead(self, index).quiet();
    port.reset = true;
    portWrite(self, index, port);
    // The specification's reset: fifty milliseconds, which is longer than
    // the ten a hub uses because a root port has no hub to repeat it.
    sys.sleepMicros(50_000);

    port = portRead(self, index).quiet();
    port.reset = false;
    portWrite(self, index, port);
    sys.sleepMicros(10_000);

    // Enabling is a separate step here, unlike on the fast controller
    // where the reset does it. A port that will not enable has nothing on
    // it worth talking to.
    var attempts: u8 = 0;
    while (attempts < 10) : (attempts += 1) {
        port = portRead(self, index);
        if (!port.connected) return .{};

        if (port.enabled) break;

        var wanted = port.quiet();
        wanted.enabled = true;
        portWrite(self, index, wanted);
        sys.sleepMicros(10_000);

        // The change bits are cleared as they appear: an enable that
        // flickered is the port settling, not a device coming and going.
        const settling = portRead(self, index);
        if (settling.changed()) portWrite(self, index, acknowledge(settling));
    } else return .{ .connected = true };

    return .{
        .connected = true,
        .enabled = true,
        .speed = if (port.low_speed) .low else .full,
    };
}

/// A port register written back with only its change bits set, which is
/// how they are cleared without disturbing anything else.
fn acknowledge(port: Port) Port {
    var copy = port.quiet();
    copy.connection_changed = port.connection_changed;
    copy.enable_changed = port.enable_changed;
    return copy;
}

/// The two ways this controller stops itself: the bus refused one of its
/// reads or writes, or it found its own schedule malformed. Either way it
/// has halted and nothing on it works again until it is rebuilt, so spend
/// the one clean rebuild, and close if it happens again: its ports are
/// lost until the next usbd start.
fn stopped(self: *Unit, status: Status) void {
    log.begin(name, .warn);
    out.text(if (status.process_error)
        "the controller found its own schedule malformed"
    else
        "a host system error");
    pci.tellBusTrouble(self.controller.location);
    log.end();

    const first_stop = !self.controller.rebuilt;
    self.controller.rebuilt = true;
    if (first_stop and reset(self)) {
        log.warn(name, "rebuilding the controller");
        startSchedule(self);
        return;
    }
    _ = reset(self);
    self.controller.opened = false;
    log.fail(name, "closed; its ports are lost until the next usbd start");
}

fn serviceIrq(self: *Unit) hc.Service {
    if (!self.controller.opened) return .quiet;

    const status: Status = @bitCast(read16(self, .status));

    // Write back only the bits that were set: a blanket acknowledgement
    // would swallow something that arrived between the read and the write.
    write16(self, .status, @bitCast(status));

    if (status.host_system_error or status.process_error) {
        stopped(self, status);
        return .reborn;
    }

    // This controller has no interrupt of its own for a port changing, so
    // the ports are read whenever it interrupts for anything, and once
    // more each time the bus asks. A change is rare and the read is two
    // I/O cycles.
    var index: u8 = 0;
    var moved = false;
    while (index < PORTS) : (index += 1) {
        const port = portRead(self, index);
        if (!port.changed()) continue;
        portWrite(self, index, acknowledge(port));
        moved = true;
    }
    return if (moved) .ports_changed else .quiet;
}

// ---------------------------------------------------------------------------
// Transfers
// ---------------------------------------------------------------------------

/// Where a chain of packets is aimed. Less than a pipe, because a control
/// transfer's stages share one of these and each carries its own toggle.
const Aim = struct {
    address: u7,
    endpoint: u4 = 0,
    low_speed: bool = false,
    max_packet: u16 = 8,
};

/// Build a chain of descriptors covering `bytes` at `offset` into the
/// arena's buffer, one per packet, toggling as it goes. Returns how many
/// descriptors it used.
///
/// This controller has no notion of a transfer larger than a packet: a
/// descriptor is one packet on the wire, so anything longer is a chain of
/// them and the toggle alternates down it.
fn packets(self: *Unit, 
    at: usize,
    pid: Pid,
    pipe: Aim,
    offset: u32,
    bytes: usize,
    toggle: *bool,
) usize {
    const arena = self.controller.arena.at;
    const size: usize = @max(@min(pipe.max_packet, 64), 1);
    const base = self.controller.arena.physOf("buffer") + offset;

    var used: usize = 0;
    var done: usize = 0;
    while (used == 0 or done < bytes) {
        if (at + used >= arena.chain.len) break;
        const take = @min(bytes - done, size);

        arena.chain[at + used] = .{
            .link = Link.none,
            .control = .{
                .active = true,
                .low_speed = pipe.low_speed,
                .error_limit = 3,
                .moved = Control.NOTHING,
            },
            .token = .{
                .pid = pid,
                .address = pipe.address,
                .endpoint = pipe.endpoint,
                .toggle = toggle.*,
                .length = Token.sized(take),
            },
            .buffer = if (take == 0) 0 else base + @as(u32, @intCast(done)),
        };
        toggle.* = !toggle.*;

        used += 1;
        done += take;
        if (bytes == 0) break;
    }
    return used;
}

/// Chain descriptors together and hand them to the queue head, the last
/// one asking for an interrupt so one transfer costs one wake.
fn queue(self: *Unit, count: usize) void {
    const arena = self.controller.arena.at;
    if (count == 0) return;

    for (0..count - 1) |i| {
        arena.chain[i].link = Link.toTransfer(self.controller.arena.physOfIndex("chain", i + 1), true);
    }
    arena.chain[count - 1].link = Link.none;
    arena.chain[count - 1].control.interrupt_on_complete = true;

    arena.queue.element = Link.toTransfer(self.controller.arena.physOf("chain"), true);
}

/// A controller of this kind is full speed itself, so it talks to a slow
/// device the same way whether a hub is in between or not: the route says
/// nothing it has to act on.
fn control(self: *Unit, pipe: usb.Pipe, setup: usb.Setup, data: []u8) hc.Error!usize {
    if (!self.controller.opened) return hc.Error.Refused;
    if (data.len > BUFFER_BYTES - usb.Setup.BYTES) return hc.Error.Refused;

    const arena = self.controller.arena.at;
    const low = pipe.speed == .low;
    const endpoint = Aim{ .address = pipe.address, .low_speed = low, .max_packet = pipe.max_packet };

    const reading = setup.request_type.direction == .in;
    const wants_data = setup.length != 0 and data.len != 0;

    @memcpy(@as([*]u8, @ptrCast(@volatileCast(&arena.buffer)))[0..usb.Setup.BYTES], std.mem.asBytes(&setup));
    if (wants_data and !reading) {
        @memcpy(@as([*]u8, @ptrCast(@volatileCast(&arena.buffer)))[usb.Setup.BYTES..][0..data.len], data);
    }

    // Setup is always DATA0, the data stage starts at DATA1 and
    // alternates, and the status stage is always DATA1.
    var toggle = false;
    var used = packets(self, 0, .setup, endpoint, 0, usb.Setup.BYTES, &toggle);

    var data_at: usize = 0;
    if (wants_data) {
        toggle = true;
        data_at = used;
        used += packets(self, used, if (reading) .in else .out, endpoint, usb.Setup.BYTES, data.len, &toggle);
    }

    toggle = true;
    used += packets(self, 
        used,
        switch (setup.statusDirection()) {
            .in => .in,
            .out => .out,
        },
        endpoint,
        0,
        0,
        &toggle,
    );

    queue(self, used);
    try settle(self, used, 1_000_000);

    if (!wants_data) return 0;

    var moved: usize = 0;
    var i = data_at;
    while (i < data_at + (used - STAGES + 1) and i < arena.chain.len) : (i += 1) {
        if (arena.chain[i].token.pid == .setup) continue;
        moved += arena.chain[i].control.bytes();
    }
    moved = @min(moved, data.len);

    if (reading and moved != 0) {
        const from: [*]const u8 = @ptrCast(@volatileCast(&arena.buffer));
        @memcpy(data[0..moved], from[usb.Setup.BYTES..][0..moved]);
    }
    return moved;
}

fn bulkLimit() usize {
    return BUFFER_BYTES;
}

fn bulk(self: *Unit, pipe: *usb.Pipe, data: []u8) hc.Error!usize {
    if (!self.controller.opened) return hc.Error.Refused;
    if (data.len > BUFFER_BYTES) return hc.Error.Refused;

    const arena = self.controller.arena.at;
    const writing = pipe.direction == .out;
    if (writing and data.len != 0) {
        @memcpy(@as([*]u8, @ptrCast(@volatileCast(&arena.buffer)))[0..data.len], data);
    }

    var toggle = pipe.toggle;
    const used = packets(self, 0, if (writing) .out else .in, .{
        .address = pipe.address,
        .endpoint = pipe.number,
        .low_speed = pipe.speed == .low,
        .max_packet = pipe.max_packet,
    }, 0, data.len, &toggle);


    queue(self, used);
    try settle(self, used, 5_000_000);

    var moved: usize = 0;
    for (0..used) |i| moved += arena.chain[i].control.bytes();
    moved = @min(moved, data.len);

    pipe.advance(moved);
    if (!writing and moved != 0) {
        const from: [*]const u8 = @ptrCast(@volatileCast(&arena.buffer));
        @memcpy(data[0..moved], from[0..moved]);
    }
    return moved;
}

/// Wait for a queued chain, on the controller's interrupt rather than on
/// the clock, and say what became of it.
fn settle(self: *Unit, count: usize, patience_us: u32) hc.Error!void {
    const arena = self.controller.arena.at;

    var waited: u32 = 0;
    while (waited < patience_us) {
        rest(self);
        waited += REST_US;
        if (!arena.chain[count - 1].control.active) break;
        if (failedAnywhere(self, count)) break;
    }

    for (0..count) |i| {
        const status = arena.chain[i].control;
        if (status.failed()) {
            // The queue stops at a failure and would stay stopped, so it
            // is cleared before anything else is asked of it.
            arena.queue.element = Link.none;
            return hc.Error.Stalled;
        }
        if (status.active) {
            arena.queue.element = Link.none;
            return hc.Error.Timeout;
        }
    }
}

fn failedAnywhere(self: *Unit, count: usize) bool {
    const arena = self.controller.arena.at;
    for (0..count) |i| {
        if (arena.chain[i].control.failed()) return true;
    }
    return false;
}

const REST_US: u32 = 50_000;

fn rest(self: *Unit) void {
    if (self.controller.irq != 0) {
        _ = sys.eventWait(self.controller.irq, REST_US);
        _ = sys.irqAck(self.controller.irq, serviceIrq(self) != .quiet);
    } else {
        sys.sleepMicros(REST_US);
    }
}

// ---------------------------------------------------------------------------
// Watched endpoints
// ---------------------------------------------------------------------------

fn watch(self: *Unit, pipe: usb.Pipe, report_bytes: u8) hc.Error!u8 {
    if (!self.controller.opened) return hc.Error.Refused;
    if (report_bytes == 0 or report_bytes > REPORT_BYTES) return hc.Error.Refused;

    const entry = table.free(&self.watches) orelse return hc.Error.Refused;
    const index = table.indexOf(&self.watches, entry);
    entry.* = .{ .live = true, .pipe = pipe, .report_bytes = report_bytes };

    arm(self, index);
    chain(self);
    return @intCast(index);
}

/// Put a fresh descriptor under a watch's head. The controller visits it
/// every frame and the device answers with nothing until it has something
/// to say, so a keyboard sitting still costs no interrupts.
fn arm(self: *Unit, index: usize) void {
    const arena = self.controller.arena.at;
    const entry = &self.watches[index];

    arena.watch_tds[index] = .{
        .link = Link.none,
        .control = .{
            .active = true,
            .low_speed = entry.pipe.speed == .low,
            .interrupt_on_complete = true,
            .short_packet_detect = true,
            // Retry forever: an endpoint being polled answers with a
            // negative acknowledgement until it has something, and a
            // limit here would eventually give up on a quiet keyboard.
            .error_limit = 0,
            .moved = Control.NOTHING,
        },
        .token = .{
            .pid = .in,
            .address = entry.pipe.address,
            .endpoint = entry.pipe.number,
            .toggle = entry.pipe.toggle,
            .length = Token.sized(entry.report_bytes),
        },
        .buffer = self.controller.arena.physOfIndex("reports", index),
    };

    arena.watches[index].element = Link.toTransfer(self.controller.arena.physOfIndex("watch_tds", index), true);
}

/// Link every head into one list and point every frame at the first. The
/// on-demand head goes last so a transfer being waited on does not sit
/// behind a keyboard that is answering nothing.
fn chain(self: *Unit) void {
    const arena = self.controller.arena.at;
    const on_demand = Link.toQueue(self.controller.arena.physOf("queue"));

    var first: ?usize = null;
    var previous: ?usize = null;
    for (&self.watches, 0..) |*entry, i| {
        if (!entry.live) continue;
        if (previous) |before| {
            arena.watches[before].link = Link.toQueue(self.controller.arena.physOfIndex("watches", i));
        } else {
            first = i;
        }
        arena.watches[i].link = on_demand;
        previous = i;
    }

    const head = if (first) |i|
        Link.toQueue(self.controller.arena.physOfIndex("watches", i))
    else
        on_demand;
    for (&arena.frames) |*frame| frame.* = head;
}

fn collect(self: *Unit, index: u8, into: []u8) ?usize {
    if (index >= self.watches.len or !self.watches[index].live) return null;
    const arena = self.controller.arena.at;
    const status = arena.watch_tds[index].control;

    if (status.active) return null;
    if (status.failed()) return null;

    const moved = @min(status.bytes(), into.len);
    if (moved != 0) {
        const from: [*]const u8 = @ptrCast(@volatileCast(&arena.reports[index]));
        @memcpy(into[0..moved], from[0..moved]);
    }

    self.watches[index].pipe.advance(status.bytes());
    arm(self, index);
    return moved;
}

fn unwatch(self: *Unit, index: u8) void {
    if (index >= self.watches.len or !self.watches[index].live) return;
    self.controller.arena.at.watches[index].element = Link.none;
    self.watches[index] = .{};
    chain(self);
}

// ---------------------------------------------------------------------------
// The seam
// ---------------------------------------------------------------------------

/// One driver body, bound to one of its units at compile time: the ops
/// table stays instance-blind and the binding costs nothing at run time.
pub fn unitOps(comptime unit: u8) hc.HcOps {
    const bound = struct {
        const self = &units[unit];
        fn open_(loc: pci.Location) bool {
            return open(self, loc);
        }
        fn port_(index: u8) hc.PortState {
            return portState(self, index);
        }
        fn resetPort_(index: u8) hc.PortState {
            return resetPort(self, index);
        }
        fn serviceIrq_() hc.Service {
            return serviceIrq(self);
        }
        fn control_(pipe: usb.Pipe, setup: usb.Setup, data: []u8) hc.Error!usize {
            return control(self, pipe, setup, data);
        }
        fn bulk_(pipe: *usb.Pipe, data: []u8) hc.Error!usize {
            return bulk(self, pipe, data);
        }
        fn watch_(pipe: usb.Pipe, report_bytes: u8) hc.Error!u8 {
            return watch(self, pipe, report_bytes);
        }
        fn collect_(index: u8, into: []u8) ?usize {
            return collect(self, index, into);
        }
        fn unwatch_(index: u8) void {
            unwatch(self, index);
        }
    };
    return .{
        .open = bound.open_,
        .ports = portCount,
        .port = bound.port_,
        .resetPort = bound.resetPort_,
        .serviceIrq = bound.serviceIrq_,
        .control = bound.control_,
        .bulk = bound.bulk_,
        .bulkLimit = bulkLimit,
        .watch = bound.watch_,
        .collect = bound.collect_,
        .unwatch = bound.unwatch_,
    };
}

pub fn unitListen(comptime unit: u8) *const fn (u32) void {
    return struct {
        fn listen(irq: u32) void {
            units[unit].controller.irq = irq;
        }
    }.listen;
}
