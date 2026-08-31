//! Calendar arithmetic: seconds since the Unix epoch to a date, and back.
//!
//! Lives in `lib/` rather than in the kernel because both sides need it and
//! neither owns it. The kernel converts a date when it stamps a FAT directory
//! entry; userspace converts one when it prints a time. Sharing the code means
//! there is one leap-year rule in the system rather than two that can disagree.
//!
//! Everything here is pure arithmetic with no allocation, no state and no
//! platform dependency, which is what makes it safe to compile into both.
//!
//! Time zones are deliberately absent. The hardware clock is read as UTC and
//! kept as UTC; a local-time offset is a display concern, and applying one here
//! would mean every caller had to know whether the value it held had already
//! been shifted.

/// A broken-down date and time. Fields are as written, not as C leaves them:
/// `year` is the full year and `month` is 1-12, because an off-by-1900 year and
/// a 0-based month have caused more bugs than they ever saved bytes.
pub const Civil = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub const SECONDS_PER_DAY: i64 = 86_400;

/// Days from 1970-01-01 to the given date, negative before it.
///
/// Howard Hinnant's `days_from_civil`: it shifts the year to start in March so
/// the leap day lands at the end, which removes the special case that makes the
/// naive version so easy to get wrong. Valid for any proleptic Gregorian date.
pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const m: i64 = month;
    const d: i64 = day;

    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;

    return era * 146_097 + doe - 719_468;
}

pub const Date = struct { year: i32, month: u8, day: u8 };

/// The inverse of `daysFromCivil`.
pub fn civilFromDays(days: i64) Date {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153); // [0, 11], March-based
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else -9);

    return .{
        .year = @intCast(y + @intFromBool(m <= 2)),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

/// Seconds since 1970-01-01 00:00:00 UTC.
pub fn toEpoch(c: Civil) i64 {
    const days = daysFromCivil(c.year, c.month, c.day);
    return days * SECONDS_PER_DAY +
        @as(i64, c.hour) * 3600 + @as(i64, c.minute) * 60 + c.second;
}

/// The inverse of `toEpoch`.
pub fn fromEpoch(seconds: i64) Civil {
    // Floor division rather than truncation, so times before the epoch land on
    // the previous day instead of rounding towards it.
    const days = @divFloor(seconds, SECONDS_PER_DAY);
    const rem = seconds - days * SECONDS_PER_DAY;
    const date = civilFromDays(days);

    return .{
        .year = @intCast(date.year),
        .month = date.month,
        .day = date.day,
        .hour = @intCast(@divTrunc(rem, 3600)),
        .minute = @intCast(@divTrunc(@mod(rem, 3600), 60)),
        .second = @intCast(@mod(rem, 60)),
    };
}

/// 0 = Sunday. 1970-01-01 was a Thursday, hence the offset.
pub fn weekday(seconds: i64) u3 {
    const days = @divFloor(seconds, SECONDS_PER_DAY);
    return @intCast(@mod(days + 4, 7));
}

pub const DAY_NAMES = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
pub const MONTH_NAMES = [12][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

/// The names written out. A listing column has three letters to spend and a
/// panel with room for the word should use it: "Tue 1 Sep" is what a table
/// says, "Tuesday 1 September" is what a person reading one line says.
pub const DAY_NAMES_FULL = [7][]const u8{
    "Sunday",   "Monday", "Tuesday",  "Wednesday",
    "Thursday", "Friday", "Saturday",
};
pub const MONTH_NAMES_FULL = [12][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

pub fn monthName(month: u8) []const u8 {
    return if (month >= 1 and month <= 12) MONTH_NAMES[month - 1] else "???";
}

pub fn monthNameFull(month: u8) []const u8 {
    return if (month >= 1 and month <= 12) MONTH_NAMES_FULL[month - 1] else "unknown";
}

pub fn dayNameFull(seconds: i64) []const u8 {
    return DAY_NAMES_FULL[weekday(seconds)];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");

test "epoch round trip" {
    const cases = [_]Civil{
        .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 },
        .{ .year = 1980, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 },
        .{ .year = 2000, .month = 2, .day = 29, .hour = 12, .minute = 0, .second = 0 },
        .{ .year = 2026, .month = 8, .day = 26, .hour = 23, .minute = 59, .second = 59 },
        .{ .year = 2100, .month = 3, .day = 1, .hour = 6, .minute = 30, .second = 15 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c, fromEpoch(toEpoch(c)));
    }
}

test "known epoch values" {
    try std.testing.expectEqual(@as(i64, 0), toEpoch(.{
        .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0,
    }));
    // 2001-09-09T01:46:40Z, the billionth second.
    try std.testing.expectEqual(@as(i64, 1_000_000_000), toEpoch(.{
        .year = 2001, .month = 9, .day = 9, .hour = 1, .minute = 46, .second = 40,
    }));
    // 1900 is not a leap year but 2000 is; the century rule is where naive
    // implementations diverge.
    try std.testing.expectEqual(@as(i64, 951_782_400), toEpoch(.{
        .year = 2000, .month = 2, .day = 29, .hour = 0, .minute = 0, .second = 0,
    }));
}

test "weekday" {
    // 1970-01-01 was a Thursday.
    try std.testing.expectEqual(@as(u3, 4), weekday(0));
    // 2026-08-26 is a Wednesday.
    try std.testing.expectEqual(@as(u3, 3), weekday(toEpoch(.{
        .year = 2026, .month = 8, .day = 26, .hour = 0, .minute = 0, .second = 0,
    })));
}

test "the names written out say the same day as the short ones" {
    // 2026-08-26 is a Wednesday.
    const when = toEpoch(.{ .year = 2026, .month = 8, .day = 26, .hour = 0, .minute = 0, .second = 0 });
    try std.testing.expectEqualStrings("Wednesday", dayNameFull(when));
    try std.testing.expectEqualStrings("Wed", DAY_NAMES[weekday(when)]);

    try std.testing.expectEqualStrings("August", monthNameFull(8));
    try std.testing.expectEqualStrings("Aug", monthName(8));

    // Every month has both spellings, and they agree on which month it is.
    for (1..13) |month| {
        const m: u8 = @intCast(month);
        try std.testing.expect(std.mem.startsWith(u8, monthNameFull(m), monthName(m)[0..1]));
    }

    // Out of range says so rather than indexing past the table.
    try std.testing.expectEqualStrings("unknown", monthNameFull(0));
    try std.testing.expectEqualStrings("unknown", monthNameFull(13));
}

test "before the epoch" {
    const c = Civil{ .year = 1969, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59 };
    try std.testing.expectEqual(@as(i64, -1), toEpoch(c));
    try std.testing.expectEqual(c, fromEpoch(-1));
}
