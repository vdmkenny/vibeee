//! Realtek RTL8139 10/100 ethernet: what QEMU offers besides the e1000, and
//! a card a very wide slice of old hardware actually carries, which is what
//! earns it a place in a "generic netbook" build. Facts from the Realtek
//! RTL8139(C) programmer's guide and Linux's 8139too.c, consulted; this code
//! is written from scratch in this system's shapes.
//!
//! The register file is sixteen windows of bytes or words behind an I/O BAR,
//! like the chip was designed in a later year than it was. Packed structs
//! for every register, a 32 KiB receive ring plus its sixteen-byte overrun
//! guard in one DMA segment, four transmit descriptors with the FIFO-era
//! empty semantics this chip was never given, and no polling: everything
//! steers from the interrupt handler.

const dev_mod = @import("dev.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const ports = @import("ulib").ports;
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
    mp_poll = 0xD2,
    imr = 0x3C,
    isr = 0x3E,
    rcr = 0x44,
    config9346 = 0x50,
    tp_poll = 0xD0,
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
    rx_ovw: bool = false,
    pkt_underrun: bool = false,
    fifo_ovw: bool = false,
    tx_empty: bool = false,
    _8: u7 = 0,
    serr: bool = false,

    fn none(self: Events) bool {
        return @as(u16, @bitCast(self)) == 0;
    }
};

/// RCR: what a receive is.
const RxConfig = packed struct(u32) {
    accept_physical: bool = false,
    accept_broadcast: bool = false,
    accept_multicast: bool = false,
    physical_match: bool = false,
    accept_runt: bool = false,
    rx_error_acos: bool = false,
    rx_crc_error: bool = false,
    /// WRAP: the ring wraps at the receive buffer size.
    wrap: bool = false,
    _8: u4 = 0,
    /// Buffer size: 0 = 8 KiB, 1 = 16, 2 = 32, 3 = 64.
    buffer_len: u2 = 0,
    _14: u2 = 0,
    /// Early receive threshold.
    rx_thresh: u8 = 0,
    _24: u8 = 0,
};

/// TSD: one transmit descriptor made of a length and an owner bit.
/// The 8139's convention is the doc's own: OWN set means the host owns the
/// descriptor and the hardware must not touch it, and the hardware transmits
/// exactly when it sees the host drop OWN, then raises it again on
/// completion.
const TxDesc = packed struct(u16) {
    size: u13 = 0,
    own: bool = false,
    _14: u1 = 0,
    /// TUN: underrun, set by the hardware on failure.
    underrun: bool = false,
};

/// The two words ahead of every received frame: status, then length.
const RxStatus = packed struct(u16) {
    ok: bool = false,
    frame_align: bool = false,
    crc_error: bool = false,
    long_frame: bool = false,
    runt_frame: bool = false,
    _5: u11 = 0,
};

const EventsUp = Events{
    .rx_ok = true,
    .rx_error = true,
    .rx_ovw = true,
    .tx_ok = true,
    .tx_error = true,
    .pkt_underrun = true,
    .fifo_ovw = true,
    .tx_empty = true,
};

comptime {
    if (@sizeOf(Events) != 2 or @sizeOf(TxDesc) != 2) @compileError("an event or descriptor word is a word");
    if (@sizeOf(RxConfig) != 4) @compileError("the receive config is one dword");
    if (@sizeOf(RxStatus) != 2) @compileError("a receive status is one word");
}

// ---------------------------------------------------------------------------
// The rings
// ---------------------------------------------------------------------------

/// The ring is the whole window the chip addresses: its CAPR and CBR fields
/// are sixteen-bit word offsets that wrap at 64 KiB, and the buffer behind
/// RBSTART has to be exactly that window plus the overrun guard.
const RX_WINDOW = 64 * 1024;
const RX_RING = RX_WINDOW;
const RX_GUARD = 16;
const TX_SLOTS = 4;

const Device = struct {
    window: Window = .{ .base = 0 },
    /// Receive ring + guard in one DMAR run.
    rx: [*]u8 = undefined,
    rx_phys: u32 = 0,
    /// Transmit descriptor words are computed from these; the buffers share
    /// the receive segment's tail is not done here: each slot owns its
    /// buffer inside one shared DMA segment.
    tx_phys: [TX_SLOTS]u32 = @splat(0),
    tx_buffer: [*][2048]u8 = undefined,

    /// Where the host reads next in the receive ring, derived from CAPR.
    rx_at: u32 = 0,
    /// Which descriptor is up next, and which are still out on the wire.
    /// Tracked here rather than read back from TSD: the hardware's idea of
    /// "own" at reset is its own, and this process's is the truth it acts on.
    tx_at: u8 = 0,
    pending: [TX_SLOTS]bool = @splat(false),
};

