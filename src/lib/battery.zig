//! Battery arithmetic, pure.
//!
//! The platform service reads `_BIF` and `_BST` and answers a `Battery`; this
//! is the part of the answer that is computation rather than firmware: what
//! the flags mean, what a charge percentage is, how long a drain will last.
//! Kept here, in the layer nothing below can import from, so it is testable
//! on the host and shared by every program that will draw a battery.
//!
//! Inputs are plain numbers rather than a struct, because the struct is the
//! wire format's business and the arithmetic does not care which one brought
//! it.

/// The ACPI format's `STATE` flags, what the firmware means by each bit.
pub const Flags = packed struct(u8) {
    discharging: bool = false,
    charging: bool = false,
    critical: bool = false,
    _rest: u5 = 0,
};

/// What a pack is doing, as one thing rather than three flags. The flags are
/// how the format says it; this is what each combination means, and deriving
/// it once here keeps every caller from re-deriving the same precedence.
pub const State = enum(u8) {
    charging,
    discharging,
    /// Takes precedence over everything: a pack in trouble is that before
    /// it is anything else.
    critical,
    /// Neither filling, draining nor in trouble.
    full,
};

pub fn state(flags: Flags) State {
    if (flags.critical) return .critical;
    if (flags.charging) return .charging;
    if (flags.discharging) return .discharging;
    return .full;
}

/// The state in words, one name for every caller that shows it.
pub fn stateLabel(current: State) []const u8 {
    return switch (current) {
        .charging => "charging",
        .discharging => "discharging",
        .critical => "critical",
        .full => "full",
    };
}

/// A part of a whole as a percentage, or null when the whole cannot be said.
///
/// Saturated at 999, because a firmware that misreports one of the pair
/// should produce a suspicious-looking number, not an overflow.
pub fn percent(part: u32, whole: u32) ?u32 {
    if (whole == 0 or whole == UNKNOWN or part == UNKNOWN) return null;
    return @intCast(@min(@as(u64, part) * 100 / whole, 999));
}

/// The value a percentage mislabeled as a capacity amounts to.
///
/// Some firmware says "last full capacity 100" beside an honest design
/// capacity of 5200: correcting is `percentToCapacity(100, 5200) == 5200`,
/// and correcting never yields more than the design.
pub fn percentToCapacity(pct: u32, design: u32) u32 {
    return @intCast(@min(@as(u64, pct) * design / 100, design));
}

/// What the firmware says when it does not know. Not the same as zero, and
/// worth keeping apart: zero capacity is a fact, this is a refusal.
pub const UNKNOWN: u32 = 0xFFFF_FFFF;

/// How much longer a drain will last.
pub const TimeLeft = struct {
    hours: u16 = 0,
    minutes: u8 = 0,
};

/// The estimate, when the pair that makes one is there.
///
/// Capacity over rate, in whichever unit a pack reports the pair:
/// milliamp-hours over milliamps is hours, and the watt pair is the same
/// shape, which is why the caller hands both in the unit the firmware chose.
pub fn runtimeLeft(remaining: u32, rate: u32) ?TimeLeft {
    if (remaining == UNKNOWN or rate == 0 or rate == UNKNOWN) return null;

    const total_minutes = @as(u64, remaining) * 60 / rate;
    return .{
        .hours = @intCast(@min(total_minutes / 60, std.math.maxInt(u16))),
        .minutes = @intCast(total_minutes % 60),
    };
}

// ---------------------------------------------------------------------------
// Tests. The home of the arithmetic is here, so this is where it is proved.
// ---------------------------------------------------------------------------

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "state flags collapse into the one with precedence" {
    try expectEqual(State.discharging, state(.{ .discharging = true }));
    try expectEqual(State.charging, state(.{ .charging = true }));
    try expectEqual(State.full, state(.{}));
    // A pack in trouble is that before it is anything else.
    try expectEqual(State.critical, state(.{
        .discharging = true,
        .charging = true,
        .critical = true,
    }));
}

test "a percentage is the part of the whole, and nothing of nothing" {
    try expectEqual(@as(?u32, 50), percent(2600, 5200));
    try expectEqual(@as(?u32, 100), percent(5200, 5200));
    try expectEqual(null, percent(2600, 0));
    try expectEqual(null, percent(UNKNOWN, 5200));
    // A firmware that overshoots is saturated, not wrapped.
    try expectEqual(@as(?u32, 999), percent(50000, 100));
}

test "a mislabeled percentage becomes the capacity it means" {
    try expectEqual(@as(u32, 0), percentToCapacity(0, 5200));
    try expectEqual(@as(u32, 5200), percentToCapacity(100, 5200));
    try expectEqual(@as(u32, 2600), percentToCapacity(50, 5200));
    // Never more than the design, whatever the firmware said.
    try expectEqual(@as(u32, 5200), percentToCapacity(150, 5200));
}

test "time left divides capacity by rate, in whatever unit" {
    // 2600 over 650 is exactly four hours.
    try expectEqual(
        @as(?TimeLeft, .{ .hours = 4, .minutes = 0 }),
        runtimeLeft(2600, 650),
    );
    // Ninety minutes crosses the hour boundary.
    try expectEqual(
        @as(?TimeLeft, .{ .hours = 1, .minutes = 30 }),
        runtimeLeft(1500, 1000),
    );
    try expect(belowAnHour(runtimeLeft(500, 1000).?));

    // The pairs that carry no answer.
    try expectEqual(null, runtimeLeft(2600, 0));
    try expectEqual(null, runtimeLeft(UNKNOWN, 650));
    try expectEqual(null, runtimeLeft(2600, UNKNOWN));
}

fn belowAnHour(left: TimeLeft) bool {
    return left.hours == 0 and left.minutes == 30;
}
