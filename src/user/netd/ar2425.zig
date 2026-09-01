//! The Atheros AR2425 radio: identification, calibration store, and the
//! shape everything above it compiles against.
//!
//! An 802.11 radio is a soft MAC. The silicon transmits, receives,
//! acknowledges and decrypts; everything that decides what to say, and to
//! whom, is software: scanning, authentication, association, key exchange
//! and rate choice. This file is the silicon half's foundation, and it is
//! honest about where that half currently stops. What it does today is
//! bring the chip out of power-down, prove which silicon it is, and read
//! the card's own store: the station address, the regulatory domain, and
//! whether the key cache may do its own cipher.
//!
//! Register offsets and sequences follow the two independent free
//! implementations of this family, the Linux ath5k driver and OpenBSD's
//! ar5k, which agree on everything used here. No datasheet exists.
//!
//! Nothing in this file allocates on a packet path, and no wait is
//! unbounded: this runs in a service whose event loop must stay
//! answerable, and a radio that has gone away must cost a bounded spin
//! and a refusal, never the machine.

const ath5k = @import("lib").ath5k;
const dev_mod = @import("dev.zig");
const dma = @import("dma.zig");
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const std = @import("std");
const sys = @import("sys");

const NicDev = dev_mod.NicDev;

pub const name = "ar2425";
pub const vendor: u16 = 0x168C;
pub const device_id: u16 = 0x001C;

/// What kind of interface this driver produces, for configuration slots.
pub const class = lib.ifmatch.Class.wifi;

/// The register aperture is sixty-four kilobytes; everything this driver
/// reaches lives in the first forty.
const MMIO_BYTES: u32 = 64 * 1024;

// ---------------------------------------------------------------------------
// Registers
// ---------------------------------------------------------------------------

/// Every register here is a word, so one window serves the whole chip.
const R = enum(usize) {
    /// Which engines are held in reset.
    reset_control = 0x4000,
    /// The sleep state machine.
    sleep_control = 0x4004,
    /// Interrupt status, shadowed for reading without acknowledging.
    interrupt_status = 0x401C,
    /// Bus configuration, including the power-down report.
    bus_config = 0x4010,
    /// Silicon revision: which MAC generation this is.
    silicon_revision = 0x4020,

    /// The calibration store: address, data, command, status.
    eeprom_address = 0x6000,
    eeprom_data = 0x6004,
    eeprom_command = 0x6008,
    eeprom_status = 0x600C,

    /// The station's own address, low four bytes then high two.
    station_id_low = 0x8000,
    station_id_high = 0x8004,

    /// The baseband's identity, which names the radio attached to it.
    phy_chip_id = 0x9818,

    /// Which engines are running. Transmission is a per-queue affair on
    /// this generation and is not in here.
    command = 0x0008,
    /// Where the receive chain begins.
    rx_chain = 0x000C,
    /// The master switch: whether any interrupt reaches the pin.
    interrupt_enable = 0x0024,
    /// What has happened. Reading it acknowledges.
    interrupt_pending = 0x0080,
    /// Which of those may be reported.
    interrupt_mask = 0x00A0,
    /// Queue zero's transmit chain. The queues are consecutive words.
    tx_chain = 0x0800,
    /// Start a queue transmitting, and stop one. Both are bit per queue.
    queue_start = 0x0840,
    queue_stop = 0x0880,
    /// Which frames the protocol unit keeps rather than discards.
    rx_filter = 0x803C,
};

const Regs = lib.mmio.Window(R, u32);

/// Which engines a reset holds down. Every bit is one block, and the bus
/// interface is deliberately absent from the fields a caller can name: on
/// a card attached by PCI Express, resetting the bus block wedges the link
/// and takes the machine with it. The bit exists in the silicon; this
/// driver has no way to spell it.
const ResetControl = packed struct(u32) {
    /// The protocol control unit: acknowledgement, filtering, timers.
    pcu: bool = false,
    /// The baseband's direct memory access engines.
    baseband: bool = false,
    mac: bool = false,
    phy: bool = false,
    _4: u28 = 0,

    /// Everything this driver ever resets together.
    const everything = ResetControl{ .pcu = true, .baseband = true, .mac = true, .phy = true };
    const nothing = ResetControl{};
};

/// The sleep state machine's three settings.
const SleepMode = enum(u2) {
    /// Awake, and staying awake.
    awake = 0,
    /// Asleep until told otherwise.
    asleep = 1,
    /// The hardware may sleep when it judges it can.
    permitted = 2,
    _,
};

