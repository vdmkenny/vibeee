//! The enhanced host controller: the high-speed half of USB.
//!
//! Two register files and two schedules. The capability file says what
//! the silicon is; the operational file is what gets driven. The
//! asynchronous schedule is a ring of queue heads the controller walks
//! forever, each head owning one endpoint and a chain of transfer
//! descriptors; the periodic schedule is for polled endpoints and stays
//! empty here.
//!
//! Every field is named. A controller register written as a magic word
//! is a register nobody can check, and this one has to be right before
//! anything else in the system can see a disk.
//!
//! Nothing spins. A transfer waits on the controller's own interrupt
//! with a deadline, and the deadline exists only so a device that has
//! gone away costs a wait rather than the machine.

const device = @import("ulib").device;
const table = @import("ulib").table;
const hc = @import("hc.zig");
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const sys = @import("sys");
const usb = lib.usb;

pub const name = "ehci";

/// The capability file is small and the operational file follows it; a
/// kilobyte covers both on every part of this class.
const MMIO_BYTES: usize = 1024;

// ---------------------------------------------------------------------------
// Registers
// ---------------------------------------------------------------------------

/// The capability file, at the aperture's base.
const Cap = enum(usize) {
    length = 0x00,
    structural = 0x04,
    capabilities = 0x08,
};

/// The operational file, at the base plus the capability file's length.
const Op = enum(usize) {
    command = 0x00,
    status = 0x04,
    interrupts = 0x08,
    frame_index = 0x0C,
    segment = 0x10,
    periodic_base = 0x14,
    async_base = 0x18,
    configured = 0x40,
    port_base = 0x44,
};

const Structural = packed struct(u32) {
    ports: u4 = 0,
    port_power_control: bool = false,
    routing_rules: bool = false,
    _6: u2 = 0,
    ports_per_companion: u4 = 0,
    companions: u4 = 0,
    port_indicators: bool = false,
    _17: u7 = 0,
    debug_port: u4 = 0,
    _28: u4 = 0,
};

const Capabilities = packed struct(u32) {
    addresses_64bit: bool = false,
    programmable_frame_list: bool = false,
    async_park: bool = false,
    _3: u1 = 0,
    isochronous_threshold: u4 = 0,
    /// Where the extended capabilities begin in configuration space, and
    /// with them the handshake that takes the controller from firmware.
    extended_capabilities: u8 = 0,
    _16: u16 = 0,
};

const Command = packed struct(u32) {
    running: bool = false,
    reset: bool = false,
    frame_list_size: u2 = 0,
    periodic_enable: bool = false,
    async_enable: bool = false,
    /// The doorbell: rung to learn when the controller has finished
    /// looking at a queue head that was unlinked.
    async_doorbell: bool = false,
    light_reset: bool = false,
    async_park_count: u2 = 0,
    _10: u1 = 0,
    async_park_enable: bool = false,
    _12: u4 = 0,
    /// How many microframes between interrupts at most.
    interrupt_threshold: u8 = 0,
    _24: u8 = 0,
};

const Status = packed struct(u32) {
    transfer: bool = false,
    transfer_error: bool = false,
    port_change: bool = false,
    frame_rollover: bool = false,
    host_error: bool = false,
    async_advance: bool = false,
    _6: u6 = 0,
    halted: bool = false,
    reclamation: bool = false,
    periodic_running: bool = false,
    async_running: bool = false,
    _16: u16 = 0,

    /// Everything worth acknowledging, written back to clear.
    const ACK = Status{
        .transfer = true,
        .transfer_error = true,
        .port_change = true,
        .frame_rollover = true,
        .host_error = true,
        .async_advance = true,
    };
};

const Interrupts = packed struct(u32) {
    transfer: bool = false,
    transfer_error: bool = false,
    port_change: bool = false,
    frame_rollover: bool = false,
    host_error: bool = false,
    async_advance: bool = false,
    _6: u26 = 0,
};

/// What the line between a port and a device currently is. The two line
/// state bits are how a full or low speed device is told apart from a
/// high speed one before any packet is sent.
const LineState = enum(u2) {
    single_ended_zero = 0,
    /// A low speed device holds the line here.
    k_state = 1,
    j_state = 2,
    undefined_state = 3,
};

const Port = packed struct(u32) {
    connected: bool = false,
    /// Write one to clear.
    connect_changed: bool = false,
    enabled: bool = false,
    enable_changed: bool = false,
    over_current: bool = false,
    over_current_changed: bool = false,
    force_resume: bool = false,
    suspended: bool = false,
    reset: bool = false,
    _9: u1 = 0,
    line_state: LineState = .single_ended_zero,
    powered: bool = false,
    /// Hand this port to the companion controller: what a full or low
    /// speed device gets, since this controller cannot talk to one.
    owned_by_companion: bool = false,
    indicators: u2 = 0,
    test_control: u4 = 0,
    wake_on_connect: bool = false,
    wake_on_disconnect: bool = false,
    wake_on_over_current: bool = false,
    _23: u9 = 0,

    /// The change bits, which are written back to clear and must never
    /// be set accidentally when writing the register for another reason.
    const CHANGES = Port{
        .connect_changed = true,
        .enable_changed = true,
        .over_current_changed = true,
    };

    /// This register with every write-to-clear bit off, so a write that
    /// means to change one thing does not silently acknowledge another.
    fn quiet(self: Port) Port {
        var copy = self;
        copy.connect_changed = false;
        copy.enable_changed = false;
        copy.over_current_changed = false;
        return copy;
    }
};

