//! The text buffer and the line walker, checked on the host.
//!
//! Wrapping and cursor arithmetic are exactly the kind of thing that looks
//! right in a screenshot and is wrong one character from the edge.

const std = @import("std");
const font = @import("lib").font;
const text = @import("text.zig");

/// A monospaced face, so a width in pixels reads as a count of characters and
/// the expectations below say what they mean. The control itself uses the
/// proportional interface face; what is under test is the arithmetic, and it
/// is the same arithmetic either way.
const mono = &font.spleen_8x16;
const CELL: i32 = 8;

fn columns(n: i32) i32 {
    return n * CELL;
}

fn buffer(storage: []u8, initial: []const u8) text.Buffer {
    var b = text.Buffer{ .bytes = storage };
    _ = b.insert(0, initial);
    return b;
}

test "insert puts text where it is asked to" {
    var storage: [64]u8 = undefined;
    var b = buffer(&storage, "helo");
    _ = b.insert(3, "l");
    try std.testing.expectEqualStrings("hello", b.slice());
}

test "insert refuses rather than truncating" {
    var storage: [4]u8 = undefined;
    var b = text.Buffer{ .bytes = &storage };
    try std.testing.expect(b.insert(0, "abcd"));
    try std.testing.expect(!b.insert(0, "e"));
    try std.testing.expectEqualStrings("abcd", b.slice());
}

test "remove closes the gap" {
    var storage: [64]u8 = undefined;
    var b = buffer(&storage, "abcdef");
    b.remove(2, 4);
    try std.testing.expectEqualStrings("abef", b.slice());
}

test "moving by character steps over a whole UTF-8 sequence" {
    var storage: [64]u8 = undefined;
    var b = buffer(&storage, "a\xC3\xA9b");

    try std.testing.expectEqual(@as(usize, 1), b.after(0));
    try std.testing.expectEqual(@as(usize, 3), b.after(1));
    try std.testing.expectEqual(@as(usize, 1), b.before(3));
}

test "a hard newline ends a line and is not shown" {
    var it = text.lines("ab\ncd", mono, columns(10));
    const first = it.next().?;
    try std.testing.expectEqual(@as(usize, 2), first.end);
    try std.testing.expectEqual(@as(usize, 3), first.next);

    const second = it.next().?;
    try std.testing.expectEqual(@as(usize, 3), second.start);
    try std.testing.expectEqual(@as(usize, 5), second.end);
}

test "wrapping breaks between words" {
    const sample = "hello world";
    var it = text.lines(sample, mono, columns(8));
    const first = it.next().?;
    try std.testing.expectEqualStrings("hello ", sample[first.start..first.end]);

    const second = it.next().?;
    try std.testing.expectEqualStrings("world", sample[second.start..second.end]);
}

test "a word longer than the line breaks inside it" {
    const sample = "abcdefghij";
    var it = text.lines(sample, mono, columns(4));
    try std.testing.expectEqualStrings("abcd", sample[it.next().?.start..][0..4]);
}

test "an empty buffer is one line" {
    try std.testing.expectEqual(@as(usize, 1), text.count("", mono, columns(10)));
}

test "a trailing newline leaves an empty line to type on" {
    try std.testing.expectEqual(@as(usize, 2), text.count("a\n", mono, columns(10)));
}

test "an offset maps to the line and place it draws at" {
    const sample = "ab\ncdef";
    try std.testing.expectEqual(
        text.Position{ .line = 0, .x = columns(1) },
        text.positionOf(sample, mono, columns(10), 1),
    );
    try std.testing.expectEqual(
        text.Position{ .line = 1, .x = columns(2) },
        text.positionOf(sample, mono, columns(10), 5),
    );
}

test "the end of a wrapped line and the start of the next are the same offset" {
    const sample = "hello world";
    const at_break = text.positionOf(sample, mono, columns(8), 6);
    try std.testing.expectEqual(@as(usize, 1), at_break.line);
    try std.testing.expectEqual(@as(i32, 0), at_break.x);
}

test "a click past the end of a line lands on its end" {
    const sample = "ab\ncdef";
    const line = text.lineAt(sample, mono, columns(10), 0);
    try std.testing.expectEqual(@as(usize, 2), text.offsetAt(sample, mono, line, columns(9)));
}

test "a click on the right half of a character puts the cursor after it" {
    const sample = "abc";
    const line = text.lineAt(sample, mono, columns(10), 0);
    try std.testing.expectEqual(@as(usize, 0), text.offsetAt(sample, mono, line, 3));
    try std.testing.expectEqual(@as(usize, 1), text.offsetAt(sample, mono, line, 5));
}

test "measuring counts characters, not bytes" {
    const sample = "\xC3\xA9\xC3\xA9x";
    try std.testing.expectEqual(
        text.Position{ .line = 0, .x = columns(2) },
        text.positionOf(sample, mono, columns(10), 4),
    );
}

test "the cursor after a trailing newline is on the new line, not the old one" {
    const sample = "abc\n";
    try std.testing.expectEqual(
        text.Position{ .line = 1, .x = 0 },
        text.positionOf(sample, mono, columns(20), 4),
    );
}

test "the cursor at the end of text without a newline stays on the last line" {
    const sample = "abc";
    try std.testing.expectEqual(
        text.Position{ .line = 0, .x = columns(3) },
        text.positionOf(sample, mono, columns(20), 3),
    );
}

test "the cursor on an empty line between two others" {
    const sample = "a\n\nb";
    try std.testing.expectEqual(
        text.Position{ .line = 1, .x = 0 },
        text.positionOf(sample, mono, columns(20), 2),
    );
}
