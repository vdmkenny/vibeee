//! Where a slider's parts are, and what a position along it means.
//!
//! The geometry only. Which pixels get painted and what a press does belong
//! to the control in `widget`, but turning a value into a knob position and a
//! pointer back into a value is arithmetic, and arithmetic that decides where
//! something is drawn *and* what clicking it means has to give the same answer
//! both ways or the knob lands somewhere the click did not.
//!
//! Pure, so it is host-tested rather than judged by dragging.

const std = @import("std");
const draw = @import("draw.zig");

const Rect = draw.Rect;

/// How thick the groove is, and how wide the part that moves along it. The
/// knob is square and as tall as the control, so it stays big enough to hit
/// on a touchpad while the groove stays a hairline-ish line.
pub const TRACK_HEIGHT: i32 = 6;
pub const KNOB_WIDTH: i32 = 9;

pub const Range = struct {
    min: i32 = 0,
    max: i32 = 100,

    /// A range with nothing in it would divide by zero and has no position to
    /// put a knob at; callers get the low end.
    pub fn empty(self: Range) bool {
        return self.max <= self.min;
    }

    pub fn clamp(self: Range, value: i32) i32 {
        return @max(self.min, @min(value, self.max));
    }

    pub fn span(self: Range) i32 {
        return self.max - self.min;
    }
};

/// The groove, centred in the control's height.
pub fn track(area: Rect) Rect {
    return .{
        .x = area.x,
        .y = area.y + @divTrunc(area.h - TRACK_HEIGHT, 2),
        .w = area.w,
        .h = TRACK_HEIGHT,
    };
}

/// How far the knob's left edge may travel. The knob is inside the control at
/// both ends, so a slider at its maximum does not hang over the next thing.
fn travel(area: Rect) i32 {
    return @max(0, area.w - KNOB_WIDTH);
}

/// Where the knob sits for a value.
pub fn knob(area: Rect, range: Range, value: i32) Rect {
    const offset = if (range.empty()) 0 else blk: {
        const along = range.clamp(value) - range.min;
        // Rounded rather than truncated, so the knob is where the value is
        // rather than always a little short of it.
        break :blk @divTrunc(along * travel(area) + @divTrunc(range.span(), 2), range.span());
    };

    return .{ .x = area.x + offset, .y = area.y, .w = KNOB_WIDTH, .h = area.h };
}

/// How much of the groove is behind the knob, which is what gets the accent.
/// Up to the knob's near edge rather than its middle, so none of the accent
/// is painted under the knob: at the low end there is nothing to see, and at
/// the high end the knob covers the rest of the groove itself.
pub fn filled(area: Rect, range: Range, value: i32) Rect {
    const groove = track(area);
    const upto = knob(area, range, value).x;
    return .{ .x = groove.x, .y = groove.y, .w = @max(0, upto - groove.x), .h = groove.h };
}

/// What a pointer at `x` is asking for.
///
/// Measured from the middle of the knob, so grabbing it and putting it
/// somewhere leaves it under the pointer rather than offset by half its width.
pub fn valueAt(area: Rect, range: Range, x: i32) i32 {
    if (range.empty()) return range.min;

    const room = travel(area);
    if (room == 0) return range.min;

    const along = @max(0, @min(x - area.x - @divTrunc(KNOB_WIDTH, 2), room));
    return range.clamp(range.min + @divTrunc(along * range.span() + @divTrunc(room, 2), room));
}

/// One step of the keyboard's arrows. A hundred steps of one percent is a key
/// held down for a long time, so a range wider than twenty moves in
/// twentieths and a narrow one moves by one.
pub fn step(range: Range) i32 {
    return @max(1, @divTrunc(range.span(), 20));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const bounds = Rect{ .x = 10, .y = 4, .w = 109, .h = 20 };
const percent = Range{ .min = 0, .max = 100 };

test "the knob stays inside the control at both ends" {
    const low = knob(bounds, percent, 0);
    try testing.expectEqual(bounds.x, low.x);

    const high = knob(bounds, percent, 100);
    try testing.expectEqual(bounds.right(), high.right());

    for ([_]i32{ 0, 1, 37, 99, 100 }) |value| {
        const at = knob(bounds, percent, value);
        try testing.expect(at.x >= bounds.x);
        try testing.expect(at.right() <= bounds.right());
    }
}

test "a value out of range is held at the end it went past" {
    try testing.expectEqual(knob(bounds, percent, 0), knob(bounds, percent, -40));
    try testing.expectEqual(knob(bounds, percent, 100), knob(bounds, percent, 900));
    try testing.expectEqual(@as(i32, 0), valueAt(bounds, percent, -1000));
    try testing.expectEqual(@as(i32, 100), valueAt(bounds, percent, 1000));
}

test "where the knob is drawn is what a press there asks for" {
    // The round trip is the whole point: the picture and the hit test have to
    // agree, or the knob jumps when you grab it.
    for ([_]i32{ 0, 5, 25, 50, 75, 95, 100 }) |value| {
        const middle = knob(bounds, percent, value).x + @divTrunc(KNOB_WIDTH, 2);
        try testing.expectEqual(value, valueAt(bounds, percent, middle));
    }
}

test "the filled part stops where the knob begins" {
    try testing.expectEqual(@as(i32, 0), filled(bounds, percent, 0).w);

    const half = filled(bounds, percent, 50);
    try testing.expectEqual(knob(bounds, percent, 50).x, half.right());
    try testing.expectEqual(track(bounds).y, half.y);

    // At the top the knob covers what is left, so the fill stops at its edge.
    const full = filled(bounds, percent, 100);
    try testing.expectEqual(knob(bounds, percent, 100).x, full.right());
    try testing.expect(full.right() <= bounds.right());
}

test "a range with nothing in it has one position and no arithmetic" {
    const fixed = Range{ .min = 7, .max = 7 };
    try testing.expect(fixed.empty());
    try testing.expectEqual(bounds.x, knob(bounds, fixed, 7).x);
    try testing.expectEqual(@as(i32, 7), valueAt(bounds, fixed, 400));
    try testing.expectEqual(@as(i32, 0), filled(bounds, fixed, 7).w);
}

test "arrows move by a twentieth, and never by nothing" {
    try testing.expectEqual(@as(i32, 5), step(percent));
    // The backlight's sixteen levels move one at a time.
    try testing.expectEqual(@as(i32, 1), step(.{ .min = 0, .max = 16 }));
    try testing.expectEqual(@as(i32, 1), step(.{ .min = 0, .max = 1 }));
}

test "the groove is centred and as wide as the control" {
    const groove = track(bounds);
    try testing.expectEqual(bounds.x, groove.x);
    try testing.expectEqual(bounds.w, groove.w);
    try testing.expectEqual(TRACK_HEIGHT, groove.h);
    try testing.expectEqual(bounds.y + bounds.h - groove.bottom(), groove.y - bounds.y);
}
