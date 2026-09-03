//! The Atheros AR5212 family: the AR2425 in the Eee PC 701, and the AR2417
//! beside it. Transcribed from the reference, FreeBSD's Atheros hardware
//! layer pinned under `third_party/ath_hal`; the reverse-engineered tables
//! come from it by a generator, never by hand.
//!
//! An 802.11 radio is a soft MAC. The silicon transmits, receives,
//! acknowledges and decrypts; everything that decides what to say, and to
//! whom, is software above this file. What this file does is bring the
//! chip up, read its calibration store, run the reset and channel-set
//! pipeline in `ar5212/reset.zig`, keep the receive chain fed, and hand
//! every intact frame up with the signal it arrived at. It transmits
//! nothing yet, and says so when asked.
//!
//! Nothing in this file allocates on a packet path, and no wait is
//! unbounded: this runs in a service whose event loop must stay
//! answerable, and a radio that has gone away, which the kill switch
//! makes the normal case, must cost a bounded spin and a refusal, never
//! the machine.

const dev_mod = @import("dev.zig");
const dma = @import("dma.zig");
const eeprom = @import("ar5212/eeprom.zig");
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pace = @import("ar5212/pace.zig");
const pci = @import("ulib").pci;
const regs_mod = @import("ar5212/regs.zig");
const reset = @import("ar5212/reset.zig");
const std = @import("std");
const sys = @import("sys");

const NicDev = dev_mod.NicDev;
const Regs = regs_mod.Regs;
const Desc = lib.ar5212.Desc;
const wifi = lib.wifi;

pub const name = "ar5212";

/// What kind of interface this driver produces, for configuration slots.
pub const class = lib.ifmatch.Class.wifi;

/// The register aperture is sixty-four kilobytes.
const MMIO_BYTES: u32 = 64 * 1024;

/// The radio revision the reference assumes when the analog part reports
/// none, which it does when the kill switch was thrown at boot.
const RADIO_REVISION_ASSUMED: u8 = 0xA2;
/// The reference's own literals for reading the radio's revision.
const RADIO_REVISION_SELECT: u32 = 0x0000_1C16;
const RADIO_REVISION_STROBE: u32 = 0x0001_0000;
const RADIO_REVISION_STROBES = 8;

// ---------------------------------------------------------------------------
// The chains
// ---------------------------------------------------------------------------

/// How many descriptors each chain holds, and how much one frame may be.
///
/// A radio hears more than it is spoken to, so the receive chain is the
/// one that has to be long enough to survive a burst the service has not
/// drained yet. Both are powers of two, which is what makes the wrap a
/// mask.
const RING_SLOTS = 32;
const SLAB = 2048;
const FCS_BYTES = 4;
const Chain = lib.ar5212.Chain(RING_SLOTS);

/// The descriptors and the buffers they name, in one physically
/// contiguous run so every address in it is one the radio can reach.
const Rings = struct {
    rx_desc: [RING_SLOTS]Desc align(64) = @splat(.{}),
    tx_desc: [RING_SLOTS]Desc align(64) = @splat(.{}),
    rx_buffer: [RING_SLOTS][SLAB]u8 = @splat(@splat(0)),
    tx_buffer: [RING_SLOTS][SLAB]u8 = @splat(@splat(0)),
};

comptime {
    if (@alignOf(Rings) < 4 or @offsetOf(Rings, "rx_desc") % 4 != 0 or
        @offsetOf(Rings, "tx_desc") % 4 != 0)
    {
        @compileError("the radio reads descriptors word-aligned");
    }
    if (SLAB > std.math.maxInt(u12)) @compileError("a receive buffer is at most what the descriptor can count");
}

