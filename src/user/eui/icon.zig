//! Small pictures, in the one form this system already knows how to draw.
//!
//! A glyph here is a one-bit bitmap and a size, and the surface expands it to
//! pixels a row at a time. An icon is the same thing with a name instead of a
//! code point, so it goes through the same blitter rather than bringing a
//! second one: nothing below draws an icon differently from a letter.
//!
//! Written as pictures rather than as hexadecimal. A row of dots and hashes is
//! something a person can read, edit and see wrong at a glance, and the
//! packing into bits happens at compile time, so the readable form costs
//! nothing at run time.
//!
//! Twelve by twelve, which is the interface face's height: an icon beside a
//! label should be the size of the label, and one that has to be measured
//! against the text every time it moves is one that will drift.

const std = @import("std");

pub const WIDTH: usize = 12;
pub const HEIGHT: usize = 12;
/// Two bytes a row, because twelve pixels do not fit in one.
pub const ROW_BYTES: usize = 2;
const BYTES: usize = HEIGHT * ROW_BYTES;

pub const Icon = enum {
    /// Four ascending bars: signal, and the only thing in the bar that says
    /// whether the radio has anything.
    wifi,
    /// A wired link, for a machine that has a cable in it.
    ethernet,
    speaker,
    /// The same speaker with its waves struck out, because a muted machine
    /// that looks quiet and a quiet machine look identical otherwise.
    muted,
    /// An outline. What is left in it is drawn as a rectangle by whoever
    /// knows the charge, so the picture never has to be redrawn per percent.
    battery,
    terminal,
    document,
    picture,
    folder,
    /// Settings. Sliders rather than a cog: a cog at this size is a blob.
    sliders,
    power,
    /// A tick, for the chosen row of a list that has one.
    check,
};

const art = [_][HEIGHT][]const u8{
    // wifi
    .{
        "............",
        "............",
        ".........##.",
        ".........##.",
        "......##.##.",
        "......##.##.",
        "......##.##.",
        "...##.##.##.",
        "...##.##.##.",
        "##.##.##.##.",
        "##.##.##.##.",
        "............",
    },
    // ethernet
    .{
        "............",
        "...######...",
        "...#....#...",
        "...######...",
        "......#.....",
        "..#####.....",
        "..#...#.....",
        "..#...#.....",
        ".###.###....",
        ".#.#.#.#....",
        ".###.###....",
        "............",
    },
    // speaker
    .{
        "............",
        "............",
        ".....##.....",
        "....###..#..",
        "..#####.#.#.",
        "..#####.#.#.",
        "..#####.#.#.",
        "..#####.#.#.",
        "....###..#..",
        ".....##.....",
        "............",
        "............",
    },
    // muted
    .{
        "............",
        "............",
        ".....##.....",
        "....###.....",
        "..#####.#..#",
        "..#####..##.",
        "..#####..##.",
        "..#####.#..#",
        "....###.....",
        ".....##.....",
        "............",
        "............",
    },
    // battery
    .{
        "............",
        "............",
        "............",
        ".#########..",
        ".#.......#..",
        ".#.......###",
        ".#.......###",
        ".#.......#..",
        ".#########..",
        "............",
        "............",
        "............",
    },
    // terminal
    .{
        "............",
        "##########..",
        "#........#..",
        "#.##.....#..",
        "#...##...#..",
        "#.##.....#..",
        "#........#..",
        "#..####..#..",
        "#........#..",
        "##########..",
        "............",
        "............",
    },
    // document
    .{
        "............",
        "..######....",
        "..#....##...",
        "..#....###..",
        "..#......#..",
        "..#.####.#..",
        "..#......#..",
        "..#.####.#..",
        "..#......#..",
        "..########..",
        "............",
        "............",
    },
    // picture
    .{
        "............",
        "..########..",
        "..#......#..",
        "..#.##...#..",
        "..#......#..",
        "..#......#..",
        "..#...##.#..",
        "..#..#####..",
        "..########..",
        "............",
        "............",
        "............",
    },
    // folder
    .{
        "............",
        "............",
        "..###.......",
        "..#..#......",
        "..#########.",
        "..#.......#.",
        "..#.......#.",
        "..#.......#.",
        "..#########.",
        "............",
        "............",
        "............",
    },
    // sliders
    .{
        "............",
        "....##......",
        ".##########.",
        "....##......",
        "............",
        "........##..",
        ".##########.",
        "........##..",
        "............",
        "..##........",
        ".##########.",
        "..##........",
    },
    // power
    .{
        "............",
        "............",
        ".....##.....",
        "..#..##..#..",
        ".#...##...#.",
        "#....##....#",
        "#..........#",
        "#..........#",
        ".#........#.",
        "..########..",
        "............",
        "............",
    },
    // check
    .{
        "............",
        "............",
        "............",
        "..........#.",
        ".........##.",
        "#.......##..",
        "##.....##...",
        ".##...##....",
        "..##.##.....",
        "...###......",
        "....#.......",
        "............",
    },
};

