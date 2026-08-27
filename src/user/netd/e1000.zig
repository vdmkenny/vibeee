//! Intel 82540EM gigabit ethernet, which is what QEMU offers and what several
//! machines of this era carry. Runs the legacy descriptors, which every 82540
//! supports and which keep the code in one shape the hardware cannot surprise.
//!
//! Everything here comes from the Intel 8254x programmers manual and Linux's
//! driver, which exists to be consulted. Written from scratch for this system,
//! in its shapes: registers are an enum over a dword window, every read or
//! written register is a packed struct whose fields are the bits, descriptor
//! sizes are compile-time facts, and nothing polls: receive reaping runs from
//! the interrupt handler only, and every hardware wait is a bounded spin with
//! `pause`.

const dev_mod = @import("dev.zig");
const log = @import("ulib").log;
const pci = @import("ulib").pci;
const std = @import("std");
const sys = @import("sys");

const NicDev = dev_mod.NicDev;
const RingSlots = 64;
const Slab = 2048;

// ---------------------------------------------------------------------------
// Register window
// ---------------------------------------------------------------------------

/// Register offsets within BAR0, one value per dword.
const R = enum(u32) {
    ctrl = 0x0000,
    status = 0x0008,
    icr = 0x00C0,
    ims = 0x00D0,
    rctl = 0x0100,
    tctl = 0x0400,
    rdbal = 0x2800,
    rdbah = 0x2804,
    rdlen = 0x2808,
    rdh = 0x2810,
    rdt = 0x2818,
    tdbal = 0x3800,
    tdbah = 0x3804,
    tdlen = 0x3808,
    tdh = 0x3810,
    tdt = 0x3818,
    /// Receive address registers, where the MAC outlives reset.
    ra0 = 0x5400,
    ra1 = 0x5404,
};

const Regs = struct {
    base: [*]volatile u32,

    fn wr(self: Regs, r: R, value: u32) void {
        self.base[@intFromEnum(r) / 4] = value;
    }

    fn rd(self: Regs, r: R) u32 {
        return self.base[@intFromEnum(r) / 4];
    }
};

// ---------------------------------------------------------------------------
// Register shapes: the bits, as fields
// ---------------------------------------------------------------------------

/// CTRL. The fields this driver writes; everything in between is carried
/// through untouched, which is the word "preserve" made mechanical.
const Ctrl = packed struct(u32) {
    _0: u5 = 0,
    /// ASDE: auto-speed detection.
    auto_speed: bool = false,
    /// SLU: set link up, the one-endpoint world this NIC lives in.
    force_link: bool = false,
    _7: u19 = 0,
    /// Device reset.
    reset: bool = false,
    _27: u5 = 0,
};

/// STATUS. Read, never written.
const StatusReg = packed struct(u32) {
    full_duplex: bool = false,
    link_up: bool = false,
    _2: u4 = 0,
    speed: Speed = .m10,
    _8: u24 = 0,
};

const Speed = enum(u2) {
    m10 = 0,
    m100 = 1,
    m1000 = 2,
    _,

    pub fn mbps(self: Speed) u16 {
        return switch (self) {
            .m10 => 10,
            .m100 => 100,
            .m1000 => 1000,
            _ => 0,
        };
    }
};

/// ICR and IMS share the bit shape: what fired, and what is let through.
const Causes = packed struct(u32) {
    /// TXDW: a transmit descriptor was written back.
    tx_done: bool = false,
    _1: u1 = 0,
    /// LSC: the link state changed.
    link_change: bool = false,
    _3: u1 = 0,
    /// RXDMT0: the receive threshold was met.
    rx_min: bool = false,
    _5: u2 = 0,
    /// RXT0: the receive timer delivered.
    rx_timer: bool = false,
    _8: u24 = 0,

    fn none(self: Causes) bool {
        return !self.tx_done and !self.link_change and !self.rx_min and !self.rx_timer;
    }
};

/// RCTL. The receive policy in the manual's own bit positions.
const RxControl = packed struct(u32) {
    _0: u1 = 0,
    enabled: bool = false,
    _2: u1 = 0,
    unicast_promisc: bool = false,
    multicast_promisc: bool = false,
    long_packets: bool = false,
    _6: u9 = 0,
    broadcast_accept: bool = false,
    _16: u10 = 0,
    strip_crc: bool = false,
    _27: u5 = 0,
};

/// TCTL. Only what this driver configures; the rest stays zero.
const TxControl = packed struct(u32) {
    _0: u1 = 0,
    enabled: bool = false,
    _2: u1 = 0,
    pad_short: bool = false,
    /// Collision threshold, manual value 0x10.
    threshold: u8 = 0,
    /// Collision distance, the manual's full-duplex value.
    collision_distance: u10 = 0,
    _22: u10 = 0,
};

