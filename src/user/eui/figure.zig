//! A figure with its name: one number, large, on a tile with a dim label
//! above it.
//!
//! What a dashboard is made of, and what a sheet's armour class and a
//! monitor's reading have in common. The number is drawn in the surface's
//! large face, so every figure in the system is the same size and shape.

const std = @import("std");
const draw = @import("draw.zig");
const icons = @import("icon.zig");
const theme = @import("theme.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

/// Air inside the tile's edge, sideways and down.
const PAD_X: i32 = 8;
const PAD_Y: i32 = 6;
/// How tall a tile is: the label, the figure under it, and the air.
pub fn height() i32 {
    return theme.enlarged(PAD_Y) * 2 + Surface.textHeight() + 2 + Surface.titleHeight();
}

/// Where the figure's text sits in `area`, for a caller that draws beside it.
pub fn figureRect(area: Rect) Rect {
    const top = area.y + theme.enlarged(PAD_Y) + Surface.textHeight() + 2;
    return .{ .x = area.x + theme.enlarged(PAD_X), .y = top, .w = area.w - theme.enlarged(PAD_X) * 2, .h = Surface.titleHeight() };
}

pub fn paint(surface: Surface, area: Rect, label: []const u8, value: []const u8, picture: ?icons.Glyph) void {
    const t = theme.current();
    surface.fill(area, t.surface_hot);
    surface.frame(area, t.line);

    var x = area.x + theme.enlarged(PAD_X);
    const label_y = area.y + theme.enlarged(PAD_Y);
    if (picture) |g| {
        surface.picture(x, Surface.iconTopFor(label_y), g, t.text_dim);
        x += theme.enlarged(@as(i32, @intCast(icons.WIDTH)) + 4);
    }
    surface.text(x, label_y, label, t.text_dim);

    const at = figureRect(area);
    surface.title(at.x, at.y, value, t.text);
}

test "a tile holds its label and its figure with air around them" {
    const area = Rect{ .x = 0, .y = 0, .w = 120, .h = height() };
    const at = figureRect(area);
    try std.testing.expect(at.y > area.y + Surface.textHeight());
    try std.testing.expectEqual(area.bottom() - PAD_Y, at.bottom());
}
