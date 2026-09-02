//! Drawing onto a 32-bit surface.
//!
//! The bottom of `libeui`: a surface, a clip rectangle, and the handful of
//! primitives everything else is built from. It knows nothing about windows,
//! events or the compositor, which is what lets the compositor and an
//! application draw with the same code into different memory.
//!
//! XRGB8888 only, and the sixteen-ish colours the panel shows without
//! dithering. The 701's panel is 6-bit plus frame-rate control, so a gradient
//! is a shimmer; flat colour on exact levels is both cheaper and better
//! looking (design/10-gui.md §2).

const std = @import("std");
const fontlib = @import("lib").font;
const icons = @import("icon.zig");
const theme = @import("theme.zig");

pub const Color = theme.Color;

/// The interface face. Proportional on purpose: a fixed grid is what a
/// terminal needs and what a button label should not look like.
pub const Font = fontlib.Font;

/// Interface text: proportional, because everything but a terminal reads
/// better that way at this size.
pub const ui_font: *const Font = &fontlib.ark_ui_12;

/// Where columns have to line up. The interface family's own fixed-advance
/// face, so a shell and a button label speak in one voice; the console keeps
/// Spleen, which was drawn for a framebuffer console and stays there.
pub const mono_font: *const Font = &fontlib.ark_mono_12;

/// Walking a string as characters rather than bytes. Lives in `lib` because
/// the font's own measuring needs it and the kernel's console draws from the
/// same faces.
pub const Codepoints = fontlib.Codepoints;
pub const codepoints = fontlib.codepoints;

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.right() and py >= self.y and py < self.bottom();
    }

    /// The overlap of two rectangles, empty if they do not touch.
    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.right(), other.right());
        const y1 = @min(self.bottom(), other.bottom());
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// The smallest rectangle containing both. Used to merge damage.
    pub fn unite(self: Rect, other: Rect) Rect {
        if (self.isEmpty()) return other;
        if (other.isEmpty()) return self;

        const x0 = @min(self.x, other.x);
        const y0 = @min(self.y, other.y);
        const x1 = @max(self.right(), other.right());
        const y1 = @max(self.bottom(), other.bottom());
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn inset(self: Rect, by: i32) Rect {
        return .{ .x = self.x + by, .y = self.y + by, .w = self.w - 2 * by, .h = self.h - 2 * by };
    }
};

/// How many bytes a surface of this shape occupies, or null for one that
/// cannot exist: nothing wide or tall, a stride shorter than a row, or a size
/// past what a length can say.
///
/// Pure, and the whole of what a compositor checks before it reads a pixel
/// from memory a client described: the shape is the client's word and the
/// segment's size is the kernel's, and this is where the two are compared.
///
/// Thirty-two bits regardless of the host, because that is the width of a
/// segment's size on the machine this runs on, and a check that passed on a
/// wider host and failed on the target would be no check.
pub fn spanBytes(width: u16, height: u16, stride: u16) ?u32 {
    if (width == 0 or height == 0 or stride < width) return null;
    const rows = std.math.mul(u32, stride, height) catch return null;
    return std.math.mul(u32, rows, @sizeOf(u32)) catch null;
}

