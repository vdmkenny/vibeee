//! A page as this reader keeps it: the words in order, and what each run of
//! them is.
//!
//! The parser builds a tree of every element and attribute a page had, which
//! is far more than a reader draws and, on a large page, several times the
//! page's own size. So the tree is walked once into this and let go: one
//! buffer of text, runs over it, blocks over the runs, and the strings the
//! runs refer to beside them. Nothing here points into the tree, so the tree
//! can go the moment the walk ends.
//!
//! Pure and host-tested. Whether a space landed inside a link or outside it
//! is decided here, and is not something to find out on the panel.

const std = @import("std");

const Writer = std.Io.Writer;

/// Which face words are set in. The reader has the interface family's two
/// sizes and its monospaced face, and every element maps onto one of the
/// three. There is no bold and no italic to map onto, so emphasis a page asks
/// for reads as plain text rather than as a guess at it.
pub const Face = enum(u2) { body, heading, mono };

/// What words are inked in: the text, the dim ink for what a page says about
/// itself rather than to the reader (an image's description), or the accent
/// a link is.
pub const Ink = enum(u2) { text, dim, link };

/// How words look. Packed, so that two looks compare as one small value.
pub const Look = packed struct(u4) {
    face: Face = .body,
    ink: Ink = .text,
};

/// Words in one look, going to one link or to none.
pub const Text = struct {
    /// Into the page's text.
    start: u32,
    len: u32,
    look: Look,
    /// Which of the page's links, if any.
    link: ?u16 = null,
};

/// A piece of a block.
pub const Run = union(enum) {
    text: Text,
    /// The line ends here: a `<br>`, or a line end in preformatted text.
    line_break,
};

pub const Kind = enum(u3) {
    paragraph,
    heading,
    /// A list entry, with its marker in the margin.
    item,
    /// Text whose spaces and line ends are the page's own.
    preformatted,
    /// A horizontal rule: no runs, only the line.
    rule,
};

pub const Marker = union(enum) {
    none,
    bullet,
    number: u32,

    /// The marker as it is written: `bullet` for a bulleted entry, and the
    /// number and a full stop for a numbered one.
    pub fn write(self: Marker, w: *Writer, bullet: []const u8) Writer.Error!void {
        switch (self) {
            .none => {},
            .bullet => try w.writeAll(bullet),
            .number => |n| try w.print("{d}.", .{n}),
        }
    }
};

/// A block, or, before it has any runs, what the next one will be.
pub const Block = struct {
    kind: Kind = .paragraph,
    /// One step in for every list or quotation it sits inside.
    depth: u8 = 0,
    /// Inside a quotation, which puts a bar down its margin.
    quoted: bool = false,
    marker: Marker = .none,
    /// Its runs, which a block still to be opened does not have.
    first: u32 = 0,
    count: u32 = 0,
};

/// Where a string is among the page's strings.
const Span = struct { at: u32, len: u32 };

pub const Page = struct {
    title: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(Run) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    /// What the page keeps beside its words, one string after another.
    strings: std.ArrayList(u8) = .empty,
    /// Where each link goes, in `strings`.
    links: std.ArrayList(Span) = .empty,

    pub fn deinit(self: *Page, gpa: std.mem.Allocator) void {
        // Every field is a list the page owns.
        inline for (std.meta.fields(Page)) |field| @field(self, field.name).deinit(gpa);
        self.* = .{};
    }

    pub fn runsOf(self: *const Page, block: Block) []const Run {
        return self.runs.items[block.first..][0..block.count];
    }

    pub fn textOf(self: *const Page, text: Text) []const u8 {
        return self.text.items[text.start..][0..text.len];
    }

    /// Where a link goes.
    pub fn address(self: *const Page, link: u16) ?[]const u8 {
        if (link >= self.links.items.len) return null;
        const span = self.links.items[link];
        return self.strings.items[span.at..][0..span.len];
    }
};

