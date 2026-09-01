//! What a camera wrote into a photograph besides the picture.
//!
//! The decoder hands back pixels and nothing else: it steps over the metadata
//! segments, orientation included, which is why a photograph taken sideways
//! decodes sideways. That tag is the one piece of this that a viewer cannot
//! do without, so the parsing is here.
//!
//! Pure, and it allocates nothing. EXIF is a TIFF file wearing a JPEG segment
//! as a hat: a byte order, a table of tagged entries, and offsets into the
//! same block. What is read out of it are the handful of tags worth showing
//! somebody, copied into fixed room, because a field claiming to be four
//! thousand characters long is a field this reads the first forty of.
//!
//! Everything is bounds-checked against the block it came in. A photograph is
//! a file from somewhere else, and every offset in it is a number somebody
//! else chose.

const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;

/// How the camera was held. The one tag a viewer must act on, or every
/// photograph taken in portrait shows on its side.
pub const Orientation = enum(u8) {
    up = 1,
    mirror_x = 2,
    down = 3,
    mirror_y = 4,
    mirror_x_then_left = 5,
    left = 6,
    mirror_x_then_right = 7,
    right = 8,

    /// Whether showing it upright swaps its width and height.
    pub fn turned(self: Orientation) bool {
        return switch (self) {
            .left, .right, .mirror_x_then_left, .mirror_x_then_right => true,
            else => false,
        };
    }

    /// Quarter turns clockwise to put it upright.
    pub fn quarters(self: Orientation) u2 {
        return switch (self) {
            .up, .mirror_x => 0,
            .down, .mirror_y => 2,
            .left, .mirror_x_then_left => 1,
            .right, .mirror_x_then_right => 3,
        };
    }

    /// Whether it is also flipped left to right.
    pub fn mirrored(self: Orientation) bool {
        return switch (self) {
            .mirror_x, .mirror_y, .mirror_x_then_left, .mirror_x_then_right => true,
            else => false,
        };
    }

    /// The one that means these quarter turns and this mirroring, which is
    /// the inverse of reading them off.
    pub fn of(turns: u2, flipped: bool) Orientation {
        return switch (turns) {
            0 => if (flipped) .mirror_x else .up,
            1 => if (flipped) .mirror_x_then_left else .left,
            2 => if (flipped) .mirror_y else .down,
            3 => if (flipped) .mirror_x_then_right else .right,
        };
    }

    /// This orientation with another quarter turn clockwise asked of it.
    ///
    /// What a viewer needs to turn a picture by hand: the file already says
    /// which way up it was taken, and a hand turning it is one more quarter
    /// on top of that rather than a second, separate idea of which way up
    /// something is.
    pub fn turnedRight(self: Orientation) Orientation {
        return of(self.quarters() +% 1, self.mirrored());
    }

    pub fn turnedLeft(self: Orientation) Orientation {
        return of(self.quarters() -% 1, self.mirrored());
    }

    fn from(value: u32) ?Orientation {
        return if (value >= 1 and value <= 8) @enumFromInt(@as(u8, @intCast(value))) else null;
    }
};

/// The longest a text field is kept. A camera writes its own name here, not
/// an essay.
pub const TEXT_MAX = 40;

const Text = Bounded(u8, TEXT_MAX);

/// What was found. Every field is optional because every one of them is.
pub const Info = struct {
    orientation: Orientation = .up,
    /// Whether the orientation was actually written, as against assumed.
    orientation_known: bool = false,
    make: Text = .{},
    model: Text = .{},
    /// When it was taken, as the camera wrote it: "2026:08:31 22:14:07".
    taken: Text = .{},

    pub fn maker(self: *const Info) []const u8 {
        return self.make.slice();
    }

    pub fn camera(self: *const Info) []const u8 {
        return self.model.slice();
    }

    pub fn when(self: *const Info) []const u8 {
        return self.taken.slice();
    }
};

/// Read what a JPEG says about itself.
///
/// Anything that is not a JPEG, or a JPEG with nothing in it, reads as a
/// photograph with nothing to say rather than as an error: a viewer showing a
/// picture has no use for a complaint about its metadata.
pub fn read(bytes: []const u8) Info {
    const block = exifBlock(bytes) orelse return .{};
    return fromTiff(block);
}

