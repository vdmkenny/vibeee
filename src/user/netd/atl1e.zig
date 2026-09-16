//! Attansic L1E 10/100/1000 ethernet (1969:1026): the wired port of the
//! Eee PC 1000 and of the 901 units that carry one, sold as the Atheros
//! AR8121, AR8113 and AR8114. The first is gigabit and the other two are
//! not; they answer the same device number and are told apart only by what
//! their PHY negotiates, so this drives all three the same way.
//!
//! Everything around the frames is the family's and is in `attansic.zig`,
//! shared with the L2 that the 701 carries: the block reset, the MDIO
//! controller, the station address, the gaps, and the low half of the MAC
//! control word. What is here is this part's own, which is the two ways it
//! moves frames.
//!
//! **Transmit is a descriptor ring.** Each descriptor points at one frame
//! and says how long it is. The frame is copied into device memory first,
//! because the buffer the stack hands down is not this driver's to give a
//! device an address for. A mailbox tells the part how far the ring has
//! been filled; a second register says how far it has got through it.
//!
//! **Receive is two pages, not a ring.** The part writes frames one after
//! another into a page of device memory, each behind a sixteen byte record
//! saying how long it is and what it was, and rounds the next one up to a
//! thirty-two byte boundary. Where it has got to is a counter it writes
//! into memory of its own, not a register, so reading it costs nothing.
//! When a page is full this driver hands it back with one byte write and
//! reads the other, which the part has been filling meanwhile.
//!
//! Every record carries a sequence number. Frames written into a page this
//! driver has already handed back would otherwise look like frames, and the
//! sequence is what says they are not.
//!
//! Nothing polls. The part interrupts when frames arrive, when the transmit
//! ring drains, and when the PHY sees the link change; nothing here asks
//! about any of those between interrupts. The one bounded wait is the MDIO
//! controller's, in `attansic`, where there is nothing to wait on.

const attansic = @import("attansic.zig");
const cursor = @import("cursor.zig");
const dev_mod = @import("dev.zig");
const dma = @import("dma.zig");
const lib = @import("lib");
const log = @import("ulib").log;
const mii = @import("mii.zig");
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const rxpage = @import("rxpage.zig");
const std = @import("std");
const sys = @import("sys");

const NicDev = dev_mod.NicDev;

/// Who this driver is, for the probe table and the interface listing.
pub const name = "atl1e";
pub const vendor = 0x1969;
pub const device_id = 0x1026;

const MMIO_BYTES: u32 = 256 * 1024;
const ETH_HEADER = lib.eth.HEADER;
const ETH_FCS = rxpage.ETH_FCS;
/// The largest frame the MAC is set up to carry, tag included. The same
/// figure the receive page is sized around.
const MAC_FRAME_LIMIT = rxpage.MAX_FRAME;
const ETH_MAX_FRAME = MAC_FRAME_LIMIT - 4;

// ---------------------------------------------------------------------------
// This part's own registers
// ---------------------------------------------------------------------------

/// What the family shares is `attansic.Register`, reached through a window
/// of its own. Keeping the sets apart means a register named in one cannot
/// be reached through the other by accident.
const R32 = enum(u32) {
    /// Wake on LAN, cleared: nothing here wakes a machine from the wire.
    wol_ctrl = 0x14A0,
    /// How much receive FIFO the part has, which sets the pause marks.
    sram_rxf_len = 0x1524,
    /// Written after every base address, to make the part take them.
    load_ptr = 0x1534,
    rxf0_page0_lo = 0x1544,
    rxf0_page1_lo = 0x1548,
    tpd_base_lo = 0x154C,
    rxf_page_size = 0x1558,
    tpd_ring_size = 0x155C,
    /// Which queue a hash lands in, and the processor it is counted
    /// against. Both zero: there is one queue.
    hash_table = 0x1560,
    base_cpu = 0x157C,
    tx_early_th = 0x1584,
    rxq_ctrl = 0x15A0,
    rxq_pause_thresh = 0x15A8,
    dma_ctrl = 0x15C0,
    /// How often the part totals its own counters. Left long: nothing
    /// here reads them.
    smb_stat_timer = 0x15C4,
    /// How far the ring has been filled, as the part is told.
    mb_tpd_prod_idx = 0x15F0,
    /// Where the part writes how far it has filled each page.
    rxf0_page0_written = 0x1820,
    rxf0_page1_written = 0x1824,
    /// Where it writes how far it has got through the ring.
    tx_mark_lo = 0x1840,
};

const R16 = enum(u32) {
    /// The moderation timer's second half, which the part wants set
    /// alongside the family's.
    irq_modu_timer2 = 0x140A,
    /// This part's PHY power and reset control. The L2's register at the
    /// same offset is a single enable bit.
    gphy_ctrl = 0x140C,
    txq_ctrl = 0x1580,
    /// How large a burst the transmit queue reads, in the upper half of
    /// the queue control register.
    txq_burst = 0x1582,
    rxq_jumbo = 0x15A4,
    /// How many descriptors or records before the part interrupts, and
    /// how long it waits when fewer than that have arrived.
    trig_tpd_thresh = 0x15C8,
    trig_rrd_thresh = 0x15CA,
    trig_tx_timer = 0x15CC,
    trig_rx_timer = 0x15CE,
    /// How far the part has got through the transmit ring.
    tpd_cons_idx = 0x1804,
};

/// The two bytes that hand a receive page back.
const R8 = enum(u32) {
    rxf0_page0_valid = 0x15F4,
    rxf0_page1_valid = 0x15F5,
};

