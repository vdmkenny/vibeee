//! A level that is read rather than set.
//!
//! A slider and a meter look alike and are opposites: one is a control that
//! says what you asked for, the other a readout that says what happened. So a
//! meter has no grip, is thinner than a slider, and carries two things a
//! slider has no use for: a peak that trails the level, and a mark where the
//! level stops being loud and starts being distortion.
//!
//! The peak matters more than it looks. A bar that only means something while
//! it is being watched says nothing about the moment you looked away, which
//! is exactly when the sound clipped.
//!
//! Pure geometry, so it is host-tested rather than judged by watching one
//! move.

const std = @import("std");
const draw = @import("draw.zig");

const Rect = draw.Rect;

/// Thinner than a slider's twenty-four, so the two are never mistaken for
/// each other at a glance.
pub const HEIGHT: i32 = 7;

/// Where a level stops being loud. Above this the fill is drawn in the
/// warning colour, because a meter's whole job is to say when that happens.
pub const LIMIT: u8 = 90;

/// How wide the peak mark is, and how far the limit mark stands proud of the
/// bar so it reads as a scale rather than as part of the level.
pub const PEAK_WIDTH: i32 = 2;
pub const LIMIT_OVERHANG: i32 = 2;

pub fn clamp(value: u8) u8 {
    return @min(value, 100);
}

/// How much of `area` a level fills.
pub fn fill(area: Rect, level: u8) Rect {
    const width = @divTrunc(area.w * @as(i32, clamp(level)), 100);
    return .{ .x = area.x, .y = area.y, .w = width, .h = area.h };
}

/// The mark for the loudest it has recently been.
///
/// Held inside the bar at the top end: a peak at a hundred drawn past the
/// right edge is a peak nobody sees, which is the one it matters most to.
pub fn peak(area: Rect, value: u8) Rect {
    const at = @divTrunc(area.w * @as(i32, clamp(value)), 100);
    const x = @min(area.x + at, area.right() - PEAK_WIDTH);
    return .{ .x = @max(area.x, x), .y = area.y, .w = PEAK_WIDTH, .h = area.h };
}

/// The scale mark, standing a little proud of the bar at both edges.
pub fn limit(area: Rect) Rect {
    const at = @divTrunc(area.w * @as(i32, LIMIT), 100);
    return .{
        .x = area.x + at,
        .y = area.y - LIMIT_OVERHANG,
        .w = 1,
        .h = area.h + LIMIT_OVERHANG * 2,
    };
}

/// Whether a level is past the mark, which decides the colour it is drawn in.
pub fn over(level: u8) bool {
    return clamp(level) > LIMIT;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const bar = Rect{ .x = 20, .y = 8, .w = 200, .h = HEIGHT };

test "a level fills its share of the bar and no more" {
    try testing.expectEqual(@as(i32, 0), fill(bar, 0).w);
    try testing.expectEqual(@as(i32, 100), fill(bar, 50).w);
    try testing.expectEqual(bar.w, fill(bar, 100).w);
    // Above the top is the top; a service that reported 120 is not drawn
    // over whatever is beside the meter.
    try testing.expectEqual(bar.w, fill(bar, 200).w);
    try testing.expectEqual(bar.x, fill(bar, 70).x);
}

test "the peak stays inside the bar, at both ends" {
    try testing.expectEqual(bar.x, peak(bar, 0).x);

    const loudest = peak(bar, 100);
    try testing.expectEqual(bar.right(), loudest.right());
    try testing.expect(loudest.x >= bar.x);

    for ([_]u8{ 0, 1, 45, 90, 99, 100, 250 }) |value| {
        const mark = peak(bar, value);
        try testing.expect(mark.x >= bar.x);
        try testing.expect(mark.right() <= bar.right());
    }
}

test "the peak sits where the level would have reached" {
    // A peak and a level at the same value mark the same place, which is
    // what makes a peak readable as the level's high-water mark.
    for ([_]u8{ 10, 25, 60, 80 }) |value| {
        try testing.expectEqual(fill(bar, value).right(), peak(bar, value).x);
    }
}

test "the limit is a scale mark, not part of the level" {
    const mark = limit(bar);
    try testing.expectEqual(bar.x + @divTrunc(bar.w * @as(i32, LIMIT), 100), mark.x);
    try testing.expectEqual(@as(i32, 1), mark.w);
    // Proud at both edges, so it reads across the bar rather than inside it.
    try testing.expect(mark.y < bar.y);
    try testing.expect(mark.bottom() > bar.bottom());
}

test "past the mark is what the warning colour is for" {
    try testing.expect(!over(0));
    try testing.expect(!over(LIMIT));
    try testing.expect(over(LIMIT + 1));
    try testing.expect(over(100));
    try testing.expect(over(200));
}

test "a bar with no width has nothing in it" {
    const none = Rect{ .x = 4, .y = 4, .w = 0, .h = HEIGHT };
    try testing.expectEqual(@as(i32, 0), fill(none, 100).w);
    try testing.expect(peak(none, 100).x >= none.x);
}
