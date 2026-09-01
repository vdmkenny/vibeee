//! Equal cells in a rectangle.
//!
//! A keypad, a row of tiles, a sheet of swatches: the same arithmetic every
//! time, and done by hand every time it gets the last column wrong. The
//! cells are found by dividing the whole rather than by multiplying a cell
//! width, so what is left over when the space does not divide evenly is
//! spread through the grid instead of piling up at one edge, and the last
//! cell ends exactly where the area does.
//!
//! Geometry only: nothing here draws or remembers anything, so a caller
//! decides what a cell contains and the toolkit's own controls do the rest.

const std = @import("std");
const draw = @import("draw.zig");

const Rect = draw.Rect;

pub const Grid = struct {
    area: Rect,
    columns: i32,
    rows: i32,
    /// Between cells, never around them: the area is the outside edge.
    gap: i32 = 0,

    /// One cell, counting from zero. A column or row outside the grid gives
    /// an empty rectangle, which draws as nothing rather than as something
    /// in the wrong place.
    pub fn cell(self: Grid, column: i32, row: i32) Rect {
        return self.wide(column, row, 1);
    }

    /// A cell spanning `across` columns, which is how a keypad gives its
    /// widest key the room two of its neighbours would have taken, gap and
    /// all.
    pub fn wide(self: Grid, column: i32, row: i32, across: i32) Rect {
        if (self.columns <= 0 or self.rows <= 0 or across <= 0) return .{};
        if (column < 0 or row < 0 or column >= self.columns or row >= self.rows) return .{};

        const last = @min(column + across, self.columns);
        const x = self.edge(self.area.x, self.area.w, self.columns, column);
        const y = self.edge(self.area.y, self.area.h, self.rows, row);
        return .{
            .x = x,
            .y = y,
            .w = self.edge(self.area.x, self.area.w, self.columns, last) - x - self.gap,
            .h = self.edge(self.area.y, self.area.h, self.rows, row + 1) - y - self.gap,
        };
    }

    /// Where the `index`th track begins. Taken as a share of the whole so
    /// the tracks stay even to within a pixel and the far edge is exact.
    fn edge(self: Grid, start: i32, length: i32, tracks: i32, index: i32) i32 {
        return start + @divTrunc(index * (length + self.gap), tracks);
    }

    /// How tall the grid has to be for cells of at least `height`, which is
    /// what a window asks before it decides how big it is.
    pub fn heightFor(rows: i32, height: i32, gap: i32) i32 {
        if (rows <= 0) return 0;
        return rows * height + (rows - 1) * gap;
    }
};

test "the cells tile the area exactly" {
    const g = Grid{ .area = .{ .x = 10, .y = 20, .w = 100, .h = 50 }, .columns = 4, .rows = 5, .gap = 4 };

    try std.testing.expectEqual(@as(i32, 10), g.cell(0, 0).x);
    try std.testing.expectEqual(@as(i32, 20), g.cell(0, 0).y);
    // The far edges land on the area's own, whatever the remainder was.
    try std.testing.expectEqual(@as(i32, 110), g.cell(3, 0).right());
    try std.testing.expectEqual(@as(i32, 70), g.cell(0, 4).bottom());
}

test "neighbours are a gap apart and never overlap" {
    const g = Grid{ .area = .{ .x = 0, .y = 0, .w = 103, .h = 77 }, .columns = 4, .rows = 5, .gap = 4 };

    var column: i32 = 0;
    while (column < 3) : (column += 1) {
        const here = g.cell(column, 0);
        const next = g.cell(column + 1, 0);
        try std.testing.expectEqual(next.x, here.right() + 4);
    }

    var row: i32 = 0;
    while (row < 4) : (row += 1) {
        const here = g.cell(0, row);
        const under = g.cell(0, row + 1);
        try std.testing.expectEqual(under.y, here.bottom() + 4);
    }
}

test "a wide cell takes its neighbours' room and the gap between them" {
    const g = Grid{ .area = .{ .x = 0, .y = 0, .w = 100, .h = 40 }, .columns = 4, .rows = 2, .gap = 5 };
    const one = g.cell(0, 0);
    const two = g.cell(1, 0);
    const both = g.wide(0, 0, 2);

    try std.testing.expectEqual(one.x, both.x);
    try std.testing.expectEqual(two.right(), both.right());
    try std.testing.expectEqual(one.w + 5 + two.w, both.w);
}

test "a span running off the end stops at the last column" {
    const g = Grid{ .area = .{ .x = 0, .y = 0, .w = 80, .h = 20 }, .columns = 4, .rows = 1, .gap = 2 };
    try std.testing.expectEqual(g.cell(3, 0).right(), g.wide(3, 0, 3).right());
}

test "a cell outside the grid is nothing at all" {
    const g = Grid{ .area = .{ .x = 0, .y = 0, .w = 80, .h = 20 }, .columns = 4, .rows = 1 };
    try std.testing.expect(g.cell(4, 0).isEmpty());
    try std.testing.expect(g.cell(0, 1).isEmpty());
    try std.testing.expect(g.cell(-1, 0).isEmpty());
}

test "a grid with no gap leaves none" {
    const g = Grid{ .area = .{ .x = 0, .y = 0, .w = 100, .h = 20 }, .columns = 5, .rows = 1 };
    try std.testing.expectEqual(@as(i32, 20), g.cell(0, 0).w);
    try std.testing.expectEqual(g.cell(1, 0).x, g.cell(0, 0).right());
}

test "the height a grid needs is its rows and the gaps between them" {
    try std.testing.expectEqual(@as(i32, 5 * 30 + 4 * 4), Grid.heightFor(5, 30, 4));
    try std.testing.expectEqual(@as(i32, 0), Grid.heightFor(0, 30, 4));
}
