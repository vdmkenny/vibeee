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

const fontlib = @import("lib").font;
const theme = @import("theme.zig");

pub const Color = theme.Color;

/// The interface face. Proportional on purpose: a fixed grid is what a
/// terminal needs and what a button label should not look like.
pub const Font = fontlib.Font;

/// Interface text: proportional, because everything but a terminal reads
/// better that way at this size.
pub const ui_font: *const Font = &fontlib.ark_ui_12;

/// Where columns have to line up. The console's face, so a terminal window and
/// the console it replaces show the same shapes.
pub const mono_font: *const Font = &fontlib.spleen_8x16;

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
            // A row at a time: the inner loop is a straight run of stores with
            // no clipping test, which is what makes filling the desktop
            // affordable on a 630 MHz core.
            const row = self.pixels + @as(usize, @intCast(y * self.stride + r.x));
            var i: usize = 0;
            while (i < @as(usize, @intCast(r.w))) : (i += 1) row[i] = color;
        }
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
        const bits = face.glyph(code) orelse face.fallback();

        var row: i32 = 0;
        while (row < @as(i32, @intCast(face.height))) : (row += 1) {
            const start = @as(usize, @intCast(row)) * face.row_bytes;
            var col: i32 = 0;
            while (col < @as(i32, @intCast(face.width))) : (col += 1) {
                // Rows are big-endian across bytes: bit 7 of the first byte is
                // the leftmost pixel.
                const byte = bits[start + @as(usize, @intCast(col)) / 8];
                if (byte >> @intCast(7 - @as(u3, @intCast(@mod(col, 8)))) & 1 == 0) continue;
                self.set(x + col, y + row, color);
            }
        }
    }

    pub fn text(self: Surface, x: i32, y: i32, message: []const u8, color: Color) void {
        self.textIn(ui_font, x, y, message, color);
    }

    pub fn textIn(self: Surface, face: *const Font, x: i32, y: i32, message: []const u8, color: Color) void {
        var pen = x;
        var it = codepoints(message);
        while (it.next()) |cp| {
            self.glyphIn(face, pen, y, cp, color);
            // Per glyph, not per cell: the interface face is proportional, and
            // advancing by the cell width would space it like a terminal.
            pen += @intCast(face.advance(cp));
        }
    }

    /// Width of `message` in pixels, for centring and for sizing a control to
    /// its label.
    pub fn textWidth(message: []const u8) i32 {
        return @intCast(ui_font.measure(message));
    }

    pub fn textHeight() i32 {
        return @intCast(ui_font.height);
    }

    pub fn textCentred(self: Surface, area: Rect, message: []const u8, color: Color) void {
        const x = area.x + @divTrunc(area.w - textWidth(message), 2);
        const y = area.y + @divTrunc(area.h - textHeight(), 2);
        self.text(x, y, message, color);
    }
};
