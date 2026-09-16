//! Keys, decoded from the bytes a terminal sends.

const std = @import("std");

pub const Key = union(enum) {
    char: u21,
    enter,
    tab,
    back_tab,
    backspace,
    delete,
    escape,
    /// Ctrl+C: leave without saving.
    interrupt,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
};

/// A key and how many bytes it took. `key` is null for bytes that are no key
/// this program reads.
pub const Decoded = struct {
    key: ?Key,
    len: usize,
};

const ESC = 0x1b;

/// Control characters with a key of their own.
const Control = enum(u8) {
    interrupt = 0x03,
    backspace_ctrl_h = 0x08,
    tab = 0x09,
    line_feed = 0x0a,
    carriage_return = 0x0d,
    delete = 0x7f,
    _,

    fn key(self: Control) ?Key {
        return switch (self) {
            .interrupt => .interrupt,
            .backspace_ctrl_h, .delete => .backspace,
            .tab => .tab,
            .line_feed, .carriage_return => .enter,
            _ => null,
        };
    }
};

/// Final bytes of the sequences read, after `ESC [` or `ESC O`.
const Final = enum(u8) {
    up = 'A',
    down = 'B',
    right = 'C',
    left = 'D',
    end = 'F',
    home = 'H',
    back_tab = 'Z',
    /// `ESC [ n ~`: the key is in the number.
    numbered = '~',
    _,
};

/// The numbers of `ESC [ n ~` keys.
const Numbered = enum(u8) {
    home = 1,
    delete = 3,
    end = 4,
    page_up = 5,
    page_down = 6,
    home_rxvt = 7,
    end_rxvt = 8,
    _,

    fn key(self: Numbered) ?Key {
        return switch (self) {
            .home, .home_rxvt => .home,
            .end, .end_rxvt => .end,
            .delete => .delete,
            .page_up => .page_up,
            .page_down => .page_down,
            _ => null,
        };
    }
};

/// The first key in `bytes`, which must not be empty.
///
/// A lone escape byte is the Escape key: a terminal sends a whole sequence in
/// one read. A sequence cut short or not known here is consumed whole.
pub fn first(bytes: []const u8) Decoded {
    std.debug.assert(bytes.len > 0);
    const lead = bytes[0];
    if (lead == ESC) return escaped(bytes);
    if (lead < 0x20 or lead == 0x7f) return .{ .key = @as(Control, @enumFromInt(lead)).key(), .len = 1 };

    const len = std.unicode.utf8ByteSequenceLength(lead) catch return .{ .key = null, .len = 1 };
    if (len > bytes.len) return .{ .key = null, .len = bytes.len };
    const codepoint = std.unicode.utf8Decode(bytes[0..len]) catch return .{ .key = null, .len = 1 };
    return .{ .key = .{ .char = codepoint }, .len = len };
}

fn escaped(bytes: []const u8) Decoded {
    if (bytes.len == 1) return .{ .key = .escape, .len = 1 };
    return switch (bytes[1]) {
        '[' => csi(bytes),
        // Application cursor mode: one final byte.
        'O' => if (bytes.len < 3)
            .{ .key = null, .len = bytes.len }
        else
            .{ .key = finalKey(@enumFromInt(bytes[2]), 0), .len = 3 },
        // Escape, then another key typed quickly: the escape alone.
        else => .{ .key = .escape, .len = 1 },
    };
}

/// `ESC [`, parameters, one final byte.
fn csi(bytes: []const u8) Decoded {
    var number: u8 = 0;
    var in_first = true;
    for (bytes[2..], 2..) |byte, at| {
        switch (byte) {
            // Saturates: a number past any key's is no key.
            '0'...'9' => if (in_first) {
                number = number *| 10 +| (byte - '0');
            },
            // Modifiers follow the first number; the key is the same.
            ';' => in_first = false,
            0x40...0x7e => return .{ .key = finalKey(@enumFromInt(byte), number), .len = at + 1 },
            else => {},
        }
    }
    return .{ .key = null, .len = bytes.len };
}

fn finalKey(final: Final, number: u8) ?Key {
    return switch (final) {
        .up => .up,
        .down => .down,
        .right => .right,
        .left => .left,
        .end => .end,
        .home => .home,
        .back_tab => .back_tab,
        .numbered => @as(Numbered, @enumFromInt(number)).key(),
        _ => null,
    };
}

const testing = std.testing;

test "sequences decode to their keys and take all their bytes" {
    const Case = struct { bytes: []const u8, key: ?Key };
    const cases = [_]Case{
        .{ .bytes = "\x1b[A", .key = .up },
        .{ .bytes = "\x1b[B", .key = .down },
        .{ .bytes = "\x1b[C", .key = .right },
        .{ .bytes = "\x1b[D", .key = .left },
        .{ .bytes = "\x1bOA", .key = .up },
        .{ .bytes = "\x1b[H", .key = .home },
        .{ .bytes = "\x1bOF", .key = .end },
        .{ .bytes = "\x1b[1~", .key = .home },
        .{ .bytes = "\x1b[3~", .key = .delete },
        .{ .bytes = "\x1b[4~", .key = .end },
        .{ .bytes = "\x1b[5~", .key = .page_up },
        .{ .bytes = "\x1b[6~", .key = .page_down },
        .{ .bytes = "\x1b[Z", .key = .back_tab },
        .{ .bytes = "\x1b[1;5A", .key = .up },
        .{ .bytes = "\x1b[3;2~", .key = .delete },
        .{ .bytes = "\x1b[99~", .key = null },
        .{ .bytes = "\x1b[?", .key = null },
    };
    for (cases) |case| {
        const decoded = first(case.bytes);
        try testing.expectEqual(case.key, decoded.key);
        try testing.expectEqual(case.bytes.len, decoded.len);
    }
}

test "control bytes and text decode one key at a time" {
    try testing.expectEqual(Decoded{ .key = .escape, .len = 1 }, first("\x1b"));
    try testing.expectEqual(Decoded{ .key = .escape, .len = 1 }, first("\x1bq"));
    try testing.expectEqual(Decoded{ .key = .enter, .len = 1 }, first("\r"));
    try testing.expectEqual(Decoded{ .key = .enter, .len = 1 }, first("\n"));
    try testing.expectEqual(Decoded{ .key = .tab, .len = 1 }, first("\t"));
    try testing.expectEqual(Decoded{ .key = .backspace, .len = 1 }, first("\x7f"));
    try testing.expectEqual(Decoded{ .key = .interrupt, .len = 1 }, first("\x03"));
    try testing.expectEqual(Decoded{ .key = null, .len = 1 }, first("\x01"));
    try testing.expectEqual(Decoded{ .key = .{ .char = 'y' }, .len = 1 }, first("yes"));
    try testing.expectEqual(Decoded{ .key = .{ .char = 0xe9 }, .len = 2 }, first("\xc3\xa9"));
}

test "a sequence cut short is consumed without a key" {
    try testing.expectEqual(Decoded{ .key = null, .len = 2 }, first("\x1b["));
    try testing.expectEqual(Decoded{ .key = null, .len = 4 }, first("\x1b[12"));
    try testing.expectEqual(Decoded{ .key = null, .len = 2 }, first("\x1bO"));
    try testing.expectEqual(Decoded{ .key = null, .len = 1 }, first("\xc3"));
    try testing.expectEqual(Decoded{ .key = null, .len = 1 }, first("\xff"));
}
