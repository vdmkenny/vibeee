//! String helpers shared by every userspace program.
//!
//! Each of these existed three or four times over before this file did, once
//! per tool that needed it. A shared copy is not just less code: it is one
//! place for the edge cases to be right.

const std = @import("std");

pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Length of a NUL-terminated string, as a slice.
pub fn span(ptr: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (ptr[n] != 0) n += 1;
    return ptr[0..n];
}

/// Leading decimal digits as a number. Stops at the first non-digit rather
/// than failing, because every caller is reading a field it already trusts.
pub fn toUnsigned(text: []const u8) usize {
    var value: usize = 0;
    for (text) |c| {
        if (c < '0' or c > '9') break;
        value = value * 10 + (c - '0');
    }
    return value;
}

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and haystack[i + j] == needle[j]) j += 1;
        if (j == needle.len) return true;
    }
    return false;
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

/// Split on runs of whitespace, writing into `words`. Returns how many.
///
/// No quoting: it would need escaping rules, and nothing yet passes an
/// argument containing a space.
pub fn splitWords(text: []const u8, words: [][]const u8) usize {
    var count: usize = 0;
    var i: usize = 0;

    while (i < text.len and count < words.len) {
        while (i < text.len and isSpace(text[i])) i += 1;
        if (i >= text.len) break;

        const start = i;
        while (i < text.len and !isSpace(text[i])) i += 1;
        words[count] = text[start..i];
        count += 1;
    }
    return count;
}

/// Iterate lines, without the terminator. A final line with no newline still
/// counts, which is what makes it safe over a truncated read.
pub const LineIterator = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(self: *LineIterator) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
        const line = self.text[start..self.pos];
        if (self.pos < self.text.len) self.pos += 1;
        return line;
    }
};

pub fn lines(text: []const u8) LineIterator {
    return .{ .text = text };
}

/// Iterate tab-separated fields, which is how the kernel returns tabular
/// information: it emits the values and leaves column widths to whoever is
/// displaying them.
pub const FieldIterator = struct {
    text: []const u8,
    pos: usize = 0,
    done: bool = false,

    pub fn next(self: *FieldIterator) ?[]const u8 {
        if (self.done) return null;
        const start = self.pos;
        while (self.pos < self.text.len and self.text[self.pos] != '\t') self.pos += 1;
        const field = self.text[start..self.pos];
        if (self.pos < self.text.len) {
            self.pos += 1;
        } else {
            self.done = true;
        }
        return field;
    }
};

pub fn fields(text: []const u8) FieldIterator {
    return .{ .text = text };
}

/// Strip leading spaces, reporting whether there were any.
///
/// Indentation carries meaning in the kernel's tabular output — an indented
/// row is a volume within the disk above it.
pub fn stripIndent(text: []const u8) struct { text: []const u8, indented: bool } {
    var rest = text;
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    return .{ .text = rest, .indented = rest.len != text.len };
}
