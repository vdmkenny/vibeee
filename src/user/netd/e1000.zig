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
const cursor = @import("cursor.zig");
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

/// RCTL. The receive policy in the manual's own bit positions. The two
/// promiscuous enables are named so that leaving them off where the
/// receiver is configured reads as a choice rather than as an omission.
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

/// What the receiver takes: this station's own address, as programmed into
/// the receive-address register, and broadcasts.
///
/// Promiscuous is deliberately off. Unicast and multicast promiscuous take
/// every frame on the segment, which on a switched wire is nothing and on
/// a shared one is everybody else's traffic handed to the stack; the cost
/// is then paid again above, in every frame lwIP has to look at and throw
/// away. The address filter is the hardware doing what it is for.
const UpRx = RxControl{
    .enabled = true,
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
    /// Descriptors and buffers, one run of device memory. Held as an arena
    /// so that giving it back is unmapping *and* closing: a handle closed
    /// under a live mapping frees nothing, and a driver stopped and opened
    /// a few times then runs the machine out of contiguous memory without
    /// ever having allocated twice.
    arena: dma.Arena(Rings) = .{},
    /// Where each end of a ring stands. Cursors rather than plain indices
    /// because the arithmetic that matters — how much is outstanding, how
    /// much room is left — is measured the way a lap is, and every lap but
    /// the first has the writing end behind the reading one.
    rx_next: cursor.Cursor(RingSlots) = .{}, // next completed receive descriptor
    tx_next: cursor.Cursor(RingSlots) = .{}, // next transmit descriptor to publish
    tx_clean: cursor.Cursor(RingSlots) = .{}, // oldest transmit descriptor still owned by hardware
    opened: bool = false,
    started: bool = false,
};

var device: Device = .{};

pub fn open(loc: pci.Location, dev: *NicDev) bool {
    if (device.opened or device.arena.at != null) {
        log.fail("e1000", "the adapter is already open");
        return false;
    }

    // One past the highest register this driver touches: the smallest
    // aperture that can serve it. A part decoding less than the family's
    // maximum is still usable, and one decoding less than this is not.
    const aperture = pci.openApertureNeeding(
        loc,
        0,
        MMIO_BYTES,
        pci.registersEnd(R, @sizeOf(u32)),
        "e1000",
        "adapter",
    ) orelse return false;
    // Every way out of here but the last one gives the registers back. A
    // driver that fails to open is asked again after the next restart of
    // the service, and an aperture left mapped each time is a hole in the
    // address space that never comes back.
    var keep_pci_enabled = false;
    defer if (!keep_pci_enabled) {
        // The bus master goes first, and then the memory it was given. An
        // open that got as far as taking device memory and then failed has
        // to give it back, or the next attempt at this adapter is refused
        // for want of the run this one is still sitting on -- but a part
        // still able to fetch holds addresses into whatever gets that
        // memory next. Releasing an arena that was never taken does
        // nothing.
        pci.disableInterruptAndMaster(loc);
        device.arena.release();
        sys.shmUnmap(@volatileCast(device.regs.base));
    };
    device.regs = .{ .base = @ptrCast(aperture) };

    if (!reset()) {
        log.fail("e1000", "reset did not complete");
        return false;
    }
    if (!readMac(dev)) {
        log.fail("e1000", "cannot read a valid MAC address");
        return false;
    }

    // One physically contiguous run for descriptors and buffers, taken and
    // mapped as one thing and zeroed before anything is written into it: a
    // descriptor left holding last boot's address is a device that fetches
    // from wherever it points.
    device.arena = dma.Arena(Rings).acquire() catch |why| {
        switch (why) {
            // No contiguous run of that size left below 4 GiB. Retold in
            // the shape `log.refused` takes rather than handed over as it
            // arrived: the arena's refusals are its own, and this is the
            // one of them the kernel's would have been.
            error.NoMemory => log.refused("e1000", "cannot allocate DMA rings", error.NoMemory),
            // Checked rather than adjusted: an adjusted physical base
            // without the same shift on the mapping would have the CPU and
            // the engine each working in a different arena.
            error.Misaligned => log.fail("e1000", "DMA rings are unaligned or cross 4 GiB"),
            error.Unmappable => log.fail("e1000", "cannot map DMA rings"),
        }
        return false;
    };

    // The two ring bases the device is written, asked of the arena rather
    // than added to its base by hand: the run that leaves this machine's
    // addresses is the one a driver hands a device a page it does not own.
    // Every offset here is inside the body, so neither can be refused; the
    // `return false` arms are the one shape a driver has for saying so,
    // and the defer above gives the arena back if one is.
    const rx_desc_at = device.arena.physOf(@offsetOf(Rings, "rx_desc")) orelse return false;
    const tx_desc_at = device.arena.physOf(@offsetOf(Rings, "tx_desc")) orelse return false;

    device.rx_next = .{};
    device.tx_next = .{};
    device.tx_clean = .{};
    const rings = device.arena.body();

    // Every receive descriptor names its buffer before the ring is handed
    // over: a descriptor left at zero is an invitation to scribble the
    // frame over the real mode vector table.
    for (&rings.rx_desc, 0..) |*desc, i| {
        desc.* = .{
            .addr_low = (device.arena.physOf(@offsetOf(Rings, "rx_buffer") + i * Slab) orelse return false).addr(),
        };
    }
    for (&rings.tx_desc, 0..) |*desc, i| {
        desc.* = .{
            .addr_low = (device.arena.physOf(@offsetOf(Rings, "tx_buffer") + i * Slab) orelse return false).addr(),
            .status = .{ .done = true },
        };
    }
    dma.publish();

    // One endpoint, and it is talking: force the link up, with auto-speed.
    configureLink();

    // Receive path: the descriptor ring and its buffers are one run.
    device.regs.write(.rdbal, rx_desc_at.addr());
    device.regs.write(.rdbah, 0);
    device.regs.write(.rdlen, RingSlots * @sizeOf(RxDesc));
    device.regs.write(.rdh, 0);
    // Head equal to tail means empty. Descriptor 63 stays as the sentinel;
    // descriptors 0 through 62 are initially available to the receiver.
    device.regs.write(.rdt, RingSlots - 1);

    // Transmit path.
    device.regs.write(.tdbal, tx_desc_at.addr());
    device.regs.write(.tdbah, 0);
    device.regs.write(.tdlen, RingSlots * @sizeOf(TxDesc));
    device.regs.write(.tdh, 0);
    device.regs.write(.tdt, 0);

    device.opened = true;
    keep_pci_enabled = true;
    dev_mod.deliverLink(dev, link(dev));
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
    return if (dev_mod.validMac(mac)) mac else null;
}

