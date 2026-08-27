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
const log = @import("ulib").log;
const pci = @import("ulib").pci;
const sys = @import("sys");

const NicDev = dev_mod.NicDev;

// ---------------------------------------------------------------------------
// Register window
// ---------------------------------------------------------------------------

/// Register offsets, bytes. The word-wide registers (16-bit) are marked in
/// their doc; everything else is a dword.
const R = enum(u32) {
    master_ctrl = 0x1400,
    irq_modu_timer = 0x1408, // 16-bit
    phy_enable = 0x140C, // 16-bit
    cmbdisdma_timer = 0x140E, // 16-bit
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
    txd_mem_size = 0x1548, // 16-bit, dword units
    txs_base_lo = 0x154C,
    txs_mem_size = 0x1550, // 16-bit, dword units
    rxd_base_lo = 0x1554,
    rxd_buf_num = 0x1558, // 16-bit
    dmar = 0x1580,
    tx_cut_thresh = 0x1590,
    dmaw = 0x15A0,
    pause_on_th = 0x15A8, // 16-bit
    pause_off_th = 0x15AA, // 16-bit
    mb_txd_wr_idx = 0x15F0, // 16-bit
    mb_rxd_rd_idx = 0x15F4, // 16-bit
    isr = 0x1600,
    imr = 0x1604,
};

/// A byte window over the aperture; each access is one volatile load or
/// store of the register's own width. Volatile is the load-bearing word: a
/// register read has an effect, and a compiler that merged two of them, or
/// dropped a store because a later one hits the same address, would be right
/// about the value and wrong about the device. The word registers sit at
/// word-aligned offsets and the dword registers at dword-aligned ones, which
/// the casts below check.
const Regs = struct {
    base: [*]volatile u8,

    fn wr32(self: Regs, r: R, value: u32) void {
        const at: *volatile u32 = @alignCast(@ptrCast(self.base + @intFromEnum(r)));
        at.* = value;
    }

    fn rd32(self: Regs, r: R) u32 {
        const at: *const volatile u32 = @alignCast(@ptrCast(self.base + @intFromEnum(r)));
        return at.*;
    }

    fn wr16(self: Regs, r: R, value: u16) void {
        const at: *volatile u16 = @alignCast(@ptrCast(self.base + @intFromEnum(r)));
        at.* = value;
    }

    fn rd16(self: Regs, r: R) u16 {
        const at: *const volatile u16 = @alignCast(@ptrCast(self.base + @intFromEnum(r)));
        return at.*;
    }
};

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
    _0: u2 = 0,
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
    _19: u9 = 0,
    phy_link_down: bool = false,
    _29: u2 = 0,
    /// ISR_DIS_INT: hold interrupts while servicing on a shared line.
    hold: bool = false,

    fn none(self: Isr) bool {
        const v: u32 = @bitCast(self);
        return v & ~(@as(u32, 1) << 31) == 0;
    }
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
    if (@sizeOf(MdioCtrl) != 4 or @sizeOf(MacCtrl) != 4 or @sizeOf(Isr) != 4) {
        @compileError("a control register shapes one dword");
    }
    if (@sizeOf(TxHeader) != 4 or @sizeOf(TxStatus) != 4 or @sizeOf(RxStatus) != 4) {
        @compileError("a packet status or header shapes one dword");
    }
    if (@sizeOf(MasterCtrl) != 4 or @sizeOf(IpgIfg) != 4 or @sizeOf(HalfDuplex) != 4) {
        @compileError("a config register shapes one dword");
    }
    if (@sizeOf(Pssr) != 2) @compileError("the PHY status word is one word");
}

// ---------------------------------------------------------------------------
// MII registers
// ---------------------------------------------------------------------------

/// The vendor power-saving bit in debug word zero; the PHY sleeps behind it.
const PHY_POWER_SAVE: u16 = 0x1000;

/// Link-up and link-down, the two events worth a PHY interrupt.
const PHY_LINK_EVENTS: u16 = 0x0C00;

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
    _0: u5 = 0,
    ten_half: bool = false, // bit 5
    ten_full: bool = false, // bit 6
    hundred_half: bool = false, // bit 7
    hundred_full: bool = false, // bit 8
    _9: u7 = 0,
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
const RX_SLOT = 1536;

