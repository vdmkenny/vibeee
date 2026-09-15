//! What a wired PHY says about the wire, in the standard's own words.
//!
//! An MDIO access is the driver's -- every MAC frames it differently, and
//! two of these parts have vendor registers the standard never heard of --
//! but the *registers* are the same on all of them: the basic status word
//! is defined once, in 802.3, and each driver was reading it into its own
//! idea of a link. Three drivers, three answers to "is there a carrier",
//! and one of them no answer at all.
//!
//! So what lives here is the interpretation, not the access. A driver
//! reads the words it needs and hands them over; this says what they mean,
//! once, tested, on the host.

const std = @import("std");
const testing = std.testing;

/// The registers a wired driver asks about the link.
pub const Register = enum(u8) {
    control = 0x00,
    status = 0x01,
    identifier_1 = 0x02,
    identifier_2 = 0x03,
    auto_negotiation_advertisement = 0x04,
    auto_negotiation_partner = 0x05,
    auto_negotiation_expansion = 0x06,
    _,
};

/// The basic control register, 802.3 clause 22.2.4. Every wired PHY has
/// this at register zero and answers to the same three bits.
pub const Control = packed struct(u16) {
    _0: u7 = 0,
    /// Let the link come up at half the speed the PHY otherwise would.
    collision_test: bool = false,
    full_duplex: bool = false,
    restart_autoneg: bool = false,
    isolate: bool = false,
    power_down: bool = false,
    autoneg_enable: bool = false,
    speed_100: bool = false,
    loopback: bool = false,
    reset: bool = false,
};

/// What the PHY offers the other end, 802.3 clause 28.2.4.1. Ten and a
/// hundred only: a thousand is offered in a register of its own, because
/// it was added to the standard after this one was full.
pub const Advertisement = packed struct(u16) {
    /// The protocol being negotiated. One is 802.3, which is the only one
    /// anything here speaks.
    selector: u5 = 1,
    ten_half: bool = false,
    ten_full: bool = false,
    hundred_half: bool = false,
    hundred_full: bool = false,
    hundred_t4: bool = false,
    pause: bool = false,
    asymmetric_pause: bool = false,
    _12: u1 = 0,
    remote_fault: bool = false,
    _14: u1 = 0,
    next_page: bool = false,
};

/// Everything a hundred megabit PHY can offer, with both kinds of pause.
pub const ADVERTISE_FAST = Advertisement{
    .ten_half = true,
    .ten_full = true,
    .hundred_half = true,
    .hundred_full = true,
    .pause = true,
    .asymmetric_pause = true,
};

/// The thousand megabit half, 802.3 clause 40.5. Register 9, which exists
/// only on a PHY that can go that fast.
pub const Gigabit = packed struct(u16) {
    _0: u8 = 0,
    thousand_half: bool = false,
    thousand_full: bool = false,
    _10: u2 = 0,
    /// Be the one that provides the clock, rather than letting the two
    /// ends work it out.
    manual_master: bool = false,
    manual_master_value: bool = false,
    manual_master_enable: bool = false,
    test_mode: u1 = 0,
};

/// The basic status register, 802.3 clause 22.2.4.
pub const Status = packed struct(u16) {
    extended_capability: bool = false,
    jabber_detect: bool = false,
    link_status: bool = false,
    auto_negotiation_ability: bool = false,
    remote_fault: bool = false,
    auto_negotiation_complete: bool = false,
    /// No preamble suppression, on a part that requires it.
    preamble_suppression: bool = false,
    _7: bool = false,
    extended_status: bool = false,
    /// 100BASE-T2 half duplex.
    t2_half: bool = false,
    t2_full: bool = false,
    /// 10BASE-T half duplex.
    t_half: bool = false,
    t_full: bool = false,
    /// 100BASE-X, TX or FX, half duplex.
    x_half: bool = false,
    x_full: bool = false,
    /// 100BASE-T4.
    t4: bool = false,
};

/// How fast, named by the number people say.
pub const Speed = enum(u16) {
    m10 = 10,
    m100 = 100,
    m1000 = 1000,

    pub fn mbps(self: Speed) u16 {
        return @intFromEnum(self);
    }
};

pub const Duplex = enum { half, full };

/// A wire with nothing on the other end of it: what a link is before one
/// is found, and after one is lost.
pub const DOWN: Outcome = .{ .up = false };

/// What the PHY made of the wire.
pub const Outcome = struct {
    up: bool = false,
    speed: Speed = .m10,
    duplex: Duplex = .half,
};

