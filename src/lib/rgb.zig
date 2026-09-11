//! A colour.
//!
//! The shape the panel actually takes: eight bits a channel in one word, with
//! the top byte unused, which is what a surface's pixels are and what the
//! framebuffer holds. So a colour and a pixel are one value, and a channel is
//! a field rather than something shifted out at each use.
//!
//! Written as `#rrggbb`, which is the one spelling everybody already knows.
//!
//! Whether anybody chose a colour is not a colour: that is `?Colour`, so
//! "the theme's own" and "black" cannot be confused for each other.
//!
//! Pure, so it is host-tested rather than judged by looking at a wall.

const std = @import("std");
const str = @import("str.zig");

/// Light or dark: which end of lightness a colour is nearer.
pub const Shade = enum { light, dark };

pub const Colour = packed struct(u32) {
    b: u8 = 0,
    g: u8 = 0,
    r: u8 = 0,
    /// The byte the panel ignores. Present so the whole thing is one word:
    /// XRGB8888 is the format the display reports and the surfaces are in.
    _unused: u8 = 0,

    pub const accepts = "#rrggbb; unset takes the theme's own";

    pub fn of(r: u8, g: u8, b: u8) Colour {
        return .{ .r = r, .g = g, .b = b };
    }

    /// A colour written the way a person writes one down, for the tables that
    /// are nothing but colours: `rgb.hex(0x2F6FE0)`.
    pub fn hex(value: u24) Colour {
        return @bitCast(@as(u32, value));
    }

    /// The word the hardware takes, for the few places that need one: a
    /// message field, a mask, a comparison.
    pub fn word(self: Colour) u32 {
        return @bitCast(self);
    }

    pub fn eql(self: Colour, other: Colour) bool {
        return self.word() == other.word();
    }

    /// How light this reads, nought to two hundred and fifty-five.
    ///
    /// The eye is far more sensitive to green than to blue, so a plain
    /// average calls a saturated blue as light as a mid grey. These are the
    /// usual weights, in eighths, which is close enough at this depth and
    /// needs no division.
    pub fn lightness(self: Colour) u8 {
        const weighted = @as(u32, self.r) * 2 + @as(u32, self.g) * 5 + self.b;
        return @intCast(weighted / 8);
    }

    /// Which end of lightness it is nearer: whether words go dark or light
    /// on it, and what makes a theme or a page a light or a dark one.
    pub fn shade(self: Colour) Shade {
        return if (self.lightness() >= 128) .light else .dark;
    }

    /// This colour with `share` 255ths of `other` in it: itself at nought and
    /// `other` at 255. What a see-through pixel over a ground comes to, and
    /// what moving a colour toward white or black is.
    pub fn mix(self: Colour, other: Colour, share: u8) Colour {
        return of(mixed(self.r, other.r, share), mixed(self.g, other.g, share), mixed(self.b, other.b, share));
    }

    /// Anything that is not six hex digits is refused rather than repaired: a
    /// wall quietly painted a colour nobody asked for is worse than a setting
    /// that did not take.
    pub fn parse(text: []const u8) ?Colour {
        var trimmed = str.trim(text);
        if (trimmed.len != 0 and trimmed[0] == '#') trimmed = trimmed[1..];
        if (trimmed.len != 6) return null;

        var out: [3]u8 = undefined;
        for (&out, 0..) |*channel, i| {
            const high = std.fmt.charToDigit(trimmed[i * 2], 16) catch return null;
            const low = std.fmt.charToDigit(trimmed[i * 2 + 1], 16) catch return null;
            channel.* = (high << 4) | low;
        }
        return of(out[0], out[1], out[2]);
    }

    pub fn spell(self: Colour, into: *str.Builder) void {
        into.print("#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b });
    }
};

/// One channel of a mix, rounded to the nearest.
fn mixed(own: u8, other: u8, share: u8) u8 {
    return @intCast((@as(u16, other) * share + @as(u16, own) * (255 - share) + 127) / 255);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a colour is three channels, and the word is what the panel takes" {
    const slate = Colour.parse("#2b3138") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 0x2b), slate.r);
    try testing.expectEqual(@as(u8, 0x31), slate.g);
    try testing.expectEqual(@as(u8, 0x38), slate.b);
    try testing.expectEqual(@as(u32, 0x2B3138), slate.word());

    // Which is the same value written the way a table writes it.
    try testing.expect(slate.eql(Colour.hex(0x2B3138)));
}

test "the hash is optional and the digits are not" {
    try testing.expect(Colour.parse("2b3138").?.eql(Colour.parse("#2b3138").?));
    try testing.expect(Colour.parse("#2B3138").?.eql(Colour.parse("#2b3138").?));

    for ([_][]const u8{ "#2b313", "#2b31388", "#2b313g", "blue", "#", "" }) |bad| {
        try testing.expectEqual(@as(?Colour, null), Colour.parse(bad));
    }
}

test "a colour reads back as what it was written as" {
    var buf: [8]u8 = undefined;
    for ([_][]const u8{ "#000000", "#2b3138", "#ffffff", "#0a0b0c" }) |text| {
        const colour = Colour.parse(text).?;
        var built = str.Builder{ .buf = &buf };
        colour.spell(&built);
        try testing.expectEqualStrings(text, built.done());
    }
}

test "lightness weighs green heaviest, as the eye does" {
    const green = Colour.hex(0x00FF00);
    const blue = Colour.hex(0x0000FF);
    const red = Colour.hex(0xFF0000);

    try testing.expect(green.lightness() > red.lightness());
    try testing.expect(red.lightness() > blue.lightness());

    try testing.expectEqual(@as(u8, 0), Colour.hex(0x000000).lightness());
    try testing.expectEqual(@as(u8, 255), Colour.hex(0xFFFFFF).lightness());
}

test "a colour is light or dark by the end of lightness it is nearer" {
    try std.testing.expectEqual(Shade.light, Colour.hex(0xFFFFFF).shade());
    try std.testing.expectEqual(Shade.light, Colour.hex(0xE9EAEC).shade());
    try std.testing.expectEqual(Shade.dark, Colour.hex(0x2A2E35).shade());
    try std.testing.expectEqual(Shade.dark, Colour.hex(0x000000).shade());
}

test "a mix runs from the colour to the other, rounding to the nearest" {
    const red = Colour.hex(0xFF0000);
    const blue = Colour.hex(0x0000FF);
    try testing.expect(red.mix(blue, 0).eql(red));
    try testing.expect(red.mix(blue, 255).eql(blue));
    try testing.expect(red.mix(blue, 128).eql(Colour.hex(0x7F0080)));
}
