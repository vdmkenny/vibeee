//! Where a panel anchored to something goes.
//!
//! A menu hanging off a bar indicator, a dropdown under a field: the caller
//! knows what it is anchored to and how big it wants to be, and the answer is
//! where that lands once the screen has had its say. An eleven pixel icon
//! near the right edge cannot have a two hundred pixel panel left-aligned
//! under it, so the panel slides until it fits.
//!
//! Pure, so it is host-tested rather than found out by opening a menu near a
//! corner.

const std = @import("std");
const draw = @import("draw.zig");

const Rect = draw.Rect;

/// How close a panel is allowed to get to the edge of the screen. Enough that
/// it reads as a panel over the desktop rather than as part of the frame.
pub const INSET: i32 = 6;

/// Which way the panel opens when there is room either way. A bar at the top
/// drops its menus down; one at the bottom sends them up.
pub const Side = enum { below, above };

/// The panel's rectangle: `w` by `h`, anchored to `anchor`, inside `screen`.
///
/// Preferred side first, the other side if it does not fit, and whichever has
/// more room if neither does. Horizontally it starts at the anchor's left
/// edge and slides left only as far as it must.
pub fn place(anchor: Rect, w: i32, h: i32, screen: Rect, side: Side) Rect {
    const width = @min(w, screen.w);
    const height = @min(h, screen.h);

    const above = anchor.y - screen.y;
    const below = screen.bottom() - anchor.bottom();
    const drops = switch (side) {
        .below => below >= height or below >= above,
        .above => !(above >= height or above > below),
    };

    const y = if (drops)
        @min(anchor.bottom(), screen.bottom() - height)
    else
        @max(anchor.y - height, screen.y);

    // Left aligned to what opened it, then slid left until it is on screen,
    // then held at the left edge if it is wider than everything.
    const limit = screen.right() - INSET - width;
    const x = @max(screen.x, @min(anchor.x, limit));

    return .{ .x = x, .y = y, .w = width, .h = height };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const panel_screen = Rect{ .x = 0, .y = 0, .w = 800, .h = 480 };
const W: i32 = 224;
const H: i32 = 180;

test "a panel opens under what it is anchored to, aligned with it" {
    const button = Rect{ .x = 40, .y = 0, .w = 26, .h = 22 };
    const panel = place(button, W, H, panel_screen, .below);

    try testing.expectEqual(button.x, panel.x);
    try testing.expectEqual(button.bottom(), panel.y);
    try testing.expectEqual(W, panel.w);
    try testing.expectEqual(H, panel.h);
}

test "an anchor near the right edge slides the panel back on screen" {
    // The case this exists for: a status icon a few pixels from the edge.
    const icon = Rect{ .x = 776, .y = 0, .w = 24, .h = 22 };
    const panel = place(icon, W, H, panel_screen, .below);

    try testing.expect(panel.right() <= panel_screen.right() - INSET);
    try testing.expectEqual(panel_screen.right() - INSET - W, panel.x);
    // It slid rather than shrank.
    try testing.expectEqual(W, panel.w);
}

test "a bar at the bottom sends its menus up" {
    const cell = Rect{ .x = 300, .y = 458, .w = 24, .h = 22 };
    const panel = place(cell, W, H, panel_screen, .above);

    try testing.expectEqual(cell.y - H, panel.y);
    try testing.expect(panel.y >= panel_screen.y);
}

test "no room the preferred way takes the other way" {
    const cell = Rect{ .x = 300, .y = 420, .w = 24, .h = 22 };
    // Asked to drop, but only 38 rows below and 420 above.
    const panel = place(cell, W, H, panel_screen, .below);
    try testing.expectEqual(cell.y - H, panel.y);
    try testing.expect(panel.bottom() <= cell.y);
}

test "no room either way stays on screen" {
    const squat = Rect{ .x = 0, .y = 0, .w = 200, .h = 60 };
    const cell = Rect{ .x = 10, .y = 20, .w = 24, .h = 22 };
    const panel = place(cell, W, H, squat, .below);

    try testing.expect(panel.y >= squat.y);
    try testing.expect(panel.bottom() <= squat.bottom());
    try testing.expect(panel.x >= squat.x);
    // Wider and taller than the screen is as big as the screen.
    try testing.expectEqual(squat.w, panel.w);
    try testing.expectEqual(squat.h, panel.h);
}

test "the panel is inside the screen wherever it is anchored" {
    var x: i32 = 0;
    while (x < panel_screen.w) : (x += 37) {
        for ([_]Side{ .below, .above }) |side| {
            const cell = Rect{ .x = x, .y = 0, .w = 24, .h = 22 };
            const panel = place(cell, W, H, panel_screen, side);
            try testing.expect(panel.x >= panel_screen.x);
            try testing.expect(panel.right() <= panel_screen.right());
            try testing.expect(panel.y >= panel_screen.y);
            try testing.expect(panel.bottom() <= panel_screen.bottom());
        }
    }
}
