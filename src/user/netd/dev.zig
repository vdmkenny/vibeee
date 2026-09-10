//! One network interface, driver inside.
//!
//! The shape every NIC driver compiles against, so the service sees `atl2`
//! and `e1000` and `rtl8139` as one thing. A driver fills in the ops; the
//! service owns the event loop, the channel and, when the stack arrives, the
//! packets. Nothing here allocates on a packet path: an interface is one
//! static table entry, its rings are DMA segments made once at start, and a
//! frame handed up is counted here and copied later by whoever owns it.

const ifmatch = @import("lib").ifmatch;
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const proto = @import("proto").net;
const settings = @import("proto").settings;
const pci = @import("ulib").pci;

pub const Location = pci.Location;

/// What a link has come to. Bandwidth is `mbps`, the machine-readable half of
/// "100 Mbit full duplex" when the tool wants the words.
pub const Link = struct {
    up: bool = false,
    mbps: u16 = 0,
    duplex: proto.Duplex = .unknown,
};

/// Counters, in one place and one shape for every driver: how much moved and
/// how much the hardware had to throw away. u64 internally so a soaked link
/// cannot wrap these between boots of itself.
pub const Stats = struct {
    rx_pkts: u64 = 0,
    rx_bytes: u64 = 0,
    tx_pkts: u64 = 0,
    tx_bytes: u64 = 0,
    /// Received but dropped: exhausted buffers, bad check, undersized.
    rx_dropped: u64 = 0,
    /// Attempted but refused: no descriptor free.
    tx_failed: u64 = 0,
    /// ARP replies this interface has carried.
    rx_arp: u64 = 0,
    /// Deliveries that ended with a cause still latched: work the pass owed
    /// and did not finish. A line that rides the falling edge gets no
    /// second chance at it, so this is the only place it shows.
    irq_late: u64 = 0,
};

/// Receiving something the hardware said about it. A driver hands this to the
/// service rather than a raw count, so the service can tell a frame from a
/// failure later without every driver re-deriving the taxonomy.
pub const RxReport = struct {
    /// The frame, inside DMA memory, valid until `rx_done` is called.
    frame: []const u8 = &.{},
    /// A frame opts in: a report that does not say a frame was received
    /// stays a drop, never a phantom packet.
    ok: bool = false,
};

/// What a driver must provide. Each is called from the event loop thread, so
/// no op may block on anything but bounded hardware waits.
pub const NicOps = struct {
    /// Bring the adapter from unknown power state to configured, rings
    /// allocated and MAC read. No traffic yet.
    open: *const fn (loc: pci.Location, dev: *NicDev) bool,
    /// Let traffic flow and interrupt lines fire.
    start: *const fn (dev: *NicDev) bool,
    /// Stop the engine and mask everything; called at teardown only.
    stop: *const fn (dev: *NicDev) void,
    /// Service one interrupt delivery. Bounded: the line stays masked while
    /// this runs, so everything done here must finish.
    /// Service the line: read the status, move what moved, clear it. Returns
    /// whether anything was actually serviced, which on a shared line is what
    /// wakes the neighbours to look again.
    irq: *const fn (dev: *NicDev) bool,
    /// Service the adapter with no interrupt behind it: reap what has
    /// arrived, and say whether there was an adapter running to be
    /// asked.
    ///
    /// A lost or unrouted interrupt is a wire that goes silent while the
    /// ring fills, and nothing in the driver can tell that from a quiet
    /// network: the line is simply never asserted again. The service
    /// therefore asks every interface whose line is absent, on the passes
    /// it would otherwise have spent waiting for one. Safe to call with
    /// nothing pending, as often as the loop likes, and on an adapter that
    /// has not started; every driver answers that for itself.
    poll: ?*const fn (dev: *NicDev) bool = null,
    /// Work a driver owes that must not happen on an interrupt: a reset, a
    /// re-tune, anything that waits on the part. Called from the loop
    /// between passes rather than from `irq`, where a slow or wedged
    /// adapter would hold the line and everything behind it.
    service: ?*const fn (dev: *NicDev) void = null,
    /// Put one frame on the wire. The bytes are the service's until this
    /// returns, copied into the ring before it does.
    transmit: *const fn (dev: *NicDev, frame: []const u8) bool,
    /// The link as the hardware last reported it.
    link: *const fn (dev: *NicDev) Link,
    /// Write the link state into the adapter's own registers. Some MACs gate
    /// their engine on it at boot and never look again; a driver with that
    /// policy provides this so every refresh re-arms the engine, and the
    /// answer "up" can never outrun the hardware being told so.
    sync_link: ?*const fn (dev: *NicDev) void = null,
    /// What this interface offers beyond a wire, for a radio. The station
    /// works through this table and names no driver, so a second radio is
    /// a second table and nothing else.
    radio: ?RadioOps = null,
};