/// The legacy support capability in configuration space: the handshake
/// that takes the controller away from the firmware.
const LegacySupport = packed struct(u32) {
    id: u8 = 0,
    next: u8 = 0,
    /// The firmware owns the controller while this is set.
    firmware_owned: bool = false,
    _17: u7 = 0,
    /// The system claims it by setting this and waiting.
    system_owned: bool = false,
    _25: u7 = 0,

    const CAPABILITY_ID: u8 = 0x01;
};

comptime {
    if (@as(u32, @bitCast(Command{ .running = true })) != 0x01 or
        @as(u32, @bitCast(Command{ .reset = true })) != 0x02 or
        @as(u32, @bitCast(Command{ .async_enable = true })) != 0x20)
    {
        @compileError("the command register's bits drifted");
    }
    if (@as(u32, @bitCast(Status{ .halted = true })) != 0x1000) {
        @compileError("the halted bit drifted");
    }
    if (@as(u32, @bitCast(Port{ .reset = true })) != 0x100 or
        @as(u32, @bitCast(Port{ .owned_by_companion = true })) != 0x2000)
    {
        @compileError("the port register's bits drifted");
    }
    if (@as(u32, @bitCast(LegacySupport{ .system_owned = true })) != 0x0100_0000) {
        @compileError("the legacy handshake's bits drifted");
    }
}

// ---------------------------------------------------------------------------
// The schedule's own structures
// ---------------------------------------------------------------------------

/// What a link pointer points at, which the controller reads from the
/// pointer's own low bits.
const LinkKind = enum(u2) {
    isochronous = 0,
    queue_head = 1,
    split_isochronous = 2,
    frame_span = 3,
};

const Link = packed struct(u32) {
    /// Nothing follows: the end of a chain.
    terminate: bool = true,
    kind: LinkKind = .queue_head,
    _3: u2 = 0,
    /// The address, which is why everything in a schedule is aligned to
    /// thirty-two bytes.
    address: u27 = 0,

    fn to(physical: u32, kind: LinkKind) Link {
        return .{ .terminate = false, .kind = kind, .address = @intCast(physical >> 5) };
    }

    const none = Link{};
};

/// What a transfer descriptor is doing, and what became of it.
const TransferStatus = packed struct(u8) {
    ping: bool = false,
    split_state: bool = false,
    missed_microframe: bool = false,
    transaction_error: bool = false,
    babble: bool = false,
    buffer_error: bool = false,
    /// The device said no, or the controller gave up on it.
    halted: bool = false,
    /// The controller still has work to do here.
    active: bool = false,

    fn failed(self: TransferStatus) bool {
        return self.halted or self.transaction_error or self.babble or self.buffer_error;
    }
};

const Pid = enum(u2) {
    out = 0,
    in = 1,
    setup = 2,
    _,
};

const Token = packed struct(u32) {
    status: TransferStatus = .{},
    pid: Pid = .out,
    error_limit: u2 = 3,
    page: u3 = 0,
    /// Interrupt when this descriptor completes.
    interrupt: bool = false,
    bytes: u15 = 0,
    /// The toggle, which the device and the host must agree on.
    toggle: bool = false,
};

/// A transfer descriptor: one stage of one transfer.
const Transfer = extern struct {
    next: Link = Link.none,
    alternate: Link = Link.none,
    token: Token = .{},
    pages: [5]u32 = @splat(0),
};

/// Where the controller keeps everything it knows about one endpoint.
const EndpointInfo = packed struct(u32) {
    address: u7 = 0,
    inactivate: bool = false,
    endpoint: u4 = 0,
    speed: EndpointSpeed = .full,
    /// Take the toggle from the descriptor rather than the queue head,
    /// which is what lets a control transfer's stages carry their own.
    toggle_from_descriptor: bool = false,
    /// This head is the ring's own anchor.
    head_of_list: bool = false,
    max_packet: u11 = 0,
    control_endpoint: bool = false,
    reload: u4 = 0,
};

const EndpointSpeed = enum(u2) {
    full = 0,
    low = 1,
    high = 2,
    _,
};

const EndpointCapabilities = packed struct(u32) {
    start_mask: u8 = 0,
    complete_mask: u8 = 0,
    hub_address: u7 = 0,
    port: u7 = 0,
    /// Transactions per microframe; one is the only value used here.
    multiplier: u2 = 1,
};

/// A queue head: one endpoint's place in the ring, with the current
/// transfer copied into its own overlay by the controller as it works.
const QueueHead = extern struct {
    link: Link = Link.none,
    info: EndpointInfo = .{},
    capabilities: EndpointCapabilities = .{},
    current: u32 = 0,
    overlay: Transfer = .{},
    /// To sixty-four bytes, which is what the controller's cache line
    /// wants and what the alignment of the pool assumes.
    _pad: [4]u32 = @splat(0),
};