const SleepControl = packed struct(u32) {
    duration: u16 = 0,
    mode: SleepMode = .awake,
    _18: u14 = 0,
};

/// The bus configuration word. Only the power-down report is read here.
const BusConfig = packed struct(u32) {
    _0: u16 = 0,
    /// Set while the chip is still powered down; a wake is complete when
    /// this clears.
    powered_down: bool = false,
    _17: u15 = 0,
};

/// Silicon revision: the generation in the high nibble pair, the stepping
/// in the low one.
const SiliconRevision = packed struct(u32) {
    revision: u4 = 0,
    version: u8 = 0,
    _12: u20 = 0,
};

/// The MAC generations this driver knows how to talk to.
const Generation = enum(u8) {
    /// AR2425, the single-chip b/g part.
    ar2425 = 0xE2,
    /// AR2417, the same generation with a different radio label.
    ar2417 = 0xE6,
    _,

    fn known(self: Generation) bool {
        return switch (self) {
            .ar2425, .ar2417 => true,
            else => false,
        };
    }
};

const EepromCommand = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    reset: bool = false,
    _3: u29 = 0,
};

const EepromStatus = packed struct(u32) {
    read_error: bool = false,
    read_done: bool = false,
    write_error: bool = false,
    write_done: bool = false,
    _4: u28 = 0,
};

/// Which engines are running.
const Command = packed struct(u32) {
    _0: u2 = 0,
    receive: bool = false,
    _3: u2 = 0,
    stop_receive: bool = false,
    software_interrupt: bool = false,
    _7: u25 = 0,
};

/// Whether anything at all reaches the interrupt pin. Held apart from the
/// mask so a handler can silence the card without forgetting which causes
/// it wanted.
const InterruptEnable = packed struct(u32) {
    enabled: bool = false,
    _1: u31 = 0,
};

/// What the radio reports, and what it may be asked to report. One shape
/// for both, because a mask and a status are the same set of causes read
/// in the two directions.
const Interrupts = packed struct(u32) {
    rx_ok: bool = false,
    rx_descriptor: bool = false,
    rx_error: bool = false,
    rx_no_frame: bool = false,
    rx_end_of_list: bool = false,
    rx_overrun: bool = false,
    tx_ok: bool = false,
    tx_descriptor: bool = false,
    tx_error: bool = false,
    tx_no_frame: bool = false,
    tx_end_of_list: bool = false,
    tx_underrun: bool = false,
    _12: u20 = 0,

    /// The causes this driver acts on. Anything else the hardware can
    /// raise is left masked, because an interrupt nobody handles is a
    /// line that never goes quiet.
    const wanted = Interrupts{
        .rx_ok = true,
        .rx_descriptor = true,
        .rx_error = true,
        .rx_overrun = true,
        .rx_end_of_list = true,
        .tx_ok = true,
        .tx_descriptor = true,
        .tx_error = true,
        .tx_underrun = true,
    };
    const none = Interrupts{};

    fn any(self: Interrupts) bool {
        return @as(u32, @bitCast(self)) != 0;
    }
};

/// Which queues a write starts or stops: one bit each.
const Queues = packed struct(u32) {
    mask: u10 = 0,
    _10: u22 = 0,

    const first = Queues{ .mask = 1 };
    const all = Queues{ .mask = std.math.maxInt(u10) };
};

/// The station address as the two registers hold it: four bytes in the
/// low word, two in the high one.
const StationIdHigh = packed struct(u32) {
    address_high: u16 = 0,
    _16: u16 = 0,
};

comptime {
    // The radio's own numbers, proved to be the shapes claimed for them.
    if (@as(u32, @bitCast(Command{ .receive = true })) != 0x04 or
        @as(u32, @bitCast(Command{ .stop_receive = true })) != 0x20)
    {
        @compileError("the command register's engine bits drifted");
    }
    if (@as(u32, @bitCast(Interrupts{ .rx_ok = true })) != 0x01 or
        @as(u32, @bitCast(Interrupts{ .tx_ok = true })) != 0x40)
    {
        @compileError("the interrupt causes drifted");
    }
    if (@as(u32, @bitCast(Queues.first)) != 0x01) {
        @compileError("a queue is one bit, and the first is the lowest");
    }
    if (@as(u32, @bitCast(ResetControl.everything)) != 0x0F) {
        @compileError("the reset word's blocks drifted");
    }
    if (@as(u32, @bitCast(SleepControl{ .mode = .asleep })) != 0x0001_0000) {
        @compileError("the sleep mode field drifted");
    }
    if (@as(u32, @bitCast(BusConfig{ .powered_down = true })) != 0x0001_0000) {
        @compileError("the power-down report drifted");
    }
    if (@as(u32, @bitCast(EepromStatus{ .read_done = true })) != 0x02 or
        @as(u32, @bitCast(EepromStatus{ .read_error = true })) != 0x01)
    {
        @compileError("the calibration store's status bits drifted");
    }
}

