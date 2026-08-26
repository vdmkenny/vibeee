//! Formatting wall-clock times for display.
//!
//! The calendar arithmetic lives in `lib/civil.zig`, shared with the kernel.
//! This is the userspace half: turning a timestamp into the handful of shapes
//! tools actually print, in one place so `ls` and `date` cannot disagree about
//! what a date looks like.

const civil = @import("lib").civil;
const out = @import("out.zig");

pub const Civil = civil.Civil;

pub fn fromEpoch(seconds: i64) Civil {
    return civil.fromEpoch(seconds);
}

/// Two digits, zero-padded. Every field of a clock reading wants this.
pub fn pair(value: u8) void {
    out.byte('0' + @as(u8, @intCast(value / 10 % 10)));
    out.byte('0' + @as(u8, @intCast(value % 10)));
}

/// `2026-08-26 14:33:07`, unambiguous, sorts as text, and the shape a log or
/// a status line wants.
pub fn writeStamp(seconds: i64) void {
    const c = fromEpoch(seconds);
    out.decimal(c.year);
    out.byte('-');
    pair(c.month);
    out.byte('-');
    pair(c.day);
    out.byte(' ');
    pair(c.hour);
    out.byte(':');
    pair(c.minute);
    out.byte(':');
    pair(c.second);
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
        pair(c.hour);
        out.byte(':');
        pair(c.minute);
    } else {
        out.byte(' ');
        out.decimal(c.year);
    }
}
