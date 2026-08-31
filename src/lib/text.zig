//! An editable text, as arithmetic rather than as a screen.
//!
//! Everything an editor does to a document that does not involve drawing it:
//! where the lines are, where the cursor is, and what inserting or deleting a
//! character does to both. No screen, no keys, no files, so all of it can be
//! read and tested on its own, which is what the editor above is then free to
//! be simple about.
//!
//! The storage is the caller's. A document is a view onto two arrays it was
//! handed, so nothing here allocates and an editor's memory is one committed
//! block sized once.
//!
//! Text is UTF-8 and the cursor moves by characters, never by bytes: a
//! cursor that could land inside a two-byte character would draw a broken
//! glyph and delete half of one.

const std = @import("std");

pub const Cursor = struct {
    /// Which line, counting from zero.
    line: usize = 0,
    /// How far into that line, in bytes. Always on a character boundary.
    column: usize = 0,
};

/// Which way a cursor is being asked to go. Named rather than numbered
/// because a key maps to one of these and nothing else.
pub const Motion = enum {
    left,
    right,
    up,
    down,
    /// The first character of the line, and the last.
    line_start,
    line_end,
    /// The first line of the document, and the last.
    document_start,
    document_end,
};

/// What an edit did, so a caller knows whether the screen needs redrawing
/// and whether the document is worth saving.
pub const Change = enum {
    /// Nothing happened: the document was full, or the cursor was already
    /// at the end of what it was asked to delete.
    none,
    /// One line changed, and only that line needs drawing again.
    line,
    /// The line count changed, so everything below moved.
    lines,
};

