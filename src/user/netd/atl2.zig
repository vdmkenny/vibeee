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
const dma = @import("dma.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const std = @import("std");
const sys = @import("sys");

const NicDev = dev_mod.NicDev;
const MMIO_BYTES: u32 = 256 * 1024;
const ETH_MTU = 1500;
const ETH_HEADER = 14;
const ETH_FCS = 4;
const ETH_VLAN = 4;
const ETH_MIN_WIRE = 64;
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

/// A byte window over the aperture; each access is one volatile load or
/// store of the register's own width. Volatile is the load-bearing word: a
/// register read has an effect, and a compiler that merged two of them, or
/// dropped a store because a later one hits the same address, would be right
/// about the value and wrong about the device.
const Regs = struct {
    base: [*]volatile u8,

    fn wr32(self: Regs, r: R32, value: u32) void {
        const at: *volatile u32 = @ptrCast(@alignCast(self.base + @intFromEnum(r)));
        at.* = value;
    }

    fn rd32(self: Regs, r: R32) u32 {
        const at: *const volatile u32 = @ptrCast(@alignCast(self.base + @intFromEnum(r)));
        return at.*;
    }

    fn wr16(self: Regs, r: R16, value: u16) void {
        const at: *volatile u16 = @ptrCast(@alignCast(self.base + @intFromEnum(r)));
        at.* = value;
    }

    fn rd16(self: Regs, r: R16) u16 {
        const at: *const volatile u16 = @ptrCast(@alignCast(self.base + @intFromEnum(r)));
        return at.*;
    }

    fn wr8(self: Regs, r: R8, value: u8) void {
        self.base[@intFromEnum(r)] = value;
    }
};

fn validateRegisterSet(comptime Register: type, comptime width: u32) void {
    inline for (std.meta.fields(Register)) |field| {
        if (field.value % width != 0) @compileError("ATL2 register is misaligned for its access width");
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
    _16: u9 = 0,
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
    _17: u10 = 0,
    underrun: bool = false,
    _28: u3 = 0,
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

const BMSR = packed struct(u16) {
    _0: u2 = 0,
    link_status: bool = false, // bit 2
    _3: u12 = 0,
    _15: u1 = 0,
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
/// hardware reads them. The receive slots demand 128-byte alignment.
const Arena = struct {
    txd: [TXD_BYTES]u8 = @splat(0),
    txs: [TXS_COUNT]TxStatus = @splat(.{}),
    rxd: [RX_COUNT]RxSlot align(128) = @splat(.{}),

    comptime {
        if (@sizeOf(Arena) != TXD_BYTES + TXS_COUNT * 4 + RX_COUNT * RX_SLOT) {
            @compileError("the descriptor arena must pack without padding surprises");
        }
    }
};

/// TFrames live in the FIFO with their four-byte header; the tread pointer
/// (what the hardware has consumed) is derived from the statuses.
const Device = struct {
    regs: Regs = .{ .base = undefined },
    arena: *Arena = undefined,
    phys: u32 = 0,
    dma_handle: ?u32 = null,
    mac: [6]u8 = @splat(0),
    /// Where it sits on the bus, kept for the PCIe capability work.
    location: pci.Location = @bitCast(@as(u16, 0)),

    /// Where the host writes next in the TXD fifo, and where the host is
    /// still owed statuses in the TXS ring.
    txd_write: usize = 0,
    txd_read: usize = 0,
    txs_fill: usize = 0,
    txs_reap: usize = 0,
    txs_used: usize = 0,
    tx_lengths: [TXS_COUNT]u16 = @splat(0),
    rxd_read: usize = 0,
    opened: bool = false,
    started: bool = false,
};

var device: Device = .{};

// ---------------------------------------------------------------------------
// Life
// ---------------------------------------------------------------------------

pub fn open(loc: pci.Location, dev: *NicDev) bool {
    if (device.opened or device.dma_handle != null) return false;

    device.location = loc;
    const base = bar0(loc) orelse return false;
    const aperture = sys.mapDevice(base, MMIO_BYTES) orelse {
        log.fail("atl2", "cannot map registers");
        return false;
    };
    pci.enableMemoryAndMaster(loc);
    var keep_pci_enabled = false;
    defer if (!keep_pci_enabled) pci.disableInterruptAndMaster(loc);
    device.regs = .{ .base = @ptrCast(@volatileCast(aperture)) };
    device.regs.wr32(.imr, 0);
    _ = device.regs.rd32(.imr);
    log.say("atl2", .dim, "registers mapped");

    device.mac = readMac() orelse {
        log.fail("atl2", "cannot read a valid MAC address");
        return false;
    };

    var phys: u32 = 0;
    const handle = sys.dmaAlloc(@sizeOf(Arena), &phys);
    if (handle < 0) {
        log.failed("atl2", "cannot allocate DMA rings", handle);
        return false;
    }
    // DMA memory is page-granular, so the 128-byte alignment the receive
    // slots demand always holds. Checked rather than adjusted: an adjusted
    // physical base without the same shift on the mapping would have the CPU
    // and the card each writing a different arena.
    const dma_handle: u32 = @intCast(handle);
    const last_offset: u32 = @intCast(@sizeOf(Arena) - 1);
    if (phys % @alignOf(Arena) != 0 or phys > std.math.maxInt(u32) - last_offset) {
        _ = sys.close(dma_handle);
        log.fail("atl2", "DMA memory is not aligned for the adapter");
        return false;
    }
    const mapped = sys.shmMap(dma_handle, .{ .writable = true }) orelse {
        _ = sys.close(dma_handle);
        log.fail("atl2", "cannot map DMA rings");
        return false;
    };
    device.arena = @ptrCast(@alignCast(mapped));
    device.phys = phys;
    device.dma_handle = dma_handle;
    device.arena.* = .{};

    log.say("atl2", .dim, "rings placed");
    if (!configure()) {
        // Configuration may already have enabled the DMA engines. Stop PCI
        // mastering before the backing allocation can be returned.
        pci.disableInterruptAndMaster(loc);
        keep_pci_enabled = true;
        _ = sys.close(dma_handle);
        device.dma_handle = null;
        device.phys = 0;
        return false;
    }
    log.say("atl2", .dim, "engine configured");
    dev.mac = device.mac;
    device.opened = true;
    keep_pci_enabled = true;
    dev.state = link(dev);

    return true;
}

fn bar0(loc: pci.Location) ?u32 {
    const raw = pci.bar(loc, 0);
    const bar: pci.MemoryBar = @bitCast(raw);
    if (bar.space != .memory or bar.kind == .reserved or bar.kind == .below_one_megabyte) {
        log.fail("atl2", "BAR0 is not a usable memory BAR");
        return null;
    }
    if (bar.kind == .bits64 and pci.bar(loc, 1) != 0) {
        log.fail("atl2", "BAR0 lies above the 32-bit address space");
        return null;
    }
    const base = bar.base();
    if (base == 0 or base > std.math.maxInt(u32) - (MMIO_BYTES - 1)) {
        log.fail("atl2", "BAR0 has no usable address");
        return null;
    }
    return base;
}

/// Reset and configure, the sequence design/08 §4.2 fixes. Bounded waits
/// only: a wedged controller costs a refused driver, never a machine.
fn configure() bool {
    device.regs.wr32(.imr, 0);
    _ = device.regs.rd32(.imr);
    if (!resetController()) return false;
    initPcie();
    resetRings();
    if (!phyInit()) {
        log.fail("atl2", "PHY did not answer");
        return false;
    }

    // Clear interrupt status, whole word.
    device.regs.wr32(.isr, ACK_EVERYTHING);
    writeMac();

    // Descriptor addresses: this machine is 32-bit, the high word is zero.
    device.regs.wr32(.desc_base_hi, 0);
    device.regs.wr32(.txd_base_lo, device.phys + @as(u32, @intCast(@offsetOf(Arena, "txd"))));
    device.regs.wr16(.txd_mem_size, TXD_BYTES / @sizeOf(u32));
    device.regs.wr32(.txs_base_lo, device.phys + @as(u32, @intCast(@offsetOf(Arena, "txs"))));
    device.regs.wr16(.txs_mem_size, TXS_COUNT);
    device.regs.wr32(.rxd_base_lo, device.phys + @as(u32, @intCast(@offsetOf(Arena, "rxd"))));
    device.regs.wr16(.rxd_buf_num, RX_COUNT);

    // Frame scheduling.
    device.regs.wr32(.mac_ipg_ifg, @bitCast(IpgIfg{
        .ipgt = 0x60,
        .min_ifg = 0x50,
        .ipgr1 = 0x40,
        .ipgr2 = 0x60,
    }));
    device.regs.wr32(.mac_half_duplex, @bitCast(HalfDuplex{
        .lcol = 0x37,
        .retry = 0xF,
        .exc_defer = true,
        .abebt = 0xA,
        .jam_ipg = 7,
    }));

    // Interrupt moderation: 100 * 2 us between deliveries, cleared timer
    // ~100 ms, plus the flag that arms the moderator at all.
    device.regs.wr16(.irq_modu_timer, 100);
    // A flat write, not a read-modify-write: after reset the register is the
    // moderation bit's to define, and this is the value the vendor's driver
    // has always written.
    device.regs.wr32(.master_ctrl, @bitCast(MasterCtrl{ .irq_moder = true }));
    device.regs.wr16(.cmbdisdma_timer, 50000);

    // Frame sizes and cut-through.
    device.regs.wr32(.mtu, MAC_FRAME_LIMIT);
    device.regs.wr32(.tx_cut_thresh, 0x177);

    // The 802.3x pause generator's thresholds, in occupied receive slots:
    // ask the far end to pause at seven eighths full, release it at a
    // twelfth. The vendor's driver computes exactly these from the ring
    // size. Zeroes here are not "off": with flow control enabled they read
    // as pause-always and release-never, a corner the silicon never ships
    // in, and the generator then fights the transmit path for the wire on
    // every received frame.
    device.regs.wr16(.pause_on_th, PAUSE_ON_SLOTS);
    device.regs.wr16(.pause_off_th, PAUSE_OFF_SLOTS);

    // Mailboxes start empty, and the engine turns.
    device.regs.wr16(.mb_txd_wr_idx, 0);
    device.regs.wr16(.mb_rxd_rd_idx, 0);
    dma.publish();
    device.regs.wr8(.dmar, @bitCast(DmaControl{ .enabled = true }));
    device.regs.wr8(.dmaw, @bitCast(DmaControl{ .enabled = true }));

    const status = @as(Isr, @bitCast(device.regs.rd32(.isr)));

    // Every cause acknowledged, then the line released; the hold bit is the
    // one bit that is not a cause.
    device.regs.wr32(.isr, ACK_EVERYTHING);
    device.regs.wr32(.isr, 0);
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
    device.regs.wr32(.ltssm_test_mode, @intFromEnum(LtssmTestMode.vendor_default));
    device.regs.wr32(.pcie_dll_tx_ctrl1, @intFromEnum(PcieDllTxCtrl1.vendor_default));

    // Force the PCIe PHY's receiver-detection result. Both reference
    // drivers set this entering suspend so a sleeping link can still
    // handshake; holding it for the whole run goes beyond them, chosen
    // deliberately for a link that has been observed to fall off the bus
    // mid-burst on this machine. A receiver this PHY fails to detect is a
    // link it will drop.
    const phymisc = device.regs.rd32(.pcie_phymisc);
    device.regs.wr32(.pcie_phymisc, phymisc | PCIE_PHYMISC_FORCE_RCV_DET);

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
    const head: pci.CapabilityPointer = @bitCast(pci.read(device.location, pci.CAPABILITIES_OFFSET));

    var at = head.pointer;
    while (at != 0) {
        const capability: pci.Capability = @bitCast(pci.read(device.location, at));
        if (capability.id == .pcie) {
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
            return;
        }
        at = capability.next;
    }
}

fn resetController() bool {
    device.regs.wr32(.master_ctrl, @bitCast(MasterCtrl{ .soft_reset = true }));
    _ = device.regs.rd32(.master_ctrl);
    sys.sleepMicros(1_000);

    for (0..10) |_| {
        if (device.regs.rd32(.idle_status) == 0) return true;
        sys.sleepMicros(1_000);
    }
    log.fail("atl2", "engines did not become idle after reset");
    return false;
}

fn resetRings() void {
    device.txd_write = 0;
    device.txd_read = 0;
    device.txs_fill = 0;
    device.txs_reap = 0;
    device.txs_used = 0;
    device.tx_lengths = @splat(0);
    device.rxd_read = 0;
    for (&device.arena.txs) |*status| status.* = .{};
    for (&device.arena.rxd) |*slot| slot.status = .{};
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
    device.regs.wr16(.phy_enable, @bitCast(PhyEnable{ .enabled = true }));
    _ = device.regs.rd16(.phy_enable);
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
    const low: StationAddressLow = @bitCast(device.regs.rd32(.mac_sta_addr));
    const high: StationAddressHigh = @bitCast(device.regs.rd32(.mac_sta_addr_hi));
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
    return if (validMac(mac)) mac else null;
}

fn validMac(mac: [6]u8) bool {
    if (mac[0] & 1 != 0) return false;
    var any = false;
    var all_ff = true;
    for (mac) |octet| {
        any = any or octet != 0;
        all_ff = all_ff and octet == 0xFF;
    }
    return any and !all_ff;
}

fn writeMac() void {
    const mac = device.mac;
    device.regs.wr32(.mac_sta_addr, @bitCast(StationAddressLow{
        .octet2 = mac[2],
        .octet3 = mac[3],
        .octet4 = mac[4],
        .octet5 = mac[5],
    }));
    device.regs.wr32(.mac_sta_addr_hi, @bitCast(StationAddressHigh{
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
    device.regs.wr32(.isr, ACK_EVERYTHING);
    device.regs.wr32(.isr, 0);
    device.started = true;
    // The step about to be taken, then the step taken: the pin opens here,
    // and on this machine the first assertion of a line is a moment worth
    // bracketing on the screen.
    log.say("atl2", .dim, "link state applied");
    pci.enableInterrupt(nic.location);
    device.regs.wr32(.imr, @bitCast(UNMASKED));
    _ = device.regs.rd32(.imr);
    log.say("atl2", .dim, "interrupts open");
    return true;
}

pub fn stop(nic: *NicDev) void {
    if (!device.opened) return;
    device.started = false;
    device.regs.wr32(.imr, 0);
    _ = device.regs.rd32(.imr);
    var ctrl = @as(MacCtrl, @bitCast(device.regs.rd32(.mac_ctrl)));
    ctrl.rx_enable = false;
    ctrl.tx_enable = false;
    device.regs.wr32(.mac_ctrl, @bitCast(ctrl));
    _ = device.regs.rd32(.mac_ctrl);
    _ = resetController();
    pci.disableInterruptAndMaster(nic.location);
    resetRings();
    if (device.dma_handle) |handle| _ = sys.close(handle);
    device.dma_handle = null;
    device.phys = 0;
    device.opened = false;
    nic.state = .{};
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
    return @as(MdioCtrl, @bitCast(device.regs.rd32(.mdio_ctrl))).data;
}

/// Start one MDIO transaction after the previous one has gone idle.
fn mdioBegin(reg: Phy, read: bool, value: u16) bool {
    if (!spinUntil(MDIO_SPINS, mdioIdle)) return false;

    device.regs.wr32(.mdio_ctrl, @bitCast(MdioCtrl{
        .data = value,
        .phy_reg = @intFromEnum(reg),
        .read = read,
        .start = true,
    }));
    return true;
}

fn mdioIdle(regs: Regs) bool {
    const state = @as(MdioCtrl, @bitCast(regs.rd32(.mdio_ctrl)));
    return !state.start and !state.busy;
}

// ---------------------------------------------------------------------------
// Traffic
// ---------------------------------------------------------------------------

/// Service the adapter until its status reads quiet, the way the vendor's
/// own handler loops. A cause that latches while one is being serviced makes
/// no new interrupt edge, and this service runs whole milliseconds where the
/// vendor's runs microseconds: a single pass would release the line with a
/// latched cause nobody will ever be told about again, and the receive side
/// falls silent until some other bit happens to edge. Frames delivered
/// seconds late, in one clump, are exactly what that silence looks like.
const SERVICE_ROUNDS = 8;

/// The overflow story is told once; after that the counter speaks.
var overflow_said = false;

pub fn irq(nic: *NicDev) bool {
    if (!device.opened or !device.started) return false;

    var serviced = false;
    var round: u32 = 0;
    while (round < SERVICE_ROUNDS) : (round += 1) {
        const cause = @as(Isr, @bitCast(device.regs.rd32(.isr)));
        if (cause.none()) return serviced; // quiet: nothing latched, or a shared line
        serviced = true;

        // The everyday causes are traffic, not news, and stay quiet: the
        // status updates, the PHY answering a poll, and the companions this
        // MAC raises beside them, a TXD underrun with every completion and
        // early-transmit chatter. Overflow means a burst outran the ring
        // while the service was busy; it is counted where `net` shows it,
        // said once, and left to the engine, which drops and recovers on
        // its own. Narrating each one would slow the service further and
        // deepen the very overflow being narrated.
        var unexpected = cause;
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

        if (cause.rxf_ov or cause.rxs_ov or cause.host_rxd_ov) {
            nic.stats.rx_dropped += 1;
            if (!overflow_said) {
                overflow_said = true;
                log.say("atl2", .dim, "rx overflowed under a burst; drops counted from here");
            }
        }

        if (@as(u32, @bitCast(unexpected)) != 0) {
            log.begin("atl2", .dim);
            out.text("cause 0x");
            out.hex(@as(u32, @bitCast(cause)), 8);
            log.end();
        }

        // The PHY latches its interrupt until its status register is read, so
        // the read comes before the acknowledgement: acknowledged the other
        // way round, the still-latched line re-raises the cause just cleared.
        if (cause.phy) _ = readPhy(.interrupt_clear);

        // Acknowledge and hold the line (ISR_DIS_INT), per the manual: work
        // on it before the next delivery on a shared level line.
        var acknowledged = cause;
        acknowledged.hold = true;
        device.regs.wr32(.isr, @bitCast(acknowledged));

        if (cause.phy_link_down or cause.dmar_timeout or cause.dmaw_timeout or
            cause.fatal_error)
        {
            // The manual's answer to a wedged DMA engine is a full reset.
            // A flagged fatal bus error joins it: reading registers against
            // a device in that state is how a bus transaction never
            // completes, and a load that never retires is a frozen machine.
            // Masked and quieted first, and the link reapplied after, because
            // configure leaves the MAC disabled until the link state says
            // otherwise.
            log.warn("atl2", "fatal adapter event; reseating the adapter");
            nic.stats.tx_failed += device.txs_used;
            device.regs.wr32(.imr, 0);
            _ = device.regs.rd32(.imr);
            device.regs.wr32(.isr, 0);
            if (!configure()) {
                device.started = false;
                nic.state = .{};
                applyLinkState(nic.state);
                pci.disableInterruptAndMaster(nic.location);
                log.fail("atl2", "adapter recovery failed");
                return true;
            }
            dev_mod.deliverLink(nic, link(nic));
            applyLinkState(nic.state);
            device.regs.wr32(.imr, @bitCast(UNMASKED));
            _ = device.regs.rd32(.imr);
            return true;
        }

        // The vendor services on the whole event class, errors included:
        // an overflow with no fresh status still means slots to reclaim,
        // and reclaiming them is what ends the overflow.
        if (cause.rx_status or cause.rxf_ov or cause.rxs_ov or cause.host_rxd_ov) reapRx(nic);
        if (cause.tx_status or cause.txf_ur or cause.txs_ov or cause.host_txd_ur or cause.tx_early) reapTx(nic);
        if (cause.link_change or cause.phy or cause.phy_link_down) {
            dev_mod.deliverLink(nic, link(nic));
            applyLinkState(nic.state);
        }

        // Release the line, then look again: only a read that comes back
        // quiet proves nothing latched while the reaps ran.
        device.regs.wr32(.isr, 0);
    }
    return serviced;
}

fn reapRx(nic: *NicDev) void {
    var reaped: usize = 0;
    while (reaped < RX_COUNT) : (reaped += 1) {
        const index = device.rxd_read;
        const slot = &device.arena.rxd[index];
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
        device.rxd_read = (index + 1) % RX_COUNT;
    }
    if (reaped != 0) device.regs.wr16(.mb_rxd_rd_idx, @intCast(device.rxd_read));
}

fn reapTx(nic: *NicDev) void {
    var reaped: usize = 0;
    while (device.txs_used != 0 and reaped < TXS_COUNT) : (reaped += 1) {
        const index = device.txs_reap;
        const ownership = @as(*const volatile TxStatus, &device.arena.txs[index]).*;
        if (!ownership.update) break;
        dma.consume();
        const status = @as(*const volatile TxStatus, &device.arena.txs[index]).*;

        // The fifo bytes this frame held: header, then the payload padded to
        // a dword, which is the same rounding the write side made.
        const length = device.tx_lengths[index];
        const held = @sizeOf(TxHeader) + std.mem.alignForward(usize, length, @sizeOf(u32));
        if (!status.ok or status.pkt_len != length) nic.stats.tx_failed += 1;
        @as(*volatile TxStatus, &device.arena.txs[index]).* = .{};
        device.tx_lengths[index] = 0;
        device.txd_read = (device.txd_read + held) % TXD_BYTES;
        device.txs_reap = (index + 1) % TXS_COUNT;
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
    const used = (device.txd_write - device.txd_read + TXD_BYTES) % TXD_BYTES;
    if (TXD_BYTES - used < needed + 4) {
        nic.stats.tx_failed += 1;
        return false;
    }

    // The next status slot we are handing the hardware: clear its update, so
    // a completion the hardware writes next is distinguishable from one left
    // over from the last lap of the ring.
    const status_slot = device.txs_fill;
    @as(*volatile TxStatus, &device.arena.txs[status_slot]).* = .{};

    const header = TxHeader{ .pkt_len = @intCast(frame.len) };
    writeFifo(device.txd_write, @sizeOf(TxHeader), std.mem.asBytes(&header));
    writeFifo(device.txd_write + @sizeOf(TxHeader), frame.len, frame);

    device.txd_write = (device.txd_write + needed) % TXD_BYTES;
    device.tx_lengths[status_slot] = @intCast(frame.len);
    device.txs_fill = (status_slot + 1) % TXS_COUNT;
    device.txs_used += 1;

    // The engine fetches the FIFO as soon as the mailbox advances. Publish
    // every byte and the cleared status before that ownership handoff, then
    // read the mailbox back to flush the posted MMIO write.
    dma.publish();
    device.regs.wr16(.mb_txd_wr_idx, @intCast(device.txd_write / @sizeOf(u32)));
    _ = device.regs.rd16(.mb_txd_wr_idx);

    dev_mod.deliverTx(nic, frame.len);
    return true;
}

/// Copy into the FIFO, in two pieces when it wraps. The caller hands a
/// pointer here so the header and the frame share one path, and the header is
/// one word so no separate mechanism is worth building.
fn writeFifo(at: usize, len: usize, bytes: []const u8) void {
    const first = @min(len, TXD_BYTES - at);
    @memcpy(device.arena.txd[at..][0..first], bytes[0..first]);
    if (first < len) {
        @memcpy(device.arena.txd[0 .. len - first], bytes[first..len]);
    }
}

// ---------------------------------------------------------------------------
// Link
// ---------------------------------------------------------------------------

pub fn link(_: *NicDev) dev_mod.Link {
    if (!device.opened) return .{};
    // Read twice, the way the vendor's driver does: the first may latch.
    _ = readPhy(.bmsr) orelse return .{};
    const bmsr = @as(BMSR, @bitCast(readPhy(.bmsr) orelse return .{}));
    if (!bmsr.link_status) return .{ .up = false };

    const pssr = @as(Pssr, @bitCast(readPhy(.pssr) orelse return .{}));
    if (!pssr.resolved or (pssr.speed != .m10 and pssr.speed != .m100)) return .{};
    return .{
        .up = true,
        .mbps = pssr.speed.mbps(),
        .duplex = if (pssr.full_duplex) .full else .half,
    };
}

/// Re-read the link and write it into the MAC's own control register. The
/// engine gates on this at every enable, and a refresh that reports up must
/// be the refresh that told the hardware so: on this adapter the two answers
/// live in different places.
pub fn syncLink(nic: *NicDev) void {
    const state = if (device.started) link(nic) else dev_mod.Link{};
    nic.state = state;
    applyLinkState(state);

    log.begin("atl2", .dim);
    out.text("sync mac_ctrl 0x");
    out.hex(device.regs.rd32(.mac_ctrl), 8);
    out.text(" imr 0x");
    out.hex(device.regs.rd32(.imr), 8);
    out.text(" isr 0x");
    out.hex(device.regs.rd32(.isr), 8);
    log.end();
}

fn applyLinkState(state: dev_mod.Link) void {
    // The whole register, flat, as the vendor's driver writes it. Every one
    // of these matters on a wire: no preamble means no receiver ever
    // synchronises, and no appended check means every frame arrives broken.
    device.regs.wr32(.mac_ctrl, @bitCast(MacCtrl{
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
    .transmit = transmit,
    .link = link,
    .sync_link = syncLink,
};
