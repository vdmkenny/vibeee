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

/// The one queue this station sends from. The family has ten, which are
/// there to hold traffic of different urgencies apart; a station with no
/// such classes has one kind of traffic and needs one queue.
const QUEUE: u4 = 0;

/// How much of a reception is worth stirring into the pool. A frame that
/// failed to decode is noise all the way through, so the beginning of one
/// says as much as the whole of it.
const NOISE_BYTES = 64;

/// How a station waits its turn: the window it backs off within, in
/// slots, and the fixed space it leaves ahead of that. The distributed
/// access defaults, which every station in a cell shares.
const CONTENTION_MIN = 15;
const CONTENTION_MAX = 1023;
const ARBITRATION_SPACE = 2;

/// How many times the hardware tries a frame before it gives up, and how
/// many times it tries the exchange that reserves the air for one.
const FRAME_TRIES = 10;
const STATION_TRIES = 32;

comptime {
    if (QUEUE >= regs_mod.QUEUES) @compileError("the queue is not one the family has");
    // A frame that fits the buffer must be one the descriptor can state,
    // which is what lets the transmit path measure against the buffer
    // alone.
    if (SLAB > lib.ar5212.MAX_FRAME) @compileError("a full buffer states a length the descriptor cannot hold");
}

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
    phys: lib.Phys = .none,
    dma_handle: ?u32 = null,
    /// The next descriptor the service expects to find finished.
    rx_next: usize = 0,
    /// The next transmit descriptor the service will fill, the next it
    /// expects to find finished, and how many lie between them.
    tx_next: usize = 0,
    tx_reap: usize = 0,
    tx_filled: usize = 0,
    /// The descriptor the chain currently ends at, which a new frame is
    /// linked onto. None while the queue has nothing outstanding, and the
    /// radio has to be pointed at the frame rather than led to it.
    tx_link: ?usize = null,
    /// The channel tuned, or none yet.
    channel: ?wifi.Channel = null,
    /// The cell this station answers for, or none while it belongs to
    /// nothing.
    cell: ?dev_mod.Cell = null,
};

var device: Device = .{};

pub const ops = dev_mod.NicOps{
    .open = open,
    .start = start,
    .stop = stop,
    .irq = irq,
    .transmit = transmit,
    .link = link,
    .radio = .{
        .tune = tune,
        .tuned = tuned,
        .setPower = setPower,
        .calibrate = calibrate,
        .adapt = adapt,
        .answerFor = answerFor,
        .transmitAt = transmitAt,
        .draw = draw,
        .sayUnanswered = sayUnanswered,
        .watchAgain = watchAgain,
        .sayIfUnheard = sayIfUnheard,
    },
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
    if (!tune(nic, .{ .number = 1 })) {
        device.started = false;
        return false;
    }
    // Before the line is armed: a device left delivering messages asserts
    // no pin, and this system routes pins.
    if (pci.useIntx(nic.location)) {
        log.note(name, "the card was set to message interrupts; turned back to its pin");
    }
    pci.enableInterrupt(nic.location);
    sayListening();

    // Reported exactly once, so a hook nobody has taken yet is a report
    // made to nobody and a radio that never hops off the channel it was
    // first tuned to. Silence would look like a quiet band.
    if (dev_mod.radio_up) |up| {
        up(nic);
    } else {
        log.warn(name, "nothing was listening for the radio coming up; it will not scan");
    }
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
    log.begin(name, if (silenced) .warn else .dim);
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
    listenFor(regs, .{});
    regs.flush(.interrupt_status_clearing);
    stopTransmit(regs);
    stopReceive(regs);
    regs.write(.rx_pointer, 0);
    regs.flush(.rx_pointer);
}

// ---------------------------------------------------------------------------
// Tuning and receiving
// ---------------------------------------------------------------------------

/// Tune to a channel: the whole reset, with the protocol unit's timers
/// kept after the first, then receive again.
pub fn tune(_: *NicDev, channel: wifi.Channel) bool {
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
    startTransmit(chip.regs);
    listenFor(chip.regs, WANTED);
    return true;
}