/// The EXIF payload inside a JPEG, if there is one.
///
/// JPEG is a chain of markers: 0xFF, a kind, then a big-endian length that
/// counts itself. EXIF rides in APP1, which begins "Exif\0\0".
fn exifBlock(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return null;

    var at: usize = 2;
    while (at + 4 <= bytes.len) {
        if (bytes[at] != 0xFF) return null;

        const kind = bytes[at + 1];
        // Padding between markers, and the ones that carry no payload.
        if (kind == 0xFF) {
            at += 1;
            continue;
        }
        // The start of the compressed data: everything after it is the
        // picture, and there are no more headers to read.
        if (kind == 0xDA or kind == 0xD9) return null;

        const size = std.mem.readInt(u16, bytes[at + 2 ..][0..2], .big);
        if (size < 2) return null;

        const body_at = at + 4;
        const body_len = @as(usize, size) - 2;
        if (body_at + body_len > bytes.len) return null;

        const body = bytes[body_at..][0..body_len];
        if (kind == 0xE1 and std.mem.startsWith(u8, body, "Exif\x00\x00")) {
            return body["Exif\x00\x00".len..];
        }

        at = body_at + body_len;
    }
    return null;
}

/// Tags worth reading. Everything else in the file is stepped over.
const Tag = enum(u16) {
    make = 0x010F,
    model = 0x0110,
    orientation = 0x0112,
    date_time = 0x0132,
    exif_ifd = 0x8769,
    date_time_original = 0x9003,
    _,
};

/// How many entries one table may hold before this stops reading it. A camera
/// writes a few dozen; a file claiming sixty thousand is a file spending this
/// program's time.
const ENTRIES_MAX = 128;

fn fromTiff(block: []const u8) Info {
    if (block.len < 8) return .{};

    const endian: std.builtin.Endian = switch (std.mem.readInt(u16, block[0..2], .little)) {
        0x4949 => .little,
        0x4D4D => .big,
        else => return .{},
    };

    if (readInt(u16, block, 2, endian) != 42) return .{};

    var info = Info{};
    const first = readInt(u32, block, 4, endian);
    walk(block, first, endian, &info, 0);
    return info;
}

/// One table of entries, and the tables it points at.
///
/// `depth` is what stops a file whose sub-table points back at itself: the
/// only nesting EXIF actually uses is one level, so two is already generous.
fn walk(block: []const u8, at: u32, endian: std.builtin.Endian, info: *Info, depth: u8) void {
    if (depth > 1) return;

    const start: usize = at;
    if (start + 2 > block.len) return;

    const count = @min(readInt(u16, block, start, endian), ENTRIES_MAX);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry = start + 2 + i * 12;
        if (entry + 12 > block.len) return;

        const tag: Tag = @enumFromInt(readInt(u16, block, entry, endian));
        const kind = readInt(u16, block, entry + 2, endian);
        const items = readInt(u32, block, entry + 4, endian);

        switch (tag) {
            .orientation => {
                if (kind != 3) continue;
                // A short lives in the first two bytes of the value field
                // rather than at an offset: it fits, so there is nowhere else
                // for it to be.
                if (Orientation.from(readInt(u16, block, entry + 8, endian))) |which| {
                    info.orientation = which;
                    info.orientation_known = true;
                }
            },
            .make => text(block, entry, kind, items, endian, &info.make),
            .model => text(block, entry, kind, items, endian, &info.model),
            // The original moment wins over the file's own timestamp, which
            // is when it was last written.
            .date_time => if (info.taken.isEmpty()) {
                text(block, entry, kind, items, endian, &info.taken);
            },
            .date_time_original => {
                info.taken.clear();
                text(block, entry, kind, items, endian, &info.taken);
            },
            .exif_ifd => walk(block, readInt(u32, block, entry + 8, endian), endian, info, depth + 1),
            else => {},
        }
    }
}

