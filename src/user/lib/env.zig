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

// How many entries there is room for is the kernel's number, not this
// side's: it is what `exec` will accept and what the stack frame is built
// to hold, so it is read from the one place both sides define it.
const MAX_ENV = @import("lib").syscalls.MAX_ENV;

/// The entries, as slices into the stack the kernel built.
var entries: [MAX_ENV][]const u8 = undefined;
var count: usize = 0;

/// Take the environment out of the frame a program started on.
///
/// Called from `_start`, because that is the only place the frame is in
/// hand: nothing later can find it again.
pub fn adopt(frame: [*]const u32) void {
    const named: usize = frame[0];

    // Past the arguments and the null that ends them.
    var at = 1 + named + 1;
    count = 0;
    while (count < entries.len and frame[at] != 0) : (at += 1) {
        entries[count] = std.mem.span(@as([*:0]const u8, @ptrFromInt(frame[at])));
        count += 1;
    }
}

/// How many arguments the program was started with, its own name included.
pub fn argc(frame: [*]const usize) usize {
    return frame[0];
}

/// The nth argument, or null past the end. Zero is the program's own name,
/// which is what it was invoked as rather than where it lives.
pub fn arg(frame: [*]const usize, index: usize) ?[]const u8 {
    if (index >= argc(frame)) return null;
    const pointer = frame[1 + index];
    if (pointer == 0) return null;
    return std.mem.span(@as([*:0]const u8, @ptrFromInt(pointer)));
}

/// The first thing after the program's own name: the file to open, the place
/// to start in, the section to show. Four windows read this out of the frame
/// by hand before it was one call.
pub fn argument(frame: [*]const usize) ?[]const u8 {
    return arg(frame, 1);
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
    if (!std.mem.eql(u8, entry[0..name.len], name)) return null;
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

test "the arguments are read out of the frame the program starts on" {
    // A start frame as the kernel lays one out: how many, then a pointer
    // each, then the null that ends them.
    const first = "efm\x00";
    const second = "/home/pictures\x00";

    var frame = [_]usize{
        2,
        @intFromPtr(first.ptr),
        @intFromPtr(second.ptr),
        0,
    };

    try std.testing.expectEqual(@as(usize, 2), argc(&frame));
    try std.testing.expectEqualStrings("efm", arg(&frame, 0).?);
    try std.testing.expectEqualStrings("/home/pictures", arg(&frame, 1).?);
    try std.testing.expectEqualStrings("/home/pictures", argument(&frame).?);
    try std.testing.expectEqual(@as(?[]const u8, null), arg(&frame, 2));
}

test "a program started with nothing after its name has no argument" {
    var frame = [_]usize{ 1, @intFromPtr("pad\x00".ptr), 0 };
    try std.testing.expectEqual(@as(?[]const u8, null), argument(&frame));
    try std.testing.expectEqualStrings("pad", arg(&frame, 0).?);
}
