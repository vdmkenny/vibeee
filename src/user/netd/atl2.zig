//! Attansic L2 10/100 ethernet (1969:2048): the wired port the Eee PC 701
//! carries. A different animal from e1000: no descriptor ring, one byte FIFO
//! the CPU copies frames into, a status ring and fixed 1536-byte receive
//! slots, the whole lot in one DMA run. The sequence in design/08-network.md
//! §4 and the register facts from Linux's atl2 driver and atlx.h (the part
//! that exists to be consulted); this code is written from scratch.
//!
//! In this system's shapes: registers are an enum over a byte window with
//! typed widths, every register's bits are a packed struct, the ring geometry
//! is proven at compile time, and the only waits are bounded spins with
//! `pause` or real sleeps, because this runs in a process where sleeping is
//! possible and spinning is the exception.

const dev_mod = @import("dev.zig");
const lib = @import("lib");
const dma = @import("dma.zig");
const log = @import("ulib").log;
const mii = @import("mii.zig");
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const cursor = @import("cursor.zig");
const std = @import("std");
const sys = @import("sys");

const NicDev = dev_mod.NicDev;
const MMIO_BYTES: u32 = 256 * 1024;
const ETH_MTU = 1500;
const ETH_HEADER = lib.eth.HEADER;
const ETH_FCS = 4;
const ETH_VLAN = 4;
/// The shortest frame worth handing up: the padded minimum, counted the way
/// the status word counts it. Anything below this the hardware has already
/// called a runt, and a frame it called good is not one this driver should
/// second-guess -- a bare acknowledgement is short by design, and dropping
/// those is a conversation that never advances.
const ETH_MIN_WIRE = 60;
const ETH_MAX_FRAME = ETH_MTU + ETH_HEADER + ETH_FCS;
const MAC_FRAME_LIMIT = ETH_MAX_FRAME + ETH_VLAN;

const StationAddressLow = packed struct(u32) {
    octet5: u8,
    octet4: u8,
    octet3: u8,
    octet2: u8,
};

const StationAddressHigh = packed struct(u32) {
    octet1: u8,
    octet0: u8,
    _16: u16 = 0,
};

// ---------------------------------------------------------------------------
// Register window
// ---------------------------------------------------------------------------

/// Register offsets are separated by access width, so a byte register cannot
/// accidentally be reached through a dword operation.
const R32 = enum(u32) {
    pcie_phymisc = 0x1000,
    pcie_dll_tx_ctrl1 = 0x1104,
    ltssm_test_mode = 0x12FC,
    master_ctrl = 0x1400,
    idle_status = 0x1410,
    mdio_ctrl = 0x1414,
    mac_ctrl = 0x1480,
    mac_ipg_ifg = 0x1484,
    mac_sta_addr = 0x1488,
    mac_sta_addr_hi = 0x148C,
    mac_half_duplex = 0x1498,
    rx_hash_table = 0x1490,
    mtu = 0x149C,
    desc_base_hi = 0x1540,
    txd_base_lo = 0x1544,
    txs_base_lo = 0x154C,
    rxd_base_lo = 0x1554,
    tx_cut_thresh = 0x1590,
    isr = 0x1600,
    imr = 0x1604,
};

const R16 = enum(u32) {
    irq_modu_timer = 0x1408,
    phy_enable = 0x140C,
    cmbdisdma_timer = 0x140E,
    txd_mem_size = 0x1548, // dword units
    txs_mem_size = 0x1550, // dword units
    rxd_buf_num = 0x1558,
    pause_on_th = 0x15A8,
    pause_off_th = 0x15AA,
    mb_txd_wr_idx = 0x15F0,
    mb_rxd_rd_idx = 0x15F4,
};

const R8 = enum(u32) {
    dmar = 0x1580,
    dmaw = 0x15A0,
};

/// The aperture, in the three widths its registers are reached at: one
/// mapping, one vocabulary per width, so a byte register cannot be reached
/// through a dword operation. The window does the volatile load or store and
/// proves at compile time that every offset in each set is aligned for the
/// width it is reached at; a misaligned access splits into two bus
/// transactions on this architecture and lands as something else again on
/// others.
const Regs = struct {
    word: lib.mmio.Window(R32, u32) = .{ .base = undefined },
    half: lib.mmio.Window(R16, u16) = .{ .base = undefined },
    byte: lib.mmio.Window(R8, u8) = .{ .base = undefined },

    /// The same base, seen three ways: `as` carries the mapping across and
    /// re-runs the alignment proof against the register set it is given.
    fn over(base: [*]volatile u8) Regs {
        const words: lib.mmio.Window(R32, u32) = .{ .base = base };
        return .{
            .word = words,
            .half = words.as(R16, u16),
            .byte = words.as(R8, u8),
        };
    }

    /// The mapping itself, for handing it back. One base whichever of the
    /// three windows is asked, because there is only ever one mapping.
    fn aperture(self: Regs) [*]volatile u8 {
        return self.word.base;
    }
};

/// One past the highest register this driver touches, in whichever of the
/// three widths it is reached: the smallest aperture that can serve it. A
/// part decoding less than the family's maximum still works; one decoding
/// less than this cannot be driven at all.
const REGISTERS_END = @max(
    @max(pci.registersEnd(R32, @sizeOf(u32)), pci.registersEnd(R16, @sizeOf(u16))),
    pci.registersEnd(R8, @sizeOf(u8)),
);

/// That a register lies inside the aperture this driver maps. Its alignment
/// for the width it is reached at is the window's proof, made when the three
/// windows above are instantiated.
fn validateRegisterSet(comptime Register: type, comptime width: u32) void {
    inline for (std.meta.fields(Register)) |field| {
        if (field.value + width > MMIO_BYTES) @compileError("ATL2 register lies outside the mapped aperture");
    }
}

// ---------------------------------------------------------------------------
// Register shapes: the bits, as fields
// ---------------------------------------------------------------------------

const MasterCtrl = packed struct(u32) {
    soft_reset: bool = false,
    _1: u1 = 0,
    irq_moder: bool = false, // ITIMER_EN
    manual_int: bool = false,
    _4: u28 = 0,
};

const DmaControl = packed struct(u8) {
    enabled: bool = false,
    _1: u7 = 0,
};

const PhyEnable = packed struct(u16) {
    enabled: bool = false,
    _1: u15 = 0,
};

/// Complete vendor-defined register images. Their individual fields are not
/// documented, so enums preserve the hardware type without inventing names
/// for unknown bits.
const LtssmTestMode = enum(u32) {
    vendor_default = 0x6500,
};

/// PCIE_PHYMISC_FORCE_RCV_DET, in the PHY's misc register at 0x1000.
const PCIE_PHYMISC_FORCE_RCV_DET: u32 = 0x4;

const PcieDllTxCtrl1 = enum(u32) {
    vendor_default = 0x568,
};

