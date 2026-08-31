//! What is left of an area once other rectangles are taken out of it.
//!
//! A single-buffered display shows every write the moment it lands, so a
//! solid fill under something about to be drawn over it is a flash of that
//! colour, once per repaint. It is faint in an emulator, where the fill and
//! the draw land microseconds apart, and plain on the machine, where the
//! panel's memory is slow enough that the gap is visible.
//!
//! The answer is not to draw faster: it is not to draw there at all. Tiled
//! windows never overlap, so what the desktop is actually visible through is
//! the screen minus the bar minus every opaque window, and that is a handful
//! of rectangles this works out before anything is painted.
//!
//! Pure arithmetic on rectangles, so it is host-tested rather than judged by
//! looking at a screen.

const std = @import("std");
const draw = @import("draw.zig");

const Rect = draw.Rect;

pub const Region = struct {
    /// One cut turns a rectangle into at most four, and a tiling layout holds
    /// sixteen windows, so this is far more room than a screen needs. It
    /// exists so the arithmetic is bounded rather than because it runs out.
    pub const MAX = 32;

    rects: [MAX]Rect = @splat(.{}),
    len: usize = 0,

    /// Everything, to start subtracting from.
    pub fn of(whole: Rect) Region {
        if (whole.isEmpty()) return .{};
        var out = Region{};
        out.rects[0] = whole;
        out.len = 1;
        return out;
    }

    pub fn items(self: *const Region) []const Rect {
        return self.rects[0..self.len];
    }

    pub fn isEmpty(self: *const Region) bool {
        return self.len == 0;
    }

    /// Take `cutter` out of what is left.
    ///
    /// Running out of room keeps the piece whole rather than dropping it: an
    /// over-painted rectangle is a flicker in one place, and a dropped one is
    /// a hole showing whatever the screen held before.
    pub fn subtract(self: *Region, cutter: Rect) void {
        if (cutter.isEmpty()) return;

        var out = Region{};
        for (self.rects[0..self.len]) |piece| {
            const overlap = piece.intersect(cutter);
            if (overlap.isEmpty()) {
                out.push(piece);
                continue;
            }

            // Above, below, then the two sides of what is left between them,
            // which is the division that never produces an overlap.
            var parts: [4]Rect = undefined;
            var count: usize = 0;

            if (overlap.y > piece.y) {
                parts[count] = .{ .x = piece.x, .y = piece.y, .w = piece.w, .h = overlap.y - piece.y };
                count += 1;
            }
            if (overlap.bottom() < piece.bottom()) {
                parts[count] = .{ .x = piece.x, .y = overlap.bottom(), .w = piece.w, .h = piece.bottom() - overlap.bottom() };
                count += 1;
            }
            if (overlap.x > piece.x) {
                parts[count] = .{ .x = piece.x, .y = overlap.y, .w = overlap.x - piece.x, .h = overlap.h };
                count += 1;
            }
            if (overlap.right() < piece.right()) {
                parts[count] = .{ .x = overlap.right(), .y = overlap.y, .w = piece.right() - overlap.right(), .h = overlap.h };
                count += 1;
            }

            if (out.len + count > MAX) {
                out.push(piece);
                continue;
            }
            for (parts[0..count]) |part| out.push(part);
        }
        self.* = out;
    }

    fn push(self: *Region, piece: Rect) void {
        if (piece.isEmpty() or self.len == MAX) return;
        self.rects[self.len] = piece;
        self.len += 1;
    }

    /// How many pixels are left, for the tests to check against the area that
    /// went in.
    pub fn area(self: *const Region) i64 {
        var total: i64 = 0;
        for (self.rects[0..self.len]) |r| total += @as(i64, r.w) * @as(i64, r.h);
        return total;
    }

    pub fn covers(self: *const Region, px: i32, py: i32) bool {
        for (self.rects[0..self.len]) |r| {
            if (r.contains(px, py)) return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const screen = Rect{ .x = 0, .y = 0, .w = 800, .h = 480 };

test "nothing taken out leaves the whole thing" {
    var r = Region.of(screen);
    try testing.expectEqual(@as(usize, 1), r.items().len);
    try testing.expectEqual(@as(i64, 800 * 480), r.area());

    r.subtract(.{ .x = 900, .y = 0, .w = 100, .h = 100 });
    try testing.expectEqual(@as(i64, 800 * 480), r.area());
}

test "the bar comes off the top and leaves one piece" {
    var r = Region.of(screen);
    r.subtract(.{ .x = 0, .y = 0, .w = 800, .h = 22 });

    try testing.expectEqual(@as(usize, 1), r.items().len);
    try testing.expectEqual(Rect{ .x = 0, .y = 22, .w = 800, .h = 458 }, r.items()[0]);
    try testing.expect(!r.covers(400, 10));
    try testing.expect(r.covers(400, 22));
}

test "a tiling that fills the screen leaves nothing to paint" {
    var r = Region.of(screen);
    r.subtract(.{ .x = 0, .y = 0, .w = 800, .h = 22 });
    // Two tiles side by side, exactly covering what the bar left.
    r.subtract(.{ .x = 0, .y = 22, .w = 480, .h = 458 });
    r.subtract(.{ .x = 480, .y = 22, .w = 320, .h = 458 });

    try testing.expect(r.isEmpty());
    try testing.expectEqual(@as(i64, 0), r.area());
}

test "a window in the middle leaves a frame around it" {
    var r = Region.of(screen);
    r.subtract(.{ .x = 200, .y = 100, .w = 400, .h = 200 });

    // Whatever the division, the pixels have to add up and the hole has to
    // be a hole.
    try testing.expectEqual(@as(i64, 800 * 480 - 400 * 200), r.area());
    try testing.expect(!r.covers(400, 200));
    try testing.expect(r.covers(199, 200));
    try testing.expect(r.covers(600, 200));
    try testing.expect(r.covers(400, 99));
    try testing.expect(r.covers(400, 300));
}

test "the pieces never overlap, however many cuts are made" {
    var r = Region.of(screen);
    r.subtract(.{ .x = 0, .y = 0, .w = 800, .h = 22 });
    r.subtract(.{ .x = 40, .y = 60, .w = 200, .h = 150 });
    r.subtract(.{ .x = 300, .y = 200, .w = 250, .h = 120 });
    r.subtract(.{ .x = 600, .y = 40, .w = 120, .h = 400 });

    for (r.items(), 0..) |a, i| {
        for (r.items()[i + 1 ..]) |b| {
            try testing.expect(a.intersect(b).isEmpty());
        }
    }

    // And they still add up to the screen less what was cut out of it.
    const cut: i64 = 800 * 22 + 200 * 150 + 250 * 120 + 120 * 400;
    try testing.expectEqual(@as(i64, 800 * 480) - cut, r.area());
}

test "a cut covering everything leaves nothing" {
    var r = Region.of(screen);
    r.subtract(screen);
    try testing.expect(r.isEmpty());

    var wider = Region.of(screen);
    wider.subtract(.{ .x = -100, .y = -100, .w = 2000, .h = 2000 });
    try testing.expect(wider.isEmpty());
}
