//! One network interface, driver inside.
//!
//! The shape every NIC driver compiles against, so the service sees `atl2`
//! and `e1000` and `rtl8139` as one thing. A driver fills in the ops; the
//! service owns the event loop, the channel and, when the stack arrives, the
//! packets. Nothing here allocates on a packet path: an interface is one
//! static table entry, its rings are DMA segments made once at start, and a
//! frame handed up is counted here and copied later by whoever owns it.

const lib = @import("lib");
const proto = @import("proto").net;
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
    irq: *const fn (dev: *NicDev) void,
    /// Put one frame on the wire. The bytes are the service's until this
    /// returns, copied into the ring before it does.
    transmit: *const fn (dev: *NicDev, frame: []const u8) void,
    /// The link as the hardware last reported it.
    link: *const fn (dev: *NicDev) Link,
    /// Write the link state into the adapter's own registers. Some MACs gate
    /// their engine on it at boot and never look again; a driver with that
    /// policy provides this so every refresh re-arms the engine, and the
    /// answer "up" can never outrun the hardware being told so.
    sync_link: ?*const fn (dev: *NicDev) void = null,
};

/// One attached adapter.
pub const NicDev = struct {
    /// The driver's name in the probe table, exactly.
    name: []const u8,
    ops: NicOps,
    location: Location,
    irq: u32 = 0,
    mac: [6]u8 = @splat(0),
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

/// Say a whole frame arrived and what was made of it. Until there is a stack
/// the service counts frames and bytes, and remembers the one kind of frame
/// that proves the traffic path: an ARP reply, parsed by the pure library.
pub fn deliverRx(dev: *NicDev, report: RxReport) void {
    if (!report.ok) {
        dev.stats.rx_dropped += 1;
        return;
    }
    dev.stats.rx_pkts += 1;
    dev.stats.rx_bytes += report.frame.len;

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

