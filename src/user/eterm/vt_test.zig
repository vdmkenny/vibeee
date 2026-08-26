//! The emulator, checked on the host.
//!
//! The whole reason `screen.zig`, `parser.zig` and `vt.zig` know nothing about
//! windows or syscalls: an escape sequence that does the wrong thing is very
//! hard to see in a screenshot of a terminal and trivial to see here.

const std = @import("std");
const screen = @import("screen.zig");
const vt = @import("vt.zig");

fn terminal(cols: usize, rows: usize) vt.Terminal {
    var t: vt.Terminal = undefined;
    t.init();
    t.resize(cols, rows);
    return t;
}

/// The text of one row, trimmed of trailing blanks.
fn line(t: *vt.Terminal, row: usize, out: []u8) []const u8 {
    const cells = t.active().row(row);
    var n: usize = 0;
    for (cells) |cell| {
        // Zero is the blank cell, which reads back as the space it draws as.
        out[n] = if (cell.ch == 0) ' ' else if (cell.ch < 128) @intCast(cell.ch) else '?';
        n += 1;
    }
    while (n > 0 and out[n - 1] == ' ') n -= 1;
    return out[0..n];
}

fn expectLine(t: *vt.Terminal, row: usize, want: []const u8) !void {
    var buf: [screen.MAX_COLS]u8 = undefined;
    try std.testing.expectEqualStrings(want, line(t, row, &buf));
}

test "printing advances the cursor" {
    var t = terminal(20, 4);
    t.write("hello");
    try expectLine(&t, 0, "hello");
    try std.testing.expectEqual(@as(usize, 5), t.cursor.col);
}

test "a line that fills the row wraps on the next character, not before" {
    var t = terminal(5, 3);
    t.write("abcde");
    // Still on the first row: the wrap is pending, not taken.
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
    try std.testing.expect(t.cursor.wrap_pending);

    t.write("f");
    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);
    try expectLine(&t, 0, "abcde");
    try expectLine(&t, 1, "f");
}

test "a carriage return after filling a row does not scroll" {
    var t = terminal(5, 3);
    t.write("abcde\rx");
    try expectLine(&t, 0, "xbcde");
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
}

test "a line feed at the bottom scrolls" {
    var t = terminal(10, 3);
    t.write("one\r\ntwo\r\nthree\r\nfour");
    try expectLine(&t, 0, "two");
    try expectLine(&t, 1, "three");
    try expectLine(&t, 2, "four");
}

test "cursor addressing is one-based" {
    var t = terminal(10, 5);
    t.write("\x1B[3;4Hx");
    try std.testing.expectEqual(@as(usize, 2), t.cursor.row);
    try expectLine(&t, 2, "   x");
}

test "an omitted parameter means one" {
    var t = terminal(10, 5);
    t.write("\x1B[5;5H\x1B[Hx");
    try expectLine(&t, 0, "x");
}

test "erase to end of line leaves what came before" {
    var t = terminal(10, 2);
    t.write("abcdef\x1B[1;4H\x1B[K");
    try expectLine(&t, 0, "abc");
}

test "erase the display clears every row" {
    var t = terminal(10, 3);
    t.write("a\r\nb\r\nc\x1B[2J");
    try expectLine(&t, 0, "");
    try expectLine(&t, 2, "");
}

test "insert and delete characters shift the rest of the line" {
    var t = terminal(10, 2);
    t.write("abcdef\x1B[1;2H\x1B[2P");
    try expectLine(&t, 0, "adef");

    t.write("\x1B[1;2H\x1B[2@");
    try expectLine(&t, 0, "a  def");
}

test "a scrolling region scrolls only inside itself" {
    var t = terminal(10, 5);
    t.write("1\r\n2\r\n3\r\n4\r\n5");
    t.write("\x1B[2;4r");
    // Setting a region homes the cursor to its top.
    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);

    t.write("\x1B[4;1Hx\n");
    try expectLine(&t, 0, "1");
    try expectLine(&t, 4, "5");
}

test "colours are taken from SGR and reset by zero" {
    var t = terminal(10, 2);
    t.write("\x1B[31ma\x1B[0mb");

    const red = t.active().at(0, 0);
    try std.testing.expectEqual(@as(u8, 1), red.fg);
    try std.testing.expect(red.style.has_fg);

    const plain = t.active().at(0, 1);
    try std.testing.expect(!plain.style.has_fg);
}

test "bright colours and 256-colour indices both land" {
    var t = terminal(10, 2);
    t.write("\x1B[92ma\x1B[38;5;200mb");
    try std.testing.expectEqual(@as(u8, 10), t.active().at(0, 0).fg);
    try std.testing.expectEqual(@as(u8, 200), t.active().at(0, 1).fg);
}

test "attributes accumulate and clear individually" {
    var t = terminal(10, 2);
    t.write("\x1B[1;4ma\x1B[24mb");
    try std.testing.expect(t.active().at(0, 0).style.bold);
    try std.testing.expect(t.active().at(0, 0).style.underline);
    try std.testing.expect(t.active().at(0, 1).style.bold);
    try std.testing.expect(!t.active().at(0, 1).style.underline);
}

test "the alternate screen keeps the primary intact" {
    var t = terminal(10, 3);
    t.write("shell output");
    t.write("\x1B[?1049h");
    t.write("full screen program");
    try expectLine(&t, 0, "full scree");

    t.write("\x1B[?1049l");
    try expectLine(&t, 0, "shell outp");
}

