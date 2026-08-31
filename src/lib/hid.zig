//! What a keyboard and a mouse say, in the boot protocol every one of them
//! speaks.
//!
//! A HID device describes its own reports in a report descriptor, and
//! parsing that is a language of its own. The boot protocol exists so a
//! host need not: a keyboard and a mouse asked for it answer in one fixed
//! shape each, which is exactly enough for a keyboard and a mouse. This
//! file is those two shapes and the table between HID's usage numbers and
//! the keys this system names.
//!
//! Nothing here transfers anything, so all of it can be read and tested
//! on its own.

const std = @import("std");
const KeyCode = @import("syscalls.zig").KeyCode;

/// The interface a boot-protocol device declares.
pub const SUBCLASS_BOOT: u8 = 0x01;

pub const Protocol = enum(u8) {
    /// The device reports whatever its report descriptor says.
    report = 0,
    /// The fixed shapes below.
    boot = 1,
};

pub const BootDevice = enum(u8) {
    none = 0x00,
    keyboard = 0x01,
    mouse = 0x02,
    _,
};

/// Class control requests, which the specification numbers rather than
/// naming.
pub const GET_REPORT: u8 = 0x01;
pub const SET_IDLE: u8 = 0x0A;
pub const SET_PROTOCOL: u8 = 0x0B;

// ---------------------------------------------------------------------------
// The keyboard
// ---------------------------------------------------------------------------

/// HID's own numbering of keys, on the keyboard usage page. Only the ones
/// this system has a key for: a usage with nothing against it is a key
/// this build does not name, and reports as nothing rather than as
/// something wrong.
const USAGES = [_]struct { u8, KeyCode }{
    .{ 0x04, .a },  .{ 0x05, .b },  .{ 0x06, .c },  .{ 0x07, .d },
    .{ 0x08, .e },  .{ 0x09, .f },  .{ 0x0A, .g },  .{ 0x0B, .h },
    .{ 0x0C, .i },  .{ 0x0D, .j },  .{ 0x0E, .k },  .{ 0x0F, .l },
    .{ 0x10, .m },  .{ 0x11, .n },  .{ 0x12, .o },  .{ 0x13, .p },
    .{ 0x14, .q },  .{ 0x15, .r },  .{ 0x16, .s },  .{ 0x17, .t },
    .{ 0x18, .u },  .{ 0x19, .v },  .{ 0x1A, .w },  .{ 0x1B, .x },
    .{ 0x1C, .y },  .{ 0x1D, .z },

    .{ 0x1E, .n1 }, .{ 0x1F, .n2 }, .{ 0x20, .n3 }, .{ 0x21, .n4 },
    .{ 0x22, .n5 }, .{ 0x23, .n6 }, .{ 0x24, .n7 }, .{ 0x25, .n8 },
    .{ 0x26, .n9 }, .{ 0x27, .n0 },

    .{ 0x28, .enter },         .{ 0x29, .escape },
    .{ 0x2A, .backspace },     .{ 0x2B, .tab },
    .{ 0x2C, .space },         .{ 0x2D, .minus },
    .{ 0x2E, .equal },         .{ 0x2F, .bracket_left },
    .{ 0x30, .bracket_right }, .{ 0x31, .backslash },
    // The key ISO keyboards put where ANSI puts nothing, which some
    // devices report here and some at 0x64.
    .{ 0x32, .backslash },
    .{ 0x33, .semicolon },     .{ 0x34, .apostrophe },
    .{ 0x35, .grave },         .{ 0x36, .comma },
    .{ 0x37, .period },        .{ 0x38, .slash },
    .{ 0x39, .caps_lock },

    .{ 0x3A, .f1 },  .{ 0x3B, .f2 },  .{ 0x3C, .f3 },  .{ 0x3D, .f4 },
    .{ 0x3E, .f5 },  .{ 0x3F, .f6 },  .{ 0x40, .f7 },  .{ 0x41, .f8 },
    .{ 0x42, .f9 },  .{ 0x43, .f10 }, .{ 0x44, .f11 }, .{ 0x45, .f12 },

    .{ 0x47, .scroll_lock },
    .{ 0x49, .insert },    .{ 0x4A, .home },
    .{ 0x4B, .page_up },   .{ 0x4C, .delete },
    .{ 0x4D, .end },       .{ 0x4E, .page_down },
    .{ 0x4F, .right },     .{ 0x50, .left },
    .{ 0x51, .down },      .{ 0x52, .up },

    .{ 0x53, .num_lock },      .{ 0x54, .kp_slash },
    .{ 0x55, .keypad_asterisk }, .{ 0x56, .kp_minus },
    .{ 0x57, .kp_plus },       .{ 0x58, .kp_enter },
    .{ 0x59, .kp1 }, .{ 0x5A, .kp2 }, .{ 0x5B, .kp3 },
    .{ 0x5C, .kp4 }, .{ 0x5D, .kp5 }, .{ 0x5E, .kp6 },
    .{ 0x5F, .kp7 }, .{ 0x60, .kp8 }, .{ 0x61, .kp9 },
    .{ 0x62, .kp0 }, .{ 0x63, .kp_period },

    // The extra key beside the left shift, which AZERTY needs.
    .{ 0x64, .iso_extra },
    .{ 0x65, .menu },

    .{ 0xE0, .control_left },  .{ 0xE1, .shift_left },
    .{ 0xE2, .alt_left },      .{ 0xE3, .super_left },
    .{ 0xE4, .control_right }, .{ 0xE5, .shift_right },
    .{ 0xE6, .alt_right },     .{ 0xE7, .super_right },
};

