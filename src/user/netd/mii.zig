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

/// How fast, in the only two directions these parts go.
pub const Speed = enum(u16) {
    m10 = 10,
    m100 = 100,

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
    try std.testing.expectEqual(@as(?Outcome, null), outcome(.{ .link_status = false }));
    try std.testing.expectEqual(@as(?Outcome, null), resolved(.{ .link_status = false }, .m100, .full));
}

test "a carrier is a link, and the speed is the part's own word" {
    const up = outcome(.{ .link_status = true }).?;
    try std.testing.expect(up.up);
    try std.testing.expectEqual(Speed.m10, up.speed);

    const fast = resolved(.{ .link_status = true }, .m100, .full).?;
    try std.testing.expectEqual(@as(u16, 100), fast.speed.mbps());
    try std.testing.expectEqual(Duplex.full, fast.duplex);
}

test "the status word is the standard's, bit for bit" {
    // A Realtek and an Attansic reading the same wire report the same
    // word; the bit that matters is the one they are both asked about.
    const attached: u16 = 0x0004;
    try std.testing.expect(@as(Status, @bitCast(attached)).link_status);
    try std.testing.expect(!@as(Status, @bitCast(@as(u16, 0x0000))).link_status);
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(Status));
}