/// Fills a page from a walk: words as the walk finds them, and a boundary
/// wherever an element starts or ends a block.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    page: *Page,

    /// How the next words look, and where they go.
    look: Look = .{},
    link: ?u16 = null,

    next: Block = .{},
    /// The block being filled. Opened by the first thing put in it, so a
    /// boundary with nothing after it before the next leaves no empty block.
    open: ?Block = null,
    /// A space is owed between what came last and whatever comes next. Owed
    /// rather than written, so none lands at the end of a block.
    space: bool = false,
    /// Characters since the last line end in preformatted text, for tabs.
    column: usize = 0,

    pub const Error = std.mem.Allocator.Error;

    /// End the block being filled, if anything was put in it, and say what
    /// the next one will be.
    pub fn boundary(self: *Builder, next: Block) Error!void {
        try self.close();
        self.next = next;
    }

    pub fn finish(self: *Builder) Error!void {
        try self.close();
    }

    /// The page's title, with its spaces made single.
    pub fn title(self: *Builder, text: []const u8) Error!void {
        var parts = std.mem.tokenizeAny(u8, text, &std.ascii.whitespace);
        while (parts.next()) |word| {
            if (self.page.title.items.len > 0) try self.page.title.append(self.gpa, ' ');
            try self.page.title.appendSlice(self.gpa, word);
        }
    }

    /// Words from the page.
    ///
    /// Spaces and line ends collapse to one space between words and none at
    /// either end of a block, which is what the specification asks of text
    /// that is not preformatted. In preformatted text they are the page's
    /// own: a tab is spaces to the next stop, and a line end ends the line.
    pub fn words(self: *Builder, bytes: []const u8) Error!void {
        if (self.next.kind == .preformatted) return self.verbatim(bytes);

        var i: usize = 0;
        while (i < bytes.len) {
            if (std.ascii.isWhitespace(bytes[i])) {
                if (self.lastText() != null) self.space = true;
                i += 1;
                continue;
            }
            const end = std.mem.indexOfAnyPos(u8, bytes, i, &std.ascii.whitespace) orelse bytes.len;
            try self.settleSpace();
            try self.put(bytes[i..end]);
            i = end;
        }
    }

    /// End the line here. A break with nothing before it on its line is a
    /// line of its own, which is what two breaks in a row are for.
    pub fn lineBreak(self: *Builder) Error!void {
        self.space = false;
        self.column = 0;
        const block = self.opened();
        try self.page.runs.append(self.gpa, .line_break);
        block.count += 1;
    }

    /// A horizontal rule, which is a block of its own.
    pub fn rule(self: *Builder) Error!void {
        try self.close();
        try self.page.blocks.append(self.gpa, .{
            .kind = .rule,
            .depth = self.next.depth,
            .quoted = self.next.quoted,
            .first = @intCast(self.page.runs.items.len),
        });
    }

    /// Keep an address, and say which link it is. Past the last number a
    /// link can have, the words still read and simply go nowhere.
    pub fn addLink(self: *Builder, address: []const u8) Error!?u16 {
        const index = std.math.cast(u16, self.page.links.items.len) orelse return null;
        try self.page.links.append(self.gpa, try self.keep(address));
        return index;
    }

    /// Keep a string beside the page's words.
    fn keep(self: *Builder, bytes: []const u8) Error!Span {
        const at: u32 = @intCast(self.page.strings.items.len);
        try self.page.strings.appendSlice(self.gpa, bytes);
        return .{ .at = at, .len = @intCast(bytes.len) };
    }

    fn close(self: *Builder) Error!void {
        if (self.open) |block| {
            if (block.count > 0) try self.page.blocks.append(self.gpa, block);
        }
        self.open = null;
        self.space = false;
        self.column = 0;
    }

    /// The words the open block ends in, where it ends in words rather than
    /// at a break or before anything was put in it. A space is owed only
    /// between words, never at the start of a line a break has just begun.
    fn lastText(self: *Builder) ?*Text {
        const block = self.open orelse return null;
        if (block.count == 0) return null;
        return switch (self.page.runs.items[self.page.runs.items.len - 1]) {
            .text => |*last| last,
            .line_break => null,
        };
    }

    fn opened(self: *Builder) *Block {
        if (self.open == null) {
            var block = self.next;
            block.first = @intCast(self.page.runs.items.len);
            block.count = 0;
            self.open = block;
            // The marker belongs to an entry's first block, not to every
            // block the entry happens to hold.
            self.next.marker = .none;
        }
        return &self.open.?;
    }

    /// Put `bytes` in the open block in the current look, lengthening the
    /// last run when it looks the same and goes to the same place.
    fn put(self: *Builder, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        const block = self.opened();
        const start: u32 = @intCast(self.page.text.items.len);
        try self.page.text.appendSlice(self.gpa, bytes);
        if (self.lastText()) |last| {
            if (last.look == self.look and last.link == self.link and last.start + last.len == start) {
                last.len += @intCast(bytes.len);
                return;
            }
        }
        try self.page.runs.append(self.gpa, .{ .text = .{
            .start = start,
            .len = @intCast(bytes.len),
            .look = self.look,
            .link = self.link,
        } });
        block.count += 1;
    }

    /// Write an owed space before the next word: in that word's look, unless
    /// the word starts a link, which would underline a space ahead of it. It
    /// goes on the end of what came before instead.
    fn settleSpace(self: *Builder) Error!void {
        if (!self.space) return;
        self.space = false;
        const last = self.lastText() orelse return;
        if (self.link == null) return self.put(" ");
        try self.page.text.append(self.gpa, ' ');
        last.len += 1;
    }

    fn verbatim(self: *Builder, bytes: []const u8) Error!void {
        var i: usize = 0;
        while (i < bytes.len) {
            switch (bytes[i]) {
                '\r' => i += 1,
                '\n' => {
                    try self.lineBreak();
                    i += 1;
                },
                '\t' => {
                    const to = TAB - self.column % TAB;
                    try self.put(("        ")[0..to]);
                    self.column += to;
                    i += 1;
                },
                else => {
                    const end = std.mem.indexOfAnyPos(u8, bytes, i, "\r\n\t") orelse bytes.len;
                    try self.put(bytes[i..end]);
                    self.column += std.unicode.utf8CountCodepoints(bytes[i..end]) catch end - i;
                    i = end;
                },
            }
        }
    }
};