/// The causes this driver acts on, and so the only ones it asks to be woken
/// for. Every one of them is answered in `irq`.
const WANTED = regs_mod.Interrupts{
    .rx_ok = true,
    .rx_descriptor = true,
    .rx_error = true,
    .rx_overrun = true,
    .rx_end_of_list = true,
    .bus_error = true,
    // Frames the baseband heard and could not make sense of. Not asked
    // for by a driver that only wants traffic, and asked for here because
    // it is the one thing that separates a receiver hearing nothing at
    // all from one hearing a band it cannot decode: a radio counting
    // these is a radio whose analog path reaches its demodulator.
    .rx_phy_error = true,
    .tx_ok = true,
    .tx_error = true,
};

/// Ask the radio to raise its line for exactly `causes`, and for nothing if
/// there are none.
///
/// Two registers, and both of them matter. The mask says which causes may
/// raise the line at all; the enable is a gate in front of it, and a gate in
/// front of nothing stays shut for ever. A card whose mask is clear receives
/// perfectly well and says nothing about it: frames land in the chain by
/// themselves, the chain fills, and nothing ever comes to read it, because
/// being told is what the line is for.
///
/// Shut before either is written and opened after, which is the order the
/// vendor's own driver uses: a cause arriving between the two writes would
/// be raised against a mask half rewritten.
fn listenFor(regs: Regs, causes: regs_mod.Interrupts) void {
    regs.put(.interrupt_enable, regs_mod.InterruptEnable{});
    regs.flush(.interrupt_enable);
    // A transmit cause asked for here is still silent until the queue it
    // belongs to is named in the secondary mask. The primary word says
    // what kind of news is wanted; these say whose.
    const ours: u10 = if (causes.tx_ok or causes.tx_error) @as(u10, 1) << QUEUE else 0;
    regs.put(.interrupt_mask_0, regs_mod.InterruptsS0{ .tx_ok = ours });
    regs.put(.interrupt_mask_1, regs_mod.InterruptsS1{ .tx_error = ours });

    regs.put(.interrupt_mask, causes);
    if (!causes.any()) return;
    regs.put(.interrupt_enable, regs_mod.InterruptEnable{ .enabled = true });
    regs.flush(.interrupt_enable);
}

/// Say, once, when the radio has been listening and its line has never
/// delivered anything.
///
/// Three faults look identical from outside, and this is everything needed
/// to tell them apart. A mask that reads back empty is a write the chip did
/// not take, and nothing will ever raise the line. A mask that took, with
/// causes standing in the status register, is a radio raising an interrupt
/// that does not arrive here, which is a question about how the line is
/// routed rather than about the radio. A mask that took with nothing
/// standing is a radio that genuinely has nothing to say, and then the fault
/// is in front of the baseband rather than behind it.
///
/// The pin and the decode are said beside them because a card that asserts
/// correctly and is told not to, or is routed to a line nobody waits on,
/// answers the second case and is not the radio's doing either.
pub fn sayIfUnheard(nic: *NicDev) void {
    if (said_unheard or !device.started or device.gone) return;
    said_unheard = true;
    const woken = nic.irq_count -| since.woken;

    const chip: *reset.Chip = if (device.chip) |*c| c else return;

    // What a sweep of the band came to, whether or not anything woke this
    // service. A radio that is woken thousands of times and hands up no
    // frame is as much a fault as one that is never woken at all, and it
    // is a different one: the first is hearing a band it cannot make sense
    // of, the second is hearing nothing.
    log.begin(name, if (woken == 0) .warn else .dim);
    out.text("a sweep of the band: woken ");
    out.decimal(@intCast(nic.irq_count -| since.woken));
    out.text(" times, ");
    out.decimal(phy_errors);
    out.text(" of them frames it could not decode, ");
    out.decimal(@intCast(nic.stats.rx_pkts -| since.handed_up));
    out.text(" handed up, ");
    out.decimal(@intCast(nic.stats.rx_dropped -| since.dropped));
    out.text(" dropped");
    const split = givenUpByModulation();
    out.text(" (");
    out.decimal(split.ofdm);
    out.text(" on ofdm, ");
    out.decimal(split.cck);
    out.text(" on cck)");
    if (commonestGivingUp()) |common| {
        out.text("; it gave up most often for ");
        // The silicon has codes this build does not name, and one of those
        // is still worth reporting by its number rather than not at all.
        if (std.enums.tagName(lib.ar5212.PhyError, common.why)) |named| {
            out.text(named);
        } else {
            out.text("reason 0x");
            out.hex(@intFromEnum(common.why), 2);
        }
        out.text(", ");
        out.decimal(common.times);
        out.text(" times");
    }
    log.end();

    sayReceivePath(chip);
    if (woken != 0) return;

    const regs = chip.regs;
    const command = pci.readCommand(nic.location);

    log.begin(name, .warn);
    out.text("listening and never woken: mask 0x");
    out.hex(@as(u32, @bitCast(regs.get(.interrupt_mask, regs_mod.Interrupts))), 8);
    out.text(", enabled ");
    out.text(if (regs.get(.interrupt_enable, regs_mod.InterruptEnable).enabled) "yes" else "no");
    out.text(", standing 0x");
    // The status that does not clear on reading, so this cannot take a
    // cause the handler is owed.
    out.hex(@as(u32, @bitCast(regs.get(.interrupt_status, regs_mod.Interrupts))), 8);
    out.text(", pin ");
    out.text(@tagName(pci.interruptPin(nic.location)));
    if (command.interrupt_disable) out.text(" told not to assert");
    out.text(", line ");
    if (nic.irq_gsi) |gsi| {
        out.decimal(gsi);
    } else {
        out.text("none");
    }
    log.end();
}