const UpCauses = Causes{
    .tx_done = true,
    .link_change = true,
    .rx_min = true,
    .rx_timer = true,
};

const UpRx = RxControl{
    .enabled = true,
    .unicast_promisc = true,
    .multicast_promisc = true,
    .broadcast_accept = true,
    .strip_crc = true,
};

const UpTx = TxControl{
    .enabled = true,
    .pad_short = true,
    .threshold = 0x10,
    .collision_distance = 0x40,
};

comptime {
    if (@sizeOf(Ctrl) != 4 or @sizeOf(StatusReg) != 4 or @sizeOf(Causes) != 4) {
        @compileError("a status or control register shapes one dword");
    }
    if (@sizeOf(RxControl) != 4 or @sizeOf(TxControl) != 4) {
        @compileError("an enable register shapes one dword");
    }
}

// ---------------------------------------------------------------------------
// The rings, one DMA segment
// ---------------------------------------------------------------------------

/// The legacy descriptor, sixteen bytes, exactly as the manual lays it out.
const Desc = extern struct {
    addr: u32 = 0,
    _reserved: u32 = 0,
    len: u16 = 0,
    csum: u16 = 0,
    status: u8 = 0,
    errors: u8 = 0,
    special: u16 = 0,
};

const DESC_DONE = 0x01;

/// TX SPECIAL: end of packet, insert the frame check sequence, report status.
const TX_CMD = 0x0B;

comptime {
    if (@sizeOf(Desc) != 16) @compileError("an 82540 descriptor is sixteen bytes");
}

/// Receive descriptors, then the buffers they point at. One DMA segment, so
/// every address in it is DMA-visible from the start.
const Rings = struct {
    rx_desc: [RingSlots]Desc = @splat(.{}),
    rx_buffer: [RingSlots][Slab]u8 = @splat(@splat(0)),
    tx_desc: [RingSlots]Desc = @splat(.{}),
    tx_buffer: [RingSlots][Slab]u8 = @splat(@splat(0)),
};

/// One adapter, one static instance. No allocation on any packet path: a
/// machine of this class has one such NIC, and a no-allocation driver wants
/// no runtime heap at all.
const Device = struct {
    regs: Regs = .{ .base = undefined },
    rings: *Rings = undefined,
    phys: u32 = 0,
    rx_tail: u16 = 0, // next slot we hand the hardware
    tx_head: u16 = 0, // next slot we write into
    tx_tail: u16 = 0, // next slot the hardware writes back
};

var device: Device = .{};

pub fn open(loc: pci.Location, dev: *NicDev) bool {
    const aperture = sys.mapDevice(pci.bar(loc, 0) & ~@as(u32, 0xF), 128 * 1024) orelse {
        log.fail("e1000", "cannot map registers");
        return false;
    };
    pci.enableMemoryAndMaster(loc);
    device.regs = .{ .base = aperture };

    // One physically contiguous run for descriptors and buffers.
    var phys: u32 = 0;
    const handle = sys.dmaAlloc(@sizeOf(Rings) + 128, &phys);
    if (handle < 0) {
        log.failed("e1000", "cannot allocate DMA rings", handle);
        return false;
    }
    const mapped = sys.shmMap(@intCast(handle), .{ .writable = true }) orelse {
        log.fail("e1000", "cannot map DMA rings");
        return false;
    };
    device.rings = @alignCast(@ptrCast(mapped));
    device.phys = @intCast(std.mem.alignForward(usize, phys, 128));

    reset();
    readMac(dev);

    // One endpoint, and it is talking: force the link up, with auto-speed.
    mergeCtrl(.{ .auto_speed = true, .force_link = true });

    // Receive path: the descriptor ring and its buffers are one run.
    device.regs.wr(.rdbal, device.phys + @offsetOf(Rings, "rx_desc"));
    device.regs.wr(.rdbah, 0);
    device.regs.wr(.rdlen, RingSlots * @sizeOf(Desc));
    device.regs.wr(.rdh, 0);
    device.regs.wr(.rdt, 0);

    // Transmit path.
    device.regs.wr(.tdbal, device.phys + @offsetOf(Rings, "tx_desc"));
    device.regs.wr(.tdbah, 0);
    device.regs.wr(.tdlen, RingSlots * @sizeOf(Desc));
    device.regs.wr(.tdh, 0);
    device.regs.wr(.tdt, 0);

    dev.state = link(dev);
    return true;
}

fn reset() void {
    mergeCtrl(.{ .reset = true });
    // The bit clears itself; waiting is bounded and pausing.
    var spins: u32 = 0;
    while (spins < 10_000) : (spins += 1) {
        if (!readCtrl().reset) return;
        asm volatile ("pause");
    }
}