comptime {
    if (@sizeOf(Transfer) != 32) @compileError("a transfer descriptor is thirty-two bytes");
    if (@sizeOf(QueueHead) != 64) @compileError("a queue head is sixty-four bytes");
    if (@as(u32, @bitCast(Token{ .status = .{ .active = true }, .error_limit = 0 })) != 0x80) {
        @compileError("the transfer token's status drifted");
    }
    if (@as(u32, @bitCast(Token{ .pid = .setup, .error_limit = 0 })) != 0x200) {
        @compileError("the transfer token's packet identifier drifted");
    }
    if (@as(u32, @bitCast(EndpointInfo{ .head_of_list = true })) != 0x8000 or
        @as(u32, @bitCast(EndpointInfo{ .speed = .high })) != 0x2000 or
        @as(u32, @bitCast(EndpointInfo{ .max_packet = 64 })) != 0x0040_0000)
    {
        @compileError("the endpoint information's bits drifted");
    }
}

/// How many stages one control transfer needs: setup, data, status.
const STAGES = 3;

/// How many interrupt endpoints may be watched at once: a keyboard, a
/// mouse, and room for the pair on a device that is both.
const WATCHES = 4;

/// The largest report a watched endpoint may carry. Boot protocol
/// reports are eight bytes; this covers those and the ones that add a
/// wheel or a few more bits.
const REPORT_BYTES = 16;

/// The largest bulk transfer carried in one go. A transfer descriptor
/// addresses five pages, so one descriptor covers this whole buffer and
/// a bulk transfer is always a single descriptor.
const BULK_BYTES = 16 * 1024;

/// The largest answer a device gives during enumeration. A configuration
/// with every descriptor it carries fits comfortably; anything longer is
/// read in pieces by whoever wants it.
const BUFFER_BYTES = 1024;

const Arena = extern struct {
    /// The ring's anchor, which points at itself and never moves.
    anchor: QueueHead align(64) = .{},
    /// One head for whichever device is being spoken to. Control
    /// transfers are one at a time by construction here: enumeration is
    /// sequential and nothing else has an endpoint yet.
    control: QueueHead align(64) = .{},
    /// One head for whichever endpoint is moving data. Bulk transfers
    /// are one at a time by construction: the class drivers above are
    /// request-and-answer, and a second request waits for the first.
    bulk: QueueHead align(64) = .{},
    stages: [STAGES]Transfer align(32) = @splat(.{}),
    payload: Transfer align(32) = .{},
    buffer: [BUFFER_BYTES]u8 align(4096) = @splat(0),
    bulk_buffer: [BULK_BYTES]u8 align(4096) = @splat(0),
    /// One head and one descriptor per watched endpoint, chained into
    /// every frame so the controller visits them once a millisecond.
    watches: [WATCHES]QueueHead align(64) = @splat(.{}),
    watch_tds: [WATCHES]Transfer align(32) = @splat(.{}),
    reports: [WATCHES][REPORT_BYTES]u8 align(32) = @splat(@splat(0)),
    /// Every entry empty: the periodic schedule stays off, but the
    /// controller wants a valid base address regardless.
    frames: [1024]Link align(4096) = @splat(Link.none),
};

const Device = struct {
    base: [*]volatile u8 = undefined,
    /// Where the operational registers begin.
    op: usize = 0,
    location: pci.Location = .{ .bus = 0, .device = 0, .function = 0 },
    arena: device.Dma(Arena) = undefined,
    ports: u8 = 0,
    port_power: bool = false,
    opened: bool = false,
    /// The interrupt this controller's transfers wait on.
    irq: u32 = 0,
};

var controller: Device = .{};

fn bulkLimit() usize {
    return BULK_BYTES;
}

fn speedOf(speed: usb.Speed) EndpointSpeed {
    return switch (speed) {
        .high => .high,
        .full => .full,
        .low => .low,
    };
}

/// How the controller reaches a device: directly, or by splitting every
/// transaction and addressing the halves at the hub in between.
///
/// A high speed bus cannot slow down for a full or low speed device, so a
/// hub does it instead: the controller sends the request to the hub at
/// full speed and comes back later for the answer. Naming the hub and its
/// port is the whole of what this side has to do about it.
fn reach(pipe: usb.Pipe) EndpointCapabilities {
    if (!pipe.route.splits(pipe.speed, .high)) return .{ .multiplier = 1 };
    return .{
        .hub_address = pipe.route.hub,
        .port = pipe.route.port,
        .multiplier = 1,
    };
}

/// The same, for an endpoint the controller polls. A split transaction is
/// begun in one microframe and collected in later ones, so both halves
/// have to be asked for.
fn periodic(pipe: usb.Pipe) EndpointCapabilities {
    var capabilities = reach(pipe);
    capabilities.start_mask = 0x01;
    if (pipe.route.splits(pipe.speed, .high)) capabilities.complete_mask = 0x1C;
    return capabilities;
}

// ---------------------------------------------------------------------------
// Watched endpoints
// ---------------------------------------------------------------------------

