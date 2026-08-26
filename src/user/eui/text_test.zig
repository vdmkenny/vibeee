//! The text buffer and the line walker, checked on the host.
//!
//! Wrapping and cursor arithmetic are exactly the kind of thing that looks
//! right in a screenshot and is wrong one character from the edge.

const std = @import("std");
const text = @import("text.zig");

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
    var it = text.lines("ab\ncd", 10);
    const first = it.next().?;
    try std.testing.expectEqual(@as(usize, 2), first.end);
    try std.testing.expectEqual(@as(usize, 3), first.next);

    const second = it.next().?;
    try std.testing.expectEqual(@as(usize, 3), second.start);
    try std.testing.expectEqual(@as(usize, 5), second.end);
}

test "wrapping breaks between words" {
    const sample = "hello world";
    var it = text.lines(sample, 8);
    const first = it.next().?;
    try std.testing.expectEqualStrings("hello ", sample[first.start..first.end]);

    const second = it.next().?;
    try std.testing.expectEqualStrings("world", sample[second.start..second.end]);
}

test "a word longer than the line breaks inside it" {
    const sample = "abcdefghij";
    var it = text.lines(sample, 4);
    try std.testing.expectEqualStrings("abcd", sample[it.next().?.start..][0..4]);
}

test "an empty buffer is one line" {
    try std.testing.expectEqual(@as(usize, 1), text.count("", 10));
}

test "a trailing newline leaves an empty line to type on" {
    try std.testing.expectEqual(@as(usize, 2), text.count("a\n", 10));
}

test "an offset maps to the line and column it draws at" {
    const sample = "ab\ncdef";
    try std.testing.expectEqual(
        text.Position{ .line = 0, .column = 1 },
        text.positionOf(sample, 10, 1),
    );
    try std.testing.expectEqual(
        text.Position{ .line = 1, .column = 2 },
        text.positionOf(sample, 10, 5),
    );
}

test "the end of a wrapped line and the start of the next are the same offset" {
    const sample = "hello world";
    const at_break = text.positionOf(sample, 8, 6);
    try std.testing.expectEqual(@as(usize, 1), at_break.line);
    try std.testing.expectEqual(@as(usize, 0), at_break.column);
}

test "a column past the end of a line lands on its end" {
    const sample = "ab\ncdef";
    const line = text.lineAt(sample, 10, 0);
    try std.testing.expectEqual(@as(usize, 2), text.offsetIn(sample, line, 9));
}

test "columns count characters, not bytes" {
    const sample = "\xC3\xA9\xC3\xA9x";
    try std.testing.expectEqual(
        text.Position{ .line = 0, .column = 2 },
        text.positionOf(sample, 10, 4),
    );
}
