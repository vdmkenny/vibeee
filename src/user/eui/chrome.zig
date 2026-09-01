//! What a window is made of: a strip along the top, a strip along the
//! bottom, and the work between them.
//!
//! Every window here has some of this and each one used to work it out for
//! itself, which is how two windows side by side came to disagree about how
//! tall a strip is by six pixels. One answer, one height, and a window says
//! which strips it has rather than where they go.
//!
//! Pure arithmetic, host-tested: a layout that is a pixel out is a thing to
//! catch here rather than to notice on a panel.

const std = @import("std");
const draw = @import("draw.zig");
const theme = @import("theme.zig");

const Rect = draw.Rect;

/// Which strips a window has. Both are optional and neither is anywhere but
/// its own edge, so this is the whole of what a caller decides.
pub const Wants = struct {
    /// A menu bar, a row of places, a path: whatever a window says about
    /// itself before the work starts.
    top: bool = false,
    /// A row of keys, a status line: whatever it says underneath.
    bottom: bool = false,
};

pub const Layout = struct {
    /// Empty when the window asked for no such strip, which draws as nothing
    /// rather than as a line in the wrong place.
    top: Rect = .{},
    body: Rect = .{},
    bottom: Rect = .{},
};

pub fn split(area: Rect, wants: Wants) Layout {
    const strip = theme.stripHeight();
    const above: i32 = if (wants.top) @min(strip, area.h) else 0;
    const below: i32 = if (wants.bottom) @min(strip, area.h - above) else 0;

    return .{
        .top = if (wants.top) .{ .x = area.x, .y = area.y, .w = area.w, .h = above } else .{},
        .body = .{
            .x = area.x,
            .y = area.y + above,
            .w = area.w,
            .h = area.h - above - below,
        },
        .bottom = if (wants.bottom) .{
            .x = area.x,
            .y = area.bottom() - below,
            .w = area.w,
            .h = below,
        } else .{},
    };
}

test "the parts tile the window exactly" {
    const area = Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    const parts = split(area, .{ .top = true, .bottom = true });
    const strip = theme.stripHeight();

    try std.testing.expectEqual(area.y, parts.top.y);
    try std.testing.expectEqual(parts.top.bottom(), parts.body.y);
    try std.testing.expectEqual(parts.body.bottom(), parts.bottom.y);
    try std.testing.expectEqual(area.bottom(), parts.bottom.bottom());
    try std.testing.expectEqual(strip, parts.top.h);
    try std.testing.expectEqual(strip, parts.bottom.h);
    try std.testing.expectEqual(area.h - strip * 2, parts.body.h);
}

test "a strip nobody asked for takes nothing and is nowhere" {
    const area = Rect{ .x = 5, .y = 7, .w = 200, .h = 100 };

    const bare = split(area, .{});
    try std.testing.expect(bare.top.isEmpty());
    try std.testing.expect(bare.bottom.isEmpty());
    try std.testing.expectEqual(area.h, bare.body.h);
    try std.testing.expectEqual(area.y, bare.body.y);

    const under = split(area, .{ .bottom = true });
    try std.testing.expect(under.top.isEmpty());
    try std.testing.expectEqual(area.y, under.body.y);
    try std.testing.expectEqual(area.bottom(), under.bottom.bottom());
}

test "a window too short for its strips keeps them inside itself" {
    // Nothing may be drawn outside the window, however little of it there is.
    const squashed = split(.{ .x = 0, .y = 0, .w = 100, .h = 10 }, .{ .top = true, .bottom = true });
    try std.testing.expect(squashed.top.h <= 10);
    try std.testing.expect(squashed.body.h >= 0);
    try std.testing.expectEqual(@as(i32, 10), squashed.top.h + squashed.body.h + squashed.bottom.h);
}

test "the strips keep the window's own left and width" {
    const area = Rect{ .x = 12, .y = 3, .w = 260, .h = 180 };
    const parts = split(area, .{ .top = true, .bottom = true });
    for ([_]Rect{ parts.top, parts.body, parts.bottom }) |part| {
        try std.testing.expectEqual(area.x, part.x);
        try std.testing.expectEqual(area.w, part.w);
    }
}
