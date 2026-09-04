//! A reading with a proportion to it: what it is, what it says, how full it
//! is, and what that means.
//!
//! Four lines of a cell, in a row of cells across the top of a window. The
//! shape a machine's vital signs want: a number alone says how much without
//! saying how much of what, and a bar alone says how full without saying of
//! what or how full in the units anybody cares about.
//!
//! The row divides its width evenly and puts a hairline between cells, so the
//! same row reads the same whether it holds three readings or five.
//!
//! Pure geometry, host-tested; the painting is the surface's.

const std = @import("std");
const draw = @import("draw.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

/// Most readings one row holds. Past this they are narrower than what they
/// say.
pub const MAX = 5;

pub const Reading = struct {
    /// What it is: "cpu", "memory".
    label: []const u8,
    /// What it says right now: "11%", "18M".
    value: []const u8,
    /// How full, nought to a hundred.
    percent: u8 = 0,
    /// What the number is of: "of 511 MiB", "2h 10m left". Empty is fine.
    note: []const u8 = "",
    /// When this reading becomes a problem, which is what turns it red.
    alarm: Alarm = .when_full,
};

/// Which end of a reading is the bad end.
///
/// Most things are a problem when they fill up: a disk, memory, a load, a
/// temperature against the point the firmware cuts the power. A battery is a
/// problem when it empties. Saying which here rather than at each caller is
/// what makes a full disk and a full memory bar turn red at the same point,
/// instead of at whichever number two programs each picked.
pub const Alarm = enum { when_full, when_empty, never };

/// Where a reading stops being ordinary. Ninety and ten: a disk at ninety per
/// cent is worth knowing about, and one at eighty is not worth colouring.
pub const FULL: u8 = 90;
pub const EMPTY: u8 = 10;

/// Whether a reading has become a problem.
pub fn alarming(percent: u8, alarm: Alarm) bool {
    return switch (alarm) {
        .when_full => percent >= FULL,
        .when_empty => percent <= EMPTY,
        .never => false,
    };
}

/// What a bar at this level should be drawn in.
pub fn inkFor(percent: u8, alarm: Alarm) draw.Color {
    const t = theme.current();
    return if (alarming(percent, alarm)) t.warning else t.accent;
}

/// How tall a row of these is: three lines of text and the bar between them.
pub fn height() i32 {
    const t = theme.current();
    return Surface.textHeight() * 2 + BAR_HEIGHT + t.padding * 3 + t.gap;
}

/// How thick the bar is. Thinner than a meter's: this is a proportion at a
/// glance rather than something to read a level off.
pub const BAR_HEIGHT: i32 = 8;

/// Where the nth of `count` cells sits.
pub fn cellRect(area: Rect, count: usize, index: usize) Rect {
    if (count == 0) return .{ .x = area.x, .y = area.y, .w = 0, .h = area.h };

    const n: i32 = @intCast(count);
    const i: i32 = @intCast(index);
    // Divided by position rather than by width, so the cells tile the row
    // exactly and the last one takes the remainder instead of falling short.
    const from = @divTrunc(area.w * i, n);
    const to = @divTrunc(area.w * (i + 1), n);
    return .{ .x = area.x + from, .y = area.y, .w = to - from, .h = area.h };
}

/// Where the bar inside a cell sits.
pub fn barRect(cell: Rect) Rect {
    const t = theme.current();
    return .{
        .x = cell.x + t.padding,
        .y = cell.y + t.padding + Surface.textHeight() + t.gap,
        .w = @max(cell.w - t.padding * 2, 0),
        .h = BAR_HEIGHT,
    };
}

/// Draw a row of readings across `area`.
pub fn paint(surface: Surface, area: Rect, readings: []const Reading) void {
    const t = theme.current();
    const count = @min(readings.len, MAX);

    surface.fill(area, t.surface);

    for (readings[0..count], 0..) |reading, i| {
        const cell = cellRect(area, count, i);
        const bar = barRect(cell);
        const alarmed = alarming(reading.percent, reading.alarm);
        const ink = if (alarmed) t.warning else t.text;

        // The name on the left and the number on the right, which is what
        // makes a row of these scannable down either edge.
        surface.text(cell.x + t.padding, cell.y + t.padding, reading.label, t.text_dim);
        surface.text(
            cell.right() - t.padding - Surface.textWidth(reading.value),
            cell.y + t.padding,
            reading.value,
            ink,
        );

        widget.paintBar(surface, bar, reading.percent, inkFor(reading.percent, reading.alarm));

        if (reading.note.len > 0) {
            surface.clipped(cell).text(
                cell.x + t.padding,
                bar.bottom() + t.gap,
                reading.note,
                t.text_dim,
            );
        }

        // A hairline between cells, drawn by the cell on its left so the last
        // one does not draw a line down the edge of the window.
        if (i + 1 < count) {
            surface.fill(.{ .x = cell.right() - 1, .y = cell.y, .w = 1, .h = cell.h }, t.line);
        }
    }

    surface.fill(.{ .x = area.x, .y = area.bottom() - 1, .w = area.w, .h = 1 }, t.line);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const row = Rect{ .x = 0, .y = 0, .w = 800, .h = 48 };

test "cells tile the row exactly, with none left over" {
    for ([_]usize{ 1, 2, 3, 4, 5 }) |count| {
        var covered: i32 = 0;
        for (0..count) |i| {
            const cell = cellRect(row, count, i);
            try testing.expectEqual(row.x + covered, cell.x);
            covered += cell.w;
        }
        try testing.expectEqual(row.w, covered);
    }
}

test "cells are within a pixel of each other in width" {
    const count: usize = 3;
    const first = cellRect(row, count, 0).w;
    for (1..count) |i| {
        const w = cellRect(row, count, i).w;
        try testing.expect(@abs(w - first) <= 1);
    }
}

test "a row of nothing has nothing in it" {
    try testing.expectEqual(@as(i32, 0), cellRect(row, 0, 0).w);
}

test "the bar fills its share and never more" {
    draw.useLinked();
    const bar = barRect(cellRect(row, 4, 0));
    try testing.expectEqual(@as(i32, 0), widget.filledWidth(bar, 0));
    try testing.expectEqual(bar.w, widget.filledWidth(bar, 100));
    // A reading that came back nonsense is drawn full rather than past the
    // end of the cell beside it.
    try testing.expectEqual(bar.w, widget.filledWidth(bar, 250));
    try testing.expect(widget.filledWidth(bar, 50) < bar.w);
}

test "a reading turns at the end that is the bad one" {
    // Filling up is the usual problem.
    try testing.expect(!alarming(0, .when_full));
    try testing.expect(!alarming(FULL - 1, .when_full));
    try testing.expect(alarming(FULL, .when_full));
    try testing.expect(alarming(100, .when_full));

    // A battery is the other way round.
    try testing.expect(alarming(0, .when_empty));
    try testing.expect(alarming(EMPTY, .when_empty));
    try testing.expect(!alarming(EMPTY + 1, .when_empty));
    try testing.expect(!alarming(100, .when_empty));

    // And some readings are neither, at either end.
    try testing.expect(!alarming(0, .never));
    try testing.expect(!alarming(100, .never));
}

test "the bar stays inside its cell" {
    draw.useLinked();
    for (0..4) |i| {
        const cell = cellRect(row, 4, i);
        const bar = barRect(cell);
        try testing.expect(bar.x >= cell.x);
        try testing.expect(bar.right() <= cell.right());
        try testing.expect(bar.bottom() <= cell.bottom());
    }
}