/// What a radio can be asked that a wire cannot. Everything above the
/// driver speaks to a radio through this and stays ignorant of which one
/// it has.
pub const RadioOps = struct {
    /// Move to a channel, and say whether the hardware settled there.
    tune: *const fn (dev: *NicDev, channel: lib.wifi.Channel) bool,
    /// The channel it is on, or none while it is between channels.
    tuned: *const fn (dev: *NicDev) ?lib.wifi.Channel,
    /// Send no harder than this, in half decibel-milliwatts. What the
    /// figure should be is the regulatory plan's business; how the
    /// hardware is told is the driver's.
    setPower: *const fn (dev: *NicDev, half_dbm: u6) void,
    /// Re-measure what drifts while the radio sits on a channel. The long
    /// form is the one that takes the receiver off the air.
    calibrate: *const fn (dev: *NicDev, long: bool) void,
    /// Re-fit the receiver to the noise it is hearing.
    adapt: *const fn (dev: *NicDev) void,
    /// Answer for this cell: take its traffic, acknowledge what it sends
    /// here, and wake for what it announces. None to answer for nothing,
    /// which is what a station does while it belongs to no cell.
    answerFor: *const fn (dev: *NicDev, cell: ?Cell) void,
    /// Put one frame on the air at this series of rates, worked down in
    /// order. What `transmit` does, with the choice of how fast made by
    /// whoever knows what the far end can hear.
    transmitAt: *const fn (dev: *NicDev, frame: []const u8, series: lib.rates.Series) bool,
    /// Draw bytes nothing here can predict. A radio hears a room full of
    /// things this machine did not arrange, which is the only such source
    /// it has. False while too little has been heard to answer honestly,
    /// and a caller that needs a secret needs that answer.
    draw: ?*const fn (dev: *NicDev, into: []u8) bool = null,
    /// Start the driver's account of what it is hearing over again,
    /// because something changed that makes the old account no evidence.
    /// Not every driver keeps one.
    watchAgain: ?*const fn (dev: *NicDev) void = null,
    /// Say what became of what it tried to send. Asked where something
    /// sent went unanswered, because the first question then is whether
    /// it left at all.
    sayUnanswered: ?*const fn (dev: *NicDev) void = null,
    /// Say what that account came to, where a stretch has passed with
    /// nothing heard at all.
    sayIfUnheard: ?*const fn (dev: *NicDev) void = null,
    /// Say what the receiver is doing. Asked where something that should
    /// have been heard was not, because a receiver that stopped and one
    /// running in a room with nothing in it look the same from here.
    sayReceiver: ?*const fn (dev: *NicDev) void = null,
};

/// The cell a station belongs to: which one, and the number it was given
/// within it.
pub const Cell = struct {
    bssid: lib.mac.Address,
    association: u14 = 0,
};