/// What the receive path is doing, said beside the interrupt plumbing when
/// nothing has woken this service.
///
/// The noise floor is the measurement that matters: it is taken through the
/// analog receive chain itself, so a plausible one is that chain working and
/// the fault being somewhere between a frame arriving and this service
/// hearing of it. One that never settled, or settled somewhere impossible,
/// is a receive chain that is not listening at all, and no descriptor will
/// ever complete however well the engine is set up.
///
/// The engine and where it is pointed are said next to it because those are
/// the other way a chain completes nothing: an engine that is not running,
/// or one walking descriptors that are not the ones this service reads.
fn sayReceivePath(chip: *reset.Chip) void {
    const regs = chip.regs;

    log.begin(name, .dim);
    out.text("the receive path: noise floor ");
    out.signed(chip.noise.current);
    out.text(" dBm");
    if (chip.noise.settling) out.text(" (not settled)");

    // The reading itself, beside what is done with it. A floor settles
    // only out of readings inside the plausible band, and one outside it
    // starts the window over, so a floor that never settles is a reading
    // that keeps arriving impossible: the value is the whole question and
    // the settled figure never shows it.
    out.text(", last read ");
    out.signed(reset.readNoiseFloor(regs));
    out.text(" against a ceiling of ");
    out.signed(chip.store.section(.g).noise_floor_threshold);
    out.text(", heard and not understood ");
    out.decimal(phy_errors);
    // Read back rather than assumed. Everything above says what the radio
    // was told; these say what it is holding, and a setting that did not
    // survive whatever came after it looks exactly like one that was never
    // written.
    out.text(", baseband ");
    out.text(if (regs.get(.phy_active, regs_mod.PhyActive).enable) "active" else "idle");
    out.text(", accepting 0x");
    out.hex(@as(u32, @bitCast(regs.get(.rx_filter, regs_mod.RxFilter))), 4);
    out.text(", engine ");
    out.text(if (regs.get(.control, regs_mod.Control).rx_enable) "running" else "stopped");
    out.text(", walking 0x");
    out.hex(regs.read(.rx_pointer), 8);
    out.text(" of 0x");
    out.hex(Chain.addressOf(chainBase("rx_desc"), 0), 8);
    log.end();
}

var said_unheard = false;

/// What a sweep is measured against: the counters as they stood when the
/// radio was last told something new. A report covering the whole life of
/// the interface would be mostly about whatever it was doing before the
/// change that prompted a fresh look, which is the opposite of the
/// question being asked.
const Since = struct { woken: u64 = 0, handed_up: u64 = 0, dropped: u64 = 0 };
var since = Since{};

