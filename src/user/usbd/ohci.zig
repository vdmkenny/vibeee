//! The Open Host Controller: full and low speed USB in AMD, SiS, ALi,
//! NVIDIA and OPTi chipsets and on add-in cards. The registers and shared
//! structures are the specification's, in `lib.ohci`; how one endpoint's
//! descriptors are queued is `ohci/queue.zig`.
//!
//! A transfer waits on the controller's interrupt, which comes at the end
//! of the frame its last descriptor finishes in, or as soon as one fails.
//! An endpoint with a read standing on it is visited every frame by the
//! controller and costs nothing here until the device answers. The one
//! wait that spins is the reset, which the controller must come out of
//! into operation within two milliseconds, less than a scheduler tick.
//!
//! The seam above is `HcOps`, bound per unit by `hc.unitOps`: a chipset
//! carries its OHCI controllers as separate functions.

const device = @import("ulib").device;
const hc = @import("hc.zig");
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const queue = @import("ohci/queue.zig");
const std = @import("std");
const sys = @import("sys");
const table = @import("ulib").table;

const ohci = lib.ohci;
const usb = lib.usb;

pub const name = "ohci";

/// The register window every controller of this kind decodes.
const MMIO_BYTES: u32 = 4096;

const Regs = lib.mmio.Window(ohci.Register, u32);
const Barrier = sys.barrier;

/// A control transfer's three stages and a tail.
const CONTROL_SLOTS = 4;
const BULK_SLOTS = 2;
const WATCH_SLOTS = 2;

/// Endpoints with a read standing on them at once: a keyboard, a mouse, a
/// hub's port changes, and a serial port's notice and stream endpoints.
const WATCHES = 8;
/// A full speed interrupt endpoint's largest packet.
const REPORT_BYTES = 64;
/// The largest control answer, and the largest bulk transfer this driver
/// carries in one call.
const CONTROL_BYTES = 1024;
const BULK_BYTES = 4096;

/// The most packets of an OUT transfer queued at once. A controller may
/// walk only so many packets of one endpoint in a pass and stop with an
/// unrecoverable error past that, as QEMU's does past thirty-three, so a
/// longer transfer goes a run at a time.
const RUN_PACKETS = 32;

const Arena = extern struct {
    hcca: ohci.Hcca align(4096) = .{},
    control: ohci.Endpoint align(16) = .{},
    bulk: ohci.Endpoint align(16) = .{},
    watches: [WATCHES]ohci.Endpoint align(16) = @splat(.{}),
    control_tds: [CONTROL_SLOTS]ohci.Transfer align(16) = @splat(.{}),
    bulk_tds: [BULK_SLOTS]ohci.Transfer align(16) = @splat(.{}),
    watch_tds: [WATCHES][WATCH_SLOTS]ohci.Transfer align(16) = @splat(@splat(.{})),
    setup: [usb.Setup.BYTES]u8 = @splat(0),
    control_buffer: [CONTROL_BYTES]u8 = @splat(0),
    bulk_buffer: [BULK_BYTES]u8 = @splat(0),
    reports: [WATCHES][REPORT_BYTES]u8 = @splat(@splat(0)),
};

/// Interrupts this driver takes.
const TAKEN = ohci.Interrupts{
    .done = true,
    .unrecoverable = true,
    .hub_changed = true,
    .master = true,
};

// Timing, from the specifications. A sleep lasts at least one scheduler tick.

/// How long the bus is held in reset before the controller is.
const BUS_RESET_US = 50_000;
/// How many looks the controller's own reset may take: ten microseconds.
const RESET_LOOKS = 10_000;
/// How long the firmware is given to let the controller go.
const OWNERSHIP_ATTEMPTS = 50;
const OWNERSHIP_PAUSE_US = 10_000;
/// A root port is reset for fifty milliseconds, in the controller's own
/// pulses of ten.
const PORT_RESET_PULSES = 5;
const PORT_RESET_LOOKS = 20;
const PORT_RESET_PAUSE_US = 10_000;
/// How long a device is left to recover after its port's reset.
const RESET_RECOVERY_US = 10_000;
/// Long enough that the controller has finished the frame it was in.
const FRAME_US = 2_000;

const CONTROL_PATIENCE_US = 1_000_000;
const BULK_PATIENCE_US = 5_000_000;
const REST_US = 50_000;

