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

/// Code points beyond Latin-1 that a text console genuinely needs: the block
/// elements, used by the panic screen to draw a QR code two module-rows to a
/// character cell.
pub const BLOCK_FIRST: u21 = 0x2580;
pub const BLOCK_LAST: u21 = 0x259F;
const LATIN_SLOTS: usize = 0x100;

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

    /// Bitmap rows for a code point, or null if the font does not carry it.
    pub fn glyph(self: *const Font, code: u21) ?[]const u8 {
        const slot = self.slotFor(code) orelse return null;
        const size = self.height * self.row_bytes;
        const start = slot * size;
        if (start + size > self.bitmap.len) return null;
        return self.bitmap[start..][0..size];
    }

    fn slotFor(self: *const Font, code: u21) ?usize {
        _ = self;
        if (code < LATIN_SLOTS) return @intCast(code);
        if (code >= BLOCK_FIRST and code <= BLOCK_LAST) {
            return LATIN_SLOTS + @as(usize, code - BLOCK_FIRST);
        }
        return null;
    }

    /// How far the pen moves after drawing `code`.
    pub fn advance(self: *const Font, code: u21) usize {
        const table = self.advances orelse return self.width;
        const slot = self.slotFor(code) orelse return self.width;
        if (slot >= table.len) return self.width;
        return table[slot];
    }

    /// Width of a string in pixels.
    pub fn measure(self: *const Font, text: []const u8) usize {
        var total: usize = 0;
        for (text) |c| total += self.advance(c);
        return total;
    }

    /// Substitute for a code point the font lacks. Better a visible marker than
    /// a blank, which reads as a bug in the program producing the text.
    pub fn fallback(self: *const Font) []const u8 {
        return self.glyph('?') orelse self.bitmap[0..self.height * self.row_bytes];
    }
};

/// The faces compiled in, smallest first. Generated from the BDF sources by
/// `zig build fonts`.
pub const spleen_8x16 = @import("fonts/spleen_8x16.zig").desc;
pub const spleen_12x24 = @import("fonts/spleen_12x24.zig").desc;

/// Proportional, for interface text rather than a terminal grid.
/// Ark Pixel by TakWolf, SIL Open Font License 1.1.
pub const ark_ui_12 = @import("fonts/ark_ui_12.zig").desc;