/// Look again, and measure from here.
///
/// Called when the radio is told something new, because everything
/// counted until then was about the radio it used to be: a channel it was
/// not listening on is not evidence about the one it is.
pub fn watchAgain(nic: *NicDev) void {
    said_unheard = false;
    phy_errors = 0;
    given_up = @splat(0);
    judged = .{};
    since = .{
        .woken = nic.irq_count,
        .handed_up = nic.stats.rx_pkts,
        .dropped = nic.stats.rx_dropped,
    };
}

/// Frames the baseband heard and could not decode. Counted rather than
/// acted on: nothing can be done with one, and the count is the proof that
/// the analog path reaches the demodulator at all.
var phy_errors: usize = 0;

/// How often the baseband gave up for each reason, by the code it gives.
///
/// Which reason dominates is what a radio failing every frame has to say
/// for itself: the codes come in an OFDM family and a CCK one, so a radio
/// failing all of one and none of the other is misconfigured for that
/// modulation, and one failing both the same way is not listening to the
/// right thing at all.
var given_up: [GIVEN_UP_CODES]u16 = @splat(0);

/// The codes the silicon uses fit in six bits; anything wider than the
/// list this build names is still counted under its own number.
const GIVEN_UP_CODES = 64;

/// What a period of listening came to, and what to do about it.
///
/// The baseband decides for itself when a signal has begun, and one too
/// willing to decide finds signals in noise: it starts, fails on the
/// timing, and says so, often enough that a real frame arriving in the
/// middle has nothing listening for it. So how hard it is to convince is
/// raised while it is giving up too often and lowered when it is not,
/// and the counts it is judged on are the ones it reported itself.
pub fn adapt(_: *NicDev) void {
    const chip: *reset.Chip = if (device.chip) |*c| c else return;
    if (!device.started or device.gone) return;

    const now = givenUpByModulation();
    if (chip.immunity.heard(chip.regs, now.ofdm -| judged.ofdm, now.cck -| judged.cck)) {
        sayImmunity(chip);
    }
    judged = now;
}

/// What the counts stood at when the radio was last judged. The tally
/// itself is the sweep's to report, so what a dwell came to is the
/// difference rather than a count anybody clears.
var judged: Modulations = .{};

const Modulations = struct { ofdm: u32 = 0, cck: u32 = 0 };

/// The failures so far, split by which demodulator gave up. The two fail
/// separately and are made harder to convince separately, and a radio
/// failing all of one and none of the other is not configured for that
/// modulation at all.
fn givenUpByModulation() Modulations {
    var totals = Modulations{};
    for (given_up, 0..) |times, code| {
        if (times == 0) continue;
        switch (lib.ar5212.modulationOf(@enumFromInt(@as(u8, @intCast(code))))) {
            .ofdm => totals.ofdm += times,
            .cck => totals.cck += times,
            .either => {},
        }
    }
    return totals;
}

fn sayImmunity(chip: *const reset.Chip) void {
    // Kept rather than gated behind asking for debug: a radio that had to
    // be made harder to convince is a room worth knowing about.
    log.begin(name, .value);
    const at = chip.immunity.rungs();
    out.text("harder to convince: noise ");
    out.decimal(at.noise);
    out.text(", spur ");
    out.decimal(at.spur);
    out.text(", first step ");
    out.decimal(at.firstep);
    log.end();
}

/// Unpredictable bytes, gathered from what the radio hears. The band is
/// full of things this machine did not arrange, and a frame the baseband
/// could not decode is nothing but those.
var noise = lib.entropy.Pool{};

/// Stir one reception in: how it measured, when it landed, and what it
/// amounted to. Only until the pool has had enough, because past that
/// point the hashing is work with nothing to show for it.
fn stirFrom(report: anytype, heard: []const u8) void {
    if (noise.ready()) return;
    var words: [8]u8 = undefined;
    std.mem.writeInt(u32, words[0..4], @bitCast(report.status0), .little);
    std.mem.writeInt(u32, words[4..8], @bitCast(report.status1), .little);
    noise.stir(&words);
    noise.stir(heard);
}