/// One attached adapter.
/// One interface, and the address of one is its identity.
///
/// A driver is handed this address when it is opened and keeps it; so does
/// the station, for as long as it holds the radio. So an interface lives
/// where it will stay before it is brought up, and is never brought up
/// somewhere else and copied into place afterwards.
pub const NicDev = struct {
    /// The driver's name in the probe table, exactly.
    name: []const u8,
    /// What `net` prints and configuration matches: the driver's name, with
    /// an ordinal from the second interface of one driver ("e1000.1").
    label: ifmatch.Name = .{},
    /// What kind of interface this is, for class matching.
    class: ifmatch.Class = .ether,
    ops: NicOps,
    location: Location,
    irq: u32 = 0,
    irq_gsi: ?u32 = null,
    irq_owned: bool = false,
    /// Whether the hardware is claimed, mapped and started right now.
    ///
    /// An interface can outlive that: a part switched off loses its power
    /// and comes back with its registers as the factory left them, so what
    /// was mapped and started has to be claimed, mapped and started again
    /// before it is anything but a slot with a card in it. The stack's own
    /// interface stays either way, because what a person configured about
    /// it did not stop being true.
    driving: bool = false,
    mac: [6]u8 = @splat(0),
    /// The channel a radio is tuned to, for the listing; zero for a wire.
    radio_channel: u8 = 0,
    state: Link = .{},
    stats: Stats = .{},

    /// What the hardware thinks happened to the last interrupt, remembered so
    /// the service can narrate without poking registers back.
    irq_count: u64 = 0,
    /// When this adapter was last asked about its rings, by its interrupt or
    /// by the loop. Kept so a line that has stopped asserting is noticed
    /// rather than waited on.
    serviced_at: u64 = 0,

    /// The last ARP reply this interface carried: who answered, by hardware
    /// and by address. The traffic proof until the stack replaces the stub.
    peer: ?Peer = null,
};

/// The far end of a wire, as an ARP reply names it.
pub const Peer = struct {
    mac: [6]u8 = @splat(0),
    addr: u32 = 0,
};

/// Where a received frame goes after the counters: the stack, once the
/// service has one running. A hook rather than an import, so this interface
/// module stays what it is, the shape drivers compile against.
pub var stack_rx: ?*const fn (dev: *NicDev, frame: []const u8) void = null;

/// Where a link change goes after the driver notices it, same shape.
pub var stack_link: ?*const fn (dev: *NicDev, up: bool) void = null;

/// A radio speaks 802.11 frames, not ethernet, and they go to the station
/// rather than the stack: every intact frame, with the signal it arrived
/// at and the rate, when the hardware named one the driver knows.
pub var radio_rx: ?*const fn (dev: *NicDev, frame: []const u8, signal: lib.wifi.Signal, rate: ?lib.wifi.Legacy) void = null;

/// How an ordinary frame reaches a radio. A radio carries traffic in its
/// own framing, and turning one into the other needs to know the cell,
/// which is the station's knowledge and no driver's. The station sets
/// this; a machine with no radio leaves it unset.
pub var radio_tx: ?*const fn (dev: *NicDev, frame: []const u8) bool = null;

/// What became of a frame that went out, for whoever is keeping the
/// account that decides how fast the next one goes.
pub var radio_tx_done: ?*const fn (dev: *NicDev, outcome: lib.rates.Outcome) void = null;

/// A radio has its chains and is listening: the station may begin.
pub var radio_up: ?*const fn (dev: *NicDev) void = null;

/// A radio has stopped: powered down, or taken away. Everything above it was
/// about that radio and none of it means anything now.
pub var radio_down: ?*const fn (dev: *NicDev) void = null;

/// Whether an address is one a wire can carry: not a group address, not
/// all zeroes, not all ones.
///
/// Every driver reads its station address out of a part that may have none
/// to give, and a card with no EEPROM answers zeroes rather than refusing.
/// An interface brought up on such an address looks configured and is not:
/// it answers for nobody, every filter built from it matches nothing, and
/// the frames it sends are ignored. Checked once, in one place, so that
/// the three drivers cannot come to disagree about what an address is.
pub fn validMac(mac: [6]u8) bool {
    if (mac[0] & 1 != 0) return false; // the group bit: multicast, not a station
    var any = false;
    var all_ff = true;
    for (mac) |octet| {
        any = any or octet != 0;
        all_ff = all_ff and octet == 0xFF;
    }
    return any and !all_ff;
}

