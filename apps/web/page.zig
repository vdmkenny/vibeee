//! A page as this reader keeps it: the words in order, and what each run of
//! them is.
//!
//! The parser builds a tree of every element and attribute a page had, which
//! is far more than a reader draws and, on a large page, several times the
//! page's own size. So the tree is walked once into this and let go: one
//! buffer of text, runs over it, blocks over the runs, and the links beside
//! them. Nothing here points into the tree, so the tree can go the moment the
//! walk ends.
//!
//! Pure and host-tested. Whether a space landed inside a link or outside it
//! is decided here, and is not something to find out on the panel.

const std = @import("std");

/// Which face a run is set in. The reader has the interface family's two
/// sizes and its monospaced face, and every element maps onto one of the
/// three. There is no bold and no italic to map onto, so emphasis a page asks
/// for reads as plain text rather than as a guess at it.
pub const Face = enum(u2) { body, heading, mono };

/// What a run is inked in: the text, the dim ink for what a page says about
/// itself rather than to the reader (an image's description), or the accent
/// a link is.
pub const Ink = enum(u2) { text, dim, link };

/// A run that goes nowhere.
pub const NO_LINK: u16 = std.math.maxInt(u16);

pub const Run = struct {
    start: u32,
    len: u32,
    face: Face,
    ink: Ink,
    link: u16 = NO_LINK,
    /// The line ends after this run: a `<br>`, or a line end in preformatted
    /// text. A run that is only a break has nothing in it.
    breaks: bool = false,

    fn looksLike(self: Run, face: Face, ink: Ink, link: u16) bool {
        return self.face == face and self.ink == ink and self.link == link;
    }
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
};

pub const Block = struct {
    kind: Kind,
    /// One step in for every list or quotation it sits inside.
    depth: u8 = 0,
    /// Inside a quotation, which puts a bar down its margin.
    quoted: bool = false,
    marker: Marker = .none,
    first: u32 = 0,
    count: u32 = 0,
};

const Span = struct { at: u32, len: u32 };

pub const Page = struct {
    title: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(Run) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    /// Every link's address, one after another, and where each one is.
    addresses: std.ArrayList(u8) = .empty,
    links: std.ArrayList(Span) = .empty,

    pub fn deinit(self: *Page, gpa: std.mem.Allocator) void {
        self.title.deinit(gpa);
        self.text.deinit(gpa);
        self.runs.deinit(gpa);
        self.blocks.deinit(gpa);
        self.addresses.deinit(gpa);
        self.links.deinit(gpa);
        self.* = .{};
    }

    pub fn runsOf(self: *const Page, block: Block) []const Run {
        return self.runs.items[block.first..][0..block.count];
    }

    pub fn textOf(self: *const Page, run: Run) []const u8 {
        return self.text.items[run.start..][0..run.len];
    }

    /// Where a link goes, or nothing for a run that is not one.
    pub fn address(self: *const Page, link: u16) ?[]const u8 {
        if (link == NO_LINK or link >= self.links.items.len) return null;
        const span = self.links.items[link];
        return self.addresses.items[span.at..][0..span.len];
    }
};

/// What the next block will be, once text arrives to start it.
pub const Context = struct {
    kind: Kind = .paragraph,
    depth: u8 = 0,
    quoted: bool = false,
    marker: Marker = .none,
};