fn readEepromMac() ?[6]u8 {
    var mac: [6]u8 = @splat(0);
    for (0..3) |i| {
        const word = readEeprom(@intCast(i)) orelse return null;
        std.mem.writeInt(u16, mac[i * 2 ..][0..2], word, .little);
    }
    return if (dev_mod.validMac(mac)) mac else null;
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

    // What is handed back is memory a bus master was writing into, unmapped
    // as well as closed: a mapping is a reference of its own, so a handle
    // closed under a live one frees nothing. Called only after the
    // registers above have been cleared, and before the aperture goes,
    // because a device left able to fetch has addresses into whatever gets
    // this memory next.
    device.arena.release();

    // The aperture is given back too, and for the same reason: a mapping
    // holds a window of this process's address space, and one left behind
    // by every stop is a machine that runs out of them. Safe only now
    // that no register names memory either side of it.
    sys.shmUnmap(@volatileCast(device.regs.base));
    device.regs = .{ .base = undefined };
    device.rx_next = .{};
    device.tx_next = .{};
    device.tx_clean = .{};
    device.opened = false;
    dev_mod.deliverLink(nic, .{});
}

/// One interrupt delivery.
///
/// The shape of the pass is `dev.serveIrq`'s: read a cause, hold the line
/// over the work, release it, and look again. What only this driver knows
/// is the three things below.
pub fn irq(nic: *NicDev) bool {
    if (!device.opened or !device.started) return false;
    return dev_mod.serveIrq(@This(), nic);
}

/// What the adapter has latched, as one word: zero for nothing, which is
/// what ends the pass, and on a shared line what says an edge was not
/// ours.
///
/// ICR is read-to-clear, so this read is also the acknowledgement of
/// everything it reported; `acknowledge` does not write it back.
pub fn cause() u32 {
    if (!device.started) return 0;
    const latched: Causes = @bitCast(device.regs.read(.icr));
    return if (latched.none()) 0 else @bitCast(latched);
}

/// Hold the line over the work, and let it go afterwards.
///
/// The causes themselves were acknowledged by reading ICR, which is
/// read-to-clear; writing them back would also clear a matching cause that
/// arrived while this pass was working, and that is work owed. So what
/// holds the line here is the mask: IMC while the work runs, IMS after it,
/// which on a level line is what stops the controller re-asserting
/// mid-pass and on an edge one costs a posted write.
pub fn acknowledge(_: u32, held: bool) void {
    if (held) {
        device.regs.write(.imc, AllCauses);
    } else {
        device.regs.write(.ims, @bitCast(UpCauses));
    }
    _ = device.regs.read(.status); // flush the posted mask write
}