/// The pictures, packed the way the blitter reads them: most significant bit
/// of the first byte is the leftmost pixel, which is the order the fonts use.
const packed_bits = blk: {
    @setEvalBranchQuota(20_000);
    var out: [art.len * BYTES]u8 = @splat(0);
    for (art, 0..) |picture, index| {
        for (picture, 0..) |row, y| {
            if (row.len != WIDTH) @compileError("every icon row is twelve pixels wide");
            for (row, 0..) |cell, x| {
                if (cell != '#' and cell != '.') @compileError("an icon row is hashes and dots");
                if (cell != '#') continue;
                const at = index * BYTES + y * ROW_BYTES + x / 8;
                out[at] |= @as(u8, 0x80) >> @intCast(x % 8);
            }
        }
    }
    const frozen = out;
    break :blk frozen;
};

comptime {
    if (art.len != std.meta.fields(Icon).len) {
        @compileError("every icon needs a picture, and every picture a name");
    }
}

/// The rows of one icon, in the shape the surface's bitmap blitter takes.
pub fn rows(which: Icon) []const u8 {
    const at = @intFromEnum(which) * BYTES;
    return packed_bits[at..][0..BYTES];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Whether a pixel is set, read back out of the packing the way the blitter
/// reads it. The tests check the pictures against what they look like.
fn lit(which: Icon, x: usize, y: usize) bool {
    const bits = rows(which);
    const byte = bits[y * ROW_BYTES + x / 8];
    return byte & (@as(u8, 0x80) >> @intCast(x % 8)) != 0;
}

test "every icon is the same size, and there is one per name" {
    try testing.expectEqual(@as(usize, 24), rows(.wifi).len);
    for (std.enums.values(Icon)) |which| {
        try testing.expectEqual(BYTES, rows(which).len);
    }
}

test "a picture packs to the bits the blitter reads" {
    // wifi's tallest bar is the rightmost, and its shortest the leftmost:
    // the top row of the tall one is lit where the short one is not.
    try testing.expect(lit(.wifi, 9, 2));
    try testing.expect(!lit(.wifi, 0, 2));
    try testing.expect(lit(.wifi, 0, 9));

    // The battery's outline is drawn and its inside is not, which is what
    // lets the charge be a rectangle rather than twelve pictures.
    try testing.expect(lit(.battery, 1, 3));
    try testing.expect(!lit(.battery, 5, 5));
    // Its terminal sticks out on the right.
    try testing.expect(lit(.battery, 11, 5));
}

test "muted is the speaker with its waves struck out" {
    // The cone is common to both.
    for (0..3) |y| {
        try testing.expectEqual(lit(.speaker, 3, y + 4), lit(.muted, 3, y + 4));
    }
    // The waves are not: where the speaker sounds, the muted one is crossed.
    try testing.expect(lit(.speaker, 8, 4));
    try testing.expect(!lit(.speaker, 11, 4));
    try testing.expect(lit(.muted, 11, 4));
}

test "sliders reads as tracks with a grip on each" {
    // Three tracks, each with a grip that sits across it rather than beside
    // it: a settings picture that is not three lines and two crosses.
    for ([_]usize{ 2, 6, 10 }) |y| {
        try testing.expect(lit(.sliders, 5, y));
        try testing.expect(lit(.sliders, 9, y));
    }
    // Each grip straddles its own track and no other.
    try testing.expect(lit(.sliders, 4, 1) and lit(.sliders, 4, 3));
    try testing.expect(!lit(.sliders, 4, 5));
    try testing.expect(lit(.sliders, 8, 5) and lit(.sliders, 8, 7));
}

test "nothing is lit outside the twelve pixels a row holds" {
    for (std.enums.values(Icon)) |which| {
        const bits = rows(which);
        var y: usize = 0;
        while (y < HEIGHT) : (y += 1) {
            // The second byte of a row carries four pixels; the low four bits
            // are past the right edge and must stay clear.
            try testing.expectEqual(@as(u8, 0), bits[y * ROW_BYTES + 1] & 0x0F);
        }
    }
}