const ControlQueue = queue.Queue(CONTROL_SLOTS, Barrier);
const BulkQueue = queue.Queue(BULK_SLOTS, Barrier);
const WatchQueue = queue.Queue(WATCH_SLOTS, Barrier);

const Watch = struct {
    live: bool = false,
    pipe: usb.Pipe = .{},
    /// How much is asked for each time round.
    wanted: u16 = 0,
    queue: WatchQueue = undefined,
};

pub const Unit = struct {
    regs: Regs = .{ .base = undefined },
    location: pci.Location = .{ .bus = 0, .device = 0, .function = 0 },
    arena: device.Dma(Arena) = undefined,
    control: ControlQueue = undefined,
    bulk: BulkQueue = undefined,
    watches: [WATCHES]Watch = @splat(.{}),
    /// The frame interval the firmware calibrated, kept across resets.
    interval: ohci.FrameInterval = .{},
    ports: u8 = 0,
    opened: bool = false,
    /// The one clean rebuild a failure is answered with.
    rebuilt: bool = false,
    irq: u32 = 0,
    /// The root hub changed while a transfer waited. Its interrupt was
    /// held back so the wait did not spin on it, and is let through once
    /// the transfer ends, for the bus to hear.
    hub_held: bool = false,
    /// A transfer's wait found the controller failed, and rebuilt or
    /// closed it. The devices the bus knew on it are gone, which the bus
    /// hears at the next interrupt.
    reborn: bool = false,
};

/// An AMD southbridge carries five.
pub const MAX_UNITS = 5;

pub var units: [MAX_UNITS]Unit = @splat(.{});

// ---------------------------------------------------------------------------
// Bring-up
// ---------------------------------------------------------------------------

pub fn open(self: *Unit, loc: pci.Location) bool {
    if (self.opened) return false;

    const aperture = pci.openApertureNeeding(loc, 0, MMIO_BYTES, ohci.REGISTERS_END, name, "controller") orelse return false;
    self.regs = .{ .base = @ptrCast(aperture) };
    self.location = loc;

    takeFromFirmware(self);
    // The memory first: from the reset on, nothing may stand between it
    // and the controller running.
    self.arena = device.Dma(Arena).alloc(name) orelse return abandon(self);
    if (!reset(self)) return abandon(self);
    start(self);
    self.opened = true;

    log.begin(name, .key);
    out.decimal(self.ports);
    out.text(" ports, full and low speed");
    log.end();
    return true;
}

fn abandon(self: *Unit) bool {
    pci.disableInterruptAndMaster(self.location);
    sys.shmUnmap(@volatileCast(self.regs.base));
    return false;
}

/// The firmware's system management code may be running the controller to
/// make a USB keyboard look like an old one. It is asked to let go, and a
/// firmware that holds on past a bounded wait is overridden by the reset.
fn takeFromFirmware(self: *Unit) void {
    const routing: ohci.Control = @bitCast(self.regs.read(.control));
    if (!routing.firmware_routed) return;

    self.regs.write(.interrupt_enable, @bitCast(ohci.Interrupts{ .ownership_changed = true }));
    self.regs.write(.command_status, @bitCast(ohci.CommandStatus{ .ownership_change = true }));
    const released = device.settles(OWNERSHIP_ATTEMPTS, OWNERSHIP_PAUSE_US, self, struct {
        fn released(unit: *Unit) bool {
            const now: ohci.Control = @bitCast(unit.regs.read(.control));
            return !now.firmware_routed;
        }
    }.released);
    if (!released) log.warn(name, "the firmware kept the controller; taking it");
}

/// Every device on the bus reset, then the controller. It comes out of its
/// own reset suspended and must be made operational within two
/// milliseconds, so `start` follows at once.
fn reset(self: *Unit) bool {
    self.regs.write(.interrupt_disable, @bitCast(ohci.Interrupts.ALL));
    const was: ohci.Control = @bitCast(self.regs.read(.control));
    const interval: ohci.FrameInterval = @bitCast(self.regs.read(.frame_interval));

    self.regs.write(.control, @bitCast(ohci.Control{ .remote_wakeup_connected = was.remote_wakeup_connected }));
    _ = self.regs.read(.control);
    sys.sleepMicros(BUS_RESET_US);

    self.regs.write(.command_status, @bitCast(ohci.CommandStatus{ .reset = true }));
    var looks: u32 = 0;
    while (@as(ohci.CommandStatus, @bitCast(self.regs.read(.command_status))).reset) : (looks += 1) {
        if (looks == RESET_LOOKS) {
            log.fail(name, "the controller would not reset");
            return false;
        }
        std.atomic.spinLoopHint();
    }

    self.interval = if (interval.bits == 0) .{} else .{ .bits = interval.bits, .largest_packet = ohci.largestPacket(interval.bits) };
    self.hub_held = false;
    return true;
}