pub const Document = struct {
    /// The text itself. The caller owns it and its length is the document's
    /// capacity, which is what makes a full document a fact rather than a
    /// failure to allocate.
    bytes: []u8,
    len: usize = 0,

    /// Where each line starts, with one entry past the last so a line's end
    /// is found the same way as its start. The caller owns this too, and its
    /// length bounds how many lines a document may have.
    line_at: []u32,
    lines: usize = 0,

    cursor: Cursor = .{},
    /// Whether anything has changed since the document was loaded or saved.
    dirty: bool = false,
    /// The file was longer than the storage, so what is here is its head.
    /// A document in this state must not be written back over the file it
    /// came from, and the editor above refuses to.
    truncated: bool = false,

    /// The column the cursor would like to be in, in characters.
    ///
    /// Moving down a long line, across a short one, and down again should
    /// arrive where the first line's column was. Without this the cursor
    /// walks left every time it passes a short line, which is the one thing
    /// everybody notices about an editor that gets it wrong.
    wanted: usize = 0,

    // -----------------------------------------------------------------
    // Loading and reading
    // -----------------------------------------------------------------

    /// Take a text as the document's contents. Anything past the storage is
    /// dropped and said so.
    pub fn load(self: *Document, text: []const u8) void {
        const take = @min(text.len, self.bytes.len);
        @memcpy(self.bytes[0..take], text[0..take]);
        self.len = take;
        self.truncated = take < text.len;
        self.dirty = false;
        self.cursor = .{};
        self.wanted = 0;
        self.index();
    }

    /// Everything written, ready to go back to a file.
    pub fn contents(self: *const Document) []const u8 {
        return self.bytes[0..self.len];
    }

    /// One line, without its separator.
    pub fn line(self: *const Document, n: usize) []const u8 {
        return lineAt(self.bytes[0..self.len], self.line_at, self.lines, n);
    }

    /// How long a line is in characters, which is what a column counts and
    /// what a screen shows.
    pub fn lineWidth(self: *const Document, n: usize) usize {
        return characters(self.line(n));
    }

    /// Where the cursor is in the whole text, which is where an insert goes.
    pub fn offset(self: *const Document) usize {
        if (self.lines == 0) return 0;
        const start = self.line_at[self.cursor.line];
        return start + self.cursor.column;
    }

    /// The cursor's column counted in characters rather than bytes, which is
    /// the column a screen draws it in.
    pub fn column(self: *const Document) usize {
        const text = self.line(self.cursor.line);
        return characters(text[0..@min(self.cursor.column, text.len)]);
    }

    // -----------------------------------------------------------------
    // Moving
    // -----------------------------------------------------------------

    pub fn move(self: *Document, motion: Motion) void {
        switch (motion) {
            .left => self.goLeft(),
            .right => self.goRight(),
            .up => self.goVertical(-1),
            .down => self.goVertical(1),
            .line_start => {
                self.cursor.column = 0;
                self.wanted = 0;
            },
            .line_end => {
                self.cursor.column = self.line(self.cursor.line).len;
                self.wanted = self.column();
            },
            .document_start => {
                self.cursor = .{};
                self.wanted = 0;
            },
            .document_end => {
                self.cursor.line = if (self.lines == 0) 0 else self.lines - 1;
                self.cursor.column = self.line(self.cursor.line).len;
                self.wanted = self.column();
            },
        }
    }

    /// Move by whole screens, which is a motion the editor sizes and the
    /// document performs so the column is kept the same way as for one line.
    pub fn moveBy(self: *Document, rows: usize, down: bool) void {
        var left = rows;
        while (left > 0) : (left -= 1) self.goVertical(if (down) 1 else -1);
    }

    fn goLeft(self: *Document) void {
        if (self.cursor.column > 0) {
            const text = self.line(self.cursor.line);
            self.cursor.column = backOne(text, self.cursor.column);
        } else if (self.cursor.line > 0) {
            // Off the front of a line is the end of the one above, which is
            // where a backspace at column zero has to leave the cursor too.
            self.cursor.line -= 1;
            self.cursor.column = self.line(self.cursor.line).len;
        }
        self.wanted = self.column();
    }

    fn goRight(self: *Document) void {
        const text = self.line(self.cursor.line);
        if (self.cursor.column < text.len) {
            self.cursor.column += charWidth(text, self.cursor.column);
        } else if (self.cursor.line + 1 < self.lines) {
            self.cursor.line += 1;
            self.cursor.column = 0;
        }
        self.wanted = self.column();
    }

    /// Up or down a line, landing in the column the cursor has been asking
    /// for rather than the one it happened to be in.
    fn goVertical(self: *Document, by: i2) void {
        if (by < 0) {
            if (self.cursor.line == 0) return;
            self.cursor.line -= 1;
        } else {
            if (self.cursor.line + 1 >= self.lines) return;
            self.cursor.line += 1;
        }
        self.cursor.column = byteAt(self.line(self.cursor.line), self.wanted);
    }

    // -----------------------------------------------------------------
    // Changing
    // -----------------------------------------------------------------

    /// Put one character where the cursor is, and step over it.
    pub fn insert(self: *Document, codepoint: u21) Change {
        var encoded: [4]u8 = undefined;
        const width = std.unicode.utf8Encode(codepoint, &encoded) catch return .none;
        if (!self.make(self.offset(), encoded[0..width])) return .none;

        self.cursor.column += width;
        self.wanted = self.column();
        return if (codepoint == '\n') .lines else .line;
    }

    /// Split the line at the cursor.
    pub fn newline(self: *Document) Change {
        if (!self.make(self.offset(), "\n")) return .none;
        self.cursor.line += 1;
        self.cursor.column = 0;
        self.wanted = 0;
        return .lines;
    }

    /// Delete the character before the cursor, joining lines when there is
    /// none: a backspace at the start of a line is what pulls it up.
    pub fn backspace(self: *Document) Change {
        if (self.cursor.column == 0 and self.cursor.line == 0) return .none;

        const joining = self.cursor.column == 0;
        const at = self.offset();
        const width = if (joining) 1 else at - (self.line_at[self.cursor.line] +
            backOne(self.line(self.cursor.line), self.cursor.column));

        self.move(.left);
        self.remove(self.offset(), width);
        return if (joining) .lines else .line;
    }

    /// Delete the character the cursor is on, joining the line below when
    /// the cursor is at the end of a line.
    pub fn delete(self: *Document) Change {
        const at = self.offset();
        if (at >= self.len) return .none;

        const text = self.line(self.cursor.line);
        const joining = self.cursor.column >= text.len;
        const width = if (joining) 1 else charWidth(text, self.cursor.column);

        self.remove(at, width);
        return if (joining) .lines else .line;
    }

    /// Put bytes in at an offset, if they fit.
    fn make(self: *Document, at: usize, what: []const u8) bool {
        if (self.len + what.len > self.bytes.len) return false;
        if (at > self.len) return false;

        // Backwards, because the tail moves into space it currently occupies.
        var i = self.len;
        while (i > at) : (i -= 1) self.bytes[i + what.len - 1] = self.bytes[i - 1];
        @memcpy(self.bytes[at..][0..what.len], what);
        self.len += what.len;

        self.dirty = true;
        self.index();
        return true;
    }

    fn remove(self: *Document, at: usize, count: usize) void {
        if (at >= self.len or count == 0) return;
        const take = @min(count, self.len - at);

        var i = at;
        while (i + take < self.len) : (i += 1) self.bytes[i] = self.bytes[i + take];
        self.len -= take;

        self.dirty = true;
        self.index();
    }

    /// Record where every line starts.
    ///
    /// Done whole after every change rather than patched. A document this
    /// size is scanned in the time between two keystrokes many times over,
    /// and an index that is rebuilt cannot drift from the text it describes.
    pub fn index(self: *Document) void {
        self.lines = indexLines(self.bytes[0..self.len], self.line_at);
        self.clamp();
    }

    /// Put the cursor back inside the document, which deleting a line or
    /// loading a shorter file can leave it outside of.
    fn clamp(self: *Document) void {
        if (self.cursor.line >= self.lines) {
            self.cursor.line = if (self.lines == 0) 0 else self.lines - 1;
        }
        const width = self.line(self.cursor.line).len;
        if (self.cursor.column > width) self.cursor.column = width;
    }
};