const Regs = struct {
    word: lib.mmio.Window(R32, u32) = .{ .base = undefined },
    half: lib.mmio.Window(R16, u16) = .{ .base = undefined },
    byte: lib.mmio.Window(R8, u8) = .{ .base = undefined },
    common: attansic.Words = .{ .base = undefined },
    family: attansic.Halves = .{ .base = undefined },

    fn over(base: [*]volatile u8) Regs {
        const words: lib.mmio.Window(R32, u32) = .{ .base = base };
        return .{
            .word = words,
            .half = words.as(R16, u16),
            .byte = words.as(R8, u8),
            .common = words.as(attansic.Register, u32),
            .family = words.as(attansic.Register16, u16),
        };
    }

    fn aperture(self: Regs) [*]volatile u8 {
        return self.word.base;
    }
};

/// One past the highest register this driver touches, in whichever width
/// it is reached: the smallest aperture that can serve it.
const REGISTERS_END = @max(
    @max(pci.registersEnd(R32, @sizeOf(u32)), pci.registersEnd(R16, @sizeOf(u16))),
    @max(
        pci.registersEnd(R8, @sizeOf(u8)),
        @max(
            pci.registersEnd(attansic.Register, @sizeOf(u32)),
            pci.registersEnd(attansic.Register16, @sizeOf(u16)),
        ),
    ),
);

// ---------------------------------------------------------------------------
// Register shapes
// ---------------------------------------------------------------------------

/// This part's PHY power and reset control.
const GphyCtrl = packed struct(u16) {
    external_reset: bool = false,
    pipe_mode: bool = false,
    test_mode: u2 = 0,
    bert_start: bool = false,
    gate_25m: bool = false,
    leave_low_power: bool = false,
    phy_idle: bool = false,
    phy_idle_disable: bool = false,
    pclk_select_disable: bool = false,
    hibernate: bool = false,
    hibernate_pulse: bool = false,
    analog_reset: bool = false,
    pll_on: bool = false,
    power_down: bool = false,
    _15: u1 = 0,
};

/// The PHY awake and able to hibernate between frames, which is what the
/// part wants before its reset is released.
const GPHY_AWAKE = GphyCtrl{
    .pll_on = true,
    .analog_reset = true,
    .hibernate_pulse = true,
    .hibernate = true,
};

/// This part's MAC control word: the family's low half, and above it what
/// this part defines for itself.
const MacCtrl = packed struct(u32) {
    base: attansic.MacBase = .{},
    tx_pause: bool = false,
    shortcut_slot_time: bool = false,
    sync_reset_tx: bool = false,
    tx_simulation_reset: bool = false,
    speed: attansic.Speed = .m10_100,
    tx_backpressure: bool = false,
    tx_huge: bool = false,
    rx_checksum: bool = false,
    multicast_all: bool = false,
    broadcast_accept: bool = false,
    /// Upload every frame that arrives, whatever its address. A debug
    /// mode; the L2 uses this bit for something else entirely.
    upload_all: bool = false,
    _28: u4 = 0,
};

/// What latched. Numbered this part's way, which is not the L2's: the two
/// registers are at the same offset and agree about almost nothing.
const Isr = packed struct(u32) {
    /// The counter block finished totalling.
    statistics: bool = false,
    timer: bool = false,
    manual: bool = false,
    /// The part's own receive FIFO overflowed.
    rxf_overflow: bool = false,
    /// A receive page filled with nobody reading it. One bit per queue,
    /// of which this driver uses the first.
    page_overflow: bool = false,
    page1_overflow: bool = false,
    page2_overflow: bool = false,
    page3_overflow: bool = false,
    txf_underrun: bool = false,
    page_full: bool = false,
    dmar_timeout: bool = false,
    dmaw_timeout: bool = false,
    phy: bool = false,
    tx_credit: bool = false,
    phy_low_power: bool = false,
    _15: u1 = 0,
    rx_packet: bool = false,
    tx_packet: bool = false,
    tx_dma: bool = false,
    rx_packet1: bool = false,
    rx_packet2: bool = false,
    rx_packet3: bool = false,
    mac_rx: bool = false,
    mac_tx: bool = false,
    unsupported_request: bool = false,
    fatal_error: bool = false,
    nonfatal_error: bool = false,
    correctable_error: bool = false,
    phy_link_down: bool = false,
    _29: u2 = 0,
    /// Hold interrupts while this pass runs, which is what a shared line
    /// needs and costs nothing on one that is not.
    hold: bool = false,

    fn none(self: Isr) bool {
        var causes = self;
        causes.hold = false;
        return @as(u32, @bitCast(causes)) == 0;
    }
};

/// Every cause acknowledged. Bit 31 is the hold and bits 29 and 30 are
/// reserved, so none of them is written here.
const ACK_EVERYTHING: u32 = @bitCast(packed struct(u32) {
    causes: u29 = std.math.maxInt(u29),
    _29: u2 = 0,
    hold: bool = false,
}{});

/// What may interrupt: frames either way, the PHY, the link going down
/// under the part, the fatal DMA pair, and the receive paths that overflow.
/// A cause nobody unmasks is a cause nobody is told about.
const UNMASKED = Isr{
    .rx_packet = true,
    .tx_packet = true,
    .txf_underrun = true,
    .rxf_overflow = true,
    .page_overflow = true,
    .phy = true,
    .phy_low_power = true,
    .dmar_timeout = true,
    .dmaw_timeout = true,
    .phy_link_down = true,
    .manual = true,
};

const TxqCtrl = packed struct(u32) {
    /// How many descriptors the part fetches at once.
    burst: u4 = 0,
    _4: u1 = 0,
    enabled: bool = false,
    /// Two back to back reads rather than one.
    enhanced: bool = false,
    _7: u9 = 0,
    /// How many bytes it reads in one aligned burst.
    read_burst: u16 = 0,
};

