//! What a page's bytes are, and turning them into the UTF-8 that everything
//! after the fetch reads.
//!
//! The parser reads UTF-8 and nothing else. Most pages are UTF-8, and most of
//! the rest are windows-1252, which is also what a page labelled ISO-8859-1
//! or ASCII is: the web's encoding standard reads those labels as
//! windows-1252, because the pages that carry them were written on machines
//! that wrote it. Those two are read. A page in any other encoding is read as
//! whichever of the two its bytes fit, and what it has beyond ASCII comes out
//! wrong.
//!
//! Which one a page is follows the order browsers use: a byte-order mark,
//! then what the site said in its answer, then what the page says about
//! itself in its first kilobyte, and failing all of those, UTF-8 where the
//! bytes are valid UTF-8 and windows-1252 where they are not.

const std = @import("std");

pub const Charset = enum { utf8, windows1252 };

/// How far into a page its own `<meta>` is looked for, as browsers do.
const PRESCAN = 1024;

/// The labels the encoding standard gives the two encodings this reads.
const labels = std.StaticStringMapWithEql(Charset, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ "utf-8", .utf8 },
    .{ "utf8", .utf8 },
    .{ "unicode-1-1-utf-8", .utf8 },
    .{ "unicode11utf8", .utf8 },
    .{ "unicode20utf8", .utf8 },
    .{ "x-unicode20utf8", .utf8 },
    .{ "windows-1252", .windows1252 },
    .{ "x-cp1252", .windows1252 },
    .{ "cp1252", .windows1252 },
    .{ "iso-8859-1", .windows1252 },
    .{ "iso8859-1", .windows1252 },
    .{ "iso88591", .windows1252 },
    .{ "iso_8859-1", .windows1252 },
    .{ "iso_8859-1:1987", .windows1252 },
    .{ "iso-ir-100", .windows1252 },
    .{ "csisolatin1", .windows1252 },
    .{ "latin1", .windows1252 },
    .{ "l1", .windows1252 },
    .{ "ibm819", .windows1252 },
    .{ "cp819", .windows1252 },
    .{ "us-ascii", .windows1252 },
    .{ "ascii", .windows1252 },
    .{ "ansi_x3.4-1968", .windows1252 },
});

/// The encoding a label names, or null for one this does not read.
pub fn named(label: []const u8) ?Charset {
    return labels.get(std.mem.trim(u8, label, &std.ascii.whitespace));
}

/// The encoding a `Content-Type` value names: `text/html; charset=ISO-8859-1`.
pub fn fromContentType(value: ?[]const u8) ?Charset {
    return labelled(value orelse return null);
}

/// The encoding a page names for itself in a `<meta>` in its first kilobyte,
/// either way it can say so: `<meta charset="...">`, or the older
/// `<meta http-equiv="Content-Type" content="...; charset=...">`.
pub fn fromMeta(bytes: []const u8) ?Charset {
    const head = bytes[0..@min(bytes.len, PRESCAN)];
    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(head, from, "<meta")) |at| {
        const end = std.mem.indexOfScalarPos(u8, head, at, '>') orelse return null;
        if (labelled(head[at..end])) |found| return found;
        from = end;
    }
    return null;
}

/// What `bytes` are, given what the site said about them, if it said.
pub fn sniff(declared: ?Charset, bytes: []const u8) Charset {
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) return .utf8;
    if (declared) |said| return said;
    if (fromMeta(bytes)) |said| return said;
    return if (std.unicode.utf8ValidateSlice(bytes)) .utf8 else .windows1252;
}

/// A body as UTF-8.
pub const Utf8 = union(enum) {
    /// The bytes as they arrived, which were UTF-8 already.
    same: []const u8,
    /// A decoded copy, which `deinit` gives back.
    decoded: []u8,

    pub fn bytes(self: Utf8) []const u8 {
        return switch (self) {
            .same => |text| text,
            .decoded => |text| text,
        };
    }

    pub fn deinit(self: Utf8, gpa: std.mem.Allocator) void {
        switch (self) {
            .same => {},
            .decoded => |text| gpa.free(text),
        }
    }
};

/// `bytes`, which are in `encoding`, as UTF-8. Copied only where decoding
/// changes them: a UTF-8 body is used as it is, and so is a windows-1252 one
/// that holds nothing but ASCII.
pub fn utf8Of(gpa: std.mem.Allocator, bytes: []const u8, encoding: Charset) error{OutOfMemory}!Utf8 {
    if (encoding == .utf8) return .{ .same = bytes };

    var size: usize = 0;
    for (bytes) |byte| size += std.unicode.utf8CodepointSequenceLength(fromWindows1252(byte)) catch unreachable;
    if (size == bytes.len) return .{ .same = bytes };

    const out = try gpa.alloc(u8, size);
    var at: usize = 0;
    for (bytes) |byte| at += std.unicode.utf8Encode(fromWindows1252(byte), out[at..]) catch unreachable;
    return .{ .decoded = out };
}

