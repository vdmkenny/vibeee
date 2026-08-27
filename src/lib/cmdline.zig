//! Kernel command line, asked and answered.
//!
//! The boot paths hand the kernel one string, and every reader of it was
//! reaching for `std.mem.indexOf` on their own. That matches
//! `noverbose` as if it were `verbose`, and when the fifth flag arrives the
//! same mistake arrives a fifth time. One word-aware `has` here, testable on
//! the host, is what every reader shares instead.
//!
//! Pure, so it lives in `lib` where tests actually run.

const std = @import("std");

/// Whether `line` carries `name` as a whole flag.
///
/// A flag is a word, delimited by spaces, so `debug` is present in
/// `"verbose debug fb"` and absent from `"xdebug"`. The caller hands slices
/// of the same string without cloning anything; a flag cannot outlive the
/// line it came from.
pub fn has(line: []const u8, name: []const u8) bool {
    var words = std.mem.splitScalar(u8, line, ' ');
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, name)) return true;
    }
    return false;
}

const testing = std.testing;

test "a flag is found among others" {
    try testing.expect(has("verbose debug fb", "debug"));
    try testing.expect(has("fb verbose", "verbose"));
    try testing.expect(has("verbose", "verbose"));
}

test "a flag is a whole word" {
    try testing.expect(!has("xdebug", "debug"));
    try testing.expect(!has("noverbose", "verbose"));
    try testing.expect(!has("", "verbose"));
}

test "extra spaces never make a fake flag" {
    try testing.expect(has("  verbose   fb ", "fb"));
    try testing.expect(!has("v e r b o s e", "verbose"));
}