//! Realtek RTL8139 10/100 ethernet: what QEMU offers besides the e1000, and
//! a card a very wide slice of old hardware actually carries, which is what
//! earns it a place in a "generic netbook" build. Facts from the Realtek
//! RTL8139(C) programmer's guide and Linux's 8139too.c, consulted; this code
//! is written from scratch in this system's shapes.
//!
//! The register file is sixteen windows of bytes or words behind an I/O BAR,
//! like the chip was designed in a later year than it was. Packed structs
//! for every register, a 32 KiB receive ring plus its no-wrap spill area in
//! one DMA segment, four transmit descriptors, and no polling: everything
//! steers from the interrupt handler.

const dev_mod = @import("dev.zig");
const lib = @import("lib");
const dma = @import("dma.zig");
const log = @import("ulib").log;
const pci = @import("ulib").pci;
const ports = @import("ulib").ports;
const std = @import("std");
const sys = @import("sys");

const NicDev = dev_mod.NicDev;

/// Register offsets, bytes. Reached over I/O ports on real hardware and on
/// every emulator that bothers, which is the shape this driver writes today.
const R = enum(u16) {
    idr0 = 0x00,
    tsd0 = 0x10,
    tsd1 = 0x14,
    tsd2 = 0x18,
    tsd3 = 0x1C,
    tsad0 = 0x20,
    tsad1 = 0x24,
    tsad2 = 0x28,
    tsad3 = 0x2C,
    rbstart = 0x30,
    cmd = 0x37,
    capr = 0x38,
    cbr = 0x3A,
    imr = 0x3C,
    isr = 0x3E,
    tcr = 0x40,
    rcr = 0x44,
};

/// A whole window lives behind one port pair; the base port is granted once
/// for the entire driver, and every access is a typed offset from it.
const Window = struct {
    base: u16,

    fn out8(self: Window, r: R, value: u8) void {
        ports.out8(self.base + @intFromEnum(r), value);
    }

    fn in8(self: Window, r: R) u8 {
        return ports.in8(self.base + @intFromEnum(r));
    }

    fn out16(self: Window, r: R, value: u16) void {
        ports.out16(self.base + @intFromEnum(r), value);
    }

    fn in16(self: Window, r: R) u16 {
        return ports.in16(self.base + @intFromEnum(r));
    }

    fn out32(self: Window, r: R, value: u32) void {
        ports.out32(self.base + @intFromEnum(r), value);
    }

    fn in32(self: Window, r: R) u32 {
        return ports.in32(self.base + @intFromEnum(r));
    }
};

// ---------------------------------------------------------------------------
// Register shapes, bit for bit
// ---------------------------------------------------------------------------

/// CMD (0x37): what the engine is doing. BUFE at bit 0, TE at bit 2,
/// RE at bit 3, RST at bit 4.
const Cmd = packed struct(u8) {
    buffer_empty: bool = false,
    _1: u1 = 0,
    tx_enable: bool = false,
    rx_enable: bool = false,
    reset: bool = false,
    _5: u3 = 0,
};

/// ISR and IMR share a shape: what fired, and what is let through. Writing
/// a bit back to ISR clears it.
const Events = packed struct(u16) {
    rx_ok: bool = false,
    rx_error: bool = false,
    tx_ok: bool = false,
    tx_error: bool = false,
    rx_overflow: bool = false,
    packet_underrun: bool = false,
    rx_fifo_overflow: bool = false,
    _7: u1 = 0,
    _8: u6 = 0,
    pci_timeout: bool = false,
    pci_error: bool = false,

    fn hasWork(self: Events) bool {
        return self.rx_ok or self.rx_error or self.tx_ok or self.tx_error or
            self.rx_overflow or self.packet_underrun or self.rx_fifo_overflow or
            self.pci_timeout or self.pci_error;
    }

    fn hasRx(self: Events) bool {
        return self.rx_ok or self.rx_error or self.rx_overflow or self.rx_fifo_overflow;
    }

    fn hasTx(self: Events) bool {
        return self.tx_ok or self.tx_error;
    }
};