/// What the standard's own words mean: no carrier, and there is nothing
/// else to ask.
///
/// `link_status` is one bit and it is the whole answer to whether a wire
/// is attached; everything finer is the driver's vendor register, because
/// which one holds the resolved speed is not something 802.3 says.
pub fn outcome(status: Status) ?Outcome {
    if (!status.link_status) return null;
    return .{ .up = true };
}

/// The same, with the speed and duplex a vendor register resolved.
///
/// Taken as given rather than derived: a part that reports 100 full has
/// already done the negotiation, and second-guessing it from the
/// advertisement is how a driver decides a wire is something it is not.
pub fn resolved(status: Status, speed: Speed, duplex: Duplex) ?Outcome {
    if (!status.link_status) return null;
    return .{ .up = true, .speed = speed, .duplex = duplex };
}

test "a wire with nothing on it is not a link" {
    try testing.expectEqual(@as(?Outcome, null), outcome(.{ .link_status = false }));
    try testing.expectEqual(@as(?Outcome, null), resolved(.{ .link_status = false }, .m100, .full));
}

test "a carrier is a link, and the speed is the part's own word" {
    const up = outcome(.{ .link_status = true }).?;
    try testing.expect(up.up);
    try testing.expectEqual(Speed.m10, up.speed);

    const fast = resolved(.{ .link_status = true }, .m100, .full).?;
    try testing.expectEqual(@as(u16, 100), fast.speed.mbps());
    try testing.expectEqual(Duplex.full, fast.duplex);
}

test "the control and advertisement words are the standard's" {
    const word = struct {
        fn of(value: anytype) u16 {
            return @bitCast(value);
        }
    }.of;

    try testing.expectEqual(@as(u16, 0x8000), word(Control{ .reset = true }));
    try testing.expectEqual(@as(u16, 0x4000), word(Control{ .loopback = true }));
    try testing.expectEqual(@as(u16, 0x2000), word(Control{ .speed_100 = true }));
    try testing.expectEqual(@as(u16, 0x1000), word(Control{ .autoneg_enable = true }));
    try testing.expectEqual(@as(u16, 0x0800), word(Control{ .power_down = true }));
    try testing.expectEqual(@as(u16, 0x0200), word(Control{ .restart_autoneg = true }));
    try testing.expectEqual(@as(u16, 0x0100), word(Control{ .full_duplex = true }));

    // The selector defaults to 802.3, which is the one the field means
    // when a driver does not think about it.
    try testing.expectEqual(@as(u16, 0x0001), word(Advertisement{}));
    try testing.expectEqual(@as(u16, 0x0020), word(Advertisement{ .selector = 0, .ten_half = true }));
    try testing.expectEqual(@as(u16, 0x0040), word(Advertisement{ .selector = 0, .ten_full = true }));
    try testing.expectEqual(@as(u16, 0x0080), word(Advertisement{ .selector = 0, .hundred_half = true }));
    try testing.expectEqual(@as(u16, 0x0100), word(Advertisement{ .selector = 0, .hundred_full = true }));
    try testing.expectEqual(@as(u16, 0x0400), word(Advertisement{ .selector = 0, .pause = true }));
    try testing.expectEqual(@as(u16, 0x0800), word(Advertisement{ .selector = 0, .asymmetric_pause = true }));
    try testing.expectEqual(@as(u16, 0x0DE1), word(ADVERTISE_FAST));

    try testing.expectEqual(@as(u16, 0x0100), word(Gigabit{ .thousand_half = true }));
    try testing.expectEqual(@as(u16, 0x0200), word(Gigabit{ .thousand_full = true }));
}

test "a thousand megabits is a speed like the others" {
    try testing.expectEqual(@as(u16, 1000), Speed.m1000.mbps());
    const fast = resolved(.{ .link_status = true }, .m1000, .full).?;
    try testing.expectEqual(@as(u16, 1000), fast.speed.mbps());
}

test "the status word is the standard's, bit for bit" {
    // A Realtek and an Attansic reading the same wire report the same
    // word; the bit that matters is the one they are both asked about.
    const attached: u16 = 0x0004;
    try testing.expect(@as(Status, @bitCast(attached)).link_status);
    try testing.expect(!@as(Status, @bitCast(@as(u16, 0x0000))).link_status);
    try testing.expectEqual(@as(usize, 2), @sizeOf(Status));
}