/// Say a radio has gone, for whoever was driving it.
pub fn radioGone(dev: *NicDev) void {
    if (dev.ops.radio == null) return;
    if (radio_down) |down| down(dev);
}

/// Something a watcher would want to know changed: a network heard, beside
/// the addresses the stack already announces. The service's one event.
pub var changed: ?*const fn () void = null;

/// The configuration slot a radio was bound to, whenever it changes: the
/// plan it obeys, the network it joins, the secret it joins with.
pub var radio_config: ?*const fn (dev: *NicDev, role: settings.NetSlot) void = null;

/// Say a whole 802.11 frame arrived: counted here, then handed to the
/// station.
pub fn deliverRadio(dev: *NicDev, frame: []const u8, signal: lib.wifi.Signal, rate: ?lib.wifi.Legacy) void {
    dev.stats.rx_pkts += 1;
    dev.stats.rx_bytes += frame.len;
    if (radio_rx) |up| up(dev, frame, signal, rate);
}

/// Say a whole frame arrived and what was made of it: counted here, then
/// handed to the stack. The ARP narration stays, because it reads the wire
/// beneath the stack and is the debug boot's traffic proof.
/// A frame the radio has finished with: which rate carried it, and
/// whether it arrived.
pub fn deliverTxDone(dev: *NicDev, outcome: lib.rates.Outcome) void {
    if (radio_tx_done) |done| done(dev, outcome);
}

/// The shortest frame a wire will carry: sixty octets of payload, which is
/// sixty-four once the hardware has appended the check sequence.
///
/// Ethernet frames shorter than this are runts and every receiver on a real
/// segment discards them, and an ARP request is forty-two bytes and so is
/// under it. Padded here, once, rather than in each driver: a driver that
/// copies what it is given verbatim sends a runt for every short frame
/// anybody above hands it, and a driver that pads for itself is one more
/// place the minimum has to be remembered. A radio is not padded, because
/// 802.11 has no such minimum and a padded one is a malformed frame.
pub const MIN_WIRE_FRAME = 60;

/// Put one ordinary frame on this interface, whatever medium is under
/// it. A wire takes it as it stands, padded to the minimum; a radio has it
/// dressed as the cell expects first. Everything above here sends the same
/// way to both.
pub fn send(dev: *NicDev, frame: []const u8) bool {
    if (dev.class == .wifi) {
        const dressed = radio_tx orelse return false;
        return dressed(dev, frame);
    }
    if (frame.len >= MIN_WIRE_FRAME) return dev.ops.transmit(dev, frame);

    var padded: [MIN_WIRE_FRAME]u8 = @splat(0);
    @memcpy(padded[0..frame.len], frame);
    return dev.ops.transmit(dev, &padded);
}

pub fn deliverRx(dev: *NicDev, report: RxReport) void {
    if (!report.ok) {
        dev.stats.rx_dropped += 1;
        return;
    }
    dev.stats.rx_pkts += 1;
    dev.stats.rx_bytes += report.frame.len;

    if (stack_rx) |up| up(dev, report.frame);

    // The wire's version of the conversation, for the debug boot: every
    // ARP frame that came up, whatever it asked. The 2s beacons tell us
    // whether the far end is talking to us, and how.
    if (lib.eth.arpParts(report.frame)) |parts| {
        log.begin(dev.name, .dim);
        out.text("arp ");
        out.text(if (parts.op == .request) "who-has " else "reply ");
        var field: [15]u8 = @splat(0);
        out.text(lib.ipv4.text(parts.peer_addr, &field));
        out.text(" from ");
        const spelled = lib.mac.text(parts.peer_mac);
        out.text(&spelled);
        log.end();
    }

    if (lib.eth.arpPeer(report.frame)) |peer| {
        dev.peer = .{ .mac = peer.mac, .addr = peer.addr };
        dev.stats.rx_arp += 1;
    }
}