const RxqCtrl = packed struct(u32) {
    /// What the part aligns each frame in a page to. Thirty-two, which
    /// is what the record walk below assumes.
    alignment: Alignment = .b32,
    _2: u2 = 0,
    queue_enabled: u3 = 0,
    ipv6_checksum: bool = false,
    hash_length: u8 = 0,
    hash_ipv4: bool = false,
    hash_ipv4_tcp: bool = false,
    hash_ipv6: bool = false,
    hash_ipv6_tcp: bool = false,
    _20: u6 = 0,
    hash_mode: u2 = 0,
    queue_select_table: bool = false,
    hash_enabled: bool = false,
    /// Start writing a frame out before the whole of it has arrived.
    cut_through: bool = false,
    enabled: bool = false,

    const Alignment = enum(u2) { b32 = 0, b64 = 1, b128 = 2, b256 = 3 };
};

const DmaCtrl = packed struct(u32) {
    read_in_order: bool = false,
    read_enhanced_order: bool = false,
    read_out_of_order: bool = false,
    read_completion_boundary: bool = false,
    read_burst: pci.PcieDeviceControl.Burst = .b128,
    write_burst: pci.PcieDeviceControl.Burst = .b128,
    /// Reads before writes on the link.
    read_priority: bool = false,
    read_delay: u5 = 0,
    write_delay: u4 = 0,
    /// Have the part write where it has got to, rather than keeping it
    /// in a register this side would have to read.
    tx_mark_in_memory: bool = false,
    rx_mark_in_memory: bool = false,
    _22: u10 = 0,
};

/// The byte that hands a receive page back to the part.
const PageValid = packed struct(u8) {
    valid: bool = false,
    number: u7 = 0,
};

// ---------------------------------------------------------------------------
// The descriptors
// ---------------------------------------------------------------------------

/// One transmit descriptor: where the frame is, how long, and what the
/// part should do about it beyond sending it, which here is nothing.
const Tpd = extern struct {
    buffer: u64 align(8) = 0,
    length: Length = .{},
    about: About = .{},

    const Length = packed struct(u32) {
        bytes: u14 = 0,
        /// Interrupt when the part has read the buffer.
        read_interrupt: bool = false,
        /// Interrupt when the frame has gone.
        sent_interrupt: bool = false,
        vlan: u16 = 0,
    };

    /// Everything the part can be asked to do to a frame on its way out.
    /// All of it is left off: checksums and segmentation are the stack's
    /// here, and a driver that offers them has to be right about every
    /// header offset in the frame.
    const About = packed struct(u32) {
        /// The last descriptor of a frame. Every frame here is one
        /// descriptor, so every descriptor is the last of one.
        end_of_frame: bool = false,
        ipv6: bool = false,
        insert_vlan: bool = false,
        custom_checksum: bool = false,
        segment: bool = false,
        ip_checksum: bool = false,
        tcp_checksum: bool = false,
        udp_checksum: bool = false,
        vlan_tagged: bool = false,
        ethernet_ii: bool = false,
        ip_header_words: u4 = 0,
        tcp_header_words: u4 = 0,
        header_only: bool = false,
        segment_size: u13 = 0,
    };
};

comptime {
    if (@sizeOf(Tpd) != 16) @compileError("a transmit descriptor is sixteen bytes");
    if (@sizeOf(Isr) != 4 or @sizeOf(MacCtrl) != 4) {
        @compileError("a control register shapes one dword");
    }
    if (@as(u16, @bitCast(GPHY_AWAKE)) != 0x3C00) {
        @compileError("the PHY control word drifted");
    }

    // The interrupt register is at the same offset as the L2's and
    // numbers its bits differently, so every one this driver acts on is
    // pinned to the value the part is documented with.
    const causes = .{
        .{ Isr{ .statistics = true }, 0x1 },
        .{ Isr{ .timer = true }, 0x2 },
        .{ Isr{ .manual = true }, 0x4 },
        .{ Isr{ .rxf_overflow = true }, 0x8 },
        .{ Isr{ .page_overflow = true }, 0x10 },
        .{ Isr{ .txf_underrun = true }, 0x100 },
        .{ Isr{ .page_full = true }, 0x200 },
        .{ Isr{ .dmar_timeout = true }, 0x400 },
        .{ Isr{ .dmaw_timeout = true }, 0x800 },
        .{ Isr{ .phy = true }, 0x1000 },
        .{ Isr{ .tx_credit = true }, 0x2000 },
        .{ Isr{ .phy_low_power = true }, 0x4000 },
        .{ Isr{ .rx_packet = true }, 0x1_0000 },
        .{ Isr{ .tx_packet = true }, 0x2_0000 },
        .{ Isr{ .tx_dma = true }, 0x4_0000 },
        .{ Isr{ .mac_rx = true }, 0x40_0000 },
        .{ Isr{ .mac_tx = true }, 0x80_0000 },
        .{ Isr{ .unsupported_request = true }, 0x100_0000 },
        .{ Isr{ .phy_link_down = true }, 0x1000_0000 },
        .{ Isr{ .hold = true }, 0x8000_0000 },
    };
    for (causes) |one| {
        if (@as(u32, @bitCast(one[0])) != one[1]) @compileError("an interrupt cause drifted");
    }

    // And the same for the words that start the two queues and the
    // engine between them.
    if (@as(u32, @bitCast(TxqCtrl{ .enabled = true, .enhanced = true })) != 0x60 or
        @as(u32, @bitCast(RxqCtrl{ .enabled = true, .cut_through = true, .ipv6_checksum = true })) != 0xC000_0080 or
        @as(u32, @bitCast(DmaCtrl{ .read_priority = true, .rx_mark_in_memory = true })) != 0x20_0400 or
        @as(u32, @bitCast(Tpd.About{ .end_of_frame = true })) != 0x1 or
        @as(u32, @bitCast(Tpd.Length{ .bytes = 0x3FFF })) != 0x3FFF or
        @as(u8, @bitCast(PageValid{ .valid = true })) != 0x1)
    {
        @compileError("a queue or descriptor word drifted");
    }
}