/// One receive slot: status, VLAN tag, then the frame bytes.
const RxSlot = extern struct {
    status: RxStatus = .{},
    vtag: u16 = 0,
    _reserved: u16 = 0,
    packet: [RX_SLOT - 8]u8 = @splat(0),
};

comptime {
    if (@sizeOf(RxSlot) != 1536) @compileError("a receive slot is 1536 bytes");
    if (@sizeOf(TxStatus) != 4) @compileError("a transmit status is one dword");
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

    /// Where the host writes next in the TXD fifo, and where the host is
    /// still owed statuses in the TXS ring.
    txd_write: usize = 0,
    txd_read: usize = 0,
    txs_fill: u16 = 0, // next slot to send
    txs_reap: u16 = 0, // next slot expected done
    rxd_read: u16 = 0, // next slot to consume (u16 wrap is the ring's own)
};

var device: Device = .{};
var attached = false;

// ---------------------------------------------------------------------------
// Life
// ---------------------------------------------------------------------------

pub fn open(loc: pci.Location, dev: *NicDev) bool {
    if (attached) return false;

    const aperture = sys.mapDevice(pci.bar(loc, 0) & ~@as(u32, 0xF), 256 * 1024) orelse {
        log.fail("atl2", "cannot map registers");
        return false;
    };
    pci.enableMemoryAndMaster(loc);
    device.regs = .{ .base = @ptrCast(@volatileCast(aperture)) };

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
    if (phys % 128 != 0) {
        log.fail("atl2", "DMA memory is not aligned for the adapter");
        return false;
    }
    const mapped = sys.shmMap(@intCast(handle), .{ .writable = true }) orelse {
        log.fail("atl2", "cannot map DMA rings");
        return false;
    };
    device.arena = @alignCast(@ptrCast(mapped));
    device.phys = phys;

    if (!configure()) return false;
    readMac(dev);
    dev.state = link(dev);

    attached = true;
    return true;
}

/// Reset and configure, the sequence design/08 §4.2 fixes. Bounded waits
/// only: a wedged controller costs a refused driver, never a machine.
fn configure() bool {
    var master = @as(MasterCtrl, @bitCast(device.regs.rd32(.master_ctrl)));
    master.soft_reset = true;
    device.regs.wr32(.master_ctrl, @bitCast(master));

    // Idle poll, the manual's 1 ms step, at most ten.
    var tries: u8 = 0;
    while (tries < 10) : (tries += 1) {
        sys.sleepMicros(1_000);
        if (device.regs.rd32(.idle_status) == 0) break;
    }

    phyInit();

    // Clear interrupt status, whole word.
    device.regs.wr32(.isr, @as(u32, 0xFFFF_FFFF));

    // Descriptor addresses: this machine is 32-bit, the high word is zero.
    device.regs.wr32(.desc_base_hi, 0);
    device.regs.wr32(.txd_base_lo, device.phys + @offsetOf(Arena, "txd"));
    device.regs.wr16(.txd_mem_size, TXD_BYTES / 4);
    device.regs.wr32(.txs_base_lo, device.phys + @offsetOf(Arena, "txs"));
    device.regs.wr16(.txs_mem_size, TXS_COUNT);
    device.regs.wr32(.rxd_base_lo, device.phys + @offsetOf(Arena, "rxd"));
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
    device.regs.wr32(.mtu, 1500 + 14 + 4 + 4);
    device.regs.wr32(.tx_cut_thresh, 0x177);
    device.regs.wr16(.pause_on_th, 0);
    device.regs.wr16(.pause_off_th, 0);

    // Mailboxes start empty, and the engine turns.
    device.regs.wr16(.mb_txd_wr_idx, 0);
    device.regs.wr16(.mb_rxd_rd_idx, 0);
    device.regs.wr32(.dmar, 1);
    device.regs.wr32(.dmaw, 1);

    // Every cause acknowledged, then the line released; the hold bit is the
    // one bit that is not a cause.
    device.regs.wr32(.isr, ACK_EVERYTHING);
    device.regs.wr32(.isr, 0);
    device.regs.wr32(.imr, @bitCast(UNMASKED));
    return true;
}

