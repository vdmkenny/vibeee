//! Where every word of a page goes, in a column a given number of pixels
//! wide.
//!
//! Done once for a page and a width, not once a frame. The lines are what a
//! view draws from, and scrolling is only which of them are on screen. A word
//! is measured once, where it is placed, and the words of one run that land
//! on one line are one fragment drawn with one call, because the space
//! between them is in the text already.
//!
//! Pure arithmetic over a page and something that measures, host-tested with
//! a measure of a fixed width a byte.

const std = @import("std");
const page_mod = @import("page.zig");

const Page = page_mod.Page;
const Block = page_mod.Block;
const Face = page_mod.Face;

pub const Error = std.mem.Allocator.Error;

/// Words from one run, together on one line.
pub const Frag = struct {
    /// From the column's left edge.
    x: i32,
    width: i32,
    /// Into the page's text.
    start: u32,
    len: u32,
    /// The run it belongs to, which says its face, its ink and where it goes.
    run: u32,
};

pub const Line = struct {
    /// From the top of the page.
    y: i32,
    height: i32,
    /// How far below `y` the baseline is, which every fragment on the line
    /// shares whatever its face.
    baseline: i32,
    first: u32,
    count: u32,
    block: u32,
    /// The first line of its block: where a list marker goes, and where a
    /// preformatted band begins.
    leads: bool,
};

/// The room between and around blocks, from the height of a line of body
/// text, so a page set larger spaces larger with it.
pub const Spacing = struct {
    paragraph: i32,
    above_heading: i32,
    below_heading: i32,
    /// Between the entries of one list, which read as a group.
    item: i32,
    /// How far in each list or quotation steps.
    indent: i32,
    /// Around preformatted text, inside the band it sits on.
    inset: i32,
    /// A rule's height; the line is in the middle of it.
    rule: i32,

    pub fn forLine(height: i32) Spacing {
        return .{
            .paragraph = @divTrunc(height * 2, 3),
            .above_heading = height,
            .below_heading = @divTrunc(height, 3),
            .item = @divTrunc(height, 6),
            .indent = height + 4,
            .inset = @divTrunc(height, 2),
            .rule = height,
        };
    }
};

