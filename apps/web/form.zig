//! A form's answers, written the way forms send them.
//!
//! `application/x-www-form-urlencoded`: each name and value in the page's own
//! encoding, letters, digits and four marks as they are, a space as a plus,
//! and every other byte as a percent sign and two hex digits. A letter the
//! page's encoding cannot hold is sent as the character reference a browser
//! sends in its place, `&#`, its number and `;`, which is what a site that
//! reads that encoding expects to find.

const std = @import("std");
const charset = @import("charset.zig");

const Writer = std.Io.Writer;

/// One answer, after any before it: `name=value`, joined to them by `&`.
pub fn writeAnswer(w: *Writer, first: bool, name: []const u8, value: []const u8, encoding: charset.Charset) Writer.Error!void {
    if (!first) try w.writeByte('&');
    try writeEncoded(w, name, encoding);
    try w.writeByte('=');
    try writeEncoded(w, value, encoding);
}

/// `text`, which is UTF-8, in `encoding` and escaped.
fn writeEncoded(w: *Writer, text: []const u8, encoding: charset.Charset) Writer.Error!void {
    const view = std.unicode.Utf8View.init(text) catch return writeBytes(w, text);
    switch (encoding) {
        .utf8 => try writeBytes(w, text),
        .windows1252 => {
            var codes = view.iterator();
            while (codes.nextCodepoint()) |code| {
                if (charset.toWindows1252(code)) |byte| {
                    try writeByte(w, byte);
                } else {
                    var reference: [16]u8 = undefined;
                    try writeBytes(w, std.fmt.bufPrint(&reference, "&#{d};", .{code}) catch unreachable);
                }
            }
        },
    }
}

fn writeBytes(w: *Writer, bytes: []const u8) Writer.Error!void {
    for (bytes) |byte| try writeByte(w, byte);
}

fn writeByte(w: *Writer, byte: u8) Writer.Error!void {
    switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '*', '-', '.', '_' => try w.writeByte(byte),
        ' ' => try w.writeByte('+'),
        else => try w.print("%{X:0>2}", .{byte}),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn answers(pairs: []const [2][]const u8, encoding: charset.Charset) ![]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    var w: Writer = .fixed(&S.buf);
    for (pairs, 0..) |pair, i| try writeAnswer(&w, i == 0, pair[0], pair[1], encoding);
    return w.buffered();
}

test "a space is a plus, and every other mark but four is escaped" {
    try testing.expectEqualStrings(
        "q=eee+pc+%26+more&t=848d6d9e",
        try answers(&.{ .{ "q", "eee pc & more" }, .{ "t", "848d6d9e" } }, .utf8),
    );
    try testing.expectEqualStrings("a=x*y-z._%2F%3F", try answers(&.{.{ "a", "x*y-z._/?" }}, .utf8));
}

test "the page's encoding decides the bytes a letter is sent as" {
    try testing.expectEqualStrings("q=caf%C3%A9", try answers(&.{.{ "q", "caf\xC3\xA9" }}, .utf8));
    try testing.expectEqualStrings("q=caf%E9+%80", try answers(&.{.{ "q", "caf\xC3\xA9 \xE2\x82\xAC" }}, .windows1252));
}

test "a letter the encoding cannot hold is sent as a reference to it" {
    try testing.expectEqualStrings("q=%26%239731%3B", try answers(&.{.{ "q", "\xE2\x98\x83" }}, .windows1252));
}
