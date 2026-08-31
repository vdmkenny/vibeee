//! Fixed tables of things that come and go.
//!
//! A driver server holds its devices in an array with a bound rather than
//! a list that grows: a table that cannot grow without limit is one that
//! cannot exhaust memory while something is being plugged in. Every such
//! table is then walked the same two ways, and those walks are here so
//! they are written once.
//!
//! A row is in use when its `live` field says so, which is the one thing
//! every table here agrees about.

const std = @import("std");

/// The first row nothing is using, ready to be filled in.
pub fn free(rows: anytype) ?*Row(@TypeOf(rows)) {
    for (rows) |*row| {
        if (!row.live) return row;
    }
    return null;
}

/// The row in use whose `field` equals `wanted`, which is how a device is
/// found again by whatever names it: an address, a handle, a port.
pub fn by(rows: anytype, comptime field: []const u8, wanted: anytype) ?*Row(@TypeOf(rows)) {
    for (rows) |*row| {
        if (row.live and @field(row, field) == wanted) return row;
    }
    return null;
}

/// How many rows are in use.
pub fn live(rows: anytype) usize {
    var count: usize = 0;
    for (rows) |*row| {
        if (row.live) count += 1;
    }
    return count;
}

/// Where a row sits in its own table, which is the number the thing it
/// stands for is known by outside.
pub fn indexOf(rows: anytype, row: anytype) usize {
    return (@intFromPtr(row) - @intFromPtr(&rows[0])) / @sizeOf(Row(@TypeOf(rows)));
}

fn Row(comptime Rows: type) type {
    const info = @typeInfo(Rows).pointer;
    return switch (@typeInfo(info.child)) {
        .array => |array| array.child,
        else => info.child,
    };
}

const Thing = struct { live: bool = false, address: u8 = 0, name: u8 = 0 };

test "a free row is the first one nothing is using" {
    var things: [3]Thing = @splat(.{});

    const first = free(&things) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), indexOf(&things, first));
    first.* = .{ .live = true, .address = 7 };

    const second = free(&things) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), indexOf(&things, second));
    second.* = .{ .live = true, .address = 9 };
    things[2] = .{ .live = true, .address = 11 };

    try std.testing.expect(free(&things) == null);
    try std.testing.expectEqual(@as(usize, 3), live(&things));

    // A row given up is the next one handed out.
    things[1].live = false;
    try std.testing.expectEqual(@as(usize, 1), indexOf(&things, free(&things).?));
    try std.testing.expectEqual(@as(usize, 2), live(&things));
}

test "a row is found by what names it, and only while it is in use" {
    var things: [3]Thing = @splat(.{});
    things[0] = .{ .live = true, .address = 7, .name = 1 };
    things[2] = .{ .live = true, .address = 9, .name = 2 };

    try std.testing.expectEqual(@as(u8, 1), (by(&things, "address", @as(u8, 7)) orelse unreachable).name);
    try std.testing.expectEqual(@as(u8, 2), (by(&things, "address", @as(u8, 9)) orelse unreachable).name);
    try std.testing.expect(by(&things, "address", @as(u8, 8)) == null);

    // A row nothing is using is not found, whatever it still holds.
    things[0].live = false;
    try std.testing.expect(by(&things, "address", @as(u8, 7)) == null);
}