fn start(self: *Unit) void {
    const arena = self.arena.at;
    arena.* = .{};
    self.control = .{ .endpoint = &arena.control, .descriptors = &arena.control_tds, .base = self.arena.physOf("control_tds") };
    self.bulk = .{ .endpoint = &arena.bulk, .descriptors = &arena.bulk_tds, .base = self.arena.physOf("bulk_tds") };
    self.control.reset();
    self.bulk.reset();
    for (&self.watches) |*entry| entry.* = .{};

    self.regs.write(.hcca, self.arena.physOf("hcca"));
    self.regs.write(.control_head, self.arena.physOf("control"));
    self.regs.write(.bulk_head, self.arena.physOf("bulk"));
    // The toggle is what tells the controller the interval is new: flipped
    // from what the register holds now, after the reset.
    const held: ohci.FrameInterval = @bitCast(self.regs.read(.frame_interval));
    var interval = self.interval;
    interval.toggle = !held.toggle;
    self.regs.write(.frame_interval, @bitCast(interval));
    self.regs.write(.periodic_start, @bitCast(ohci.PeriodicStart.of(interval.bits)));
    self.regs.write(.low_speed_threshold, @bitCast(ohci.LowSpeedThreshold{}));
    const was: ohci.Control = @bitCast(self.regs.read(.control));
    self.regs.write(.control, @bitCast(ohci.Control{
        .control_bulk_ratio = 3,
        .periodic_enabled = true,
        .control_enabled = true,
        .bulk_enabled = true,
        .state = .operational,
        .remote_wakeup_connected = was.remote_wakeup_connected,
    }));

    self.regs.write(.interrupt_status, @bitCast(ohci.Interrupts.ALL));
    self.regs.write(.interrupt_enable, @bitCast(TAKEN));

    // Power: every port at once, and each on its own, which between them
    // covers both ways a controller switches it.
    const hub: ohci.HubA = @bitCast(self.regs.read(.hub_a));
    self.ports = @min(hub.ports, ohci.MAX_PORTS);
    self.regs.write(.hub_status, @bitCast(ohci.HubStatus{ .set_power = true }));
    for (0..self.ports) |index| portWrite(self, @intCast(index), .{ .power_on = true });
    if (hub.powerOnUs() > 0) sys.sleepMicros(hub.powerOnUs());
}

// ---------------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------------

fn portRead(self: *Unit, index: u8) ohci.PortStatus {
    return @bitCast(self.regs.readAt(ohci.portOffset(@intCast(index))));
}

fn portWrite(self: *Unit, index: u8, command: ohci.PortCommand) void {
    self.regs.writeAt(ohci.portOffset(@intCast(index)), @bitCast(command));
}

pub fn portCount(self: *Unit) u8 {
    return self.ports;
}

pub fn portState(self: *Unit, index: u8) hc.PortState {
    if (!self.opened or index >= self.ports) return .{};
    const status = portRead(self, index);
    return .{
        .connected = status.connected,
        .enabled = status.enabled,
        .speed = if (status.low_speed) .low else .full,
        .changed = status.changed(),
    };
}

pub fn resetPort(self: *Unit, index: u8) hc.PortState {
    if (!self.opened or index >= self.ports) return .{};

    for (0..PORT_RESET_PULSES) |_| {
        if (!portRead(self, index).connected) return .{};
        portWrite(self, index, .{ .reset = true });
        const Look = struct { unit: *Unit, index: u8 };
        const done = device.settles(PORT_RESET_LOOKS, PORT_RESET_PAUSE_US, Look{ .unit = self, .index = index }, struct {
            fn done(look: Look) bool {
                return !portRead(look.unit, look.index).resetting;
            }
        }.done);
        if (!done) return .{ .connected = true };
    }
    portWrite(self, index, .acknowledging(portRead(self, index)));
    sys.sleepMicros(RESET_RECOVERY_US);

    const status = portRead(self, index);
    if (!status.connected) return .{};
    if (!status.enabled) return .{ .connected = true };
    return .{ .connected = true, .enabled = true, .speed = if (status.low_speed) .low else .full };
}

