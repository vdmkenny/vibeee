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
const causes = @import("causes.zig");
const hc = @import("hc.zig");
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const sys = @import("sys");
const ehci = lib.ehci;
const transfer = @import("ehci/transfer.zig");
const usb = lib.usb;

const Barrier = sys.barrier;
const Link = transfer.Link;
const Pid = transfer.Pid;
const Transfer = transfer.Transfer;

pub const name = "ehci";

/// The capability file is small and the operational file follows it; a
/// kilobyte covers both on every part of this class.
const MMIO_BYTES: u32 = 1024;

// ---------------------------------------------------------------------------
// Registers
// ---------------------------------------------------------------------------

const Length = packed struct(u32) {
    /// Where the operational registers begin, from the capability base.
    operational: u8,
    _8: u8,
    version: u16,
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

    /// Interrupts this driver enables. Frame list rollover is off: nothing
    /// here counts frames.
    const TAKEN = Interrupts{
        .transfer = true,
        .transfer_error = true,
        .port_change = true,
        .host_error = true,
        .async_advance = true,
    };

    /// `TAKEN` without port change, while a transfer waits with a port
    /// change latched.
    const HOLDING = holding: {
        var taken = TAKEN;
        taken.port_change = false;
        break :holding taken;
    };
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
}

// ---------------------------------------------------------------------------
// The schedule's own structures
// ---------------------------------------------------------------------------

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
    /// Transactions per microframe, as the endpoint's descriptor asked for
    /// it. One for everything but a high-speed endpoint wanting more
    /// bandwidth than a single packet a microframe gives it.
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
    /// Out to ninety-six bytes: a whole number of the thirty-two byte
    /// strides the controller requires of every head in an array.
    _pad: [4]u32 = @splat(0),
};

comptime {
    if (@sizeOf(QueueHead) != 96) @compileError("an extended queue head is ninety-six bytes");
    if (@as(u32, @bitCast(EndpointInfo{ .head_of_list = true })) != 0x8000 or
        @as(u32, @bitCast(EndpointInfo{ .speed = .high })) != 0x2000 or
        @as(u32, @bitCast(EndpointInfo{ .max_packet = 64 })) != 0x0040_0000)
    {
        @compileError("the endpoint information's bits drifted");
    }
}

/// How many stages one control transfer needs: setup, data, status.
const STAGES = 3;

/// How many endpoints may have a read standing on them at once: a
/// keyboard, a mouse, a hub's port changes, and a serial port's pair of
/// a notice endpoint and a stream of bytes.
const WATCHES = 8;

/// The most one standing read takes in at a time. A high speed bulk
/// endpoint sends five hundred and twelve bytes to a packet and a device
/// answering with more than was asked for is a failed transfer, so this
/// is the largest packet rather than the largest useful read; boot
/// protocol reports are eight bytes and fit many times over.
const REPORT_BYTES = 512;

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
    capability: lib.mmio.Window(ehci.CapabilityRegister, u32) = undefined,
    /// At the capability registers' base plus their length.
    operational: lib.mmio.Window(Op, u32) = undefined,
    location: pci.Location = .{ .bus = 0, .device = 0, .function = 0 },
    arena: device.Dma(Arena) = undefined,
    ports: u8 = 0,
    port_power: bool = false,
    opened: bool = false,
    /// Whether the part addresses sixty-four bits: decides if the segment
    /// register exists to be written.
    wide: bool = false,
    /// The one clean rebuild a host system error is answered with.
    rebuilt: bool = false,
    /// The interrupt this controller's transfers wait on.
    irq: u32 = 0,
    /// A port change latched during a transfer's wait. Its interrupt is
    /// disabled until the transfer ends.
    ports_held: bool = false,
    /// A transfer's wait found the controller failed and rebuilt or closed
    /// it. Reported by the next `serviceIrq`.
    reborn: bool = false,
};

var controller: Device = .{};

fn bulkLimit() usize {
    return BULK_BYTES;
}

