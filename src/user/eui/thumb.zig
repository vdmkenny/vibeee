//! A picture, shrunk to fit and stood the right way up.
//!
//! Two things a picture needs before it can be shown beside anything else. It
//! is almost never the size of the room it goes in, and a photograph carries
//! the way the camera was held rather than the way it should be looked at, so
//! showing one without turning it shows it on its side.
//!
//! Nearest neighbour, on purpose. Averaging is what a picture wants on a
//! screen with pixels to spare; this panel is 800 by 480 and the processor is
//! a 630 MHz single core, so a preview that took a second to smooth would be
//! a file manager that stops when the cursor moves. Sampled, it costs one
//! read per pixel drawn and not one per pixel read, which is what makes a
//! large photograph affordable at all.
//!
//! Where the picture lands is pure arithmetic and tested here; the drawing is
//! the surface's.

const std = @import("std");
const draw = @import("draw.zig");
const exif = @import("lib").exif;

const Rect = draw.Rect;
const Surface = draw.Surface;

/// A picture as this draws one: words in a row, and its shape.
pub const Source = struct {
    pixels: []const u32,
    width: u16,
    height: u16,

    fn at(self: Source, x: u32, y: u32) u32 {
        const index = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        return if (index < self.pixels.len) self.pixels[index] else 0;
    }
};

/// A pixel in a picture, and a picture's shape. Named rather than anonymous
/// so that what one function returns is what the next one takes.
pub const Point = struct { x: u32, y: u32 };
pub const Size = struct { w: u16, h: u16 };

/// How large a picture reads once it is upright: a quarter turn swaps its
/// sides.
pub fn uprightSize(width: u16, height: u16, turn: exif.Orientation) Size {
    return if (turn.turned()) .{ .w = height, .h = width } else .{ .w = width, .h = height };
}

/// Whether something smaller than its room may be drawn larger than it is.
pub const Scale = enum {
    /// Never past its own size. A preview blown up is a blurry claim to
    /// detail the picture does not have.
    natural,
    /// As large as the room allows. What a program's own pixels want: a
    /// fixed logical size shown in whatever window the desktop gives it,
    /// where drawing it small in the middle would be the wrong answer.
    fill,
};

/// Where a picture of this shape goes inside `area`, keeping its proportions
/// and growing or not according to `policy`.
///
/// Centred in what is left over, because a picture pinned to a corner reads
/// as one that failed to load rather than as one smaller than its frame.
pub fn fitAs(area: Rect, width: u16, height: u16, policy: Scale) Rect {
    if (width == 0 or height == 0 or area.w <= 0 or area.h <= 0) {
        return .{ .x = area.x, .y = area.y, .w = 0, .h = 0 };
    }

    const w: i64 = width;
    const h: i64 = height;

    // Worked out at the picture's full size, so the proportions are exact:
    // a rounded scale factor costs a picture nearly as large as its room a
    // border of nothing, which reads as a border somebody meant.
    //
    // As wide as the room, unless that makes it taller than the room, in
    // which case the height is what binds.
    var wide: i64 = area.w;
    var tall: i64 = @divTrunc(wide * h, w);
    if (tall > area.h) {
        tall = area.h;
        wide = @divTrunc(tall * w, h);
    }

    if (policy == .natural and wide > w) {
        wide = w;
        tall = h;
    }

    const drawn_w: i32 = @intCast(@max(wide, 1));
    const drawn_h: i32 = @intCast(@max(tall, 1));

    return .{
        .x = area.x + @divTrunc(area.w - drawn_w, 2),
        .y = area.y + @divTrunc(area.h - drawn_h, 2),
        .w = drawn_w,
        .h = drawn_h,
    };
}

/// The same, for a preview: never larger than the picture itself.
pub fn fit(area: Rect, width: u16, height: u16) Rect {
    return fitAs(area, width, height, .natural);
}

