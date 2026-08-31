//! Colours a person picks by name.
//!
//! Two lists: the highlight the interface is drawn with, and the pointer.
//! Named rather than given as three channels, because a colour picked from a
//! list is a colour that still reads against the rest of the theme: the
//! highlights here are all pitched at the same lightness as the blue they
//! replace, so text on them stays legible whichever is chosen.
//!
//! Here in `lib` rather than in the toolkit, because the settings schema
//! names these and the schema cannot reach the toolkit.

const std = @import("std");

/// What the interface highlights with: selected rows, the focused window's
/// edge, a slider's fill.
pub const Accent = enum {
    blue,
    indigo,
    violet,
    magenta,
    red,
    orange,
    amber,
    green,
    teal,
    cyan,

    pub const accepts = "blue, indigo, violet, magenta, red, orange, amber, green, teal or cyan";

    /// Every one of these is around forty per cent lightness, which is what
    /// keeps white text on top of it readable: a yellow at its own natural
    /// lightness would be a highlight nobody could read a label on.
    pub fn rgb(self: Accent) u32 {
        return switch (self) {
            .blue => 0x2F6FE0,
            .indigo => 0x5A5FD8,
            .violet => 0x8A4FD0,
            .magenta => 0xB8409A,
            .red => 0xC8443C,
            .orange => 0xC06018,
            .amber => 0xA07A10,
            .green => 0x2F8C46,
            .teal => 0x0F8A80,
            .cyan => 0x1C7FB8,
        };
    }
};

/// What the pointer is drawn in. Fewer, and plainer: a pointer is a shape you
/// have to find on any background, so the useful choices are the ones with the
/// most contrast against everything else.
pub const Pointer = enum {
    white,
    black,
    red,
    green,
    blue,
    yellow,

    pub const accepts = "white, black, red, green, blue or yellow";

    pub fn rgb(self: Pointer) u32 {
        return switch (self) {
            .white => 0xFFFFFF,
            .black => 0x000000,
            .red => 0xE03030,
            .green => 0x30C050,
            .blue => 0x3070E0,
            .yellow => 0xF0D030,
        };
    }

    /// The outline drawn around it, which is what makes a pointer visible on
    /// a background of its own colour.
    pub fn outline(self: Pointer) u32 {
        return switch (self) {
            .black => 0xFFFFFF,
            else => 0x000000,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "every highlight is dark enough to carry white text" {
    // Rough perceived lightness, the usual weighting. Above about sixty per
    // cent, white text on it stops being readable.
    for (std.enums.values(Accent)) |accent| {
        const value = accent.rgb();
        const r: u32 = (value >> 16) & 0xFF;
        const g: u32 = (value >> 8) & 0xFF;
        const b: u32 = value & 0xFF;
        const lightness = (r * 299 + g * 587 + b * 114) / 1000;
        try testing.expect(lightness < 155);
    }
}

test "the highlights are all in the same register" {
    // No two more than a third apart in lightness, which is what makes them
    // alternatives rather than a set of unrelated colours.
    var lowest: u32 = 255;
    var highest: u32 = 0;
    for (std.enums.values(Accent)) |accent| {
        const value = accent.rgb();
        const lightness = (((value >> 16) & 0xFF) * 299 + ((value >> 8) & 0xFF) * 587 + (value & 0xFF) * 114) / 1000;
        lowest = @min(lowest, lightness);
        highest = @max(highest, lightness);
    }
    try testing.expect(highest - lowest < 60);
}

test "a pointer is outlined in something it is not" {
    for (std.enums.values(Pointer)) |pointer| {
        try testing.expect(pointer.rgb() != pointer.outline());
    }
}