/// A string field, which is where it says it is unless it is short enough to
/// live in the entry itself.
fn text(
    block: []const u8,
    entry: usize,
    kind: u16,
    items: u32,
    endian: std.builtin.Endian,
    into: *Text,
) void {
    if (kind != 2 or items == 0) return;

    const inline_room = 4;
    const from: usize = if (items <= inline_room)
        entry + 8
    else
        readInt(u32, block, entry + 8, endian);

    if (from >= block.len) return;

    const available = @min(@as(usize, items), block.len - from);
    const raw = block[from..][0..available];

    // Counted with its terminator, and padded with spaces by some cameras.
    const said = std.mem.trim(u8, std.mem.sliceTo(raw, 0), " ");
    into.clear();
    for (said) |byte| into.append(byte) catch break;
}

/// A number from the block, or zero when it is not all there.
fn readInt(comptime T: type, block: []const u8, at: usize, endian: std.builtin.Endian) T {
    const size = @sizeOf(T);
    if (at + size > block.len) return 0;
    return std.mem.readVarInt(T, block[at..][0..size], endian);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A JPEG carrying one APP1 segment and nothing else, built here so the test
/// needs no file beside it.
fn photograph(comptime tiff: []const u8) [tiff.len + 12]u8 {
    var out: [tiff.len + 12]u8 = undefined;
    const size: u16 = @intCast(tiff.len + 6 + 2);

    out[0] = 0xFF;
    out[1] = 0xD8;
    out[2] = 0xFF;
    out[3] = 0xE1;
    std.mem.writeInt(u16, out[4..6], size, .big);
    @memcpy(out[6..12], "Exif\x00\x00");
    @memcpy(out[12..], tiff);
    return out;
}

/// A little-endian TIFF block: header, one entry table.
const upright = "II" ++ // byte order
    "\x2A\x00" ++ // 42
    "\x08\x00\x00\x00" ++ // first table at 8
    "\x01\x00" ++ // one entry
    "\x12\x01" ++ "\x03\x00" ++ "\x01\x00\x00\x00" ++ "\x01\x00\x00\x00" ++
    "\x00\x00\x00\x00"; // no next table

const sideways = "II" ++ "\x2A\x00" ++ "\x08\x00\x00\x00" ++
    "\x01\x00" ++
    "\x12\x01" ++ "\x03\x00" ++ "\x01\x00\x00\x00" ++ "\x06\x00\x00\x00" ++
    "\x00\x00\x00\x00";

test "a photograph says which way up it was taken" {
    const flat = photograph(upright);
    const info = read(&flat);
    try testing.expect(info.orientation_known);
    try testing.expectEqual(Orientation.up, info.orientation);
    try testing.expect(!info.orientation.turned());

    const turned = photograph(sideways);
    const other = read(&turned);
    try testing.expectEqual(Orientation.left, other.orientation);
    try testing.expect(other.orientation.turned());
    try testing.expectEqual(@as(u2, 1), other.orientation.quarters());
    try testing.expect(!other.orientation.mirrored());
}

test "putting one upright is turning and sometimes flipping it" {
    try testing.expectEqual(@as(u2, 0), Orientation.up.quarters());
    try testing.expectEqual(@as(u2, 2), Orientation.down.quarters());
    try testing.expectEqual(@as(u2, 3), Orientation.right.quarters());

    try testing.expect(Orientation.mirror_x.mirrored());
    try testing.expect(!Orientation.down.mirrored());
    // A mirrored quarter turn is both, which is what the odd numbers mean.
    try testing.expect(Orientation.mirror_x_then_left.mirrored());
    try testing.expect(Orientation.mirror_x_then_left.turned());
}

test "a picture with nothing to say says nothing" {
    // Not a JPEG at all.
    const nothing = read("plain bytes");
    try testing.expect(!nothing.orientation_known);
    try testing.expectEqual(Orientation.up, nothing.orientation);

    // A JPEG whose first marker is the picture: there is no metadata to find.
    const bare = [_]u8{ 0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02 };
    try testing.expect(!read(&bare).orientation_known);

    // An APP1 that is not EXIF.
    const other_app1 = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x08, 'X', 'M', 'P', 0, 0, 0 };
    try testing.expect(!read(&other_app1).orientation_known);
}

