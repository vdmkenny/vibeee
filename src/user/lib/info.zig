//! Asking the kernel about itself.
//!
//! `sysinfo` returns text and a length, and every tool that used it was
//! repeating the same "negative means it failed, otherwise slice to the length"
//! dance. One place to get it wrong is enough.

const sys = @import("sys");
const str = @import("lib").str;

/// The value of `key`, or an empty string if the kernel does not know it.
///
/// Empty rather than an error: every caller wants to print what it got and
/// skip what it did not, and an error type would make each of them write the
/// same two lines to decide that.
pub fn ask(key: []const u8, buf: []u8) []const u8 {
    const n = sys.sysinfo(key, buf);
    return if (n > 0) buf[0..@intCast(n)] else "";
}

/// The value of `key` as a number, or zero.
pub fn askNumber(key: []const u8) usize {
    var buf: [32]u8 = @splat(0);
    return str.toUnsigned(ask(key, &buf));
}

/// Whether `name` appears in a newline-separated list the kernel returned.
pub fn listContains(key: []const u8, name: []const u8, buf: []u8) bool {
    var it = str.lines(ask(key, buf));
    while (it.next()) |line| {
        if (str.eql(str.trim(line), name)) return true;
    }
    return false;
}
