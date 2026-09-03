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

/// A radio has its chains and is listening: the station may begin.
pub var radio_up: ?*const fn (dev: *NicDev) void = null;

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