const MdioCtrl = packed struct(u32) {
    data: u16 = 0,
    phy_reg: u5 = 0,
    /// MDIO_RW: one reads a PHY register, zero writes.
    read: bool = false,
    /// MDIO_SUP_PREAMBLE speeds the transfer; always set, per the manual.
    preamble: bool = true,
    start: bool = false,
    clk_sel: u3 = 0, // 0 = 25/4 MHz
    busy: bool = false,
    _28: u4 = 0,
};

/// What the MAC counts the wire's speed as, at bits 20:21 of MAC_CTRL. Not
/// the PHY's own encoding: ten and a hundred share one value here, and the
/// gigabit value belongs to parts this driver does not drive.
const MacSpeed = enum(u2) {
    m10_100 = 1,
    m1000 = 2,
    _,
};

const MacCtrl = packed struct(u32) {
    tx_enable: bool = false,
    rx_enable: bool = false,
    tx_flow: bool = false,
    rx_flow: bool = false,
    loopback: bool = false,
    full_duplex: bool = false,
    add_crc: bool = false,
    pad: bool = false,
    len_check: bool = false,
    huge: bool = false,
    preamble_len: u4 = 0,
    _14: u1 = 0,
    promiscuous: bool = false,
    _16: u4 = 0,
    /// The speed, always written. Two of the four encodings are defined
    /// and zero is not one of them: left at zero the field is whatever
    /// the silicon makes of an undefined value, and a receiver that
    /// never synchronises is what that has looked like. Linux writes the
    /// 10/100 value for this part on every path, so this driver does.
    speed: MacSpeed = .m10_100,
    _22: u3 = 0,
    multicast_all: bool = false,
    broadcast_accept: bool = false,
    /// MACLP_CLK_PHY: clock the MAC from the PHY.
    phy_clock: bool = false,
    _28: u4 = 0,
};

const IpgIfg = packed struct(u32) {
    ipgt: u7 = 0,
    _7: u1 = 0,
    min_ifg: u8 = 0,
    ipgr1: u7 = 0,
    _23: u1 = 0,
    ipgr2: u7 = 0,
    _31: u1 = 0,
};

const HalfDuplex = packed struct(u32) {
    lcol: u10 = 0,
    _10: u2 = 0,
    retry: u4 = 0,
    exc_defer: bool = false,
    _17: u2 = 0,
    abebe: bool = false,
    abebt: u4 = 0,
    jam_ipg: u4 = 0,
    _28: u4 = 0,
};

const Isr = packed struct(u32) {
    timer: bool = false,
    manual: bool = false,
    rxf_ov: bool = false,
    txf_ur: bool = false,
    txs_ov: bool = false,
    rxs_ov: bool = false,
    link_change: bool = false,
    host_txd_ur: bool = false,
    host_rxd_ov: bool = false,
    dmar_timeout: bool = false,
    dmaw_timeout: bool = false,
    phy: bool = false,
    _12: u4 = 0,
    tx_status: bool = false, // TS_UPDATE
    rx_status: bool = false, // RS_UPDATE
    tx_early: bool = false,
    _19: u5 = 0,
    unsupported_request: bool = false,
    fatal_error: bool = false,
    nonfatal_error: bool = false,
    correctable_error: bool = false,
    phy_link_down: bool = false,
    _29: u2 = 0,
    /// ISR_DIS_INT: hold interrupts while servicing on a shared line.
    hold: bool = false,

    fn none(self: Isr) bool {
        var causes = self;
        causes.hold = false;
        return @as(u32, @bitCast(causes)) == 0;
    }
};

const IsrClear = packed struct(u32) {
    causes: u30 = std.math.maxInt(u30),
    _30: u1 = 0,
    hold: bool = false,
};

/// The PHY status word (MII register 17, "PSSR").
const Pssr = packed struct(u16) {
    _0: u11 = 0,
    resolved: bool = false,
    _12: u1 = 0,
    full_duplex: bool = false,
    speed: Speed = .m10,
};

const Speed = enum(u2) {
    m10 = 0,
    m100 = 1,
    m1000 = 2,
    _,

    fn mbps(self: Speed) u16 {
        return switch (self) {
            .m10 => 10,
            .m100 => 100,
            .m1000 => 1000,
            _ => 0,
        };
    }
};

/// The four-byte header before every frame in the TX fifo.
const TxHeader = packed struct(u32) {
    pkt_len: u11 = 0,
    _11: u4 = 0,
    insert_vlan: bool = false,
    vlan: u16 = 0,
};

/// One transmit status entry, as the hardware writes it back.
const TxStatus = packed struct(u32) {
    pkt_len: u11 = 0,
    _11: u5 = 0,
    ok: bool = false,
    _17: u8 = 0,
    /// Bit 25, not 27. Named and left alone: this MAC raises it beside
    /// ordinary completions, so reading it as a failure would count every
    /// frame sent as one that did not go.
    underrun: bool = false,
    _26: u5 = 0,
    update: bool = false,
};

/// One receive slot's status word: the first four bytes of a 1536-byte slot.
const RxStatus = packed struct(u32) {
    pkt_len: u11 = 0,
    _11: u5 = 0,
    ok: bool = false,
    _17: u4 = 0,
    crc_error: bool = false,
    code_error: bool = false,
    runt: bool = false,
    fragment: bool = false,
    truncated: bool = false,
    align_error: bool = false,
    has_vlan: bool = false,
    _28: u3 = 0,
    update: bool = false,
};

comptime {
    validateRegisterSet(R8, @sizeOf(u8));
    validateRegisterSet(R16, @sizeOf(u16));
    validateRegisterSet(R32, @sizeOf(u32));
    if (@sizeOf(MdioCtrl) != 4 or @sizeOf(MacCtrl) != 4 or @sizeOf(Isr) != 4) {
        @compileError("a control register shapes one dword");
    }
    if (@bitOffsetOf(Isr, "unsupported_request") != 24 or
        @bitOffsetOf(Isr, "fatal_error") != 25 or
        @bitOffsetOf(Isr, "nonfatal_error") != 26 or
        @bitOffsetOf(Isr, "correctable_error") != 27 or
        @bitOffsetOf(Isr, "phy_link_down") != 28 or
        @bitOffsetOf(Isr, "hold") != 31)
    {
        @compileError("ATL2 interrupt status fields are in the wrong bit position");
    }
    if (@sizeOf(TxHeader) != 4 or @sizeOf(TxStatus) != 4 or @sizeOf(RxStatus) != 4) {
        @compileError("a packet status or header shapes one dword");
    }
    if (@sizeOf(MasterCtrl) != 4 or @sizeOf(IpgIfg) != 4 or @sizeOf(HalfDuplex) != 4) {
        @compileError("a config register shapes one dword");
    }
    if (@sizeOf(Pssr) != 2 or @sizeOf(PhyEnable) != 2) {
        @compileError("a PHY register shape is one word");
    }
    if (@sizeOf(DmaControl) != 1) @compileError("a DMA enable register is one byte");
    if (@sizeOf(LtssmTestMode) != 4 or @sizeOf(PcieDllTxCtrl1) != 4) {
        @compileError("a PCIe register image is one dword");
    }
    if (@sizeOf(StationAddressLow) != 4 or @sizeOf(StationAddressHigh) != 4) {
        @compileError("a station-address register is one dword");
    }
}

