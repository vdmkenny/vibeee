//! The strip along the bottom of a window: what just happened on the left,
//! what to do about it on the right.
//!
//! Every window that can be got wrong needs one, so its geometry lives here
//! rather than in the windows: the button that closes Settings and the button
//! that closes anything else should be the same size in the same corner, and
//! the way that stops being true is each window measuring for itself.
//!
//! Buttons are as wide as what they say plus a fixed padding, so "Save" and
//! "Disconnect" both look deliberate. They pack from the right in the order
//! given, which reads left to right as written.

const std = @import("std");
const theme = @import("theme.zig");
const draw = @import("draw.zig");
const row = @import("row.zig");

const Rect = draw.Rect;

/// Room either side of a button's label. Wider than the padding elsewhere:
/// a button is a target as well as a word.
pub const BUTTON_PADDING: i32 = 14;

/// The strip is a control tall plus a margin, which is where the design's
/// thirty pixels come from and how they follow the interface's size.
pub fn height() i32 {
    const t = theme.current();
    return t.control_height + t.padding;
}

/// The strip at the bottom of a window.
pub fn strip(area: Rect) Rect {
    const h = height();
    return .{ .x = area.x, .y = area.bottom() - h, .w = area.w, .h = h };
}

/// What is left of the window once the strip is taken.
pub fn above(area: Rect) Rect {
    return .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h - height() };
}

pub fn buttonWidth(label: []const u8) i32 {
    return draw.Surface.textWidth(label) + theme.enlarged(BUTTON_PADDING) * 2;
}

/// Where the buttons go: packed against the right edge, inside the same
/// padding the rest of the window uses, in the order they were named.
pub fn place(bar: Rect, labels: []const []const u8, into: []Rect) []Rect {
    const t = theme.current();
    var widths: [8]i32 = undefined;
    const count = @min(labels.len, widths.len);
    for (labels[0..count], 0..) |label, i| widths[i] = buttonWidth(label);

    const inner = Rect{
        .x = bar.x + t.menu_padding,
        .y = bar.y + @divTrunc(bar.h - t.control_height, 2),
        .w = bar.w - t.menu_padding * 2,
        .h = t.control_height,
    };
    const cells = row.place(inner, .right, widths[0..count], into);
    // `row` packs cells hard against each other; buttons want air between.
    for (cells, 0..) |*cell, i| {
        const from_edge = @as(i32, @intCast(cells.len - 1 - i));
        cell.x -= from_edge * t.gap;
    }
    return cells;
}

/// The room the message gets: everything left of the buttons.
pub fn messageRect(bar: Rect, buttons: []const Rect) Rect {
    const t = theme.current();
    const left = bar.x + t.menu_padding;
    const right = if (buttons.len == 0) bar.right() - t.menu_padding else buttons[0].x - t.gap;
    return .{
        .x = left,
        .y = bar.y + @divTrunc(bar.h - draw.Surface.textHeight(), 2),
        .w = @max(0, right - left),
        .h = draw.Surface.textHeight(),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const window = Rect{ .x = 0, .y = 0, .w = 640, .h = 480 };

test "the strip is a control tall plus a margin, at the bottom" {
    const bar = strip(window);
    try testing.expectEqual(@as(i32, 30), bar.h);
    try testing.expectEqual(window.bottom(), bar.bottom());
    try testing.expectEqual(window.w, bar.w);
    // And what is above it is the rest, with nothing lost between them.
    try testing.expectEqual(bar.y, above(window).bottom());
}

test "a button is as wide as what it says" {
    try testing.expect(buttonWidth("Save") < buttonWidth("Disconnect"));
    // Both are wider than their text by the same padding, so neither looks
    // cramped next to the other.
    try testing.expectEqual(
        buttonWidth("Save") - draw.Surface.textWidth("Save"),
        buttonWidth("Disconnect") - draw.Surface.textWidth("Disconnect"),
    );
}

test "buttons pack right in the order they are named, with air between" {
    const bar = strip(window);
    var cells: [4]Rect = undefined;
    const placed = place(bar, &.{ "Save", "Close" }, &cells);

    try testing.expectEqual(@as(usize, 2), placed.len);
    // Named left to right, drawn left to right.
    try testing.expect(placed[0].right() < placed[1].x);
    // The last one sits inside the window's padding, not against the glass.
    try testing.expectEqual(bar.right() - theme.current().menu_padding, placed[1].right());
    for (placed) |cell| {
        try testing.expectEqual(theme.current().control_height, cell.h);
        try testing.expect(cell.y > bar.y and cell.bottom() < bar.bottom());
    }
}

test "the message gets what the buttons leave" {
    const bar = strip(window);
    var cells: [4]Rect = undefined;
    const placed = place(bar, &.{ "Save", "Close" }, &cells);
    const message = messageRect(bar, placed);

    try testing.expect(message.right() <= placed[0].x);
    try testing.expectEqual(bar.x + theme.current().menu_padding, message.x);
    try testing.expect(message.w > 0);

    // With no buttons at all it is the whole strip, rather than nothing.
    const alone = messageRect(bar, &.{});
    try testing.expect(alone.w > message.w);
}