/// What is known about one interrupt endpoint being polled.
const Watch = struct {
    live: bool = false,
    pipe: usb.Pipe = .{},
    /// How many bytes the device's reports are, which is how much is
    /// asked for each time round.
    report_bytes: u8 = 0,
};

var watches: [WATCHES]Watch = @splat(.{});

/// Start polling an interrupt endpoint.
///
/// The work is the controller's: the head goes in the periodic schedule
/// and is visited once a millisecond, the device answers with a report or
/// with nothing, and only a report ends the transfer and raises the
/// interrupt. A keyboard nobody is typing on produces no wakes at all.
fn watch(pipe: usb.Pipe, report_bytes: u8) hc.Error!u8 {
    if (!controller.opened) return hc.Error.Refused;
    if (report_bytes == 0 or report_bytes > REPORT_BYTES) return hc.Error.Refused;

    const entry = table.free(&watches) orelse return hc.Error.Refused;
    const index = table.indexOf(&watches, entry);
    watches[index] = .{ .live = true, .pipe = pipe, .report_bytes = report_bytes };

    const arena = controller.arena.at;
    scheduleRunning(.periodic, false);

    arena.watches[index] = .{
        .link = Link.none,
        .info = .{
            .address = pipe.address,
            .endpoint = pipe.number,
            .speed = speedOf(pipe.speed),
            .toggle_from_descriptor = true,
            .max_packet = @intCast(@min(pipe.max_packet, REPORT_BYTES)),
        },
        // One transaction, in the first microframe of each frame. The
        // endpoint's own interval would poll less often; a millisecond
        // costs the controller a token and nobody else anything, and it
        // is what a keyboard wants anyway. A slow endpoint behind a hub
        // needs the second half of its split collected as well, which is
        // what the complete mask asks for.
        .capabilities = periodic(pipe),
    };

    arena.watches[index].current = 0;
    arena.watches[index].overlay = .{};
    arm(index);
    chain();
    scheduleRunning(.periodic, true);
    return @intCast(index);
}

/// Make a watch's descriptor ready for the next report, and hand it back
/// to the head.
///
/// The head consumes the pointer as it works: a finished transfer leaves
/// the overlay's next pointer terminating, so re-arming is two writes and
/// not one. Both are allowed while the schedule runs, because a head with
/// nothing active is a head the controller is only looking at.
///
/// The order is the order the controller reads them: the descriptor is
/// complete before anything points at it, so a controller looking between
/// the two writes finds an empty queue rather than half a transfer.
fn arm(index: usize) void {
    const arena = controller.arena.at;
    const entry = &watches[index];

    arena.watch_tds[index] = describe(
        .in,
        entry.pipe.toggle,
        controller.arena.physOfIndex("reports", index),
        entry.report_bytes,
        true,
    );
    arena.watch_tds[index].next = Link.none;

    arena.watches[index].current = 0;
    arena.watches[index].overlay.token = .{};
    arena.watches[index].overlay.alternate = Link.none;
    arena.watches[index].overlay.next =
        Link.to(controller.arena.physOfIndex("watch_tds", index), .isochronous);
}

/// Link every live watch into one chain, and point every frame at it. A
/// frame list of a thousand identical pointers is what "visit these once
/// a millisecond" looks like to the controller.
fn chain() void {
    const arena = controller.arena.at;

    var first: ?usize = null;
    var previous: ?usize = null;
    for (&watches, 0..) |*entry, i| {
        if (!entry.live) continue;
        if (previous) |before| {
            arena.watches[before].link = Link.to(controller.arena.physOfIndex("watches", i), .queue_head);
        } else {
            first = i;
        }
        arena.watches[i].link = Link.none;
        previous = i;
    }

    const head = if (first) |i|
        Link.to(controller.arena.physOfIndex("watches", i), .queue_head)
    else
        Link.none;
    for (&arena.frames) |*frame| frame.* = head;
}

/// Whatever a watched endpoint answered with since it was last asked. The
/// watch is re-armed here, so a caller that stops asking stops receiving
/// rather than being asked to remember a second call.
fn collect(index: u8, into: []u8) ?usize {
    if (index >= watches.len or !watches[index].live) return null;
    const arena = controller.arena.at;
    const token = arena.watch_tds[index].token;

    if (token.status.active) return null;

    // A halted endpoint has stopped answering and will keep not
    // answering: re-arming it would poll a dead pipe forever, so it is
    // left alone until whoever owns it clears the halt.
    if (token.status.failed()) return null;

    const moved = @as(usize, watches[index].report_bytes) - @as(usize, token.bytes);
    const wanted = @min(moved, into.len);
    if (wanted != 0) {
        const from: [*]const u8 = @ptrCast(@volatileCast(&arena.reports[index]));
        @memcpy(into[0..wanted], from[0..wanted]);
    }

    // The queue head advances itself: its overlay goes inactive when the
    // transfer ends, and the descriptor it already points at is picked up
    // again as soon as it is made active. Nothing here stops a schedule
    // to say so.
    watches[index].pipe.advance(moved);
    arm(index);
    return wanted;
}

