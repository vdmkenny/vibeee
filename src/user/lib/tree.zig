//! Drawing a thing that branches.
//!
//! A directory and everything under it, a bus and everything plugged into
//! it: different subjects, one picture. The rails and the stems are here
//! so the picture is the same in both, and so the next thing with a shape
//! draws it without inventing a third set of characters.

const font = @import("lib").font;
const out = @import("out.zig");

/// One entry's place among its siblings, which is the whole of what
/// decides how it is drawn.
pub const Rung = enum {
    /// Something else follows at this level.
    more,
    /// Nothing does.
    last,

    /// Drawn beside the entry's own name.
    pub fn stem(self: Rung) []const u8 {
        return switch (self) {
            .more => "\u{251C}\u{2500}\u{2500} ",
            .last => "\u{2514}\u{2500}\u{2500} ",
        };
    }

    /// Drawn beside everything nested below it: a rail while there is
    /// still something further down to reach, blank once there is not.
    pub fn under(self: Rung) []const u8 {
        return switch (self) {
            .more => "\u{2502}   ",
            .last => "    ",
        };
    }

    pub fn of(index: usize, count: usize) Rung {
        return if (index + 1 == count) .last else .more;
    }
};

/// How wide one level of nesting is, so a caller padding a column can
/// tell how much of it a rail has already taken.
pub const WIDTH = 4;

/// The rails above a row, then its own stem.
///
/// `rails` holds one rung per level already entered; `rung` is this row's.
/// Every drawing of a branching thing does exactly this before it prints
/// the name.
pub fn lead(rails: []const Rung, rung: Rung) void {
    for (rails) |rail| out.text(rail.under());
    out.text(rung.stem());
}

comptime {
    // The rails are drawn with the box-drawing characters the font
    // carries, which is what keeps them one cell wide.
    _ = font.glyphs.rule_h;
    _ = font.glyphs.rule_v;
}
