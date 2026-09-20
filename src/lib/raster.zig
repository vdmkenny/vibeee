//! Drawing into a picture: the marks a person makes with a pointer.
//!
//! A canvas is a rectangle of pixels and nothing else, with no window and no
//! memory of its own. Every mark is clipped to it, so a stroke that runs off
//! an edge stops there rather than wrapping into the row below.
//!
//! Pure, and tested on the host: what a tool does to the pixels is the whole
//! of a drawing program that can be checked without a screen.

const std = @import("std");
const rgb = @import("rgb.zig");

pub const Colour = rgb.Colour;

/// Whether two colours are the same to the eye. The unused byte is not part
/// of a colour, and a picture decoded from a file may carry anything in it.
pub fn same(a: Colour, b: Colour) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

/// A shape's outline, or the whole of it.
pub const Fill = enum { outline, solid };

/// How far a flood got.
pub const Spread = enum {
    /// Every pixel the colour could reach took it.
    done,
    /// The runs outgrew the room the caller lent. What was reached is
    /// filled and the rest is not.
    ran_out,
};

/// One pixel a flood has still to spread from.
pub const Seed = packed struct(u32) { x: u16, y: u16 };

/// How far from the origin a point may be before it is brought in. A pointer
/// dragged far outside the window still names a direction, and the
/// arithmetic below stays inside a word.
const REACH: i32 = 1 << 15;

fn near(value: i32) i32 {
    return std.math.clamp(value, -REACH, REACH);
}