/// Where a tab in preformatted text stops.
const TAB = 8;

/// The page as plain text, for a terminal: blocks apart by a blank line, a
/// list's entries under one another with their markers, preformatted text as
/// it was. What `web -t` prints, so the words a window shows and the words a
/// pipe gets are the same words.
pub fn writeText(page: *const Page, w: *Writer) Writer.Error!void {
    var previous: ?Kind = null;
    for (page.blocks.items) |block| {
        if (previous) |kind| {
            // A list's entries follow one another; everything else stands
            // apart by a blank line.
            try w.writeAll(if (kind == .item and block.kind == .item) "\n" else "\n\n");
        }
        previous = block.kind;

        const indent = 2 * @as(usize, block.depth);
        try w.splatByteAll(' ', indent);
        try block.marker.write(w, "-");
        if (block.marker != .none) try w.writeByte(' ');
        if (block.kind == .rule) {
            try w.writeAll("----");
            continue;
        }

        const runs = page.runsOf(block);
        for (runs, 0..) |run, i| switch (run) {
            .text => |text| try w.writeAll(page.textOf(text)),
            // A break the block ends on is the block's own end already.
            .line_break => if (i + 1 < runs.len) {
                try w.writeByte('\n');
                try w.splatByteAll(' ', indent);
            },
        };
    }
    if (previous != null) try w.writeByte('\n');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    page: Page = .{},
    builder: Builder = undefined,

    fn init(self: *Fixture) void {
        self.builder = .{ .gpa = testing.allocator, .page = &self.page };
    }

    fn deinit(self: *Fixture) void {
        self.page.deinit(testing.allocator);
    }

    fn runText(self: *const Fixture, index: usize) []const u8 {
        return self.page.textOf(self.page.runs.items[index].text);
    }

    fn written(self: *const Fixture) !std.Io.Writer.Allocating {
        var text: std.Io.Writer.Allocating = .init(testing.allocator);
        try writeText(&self.page, &text.writer);
        return text;
    }
};

test "spaces collapse between words and vanish at a block's edges" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    try f.builder.words("  \n hello   \t world \n ");
    try f.builder.finish();
    try testing.expectEqual(@as(usize, 1), f.page.blocks.items.len);
    try testing.expectEqualStrings("hello world", f.page.text.items);
}

