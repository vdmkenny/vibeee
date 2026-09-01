//! Bitmap font description.
//!
//! A font is a dense bitmap indexed by slot, plus its metrics. Everything that
//! draws text works through this, so swapping a font, or shipping several
//! sizes and choosing at boot, needs no change anywhere else.
//!
//! In `lib/` because both sides draw text: the kernel console renders the boot
//! log and the panic screen, and the GUI toolkit renders everything else. One
//! copy of the glyphs, one place that knows how a row of them is packed.

const std = @import("std");

/// The code points a font is subset to, and the order their slots run in.
///
/// Shared with `mkfont`, which builds the tables, so the generator and the
/// renderer cannot disagree about which slot holds which character. A dense
/// array indexed by slot makes lookup one index rather than a search; ranges
/// rather than all of Unicode keeps a font at ten kilobytes instead of
/// megabytes.
pub const Range = struct {
    first: u21,
    last: u21,

    pub fn count(self: Range) usize {
        return self.last - self.first + 1;
    }
};

pub const ranges = [_]Range{
    // Latin-1: everything a Western text console needs.
    .{ .first = 0x0000, .last = 0x00FF },
    // General punctuation: the ellipsis, bullets and real dashes, which are
    // the difference between typeset text and a terminal transcript.
    .{ .first = 0x2010, .last = 0x203A },
    // Arrows, for menus, scrollbars and anything that points.
    .{ .first = 0x2190, .last = 0x21BB },
    // Box drawing, which the terminal's DEC graphics mode maps onto and which
    // draws a frame more cheaply than four fills.
    .{ .first = 0x2500, .last = 0x257F },
    // Block elements, used by the panic screen's QR renderer.
    .{ .first = 0x2580, .last = 0x259F },
    // Geometric shapes: the triangles, squares and circles that make a
    // dropdown marker or a radio button without a bitmap.
    .{ .first = 0x25A0, .last = 0x25CF },
};

/// Total slots, so both sides size the same table.
pub const SLOTS = blk: {
    var total: usize = 0;
    for (ranges) |r| total += r.count();
    break :blk total;
};

/// Where a code point's glyph lives, or null if it is outside the subset.
pub fn slotFor(code: u21) ?usize {
    var base: usize = 0;
    for (ranges) |r| {
        if (code >= r.first and code <= r.last) return base + (code - r.first);
        base += r.count();
    }
    return null;
}

/// Characters the interface draws by name rather than by number, so a call
/// site reads as what it means and a font without one can be substituted in
/// one place.
pub const glyphs = struct {
    pub const ellipsis: u21 = 0x2026;
    pub const bullet: u21 = 0x2022;
    pub const arrow_left: u21 = 0x2190;
    pub const arrow_right: u21 = 0x2192;
    pub const triangle_down: u21 = 0x25BC;
    pub const triangle_right: u21 = 0x25B6;
    pub const square: u21 = 0x25A0;
    pub const square_hollow: u21 = 0x25A1;
    pub const circle: u21 = 0x25CF;
    /// Box drawing, for rules and frames.
    pub const rule_h: u21 = 0x2500;
    pub const rule_v: u21 = 0x2502;
};

/// The rows of a cell a glyph occupies.
pub const Band = struct {
    top: usize,
    bottom: usize,

    /// Twice the middle, so half a row stays a whole number.
    pub fn twiceMiddle(self: Band) usize {
        return self.top + self.bottom;
    }
};

