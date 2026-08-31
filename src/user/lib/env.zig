//! What a program was told about where it is.
//!
//! A list of `NAME=value` strings the parent handed over, arriving on the
//! stack after the arguments because that is where C's own layout puts
//! it. A program written in Zig reads it the same way a program written
//! in C does, which is the point: the two are the same program to
//! everything below them.
//!
//! Read-only here. Changing an environment is something a program does to
//! its *children*, by handing them a different one, and the shell is the
//! only thing that wants to.

const str = @import("lib").str;
const sys = @import("sys");

/// The entries, as slices into the stack the kernel built.
var entries: [sys.MAX_ENV][]const u8 = undefined;
var count: usize = 0;

/// Take the environment out of the frame a program started on.
///
/// Called from `_start`, because that is the only place the frame is in
/// hand: nothing later can find it again.
pub fn adopt(frame: [*]const u32) void {
    const argc: usize = frame[0];

    // Past the arguments and the null that ends them.
    var at = 1 + argc + 1;
    count = 0;
    while (count < entries.len and frame[at] != 0) : (at += 1) {
        entries[count] = str.span(@as([*:0]const u8, @ptrFromInt(frame[at])));
        count += 1;
    }
}

/// Everything this program was told, for handing on to a child.
pub fn all() []const []const u8 {
    return entries[0..count];
}

/// What one name was set to, or null when it was not set at all.
///
/// Null rather than empty: a program asking where home is should take its
/// own default when nobody said, and an empty answer is somebody saying
/// "nowhere".
pub fn get(name: []const u8) ?[]const u8 {
    for (entries[0..count]) |entry| {
        if (valueOf(entry, name)) |value| return value;
    }
    return null;
}

/// The value in `NAME=value`, when the name is the one being asked about.
/// Compared whole, so `HOMEBREW` is not `HOME`.
pub fn valueOf(entry: []const u8, name: []const u8) ?[]const u8 {
    if (entry.len < name.len + 1) return null;
    if (entry[name.len] != '=') return null;
    if (!str.eql(entry[0..name.len], name)) return null;
    return entry[name.len + 1 ..];
}

const std = @import("std");

test "a name is matched whole, and its value is what follows the sign" {
    try std.testing.expectEqualStrings("/home", valueOf("HOME=/home", "HOME").?);
    try std.testing.expectEqualStrings("", valueOf("HOME=", "HOME").?);

    // A longer name that begins the same way is a different name.
    try std.testing.expect(valueOf("HOMEBREW=/x", "HOME") == null);
    try std.testing.expect(valueOf("HOM=/x", "HOME") == null);
    try std.testing.expect(valueOf("HOME", "HOME") == null);
    try std.testing.expect(valueOf("", "HOME") == null);

    // A value with a sign in it belongs to the value.
    try std.testing.expectEqualStrings("a=b", valueOf("K=a=b", "K").?);
}