// ---------------------------------------------------------------------------
// MII registers
// ---------------------------------------------------------------------------

const PhyDebug = packed struct(u16) {
    _0: u12 = 0,
    power_save: bool = false,
    _13: u3 = 0,
};

const PhyInterruptEnable = packed struct(u16) {
    _0: u10 = 0,
    link_down: bool = false,
    link_up: bool = false,
    _12: u4 = 0,
};

/// Link-up and link-down, the two events worth a PHY interrupt.
const PHY_LINK_EVENTS = PhyInterruptEnable{
    .link_down = true,
    .link_up = true,
};

const Phy = enum(u5) {
    bmcr = 0,
    bmsr = 1,
    advertise = 4,
    pssr = 17,
    /// PHY interrupt enable: link-change, the value 0x0C00.
    interrupt = 18,
    /// PHY interrupt status, read to clear.
    interrupt_clear = 19,
    dbg_addr = 29,
    dbg_data = 30,
};

const BMCR = packed struct(u16) {
    _0: u8 = 0,
    _8: u1 = 0,
    restart_autoneg: bool = false, // bit 9
    _10: u2 = 0,
    autoneg_enable: bool = false, // bit 12
    _13: u2 = 0,
    reset: bool = false, // bit 15
};

const ADVERTISE_ALL = packed struct(u16) {
    selector: bool = true,
    _1: u4 = 0,
    ten_half: bool = false, // bit 5
    ten_full: bool = false, // bit 6
    hundred_half: bool = false, // bit 7
    hundred_full: bool = false, // bit 8
    _9: u1 = 0,
    pause: bool = true,
    asymmetric_pause: bool = true,
    _12: u4 = 0,
}{
    .ten_half = true,
    .ten_full = true,
    .hundred_half = true,
    .hundred_full = true,
};

// ---------------------------------------------------------------------------
// The rings, one DMA segment
// ---------------------------------------------------------------------------

const TXD_BYTES = 8 * 1024;
const TXS_COUNT = 160;
const RX_COUNT = 64;

/// Flow-control thresholds, the vendor's own arithmetic over the ring.
const PAUSE_ON_SLOTS: u16 = (RX_COUNT / 8) * 7;
const PAUSE_OFF_SLOTS: u16 = @max(2, RX_COUNT / 12);
const RX_SLOT = 1536;
const RX_STATUS_BYTES = @sizeOf(RxStatus) + 2 * @sizeOf(u16);

/// One receive slot: status, VLAN tag, then the frame bytes.
const RxSlot = extern struct {
    status: RxStatus = .{},
    vtag: u16 = 0,
    _reserved: u16 = 0,
    packet: [RX_SLOT - RX_STATUS_BYTES]u8 = @splat(0),
};

comptime {
    if (@sizeOf(RxSlot) != 1536) @compileError("a receive slot is 1536 bytes");
    if (@offsetOf(RxSlot, "packet") != RX_STATUS_BYTES) @compileError("receive status layout drifted");
    if (@sizeOf(TxStatus) != 4) @compileError("a transmit status is one dword");
    if (TXD_BYTES % @sizeOf(u32) != 0) @compileError("the transmit FIFO must be dword sized");
    if (TXS_COUNT > std.math.maxInt(u16) or RX_COUNT > std.math.maxInt(u16)) {
        @compileError("ring counts must fit their mailbox registers");
    }
    if (MAC_FRAME_LIMIT > std.math.maxInt(u11)) @compileError("a frame length must fit hardware");
}

/// The three regions, one physically contiguous run, in the order the
/// hardware reads them. The receive slots demand 128-byte alignment, which
/// is what the arena is asked for.
const Rings = struct {
    txd: [TXD_BYTES]u8 = @splat(0),
    txs: [TXS_COUNT]TxStatus = @splat(.{}),
    rxd: [RX_COUNT]RxSlot align(128) = @splat(.{}),

    comptime {
        if (@sizeOf(Rings) != TXD_BYTES + TXS_COUNT * 4 + RX_COUNT * RX_SLOT) {
            @compileError("the descriptor arena must pack without padding surprises");
        }
    }
};

/// TFrames live in the FIFO with their four-byte header; the tread pointer
/// (what the hardware has consumed) is derived from the statuses.
const Device = struct {
    regs: Regs = .{},
    /// The rings and the run they live in, as one value: it is mapped,
    /// zeroed and given back by the arena, and there is no state in which
    /// one of those has been done without the other.
    arena: dma.Arena(Rings) = .{},
    mac: [6]u8 = @splat(0),
    /// Where it sits on the bus, kept for the PCIe capability work.
    location: pci.Location = @bitCast(@as(u16, 0)),

    /// A fatal event whose reset is owed: named on the line, done between
    /// passes.
    reseat_pending: bool = false,
    reseat_cause: u32 = 0,
    /// Where the host writes next in the TXD fifo and where the host is
    /// still owed fifo bytes, where the next status will be filled and
    /// where the next completion is reaped, and where the next receive slot
    /// is read. Cursors rather than numbers: the wrap is the arithmetic
    /// this driver used to write out at each of them.
    txd_write: cursor.Cursor(TXD_BYTES) = .{},
    txd_read: cursor.Cursor(TXD_BYTES) = .{},
    txs_fill: cursor.Cursor(TXS_COUNT) = .{},
    txs_reap: cursor.Cursor(TXS_COUNT) = .{},
    txs_used: usize = 0,
    tx_lengths: [TXS_COUNT]u16 = @splat(0),
    rxd_read: cursor.Cursor(RX_COUNT) = .{},
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
    const aperture = pci.openApertureNeeding(loc, 0, MMIO_BYTES, REGISTERS_END, "atl2", "adapter") orelse
        return false;
    // Every way out of here but the last gives the registers back. A
    // driver that fails to open is asked again each time the service
    // restarts, and an aperture left mapped each time is a window of this
    // process's address space that never comes back.
    var keep_pci_enabled = false;
    defer if (!keep_pci_enabled) {
        sys.shmUnmap(@volatileCast(device.regs.aperture()));
        pci.disableInterruptAndMaster(loc);
    };
    device.regs = Regs.over(@ptrCast(aperture));

    // Before anything is asked of the line: a device left delivering
    // message-signalled interrupts asserts no pin, and this system routes
    // pins. Firmware hands a card over with messages enabled often enough
    // that an adapter would otherwise sit silent, receiving nothing, for
    // exactly as long as it took to notice.
    if (pci.useIntx(loc)) {
        log.note("atl2", "the adapter was set to message interrupts; turned back to its pin");
    }

    device.regs.word.write(.imr, 0);
    _ = device.regs.word.read(.imr);
    log.say("atl2", .dim, "registers mapped");

    device.mac = readMac() orelse {
        log.fail("atl2", "cannot read a valid MAC address");
        return false;
    };

    // One run of device memory for the whole of the rings, taken and
    // mapped as one thing: a mapping is a reference of its own, so a
    // handle closed under a live mapping frees nothing and a driver
    // stopped and opened a few times runs the machine out of contiguous
    // memory without ever having allocated twice. The arena zeroes it,
    // because a descriptor left holding last boot's address is a device
    // that fetches from wherever it points.
    device.arena = dma.Arena(Rings).acquire() catch |why| {
        switch (why) {
            // No contiguous run of that size left below 4 GiB. Retold in
            // the shape `log.refused` takes rather than handed over as it
            // arrived: the arena's refusals are its own, and this is the
            // one of them the kernel's would have been.
            error.NoMemory => log.refused("atl2", "cannot allocate DMA rings", error.NoMemory),
            // Checked rather than adjusted: an adjusted physical base
            // without the same shift on the mapping would have the CPU and
            // the card each writing a different arena.
            error.Misaligned => log.fail("atl2", "DMA memory is not aligned for the adapter"),
            error.Unmappable => log.fail("atl2", "cannot map DMA rings"),
        }
        return false;
    };

    log.say("atl2", .dim, "rings placed");
    if (!configure()) {
        // Configuration may already have enabled the DMA engines. Stop PCI
        // mastering before the backing allocation can be returned.
        pci.disableInterruptAndMaster(loc);
        keep_pci_enabled = true;
        device.arena.release();
        sys.shmUnmap(@volatileCast(device.regs.aperture()));
        device.regs = .{};
        return false;
    }
    log.say("atl2", .dim, "engine configured");
    dev.mac = device.mac;
    device.opened = true;
    keep_pci_enabled = true;
    dev_mod.deliverLink(dev, link(dev));

    return true;
}