// ---------------------------------------------------------------------------
// Interrupts
// ---------------------------------------------------------------------------

pub fn serviceIrq(self: *Unit) hc.Service {
    const reborn = self.reborn;
    self.reborn = false;
    if (!self.opened) return if (reborn) .reborn else .quiet;

    const latched: ohci.Interrupts = @bitCast(self.regs.read(.interrupt_status));
    if (latched == ohci.Interrupts.ALL) return gone(self);
    if (latched.done) self.arena.at.hcca.done_head = 0;
    self.regs.write(.interrupt_status, @bitCast(ohci.Interrupts{
        .done = latched.done,
        .unrecoverable = latched.unrecoverable,
        .hub_changed = latched.hub_changed,
    }));
    if (latched.unrecoverable) return stopped(self);

    // Every port's changes are cleared together: on some controllers the
    // hub interrupt stays asserted while any of them is set.
    var moved = false;
    for (0..self.ports) |index| {
        const status = portRead(self, @intCast(index));
        if (!status.changed()) continue;
        portWrite(self, @intCast(index), .acknowledging(status));
        moved = true;
    }
    if (reborn) return .reborn;
    return if (moved) .ports_changed else .quiet;
}

/// Wait for the controller while a transfer is under way. Only what the
/// transfer needs is taken here: a finished descriptor, and a controller
/// that has failed. A hub change is held back for the bus to hear after.
fn rest(self: *Unit) void {
    if (self.irq == 0) return sys.sleepMicros(REST_US);

    sys.eventWait(self.irq, REST_US) catch {};
    const latched: ohci.Interrupts = @bitCast(self.regs.read(.interrupt_status));
    if (latched == ohci.Interrupts.ALL) {
        _ = gone(self);
        self.reborn = true;
    } else {
        if (latched.done) self.arena.at.hcca.done_head = 0;
        self.regs.write(.interrupt_status, @bitCast(ohci.Interrupts{ .done = latched.done, .unrecoverable = latched.unrecoverable }));
        if (latched.hub_changed and !self.hub_held) {
            self.regs.write(.interrupt_disable, @bitCast(ohci.Interrupts{ .hub_changed = true }));
            self.hub_held = true;
        }
        if (latched.unrecoverable) {
            _ = stopped(self);
            self.reborn = true;
        }
    }
    sys.irqAck(self.irq, true);
}

/// Let a held hub change through: its status is still latched, so the
/// controller interrupts again as soon as it is enabled.
fn releaseHub(self: *Unit) void {
    if (!self.hub_held) return;
    self.hub_held = false;
    self.regs.write(.interrupt_enable, @bitCast(ohci.Interrupts{ .hub_changed = true }));
}

/// A controller that reads as all ones has left the bus.
fn gone(self: *Unit) hc.Service {
    log.warn(name, "the controller has gone from the bus");
    self.opened = false;
    return .reborn;
}

/// The controller stopped itself: the bus refused one of its accesses, or
/// its schedule was malformed. The one clean rebuild is spent on it, and a
/// second failure closes the controller until the next usbd start.
fn stopped(self: *Unit) hc.Service {
    log.warn(name, "an unrecoverable error");
    pci.tellBusTrouble(self.location);
    const first = !self.rebuilt;
    self.rebuilt = true;
    if (first and reset(self)) {
        log.warn(name, "rebuilding the controller");
        start(self);
        return .reborn;
    }
    self.opened = false;
    log.fail(name, "closed; its ports are lost until the next usbd start");
    return .reborn;
}

pub fn quiesce(self: *Unit) void {
    if (!self.opened) return;
    self.regs.write(.interrupt_disable, @bitCast(ohci.Interrupts.ALL));
    self.regs.write(.control, @bitCast(ohci.Control{}));
    self.rebuilt = false;
}

pub fn rebuild(self: *Unit) bool {
    if (!self.opened) return false;
    takeFromFirmware(self);
    if (!reset(self)) {
        self.opened = false;
        return false;
    }
    start(self);
    return true;
}

pub fn listen(self: *Unit, irq: u32) void {
    self.irq = irq;
}

// ---------------------------------------------------------------------------
// Transfers
// ---------------------------------------------------------------------------

