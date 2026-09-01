//! A colour, as a setting spells it.
//!
//! Three channels and whether anybody has chosen them. Unset is a state
//! rather than a colour, because "the theme's own" and "black" are different
//! answers and a file that cannot tell them apart cannot say the first one.
//!
//! Written as `#rrggbb`, which is the one spelling everybody already knows.
//!
//! Pure, so it is host-tested rather than judged by looking at a wall.

const std = @import("std");
const str = @import("str.zig");

pub const Colour = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    /// Whether these three mean anything. A caller with an unset colour uses
    /// whatever it would have used before the setting existed.
    set: bool = false,

    pub const accepts = "#rrggbb; unset takes the theme's own";

    pub fn of(r: u8, g: u8, b: u8) Colour {
        return .{ .r = r, .g = g, .b = b, .set = true };
    }

    /// The colour as the surface takes it: eight bits a channel, red highest.
    pub fn packed24(self: Colour) u32 {
        return (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | self.b;
    }

    pub fn ofPacked(value: u32) Colour {
        return of(
            @truncate(value >> 16),
            @truncate(value >> 8),
            @truncate(value),
        );
    }

    /// This colour, or the one to fall back to when nobody has chosen.
    pub fn orElse(self: Colour, fallback: u32) u32 {
        return if (self.set) self.packed24() else fallback;
    }

    pub fn eql(self: Colour, other: Colour) bool {
        if (self.set != other.set) return false;
        if (!self.set) return true;
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }

    /// Nothing written is nobody having chosen. Anything that is not six hex
    /// digits is refused rather than repaired: a wall quietly painted a
    /// colour nobody asked for is worse than a setting that did not take.
    pub fn parse(text: []const u8) ?Colour {
        var trimmed = str.trim(text);
        if (trimmed.len == 0) return Colour{};
        if (trimmed[0] == '#') trimmed = trimmed[1..];
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
        if (!self.set) return;
        into.byte('#');
        for ([_]u8{ self.r, self.g, self.b }) |channel| {
            into.byte(std.fmt.digitToChar(channel >> 4, .lower));
            into.byte(std.fmt.digitToChar(channel & 0xF, .lower));
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a colour is three channels and whether anybody chose them" {
    const slate = Colour.parse("#2b3138") orelse return error.TestUnexpectedResult;
    try testing.expect(slate.set);
    try testing.expectEqual(@as(u8, 0x2b), slate.r);
    try testing.expectEqual(@as(u8, 0x31), slate.g);
    try testing.expectEqual(@as(u8, 0x38), slate.b);
    try testing.expectEqual(@as(u32, 0x2B3138), slate.packed24());
}

test "unset is a state, not a colour" {
    const unset = Colour.parse("") orelse return error.TestUnexpectedResult;
    try testing.expect(!unset.set);
    // Which is what makes it different from black.
    try testing.expect(!unset.eql(Colour.of(0, 0, 0)));
    try testing.expectEqual(@as(u32, 0x5C6670), unset.orElse(0x5C6670));
    try testing.expectEqual(@as(u32, 0x2B3138), Colour.ofPacked(0x2B3138).orElse(0x5C6670));
}

test "the hash is optional and the digits are not" {
    try testing.expect(Colour.parse("2b3138").?.eql(Colour.parse("#2b3138").?));
    try testing.expect(Colour.parse("#2B3138").?.eql(Colour.parse("#2b3138").?));

    for ([_][]const u8{ "#2b313", "#2b31388", "#2b313g", "blue", "#" }) |bad| {
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

    // Unset writes nothing, which is how the file says nobody chose.
    var built = str.Builder{ .buf = &buf };
    (Colour{}).spell(&built);
    try testing.expectEqualStrings("", built.done());
}

test "packing and unpacking are the same colour" {
    for ([_]u32{ 0x000000, 0x2B3138, 0xFFFFFF, 0x0A0B0C }) |value| {
        try testing.expectEqual(value, Colour.ofPacked(value).packed24());
    }
}