var device: Device = .{};
var attached = false;

/// One DMA segment for receive ring, guard and the four transmit buffers.
const Arena = struct {
    rx: [RX_RING + RX_GUARD]u8 = @splat(0),
    tx: [TX_SLOTS][2048]u8 = @splat(@splat(0)),
};

pub fn open(loc: pci.Location, dev: *NicDev) bool {
    if (attached) return false;

    // The I/O BAR: the 8139 lives behind ports, and the base is the address
    // with its type bits off.
    const bar = pci.bar(loc, 0);
    if (bar & 1 == 0) {
        log.fail("rtl8139", "this card answers memory, which is not driven yet");
        return false;
    }
    if (sys.ioportGrant(@truncate((bar & ~@as(u32, 3)) & 0xFFFF), 0x100) < 0) {
        log.fail("rtl8139", "cannot reach its ports");
        return false;
    }
    pci.enableMemoryAndMaster(loc);
    device.window = .{ .base = @truncate((bar & ~@as(u32, 3)) & 0xFFFF) };

    var phys: u32 = 0;
    const handle = sys.dmaAlloc(@sizeOf(Arena) + 16, &phys);
    if (handle < 0) {
        log.failed("rtl8139", "cannot allocate DMA rings", handle);
        return false;
    }
    const mapped = sys.shmMap(@intCast(handle), .{ .writable = true }) orelse {
        log.fail("rtl8139", "cannot map DMA rings");
        return false;
    };
    const arena: *Arena = @alignCast(@ptrCast(mapped));
    device.rx = @ptrCast(&arena.rx);
    // DMA memory is page-granular, which is every alignment this chip asks
    // for; adjusting the physical side alone would part it from the mapping.
    device.rx_phys = phys + @offsetOf(Arena, "rx");
    device.tx_buffer = @ptrCast(&arena.tx);
    inline for (0..TX_SLOTS) |i| {
        device.tx_phys[i] = phys + @offsetOf(Arena, "tx") + i * 2048;
    }

    // Reset the card, then let the EEPROM's auto-load put the permanent MAC
    // into the IDR window where this driver reads it.
    device.window.out8(.cmd, @bitCast(Cmd{ .reset = true }));
    sys.sleepMicros(10_000);
    device.window.out16(.config9346, 0xC0); // EEM1 | EEM0: auto-load
    device.window.out8(.cmd, 0);
    sys.sleepMicros(1_000);
    readMac(dev);

    // Receive: everything through, ring of 32 KiB. The buffer length bits
    // are the chip's own 2-bit size field: 2 means 32 KiB.
    device.window.out32(.rbstart, device.rx_phys);
    // No overflow past the end: with WRAP off the chip splits a frame at
    // the boundary instead of running into the guard, and the reader below
    // already reads everything modulo the ring.
    device.window.out32(.rcr, @bitCast(RxConfig{
        .accept_physical = true,
        .accept_broadcast = true,
        .accept_multicast = true,
        .physical_match = true,
        .buffer_len = 3, // the 64 KiB the offsets wrap at
    }));

    // Transmit: silence the FIFO-era thresholds this chip never grew out of.
    ports.out32(device.window.base + 0x40, 0x03000700); // TCR: IFG defaults
    ports.out32(device.window.base + 0xD8, 0x00007000); // early TX don't

    // Interrupts on, engine off until start: everything a start does is
    // begin the two engines at once.
    device.window.out16(.imr, @bitCast(EventsUp));
    device.rx_at = 0;
    device.tx_at = 0;

    attached = true;
    dev.state = link(dev);
    return true;
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
    // Both engines in one byte: receive, transmit and the FIFO flag begin
    // together.
    device.window.out8(.cmd, @bitCast(Cmd{
        .buffer_empty = true,
        .tx_enable = true,
        .rx_enable = true,
    }));
    return true;
}

pub fn stop(_: *NicDev) void {
    device.window.out8(.cmd, 0);
}

pub fn irq(nic: *NicDev) void {
    const events = @as(Events, @bitCast(device.window.in16(.isr)));
    if (events.none()) return; // a shared line, not ours

    // Written back to clear; this chip wants its polls strobed too.
    device.window.out16(.isr, @bitCast(events));
    // The 8139 releases each direction through its own poll register;
    // stroking both is what lowers the line and ends the interrupt.
    if (events.tx_ok or events.tx_error) device.window.out16(.tp_poll, 0x0000);
    if (events.rx_ok or events.rx_error or events.rx_ovw or events.fifo_ovw) {
        device.window.out16(.mp_poll, 0x0000);
    }

    if (events.rx_ok or events.rx_ovw) reapRx(nic);
    if (events.tx_ok or events.tx_error) reapTx(nic);
}