/// One pass of the adapter's work, on the line.
///
/// Nothing here may wait on the part: the line is held while it runs, and
/// on a shared line so is every neighbour's. Reaping is bounded by
/// `RX_REAP_BUDGET` rather than by the number of rounds, because a round
/// is a look at the cause and not a limit on what a wire can have filled.
pub fn service(causes: u32, nic: *NicDev) void {
    const latched: Causes = @bitCast(causes);
    if (latched.rx_min or latched.rx_overrun or latched.rx_timer) reapRx(nic);
    if (latched.rx_sequence or latched.rx_overrun) nic.stats.rx_dropped += 1;
    if (latched.tx_done) reapTx(nic);
    if (latched.link_change) dev_mod.deliverLink(nic, link(nic));
}

pub fn poll(dev: *NicDev) bool {
    if (!device.opened or !device.started) return false;
    // Whatever arrived with no interrupt behind it: a line the firmware
    // routed nowhere, or an edge this service never saw. Nothing about
    // the ring depends on being woken; the descriptors are the hardware's
    // to fill whether an interrupt was delivered or not.
    reapRx(dev);
    reapTx(dev);
    return true;
}

/// How many frames one pass of the receiver takes, however many the wire
/// has for it.
///
/// Each descriptor is handed straight back to the hardware as it is
/// drained, so at line rate the ring refills underneath the loop as fast
/// as the loop empties it and a pass that ran until the ring was quiet
/// would never end: this service is one thread, and everything else it
/// does — the stack's timers, the other interfaces on the line, the
/// channel it answers requests on — stops for as long as the wire keeps
/// talking. One lap of the ring is the most one pass takes; what is still
/// there when it stops is the next pass's to take.
const RX_REAP_BUDGET = RingSlots;

fn reapRx(dev: *NicDev) void {
    const rings = device.arena.body();
    var reaped: usize = 0;
    while (reaped < RX_REAP_BUDGET) : (reaped += 1) {
        const slot = device.rx_next.at;
        const desc = &rings.rx_desc[slot];
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
                .frame = rings.rx_buffer[slot][0..length],
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
        device.rx_next.next();
        // RDT names the last descriptor returned to hardware, not the next
        // descriptor software expects to consume: writing the cursor as it
        // stands now would hand the engine a descriptor this pass has not
        // refilled, and hardware and software would be one apart for the
        // rest of the run.
        device.regs.write(.rdt, @intCast(slot));
    }
}

fn reapTx(nic: *NicDev) void {
    const rings = device.arena.body();
    // How much is still the hardware's: from the oldest descriptor not yet
    // reclaimed up to the one the next send will take, measured the way a
    // lap is, because after the first the writing end is behind the
    // reading one and a plain subtraction goes below zero.
    var outstanding = device.tx_next.used(device.tx_clean.at);
    while (outstanding > 0) : (outstanding -= 1) {
        const desc = &rings.tx_desc[device.tx_clean.at];
        const ownership = @as(*const volatile TxStatus, &desc.status).*;
        if (!ownership.done) break;
        dma.consume();
        const status = @as(*const volatile TxStatus, &desc.status).*;
        if (status.failed()) nic.stats.tx_failed += 1;
        device.tx_clean.next();
    }
}

pub fn transmit(nic: *NicDev, frame: []const u8) bool {
    if (!device.opened or !device.started or frame.len < 14 or frame.len > Slab) return false;

    // Completion interrupts are advisory for reclaim: checking writebacks
    // here prevents backpressure when the event is delayed or coalesced.
    reapTx(nic);
    // One slot stays unused because TDH == TDT is the hardware's empty
    // state: what is asked for is the room the ring has, which is one
    // short of its size for exactly that reason.
    if (device.tx_next.room(device.tx_clean.at) == 0) {
        nic.stats.tx_failed += 1;
        return false;
    }
    const slot = device.tx_next.at;

    const rings = device.arena.body();
    const desc = &rings.tx_desc[slot];
    const ownership = @as(*const volatile TxStatus, &desc.status).*;
    if (!ownership.done) {
        nic.stats.tx_failed += 1;
        return false;
    }

    @memcpy(rings.tx_buffer[slot][0..frame.len], frame);
    const address = desc.addr_low;
    desc.* = .{
        .addr_low = address,
        .length = @intCast(frame.len),
        .command = SendCommand,
    };

    dma.publish();
    device.tx_next.next();
    // TDT, unlike RDT, is one past the last descriptor the engine may
    // send, which is the cursor as it now stands.
    device.regs.write(.tdt, @intCast(device.tx_next.at));

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
    .poll = poll,
    .transmit = transmit,
    .link = link,
};
