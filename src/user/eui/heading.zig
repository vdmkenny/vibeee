//! A section's title inside a pane.
//!
//! A dim line of words, a picture before it when the section has one, and a
//! hairline under it that says where the section begins. Painted rather than
//! run: nothing about it answers the pointer, and a pane with three sections
//! wants three of these drawn the same way rather than three ideas of one.

const std = @import("std");
const draw = @import("draw.zig");
const icons = @import("icon.zig");
const theme = @import("theme.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

/// Room between a picture and the words.
const GAP: i32 = 6;
/// Air under the hairline before the section's first row.
const BELOW: i32 = 8;

/// What a heading takes from the top of its area, hairline and air included.
pub fn height() i32 {
    return Surface.textHeight() + theme.enlarged(BELOW);
}

pub fn paint(surface: Surface, area: Rect, text: []const u8, picture: ?icons.Glyph) void {
    const t = theme.current();
    var x = area.x;
    if (picture) |g| {
        surface.picture(x, Surface.iconTopFor(area.y), g, t.text_dim);
        x += theme.enlarged(@as(i32, @intCast(icons.WIDTH)) + GAP);
    }
    surface.text(x, area.y, text, t.text_dim);
    surface.fill(.{ .x = area.x, .y = area.y + Surface.textHeight() + 2, .w = area.w, .h = 1 }, t.line);
}

test "a heading is its words and the air under the rule" {
    try std.testing.expect(height() > Surface.textHeight());
    try std.testing.expectEqual(Surface.textHeight() + BELOW, height());
}