pub const Layout = struct {
    lines: std.ArrayList(Line) = .empty,
    frags: std.ArrayList(Frag) = .empty,
    /// How tall the whole page is.
    height: i32 = 0,
    /// The column it was laid out for, which is what says it needs doing
    /// again.
    width: i32 = 0,

    pub fn deinit(self: *Layout, gpa: std.mem.Allocator) void {
        self.lines.deinit(gpa);
        self.frags.deinit(gpa);
        self.* = .{};
    }

    pub fn fragsOf(self: *const Layout, line: Line) []const Frag {
        return self.frags.items[line.first..][0..line.count];
    }

    /// The first line reaching below `y`, which is where drawing a view that
    /// starts at `y` begins. Halving rather than walking: a long page has
    /// thousands of lines and a scroll asks this every pass.
    pub fn lineAt(self: *const Layout, y: i32) usize {
        var lo: usize = 0;
        var hi = self.lines.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const line = self.lines.items[mid];
            if (line.y + line.height <= y) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

/// Lay `page` out `width` pixels wide.
///
/// `metrics` answers four questions of a face: `width(face, bytes)`,
/// `height(face)`, `ascent(face)`, and `fit(face, bytes, room)`, how many of
/// the bytes fit in that many pixels, at a letter's edge.
pub fn build(gpa: std.mem.Allocator, page: *const Page, width: i32, spacing: Spacing, metrics: anytype) Error!Layout {
    var out = Layout{ .width = width };
    errdefer out.deinit(gpa);

    var p = Placer(@TypeOf(metrics)){ .gpa = gpa, .page = page, .out = &out, .metrics = metrics };

    var previous: ?Block = null;
    for (page.blocks.items, 0..) |block, index| {
        if (previous) |before| p.y += gap(spacing, before, block);
        previous = block;

        p.block = @intCast(index);
        p.leads = true;
        p.startLine();

        const inset: i32 = if (block.kind == .preformatted) spacing.inset else 0;
        p.x0 = @as(i32, block.depth) * spacing.indent + inset;
        // Never narrower than a few letters: a list nested past the column's
        // edge still has to put its words somewhere.
        p.room = @max(width - p.x0 - inset, spacing.indent * 2);

        if (block.kind == .rule) {
            try out.lines.append(gpa, .{
                .y = p.y,
                .height = spacing.rule,
                .baseline = 0,
                .first = @intCast(out.frags.items.len),
                .count = 0,
                .block = @intCast(index),
                .leads = true,
            });
            p.y += spacing.rule;
            continue;
        }

        p.y += inset;
        if (block.kind == .preformatted) {
            for (page.runsOf(block), 0..) |run, k| {
                try p.cut(block.first + @as(u32, @intCast(k)), run.start, page.textOf(run));
                if (run.breaks) try p.endLine(run.face, true);
            }
        } else {
            try p.flow(block.first, block.first + block.count);
        }
        try p.endLine(.body, false);
        p.y += inset;
    }

    out.height = p.y;
    return out;
}

/// The room above `block`, given what came before it.
fn gap(spacing: Spacing, before: Block, block: Block) i32 {
    if (block.kind == .heading) return spacing.above_heading;
    if (before.kind == .heading) return spacing.below_heading;
    if (before.kind == .item and block.kind == .item) return spacing.item;
    return spacing.paragraph;
}

/// A place in a block's text: a run, and a byte of its text.
const Spot = struct { run: u32, at: usize };

fn Placer(comptime Metrics: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        page: *const Page,
        out: *Layout,
        metrics: Metrics,

        y: i32 = 0,
        block: u32 = 0,
        leads: bool = false,
        /// Where the block's text starts from the column edge, and how much
        /// of the column it has.
        x0: i32 = 0,
        room: i32 = 0,

        /// The line being filled: how far along it the next word goes, its
        /// first fragment, and the tallest face on it so far.
        pen: i32 = 0,
        first: u32 = 0,
        ascent: i32 = 0,
        descent: i32 = 0,

        fn startLine(self: *Self) void {
            self.pen = 0;
            self.first = @intCast(self.out.frags.items.len);
            self.ascent = 0;
            self.descent = 0;
        }

        fn occupied(self: *const Self) bool {
            return self.out.frags.items.len > self.first;
        }

        fn grow(self: *Self, face: Face) void {
            const ascent = self.metrics.ascent(face);
            self.ascent = @max(self.ascent, ascent);
            self.descent = @max(self.descent, self.metrics.height(face) - ascent);
        }

        /// Close the line being filled. One with nothing on it is kept only
        /// when a break asked for it, as tall as `face`.
        fn endLine(self: *Self, face: Face, keep_empty: bool) Error!void {
            if (self.occupied()) {
                // A line ends where its last word does. The space after that
                // word is in the text, and would only lengthen what a link's
                // underline runs under.
                const last = &self.out.frags.items[self.out.frags.items.len - 1];
                if (last.len > 0 and self.page.text.items[last.start + last.len - 1] == ' ') {
                    last.len -= 1;
                    last.width -= self.metrics.width(self.page.runs.items[last.run].face, " ");
                }
            } else {
                if (!keep_empty) return;
                self.grow(face);
            }

            try self.out.lines.append(self.gpa, .{
                .y = self.y,
                .height = self.ascent + self.descent,
                .baseline = self.ascent,
                .first = self.first,
                .count = @intCast(self.out.frags.items.len - self.first),
                .block = self.block,
                .leads = self.leads,
            });
            self.y += self.ascent + self.descent;
            self.leads = false;
            self.startLine();
        }

        /// Put text on the line, joining the fragment before it where that
        /// is the same run and the text follows on.
        fn add(self: *Self, run: u32, start: u32, len: u32, width: i32) Error!void {
            self.grow(self.page.runs.items[run].face);
            self.pen += width;
            if (self.occupied()) {
                const last = &self.out.frags.items[self.out.frags.items.len - 1];
                if (last.run == run and last.start + last.len == start) {
                    last.len += len;
                    last.width += width;
                    return;
                }
            }
            try self.out.frags.append(self.gpa, .{
                .x = self.x0 + self.pen - width,
                .width = width,
                .start = start,
                .len = len,
                .run = run,
            });
        }

        /// The words of runs `first` up to `last`, broken onto lines at their
        /// spaces. A word runs on from one run into the next where a link or
        /// a change of face falls inside it, so a line never breaks where two
        /// runs meet unless there is a space there.
        fn flow(self: *Self, first: u32, last: u32) Error!void {
            var here = Spot{ .run = first, .at = 0 };
            while (here.run < last) {
                const run = self.page.runs.items[here.run];
                const text = self.page.textOf(run);
                if (here.at == text.len) {
                    if (run.breaks) try self.endLine(run.face, true);
                    here = .{ .run = here.run + 1, .at = 0 };
                    continue;
                }
                if (text[here.at] == ' ') {
                    // The space goes with the word before it. A line that
                    // ends here hands it back; one at the start of a line
                    // follows nothing and is not placed.
                    if (self.occupied()) try self.add(here.run, run.start + @as(u32, @intCast(here.at)), 1, self.metrics.width(run.face, " "));
                    here.at += 1;
                    continue;
                }
                const end = self.wordEnd(here, last);
                const width = self.widthBetween(here, end);
                if (self.pen > 0 and self.pen + width > self.room) try self.endLine(run.face, false);
                try self.place(here, end, width);
                here = end;
            }
        }

        /// Where the word starting at `from` ends: at the next space, or at
        /// the end of a run that ends the line or is the last.
        fn wordEnd(self: *const Self, from: Spot, last: u32) Spot {
            var spot = from;
            while (true) {
                const run = self.page.runs.items[spot.run];
                const text = self.page.textOf(run);
                if (std.mem.indexOfScalarPos(u8, text, spot.at, ' ')) |space| return .{ .run = spot.run, .at = space };
                if (run.breaks or spot.run + 1 == last) return .{ .run = spot.run, .at = text.len };
                spot = .{ .run = spot.run + 1, .at = 0 };
            }
        }

        fn widthBetween(self: *const Self, from: Spot, to: Spot) i32 {
            var total: i32 = 0;
            var index = from.run;
            while (index <= to.run) : (index += 1) {
                const piece = self.pieceOf(index, from, to);
                total += self.metrics.width(self.page.runs.items[index].face, piece.text);
            }
            return total;
        }

        /// Put the word from `from` to `to` on the line, a piece for each run
        /// it crosses, and cut a letter at a time when it is longer than a
        /// line. `width` is what the whole of it measures.
        fn place(self: *Self, from: Spot, to: Spot, width: i32) Error!void {
            const long = width > self.room;
            var index = from.run;
            while (index <= to.run) : (index += 1) {
                const piece = self.pieceOf(index, from, to);
                if (piece.text.len == 0) continue;
                if (long) {
                    try self.cut(index, piece.start, piece.text);
                } else {
                    // A word inside one run, which is nearly every word, was
                    // measured whole already.
                    const face = self.page.runs.items[index].face;
                    const wide = if (from.run == to.run) width else self.metrics.width(face, piece.text);
                    try self.add(index, piece.start, @intCast(piece.text.len), wide);
                }
            }
        }

        const Piece = struct { start: u32, text: []const u8 };

        /// What of run `index`'s text lies between `from` and `to`.
        fn pieceOf(self: *const Self, index: u32, from: Spot, to: Spot) Piece {
            const run = self.page.runs.items[index];
            const text = self.page.textOf(run);
            const begin: usize = if (index == from.run) from.at else 0;
            const end: usize = if (index == to.run) to.at else text.len;
            return .{ .start = run.start + @as(u32, @intCast(begin)), .text = text[begin..end] };
        }

        /// Text placed a letter at a time wherever the line runs out: a word
        /// longer than the line, or preformatted text, whose spaces are not
        /// places to break but part of what it says.
        fn cut(self: *Self, index: u32, start: u32, text: []const u8) Error!void {
            const face = self.page.runs.items[index].face;
            var rest = text;
            var at = start;
            while (rest.len > 0) {
                var n = self.metrics.fit(face, rest, self.room - self.pen);
                if (n == 0) {
                    if (self.occupied()) {
                        try self.endLine(face, false);
                        continue;
                    }
                    // Not even one letter fits an empty line. It goes on
                    // anyway, or nothing ever would.
                    n = @min(rest.len, std.unicode.utf8ByteSequenceLength(rest[0]) catch 1);
                }
                try self.add(index, at, @intCast(n), self.metrics.width(face, rest[0..n]));
                rest = rest[n..];
                at += @intCast(n);
                if (rest.len > 0) try self.endLine(face, false);
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Every byte six pixels wide; a body line eighteen tall, a heading's
/// twenty-four.
const Fixed = struct {
    pub fn width(_: Fixed, _: Face, bytes: []const u8) i32 {
        return @intCast(bytes.len * 6);
    }
    pub fn height(_: Fixed, face: Face) i32 {
        return if (face == .heading) 24 else 18;
    }
    pub fn ascent(_: Fixed, face: Face) i32 {
        return if (face == .heading) 18 else 14;
    }
    pub fn fit(_: Fixed, _: Face, bytes: []const u8, room: i32) usize {
        return @min(bytes.len, @as(usize, @intCast(@max(room, 0))) / 6);
    }
};

const eighteen = Spacing.forLine(18);

const Built = struct {
    page: Page = .{},
    layout: Layout = .{},

    fn deinit(self: *Built) void {
        self.layout.deinit(testing.allocator);
        self.page.deinit(testing.allocator);
    }

    fn fragText(self: *const Built, frag: Frag) []const u8 {
        return self.page.text.items[frag.start..][0..frag.len];
    }

    fn line(self: *const Built, index: usize) []const Frag {
        return self.layout.fragsOf(self.layout.lines.items[index]);
    }
};

fn paragraph(text: []const u8, width: i32) !Built {
    var b = Built{};
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try builder.words(text);
    try builder.finish();
    b.layout = try build(testing.allocator, &b.page, width, eighteen, Fixed{});
    return b;
}

test "words that fit are one line and one fragment" {
    var b = try paragraph("hello world", 600);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 1), b.layout.lines.items.len);
    try testing.expectEqual(@as(usize, 1), b.line(0).len);
    try testing.expectEqualStrings("hello world", b.fragText(b.line(0)[0]));
    try testing.expectEqual(@as(i32, 66), b.line(0)[0].width);
}

test "words wrap at the width, and no line ends in a space" {
    var b = try paragraph("aaaa bbbb cccc", 60);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 2), b.layout.lines.items.len);
    try testing.expectEqualStrings("aaaa bbbb", b.fragText(b.line(0)[0]));
    try testing.expectEqual(@as(i32, 54), b.line(0)[0].width);
    try testing.expectEqualStrings("cccc", b.fragText(b.line(1)[0]));
    try testing.expectEqual(@as(i32, 0), b.line(1)[0].x);
    try testing.expectEqual(@as(i32, 18), b.layout.lines.items[1].y);
}

test "a word longer than the line is cut where the line runs out" {
    var b = try paragraph("abcdefghijklmnop", 60);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 2), b.layout.lines.items.len);
    try testing.expectEqualStrings("abcdefghij", b.fragText(b.line(0)[0]));
    try testing.expectEqualStrings("klmnop", b.fragText(b.line(1)[0]));
}