/// The widest a drawn picture may be before this stops keeping a column
/// table for it. Wider than any window on this panel; a caller that beats it
/// gets the plain path rather than a refusal.
pub const COLUMNS_MAX = 1024;

/// Where each stored pixel is, as one number and two steps.
///
/// A turn is an affine map on indices, so the whole of it is a place to start
/// and how far to move for one step across and one step down. Derived by
/// asking `sampleAt` for three corners rather than by writing the eight cases
/// out again: the case analysis is tested once, over there, and this is the
/// fast form of the same answer.
const Walk = struct {
    base: i32,
    across: i32,
    down: i32,

    fn of(width: u16, height: u16, turn: exif.Orientation) Walk {
        const upright = uprightSize(width, height, turn);
        const origin = indexOf(sampleAt(0, 0, width, height, turn), width);

        return .{
            .base = origin,
            .across = if (upright.w > 1)
                indexOf(sampleAt(1, 0, width, height, turn), width) - origin
            else
                0,
            .down = if (upright.h > 1)
                indexOf(sampleAt(0, 1, width, height, turn), width) - origin
            else
                0,
        };
    }
};

fn indexOf(at: Point, width: u16) i32 {
    return @intCast(at.y * @as(u32, width) + at.x);
}

/// Draw `source` into `into`, sampled, and turned as the camera asks.
///
/// The loop walks the destination: every pixel on screen is written exactly
/// once whatever the picture's size, and nothing is read that is not shown.
///
/// Which pixel each column reads is worked out once for the whole picture
/// rather than per row, so the inner loop is an add, a load and a store. The
/// two divisions a nearest-neighbour scale needs are the expensive part on a
/// processor of this age, and there are as many of them as there are columns
/// instead of as there are pixels.
pub fn paint(surface: Surface, into: Rect, source: Source, turn: exif.Orientation) void {
    const target = into.intersect(surface.clip);
    if (target.isEmpty() or source.width == 0 or source.height == 0) return;
    if (into.w <= 0 or into.h <= 0 or target.w > COLUMNS_MAX) return;

    const upright = uprightSize(source.width, source.height, turn);
    const walk = Walk.of(source.width, source.height, turn);

    // One entry per column drawn: how far into the picture that column reads.
    var columns: [COLUMNS_MAX]i32 = undefined;
    const skipped = target.x - into.x;
    for (columns[0..@intCast(target.w)], 0..) |*offset, i| {
        const dx = skipped + @as(i32, @intCast(i));
        const up_x = @divTrunc(dx * @as(i32, upright.w), into.w);
        offset.* = up_x * walk.across;
    }

    const limit: i32 = @intCast(source.pixels.len);
    var y: i32 = 0;
    while (y < target.h) : (y += 1) {
        const dy = (target.y - into.y) + y;
        const up_y = @divTrunc(dy * @as(i32, upright.h), into.h);
        const row = walk.base + up_y * walk.down;

        const line = surface.pixels + @as(usize, @intCast((target.y + y) * surface.stride + target.x));
        for (columns[0..@intCast(target.w)], 0..) |offset, i| {
            const at = row + offset;
            // A picture whose buffer is shorter than its own shape claims is
            // a picture from somewhere else; it reads as nothing rather than
            // as whatever is past the end of it.
            line[i] = if (at >= 0 and at < limit) source.pixels[@intCast(at)] else 0;
        }
    }
}