fn watchLimit() usize {
    return REPORT_BYTES;
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
    if (!pipe.route.splits(pipe.speed, .high)) return .{ .multiplier = pipe.per_microframe };
    return .{
        .hub_address = pipe.route.hub,
        .port = pipe.route.port,
        .multiplier = pipe.per_microframe,
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
    /// How much is asked for each time round, which is at least one of
    /// the endpoint's packets and at most what the arena holds.
    wanted: u16 = 0,
};

var watches: [WATCHES]Watch = @splat(.{});

/// Leave a read standing on an endpoint.
///
/// The work is the controller's: the head goes in the periodic schedule
/// and is visited once a millisecond, the device answers with something
/// or with nothing, and only something ends the transfer and raises the
/// interrupt. A keyboard nobody is typing on produces no wakes at all,
/// and neither does a serial port nobody is sending to.
///
/// A bulk endpoint watched this way is asked once a frame rather than as
/// often as the schedule comes round to it, which is the one thing given
/// up for having a single shape here: five hundred and twelve bytes a
/// millisecond is far more than a serial line carries and far less than
/// a disk wants, which is why a disk is read by asking rather than by
/// leaving a read standing.
fn watch(pipe: usb.Pipe, wanted: u16) hc.Error!u8 {
    if (!controller.opened) return hc.Error.Refused;
    if (wanted == 0 or wanted > REPORT_BYTES) return hc.Error.Refused;

    const entry = table.free(&watches) orelse return hc.Error.Refused;
    const index = table.indexOf(&watches, entry);
    watches[index] = .{ .live = true, .pipe = pipe, .wanted = wanted };

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
        // One transaction a microframe, beginning in the first of each
        // frame. The endpoint's own interval would poll less often; a
        // millisecond costs the controller a token and nobody else
        // anything, and it is what a keyboard wants anyway. A slow
        // endpoint behind a hub needs the second half of its split
        // collected as well, which is what the complete mask asks for.
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

    // A report is sixty-four bytes at most, which reaches two pages at
    // most, so the descriptor always has the pointers for it.
    arena.watch_tds[index] = (describe(
        .in,
        entry.pipe.toggle,
        controller.arena.physOfIndex("reports", index),
        @intCast(entry.wanted),
        true,
    )) orelse unreachable;
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

    // A halted endpoint has stopped answering and will keep not
    // answering: re-arming it would poll a dead pipe forever, so it is
    // left alone until whoever owns it clears the halt.
    const moved = switch (transfer.result(Barrier, (&arena.watch_tds[index])[0..1], .{ .asked = watches[index].wanted })) {
        .moved => |bytes| bytes,
        .unfinished, .failed => return null,
    };

    // Bounded by who is asking as well as by what the watch armed.
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
/// Hand a parked queue head a chain. The schedule keeps running the whole
/// time: everything is written while the head's overlay still says there
/// is nothing to follow, and the word that changes that is written last,
/// whole, so the controller meets either nothing or the finished chain.
/// The stale next is cleared first, because a head left halted by a
/// failed transfer still points at the chain that failed it.
fn feed(
    head: *volatile QueueHead,
    info: EndpointInfo,
    capabilities: EndpointCapabilities,
    first: u32,
) void {
    head.overlay.next = Link.none;
    head.overlay.alternate = Link.none;
    head.overlay.token = .{};
    head.current = 0;
    head.info = info;
    head.capabilities = capabilities;
    head.overlay.next = Link.to(first, .isochronous);
}

/// Take a queue head back from a chain that never finished: the one pause
/// of the running schedule, because the controller may hold any part of
/// the chain in hand, and the pause is what makes it let go before the
/// head is parked again.
fn reclaim(head: *volatile QueueHead) void {
    scheduleRunning(.asynchronous, false);
    head.overlay.next = Link.none;
    head.overlay.alternate = Link.none;
    head.overlay.token = .{};
    head.current = 0;
    scheduleRunning(.asynchronous, true);
}

fn bulk(pipe: *usb.Pipe, data: []u8) hc.Error!usize {
    if (!controller.opened) return hc.Error.Refused;
    if (data.len > BULK_BYTES) return hc.Error.Refused;

    const arena = controller.arena.at;
    const writing = pipe.direction == .out;
    if (writing and data.len != 0) {
        @memcpy(@as([*]u8, @ptrCast(@volatileCast(&arena.bulk_buffer)))[0..data.len], data);
    }

    arena.payload = (describe(
        if (writing) .out else .in,
        pipe.toggle,
        controller.arena.physOf("bulk_buffer"),
        @intCast(data.len),
        true,
    )) orelse return hc.Error.Refused;
    arena.payload.next = Link.none;

    feed(&arena.bulk, .{
        .address = pipe.address,
        .endpoint = pipe.number,
        .speed = speedOf(pipe.speed),
        .toggle_from_descriptor = true,
        .max_packet = @intCast(pipe.max_packet),
        .reload = 4,
    }, reach(pipe.*), controller.arena.physOf("payload"));

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
    defer releasePorts();
    const arena = controller.arena.at;
    const payload = (&arena.payload)[0..1];

    var waited_us: u32 = 0;
    const DEADLINE_US: u32 = 5_000_000;
    while (waited_us < DEADLINE_US) {
        // A rebuild discards the schedule the payload was on.
        if (rest() == .reborn) return hc.Error.Refused;
        waited_us += REST_US;
        if (transfer.settled(Barrier, payload)) break;
    }

    return switch (transfer.result(Barrier, payload, .{ .asked = asked })) {
        .moved => |bytes| bytes,
        .failed => hc.Error.Stalled,
        .unfinished => {
            sayUnfinished("the bulk transfer", &arena.bulk, payload);
            reclaim(&arena.bulk);
            return hc.Error.Timeout;
        },
    };
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
    .watchLimit = watchLimit,
    .unwatch = unwatch,
    .quiesce = quiesce,
    .rebuild = rebuildController,
};

/// The interrupt handle is given after the controller opens, because the
/// line is only routed once the device is claimed.
pub fn listenOn(irq: u32) void {
    controller.irq = irq;
}

// ---------------------------------------------------------------------------
// Register access
// ---------------------------------------------------------------------------

fn capRead(register: ehci.CapabilityRegister) u32 {
    return controller.capability.read(register);
}

fn opRead(register: Op) u32 {
    return controller.operational.read(register);
}

fn opWrite(register: Op, value: u32) void {
    controller.operational.write(register, value);
}

/// Where port `index` is, from the operational registers.
fn portOffset(index: u8) usize {
    return @intFromEnum(Op.port_base) + @as(usize, index) * @sizeOf(Port);
}

fn portRead(index: u8) Port {
    return @bitCast(controller.operational.readAt(portOffset(index)));
}

fn portWrite(index: u8, value: Port) void {
    controller.operational.writeAt(portOffset(index), @bitCast(value));
}

// ---------------------------------------------------------------------------
// Bring-up
// ---------------------------------------------------------------------------

fn open(loc: pci.Location) bool {
    if (controller.opened) return false;

    // The firmware traps writes to this part's configuration, the base
    // address and command words included, and answers them in management
    // mode with its hands back on the controller. So the aperture is
    // reached with reads alone, ownership is taken, and only then are the
    // trapped words written: the sizing probe and the enables fire no
    // traps once nothing is armed to hear them. A firmware driving the
    // controller always leaves it decoded; a part found undecoded has no
    // firmware behind it and is switched on first.
    const base = pci.memoryBase(loc, 0) orelse {
        log.fail(name, "the controller exposes no register aperture");
        return false;
    };
    if (!pci.readCommand(loc).memory_space) pci.enableMemoryAndMaster(loc);
    const aperture = sys.mapDevice(base, MMIO_BYTES) orelse {
        log.fail(name, "cannot map registers");
        return false;
    };

    controller.capability = .{ .base = @ptrCast(aperture) };
    controller.location = loc;
    const length: Length = @bitCast(capRead(.length));
    controller.operational = .{ .base = controller.capability.base + length.operational };

    const structural: Structural = @bitCast(capRead(.structural));
    controller.ports = structural.ports;
    controller.port_power = structural.port_power_control;
    if (controller.ports == 0) {
        log.fail(name, "the controller reports no ports");
        return false;
    }

    // The firmware has been driving this controller to read the boot
    // medium. Taking it politely, before the first trapped word, is what
    // stops its management code from fighting us for the ports afterwards.
    const capabilities: ehci.Capabilities = @bitCast(capRead(.capabilities));
    controller.wide = capabilities.addresses_64bit;
    takeFromFirmware(capabilities);
    _ = pci.sizeWindow(loc, 0, MMIO_BYTES, name, "controller");
    pci.enableMemoryAndMaster(loc);

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
/// let go, and turn off every interrupt into the firmware.
fn takeFromFirmware(caps: ehci.Capabilities) void {
    const legacy = caps.legacy() orelse return;

    var support: ehci.LegacySupport = @bitCast(pci.read(controller.location, legacy.at(.support)));
    if (support.id != .legacy_support) return;

    support.system_owned = true;
    pci.write(controller.location, legacy.at(.support), @bitCast(support));

    const yielded = device.settles(100, 10_000, legacy, struct {
        fn ready(place: ehci.LegacyPlace) bool {
            const now: ehci.LegacySupport = @bitCast(pci.read(controller.location, place.at(.support)));
            return !now.firmware_owned;
        }
    }.ready);

    if (!yielded) {
        // The controller is reset next, so a firmware that keeps it is
        // overridden.
        log.warn(name, "the firmware would not hand the controller over; taking it");
        pci.write(controller.location, legacy.at(.support), @bitCast(support.seized()));
    }

    pci.write(controller.location, legacy.at(.control), @bitCast(ehci.LegacyControl.RELEASED));
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
    // The working heads park passively: nothing active, nothing halted,
    // and a next that terminates. The controller passes over them at the
    // cost of one fetch, and a transfer is handed over by rewriting that
    // one word, never by stopping the schedule.
    controller.arena.at.control = .{
        .link = Link.to(controller.arena.physOf("bulk"), .queue_head),
        .info = .{ .toggle_from_descriptor = true, .speed = .high, .max_packet = 64 },
    };
    controller.arena.at.bulk = .{
        .link = Link.to(anchor_physical, .queue_head),
        .info = .{ .toggle_from_descriptor = true, .speed = .high, .max_packet = 512 },
    };

    if (controller.wide) opWrite(.segment, 0);
    opWrite(.periodic_base, controller.arena.physOf("frames"));
    opWrite(.async_base, anchor_physical);

    opWrite(.interrupts, @bitCast(Interrupts.TAKEN));
    controller.ports_held = false;

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
        // The specification gives a device a hundred milliseconds from
        // power to attach; looking sooner reads an empty port that is
        // merely still waking.
        sys.sleepMicros(usb.ATTACH_DEBOUNCE_US);
    }
}

// ---------------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------------

fn portCount() u8 {
    return if (controller.opened) controller.ports else 0;
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

/// Acknowledge the controller's causes until none is latched. Reports a
/// port change, or a rebuild in this pass or in a transfer's wait.
fn serviceIrq() hc.Service {
    const reborn = controller.reborn;
    controller.reborn = false;
    if (!controller.opened) return if (reborn) .reborn else .quiet;

    var ports_changed = false;
    var worked = false;
    for (0..causes.ROUNDS) |_| {
        const taken = causes.intersect(@as(Status, @bitCast(opRead(.status))), Interrupts.TAKEN);
        if (taken == Status{}) break;
        worked = true;
        // Write-one-to-clear, the causes read only: one latched after the
        // read stays for the next round.
        opWrite(.status, @bitCast(taken));
        if (taken.host_error) {
            hostError();
            return .reborn;
        }
        if (taken.port_change) ports_changed = true;
    }
    if (reborn) return .reborn;
    if (ports_changed) return .ports_changed;
    return if (worked) .serviced else .quiet;
}

/// A host system error is the controller saying the bus refused one of its
/// own reads or writes. The schedules halt and the port state machines
/// stop with them, so nothing on this controller works again until it is
/// rebuilt. Narrate what it was holding, spend the one clean rebuild, and
/// if the error comes back, close: a controller that cannot be trusted
/// with the bus keeps its ports from the companions for nothing.
fn hostError() void {
    log.begin(name, .warn);
    out.text("a host system error while walking ");
    out.hex(opRead(.async_base), 8);
    out.text("; the arena is at ");
    out.hex(controller.arena.phys.addr(), 8);
    pci.tellBusTrouble(controller.location);
    log.end();

    // The firmware is the only other party that can move this controller.
    // Its occurred bits record every base address and command write, this
    // driver's included, so only an enabled event or a moved semaphore is
    // reported. The rebuild takes the controller back either way.
    const caps: ehci.Capabilities = @bitCast(capRead(.capabilities));
    if (caps.legacy()) |legacy| {
        const support: ehci.LegacySupport = @bitCast(pci.read(controller.location, legacy.at(.support)));
        const traps: ehci.LegacyControl = @bitCast(pci.read(controller.location, legacy.at(.control)));
        if (support.id == .legacy_support and
            (support.firmware_owned or !support.system_owned or traps.armed()))
        {
            log.begin(name, .warn);
            out.text("the firmware is armed on the controller: owner bits ");
            out.hex(@as(u32, @bitCast(support)), 8);
            out.text(", traps ");
            out.hex(@as(u32, @bitCast(traps)), 8);
            log.end();
        }
    }

    if (controller.rebuilt) {
        surrender();
        return;
    }
    controller.rebuilt = true;
    log.warn(name, "rebuilding the controller");
    takeFromFirmware(caps);
    if (reset()) startSchedule() else surrender();
}

/// Stop everything, for a machine about to take the power away.
///
/// The one clean rebuild a fatal error earns is spent and given back here:
/// a controller put down deliberately and brought back is not one that
/// went wrong, and holding the mark against it would close it for good the
/// first time it did.
fn quiesce() void {
    if (!controller.opened) return;
    _ = reset();
    controller.rebuilt = false;
}

/// And build it again, as at the first open.
fn rebuildController() bool {
    if (!controller.opened) return false;
    takeFromFirmware(@bitCast(capRead(.capabilities)));
    if (!reset()) {
        controller.opened = false;
        return false;
    }
    startSchedule();
    return true;
}

/// Close the controller and route every port to the companions, which can
/// at least carry the same devices at full speed. The companions notice
/// nothing on their own, so the handover finishes on the next usbd start.
fn surrender() void {
    _ = reset();
    opWrite(.configured, 0);
    controller.opened = false;
    log.fail(name, "closed; the ports fall to the companions on the next usbd start");
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
    arena.stages[0] = describe(.setup, false, setup_page, usb.Setup.BYTES, false) orelse return hc.Error.Refused;
    stages += 1;

    if (wants_data) {
        arena.stages[1] = (describe(
            if (reading) .in else .out,
            true,
            data_page,
            @intCast(data.len),
            false,
        )) orelse return hc.Error.Refused;
        stages += 1;
    }

    // The status stage runs against the data stage, and the setup packet
    // is what knows which way that is. It alone interrupts: one transfer,
    // one wake, however many stages it took.
    arena.stages[stages] = (describe(
        switch (setup.statusDirection()) {
            .in => .in,
            .out => .out,
        },
        true,
        0,
        0,
        true,
    )) orelse return hc.Error.Refused;
    stages += 1;

    // Chain them, and end the chain.
    for (0..stages - 1) |i| {
        arena.stages[i].next = Link.to(controller.arena.physOfIndex("stages", i + 1), .isochronous);
    }
    arena.stages[stages - 1].next = Link.none;

    // Point the head at this device and hand it the chain, the schedule
    // still running: the handoff is the overlay's next word, written last.
    feed(&arena.control, .{
        .address = pipe.address,
        .endpoint = 0,
        .speed = speedOf(pipe.speed),
        .toggle_from_descriptor = true,
        .max_packet = @intCast(pipe.max_packet),
        .control_endpoint = pipe.speed != .high,
        .reload = 4,
    }, reach(pipe), controller.arena.physOf("stages"));

    return try awaitStages(stages, data, reading, wants_data);
}

/// One stage of a control transfer.
fn describe(pid: Pid, toggle: bool, page: u32, bytes: u15, interrupt: bool) ?Transfer {
    return transfer.spanning(pid, toggle, page, bytes, interrupt);
}

/// How long one wait step lasts. Long enough that a transfer nobody
/// answers costs a handful of wakes, short enough that a deadline is
/// still measured in the units it is written in.
const REST_US: u32 = 50_000;

/// One wait step: on the controller's interrupt, or on the clock before the
/// line is routed.
fn rest() hc.Rest {
    if (controller.irq == 0) {
        sys.sleepMicros(REST_US);
        return .waited;
    }

    sys.eventWait(controller.irq, REST_US) catch {};
    const outcome = takeTransferCauses();
    sys.irqAck(controller.irq, outcome != .waited);
    return outcome;
}

/// Acknowledge transfer and failure causes until none is latched. A port
/// change stays latched, with its interrupt disabled until the transfer
/// ends.
fn takeTransferCauses() hc.Rest {
    var worked = false;
    for (0..causes.ROUNDS) |_| {
        const latched: Status = @bitCast(opRead(.status));
        if (latched.port_change and !controller.ports_held) {
            enable(Interrupts.HOLDING);
            controller.ports_held = true;
        }
        const taken = causes.intersect(latched, Interrupts.HOLDING);
        if (taken == Status{}) return if (worked) .worked else .waited;
        opWrite(.status, @bitCast(taken));
        worked = true;
        if (taken.host_error) {
            hostError();
            controller.reborn = true;
            return .reborn;
        }
    }
    return .worked;
}

/// After a transfer: enable a held port change interrupt again. The change
/// is still latched, so the controller interrupts for `serviceIrq`.
fn releasePorts() void {
    if (!controller.ports_held) return;
    controller.ports_held = false;
    if (controller.opened) enable(Interrupts.TAKEN);
}

/// Write the interrupt enables, then a status write that clears nothing:
/// QEMU's controller updates its interrupt line only on a status write.
fn enable(interrupts: Interrupts) void {
    opWrite(.interrupts, @bitCast(interrupts));
    opWrite(.status, @bitCast(Status{}));
}

/// What became of a transfer that did not finish: every descriptor's
/// state, and whether the head was ever advanced onto them. A device that
/// answers nothing and a schedule that never reached the head look the
/// same from outside and want opposite fixes, and this is the reading
/// that tells them apart.
fn sayUnfinished(
    what: []const u8,
    head: *volatile QueueHead,
    descriptors: []volatile Transfer,
) void {
    log.begin(name, .dim);
    out.text(what);
    out.text(": ");
    for (descriptors, 0..) |*descriptor, i| {
        if (i != 0) out.text(", ");
        const token = descriptor.token;
        out.text(switch (token.pid) {
            .setup => "setup",
            .in => "in",
            .out => "out",
            _ => "?",
        });
        out.byte(' ');
        const status = token.status;
        if (status.transaction_error) {
            out.text("unanswered on the wire");
        } else if (status.babble) {
            out.text("babbled over");
        } else if (status.buffer_error) {
            out.text("starved of memory");
        } else if (status.halted) {
            out.text("refused");
        } else if (status.active) {
            out.text("never served");
        } else {
            out.text("done");
        }
    }

    // Where the head stands. A current pointer of zero with a descriptor
    // still active means the controller never advanced onto the chain at
    // all, which is a different illness from a device saying nothing.
    out.text("; the head stands at ");
    out.hex(head.current, 8);
    out.text(" holding ");
    out.hex(@as(u32, @bitCast(head.overlay.token)), 8);
    const running: Status = @bitCast(opRead(.status));
    if (!running.async_running) out.text("; the asynchronous schedule is not running");
    log.end();
}

fn awaitStages(stages: usize, data: []u8, reading: bool, wants_data: bool) hc.Error!usize {
    defer releasePorts();
    const arena = controller.arena.at;
    const descriptors = arena.stages[0..stages];

    // The deadline is generous: a device answering a descriptor request
    // is fast, and a device that has gone away is what the deadline is
    // for. The wait is on the controller's interrupt, so a machine with
    // nothing to do here does nothing.
    var waited_us: u32 = 0;
    const DEADLINE_US: u32 = 1_000_000;
    while (waited_us < DEADLINE_US) {
        // A rebuild discards the schedule the stages were on.
        if (rest() == .reborn) return hc.Error.Refused;
        waited_us += REST_US;
        if (transfer.settled(Barrier, descriptors)) break;
    }

    // A failure is narrated stage by stage: which were served, which the
    // controller still owes, and what the wire said, which tells a schedule
    // nobody walks from a device nobody hears.
    const counted: ?transfer.Counted = if (wants_data) .{ .stage = 1, .asked = data.len } else null;
    const moved = switch (transfer.result(Barrier, descriptors, counted)) {
        .moved => |bytes| bytes,
        .failed => {
            sayUnfinished("the transfer's stages", &arena.control, descriptors);
            return hc.Error.Stalled;
        },
        .unfinished => {
            sayUnfinished("the transfer's stages", &arena.control, descriptors);
            // A halted head has been let go; a chain still active is
            // still the controller's, and is taken back before reuse.
            reclaim(&arena.control);
            return hc.Error.Timeout;
        },
    };

    if (reading and moved != 0) {
        const from: [*]const u8 = @ptrCast(@volatileCast(&arena.buffer));
        @memcpy(data[0..moved], from[usb.Setup.BYTES..][0..moved]);
    }
    return moved;
}

const std = @import("std");