/// Writing one to a cause clears it; all of them at once is the reset of the
/// register. Bit 31 stays clear: it is the hold, not a cause.
const ACK_EVERYTHING: u32 = 0x7FFF_FFFF;

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
fn phyInit() void {
    device.regs.wr16(.phy_enable, 1);
    sys.sleepMicros(1_000);

    writePhy(.dbg_addr, 0);
    const debug = readPhy(.dbg_data);
    if (debug & PHY_POWER_SAVE != 0) writePhy(.dbg_data, debug & ~PHY_POWER_SAVE);

    writePhy(.interrupt, PHY_LINK_EVENTS);
    writePhy(.advertise, @bitCast(ADVERTISE_ALL));
    writePhy(.bmcr, @bitCast(BMCR{
        .reset = true,
        .autoneg_enable = true,
        .restart_autoneg = true,
    }));
}

fn readMac(dev: *NicDev) void {
    // The vendors keep the permanent address two ways this driver is not
    // being asked to parse yet (NVM/EEPROM words). Reading the working
    // registers back is where the BIOS usually leaves the right one, and on
    // the far path the fields come back all-zero and rightly look like no
    // story: nothing is invented.
    const low = device.regs.rd32(.mac_sta_addr);
    const high = device.regs.rd32(.mac_sta_addr_hi);
    // The high word holds the first two octets with the first in its upper
    // byte: the vendor's own assignment begins 00:1f:c6, and swapped halves
    // put the multicast bit in the station address.
    dev.mac = .{
        @truncate(high >> 8),
        @truncate(high),
        @truncate(low >> 24),
        @truncate(low >> 16),
        @truncate(low >> 8),
        @truncate(low),
    };
    // Write what was read, so the filter matches the word on the wire.
    device.regs.wr32(.mac_sta_addr, low);
    device.regs.wr32(.mac_sta_addr_hi, high);
}

pub fn start(nic: *NicDev) bool {
    nic.state = link(nic);
    applyLinkState(nic.state);
    return true;
}

pub fn stop(_: *NicDev) void {
    var ctrl = @as(MacCtrl, @bitCast(device.regs.rd32(.mac_ctrl)));
    ctrl.rx_enable = false;
    ctrl.tx_enable = false;
    device.regs.wr32(.mac_ctrl, @bitCast(ctrl));
}

// ---------------------------------------------------------------------------
// MII, hosts of PHY transactions
// ---------------------------------------------------------------------------

fn writePhy(reg: Phy, value: u16) void {
    if (mdioBegin(reg, false, value)) return;
    _ = spinUntil(10, struct {
        fn idle(r: Regs) bool {
            return !@as(MdioCtrl, @bitCast(r.rd32(.mdio_ctrl))).busy;
        }
    }.idle);
}

fn readPhy(reg: Phy) u16 {
    if (mdioBegin(reg, true, 0)) return 0;
    const done = spinUntil(10, struct {
        fn idle(r: Regs) bool {
            return !@as(MdioCtrl, @bitCast(r.rd32(.mdio_ctrl))).busy;
        }
    }.idle);
    if (!done) return 0;
    return @as(MdioCtrl, @bitCast(device.regs.rd32(.mdio_ctrl))).data;
}

/// One MDIO transaction, returning true if the bus would not answer within
/// the bound. Waiting for the bus first, then starting.
fn mdioBegin(reg: Phy, read: bool, value: u16) bool {
    if (!spinUntil(10, struct {
        fn idle(r: Regs) bool {
            return !@as(MdioCtrl, @bitCast(r.rd32(.mdio_ctrl))).busy;
        }
    }.idle)) return true;

    device.regs.wr32(.mdio_ctrl, @bitCast(MdioCtrl{
        .data = value,
        .phy_reg = @intFromEnum(reg),
        .read = read,
        .start = true,
    }));
    return false;
}

// ---------------------------------------------------------------------------
// Traffic
// ---------------------------------------------------------------------------