// ---------------------------------------------------------------------------
// The rings, one DMA segment
// ---------------------------------------------------------------------------

/// How many frames may be waiting to go. A multiple of four, which is what
/// the part counts its ring in.
const TPD_COUNT = 32;

/// One frame's worth of device memory per descriptor. The stack's buffer
/// is not this driver's to hand a device an address for, so every frame is
/// copied into one of these first.
const TX_SLOT = 1536;

/// The two pages the part fills in turn. How large they are and what is
/// written into them is `rxpage`.
const PAGES = 2;

const Rings = extern struct {
    /// The transmit ring, which the part reads.
    tpd: [TPD_COUNT]Tpd align(16) = @splat(.{}),
    /// Where the part says it has got to in each page. It writes these
    /// by DMA rather than keeping them in registers, so looking is a
    /// load from memory this process already has mapped.
    written: [PAGES]u32 align(rxpage.ALIGN) = @splat(0),
    /// Where the part would total the transmit side, which it is given
    /// an address for and never asked to use: how far it has got through
    /// the ring is a register, and that is what this driver reads.
    tx_mark: u32 align(rxpage.ALIGN) = 0,
    /// The frames it receives, one page filled while the other is read.
    page: [PAGES][rxpage.PAGE_ROOM]u8 align(rxpage.ALIGN) = @splat(@splat(0)),
    /// The frames it sends, copied in before the ring is advanced.
    slot: [TPD_COUNT][TX_SLOT]u8 align(8) = @splat(@splat(0)),
};

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const Device = struct {
    regs: Regs = .{},
    location: pci.Location = .{ .bus = 0, .device = 0, .function = 0 },
    arena: dma.Arena(Rings) = undefined,
    mac: [6]u8 = @splat(0),
    /// Where the next frame goes in the transmit ring, and how far the
    /// part had got last time this side looked.
    fill: cursor.Cursor(TPD_COUNT) = .{},
    reaped: cursor.Cursor(TPD_COUNT) = .{},
    /// Which page is being read, and where the walk through it stands.
    reading: usize = 0,
    walk: rxpage.Walk = .{},
    /// What the link last came to, so a change is a change.
    link_state: dev_mod.Link = .{},
    /// A full reconfigure is owed, and what asked for it. Done between
    /// passes rather than on the line: everything it waits on is the
    /// part's, and on a shared line every neighbour would wait with it.
    reseat_pending: bool = false,
    reseat_cause: u32 = 0,
    opened: bool = false,
    started: bool = false,
};

var device: Device = .{};

// ---------------------------------------------------------------------------
// Life
// ---------------------------------------------------------------------------

pub fn open(loc: pci.Location, dev: *NicDev) bool {
    if (device.opened) return false;

    device.location = loc;
    const aperture = pci.openApertureNeeding(loc, 0, MMIO_BYTES, REGISTERS_END, name, "adapter") orelse
        return false;
    // Every way out of here but the last gives the registers back: a
    // driver that fails to open is asked again each time the service
    // restarts, and an aperture left mapped each time is a window of this
    // process's address space that never comes back.
    var keep_pci_enabled = false;
    defer if (!keep_pci_enabled) {
        sys.shmUnmap(@volatileCast(device.regs.aperture()));
        pci.disableInterruptAndMaster(loc);
    };
    device.regs = Regs.over(@ptrCast(aperture));

    // A device left delivering message-signalled interrupts asserts no
    // pin, and this system routes pins.
    if (pci.useIntx(loc)) {
        log.note(name, "the adapter was set to message interrupts; turned back to its pin");
    }

    device.regs.common.write(.imr, 0);
    _ = device.regs.common.read(.imr);
    log.say(name, .dim, "registers mapped");

    device.mac = readMac() orelse {
        log.fail(name, "cannot read a valid MAC address");
        return false;
    };

    // One run of device memory for the whole of the rings, taken and
    // mapped as one thing: a mapping is a reference of its own, so a
    // handle closed under a live mapping frees nothing.
    device.arena = dma.Arena(Rings).acquire() catch |why| {
        switch (why) {
            error.NoMemory => log.refused(name, "cannot allocate DMA rings", error.NoMemory),
            error.Misaligned => log.fail(name, "DMA memory is not aligned for the adapter"),
            error.Unmappable => log.fail(name, "cannot map DMA rings"),
        }
        return false;
    };
    log.say(name, .dim, "rings placed");

    if (!configure()) {
        pci.disableInterruptAndMaster(loc);
        keep_pci_enabled = true;
        device.arena.release();
        sys.shmUnmap(@volatileCast(device.regs.aperture()));
        device.regs = .{};
        return false;
    }
    log.say(name, .dim, "engine configured");

    dev.mac = device.mac;
    device.opened = true;
    keep_pci_enabled = true;
    dev_mod.deliverLink(dev, link(dev));
    return true;
}

/// Reset and configure. Bounded waits only: a wedged controller costs a
/// refused driver, never a machine.
fn configure() bool {
    device.regs.common.write(.imr, 0);
    _ = device.regs.common.read(.imr);

    attansic.reset(device.regs.common, sys.sleepMicros) catch {
        log.fail(name, "engines did not become idle after reset");
        return false;
    };
    resetRings();

    if (!phyInit()) {
        log.fail(name, "PHY did not answer");
        return false;
    }

    device.regs.common.write(.isr, ACK_EVERYTHING);
    attansic.writeStation(device.regs.common, device.mac);
    // Nothing here wakes the machine from the wire, and a part left armed
    // by firmware would hold its PHY awake for it.
    device.regs.word.write(.wol_ctrl, 0);

    if (!placeRings()) return false;
    configureTiming();
    configureQueues();

    const latched: Isr = @bitCast(device.regs.common.read(.isr));
    device.regs.common.write(.isr, ACK_EVERYTHING);
    device.regs.common.write(.isr, 0);
    if (latched.phy_link_down) {
        log.fail(name, "PCIe link dropped during configuration");
        return false;
    }
    return true;
}