test "a break ends a line, two make an empty one, and one at the end adds nothing" {
    var b = Built{};
    defer b.deinit();
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try builder.words("one");
    try builder.lineBreak();
    try builder.lineBreak();
    try builder.words("two");
    try builder.lineBreak();
    try builder.finish();
    b.layout = try build(testing.allocator, &b.page, 600, eighteen, Fixed{});

    try testing.expectEqual(@as(usize, 3), b.layout.lines.items.len);
    try testing.expectEqualStrings("one", b.fragText(b.line(0)[0]));
    try testing.expectEqual(@as(usize, 0), b.line(1).len);
    try testing.expectEqual(@as(i32, 18), b.layout.lines.items[1].height);
    try testing.expectEqualStrings("two", b.fragText(b.line(2)[0]));
}

test "blocks stack with their gaps, and a heading is as tall as its face" {
    var b = Built{};
    defer b.deinit();
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try builder.boundary(.{ .kind = .heading });
    builder.face = .heading;
    try builder.words("Title");
    builder.face = .body;
    try builder.boundary(.{});
    try builder.words("First.");
    try builder.boundary(.{});
    try builder.words("Second.");
    try builder.finish();
    b.layout = try build(testing.allocator, &b.page, 600, eighteen, Fixed{});

    const lines = b.layout.lines.items;
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqual(@as(i32, 24), lines[0].height);
    try testing.expectEqual(@as(i32, 18), lines[0].baseline);
    try testing.expectEqual(@as(i32, 24 + eighteen.below_heading), lines[1].y);
    try testing.expectEqual(lines[1].y + 18 + eighteen.paragraph, lines[2].y);
    try testing.expectEqual(lines[2].y + 18, b.layout.height);
}