test "a space before a link stays outside it" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    try f.builder.words("see ");
    f.builder.link = try f.builder.addLink("https://a.org/");
    f.builder.look.ink = .link;
    try f.builder.words("the page");
    f.builder.link = null;
    f.builder.look.ink = .text;
    try f.builder.words(" now");
    try f.builder.finish();

    try testing.expectEqual(@as(usize, 3), f.page.runs.items.len);
    try testing.expectEqualStrings("see ", f.runText(0));
    try testing.expectEqualStrings("the page", f.runText(1));
    try testing.expectEqualStrings(" now", f.runText(2));
    try testing.expectEqualStrings("https://a.org/", f.page.address(f.page.runs.items[1].text.link.?).?);
}

test "text that looks the same is one run, across the pieces it arrives in" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    try f.builder.words("one ");
    try f.builder.words("two");
    try f.builder.words(" three");
    try f.builder.finish();
    try testing.expectEqual(@as(usize, 1), f.page.runs.items.len);
    try testing.expectEqualStrings("one two three", f.runText(0));
}

test "a boundary with nothing before the next leaves no empty block" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    try f.builder.boundary(.{});
    try f.builder.boundary(.{ .kind = .heading });
    try f.builder.words("Title");
    try f.builder.boundary(.{});
    try f.builder.boundary(.{});
    try f.builder.words("Body");
    try f.builder.finish();
    try testing.expectEqual(@as(usize, 2), f.page.blocks.items.len);
    try testing.expectEqual(Kind.heading, f.page.blocks.items[0].kind);
    try testing.expectEqual(Kind.paragraph, f.page.blocks.items[1].kind);
}

test "a marker goes on an entry's first block only" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    try f.builder.boundary(.{ .kind = .item, .depth = 1, .marker = .{ .number = 3 } });
    try f.builder.words("first");
    try f.builder.boundary(f.builder.next);
    try f.builder.words("more of the same entry");
    try f.builder.finish();
    try testing.expectEqual(Marker{ .number = 3 }, f.page.blocks.items[0].marker);
    try testing.expectEqual(Marker.none, f.page.blocks.items[1].marker);
    try testing.expectEqual(@as(u8, 1), f.page.blocks.items[1].depth);
}

test "preformatted text keeps its spaces, stops its tabs and ends its lines" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    try f.builder.boundary(.{ .kind = .preformatted });
    try f.builder.words("a\tb\n  c\r\n\nd");
    try f.builder.finish();
    var text = try f.written();
    defer text.deinit();
    try testing.expectEqualStrings("a       b\n  c\n\nd\n", text.written());
}

test "a break ends a line, and two make an empty one" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    try f.builder.words("one");
    try f.builder.lineBreak();
    try f.builder.lineBreak();
    try f.builder.words(" two");
    try f.builder.finish();
    const runs = f.page.runs.items;
    try testing.expectEqual(@as(usize, 4), runs.len);
    try testing.expect(runs[1] == .line_break and runs[2] == .line_break);
    // No space at the start of the line after a break.
    try testing.expectEqualStrings("two", f.runText(3));
}

test "a rule is a block of its own, and the text reads as the page did" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    try f.builder.boundary(.{ .kind = .heading });
    try f.builder.words("Storage");
    try f.builder.boundary(.{});
    try f.builder.words("Sequential is fine.");
    try f.builder.rule();
    try f.builder.boundary(.{ .kind = .item, .depth = 1, .marker = .bullet });
    try f.builder.words("one");
    try f.builder.boundary(.{ .kind = .item, .depth = 1, .marker = .bullet });
    try f.builder.words("two");
    try f.builder.finish();

    var text = try f.written();
    defer text.deinit();
    try testing.expectEqualStrings("Storage\n\nSequential is fine.\n\n----\n\n  - one\n  - two\n", text.written());
}

test "a title has its spaces made single" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    try f.builder.title("\n  Storage on\tthe  701 \n");
    try testing.expectEqualStrings("Storage on the 701", f.page.title.items);
}