fn resetRings() void {
    device.fill = .{};
    device.reaped = .{};
    device.reading = 0;
    device.walk.restart();

    const rings = device.arena.body();
    for (&rings.tpd) |*descriptor| descriptor.* = .{};
    for (&rings.written) |*mark| mark.* = 0;
    rings.tx_mark = 0;
}

/// Where one region of the rings sits, as the number the part is
/// programmed with. Asked of the arena rather than added to its base here,
/// so the offset is the arena's to bound against the run it handed out.
fn ringAt(offset: usize) ?u32 {
    const place = device.arena.physOf(offset) orelse return null;
    return place.addr();
}

/// Tell the part where everything is. Every base is written, then the load
/// register, which is what makes it take them.
fn placeRings() bool {
    const regs = device.regs;
    // This machine is thirty-two bit, so the high half of every address
    // is zero. Said rather than left: the part keeps one high half for
    // the whole arena and would otherwise fetch from wherever it points.
    regs.common.write(.desc_base_hi, 0);

    regs.word.write(.tpd_base_lo, ringAt(@offsetOf(Rings, "tpd")) orelse return false);
    regs.word.write(.tpd_ring_size, TPD_COUNT);
    regs.word.write(.tx_mark_lo, ringAt(@offsetOf(Rings, "tx_mark")) orelse return false);

    const pages = [PAGES]R32{ .rxf0_page0_lo, .rxf0_page1_lo };
    const marks = [PAGES]R32{ .rxf0_page0_written, .rxf0_page1_written };
    const valid = [PAGES]R8{ .rxf0_page0_valid, .rxf0_page1_valid };
    for (pages, marks, valid, 0..) |page, mark, hand_back, which| {
        regs.word.write(page, ringAt(@offsetOf(Rings, "page") + which * rxpage.PAGE_ROOM) orelse return false);
        regs.word.write(mark, ringAt(@offsetOf(Rings, "written") + which * @sizeOf(u32)) orelse return false);
        regs.byte.write(hand_back, @bitCast(PageValid{ .valid = true }));
    }
    regs.word.write(.rxf_page_size, rxpage.PAGE_BYTES);

    dma.publish();
    regs.word.write(.load_ptr, 1);
    return true;
}

/// How long the part waits before telling this side about work.
///
/// Every one of these is a trade between latency and how many interrupts a
/// busy wire costs, and on a 630 MHz processor the second half of that is
/// the one that matters. The figures are the vendor driver's.
fn configureTiming() void {
    const regs = device.regs;
    // Two microsecond units: two hundred microseconds between deliveries,
    // and a hundred milliseconds after which a latched cause is delivered
    // whether or not the moderator would have held it longer.
    const MODERATION = 100;
    const ANTI_LOST = 50_000;

    regs.family.write(.irq_modu_timer, MODERATION);
    regs.half.write(.irq_modu_timer2, MODERATION);
    regs.common.write(.master_ctrl, @bitCast(attansic.MasterCtrl{
        .moderation_timer = true,
        .moderation_timer2 = true,
        .led_mode = true,
    }));

    // One record is enough to be worth an interrupt; half the transmit
    // ring going is. Below either the timers below deliver anyway.
    regs.half.write(.trig_rrd_thresh, 1);
    regs.half.write(.trig_tpd_thresh, TPD_COUNT / 2);
    regs.half.write(.trig_rx_timer, 4);
    regs.half.write(.trig_tx_timer, MODERATION * 4 / 3);
    regs.family.write(.cmbdisdma_timer, ANTI_LOST);
    regs.word.write(.smb_stat_timer, 200_000);

    regs.common.write(.mtu, MAC_FRAME_LIMIT);
    regs.common.write(.mac_ipg_ifg, @bitCast(attansic.IpgIfg{
        .ipgt = 0x60,
        .min_ifg = 0x50,
        .ipgr1 = 0x40,
        .ipgr2 = 0x60,
    }));
    regs.common.write(.mac_half_duplex, @bitCast(attansic.HalfDuplex{
        .lcol = 0x37,
        .retry = 0xF,
        .exc_defer = true,
        .abebt = 0xA,
        .jam_ipg = 7,
    }));
}

/// Start the two queues and the DMA engine between them.
fn configureQueues() void {
    const regs = device.regs;

    // How much the part may move in one burst, which is the smaller of
    // what it would like and what the link settled on. Asking for more
    // than the link carries puts packets on it that the other end will
    // not take.
    const settled = linkBurst();
    regs.word.write(.dma_ctrl, @bitCast(DmaCtrl{
        .read_out_of_order = true,
        .read_priority = true,
        .read_burst = settled.read,
        .write_burst = settled.write,
        // Where the part has filled each receive page is written into
        // memory this side already has mapped, so looking costs a load
        // rather than an uncached register read. The transmit side keeps
        // its own in a register, which is the reference driver's
        // arrangement and the one its hardware is known to honour.
        .rx_mark_in_memory = true,
    }));

    // A frame is never held back for being large: this driver offers the
    // part no checksums or segmentation to be held back for.
    regs.word.write(.tx_early_th, EIGHTHS);
    regs.half.write(.txq_burst, settled.read.bytes());
    regs.half.write(.txq_ctrl, @truncate(@as(u32, @bitCast(TxqCtrl{
        .burst = 5,
        .enabled = true,
        .enhanced = true,
    }))));

    // Ask the far end to pause when the part's own FIFO is four fifths
    // full and release it at a fifth. The part reports how large that
    // FIFO is; zeroes here are not "off" but pause-always, which would
    // have the generator fighting the transmit path for the wire on
    // every frame received.
    const fifo = regs.word.read(.sram_rxf_len);
    regs.word.write(.rxq_pause_thresh, @bitCast(PauseMarks{
        .ask = fit(fifo * 4 / 5),
        .release = fit(fifo / 5),
    }));
    regs.half.write(.rxq_jumbo, @bitCast(JumboMarks{ .cut_through_at = EIGHTHS, .look_ahead = 1 }));

    // One queue, no hashing: this machine has one processor and nothing
    // above this driver wants frames sorted before it sees them.
    regs.word.write(.hash_table, 0);
    regs.word.write(.base_cpu, 0);
    regs.word.write(.rxq_ctrl, @bitCast(RxqCtrl{
        .alignment = .b32,
        .ipv6_checksum = true,
        .cut_through = true,
        .enabled = true,
    }));
}