/// Which stored pixel shows at `(x, y)` of the upright picture.
///
/// Written as the inverse of the turn rather than as eight cases of a rotate:
/// the caller is asking where to read, and every one of these is the same two
/// swaps with different signs.
pub fn sampleAt(x: u32, y: u32, width: u16, height: u16, turn: exif.Orientation) Point {
    const w: u32 = width;
    const h: u32 = height;

    // Undo the quarter turns first: the picture was stored turned, so reading
    // it upright means turning back.
    var sx: u32 = x;
    var sy: u32 = y;
    switch (turn.quarters()) {
        0 => {},
        // A quarter clockwise: the upright picture is `h` wide, so the
        // across-and-down of it are bounded by the stored height and width
        // the other way round. Getting those two the wrong way about is what
        // makes a turn read as a smear.
        1 => {
            sx = y;
            sy = h -| 1 -| @min(x, h -| 1);
        },
        2 => {
            sx = w -| 1 -| @min(x, w -| 1);
            sy = h -| 1 -| @min(y, h -| 1);
        },
        3 => {
            sx = w -| 1 -| @min(y, w -| 1);
            sy = x;
        },
    }

    if (turn.mirrored()) sx = w -| 1 -| @min(sx, w -| 1);

    return .{ .x = @min(sx, w -| 1), .y = @min(sy, h -| 1) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const room = Rect{ .x = 10, .y = 20, .w = 200, .h = 100 };

test "a picture keeps its proportions and is centred in what is left" {
    // Wider than its room: the width binds, and the spare height is split.
    const wide = fit(room, 400, 100);
    try testing.expectEqual(@as(i32, 200), wide.w);
    try testing.expectEqual(@as(i32, 50), wide.h);
    try testing.expectEqual(room.x, wide.x);
    try testing.expectEqual(room.y + 25, wide.y);

    // Taller than its room: the height binds.
    const tall = fit(room, 100, 400);
    try testing.expectEqual(@as(i32, 100), tall.h);
    try testing.expectEqual(@as(i32, 25), tall.w);
    try testing.expect(tall.x > room.x);
}

test "a small picture is not blown up to fill the room" {
    const small = fit(room, 20, 10);
    try testing.expectEqual(@as(i32, 20), small.w);
    try testing.expectEqual(@as(i32, 10), small.h);
}

test "asked to fill, the same picture is drawn as large as the room allows" {
    // Twice as wide as it is tall, in a room twice as wide as it is tall:
    // it fills the room exactly.
    const filled = fitAs(room, 20, 10, .fill);
    try testing.expectEqual(@as(i32, 200), filled.w);
    try testing.expectEqual(@as(i32, 100), filled.h);
    try testing.expectEqual(room.x, filled.x);
    try testing.expectEqual(room.y, filled.y);

    // Squarer than its room: the height binds, and the spare width is split
    // rather than stretched.
    const boxed = fitAs(room, 100, 100, .fill);
    try testing.expectEqual(@as(i32, 100), boxed.w);
    try testing.expectEqual(@as(i32, 100), boxed.h);
    try testing.expectEqual(room.x + 50, boxed.x);

    // Nothing to draw still takes no room, whichever way it is asked.
    try testing.expectEqual(@as(i32, 0), fitAs(room, 0, 10, .fill).w);
}

test "a picture nearly as large as its room keeps its size" {
    // A picture four pixels narrower than its room is drawn four pixels
    // narrower, not at whatever coarser step a scale factor would land on.
    const snug = fitAs(.{ .x = 0, .y = 0, .w = 796, .h = 576 }, 800, 480, .fill);
    try testing.expectEqual(@as(i32, 796), snug.w);
    try testing.expectEqual(@as(i32, 477), snug.h);

    // And it stays centred in what is left over.
    try testing.expectEqual(@as(i32, 0), snug.x);
    try testing.expectEqual(@as(i32, 49), snug.y);
}

test "nothing to draw takes no room" {
    try testing.expectEqual(@as(i32, 0), fit(room, 0, 10).w);
    try testing.expectEqual(@as(i32, 0), fit(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, 10, 10).w);
}

test "a quarter turn swaps which way round it reads" {
    const upright = uprightSize(640, 480, .up);
    try testing.expectEqual(@as(u16, 640), upright.w);
    try testing.expectEqual(@as(u16, 480), upright.h);

    const turned = uprightSize(640, 480, .left);
    try testing.expectEqual(@as(u16, 480), turned.w);
    try testing.expectEqual(@as(u16, 640), turned.h);
}

test "an upright picture samples itself" {
    const at = sampleAt(3, 7, 100, 50, .up);
    try testing.expectEqual(@as(u32, 3), at.x);
    try testing.expectEqual(@as(u32, 7), at.y);
}

test "turning reads the corner that becomes the top left" {
    // Stored on its left side: the upright top left comes from the stored
    // bottom left.
    const left = sampleAt(0, 0, 4, 3, .left);
    try testing.expectEqual(@as(u32, 0), left.x);
    try testing.expectEqual(@as(u32, 2), left.y);

    // Upside down: the upright top left is the stored bottom right.
    const down = sampleAt(0, 0, 4, 3, .down);
    try testing.expectEqual(@as(u32, 3), down.x);
    try testing.expectEqual(@as(u32, 2), down.y);

    // Mirrored: the same row, read from the other end.
    const mirrored = sampleAt(0, 1, 4, 3, .mirror_x);
    try testing.expectEqual(@as(u32, 3), mirrored.x);
    try testing.expectEqual(@as(u32, 1), mirrored.y);
}

test "every sample lands inside the picture, whichever way it is turned" {
    const w: u16 = 7;
    const h: u16 = 5;

    for (std.enums.values(exif.Orientation)) |turn| {
        const upright = uprightSize(w, h, turn);
        var y: u32 = 0;
        while (y < upright.h) : (y += 1) {
            var x: u32 = 0;
            while (x < upright.w) : (x += 1) {
                const at = sampleAt(x, y, w, h, turn);
                try testing.expect(at.x < w);
                try testing.expect(at.y < h);
            }
        }
    }
}

test "an upright turn reads every pixel exactly once" {
    // What makes this a turn rather than a smear: no two places in the
    // upright picture come from the same stored pixel.
    const w: u16 = 4;
    const h: u16 = 3;

    for (std.enums.values(exif.Orientation)) |turn| {
        var seen = [_]bool{false} ** (@as(usize, w) * @as(usize, h));
        const upright = uprightSize(w, h, turn);

        var y: u32 = 0;
        while (y < upright.h) : (y += 1) {
            var x: u32 = 0;
            while (x < upright.w) : (x += 1) {
                const at = sampleAt(x, y, w, h, turn);
                const index = at.y * w + at.x;
                try testing.expect(!seen[index]);
                seen[index] = true;
            }
        }

        for (seen) |touched| try testing.expect(touched);
    }
}

test "the fast walk reads exactly what the tested rule says" {
    // The whole of the speed here is that a turn is an affine map on indices.
    // If that is ever untrue for some orientation, this is where it shows,
    // rather than in a preview that looks subtly wrong.
    const w: u16 = 6;
    const h: u16 = 4;

    for (std.enums.values(exif.Orientation)) |turn| {
        const walk = Walk.of(w, h, turn);
        const upright = uprightSize(w, h, turn);

        var y: u32 = 0;
        while (y < upright.h) : (y += 1) {
            var x: u32 = 0;
            while (x < upright.w) : (x += 1) {
                const slow = indexOf(sampleAt(x, y, w, h, turn), w);
                const fast = walk.base +
                    @as(i32, @intCast(x)) * walk.across +
                    @as(i32, @intCast(y)) * walk.down;
                try testing.expectEqual(slow, fast);
            }
        }
    }
}

test "a picture one pixel across does not step off the end of itself" {
    for (std.enums.values(exif.Orientation)) |turn| {
        const thin = Walk.of(1, 8, turn);
        const flat = Walk.of(8, 1, turn);
        const dot = Walk.of(1, 1, turn);

        // One of the two steps is nothing at all, which is what stops the
        // walk from leaving a picture with no room to move in.
        try testing.expect(thin.across == 0 or thin.down == 0);
        try testing.expect(flat.across == 0 or flat.down == 0);
        try testing.expectEqual(@as(i32, 0), dot.across);
        try testing.expectEqual(@as(i32, 0), dot.down);
    }
}