fn unwatch(index: u8) void {
    if (index >= watches.len or !watches[index].live) return;
    scheduleRunning(.periodic, false);
    watches[index] = .{};
    chain();
    scheduleRunning(.periodic, true);
}



/// One bulk transfer: a single descriptor, because the buffer it points
/// at is contiguous and no larger than the five pages one descriptor
/// addresses. The pipe carries the toggle in and takes it out advanced
/// by what moved, so a short answer does not desynchronise the endpoint.
fn bulk(pipe: *usb.Pipe, data: []u8) hc.Error!usize {
    if (!controller.opened) return hc.Error.Refused;
    if (data.len > BULK_BYTES) return hc.Error.Refused;

    const arena = controller.arena.at;
    const writing = pipe.direction == .out;
    if (writing and data.len != 0) {
        @memcpy(@as([*]u8, @ptrCast(@volatileCast(&arena.bulk_buffer)))[0..data.len], data);
    }

    arena.payload = describe(
        if (writing) .out else .in,
        pipe.toggle,
        controller.arena.physOf("bulk_buffer"),
        @intCast(data.len),
        true,
    );
    arena.payload.next = Link.none;

    scheduleRunning(.asynchronous, false);
    arena.bulk.info = .{
        .address = pipe.address,
        .endpoint = pipe.number,
        .speed = speedOf(pipe.speed),
        .toggle_from_descriptor = true,
        .max_packet = @intCast(pipe.max_packet),
        .reload = 4,
    };
    arena.bulk.capabilities = reach(pipe.*);
    arena.bulk.current = 0;
    arena.bulk.overlay = .{ .next = Link.to(controller.arena.physOf("payload"), .isochronous) };
    scheduleRunning(.asynchronous, true);

    const moved = try awaitPayload(data.len);
    pipe.advance(moved);

    if (!writing and moved != 0) {
        const from: [*]const u8 = @ptrCast(@volatileCast(&arena.bulk_buffer));
        @memcpy(data[0..moved], from[0..moved]);
    }
    return moved;
}

/// Wait for the one descriptor a bulk transfer uses, on the controller's
/// interrupt rather than on the clock.
fn awaitPayload(asked: usize) hc.Error!usize {
    const arena = controller.arena.at;

    var waited_us: u32 = 0;
    const DEADLINE_US: u32 = 5_000_000;
    while (waited_us < DEADLINE_US) {
        rest();
        waited_us += REST_US;

        const token = arena.payload.token;
        if (!token.status.active or token.status.failed()) break;
    }

    const token = arena.payload.token;
    if (token.status.failed()) return hc.Error.Stalled;
    if (token.status.active) return hc.Error.Timeout;
    // The controller counts down what it did not carry, so a short
    // answer shows up as bytes left over.
    return asked - @as(usize, token.bytes);
}

pub const ops = hc.HcOps{
    .open = open,
    .ports = portCount,
    .port = portState,
    .resetPort = resetPort,
    .serviceIrq = serviceIrq,
    .control = control,
    .bulk = bulk,
    .bulkLimit = bulkLimit,
    .watch = watch,
    .collect = collect,
    .unwatch = unwatch,
};

/// The interrupt handle is given after the controller opens, because the
/// line is only routed once the device is claimed.
pub fn listenOn(irq: u32) void {
    controller.irq = irq;
}

// ---------------------------------------------------------------------------
// Register access
// ---------------------------------------------------------------------------

fn capRead(register: Cap) u32 {
    const at: *const volatile u32 = @ptrCast(@alignCast(controller.base + @intFromEnum(register)));
    return at.*;
}

fn opRead(register: Op) u32 {
    const at: *const volatile u32 = @ptrCast(@alignCast(controller.base + controller.op + @intFromEnum(register)));
    return at.*;
}

fn opWrite(register: Op, value: u32) void {
    const at: *volatile u32 = @ptrCast(@alignCast(controller.base + controller.op + @intFromEnum(register)));
    at.* = value;
}

fn portRead(index: u8) Port {
    const offset = controller.op + @intFromEnum(Op.port_base) + @as(usize, index) * 4;
    const at: *const volatile u32 = @ptrCast(@alignCast(controller.base + offset));
    return @bitCast(at.*);
}

fn portWrite(index: u8, value: Port) void {
    const offset = controller.op + @intFromEnum(Op.port_base) + @as(usize, index) * 4;
    const at: *volatile u32 = @ptrCast(@alignCast(controller.base + offset));
    at.* = @bitCast(value);
}

// ---------------------------------------------------------------------------
// Bring-up
// ---------------------------------------------------------------------------