// ---------------------------------------------------------------------------
// Lines
// ---------------------------------------------------------------------------

/// Record where every line of `bytes` starts, and answer how many there are.
///
/// `into` gets one entry per line plus one past the last, so a line's end is
/// found the same way as its start; it bounds the count, and a text with more
/// lines than it holds is indexed as far as it goes.
///
/// The rule worth writing once is the last line: a text ending in a separator
/// has an empty line after it, and an empty text is one empty line, because a
/// cursor has to have somewhere to be.
pub fn indexLines(bytes: []const u8, into: []u32) usize {
    if (into.len == 0) return 0;

    var lines: usize = 0;
    var at: usize = 0;
    while (at < bytes.len and lines + 1 < into.len) {
        into[lines] = @intCast(at);
        lines += 1;
        while (at < bytes.len and bytes[at] != '\n') at += 1;
        at += 1;
    }

    if (lines + 1 < into.len and (bytes.len == 0 or bytes[bytes.len - 1] == '\n')) {
        into[lines] = @intCast(bytes.len);
        lines += 1;
    }
    into[lines] = @intCast(bytes.len);
    return lines;
}

/// One indexed line, without its separator.
pub fn lineAt(bytes: []const u8, into: []const u32, lines: usize, n: usize) []const u8 {
    if (n >= lines) return "";
    const from = into[n];
    var to = into[n + 1];
    if (to > from and bytes[to - 1] == '\n') to -= 1;
    return bytes[from..to];
}

// ---------------------------------------------------------------------------
// Characters, which are not bytes
// ---------------------------------------------------------------------------

/// How many characters a string holds. Continuation bytes are the ones that
/// are not the start of anything, so counting the rest counts characters.
pub fn characters(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    return count;
}

/// The byte offset of the nth character, or the end of the string when it
/// has fewer than n.
pub fn byteAt(text: []const u8, n: usize) usize {
    var seen: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        if (seen == n) return at;
        at += charWidth(text, at);
        seen += 1;
    }
    return text.len;
}

/// How many bytes the character at `at` occupies. A byte that begins nothing
/// is taken as one byte, so malformed text moves the cursor rather than
/// trapping it.
///
/// What anything drawing text one cell at a time needs, which is why it is
/// not private to the cursor arithmetic.
pub fn charWidth(text: []const u8, at: usize) usize {
    const width = std.unicode.utf8ByteSequenceLength(text[at]) catch return 1;
    return @min(@as(usize, width), text.len - at);
}