/// Reset and configure, the sequence design/08 §4.2 fixes. Bounded waits
/// only: a wedged controller costs a refused driver, never a machine.
fn configure() bool {
    device.regs.word.write(.imr, 0);
    _ = device.regs.word.read(.imr);
    if (!resetController()) return false;
    initPcie();
    resetRings();
    if (!phyInit()) {
        log.fail("atl2", "PHY did not answer");
        return false;
    }

    // Clear interrupt status, whole word.
    device.regs.word.write(.isr, ACK_EVERYTHING);
    writeMac();

    // Descriptor addresses: this machine is 32-bit, the high word is zero.
    // Asked of the arena rather than added to its base by hand: the run
    // that leaves the machine's addresses is the one a driver hands a
    // device a page it does not own by.
    device.regs.word.write(.desc_base_hi, 0);
    device.regs.word.write(.txd_base_lo, ringAt(@offsetOf(Rings, "txd")) orelse return false);
    device.regs.half.write(.txd_mem_size, TXD_BYTES / @sizeOf(u32));
    device.regs.word.write(.txs_base_lo, ringAt(@offsetOf(Rings, "txs")) orelse return false);
    device.regs.half.write(.txs_mem_size, TXS_COUNT);
    device.regs.word.write(.rxd_base_lo, ringAt(@offsetOf(Rings, "rxd")) orelse return false);
    device.regs.half.write(.rxd_buf_num, RX_COUNT);

    // Frame scheduling.
    device.regs.word.write(.mac_ipg_ifg, @bitCast(IpgIfg{
        .ipgt = 0x60,
        .min_ifg = 0x50,
        .ipgr1 = 0x40,
        .ipgr2 = 0x60,
    }));
    device.regs.word.write(.mac_half_duplex, @bitCast(HalfDuplex{
        .lcol = 0x37,
        .retry = 0xF,
        .exc_defer = true,
        .abebt = 0xA,
        .jam_ipg = 7,
    }));

    // Interrupt moderation: 100 * 2 us between deliveries, cleared timer
    // ~100 ms, plus the flag that arms the moderator at all.
    device.regs.half.write(.irq_modu_timer, 100);
    // A flat write, not a read-modify-write: after reset the register is the
    // moderation bit's to define, and this is the value the vendor's driver
    // has always written.
    device.regs.word.write(.master_ctrl, @bitCast(MasterCtrl{ .irq_moder = true }));
    device.regs.half.write(.cmbdisdma_timer, 50000);

    // Frame sizes and cut-through.
    device.regs.word.write(.mtu, MAC_FRAME_LIMIT);
    device.regs.word.write(.tx_cut_thresh, 0x177);

    // The 802.3x pause generator's thresholds, in occupied receive slots:
    // ask the far end to pause at seven eighths full, release it at a
    // twelfth. The vendor's driver computes exactly these from the ring
    // size. Zeroes here are not "off": with flow control enabled they read
    // as pause-always and release-never, a corner the silicon never ships
    // in, and the generator then fights the transmit path for the wire on
    // every received frame.
    device.regs.half.write(.pause_on_th, PAUSE_ON_SLOTS);
    device.regs.half.write(.pause_off_th, PAUSE_OFF_SLOTS);

    // Mailboxes start empty, and the engine turns.
    device.regs.half.write(.mb_txd_wr_idx, 0);
    device.regs.half.write(.mb_rxd_rd_idx, 0);
    dma.publish();
    device.regs.byte.write(.dmar, @bitCast(DmaControl{ .enabled = true }));
    device.regs.byte.write(.dmaw, @bitCast(DmaControl{ .enabled = true }));

    const status = @as(Isr, @bitCast(device.regs.word.read(.isr)));

    // Every cause acknowledged, then the line released; the hold bit is the
    // one bit that is not a cause.
    device.regs.word.write(.isr, ACK_EVERYTHING);
    device.regs.word.write(.isr, 0);
    if (status.phy_link_down) {
        log.fail("atl2", "PCIe link dropped during configuration");
        return false;
    }
    return true;
}

/// Restore the PCIe block's vendor defaults after a MAC reset, and take the
/// link out of every conversation it cannot be trusted to hold. This MAC
/// raises phantom unsupported-request and non-fatal errors as soon as its
/// DMA engines start, so every road an error report could travel is closed:
/// the capability's four reporting enables, and the legacy SERR# gate in
/// the command register, which the specification says transmits the fatal
/// and non-fatal classes on its own whatever the capability enables say.
/// On this machine the root's error handling belongs to the firmware, and
/// a report per phantom under a sustained transfer is a machine that
/// vanishes into system management mode mid-download. The active-state
/// power management states go too: this family's L0s and L1 are known to
/// hang the link, a hung link turns the next register read into a load
/// that never retires, and the cycle in and out of low power is exactly
/// what a streaming transfer produces.
fn initPcie() void {
    device.regs.word.write(.ltssm_test_mode, @intFromEnum(LtssmTestMode.vendor_default));
    device.regs.word.write(.pcie_dll_tx_ctrl1, @intFromEnum(PcieDllTxCtrl1.vendor_default));

    // Force the PCIe PHY's receiver-detection result. Both reference
    // drivers set this entering suspend so a sleeping link can still
    // handshake; holding it for the whole run goes beyond them, chosen
    // deliberately for a link that has been observed to fall off the bus
    // mid-burst on this machine. A receiver this PHY fails to detect is a
    // link it will drop.
    const phymisc = device.regs.word.read(.pcie_phymisc);
    device.regs.word.write(.pcie_phymisc, phymisc | PCIE_PHYMISC_FORCE_RCV_DET);

    var command = pci.readCommand(device.location);
    command.serr_enable = false;
    command.parity_response = false;
    pci.writeCommand(device.location, command);

    quietPcieCapability();
}