/// Fills a page from a walk: words as the walk finds them, and a boundary
/// wherever an element starts or ends a block.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    page: *Page,

    /// How the next words look.
    face: Face = .body,
    ink: Ink = .text,
    link: u16 = NO_LINK,

    next: Context = .{},
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
    pub fn boundary(self: *Builder, next: Context) Error!void {
        try self.close();
        self.next = next;
    }

    pub fn finish(self: *Builder) Error!void {
        try self.close();
    }

    /// The page's title, with its spaces made single.
    pub fn title(self: *Builder, text: []const u8) Error!void {
        var parts = std.mem.tokenizeAny(u8, text, " \t\r\n\x0c");
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
            if (isSpace(bytes[i])) {
                if (self.midLine()) self.space = true;
                i += 1;
                continue;
            }
            var end = i;
            while (end < bytes.len and !isSpace(bytes[end])) end += 1;
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
        if (block.count > 0) {
            const last = &self.page.runs.items[self.page.runs.items.len - 1];
            if (!last.breaks) {
                last.breaks = true;
                return;
            }
        }
        try self.page.runs.append(self.gpa, .{
            .start = @intCast(self.page.text.items.len),
            .len = 0,
            .face = self.face,
            .ink = self.ink,
            .breaks = true,
        });
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
    /// link can have, the text still reads and simply goes nowhere.
    pub fn addLink(self: *Builder, address: []const u8) Error!u16 {
        if (self.page.links.items.len >= NO_LINK) return NO_LINK;
        const at: u32 = @intCast(self.page.addresses.items.len);
        try self.page.addresses.appendSlice(self.gpa, address);
        try self.page.links.append(self.gpa, .{ .at = at, .len = @intCast(address.len) });
        return @intCast(self.page.links.items.len - 1);
    }

    fn close(self: *Builder) Error!void {
        if (self.open) |block| {
            if (block.count > 0) try self.page.blocks.append(self.gpa, block);
        }
        self.open = null;
        self.space = false;
        self.column = 0;
    }

    /// Whether the line being filled has words on it. A space is owed only
    /// between words, never at the start of a line a break has just begun.
    fn midLine(self: *const Builder) bool {
        const block = self.open orelse return false;
        if (block.count == 0) return false;
        return !self.page.runs.items[self.page.runs.items.len - 1].breaks;
    }

    fn opened(self: *Builder) *Block {
        if (self.open == null) {
            self.open = .{
                .kind = self.next.kind,
                .depth = self.next.depth,
                .quoted = self.next.quoted,
                .marker = self.next.marker,
                .first = @intCast(self.page.runs.items.len),
            };
            // The marker belongs to an entry's first block, not to every
            // block the entry happens to hold.
            self.next.marker = .none;
        }
        return &self.open.?;
    }

    /// Put `bytes` in the open block in the current look, lengthening the
    /// last run when it looks the same.
    fn put(self: *Builder, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        const block = self.opened();
        const start: u32 = @intCast(self.page.text.items.len);
        try self.page.text.appendSlice(self.gpa, bytes);
        if (block.count > 0) {
            const last = &self.page.runs.items[self.page.runs.items.len - 1];
            if (!last.breaks and last.looksLike(self.face, self.ink, self.link) and last.start + last.len == start) {
                last.len += @intCast(bytes.len);
                return;
            }
        }
        try self.page.runs.append(self.gpa, .{
            .start = start,
            .len = @intCast(bytes.len),
            .face = self.face,
            .ink = self.ink,
            .link = self.link,
        });
        block.count += 1;
    }

    /// Write an owed space before the next word: in that word's look, unless
    /// the word starts a link, which would underline a space ahead of it. It
    /// goes on the end of what came before instead.
    fn settleSpace(self: *Builder) Error!void {
        if (!self.space) return;
        self.space = false;
        if (!self.midLine()) return;
        if (self.link == NO_LINK) return self.put(" ");

        try self.page.text.append(self.gpa, ' ');
        self.page.runs.items[self.page.runs.items.len - 1].len += 1;
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
                    var end = i;
                    while (end < bytes.len and bytes[end] != '\n' and bytes[end] != '\r' and bytes[end] != '\t') end += 1;
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

fn isSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0c => true,
        else => false,
    };
}

/// The page as plain text, for a terminal: blocks apart by a blank line, a
/// list's entries under one another with their markers, preformatted text as
/// it was. What `web -t` prints, so the words a window shows and the words a
/// pipe gets are the same words.
///
/// `sink` is anything with `text(bytes)`.
pub fn writeText(page: *const Page, sink: anytype) void {
    var previous: ?Kind = null;
    for (page.blocks.items) |block| {
        if (previous) |kind| {
            // A list's entries follow one another; everything else stands
            // apart by a blank line.
            sink.text(if (kind == .item and block.kind == .item) "\n" else "\n\n");
        }
        previous = block.kind;

        indent(sink, block.depth);
        switch (block.marker) {
            .none => {},
            .bullet => sink.text("- "),
            .number => |n| {
                var digits: [16]u8 = undefined;
                sink.text(std.fmt.bufPrint(&digits, "{d}. ", .{n}) catch "");
            },
        }
        if (block.kind == .rule) {
            sink.text("----");
            continue;
        }

        const runs = page.runsOf(block);
        for (runs, 0..) |run, i| {
            sink.text(page.textOf(run));
            if (run.breaks and i + 1 < runs.len) {
                sink.text("\n");
                indent(sink, block.depth);
            }
        }
    }
    if (previous != null) sink.text("\n");
}

fn indent(sink: anytype, depth: u8) void {
    var n: u8 = 0;
    while (n < depth) : (n += 1) sink.text("  ");
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
        return self.page.textOf(self.page.runs.items[index]);
    }
};

const Collect = struct {
    buf: std.ArrayList(u8) = .empty,
    fn text(self: *Collect, bytes: []const u8) void {
        self.buf.appendSlice(testing.allocator, bytes) catch unreachable;
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
    f.builder.ink = .link;
    try f.builder.words("the page");
    f.builder.link = NO_LINK;
    f.builder.ink = .text;
    try f.builder.words(" now");
    try f.builder.finish();

    try testing.expectEqual(@as(usize, 3), f.page.runs.items.len);
    try testing.expectEqualStrings("see ", f.runText(0));
    try testing.expectEqualStrings("the page", f.runText(1));
    try testing.expectEqualStrings(" now", f.runText(2));
    try testing.expectEqualStrings("https://a.org/", f.page.address(f.page.runs.items[1].link).?);
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
    var c = Collect{};
    defer c.buf.deinit(testing.allocator);
    writeText(&f.page, &c);
    try testing.expectEqualStrings("a       b\n  c\n\nd\n", c.buf.items);
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
    try testing.expectEqual(@as(usize, 3), f.page.runs.items.len);
    try testing.expect(f.page.runs.items[0].breaks);
    try testing.expectEqual(@as(u32, 0), f.page.runs.items[1].len);
    // No space at the start of the line after a break.
    try testing.expectEqualStrings("two", f.runText(2));
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

    var c = Collect{};
    defer c.buf.deinit(testing.allocator);
    writeText(&f.page, &c);
    try testing.expectEqualStrings("Storage\n\nSequential is fine.\n\n----\n\n  - one\n  - two\n", c.buf.items);
}

test "a title has its spaces made single" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    try f.builder.title("\n  Storage on\tthe  701 \n");
    try testing.expectEqualStrings("Storage on the 701", f.page.title.items);
}