fn open(loc: pci.Location) bool {
    const base = pci.memoryBase(loc, 0) orelse {
        log.fail(name, "the controller exposes no register aperture");
        return false;
    };
    const aperture = sys.mapDevice(base, MMIO_BYTES) orelse {
        log.fail(name, "cannot map registers");
        return false;
    };
    pci.enableMemoryAndMaster(loc);

    controller.base = @ptrCast(aperture);
    controller.location = loc;
    controller.op = capRead(.length) & 0xFF;

    const structural: Structural = @bitCast(capRead(.structural));
    controller.ports = structural.ports;
    controller.port_power = structural.port_power_control;
    if (controller.ports == 0) {
        log.fail(name, "the controller reports no ports");
        return false;
    }

    // The firmware has been driving this controller to read the boot
    // medium. Taking it politely, before touching an operational
    // register, is what stops its management code from fighting us for
    // the ports afterwards.
    takeFromFirmware(@bitCast(capRead(.capabilities)));

    controller.arena = device.Dma(Arena).alloc(name) orelse return false;
    if (!reset()) return false;

    startSchedule();
    controller.opened = true;

    log.begin(name, .key);
    out.decimal(controller.ports);
    out.text(" ports, ");
    out.decimal(structural.companions);
    out.text(" companion controllers");
    log.end();
    return true;
}

/// The legacy handshake: claim the controller, wait for the firmware to
/// let go, and silence the management interrupts it was using.
fn takeFromFirmware(caps: Capabilities) void {
    const at = caps.extended_capabilities;
    if (at < 0x40) return;

    var legacy: LegacySupport = @bitCast(pci.read(controller.location, at));
    if (legacy.id != LegacySupport.CAPABILITY_ID) return;

    legacy.system_owned = true;
    pci.write(controller.location, at, @bitCast(legacy));

    const yielded = device.settles(100, 10_000, at, struct {
        fn ready(offset: u8) bool {
            const now: LegacySupport = @bitCast(pci.read(controller.location, offset));
            return !now.firmware_owned;
        }
    }.ready);

    if (!yielded) {
        // A firmware that will not let go is taken from: it has no
        // business in a controller this system is about to reset, and
        // the alternative is a machine that cannot use its own disk.
        log.warn(name, "the firmware would not hand the controller over; taking it");
        pci.write(controller.location, at, @bitCast(LegacySupport{
            .id = legacy.id,
            .next = legacy.next,
            .system_owned = true,
        }));
    }

    // Whatever it was asking to be told about, it is not told any more.
    pci.write(controller.location, at + 4, 0);
}

fn reset() bool {
    // Halt first: resetting a running controller is undefined, and this
    // one has been running since the firmware read the boot medium.
    var command: Command = @bitCast(opRead(.command));
    command.running = false;
    opWrite(.command, @bitCast(command));

    if (!device.settles(160, 100, {}, struct {
        fn ready(_: void) bool {
            const status: Status = @bitCast(opRead(.status));
            return status.halted;
        }
    }.ready)) {
        log.fail(name, "the controller would not halt");
        return false;
    }

    opWrite(.command, @bitCast(Command{ .reset = true }));
    if (!device.settles(250, 1000, {}, struct {
        fn ready(_: void) bool {
            const now: Command = @bitCast(opRead(.command));
            return !now.reset;
        }
    }.ready)) {
        log.fail(name, "the controller would not reset");
        return false;
    }
    return true;
}

/// The ring, the schedule, and the ports: everything that turns a reset
/// controller into one carrying traffic.
fn startSchedule() void {
    const anchor_physical = controller.arena.physOf("anchor");

    // A ring of one: the anchor points at itself, and the control head
    // is linked in behind it. The controller walks this forever, which
    // costs it nothing while every head is idle.
    controller.arena.at.anchor = .{
        .link = Link.to(controller.arena.physOf("control"), .queue_head),
        .info = .{ .head_of_list = true, .max_packet = 64, .speed = .high },
        .overlay = .{ .token = .{ .status = .{ .halted = true } } },
    };
    controller.arena.at.control = .{
        .link = Link.to(controller.arena.physOf("bulk"), .queue_head),
        .info = .{ .toggle_from_descriptor = true, .speed = .high, .max_packet = 64 },
        .overlay = .{ .token = .{ .status = .{ .halted = true } } },
    };
    controller.arena.at.bulk = .{
        .link = Link.to(anchor_physical, .queue_head),
        .info = .{ .toggle_from_descriptor = true, .speed = .high, .max_packet = 512 },
        .overlay = .{ .token = .{ .status = .{ .halted = true } } },
    };

    opWrite(.segment, 0);
    opWrite(.periodic_base, controller.arena.physOf("frames"));
    opWrite(.async_base, anchor_physical);

    // Every interrupt this driver acts on. The frame-list rollover is
    // left out: nothing here counts frames, and a controller that
    // interrupts a thousand times a second for nobody is a machine
    // spending its life in an interrupt handler.
    opWrite(.interrupts, @bitCast(Interrupts{
        .transfer = true,
        .transfer_error = true,
        .port_change = true,
        .host_error = true,
        .async_advance = true,
    }));

    opWrite(.command, @bitCast(Command{
        .running = true,
        .async_enable = true,
        .interrupt_threshold = 8,
    }));

    // Route every port here rather than to the companions. A full or
    // low speed device is handed back one port at a time, on the reset
    // that discovers what it is.
    opWrite(.configured, 1);

    if (controller.port_power) {
        var index: u8 = 0;
        while (index < controller.ports) : (index += 1) {
            var port = portRead(index).quiet();
            port.powered = true;
            portWrite(index, port);
        }
        // The specification's own settling time for power to reach a
        // device and its pull-ups to mean anything.
        sys.sleepMicros(20_000);
    }
}