/// The marks the pause generator works to, in entries of the part's own
/// receive FIFO.
const PauseMarks = packed struct(u32) {
    /// Full enough to ask the far end to stop.
    ask: u12 = 0,
    _12: u4 = 0,
    /// Empty enough to let it start again.
    release: u12 = 0,
    _28: u4 = 0,
};

/// When the part starts writing a frame out before the whole of it has
/// arrived, in eight-byte units.
const JumboMarks = packed struct(u16) {
    cut_through_at: u11 = 0,
    /// How far ahead of itself it reads while doing that.
    look_ahead: u4 = 0,
    _15: u1 = 0,
};

/// The largest frame, counted the way these registers count: eight bytes
/// to the unit. Eleven bits is the narrowest field that carries it, and
/// this machine's frames are nowhere near filling one.
const EIGHTHS: u11 = (MAC_FRAME_LIMIT + 7) >> 3;

/// A figure the part reported, cut to the field that carries it. A FIFO
/// larger than the field describes would otherwise spill into the mark
/// beside it and ask the far end to pause forever.
fn fit(value: anytype) u12 {
    return @intCast(@min(value, std.math.maxInt(u12)));
}

const Burst = struct {
    read: pci.PcieDeviceControl.Burst,
    write: pci.PcieDeviceControl.Burst,
};

/// What the link settled on, or the smallest burst there is where the part
/// carries no PCI Express capability to ask.
fn linkBurst() Burst {
    // What the part would use given the room. A kilobyte is the vendor
    // driver's figure for both directions.
    const WANTED = pci.PcieDeviceControl.Burst.b1024;

    const at = pci.capabilityAt(device.location, .pcie) orelse return .{ .read = .b128, .write = .b128 };
    const control: pci.PcieDeviceControl = @bitCast(
        pci.read(device.location, at + pci.PcieDeviceControl.OFFSET),
    );
    return .{
        .read = WANTED.atMost(control.max_read_request),
        .write = WANTED.atMost(control.max_payload),
    };
}

pub fn start(nic: *NicDev) bool {
    if (!device.opened or device.started) return false;

    // Whatever the PHY latched while the reset armed it is history.
    _ = readPhy(.interrupt_clear);

    device.regs.common.write(.isr, ACK_EVERYTHING);
    device.regs.common.write(.isr, 0);

    device.started = true;
    syncLink(nic);

    device.regs.common.write(.imr, @bitCast(UNMASKED));
    _ = device.regs.common.read(.imr);
    return true;
}

pub fn stop(nic: *NicDev) void {
    _ = nic;
    if (!device.opened) return;
    device.started = false;

    device.regs.common.write(.imr, 0);
    _ = device.regs.common.read(.imr);

    var ctrl: MacCtrl = @bitCast(device.regs.common.read(.mac_ctrl));
    ctrl.base.rx_enable = false;
    ctrl.base.tx_enable = false;
    device.regs.common.write(.mac_ctrl, @bitCast(ctrl));
    _ = device.regs.common.read(.mac_ctrl);

    // The queues stop with the engines; the reset is what actually lets
    // the memory below go.
    attansic.reset(device.regs.common, sys.sleepMicros) catch {};
    device.regs.half.write(.txq_ctrl, 0);
    device.regs.word.write(.rxq_ctrl, 0);
    _ = device.regs.word.read(.rxq_ctrl);

    pci.disableInterruptAndMaster(device.location);
    device.arena.release();
    sys.shmUnmap(@volatileCast(device.regs.aperture()));
    device.regs = .{};
    device.opened = false;
}

// ---------------------------------------------------------------------------
// The PHY
// ---------------------------------------------------------------------------

fn mdio() attansic.Mdio {
    return .{ .words = device.regs.common };
}

fn writePhy(register: attansic.Phy, value: u16) bool {
    mdio().write(register, value) catch return false;
    return true;
}

fn readPhy(register: attansic.Phy) ?u16 {
    return mdio().read(register) catch null;
}

fn readMac() ?[6]u8 {
    // Where the firmware left it. The part also keeps a copy in an
    // attached serial memory this driver does not read: a machine whose
    // firmware brought the port up has the right address in the working
    // registers, and one that did not answers all zero, which is refused
    // rather than invented.
    const mac = attansic.readStation(device.regs.common);
    return if (dev_mod.validMac(mac)) mac else null;
}

