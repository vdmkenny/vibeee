//! Console font description.
//!
//! A font is a dense bitmap indexed by slot, plus its metrics. Everything that
//! draws text works through this, so swapping a font — or shipping several
//! sizes and choosing at boot — needs no change anywhere else.

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
    /// Bytes per glyph row. Not width/8 — a 12-pixel row occupies two bytes.
    row_bytes: usize,
    bitmap: []const u8,

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

    /// Substitute for a code point the font lacks. Better a visible marker than
    /// a blank, which reads as a bug in the program producing the text.
    pub fn fallback(self: *const Font) []const u8 {
        return self.glyph('?') orelse self.bitmap[0..self.height * self.row_bytes];
    }
};