/// Bytes nothing here can predict, or false while too little has been
/// heard to say that honestly.
pub fn draw(_: *NicDev, into: []u8) bool {
    return noise.draw(into);
}

/// What became of everything this radio tried to send. Asked where
/// something sent went unanswered, because the first question then is
/// whether it was sent at all, and the account and the registers answer
/// that between them.
pub fn sayUnanswered(nic: *NicDev) void {
    if (!device.started or device.gone) return;
    const chip: *reset.Chip = if (device.chip) |*c| c else return;
    const regs = chip.regs;

    const enabled = regs.get(.queue_enable, regs_mod.QueueMask).queues;
    const held = regs.get(.queue_disable, regs_mod.QueueMask).queues;
    const status: regs_mod.QueueStatus = @bitCast(regs.readAt(regs_mod.queueStatus(QUEUE)));

    // Always said, never dimmed: this is asked for where something has
    // already gone wrong, and a line that reports the fault only when the
    // fault is of one particular kind is a line that is missing exactly
    // when it is wanted.
    log.begin(name, .warn);
    out.text("what it sent: ");
    out.decimal(@intCast(nic.stats.tx_pkts));
    out.text(" went, ");
    out.decimal(@intCast(nic.stats.tx_failed));
    out.text(" did not, ");
    out.decimal(device.tx_filled);
    out.text(" still in the queue");
    if (commonestUnsent()) |common| {
        out.text("; most often ");
        out.text(std.enums.tagName(lib.ar5212.Failure, common.why) orelse "of no stated kind");
        out.text(", ");
        out.decimal(common.times);
        out.text(" times");
    }

    // The registers, because a queue that is held still or was never
    // pointed anywhere is a different fault from one that sent and was
    // not answered.
    out.text(". The queue is ");
    out.text(if (enabled & (@as(u10, 1) << QUEUE) != 0) "running" else "idle");
    if (held & (@as(u10, 1) << QUEUE) != 0) out.text(", and held still");
    out.text(", pointed at ");
    out.hex(regs.readAt(regs_mod.txPointer(QUEUE)), 8);
    out.text(", with ");
    out.decimal(status.pending_frames);
    out.text(" frames pending. It heard ");
    out.decimal(@intCast(nic.stats.rx_pkts));
    out.text(" frames and dropped ");
    out.decimal(@intCast(nic.stats.rx_dropped));
    log.end();
}

/// How frames failed to leave, by kind. A station that cannot get a word
/// in says which way it is failing rather than only that it is.
var unsent = std.enums.EnumArray(lib.ar5212.Failure, u32).initFill(0);

fn noteUnsent(why: lib.ar5212.Failure) void {
    unsent.getPtr(why).* +|= 1;
}

/// A kind of failure and how often it has been met.
const Unsent = struct { why: lib.ar5212.Failure, times: u32 };

/// The kind of failure the radio meets most often, if it has met any.
fn commonestUnsent() ?Unsent {
    var worst: ?Unsent = null;
    for (std.enums.values(lib.ar5212.Failure)) |why| {
        const times = unsent.get(why);
        if (times == 0) continue;
        if (worst == null or times > worst.?.times) worst = .{ .why = why, .times = times };
    }
    return worst;
}

fn noteGivenUp(why: lib.ar5212.PhyError) void {
    const code = @intFromEnum(why);
    if (code < GIVEN_UP_CODES) given_up[code] +|= 1;
}

/// The reason the baseband gave most often, and how many times.
fn commonestGivingUp() ?struct { why: lib.ar5212.PhyError, times: u16 } {
    var best: usize = 0;
    var most: u16 = 0;
    for (given_up, 0..) |times, code| {
        if (times <= most) continue;
        most = times;
        best = code;
    }
    if (most == 0) return null;
    return .{ .why = @enumFromInt(@as(u8, @intCast(best))), .times = most };
}

/// The channel the radio is on.
pub fn tuned(_: *NicDev) ?wifi.Channel {
    return device.channel;
}

/// The periodic calibration: I/Q on a short call, the noise floor too on
/// a long one.
pub fn calibrate(_: *NicDev, long: bool) void {
    if (!device.started or device.gone) return;
    const chip: *reset.Chip = if (device.chip) |*c| c else return;
    reset.calibrate(chip, long);
}

