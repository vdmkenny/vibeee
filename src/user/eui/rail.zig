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
    /// How far the row is held under the ones above it. A rail with more
    /// places than fit groups them, and the group is the parent row: a
    /// channel sits under its network, a folder's contents under the folder.
    depth: u2 = 0,
    /// How much is waiting here, drawn as a badge at the right edge. Zero
    /// draws none.
    count: u16 = 0,
    /// The count wants attention now rather than when you next look. Drawn
    /// in the warning colour.
    urgent: bool = false,
};

/// How far one level of nesting moves a row's contents.
pub const INDENT: i32 = 10;

/// How far in a row's contents start at this depth.
pub fn indentOf(depth: u2) i32 {
    return theme.enlarged(INDENT) * depth;
}

/// The badge at the right of a row, or null where the row has no count.
///
/// Sized from the digits it holds so a four-figure count is not clipped, and
/// never wider than half the row: a rail is a list of names first.
pub fn badge(row: Rect, count: u16) ?Rect {
    if (count == 0) return null;
    const t = theme.current();
    var room: [4]u8 = undefined;
    const height = draw.Surface.textHeight() + 2;
    const across = @min(
        @max(draw.Surface.textWidth(spellCount(count, &room)) + t.padding, height),
        @divTrunc(row.w, 2),
    );
    return .{
        .x = row.right() - t.menu_padding - across,
        .y = row.y + @divTrunc(row.h - height, 2),
        .w = across,
        .h = height,
    };
}

/// The largest count drawn as a number. Above it the badge says so with a
/// plus: the difference between 300 and 400 waiting messages is not something
/// a badge can usefully say.
pub const COUNT_MAX: u16 = 99;

/// The count as text, written into `room`.
pub fn spellCount(count: u16, room: *[4]u8) []const u8 {
    if (count > COUNT_MAX) {
        room[0..3].* = "99+".*;
        return room[0..3];
    }
    return std.fmt.bufPrint(room, "{d}", .{count}) catch unreachable;
}

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

test "a nested row starts further in than its parent" {
    try testing.expectEqual(@as(i32, 0), indentOf(0));
    try testing.expectEqual(INDENT, indentOf(1));
    try testing.expectEqual(INDENT * 2, indentOf(2));
}

test "a count is a badge at the right of the row" {
    draw.useLinked();
    const rail = column(window, 30);
    const row = rowRect(rail, 0);

    try testing.expectEqual(@as(?Rect, null), badge(row, 0));

    const one = badge(row, 3) orelse return error.NoBadge;
    try testing.expect(one.right() < row.right());
    try testing.expect(one.y > row.y);
    try testing.expectEqual(row.bottom() - one.bottom(), one.y - row.y);

    // One digit and two are the same width, so a badge does not jitter as
    // the count passes ten. A longer label grows it, and nothing takes more
    // than half the row.
    const two = badge(row, 42) orelse return error.NoBadge;
    try testing.expectEqual(one.w, two.w);
    const capped = badge(row, 65535) orelse return error.NoBadge;
    try testing.expect(capped.w > one.w);
    try testing.expect(capped.w <= @divTrunc(row.w, 2));
}

test "a count past the cap says so rather than growing" {
    var room: [4]u8 = undefined;
    try testing.expectEqualStrings("1", spellCount(1, &room));
    try testing.expectEqualStrings("42", spellCount(42, &room));
    try testing.expectEqualStrings("99", spellCount(COUNT_MAX, &room));
    try testing.expectEqualStrings("99+", spellCount(COUNT_MAX + 1, &room));
    try testing.expectEqualStrings("99+", spellCount(65535, &room));
}

test "the footer sits at the bottom of the rail" {
    draw.useLinked();
    const rail = column(window, 30);
    const strip = footer(rail);
    try testing.expectEqual(rail.bottom(), strip.bottom());
    try testing.expectEqual(rail.w, strip.w);
    try testing.expect(strip.h > draw.Surface.textHeight());
}
