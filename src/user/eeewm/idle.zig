//! What the machine does when it is left alone, and when the pack runs out.
//!
//! The backlight is most of what this machine draws, so the minutes after
//! somebody stops typing are most of what decides how long a charge lasts.
//! The manager is where this belongs: it is the process every key and every
//! movement already reaches, and the only one that knows the difference
//! between a machine nobody is using and one running something.
//!
//! Nothing polls. The deadline for the next thing due is handed to the same
//! wait the rest of the loop uses, so a machine left alone costs one wake at
//! the moment it has something to do.
//!
//! The arithmetic is pure and tested; what it decides is carried out by the
//! caller, which is the half that talks to the platform service.

const std = @import("std");
const settings = @import("proto").settings;

/// What the machine should be doing to its screen.
pub const State = enum {
    /// Somebody is here.
    awake,
    /// Left alone long enough to turn the panel down.
    dim,
    /// Left alone long enough to turn it off.
    off,
};

/// What has to happen next, and when.
pub const Step = struct {
    /// What the screen should be in.
    want: State,
    /// Microseconds until the next change is due, or null when nothing is.
    /// A caller with nothing else waiting waits this long and no longer.
    due_us: ?u64,
};

/// Where things stand, given how long it has been since anybody did anything.
///
/// Both intervals may be `never`, and the second may be shorter than the
/// first: a person is choosing two numbers separately and nothing stops them
/// crossing. Off wins when they do, because it is the stronger answer and the
/// one that saves more.
pub fn stepFor(power: settings.Power, idle_us: u64) Step {
    const dim_us = seconds(power.dim_after);
    const off_us = seconds(power.blank_after);

    const dimmed = dim_us != null and idle_us >= dim_us.?;
    const blanked = off_us != null and idle_us >= off_us.?;

    const want: State = if (blanked) .off else if (dimmed) .dim else .awake;

    return .{ .want = want, .due_us = nextDue(dim_us, off_us, idle_us) };
}

/// How long until whichever deadline has not passed yet.
fn nextDue(dim_us: ?u64, off_us: ?u64, idle_us: u64) ?u64 {
    var soonest: ?u64 = null;
    for ([_]?u64{ dim_us, off_us }) |at| {
        const when = at orelse continue;
        if (when <= idle_us) continue;
        const left = when - idle_us;
        soonest = if (soonest) |so_far| @min(so_far, left) else left;
    }
    return soonest;
}

fn seconds(interval: settings.Idle) ?u64 {
    const secs = interval.seconds() orelse return null;
    return @as(u64, secs) * 1_000_000;
}

/// The backlight level a state wants, given the level in use.
///
/// Dim is a share of what was chosen rather than a fixed number: a panel set
/// low already should not brighten when it dims, and one set high should go
/// somewhere worth the trouble.
pub fn levelFor(want: State, chosen: u32, dim_to: u8, lowest: u32) u32 {
    return switch (want) {
        .awake => chosen,
        .dim => @max(lowest, chosen * @as(u32, @min(dim_to, 100)) / 100),
        .off => 0,
    };
}

/// Whether the pack has reached the point the action was chosen for.
pub fn packIsLow(percent: u32, discharging: bool, at: u8) bool {
    return discharging and percent <= at;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const SECOND: u64 = 1_000_000;

test "nothing happens while somebody is there" {
    const power = settings.Power{ .dim_after = .@"1m", .blank_after = .@"10m" };
    const step = stepFor(power, 5 * SECOND);

    try testing.expectEqual(State.awake, step.want);
    // Due when the first of the two falls, not when the interval began.
    try testing.expectEqual(@as(?u64, 55 * SECOND), step.due_us);
}

test "the panel dims, then goes off" {
    const power = settings.Power{ .dim_after = .@"1m", .blank_after = .@"5m" };

    try testing.expectEqual(State.awake, stepFor(power, 59 * SECOND).want);
    try testing.expectEqual(State.dim, stepFor(power, 60 * SECOND).want);
    try testing.expectEqual(State.dim, stepFor(power, 299 * SECOND).want);
    try testing.expectEqual(State.off, stepFor(power, 300 * SECOND).want);

    // Once both have passed there is nothing further due.
    try testing.expectEqual(@as(?u64, null), stepFor(power, 600 * SECOND).due_us);
}

test "never means never, at either end" {
    const neither = settings.Power{ .dim_after = .never, .blank_after = .never };
    try testing.expectEqual(State.awake, stepFor(neither, 3600 * SECOND).want);
    try testing.expectEqual(@as(?u64, null), stepFor(neither, 3600 * SECOND).due_us);

    const only_off = settings.Power{ .dim_after = .never, .blank_after = .@"1m" };
    try testing.expectEqual(State.awake, stepFor(only_off, 30 * SECOND).want);
    try testing.expectEqual(State.off, stepFor(only_off, 60 * SECOND).want);
    try testing.expectEqual(@as(?u64, 30 * SECOND), stepFor(only_off, 30 * SECOND).due_us);
}

test "off wins when somebody sets it sooner than dim" {
    // Two numbers chosen separately can cross, and the stronger answer is the
    // one that saves more.
    const crossed = settings.Power{ .dim_after = .@"10m", .blank_after = .@"1m" };
    try testing.expectEqual(State.off, stepFor(crossed, 60 * SECOND).want);
    try testing.expectEqual(State.off, stepFor(crossed, 600 * SECOND).want);
}

test "dim is a share of what was chosen, and never nothing" {
    // A panel set high goes somewhere worth the trouble.
    try testing.expectEqual(@as(u32, 4), levelFor(.dim, 15, 30, 1));
    // One already low stays visible rather than going out.
    try testing.expectEqual(@as(u32, 1), levelFor(.dim, 2, 30, 1));
    try testing.expectEqual(@as(u32, 1), levelFor(.dim, 1, 30, 1));

    try testing.expectEqual(@as(u32, 15), levelFor(.awake, 15, 30, 1));
    try testing.expectEqual(@as(u32, 0), levelFor(.off, 15, 30, 1));
}

test "the pack is only low while it is emptying" {
    try testing.expect(packIsLow(5, true, 5));
    try testing.expect(packIsLow(3, true, 5));
    try testing.expect(!packIsLow(6, true, 5));
    // On mains it is filling, however little is in it.
    try testing.expect(!packIsLow(3, false, 5));
}
