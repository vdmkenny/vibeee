//! System timekeeping: one monotonic clock, one wall clock.
//!
//! The monotonic clock counts microseconds since boot and is the timer's
//! business. The wall clock is derived from it, an offset established once,
//! plus however long the machine has been up, rather than read from hardware
//! on demand. Two reasons:
//!
//!   * Reading the CMOS RTC costs several I/O port round trips and has to be
//!     retried to avoid catching a mid-carry update. Doing that on every
//!     timestamp would make writing a file measurably slower.
//!   * The RTC has one-second resolution and can be corrected underneath us.
//!     Deriving from the monotonic counter gives microseconds, and guarantees
//!     that two timestamps taken in order compare in order.
//!
//! Where the initial offset comes from is not this module's concern. The RTC
//! supplies it at boot; SNTP will supply a better one later, over the network,
//! by calling `set` again. Both go through the same door, so nothing else in
//! the system needs to learn that the time source changed.
//!
//! UTC throughout, never local time. See `lib/civil.zig`.

const civil = @import("lib").civil;
const hal = @import("hal.zig");

/// Microseconds to add to the monotonic clock to get wall time, or null while
/// no source has reported one. Null rather than zero: a machine whose RTC is
/// dead should say it does not know the time, not claim it is 1970.
var epoch_offset_us: ?i64 = null;

/// Where the current offset came from, for the boot log and `date`.
///
/// Copied rather than borrowed. A name arriving through a syscall is the
/// caller's memory, and a slice kept into it says whatever happens to be at
/// that address by the time somebody reads it, which is a use of memory the
/// caller may have freed and a way to read out what replaced it.
var source_buf: [16]u8 = ("none" ++ [_]u8{0} ** 12).*;
var source_len: usize = "none".len;

/// Microseconds since boot. Monotonic: never steps, never runs backwards.
pub fn monotonicMicros() u64 {
    return hal.monotonicMicros();
}

/// Adopt `epoch_us` as the current wall-clock time.
///
/// The offset is what is stored, not the timestamp, so the clock keeps running
/// afterwards at the monotonic clock's rate.
pub fn set(epoch_us: i64, from: []const u8) void {
    epoch_offset_us = epoch_us - @as(i64, @intCast(monotonicMicros()));
    source_len = @min(from.len, source_buf.len);
    @memcpy(source_buf[0..source_len], from[0..source_len]);
}

pub fn setCivil(c: civil.Civil, from: []const u8) void {
    set(civil.toEpoch(c) * 1_000_000, from);
}

/// Whether the wall clock has been set at all.
pub fn valid() bool {
    return epoch_offset_us != null;
}

pub fn sourceName() []const u8 {
    return source_buf[0..source_len];
}

/// Microseconds since the Unix epoch, or 0 if the clock was never set.
///
/// Zero rather than an error: every caller would have to handle the error and
/// almost all of them would handle it by substituting zero anyway. Callers that
/// genuinely care ask `valid()` first.
pub fn realtimeMicros() i64 {
    const offset = epoch_offset_us orelse return 0;
    return offset + @as(i64, @intCast(monotonicMicros()));
}

pub fn realtimeSeconds() i64 {
    return @divFloor(realtimeMicros(), 1_000_000);
}

pub fn nowCivil() civil.Civil {
    return civil.fromEpoch(realtimeSeconds());
}