/// Somewhere to draw: pixels, geometry, and the region drawing is confined to.
///
/// The clip travels with the surface rather than being passed to every call,
/// because a widget draws a dozen primitives and every one of them must be
/// confined to the same place. Forgetting once is a widget that paints over
/// its neighbour.
pub const Surface = struct {
    pixels: [*]u32,
    width: i32,
    height: i32,
    /// Pixels per scanline, which is not the width.
    stride: i32,
    clip: Rect,

    pub fn init(pixels: [*]u32, width: i32, height: i32, stride: i32) Surface {
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .stride = stride,
            .clip = .{ .x = 0, .y = 0, .w = width, .h = height },
        };
    }

    /// A view of the same pixels confined to `area`.
    pub fn clipped(self: Surface, area: Rect) Surface {
        var out = self;
        out.clip = self.clip.intersect(area);
        return out;
    }

    pub fn set(self: Surface, x: i32, y: i32, color: Color) void {
        if (!self.clip.contains(x, y)) return;
        self.pixels[@intCast(y * self.stride + x)] = color;
    }

    /// The colour at a point, or black outside the surface. For anything that
    /// has to put back what it drew over, which without a hardware cursor
    /// plane is how a pointer moves without the screen being redrawn.
    pub fn get(self: Surface, x: i32, y: i32) Color {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return 0;
        return self.pixels[@intCast(y * self.stride + x)];
    }

    pub fn fill(self: Surface, area: Rect, color: Color) void {
        const r = self.clip.intersect(area);
        if (r.isEmpty()) return;

        var y = r.y;
        while (y < r.bottom()) : (y += 1) {
            // A row at a time, as one splat: no clipping test inside, and the
            // compiler is free to widen the stores, which on a
            // write-combining framebuffer is what fills a line in one burst.
            const row = self.pixels + @as(usize, @intCast(y * self.stride + r.x));
            @memset(row[0..@intCast(r.w)], color);
        }
    }

    /// Copy a rectangle of `source` onto this surface, `at` being where the
    /// source's origin lands, confined to `limit` and this surface's clip.
    ///
    /// The compositor's whole job, so it is the one path that must not be
    /// written per pixel: every bound is settled before the loops, and each
    /// row is one copy the compiler may widen. On a write-combining
    /// framebuffer that is the difference between a repaint and a wipe you
    /// can watch.
    pub fn copyFrom(self: Surface, source: Surface, at_x: i32, at_y: i32, limit: Rect) void {
        const target = copyTarget(self, source, at_x, at_y, limit) orelse return;

        var y = target.y;
        while (y < target.bottom()) : (y += 1) {
            const from = source.pixels + @as(usize, @intCast((y - at_y) * source.stride + (target.x - at_x)));
            const to = self.pixels + @as(usize, @intCast(y * self.stride + target.x));
            @memcpy(to[0..@intCast(target.w)], from[0..@intCast(target.w)]);
        }
    }

    /// Where a copy actually lands: the placement clipped by the limit, this
    /// surface's clip, and what the source actually has. Null when nothing
    /// survives. Settling every bound here is what leaves the loops above
    /// with no branches in them.
    fn copyTarget(self: Surface, source: Surface, at_x: i32, at_y: i32, limit: Rect) ?Rect {
        const placed = Rect{ .x = at_x, .y = at_y, .w = source.width, .h = source.height };
        const target = placed.intersect(limit).intersect(self.clip);
        return if (target.isEmpty()) null else target;
    }

    pub fn frame(self: Surface, area: Rect, color: Color) void {
        self.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, color);
        self.fill(.{ .x = area.x, .y = area.bottom() - 1, .w = area.w, .h = 1 }, color);
        self.fill(.{ .x = area.x, .y = area.y, .w = 1, .h = area.h }, color);
        self.fill(.{ .x = area.right() - 1, .y = area.y, .w = 1, .h = area.h }, color);
    }

    /// A border of `width` pixels drawn *inside* `area`, so a window never
    /// changes size by gaining or losing one.
    pub fn borderInset(self: Surface, area: Rect, width: i32, color: Color) void {
        var i: i32 = 0;
        while (i < width) : (i += 1) self.frame(area.inset(i), color);
    }

    /// Draw one glyph with its top-left at (x, y).
    pub fn glyph(self: Surface, x: i32, y: i32, code: u21, color: Color) void {
        self.glyphIn(ui_font, x, y, code, color);
    }

    /// One glyph from a face of the caller's choosing. What a terminal uses,
    /// since a grid needs the monospaced face and everything else does not.
    pub fn glyphIn(self: Surface, face: *const Font, x: i32, y: i32, code: u21, color: Color) void {
        self.glyphScaled(face, x, y, code, color, theme.textScale());
    }

    fn glyphScaled(self: Surface, face: *const Font, x: i32, y: i32, code: u21, color: Color, scale: i32) void {
        const bits = face.glyph(code) orelse face.fallback();
        self.bitmapAt(x, y, bits, face.width, face.height, face.row_bytes, color, scale);
    }

    /// A named picture, which is a bitmap with a name rather than a code
    /// point and goes through the same expansion a letter does.
    /// A caller's own picture, in the icons' format and at their size.
    pub fn picture(self: Surface, x: i32, y: i32, glyph_bits: icons.Glyph, color: Color) void {
        self.bitmapAt(x, y, glyph_bits, icons.WIDTH, icons.HEIGHT, icons.ROW_BYTES, color, theme.textScale());
    }

    pub fn icon(self: Surface, x: i32, y: i32, which: icons.Icon, color: Color) void {
        self.bitmapAt(x, y, icons.rows(which), icons.WIDTH, icons.HEIGHT, icons.ROW_BYTES, color, theme.textScale());
    }

    /// The same picture, drawn `times` larger. For a mark that stands for the
    /// machine rather than sitting beside a word.
    pub fn iconLarge(self: Surface, x: i32, y: i32, which: icons.Icon, color: Color, times: i32) void {
        self.bitmapAt(x, y, icons.rows(which), icons.WIDTH, icons.HEIGHT, icons.ROW_BYTES, color, theme.textScale() * times);
    }

    pub fn iconLargeSize(times: i32) i32 {
        return iconSize() * times;
    }

    /// How large a picture is drawn, which grows with the letters beside it.
    /// Where a picture goes so it reads as being on the same line as text
    /// drawn at `y`.
    ///
    /// Not the middle of the text's cell. A face leaves room under its
    /// letters for the ones that hang below, so a picture centred on the cell
    /// sits above the letters beside it, and every icon in the system reads
    /// as floating a little.
    ///
    /// Centred on the body of a lowercase letter instead, which is where the
    /// eye puts the line. Measured from the face rather than given as a
    /// number, so a different face or a doubled one still lines up.
    pub fn iconTopFor(y: i32) i32 {
        return y + BODY_MIDDLE * theme.textScale() - @divTrunc(iconSize(), 2);
    }

    /// Half way down the body of a lowercase letter, in rows of the face.
    /// Taken from an `x`, which has neither an ascender nor a descender, and
    /// from an `o` where a face has no `x`.
    const BODY_MIDDLE: i32 = blk: {
        const band = ui_font.inkBand('x') orelse
            fontlib.Band{ .top = 0, .bottom = ui_font.height - 1 };
        break :blk @intCast(@divTrunc(band.twiceMiddle() + 1, 2));
    };

    pub fn iconSize() i32 {
        return @as(i32, @intCast(icons.WIDTH)) * theme.textScale();
    }

    /// One-bit rows expanded onto the surface. The one place a bitmap becomes
    /// pixels, so a letter and an icon cannot disagree about which bit is the
    /// leftmost.
    pub fn bitmap(
        self: Surface,
        x: i32,
        y: i32,
        bits: []const u8,
        width: usize,
        height: usize,
        row_bytes: usize,
        color: Color,
    ) void {
        self.bitmapAt(x, y, bits, width, height, row_bytes, color, 1);
    }

    /// The same, drawn `times` larger in both directions.
    pub fn bitmapAt(
        self: Surface,
        x: i32,
        y: i32,
        bits: []const u8,
        width: usize,
        height: usize,
        row_bytes: usize,
        color: Color,
        times: i32,
    ) void {
        if (times != 1) {
            // A pixel of the face becomes a square of them. Whole numbers
            // only: the face is a bitmap, and anything that is not a whole
            // number of pixels is a blurred letter. The squares go through
            // `fill`, which clips them.
            var row: i32 = 0;
            while (row < @as(i32, @intCast(height))) : (row += 1) {
                const start = @as(usize, @intCast(row)) * row_bytes;
                var col: i32 = 0;
                while (col < @as(i32, @intCast(width))) : (col += 1) {
                    const byte = bits[start + @as(usize, @intCast(col)) / 8];
                    if (byte >> @intCast(7 - @as(u3, @intCast(@mod(col, 8)))) & 1 == 0) continue;
                    self.fill(.{
                        .x = x + col * times,
                        .y = y + row * times,
                        .w = times,
                        .h = times,
                    }, color);
                }
            }
            return;
        }

        // The clip is settled once, outside the loops: a terminal paints
        // thousands of glyphs a scroll, and a bounds test per pixel of each
        // was a measurable share of every repaint.
        const target = self.clip.intersect(.{
            .x = x,
            .y = y,
            .w = @intCast(width),
            .h = @intCast(height),
        });
        if (target.isEmpty()) return;

        var row = target.y;
        while (row < target.bottom()) : (row += 1) {
            const start = @as(usize, @intCast(row - y)) * row_bytes;
            const line = self.pixels + @as(usize, @intCast(row * self.stride));

            var col = target.x;
            while (col < target.right()) : (col += 1) {
                // Rows are big-endian across bytes: bit 7 of the first byte
                // is the leftmost pixel.
                const bit = col - x;
                const byte = bits[start + @as(usize, @intCast(bit)) / 8];
                if (byte >> @intCast(7 - @as(u3, @intCast(@mod(bit, 8)))) & 1 == 0) continue;
                line[@intCast(col)] = color;
            }
        }
    }

    pub fn text(self: Surface, x: i32, y: i32, message: []const u8, color: Color) void {
        self.textIn(ui_font, x, y, message, color);
    }

    pub fn textIn(self: Surface, face: *const Font, x: i32, y: i32, message: []const u8, color: Color) void {
        self.textScaled(face, x, y, message, color, theme.textScale());
    }

    /// The one word a window is about, drawn `times` the size of everything
    /// else. There is one face, so a heading is that face magnified by a
    /// whole number: the alternative is a second font in memory to say one
    /// word slightly larger.
    ///
    /// A multiple of the interface's own size rather than an absolute one,
    /// so a heading stays a heading when the whole interface is scaled up.
    pub fn textLarge(self: Surface, x: i32, y: i32, message: []const u8, color: Color, times: i32) void {
        self.textScaled(ui_font, x, y, message, color, theme.textScale() * times);
    }

    pub fn textLargeWidth(message: []const u8, times: i32) i32 {
        return textWidth(message) * times;
    }

    pub fn textLargeHeight(times: i32) i32 {
        return textHeight() * times;
    }

    fn textScaled(self: Surface, face: *const Font, x: i32, y: i32, message: []const u8, color: Color, scale: i32) void {
        var pen = x;
        var it = codepoints(message);
        while (it.next()) |cp| {
            self.glyphScaled(face, pen, y, cp, color, scale);
            // Per glyph, not per cell: the interface face is proportional, and
            // advancing by the cell width would space it like a terminal. The
            // advance grows with the letters, or they overlap.
            pen += @as(i32, @intCast(face.advance(cp))) * scale;
        }
    }

    /// Width of `message` in pixels, for centring and for sizing a control to
    /// its label.
    /// Measured at the size it will be drawn: every caller that centres a
    /// label or sizes a control to one asks here, so the answer has to be
    /// the answer for the screen rather than for the face.
    pub fn textWidth(message: []const u8) i32 {
        return @as(i32, @intCast(ui_font.measure(message))) * theme.textScale();
    }

    pub fn textHeight() i32 {
        return @as(i32, @intCast(ui_font.height)) * theme.textScale();
    }

    pub fn textCentred(self: Surface, area: Rect, message: []const u8, color: Color) void {
        const x = area.x + @divTrunc(area.w - textWidth(message), 2);
        const y = area.y + @divTrunc(area.h - textHeight(), 2);
        self.text(x, y, message, color);
    }
};