/// Wake the PHY, apply the maker's corrections, arm link interrupts and
/// start negotiating.
///
/// The five writes through the debug registers are the vendor driver's,
/// where they carry no explanation beyond which part of the analog side
/// each one settles. They are transcribed rather than reasoned about.
fn phyInit() bool {
    const regs = device.regs;
    regs.half.write(.gphy_ctrl, @bitCast(GPHY_AWAKE));
    sys.sleepMicros(2_000);
    var awake = GPHY_AWAKE;
    awake.external_reset = true;
    regs.half.write(.gphy_ctrl, @bitCast(awake));
    sys.sleepMicros(2_000);

    const corrections = [_]struct { at: u16, value: u16 }{
        .{ .at = 0x0B, .value = 0xBC00 },
        .{ .at = 0x00, .value = 0x02EF },
        .{ .at = 0x12, .value = 0x4C04 },
        .{ .at = 0x04, .value = 0x8BBB },
        .{ .at = 0x05, .value = 0x2C46 },
    };
    for (corrections) |one| {
        if (!writePhy(.debug_addr, one.at)) return false;
        if (!writePhy(.debug_data, one.value)) return false;
    }
    sys.sleepMicros(1_000);

    if (!writePhy(.interrupt, @bitCast(attansic.BOTH_LINK_EVENTS))) return false;
    if (!writePhy(.advertise, @bitCast(mii.ADVERTISE_FAST))) return false;
    // A thousand megabits as well, on the part of the family that can.
    // Two of the three cannot, and have no such register to write: the
    // answer is not checked, because on those parts there is nothing for
    // it to mean.
    _ = writePhy(.gigabit, @bitCast(mii.Gigabit{ .thousand_full = true, .thousand_half = true }));
    return writePhy(.control, @bitCast(mii.Control{
        .reset = true,
        .autoneg_enable = true,
        .restart_autoneg = true,
    }));
}

pub fn link(nic: *NicDev) dev_mod.Link {
    _ = nic;
    if (!device.opened) return .{};

    // Read twice, the way the vendor's driver does: the first may latch.
    _ = readPhy(.status) orelse return .{};
    const status: mii.Status = @bitCast(readPhy(.status) orelse return .{});
    if (mii.outcome(status) == null) return .{ .up = false };

    const settled: attansic.Resolved = @bitCast(readPhy(.resolved) orelse return .{});
    if (!settled.settled) return .{};
    const speed = settled.speed.wire() orelse return .{};

    const outcome = mii.resolved(status, speed, if (settled.full_duplex) .full else .half) orelse
        return .{};
    return dev_mod.linkFrom(outcome);
}

/// Re-read the link and write it into the MAC's own control register.
///
/// The engine gates on this: a part told nothing about the wire receives
/// nothing, whatever the PHY has negotiated.
pub fn syncLink(nic: *NicDev) void {
    const now = link(nic);
    applyLinkState(now);
    device.link_state = now;
    dev_mod.deliverLink(nic, now);
}

fn applyLinkState(state: dev_mod.Link) void {
    const settled: attansic.PhySpeed = switch (state.mbps) {
        1000 => .m1000,
        100 => .m100,
        else => .m10,
    };
    device.regs.common.write(.mac_ctrl, @bitCast(MacCtrl{
        .base = .{
            .tx_enable = state.up,
            .rx_enable = state.up,
            .full_duplex = state.duplex == .full,
            .tx_flow = true,
            .rx_flow = true,
            .add_crc = true,
            .pad = true,
            .preamble_len = 7,
        },
        .speed = settled.mac(),
        .broadcast_accept = true,
    }));
    _ = device.regs.common.read(.mac_ctrl);
}

// ---------------------------------------------------------------------------
// Traffic
// ---------------------------------------------------------------------------

pub fn irq(nic: *NicDev) bool {
    if (!device.opened) return false;
    return dev_mod.serveIrq(@This(), nic);
}

/// What latched, or zero when nothing did. `serveIrq`'s vocabulary.
///
/// Nothing at all while a reseat is owed: the part's next word belongs to
/// the reseat rather than to this pass, and saying so is what ends the
/// pass instead of working on an adapter that is about to be rebuilt.
pub fn cause() u32 {
    if (device.reseat_pending) return 0;
    const latched: Isr = @bitCast(device.regs.common.read(.isr));
    return if (latched.none()) 0 else @bitCast(latched);
}

pub fn acknowledge(what: u32, hold: bool) void {
    var causes: Isr = @bitCast(what);
    causes.hold = hold;
    device.regs.common.write(.isr, @bitCast(causes));
}

pub fn service(what: u32, nic: *NicDev) void {
    const causes: Isr = @bitCast(what);

    // A cause that says the part is not there any more. Nothing below
    // would mean anything.
    if (causes.phy_link_down) {
        log.fail(name, "the PCIe link dropped under the adapter");
        return;
    }
    if (causes.phy or causes.phy_low_power) {
        // Read to clear, then take the answer from the PHY rather than
        // from the bit: which way the link went is its business.
        _ = readPhy(.interrupt_clear);
        syncLink(nic);
    }
    if (causes.tx_packet or causes.tx_credit or causes.txf_underrun) reapTx();
    if (causes.rx_packet or causes.page_full) receive(nic);

    if (causes.rxf_overflow or causes.page_overflow) {
        // The wire outran this process. Counted rather than said every
        // time: a busy link says it often and the counter is the answer.
        nic.stats.rx_dropped += 1;
    }
    // An engine that stopped moving is not something a pass can fix.
    if (causes.dmar_timeout or causes.dmaw_timeout) askReseat(what);
}

/// Ask for the adapter to be rebuilt between passes.
fn askReseat(why: u32) void {
    if (device.reseat_pending) return;
    device.reseat_cause = why;
    device.reseat_pending = true;
    device.regs.common.write(.imr, 0);
    _ = device.regs.common.read(.imr);
    log.warn(name, "fatal adapter event; the adapter will be reseated");
}

/// Work owed between passes rather than on the line. Asked by the loop,
/// where waiting on the part costs nobody their interrupt.
pub fn upkeep(nic: *NicDev, _: u64) void {
    if (!device.opened) return;
    reseat(nic);
}