/// The table as a lookup, built once at compile time. A branch per key
/// would be a two hundred way switch on the hot path of every keystroke;
/// this is one load.
const TABLE: [256]KeyCode = blk: {
    var table: [256]KeyCode = @splat(.none);
    for (USAGES) |pair| table[pair[0]] = pair[1];
    break :blk table;
};

/// The key a HID usage number means, or none for one this build does not
/// name.
pub fn keyFor(usage: u8) KeyCode {
    return TABLE[usage];
}

/// The modifier byte every boot keyboard report starts with. The order is
/// the specification's: the left-hand keys, then the right.
pub const Mods = packed struct(u8) {
    control_left: bool = false,
    shift_left: bool = false,
    alt_left: bool = false,
    super_left: bool = false,
    control_right: bool = false,
    shift_right: bool = false,
    alt_right: bool = false,
    super_right: bool = false,

    /// The usage number of each bit, in the order they are declared, so a
    /// modifier travels the same path as every other key.
    pub const USAGE_BASE: u8 = 0xE0;

    pub fn held(self: Mods, index: u3) bool {
        return (@as(u8, @bitCast(self)) >> index) & 1 == 1;
    }
};

/// How many keys a boot report can hold at once, and what a keyboard
/// answers with when more than that are down.
pub const ROLLOVER = 6;
pub const TOO_MANY_KEYS: u8 = 0x01;

/// One boot keyboard report: eight bytes, a modifier byte, a byte the
/// specification reserves, and six key slots.
pub const Keys = struct {
    mods: Mods = .{},
    down: [ROLLOVER]u8 = @splat(0),

    pub const BYTES = 8;

    pub fn parse(bytes: []const u8) ?Keys {
        if (bytes.len < BYTES) return null;
        var self = Keys{ .mods = @bitCast(bytes[0]) };
        @memcpy(&self.down, bytes[2..8]);
        return self;
    }

    /// Whether a usage is among the keys currently down.
    pub fn holds(self: Keys, usage: u8) bool {
        for (self.down) |key| {
            if (key == usage) return true;
        }
        return false;
    }

    /// Whether the keyboard gave up counting, which happens when more keys
    /// are down than it can report. Nothing may be concluded from such a
    /// report except that the previous one still stands.
    pub fn overflowed(self: Keys) bool {
        return self.down[0] == TOO_MANY_KEYS;
    }
};

/// What changed between two reports, which is the only thing a keyboard
/// actually tells you: a report says what is down, and a keystroke is the
/// difference between one report and the next.
pub const Change = struct {
    usage: u8,
    pressed: bool,
};

/// Walk the differences between the previous report and this one. Presses
/// and releases both, modifiers included, in a fixed order so the same two
/// reports always produce the same keystrokes.
pub const Changes = struct {
    was: Keys,
    now: Keys,
    at: usize = 0,

    pub fn next(self: *Changes) ?Change {
        // The modifiers first, so a shift that arrived with a letter is
        // already down when the letter is handled.
        while (self.at < 8) {
            const index: u3 = @intCast(self.at);
            self.at += 1;
            const before = self.was.mods.held(index);
            const after = self.now.mods.held(index);
            if (before != after) {
                return .{ .usage = Mods.USAGE_BASE + index, .pressed = after };
            }
        }

        // Then the releases: a key that went up before another went down
        // should be reported that way round.
        while (self.at < 8 + ROLLOVER) {
            const usage = self.was.down[self.at - 8];
            self.at += 1;
            if (usage > TOO_MANY_KEYS and !self.now.holds(usage)) {
                return .{ .usage = usage, .pressed = false };
            }
        }

        while (self.at < 8 + 2 * ROLLOVER) {
            const usage = self.now.down[self.at - 8 - ROLLOVER];
            self.at += 1;
            if (usage > TOO_MANY_KEYS and !self.was.holds(usage)) {
                return .{ .usage = usage, .pressed = true };
            }
        }
        return null;
    }
};