// ---------------------------------------------------------------------------
// Where the card keeps what it knows about itself
// ---------------------------------------------------------------------------

/// Word offsets into the calibration store. The station address occupies
/// three words read from the highest down, which is the order the vendor's
/// own layout puts them in.
const Eeprom = struct {
    const magic: u16 = 0x003D;
    const magic_value: u16 = 0x5AA5;
    const protect: u16 = 0x003F;
    const regulatory_domain: u16 = 0x00BF;
    /// The header word whose second bit disables the key cache's cipher.
    const misc5: u16 = 0x00C6;
    /// The station address, highest word first.
    const address_top: u16 = 0x1F;
    const address_bottom: u16 = 0x1D;
    /// The word above the address, which the vendor's driver reads and
    /// discards before the address itself. Its read is what settles the
    /// store's address latch.
    const address_prelude: u16 = 0x20;

    /// How long one word may take. The vendor waits far longer; a service
    /// that must stay answerable does not, and a store this slow is a card
    /// worth refusing.
    const READ_ATTEMPTS: u32 = 2000;
    const READ_PAUSE_US: u32 = 15;
};

/// What the card says about itself, once its store has been read.
pub const Identity = struct {
    generation: Generation = @enumFromInt(0),
    revision: u4 = 0,
    /// The baseband's identity word, which names the attached radio.
    phy_id: u32 = 0,
    /// Which regulatory domain the card was built for. The channels a scan
    /// visits are the intersection of this and the band's own list, never
    /// the union.
    regulatory_domain: u16 = 0,
    /// Whether the key cache may perform its own cipher. A card that says
    /// no is not a card that cannot be joined; it is one whose frames are
    /// enciphered in software.
    hardware_cipher: bool = false,
};

// ---------------------------------------------------------------------------
// The device
// ---------------------------------------------------------------------------

/// How many descriptors each chain holds, and how much one frame may be.
///
/// A radio hears more than it is spoken to, so the receive chain is the
/// one that has to be long enough to survive a burst the service has not
/// drained yet. Both are powers of two, which is what makes the wrap a
/// mask.
const RING_SLOTS = 32;
const SLAB = 2048;
const Chain = ath5k.Ring(RING_SLOTS);

/// The descriptors and the buffers they name, in one physically
/// contiguous run so every address in it is one the radio can reach.
const Rings = struct {
    rx_desc: [RING_SLOTS]ath5k.Desc align(64) = @splat(.{}),
    tx_desc: [RING_SLOTS]ath5k.Desc align(64) = @splat(.{}),
    rx_buffer: [RING_SLOTS][SLAB]u8 = @splat(@splat(0)),
    tx_buffer: [RING_SLOTS][SLAB]u8 = @splat(@splat(0)),
};

comptime {
    if (@alignOf(Rings) < 4 or @offsetOf(Rings, "rx_desc") % 4 != 0 or
        @offsetOf(Rings, "tx_desc") % 4 != 0)
    {
        @compileError("the radio reads descriptors word-aligned");
    }
}

/// One radio, one static instance. Nothing on a frame's path allocates:
/// the chains are as long as they will ever be from the moment they are
/// made.
const Device = struct {
    regs: Regs = .{ .base = undefined },
    location: pci.Location = .{ .bus = 0, .device = 0, .function = 0 },
    identity: Identity = .{},
    opened: bool = false,
    started: bool = false,

    rings: ?*Rings = null,
    /// Where the run begins, as the radio addresses it.
    phys: u32 = 0,
    dma_handle: ?u32 = null,
    /// The next descriptor the service expects to find finished.
    rx_next: usize = 0,
};

var device: Device = .{};

pub const ops = dev_mod.NicOps{
    .open = open,
    .start = start,
    .stop = stop,
    .irq = irq,
    .transmit = transmit,
    .link = link,
};

