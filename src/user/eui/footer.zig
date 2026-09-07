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
const chrome = @import("chrome.zig");
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
    return theme.stripHeight();
}

/// The strip at the bottom of a window.
///
/// The same cut `chrome` makes, asked for by the half a caller wants: a
/// window is cut into its strips in one place, or the two answers differ
/// at the edges and a window shorter than one strip gets a body of
/// negative height from one and nothing from the other.
pub fn strip(area: Rect) Rect {
    return chrome.split(area, .{ .bottom = true }).bottom;
}

/// What is left of the window once the strip is taken.
pub fn above(area: Rect) Rect {
    return chrome.split(area, .{ .bottom = true }).body;
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
    // The air after a button is part of what it takes, so what fits is
    // decided with the air included. Added afterwards instead, a row that
    // only just fitted was pushed left out of the bar it was placed in.
    for (labels[0..count], 0..) |label, i| {
        widths[i] = buttonWidth(label) + if (i + 1 < count) t.gap else 0;
    }

    const inner = Rect{
        .x = bar.x + t.menu_padding,
        .y = bar.y + @divTrunc(bar.h - t.control_height, 2),
        .w = bar.w - t.menu_padding * 2,
        .h = t.control_height,
    };
    const cells = row.place(inner, .right, widths[0..count], into);
    // Each cell holds a button and the air after it; the button is the
    // left of it, and the last one has no air to give back.
    for (cells, 0..) |*cell, i| {
        if (i + 1 < cells.len) cell.w -= t.gap;
    }
    return cells;
}

/// How many of `labels` `place` had to leave out, given what it placed.
/// The cells are packed against the right edge, so what a bar too narrow
/// for all of them drops is the front of the list: a caller pairing cells
/// with what it asked for starts here.
pub fn dropped(labels: []const []const u8, placed: []const Rect) usize {
    return labels.len - placed.len;
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
    draw.useLinked();
    try testing.expect(buttonWidth("Save") < buttonWidth("Disconnect"));
    // Both are wider than their text by the same padding, so neither looks
    // cramped next to the other.
    try testing.expectEqual(
        buttonWidth("Save") - draw.Surface.textWidth("Save"),
        buttonWidth("Disconnect") - draw.Surface.textWidth("Disconnect"),
    );
}

test "buttons pack right in the order they are named, with air between" {
    draw.useLinked();
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
    draw.useLinked();
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
