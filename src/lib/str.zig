//! String helpers, shared by everything.
//!
//! Each of these existed three or four times over before this file did, once
//! per tool that needed it. A shared copy is not just less code: it is one
//! place for the edge cases to be right.
//!
//! In `lib` rather than with the rest of userspace because it is pure
//! computation. Formatting a number is the same work in a kernel, in a toolkit
//! drawing a file size, and in a terminal answering a cursor position report,
//! and each of those had written it out again for want of somewhere to reach.


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
/// Split on a single separator byte.
///
/// One iterator rather than one per separator: lines, tab-separated columns and
/// comma-separated lists are the same traversal, and having three near-copies
/// of it was three places for the end-of-input case to differ.
///
/// A trailing separator does not produce a final empty piece, so "a\n" is one
/// line rather than two, which is what every caller here wants and what the
/// alternative kept getting wrong.
pub const Splitter = struct {
    text: []const u8,
    separator: u8,
    pos: usize = 0,

    pub fn next(self: *Splitter) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        while (self.pos < self.text.len and self.text[self.pos] != self.separator) self.pos += 1;
        const piece = self.text[start..self.pos];
        if (self.pos < self.text.len) self.pos += 1;
        return piece;
    }
};

pub fn split(text: []const u8, separator: u8) Splitter {
    return .{ .text = text, .separator = separator };
}

pub fn lines(text: []const u8) Splitter {
    return split(text, '\n');
}

/// Tab-separated fields, which is how the kernel returns tabular information:
/// it emits the values and leaves column widths to whoever displays them.
pub fn fields(text: []const u8) Splitter {
    return split(text, '\t');
}

/// Drop leading and trailing whitespace.
pub fn trim(text: []const u8) []const u8 {
    var rest = text;
    while (rest.len > 0 and isSpace(rest[0])) rest = rest[1..];
    while (rest.len > 0 and isSpace(rest[rest.len - 1])) rest = rest[0 .. rest.len - 1];
    return rest;
}

/// Strip leading spaces, reporting whether there were any.
///
/// Indentation carries meaning in the kernel's tabular output, an indented
/// row is a volume within the disk above it.
pub fn stripIndent(text: []const u8) struct { text: []const u8, indented: bool } {
    var rest = text;
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    return .{ .text = rest, .indented = rest.len != text.len };
}

/// Write `value` as decimal into `buf`, returning how many bytes were used.
///
/// Here rather than in `out.zig` because a caller that wants a number in a
/// buffer should not have to route it through the output stream to get one.
pub fn decimal(buf: []u8, value: usize) usize {
    var digits: [20]u8 = undefined;
    var n: usize = 0;
    var v = value;

    if (v == 0) {
        digits[0] = '0';
        n = 1;
    }
    while (v > 0) : (v /= 10) {
        digits[n] = '0' + @as(u8, @intCast(v % 10));
        n += 1;
    }

    const written = @min(n, buf.len);
    for (0..written) |i| buf[i] = digits[n - 1 - i];
    return written;
}

/// Whether a short name is stored upper-cased because FAT had nowhere to record
/// its case.
///
/// A name with any lowercase in it came from a long-name record, which does
/// preserve case, so it is left alone. That is the rule Windows and macOS
/// apply, and it means `README.TXT` on disk reads as `readme.txt` while
/// `MyNotes.md` keeps its shape.
pub fn caseless(text: []const u8) bool {
    for (text) |c| {
        if (c >= 'a' and c <= 'z') return false;
    }
    return true;
}

/// A filename or path written the way it should be read. The result points into
/// `buf` when the case had to be changed, and into `text` when it did not.
pub fn displayName(buf: []u8, text: []const u8) []const u8 {
    if (!caseless(text) or text.len > buf.len) return text;
    @memcpy(buf[0..text.len], text);
    lowerName(buf[0..text.len]);
    return buf[0..text.len];
}

/// The same rule applied where the name already is, for a caller that owns a
/// copy of it.
pub fn lowerName(name: []u8) void {
    if (!caseless(name)) return;
    for (name) |*c| {
        if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
    }
}

/// Building a short string in a fixed buffer.
///
/// For text that goes somewhere other than standard output: a window's status
/// line, a config file, a label. Silently stops at the end of the buffer,
/// because every caller here is composing something whose length it already
/// knows and a truncated label beats a fallible one.
pub const Builder = struct {
    buf: []u8,
    len: usize = 0,

    pub fn text(self: *Builder, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    pub fn byte(self: *Builder, c: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }

    pub fn number(self: *Builder, value: usize) void {
        self.len += decimal(self.buf[self.len..], value);
    }

    /// A number and its unit, the pair that always travels together.
    pub fn quantity(self: *Builder, value: usize, unit: []const u8) void {
        self.number(value);
        self.byte(' ');
        self.text(unit);
    }

    pub fn done(self: *const Builder) []const u8 {
        return self.buf[0..self.len];
    }
};