pub const Canvas = struct {
    pixels: []Colour,
    width: u16,
    height: u16,

    pub fn of(pixels: []Colour, width: u16, height: u16) Canvas {
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    pub fn count(self: Canvas) usize {
        return @as(usize, self.width) * self.height;
    }

    pub fn holds(self: Canvas, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x < self.width and y < self.height;
    }

    pub fn get(self: Canvas, x: i32, y: i32) ?Colour {
        if (!self.holds(x, y)) return null;
        return self.pixels[self.at(x, y)];
    }

    /// One pixel, where it is on the canvas. Off it, nothing happens.
    pub fn set(self: Canvas, x: i32, y: i32, colour: Colour) void {
        if (!self.holds(x, y)) return;
        self.pixels[self.at(x, y)] = colour;
    }

    fn at(self: Canvas, x: i32, y: i32) usize {
        return @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
    }

    /// The whole picture in one colour, which is what a new one is.
    pub fn clear(self: Canvas, colour: Colour) void {
        @memset(self.pixels[0..self.count()], colour);
    }

    /// The brush: a square of `size` pixels about the point. What a pencil
    /// leaves, and what every line and edge below is drawn with.
    pub fn dot(self: Canvas, x: i32, y: i32, size: u8, colour: Colour) void {
        const side: i32 = @max(size, 1);
        const from = -@divTrunc(side - 1, 2);
        var down: i32 = 0;
        while (down < side) : (down += 1) {
            var across: i32 = 0;
            while (across < side) : (across += 1) {
                self.set(x + from + across, y + from + down, colour);
            }
        }
    }

    /// A straight line between two points: a step along the longer axis,
    /// carrying the error of the shorter one.
    pub fn line(self: Canvas, from_x: i32, from_y: i32, to_x: i32, to_y: i32, size: u8, colour: Colour) void {
        var end_x = near(to_x);
        var end_y = near(to_y);
        var x = near(from_x);
        var y = near(from_y);

        // Walked from the same end whichever way it was dragged: a line and
        // the same line backwards are the same pixels.
        if (y > end_y or (y == end_y and x > end_x)) {
            std.mem.swap(i32, &x, &end_x);
            std.mem.swap(i32, &y, &end_y);
        }

        const step_x: i32 = if (x < end_x) 1 else -1;
        const step_y: i32 = if (y < end_y) 1 else -1;
        const across: i32 = @intCast(@abs(end_x - x));
        const down: i32 = -@as(i32, @intCast(@abs(end_y - y)));
        var error_term = across + down;

        while (true) {
            self.dot(x, y, size, colour);
            if (x == end_x and y == end_y) break;
            const twice = error_term * 2;
            if (twice >= down) {
                error_term += down;
                x += step_x;
            }
            if (twice <= across) {
                error_term += across;
                y += step_y;
            }
        }
    }

    /// A rectangle between two corners, either way round.
    pub fn box(self: Canvas, from_x: i32, from_y: i32, to_x: i32, to_y: i32, size: u8, colour: Colour, fill: Fill) void {
        const left = @min(near(from_x), near(to_x));
        const right = @max(near(from_x), near(to_x));
        const top = @min(near(from_y), near(to_y));
        const bottom = @max(near(from_y), near(to_y));

        if (fill == .solid) {
            // Only the part on the canvas is walked: a rectangle dragged far
            // outside it is still a rectangle, and iterating the rest of it
            // would be counting to a number nobody can see.
            var row = @max(top, 0);
            const last_row = @min(bottom, @as(i32, self.height) - 1);
            const first = @max(left, 0);
            const last = @min(right, @as(i32, self.width) - 1);
            while (row <= last_row) : (row += 1) {
                var column = first;
                while (column <= last) : (column += 1) self.set(column, row, colour);
            }
            return;
        }

        self.line(left, top, right, top, size, colour);
        self.line(left, bottom, right, bottom, size, colour);
        self.line(left, top, left, bottom, size, colour);
        self.line(right, top, right, bottom, size, colour);
    }

    /// An ellipse in the rectangle between two corners, a row at a time.
    ///
    /// Row by row rather than around the curve, so an ellipse larger than the
    /// canvas costs the rows it covers rather than its own circumference. The
    /// half width of a row is the ellipse's own equation, in whole numbers.
    pub fn ellipse(self: Canvas, from_x: i32, from_y: i32, to_x: i32, to_y: i32, size: u8, colour: Colour, fill: Fill) void {
        const left = @min(near(from_x), near(to_x));
        const right = @max(near(from_x), near(to_x));
        const top = @min(near(from_y), near(to_y));
        const bottom = @max(near(from_y), near(to_y));

        const radius_x: i64 = @divTrunc(right - left, 2);
        const radius_y: i64 = @divTrunc(bottom - top, 2);
        if (radius_x == 0 or radius_y == 0) {
            self.line(left, top, right, bottom, size, colour);
            return;
        }
        const centre_x: i64 = left + radius_x;
        const centre_y: i64 = top + radius_y;
        const sx = radius_x * radius_x;
        const sy = radius_y * radius_y;

        // The brush reaches past the row it is on, so a row just off the
        // canvas still leaves a mark on it.
        const reach: i32 = @max(size, 1);
        var row: i32 = @max(top, -reach);
        const last: i32 = @min(bottom, @as(i32, self.height) - 1 + reach);
        var above: ?i64 = null;

        while (row <= last) : (row += 1) {
            const away: i64 = @as(i64, row) - centre_y;
            if (away * away > sy) {
                above = null;
                continue;
            }
            const half: i64 = @intCast(std.math.sqrt(@as(u64, @intCast(@divTrunc(sx * (sy - away * away), sy)))));

            if (fill == .solid) {
                var column = @max(@as(i32, @intCast(centre_x - half)), 0);
                const stop = @min(@as(i32, @intCast(centre_x + half)), @as(i32, self.width) - 1);
                while (column <= stop) : (column += 1) self.set(column, row, colour);
                above = half;
                continue;
            }

            // The run between this row's edge and the one above it, so the
            // curve has no gaps where it turns along the top and the bottom.
            const from_half = above orelse half;
            var step = @min(half, from_half);
            const outer = @max(half, from_half);
            while (step <= outer) : (step += 1) {
                self.dot(@intCast(centre_x - step), row, size, colour);
                self.dot(@intCast(centre_x + step), row, size, colour);
            }
            above = half;
        }
    }

    /// Spread a colour from one pixel over everything its own colour reaches,
    /// four ways. `seeds` is the room the caller lends for the runs still to
    /// be looked at; a fill that outgrows it stops and says so.
    pub fn flood(self: Canvas, from_x: i32, from_y: i32, colour: Colour, seeds: []Seed) Spread {
        if (!self.holds(from_x, from_y)) return .done;
        const target = self.pixels[self.at(from_x, from_y)];
        if (same(target, colour)) return .done;
        if (seeds.len == 0) return .ran_out;

        var pending: usize = 1;
        seeds[0] = .{ .x = @intCast(from_x), .y = @intCast(from_y) };
        var spread: Spread = .done;

        while (pending > 0) {
            pending -= 1;
            const seed = seeds[pending];
            const row: i32 = seed.y;
            if (!same(self.pixels[self.at(seed.x, row)], target)) continue;

            var left: i32 = seed.x;
            while (left > 0 and same(self.pixels[self.at(left - 1, row)], target)) left -= 1;
            var right: i32 = seed.x;
            while (right + 1 < self.width and same(self.pixels[self.at(right + 1, row)], target)) right += 1;

            var column = left;
            while (column <= right) : (column += 1) self.pixels[self.at(column, row)] = colour;

            for ([_]i32{ row - 1, row + 1 }) |near_row| {
                if (near_row < 0 or near_row >= self.height) continue;
                var scan = left;
                while (scan <= right) : (scan += 1) {
                    if (!same(self.pixels[self.at(scan, near_row)], target)) continue;
                    if (pending == seeds.len) {
                        spread = .ran_out;
                        break;
                    }
                    // The first pixel of a run is the seed; the rest of that
                    // run is reached from it.
                    seeds[pending] = .{ .x = @intCast(scan), .y = @intCast(near_row) };
                    pending += 1;
                    while (scan + 1 <= right and same(self.pixels[self.at(scan + 1, near_row)], target)) scan += 1;
                }
            }
        }
        return spread;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fuzzing = @import("fuzzing.zig");
const testing = std.testing;
const Choices = fuzzing.Choices;

const WHITE = Colour.hex(0xFFFFFF);
const BLACK = Colour.hex(0x000000);
const RED = Colour.hex(0xFF0000);

const Small = struct {
    pixels: [16 * 12]Colour = @splat(WHITE),

    fn canvas(self: *Small) Canvas {
        return Canvas.of(&self.pixels, 16, 12);
    }
};

/// How many pixels of a colour a canvas holds.
fn tally(canvas: Canvas, colour: Colour) usize {
    var found: usize = 0;
    for (canvas.pixels[0..canvas.count()]) |pixel| {
        if (same(pixel, colour)) found += 1;
    }
    return found;
}

test "a pixel off the canvas is not written, and one on it is" {
    var small = Small{};
    const canvas = small.canvas();

    canvas.set(-1, 0, BLACK);
    canvas.set(0, -1, BLACK);
    canvas.set(16, 0, BLACK);
    canvas.set(0, 12, BLACK);
    try testing.expectEqual(@as(usize, 0), tally(canvas, BLACK));

    canvas.set(3, 4, BLACK);
    try testing.expectEqual(@as(usize, 1), tally(canvas, BLACK));
    try testing.expectEqual(BLACK, canvas.get(3, 4).?);
    try testing.expectEqual(@as(?Colour, null), canvas.get(16, 4));
}

test "a brush leaves a square about the point, cut at the edges" {
    var small = Small{};
    const canvas = small.canvas();

    canvas.dot(5, 5, 3, BLACK);
    try testing.expectEqual(@as(usize, 9), tally(canvas, BLACK));
    try testing.expectEqual(BLACK, canvas.get(4, 4).?);
    try testing.expectEqual(BLACK, canvas.get(6, 6).?);
    try testing.expectEqual(WHITE, canvas.get(7, 7).?);

    canvas.clear(WHITE);
    canvas.dot(0, 0, 3, BLACK);
    // A corner keeps the quarter of the brush that is on the canvas.
    try testing.expectEqual(@as(usize, 4), tally(canvas, BLACK));
}

test "a line joins its ends, whichever way it is drawn" {
    var one = Small{};
    var other = Small{};
    const forward = one.canvas();
    const backward = other.canvas();

    forward.line(1, 2, 13, 9, 1, BLACK);
    backward.line(13, 9, 1, 2, 1, BLACK);
    try testing.expectEqualSlices(Colour, forward.pixels, backward.pixels);

    try testing.expectEqual(BLACK, forward.get(1, 2).?);
    try testing.expectEqual(BLACK, forward.get(13, 9).?);
    // Joined: every row it crosses has a pixel on it.
    var row: i32 = 2;
    while (row <= 9) : (row += 1) {
        var found = false;
        var column: i32 = 0;
        while (column < 16) : (column += 1) {
            if (same(forward.get(column, row).?, BLACK)) found = true;
        }
        try testing.expect(found);
    }
}

test "a line that runs off the canvas stops at the edge" {
    var small = Small{};
    const canvas = small.canvas();

    canvas.line(-40, 6, 40, 6, 1, BLACK);
    try testing.expectEqual(@as(usize, 16), tally(canvas, BLACK));

    canvas.clear(WHITE);
    canvas.line(-1000, -1000, 1000, 1000, 1, BLACK);
    try testing.expect(tally(canvas, BLACK) > 0);
}

test "a box is its four edges, or all of it" {
    var small = Small{};
    const canvas = small.canvas();

    canvas.box(2, 2, 6, 5, 1, BLACK, .outline);
    try testing.expectEqual(BLACK, canvas.get(2, 2).?);
    try testing.expectEqual(BLACK, canvas.get(6, 5).?);
    try testing.expectEqual(BLACK, canvas.get(4, 2).?);
    try testing.expectEqual(WHITE, canvas.get(4, 4).?);
    // Five across and four down: the edges are fourteen pixels.
    try testing.expectEqual(@as(usize, 14), tally(canvas, BLACK));

    canvas.clear(WHITE);
    canvas.box(6, 5, 2, 2, 1, BLACK, .solid);
    try testing.expectEqual(@as(usize, 20), tally(canvas, BLACK));
    try testing.expectEqual(BLACK, canvas.get(4, 4).?);
}

test "an ellipse touches the middle of each side of its box and leaves the corners" {
    var small = Small{};
    const canvas = small.canvas();

    canvas.ellipse(2, 2, 10, 10, 1, BLACK, .outline);
    try testing.expectEqual(BLACK, canvas.get(6, 2).?);
    try testing.expectEqual(BLACK, canvas.get(6, 10).?);
    try testing.expectEqual(BLACK, canvas.get(2, 6).?);
    try testing.expectEqual(BLACK, canvas.get(10, 6).?);
    try testing.expectEqual(WHITE, canvas.get(2, 2).?);
    try testing.expectEqual(WHITE, canvas.get(10, 10).?);
    try testing.expectEqual(WHITE, canvas.get(6, 6).?);

    canvas.clear(WHITE);
    canvas.ellipse(2, 2, 10, 10, 1, BLACK, .solid);
    try testing.expectEqual(BLACK, canvas.get(6, 6).?);
    try testing.expectEqual(WHITE, canvas.get(2, 2).?);
}

test "a fill spreads over its own colour and stops at another" {
    var small = Small{};
    const canvas = small.canvas();
    var seeds: [64]Seed = undefined;

    canvas.box(4, 3, 11, 8, 1, BLACK, .outline);
    try testing.expectEqual(Spread.done, canvas.flood(6, 5, RED, &seeds));

    // Inside the box, and nothing outside it.
    try testing.expectEqual(RED, canvas.get(6, 5).?);
    try testing.expectEqual(WHITE, canvas.get(0, 0).?);
    try testing.expectEqual(BLACK, canvas.get(4, 3).?);
    try testing.expectEqual(@as(usize, 6 * 4), tally(canvas, RED));
}

test "a fill of the colour already there changes nothing, and one off the canvas does nothing" {
    var small = Small{};
    const canvas = small.canvas();
    var seeds: [64]Seed = undefined;

    try testing.expectEqual(Spread.done, canvas.flood(5, 5, WHITE, &seeds));
    try testing.expectEqual(@as(usize, canvas.count()), tally(canvas, WHITE));

    try testing.expectEqual(Spread.done, canvas.flood(-1, 5, RED, &seeds));
    try testing.expectEqual(@as(usize, 0), tally(canvas, RED));
}

test "a fill with no room for its runs says how far it got" {
    var small = Small{};
    const canvas = small.canvas();
    var none: [0]Seed = undefined;
    try testing.expectEqual(Spread.ran_out, canvas.flood(5, 5, RED, &none));

    // One run's worth of room, on a canvas that needs more than one.
    var one: [1]Seed = undefined;
    try testing.expectEqual(Spread.ran_out, canvas.flood(5, 5, RED, &one));
    const reached = tally(canvas, RED);
    try testing.expect(reached > 0 and reached < canvas.count());
}

// ---------------------------------------------------------------------------
// Fuzzing: marks made at random
// ---------------------------------------------------------------------------

/// Every tool, pointed anywhere, on a canvas whose every pixel must be either
/// the colour it started as or the one colour the marks are made in.
fn drawOneCanvas(from: Choices) anyerror!void {
    var pixels: [32 * 24]Colour = @splat(WHITE);
    const canvas = Canvas.of(&pixels, 32, 24);
    var seeds: [128]Seed = undefined;

    const Tool = enum { dot, line, box, solid_box, ellipse, solid_ellipse, flood, clear };

    for (0..from.upTo(40)) |_| {
        // Around the canvas rather than anywhere at all: the cases worth
        // trying are the ones that cross an edge.
        const x: i32 = @as(i32, @intCast(from.below(96))) - 32;
        const y: i32 = @as(i32, @intCast(from.below(88))) - 32;
        const to_x: i32 = @as(i32, @intCast(from.below(96))) - 32;
        const to_y: i32 = @as(i32, @intCast(from.below(88))) - 32;
        const size: u8 = from.upTo(5);

        switch (from.one(Tool)) {
            .dot => canvas.dot(x, y, size, BLACK),
            .line => canvas.line(x, y, to_x, to_y, size, BLACK),
            .box => canvas.box(x, y, to_x, to_y, size, BLACK, .outline),
            .solid_box => canvas.box(x, y, to_x, to_y, size, BLACK, .solid),
            .ellipse => canvas.ellipse(x, y, to_x, to_y, size, BLACK, .outline),
            .solid_ellipse => canvas.ellipse(x, y, to_x, to_y, size, BLACK, .solid),
            .flood => _ = canvas.flood(x, y, BLACK, &seeds),
            .clear => canvas.clear(WHITE),
        }

        for (canvas.pixels) |pixel| {
            if (!same(pixel, WHITE) and !same(pixel, BLACK)) {
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "fuzz: every mark lands on the canvas and nowhere else" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            return drawOneCanvas(.{ .fuzzer = smith });
        }
    };
    try std.testing.fuzz({}, Target.one, .{});
}

test "marks made at random" {
    try fuzzing.seeded(drawOneCanvas, 0xDA_A17, 500);
}