/// Bring the card out of whatever state the firmware left it in, prove
/// which silicon it is, and read its store.
pub fn open(loc: pci.Location, nic: *NicDev) bool {
    device = .{ .location = loc };

    const aperture = pci.openAperture(loc, 0, MMIO_BYTES, name, "radio") orelse
        return false;
    var keep_enabled = false;
    defer if (!keep_enabled) pci.disableInterruptAndMaster(loc);

    device.regs = .{ .base = @ptrCast(aperture) };

    if (!wake()) {
        log.fail(name, "the radio stayed powered down");
        return false;
    }
    if (!identify()) return false;
    if (!warmReset()) {
        log.fail(name, "the radio did not come back from reset");
        return false;
    }
    // The reset returns the chip to power-down, so the wake is repeated
    // before anything reads a register that reset cleared.
    if (!wake()) {
        log.fail(name, "the radio stayed powered down after reset");
        return false;
    }

    if (!readIdentity()) return false;
    if (!readAddress(&nic.mac)) {
        log.fail(name, "the calibration store holds no station address");
        return false;
    }
    writeStationAddress(nic.mac);

    device.opened = true;
    keep_enabled = true;
    sayIdentity(nic.mac);
    return true;
}

/// Give the radio its chains and let it listen.
///
/// What this does not do is tune it. A radio with no channel set and no
/// association hears nothing, so the chains run empty until the joining
/// above this makes there be something to hear. Having them running is
/// what makes that the only missing piece.
pub fn start(nic: *NicDev) bool {
    if (!device.opened or device.started) return false;

    if (!buildRings()) {
        log.fail(name, "cannot lay out the descriptor chains");
        return false;
    }

    quiet();

    // The chain is a circle, so the hardware is given one address and
    // follows links from there for as long as it is fed.
    device.regs.write(.rx_chain, Chain.addressOf(chainBase("rx_desc"), 0));
    device.regs.write(.tx_chain, Chain.addressOf(chainBase("tx_desc"), 0));
    dma.publish();

    device.regs.write(.command, @bitCast(Command{ .receive = true }));
    _ = device.regs.read(.command);

    pci.enableInterrupt(nic.location);
    device.regs.write(.interrupt_mask, @bitCast(Interrupts.wanted));
    device.regs.write(.interrupt_enable, @bitCast(InterruptEnable{ .enabled = true }));
    _ = device.regs.read(.interrupt_enable);

    device.started = true;
    return true;
}

pub fn stop(_: *NicDev) void {
    if (!device.opened) return;
    device.started = false;

    quiet();
    releaseRings();

    device.regs.write(.sleep_control, @bitCast(SleepControl{ .mode = .permitted }));
    _ = device.regs.read(.sleep_control);
}

/// Silence the radio and let go of every address it holds.
///
/// Ordered so no register still names memory that is about to be handed
/// back: the causes are masked, the engines stopped, and only then are the
/// chain pointers cleared.
fn quiet() void {
    device.regs.write(.interrupt_enable, @bitCast(InterruptEnable{}));
    device.regs.write(.interrupt_mask, @bitCast(Interrupts.none));
    _ = device.regs.read(.interrupt_pending);

    device.regs.write(.queue_stop, @bitCast(Queues.all));
    device.regs.write(.command, @bitCast(Command{ .stop_receive = true }));
    _ = device.regs.read(.command);
    sys.sleepMicros(3000);

    device.regs.write(.rx_chain, 0);
    device.regs.write(.tx_chain, 0);
    _ = device.regs.read(.rx_chain);
}

/// What the radio has to say. Reading the register acknowledges it, so it
/// is read once and every cause in it acted on.
pub fn irq(nic: *NicDev) bool {
    if (!device.started) return false;

    const cause: Interrupts = @bitCast(device.regs.read(.interrupt_pending));
    if (!cause.any()) return false;

    if (cause.rx_ok or cause.rx_descriptor or cause.rx_end_of_list) reapRx(nic);
    if (cause.rx_error or cause.rx_overrun) nic.stats.rx_dropped += 1;
    if (cause.tx_error or cause.tx_underrun) nic.stats.tx_failed += 1;

    // A chain that ran to its end was starved rather than broken: it is
    // circular, so pointing the radio back at the slot the service is
    // waiting on is all the repair there is.
    if (cause.rx_end_of_list) {
        device.regs.write(.rx_chain, Chain.addressOf(chainBase("rx_desc"), device.rx_next));
        device.regs.write(.command, @bitCast(Command{ .receive = true }));
    }
    return true;
}