fn readCtrl() Ctrl {
    return @bitCast(device.regs.rd(.ctrl));
}

/// Write the fields given, on top of whatever the register holds: a field
/// asked for is set, the rest of the word carries through unread, unjudged.
fn mergeCtrl(wanted: Ctrl) void {
    var next = readCtrl();
    next.auto_speed = next.auto_speed or wanted.auto_speed;
    next.force_link = next.force_link or wanted.force_link;
    next.reset = wanted.reset;
    device.regs.wr(.ctrl, @bitCast(next));
}

fn readMac(dev: *NicDev) void {
    const low = device.regs.rd(.ra0);
    const high = device.regs.rd(.ra1);
    dev.mac = .{
        @truncate(low),
        @truncate(low >> 8),
        @truncate(low >> 16),
        @truncate(low >> 24),
        @truncate(high),
        @truncate(high >> 8),
    };
}

pub fn start(_: *NicDev) bool {
    device.regs.wr(.rctl, @bitCast(UpRx));
    device.regs.wr(.tctl, @bitCast(UpTx));
    device.regs.wr(.ims, @bitCast(UpCauses));
    return true;
}

pub fn stop(_: *NicDev) void {
    device.regs.wr(.ims, 0);
    var rx = @as(RxControl, @bitCast(device.regs.rd(.rctl)));
    rx.enabled = false;
    device.regs.wr(.rctl, @bitCast(rx));
    var tx = @as(TxControl, @bitCast(device.regs.rd(.tctl)));
    tx.enabled = false;
    device.regs.wr(.tctl, @bitCast(tx));
}

pub fn irq(dev: *NicDev) void {
    const cause = @as(Causes, @bitCast(device.regs.rd(.icr)));
    if (cause.none()) return; // a shared line, not ours
    device.regs.wr(.icr, @bitCast(cause)); // acknowledge what was acted on

    if (cause.rx_min or cause.rx_timer) reapRx(dev);
    if (cause.tx_done) reapTx();
    if (cause.link_change) dev.state = link(dev);
}

fn reapRx(dev: *NicDev) void {
    while (true) {
        const head = device.regs.rd(.rdh);
        if (head == device.rx_tail) break;

        const index = device.rx_tail % RingSlots;
        const desc = &device.rings.rx_desc[index];

        if (desc.status & DESC_DONE != 0) {
            dev_mod.deliverRx(dev, .{
                .ok = desc.errors == 0 and desc.len >= 60 and desc.len <= Slab,
                .frame = device.rings.rx_buffer[index][0..desc.len],
            });
            desc.status = 0; // the slot is ours again
            device.rx_tail = (device.rx_tail + 1) % RingSlots;
            device.regs.wr(.rdt, device.rx_tail);
        }
    }
}

fn reapTx() void {
    while (device.tx_tail != device.tx_head) {
        const desc = &device.rings.tx_desc[device.tx_tail];
        if (desc.status & DESC_DONE == 0) break;
        device.tx_tail = (device.tx_tail + 1) % RingSlots;
    }
}

pub fn transmit(nic: *NicDev, frame: []const u8) void {
    if (frame.len > Slab) return;

    // One slot is kept free: a full ring and an empty ring look the same to
    // the hardware, and the one that hurts is not the one full.
    const used = (device.tx_head - device.tx_tail + RingSlots) % RingSlots;
    if (used >= RingSlots - 1) {
        nic.stats.tx_failed += 1;
        return;
    }

    const slot = device.tx_head;
    const desc = &device.rings.tx_desc[slot];
    @memcpy(device.rings.tx_buffer[slot][0..frame.len], frame);
    desc.addr = device.phys + @offsetOf(Rings, "tx_buffer") + slot * Slab;
    desc.len = @intCast(frame.len);
    desc.status = 0;
    desc.errors = 0;
    desc.special = TX_CMD;

    device.tx_head = (slot + 1) % RingSlots;
    device.regs.wr(.tdt, device.tx_head);

    dev_mod.deliverTx(nic, frame.len);
}

pub fn link(_: *NicDev) dev_mod.Link {
    const status = @as(StatusReg, @bitCast(device.regs.rd(.status)));
    return .{
        .up = status.link_up,
        .mbps = if (status.link_up) status.speed.mbps() else 0,
        .duplex = if (status.full_duplex) .full else .half,
    };
}

/// Who this driver is, for the probe table and the interface listing.
pub const name = "e1000";
pub const vendor = 0x8086;
pub const device_id = 0x100E;
pub const ops: dev_mod.NicOps = .{
    .open = open,
    .start = start,
    .stop = stop,
    .irq = irq,
    .transmit = transmit,
    .link = link,
};