/// What happened between two reports. An overflowed report says nothing
/// except that the keyboard lost count, so it changes nothing.
pub fn changes(was: Keys, now: Keys) Changes {
    if (now.overflowed()) return .{ .was = was, .now = was };
    return .{ .was = was, .now = now };
}

// ---------------------------------------------------------------------------
// The mouse
// ---------------------------------------------------------------------------

/// The button byte a boot mouse report starts with.
pub const MouseButtons = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    _3: u5 = 0,
};

/// One boot mouse report: buttons, then movement, then a wheel if the
/// device has one. Three bytes at least, and devices that add a wheel put
/// it fourth, which is the one extension the boot protocol tolerates.
pub const Motion = struct {
    buttons: MouseButtons = .{},
    dx: i8 = 0,
    dy: i8 = 0,
    wheel: i8 = 0,

    pub const BYTES = 3;

    pub fn parse(bytes: []const u8) ?Motion {
        if (bytes.len < BYTES) return null;
        return .{
            .buttons = @bitCast(bytes[0]),
            .dx = @bitCast(bytes[1]),
            .dy = @bitCast(bytes[2]),
            .wheel = if (bytes.len > 3) @bitCast(bytes[3]) else 0,
        };
    }

    pub fn moved(self: Motion) bool {
        return self.dx != 0 or self.dy != 0 or self.wheel != 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the usage table names the keys this system has and nothing else" {
    try std.testing.expectEqual(KeyCode.a, keyFor(0x04));
    try std.testing.expectEqual(KeyCode.z, keyFor(0x1D));
    try std.testing.expectEqual(KeyCode.n1, keyFor(0x1E));
    try std.testing.expectEqual(KeyCode.n0, keyFor(0x27));
    try std.testing.expectEqual(KeyCode.enter, keyFor(0x28));
    try std.testing.expectEqual(KeyCode.space, keyFor(0x2C));
    try std.testing.expectEqual(KeyCode.f12, keyFor(0x45));
    try std.testing.expectEqual(KeyCode.up, keyFor(0x52));
    try std.testing.expectEqual(KeyCode.iso_extra, keyFor(0x64));
    try std.testing.expectEqual(KeyCode.control_left, keyFor(0xE0));
    try std.testing.expectEqual(KeyCode.super_right, keyFor(0xE7));

    // Nothing where the specification puts nothing.
    try std.testing.expectEqual(KeyCode.none, keyFor(0x00));
    try std.testing.expectEqual(KeyCode.none, keyFor(TOO_MANY_KEYS));
    try std.testing.expectEqual(KeyCode.none, keyFor(0xFF));
}

test "a boot keyboard report is read, and a short one refused" {
    const report = [_]u8{ 0x02, 0x00, 0x04, 0x05, 0, 0, 0, 0 };
    const keys = Keys.parse(&report) orelse return error.TestUnexpectedResult;

    try std.testing.expect(keys.mods.shift_left);
    try std.testing.expect(!keys.mods.control_left);
    try std.testing.expect(keys.holds(0x04));
    try std.testing.expect(keys.holds(0x05));
    try std.testing.expect(!keys.holds(0x06));
    try std.testing.expect(!keys.overflowed());

    try std.testing.expect(Keys.parse(report[0..7]) == null);
}

test "a keystroke is the difference between two reports" {
    const nothing = Keys{};
    const pressed_a = Keys.parse(&[_]u8{ 0, 0, 0x04, 0, 0, 0, 0, 0 }).?;

    var down = changes(nothing, pressed_a);
    const first = down.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0x04), first.usage);
    try std.testing.expect(first.pressed);
    try std.testing.expect(down.next() == null);

    // Holding it produces nothing at all: the report is the same.
    var held = changes(pressed_a, pressed_a);
    try std.testing.expect(held.next() == null);

    var up = changes(pressed_a, nothing);
    const release = up.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0x04), release.usage);
    try std.testing.expect(!release.pressed);
    try std.testing.expect(up.next() == null);
}