// ---------------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------------

fn portCount() u8 {
    return controller.ports;
}

fn portState(index: u8) hc.PortState {
    if (!controller.opened or index >= controller.ports) return .{};
    const port = portRead(index);
    return .{
        .connected = port.connected,
        .enabled = port.enabled,
        .changed = port.connect_changed,
        .released = port.owned_by_companion,
        .speed = .high,
    };
}

/// Reset one port, and find out what is on it. A device that turns out
/// not to be high speed is handed to the companion controller, which is
/// the only thing this controller can do with it.
fn resetPort(index: u8) hc.PortState {
    if (!controller.opened or index >= controller.ports) return .{};

    var port = portRead(index);
    if (!port.connected) return .{};

    // Acknowledge the connection before resetting, so a change reported
    // afterwards is a new one.
    portWrite(index, blk: {
        var acknowledged = port.quiet();
        acknowledged.connect_changed = true;
        break :blk acknowledged;
    });

    // A device holding the line low is low speed and cannot be spoken to
    // here at all; the companion takes it without a reset.
    port = portRead(index);
    if (port.line_state == .k_state) return release(index, .low);

    var resetting = port.quiet();
    resetting.reset = true;
    resetting.enabled = false;
    portWrite(index, resetting);
    // The specification's reset duration; the controller times the
    // signalling itself once the bit clears.
    sys.sleepMicros(50_000);

    resetting.reset = false;
    portWrite(index, resetting);

    if (!device.settles(20, 1000, index, struct {
        fn ready(at: u8) bool {
            return !portRead(at).reset;
        }
    }.ready)) {
        log.warn(name, "a port would not come out of reset");
        return .{};
    }

    // The controller enables the port only for a device it can carry.
    // Anything else is full speed, and belongs to the companion.
    port = portRead(index);
    if (!port.enabled) return release(index, .full);

    return .{ .connected = true, .enabled = true, .speed = .high };
}

fn release(index: u8, speed: usb.Speed) hc.PortState {
    var port = portRead(index).quiet();
    port.owned_by_companion = true;
    portWrite(index, port);
    return .{ .connected = true, .released = true, .speed = speed };
}

/// Acknowledge the controller's interrupt. Returns whether a port
/// changed, which is the only thing the bus above needs to be told.
fn serviceIrq() bool {
    if (!controller.opened) return false;

    const status: Status = @bitCast(opRead(.status));
    if (status.host_error) log.warn(name, "the controller reported a host system error");

    // Write-one-to-clear, and only the bits that were actually set: a
    // blanket acknowledgement would swallow a change that arrived
    // between the read and the write.
    opWrite(.status, @bitCast(status));
    return status.port_change;
}

// ---------------------------------------------------------------------------
// Control transfers
// ---------------------------------------------------------------------------

/// One control transfer, built as its three stages and handed to the
/// controller in one go.
/// The controller caches a queue head for as long as the asynchronous
/// schedule runs, so editing one in place changes nothing it can see:
/// the next transfer goes to the address the last one used. Stopping the
/// schedule is what makes an edit take, because the ring is read from
/// memory again when it starts. Control transfers happen while a device
/// is being enumerated and at no other time, so a bus at rest never pays
/// for this.
const Schedule = enum { asynchronous, periodic };

fn scheduleRunning(which: Schedule, wanted: bool) void {
    var command: Command = @bitCast(opRead(.command));
    const enabled = switch (which) {
        .asynchronous => command.async_enable,
        .periodic => command.periodic_enable,
    };
    if (enabled == wanted) {
        // Still worth waiting for the controller to agree: the enable
        // bit is a request, and the running bit is the answer.
        _ = awaitSchedule(which, wanted);
        return;
    }
    switch (which) {
        .asynchronous => command.async_enable = wanted,
        .periodic => command.periodic_enable = wanted,
    }
    opWrite(.command, @bitCast(command));
    if (!awaitSchedule(which, wanted)) {
        log.warn(name, "a schedule would not change state");
    }
}

fn awaitSchedule(which: Schedule, wanted: bool) bool {
    const Want = struct { which: Schedule, wanted: bool };
    return device.settles(200, 50, Want{ .which = which, .wanted = wanted }, struct {
        fn ready(want: Want) bool {
            const status: Status = @bitCast(opRead(.status));
            const running = switch (want.which) {
                .asynchronous => status.async_running,
                .periodic => status.periodic_running,
            };
            return running == want.wanted;
        }
    }.ready);
}