/// One radio, one static instance. Nothing on a frame's path allocates:
/// the chains are as long as they will ever be from the moment they are
/// made.
const Device = struct {
    location: pci.Location = .{ .bus = 0, .device = 0, .function = 0 },
    /// The interface record the service keeps for this radio.
    nic: ?*NicDev = null,
    chip: ?reset.Chip = null,
    opened: bool = false,
    started: bool = false,
    /// The card answered all ones: it has gone, and nothing is asked of
    /// it again.
    gone: bool = false,
    bus_error_said: bool = false,

    rings: ?*Rings = null,
    /// Where the run begins, as the radio addresses it.
    phys: u32 = 0,
    dma_handle: ?u32 = null,
    /// The next descriptor the service expects to find finished.
    rx_next: usize = 0,
    /// The channel tuned, or none yet.
    channel: ?wifi.Channel = null,
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

// ---------------------------------------------------------------------------
// Bring-up
// ---------------------------------------------------------------------------

/// Bring the card out of whatever state the firmware left it in, prove
/// which silicon it is, and read its store.
pub fn open(loc: pci.Location, nic: *NicDev) bool {
    device = .{ .location = loc, .nic = nic };

    const aperture = pci.openAperture(loc, 0, MMIO_BYTES, name, "radio") orelse return false;
    var keep_enabled = false;
    defer if (!keep_enabled) pci.disableInterruptAndMaster(loc);

    const regs = Regs{ .window = .{ .base = @ptrCast(aperture) } };

    if (!reset.wake(regs)) {
        log.fail(name, "the radio stayed powered down");
        return false;
    }

    // A generation this driver does not know is refused rather than
    // guessed at: the sequences are not portable across generations, and
    // a wrong guess programs a radio blind.
    const silicon = regs.get(.silicon_revision, regs_mod.SiliconRevision);
    if (!silicon.version.known()) {
        log.begin(name, .bad);
        out.text("unfamiliar silicon, version ");
        out.decimal(@intFromEnum(silicon.version));
        out.text("; only the AR2425 and AR2417 are transcribed");
        log.end();
        return false;
    }

    var chip = reset.Chip{
        .regs = regs,
        .store = undefined,
        .version = silicon.version,
        .revision = silicon.revision,
        .phy_revision = 0,
        .radio_revision = 0,
        .part = if (silicon.version == .ar2417) .ar2417 else .ar2425,
        .mac = @splat(0),
    };

    if (!reset.chipReset(&chip, null)) {
        log.fail(name, "the radio did not come back from reset");
        return false;
    }
    chip.phy_revision = @truncate(regs.read(.phy_chip_id));
    if (chip.isPcie()) reset.configurePcie(regs);
    regs.set(.pci_config, regs_mod.PciConfig, "retry_fix_enable", true);

    regs.put(.phy_test, regs_mod.PhyTest.analog_access);
    chip.radio_revision = readRadioRevision(regs);
    chip.radio_revision_assumed = chip.radio_revision == 0;
    if (chip.radio_revision_assumed) chip.radio_revision = RADIO_REVISION_ASSUMED;

    // The store's size, as the bus block reports it. A part attached by
    // PCI Express reports none and is trusted; anything but sixteen
    // kilobits otherwise is a store this driver has no layout for.
    switch (regs.get(.pci_config, regs_mod.PciConfig).eeprom_size) {
        .kbit16 => {},
        .kbit4 => if (!chip.isPcie()) {
            log.fail(name, "the calibration store's size is not one this driver reads");
            return false;
        },
        .kbit8, .failed => {
            log.fail(name, "the calibration store's size is not one this driver reads");
            return false;
        },
    }

    chip.store = eeprom.read(regs) catch |err| {
        log.begin(name, .bad);
        out.text("the calibration store ");
        out.text(switch (err) {
            error.Unreadable => "does not answer",
            error.Version => "is older than this driver reads",
            error.Checksum => "does not add up",
            error.Address => "holds no station address",
        });
        log.end();
        return false;
    };
    // What the reference sets for these parts whatever the store says:
    // 11b on, turbo off.
    chip.store.b_mode = true;
    chip.store.turbo2_disable = true;
    chip.store.turbo5_disable = true;

    chip.mac = chip.store.mac;
    nic.mac = chip.mac;

    device.chip = chip;
    device.opened = true;
    keep_enabled = true;
    sayIdentity(&device.chip.?);
    return true;
}

/// The radio's revision byte, read through the baseband the way the
/// reference does: a select, eight strobes, then the byte it hands back.
fn readRadioRevision(regs: Regs) u8 {
    regs.write(.phy_bank2, RADIO_REVISION_SELECT);
    for (0..RADIO_REVISION_STROBES) |_| regs.write(.phy_radio_revision_strobe, RADIO_REVISION_STROBE);
    return lib.ar5212.radioRevision(regs.get(.phy_radio_revision, regs_mod.PhyRadioRevision).value);
}

fn sayIdentity(chip: *const reset.Chip) void {
    log.begin(name, .key);
    out.text(chip.version.spell());
    out.text(" rev ");
    out.decimal(chip.revision);
    out.text(", radio 0x");
    out.hex(chip.radio_revision, 2);
    if (chip.radio_revision_assumed) out.text(" assumed, the analog part reported none");
    out.text(", store ");
    out.decimal(chip.store.version.major());
    out.text(".");
    out.decimal(chip.store.version.minor());
    out.text(", mac ");
    const spelled = lib.mac.text(chip.mac);
    out.text(&spelled);
    out.text(", domain 0x");
    out.hex(chip.store.regulatory_domain, 4);
    if (chip.store.capabilities.aes_disabled) out.text(", software cipher only");
    if (chip.store.rf_kill) out.text(", kill switch wired");
    log.end();
}

/// Give the radio its chains, tune it to the first channel, and let it
/// listen. The station above hops from here.
pub fn start(nic: *NicDev) bool {
    if (!device.opened or device.started) return false;

    if (!buildRings()) {
        log.fail(name, "cannot lay out the descriptor chains");
        return false;
    }
    device.started = true;
    if (!tune(.{ .number = 1 })) {
        device.started = false;
        return false;
    }
    pci.enableInterrupt(nic.location);
    sayListening();
    if (dev_mod.radio_up) |up| up(nic);
    return true;
}

/// What the radio is doing once it is listening.
///
/// The kill switch is the thing worth saying: a silenced radio hears
/// nothing and says nothing, which is exactly what a radio somewhere with
/// no network in earshot does, and without this the two cannot be told
/// apart from a log. Said here rather than with the identity because the
/// pin is not an input until the first full reset has wired it.
fn sayListening() void {
    const chip = if (device.chip) |*c| c else return;
    if (!chip.store.rf_kill) return;

    const silenced = reset.killed(chip);
    log.begin(name, if (silenced) .warn else .key);
    out.text(if (silenced)
        "the kill switch is silencing the radio; it will hear nothing"
    else
        "the kill switch is clear");
    log.end();
}

pub fn stop(_: *NicDev) void {
    if (!device.opened) return;
    device.started = false;
    if (device.chip) |*chip| {
        if (!device.gone) {
            quiet(chip.regs);
            reset.sleep(chip.regs);
        }
    }
    releaseRings();
}

/// Silence the radio and let go of every address it holds.
///
/// Ordered so no register still names memory that is about to be handed
/// back: the causes are masked, the engines stopped, and only then is the
/// chain pointer cleared.
fn quiet(regs: Regs) void {
    regs.put(.interrupt_enable, regs_mod.InterruptEnable{});
    regs.put(.interrupt_mask, regs_mod.Interrupts{});
    regs.flush(.interrupt_status_clearing);
    stopReceive(regs);
    regs.write(.rx_pointer, 0);
    regs.flush(.rx_pointer);
}

// ---------------------------------------------------------------------------
// Tuning and receiving
// ---------------------------------------------------------------------------

/// Tune to a channel: the whole reset, with the protocol unit's timers
/// kept after the first, then receive again.
pub fn tune(channel: wifi.Channel) bool {
    if (!device.started or device.gone) return false;
    const chip: *reset.Chip = if (device.chip) |*c| c else return false;
    const megahertz = channel.megahertz() orelse return false;

    stopReceive(chip.regs);
    reset.forgetChannel(chip);
    const kind: reset.Kind = if (device.channel == null) .power_on else .channel_change;
    reset.reset(chip, megahertz, kind) catch |err| {
        log.begin(name, .bad);
        out.text("channel ");
        out.decimal(channel.number);
        out.text(": ");
        out.text(switch (err) {
            error.Asleep => "the radio would not wake",
            error.ChipReset => "the reset did not complete",
            error.Synth => "the synthesizer refused the frequency",
        });
        log.end();
        return false;
    };
    device.channel = channel;
    if (device.nic) |nic| nic.radio_channel = channel.number;

    startReceive(chip.regs);
    chip.regs.put(.interrupt_enable, regs_mod.InterruptEnable{ .enabled = true });
    chip.regs.flush(.interrupt_enable);
    return true;
}

/// The channel the radio is on.
pub fn tuned() ?wifi.Channel {
    return device.channel;
}

/// The periodic calibration: I/Q on a short call, the noise floor too on
/// a long one.
pub fn calibrate(long: bool) void {
    if (!device.started or device.gone) return;
    const chip: *reset.Chip = if (device.chip) |*c| c else return;
    reset.calibrate(chip, long);
}

/// The ceiling on the frames the protocol unit sends itself, from the
/// regulatory plan. Applied at the next reset.
pub fn setSelfPower(half_dbm: u6) void {
    const chip: *reset.Chip = if (device.chip) |*c| c else return;
    chip.self_power = half_dbm;
}

/// Point the radio at the chain and let the protocol unit pass frames:
/// beacons and probe responses for the scan, and everything addressed
/// here or to everyone.
fn startReceive(regs: Regs) void {
    if (device.rings == null) return;
    regs.write(.rx_pointer, Chain.addressOf(chainBase("rx_desc"), device.rx_next));
    dma.publish();
    regs.put(.control, regs_mod.Control{ .rx_enable = true });
    regs.set(.diagnostics, regs_mod.Diagnostics, "rx_disable", false);
    regs.put(.mib_control, regs_mod.MibControl{});
    regs.put(.rx_filter, regs_mod.RxFilter{
        .unicast = true,
        .multicast = true,
        .broadcast = true,
        .beacon = true,
    });
    regs.write(.phy_error_filter, 0);
    regs.set(.rx_config, regs_mod.RxConfig, "zero_length_dma", false);
}

/// Stop the protocol unit passing frames and the engine fetching them,
/// and wait long enough for the frame in flight to land.
fn stopReceive(regs: Regs) void {
    regs.set(.diagnostics, regs_mod.Diagnostics, "rx_disable", true);
    regs.put(.mib_control, regs_mod.MibControl{ .freeze = true, .clear = true });
    regs.put(.rx_filter, regs_mod.RxFilter{});
    regs.put(.control, regs_mod.Control{ .rx_disable = true });
    _ = pace.until(regs, .control, regs_mod.Control, "rx_enable", false, pace.DEFAULT_TRIES);
    pace.delay(3000);
}

/// What the radio has to say. The clearing status register is read once
/// and every cause in it acted on.
pub fn irq(nic: *NicDev) bool {
    if (!device.started or device.gone) return false;
    const chip: *reset.Chip = if (device.chip) |*c| c else return false;
    const regs = chip.regs;

    // A card that has gone answers all ones, which is not the pending
    // bit alone.
    const pending = regs.read(.interrupt_pending);
    if (pending != @as(u32, @bitCast(regs_mod.InterruptPending{ .pending = true }))) return false;

    const cause = regs.get(.interrupt_status_clearing, regs_mod.Interrupts);
    if (cause.isAbsent()) {
        goneAway(nic);
        return false;
    }
    if (!cause.any()) return false;

    if (cause.rx_ok or cause.rx_descriptor or cause.rx_error) reapRx(nic, chip);
    if (cause.rx_overrun) nic.stats.rx_dropped += 1;

    // A chain that ran to its end was starved rather than broken: it is
    // circular, so pointing the radio back at the slot the service is
    // waiting on is all the repair there is.
    if (cause.rx_end_of_list) {
        regs.write(.rx_pointer, Chain.addressOf(chainBase("rx_desc"), device.rx_next));
        regs.put(.control, regs_mod.Control{ .rx_enable = true });
    }
    if (cause.bus_error and !device.bus_error_said) {
        log.warn(name, "the card reported a bus error");
        device.bus_error_said = true;
    }
    return true;
}

/// The kill switch power-gates the slot: the card vanishes mid-word, and
/// everything after reads as ones. Said once, and the carrier is down.
fn goneAway(nic: *NicDev) void {
    device.gone = true;
    log.warn(name, "the radio has gone away; the kill switch, or the slot");
    dev_mod.deliverLink(nic, .{});
}

/// Take every finished receive descriptor, in the order the radio filled
/// them, and give each one back as soon as its frame has been handed
/// over.
fn reapRx(nic: *NicDev, chip: *reset.Chip) void {
    const rings = device.rings orelse return;

    while (true) {
        const slot = device.rx_next;
        const desc: *const volatile Desc = &rings.rx_desc[slot];
        const report = desc.received();
        if (!report.status1.done) break;

        // The chain's tail links back into it, so the hardware may have
        // done this descriptor once and picked it up again: be sure it
        // has moved on before believing the report.
        const following: *const volatile Desc = &rings.rx_desc[Chain.next(slot)];
        if (!following.received().status1.done and
            chip.regs.read(.rx_pointer) == Chain.addressOf(chainBase("rx_desc"), slot)) break;
        dma.consume();

        // A length is the radio's word until it has been measured against
        // the buffer that holds it; the check sequence at the end is the
        // hardware's and not the frame's.
        const length: usize = report.status0.data_length;
        if (report.status1.intact() and !report.status0.more and length > FCS_BYTES and length <= SLAB) {
            const frame = rings.rx_buffer[slot][0 .. length - FCS_BYTES];
            dev_mod.deliverRadio(nic, frame, signalOf(chip, report.status0.signal), report.status0.rate.rate());
        } else {
            nic.stats.rx_dropped += 1;
        }

        armReceive(rings, slot);
        dma.publish();
        device.rx_next = Chain.next(slot);
    }
}

/// The signal a frame arrived at: the baseband's margin over its noise
/// floor, and the absolute figure that margin and the calibrated floor
/// add up to.
fn signalOf(chip: *const reset.Chip, margin: u8) wifi.Signal {
    const dbm = std.math.clamp(@as(i32, chip.noise.current) + margin, std.math.minInt(i8), std.math.maxInt(i8));
    return .{ .snr_db = margin, .dbm = @intCast(dbm) };
}

/// A radio with no association has nowhere to send a frame, and says so
/// rather than dropping it silently.
pub fn transmit(nic: *NicDev, _: []const u8) bool {
    nic.stats.tx_failed += 1;
    return false;
}

/// The carrier of a radio is its association, which does not exist yet.
pub fn link(_: *NicDev) dev_mod.Link {
    return .{};
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
        SLAB,
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
