//! Colour, as the escape sequences every terminal already understands.
//!
//! A program does not know what is on the other end of its output: the
//! console, a terminal emulator, or a file. Saying what it wants in the
//! sequence they all speak means the same program is right in all three
//! cases, and it costs the one place that cannot use colour, a file, nothing
//! but a few bytes nobody reads.
//!
//! Here rather than in each tool because a hand-written escape is a byte
//! sequence with no name, and the second one written is already a place for
//! them to disagree.

const out = @import("out.zig");

/// The sixteen colours a text console has, in the order the escape sequences
/// number them, which is not the order the hardware palette does.
pub const Colour = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,

    /// Written before the colour to reach the bright half of the palette.
    pub const bright_offset = 60;
};

/// Start writing in `c`. Ends at the next `plain`.
pub fn on(c: Colour) void {
    sequence(30 + @intFromEnum(c));
}

/// The bright half, which on a console this dim is what most text wants.
pub fn bright(c: Colour) void {
    sequence(30 + Colour.bright_offset + @intFromEnum(c));
}

/// Swap foreground and background, which is how a status line is set apart
/// without needing a colour of its own.
pub fn reverse() void {
    sequence(7);
}

/// Back to the default, which every other sequence is measured against.
pub fn plain() void {
    sequence(0);
}

/// Write one rendition parameter.
fn sequence(param: u8) void {
    out.byte(0x1B);
    out.byte('[');
    out.decimal(param);
    out.byte('m');
}
