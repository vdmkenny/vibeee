//! A control strip: a picture you can press, a slider, and the number it is
//! at.
//!
//! The shape a panel takes when it is about one quantity. The sound menu is a
//! level with a mute beside it; the power menu is a backlight with its lamp
//! beside it; a settings row is the same three things in a line. Written once
//! so all of them are the same three things in the same places, and so that
//! moving the number an extra pixel moves it everywhere.
//!
//! The reading is measured rather than assumed: "16 of 16" and "100%" are
//! different widths, and a track sized for the shorter one leaves the longer
//! one hanging off the end.
//!
//! Pure, so where a press lands is host-tested.

const std = @import("std");
const theme = @import("theme.zig");
const draw = @import("draw.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;

/// A strip is a control tall with the panel's own padding either side.
pub fn height() i32 {
    const t = theme.current();
    return t.control_height + t.menu_padding * 2;
}

/// The strip across the top of a panel.
pub fn of(panel: Rect) Rect {
    return .{ .x = panel.x, .y = panel.y, .w = panel.w, .h = height() };
}

/// What is left of the panel underneath it.
pub fn below(panel: Rect) Rect {
    const used = height();
    return .{ .x = panel.x, .y = panel.y + used, .w = panel.w, .h = panel.h - used };
}

/// The picture at the left, which is a target as well as a picture: sized to
/// the whole column so a touchpad can hit it.
pub fn button(area: Rect) Rect {
    const t = theme.current();
    return .{
        .x = area.x + t.menu_padding,
        .y = area.y + t.menu_padding,
        .w = widget.markWidth(),
        .h = t.control_height,
    };
}

/// The groove, between the picture and the reading.
pub fn track(area: Rect, text: []const u8) Rect {
    const t = theme.current();
    const left = button(area).right();
    return .{
        .x = left,
        .y = area.y + t.menu_padding,
        .w = area.right() - readingWidth(text) - left,
        .h = t.control_height,
    };
}

/// Where the number goes, hard against the right edge.
pub fn reading(area: Rect, text: []const u8) Rect {
    const t = theme.current();
    return .{
        .x = area.right() - t.menu_padding - draw.Surface.textWidth(text),
        .y = area.y + @divTrunc(area.h - draw.Surface.textHeight(), 2),
        .w = draw.Surface.textWidth(text),
        .h = draw.Surface.textHeight(),
    };
}

fn readingWidth(text: []const u8) i32 {
    const t = theme.current();
    return t.gap + draw.Surface.textWidth(text) + t.menu_padding;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const menu = Rect{ .x = 40, .y = 22, .w = 220, .h = 180 };

test "the strip is a control tall, and the list gets the rest" {
    const bar = of(menu);
    try testing.expectEqual(menu.y, bar.y);
    try testing.expectEqual(menu.w, bar.w);
    try testing.expectEqual(theme.current().control_height + theme.current().menu_padding * 2, bar.h);

    const rest = below(menu);
    try testing.expectEqual(bar.bottom(), rest.y);
    try testing.expectEqual(menu.bottom(), rest.bottom());
}

test "picture, groove and number sit in that order and do not overlap" {
    draw.useLinked();
    const bar = of(menu);
    const picture = button(bar);
    const groove = track(bar, "100%");
    const number = reading(bar, "100%");

    try testing.expect(picture.x >= bar.x);
    try testing.expectEqual(picture.right(), groove.x);
    try testing.expect(groove.right() <= number.x);
    try testing.expectEqual(bar.right() - theme.current().menu_padding, number.right());
}

test "a longer reading takes its room from the groove" {
    draw.useLinked();
    const bar = of(menu);
    const short = track(bar, "5%");
    const long = track(bar, "16 of 16");

    try testing.expect(long.w < short.w);
    try testing.expectEqual(short.x, long.x);
    // Both still start after the picture and end before their own number.
    try testing.expect(long.right() <= reading(bar, "16 of 16").x);
}

test "everything stays inside the panel" {
    draw.useLinked();
    const bar = of(menu);
    for ([_][]const u8{ "0%", "100%", "16 of 16" }) |text| {
        const groove = track(bar, text);
        try testing.expect(groove.x >= bar.x);
        try testing.expect(groove.right() <= bar.right());
        try testing.expect(groove.y >= bar.y and groove.bottom() <= bar.bottom());
    }
}