/// The ceiling on the frames the protocol unit sends itself, from the
/// regulatory plan. Applied at the next reset.
pub fn setPower(_: *NicDev, half_dbm: u6) void {
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
    regs.put(.rx_filter, receiveFilter());
    // Undecodable frames are asked for here and not in the filter above:
    // the protocol unit takes no bit for them, which is why one written
    // there is dropped. Both modulations this radio speaks, because either
    // failing is the same news, and a receiver hearing a band it cannot
    // make sense of is what tells it apart from a band with nothing on it.
    const errors = regs_mod.PhyErrorFilter{ .ofdm = true, .cck = true };
    regs.put(.phy_error_filter, errors);

    // One of these arrives with no frame behind it, so the engine has to be
    // willing to write nothing at all. Asking for them without this is
    // asking for a report that cannot be delivered.
    regs.set(.rx_config, regs_mod.RxConfig, "zero_length_dma", @as(u32, @bitCast(errors)) != 0);
}

/// Set the queue up to send: one scheduler feeding one arbiter, waiting
/// its turn the way every station in a cell agrees to.
fn startTransmit(regs: Regs) void {
    if (device.rings == null) return;

    // Which scheduler feeds this arbiter. One each, so a frame queued is
    // a frame this arbiter contends for.
    regs.putAt(regs_mod.dcuQueueMask(QUEUE), regs_mod.QueueMask{ .queues = @as(u10, 1) << QUEUE });
    regs.putAt(regs_mod.dcuLocalIfs(QUEUE), regs_mod.LocalIfs{
        .contention_min = CONTENTION_MIN,
        .contention_max = CONTENTION_MAX,
        .arbitration_space = ARBITRATION_SPACE,
    });
    regs.putAt(regs_mod.dcuRetryLimit(QUEUE), regs_mod.RetryLimit{
        .frame_short = FRAME_TRIES,
        .frame_long = FRAME_TRIES,
        .station_short = STATION_TRIES,
        .station_long = STATION_TRIES,
    });
    // Nothing holds the medium for a stretch: a frame at a time, released
    // between them.
    regs.putAt(regs_mod.dcuChannelTime(QUEUE), regs_mod.ChannelTime{});
    regs.putAt(regs_mod.queueMisc(QUEUE), regs_mod.QueueMisc{
        .scheduling = .as_soon_as_possible,
        .early_termination = true,
    });
    regs.putAt(regs_mod.dcuMisc(QUEUE), regs_mod.DcuMisc{ .wait_for_fragment = true });
}

/// Stop the queue and let go of whatever the service was still holding
/// room for.
fn stopTransmit(regs: Regs) void {
    regs.holdQueues(@as(u10, 1) << QUEUE);
    _ = pace.until(regs, .queue_enable, regs_mod.QueueMask, "queues", 0, pace.DEFAULT_TRIES);
    regs.releaseQueues();
    device.tx_next = 0;
    device.tx_reap = 0;
    device.tx_filled = 0;
    device.tx_link = null;
}

/// What the receiver accepts. A station with no cell of its own has
/// nothing to be selective about: it is listening to a band to find out
/// what is on it, and a frame addressed elsewhere is exactly what it is
/// looking for. Once it belongs to a cell, it takes what is meant for it.
fn receiveFilter() regs_mod.RxFilter {
    // A station the cell has not yet given a number to is still finding
    // its way in, and hears everything while it does: the address is set
    // early so the hardware answers for the cell, and narrowing what it
    // listens to that early would only hide the replies it is waiting on.
    const inside = if (device.cell) |cell| cell.association != 0 else false;
    return .{
        .unicast = true,
        .multicast = true,
        .broadcast = true,
        .beacon = true,
        .promiscuous = !inside,
    };
}

