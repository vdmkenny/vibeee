//! The column of sections down the side of a window.
//!
//! A rail is a list of the places a window has, always visible, with the one
//! you are in marked. It exists so a pane never has to scroll to find a
//! heading: on a screen this short, a settings window that hides its own
//! table of contents is a window you navigate by guessing.
//!
//! It is not a column of buttons. A button has an edge because it is a thing
//! you press; a rail row is a place you are, so the selected row is a filled
//! band across the whole column and the rest are plain text on a slightly
//! sunken ground. That distinction is the whole visual argument: buttons in a
//! stack read as six separate decisions, a rail reads as one.
//!
//! The geometry here is pure, so the row a click lands on is host-tested
//! rather than found by clicking.

const std = @import("std");
const theme = @import("theme.zig");
const draw = @import("draw.zig");
const icons = @import("icon.zig");

const Rect = draw.Rect;

/// A place the window has. The picture is optional per row, but a rail with
/// one picture indents every row: labels that start in different columns
/// depending on whether their section has an icon read as two lists.
pub const Item = struct {
    label: []const u8,
    icon: ?icons.Icon = null,
    /// A picture of the program's own, in the toolkit's format, for a row
    /// the toolkit has no name for. Drawn where the icon would be.
    glyph: ?icons.Glyph = null,
};

/// Whether any row carries a picture, which decides the indent for all of
/// them.
pub fn marked(items: []const Item) bool {
    for (items) |item| {
        if (item.icon != null or item.glyph != null) return true;
    }
    return false;
}

/// Wide enough for the longest section name with the padding either side,
/// measured at a hundred per cent and grown from there.
pub const WIDTH: i32 = 124;

/// Taller than a menu row. A menu is read once and dismissed; a rail is
/// looked at for as long as the window is open, and the extra four pixels
/// are what keep six of them from reading as a wall of text.
pub const ROW_HEIGHT: i32 = 26;

pub fn width() i32 {
    return theme.enlarged(WIDTH);
}

pub fn rowHeight() i32 {
    return theme.enlarged(ROW_HEIGHT);
}

/// The column itself, inside a window whose bottom `foot` pixels belong to
/// something else.
pub fn column(area: Rect, foot: i32) Rect {
    return .{ .x = area.x, .y = area.y, .w = width(), .h = area.h - foot };
}

/// What is left for the pane once the rail and its hairline are taken.
pub fn beside(area: Rect, rail: Rect) Rect {
    const left = rail.right() + 1;
    return .{ .x = left, .y = area.y, .w = area.right() - left, .h = rail.h };
}

pub fn rowRect(rail: Rect, index: usize) Rect {
    const height = rowHeight();
    return .{
        .x = rail.x,
        .y = rail.y + @as(i32, @intCast(index)) * height,
        .w = rail.w,
        .h = height,
    };
}

/// Which row a point falls on, or null when it misses the rows entirely.
///
/// Rows stop where the list stops: the empty column below the last one is
/// not a seventh row, and clicking it selects nothing.
pub fn rowAt(rail: Rect, count: usize, x: i32, y: i32) ?usize {
    if (!rail.contains(x, y)) return null;
    const height = rowHeight();
    if (height <= 0) return null;
    const row = @divTrunc(y - rail.y, height);
    if (row < 0) return null;
    const index: usize = @intCast(row);
    return if (index < count) index else null;
}

/// The strip at the foot of the rail, where a window says what it is a
/// window of. Sits under a hairline, hard against the bottom.
pub fn footer(rail: Rect) Rect {
    const t = theme.current();
    const height = t.padding * 2 + draw.Surface.textHeight();
    return .{ .x = rail.x, .y = rail.bottom() - height, .w = rail.w, .h = height };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const window = Rect{ .x = 0, .y = 0, .w = 640, .h = 458 };

test "the rail takes its width and leaves the rest to the pane" {
    const rail = column(window, 30);
    try testing.expectEqual(WIDTH, rail.w);
    try testing.expectEqual(@as(i32, 428), rail.h);

    const pane = beside(window, rail);
    // The hairline between them belongs to neither.
    try testing.expectEqual(rail.right() + 1, pane.x);
    try testing.expectEqual(window.right(), pane.right());
    try testing.expectEqual(rail.h, pane.h);
}

test "rows stack from the top with no gaps" {
    const rail = column(window, 30);
    try testing.expectEqual(rail.y, rowRect(rail, 0).y);
    for (0..5) |i| {
        const above = rowRect(rail, i);
        const below = rowRect(rail, i + 1);
        try testing.expectEqual(above.bottom(), below.y);
        try testing.expectEqual(rail.w, above.w);
        try testing.expectEqual(ROW_HEIGHT, above.h);
    }
}

test "a click lands on the row it looks like it landed on" {
    const rail = column(window, 30);
    for (0..6) |i| {
        const row = rowRect(rail, i);
        try testing.expectEqual(@as(?usize, i), rowAt(rail, 6, row.x + 4, row.y + 1));
        try testing.expectEqual(@as(?usize, i), rowAt(rail, 6, row.x + 4, row.bottom() - 1));
    }
}

test "the empty column below the last row is not a row" {
    const rail = column(window, 30);
    const below = rowRect(rail, 6);
    try testing.expectEqual(@as(?usize, null), rowAt(rail, 6, below.x + 4, below.y + 4));
    try testing.expectEqual(@as(?usize, null), rowAt(rail, 6, rail.right() + 8, rail.y + 4));
    try testing.expectEqual(@as(?usize, null), rowAt(rail, 6, rail.x + 4, rail.bottom() - 1));
}

test "the footer sits at the bottom of the rail" {
    const rail = column(window, 30);
    const strip = footer(rail);
    try testing.expectEqual(rail.bottom(), strip.bottom());
    try testing.expectEqual(rail.w, strip.w);
    try testing.expect(strip.h > draw.Surface.textHeight());
}
