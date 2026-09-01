//! A tally: n of m, as a row of pips.
//!
//! For a count that is small and whole: charges left, steps taken, slots
//! spent. A number would say the same thing, but a row says it at a glance
//! and takes a press to change: a pip pressed fills up to itself, and the
//! last filled one pressed again empties itself, so a tally is set and unset
//! from the same row.

const std = @import("std");
const draw = @import("draw.zig");
const theme = @import("theme.zig");

const Rect = draw.Rect;

/// One pip's side, and the room between two.
pub const SIZE: i32 = 10;
pub const GAP: i32 = 4;

pub fn size() i32 {
    return theme.enlarged(SIZE);
}

pub fn gap() i32 {
    return theme.enlarged(GAP);
}

/// How wide a row of `count` pips is.
pub fn width(count: usize) i32 {
    if (count == 0) return 0;
    const n: i32 = @intCast(count);
    return n * size() + (n - 1) * gap();
}

/// Where pip `index` sits: a row from the left edge, centred in the height.
pub fn cell(area: Rect, index: usize) Rect {
    const i: i32 = @intCast(index);
    return .{
        .x = area.x + i * (size() + gap()),
        .y = area.y + @divTrunc(area.h - size(), 2),
        .w = size(),
        .h = size(),
    };
}

/// Which pip a point falls on, counting the gap after a pip as the pip's
/// own so a press between two is not a miss. Null off the row.
pub fn at(area: Rect, count: usize, x: i32, y: i32) ?usize {
    if (count == 0 or !area.contains(x, y)) return null;
    const along = x - area.x;
    if (along < 0) return null;
    const index: usize = @intCast(@divTrunc(along, size() + gap()));
    return if (index < count) index else null;
}

/// The tally after pip `index` is pressed with `filled` set: up to and
/// including it, or one fewer when it was the last one filled.
pub fn pressed(filled: usize, index: usize) usize {
    return if (index + 1 == filled) index else index + 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const row = Rect{ .x = 20, .y = 10, .w = 100, .h = 22 };

test "a row is its pips and the gaps between them" {
    try testing.expectEqual(@as(i32, 0), width(0));
    try testing.expectEqual(SIZE, width(1));
    try testing.expectEqual(3 * SIZE + 2 * GAP, width(3));

    const third = cell(row, 2);
    try testing.expectEqual(row.x + 2 * (SIZE + GAP), third.x);
    try testing.expectEqual(SIZE, third.w);
    // Centred in the row's height, not sitting on its top edge.
    try testing.expectEqual(row.y + @divTrunc(row.h - SIZE, 2), third.y);
}

test "a press lands on the pip it is nearest, and nowhere past the row" {
    try testing.expectEqual(@as(?usize, 0), at(row, 3, row.x + 1, row.y + 5));
    try testing.expectEqual(@as(?usize, 1), at(row, 3, row.x + SIZE + GAP + 2, row.y + 5));
    // The gap after a pip belongs to it.
    try testing.expectEqual(@as(?usize, 0), at(row, 3, row.x + SIZE + 1, row.y + 5));
    try testing.expectEqual(@as(?usize, null), at(row, 3, row.x + width(3) + GAP + 1, row.y + 5));
    try testing.expectEqual(@as(?usize, null), at(row, 3, row.x + 1, row.y - 1));
    try testing.expectEqual(@as(?usize, null), at(row, 0, row.x + 1, row.y + 5));
}

test "a pip pressed fills to itself, and the last one filled empties itself" {
    try testing.expectEqual(@as(usize, 1), pressed(0, 0));
    try testing.expectEqual(@as(usize, 3), pressed(1, 2));
    try testing.expectEqual(@as(usize, 2), pressed(3, 2));
    try testing.expectEqual(@as(usize, 0), pressed(1, 0));
}