fn reapRx(nic: *NicDev) void {
    while (true) {
        // The ring reads forward from where the host left off: at the read
        // pointer sits the next frame's header, then the frame bytes, then
        // the checksum tail. The handshake runs in bytes and in opposite
        // directions: the write side is read back from CBR, and
        // acknowledging is CAPR written.
        const next_write = @as(u32, device.window.in16(.cbr));
        if (next_write == device.rx_at) break;

        const header_at = device.rx_at % RX_RING;
        const len = ringWord(header_at + 2);
        const status = @as(RxStatus, @bitCast(ringWord(header_at)));

        // The length names frame and checksum together; the frame is the
        // part this service keeps, so it is the part counted.
        const frame_len = len -| 4;
        const frame_at = (device.rx_at + 4) % RX_RING;
        // The minimum here is what makes a frame: two addresses and an
        // EtherType. A 42-byte ARP reply is short, and short is legal; it
        // is the TX path that pads.
        const good = status.ok and !status.crc_error and !status.long_frame and
            frame_len >= 14 and frame_len <= 1518;

        var frame: [2048]u8 = undefined;
        if (good) {
            var got: usize = 0;
            while (got < frame_len) : (got += 1) frame[got] = device.rx[(frame_at + got) % RX_RING];
            dev_mod.deliverRx(nic, .{ .ok = true, .frame = frame[0..frame_len] });
        } else {
            dev_mod.deliverRx(nic, .{});
        }

        device.rx_at = next_write;
        // Sixteen back, by the chip's own convention: CAPR reads ahead of
        // itself by the header it has already consumed, and a raw offset
        // here tells it the host has read sixteen bytes it has not.
        device.window.out16(.capr, @truncate(next_write -% 16));
    }
}

fn ringWord(at: u32) u16 {
    return @as(u16, device.rx[at % RX_RING]) | (@as(u16, device.rx[(at + 1) % RX_RING]) << 8);
}

/// The one way a transmit descriptor is spelled into the window: the
/// hardware reads the low word, and the width it answers is a dword.
fn tsdWord(size: u13, own: bool) u32 {
    const desc = TxDesc{ .size = size, .own = own };
    return @as(u32, @intCast(@as(u16, @bitCast(desc))));
}

fn reapTx(nic: *NicDev) void {
    // Which descriptors came back: a pending slot the hardware took back by
    // raising OWN again is done, and the outcome is the underrun bit.
    for (0..TX_SLOTS) |i| {
        if (!device.pending[i]) continue;
        const at: R = @enumFromInt(@intFromEnum(R.tsd0) + i * 4);
        const desc: TxDesc = @bitCast(@as(u16, @truncate(device.window.in32(at))));
        if (!desc.own) continue;
        device.pending[i] = false;
        if (desc.underrun) nic.stats.tx_failed += 1;
    }
}

pub fn transmit(nic: *NicDev, frame: []const u8) void {
    if (frame.len > 2048) return;

    // A slow owner: the ring tracks its own pending, and a slot not yet back
    // from the wire is refused rather than overwritten.
    const slot = device.tx_at;
    if (device.pending[slot]) {
        nic.stats.tx_failed += 1;
        return;
    }

    // This chip pads nothing: a frame below the ethernet minimum leaves as
    // a runt and every receiver on a real wire discards it.
    const wired = @max(frame.len, 60);
    @memcpy(device.tx_buffer[slot][0..frame.len], frame);
    if (frame.len < wired) @memset(device.tx_buffer[slot][frame.len..wired], 0);
    const at: R = @enumFromInt(@intFromEnum(R.tsd0) + slot * 4);
    const addr_at: R = @enumFromInt(@intFromEnum(R.tsad0) + slot * 4);
    device.pending[slot] = true;

    // The owner handshake, per the datasheet and per QEMU's reading of it:
    // take ownership, place the frame, then drop the bit. The drop is the
    // signal a transmit starts on. Writes are 32-bit here because the
    // window this register lives in only answers that width.
    device.window.out32(at, tsdWord(0, true));
    device.window.out32(addr_at, device.tx_phys[slot]);
    device.window.out32(at, tsdWord(@intCast(wired), false));
    device.tx_at = (slot + 1) % TX_SLOTS;

    dev_mod.deliverTx(nic, frame.len);
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