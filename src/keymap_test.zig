//! Keymap tests.
//!
//! These run on the host, which matters: dead-key composition and AltGr levels
//! are exactly the kind of logic that is tedious to verify by typing on real
//! hardware, and impossible to verify quickly.

const std = @import("std");
const input = @import("kernel/input.zig");
const keymap = @import("kernel/keymap.zig");

const Mods = input.Modifiers;

fn press(code: input.KeyCode, mods: Mods) keymap.Output {
    return keymap.translate(code, mods);
}

fn expectChar(expected: u21, out: keymap.Output) !void {
    try std.testing.expectEqual(expected, out.codepoint);
}

test "us-international: plain letters and shift" {
    keymap.setLayout(0);
    keymap.resetCompose();
    try expectChar('a', press(.a, .{}));
    try expectChar('A', press(.a, .{ .shift = true }));
    try expectChar('1', press(.n1, .{}));
    try expectChar('!', press(.n1, .{ .shift = true }));
}

test "us-international: dead key composes" {
    keymap.setLayout(0);
    keymap.resetCompose();

    // Apostrophe is dead: it emits nothing and waits.
    const acute = press(.apostrophe, .{});
    try expectChar(0, acute);
    try std.testing.expect(acute.dead_pending);
    try std.testing.expect(keymap.deadPending());

    try expectChar(0xE9, press(.e, .{})); // é
    try std.testing.expect(!keymap.deadPending());
}

test "us-international: dead key followed by space is the literal" {
    keymap.setLayout(0);
    keymap.resetCompose();
    _ = press(.apostrophe, .{});
    try expectChar('\'', press(.space, .{}));
}

test "us-international: dead key that cannot combine emits both" {
    keymap.setLayout(0);
    keymap.resetCompose();
    _ = press(.apostrophe, .{});

    // There is no acute-accented 'q', so the accent and the letter both appear
    // rather than either being swallowed.
    const out = press(.q, .{});
    try expectChar('\'', out);
    try std.testing.expectEqual(@as(u21, 'q'), out.extra);
}

test "us-international: doubling a dead key gives the literal" {
    keymap.setLayout(0);
    keymap.resetCompose();
    _ = press(.apostrophe, .{});
    try expectChar('\'', press(.apostrophe, .{}));
    try std.testing.expect(!keymap.deadPending());
}

test "belgian azerty: letters are transposed" {
    keymap.setLayout(1);
    keymap.resetCompose();
    // The key where Q sits on a US keyboard produces 'a' on AZERTY.
    try expectChar('a', press(.q, .{}));
    try expectChar('z', press(.w, .{}));
    try expectChar('q', press(.a, .{}));
    try expectChar('m', press(.semicolon, .{}));
}

test "belgian azerty: digits need shift" {
    keymap.setLayout(1);
    keymap.resetCompose();
    try expectChar('&', press(.n1, .{}));
    try expectChar('1', press(.n1, .{ .shift = true }));
    try expectChar(0xE9, press(.n2, .{})); // é
    try expectChar('2', press(.n2, .{ .shift = true }));
}

test "belgian azerty: programming symbols live behind altgr" {
    keymap.setLayout(1);
    keymap.resetCompose();
    try expectChar('@', press(.n2, .{ .altgr = true }));
    try expectChar('#', press(.n3, .{ .altgr = true }));
    try expectChar('{', press(.n9, .{ .altgr = true }));
    try expectChar('}', press(.n0, .{ .altgr = true }));
    try expectChar('[', press(.bracket_left, .{ .altgr = true }));
    try expectChar(']', press(.bracket_right, .{ .altgr = true }));
    try expectChar('\\', press(.iso_extra, .{ .altgr = true }));
    try expectChar('|', press(.n1, .{ .altgr = true }));
}

test "caps lock cancels with shift rather than compounding" {
    keymap.setLayout(0);
    keymap.resetCompose();
    try expectChar('A', press(.a, .{ .caps_lock = true }));
    try expectChar('a', press(.a, .{ .caps_lock = true, .shift = true }));
    // Caps Lock must not affect digits or punctuation.
    try expectChar('1', press(.n1, .{ .caps_lock = true }));
}

test "control beats composition" {
    keymap.setLayout(0);
    keymap.resetCompose();
    _ = press(.apostrophe, .{});

    // Ctrl+C is an interrupt, not a candidate for a cedilla.
    try expectChar(3, press(.c, .{ .control = true }));
    try std.testing.expect(!keymap.deadPending());
}

test "every layout defines the keys a shell needs" {
    // A layout missing letters or Enter would be unusable, and the failure
    // would show up as keys silently doing nothing.
    const required = [_]input.KeyCode{
        .a, .b, .c, .z, .n0, .n9, .space, .enter, .backspace, .minus, .period,
    };
    for (0..keymap.layoutCount()) |i| {
        keymap.setLayout(i);
        for (required) |code| {
            keymap.resetCompose();
            const out = keymap.translate(code, .{});
            if (out.codepoint == 0 and !out.dead_pending) {
                std.debug.print("layout '{s}' produces nothing for key .{s}\n", .{
                    keymap.layoutNames(i).?, @tagName(code),
                });
                return error.LayoutIncomplete;
            }
        }
    }
    keymap.setLayout(0);
}