pub const Font = struct {
    name: []const u8,
    width: usize,
    height: usize,
    /// Bytes per glyph row. Not width/8, a 12-pixel row occupies two bytes.
    row_bytes: usize,
    /// Rows above the baseline. Text is positioned by its top edge everywhere
    /// here, so this matters only when mixing faces of different heights.
    ascent: usize = 0,
    bitmap: []const u8,
    /// Advance width per slot for a proportional face, or null for a
    /// monospaced one where every glyph advances by `width`. Text layout goes
    /// through `advance` so a caller never has to know which it has.
    advances: ?[]const u8 = null,

    pub fn isProportional(self: *const Font) bool {
        return self.advances != null;
    }

    /// The rows a glyph actually inks, top and bottom, or null for one that
    /// is blank or absent.
    ///
    /// What a face's numbers do not say: `height` counts the whole cell and
    /// `ascent` says where the baseline is, but neither says where the body
    /// of a letter sits between them. Anything placing a picture beside a
    /// word needs that, and measuring the face is more honest than a constant
    /// somebody read off a screenshot.
    pub fn inkBand(self: *const Font, code: u21) ?Band {
        const rows = self.glyph(code) orelse return null;

        var top: ?usize = null;
        var bottom: usize = 0;
        for (0..self.height) |y| {
            var inked = false;
            for (0..self.row_bytes) |byte| {
                if (rows[y * self.row_bytes + byte] != 0) inked = true;
            }
            if (!inked) continue;
            if (top == null) top = y;
            bottom = y;
        }

        return .{ .top = top orelse return null, .bottom = bottom };
    }

    /// Bitmap rows for a code point, or null if the font does not carry it.
    pub fn glyph(self: *const Font, code: u21) ?[]const u8 {
        const slot = self.slotOf(code) orelse return null;
        const size = self.height * self.row_bytes;
        const start = slot * size;
        if (start + size > self.bitmap.len) return null;
        return self.bitmap[start..][0..size];
    }

    fn slotOf(self: *const Font, code: u21) ?usize {
        _ = self;
        return slotFor(code);
    }

    /// How far the pen moves after drawing `code`.
    pub fn advance(self: *const Font, code: u21) usize {
        const table = self.advances orelse return self.width;
        const slot = self.slotOf(code) orelse return self.width;
        if (slot >= table.len) return self.width;

        // A slot the face never filled advances by the face's own width. Zero
        // would draw the next character on top of this one, and a subset that
        // omits a codepoint should cost a blank, not a collision.
        const value = table[slot];
        return if (value == 0) self.width else value;
    }

    /// Width of a string in pixels.
    ///
    /// By character, not by byte: a three-byte box-drawing rule advances once,
    /// and counting its bytes made every measurement of anything above Latin-1
    /// three times too wide.
    pub fn measure(self: *const Font, text: []const u8) usize {
        var total: usize = 0;
        var it = codepoints(text);
        while (it.next()) |cp| total += self.advance(cp);
        return total;
    }

    /// Substitute for a code point the font lacks. Better a visible marker than
    /// a blank, which reads as a bug in the program producing the text.
    pub fn fallback(self: *const Font) []const u8 {
        return self.glyph('?') orelse self.bitmap[0 .. self.height * self.row_bytes];
    }
};

/// The faces compiled in, smallest first. Generated from the BDF sources by
/// `zig build fonts`.
pub const spleen_8x16 = @import("fonts/spleen_8x16.zig").desc;
pub const spleen_12x24 = @import("fonts/spleen_12x24.zig").desc;

/// Proportional, for interface text rather than a terminal grid.
/// Ark Pixel by TakWolf, SIL Open Font License 1.1.
pub const ark_ui_12 = @import("fonts/ark_ui_12.zig").desc;
pub const ark_mono_12 = @import("fonts/ark_mono_12.zig").desc;

/// Walk a string as characters rather than bytes.
///
/// Strings here are UTF-8, and the font carries box drawing, arrows and shapes
/// well above Latin-1. Iterating bytes drew a three-byte character as three
/// wrong ones, which is what a box-drawing rule looked like before this.
///
/// Malformed input yields U+FFFD and advances one byte, so a bad string
/// renders as visible nonsense rather than desynchronising everything after
/// it.
pub const Codepoints = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn next(self: *Codepoints) ?u21 {
        if (self.pos >= self.bytes.len) return null;

        const first = self.bytes[self.pos];
        const length = std.unicode.utf8ByteSequenceLength(first) catch {
            self.pos += 1;
            return 0xFFFD;
        };

        if (self.pos + length > self.bytes.len) {
            self.pos = self.bytes.len;
            return 0xFFFD;
        }

        const cp = std.unicode.utf8Decode(self.bytes[self.pos..][0..length]) catch {
            self.pos += 1;
            return 0xFFFD;
        };
        self.pos += length;
        return cp;
    }
};

pub fn codepoints(bytes: []const u8) Codepoints {
    return .{ .bytes = bytes };
}