/// Take every finished receive descriptor, in the order the radio filled
/// them, and give each one back as soon as its frame has been handed over.
fn reapRx(nic: *NicDev) void {
    const rings = device.rings orelse return;

    while (true) {
        const slot = device.rx_next;
        const desc = &rings.rx_desc[slot];

        const report = @as(*const volatile ath5k.Desc, desc).received();
        if (!report.status.done) break;
        dma.consume();

        // A length is the radio's word until it has been measured against
        // the buffer that holds it.
        const length: usize = report.length;
        if (report.status.intact() and length > 0 and length <= SLAB) {
            dev_mod.deliverRx(nic, .{ .ok = true, .frame = rings.rx_buffer[slot][0..length] });
        } else {
            dev_mod.deliverRx(nic, .{});
        }

        armReceive(rings, slot);
        dma.publish();
        device.rx_next = Chain.next(slot);
    }
}

/// A radio with no association has nowhere to send a frame, and says so
/// rather than dropping it silently. The chain is laid and running; what
/// is missing is a network to name in a frame's header.
pub fn transmit(nic: *NicDev, _: []const u8) bool {
    nic.stats.tx_failed += 1;
    return false;
}

// ---------------------------------------------------------------------------
// The chains
// ---------------------------------------------------------------------------

/// Where one chain begins, as the radio addresses it.
fn chainBase(comptime field: []const u8) u32 {
    return device.phys + @offsetOf(Rings, field);
}

/// Hand one receive descriptor back to the radio: its buffer, its
/// successor, and no status at all.
fn armReceive(rings: *Rings, slot: usize) void {
    const buffers = chainBase("rx_buffer");
    rings.rx_desc[slot].armReceive(
        buffers + @as(u32, @intCast(slot * SLAB)),
        Chain.linkFor(chainBase("rx_desc"), slot),
    );
}

/// One contiguous run for both chains and their buffers, chained into
/// circles and handed to the radio.
fn buildRings() bool {
    if (device.rings != null) return true;

    var phys: u32 = 0;
    const handle = sys.dmaAlloc(@sizeOf(Rings), &phys);
    if (handle < 0) {
        log.failed(name, "cannot allocate the descriptor chains", handle);
        return false;
    }
    const owned: u32 = @intCast(handle);

    if (!Chain.addressable(phys) or phys % @alignOf(Rings) != 0) {
        _ = sys.close(owned);
        log.fail(name, "the descriptor chains are unaligned or out of reach");
        return false;
    }

    const mapped = sys.shmMap(owned, .{ .writable = true }) orelse {
        _ = sys.close(owned);
        log.fail(name, "cannot map the descriptor chains");
        return false;
    };

    const rings: *Rings = @ptrCast(@alignCast(mapped));
    rings.* = .{};
    device.rings = rings;
    device.phys = phys;
    device.dma_handle = owned;
    device.rx_next = 0;

    // Receive descriptors are the radio's from the start; transmit ones
    // are the service's until it has something to put in them, so they
    // carry their links and nothing else.
    for (0..RING_SLOTS) |slot| {
        armReceive(rings, slot);
        rings.tx_desc[slot].link = Chain.linkFor(chainBase("tx_desc"), slot);
    }
    dma.publish();
    return true;
}

fn releaseRings() void {
    const handle = device.dma_handle orelse return;
    _ = sys.close(handle);
    device.dma_handle = null;
    device.rings = null;
    device.phys = 0;
}

/// The carrier of a radio is its association, which does not exist yet.
pub fn link(_: *NicDev) dev_mod.Link {
    return .{};
}

// ---------------------------------------------------------------------------
// Power, reset and identity
// ---------------------------------------------------------------------------

/// Ask the chip to stay awake and wait for it to report that it is.
fn wake() bool {
    device.regs.write(.sleep_control, @bitCast(SleepControl{ .mode = .awake }));
    _ = device.regs.read(.sleep_control);

    var waited: u32 = 0;
    while (waited < 200) : (waited += 1) {
        const config: BusConfig = @bitCast(device.regs.read(.bus_config));
        if (!config.powered_down) return true;
        sys.sleepMicros(50);
    }
    return false;
}

