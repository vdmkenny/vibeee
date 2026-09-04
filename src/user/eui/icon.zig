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

const kind = @import("lib").kind;
const std = @import("std");

pub const WIDTH: usize = 12;
pub const HEIGHT: usize = 12;
/// Two bytes a row, because twelve pixels do not fit in one.
pub const ROW_BYTES: usize = 2;
/// The bytes one picture packs to.
pub const BYTES: usize = HEIGHT * ROW_BYTES;

/// One picture, packed: what `of` hands out for a named icon, and what a
/// program's own picture is once `pack` has made it. A pointer to the bytes
/// rather than the bytes, so a rail row or a tile carries a word, not a copy.
pub const Glyph = *const [BYTES]u8;

/// The picture a sort of file gets. One rule for the system: a listing, a
/// preview pane and a launcher row draw the same file the same way, and a
/// family this build cannot open still gets a picture that says what it is.
pub fn forFamily(family: kind.Family) Icon {
    return switch (family) {
        .directory => .folder,
        .picture => .picture,
        .program => .apps,
        else => .document,
    };
}

pub const Icon = enum {
    /// Four ascending bars: signal, and the only thing in the bar that says
    /// whether the radio has anything.
    wifi,
    /// The same bars with the tallest ones unlit: a network heard less
    /// well. The lit bars stay where they are, so the picture reads as a
    /// level rather than as a different drawing each time.
    wifi_good,
    wifi_fair,
    wifi_weak,
    /// A wired link, for a machine that has a cable in it.
    ethernet,
    speaker,
    /// The same cone with one wave: a machine that is on but quiet, which
    /// looks like a machine that is off if the picture does not say so.
    speaker_low,
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
    /// Bars of different heights: what is running and how much of the
    /// machine it is using.
    chart,
    /// A screen over two rows of keys, which is what a calculator has looked
    /// like for longer than this machine has existed.
    calculator,
    /// Settings. Sliders rather than a cog: a cog at this size is a blob.
    sliders,
    power,
    /// A tick, for the chosen row of a list that has one.
    check,
    /// One window filling its frame: a desktop showing one of its windows at
    /// full size rather than the tiling it would otherwise have.
    maximised,
    /// A panel on a stand. What the screen settings are about, and the only
    /// picture here that is a drawing of the thing you are looking at.
    display,
    /// Keys in rows, with the space bar under them.
    keyboard,
    /// A letter in a box: what this machine is, rather than a setting to
    /// change. The one row of a rail that answers instead of asking.
    about,
    /// A question mark: where the answers are.
    help,
    /// A lens with a handle: where typing goes.
    search,
    /// A way out of the room: the sign over a fire door, which is what
    /// leaving the desktop for a bare shell is.
    exit,
    /// Four squares: programs, as a group rather than any one of them.
    apps,
    /// The system's own mark: a lowercase e with a written slant. A letter
    /// rather than a symbol, because the machine is named after one.
    logo,
    /// The same cell with a bolt in it. A machine on mains says so with the
    /// picture rather than with the level, because the level is going up and
    /// a number climbing on its own is not what somebody is asking.
    battery_charging,
    /// The same cell with a bang in it, drawn in the warning colour. Shape as
    /// well as colour: a picture that says "act now" only by being red says
    /// nothing to somebody who cannot tell it from the other one.
    battery_critical,
    /// A face with two hands. What the bar's clock opens, and the one picture
    /// nobody has to be taught.
    clock,
    /// Scissors, two sheets and a board: what the other mouse button offers
    /// wherever there is text.
    cut,
    copy,
    paste,
    /// A block with everything in it taken.
    select_all,
    /// Which way a table is ordered, beside the heading it is ordered by.
    sort_up,
    sort_down,
    /// A closed padlock: a connection nobody in between can read. Shown
    /// beside what it protects rather than as a state to change.
    lock,
};