const DmaBurst = enum(u3) {
    bytes_16,
    bytes_32,
    bytes_64,
    bytes_128,
    bytes_256,
    bytes_512,
    bytes_1024,
    maximum,
};

const RxBufferLen = enum(u2) {
    kib_8,
    kib_16,
    kib_32,
    kib_64,
};

const RxFifoThreshold = enum(u3) {
    bytes_16,
    bytes_32,
    bytes_64,
    bytes_128,
    bytes_256,
    bytes_512,
    bytes_1024,
    none,
};

/// RCR: what a receive is.
const RxConfig = packed struct(u32) {
    accept_all_physical: bool = false,
    physical_match: bool = false,
    accept_multicast: bool = false,
    accept_broadcast: bool = false,
    accept_runt: bool = false,
    accept_error: bool = false,
    _6: u1 = 0,
    /// Keep a packet contiguous past the nominal end of a sub-64 KiB ring.
    no_wrap: bool = false,
    dma_burst: DmaBurst = .bytes_16,
    buffer_len: RxBufferLen = .kib_8,
    fifo_threshold: RxFifoThreshold = .bytes_16,
    _16: u8 = 0,
    early_threshold: u4 = 0,
    _28: u4 = 0,
};

const InterframeGap = enum(u2) {
    short_84,
    short_88,
    short_92,
    ieee_96,
};

const TxConfig = packed struct(u32) {
    clear_abort: bool = false,
    _1: u3 = 0,
    retry: u4 = 0,
    dma_burst: DmaBurst = .bytes_16,
    _11: u5 = 0,
    disable_crc: bool = false,
    loopback: u2 = 0,
    _19: u5 = 0,
    interframe_gap: InterframeGap = .short_84,
    _26: u6 = 0,
};

/// TSD: writing a length hands a host-owned slot to the device. Completion
/// raises OWN and one of the completion status bits before the slot is reused.
const TxStatus = packed struct(u32) {
    size: u13 = 0,
    host_owns: bool = false,
    underrun: bool = false,
    ok: bool = false,
    early_threshold: u6 = 0,
    _22: u2 = 0,
    collisions: u4 = 0,
    carrier_heartbeat: bool = false,
    out_of_window: bool = false,
    aborted: bool = false,
    carrier_lost: bool = false,

    fn failed(self: TxStatus) bool {
        return !self.ok or self.underrun or self.out_of_window or self.aborted;
    }
};

/// The status word and wire length ahead of every received frame.
const RxHeader = packed struct(u32) {
    ok: bool = false,
    frame_align: bool = false,
    crc_error: bool = false,
    long_frame: bool = false,
    runt_frame: bool = false,
    bad_symbol: bool = false,
    _6: u7 = 0,
    broadcast: bool = false,
    physical: bool = false,
    multicast: bool = false,
    length: u16 = 0,

    fn good(self: RxHeader, frame_len: usize) bool {
        return self.ok and !self.frame_align and !self.crc_error and
            !self.long_frame and !self.runt_frame and !self.bad_symbol and
            frame_len >= ETH_MIN_FRAME and frame_len <= ETH_MAX_FRAME;
    }
};

const EventsUp = Events{
    .rx_ok = true,
    .rx_error = true,
    .rx_overflow = true,
    .tx_ok = true,
    .tx_error = true,
    .packet_underrun = true,
    .rx_fifo_overflow = true,
    .pci_timeout = true,
    .pci_error = true,
};

comptime {
    if (@sizeOf(Cmd) != 1) @compileError("the command register is one byte");
    if (@sizeOf(Events) != 2) @compileError("the interrupt register is one word");
    if (@sizeOf(RxConfig) != 4 or @sizeOf(TxConfig) != 4) @compileError("a transfer config is one dword");
    if (@sizeOf(TxStatus) != 4 or @sizeOf(RxHeader) != 4) @compileError("a packet status is one dword");
}

// ---------------------------------------------------------------------------
// The rings
// ---------------------------------------------------------------------------