// ---------------------------------------------------------------------------
// Tests
//
// Small in-memory surfaces, checked pixel by pixel. The copy is the
// compositor's whole job, so where a row starts and stops is exactly what
// must not be wrong.
// ---------------------------------------------------------------------------

const testing = @import("std").testing;

const SIDE = 8;

fn flat(pixels: *[SIDE * SIDE]u32, value: u32) Surface {
    @memset(pixels, value);
    return Surface.init(pixels, SIDE, SIDE, SIDE);
}

test "a copy lands where it was placed and nowhere else" {
    var dst_pixels: [SIDE * SIDE]u32 = undefined;
    var src_pixels: [SIDE * SIDE]u32 = undefined;
    const dst = flat(&dst_pixels, 0x111111);
    var src = flat(&src_pixels, 0x999999);
    src.width = 3;
    src.height = 2;

    dst.copyFrom(src, 2, 3, .{ .x = 0, .y = 0, .w = SIDE, .h = SIDE });

    for (0..SIDE) |y| {
        for (0..SIDE) |x| {
            const inside = x >= 2 and x < 5 and y >= 3 and y < 5;
            const want: u32 = if (inside) 0x999999 else 0x111111;
            try testing.expectEqual(want, dst_pixels[y * SIDE + x]);
        }
    }
}