test "a list's entries step in and stay close" {
    var b = Built{};
    defer b.deinit();
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try builder.boundary(.{ .kind = .item, .depth = 1, .marker = .bullet });
    try builder.words("one");
    try builder.boundary(.{ .kind = .item, .depth = 1, .marker = .bullet });
    try builder.words("two");
    try builder.finish();
    b.layout = try build(testing.allocator, &b.page, 600, eighteen, Fixed{});

    const lines = b.layout.lines.items;
    try testing.expectEqual(eighteen.indent, b.line(0)[0].x);
    try testing.expect(lines[0].leads and lines[1].leads);
    try testing.expectEqual(lines[0].y + 18 + eighteen.item, lines[1].y);
}

test "preformatted text keeps its spaces and wraps a letter at a time" {
    var b = Built{};
    defer b.deinit();
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try builder.boundary(.{ .kind = .preformatted });
    try builder.words("a  b cdefgh");
    try builder.finish();
    // Ten letters of room once the band's inset is off both sides.
    b.layout = try build(testing.allocator, &b.page, 60 + 2 * eighteen.inset, eighteen, Fixed{});

    try testing.expectEqual(@as(usize, 2), b.layout.lines.items.len);
    try testing.expectEqualStrings("a  b cdefg", b.fragText(b.line(0)[0]));
    try testing.expectEqualStrings("h", b.fragText(b.line(1)[0]));
    try testing.expectEqual(eighteen.inset, b.line(0)[0].x);
}

