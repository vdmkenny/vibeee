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
const mii = @import("mii.zig");
const ring = @import("ring.zig");
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
    /// The chip's own account of the medium: carrier and speed, in bits
    /// the datasheet names. No duplex here, and no MDIO either: the 8139
    /// puts its PHY's standard registers in the port window, so asking the
    /// wire about itself is a port read and not a bit-banged frame.
    media_status = 0x58,
    /// The PHY's basic status word (MII register 1), mapped into the port
    /// window at this offset.
    basic_mode_status = 0x64,
};

/// A whole register file lives behind one port pair: the base port is
/// granted once for the entire driver, and every access is a typed offset
/// from it.
///
/// Port I/O, not a memory window, and deliberately not `lib.mmio.Window`:
/// this part is reached with `in`/`out` on real hardware and on every
/// emulator that bothers, so nothing here is ever a load from a mapped
/// BAR and the two must not be unified.
const Ports = struct {
    base: u16,

    fn out8(self: Ports, r: R, value: u8) void {
        ports.out8(self.base + @intFromEnum(r), value);
    }

    fn in8(self: Ports, r: R) u8 {
        return ports.in8(self.base + @intFromEnum(r));
    }

    fn out16(self: Ports, r: R, value: u16) void {
        ports.out16(self.base + @intFromEnum(r), value);
    }

    fn in16(self: Ports, r: R) u16 {
        return ports.in16(self.base + @intFromEnum(r));
    }

    fn out32(self: Ports, r: R, value: u32) void {
        ports.out32(self.base + @intFromEnum(r), value);
    }

    fn in32(self: Ports, r: R) u32 {
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
        return self.rx_ok or self.rx_error or self.rx_overflow;
    }

    /// A receive FIFO overflow is not traffic to drain. The receiver has
    /// lost count of how much of the frame in flight it wrote, so the
    /// boundary between records is gone and every length read from here
    /// on is a guess: it takes the reset path, not the drain.
    fn losesSync(self: Events) bool {
        return self.rx_fifo_overflow;
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

/// Media Status (0x58): what the chip makes of the wire, in its own bits.
///
/// The carrier bit is inverted with respect to how a link is spoken of: it
/// is *set* while there is no carrier, so a part that has never seen a wire
/// and one holding a live one differ in one bit and the rest is decoration.
const MediaStatus = packed struct(u8) {
    tx_pause: bool = false,
    rx_pause: bool = false,
    link_fail: bool = false,
    /// Ten megabits. Clear means a hundred, the only other rate this part
    /// runs at and so the only other reading.
    speed_10: bool = false,
    _4: u2 = 0,
    rx_flow_enable: bool = false,
    tx_flow_enable: bool = false,
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
    if (@sizeOf(MediaStatus) != 1) @compileError("the media status register is one byte");
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
const ETH_HEADER = lib.eth.HEADER;
const ETH_MIN_FRAME = 60;
const ETH_MAX_FRAME = 1518;
const ETH_FCS = 4;
const RX_UNFINISHED = 0xFFF0;
/// The longest record the receive area can hold whole: the ring, its pad
/// and its no-wrap spill, which is as far as the chip may write one
/// contiguous record. A length past this was not written anywhere this
/// driver can read, so what the read pointer would land on is not the
/// next record's header and the ring has to be rebuilt.
const RX_MAX_RECORD = RX_RING + RX_PAD + RX_WRAP_PAD;
const IO_PORTS = 0x100;
const PORT_SPACE: u32 = @as(u32, 1) << @bitSizeOf(u16);
const RESET_ATTEMPTS = 1000;

/// What the receiver takes: frames addressed to this station, which it
/// matches against IDR0-5, and broadcasts.
///
/// Accept-all-physical is deliberately off. Taking every frame on the
/// segment hands the stack everybody else's traffic, which on a shared
/// wire is most of what passes and on a switched one is nothing at all;
/// the cost is paid twice, once copying it and once above, deciding it
/// was never ours. The address filter is the hardware doing its job.
const RxUp = RxConfig{
    .physical_match = true,
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
    ports: Ports = .{ .base = 0 },
    /// The one segment of device memory this adapter is ever given: receive
    /// ring, guard and spill, and the four transmit buffers. Held as an
    /// arena -- mapping and handle together -- because a handle closed
    /// under a live mapping frees nothing, and a mapping nobody remembers
    /// is a leak in a band handed out by a linear scan.
    arena: dma.Arena(Rings) = .{},
    /// Where the device was told the ring and the transmit buffers are.
    rx_phys: lib.Phys = .none,
    tx_phys: [TX_SLOTS]u32 = @splat(0),

    /// Where the host reads next in the receive ring, derived from CAPR.
    rx_at: ring.Cursor(RX_RING) = .{},
    /// Which descriptor is up next, and which are still out on the wire.
    /// Tracked here rather than read back from TSD: the hardware's idea of
    /// "own" at reset is its own, and this process's is the truth it acts on.
    tx_at: ring.Cursor(TX_SLOTS) = .{},
    pending: [TX_SLOTS]bool = @splat(false),
    started: bool = false,
};

var device: Device = .{};
var attached = false;

/// The receive ring, read the way it has to be: the chip is writing into it
/// while this code walks it, so every load must really happen, which is a
/// plain array read does not promise.
fn rxArea() *volatile [RX_RING + RX_PAD + RX_WRAP_PAD]u8 {
    return @ptrCast(&device.arena.body().rx);
}

/// What one DMA segment holds: the receive ring with its guard and spill,
/// and the four transmit buffers behind it.
const Rings = struct {
    rx: [RX_RING + RX_PAD + RX_WRAP_PAD]u8 align(4) = @splat(0),
    tx: [TX_SLOTS][TX_BUFFER]u8 align(4) = @splat(@splat(0)),
};

comptime {
    const largest_record = std.mem.alignForward(usize, @sizeOf(RxHeader) + ETH_MAX_FRAME + ETH_FCS, 4);
    if (RX_PAD + RX_WRAP_PAD < largest_record) @compileError("the receive spill area cannot hold a frame");
    if (@offsetOf(Rings, "tx") % 4 != 0) @compileError("transmit buffers must be dword aligned");
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
    sys.ioportGrant(@intCast(base), IO_PORTS) catch {
        log.fail("rtl8139", "cannot reach its ports");
        return false;
    };
    pci.enableIoAndMaster(loc);
    var keep_pci_enabled = false;
    defer if (!keep_pci_enabled) pci.disableInterruptAndMaster(loc);
    device.ports = .{ .base = @intCast(base) };

    if (!reset()) return false;
    if (!readMac(dev)) {
        log.fail("rtl8139", "cannot read a valid MAC address");
        return false;
    }

    device.arena = dma.Arena(Rings).acquire() catch |why| {
        // The arena's own three answers, said in this driver's words: a
        // refusal carries no errno to name, and "cannot allocate" loses
        // the one thing worth knowing, which is why not.
        log.fail("rtl8139", switch (why) {
            error.NoMemory => "no device memory left for the rings",
            error.Misaligned => "device memory is not aligned for the adapter",
            error.Unmappable => "cannot map the rings into this process",
        });
        return false;
    };
    // DMA memory is page-granular, which is every alignment this chip asks
    // for; adjusting the physical side alone would part it from the mapping.
    device.rx_phys = device.arena.physOf(@offsetOf(Rings, "rx")) orelse return refuseArena();
    inline for (0..TX_SLOTS) |i| {
        const at = @offsetOf(Rings, "tx") + i * TX_BUFFER;
        device.tx_phys[i] = (device.arena.physOf(at) orelse return refuseArena()).addr();
    }

    device.rx_at = .{};
    device.tx_at = .{};
    device.pending = @splat(false);
    device.started = false;

    // Attached before the link is asked for: the ports are granted and the
    // adapter is out of reset, so what the PHY says now is a real answer,
    // and an interface that came up on a wire with nothing on the far end
    // of it should say so from the first report.
    attached = true;
    keep_pci_enabled = true;
    dev_mod.deliverLink(dev, link(dev));
    return true;
}

/// Give the segment back and go no further: an offset inside it that cannot
/// be named to the device is a segment no register can be programmed from,
/// and the alternative is a DMA address of zero written where a ring was.
fn refuseArena() bool {
    device.arena.release();
    log.fail("rtl8139", "the DMA segment does not fit the adapter's addressing");
    return false;
}

/// Reset includes the EEPROM autoload. The bit self-clears; a dead device is
/// refused after the same bounded ten milliseconds used by established 8139
/// drivers rather than being configured through an unfinished reset.
fn reset() bool {
    device.ports.out16(.imr, 0);
    device.ports.out8(.cmd, @bitCast(Cmd{ .reset = true }));
    for (0..RESET_ATTEMPTS) |_| {
        if (!@as(Cmd, @bitCast(device.ports.in8(.cmd))).reset) return true;
        sys.sleepMicros(10);
    }
    log.fail("rtl8139", "reset did not complete");
    return false;
}

/// The IDR window: six bytes, and the auto-load wrote the EEPROM's own
/// word into them. A card with no EEPROM is zeroes, which is not an
/// address, so it is refused rather than invented: an interface brought
/// up answering for nothing sends frames no filter can match and nothing
/// can answer.
fn readMac(dev: *NicDev) bool {
    var mac: [6]u8 = @splat(0);
    for (&mac, 0..) |*octet, i| {
        octet.* = ports.in8(device.ports.base + @as(u16, @intCast(i)));
    }
    if (!dev_mod.validMac(mac)) return false;
    dev.mac = mac;
    return true;
}

pub fn start(_: *NicDev) bool {
    if (!attached) return false;
    if (device.started) return true;

    device.ports.out16(.imr, 0);
    const stale = device.ports.in16(.isr);
    if (stale != std.math.maxInt(u16)) device.ports.out16(.isr, stale);

    device.rx_at = .{};
    device.tx_at = .{};
    device.pending = @splat(false);
    device.ports.out32(.rbstart, device.rx_phys.addr());
    inline for (0..TX_SLOTS) |i| {
        device.ports.out32(txAddressRegister(i), device.tx_phys[i]);
    }

    // TCR only accepts its transfer settings while the transmitter is on.
    device.ports.out8(.cmd, @bitCast(Cmd{ .tx_enable = true, .rx_enable = true }));
    device.ports.out32(.rcr, @bitCast(RxUp));
    device.ports.out32(.tcr, @bitCast(TxUp));

    const running = @as(Cmd, @bitCast(device.ports.in8(.cmd)));
    if (!running.tx_enable or !running.rx_enable) {
        device.ports.out8(.cmd, 0);
        log.fail("rtl8139", "receive/transmit engines did not start");
        return false;
    }

    const pending = device.ports.in16(.isr);
    if (pending != std.math.maxInt(u16)) device.ports.out16(.isr, pending);
    device.started = true;
    device.ports.out16(.imr, @bitCast(EventsUp));
    return true;
}

pub fn stop(nic: *NicDev) void {
    if (!attached) return;

    // Mask first, then stop both DMA directions and wait until the ownership
    // handoff is visible before software forgets which TX buffers were live.
    device.ports.out16(.imr, 0);
    device.ports.out8(.cmd, 0);
    var stopped = false;
    for (0..RESET_ATTEMPTS) |_| {
        const command = @as(Cmd, @bitCast(device.ports.in8(.cmd)));
        if (!command.tx_enable and !command.rx_enable) {
            stopped = true;
            break;
        }
        sys.sleepMicros(10);
    }
    if (!stopped) log.warn("rtl8139", "receive/transmit engines did not stop");
    dma.consume();

    const pending = device.ports.in16(.isr);
    if (pending != std.math.maxInt(u16)) device.ports.out16(.isr, pending);
    device.started = false;
    device.rx_at = .{};
    device.tx_at = .{};
    device.pending = @splat(false);

    // Clear every register that names the arena before the arena is
    // handed back. The engines are off, but a receiver restarted by
    // anything else fetches from where RBSTART still points, and the
    // address it holds is about to belong to somebody else: that is a
    // DMA write into whatever gets it next.
    device.ports.out32(.rbstart, 0);
    inline for (0..TX_SLOTS) |i| device.ports.out32(txAddressRegister(i), 0);
    device.ports.out16(.capr, 0);
    _ = device.ports.in8(.cmd); // flush the posted writes

    // Last of all: the adapter has no address left to fetch from, so the
    // segment is the process's alone and may be unmapped and closed. Any
    // earlier and a bus master that had not quite stopped writes into
    // whatever gets this memory next.
    pci.disableInterruptAndMaster(nic.location);
    device.arena.release();
    device.rx_phys = .none;
    device.tx_phys = @splat(0);
    attached = false;
    dev_mod.deliverLink(nic, .{});
}

pub fn irq(nic: *NicDev) bool {
    return dev_mod.serveIrq(@This(), nic);
}

/// What the adapter has latched, as the shared interrupt pass wants it:
/// zero for nothing, and otherwise the interrupt status word itself, which
/// is also what clears it and what `service` is handed back.
pub fn cause() u32 {
    if (!device.started) return 0;
    const raw = device.ports.in16(.isr);
    // Every bit set is what a read of nothing looks like: a shared line
    // driven by somebody else, or no adapter behind these ports at all.
    if (raw == 0 or raw == std.math.maxInt(u16)) return 0;
    const events = @as(Events, @bitCast(raw));
    return if (events.hasWork()) @as(u32, raw) else 0;
}

/// Clear what this pass captured, and hold or release the line around the
/// work done for it.
///
/// The clear comes first, as it did before this was three functions: a
/// cause arriving during the drain stays latched and is handled by the next
/// round, rather than being erased by a late write-one-to-clear. The mask
/// is what holds the line, on a level-triggered one, between the clear and
/// the end of the work it asked for.
///
/// `held` reaches here in two shapes -- a boolean while the pass holds the
/// line, a zero once it lets it go -- and both mean the one thing this
/// driver needs from it.
pub fn acknowledge(latched: u32, held: bool) void {
    const holding: bool = if (@TypeOf(held) == bool) held else held != 0;
    device.ports.out16(.isr, @truncate(latched));
    device.ports.out16(.imr, if (holding) 0 else @bitCast(EventsUp));
}

pub fn service(latched: u32, nic: *NicDev) void {
    const events = @as(Events, @bitCast(@as(u16, @truncate(latched))));
    if (events.losesSync()) {
        // TODO: this belongs in the `service` op, not on the line. A
        // receiver that has lost sync waits for the frame in flight to
        // finish -- up to ten milliseconds of `sleepMicros` here -- and an
        // interrupt handler that waits on the part holds the line and
        // every neighbour sharing it for as long. It stays because moving
        // it means deferring the reset to the loop, which is a change in
        // when the ring is rebuilt and not one this pass should make
        // silently.
        recoverRx(nic);
    } else if (events.hasRx()) {
        reapRx(nic);
    }
    if (events.hasTx()) reapTx(nic);
}

/// Service the adapter with no interrupt behind it: a line the firmware
/// routed nowhere, or an edge this service never saw. Draining the ring
/// and the four transmit slots is all an interrupt would have asked for.
pub fn poll(nic: *NicDev) bool {
    if (!device.started) return false;
    reapRx(nic);
    reapTx(nic);
    return true;
}

fn reapRx(nic: *NicDev) void {
    const command = @as(Cmd, @bitCast(device.ports.in8(.cmd)));
    if (command.buffer_empty) return;

    // CBR is only the end of the snapshot, not the next packet. Consume at
    // most that finite snapshot so a busy wire cannot make one IRQ unbounded.
    const write_at = ring.wrapped(@as(usize, device.ports.in16(.cbr)), RX_RING);
    var remaining = ring.usedBetween(write_at, device.rx_at.at, RX_RING);
    if (remaining == 0) remaining = RX_RING; // BUFE distinguished full from empty
    dma.consume();

    while (remaining >= @sizeOf(RxHeader)) {
        const header_at = device.rx_at.at;
        const header = readRxHeader(header_at);
        if (header.length == RX_UNFINISHED) return;

        const wire_len = @as(usize, header.length);
        // Only a length that makes the record boundary unknowable earns
        // the reset. Too short to hold the check sequence means there is
        // no frame length to subtract it from, and longer than the ring
        // and its spill together means what the hardware wrote is not
        // what this pointer would read; either way the next record is not
        // at `rx_at + record`, and walking there is a tour of the arena
        // chosen by whoever sent the frame.
        if (wire_len < ETH_FCS or @sizeOf(RxHeader) + wire_len > RX_MAX_RECORD) {
            recoverRx(nic);
            return;
        }
        const record_len = std.mem.alignForward(usize, @sizeOf(RxHeader) + wire_len, 4);
        if (record_len > remaining) return; // the writer has not published the full frame yet

        // Anything else is a frame this pass can step over, however wrong
        // it is on the wire: an oversized one fails `good` below, counts
        // as a drop and is left behind, and the ring keeps going. A
        // length between the 1518 a large frame may be and a few
        // kilobytes arrives with a clean status often enough that taking
        // the receiver down for it threw away everything in the ring too.
        const frame_len = wire_len - ETH_FCS;
        const frame_at = header_at + @sizeOf(RxHeader);
        var frame: [ETH_MAX_FRAME]u8 = undefined;
        if (header.good(frame_len)) {
            const area = rxArea();
            for (0..frame_len) |got| frame[got] = area[frame_at + got];
            dev_mod.deliverRx(nic, .{ .ok = true, .frame = frame[0..frame_len] });
        } else {
            dev_mod.deliverRx(nic, .{});
        }

        device.rx_at.advance(record_len);
        remaining -= record_len;
        // CAPR is sixteen bytes behind the actual consumer. Publishing before
        // the write ensures all CPU reads finish before the device may reuse it.
        dma.publish();
        device.ports.out16(.capr, @truncate(device.rx_at.at -% 16));
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
    const area = rxArea();
    const low: u16 = area[at];
    const high: u16 = area[at + 1];
    return low | (high << 8);
}

/// A malformed length loses packet boundaries. Reset only the receive side,
/// preserving a live transmitter, rather than walking attacker-controlled
/// offsets through the DMA arena.
fn recoverRx(nic: *NicDev) void {
    dev_mod.deliverRx(nic, .{});
    const command = @as(Cmd, @bitCast(device.ports.in8(.cmd)));
    device.ports.out8(.cmd, @bitCast(Cmd{ .tx_enable = command.tx_enable }));

    // The receiver does not stop the instant the write retires: the frame
    // in flight finishes first. Read the command back until it says so,
    // and give it time, before the ring's addresses are moved under it.
    var off = false;
    for (0..RESET_ATTEMPTS) |_| {
        if (!@as(Cmd, @bitCast(device.ports.in8(.cmd))).rx_enable) {
            off = true;
            break;
        }
        sys.sleepMicros(10);
    }
    if (!off) log.warn("rtl8139", "the receiver did not stop for its reset");

    device.rx_at = .{};
    device.ports.out32(.rbstart, device.rx_phys.addr());
    // CAPR is the hardware's own account of where the host has read to,
    // and reprogramming it is what made this a reset: with RBSTART back
    // at zero and CAPR left where it was, the two disagree and the
    // receiver fetches from one while the host drains the other.
    device.ports.out16(.capr, @truncate(device.rx_at.at -% 16));
    device.ports.out8(.cmd, @bitCast(Cmd{
        .tx_enable = command.tx_enable,
        .rx_enable = command.rx_enable,
    }));
    device.ports.out32(.rcr, @bitCast(RxUp));
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
    for (&device.pending, 0..) |*pending, i| {
        if (!pending.*) continue;
        const status: TxStatus = @bitCast(device.ports.in32(txStatusRegister(i)));
        if (!status.host_owns) continue;
        dma.consume();
        pending.* = false;
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

    const slot = device.tx_at.at;
    if (device.pending[slot]) {
        nic.stats.tx_failed += 1;
        return false;
    }
    const status: TxStatus = @bitCast(device.ports.in32(txStatusRegister(slot)));
    if (!status.host_owns) {
        nic.stats.tx_failed += 1;
        return false;
    }
    dma.consume();

    // This chip pads nothing, so what it is handed must already be a whole
    // frame: `dev.send` sees to that for every wire driver, and a frame
    // below the ethernet minimum would leave here as a runt, which every
    // receiver on a real wire discards.
    @memcpy(device.arena.body().tx[slot][0..frame.len], frame);
    device.ports.out32(txAddressRegister(slot), device.tx_phys[slot]);
    device.pending[slot] = true;

    // The TSD write is the ownership handoff and transmission trigger.
    dma.publish();
    device.ports.out32(txStatusRegister(slot), @bitCast(TxStatus{
        .size = @intCast(frame.len),
        .early_threshold = 8, // 8 * 32 bytes: the established 256-byte threshold
    }));
    device.tx_at.next();

    dev_mod.deliverTx(nic, frame.len);
    return true;
}

pub fn link(_: *NicDev) dev_mod.Link {
    if (!attached) return .{};

    // The 8139 keeps its PHY's basic status word in the port window, at
    // 0x64, so the standard's register is a port read here and not an MDIO
    // frame: this driver has no bit-banged MDIO to do it with and does not
    // need one. What the standard says about that word is `mii`'s answer,
    // not this driver's.
    const status: mii.Status = @bitCast(device.ports.in16(.basic_mode_status));
    const carrier = mii.outcome(status) orelse return .{};

    // Speed is the chip's own bit in its media status register: ten if it
    // is set, a hundred if not, the only two rates this part runs at. The
    // same register says carrier again, the other way round, and a part
    // that disagrees with its own PHY is not one to answer for.
    //
    // Duplex is the one thing neither register carries. Resolving it means
    // comparing what was advertised with what the partner answered, which
    // is a conversation in MII registers this driver has no way to hold;
    // it is left unknown rather than assumed full, because a half-duplex
    // wire called full is a link that loses frames with both ends certain
    // they are right.
    const media: MediaStatus = @bitCast(device.ports.in8(.media_status));
    if (media.link_fail) return .{};
    return .{
        .up = carrier.up,
        .mbps = if (media.speed_10) 10 else 100,
    };
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
    .poll = poll,
    .transmit = transmit,
    .link = link,
};
