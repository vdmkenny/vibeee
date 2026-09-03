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
const lib = @import("lib");
const std = @import("std");
const dma = @import("dma.zig");
const log = @import("ulib").log;
const pci = @import("ulib").pci;
const sys = @import("sys");

const NicDev = dev_mod.NicDev;
const RingSlots = 64;
const Slab = 2048;
const MMIO_BYTES: u32 = 128 * 1024;
const MinimumFrame = 60;
const AllCauses: u32 = 0xFFFF_FFFF;
const ResetSpins = 10_000;
const EepromSpins = 10_000;

// ---------------------------------------------------------------------------
// Register window
// ---------------------------------------------------------------------------

/// Register offsets within BAR0, one value per dword.
const R = enum(u32) {
    ctrl = 0x0000,
    status = 0x0008,
    eerd = 0x0014,
    icr = 0x00C0,
    ims = 0x00D0,
    imc = 0x00D8,
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

/// The card's aperture, named by `R`. The shared window proves at compile
/// time that every offset in the set is word aligned.
const Regs = lib.mmio.Window(R, u32);

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
    _7: u4 = 0,
    force_speed: bool = false,
    force_duplex: bool = false,
    _13: u13 = 0,
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
    tx_queue_empty: bool = false,
    /// LSC: the link state changed.
    link_change: bool = false,
    rx_sequence: bool = false,
    /// RXDMT0: the receive threshold was met.
    rx_min: bool = false,
    _5: u1 = 0,
    rx_overrun: bool = false,
    /// RXT0: the receive timer delivered.
    rx_timer: bool = false,
    _8: u24 = 0,

    fn none(self: Causes) bool {
        return !self.tx_done and !self.tx_queue_empty and !self.link_change and
            !self.rx_sequence and !self.rx_min and !self.rx_overrun and !self.rx_timer;
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

const ReceiveAddressHigh = packed struct(u32) {
    octet4: u8 = 0,
    octet5: u8 = 0,
    _16: u15 = 0,
    valid: bool = false,
};

const EepromRead = packed struct(u32) {
    start: bool = false,
    _1: u3 = 0,
    done: bool = false,
    _5: u3 = 0,
    address: u8 = 0,
    data: u16 = 0,
};

const UpCauses = Causes{
    .tx_done = true,
    .link_change = true,
    .rx_sequence = true,
    .rx_min = true,
    .rx_overrun = true,
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
    if (@sizeOf(RxControl) != 4 or @sizeOf(TxControl) != 4 or
        @sizeOf(ReceiveAddressHigh) != 4 or @sizeOf(EepromRead) != 4)
    {
        @compileError("an enable register shapes one dword");
    }
    if (@bitOffsetOf(EepromRead, "done") != 4 or
        @bitOffsetOf(EepromRead, "address") != 8)
    {
        @compileError("EEPROM control fields do not match EERD");
    }
    if (@intFromEnum(R.ra1) + 4 > MMIO_BYTES) @compileError("register exceeds BAR0");
}

// ---------------------------------------------------------------------------
// The rings, one DMA segment
// ---------------------------------------------------------------------------

const RxStatus = packed struct(u8) {
    done: bool = false,
    end_of_packet: bool = false,
    ignore_checksum: bool = false,
    vlan: bool = false,
    udp_checksum: bool = false,
    tcp_checksum: bool = false,
    ip_checksum: bool = false,
    passed_inexact: bool = false,
};

const RxErrors = packed struct(u8) {
    crc: bool = false,
    symbol: bool = false,
    sequence: bool = false,
    _3: u1 = 0,
    carrier_extension: bool = false,
    transport_checksum: bool = false,
    ip_checksum: bool = false,
    data: bool = false,

    fn any(self: RxErrors) bool {
        return self.crc or self.symbol or self.sequence or self.carrier_extension or
            self.transport_checksum or self.ip_checksum or self.data;
    }
};

const TxCommand = packed struct(u8) {
    end_of_packet: bool = false,
    insert_fcs: bool = false,
    insert_checksum: bool = false,
    report_status: bool = false,
    report_packet_sent: bool = false,
    extended: bool = false,
    vlan: bool = false,
    interrupt_delay: bool = false,
};

const TxStatus = packed struct(u8) {
    done: bool = false,
    excessive_collisions: bool = false,
    late_collision: bool = false,
    underrun: bool = false,
    _4: u4 = 0,

    fn failed(self: TxStatus) bool {
        return self.excessive_collisions or self.late_collision or self.underrun;
    }
};

const SendCommand = TxCommand{
    .end_of_packet = true,
    .insert_fcs = true,
    .report_status = true,
};

/// The legacy receive descriptor, sixteen bytes, the manual's layout.
const RxDesc = extern struct {
    addr_low: u32 = 0,
    addr_high: u32 = 0,
    length: u16 = 0,
    checksum: u16 = 0,
    status: RxStatus = .{},
    errors: RxErrors = .{},
    special: u16 = 0,
};

/// The legacy transmit descriptor, including its byte-wide command and
/// writeback fields rather than treating them as unrelated dwords.
const TxDesc = extern struct {
    addr_low: u32 = 0,
    addr_high: u32 = 0,
    length: u16 = 0,
    checksum_offset: u8 = 0,
    command: TxCommand = .{},
    status: TxStatus = .{},
    checksum_start: u8 = 0,
    special: u16 = 0,
};

comptime {
    if (@sizeOf(RxDesc) != 16 or @sizeOf(TxDesc) != 16) {
        @compileError("an 82540 descriptor is sixteen bytes, whichever way");
    }
    if (@offsetOf(RxDesc, "status") != 12 or @offsetOf(TxDesc, "status") != 12) {
        @compileError("descriptor writeback status must begin at byte twelve");
    }
}

/// Receive descriptors, then the buffers they point at. One DMA segment, so
/// every address in it is DMA-visible from the start.
const Rings = struct {
    rx_desc: [RingSlots]RxDesc align(128) = @splat(.{}),
    rx_buffer: [RingSlots][Slab]u8 = @splat(@splat(0)),
    tx_desc: [RingSlots]TxDesc align(128) = @splat(.{}),
    tx_buffer: [RingSlots][Slab]u8 = @splat(@splat(0)),
};

comptime {
    if (RingSlots < 8 or RingSlots * @sizeOf(RxDesc) % 128 != 0 or
        RingSlots * @sizeOf(TxDesc) % 128 != 0)
    {
        @compileError("descriptor rings must be at least eight entries and a multiple of 128 bytes");
    }
    if (@alignOf(Rings) < 128 or @offsetOf(Rings, "rx_desc") % 128 != 0 or
        @offsetOf(Rings, "tx_desc") % 128 != 0)
    {
        @compileError("descriptor rings must be 128-byte aligned");
    }
}

/// One adapter, one static instance. No allocation on any packet path: a
/// machine of this class has one such NIC, and a no-allocation driver wants
/// no runtime heap at all.
const Device = struct {
    regs: Regs = .{ .base = undefined },
    rings: *Rings = undefined,
    phys: lib.Phys = .none,
    dma_handle: ?u32 = null,
    rx_next: u16 = 0, // next completed receive descriptor
    tx_next: u16 = 0, // next transmit descriptor to publish
    tx_clean: u16 = 0, // oldest transmit descriptor still owned by hardware
    opened: bool = false,
    started: bool = false,
};

var device: Device = .{};

pub fn open(loc: pci.Location, dev: *NicDev) bool {
    if (device.opened or device.dma_handle != null) {
        log.fail("e1000", "the adapter is already open");
        return false;
    }

    const aperture = pci.openAperture(loc, 0, MMIO_BYTES, "e1000", "adapter") orelse
        return false;
    var keep_pci_enabled = false;
    defer if (!keep_pci_enabled) pci.disableInterruptAndMaster(loc);
    device.regs = .{ .base = @ptrCast(aperture) };

    if (!reset()) {
        log.fail("e1000", "reset did not complete");
        return false;
    }
    if (!readMac(dev)) {
        log.fail("e1000", "cannot read a valid MAC address");
        return false;
    }

    // One physically contiguous run for descriptors and buffers.
    var phys: lib.Phys = .none;
    const handle = sys.dmaAlloc(@sizeOf(Rings), &phys);
    if (handle < 0) {
        log.failed("e1000", "cannot allocate DMA rings", handle);
        return false;
    }
    const dma_handle: u32 = @intCast(handle);
    const last_offset: u32 = @intCast(@sizeOf(Rings) - 1);
    // A run that leaves the addresses this machine has is one the engine
    // would walk off the end of.
    if (phys.addr() % @alignOf(Rings) != 0 or phys.plus(last_offset) == null) {
        _ = sys.close(dma_handle);
        log.fail("e1000", "DMA rings are unaligned or cross 4 GiB");
        return false;
    }
    const mapped = sys.shmMap(@intCast(handle), .{ .writable = true }) orelse {
        _ = sys.close(dma_handle);
        log.fail("e1000", "cannot map DMA rings");
        return false;
    };
    device.rings = @ptrCast(@alignCast(mapped));
    device.phys = phys;
    device.dma_handle = dma_handle;
    device.rx_next = 0;
    device.tx_next = 0;
    device.tx_clean = 0;
    device.rings.* = .{};

    // Every receive descriptor names its buffer before the ring is handed
    // over: a descriptor left at zero is an invitation to scribble the
    // frame over the real mode vector table.
    for (&device.rings.rx_desc, 0..) |*desc, i| {
        desc.* = .{
            .addr_low = device.phys.addr() + @as(u32, @intCast(@offsetOf(Rings, "rx_buffer") + i * Slab)),
        };
    }
    for (&device.rings.tx_desc, 0..) |*desc, i| {
        desc.* = .{
            .addr_low = device.phys.addr() + @as(u32, @intCast(@offsetOf(Rings, "tx_buffer") + i * Slab)),
            .status = .{ .done = true },
        };
    }
    dma.publish();

    // One endpoint, and it is talking: force the link up, with auto-speed.
    configureLink();

    // Receive path: the descriptor ring and its buffers are one run.
    device.regs.write(.rdbal, device.phys.addr() + @offsetOf(Rings, "rx_desc"));
    device.regs.write(.rdbah, 0);
    device.regs.write(.rdlen, RingSlots * @sizeOf(RxDesc));
    device.regs.write(.rdh, 0);
    // Head equal to tail means empty. Descriptor 63 stays as the sentinel;
    // descriptors 0 through 62 are initially available to the receiver.
    device.regs.write(.rdt, RingSlots - 1);

    // Transmit path.
    device.regs.write(.tdbal, device.phys.addr() + @offsetOf(Rings, "tx_desc"));
    device.regs.write(.tdbah, 0);
    device.regs.write(.tdlen, RingSlots * @sizeOf(TxDesc));
    device.regs.write(.tdh, 0);
    device.regs.write(.tdt, 0);

    device.opened = true;
    keep_pci_enabled = true;
    dev.state = link(dev);
    return true;
}

fn reset() bool {
    maskAndClearInterrupts();
    device.regs.write(.rctl, 0);
    device.regs.write(.tctl, @bitCast(TxControl{ .pad_short = true }));
    _ = device.regs.read(.status);
    sys.sleepMicros(10_000);

    var ctrl = readCtrl();
    ctrl.reset = true;
    device.regs.write(.ctrl, @bitCast(ctrl));
    _ = device.regs.read(.status);

    // The bit clears itself; waiting is bounded and pausing.
    var spins: u32 = 0;
    while (spins < ResetSpins) : (spins += 1) {
        if (!readCtrl().reset) {
            // The 82540 reloads its EEPROM after reset; RAR and EERD are not
            // stable until that fixed settling interval has passed.
            sys.sleepMicros(5_000);
            maskAndClearInterrupts();
            return true;
        }
        std.atomic.spinLoopHint();
    }
    maskAndClearInterrupts();
    return false;
}

fn readCtrl() Ctrl {
    return @bitCast(device.regs.read(.ctrl));
}

fn configureLink() void {
    var ctrl = readCtrl();
    ctrl.auto_speed = true;
    ctrl.force_link = true;
    ctrl.force_speed = false;
    ctrl.force_duplex = false;
    ctrl.reset = false;
    device.regs.write(.ctrl, @bitCast(ctrl));
}

fn readMac(dev: *NicDev) bool {
    const mac = readRar() orelse readEepromMac() orelse return false;
    writeRar(mac);
    dev.mac = mac;
    return true;
}

/// The receive-address low register: the first four octets in wire order.
const ReceiveAddressLow = packed struct(u32) {
    octet0: u8,
    octet1: u8,
    octet2: u8,
    octet3: u8,
};

fn readRar() ?[6]u8 {
    const low: ReceiveAddressLow = @bitCast(device.regs.read(.ra0));
    const high: ReceiveAddressHigh = @bitCast(device.regs.read(.ra1));
    if (!high.valid) return null;
    const mac = [6]u8{
        low.octet0,  low.octet1,  low.octet2, low.octet3,
        high.octet4, high.octet5,
    };
    return if (validMac(mac)) mac else null;
}

fn readEepromMac() ?[6]u8 {
    var mac: [6]u8 = @splat(0);
    for (0..3) |i| {
        const word = readEeprom(@intCast(i)) orelse return null;
        std.mem.writeInt(u16, mac[i * 2 ..][0..2], word, .little);
    }
    return if (validMac(mac)) mac else null;
}

fn readEeprom(address: u8) ?u16 {
    device.regs.write(.eerd, @bitCast(EepromRead{ .start = true, .address = address }));
    var spins: u32 = 0;
    while (spins < EepromSpins) : (spins += 1) {
        const result = @as(EepromRead, @bitCast(device.regs.read(.eerd)));
        if (result.done) return result.data;
        std.atomic.spinLoopHint();
    }
    return null;
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

fn writeRar(mac: [6]u8) void {
    device.regs.write(.ra0, @bitCast(ReceiveAddressLow{
        .octet0 = mac[0],
        .octet1 = mac[1],
        .octet2 = mac[2],
        .octet3 = mac[3],
    }));
    device.regs.write(.ra1, @bitCast(ReceiveAddressHigh{
        .octet4 = mac[4],
        .octet5 = mac[5],
        .valid = true,
    }));
}

fn maskAndClearInterrupts() void {
    device.regs.write(.imc, AllCauses);
    _ = device.regs.read(.status); // flush the posted mask write
    _ = device.regs.read(.icr); // ICR is read-to-clear
}

pub fn start(nic: *NicDev) bool {
    if (!device.opened or device.started) return false;

    maskAndClearInterrupts();
    dma.publish();
    device.regs.write(.rctl, @bitCast(UpRx));
    device.regs.write(.tctl, @bitCast(UpTx));
    _ = device.regs.read(.status);
    pci.enableInterrupt(nic.location);
    device.started = true;
    device.regs.write(.ims, @bitCast(UpCauses));
    _ = device.regs.read(.ims);
    return true;
}

pub fn stop(nic: *NicDev) void {
    if (!device.opened) return;
    device.started = false;

    device.regs.write(.imc, AllCauses);
    device.regs.write(.rctl, 0);
    device.regs.write(.tctl, @bitCast(TxControl{ .pad_short = true }));
    _ = device.regs.read(.status);
    sys.sleepMicros(10_000);

    // No register may retain a pointer to memory returned below.
    device.regs.write(.rdlen, 0);
    device.regs.write(.rdh, 0);
    device.regs.write(.rdt, 0);
    device.regs.write(.rdbal, 0);
    device.regs.write(.rdbah, 0);
    device.regs.write(.tdlen, 0);
    device.regs.write(.tdh, 0);
    device.regs.write(.tdt, 0);
    device.regs.write(.tdbal, 0);
    device.regs.write(.tdbah, 0);
    _ = device.regs.read(.status);
    _ = device.regs.read(.icr);

    pci.disableInterruptAndMaster(nic.location);
    if (device.dma_handle) |handle| _ = sys.close(handle);
    device.dma_handle = null;
    device.phys = .none;
    device.rx_next = 0;
    device.tx_next = 0;
    device.tx_clean = 0;
    device.opened = false;
    nic.state = .{};
}

pub fn irq(dev: *NicDev) bool {
    if (!device.opened or !device.started) return false;
    const cause = @as(Causes, @bitCast(device.regs.read(.icr)));
    if (cause.none()) return false; // a shared line, not ours

    // Reading ICR acknowledged this snapshot. Writing it back would also
    // clear a matching cause that arrived while this handler was working.
    if (cause.rx_min or cause.rx_overrun or cause.rx_timer) reapRx(dev);
    if (cause.rx_sequence or cause.rx_overrun) dev.stats.rx_dropped += 1;
    if (cause.tx_done) reapTx(dev);
    if (cause.link_change) dev_mod.deliverLink(dev, link(dev));
    return true;
}

fn reapRx(dev: *NicDev) void {
    while (true) {
        const slot = device.rx_next;
        const desc = &device.rings.rx_desc[slot];
        const ownership = @as(*const volatile RxStatus, &desc.status).*;
        if (!ownership.done) break;
        dma.consume();

        const status = @as(*const volatile RxStatus, &desc.status).*;
        const length = @as(*const volatile u16, &desc.length).*;
        const errors = @as(*const volatile RxErrors, &desc.errors).*;
        const good = status.end_of_packet and !errors.any() and
            length >= MinimumFrame and length <= Slab;

        if (good) {
            dev_mod.deliverRx(dev, .{
                .ok = true,
                .frame = device.rings.rx_buffer[slot][0..length],
            });
        } else {
            // Never form a slice from a device-provided length until it has
            // been bounded against the actual DMA slab.
            dev_mod.deliverRx(dev, .{});
        }

        desc.length = 0;
        desc.checksum = 0;
        desc.errors = .{};
        desc.special = 0;
        desc.status = .{};
        dma.publish();
        device.rx_next = (slot + 1) % RingSlots;
        // RDT names the last descriptor returned to hardware, not the next
        // descriptor software expects to consume.
        device.regs.write(.rdt, slot);
    }
}

fn reapTx(nic: *NicDev) void {
    while (device.tx_clean != device.tx_next) {
        const desc = &device.rings.tx_desc[device.tx_clean];
        const ownership = @as(*const volatile TxStatus, &desc.status).*;
        if (!ownership.done) break;
        dma.consume();
        const status = @as(*const volatile TxStatus, &desc.status).*;
        if (status.failed()) nic.stats.tx_failed += 1;
        device.tx_clean = (device.tx_clean + 1) % RingSlots;
    }
}

pub fn transmit(nic: *NicDev, frame: []const u8) bool {
    if (!device.opened or !device.started or frame.len < 14 or frame.len > Slab) return false;

    // Completion interrupts are advisory for reclaim: checking writebacks
    // here prevents backpressure when the event is delayed or coalesced.
    reapTx(nic);
    const slot = device.tx_next;
    const next = (slot + 1) % RingSlots;
    // One slot stays unused because TDH == TDT is the hardware's empty state.
    if (next == device.tx_clean) {
        nic.stats.tx_failed += 1;
        return false;
    }

    const desc = &device.rings.tx_desc[slot];
    const ownership = @as(*const volatile TxStatus, &desc.status).*;
    if (!ownership.done) {
        nic.stats.tx_failed += 1;
        return false;
    }

    @memcpy(device.rings.tx_buffer[slot][0..frame.len], frame);
    const address = desc.addr_low;
    desc.* = .{
        .addr_low = address,
        .length = @intCast(frame.len),
        .command = SendCommand,
    };

    dma.publish();
    device.tx_next = next;
    device.regs.write(.tdt, next);

    dev_mod.deliverTx(nic, frame.len);
    return true;
}

pub fn link(_: *NicDev) dev_mod.Link {
    if (!device.opened) return .{};
    const status = @as(StatusReg, @bitCast(device.regs.read(.status)));
    return .{
        .up = status.link_up,
        .mbps = if (status.link_up) status.speed.mbps() else 0,
        .duplex = if (!status.link_up) .unknown else if (status.full_duplex) .full else .half,
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