pub fn irq(nic: *NicDev) void {
    const cause = @as(Isr, @bitCast(device.regs.rd32(.isr)));
    if (cause.none()) return; // a shared line, not ours

    // The PHY latches its interrupt until its status register is read, so
    // the read comes before the acknowledgement: acknowledged the other way
    // round, the still-latched line re-raises the cause just cleared.
    if (cause.phy) _ = readPhy(.interrupt_clear);

    // Acknowledge and hold the line (ISR_DIS_INT), per the manual: work on
    // it before the next delivery on a shared level line.
    device.regs.wr32(.isr, @as(u32, @bitCast(cause)) | @as(u32, @bitCast(Isr{ .hold = true })));

    if (cause.dmar_timeout or cause.dmaw_timeout) {
        // The manual's answer to a wedged DMA engine is a full reset. Masked
        // and quieted first, and the link reapplied after, because configure
        // leaves the MAC disabled until the link state says otherwise.
        log.warn("atl2", "DMA timeout; reseating the adapter");
        device.regs.wr32(.imr, 0);
        device.regs.wr32(.isr, 0);
        _ = configure();
        nic.state = link(nic);
        applyLinkState(nic.state);
        return;
    }

    if (cause.rx_status) reapRx(nic);
    if (cause.tx_status) reapTx();
    if (cause.link_change or cause.phy or cause.phy_link_down) {
        nic.state = link(nic);
        applyLinkState(nic.state);
    }

    // Release the line.
    device.regs.wr32(.isr, 0);
}

fn reapRx(nic: *NicDev) void {
    while (true) {
        const index = device.rxd_read % RX_COUNT;
        const slot = &device.arena.rxd[index];
        // The hardware writes this word; the load must happen every lap.
        const status = @as(*const volatile RxStatus, &slot.status).*;

        if (!status.update) break;

        // The length comes off the wire; the slot clamps whatever it says.
        const len = @min(status.pkt_len, RX_SLOT - 8);
        const good = status.ok and !status.crc_error and !status.code_error and
            !status.fragment and !status.align_error and len >= 60;

        dev_mod.deliverRx(nic, .{
            .ok = good,
            .frame = slot.packet[0..len],
        });

        // The whole status word, update included: the slot is ours again.
        @as(*volatile RxStatus, &slot.status).* = .{};
        device.rxd_read +%= 1;
        device.regs.wr16(.mb_rxd_rd_idx, device.rxd_read);
    }
}

fn reapTx() void {
    while (true) {
        const index = device.txs_reap % TXS_COUNT;
        const status = @as(*const volatile TxStatus, &device.arena.txs[index]).*;
        if (!status.update) break;

        // The fifo bytes this frame held: header, then the payload padded to
        // a dword, which is the same rounding the write side made.
        const held = 4 + ((@as(usize, status.pkt_len) + 3) & ~@as(usize, 3));
        device.txd_read = (device.txd_read + held) % TXD_BYTES;
        device.txs_reap +%= 1;
    }
}

pub fn transmit(nic: *NicDev, frame: []const u8) void {
    if (frame.len > RX_SLOT - 8 - 4) return;

    const pay = (frame.len + 3) & ~@as(usize, 3);
    const needed = 4 + pay;
    const used = (device.txd_write - device.txd_read + TXD_BYTES) % TXD_BYTES;
    if (TXD_BYTES - used < needed + 4) {
        nic.stats.tx_failed += 1;
        return;
    }

    // The next status slot we are handing the hardware: clear its update, so
    // a completion the hardware writes next is distinguishable from one left
    // over from the last lap of the ring.
    @as(*volatile TxStatus, &device.arena.txs[device.txs_fill % TXS_COUNT]).* = .{};

    const header = TxHeader{ .pkt_len = @intCast(frame.len) };
    writeFifo(device.txd_write, 4, @as([*]const u8, @ptrCast(&header))[0..4]);
    writeFifo(device.txd_write + 4, frame.len, frame);

    device.txd_write = (device.txd_write + needed) % TXD_BYTES;
    device.txs_fill +%= 1;
    device.regs.wr16(.mb_txd_wr_idx, @intCast(device.txd_write >> 2));

    dev_mod.deliverTx(nic, frame.len);
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
    // Read twice, the way the vendor's driver does: the first may latch.
    _ = readPhy(.bmsr);
    const bmsr = @as(BMSR, @bitCast(readPhy(.bmsr)));
    if (!bmsr.link_status) return .{ .up = false };

    const pssr = @as(Pssr, @bitCast(readPhy(.pssr)));
    return .{
        .up = true,
        .mbps = pssr.speed.mbps(),
        .duplex = if (pssr.full_duplex) .full else .half,
    };
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
        asm volatile ("pause");
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
};