/// A 64 KiB ring is known to lock some revisions. In no-wrap mode the chip
/// keeps a packet contiguous beyond a 32 KiB boundary, so the DMA allocation
/// includes the documented pad and enough room for the largest spill.
const RX_RING = 32 * 1024;
const RX_PAD = 16;
const RX_WRAP_PAD = 2048;
const TX_SLOTS = 4;
const TX_BUFFER = 2048;
const ETH_HEADER = 14;
const ETH_MIN_FRAME = 60;
const ETH_MAX_FRAME = 1518;
const ETH_FCS = 4;
const RX_UNFINISHED = 0xFFF0;
const IO_PORTS = 0x100;
const PORT_SPACE: u32 = @as(u32, 1) << @bitSizeOf(u16);
const RESET_ATTEMPTS = 1000;
const IRQ_DRAIN_PASSES = 16;

const RxUp = RxConfig{
    .accept_all_physical = true,
    .physical_match = true,
    .accept_multicast = true,
    .accept_broadcast = true,
    .no_wrap = true,
    .dma_burst = .maximum,
    .buffer_len = .kib_32,
    .fifo_threshold = .none,
};

const TxUp = TxConfig{
    .retry = 8,
    .dma_burst = .bytes_1024,
    .interframe_gap = .ieee_96,
};

const Device = struct {
    window: Window = .{ .base = 0 },
    /// Receive ring + guard in one DMAR run.
    rx: [*]volatile u8 = undefined,
    rx_phys: lib.Phys = .none,
    /// Transmit descriptor words are computed from these; the buffers share
    /// the receive segment's tail is not done here: each slot owns its
    /// buffer inside one shared DMA segment.
    tx_phys: [TX_SLOTS]u32 = @splat(0),
    tx_buffer: [*][TX_BUFFER]u8 = undefined,

    /// Where the host reads next in the receive ring, derived from CAPR.
    rx_at: usize = 0,
    /// Which descriptor is up next, and which are still out on the wire.
    /// Tracked here rather than read back from TSD: the hardware's idea of
    /// "own" at reset is its own, and this process's is the truth it acts on.
    tx_at: usize = 0,
    pending: [TX_SLOTS]bool = @splat(false),
    dma_handle: ?u32 = null,
    started: bool = false,
};

var device: Device = .{};
var attached = false;

/// One DMA segment for receive ring, guard and the four transmit buffers.
const Arena = struct {
    rx: [RX_RING + RX_PAD + RX_WRAP_PAD]u8 align(4) = @splat(0),
    tx: [TX_SLOTS][TX_BUFFER]u8 align(4) = @splat(@splat(0)),
};

comptime {
    const largest_record = std.mem.alignForward(usize, @sizeOf(RxHeader) + ETH_MAX_FRAME + ETH_FCS, 4);
    if (RX_PAD + RX_WRAP_PAD < largest_record) @compileError("the receive spill area cannot hold a frame");
    if (@offsetOf(Arena, "tx") % 4 != 0) @compileError("transmit buffers must be dword aligned");
}

