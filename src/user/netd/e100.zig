//! Intel PRO/100: the 8255x family, and the LAN controller inside ICH2 to
//! ICH7 and NM10. Facts from Intel's 8255x developer manual and Linux's
//! e100.c, consulted; written from scratch in this system's shapes, with
//! the register and block shapes in `e100/regs.zig`.
//!
//! One DMA segment holds two rings: receive descriptors, each with room for
//! a frame, and command blocks, which carry the configuration and every
//! transmitted frame alike. How the host keeps them is `e100/rings.zig`.
//! Nothing waits on the part once it runs: each unit is started again from
//! the event that says it stopped, and the PHY is read one register per
//! management cycle, each cycle's end raising an interrupt.

const dev_mod = @import("dev.zig");
const dma = @import("dma.zig");
const cursor = @import("cursor.zig");
const mii = @import("mii.zig");
const regs = @import("e100/regs.zig");
const rings = @import("e100/rings.zig");
const lib = @import("lib");
const ulib = @import("ulib");
const log = ulib.log;
const pci = ulib.pci;
const sys = @import("sys");

const NicDev = dev_mod.NicDev;

pub const name = "e100";

/// The control and status window the part decodes.
const CSR_BYTES: u32 = 4096;

const RX_SLOTS = 64;
const TX_SLOTS = 32;

/// How long a reset holds before the part is spoken to again.
const RESET_US = 20;

/// How often the link is read: the part raises nothing when the wire changes.
const LINK_PERIOD_US: u64 = 2_000_000;

/// How long a management cycle may take before its reading is given up.
/// One takes a few tens of microseconds.
const MDI_PATIENCE_US: u64 = 100_000;

/// While starting, how often and how long to look for the part to take a
/// command. It takes one within microseconds.
const ACCEPT_ATTEMPTS = 20;
const ACCEPT_PAUSE_US = 1_000;

/// Reads of the status register that hold each EEPROM line change. The
/// EEPROM wants its clock held high and low for at least 250 ns, no register
/// says when that has passed, and one read is a bus transaction of at least
/// 50 ns on the fastest bus a part sits on.
const EEPROM_HOLD_READS = 16;

/// What a board with no management PHY is taken to be on: its serial
/// interface runs at ten megabits, half duplex, and cannot say whether a
/// wire is there.
const WITHOUT_PHY = mii.Outcome{ .up = true, .speed = .m10, .duplex = .half };

const Bytes = lib.mmio.Window(regs.Byte, u8);
const Dwords = lib.mmio.Window(regs.Dword, u32);

const Rings = struct {
    rx: [RX_SLOTS]regs.Receive,
    tx: [TX_SLOTS]regs.Block,
};

const Receiver = rings.Receiver(RX_SLOTS, dma);
const Transmitter = rings.Transmitter(TX_SLOTS, dma);

/// The link as the PHY last said it, and the reading under way.
const Watch = struct {
    reading: ?mii.Reading = null,
    /// When the cycle on the wire was asked for.
    asked_at: u64 = 0,
    /// When the next reading begins.
    due: u64 = 0,
    last: ?mii.Outcome = null,
};

const Device = struct {
    bytes: Bytes = .{ .base = undefined },
    arena: dma.Arena(Rings) = .{},
    generation: regs.Generation = .i82557,
    phy: u5 = 0,
    receiver: Receiver = .{ .descriptors = undefined },
    transmitter: Transmitter = .{ .blocks = undefined },
    watch: Watch = .{},
    opened: bool = false,
    started: bool = false,

    fn dwords(self: Device) Dwords {
        return self.bytes.as(regs.Dword, u32);
    }
};

var device: Device = .{};

pub fn open(loc: pci.Location, dev: *NicDev) bool {
    if (device.opened) {
        log.fail(name, "the adapter is already open");
        return false;
    }

    const registers = @max(pci.registersEnd(regs.Byte, 1), pci.registersEnd(regs.Dword, 4));
    const aperture = pci.openApertureNeeding(loc, 0, CSR_BYTES, registers, name, "adapter") orelse return false;
    var keep = false;
    defer if (!keep) {
        pci.disableInterruptAndMaster(loc);
        device.arena.release();
        sys.shmUnmap(@volatileCast(device.bytes.base));
    };
    device = .{ .bytes = .{ .base = @ptrCast(aperture) } };
    reset();

    const code: lib.pci.ClassCode = @bitCast(pci.read(loc, lib.pci.ClassCode.OFFSET));
    device.generation = .of(code.revision);

    var eeprom = regs.Eeprom(Pins){ .pins = .{ .bytes = device.bytes } };
    var words: [3]u16 = undefined;
    for (&words, [_]regs.EepromWord{ .address_0, .address_1, .address_2 }) |*word, at| word.* = eeprom.read(at);
    const mac = lib.mac.fromWords(words);
    if (!dev_mod.validMac(mac)) {
        log.fail(name, "cannot read a valid MAC address");
        return false;
    }
    dev.mac = mac;
    const phy: regs.PhyWord = @bitCast(eeprom.read(.phy));
    device.phy = phy.address;

    device.arena = dma.Arena(Rings).acquire() catch |why| {
        log.fail(name, dma.Arena(Rings).said(why));
        return false;
    };
    const memory = device.arena.body();
    for (&memory.rx, 0..) |*descriptor, i| {
        descriptor.header.link = slotAddress("rx", cursor.wrapped(i + 1, RX_SLOTS)) orelse return false;
    }
    for (&memory.tx, 0..) |*block, i| {
        block.header.link = slotAddress("tx", cursor.wrapped(i + 1, TX_SLOTS)) orelse return false;
    }
    device.receiver = .{ .descriptors = &memory.rx };
    device.transmitter = .{ .blocks = &memory.tx };

    device.opened = true;
    keep = true;
    return true;
}