test "the first line on screen is found by halving" {
    var b = try paragraph("aaaa bbbb cccc dddd eeee ffff", 30);
    defer b.deinit();
    // Five letters a line: one word each, eighteen pixels apart.
    try testing.expectEqual(@as(usize, 6), b.layout.lines.items.len);
    try testing.expectEqual(@as(usize, 0), b.layout.lineAt(0));
    try testing.expectEqual(@as(usize, 0), b.layout.lineAt(17));
    try testing.expectEqual(@as(usize, 1), b.layout.lineAt(18));
    try testing.expectEqual(@as(usize, 3), b.layout.lineAt(60));
    try testing.expectEqual(@as(usize, 6), b.layout.lineAt(10_000));
}

test "a line breaks at a space, never where a link meets the text after it" {
    var b = Built{};
    defer b.deinit();
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try builder.words("aaaa bbbb ");
    builder.link = try builder.addLink("https://a.org/");
    builder.ink = .link;
    try builder.words("cccc");
    builder.link = page_mod.NO_LINK;
    builder.ink = .text;
    try builder.words("; dd");
    try builder.finish();
    // Fourteen letters a line: "aaaa bbbb cccc" fits exactly, and the
    // semicolon after the link belongs to its last word.
    b.layout = try build(testing.allocator, &b.page, 84, eighteen, Fixed{});

    try testing.expectEqual(@as(usize, 2), b.layout.lines.items.len);
    try testing.expectEqualStrings("aaaa bbbb", b.fragText(b.line(0)[0]));
    const second = b.line(1);
    try testing.expectEqualStrings("cccc", b.fragText(second[0]));
    try testing.expectEqualStrings("; dd", b.fragText(second[1]));
    try testing.expectEqual(@as(i32, 24), second[1].x);
}

test "a link's words are their own fragment beside the text around them" {
    var b = Built{};
    defer b.deinit();
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try builder.words("see ");
    builder.link = try builder.addLink("https://a.org/");
    builder.ink = .link;
    try builder.words("here");
    builder.link = page_mod.NO_LINK;
    builder.ink = .text;
    try builder.words(" now");
    try builder.finish();
    b.layout = try build(testing.allocator, &b.page, 600, eighteen, Fixed{});

    const frags = b.line(0);
    try testing.expectEqual(@as(usize, 3), frags.len);
    try testing.expectEqualStrings("here", b.fragText(frags[1]));
    try testing.expectEqual(@as(i32, 24), frags[1].x);
    try testing.expectEqual(@as(i32, 24), frags[1].width);
}