/// A window of characters out of a line: `count` of them starting at the
/// `from`th, clipped to what is there.
///
/// What drawing a line into a screen narrower than it is comes down to, and
/// the same arithmetic whether the line is the cursor's or not.
pub fn window(text: []const u8, from: usize, count: usize) []const u8 {
    const start = byteAt(text, from);
    const end = byteAt(text, from + count);
    return text[start..end];
}

/// Move a window so that `at` is inside it, and no further.
///
/// Scrolling, in one line: a cursor one row below the screen moves the
/// screen one row, not a screenful, and one above moves it back. Used for
/// both directions, because a screen too narrow for a line is the same
/// problem as one too short for a file.
pub fn follow(start: usize, span: usize, at: usize) usize {
    if (span == 0) return at;
    if (at < start) return at;
    if (at >= start + span) return at + 1 - span;
    return start;
}

/// Where the character before `at` begins.
fn backOne(text: []const u8, at: usize) usize {
    var back = at;
    while (back > 0) {
        back -= 1;
        if (text[back] & 0xC0 != 0x80) return back;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A document over its own storage, for a test to write into.
fn scratch(bytes: []u8, index: []u32, from: []const u8) Document {
    var doc = Document{ .bytes = bytes, .line_at = index };
    doc.load(from);
    return doc;
}

test "an empty document is one empty line with the cursor in it" {
    var bytes: [64]u8 = undefined;
    var index: [16]u32 = undefined;
    var doc = scratch(&bytes, &index, "");

    try testing.expectEqual(@as(usize, 1), doc.lines);
    try testing.expectEqualStrings("", doc.line(0));
    try testing.expectEqual(@as(usize, 0), doc.offset());
    try testing.expect(!doc.dirty);
}

test "lines are found without their separators, and a trailing one makes a line" {
    var bytes: [64]u8 = undefined;
    var index: [16]u32 = undefined;

    var doc = scratch(&bytes, &index, "one\ntwo\nthree");
    try testing.expectEqual(@as(usize, 3), doc.lines);
    try testing.expectEqualStrings("one", doc.line(0));
    try testing.expectEqualStrings("two", doc.line(1));
    try testing.expectEqualStrings("three", doc.line(2));
    try testing.expectEqualStrings("", doc.line(3));

    // A text ending in a separator has an empty line after it, which is
    // where the cursor goes when you press enter at the end of a file.
    doc.load("one\ntwo\n");
    try testing.expectEqual(@as(usize, 3), doc.lines);
    try testing.expectEqualStrings("", doc.line(2));
}

test "typing puts characters in and the cursor after them" {
    var bytes: [64]u8 = undefined;
    var index: [16]u32 = undefined;
    var doc = scratch(&bytes, &index, "");

    for ("hi") |c| try testing.expectEqual(Change.line, doc.insert(c));
    try testing.expectEqualStrings("hi", doc.contents());
    try testing.expectEqual(@as(usize, 2), doc.cursor.column);
    try testing.expect(doc.dirty);

    // Inserting in the middle pushes the rest along.
    doc.move(.line_start);
    _ = doc.insert('o');
    try testing.expectEqualStrings("ohi", doc.contents());
    try testing.expectEqual(@as(usize, 1), doc.cursor.column);
}

test "a document that is full takes nothing more" {
    var bytes: [4]u8 = undefined;
    var index: [16]u32 = undefined;
    var doc = scratch(&bytes, &index, "abcd");

    try testing.expectEqual(@as(usize, 4), doc.len);
    try testing.expectEqual(Change.none, doc.insert('e'));
    try testing.expectEqual(Change.none, doc.newline());
    try testing.expectEqualStrings("abcd", doc.contents());

    // And a file longer than the storage says so rather than pretending.
    doc.load("abcdefgh");
    try testing.expect(doc.truncated);
    try testing.expectEqualStrings("abcd", doc.contents());
}

test "enter splits a line and leaves the cursor at the start of the new one" {
    var bytes: [64]u8 = undefined;
    var index: [16]u32 = undefined;
    var doc = scratch(&bytes, &index, "hello world");

    doc.cursor.column = 5;
    try testing.expectEqual(Change.lines, doc.newline());
    try testing.expectEqual(@as(usize, 2), doc.lines);
    try testing.expectEqualStrings("hello", doc.line(0));
    try testing.expectEqualStrings(" world", doc.line(1));
    try testing.expectEqual(@as(usize, 1), doc.cursor.line);
    try testing.expectEqual(@as(usize, 0), doc.cursor.column);
}

test "backspace deletes backwards, and joins lines at the start of one" {
    var bytes: [64]u8 = undefined;
    var index: [16]u32 = undefined;
    var doc = scratch(&bytes, &index, "ab\ncd");

    doc.move(.document_end);
    try testing.expectEqual(Change.line, doc.backspace());
    try testing.expectEqualStrings("ab\nc", doc.contents());

    doc.move(.line_start);
    // At the start of a line there is nothing to delete but the separator,
    // which pulls the line up onto the one above.
    try testing.expectEqual(Change.lines, doc.backspace());
    try testing.expectEqualStrings("abc", doc.contents());
    try testing.expectEqual(@as(usize, 1), doc.lines);
    try testing.expectEqual(@as(usize, 0), doc.cursor.line);
    try testing.expectEqual(@as(usize, 2), doc.cursor.column);

    // And at the very start there is nothing to do at all.
    doc.move(.document_start);
    try testing.expectEqual(Change.none, doc.backspace());
    try testing.expectEqualStrings("abc", doc.contents());
}

test "delete takes the character under the cursor, and joins the line below" {
    var bytes: [64]u8 = undefined;
    var index: [16]u32 = undefined;
    var doc = scratch(&bytes, &index, "ab\ncd");

    try testing.expectEqual(Change.line, doc.delete());
    try testing.expectEqualStrings("b\ncd", doc.contents());

    doc.move(.line_end);
    try testing.expectEqual(Change.lines, doc.delete());
    try testing.expectEqualStrings("bcd", doc.contents());

    doc.move(.document_end);
    try testing.expectEqual(Change.none, doc.delete());
}

test "the cursor walks off one line onto the next and back" {
    var bytes: [64]u8 = undefined;
    var index: [16]u32 = undefined;
    var doc = scratch(&bytes, &index, "ab\ncd");

    doc.move(.line_end);
    try testing.expectEqual(@as(usize, 2), doc.cursor.column);

    // Off the end of a line is the start of the next.
    doc.move(.right);
    try testing.expectEqual(@as(usize, 1), doc.cursor.line);
    try testing.expectEqual(@as(usize, 0), doc.cursor.column);

    // And off the front is the end of the one above.
    doc.move(.left);
    try testing.expectEqual(@as(usize, 0), doc.cursor.line);
    try testing.expectEqual(@as(usize, 2), doc.cursor.column);

    // The ends of the document stop rather than wrap.
    doc.move(.document_start);
    doc.move(.left);
    try testing.expectEqual(Cursor{ .line = 0, .column = 0 }, doc.cursor);
    doc.move(.document_end);
    doc.move(.right);
    try testing.expectEqual(@as(usize, 1), doc.cursor.line);
    try testing.expectEqual(@as(usize, 2), doc.cursor.column);
}

test "moving down past a short line remembers the column it wanted" {
    var bytes: [64]u8 = undefined;
    var index: [16]u32 = undefined;
    var doc = scratch(&bytes, &index, "long line here\nab\nanother long one");

    doc.cursor.column = 10;
    doc.wanted = 10;

    // Across the short line the cursor sits at its end, and past it goes
    // back where it was asked for. Without this it would walk left.
    doc.move(.down);
    try testing.expectEqual(@as(usize, 1), doc.cursor.line);
    try testing.expectEqual(@as(usize, 2), doc.cursor.column);

    doc.move(.down);
    try testing.expectEqual(@as(usize, 2), doc.cursor.line);
    try testing.expectEqual(@as(usize, 10), doc.cursor.column);

    // Typing sets a new column to want.
    _ = doc.insert('x');
    try testing.expectEqual(@as(usize, 11), doc.wanted);
}

test "the cursor moves by characters, not by bytes" {
    var bytes: [64]u8 = undefined;
    var index: [16]u32 = undefined;
    // Three characters, five bytes: the accented ones take two each.
    var doc = scratch(&bytes, &index, "éaç");

    try testing.expectEqual(@as(usize, 5), doc.len);
    try testing.expectEqual(@as(usize, 3), doc.lineWidth(0));

    doc.move(.right);
    try testing.expectEqual(@as(usize, 2), doc.cursor.column);
    try testing.expectEqual(@as(usize, 1), doc.column());

    doc.move(.right);
    try testing.expectEqual(@as(usize, 3), doc.cursor.column);
    doc.move(.left);
    try testing.expectEqual(@as(usize, 2), doc.cursor.column);

    // And deleting takes a whole character, never half of one.
    doc.move(.line_end);
    _ = doc.backspace();
    try testing.expectEqualStrings("éa", doc.contents());
    _ = doc.backspace();
    try testing.expectEqualStrings("é", doc.contents());
    _ = doc.backspace();
    try testing.expectEqualStrings("", doc.contents());
}

test "an accented character is inserted whole" {
    var bytes: [64]u8 = undefined;
    var index: [16]u32 = undefined;
    var doc = scratch(&bytes, &index, "");

    _ = doc.insert('e');
    _ = doc.insert('é');
    _ = doc.insert('e');
    try testing.expectEqualStrings("eée", doc.contents());
    try testing.expectEqual(@as(usize, 4), doc.len);
    try testing.expectEqual(@as(usize, 3), doc.column());
}

test "the cursor is put back inside a document that shrank under it" {
    var bytes: [64]u8 = undefined;
    var index: [16]u32 = undefined;
    var doc = scratch(&bytes, &index, "one\ntwo\nthree");

    doc.move(.document_end);
    try testing.expectEqual(@as(usize, 2), doc.cursor.line);

    doc.load("a");
    try testing.expectEqual(Cursor{ .line = 0, .column = 0 }, doc.cursor);
    try testing.expect(!doc.dirty);
}

test "a document with more lines than its index holds stops rather than overruns" {
    var bytes: [64]u8 = undefined;
    // Room for three lines and the entry past the last.
    var index: [4]u32 = undefined;
    var doc = scratch(&bytes, &index, "a\nb\nc\nd\ne");

    try testing.expect(doc.lines <= 3);
    try testing.expectEqualStrings("a", doc.line(0));
}

test "characters and byte offsets agree about where things are" {
    try testing.expectEqual(@as(usize, 0), characters(""));
    try testing.expectEqual(@as(usize, 3), characters("abc"));
    try testing.expectEqual(@as(usize, 3), characters("éaç"));

    try testing.expectEqual(@as(usize, 0), byteAt("éaç", 0));
    try testing.expectEqual(@as(usize, 2), byteAt("éaç", 1));
    try testing.expectEqual(@as(usize, 3), byteAt("éaç", 2));
    // Past the end is the end, which is where a cursor asking for a column
    // a short line does not have belongs.
    try testing.expectEqual(@as(usize, 5), byteAt("éaç", 3));
    try testing.expectEqual(@as(usize, 5), byteAt("éaç", 99));
}

test "a paragraph survives being typed, split, joined and read back" {
    var bytes: [256]u8 = undefined;
    var index: [32]u32 = undefined;
    var doc = scratch(&bytes, &index, "");

    for ("the quick brown fox") |c| _ = doc.insert(c);
    _ = doc.newline();
    for ("jumps over") |c| _ = doc.insert(c);

    try testing.expectEqual(@as(usize, 2), doc.lines);
    try testing.expectEqualStrings("the quick brown fox\njumps over", doc.contents());

    // Join them back into one line and the text is what it would have been
    // without the split at all.
    doc.move(.document_start);
    doc.move(.down);
    doc.move(.line_start);
    _ = doc.backspace();
    try testing.expectEqualStrings("the quick brown foxjumps over", doc.contents());
    try testing.expectEqual(@as(usize, 1), doc.lines);
}

test "indexing finds the lines, and the last one is the rule worth writing once" {
    var index: [8]u32 = undefined;

    // A text with no trailing separator has as many lines as it has pieces.
    try testing.expectEqual(@as(usize, 3), indexLines("a\nb\nc", &index));
    try testing.expectEqualStrings("a", lineAt("a\nb\nc", &index, 3, 0));
    try testing.expectEqualStrings("c", lineAt("a\nb\nc", &index, 3, 2));
    try testing.expectEqualStrings("", lineAt("a\nb\nc", &index, 3, 3));

    // One that does has an empty line after it, which is where the cursor
    // goes when you press enter at the end of a file.
    try testing.expectEqual(@as(usize, 3), indexLines("a\nb\n", &index));
    try testing.expectEqualStrings("", lineAt("a\nb\n", &index, 3, 2));

    // Nothing at all is one empty line, because a cursor has to be somewhere.
    try testing.expectEqual(@as(usize, 1), indexLines("", &index));
    try testing.expectEqualStrings("", lineAt("", &index, 1, 0));

    // Empty lines in the middle are lines.
    try testing.expectEqual(@as(usize, 3), indexLines("a\n\nb", &index));
    try testing.expectEqualStrings("", lineAt("a\n\nb", &index, 3, 1));
}

test "indexing stops at the room it was given rather than overrunning it" {
    var small: [3]u32 = undefined;
    const many = "a\nb\nc\nd\ne\nf";
    const found = indexLines(many, &small);

    try testing.expect(found <= 2);
    try testing.expectEqualStrings("a", lineAt(many, &small, found, 0));

    // No room at all is no lines, not a write past the end.
    var none: [0]u32 = undefined;
    try testing.expectEqual(@as(usize, 0), indexLines(many, &none));
}

test "a character's width is its own, and a byte that begins nothing is one" {
    try testing.expectEqual(@as(usize, 1), charWidth("abc", 0));
    try testing.expectEqual(@as(usize, 2), charWidth("é", 0));
    try testing.expectEqual(@as(usize, 3), charWidth("€", 0));

    // Malformed text moves a cursor rather than trapping it.
    try testing.expectEqual(@as(usize, 1), charWidth(&[_]u8{0x80}, 0));

    // And a truncated character is only as wide as what is there.
    try testing.expectEqual(@as(usize, 1), charWidth("é"[0..1], 0));
}

test "a window takes the characters a screen has room for" {
    try testing.expectEqualStrings("abc", window("abcdef", 0, 3));
    try testing.expectEqualStrings("cde", window("abcdef", 2, 3));
    // Past the end clips rather than reaching.
    try testing.expectEqualStrings("ef", window("abcdef", 4, 9));
    try testing.expectEqualStrings("", window("abcdef", 9, 3));
    try testing.expectEqualStrings("", window("abcdef", 0, 0));

    // And it counts characters, so a window never cuts one in half.
    try testing.expectEqualStrings("é", window("éaç", 0, 1));
    try testing.expectEqualStrings("aç", window("éaç", 1, 2));
    try testing.expectEqualStrings("", window("éaç", 3, 1));
}

test "a window follows a position without jumping further than it must" {
    // Already inside: nothing moves.
    try testing.expectEqual(@as(usize, 10), follow(10, 5, 12));
    try testing.expectEqual(@as(usize, 10), follow(10, 5, 10));
    try testing.expectEqual(@as(usize, 10), follow(10, 5, 14));

    // One past the end moves it by one, not by a screenful.
    try testing.expectEqual(@as(usize, 11), follow(10, 5, 15));
    try testing.expectEqual(@as(usize, 16), follow(10, 5, 20));

    // Above it moves back to exactly there.
    try testing.expectEqual(@as(usize, 9), follow(10, 5, 9));
    try testing.expectEqual(@as(usize, 0), follow(10, 5, 0));

    // A window of nothing is wherever it is asked to be.
    try testing.expectEqual(@as(usize, 7), follow(0, 0, 7));
}