/// Point an idle endpoint at a device's endpoint. Idle means nothing is
/// queued on it, so the controller has nothing to do with what it reads.
fn aim(endpoint: *volatile ohci.Endpoint, pipe: usb.Pipe, number: u4) void {
    endpoint.control = .{
        .address = pipe.address,
        .endpoint = number,
        .low_speed = pipe.speed == .low,
        .max_packet = @intCast(@min(pipe.max_packet, std.math.maxInt(u11))),
    };
}

fn toggle(data1: bool) ohci.Toggle {
    return if (data1) .data1 else .data0;
}

/// A control transfer's stages: setup, the data if any, and the status in
/// the other direction.
pub fn control(self: *Unit, pipe: usb.Pipe, setup: usb.Setup, data: []u8) hc.Error!usize {
    if (!self.opened) return hc.Error.Refused;
    if (data.len > CONTROL_BYTES) return hc.Error.Refused;

    const arena = self.arena.at;
    const reading = setup.request_type.direction == .in;
    const carries = setup.length != 0 and data.len != 0;
    arena.setup = std.mem.toBytes(setup);
    if (carries and !reading) @memcpy(bytesOf(self, "control_buffer")[0..data.len], data);

    aim(&arena.control, pipe, 0);
    var stages: [CONTROL_SLOTS - 1]queue.Stage = undefined;
    var count: usize = 0;
    stages[count] = .{ .pid = .setup, .toggle = .data0, .buffer = self.arena.physOf("setup"), .length = usb.Setup.BYTES };
    count += 1;
    if (carries) {
        stages[count] = .{
            .pid = if (reading) .in else .out,
            .toggle = .data1,
            .buffer = self.arena.physOf("control_buffer"),
            .length = @intCast(data.len),
            .short_ok = reading,
        };
        count += 1;
    }
    stages[count] = .{
        .pid = switch (setup.statusDirection()) {
            .in => .in,
            .out => .out,
        },
        .toggle = .data1,
    };
    count += 1;

    if (!self.control.append(stages[0..count])) return hc.Error.Refused;
    self.regs.write(.command_status, @bitCast(ohci.CommandStatus{ .control_filled = true }));
    const moved = try finish(self, &self.control, &arena.control, 1, CONTROL_PATIENCE_US);
    if (!carries) return 0;

    const taken = @min(moved, data.len);
    if (reading) @memcpy(data[0..taken], bytesOf(self, "control_buffer")[0..taken]);
    return taken;
}

pub fn bulk(self: *Unit, pipe: *usb.Pipe, data: []u8) hc.Error!usize {
    if (!self.opened) return hc.Error.Refused;
    if (data.len > BULK_BYTES) return hc.Error.Refused;
    if (pipe.direction == .in) return carry(self, pipe, data);

    const run_bytes = RUN_PACKETS * @as(usize, @max(pipe.max_packet, 1));
    var sent: usize = 0;
    while (true) {
        const run = @min(data.len - sent, run_bytes);
        const moved = try carry(self, pipe, data[sent..][0..run]);
        sent += moved;
        if (moved < run or sent == data.len) return sent;
    }
}

/// One bulk transfer, as one descriptor.
fn carry(self: *Unit, pipe: *usb.Pipe, data: []u8) hc.Error!usize {
    const arena = self.arena.at;
    const writing = pipe.direction == .out;
    if (writing) @memcpy(bytesOf(self, "bulk_buffer")[0..data.len], data);

    aim(&arena.bulk, pipe.*, pipe.number);
    if (!self.bulk.append(&.{.{
        .pid = if (writing) .out else .in,
        .toggle = toggle(pipe.toggle),
        .buffer = self.arena.physOf("bulk_buffer"),
        .length = @intCast(data.len),
        .short_ok = !writing,
    }})) return hc.Error.Refused;
    self.regs.write(.command_status, @bitCast(ohci.CommandStatus{ .bulk_filled = true }));

    const moved = @min(try finish(self, &self.bulk, &arena.bulk, 0, BULK_PATIENCE_US), data.len);
    pipe.advance(moved);
    if (!writing) @memcpy(data[0..moved], bytesOf(self, "bulk_buffer")[0..moved]);
    return moved;
}

pub fn bulkLimit(_: *Unit) usize {
    return BULK_BYTES;
}

