//! An exact number with a step down and a step up.
//!
//! For a value set by counting rather than by feel: a quantity, a level,
//! points left. A slider covers a range in a sweep and lands near; this
//! lands on the number asked for, one press at a time, with the number
//! between the two presses where it is read.

const std = @import("std");
const draw = @import("draw.zig");
const theme = @import("theme.zig");

const Rect = draw.Rect;

/// Room for the number between the buttons.
pub const VALUE_WIDTH: i32 = 40;

pub const Parts = struct {
    less: Rect,
    value: Rect,
    more: Rect,
};

/// The two buttons are squares of the control's height at either end, and
/// the number has what is left between them.
pub fn parts(area: Rect) Parts {
    const side = @min(area.h, @divTrunc(area.w, 2));
    const middle = @max(0, area.w - side * 2);
    return .{
        .less = .{ .x = area.x, .y = area.y, .w = side, .h = area.h },
        .value = .{ .x = area.x + side, .y = area.y, .w = middle, .h = area.h },
        .more = .{ .x = area.x + side + middle, .y = area.y, .w = side, .h = area.h },
    };
}

/// How wide a stepper of `height` is: two squares and the number's room.
pub fn width(height: i32) i32 {
    return height * 2 + theme.enlarged(VALUE_WIDTH);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the parts tile the control: a square, the number, a square" {
    const area = Rect{ .x = 10, .y = 4, .w = width(24), .h = 24 };
    const p = parts(area);
    try testing.expectEqual(@as(i32, 24), p.less.w);
    try testing.expectEqual(@as(i32, 24), p.more.w);
    try testing.expectEqual(VALUE_WIDTH, p.value.w);
    try testing.expectEqual(p.less.right(), p.value.x);
    try testing.expectEqual(p.value.right(), p.more.x);
    try testing.expectEqual(area.right(), p.more.right());
}

test "a control too narrow for its height gives the number nothing rather than overlap" {
    const p = parts(.{ .x = 0, .y = 0, .w = 30, .h = 24 });
    try testing.expectEqual(@as(i32, 15), p.less.w);
    try testing.expectEqual(@as(i32, 0), p.value.w);
    try testing.expectEqual(@as(i32, 30), p.more.right());
}