pub fn open(loc: pci.Location, dev: *NicDev) bool {
    if (attached) return false;

    const bar: pci.IoBar = @bitCast(pci.bar(loc, 0));
    if (!bar.io_space or bar.reserved) {
        log.fail("rtl8139", "BAR0 is not a valid I/O BAR");
        return false;
    }
    const base = bar.base();
    if (base == 0 or base > PORT_SPACE - IO_PORTS) {
        log.fail("rtl8139", "BAR0 is outside the x86 I/O port space");
        return false;
    }
    if (sys.ioportGrant(@intCast(base), IO_PORTS) < 0) {
        log.fail("rtl8139", "cannot reach its ports");
        return false;
    }
    pci.enableIoAndMaster(loc);
    var keep_pci_enabled = false;
    defer if (!keep_pci_enabled) pci.disableInterruptAndMaster(loc);
    device.window = .{ .base = @intCast(base) };

    if (!reset()) return false;
    readMac(dev);

    var phys: lib.Phys = .none;
    const handle = sys.dmaAlloc(@sizeOf(Arena), &phys);
    if (handle < 0) {
        log.failed("rtl8139", "cannot allocate DMA rings", handle);
        return false;
    }
    const dma_handle: u32 = @intCast(handle);
    if (phys.addr() % @alignOf(Arena) != 0) {
        _ = sys.close(dma_handle);
        log.fail("rtl8139", "DMA memory is not aligned for the adapter");
        return false;
    }
    const mapped = sys.shmMap(@intCast(handle), .{ .writable = true }) orelse {
        _ = sys.close(dma_handle);
        log.fail("rtl8139", "cannot map DMA rings");
        return false;
    };
    const arena: *Arena = @ptrCast(@alignCast(mapped));
    device.rx = @ptrCast(&arena.rx);
    // DMA memory is page-granular, which is every alignment this chip asks
    // for; adjusting the physical side alone would part it from the mapping.
    device.rx_phys = lib.Phys.of(phys.addr() + @offsetOf(Arena, "rx"));
    device.tx_buffer = @ptrCast(&arena.tx);
    inline for (0..TX_SLOTS) |i| {
        device.tx_phys[i] = phys.addr() + @offsetOf(Arena, "tx") + i * TX_BUFFER;
    }

    device.rx_at = 0;
    device.tx_at = 0;
    device.pending = @splat(false);
    device.dma_handle = dma_handle;
    device.started = false;

    attached = true;
    keep_pci_enabled = true;
    dev.state = link(dev);
    return true;
}

/// Reset includes the EEPROM autoload. The bit self-clears; a dead device is
/// refused after the same bounded ten milliseconds used by established 8139
/// drivers rather than being configured through an unfinished reset.
fn reset() bool {
    device.window.out16(.imr, 0);
    device.window.out8(.cmd, @bitCast(Cmd{ .reset = true }));
    for (0..RESET_ATTEMPTS) |_| {
        if (!@as(Cmd, @bitCast(device.window.in8(.cmd))).reset) return true;
        sys.sleepMicros(10);
    }
    log.fail("rtl8139", "reset did not complete");
    return false;
}

fn readMac(dev: *NicDev) void {
    // The IDR window: six bytes, and the auto-load wrote the EEPROM's own
    // word into them. A card with no EEPROM is zeroes, and rightly looks
    // like it has no story: nothing is invented.
    var mac: [6]u8 = @splat(0);
    for (0..6) |i| {
        mac[i] = ports.in8(device.window.base + @as(u16, @intCast(i)));
    }
    dev.mac = mac;
}

pub fn start(_: *NicDev) bool {
    if (!attached) return false;
    if (device.started) return true;

    device.window.out16(.imr, 0);
    const stale = device.window.in16(.isr);
    if (stale != std.math.maxInt(u16)) device.window.out16(.isr, stale);

    device.rx_at = 0;
    device.tx_at = 0;
    device.pending = @splat(false);
    device.window.out32(.rbstart, device.rx_phys.addr());
    inline for (0..TX_SLOTS) |i| {
        device.window.out32(txAddressRegister(i), device.tx_phys[i]);
    }

    // TCR only accepts its transfer settings while the transmitter is on.
    device.window.out8(.cmd, @bitCast(Cmd{ .tx_enable = true, .rx_enable = true }));
    device.window.out32(.rcr, @bitCast(RxUp));
    device.window.out32(.tcr, @bitCast(TxUp));

    const running = @as(Cmd, @bitCast(device.window.in8(.cmd)));
    if (!running.tx_enable or !running.rx_enable) {
        device.window.out8(.cmd, 0);
        log.fail("rtl8139", "receive/transmit engines did not start");
        return false;
    }

    const pending = device.window.in16(.isr);
    if (pending != std.math.maxInt(u16)) device.window.out16(.isr, pending);
    device.started = true;
    device.window.out16(.imr, @bitCast(EventsUp));
    return true;
}