/// Clear the four error-reporting enables and the ASPM states in the
/// device's PCI Express capability. The capability list is walked, not
/// assumed: the pointer is whatever the silicon says it is.
fn quietPcieCapability() void {
    const at = pci.capabilityAt(device.location, .pcie) orelse return;

    var control: pci.PcieDeviceControl =
        @bitCast(pci.read(device.location, at + pci.PcieDeviceControl.OFFSET));
    control.correctable_report = false;
    control.non_fatal_report = false;
    control.fatal_report = false;
    control.unsupported_report = false;
    pci.write(device.location, at + pci.PcieDeviceControl.OFFSET, @bitCast(control));

    var wire: pci.PcieLinkControl =
        @bitCast(pci.read(device.location, at + pci.PcieLinkControl.OFFSET));
    wire.aspm = 0;
    pci.write(device.location, at + pci.PcieLinkControl.OFFSET, @bitCast(wire));
}

fn resetController() bool {
    device.regs.word.write(.master_ctrl, @bitCast(MasterCtrl{ .soft_reset = true }));
    _ = device.regs.word.read(.master_ctrl);
    sys.sleepMicros(1_000);

    for (0..10) |_| {
        if (device.regs.word.read(.idle_status) == 0) return true;
        sys.sleepMicros(1_000);
    }
    log.fail("atl2", "engines did not become idle after reset");
    return false;
}

fn resetRings() void {
    device.txd_write = .{};
    device.txd_read = .{};
    device.txs_fill = .{};
    device.txs_reap = .{};
    device.txs_used = 0;
    device.tx_lengths = @splat(0);
    device.rxd_read = .{};
    for (&device.arena.body().txs) |*status| status.* = .{};
    for (&device.arena.body().rxd) |*slot| slot.status = .{};
}

/// Where one region of the rings sits, as the number a device is
/// programmed with. Asked of the arena rather than added to its base here,
/// so the offset is the arena's to bound against the run it handed out.
fn ringAt(offset: usize) ?u32 {
    const place = device.arena.physOf(offset) orelse return null;
    return place.addr();
}

/// The vendor's all-causes acknowledgement. Bit 31 is the interrupt hold and
/// bit 30 is reserved, so neither is written here.
const ACK_EVERYTHING: u32 = @bitCast(IsrClear{});

/// What may interrupt: the two status updates, the PHY, the PCIe link loss
/// and the fatal DMA pair. Link-change stays off, as the vendor's own driver
/// keeps it: the PHY interrupt already reports it, latched until read.
const UNMASKED = Isr{
    .tx_status = true,
    .rx_status = true,
    .phy = true,
    .phy_link_down = true,
    .dmar_timeout = true,
    .dmaw_timeout = true,
};

/// The PHY, through the MII window: wake it, clear the vendor power-save
/// bit, arm link interrupts, restart autonegotiation.
fn phyInit() bool {
    device.regs.half.write(.phy_enable, @bitCast(PhyEnable{ .enabled = true }));
    _ = device.regs.half.read(.phy_enable);
    sys.sleepMicros(1_000);

    if (!writePhy(.dbg_addr, 0)) return false;
    var debug: PhyDebug = @bitCast(readPhy(.dbg_data) orelse return false);
    if (debug.power_save) {
        debug.power_save = false;
        if (!writePhy(.dbg_data, @bitCast(debug))) return false;
    }
    sys.sleepMicros(1_000);

    if (!writePhy(.interrupt, @bitCast(PHY_LINK_EVENTS))) return false;
    if (!writePhy(.advertise, @bitCast(ADVERTISE_ALL))) return false;
    return writePhy(.bmcr, @bitCast(BMCR{
        .reset = true,
        .autoneg_enable = true,
        .restart_autoneg = true,
    }));
}

fn readMac() ?[6]u8 {
    // The vendors keep the permanent address two ways this driver is not
    // being asked to parse yet (NVM/EEPROM words). Reading the working
    // registers back is where the BIOS usually leaves the right one, and on
    // the far path the fields come back all-zero and rightly look like no
    // story: nothing is invented.
    const low: StationAddressLow = @bitCast(device.regs.word.read(.mac_sta_addr));
    const high: StationAddressHigh = @bitCast(device.regs.word.read(.mac_sta_addr_hi));
    // The high word holds the first two octets with the first in its upper
    // byte: the vendor's own assignment begins 00:1f:c6, and swapped halves
    // put the multicast bit in the station address.
    const mac = [6]u8{
        high.octet0,
        high.octet1,
        low.octet2,
        low.octet3,
        low.octet4,
        low.octet5,
    };
    return if (dev_mod.validMac(mac)) mac else null;
}

fn writeMac() void {
    const mac = device.mac;
    device.regs.word.write(.mac_sta_addr, @bitCast(StationAddressLow{
        .octet2 = mac[2],
        .octet3 = mac[3],
        .octet4 = mac[4],
        .octet5 = mac[5],
    }));
    device.regs.word.write(.mac_sta_addr_hi, @bitCast(StationAddressHigh{
        .octet0 = mac[0],
        .octet1 = mac[1],
    }));
}

pub fn start(nic: *NicDev) bool {
    if (!device.opened or device.started) return false;
    // The PHY has been latching events since the reset armed them; whatever
    // it holds is folded into the link read below. Cleared before the line
    // is ever unmasked, or the stale latch is the first interrupt.
    if (readPhy(.interrupt_clear) == null) {
        log.fail("atl2", "cannot clear the PHY interrupt latch");
        return false;
    }

    dev_mod.deliverLink(nic, link(nic));
    applyLinkState(nic.state);
    device.regs.word.write(.isr, ACK_EVERYTHING);
    device.regs.word.write(.isr, 0);
    device.started = true;
    // The step about to be taken, then the step taken: the pin opens here,
    // and on this machine the first assertion of a line is a moment worth
    // bracketing on the screen.
    log.say("atl2", .dim, "link state applied");
    pci.enableInterrupt(nic.location);
    device.regs.word.write(.imr, @bitCast(UNMASKED));
    _ = device.regs.word.read(.imr);
    log.say("atl2", .dim, "interrupts open");
    return true;
}

