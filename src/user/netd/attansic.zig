//! What the Attansic parts have in common.
//!
//! The Eee PC 701 carries the L2 and the 1000 the L1E. They move frames in
//! completely different ways, so their rings and their interrupt registers
//! have nothing to say to each other. Everything around the frames is the
//! same silicon: the same block reset, the same MDIO controller at the same
//! offset with the same bits, the same station address, the same
//! inter-packet gap and half-duplex registers, and the same low half of the
//! MAC control word.
//!
//! That part is here, once, with every bit position checked on the build
//! machine against the values the parts are documented with. Neither driver
//! can be run anywhere but on a machine that has the part, so a test that
//! runs is worth more here than in most places.
//!
//! What is not here is anything whose meaning differs between the parts,
//! even where the offset is the same. The interrupt status register is at
//! 0x1600 on both and its bits are numbered differently; bit 27 of the MAC
//! control word clocks the MAC from the PHY on one part and turns on a
//! debug mode on the other. Those stay with the driver that knows which
//! part it is talking to.

const lib = @import("lib");
const std = @import("std");

/// The registers at the same offset on every part, read and written a word
/// at a time. A register whose bits differ between the parts is still here
/// when its offset does not: where it is and what it means are separate
/// questions, and the driver answers the second.
pub const Register = enum(u32) {
    pcie_phymisc = 0x1000,
    ltssm_test_mode = 0x12FC,
    master_ctrl = 0x1400,
    manual_timer = 0x1404,
    idle_status = 0x1410,
    mdio_ctrl = 0x1414,
    mac_ctrl = 0x1480,
    mac_ipg_ifg = 0x1484,
    mac_sta_addr = 0x1488,
    mac_sta_addr_hi = 0x148C,
    rx_hash_table = 0x1490,
    mac_half_duplex = 0x1498,
    mtu = 0x149C,
    desc_base_hi = 0x1540,
    isr = 0x1600,
    imr = 0x1604,
};

/// The same, for the two reached a half word at a time.
pub const Register16 = enum(u32) {
    irq_modu_timer = 0x1408,
    cmbdisdma_timer = 0x140E,
};

pub const Words = lib.mmio.Window(Register, u32);
pub const Halves = lib.mmio.Window(Register16, u16);

// ---------------------------------------------------------------------------
// Register shapes
// ---------------------------------------------------------------------------

/// The master control word. The L2 sets only the reset and the moderation
/// timer; the rest are named because the L1E uses them and because the top
/// half is where both parts say which part they are.
pub const MasterCtrl = packed struct(u32) {
    soft_reset: bool = false,
    /// The manual timer, which counts down to one interrupt.
    manual_timer: bool = false,
    /// The moderation timer, which holds interrupts together.
    moderation_timer: bool = false,
    manual_int: bool = false,
    _4: u1 = 0,
    moderation_timer2: bool = false,
    /// Clear the interrupt status by reading it.
    read_clears: bool = false,
    _7: u2 = 0,
    led_mode: bool = false,
    _10: u6 = 0,
    revision: u8 = 0,
    part: u8 = 0,
};

/// Which blocks are still working. Every one of them reads zero when the
/// part has finished resetting, which is the only thing a driver asks.
pub const IdleStatus = packed struct(u32) {
    rx_mac: bool = false,
    tx_mac: bool = false,
    rx_queue: bool = false,
    tx_queue: bool = false,
    dma_read: bool = false,
    dma_write: bool = false,
    statistics: bool = false,
    counters: bool = false,
    _8: u24 = 0,

    pub fn busy(self: IdleStatus) bool {
        return @as(u32, @bitCast(self)) != 0;
    }
};

/// The MDIO controller, which is how either part reaches its PHY.
pub const MdioCtrl = packed struct(u32) {
    data: u16 = 0,
    phy_reg: u5 = 0,
    /// One reads a PHY register, zero writes.
    read: bool = false,
    /// Suppressing the preamble speeds the transfer. Always set, per the
    /// manual for both parts.
    preamble: bool = true,
    start: bool = false,
    /// Zero is a quarter of the 25 MHz reference, which is what both
    /// drivers use.
    clock: u3 = 0,
    busy: bool = false,
    _28: u4 = 0,
};

