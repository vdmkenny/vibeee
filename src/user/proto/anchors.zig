//! Places inside a program that can be reached from outside it.
//!
//! A launcher that could only start programs would make somebody looking for
//! the wallpaper open Settings and then hunt through it. What they are
//! looking for has a name, and the program knows it: this is where a program
//! says which of its own places are worth naming, and what to pass it to open
//! there.
//!
//! Declared rather than discovered. A program is not running when it is being
//! searched for, so nothing can ask it; and a file to parse would be a second
//! description to keep in step with the first. Each program contributes a
//! list built from whatever it already has, so Settings' sections advertise
//! themselves and cannot drift from the rail that draws them.

const std = @import("std");
const icons = @import("eui").icon;
const panes = @import("panes.zig");
const str = @import("lib").str;

/// One place inside a program.
pub const Anchor = struct {
    /// What to call it where somebody is reading a list of results. Not the
    /// bare tab name: "Help" in a list of programs says nothing about what it
    /// is help with.
    says: []const u8,
    /// What to pass the program to open there.
    arg: []const u8,
};

/// A program and the places inside it.
pub const Program = struct {
    /// What the program is called on disk, which is how this joins whatever
    /// list of programs the caller already has.
    name: []const u8,
    path: []const u8,
    /// The program's own picture, drawn beside each of its places: what a
    /// result is inside is as much of the answer as what it is called.
    mark: icons.Icon,
    anchors: []const Anchor,
};

/// Settings' own sections, from the enum the rail is drawn from.
const settings_anchors = blk: {
    const values = std.enums.values(panes.Section);
    var out: [values.len]Anchor = undefined;
    for (values, 0..) |which, i| {
        out[i] = .{ .says = which.says(), .arg = @tagName(which) };
    }
    const frozen = out;
    break :blk frozen;
};

/// Every program with places inside it. One line each; a program with none
/// does not appear.
pub const all = [_]Program{
    .{
        .name = "settings",
        .path = "/bin/settings",
        .mark = .sliders,
        .anchors = &settings_anchors,
    },
};

/// How many places there are in all, so a caller can size an array without
/// counting them at run time.
pub const TOTAL = blk: {
    var n: usize = 0;
    for (all) |program| n += program.anchors.len;
    break :blk n;
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "every section of settings is reachable by name" {
    try testing.expectEqual(std.enums.values(panes.Section).len, settings_anchors.len);

    for (settings_anchors) |anchor| {
        try testing.expect(anchor.says.len > 0);
        // The argument is what the program parses, so it has to be one of the
        // names it accepts.
        try testing.expect(panes.Section.parse(anchor.arg) != null);
    }
}

test "the count is what the lists actually hold" {
    var counted: usize = 0;
    for (all) |program| counted += program.anchors.len;
    try testing.expectEqual(TOTAL, counted);
}

test "no two places read the same" {
    for (all) |program| {
        for (program.anchors, 0..) |a, i| {
            for (program.anchors[i + 1 ..]) |b| {
                try testing.expect(!str.eql(a.says, b.says));
                try testing.expect(!str.eql(a.arg, b.arg));
            }
        }
    }
}