pub fn stop(nic: *NicDev) void {
    if (!device.opened) return;
    device.started = false;
    device.regs.word.write(.imr, 0);
    _ = device.regs.word.read(.imr);
    var ctrl = @as(MacCtrl, @bitCast(device.regs.word.read(.mac_ctrl)));
    ctrl.rx_enable = false;
    ctrl.tx_enable = false;
    device.regs.word.write(.mac_ctrl, @bitCast(ctrl));
    _ = device.regs.word.read(.mac_ctrl);
    _ = resetController();
    // The three base registers are the only places that still name the
    // arena. The reset above has the engine's own idea of them, but said
    // rather than assumed: the next thing that happens is that the memory
    // they point at stops belonging to this driver.
    device.regs.word.write(.txd_base_lo, 0);
    device.regs.word.write(.txs_base_lo, 0);
    device.regs.word.write(.rxd_base_lo, 0);
    device.regs.byte.write(.dmar, @bitCast(DmaControl{}));
    device.regs.byte.write(.dmaw, @bitCast(DmaControl{}));
    _ = device.regs.word.read(.isr);
    pci.disableInterruptAndMaster(nic.location);
    resetRings();
    device.arena.release();
    // And the aperture, for the same reason the arena goes: a mapping
    // given back by nothing is a window of the address space lost for
    // the rest of the run.
    sys.shmUnmap(@volatileCast(device.regs.aperture()));
    device.regs = .{};
    device.opened = false;
    dev_mod.deliverLink(nic, .{});
}

// ---------------------------------------------------------------------------
// MII, hosts of PHY transactions
// ---------------------------------------------------------------------------

/// An MDIO frame takes tens of microseconds on the real bus, and each look
/// at the busy bit is an uncached read costing about one. The budget covers
/// the slowest frame with a wide margin and still bounds a wedged bus to
/// milliseconds; the emulator's instant answers taught a budget of ten,
/// which real silicon spends before the frame has clocked its preamble.
const MDIO_SPINS = 4000;

fn writePhy(reg: Phy, value: u16) bool {
    if (!mdioBegin(reg, false, value)) return false;
    return spinUntil(MDIO_SPINS, mdioIdle);
}

fn readPhy(reg: Phy) ?u16 {
    if (!mdioBegin(reg, true, 0)) return null;
    if (!spinUntil(MDIO_SPINS, mdioIdle)) return null;
    return @as(MdioCtrl, @bitCast(device.regs.word.read(.mdio_ctrl))).data;
}

/// Start one MDIO transaction after the previous one has gone idle.
fn mdioBegin(reg: Phy, read: bool, value: u16) bool {
    if (!spinUntil(MDIO_SPINS, mdioIdle)) return false;

    device.regs.word.write(.mdio_ctrl, @bitCast(MdioCtrl{
        .data = value,
        .phy_reg = @intFromEnum(reg),
        .read = read,
        .start = true,
    }));
    return true;
}

fn mdioIdle(regs: Regs) bool {
    const state = @as(MdioCtrl, @bitCast(regs.word.read(.mdio_ctrl)));
    return !state.start and !state.busy;
}

// ---------------------------------------------------------------------------
// Traffic
// ---------------------------------------------------------------------------

/// The overflow story is told once; after that the counter speaks.
var overflow_said = false;

/// One interrupt delivery.
///
/// The shape of the pass is `dev.serveIrq`'s: read a cause, hold the line
/// over the work, release it, and look again. The looking again is the part
/// that matters here. A cause that latches while one is being serviced
/// makes no new interrupt edge, and this service runs whole milliseconds
/// where the vendor's runs microseconds: a pass that ended on a fixed
/// count without looking would release the line with a latched cause nobody
/// will ever be told about again, and the receive side falls silent until
/// some other bit happens to edge. Frames delivered seconds late, in one
/// clump, are exactly what that silence looks like.
pub fn irq(nic: *NicDev) bool {
    if (!device.opened or !device.started) return false;
    return dev_mod.serveIrq(@This(), nic);
}

/// What the adapter has latched, as one word.
///
/// The hold bit is not a cause but this driver's own line, so it is left
/// out: zero means there is nothing to service, and that is what ends the
/// pass.
pub fn cause() u32 {
    // A reseat is owed: the adapter is masked and its next word belongs to
    // the reseat, not to this pass. Saying "nothing latched" is what lets
    // the pass end here rather than naming one fatal event once per round
    // until the budget runs out.
    if (device.reseat_pending) return 0;

    const latched: Isr = @bitCast(device.regs.word.read(.isr));
    if (latched.none()) return 0; // nothing latched, or a shared line
    var causes = latched;
    causes.hold = false;
    return @bitCast(causes);
}

/// Acknowledge what latched, and either hold the line over the work or
/// release it afterwards.
///
/// Holding writes the causes back with ISR_DIS_INT, per the manual, so a
/// shared level line cannot re-assert mid-pass. Releasing writes zero
/// rather than the causes again: whatever latched while the work ran is
/// work owed, and clearing it on the way out is how it goes unseen -- the
/// pass reads the cause again instead.
pub fn acknowledge(causes: u32, held: bool) void {
    // The flag reaches here in two shapes -- a boolean while the pass
    // holds the line, a zero once it lets it go -- and both mean the one
    // thing asked of it.
    const holding: bool = if (@TypeOf(held) == bool) held else held != 0;
    if (!holding) {
        device.regs.word.write(.isr, 0);
        return;
    }
    var acknowledged: Isr = @bitCast(causes);
    // The PHY holds its interrupt line until its own status register is
    // read, so that read comes before the write that clears the bit:
    // acknowledged the other way round, the line is still asserted when
    // the clear lands and simply latches the cause again.
    if (acknowledged.phy) _ = readPhy(.interrupt_clear);
    acknowledged.hold = true;
    device.regs.word.write(.isr, @bitCast(acknowledged));
}

