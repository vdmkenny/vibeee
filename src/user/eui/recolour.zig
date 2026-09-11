//! Colours chosen elsewhere, kept readable here.
//!
//! A page's own colours, a chat's nicknames, a file's highlighting: each was
//! chosen against some ground of its own, usually white, and a theme here may
//! be the other shade. These are the few things every program does with such
//! a colour: bring it onto this theme, and keep words in it readable on the
//! ground they land on. One arithmetic for all of them, so no two programs
//! disagree about what readable means.
//!
//! Everything moves in lightness and keeps its hue. Lightness is the colour's
//! own `lightness`, the weighted sum the rest of the system judges light and
//! dark by.

const std = @import("std");
const rgb = @import("lib").rgb;

const Color = rgb.Colour;
const Shade = rgb.Shade;

const black: Color = .{};
const white = Color.of(255, 255, 255);

/// How far apart in lightness, out of 255, words and their ground have to be
/// to read: a little less than the dim ink of the darkest theme stands from
/// its ground.
pub const CONTRAST = 96;

/// `wanted` as words on `ground`: as it is where it already reads, and
/// otherwise moved toward black on a light ground or white on a dark one, by
/// the least that makes it read.
pub fn legible(wanted: Color, ground: Color) Color {
    const under: i16 = ground.lightness();
    if (@abs(wanted.lightness() - under) >= CONTRAST) return wanted;

    const toward = switch (ground.shade()) {
        .light => black,
        .dark => white,
    };
    // Halved until the least share of the far end that reads is found. The
    // far end itself always reads: black or white is at least 128 from any
    // ground.
    var low: u16 = 0;
    var high: u16 = 255;
    while (low < high) {
        const middle = (low + high) / 2;
        if (@abs(wanted.mix(toward, @intCast(middle)).lightness() - under) >= CONTRAST) high = middle else low = middle + 1;
    }
    return wanted.mix(toward, @intCast(low));
}

/// A colour chosen for a page of shade `from`, as it belongs on a theme whose
/// ground is `theme_ground`. As it is where the two are the same shade.
/// Otherwise it is turned over in lightness, keeping its hue: the page's own
/// end of lightness lands on the theme's ground, the other end on the theme's
/// other end, and everything between in the same order the other way up. So
/// a light page's white box is not a lamp in a dark room, its pale yellow is
/// a dark yellow and its near-black words are near-white, and a dark page on
/// a light theme is turned over the same way.
pub fn adapted(wanted: Color, from: Shade, theme_ground: Color) Color {
    const to = theme_ground.shade();
    if (from == to) return wanted;
    const base: u32 = theme_ground.lightness();
    // How far the colour is from white, which is a light page's own end and
    // a dark page's other one.
    const depth: u32 = 255 - @as(u32, wanted.lightness());
    return withLightness(wanted, @intCast(switch (to) {
        .dark => base + depth * (255 - base) / 255,
        .light => base * depth / 255,
    }));
}

/// `colour` lighter by `by`, or darker by it where it has not the room.
pub fn lighter(colour: Color, by: u8) Color {
    const now = colour.lightness();
    return withLightness(colour, if (255 - now >= by) now + by else now -| by);
}

/// `colour` darker by `by`, or lighter by it where it has not the room.
pub fn darker(colour: Color, by: u8) Color {
    const now = colour.lightness();
    return withLightness(colour, if (now >= by) now - by else now +| by);
}

/// `colour` at `target` lightness, keeping its hue: mixed toward white to be
/// lighter and toward black to be darker, by what moves it that far.
fn withLightness(colour: Color, target: u8) Color {
    const now: u32 = colour.lightness();
    if (target == now) return colour;
    if (target > now) return colour.mix(white, @intCast((target - now) * 255 / (255 - now)));
    return colour.mix(black, @intCast((now - target) * 255 / now));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const dusk = Color.hex(0x363B44);

fn distance(a: Color, b: Color) u16 {
    return @abs(@as(i16, a.lightness()) - b.lightness());
}

test "a colour that already reads is left as it is" {
    try testing.expect(legible(.hex(0x000080), white).eql(.hex(0x000080)));
    try testing.expect(legible(.hex(0xFFFF00), dusk).eql(.hex(0xFFFF00)));
}

test "a pale colour on a light ground is darkened just enough to read" {
    const got = legible(.hex(0xFFFF99), white);
    try testing.expect(distance(got, white) >= CONTRAST);
    // By the least that does, give or take the rounding of a mix.
    try testing.expect(got.lightness() + 4 >= 255 - CONTRAST);
    // And it is still a yellow.
    try testing.expect(got.r == got.g and got.b < got.r);
}

test "a dark colour on a dark ground is lightened, and keeps its hue" {
    const got = legible(.hex(0x000080), dusk);
    try testing.expect(distance(got, dusk) >= CONTRAST);
    try testing.expect(got.b > got.r and got.r == got.g);
}

test "a colour chosen for the theme's own shade stays as it was chosen" {
    try testing.expect(adapted(.hex(0xFFFFCC), .light, .hex(0xE9EAEC)).eql(.hex(0xFFFFCC)));
    try testing.expect(adapted(.hex(0x202122), .light, .hex(0xE9EAEC)).eql(.hex(0x202122)));
    try testing.expect(adapted(.hex(0x202122), .dark, dusk).eql(.hex(0x202122)));
}

test "a light page's colours on a dark theme are turned over in lightness and keep their hue" {
    // White is the theme's own ground, give or take a step.
    try testing.expect(distance(adapted(white, .light, dusk), dusk) <= 2);
    // Near-black words are near-white ones.
    try testing.expect(adapted(.hex(0x202122), .light, dusk).lightness() > 200);
    // A pale yellow is a dark yellow.
    const pale = adapted(.hex(0xFFFFCC), .light, dusk);
    try testing.expect(pale.r > pale.b and pale.lightness() < 96);
    // And what was lighter than something is darker than it now.
    try testing.expect(adapted(.hex(0xCCCCCC), .light, dusk).lightness() < adapted(.hex(0x666666), .light, dusk).lightness());
}

test "a dark page's colours on a light theme are turned over the other way" {
    const paper = Color.hex(0xF5F6F7);
    // Black is the theme's own ground, give or take a step.
    try testing.expect(distance(adapted(black, .dark, paper), paper) <= 2);
    // Near-white words are near-black ones.
    try testing.expect(adapted(.hex(0xE0E0E0), .dark, paper).lightness() < 40);
    // A dark blue is a pale blue.
    const navy = adapted(.hex(0x000080), .dark, paper);
    try testing.expect(navy.b > navy.r and navy.lightness() > 200);
    // And what was lighter than something is darker than it now.
    try testing.expect(adapted(.hex(0xCCCCCC), .dark, paper).lightness() < adapted(.hex(0x666666), .dark, paper).lightness());
}

test "a step lighter or darker turns back where there is no room" {
    const grey = Color.hex(0x808080);
    try testing.expect(distance(lighter(grey, 14), grey) >= 13);
    try testing.expect(distance(darker(grey, 14), grey) >= 13);
    try testing.expect(lighter(white, 14).lightness() < 255);
    try testing.expect(darker(black, 14).lightness() > 0);
}
