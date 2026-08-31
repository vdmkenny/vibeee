//! Turning a typed command word into a path to run.
//!
//! The rule is the one every shell has: a word with a slash in it is already
//! a path and is used as typed, and a word without one names a program in the
//! bin directory. The working directory is deliberately not searched for bare
//! names, so what runs depends on what was typed rather than on where you
//! happen to be standing.

const std = @import("std");

/// Whether `name` says where a program is rather than just naming one.
///
/// The same question decides what a word runs and what a half-typed word
/// completes against, so both ask it here.
pub fn isPath(name: []const u8) bool {
    return std.mem.indexOfScalar(u8, name, '/') != null;
}

/// The path `name` should be run from, or null if it does not fit in `buf`.
///
/// A path is returned as typed, whether absolute or relative: the kernel
/// resolves it against the working directory and collapses "." and ".."
/// there, in the one place that every syscall agrees on.
pub fn pathFor(name: []const u8, bin_dir: []const u8, buf: []u8) ?[]const u8 {
    if (name.len == 0) return null;
    if (isPath(name)) return name;

    if (bin_dir.len + name.len > buf.len) return null;
    @memcpy(buf[0..bin_dir.len], bin_dir);
    @memcpy(buf[bin_dir.len..][0..name.len], name);
    return buf[0 .. bin_dir.len + name.len];
}

const testing = std.testing;
const BIN = "/bin/";

test "a word says where a program is only if it has a separator" {
    try testing.expect(!isPath("doom"));
    try testing.expect(!isPath(""));
    try testing.expect(isPath("./doom"));
    try testing.expect(isPath("/home/doom"));
    try testing.expect(isPath("sub/prog"));
}

test "a bare name comes from the bin directory" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/bin/ls", pathFor("ls", BIN, &buf).?);
}

test "a relative path is used as typed" {
    var buf: [64]u8 = undefined;
    // The case that matters: a program sitting in the working directory is
    // reached by saying so, not by having the bin directory pasted in front.
    try testing.expectEqualStrings("./doom", pathFor("./doom", BIN, &buf).?);
    try testing.expectEqualStrings("../bin/doom", pathFor("../bin/doom", BIN, &buf).?);
    try testing.expectEqualStrings("sub/prog", pathFor("sub/prog", BIN, &buf).?);
}

test "an absolute path is used as typed" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/home/doom", pathFor("/home/doom", BIN, &buf).?);
}

test "a name that does not fit is refused rather than truncated" {
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), pathFor("verylongname", BIN, &buf));
    try testing.expectEqual(@as(?[]const u8, null), pathFor("", BIN, &buf));
}

test "the last byte of the buffer is usable" {
    var buf: [7]u8 = undefined;
    try testing.expectEqualStrings("/bin/ls", pathFor("ls", BIN, &buf).?);
}
