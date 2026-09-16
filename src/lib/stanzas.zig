//! Text files of `key = value` records: a blank line between records, `#`
//! comments anywhere. `etc/services`, `etc/openers` and the driver manifests
//! are written this way.

const std = @import("std");
const str = @import("str.zig");

pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

/// Split a `key = value` line. Null for a comment, a blank line, or anything
/// without a separator.
pub fn pair(line: []const u8) ?Pair {
    const text = str.trim(line);
    if (text.len == 0 or text[0] == '#') return null;
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    return .{ .key = str.trim(text[0..equals]), .value = str.trim(text[equals + 1 ..]) };
}

/// The records of a file in order, each with the blank lines that follow it,
/// so the records laid end to end are the file.
pub fn records(text: []const u8) Records {
    return .{ .rest = text };
}

pub const Records = struct {
    rest: []const u8,

    pub fn next(self: *Records) ?[]const u8 {
        if (self.rest.len == 0) return null;
        var at: usize = 0;
        var in_record = false;
        var ended = false;
        while (at < self.rest.len) {
            const end = if (std.mem.indexOfScalarPos(u8, self.rest, at, '\n')) |newline| newline + 1 else self.rest.len;
            const blank = std.mem.trim(u8, self.rest[at..end], " \t\r\n").len == 0;
            if (blank) {
                ended = in_record;
            } else {
                if (ended) break;
                in_record = true;
            }
            at = end;
        }
        defer self.rest = self.rest[at..];
        return self.rest[0..at];
    }
};

/// The value of the first `key` in a record.
pub fn find(record: []const u8, key: []const u8) ?[]const u8 {
    var lines = str.lines(record);
    while (lines.next()) |line| {
        const found = pair(line) orelse continue;
        if (std.mem.eql(u8, found.key, key)) return found.value;
    }
    return null;
}

const testing = std.testing;

test "a line splits at its first equals sign, and comments and blanks do not" {
    const found = pair("  binary  = /bin/a=b ").?;
    try testing.expectEqualStrings("binary", found.key);
    try testing.expectEqualStrings("/bin/a=b", found.value);
    try testing.expect(pair("# name = x") == null);
    try testing.expect(pair("   ") == null);
    try testing.expect(pair("no separator") == null);
}

test "records laid end to end are the file" {
    const text =
        \\# A header.
        \\
        \\name = one
        \\# a comment inside
        \\needs = two
        \\
        \\
        \\name = two
    ;
    var each = records(text);
    try testing.expectEqualStrings("# A header.\n\n", each.next().?);
    const one = each.next().?;
    try testing.expectEqualStrings("name = one\n# a comment inside\nneeds = two\n\n\n", one);
    try testing.expectEqualStrings("name = two", each.next().?);
    try testing.expect(each.next() == null);

    try testing.expectEqualStrings("two", find(one, "needs").?);
    try testing.expect(find(one, "binary") == null);
}

test "leading blank lines belong to the first record" {
    var each = records("\n\nname = a\n");
    try testing.expectEqualStrings("\n\nname = a\n", each.next().?);
    try testing.expect(each.next() == null);
}
