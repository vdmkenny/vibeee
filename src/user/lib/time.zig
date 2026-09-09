//! Formatting wall-clock times for display.
//!
//! The calendar arithmetic lives in `lib/civil.zig`, shared with the kernel.
//! This is the userspace half: turning a timestamp into the handful of shapes
//! tools actually print, in one place so `ls` and `date` cannot disagree about
//! what a date looks like.

const civil = @import("lib").civil;
const str = @import("lib").str;
const out = @import("out.zig");

pub const Civil = civil.Civil;

pub fn fromEpoch(seconds: i64) Civil {
    return civil.fromEpoch(seconds);
}

/// `2026-08-26 14:33:07`, unambiguous, sorts as text, and the shape a log or
/// a status line wants.
///
/// Built into a buffer, because the two callers want it in two places: a tool
/// prints it and a window draws it, and a stamp spelled twice is two shapes
/// that drift.
pub fn stamp(buf: []u8, seconds: i64) []const u8 {
    const c = fromEpoch(seconds);
    var line = str.Builder{ .buf = buf };

    line.number(@intCast(@max(c.year, 0)));
    line.byte('-');
    twoDigits(&line, c.month);
    line.byte('-');
    twoDigits(&line, c.day);
    line.byte(' ');
    writeClock(&line, c);
    line.byte(':');
    twoDigits(&line, c.second);
    return line.done();
}

/// Two digits, zero-padded. Every field of a clock reading wants this.
fn twoDigits(into: *str.Builder, value: u8) void {
    into.byte('0' + @as(u8, @intCast(value / 10 % 10)));
    into.byte('0' + @as(u8, @intCast(value % 10)));
}

/// The hour and minute of a reading, which is where every clock shape here
/// starts.
fn writeClock(line: *str.Builder, c: Civil) void {
    twoDigits(line, c.hour);
    line.byte(':');
    twoDigits(line, c.minute);
}

/// `14:33`, the shape a clock is glanced at in: a panel, a message line.
pub fn clock(buf: []u8, seconds: i64) []const u8 {
    var line = str.Builder{ .buf = buf };
    writeClock(&line, fromEpoch(seconds));
    return line.done();
}

/// `14:33:07`, for where the reading is being read rather than glanced at.
pub fn clockSeconds(buf: []u8, seconds: i64) []const u8 {
    const c = fromEpoch(seconds);
    var line = str.Builder{ .buf = buf };
    writeClock(&line, c);
    line.byte(':');
    twoDigits(&line, c.second);
    return line.done();
}

pub fn writeStamp(seconds: i64) void {
    var buf: [24]u8 = @splat(0);
    out.text(stamp(&buf, seconds));
}

/// A fixed-width 12-character listing column: `Aug 26 14:33` for something
/// recent, `Aug 26  2019` for anything further away than about six months.
///
/// Swapping the time for the year past that point is what `ls` has always
/// done, and for the same reason: the clock time of a file from years ago
/// carries no information anyone reading a listing wants, but the year does.
///
/// "Further away" in either direction, rather than only into the past. FAT
/// records no timezone, so a volume written by a machine in another one, or
/// by a host tool writing local time, which is most of them, carries stamps
/// hours ahead of our UTC clock. Treating those as ancient and printing the
/// year would be a worse answer than simply showing the time.
pub fn writeListed(seconds: i64, now: i64) void {
    if (seconds == 0) {
        out.text("           -");
        return;
    }

    const c = fromEpoch(seconds);
    out.text(civil.monthName(c.month));
    out.byte(' ');
    out.byte(if (c.day < 10) ' ' else '0' + @as(u8, @intCast(c.day / 10)));
    out.byte('0' + @as(u8, @intCast(c.day % 10)));
    out.byte(' ');

    const six_months: i64 = 182 * 24 * 3600;
    const distance = if (seconds > now) seconds - now else now - seconds;
    const recent = now != 0 and distance < six_months;

    if (recent) {
        var face: [5]u8 = undefined;
        var line = str.Builder{ .buf = &face };
        writeClock(&line, c);
        out.text(line.done());
    } else {
        out.byte(' ');
        out.decimal(c.year);
    }
}

const testing = @import("std").testing;

test "a clock reading is the same three fields wherever it is shown" {
    // 2026-09-11 04:37:21 UTC.
    const at: i64 = 1_789_101_441;

    var buf: [24]u8 = undefined;
    const full = stamp(&buf, at);

    var short: [8]u8 = undefined;
    var with_seconds: [8]u8 = undefined;

    // Each shape is a prefix of the one above it, because they are one
    // reading written to different lengths rather than three conversions.
    try testing.expectEqualStrings(full[11..16], clock(&short, at));
    try testing.expectEqualStrings(full[11..19], clockSeconds(&with_seconds, at));
}

test "every field is padded to two digits" {
    // 2001-02-03 04:05:06 UTC.
    const at: i64 = 981_173_106;
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("2001-02-03 04:05:06", stamp(&buf, at));

    var face: [8]u8 = undefined;
    try testing.expectEqualStrings("04:05", clock(&face, at));
    try testing.expectEqualStrings("04:05:06", clockSeconds(&face, at));
}

test "midnight is not blank and noon is not confused with it" {
    var face: [8]u8 = undefined;
    try testing.expectEqualStrings("00:00", clock(&face, 0));
    try testing.expectEqualStrings("12:00", clock(&face, 12 * 3600));
    try testing.expectEqualStrings("23:59:59", clockSeconds(&face, 24 * 3600 - 1));
}