test "a cursor position report answers with the position" {
    var t = terminal(20, 5);
    t.write("\x1B[3;7H\x1B[6n");
    try std.testing.expectEqualStrings("\x1B[3;7R", t.takeReply());
}

test "a sequence split across writes still parses" {
    var t = terminal(10, 3);
    t.write("\x1B");
    t.write("[2");
    t.write(";3");
    t.write("Hx");
    try expectLine(&t, 1, "  x");
}

test "UTF-8 split across writes produces one character" {
    var t = terminal(10, 2);
    t.write("\xE2\x94");
    t.write("\x80");
    try std.testing.expectEqual(@as(u32, 0x2500), t.active().at(0, 0).ch);
}

test "an unknown sequence is dropped rather than printed" {
    var t = terminal(10, 2);
    t.write("\x1B[?9999hx");
    try expectLine(&t, 0, "x");
}

test "a title arrives through OSC" {
    var t = terminal(10, 2);
    t.write("\x1B]0;build\x07");
    try std.testing.expect(t.title_changed);
    try std.testing.expectEqualStrings("build", t.title[0..t.title_len]);
}

test "backspace over a pending wrap stays on the line" {
    var t = terminal(3, 2);
    t.write("abc\x08x");
    try expectLine(&t, 0, "abx");
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
}

test "tabs land on eight-column stops" {
    var t = terminal(20, 2);
    t.write("a\tb");
    try expectLine(&t, 0, "a       b");
}

test "reset returns the terminal to its starting state" {
    var t = terminal(10, 3);
    t.write("\x1B[31m\x1B[?1049hjunk\x1Bc");
    try std.testing.expect(!t.on_alternate);
    try std.testing.expect(!t.cursor.pen.style.has_fg);
    try expectLine(&t, 0, "");
}

// ---------------------------------------------------------------------------
// Key encoding
// ---------------------------------------------------------------------------

const keys = @import("keys.zig");
const abi = @import("lib").syscalls;

fn pressed(code: abi.KeyCode, mods: abi.Modifiers, application: bool) []const u8 {
    const buf = struct {
        var storage: [keys.MAX]u8 = undefined;
    };
    return keys.key(code, mods, application, &buf.storage);
}

fn typed(cp: u32, mods: abi.Modifiers) []const u8 {
    const buf = struct {
        var storage: [keys.MAX]u8 = undefined;
    };
    return keys.text(cp, mods, &buf.storage);
}

test "arrow keys switch form with application cursor mode" {
    try std.testing.expectEqualStrings("\x1B[A", pressed(.up, .{}, false));
    try std.testing.expectEqualStrings("\x1BOA", pressed(.up, .{}, true));
}

test "a modified arrow key is always CSI, with the modifier as a parameter" {
    try std.testing.expectEqualStrings("\x1B[1;5C", pressed(.right, .{ .control = true }, true));
    try std.testing.expectEqualStrings("\x1B[1;2D", pressed(.left, .{ .shift = true }, false));
}

test "the numbered keys carry their number" {
    try std.testing.expectEqualStrings("\x1B[5~", pressed(.page_up, .{}, false));
    try std.testing.expectEqualStrings("\x1B[3~", pressed(.delete, .{}, false));
    try std.testing.expectEqualStrings("\x1B[15~", pressed(.f5, .{}, false));
}

test "the first four function keys are SS3" {
    try std.testing.expectEqualStrings("\x1BOP", pressed(.f1, .{}, false));
}

test "backspace sends DEL and enter sends CR" {
    try std.testing.expectEqualStrings("\x7F", pressed(.backspace, .{}, false));
    try std.testing.expectEqualStrings("\r", pressed(.enter, .{}, false));
}

test "shift and tab is its own sequence" {
    try std.testing.expectEqualStrings("\t", pressed(.tab, .{}, false));
    try std.testing.expectEqualStrings("\x1B[Z", pressed(.tab, .{ .shift = true }, false));
}

test "control chords follow the character, not the key" {
    try std.testing.expectEqualStrings("\x03", typed('c', .{ .control = true }));
    try std.testing.expectEqualStrings("\x03", typed('C', .{ .control = true }));
    try std.testing.expectEqualStrings("\x1B", typed('[', .{ .control = true }));
}

test "alt prefixes with escape" {
    try std.testing.expectEqualStrings("\x1Bx", typed('x', .{ .alt = true }));
    try std.testing.expectEqualStrings("\x1B\x18", typed('x', .{ .alt = true, .control = true }));
}

test "a character above ASCII goes out as UTF-8" {
    try std.testing.expectEqualStrings("\xC3\xA9", typed(0xE9, .{}));
}

test "a control chord with no control code sends nothing" {
    try std.testing.expectEqualStrings("", typed('5', .{ .control = true }));
}

test "a line feed returns the carriage, since no pty will" {
    var t = terminal(10, 3);
    t.write("ab\ncd");
    try expectLine(&t, 0, "ab");
    try expectLine(&t, 1, "cd");
}

test "newline mode can be turned off" {
    var t = terminal(10, 3);
    t.write("\x1B[20lab\ncd");
    try expectLine(&t, 0, "ab");
    try expectLine(&t, 1, "  cd");
}

test "insert mode shifts rather than overwrites" {
    var t = terminal(10, 2);
    t.write("abcd\x1B[1;2H\x1B[4hXY");
    try expectLine(&t, 0, "aXYbcd");
}

test "a terminal has a usable size before it is told one" {
    var t: vt.Terminal = undefined;
    t.init();
    t.write("output before the first configure");
    try expectLine(&t, 0, "output before the first configure");
}