test "the camera's own words come back, trimmed" {
    // Make = "Eee", at an offset, and a model short enough to live in the
    // entry itself.
    const tiff = "II" ++ "\x2A\x00" ++ "\x08\x00\x00\x00" ++
        "\x02\x00" ++
        "\x0F\x01" ++ "\x02\x00" ++ "\x08\x00\x00\x00" ++ "\x32\x00\x00\x00" ++
        "\x10\x01" ++ "\x02\x00" ++ "\x04\x00\x00\x00" ++ "701\x00" ++
        "\x00\x00\x00\x00" ++
        // Padding out to offset 0x32, then the string. The block so far is
        // the header, the count, two entries and the empty next-table
        // pointer, which is thirty-eight bytes.
        "\x00" ** (0x32 - 38) ++ "ASUS   \x00";

    const flat = photograph(tiff);
    const info = read(&flat);
    try testing.expectEqualStrings("ASUS", info.maker());
    try testing.expectEqualStrings("701", info.camera());
}

test "a big-endian file reads the same as a little-endian one" {
    const big = "MM" ++ "\x00\x2A" ++ "\x00\x00\x00\x08" ++
        "\x00\x01" ++
        "\x01\x12" ++ "\x00\x03" ++ "\x00\x00\x00\x01" ++ "\x00\x06\x00\x00" ++
        "\x00\x00\x00\x00";

    const flat = photograph(big);
    try testing.expectEqual(Orientation.left, read(&flat).orientation);
}

test "offsets that point outside the block are refused, not followed" {
    // An entry whose value lives past the end of everything.
    const runaway = "II" ++ "\x2A\x00" ++ "\x08\x00\x00\x00" ++
        "\x01\x00" ++
        "\x0F\x01" ++ "\x02\x00" ++ "\xFF\xFF\xFF\x7F" ++ "\xF0\xFF\xFF\x7F" ++
        "\x00\x00\x00\x00";

    const flat = photograph(runaway);
    const info = read(&flat);
    try testing.expectEqualStrings("", info.maker());

    // A table that says it starts past the end.
    const lost = "II" ++ "\x2A\x00" ++ "\xF0\xFF\xFF\x7F";
    const flat_lost = photograph(lost);
    try testing.expect(!read(&flat_lost).orientation_known);
}

test "a table pointing at itself is walked once, not forever" {
    // The sub-table offset points back at the first table.
    const looped = "II" ++ "\x2A\x00" ++ "\x08\x00\x00\x00" ++
        "\x01\x00" ++
        "\x69\x87" ++ "\x04\x00" ++ "\x01\x00\x00\x00" ++ "\x08\x00\x00\x00" ++
        "\x00\x00\x00\x00";

    const flat = photograph(looped);
    _ = read(&flat);
}

test "a turn composes with the way the camera held it" {
    const std_testing = std.testing;

    // A picture already upright, turned right, is one a viewer must turn a
    // quarter to show as it now is.
    try std_testing.expectEqual(Orientation.left, Orientation.up.turnedRight());
    try std_testing.expectEqual(Orientation.down, Orientation.left.turnedRight());
    try std_testing.expectEqual(Orientation.right, Orientation.down.turnedRight());
    try std_testing.expectEqual(Orientation.up, Orientation.right.turnedRight());

    // Four of either way is where it started, whatever it started as.
    for ([_]Orientation{ .up, .down, .left, .right, .mirror_x, .mirror_y }) |start| {
        var turned = start;
        for (0..4) |_| turned = turned.turnedRight();
        try std_testing.expectEqual(start, turned);

        var back = start;
        for (0..4) |_| back = back.turnedLeft();
        try std_testing.expectEqual(start, back);
    }

    // Turning one way and back is where it started.
    try std_testing.expectEqual(Orientation.up, Orientation.up.turnedRight().turnedLeft());

    // A mirrored picture stays mirrored however it is turned.
    try std_testing.expect(Orientation.mirror_x.turnedRight().mirrored());
}