/// The EEPROM's lines, each change held long enough for the part to see.
const Pins = struct {
    bytes: Bytes,

    pub fn put(self: Pins, lines: regs.EepromPins) void {
        self.bytes.write(.eeprom, @bitCast(lines));
        for (0..EEPROM_HOLD_READS) |_| _ = self.bytes.read(.status);
    }

    pub fn get(self: Pins) regs.EepromPins {
        return @bitCast(self.bytes.read(.eeprom));
    }
};

/// Both units stopped and the part off the bus, then the part reset, its
/// line masked.
fn reset() void {
    for ([_]regs.PortAction{ .selective_reset, .software_reset }) |action| {
        device.dwords().write(.port, @bitCast(regs.Port{ .action = action }));
        _ = device.bytes.read(.status);
        sys.sleepMicros(RESET_US);
    }
    mask(true);
}

fn mask(held: bool) void {
    device.bytes.write(.interrupts, @bitCast(regs.InterruptControl{ .masked = held }));
    _ = device.bytes.read(.status);
}

/// The address a device is given for one slot of a ring.
fn slotAddress(comptime ring: []const u8, index: usize) ?u32 {
    const Slot = @typeInfo(@FieldType(Rings, ring)).array.child;
    const at = device.arena.physOf(@offsetOf(Rings, ring) + index * @sizeOf(Slot)) orelse return null;
    return at.addr();
}

pub fn start(nic: *NicDev) bool {
    if (!device.opened) return false;
    if (device.started) return true;

    mask(true);
    device.bytes.write(.events, @bitCast(regs.Events.GONE));

    // The receiver starts at the first descriptor. The first two blocks set
    // the part up: how it runs, then which address is its own.
    device.receiver.reset();
    device.transmitter.reset();
    _ = device.transmitter.append(.{ .configure = .of(device.generation) });
    _ = device.transmitter.append(.{ .address = nic.mac });

    const first_block = slotAddress("tx", 0) orelse return false;
    const first_descriptor = slotAddress("rx", 0) orelse return false;
    const started = commandNow(.{ .command_unit = .load_base }, 0) and
        commandNow(.{ .receiver = .load_base }, 0) and
        commandNow(.{ .command_unit = .start }, first_block) and
        commandNow(.{ .receiver = .start }, first_descriptor);
    if (!started) {
        log.fail(name, "the adapter did not take its start commands");
        reset();
        return false;
    }

    device.started = true;
    device.watch = .{};
    pci.enableInterrupt(nic.location);
    mask(false);
    return true;
}