test "a modifier arriving with a letter is reported before it" {
    const nothing = Keys{};
    // Left shift and 'a' in the same report.
    const both = Keys.parse(&[_]u8{ 0x02, 0, 0x04, 0, 0, 0, 0, 0 }).?;

    var walk = changes(nothing, both);
    const shift = walk.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(KeyCode.shift_left, keyFor(shift.usage));
    try std.testing.expect(shift.pressed);

    const letter = walk.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(KeyCode.a, keyFor(letter.usage));
    try std.testing.expect(letter.pressed);
    try std.testing.expect(walk.next() == null);
}

test "a release is reported before a press in the same report" {
    const was = Keys.parse(&[_]u8{ 0, 0, 0x04, 0, 0, 0, 0, 0 }).?;
    const now = Keys.parse(&[_]u8{ 0, 0, 0x05, 0, 0, 0, 0, 0 }).?;

    var walk = changes(was, now);
    const first = walk.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0x04), first.usage);
    try std.testing.expect(!first.pressed);

    const second = walk.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0x05), second.usage);
    try std.testing.expect(second.pressed);
    try std.testing.expect(walk.next() == null);
}

test "a keyboard that lost count changes nothing" {
    const held = Keys.parse(&[_]u8{ 0, 0, 0x04, 0x05, 0, 0, 0, 0 }).?;
    const lost = Keys.parse(&[_]u8{ 0, 0, TOO_MANY_KEYS, TOO_MANY_KEYS, TOO_MANY_KEYS, TOO_MANY_KEYS, TOO_MANY_KEYS, TOO_MANY_KEYS }).?;

    try std.testing.expect(lost.overflowed());
    var walk = changes(held, lost);
    try std.testing.expect(walk.next() == null);
}

test "several keys at once each produce their own keystroke" {
    const nothing = Keys{};
    const three = Keys.parse(&[_]u8{ 0, 0, 0x04, 0x16, 0x07, 0, 0, 0 }).?;

    var walk = changes(nothing, three);
    var seen: [3]KeyCode = @splat(.none);
    for (&seen) |*slot| {
        const change = walk.next() orelse return error.TestUnexpectedResult;
        try std.testing.expect(change.pressed);
        slot.* = keyFor(change.usage);
    }
    try std.testing.expect(walk.next() == null);
    try std.testing.expectEqualSlices(KeyCode, &.{ .a, .s, .d }, &seen);
}

test "a boot mouse report is read, with or without a wheel" {
    const three = [_]u8{ 0x01, 5, 0xFB };
    const plain = Motion.parse(&three) orelse return error.TestUnexpectedResult;
    try std.testing.expect(plain.buttons.left);
    try std.testing.expect(!plain.buttons.right);
    try std.testing.expectEqual(@as(i8, 5), plain.dx);
    try std.testing.expectEqual(@as(i8, -5), plain.dy);
    try std.testing.expectEqual(@as(i8, 0), plain.wheel);
    try std.testing.expect(plain.moved());

    const four = [_]u8{ 0x06, 0, 0, 0xFF };
    const wheeled = Motion.parse(&four) orelse return error.TestUnexpectedResult;
    try std.testing.expect(wheeled.buttons.right);
    try std.testing.expect(wheeled.buttons.middle);
    try std.testing.expectEqual(@as(i8, -1), wheeled.wheel);
    try std.testing.expect(wheeled.moved());

    const still = Motion.parse(&[_]u8{ 0, 0, 0 }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!still.moved());

    try std.testing.expect(Motion.parse(&[_]u8{ 0, 0 }) == null);
}

test "the modifier byte's bits are where the specification puts them" {
    try std.testing.expectEqual(@as(u8, 0x01), @as(u8, @bitCast(Mods{ .control_left = true })));
    try std.testing.expectEqual(@as(u8, 0x02), @as(u8, @bitCast(Mods{ .shift_left = true })));
    try std.testing.expectEqual(@as(u8, 0x40), @as(u8, @bitCast(Mods{ .alt_right = true })));
    try std.testing.expectEqual(@as(u8, 0x80), @as(u8, @bitCast(Mods{ .super_right = true })));

    // Every bit's usage number is its index above the base, which is what
    // lets a modifier travel the same path as every other key.
    inline for (0..8) |i| {
        const bit: u3 = @intCast(i);
        const only: Mods = @bitCast(@as(u8, 1) << bit);
        try std.testing.expect(only.held(bit));
        try std.testing.expect(keyFor(Mods.USAGE_BASE + bit) != .none);
    }
    try std.testing.expectEqual(@as(u8, 0x04), @as(u8, @bitCast(MouseButtons{ .middle = true })));
}