fn control(pipe: usb.Pipe, setup: usb.Setup, data: []u8) hc.Error!usize {
    if (!controller.opened) return hc.Error.Refused;
    if (data.len > BUFFER_BYTES) return hc.Error.Refused;

    const wants_data = setup.length != 0 and data.len != 0;
    const reading = setup.request_type.direction == .in;

    // The setup packet, then whatever data the request carries, then a
    // status stage in the opposite direction. Every stage's toggle is
    // its own: setup is always zero, data starts at one and alternates,
    // and status is always one.
    const arena = controller.arena.at;
    @memcpy(@as([*]u8, @ptrCast(@volatileCast(&arena.buffer)))[0..usb.Setup.BYTES], std.mem.asBytes(&setup));
    if (wants_data and !reading) {
        @memcpy(@as([*]u8, @ptrCast(@volatileCast(&arena.buffer)))[usb.Setup.BYTES..][0..data.len], data);
    }

    const setup_page = controller.arena.physOf("buffer");
    const data_page = setup_page + usb.Setup.BYTES;

    var stages: usize = 0;
    arena.stages[0] = describe(.setup, false, setup_page, usb.Setup.BYTES, false);
    stages += 1;

    if (wants_data) {
        arena.stages[1] = describe(
            if (reading) .in else .out,
            true,
            data_page,
            @intCast(data.len),
            false,
        );
        stages += 1;
    }

    // The status stage runs against the data stage, and the setup packet
    // is what knows which way that is. It alone interrupts: one transfer,
    // one wake, however many stages it took.
    arena.stages[stages] = describe(
        switch (setup.statusDirection()) {
            .in => .in,
            .out => .out,
        },
        true,
        0,
        0,
        true,
    );
    stages += 1;

    // Chain them, and end the chain.
    for (0..stages - 1) |i| {
        arena.stages[i].next = Link.to(controller.arena.physOfIndex("stages", i + 1), .isochronous);
    }
    arena.stages[stages - 1].next = Link.none;

    // Point the head at this device and hand it the chain. The overlay
    // is cleared rather than edited: whatever the controller left there
    // from the last transfer describes the last transfer.
    scheduleRunning(.asynchronous, false);
    arena.control.info = .{
        .address = pipe.address,
        .endpoint = 0,
        .speed = speedOf(pipe.speed),
        .toggle_from_descriptor = true,
        .max_packet = @intCast(pipe.max_packet),
        .control_endpoint = pipe.speed != .high,
        .reload = 4,
    };
    arena.control.capabilities = reach(pipe);
    arena.control.current = 0;
    arena.control.overlay = .{ .next = Link.to(controller.arena.physOf("stages"), .isochronous) };
    scheduleRunning(.asynchronous, true);

    return try awaitStages(stages, data, reading, wants_data);
}

/// One stage of a control transfer.
fn describe(pid: Pid, toggle: bool, page: u32, bytes: u15, interrupt: bool) Transfer {
    var stage = Transfer{
        .next = Link.none,
        .alternate = Link.none,
        .token = .{
            .status = .{ .active = true },
            .pid = pid,
            .error_limit = 3,
            .interrupt = interrupt,
            .bytes = bytes,
            .toggle = toggle,
        },
    };
    if (bytes != 0) {
        stage.pages[0] = page;
        // A stage never crosses more than one page boundary here: the
        // buffer is page aligned and shorter than two pages.
        stage.pages[1] = (page & ~@as(u32, 0xFFF)) + 0x1000;
    }
    return stage;
}

/// Wait for the controller to finish, on its own interrupt, and read
/// what happened out of the descriptors.
/// How long one wait step lasts. Long enough that a transfer nobody
/// answers costs a handful of wakes, short enough that a deadline is
/// still measured in the units it is written in.
const REST_US: u32 = 50_000;

/// One step of waiting for the controller. The wait is on its interrupt,
/// so a machine with nothing to carry does nothing; before the line is
/// routed, during the first moments of bring-up, there is nothing to
/// wait on but the clock.
fn rest() void {
    if (controller.irq != 0) {
        _ = sys.eventWait(controller.irq, REST_US);
        _ = sys.irqAck(controller.irq, serviceIrq());
    } else {
        sys.sleepMicros(REST_US);
    }
}

fn awaitStages(stages: usize, data: []u8, reading: bool, wants_data: bool) hc.Error!usize {
    const arena = controller.arena.at;

    // The deadline is generous: a device answering a descriptor request
    // is fast, and a device that has gone away is what the deadline is
    // for. The wait is on the controller's interrupt, so a machine with
    // nothing to do here does nothing.
    var waited_us: u32 = 0;
    const DEADLINE_US: u32 = 1_000_000;
    while (waited_us < DEADLINE_US) {
        rest();
        waited_us += REST_US;

        const last = arena.stages[stages - 1].token;
        if (!last.status.active) break;
        if (last.status.failed()) break;
    }

    // Whatever the outcome, it is the descriptors that say so.
    for (0..stages) |i| {
        const token = arena.stages[i].token;
        if (token.status.failed()) return hc.Error.Stalled;
        if (token.status.active) return hc.Error.Timeout;
    }

    if (!wants_data) return 0;

    // The controller counts down what it did not transfer, so what
    // moved is what was asked for less what is left.
    const asked = arena.stages[1].token.bytes;
    const requested: usize = data.len;
    const moved = requested - @as(usize, asked);

    if (reading and moved != 0) {
        const from: [*]const u8 = @ptrCast(@volatileCast(&arena.buffer));
        @memcpy(data[0..moved], from[usb.Setup.BYTES..][0..moved]);
    }
    return moved;
}

const std = @import("std");