pub fn stop(nic: *NicDev) void {
    if (!device.opened) return;
    device.started = false;
    reset();
    pci.disableInterruptAndMaster(nic.location);
    device.arena.release();
    sys.shmUnmap(@volatileCast(device.bytes.base));
    device = .{};
    dev_mod.deliverLink(nic, .{});
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// The part, as the rings' housekeeping reads and commands it.
const Part = struct {
    pub fn accepted(_: Part) bool {
        return device.bytes.read(.command) == 0;
    }

    pub fn status(_: Part) regs.Status {
        return @bitCast(device.bytes.read(.status));
    }

    pub fn startReceiver(_: Part, slot: usize) void {
        give(.{ .receiver = .start }, slotAddress("rx", slot) orelse return);
    }

    pub fn resumeCommandUnit(_: Part) void {
        give(.{ .command_unit = .@"resume" }, null);
    }
};

/// A command the part has room for: it has taken the one before.
fn give(which: regs.Command, pointer: ?u32) void {
    if (pointer) |address| device.dwords().write(.pointer, address);
    device.bytes.write(.command, @bitCast(which));
}

/// A command while starting, where each needs the one before taken.
fn commandNow(which: regs.Command, pointer: ?u32) bool {
    if (!ulib.device.settles(ACCEPT_ATTEMPTS, ACCEPT_PAUSE_US, Part{}, Part.accepted)) return false;
    give(which, pointer);
    return true;
}

// ---------------------------------------------------------------------------
// Interrupts and housekeeping
// ---------------------------------------------------------------------------

pub fn irq(nic: *NicDev) bool {
    if (!device.started) return false;
    return dev_mod.serveIrq(@This(), nic);
}

/// What latched, as one word: zero for nothing, and for a part that has
/// left the bus.
pub fn cause() u32 {
    if (!device.started) return 0;
    const latched = device.bytes.read(.events);
    if (latched == @as(u8, @bitCast(regs.Events.GONE))) return 0;
    return latched;
}

/// Clear what was read and hold the line over the work; let it go after.
/// A cause that latches during the work stays latched for the next look.
pub fn acknowledge(causes: u32, held: bool) void {
    if (held) device.bytes.write(.events, @truncate(causes));
    mask(held);
}

pub fn service(causes: u32, nic: *NicDev) void {
    const latched: regs.Events = @bitCast(@as(u8, @truncate(causes)));
    if (latched.frame_received or latched.receiver_stopped) take(nic);
    if (latched.command_unit_left or latched.command_done) device.transmitter.reap(nic, failed);
    if (latched.mdi_done) heard(nic);
    keepRunning(nic);
}

/// Whatever arrived with no interrupt behind it.
pub fn poll(nic: *NicDev) bool {
    if (!device.started) return false;
    take(nic);
    device.transmitter.reap(nic, failed);
    keepRunning(nic);
    return true;
}

/// Between passes: start again what stopped while the part was busy, begin
/// a link reading when one is due, and give up on a cycle the part never
/// finished.
fn tend(nic: *NicDev, now: u64) void {
    if (!device.started) return;
    keepRunning(nic);

    if (device.watch.reading != null) {
        if (now -% device.watch.asked_at < MDI_PATIENCE_US) return;
        device.watch.reading = null;
        device.watch.due = now + LINK_PERIOD_US;
        return;
    }
    if (now < device.watch.due) return;
    device.watch.reading = .{ .was = device.watch.last };
    ask(.status, now);
}

// ---------------------------------------------------------------------------
// The rings
// ---------------------------------------------------------------------------

fn keepRunning(nic: *NicDev) void {
    rings.keepRunning(&device.receiver, &device.transmitter, Part{}, nic, failed);
}

fn take(nic: *NicDev) void {
    device.receiver.take(dev_mod.RX_REAP_BUDGET, nic, delivered);
}

fn delivered(nic: *NicDev, frame: ?[]const u8) void {
    dev_mod.deliverRx(nic, if (frame) |whole| .{ .ok = true, .frame = whole } else .{});
}

fn failed(nic: *NicDev) void {
    nic.stats.tx_failed += 1;
}

pub fn transmit(nic: *NicDev, frame: []const u8) bool {
    if (!device.started or frame.len > dev_mod.MAX_WIRE_FRAME) return false;
    device.transmitter.reap(nic, failed);
    if (!device.transmitter.append(.{ .frame = frame })) {
        nic.stats.tx_failed += 1;
        return false;
    }
    // A unit still running finds the block on its own; one suspended
    // behind the block before is resumed here, or by the event its
    // suspending raised.
    keepRunning(nic);
    dev_mod.deliverTx(nic, frame.len);
    return true;
}

// ---------------------------------------------------------------------------
// Link
// ---------------------------------------------------------------------------

/// Ask the PHY for one register, the end of the cycle to raise an interrupt.
fn ask(register: mii.Register, now: u64) void {
    device.dwords().write(.mdi, @bitCast(regs.Mdi{
        .register = @intCast(@intFromEnum(register)),
        .phy = device.phy,
        .opcode = .read,
        .interrupt = true,
    }));
    device.watch.asked_at = now;
}

/// A management cycle ended: take its word, then ask the next register or
/// say what the link is.
fn heard(nic: *NicDev) void {
    const reading = if (device.watch.reading) |*reading| reading else return;
    const cycle: regs.Mdi = @bitCast(device.dwords().read(.mdi));
    if (!cycle.ready) return;
    const now = dev_mod.clock();
    switch (reading.took(cycle.data)) {
        .ask => |register| ask(register, now),
        .done => |outcome| settled(nic, outcome, now),
        .absent => settled(nic, WITHOUT_PHY, now),
    }
}

fn settled(nic: *NicDev, outcome: mii.Outcome, now: u64) void {
    device.watch.reading = null;
    device.watch.last = outcome;
    device.watch.due = now + LINK_PERIOD_US;
    dev_mod.deliverLink(nic, dev_mod.linkFrom(outcome));
}

pub fn link(_: *NicDev) dev_mod.Link {
    return dev_mod.linkFrom(device.watch.last orelse return .{});
}

pub const ops: dev_mod.NicOps = .{
    .open = open,
    .start = start,
    .stop = stop,
    .irq = irq,
    .poll = poll,
    .service = tend,
    .transmit = transmit,
    .link = link,
};