test "the limit and the clip both confine a copy" {
    var dst_pixels: [SIDE * SIDE]u32 = undefined;
    var src_pixels: [SIDE * SIDE]u32 = undefined;
    var dst = flat(&dst_pixels, 0x111111);
    const src = flat(&src_pixels, 0x999999);

    dst.clip = .{ .x = 1, .y = 1, .w = 5, .h = 5 };
    dst.copyFrom(src, 0, 0, .{ .x = 3, .y = 0, .w = SIDE, .h = 4 });

    for (0..SIDE) |y| {
        for (0..SIDE) |x| {
            // Only where the placement, the limit and the clip all agree.
            const inside = x >= 3 and x < 6 and y >= 1 and y < 4;
            const want: u32 = if (inside) 0x999999 else 0x111111;
            try testing.expectEqual(want, dst_pixels[y * SIDE + x]);
        }
    }
}

test "a copy hanging off every edge keeps to the surface" {
    var dst_pixels: [SIDE * SIDE]u32 = undefined;
    var src_pixels: [SIDE * SIDE]u32 = undefined;
    const dst = flat(&dst_pixels, 0x111111);
    const src = flat(&src_pixels, 0x999999);

    // Off the top-left and off the bottom-right: both must clamp, and a
    // negative placement must skip the right amount of the source.
    dst.copyFrom(src, -3, -3, .{ .x = 0, .y = 0, .w = SIDE, .h = SIDE });
    dst.copyFrom(src, 6, 6, .{ .x = 0, .y = 0, .w = SIDE, .h = SIDE });

    try testing.expectEqual(@as(u32, 0x999999), dst_pixels[0]);
    try testing.expectEqual(@as(u32, 0x999999), dst_pixels[4 * SIDE + 4]);
    try testing.expectEqual(@as(u32, 0x111111), dst_pixels[5 * SIDE + 5]);
    try testing.expectEqual(@as(u32, 0x999999), dst_pixels[7 * SIDE + 7]);
}

test "a surface's span is its rows by its stride in words, and only for a real shape" {
    try std.testing.expectEqual(@as(?u32, 800 * 600 * 4), spanBytes(800, 600, 800));
    // A stride wider than the row counts the padding, which the reader will
    // step over and the memory must therefore hold.
    try std.testing.expectEqual(@as(?u32, 1024 * 600 * 4), spanBytes(800, 600, 1024));

    try testing_null(spanBytes(0, 600, 800));
    try testing_null(spanBytes(800, 0, 800));
    // A stride shorter than a row would have rows overlap.
    try testing_null(spanBytes(800, 600, 799));
    // Past what a segment's size can say: four gigabytes, on any host.
    try testing_null(spanBytes(65535, 65535, 65535));
}

fn testing_null(got: ?u32) !void {
    try std.testing.expectEqual(@as(?u32, null), got);
}
