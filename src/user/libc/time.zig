//! Time, in the two shapes C asks for it.
//!
//! No timezone database and no `localtime`: this machine has one clock, kept
//! in UTC, and a table of the world's daylight-saving rules is megabytes to
//! answer a question the settings can answer in a line. `gmtime` is here
//! because breaking a timestamp into fields is arithmetic, and that much is
//! worth having.

const civil = @import("lib").civil;
const errno = @import("errno.zig");
const sys = @import("sys");

pub const CLOCK_REALTIME = 0;
pub const CLOCK_MONOTONIC = 1;

pub const Timespec = extern struct {
    tv_sec: c_long,
    tv_nsec: c_long,
};

pub const Timeval = extern struct {
    tv_sec: c_long,
    tv_usec: c_long,
};

pub const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
};

export fn clock_gettime(which: c_int, out: *Timespec) callconv(.c) c_int {
    const micros: i64 = switch (which) {
        CLOCK_MONOTONIC => @intCast(sys.clockMicros()),
        CLOCK_REALTIME => sys.realtimeMicros() orelse 0,
        else => return @intCast(errno.fail(errno.EINVAL)),
    };

    out.tv_sec = @intCast(@divFloor(micros, 1_000_000));
    out.tv_nsec = @intCast(@mod(micros, 1_000_000) * 1000);
    return 0;
}

export fn gettimeofday(out: *Timeval, timezone: ?*anyopaque) callconv(.c) c_int {
    _ = timezone; // Obsolete in POSIX, and there is nothing to put in it.

    const micros = sys.realtimeMicros() orelse 0;
    out.tv_sec = @intCast(@divFloor(micros, 1_000_000));
    out.tv_usec = @intCast(@mod(micros, 1_000_000));
    return 0;
}

export fn time(out: ?*c_long) callconv(.c) c_long {
    const seconds: c_long = @intCast(@divFloor(sys.realtimeMicros() orelse 0, 1_000_000));
    if (out) |slot| slot.* = seconds;
    return seconds;
}

export fn nanosleep(wanted: *const Timespec, left: ?*Timespec) callconv(.c) c_int {
    sys.sleepMicros(@intCast(wanted.tv_sec * 1_000_000 + @divTrunc(wanted.tv_nsec, 1000)));
    // Nothing interrupts a sleep here, so none of it is ever left.
    if (left) |slot| slot.* = .{ .tv_sec = 0, .tv_nsec = 0 };
    return 0;
}

var broken: Tm = undefined;

/// UTC, always. `localtime` is the same function: with one clock and no
/// timezone table there is no local time to be different.
export fn gmtime(seconds: *const c_long) callconv(.c) *Tm {
    const parts = civil.fromEpoch(seconds.*);

    broken = .{
        .tm_sec = @intCast(parts.second),
        .tm_min = @intCast(parts.minute),
        .tm_hour = @intCast(parts.hour),
        .tm_mday = @intCast(parts.day),
        .tm_mon = @as(c_int, @intCast(parts.month)) - 1,
        .tm_year = @as(c_int, @intCast(parts.year)) - 1900,
        .tm_wday = @intCast(civil.weekday(seconds.*)),
        .tm_yday = 0,
        .tm_isdst = 0,
    };
    return &broken;
}

export fn localtime(seconds: *const c_long) callconv(.c) *Tm {
    return gmtime(seconds);
}