/// One pass of the adapter's work, on the line.
///
/// Nothing here may wait on the part: the line is held while it runs, and
/// on a shared line so is every neighbour's.
pub fn service(causes: u32, nic: *NicDev) void {
    const latched: Isr = @bitCast(causes);

    // The everyday causes are traffic, not news, and stay quiet: the
    // status updates, the PHY answering a poll, and the companions this
    // MAC raises beside them, a TXD underrun with every completion and
    // early-transmit chatter. Overflow means a burst outran the ring
    // while the service was busy; it is counted where `net` shows it,
    // said once, and left to the engine, which drops and recovers on
    // its own. Narrating each one would slow the service further and
    // deepen the very overflow being narrated.
    var unexpected = latched;
    unexpected.rx_status = false;
    unexpected.tx_status = false;
    unexpected.phy = false;
    unexpected.hold = false;
    unexpected.host_txd_ur = false;
    unexpected.tx_early = false;
    unexpected.rxf_ov = false;
    unexpected.rxs_ov = false;
    unexpected.host_rxd_ov = false;
    unexpected.correctable_error = false;

    if (latched.rxf_ov or latched.rxs_ov or latched.host_rxd_ov) {
        nic.stats.rx_dropped += 1;
        if (!overflow_said) {
            overflow_said = true;
            log.say("atl2", .dim, "rx overflowed under a burst; drops counted from here");
        }
    }

    if (@as(u32, @bitCast(unexpected)) != 0) {
        log.begin("atl2", .dim);
        out.text("cause 0x");
        out.hex(causes, 8);
        log.end();
    }

    if (latched.phy_link_down or latched.dmar_timeout or latched.dmaw_timeout or
        latched.fatal_error)
    {
        // The manual's answer to a wedged DMA engine is a full reset, and
        // the reset is deferred: it soft-resets the MAC and rewrites the
        // PCIe and PHY registers, which is tens of milliseconds of
        // waiting on the part. Done here it holds the line for that
        // whole time, and worse, it is done with the engine mid-transfer
        // -- the family's L0s/L1 handling is known to hang the link, and
        // a hung link turns the next register read into a load that
        // never retires. That is a frozen machine with no panic behind
        // it, because an NMI cannot unstick a bus.
        //
        // So: name the cause, quiet the adapter, and let the loop do the
        // reseat between passes. Linux does the same from a workqueue.
        // The acknowledgement that follows this return releases the line,
        // and the next read has nothing to say while a reseat is owed.
        device.reseat_cause = causes;
        device.reseat_pending = true;
        device.regs.word.write(.imr, 0);
        _ = device.regs.word.read(.imr);
        log.warn("atl2", "fatal adapter event; the adapter will be reseated");
        return;
    }

    // The vendor services on the whole event class, errors included:
    // an overflow with no fresh status still means slots to reclaim,
    // and reclaiming them is what ends the overflow.
    if (latched.rx_status or latched.rxf_ov or latched.rxs_ov or latched.host_rxd_ov) reapRx(nic);
    if (latched.tx_status or latched.txf_ur or latched.txs_ov or latched.host_txd_ur or latched.tx_early) reapTx(nic);
    if (latched.link_change or latched.phy or latched.phy_link_down) {
        dev_mod.deliverLink(nic, link(nic));
        applyLinkState(nic.state);
    }
}

/// Service the adapter with no interrupt behind it: a line the firmware
/// routed nowhere, or an edge this service never saw. The two reaps are
/// all an interrupt would have asked for, and the mailboxes they write
/// are what the engine looks at either way.
pub fn poll(nic: *NicDev) bool {
    if (!device.opened or !device.started) return false;
    reseat(nic);
    reapRx(nic);
    reapTx(nic);
    return true;
}

/// Work owed between passes rather than on the line: a pending reseat, and
/// nothing else yet. Asked by the loop, where waiting on the part costs
/// nobody their interrupt.
pub fn upkeep(nic: *NicDev) void {
    if (!device.opened) return;
    reseat(nic);
}

/// Reseat the adapter after a fatal event, outside the interrupt that saw
/// it. Frames still queued are counted as failed rather than silently lost,
/// and the adapter is left stopped if it cannot be brought back: an adapter
/// in that state is not one to keep handing frames to.
fn reseat(nic: *NicDev) void {
    if (!device.reseat_pending) return;
    device.reseat_pending = false;

    log.begin(nic.name, .warn);
    out.text("reseating the adapter after cause 0x");
    out.hex(device.reseat_cause, 8);
    log.end();

    nic.stats.tx_failed += device.txs_used;
    device.txs_used = 0;
    device.txs_fill = .{};
    device.txs_reap = .{};
    device.txd_write = .{};
    device.txd_read = .{};

    if (!configure()) {
        device.started = false;
        dev_mod.deliverLink(nic, .{});
        applyLinkState(nic.state);
        pci.disableInterruptAndMaster(nic.location);
        log.fail("atl2", "adapter recovery failed");
        return;
    }

    device.started = true;
    dev_mod.deliverLink(nic, link(nic));
    applyLinkState(nic.state);
    device.regs.word.write(.imr, @bitCast(UNMASKED));
    _ = device.regs.word.read(.imr);
    log.say("atl2", .dim, "the adapter is back");
}

fn reapRx(nic: *NicDev) void {
    var reaped: usize = 0;
    while (reaped < RX_COUNT) : (reaped += 1) {
        const index = device.rxd_read.at;
        const slot = &device.arena.body().rxd[index];
        // The hardware writes this word; the load must happen every lap.
        const ownership = @as(*const volatile RxStatus, &slot.status).*;

        if (!ownership.update) break;
        dma.consume();
        const status = @as(*const volatile RxStatus, &slot.status).*;

        // The device reports bytes on the wire, including the FCS. Never form
        // a slice until that value has been bounded against both the protocol
        // and the DMA slot.
        const wire_len = @as(usize, status.pkt_len);
        const good = status.ok and !status.crc_error and !status.code_error and
            !status.runt and !status.fragment and !status.truncated and
            !status.align_error and wire_len >= ETH_MIN_WIRE and
            wire_len <= ETH_MAX_FRAME and wire_len <= slot.packet.len;

        if (good) {
            dev_mod.deliverRx(nic, .{
                .ok = true,
                .frame = slot.packet[0 .. wire_len - ETH_FCS],
            });
        } else {
            dev_mod.deliverRx(nic, .{});
        }

        // The whole status word, update included: the slot is ours again.
        @as(*volatile RxStatus, &slot.status).* = .{};
        dma.publish();
        device.rxd_read.next();
    }
    if (reaped != 0) device.regs.half.write(.mb_rxd_rd_idx, @intCast(device.rxd_read.at));
}

fn reapTx(nic: *NicDev) void {
    var reaped: usize = 0;
    while (device.txs_used != 0 and reaped < TXS_COUNT) : (reaped += 1) {
        const index = device.txs_reap.at;
        const ownership = @as(*const volatile TxStatus, &device.arena.body().txs[index]).*;
        if (!ownership.update) break;
        dma.consume();
        const status = @as(*const volatile TxStatus, &device.arena.body().txs[index]).*;

        // The fifo bytes this frame held: header, then the payload padded to
        // a dword, which is the same rounding the write side made.
        const length = device.tx_lengths[index];
        const held = @sizeOf(TxHeader) + std.mem.alignForward(usize, length, @sizeOf(u32));
        if (!status.ok or status.pkt_len != length) nic.stats.tx_failed += 1;
        @as(*volatile TxStatus, &device.arena.body().txs[index]).* = .{};
        device.tx_lengths[index] = 0;
        device.txd_read.advance(held);
        device.txs_reap.next();
        device.txs_used -= 1;
    }
}