/// Answer for a cell: take its traffic and acknowledge what it addresses
/// here. None to answer for nothing, which is where a station starts and
/// where it returns when it leaves.
pub fn answerFor(_: *NicDev, cell: ?dev_mod.Cell) void {
    device.cell = cell;
    const chip: *reset.Chip = if (device.chip) |*c| c else return;

    // Kept on the chip, not only in its registers: a reset writes them
    // back from here, so a retune does not drop the cell.
    chip.bssid = if (cell) |c| c.bssid else @splat(0);
    chip.association_id = if (cell) |c| c.association else 0;
    if (device.gone) return;

    chip.regs.write(.bss_id_low, std.mem.readInt(u32, chip.bssid[0..4], .little));
    chip.regs.put(.bss_id_high, regs_mod.BssIdHigh{
        .address_high = std.mem.readInt(u16, chip.bssid[4..6], .little),
        .association_id = chip.association_id,
    });
    chip.regs.put(.rx_filter, receiveFilter());
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

    // All ones before anything else. A card that has gone answers that to
    // every read, and it is not the pending bit alone, so a test for the
    // pending bit sends it away as an interrupt that was not ours: the
    // card is then never noticed to have gone, however many times it is
    // asked. Absence is read from the raw word rather than from a
    // bitfield, because a bitfield is an interpretation and this is the
    // value that means there was nothing to interpret.
    const pending = regs.read(.interrupt_pending);
    if (pending == std.math.maxInt(u32)) {
        goneAway(nic);
        return false;
    }
    if (pending != @as(u32, @bitCast(regs_mod.InterruptPending{ .pending = true }))) return false;

    const cause = regs.get(.interrupt_status_clearing, regs_mod.Interrupts);
    if (cause.isAbsent()) {
        goneAway(nic);
        return false;
    }
    if (!cause.any()) return false;

    if (cause.rx_ok or cause.rx_descriptor or cause.rx_error) reapRx(nic, chip);
    if (cause.tx_ok or cause.tx_error) reapTx(nic);
    if (cause.rx_overrun) nic.stats.rx_dropped += 1;
    if (cause.rx_phy_error) phy_errors +%= 1;

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
        stirFrom(report, rings.rx_buffer[slot][0..@min(length, NOISE_BYTES)]);
        if (report.status1.intact() and !report.status0.more and length > FCS_BYTES and length <= SLAB) {
            const frame = rings.rx_buffer[slot][0 .. length - FCS_BYTES];
            dev_mod.deliverRadio(nic, frame, signalOf(chip, report.status0.signal), report.status0.rate.rate());
        } else {
            nic.stats.rx_dropped += 1;
            if (report.status1.phyError()) |why| noteGivenUp(why);
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

/// Count a frame that never left, and say so to the caller.
fn refused(nic: *NicDev) bool {
    nic.stats.tx_failed += 1;
    return false;
}

/// Put one frame on the air. The bytes are already a whole radio frame:
/// what goes where in it is the station's business, and how fast and how
/// hard it goes is this one's.
pub fn transmit(nic: *NicDev, frame: []const u8) bool {
    const channel = device.channel orelse return refused(nic);
    // Nothing has been agreed about this frame, so it goes at the rate
    // the band obliges every station to understand.
    return transmitAt(nic, frame, lib.rates.only(channel.band.slowest(), FRAME_TRIES));
}

/// The same, at a chosen series: try the first, and work down to the one
/// that has to arrive.
pub fn transmitAt(nic: *NicDev, frame: []const u8, series: lib.rates.Series) bool {
    if (!device.started or device.gone) return refused(nic);
    const chip: *reset.Chip = if (device.chip) |*c| c else return refused(nic);
    const rings = device.rings orelse return refused(nic);
    if (series.slice().len == 0) return refused(nic);
    if (frame.len == 0 or frame.len > SLAB) return refused(nic);

    // Finished descriptors first: the ring is short, and a frame offered
    // just after one completes should find the room it freed.
    reapTx(nic);
    if (device.tx_filled == RING_SLOTS) return refused(nic);

    const slot = device.tx_next;
    @memcpy(rings.tx_buffer[slot][0..frame.len], frame);

    // Only a frame sent to one station is answered, and only an answered
    // frame is worth retrying. A group address is spoken to the room.
    const head = lib.ieee80211.Header.parse(frame);
    const answered = if (head) |h| !lib.mac.isGroup(h.addr1) else false;

    const desc: *volatile Desc = &rings.tx_desc[slot];
    desc.armTransmit(chainBase("tx_buffer") + @as(u32, @intCast(slot * SLAB)), 0, .{
        .frame_bytes = @intCast(frame.len),
        .series = series,
        .power = chip.self_power,
        .acknowledged = answered,
    });
    dma.publish();

    const address = Chain.addressOf(chainBase("tx_desc"), slot);
    if (device.tx_link) |tail| {
        // The queue is already running: put this frame on the end of the
        // chain it is working through.
        rings.tx_desc[tail].link = address;
        dma.publish();
    } else {
        chip.regs.writeAt(regs_mod.txPointer(QUEUE), address);
    }
    device.tx_link = slot;
    device.tx_next = Chain.next(slot);
    device.tx_filled += 1;

    // Said every time, not only when the chain was empty: a queue that
    // reached the old end and stopped before the link was written needs
    // telling that there is more.
    chip.regs.put(.queue_enable, regs_mod.QueueMask{ .queues = @as(u10, 1) << QUEUE });
    return true;
}

/// Take every finished transmit descriptor, in the order the radio
/// worked through them, and account for what became of each frame.
fn reapTx(nic: *NicDev) void {
    const rings = device.rings orelse return;

    while (device.tx_filled != 0) {
        const slot = device.tx_reap;
        const desc: *const volatile Desc = &rings.tx_desc[slot];
        const report = desc.sent();
        if (!report.done()) break;
        dma.consume();

        // Which rates to credit and which to blame. The control words are
        // as they were written, so the frame says this about itself.
        //
        // Every step the hardware worked past is a step that did not get
        // through, and it is said so: a rate blamed only when it is the
        // last one tried is a rate whose failures are always paid for by
        // the step behind it, and the account would go on choosing it.
        const speeds: lib.ar5212.TxControl3 = @bitCast(desc.body.tx.control3);
        const final = report.status1.final_series;
        for (0..@as(usize, final) + 1) |step| {
            const carried = lib.ar5212.rateOfStep(speeds, @intCast(step)).rate() orelse continue;
            dev_mod.deliverTxDone(nic, .{
                .rate = carried,
                .sent = step == final and report.status0.sent,
            });
        }

        if (report.failure()) |why| {
            nic.stats.tx_failed += 1;
            noteUnsent(why);
        } else {
            nic.stats.tx_pkts += 1;
            // The hardware leaves the control words as they were written,
            // so the frame measures itself and needs no record kept
            // alongside the ring.
            const filled: lib.ar5212.TxControl1 = @bitCast(desc.body.tx.control1);
            nic.stats.tx_bytes += filled.buffer_length;
        }

        device.tx_reap = Chain.next(slot);
        device.tx_filled -= 1;
        // The chain ends where the service stopped filling it. With
        // nothing outstanding there is no end to add to, and the next
        // frame is one the radio has to be pointed at.
        if (device.tx_filled == 0) device.tx_link = null;
    }
}

/// The carrier of a radio is the cell it belongs to. Nothing has agreed
/// on a faster rate than the one the band obliges every station to
/// understand, so that is what it runs at.
pub fn link(_: *NicDev) dev_mod.Link {
    if (device.cell == null) return .{};
    const channel = device.channel orelse return .{};
    return .{
        .up = true,
        .mbps = @intCast(channel.band.slowest().kbps() / 1000),
        .duplex = .half,
    };
}

// ---------------------------------------------------------------------------
// The chains
// ---------------------------------------------------------------------------

/// Where one chain begins, as the radio addresses it.
fn chainBase(comptime field: []const u8) u32 {
    return device.phys.addr() + @offsetOf(Rings, field);
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

    var phys: lib.Phys = .none;
    const handle = sys.dmaAlloc(@sizeOf(Rings), &phys);
    if (handle < 0) {
        log.failed(name, "cannot allocate the descriptor chains", handle);
        return false;
    }
    const owned: u32 = @intCast(handle);

    if (!Chain.addressable(phys.addr()) or phys.addr() % @alignOf(Rings) != 0) {
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
    device.phys = .none;
}