/// The windows-1252 byte for a code point, where the encoding has one.
pub fn toWindows1252(code: u21) ?u8 {
    return switch (code) {
        0x00...0x7F, 0xA0...0xFF => @intCast(code),
        else => for (windows1252_high, 0x80..) |high, byte| {
            if (high == code) break @intCast(byte);
        } else null,
    };
}

/// The first `charset=` in `text` that names an encoding this reads.
fn labelled(text: []const u8) ?Charset {
    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, from, "charset")) |at| {
        from = at + "charset".len;
        var i = from;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i == text.len or text[i] != '=') continue;
        i += 1;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '"' or text[i] == '\'')) i += 1;
        const start = i;
        while (i < text.len and isLabelByte(text[i])) i += 1;
        if (named(text[start..i])) |found| return found;
    }
    return null;
}

fn isLabelByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ':' or byte == '.';
}

/// The code point a windows-1252 byte stands for. Below 0x80 and above 0x9F
/// it is the byte's own value, as in ISO-8859-1. Between them are the letters
/// and marks the encoding put there, from the standard's own index.
fn fromWindows1252(byte: u8) u21 {
    return switch (byte) {
        0x80...0x9F => windows1252_high[byte - 0x80],
        else => byte,
    };
}

const windows1252_high = [32]u21{
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

comptime {
    // Every byte stands for a code point UTF-8 can hold, which is why
    // measuring and encoding one above cannot fail.
    @setEvalBranchQuota(10_000);
    for (0..256) |byte| std.debug.assert(std.unicode.utf8ValidCodepoint(fromWindows1252(@intCast(byte))));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the labels browsers read as windows-1252 are read as it" {
    try testing.expectEqual(Charset.windows1252, named("ISO-8859-1").?);
    try testing.expectEqual(Charset.windows1252, named("latin1").?);
    try testing.expectEqual(Charset.windows1252, named("US-ASCII").?);
    try testing.expectEqual(Charset.windows1252, named("cp1252").?);
    try testing.expectEqual(Charset.utf8, named(" utf-8 ").?);
    try testing.expectEqual(@as(?Charset, null), named("shift_jis"));
}

test "a content type's label is found in any case, quoted or not" {
    try testing.expectEqual(Charset.windows1252, fromContentType("text/html; charset=ISO-8859-1").?);
    try testing.expectEqual(Charset.utf8, fromContentType("text/html;CHARSET=\"utf-8\"").?);
    try testing.expectEqual(@as(?Charset, null), fromContentType("text/html"));
    try testing.expectEqual(@as(?Charset, null), fromContentType(null));
}

test "a page names its encoding in either kind of meta" {
    try testing.expectEqual(Charset.utf8, fromMeta("<html><head><meta charset=\"utf-8\"><title>").?);
    try testing.expectEqual(
        Charset.windows1252,
        fromMeta("<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; CHARSET=ISO-8859-1\">").?,
    );
    try testing.expectEqual(@as(?Charset, null), fromMeta("<meta name=\"viewport\" content=\"width=device-width\">"));
}

test "a mark outranks what the site said, which outranks what the page says" {
    try testing.expectEqual(Charset.utf8, sniff(.windows1252, "\xEF\xBB\xBFcaf\xC3\xA9"));
    try testing.expectEqual(Charset.utf8, sniff(.utf8, "<meta charset=latin1>"));
    try testing.expectEqual(Charset.windows1252, sniff(null, "<meta charset=latin1>"));
}

test "a page that says nothing is UTF-8 when its bytes are, and windows-1252 when not" {
    try testing.expectEqual(Charset.utf8, sniff(null, "caf\xC3\xA9"));
    try testing.expectEqual(Charset.windows1252, sniff(null, "caf\xE9"));
}

test "windows-1252 becomes UTF-8, the letters it added included" {
    const text = try utf8Of(testing.allocator, "\xA3329, \x80 caf\xE9 \x93q\x94 1024\xD7600", .windows1252);
    defer text.deinit(testing.allocator);
    try testing.expectEqualStrings("\xC2\xA3329, \xE2\x82\xAC caf\xC3\xA9 \xE2\x80\x9Cq\xE2\x80\x9D 1024\xC3\x97600", text.bytes());
}

test "a letter goes back to its windows-1252 byte where the encoding has one" {
    try testing.expectEqual(@as(?u8, 'a'), toWindows1252('a'));
    try testing.expectEqual(@as(?u8, 0xE9), toWindows1252(0xE9));
    try testing.expectEqual(@as(?u8, 0x80), toWindows1252(0x20AC));
    try testing.expectEqual(@as(?u8, null), toWindows1252(0x2603));
}

test "a body that decoding would not change is not copied" {
    const ascii = try utf8Of(testing.allocator, "plain words", .windows1252);
    try testing.expect(ascii == .same);
    const already = try utf8Of(testing.allocator, "caf\xC3\xA9", .utf8);
    try testing.expect(already == .same);
}