pub fn transmit(nic: *NicDev, frame: []const u8) bool {
    if (!device.opened or !device.started or
        frame.len < ETH_HEADER or frame.len > ETH_MAX_FRAME - ETH_FCS)
    {
        return false;
    }
    // Completions are advisory interrupts; reclaim here too so coalescing
    // cannot make a free ring look full.
    reapTx(nic);
    if (device.txs_used >= TXS_COUNT - 1) {
        nic.stats.tx_failed += 1;
        return false;
    }

    const pay = std.mem.alignForward(usize, frame.len, @sizeOf(u32));
    const needed = @sizeOf(TxHeader) + pay;
    // How much of the fifo the hardware has still to consume. The write
    // cursor is behind the read one for the whole of every lap after the
    // first, which is the ordinary case and not the awkward one, so the
    // distance is measured the way a lap measures it: a `usize` taken
    // below zero is a panic in a safe build and silent nonsense in the
    // one that ships.
    const used = device.txd_write.used(device.txd_read.at);
    if (TXD_BYTES - used < needed + 4) {
        nic.stats.tx_failed += 1;
        return false;
    }

    // The next status slot we are handing the hardware: clear its update, so
    // a completion the hardware writes next is distinguishable from one left
    // over from the last lap of the ring.
    const status_slot = device.txs_fill.at;
    @as(*volatile TxStatus, &device.arena.body().txs[status_slot]).* = .{};

    const header = TxHeader{ .pkt_len = @intCast(frame.len) };
    const at = device.txd_write.at;
    writeFifo(at, @sizeOf(TxHeader), std.mem.asBytes(&header));
    writeFifo(cursor.wrapped(at + @sizeOf(TxHeader), TXD_BYTES), frame.len, frame);

    device.txd_write.advance(needed);
    device.tx_lengths[status_slot] = @intCast(frame.len);
    device.txs_fill.next();
    device.txs_used += 1;

    // The engine fetches the FIFO as soon as the mailbox advances. Publish
    // every byte and the cleared status before that ownership handoff, then
    // read the mailbox back to flush the posted MMIO write.
    dma.publish();
    device.regs.half.write(.mb_txd_wr_idx, @intCast(device.txd_write.at / @sizeOf(u32)));
    _ = device.regs.half.read(.mb_txd_wr_idx);

    dev_mod.deliverTx(nic, frame.len);
    return true;
}

/// Copy into the FIFO, in two pieces when it wraps. The caller hands a
/// pointer here so the header and the frame share one path, and the header is
/// one word so no separate mechanism is worth building.
fn writeFifo(at: usize, len: usize, bytes: []const u8) void {
    const first = @min(len, TXD_BYTES - at);
    @memcpy(device.arena.body().txd[at..][0..first], bytes[0..first]);
    if (first < len) {
        @memcpy(device.arena.body().txd[0 .. len - first], bytes[first..len]);
    }
}

// ---------------------------------------------------------------------------
// Link
// ---------------------------------------------------------------------------

pub fn link(_: *NicDev) dev_mod.Link {
    if (!device.opened) return .{};
    // Read twice, the way the vendor's driver does: the first may latch.
    _ = readPhy(.bmsr) orelse return .{};
    const status: mii.Status = @bitCast(readPhy(.bmsr) orelse return .{});
    // Whether a word is a link at all is the standard's question and
    // `mii`'s answer. No carrier: there is nothing finer to ask, and the
    // vendor register below has resolved nothing either.
    if (mii.outcome(status) == null) return .{ .up = false };

    const pssr = @as(Pssr, @bitCast(readPhy(.pssr) orelse return .{}));
    if (!pssr.resolved) return .{};
    // How fast, in the standard's words rather than this part's encoding
    // of them: a PHY that has resolved neither ten nor a hundred has not
    // answered, and `mii` has no name for what it did say.
    const speed: mii.Speed = switch (pssr.speed) {
        .m10 => .m10,
        .m100 => .m100,
        else => return .{},
    };

    // Taken as given rather than derived: a part that reports 100 full has
    // already done the negotiation, and second-guessing it from the
    // advertisement is how a driver decides a wire is something it is not.
    const resolved = mii.resolved(status, speed, if (pssr.full_duplex) .full else .half) orelse
        return .{};
    return .{
        .up = resolved.up,
        .mbps = resolved.speed.mbps(),
        .duplex = if (resolved.duplex == .full) .full else .half,
    };
}

/// Re-read the link and write it into the MAC's own control register. The
/// engine gates on this at every enable, and a refresh that reports up must
/// be the refresh that told the hardware so: on this adapter the two answers
/// live in different places.
pub fn syncLink(nic: *NicDev) void {
    // Asked on ordinary `net` requests, which come for an adapter that
    // never opened as readily as for one that did: the registers below
    // are a mapping this driver does not hold in that case, and reading
    // one of them is a fault in a process that serves every interface.
    if (!device.opened) {
        dev_mod.deliverLink(nic, .{});
        return;
    }
    const state = if (device.started) link(nic) else dev_mod.Link{};
    dev_mod.deliverLink(nic, state);
    applyLinkState(state);

    // Only when one of them moves. This is asked on every look at the
    // link, and a line each time is a flood that pushes everything else
    // out of the log ring.
    const now = Registers{
        .mac_ctrl = device.regs.word.read(.mac_ctrl),
        .imr = device.regs.word.read(.imr),
        .isr = device.regs.word.read(.isr),
    };
    if (said_registers) |before| {
        if (std.meta.eql(before, now)) return;
    }
    said_registers = now;

    log.begin("atl2", .dim);
    out.text("sync mac_ctrl 0x");
    out.hex(now.mac_ctrl, 8);
    out.text(" imr 0x");
    out.hex(now.imr, 8);
    out.text(" isr 0x");
    out.hex(now.isr, 8);
    log.end();
}

const Registers = struct { mac_ctrl: u32, imr: u32, isr: u32 };

/// What the last such line said, so the same thing is not said again.
var said_registers: ?Registers = null;

fn applyLinkState(state: dev_mod.Link) void {
    // The whole register, flat, as the vendor's driver writes it. Every one
    // of these matters on a wire: no preamble means no receiver ever
    // synchronises, and no appended check means every frame arrives broken.
    device.regs.word.write(.mac_ctrl, @bitCast(MacCtrl{
        .tx_enable = state.up,
        .rx_enable = state.up,
        .full_duplex = state.duplex == .full,
        .phy_clock = true,
        .tx_flow = true,
        .rx_flow = true,
        .add_crc = true,
        .pad = true,
        .preamble_len = 7,
        .broadcast_accept = true,
        .speed = .m10_100,
    }));
}

/// A bounded wait with `pause`: the manual's waits are microseconds of
/// hardware settling, and a wedged device must cost a slow spin and a "no",
/// never a machine.
fn spinUntil(budget: u32, done: *const fn (Regs) bool) bool {
    var spins: u32 = 0;
    while (spins < budget) : (spins += 1) {
        if (done(device.regs)) return true;
        std.atomic.spinLoopHint();
    }
    return false;
}

/// Who this driver is, for the probe table and the interface listing.
pub const name = "atl2";
pub const vendor = 0x1969;
pub const device_id = 0x2048;
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
