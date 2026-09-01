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

const std = @import("std");

/// Whether `text` begins with `prefix`. Shorter than the prefix is not.
/// Whether two strings say the same thing, folded for case.
///
/// Whether `a` sorts before `b`, folded for case.
///
/// Leading decimal digits as a number. Stops at the first non-digit rather
/// than failing, because every caller is reading a field it already trusts.
/// Whether two strings say the same thing, folded for case.
///
/// What a suffix comparison wants, and a name from a volume written on
/// another machine: `README.TXT` and `readme.txt` are one file's name written
/// twice.
pub fn eqlFold(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Whether `a` sorts before `b`, folded for case.
///
/// What a list of names ordered by name means: somebody looking for "Files"
/// does not care that it was written with a capital.
pub fn before(a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

pub fn toUnsigned(text: []const u8) usize {
    var value: usize = 0;
    for (text) |c| {
        if (c < '0' or c > '9') break;
        value = value * 10 + (c - '0');
    }
    return value;
}

/// A hexadecimal number, stopping at the first character that is not one.
///
/// Lenient in the same way `toUnsigned` is: hardware tables are full of hex and
/// a caller reading one wants the number, not a diagnosis of the text.
pub fn fromHex(text: []const u8) usize {
    var out: usize = 0;
    for (text) |c| {
        const digit: usize = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => break,
        };
        out = out *| 16 +| digit;
    }
    return out;
}

/// Whether a byte is part of a word, for the movement and the deletion that
/// step over one. Letters, digits, and the underscore that holds an
/// identifier together; anything above ASCII counts, because the alternative
/// is stopping in the middle of a word written in a language that needs
/// those bytes.
pub fn inWord(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => c >= 0x80,
    };
}

/// The start of the word at or before `at`. Runs of separators are crossed
/// first, so a cursor sitting after a space takes the word before it rather
/// than the space.
pub fn wordBefore(text: []const u8, at: usize) usize {
    var i = @min(at, text.len);
    while (i > 0 and !inWord(text[i - 1])) i -= 1;
    while (i > 0 and inWord(text[i - 1])) i -= 1;
    return i;
}

/// The end of the word at or after `at`.
pub fn wordAfter(text: []const u8, at: usize) usize {
    var i = @min(at, text.len);
    while (i < text.len and !inWord(text[i])) i += 1;
    while (i < text.len and inWord(text[i])) i += 1;
    return i;
}

/// The start of the field at or before `at`: the same walk with whitespace
/// as the only separator.
///
/// What a command line means by a word. A path is one thing to somebody
/// typing it, and a deletion that stopped at every slash would take four
/// presses to undo one argument.
pub fn fieldBefore(text: []const u8, at: usize) usize {
    var i = @min(at, text.len);
    while (i > 0 and isSpace(text[i - 1])) i -= 1;
    while (i > 0 and !isSpace(text[i - 1])) i -= 1;
    return i;
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

/// Split on runs of whitespace, writing into `words`. Returns how many.
///
/// No quoting: it would need escaping rules, and nothing yet passes an
/// argument containing a space.
pub fn splitWords(text: []const u8, into: [][]const u8) usize {
    var it = words(text);
    var count: usize = 0;
    while (count < into.len) : (count += 1) {
        into[count] = it.next() orelse break;
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

/// Whitespace-separated words, for text people wrote: runs of blanks are
/// one separator and never yield empty words, unlike a single-byte split.
pub const WordSplitter = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(self: *WordSplitter) ?[]const u8 {
        while (self.pos < self.text.len and isSpace(self.text[self.pos])) self.pos += 1;
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        while (self.pos < self.text.len and !isSpace(self.text[self.pos])) self.pos += 1;
        return self.text[start..self.pos];
    }
};

pub fn words(text: []const u8) WordSplitter {
    return .{ .text = text };
}

/// Drop leading and trailing whitespace.
pub fn trim(text: []const u8) []const u8 {
    var rest = text;
    while (rest.len > 0 and isSpace(rest[0])) rest = rest[1..];
    while (rest.len > 0 and isSpace(rest[rest.len - 1])) rest = rest[0 .. rest.len - 1];
    return rest;
}

/// Trim the ends and reduce every internal run of whitespace to one space,
/// rewriting `text` in place and returning the shortened slice.
///
/// A byte only ever moves earlier than it was read from, so the write index
/// stays behind the read index and the two never collide.
pub fn collapseSpaces(text: []u8) []u8 {
    var out: usize = 0;
    var gap = false;
    for (trim(text)) |c| {
        if (isSpace(c)) {
            gap = true;
            continue;
        }
        if (gap and out > 0) {
            text[out] = ' ';
            out += 1;
        }
        gap = false;
        text[out] = c;
        out += 1;
    }
    return text[0..out];
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

/// Whether `needle` appears in `haystack`, ignoring the difference between
/// upper and lower case.
///
/// What a person typing into a search field means: nobody types the capital
/// in "Files" and expects to be told there is no such program. ASCII only,
/// which is what the names in this system are.
pub fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(needle[i])) break;
        } else return true;
    }
    return false;
}