pub fn stop(nic: *NicDev) void {
    if (!attached) return;

    // Mask first, then stop both DMA directions and wait until the ownership
    // handoff is visible before software forgets which TX buffers were live.
    device.window.out16(.imr, 0);
    device.window.out8(.cmd, 0);
    var stopped = false;
    for (0..RESET_ATTEMPTS) |_| {
        const command = @as(Cmd, @bitCast(device.window.in8(.cmd)));
        if (!command.tx_enable and !command.rx_enable) {
            stopped = true;
            break;
        }
        sys.sleepMicros(10);
    }
    if (!stopped) log.warn("rtl8139", "receive/transmit engines did not stop");
    dma.consume();

    const pending = device.window.in16(.isr);
    if (pending != std.math.maxInt(u16)) device.window.out16(.isr, pending);
    device.started = false;
    device.rx_at = 0;
    device.tx_at = 0;
    device.pending = @splat(false);
    pci.disableInterruptAndMaster(nic.location);
    if (device.dma_handle) |handle| _ = sys.close(handle);
    device.dma_handle = null;
    device.rx_phys = .none;
    device.tx_phys = @splat(0);
    attached = false;
    nic.state = .{};
}

pub fn irq(nic: *NicDev) bool {
    if (!device.started) return false;

    // Acknowledge each captured cause before draining it. A cause arriving
    // during the drain then remains latched and is handled by the next pass,
    // rather than being erased by a late write-one-to-clear acknowledgement.
    var serviced = false;
    for (0..IRQ_DRAIN_PASSES) |_| {
        const raw = device.window.in16(.isr);
        if (raw == 0 or raw == std.math.maxInt(u16)) break; // shared line or absent device
        const events = @as(Events, @bitCast(raw));
        if (!events.hasWork()) break;

        serviced = true;
        device.window.out16(.isr, raw);
        if (events.hasRx()) reapRx(nic);
        if (events.hasTx()) reapTx(nic);
    }
    return serviced;
}

fn reapRx(nic: *NicDev) void {
    const command = @as(Cmd, @bitCast(device.window.in8(.cmd)));
    if (command.buffer_empty) return;

    // CBR is only the end of the snapshot, not the next packet. Consume at
    // most that finite snapshot so a busy wire cannot make one IRQ unbounded.
    const write_at = @as(usize, device.window.in16(.cbr)) % RX_RING;
    var remaining = (write_at + RX_RING - device.rx_at) % RX_RING;
    if (remaining == 0) remaining = RX_RING; // BUFE distinguished full from empty
    dma.consume();

    while (remaining >= @sizeOf(RxHeader)) {
        const header_at = device.rx_at;
        const header = readRxHeader(header_at);
        if (header.length == RX_UNFINISHED) return;

        const wire_len = @as(usize, header.length);
        if (wire_len < ETH_FCS or wire_len > ETH_MAX_FRAME + ETH_FCS) {
            recoverRx(nic);
            return;
        }
        const record_len = std.mem.alignForward(usize, @sizeOf(RxHeader) + wire_len, 4);
        if (record_len > remaining) return; // the writer has not published the full frame yet

        const frame_len = wire_len - ETH_FCS;
        const frame_at = header_at + @sizeOf(RxHeader);
        var frame: [ETH_MAX_FRAME]u8 = undefined;
        if (header.good(frame_len)) {
            var got: usize = 0;
            while (got < frame_len) : (got += 1) frame[got] = device.rx[frame_at + got];
            dev_mod.deliverRx(nic, .{ .ok = true, .frame = frame[0..frame_len] });
        } else {
            dev_mod.deliverRx(nic, .{});
        }

        device.rx_at = (device.rx_at + record_len) % RX_RING;
        remaining -= record_len;
        // CAPR is sixteen bytes behind the actual consumer. Publishing before
        // the write ensures all CPU reads finish before the device may reuse it.
        dma.publish();
        device.window.out16(.capr, @truncate(device.rx_at -% 16));
    }
}

fn readRxHeader(at: usize) RxHeader {
    const low = rxWord(at);
    const high = rxWord(at + 2);
    return @bitCast(@as(u32, low) | (@as(u32, high) << 16));
}