/// The inter-packet gaps, in bit times.
pub const IpgIfg = packed struct(u32) {
    /// Back to back.
    ipgt: u7 = 0,
    _7: u1 = 0,
    /// The least gap a received frame is allowed; a frame arriving sooner
    /// is dropped.
    min_ifg: u8 = 0,
    /// The carrier sense window.
    ipgr1: u7 = 0,
    _23: u1 = 0,
    /// The rest of the gap.
    ipgr2: u7 = 0,
    _31: u1 = 0,
};

/// What the MAC does about collisions, which only matters half duplex.
pub const HalfDuplex = packed struct(u32) {
    /// The collision window.
    lcol: u10 = 0,
    _10: u2 = 0,
    /// How many times a frame is sent again before it is dropped.
    retry: u4 = 0,
    /// Send a frame that has been deferred past the limit rather than
    /// dropping it.
    exc_defer: bool = false,
    no_back_collision: bool = false,
    no_back_pressure: bool = false,
    /// The alternative binary exponential back-off.
    abebe: bool = false,
    abebt: u4 = 0,
    /// The gap before jamming, in units of eight bit times.
    jam_ipg: u4 = 0,
    _28: u4 = 0,
};

/// The low half of the MAC control word, which is the same on both parts.
/// What sits above it is not, so each driver names its own upper half and
/// puts this at the bottom of it.
pub const MacBase = packed struct(u16) {
    tx_enable: bool = false,
    rx_enable: bool = false,
    tx_flow: bool = false,
    rx_flow: bool = false,
    loopback: bool = false,
    full_duplex: bool = false,
    add_crc: bool = false,
    /// Pad short frames to sixty bytes and then add the checksum. Takes
    /// precedence over `add_crc`.
    pad: bool = false,
    /// Check that the length field matches the frame.
    len_check: bool = false,
    huge: bool = false,
    preamble_len: u4 = 0,
    /// Strip the VLAN tag from every received frame.
    remove_vlan: bool = false,
    promiscuous: bool = false,
};

/// What the MAC counts the wire's speed as, at bits 20 and 21 of the MAC
/// control word. Not the PHY's encoding: ten and a hundred share one value
/// here, and zero is not a value at all.
pub const Speed = enum(u2) {
    m10_100 = 1,
    m1000 = 2,
    _,
};

/// The station address, which both parts hold as one word and a half with
/// the first octet in the top byte of the high word.
pub const StationLow = packed struct(u32) {
    octet5: u8 = 0,
    octet4: u8 = 0,
    octet3: u8 = 0,
    octet2: u8 = 0,
};

pub const StationHigh = packed struct(u32) {
    octet1: u8 = 0,
    octet0: u8 = 0,
    _16: u16 = 0,
};

/// The address the part is holding. All zero where nothing has written
/// one, which the caller checks: this reads the registers and does not
/// decide whether what it found is an address.
pub fn readStation(words: Words) [6]u8 {
    const low: StationLow = @bitCast(words.read(.mac_sta_addr));
    const high: StationHigh = @bitCast(words.read(.mac_sta_addr_hi));
    return .{ high.octet0, high.octet1, low.octet2, low.octet3, low.octet4, low.octet5 };
}

pub fn writeStation(words: Words, mac: [6]u8) void {
    words.write(.mac_sta_addr, @bitCast(StationLow{
        .octet2 = mac[2],
        .octet3 = mac[3],
        .octet4 = mac[4],
        .octet5 = mac[5],
    }));
    words.write(.mac_sta_addr_hi, @bitCast(StationHigh{ .octet0 = mac[0], .octet1 = mac[1] }));
}

// ---------------------------------------------------------------------------
// Sequences
// ---------------------------------------------------------------------------

