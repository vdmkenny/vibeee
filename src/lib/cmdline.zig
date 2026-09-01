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

/// What `line` gives as the value of `name`, when a word spells
/// `name=value`.
///
/// The same word rule as `has`: `wifi.txpower` is not found in
/// `nowifi.txpower=20`, and a word carrying no separator is a flag rather
/// than a setting, so it answers nothing. An empty value is a value, since
/// `name=` is how a caller says the setting is present and says nothing,
/// which is different from not naming it at all.
///
/// The result borrows from `line` and cannot outlive it.
pub fn value(line: []const u8, name: []const u8) ?[]const u8 {
    var words = std.mem.splitScalar(u8, line, ' ');
    while (words.next()) |word| {
        const at = std.mem.indexOfScalar(u8, word, '=') orelse continue;
        if (std.mem.eql(u8, word[0..at], name)) return word[at + 1 ..];
    }
    return null;
}

const testing = std.testing;

test "a setting gives up its value" {
    try testing.expectEqualStrings("31", value("verbose wifi.txpower=31 fb", "wifi.txpower").?);
    try testing.expectEqualStrings("fcc", value("wifi.regdomain=fcc", "wifi.regdomain").?);
    // Present and saying nothing is not the same as absent.
    try testing.expectEqualStrings("", value("wifi.regdomain=", "wifi.regdomain").?);
}

test "a setting is a whole word, and a flag is not a setting" {
    try testing.expectEqual(@as(?[]const u8, null), value("nowifi.txpower=20", "wifi.txpower"));
    try testing.expectEqual(@as(?[]const u8, null), value("verbose debug", "verbose"));
    try testing.expectEqual(@as(?[]const u8, null), value("", "verbose"));
    // A value may itself carry the separator; only the first one divides.
    try testing.expectEqualStrings("a=b", value("k=a=b", "k").?);
}

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