/// A picture and the name it belongs to.
///
/// Named rather than positional: an array of pictures in enum order is
/// one insertion away from every icon after it drawing the wrong thing,
/// and nothing about the result looks wrong until somebody sees a tick
/// where a window should be. The comptime block below proves the order.
/// Where a picture sits in its cell.
///
/// Almost everything is centred, and the check below holds it to that. A
/// family that reads as a scale is the exception: signal bars grow from one
/// corner, and re-centring each step would make the bars jump about as the
/// strength changed, which is the one thing a strength picture must not do.
const Anchor = enum { centre, corner };

const Picture = struct {
    icon: Icon,
    rows: [HEIGHT][]const u8,
    anchor: Anchor = .centre,
};

const art = [_]Picture{
    .{
        .icon = .wifi,
        .rows = .{
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
    },
    .{
        .icon = .wifi_good,
        .anchor = .corner,
        .rows = .{
            "............",
            "............",
            "............",
            "............",
            "......##.##.",
            "......##.##.",
            "......##.##.",
            "...##.##.##.",
            "...##.##.##.",
            "##.##.##.##.",
            "##.##.##.##.",
            "............",
        },
    },
    .{
        .icon = .wifi_fair,
        .anchor = .corner,
        .rows = .{
            "............",
            "............",
            "............",
            "............",
            "............",
            "............",
            "............",
            "...##.##....",
            "...##.##....",
            "##.##.##....",
            "##.##.##....",
            "............",
        },
    },
    .{
        .icon = .wifi_weak,
        .anchor = .corner,
        .rows = .{
            "............",
            "............",
            "............",
            "............",
            "............",
            "............",
            "............",
            "............",
            "............",
            "##..........",
            "##..........",
            "............",
        },
    },
    .{
        .icon = .ethernet,
        .rows = .{
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
    },
    .{
        .icon = .speaker,
        .rows = .{
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
    },
    .{
        .icon = .speaker_low,
        .rows = .{
            "............",
            "............",
            ".....##.....",
            "....###.....",
            "..#####..#..",
            "..#####.#...",
            "..#####.#...",
            "..#####..#..",
            "....###.....",
            ".....##.....",
            "............",
            "............",
        },
    },
    .{
        .icon = .muted,
        .rows = .{
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
    },
    .{
        .icon = .battery,
        .rows = .{
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
    },
    .{
        .icon = .terminal,
        .rows = .{
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
    },
    .{
        .icon = .document,
        .rows = .{
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
    },
    .{
        .icon = .picture,
        .rows = .{
            "............",
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
        },
    },
    .{
        .icon = .folder,
        .rows = .{
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
    },
    .{
        .icon = .chart,
        .rows = .{
            "............",
            "............",
            "............",
            ".##......##.",
            ".##......##.",
            ".##..##..##.",
            ".##..##..##.",
            ".##..##..##.",
            ".##..##..##.",
            "............",
            "............",
            "............",
        },
    },
    .{
        .icon = .calculator,
        .rows = .{
            "............",
            "............",
            ".##########.",
            ".#........#.",
            ".#.######.#.",
            ".#........#.",
            ".#.##..##.#.",
            ".#........#.",
            ".#.##..##.#.",
            ".#........#.",
            ".##########.",
            "............",
        },
    },
    .{
        .icon = .sliders,
        .rows = .{
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
    },
    .{
        .icon = .power,
        .rows = .{
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
    },
    .{
        .icon = .check,
        .rows = .{
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
            "............",
        },
    },
    .{
        .icon = .maximised,
        .rows = .{
            "............",
            "............",
            ".##########.",
            ".#........#.",
            ".#.######.#.",
            ".#.######.#.",
            ".#.######.#.",
            ".#.######.#.",
            ".#........#.",
            ".##########.",
            "............",
            "............",
        },
    },
    .{
        .icon = .display,
        .rows = .{
            "............",
            "############",
            "#..........#",
            "#..........#",
            "#..........#",
            "#..........#",
            "#..........#",
            "############",
            "....####....",
            "....####....",
            "..########..",
            "............",
        },
    },
    .{
        .icon = .keyboard,
        .rows = .{
            "............",
            "............",
            "############",
            "#.#.#.#.#..#",
            "#..........#",
            "#.#.#.#.#..#",
            "#..........#",
            "#..######..#",
            "#..........#",
            "############",
            "............",
            "............",
        },
    },
    .{
        .icon = .about,
        .rows = .{
            "............",
            "..########..",
            ".##......##.",
            "##...##...##",
            "##...##...##",
            "##........##",
            "##...##...##",
            "##...##...##",
            "##...##...##",
            ".##......##.",
            "..########..",
            "............",
        },
    },
    .{
        .icon = .help,
        .rows = .{
            "............",
            "...######...",
            "..##....##..",
            ".##......##.",
            ".........##.",
            "........##..",
            ".....####...",
            ".....##.....",
            ".....##.....",
            "............",
            ".....##.....",
            ".....##.....",
        },
    },
    .{
        .icon = .search,
        .rows = .{
            "..#####.....",
            ".##...##....",
            "##.....##...",
            "#.......#...",
            "#.......#...",
            "#.......#...",
            "##.....##...",
            ".##...##....",
            "..#####.##..",
            ".......##.##",
            "..........##",
            "...........#",
        },
    },
    .{
        .icon = .exit,
        .rows = .{
            "............",
            "####........",
            "#...........",
            "#.......#...",
            "#........#..",
            "#....######.",
            "#....######.",
            "#........#..",
            "#.......#...",
            "#...........",
            "####........",
            "............",
        },
    },
    .{
        .icon = .apps,
        .rows = .{
            "............",
            ".####..####.",
            ".####..####.",
            ".####..####.",
            ".####..####.",
            "............",
            ".####..####.",
            ".####..####.",
            ".####..####.",
            ".####..####.",
            "............",
            "............",
        },
    },
    .{
        .icon = .logo,
        .rows = .{
            "............",
            "............",
            "......####..",
            ".....##..##.",
            "....##....##",
            "...########.",
            "...##.......",
            "..##........",
            "..##.....##.",
            "..##....##..",
            "...#####....",
            "............",
        },
    },
    .{
        .icon = .battery_charging,
        .rows = .{
            "............",
            "............",
            "............",
            ".#########..",
            ".#....##.#..",
            ".#...###.###",
            ".#..###..###",
            ".#...##..#..",
            ".#########..",
            "............",
            "............",
            "............",
        },
    },
    .{
        .icon = .battery_critical,
        .rows = .{
            "............",
            "............",
            "............",
            ".#########..",
            ".#...##..#..",
            ".#...##..###",
            ".#.......###",
            ".#...##..#..",
            ".#########..",
            "............",
            "............",
            "............",
        },
    },
    .{
        .icon = .clock,
        .rows = .{
            "............",
            "...######...",
            "..##....##..",
            ".##..##..##.",
            "##...##...##",
            "##...##...##",
            "##...#####.#",
            "##........##",
            "##........##",
            ".##......##.",
            "..##....##..",
            "...######...",
        },
    },
    .{
        .icon = .cut,
        .rows = .{
            ".##.......##",
            ".##.......##",
            "..##.....##.",
            "...##...##..",
            "....##.##...",
            ".....###....",
            "....##.##...",
            "...##...##..",
            "..###...###.",
            "..#.#...#.#.",
            "..###...###.",
            "............",
        },
    },
    .{
        .icon = .copy,
        .rows = .{
            "............",
            ".######.....",
            ".#....#.....",
            ".#..######..",
            ".#..#....#..",
            ".####....#..",
            "....#....#..",
            "....#....#..",
            "....#....#..",
            "....######..",
            "............",
            "............",
        },
    },
    .{
        .icon = .paste,
        .rows = .{
            "....####....",
            "...#....#...",
            ".##########.",
            ".#........#.",
            ".#........#.",
            ".#........#.",
            ".#........#.",
            ".#........#.",
            ".#........#.",
            ".#........#.",
            ".##########.",
            "............",
        },
    },
    .{
        .icon = .select_all,
        .rows = .{
            "............",
            ".##########.",
            ".#........#.",
            ".#.######.#.",
            ".#.######.#.",
            ".#.######.#.",
            ".#.######.#.",
            ".#.######.#.",
            ".#........#.",
            ".##########.",
            "............",
            "............",
        },
    },
    .{
        .icon = .sort_up,
        .rows = .{
            "............",
            "............",
            "............",
            ".....##.....",
            "....####....",
            "...##..##...",
            "..##....##..",
            ".##......##.",
            "............",
            "............",
            "............",
            "............",
        },
    },
    .{
        .icon = .sort_down,
        .rows = .{
            "............",
            "............",
            "............",
            ".##......##.",
            "..##....##..",
            "...##..##...",
            "....####....",
            ".....##.....",
            "............",
            "............",
            "............",
            "............",
        },
    },
    .{
        .icon = .lock,
        .rows = .{
            "............",
            "............",
            "....####....",
            "...##..##...",
            "...##..##...",
            "..########..",
            "..##....##..",
            "..##.##.##..",
            "..##.##.##..",
            "..########..",
            "............",
            "............",
        },
    },
};

/// The pictures, packed the way the blitter reads them: most significant bit
/// of the first byte is the leftmost pixel, which is the order the fonts use.
const packed_bits = blk: {
    @setEvalBranchQuota(20_000);
    var out: [art.len * BYTES]u8 = @splat(0);
    for (art, 0..) |picture, index| {
        for (picture.rows, 0..) |row, y| {
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
    // Thirty-two pictures of a hundred and forty-four cells each is more
    // branches than the default allowance, and all of it is arithmetic the
    // compiler does once.
    @setEvalBranchQuota(20_000);

    if (art.len != std.meta.fields(Icon).len) {
        @compileError("every icon needs a picture, and every picture a name");
    }
    // And each in the place its name says, so a picture inserted in the
    // middle cannot quietly shift every one after it.
    for (art, 0..) |picture, index| {
        if (@intFromEnum(picture.icon) != index) {
            @compileError("the picture for " ++ @tagName(picture.icon) ++ " is out of order");
        }
    }

    // And drawn in the middle of its own cell. A picture beside a word is
    // placed by its cell, so one drawn high inside that cell sits high beside
    // every label in the system, and the fault looks like a layout bug in
    // whichever window somebody happened to notice it in.
    for (art) |picture| {
        var top: ?usize = null;
        var bottom: usize = 0;
        for (picture.rows, 0..) |row, y| {
            for (row) |cell| {
                if (cell != '#') continue;
                if (top == null) top = y;
                bottom = y;
                break;
            }
        }

        if (picture.anchor == .corner) continue;
        const first = top orelse continue;
        // Twice the centre, so the half a row an even-height picture lands on
        // stays a whole number: eleven is the middle of twelve rows.
        const twice = first + bottom;
        if (twice < 10 or twice > 12) {
            @compileError("the picture for " ++ @tagName(picture.icon) ++
                " is not centred in its cell");
        }
    }
}

/// The picture for a sound level.
///
/// Here rather than beside the sound protocol because it is a decision about
/// pictures, and every place that shows a level wants the same one: a bar
/// indicator and a panel that disagreed about what half volume looks like
/// would be two different machines.
/// Which picture says how well a network is heard.
///
/// `bars` is what the network service reports, zero to three, so the
/// picture and any figure beside it cannot disagree about one reading.
pub fn signal(bars: u8) Icon {
    return switch (bars) {
        0 => .wifi_weak,
        1 => .wifi_fair,
        2 => .wifi_good,
        else => .wifi,
    };
}

pub fn volume(percent: u8, muted: bool) Icon {
    if (muted or percent == 0) return .muted;
    return if (percent < 50) .speaker_low else .speaker;
}

/// Which cell to draw for a pack in a given state.
///
/// One place decides, because the bar, the menu and a settings pane all have
/// to agree: a machine showing a bolt in one place and a level in another is
/// a machine telling two stories about the same battery.
pub fn battery(charging: bool, critical: bool) Icon {
    if (critical) return .battery_critical;
    return if (charging) .battery_charging else .battery;
}

/// Whether a picture leaves room for the charge to be drawn inside it. The
/// bolt and the bang fill the cell themselves.
pub fn holdsCharge(which: Icon) bool {
    return which == .battery;
}

/// The hollow of the battery picture, where the charge is drawn.
///
/// Given as numbers rather than measured off the art by whoever fills it: the
/// picture and the rectangle inside it have to agree, and the test below is
/// what makes them. Plain integers because this file cannot reach for a
/// rectangle: the surface that has one already imports this.
pub const battery_inside = .{ .x = 2, .y = 4, .w = 7, .h = 4 };

/// The rows of one icon, in the shape the surface's bitmap blitter takes.
pub fn rows(which: Icon) []const u8 {
    const at = @intFromEnum(which) * BYTES;
    return packed_bits[at..][0..BYTES];
}

/// A named icon as a glyph, for anything that takes a caller's own picture.
pub fn of(which: Icon) Glyph {
    return packed_bits[@intFromEnum(which) * BYTES ..][0..BYTES];
}

/// Pack a picture written as rows of dots and hashes, the way the icons here
/// are written, into the bytes the surface draws. At compile time, so a
/// program's own pictures cost nothing at run time, and a row of the wrong
/// length or a picture sitting off centre in its cell is refused before it
/// ships rather than looking like a layout bug in whichever window somebody
/// notices it in.
pub fn pack(comptime picture: [HEIGHT][]const u8) [BYTES]u8 {
    // A picture is a hundred and forty-four cells of arithmetic done once at
    // compile time; a program packing a handful in one initialiser is past
    // the default allowance.
    @setEvalBranchQuota(20_000);
    comptime {
        var top: ?usize = null;
        var bottom: usize = 0;
        for (picture, 0..) |row, y| {
            if (row.len != WIDTH) @compileError("a picture row is twelve cells wide");
            for (row) |cell| {
                if (cell != '#') continue;
                if (top == null) top = y;
                bottom = y;
                break;
            }
        }
        if (top) |first| {
            const twice = first + bottom;
            if (twice < 10 or twice > 12) @compileError("a picture is drawn centred in its cell");
        }
    }

    var out: [BYTES]u8 = @splat(0);
    inline for (picture, 0..) |row, y| {
        inline for (row, 0..) |cell, x| {
            if (cell == '#') out[y * ROW_BYTES + x / 8] |= @as(u8, 0x80) >> @intCast(x % 8);
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "a caller's picture packs to the same bytes a named icon does" {
    // The document icon, redrawn by hand, packs to the document's own bytes.
    const again = pack(art[@intFromEnum(Icon.document)].rows);
    try std.testing.expectEqualSlices(u8, rows(.document), &again);
    try std.testing.expectEqualSlices(u8, rows(.document), of(.document));
}

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

test "the battery is hollow exactly where the charge goes" {
    const inside = battery_inside;
    var y: usize = @intCast(inside.y);
    while (y < inside.y + inside.h) : (y += 1) {
        var x: usize = @intCast(inside.x);
        while (x < inside.x + inside.w) : (x += 1) {
            try testing.expect(!lit(.battery, x, y));
        }
    }

    // And drawn all the way around it, so a full charge does not leak out.
    try testing.expect(lit(.battery, @intCast(inside.x - 1), @intCast(inside.y)));
    try testing.expect(lit(.battery, @intCast(inside.x + inside.w), @intCast(inside.y)));
    try testing.expect(lit(.battery, @intCast(inside.x), @intCast(inside.y - 1)));
    try testing.expect(lit(.battery, @intCast(inside.x), @intCast(inside.y + inside.h)));
}

test "a level picks the picture that says what it sounds like" {
    try testing.expectEqual(Icon.muted, volume(0, false));
    try testing.expectEqual(Icon.muted, volume(70, true));
    try testing.expectEqual(Icon.speaker_low, volume(1, false));
    try testing.expectEqual(Icon.speaker_low, volume(49, false));
    try testing.expectEqual(Icon.speaker, volume(50, false));
    try testing.expectEqual(Icon.speaker, volume(100, false));
}

test "the quiet speaker is the loud one with a wave taken off" {
    // The cone is the same picture; only what comes out of it differs.
    for (0..12) |y| {
        for (0..7) |x| {
            try testing.expectEqual(lit(.speaker, x, y), lit(.speaker_low, x, y));
        }
    }
    try testing.expect(lit(.speaker, 10, 5));
    try testing.expect(!lit(.speaker_low, 10, 5));
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