/// One little-endian word from the ring, byte by byte: the ring is DMA
/// memory and every load must really happen, which is what keeps a plain
/// `readInt` out of this function.
fn rxWord(at: usize) u16 {
    const low: u16 = device.rx[at];
    const high: u16 = device.rx[at + 1];
    return low | (high << 8);
}

/// A malformed length loses packet boundaries. Reset only the receive side,
/// preserving a live transmitter, rather than walking attacker-controlled
/// offsets through the DMA arena.
fn recoverRx(nic: *NicDev) void {
    dev_mod.deliverRx(nic, .{});
    const command = @as(Cmd, @bitCast(device.window.in8(.cmd)));
    device.window.out8(.cmd, @bitCast(Cmd{ .tx_enable = command.tx_enable }));
    device.rx_at = 0;
    device.window.out32(.rbstart, device.rx_phys.addr());
    device.window.out8(.cmd, @bitCast(Cmd{
        .tx_enable = command.tx_enable,
        .rx_enable = command.rx_enable,
    }));
    device.window.out32(.rcr, @bitCast(RxUp));
}

fn txStatusRegister(slot: usize) R {
    return @enumFromInt(@intFromEnum(R.tsd0) + slot * @sizeOf(u32));
}

fn txAddressRegister(slot: usize) R {
    return @enumFromInt(@intFromEnum(R.tsad0) + slot * @sizeOf(u32));
}

fn reapTx(nic: *NicDev) void {
    // OWN is the device-to-host handoff. Once observed, acquire before the
    // corresponding bounce buffer can be overwritten by a later transmit.
    for (0..TX_SLOTS) |i| {
        if (!device.pending[i]) continue;
        const status: TxStatus = @bitCast(device.window.in32(txStatusRegister(i)));
        if (!status.host_owns) continue;
        dma.consume();
        device.pending[i] = false;
        if (status.failed()) nic.stats.tx_failed += 1;
    }
}

pub fn transmit(nic: *NicDev, frame: []const u8) bool {
    if (!device.started or frame.len < ETH_HEADER or frame.len > ETH_MAX_FRAME) {
        nic.stats.tx_failed += 1;
        return false;
    }

    // Reclaim completed slots even if their interrupt was coalesced or lost.
    reapTx(nic);

    const slot = device.tx_at;
    if (device.pending[slot]) {
        nic.stats.tx_failed += 1;
        return false;
    }
    const status: TxStatus = @bitCast(device.window.in32(txStatusRegister(slot)));
    if (!status.host_owns) {
        nic.stats.tx_failed += 1;
        return false;
    }
    dma.consume();

    // This chip pads nothing: a frame below the ethernet minimum leaves as
    // a runt and every receiver on a real wire discards it.
    const wired = @max(frame.len, ETH_MIN_FRAME);
    @memcpy(device.tx_buffer[slot][0..frame.len], frame);
    if (frame.len < wired) @memset(device.tx_buffer[slot][frame.len..wired], 0);
    device.window.out32(txAddressRegister(slot), device.tx_phys[slot]);
    device.pending[slot] = true;

    // The TSD write is the ownership handoff and transmission trigger.
    dma.publish();
    device.window.out32(txStatusRegister(slot), @bitCast(TxStatus{
        .size = @intCast(wired),
        .early_threshold = 8, // 8 * 32 bytes: the established 256-byte threshold
    }));
    device.tx_at = (slot + 1) % TX_SLOTS;

    dev_mod.deliverTx(nic, frame.len);
    return true;
}

pub fn link(_: *NicDev) dev_mod.Link {
    // The 8139 has no link status register worth the name: media detection
    // lives in the mii-plus family. It is reported up at the speed the chip
    // is, which is the honest answer available.
    return .{ .up = true, .mbps = 100, .duplex = .full };
}

/// Who this driver is, for the probe table and the interface listing.
pub const name = "rtl8139";
pub const vendor = 0x10EC;
pub const device_id = 0x8139;
pub const ops: dev_mod.NicOps = .{
    .open = open,
    .start = start,
    .stop = stop,
    .irq = irq,
    .transmit = transmit,
    .link = link,
};