/// Service one interrupt delivery, the way every driver should.
///
/// A driver supplies the three things only it can know -- what latched, how
/// to acknowledge it, what to do about it -- and the shape of the pass is
/// this function's: read a cause, hold the line while it is worked on,
/// release it, and look again. Bounded, and re-read on the way out.
///
/// The re-read is the part a driver gets wrong. A cause that latches
/// *during* the last pass's work is real work owed, and a driver that ends
/// its loop on a fixed count without looking again has dropped it: on a
/// line that rides the falling edge there is no second edge coming, so the
/// adapter is silent for the rest of the run. Counted where `net` shows it
/// rather than trusted to the driver.
///
/// `Driver.service` must not wait on the part, reset anything, or do
/// anything else slow: the line is held while it runs, and on a shared line
/// so is every neighbour's. Slow work belongs in the `service` op, which
/// the loop calls between passes.
pub fn serveIrq(comptime Driver: type, nic: *NicDev) bool {
    comptime {
        for (.{ "cause", "acknowledge", "service" }) |need| {
            if (!@hasDecl(Driver, need)) @compileError("an interrupt driver needs a " ++ need);
        }
    }

    var serviced = false;
    var round: usize = 0;

    while (round < IRQ_ROUNDS) : (round += 1) {
        const cause = Driver.cause();
        if (cause == 0) break;
        serviced = true;

        // Held for the work, released after it: on a level line that is
        // what keeps the controller from re-asserting mid-pass, and on an
        // edge one it costs nothing.
        Driver.acknowledge(cause, true);
        Driver.service(cause, nic);
        Driver.acknowledge(cause, false);
    }

    if (Driver.cause() != 0) {
        // Work a bounded pass could not finish. The loop asks again
        // (`serviceAdapters`), so it is not lost -- but it is worth seeing.
        nic.stats.irq_late += 1;
    }
    return serviced;
}

/// How many cause/reap rounds one delivery may take. Enough for a burst,
/// bounded so a device that never stops latching cannot hold the loop.
const IRQ_ROUNDS = 8;

/// Say a frame went onto the wire.
pub fn deliverTx(dev: *NicDev, bytes: usize) void {
    dev.stats.tx_pkts += 1;
    dev.stats.tx_bytes += bytes;
}

/// Say the link changed. Drivers call this wherever they refresh `state`,
/// and the stack follows the carrier from here.
pub fn deliverLink(dev: *NicDev, fresh: Link) void {
    const was = dev.state.up;
    dev.state = fresh;
    if (was == fresh.up) return;
    if (stack_link) |follow| follow(dev, fresh.up);
}

/// Whatever a pass owes the adapters besides the lines it waited on.
///
/// Two kinds of asking. An adapter the firmware routed nowhere is asked
/// every pass, because there is no line and no second chance at whatever
/// arrived while the service was busy elsewhere. An adapter that *has* a
/// line is asked too, but only when that line has been quiet for
/// `QUIET_US`: on this class of machine the PIRQ pins ride the falling
/// edge, and an edge that arrives while the driver is mid-service -- or
/// between the last status read and the return -- is gone for good. The
/// interrupt is still the fast path; this is what keeps a lost one from
/// being permanent.
///
/// Deferred work runs for every driven adapter: a reseat that may wait on
/// the part belongs to the loop, not to the line.
pub fn serviceAdapters(interfaces: []NicDev) void {
    const now = clock();

    for (interfaces) |*iface| {
        if (!iface.driving) continue;

        if (iface.ops.service) |work| work(iface);

        const poll = iface.ops.poll orelse continue;
        const quiet = iface.irq == 0 or now -% iface.serviced_at >= QUIET_US;
        if (!quiet) continue;
        if (poll(iface)) iface.serviced_at = now;
    }
}

/// How long a line may be quiet before the loop asks as well as listens.
///
/// Long enough that a busy adapter is served by its interrupts and not by
/// this, short enough that a lost one costs a few frames rather than the
/// rest of the boot.
const QUIET_US: u64 = 25_000;

/// Microseconds since the machine started, as this file counts them. Public
/// so that the loop marking an adapter serviced and the loop deciding whether
/// one has been quiet read the same clock.
pub fn clock() u64 {
    return @intCast(@import("sys").clockMicros());
}
