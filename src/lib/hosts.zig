//! The hosts table: names answered from a file before any server is asked.
//!
//! One line per address, `address name [name...]`, `#` comments, matching
//! the file format every networked system reads. Names compare without
//! case, the way DNS does. Pure text-in, answer-out; whoever resolves owns
//! reading the file.

const std = @import("std");
const ipv4 = @import("ipv4.zig");
const str = @import("str.zig");

/// The address the table gives `name`, or null when no line names it.
pub fn lookup(table: []const u8, name: []const u8) ?u32 {
    var lines = str.lines(table);
    while (lines.next()) |line| {
        const text = str.trim(uncommented(line));
        if (text.len == 0) continue;

        var words = str.words(text);
        const addr = ipv4.parse(words.next() orelse continue) orelse continue;
        while (words.next()) |candidate| {
            if (sameName(candidate, name)) return addr;
        }
    }
    return null;
}

fn uncommented(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c == '#') return line[0..i];
    }
    return line;
}

fn sameName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

test "a name resolves from its line, whatever the case" {
    const table =
        \\# the build machine
        \\192.0.2.10   builder builder.lan
        \\192.0.2.20   printer   # in the hallway
    ;
    try std.testing.expectEqual(@as(?u32, 0xC000020A), lookup(table, "builder"));
    try std.testing.expectEqual(@as(?u32, 0xC000020A), lookup(table, "BUILDER.LAN"));
    try std.testing.expectEqual(@as(?u32, 0xC0000214), lookup(table, "printer"));
    try std.testing.expectEqual(@as(?u32, null), lookup(table, "elsewhere"));
}

test "broken lines are passed over rather than tripped on" {
    const table =
        \\not-an-address  ghost
        \\192.0.2.9
        \\192.0.2.30 real
    ;
    try std.testing.expectEqual(@as(?u32, null), lookup(table, "ghost"));
    try std.testing.expectEqual(@as(?u32, 0xC000021E), lookup(table, "real"));
}