pub const Case = enum { lower, upper };

const ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz";

/// `value` in `base`, written into the tail of `buf` and returned as the slice
/// it occupies.
///
/// The one place a number becomes digits. Backwards from the end because
/// digits come out least significant first, so writing forward would mean
/// generating them and then reversing them.
pub fn number(buf: []u8, value: usize, base: u8, case: Case) []const u8 {
    if (buf.len == 0) return buf[0..0];

    var at = buf.len;
    var left = value;
    while (true) {
        at -= 1;
        const digit = ALPHABET[@intCast(left % base)];
        buf[at] = if (case == .upper) upperOf(digit) else digit;

        left /= base;
        if (left == 0 or at == 0) break;
    }
    return buf[at..];
}

fn upperOf(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

/// The same in base ten, written from the *start* of `buf`, for a caller
/// building a string forward. Returns how many bytes it used.
pub fn decimal(buf: []u8, value: usize) usize {
    var scratch: [24]u8 = undefined;
    const written = number(&scratch, value, 10, .lower);

    const n = @min(written.len, buf.len);
    @memcpy(buf[0..n], written[0..n]);
    return n;
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

/// A name written the way it should be read, in place.
///
/// FAT stores a short name upper-cased because the format has nowhere to
/// record case. That is a fact about the medium, not about the file, so the
/// kernel undoes it wherever a name leaves it and nothing downstream has to
/// know the medium was ever involved.
pub fn lowerName(name: []u8) void {
    if (!caseless(name)) return;
    for (name) |*c| c.* = std.ascii.toLower(c.*);
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

    /// A fixed width of hexadecimal digits, zero-padded. What every
    /// hardware identifier is written as, so it is written once.
    pub fn hex(self: *Builder, value: usize, digits: usize) void {
        var i = digits;
        while (i > 0) {
            i -= 1;
            const nibble: u8 = @intCast((value >> @intCast(i * 4)) & 0xF);
            self.byte(ALPHABET[nibble]);
        }
    }

    /// A number and its unit, the pair that always travels together.
    /// A size as a person reads it: three figures and a unit.
    ///
    /// Under a kilobyte it is a plain count, because "34" is a number of
    /// bytes and a unit after it says nothing. Above that, one decimal while
    /// the figure is small enough for it to mean something: the difference
    /// between 4.0M and 4.9M is a decision somebody might make, and the one
    /// between 379K and 380K is not.
    pub fn bytes(self: *Builder, value: usize) void {
        const K = 1024;
        if (value < K) return self.number(value);

        const unit: u8 = if (value < K * K) 'K' else if (value < K * K * K) 'M' else 'G';
        const scale: usize = switch (unit) {
            'K' => K,
            'M' => K * K,
            else => K * K * K,
        };

        // Tenths, so the rounding happens once and in one place.
        const tenths = value * 10 / scale;
        self.number(tenths / 10);
        if (tenths < 1000) {
            self.byte('.');
            self.number(tenths % 10);
        }
        self.byte(unit);
    }

    pub fn quantity(self: *Builder, value: usize, unit: []const u8) void {
        self.number(value);
        self.byte(' ');
        self.text(unit);
    }

    /// A span of time as a person says it: the largest unit that applies
    /// and the ones below it, and never a leading "0h".
    ///
    /// Here rather than in each caller because uptime is shown by the shell,
    /// by the monitor and by a command, and three spellings of the same
    /// number is three chances for two of them to disagree.
    pub fn duration(self: *Builder, seconds: usize) void {
        const hours = seconds / 3600;
        const minutes = (seconds % 3600) / 60;

        if (hours > 0) {
            self.number(hours);
            self.text("h ");
        }
        if (hours > 0 or minutes > 0) {
            self.number(minutes);
            self.text("m ");
        }
        self.number(seconds % 60);
        self.byte('s');
    }

    pub fn done(self: *const Builder) []const u8 {
        return self.buf[0..self.len];
    }
};

test "hex reads both cases and stops at the first character that is not one" {
    try std.testing.expectEqual(@as(usize, 0x8086), fromHex("8086"));
    try std.testing.expectEqual(@as(usize, 0x100e), fromHex("100e"));
    try std.testing.expectEqual(@as(usize, 0x100E), fromHex("100E"));
    try std.testing.expectEqual(@as(usize, 0x1f), fromHex("1f:extra"));
    try std.testing.expectEqual(@as(usize, 0), fromHex(""));
    try std.testing.expectEqual(@as(usize, 0), fromHex("zz"));
}

test "collapseSpaces trims the ends and reduces every internal run to one" {
    // A CPUID brand string, which pads a run before the clock speed.
    var brand = "Intel(R) Celeron(R) M processor          900MHz".*;
    try std.testing.expectEqualStrings(
        "Intel(R) Celeron(R) M processor 900MHz",
        collapseSpaces(&brand),
    );

    var padded = "   spaced   out   ".*;
    try std.testing.expectEqualStrings("spaced out", collapseSpaces(&padded));

    var tabs = "a\t\t b".*;
    try std.testing.expectEqualStrings("a b", collapseSpaces(&tabs));

    var blank = "     ".*;
    try std.testing.expectEqualStrings("", collapseSpaces(&blank));

    var single = "x".*;
    try std.testing.expectEqualStrings("x", collapseSpaces(&single));
}

test "the builder writes hardware identifiers at a fixed width" {
    var buf: [16]u8 = @splat(0);
    var text = Builder{ .buf = &buf };
    text.hex(0x8086, 4);
    text.byte(':');
    text.hex(0x2668, 4);
    try std.testing.expectEqualStrings("8086:2668", text.done());

    var short: [8]u8 = @splat(0);
    var padded = Builder{ .buf = &short };
    padded.hex(0x0C, 2);
    try std.testing.expectEqualStrings("0c", padded.done());
}

/// How many leading characters of `text` are in `set`.
///
/// The first half of tokenising: a run of separators to step over. Named
/// for what C calls it, because the callers that want it are C's.
pub fn spanOfAny(text: []const u8, set: []const u8) usize {
    var n: usize = 0;
    while (n < text.len and hasByte(set, text[n])) n += 1;
    return n;
}

/// How many leading characters of `text` are *not* in `set`, which is the
/// other half: the token itself.
pub fn spanUntilAny(text: []const u8, set: []const u8) usize {
    var n: usize = 0;
    while (n < text.len and !hasByte(set, text[n])) n += 1;
    return n;
}

/// Where the first character of `text` that is in `set` sits.
pub fn indexOfAny(text: []const u8, set: []const u8) ?usize {
    const at = spanUntilAny(text, set);
    return if (at == text.len) null else at;
}

/// Whether a set of characters holds one. Distinct from `contains`,
/// which asks the same about a substring.
pub fn hasByte(set: []const u8, byte: u8) bool {
    for (set) |c| {
        if (c == byte) return true;
    }
    return false;
}

/// The longest leading part of `text` that reads as a number, in the
/// shape C accepts: a sign, digits with at most one point among them,
/// and an exponent that must itself have digits to be part of it.
///
/// Length rather than a value, because the caller wants both: the number
/// to parse and where it stopped, and finding the end twice would be two
/// answers to one question.
pub fn numberSpan(text: []const u8) usize {
    var at: usize = 0;
    if (at < text.len and (text[at] == '+' or text[at] == '-')) at += 1;

    var digits: usize = 0;
    while (at < text.len and isDigit(text[at])) : (at += 1) digits += 1;

    if (at < text.len and text[at] == '.') {
        at += 1;
        while (at < text.len and isDigit(text[at])) : (at += 1) digits += 1;
    }
    // No digits at all is not a number, whatever else was there.
    if (digits == 0) return 0;

    // An exponent counts only if it has digits of its own; `1e` is the
    // number one followed by a letter.
    if (at < text.len and (text[at] == 'e' or text[at] == 'E')) {
        var after = at + 1;
        if (after < text.len and (text[after] == '+' or text[after] == '-')) after += 1;

        var exponent_digits: usize = 0;
        while (after < text.len and isDigit(text[after])) : (after += 1) exponent_digits += 1;
        if (exponent_digits > 0) at = after;
    }
    return at;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

test "a run of characters is measured from a set, either way round" {
    try std.testing.expectEqual(@as(usize, 3), spanOfAny("aabxyz", "ab"));
    try std.testing.expectEqual(@as(usize, 0), spanOfAny("xyz", "ab"));
    try std.testing.expectEqual(@as(usize, 0), spanOfAny("", "ab"));
    try std.testing.expectEqual(@as(usize, 6), spanOfAny("aabbaa", "ab"));

    try std.testing.expectEqual(@as(usize, 3), spanUntilAny("xyzab", "ab"));
    try std.testing.expectEqual(@as(usize, 0), spanUntilAny("ab", "ab"));
    try std.testing.expectEqual(@as(usize, 5), spanUntilAny("xyzuv", "ab"));

    try std.testing.expectEqual(@as(usize, 3), indexOfAny("xyzab", "ab").?);
    try std.testing.expect(indexOfAny("xyz", "ab") == null);
    // An empty set matches nothing, so nothing is ever found in it.
    try std.testing.expect(indexOfAny("xyz", "") == null);
}

test "the leading number is measured in the shape C accepts" {
    try std.testing.expectEqual(@as(usize, 3), numberSpan("123"));
    try std.testing.expectEqual(@as(usize, 4), numberSpan("-123abc"));
    try std.testing.expectEqual(@as(usize, 5), numberSpan("3.125"));
    try std.testing.expectEqual(@as(usize, 2), numberSpan(".5"));
    try std.testing.expectEqual(@as(usize, 2), numberSpan("5."));
    try std.testing.expectEqual(@as(usize, 6), numberSpan("1.5e10"));
    try std.testing.expectEqual(@as(usize, 7), numberSpan("1.5e-10"));
    try std.testing.expectEqual(@as(usize, 8), numberSpan("+1.5E+10x"));

    // An exponent with no digits is not part of the number.
    try std.testing.expectEqual(@as(usize, 1), numberSpan("1e"));
    try std.testing.expectEqual(@as(usize, 1), numberSpan("1e+"));
    try std.testing.expectEqual(@as(usize, 3), numberSpan("1.5e"));

    // Nothing that is not a number is one.
    try std.testing.expectEqual(@as(usize, 0), numberSpan(""));
    try std.testing.expectEqual(@as(usize, 0), numberSpan("abc"));
    try std.testing.expectEqual(@as(usize, 0), numberSpan("-"));
    try std.testing.expectEqual(@as(usize, 0), numberSpan("."));
    try std.testing.expectEqual(@as(usize, 0), numberSpan("+.e5"));
}

test "a duration reads as a person says it" {
    var buf: [32]u8 = undefined;
    const cases = [_]struct { seconds: usize, text: []const u8 }{
        .{ .seconds = 0, .text = "0s" },
        .{ .seconds = 31, .text = "31s" },
        .{ .seconds = 60, .text = "1m 0s" },
        .{ .seconds = 3599, .text = "59m 59s" },
        .{ .seconds = 3600, .text = "1h 0m 0s" },
        .{ .seconds = 3661, .text = "1h 1m 1s" },
        .{ .seconds = 90061, .text = "25h 1m 1s" },
    };
    for (cases) |case| {
        var built = Builder{ .buf = &buf };
        built.duration(case.seconds);
        try @import("std").testing.expectEqualStrings(case.text, built.done());
    }
}

test "a search matches whatever case it was typed in" {
    const expect = @import("std").testing.expect;
    try expect(containsFold("Files", "fil"));
    try expect(containsFold("Files", "FIL"));
    try expect(containsFold("Files", "iles"));
    try expect(containsFold("eeefetch", "fetch"));
    // Nothing typed matches everything, which is what an empty field means.
    try expect(containsFold("Files", ""));

    try expect(!containsFold("Files", "x"));
    try expect(!containsFold("Files", "filesystem"));
    try expect(!containsFold("", "a"));
}

test "a size reads as three digits and a unit" {
    var buf: [16]u8 = undefined;

    const cases = [_]struct { value: usize, said: []const u8 }{
        // Bytes are a count, not a measurement with a unit.
        .{ .value = 0, .said = "0" },
        .{ .value = 34, .said = "34" },
        .{ .value = 999, .said = "999" },
        // Small figures carry a decimal, because it says something.
        .{ .value = 1024, .said = "1.0K" },
        .{ .value = 1024 * 34, .said = "34.0K" },
        .{ .value = 1024 * 1024, .said = "1.0M" },
        .{ .value = 1024 * 1024 * 1024 * 3, .said = "3.0G" },
        // Three figures do not.
        .{ .value = 1024 * 379, .said = "379K" },
        .{ .value = 1024 * 1024 * 511, .said = "511M" },
    };

    for (cases) |case| {
        var line = Builder{ .buf = &buf };
        line.bytes(case.value);
        try std.testing.expectEqualStrings(case.said, line.done());
    }

    // Rounded down rather than up: a file said to be 2M that is not yet 2M is
    // a listing that cannot be trusted about the ones that are.
    var line = Builder{ .buf = &buf };
    line.bytes(1024 * 1024 * 2 - 1);
    try std.testing.expectEqualStrings("1.9M", line.done());
}

test "names sort by what they say, not by their capitals" {
    try std.testing.expect(std.ascii.lessThanIgnoreCase("apple", "banana"));
    try std.testing.expect(!std.ascii.lessThanIgnoreCase("banana", "apple"));

    // Case is not part of the order.
    try std.testing.expect(std.ascii.lessThanIgnoreCase("Apple", "banana"));
    try std.testing.expect(std.ascii.lessThanIgnoreCase("apple", "Banana"));
    try std.testing.expect(!std.ascii.lessThanIgnoreCase("Banana", "apple"));

    // A prefix comes before what extends it, and nothing comes before itself.
    try std.testing.expect(std.ascii.lessThanIgnoreCase("file", "files"));
    try std.testing.expect(!std.ascii.lessThanIgnoreCase("files", "file"));
    try std.testing.expect(!std.ascii.lessThanIgnoreCase("file", "file"));
    try std.testing.expect(!std.ascii.lessThanIgnoreCase("File", "file"));

    // Nothing sorts before something.
    try std.testing.expect(std.ascii.lessThanIgnoreCase("", "a"));
    try std.testing.expect(!std.ascii.lessThanIgnoreCase("a", ""));
}

test "a word is what somebody means by one" {
    try std.testing.expect(inWord('a'));
    try std.testing.expect(inWord('Z'));
    try std.testing.expect(inWord('7'));
    try std.testing.expect(inWord('_'));
    // Anything above ASCII is part of a word, or a deletion would stop in the
    // middle of one written in a language that needs those bytes.
    try std.testing.expect(inWord(0xC3));

    try std.testing.expect(!inWord(' '));
    try std.testing.expect(!inWord('-'));
    try std.testing.expect(!inWord('/'));
    try std.testing.expect(!inWord('.'));
}

test "the word before the cursor crosses what is between them first" {
    const line = "the quick brown fox";

    // From the end of a word: back to the start of that word.
    try std.testing.expectEqual(@as(usize, 16), wordBefore(line, line.len));
    // From just after a space: past the space, to the word before it.
    try std.testing.expectEqual(@as(usize, 10), wordBefore(line, 16));
    // From the very start there is nowhere to go.
    try std.testing.expectEqual(@as(usize, 0), wordBefore(line, 0));
    // From the middle of a word: to that word's start.
    try std.testing.expectEqual(@as(usize, 4), wordBefore(line, 7));

    // Trailing separators are crossed before the word is.
    try std.testing.expectEqual(@as(usize, 0), wordBefore("one   ", 6));
}

test "the word after the cursor runs to the end of it" {
    const line = "the quick brown";
    try std.testing.expectEqual(@as(usize, 3), wordAfter(line, 0));
    // From the space: over it and through the word after.
    try std.testing.expectEqual(@as(usize, 9), wordAfter(line, 3));
    try std.testing.expectEqual(line.len, wordAfter(line, line.len));
    try std.testing.expectEqual(line.len, wordAfter(line, 10));
}

test "a field is what a command line means by a word" {
    // A path is one thing to somebody typing it, so the whole of it goes.
    const line = "cat /home/user/notes.txt";
    try std.testing.expectEqual(@as(usize, 4), fieldBefore(line, line.len));
    try std.testing.expectEqual(@as(usize, 0), fieldBefore(line, 3));

    // Which is where it differs from the prose rule, that stops at the dot.
    try std.testing.expect(wordBefore(line, line.len) > fieldBefore(line, line.len));

    // Trailing spaces are crossed first, like the other one.
    try std.testing.expectEqual(@as(usize, 0), fieldBefore("one   ", 6));
    try std.testing.expectEqual(@as(usize, 0), fieldBefore("", 0));
}