/// Rebuild the adapter after a fatal event, outside the interrupt that saw
/// it. Frames still queued are counted as failed rather than silently
/// lost, and the adapter is left stopped if it cannot be brought back: one
/// that will not configure is one nothing further can be asked of.
fn reseat(nic: *NicDev) void {
    if (!device.reseat_pending) return;
    device.reseat_pending = false;

    log.begin(nic.name, .warn);
    out.text("reseating the adapter after cause 0x");
    out.hex(device.reseat_cause, 8);
    log.end();

    nic.stats.tx_failed += device.fill.used(device.reaped.at);

    if (!configure()) {
        device.started = false;
        dev_mod.deliverLink(nic, .{});
        applyLinkState(.{});
        pci.disableInterruptAndMaster(device.location);
        log.fail(name, "adapter recovery failed");
        return;
    }

    device.started = true;
    syncLink(nic);
    device.regs.common.write(.imr, @bitCast(UNMASKED));
    _ = device.regs.common.read(.imr);
    log.say(name, .dim, "the adapter is back");
}

/// The adapter with no interrupt behind it, for a line that never fires.
pub fn poll(nic: *NicDev) bool {
    if (!device.opened or !device.started) return false;
    reseat(nic);
    reapTx();
    receive(nic);
    return true;
}

/// Give back every descriptor the part has finished with.
fn reapTx() void {
    const mark = device.regs.half.read(.tpd_cons_idx);
    // A mark outside the ring is a part answering nonsense; giving back
    // descriptors on the strength of it would hand the stack buffers the
    // part is still reading.
    if (mark >= TPD_COUNT) return;

    // Bounded by the ring: the part's mark and this side's cursor are
    // both inside it, so the walk between them is at most one lap.
    var steps: usize = 0;
    while (device.reaped.at != mark and steps < TPD_COUNT) : (steps += 1) {
        device.reaped.next();
    }
    dma.consume();
}

/// How many frames one pass may take off the adapter, so a busy wire
/// cannot hold the service. One number for every driver here.
const RX_BURST = dev_mod.RX_REAP_BUDGET;

/// Everything the part has written into the page being read, and then the
/// other page when this one is finished with.
fn receive(nic: *NicDev) void {
    var taken: usize = 0;
    while (taken < RX_BURST) : (taken += 1) {
        // Every record counts against the budget, whether or not it
        // turned out to be a frame: a page full of broken ones must not
        // hold the service any longer than a page full of good ones.
        const frame = nextFrame(nic) orelse return;
        if (frame.len != 0) dev_mod.deliverRx(nic, .{ .frame = frame, .ok = true });
    }
}

/// The next record in the page being read, or nothing when the part has
/// not written one.
///
/// An empty slice means a record the part marked broken: the page has
/// moved on by it, so the caller asks again rather than stopping.
fn nextFrame(nic: *NicDev) ?[]const u8 {
    const rings = device.arena.body();
    dma.consume();

    const written = @as(*volatile u32, &rings.written[device.reading]).*;
    const page = &rings.page[device.reading];

    const found = device.walk.next(page, written);
    switch (found) {
        .empty => return null,
        .lost => return lost(nic),
        .broken => {
            // The wire broke it and the part said so.
            nic.stats.rx_dropped += 1;
            if (device.walk.finished()) handBack();
            return &.{};
        },
        .frame => |frame| {
            if (device.walk.finished()) handBack();
            return frame;
        },
    }
}

/// Hand the page being read back to the part and turn to the other one.
fn handBack() void {
    const rings = device.arena.body();
    @as(*volatile u32, &rings.written[device.reading]).* = 0;
    dma.publish();

    const valid = [PAGES]R8{ .rxf0_page0_valid, .rxf0_page1_valid };
    device.regs.byte.write(valid[device.reading], @bitCast(PageValid{ .valid = true }));

    device.reading = (device.reading + 1) % PAGES;
    // The offset starts again and the count of frames does not: the part
    // numbers them across pages, not within one.
    device.walk.rewind();
}

/// This side has lost its place in the page.
///
/// A page whose record boundaries are unknown holds frames that cannot be
/// found, so there is nothing to do but rebuild the adapter, which puts
/// both its count and this side's back to zero. Done between passes, like
/// every other reseat.
fn lost(nic: *NicDev) ?[]const u8 {
    nic.stats.rx_dropped += 1;
    log.warn(name, "lost the place in the receive page");
    askReseat(@bitCast(Isr{ .rxf_overflow = true }));
    return null;
}

pub fn transmit(nic: *NicDev, frame: []const u8) bool {
    if (!device.opened or !device.started) return false;
    if (frame.len < ETH_HEADER or frame.len > ETH_MAX_FRAME - ETH_FCS) return false;

    // Completions are moderated, so reclaim here as well: coalescing must
    // not make a free ring look full.
    reapTx();
    if (device.fill.room(device.reaped.at) == 0) {
        nic.stats.tx_failed += 1;
        return false;
    }

    const slot = device.fill.at;
    const rings = device.arena.body();
    @memcpy(rings.slot[slot][0..frame.len], frame);

    const at = ringAt(@offsetOf(Rings, "slot") + slot * TX_SLOT) orelse {
        nic.stats.tx_failed += 1;
        return false;
    };
    rings.tpd[slot] = .{
        .buffer = at,
        .length = .{ .bytes = @intCast(frame.len) },
        .about = .{ .end_of_frame = true },
    };

    device.fill.next();

    // The part fetches as soon as the mailbox advances, so every byte and
    // the descriptor go before that handoff. The read back flushes the
    // posted write.
    dma.publish();
    device.regs.word.write(.mb_tpd_prod_idx, @intCast(device.fill.at));
    _ = device.regs.word.read(.mb_tpd_prod_idx);

    dev_mod.deliverTx(nic, frame.len);
    return true;
}

pub const ops: dev_mod.NicOps = .{
    .open = open,
    .start = start,
    .stop = stop,
    .irq = irq,
    .poll = poll,
    .service = upkeep,
    .transmit = transmit,
    .link = link,
    .sync_link = syncLink,
};