/// Wait for a queued transfer on the controller's interrupt, and say what
/// became of it. A transfer the device never answers is taken off the
/// endpoint once the controller is past it.
fn finish(
    self: *Unit,
    pending: anytype,
    endpoint: *volatile ohci.Endpoint,
    counted: usize,
    patience_us: u32,
) hc.Error!u32 {
    defer releaseHub(self);

    var waited: u32 = 0;
    while (!pending.settled()) : (waited += REST_US) {
        if (!self.opened) return hc.Error.Refused;
        if (waited >= patience_us) {
            endpoint.control.skip = true;
            sys.sleepMicros(FRAME_US);
            pending.clear();
            endpoint.control.skip = false;
            return hc.Error.Timeout;
        }
        rest(self);
    }

    return switch (pending.result(counted)) {
        .moved => |bytes| bytes,
        .failed => |why| {
            pending.clear();
            return switch (why) {
                .not_responding => hc.Error.Timeout,
                else => hc.Error.Stalled,
            };
        },
    };
}

/// A byte field of the arena, as plain bytes for copying through.
fn bytesOf(self: *Unit, comptime field: []const u8) []u8 {
    const place = &@field(self.arena.at, field);
    const Field = @typeInfo(@TypeOf(place)).pointer.child;
    return @as([*]u8, @ptrCast(@volatileCast(place)))[0..@sizeOf(Field)];
}

// ---------------------------------------------------------------------------
// Watched endpoints
// ---------------------------------------------------------------------------

pub fn watch(self: *Unit, pipe: usb.Pipe, wanted: u16) hc.Error!u8 {
    if (!self.opened) return hc.Error.Refused;
    if (wanted == 0 or wanted > REPORT_BYTES) return hc.Error.Refused;

    const entry = table.free(&self.watches) orelse return hc.Error.Refused;
    const index = table.indexOf(&self.watches, entry);
    const arena = self.arena.at;
    const endpoint = &arena.watches[index];

    endpoint.control = .{ .skip = true };
    entry.* = .{
        .live = true,
        .pipe = pipe,
        .wanted = wanted,
        .queue = .{ .endpoint = endpoint, .descriptors = &arena.watch_tds[index], .base = self.arena.physOfIndex("watch_tds", index) },
    };
    entry.queue.reset();
    arm(self, index);
    aim(endpoint, pipe, pipe.number);
    chain(self);
    return @intCast(index);
}

/// A standing read: one descriptor asking for as much as the watch wants.
/// The controller retries it every frame while the device has nothing, at
/// no cost here.
fn arm(self: *Unit, index: usize) void {
    const entry = &self.watches[index];
    _ = entry.queue.append(&.{.{
        .pid = .in,
        .toggle = toggle(entry.pipe.toggle),
        .buffer = self.arena.physOfIndex("reports", index),
        .length = entry.wanted,
        .short_ok = true,
    }});
}

/// Every live watch in one list, which every slot of the interrupt table
/// begins: each is visited every frame. Built from the back, so a watch
/// taken out still names the one that followed it for a controller
/// passing through it this frame.
fn chain(self: *Unit) void {
    const arena = self.arena.at;
    var head: u32 = 0;
    var index: usize = WATCHES;
    while (index > 0) {
        index -= 1;
        if (!self.watches[index].live) continue;
        arena.watches[index].next = head;
        head = self.arena.physOfIndex("watches", index);
    }
    for (&arena.hcca.interrupt_table) |*slot| slot.* = head;
}

pub fn collect(self: *Unit, index: u8, into: []u8) ?usize {
    if (index >= WATCHES or !self.watches[index].live) return null;
    const entry = &self.watches[index];
    if (!entry.queue.settled()) return null;

    const bytes = switch (entry.queue.result(0)) {
        .moved => |bytes| bytes,
        .failed => return null,
    };
    const taken = @min(@min(bytes, entry.wanted), into.len);
    const from: [*]const u8 = @ptrCast(@volatileCast(&self.arena.at.reports[index]));
    @memcpy(into[0..taken], from[0..taken]);

    entry.pipe.advance(bytes);
    arm(self, index);
    return taken;
}

pub fn watchLimit(_: *Unit) usize {
    return REPORT_BYTES;
}

pub fn unwatch(self: *Unit, index: u8) void {
    if (index >= WATCHES or !self.watches[index].live) return;
    self.arena.at.watches[index].control.skip = true;
    self.watches[index].live = false;
    chain(self);
    // The controller may be inside the endpoint this frame; the slot is not
    // used again until it has left.
    sys.sleepMicros(FRAME_US);
}
