//! A row of fixed-width cells, laid out from one end.
//!
//! The bar's status area is the reason this exists: a painter and a hit test
//! that each work out where things are will agree until one of them is
//! edited, so both ask here instead. Which cells there are is the caller's
//! business; how wide the row is and where each one lands is arithmetic, and
//! arithmetic belongs somewhere it can be tested.
//!
//! Pure, so it is host-tested rather than checked by clicking on it.

const std = @import("std");
const draw = @import("draw.zig");

const Rect = draw.Rect;

pub const Side = enum { left, right };

/// Where each cell of `widths` sits inside `area`, packed against `side`.
///
/// A cell that will not fit is dropped rather than drawn over its neighbour:
/// a narrow bar loses whatever is furthest from the edge it packs against,
/// and what is left still reads. The rectangles come back in the order the
/// widths were given, whichever end they were laid from.
pub fn place(area: Rect, side: Side, widths: []const i32, into: []Rect) []Rect {
    var count: usize = 0;

    switch (side) {
        .right => {
            var edge = area.right();
            var index = widths.len;
            while (index > 0) {
                index -= 1;
                if (count == into.len) break;
                const w = widths[index];
                if (w <= 0 or edge - w < area.x) break;

                into[count] = .{ .x = edge - w, .y = area.y, .w = w, .h = area.h };
                count += 1;
                edge -= w;
            }
            std.mem.reverse(Rect, into[0..count]);
        },
        .left => {
            var edge = area.x;
            for (widths) |w| {
                if (count == into.len) break;
                if (w <= 0 or edge + w > area.right()) break;

                into[count] = .{ .x = edge, .y = area.y, .w = w, .h = area.h };
                count += 1;
                edge += w;
            }
        },
    }

    return into[0..count];
}

/// Which cell a point is in, as an index into what `place` handed back.
pub fn at(cells: []const Rect, x: i32, y: i32) ?usize {
    for (cells, 0..) |cell, i| {
        if (cell.contains(x, y)) return i;
    }
    return null;
}

/// The extent the cells actually occupy, which is what the rest of the row
/// has left. Empty when nothing was placed.
pub fn extent(cells: []const Rect) Rect {
    if (cells.len == 0) return .{};
    var all = cells[0];
    for (cells[1..]) |cell| all = all.unite(cell);
    return all;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const strip = Rect{ .x = 0, .y = 0, .w = 800, .h = 22 };
const sizes = [_]i32{ 24, 24, 58, 30, 52 };

test "cells pack against the right edge and touch without overlapping" {
    var buf: [8]Rect = undefined;
    const cells = place(strip, .right, &sizes, &buf);

    try testing.expectEqual(sizes.len, cells.len);
    try testing.expectEqual(strip.right(), cells[cells.len - 1].right());
    for (cells, sizes) |cell, w| try testing.expectEqual(w, cell.w);
    for (cells[0 .. cells.len - 1], cells[1..]) |left, right| {
        try testing.expectEqual(left.right(), right.x);
    }
}

test "cells pack against the left edge in the same order" {
    var buf: [8]Rect = undefined;
    const cells = place(strip, .left, &sizes, &buf);

    try testing.expectEqual(sizes.len, cells.len);
    try testing.expectEqual(strip.x, cells[0].x);
    for (cells, sizes) |cell, w| try testing.expectEqual(w, cell.w);
}

test "a point lands in the cell drawn there and nowhere else" {
    var buf: [8]Rect = undefined;
    const cells = place(strip, .right, &sizes, &buf);

    for (cells, 0..) |cell, i| {
        try testing.expectEqual(i, at(cells, cell.x + @divTrunc(cell.w, 2), 10).?);
    }
    try testing.expectEqual(@as(?usize, null), at(cells, 0, 10));
    try testing.expectEqual(@as(?usize, null), at(cells, 400, 10));
}

test "what will not fit is dropped, and what is left keeps the edge" {
    var buf: [8]Rect = undefined;
    const narrow = Rect{ .x = 0, .y = 0, .w = 90, .h = 22 };

    const right = place(narrow, .right, &sizes, &buf);
    try testing.expect(right.len < sizes.len);
    try testing.expectEqual(narrow.right(), right[right.len - 1].right());
    for (right) |cell| try testing.expect(cell.x >= narrow.x);

    var other: [8]Rect = undefined;
    const left = place(narrow, .left, &sizes, &other);
    try testing.expect(left.len < sizes.len);
    try testing.expectEqual(narrow.x, left[0].x);
    for (left) |cell| try testing.expect(cell.right() <= narrow.right());
}

test "the room the cells take is the room the rest of the row does not have" {
    var buf: [8]Rect = undefined;
    const cells = place(strip, .right, &sizes, &buf);

    var total: i32 = 0;
    for (sizes) |w| total += w;
    try testing.expectEqual(strip.right() - total, extent(cells).x);

    var none: [8]Rect = undefined;
    try testing.expect(extent(place(strip, .right, &.{}, &none)).isEmpty());
}

test "somewhere to put them that is too small for all of them" {
    var buf: [2]Rect = undefined;
    const cells = place(strip, .right, &sizes, &buf);
    try testing.expectEqual(@as(usize, 2), cells.len);
    // Still the ones nearest the edge it packs against.
    try testing.expectEqual(strip.right(), cells[1].right());
}