/// How long a block may take to stop after a reset, in milliseconds. Both
/// vendor drivers wait ten.
pub const RESET_MS = 10;

pub const Stuck = error{
    /// A block was still working when the budget ran out, which means the
    /// part did not reset and nothing after this would mean anything.
    StillBusy,
};

/// Reset every block and wait for them all to stop.
///
/// The read after the write posts it, so the write reaches the part before
/// anything waits on its effect. The clock is the caller's: this module has
/// no business deciding how a process waits, and taking it at compile time
/// costs nothing at run time and lets the sequence be tested off hardware.
pub fn reset(words: Words, comptime sleepMicros: fn (u32) void) Stuck!void {
    words.write(.master_ctrl, @bitCast(MasterCtrl{ .soft_reset = true }));
    _ = words.read(.master_ctrl);
    sleepMicros(1_000);

    for (0..RESET_MS) |_| {
        const state: IdleStatus = @bitCast(words.read(.idle_status));
        if (!state.busy()) return;
        sleepMicros(1_000);
    }
    return error.StillBusy;
}

/// The PHY, reached through the MAC's own MDIO controller.
pub const Mdio = struct {
    words: Words,

    /// How many looks at the busy bit before giving up.
    ///
    /// This is the one place in either driver that spins, and it spins
    /// because there is nothing to wait on: the MDIO controller raises no
    /// interrupt when a frame finishes, and the shortest sleep this
    /// system can take is the ten millisecond tick, which is two hundred
    /// times longer than the frame it would be waiting for. Everything
    /// else either of these drivers waits for is an interrupt, including
    /// the link changing, which the PHY reports rather than being asked
    /// about.
    ///
    /// The budget covers the slowest frame with room to spare and still
    /// bounds a wedged bus to milliseconds: a frame takes tens of
    /// microseconds on the wire and each look is an uncached read costing
    /// about one. A budget of ten passes in an emulator and is spent
    /// before real silicon has clocked its preamble.
    pub const SPINS = 4000;

    pub const Error = error{
        /// The controller never went idle, so nothing was read or written
        /// and the value in the register is not an answer.
        Timeout,
    };

    /// One PHY register. `register` is the driver's own enum of them, so
    /// each driver names the registers of the PHY it has.
    pub fn read(self: Mdio, register: anytype) Error!u16 {
        try self.begin(register, true, 0);
        try self.settle();
        const state: MdioCtrl = @bitCast(self.words.read(.mdio_ctrl));
        return state.data;
    }

    pub fn write(self: Mdio, register: anytype, value: u16) Error!void {
        try self.begin(register, false, value);
        try self.settle();
    }

    /// Start one transaction, after the one before it has finished.
    fn begin(self: Mdio, register: anytype, reading: bool, value: u16) Error!void {
        try self.settle();
        self.words.write(.mdio_ctrl, @bitCast(MdioCtrl{
            .data = value,
            .phy_reg = @intFromEnum(register),
            .read = reading,
            .start = true,
        }));
    }

    fn idle(self: Mdio) bool {
        const state: MdioCtrl = @bitCast(self.words.read(.mdio_ctrl));
        return !state.start and !state.busy;
    }

    fn settle(self: Mdio) Error!void {
        var spins: u32 = 0;
        while (spins < SPINS) : (spins += 1) {
            if (self.idle()) return;
            std.atomic.spinLoopHint();
        }
        return error.Timeout;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// Every value below is the part's documented one. These shapes are the only
// thing about either driver that can be checked away from the hardware, so
// they are checked exactly.

const testing = std.testing;

fn word(value: anytype) u32 {
    return @bitCast(value);
}

test "the master control word is the part's" {
    try testing.expectEqual(@as(u32, 0x1), word(MasterCtrl{ .soft_reset = true }));
    try testing.expectEqual(@as(u32, 0x2), word(MasterCtrl{ .manual_timer = true }));
    try testing.expectEqual(@as(u32, 0x4), word(MasterCtrl{ .moderation_timer = true }));
    try testing.expectEqual(@as(u32, 0x8), word(MasterCtrl{ .manual_int = true }));
    try testing.expectEqual(@as(u32, 0x20), word(MasterCtrl{ .moderation_timer2 = true }));
    try testing.expectEqual(@as(u32, 0x40), word(MasterCtrl{ .read_clears = true }));
    try testing.expectEqual(@as(u32, 0x200), word(MasterCtrl{ .led_mode = true }));

    // Which part it is, and which revision of it, in the top two bytes.
    const said: MasterCtrl = @bitCast(@as(u32, 0x2048_0000));
    try testing.expectEqual(@as(u8, 0x20), said.part);
    try testing.expectEqual(@as(u8, 0x48), said.revision);
}

test "a part that has finished resetting says every block is idle" {
    try testing.expect(!(IdleStatus{}).busy());
    try testing.expectEqual(@as(u32, 0x01), word(IdleStatus{ .rx_mac = true }));
    try testing.expectEqual(@as(u32, 0x02), word(IdleStatus{ .tx_mac = true }));
    try testing.expectEqual(@as(u32, 0x04), word(IdleStatus{ .rx_queue = true }));
    try testing.expectEqual(@as(u32, 0x08), word(IdleStatus{ .tx_queue = true }));
    try testing.expectEqual(@as(u32, 0x10), word(IdleStatus{ .dma_read = true }));
    try testing.expectEqual(@as(u32, 0x20), word(IdleStatus{ .dma_write = true }));
    try testing.expectEqual(@as(u32, 0x40), word(IdleStatus{ .statistics = true }));
    try testing.expectEqual(@as(u32, 0x80), word(IdleStatus{ .counters = true }));
    try testing.expect((IdleStatus{ .rx_queue = true }).busy());
}

test "the MDIO control word is the part's" {
    // A read of PHY register 1, started, with the preamble suppressed.
    const asked = MdioCtrl{ .phy_reg = 1, .read = true, .start = true };
    try testing.expectEqual(@as(u32, 0x0001_0000 | 0x200000 | 0x400000 | 0x800000), word(asked));

    try testing.expectEqual(@as(u32, 0x400000), word(MdioCtrl{}));
    try testing.expectEqual(@as(u32, 0x400000 | 0x8000000), word(MdioCtrl{ .busy = true }));
    // The data the part answered with is the low half.
    const answer: MdioCtrl = @bitCast(@as(u32, 0x0000_1234));
    try testing.expectEqual(@as(u16, 0x1234), answer.data);
}

test "the gap and collision registers are the part's" {
    try testing.expectEqual(@as(u32, 0x7F), word(IpgIfg{ .ipgt = 0x7F }));
    try testing.expectEqual(@as(u32, 0xFF00), word(IpgIfg{ .min_ifg = 0xFF }));
    try testing.expectEqual(@as(u32, 0x7F_0000), word(IpgIfg{ .ipgr1 = 0x7F }));
    try testing.expectEqual(@as(u32, 0x7F00_0000), word(IpgIfg{ .ipgr2 = 0x7F }));

    try testing.expectEqual(@as(u32, 0x3FF), word(HalfDuplex{ .lcol = 0x3FF }));
    try testing.expectEqual(@as(u32, 0xF000), word(HalfDuplex{ .retry = 0xF }));
    try testing.expectEqual(@as(u32, 0x1_0000), word(HalfDuplex{ .exc_defer = true }));
    try testing.expectEqual(@as(u32, 0x2_0000), word(HalfDuplex{ .no_back_collision = true }));
    try testing.expectEqual(@as(u32, 0x4_0000), word(HalfDuplex{ .no_back_pressure = true }));
    try testing.expectEqual(@as(u32, 0x8_0000), word(HalfDuplex{ .abebe = true }));
    try testing.expectEqual(@as(u32, 0xF0_0000), word(HalfDuplex{ .abebt = 0xF }));
    try testing.expectEqual(@as(u32, 0xF00_0000), word(HalfDuplex{ .jam_ipg = 0xF }));
}

test "the low half of the MAC control word is the part's" {
    const half = struct {
        fn of(value: MacBase) u16 {
            return @bitCast(value);
        }
    }.of;
    try testing.expectEqual(@as(u16, 0x01), half(.{ .tx_enable = true }));
    try testing.expectEqual(@as(u16, 0x02), half(.{ .rx_enable = true }));
    try testing.expectEqual(@as(u16, 0x04), half(.{ .tx_flow = true }));
    try testing.expectEqual(@as(u16, 0x08), half(.{ .rx_flow = true }));
    try testing.expectEqual(@as(u16, 0x10), half(.{ .loopback = true }));
    try testing.expectEqual(@as(u16, 0x20), half(.{ .full_duplex = true }));
    try testing.expectEqual(@as(u16, 0x40), half(.{ .add_crc = true }));
    try testing.expectEqual(@as(u16, 0x80), half(.{ .pad = true }));
    try testing.expectEqual(@as(u16, 0x100), half(.{ .len_check = true }));
    try testing.expectEqual(@as(u16, 0x200), half(.{ .huge = true }));
    try testing.expectEqual(@as(u16, 0x3C00), half(.{ .preamble_len = 0xF }));
    try testing.expectEqual(@as(u16, 0x4000), half(.{ .remove_vlan = true }));
    try testing.expectEqual(@as(u16, 0x8000), half(.{ .promiscuous = true }));

    // The speed field sits above it, at bits 20 and 21.
    const Whole = packed struct(u32) { base: MacBase, _16: u4 = 0, speed: Speed, _22: u10 = 0 };
    try testing.expectEqual(@as(u32, 0x10_0000), word(Whole{ .base = .{}, .speed = .m10_100 }));
    try testing.expectEqual(@as(u32, 0x20_0000), word(Whole{ .base = .{}, .speed = .m1000 }));
    try testing.expectEqual(@as(u32, 0x10_0003), word(Whole{
        .base = .{ .tx_enable = true, .rx_enable = true },
        .speed = .m10_100,
    }));
}

test "the station address reads back the way it was written" {
    var store: [0x1600]u8 align(4) = @splat(0);
    const words = Words{ .base = &store };

    const mac = [6]u8{ 0x00, 0x1F, 0xC6, 0x11, 0x22, 0x33 };
    writeStation(words, mac);
    try testing.expectEqual(mac, readStation(words));

    // The first octet sits above the second in the high word, and the
    // last four fill the low one. The other way round would put the
    // multicast bit in the station address.
    try testing.expectEqual(@as(u32, 0x0000_001F), words.read(.mac_sta_addr_hi));
    try testing.expectEqual(@as(u32, 0xC611_2233), words.read(.mac_sta_addr));

    // Nothing written is nothing read, which is what the caller checks.
    const empty = Words{ .base = &store };
    writeStation(empty, @splat(0));
    try testing.expectEqual([6]u8{ 0, 0, 0, 0, 0, 0 }, readStation(empty));
}

test "a part is reset when every block has gone idle" {
    var store: [0x1600]u8 align(4) = @splat(0);
    const words = Words{ .base = &store };

    const Clock = struct {
        var slept: u32 = 0;
        fn tick(micros: u32) void {
            slept += micros;
        }
    };
    Clock.slept = 0;

    // The store reads zero everywhere, which is every block idle.
    try reset(words, Clock.tick);
    try testing.expectEqual(@as(u32, 0x1), words.read(.master_ctrl));
    try testing.expectEqual(@as(u32, 1_000), Clock.slept);

    // A part that never stops is given the whole budget and refused.
    words.write(.idle_status, @bitCast(IdleStatus{ .tx_queue = true }));
    Clock.slept = 0;
    try testing.expectError(error.StillBusy, reset(words, Clock.tick));
    try testing.expectEqual(@as(u32, 1_000 * (RESET_MS + 1)), Clock.slept);
}