/// Hold every engine down, then let them all go. The bus interface is
/// never part of this: on a card attached by PCI Express, resetting it
/// takes the link down and the machine with it.
fn warmReset() bool {
    device.regs.write(.reset_control, @bitCast(ResetControl.everything));
    _ = device.regs.read(.reset_control);
    sys.sleepMicros(15);

    device.regs.write(.reset_control, @bitCast(ResetControl.nothing));

    var waited: u32 = 0;
    while (waited < 200) : (waited += 1) {
        if (device.regs.read(.reset_control) == 0) return true;
        sys.sleepMicros(50);
    }
    return false;
}

/// Which silicon this is. A part this driver does not know is refused
/// rather than guessed at: the register sequences below are not portable
/// across generations, and a wrong guess programs a radio blind.
fn identify() bool {
    const revision: SiliconRevision = @bitCast(device.regs.read(.silicon_revision));
    device.identity.generation = @enumFromInt(revision.version);
    device.identity.revision = revision.revision;

    if (!device.identity.generation.known()) {
        log.begin(name, .bad);
        out.text("unfamiliar silicon, revision 0x");
        out.hex(revision.version, 2);
        out.text("; refusing to drive it blind");
        log.end();
        return false;
    }

    device.identity.phy_id = device.regs.read(.phy_chip_id);
    return true;
}

/// Read the card's own account of itself: that the store is intelligible
/// at all, which regulatory domain it was built for, and whether its key
/// cache may cipher.
fn readIdentity() bool {
    const magic = readWord(Eeprom.magic) orelse {
        log.fail(name, "the calibration store does not answer");
        return false;
    };
    if (magic != Eeprom.magic_value) {
        log.fail(name, "the calibration store is not one this card wrote");
        return false;
    }

    device.identity.regulatory_domain = readWord(Eeprom.regulatory_domain) orelse 0;
    if (readWord(Eeprom.misc5)) |misc| {
        // The second bit disables the cipher engine, so the capability is
        // its absence.
        device.identity.hardware_cipher = (misc >> 1) & 1 == 0;
    }
    return true;
}

/// The station address, from the three words the store keeps it in,
/// highest first, each word most significant byte first.
fn readAddress(into: *lib.mac.Address) bool {
    // The vendor's driver reads the word above the address first and
    // discards it; the read is what settles the store's address latch.
    _ = readWord(Eeprom.address_prelude);

    var address: lib.mac.Address = @splat(0);
    var total: u32 = 0;
    var at: usize = 0;
    var offset: u16 = Eeprom.address_top;
    while (offset >= Eeprom.address_bottom) : (offset -= 1) {
        const word = readWord(offset) orelse return false;
        total += word;
        address[at] = @truncate(word >> 8);
        address[at + 1] = @truncate(word);
        at += 2;
    }

    // An unwritten store reads as all zeroes or all ones, and neither is
    // an address.
    if (total == 0 or total == 3 * 0xFFFF) return false;
    into.* = address;
    return true;
}

/// One word from the calibration store: name the offset, ask for a read,
/// and wait a bounded time for the answer.
fn readWord(offset: u16) ?u16 {
    device.regs.write(.eeprom_address, offset);
    device.regs.write(.eeprom_command, @bitCast(EepromCommand{ .read = true }));

    var attempts: u32 = 0;
    while (attempts < Eeprom.READ_ATTEMPTS) : (attempts += 1) {
        const status: EepromStatus = @bitCast(device.regs.read(.eeprom_status));
        if (status.read_done) {
            if (status.read_error) return null;
            return @truncate(device.regs.read(.eeprom_data));
        }
        sys.sleepMicros(Eeprom.READ_PAUSE_US);
    }
    return null;
}

/// Tell the protocol control unit which address it answers to. Filtering
/// and acknowledgement are the hardware's, and both are keyed on this.
fn writeStationAddress(address: lib.mac.Address) void {
    const low = std.mem.readInt(u32, address[0..4], .little);
    const high = std.mem.readInt(u16, address[4..6], .little);
    device.regs.write(.station_id_low, low);
    device.regs.write(.station_id_high, @bitCast(StationIdHigh{ .address_high = high }));
}

fn sayIdentity(address: lib.mac.Address) void {
    log.begin(name, .key);
    out.text(switch (device.identity.generation) {
        .ar2425 => "AR2425",
        .ar2417 => "AR2417",
        else => "unknown",
    });
    out.text(" rev ");
    out.decimal(device.identity.revision);
    out.text(", mac ");
    const spelled = lib.mac.text(address);
    out.text(&spelled);
    out.text(", domain 0x");
    out.hex(device.identity.regulatory_domain, 4);
    if (!device.identity.hardware_cipher) out.text(", software cipher only");
    log.end();
}
