//! Where every word of a page goes, and every control and picture among
//! them, in a column a given number of pixels wide.
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
const text_lib = @import("lib").text;
const page_mod = @import("page.zig");

const Page = page_mod.Page;
const Block = page_mod.Block;
const Face = page_mod.Face;
const Text = page_mod.Text;

pub const Error = std.mem.Allocator.Error;

/// How much room a control or a picture takes on a line.
pub const Size = struct { w: i32, h: i32 };

/// One thing on a line: words from one run, or a control or a picture.
pub const Frag = struct {
    /// From the column's left edge.
    x: i32,
    width: i32,
    /// The run it belongs to, which says what it is: words, how they look
    /// and where they go, or which control or picture.
    run: u32,
    shape: Shape,

    pub const Shape = union(enum) {
        /// Words, by where they are in the page's text.
        words: Words,
        /// A control or a picture, and how tall it is drawn.
        box: i32,
    };

    pub const Words = struct { start: u32, len: u32 };

    /// Whether the place `at` in the page's text is on this fragment. A box
    /// is the whole of its run.
    fn holds(self: Frag, at: u32) bool {
        return switch (self.shape) {
            .words => |words| at >= words.start and at < words.start + @max(words.len, 1),
            .box => true,
        };
    }
};

/// A place in a page that outlasts its layout: a run, and how far into the
/// page's text, which for a box is nowhere in particular.
pub const Place = struct { run: u32, at: u32 };

/// A place, and the top of the line it begins.
pub const Mark = struct { place: Place, y: i32 };

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
    /// starts at `y` begins. Found by halving: a long page has thousands of
    /// lines, and a scroll asks this every pass.
    pub fn lineAt(self: *const Layout, y: i32) usize {
        return std.sort.partitionPoint(Line, self.lines.items, y, endsAbove);
    }

    fn endsAbove(y: i32, line: Line) bool {
        return line.y + line.height <= y;
    }

    /// What begins the first line reaching below `y` that has anything on
    /// it: what a view keeps its place by when the page is laid out again
    /// under it.
    pub fn markAt(self: *const Layout, y: i32) ?Mark {
        const lines = self.lines.items;
        var i = self.lineAt(y);
        while (i < lines.len) : (i += 1) {
            const frags = self.fragsOf(lines[i]);
            if (frags.len == 0) continue;
            const at: u32 = switch (frags[0].shape) {
                .words => |words| words.start,
                .box => 0,
            };
            return .{ .place = .{ .run = frags[0].run, .at = at }, .y = lines[i].y };
        }
        return null;
    }

    /// Where the line holding `place` is, from the top of the page.
    pub fn lineOf(self: *const Layout, place: Place) ?i32 {
        for (self.lines.items) |line| {
            for (self.fragsOf(line)) |frag| {
                if (frag.run == place.run and frag.holds(place.at)) return line.y;
            }
        }
        return null;
    }
};

/// Lay `page` out `width` pixels wide.
///
/// `metrics` answers four questions of a face: `width(face, bytes)`,
/// `height(face)`, `ascent(face)`, and `fit(face, bytes, room)`, how many of
/// the bytes fit in that many pixels, at a letter's edge. It answers two more
/// of what is not words: `control(page, control)`, the room a control takes,
/// and `picture(page, index, room)`, the room a picture takes in a column
/// `room` wide.
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
        p.alignment = block.alignment;
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
            try p.verbatim(block);
        } else {
            try p.flow(block.first, block.first + block.count);
        }
        try p.endLine(false);
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

/// A place in a block's text: a run, and a byte of its words.
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
        /// Which way the block's lines lean.
        alignment: page_mod.Alignment = .start,
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
        /// The face of the words placed last, which is how tall a line a
        /// break leaves empty is.
        face: Face = .body,

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

        /// The words of the run at `index`, which is known to be words.
        fn textAt(self: *const Self, index: u32) Text {
            return self.page.runs.items[index].text;
        }

        /// Close the line being filled. One with nothing on it is kept only
        /// when a break asked for it, as tall as the words before it.
        fn endLine(self: *Self, keep_empty: bool) Error!void {
            if (self.occupied()) {
                // A line ends where its last word does. The space after that
                // word is in the text, and would only lengthen what a link's
                // underline runs under.
                const last = &self.out.frags.items[self.out.frags.items.len - 1];
                switch (last.shape) {
                    .words => |*words| if (words.len > 0 and self.page.text.items[words.start + words.len - 1] == ' ') {
                        words.len -= 1;
                        last.width -= self.metrics.width(self.textAt(last.run).look.face, " ");
                    },
                    .box => {},
                }
                self.lean();
            } else {
                if (!keep_empty) return;
                self.grow(self.face);
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

        /// Move what is on the line being ended along by the room it leaves,
        /// where its block's lines lean to the middle or to the end.
        fn lean(self: *Self) void {
            const frags = self.out.frags.items[self.first..];
            const last = frags[frags.len - 1];
            const left = self.room - (last.x + last.width - self.x0);
            const by = switch (self.alignment) {
                .start => return,
                .center => @divTrunc(left, 2),
                .end => left,
            };
            if (by <= 0) return;
            for (frags) |*frag| frag.x += by;
        }

        /// Put words on the line, joining the fragment before them where
        /// that is the same run and they follow on.
        fn add(self: *Self, run: u32, face: Face, start: u32, len: u32, width: i32) Error!void {
            self.grow(face);
            self.face = face;
            self.pen += width;
            if (self.occupied()) {
                const last = &self.out.frags.items[self.out.frags.items.len - 1];
                if (last.run == run) {
                    switch (last.shape) {
                        .words => |*words| if (words.start + words.len == start) {
                            words.len += len;
                            last.width += width;
                            return;
                        },
                        .box => {},
                    }
                }
            }
            try self.out.frags.append(self.gpa, .{
                .x = self.x0 + self.pen - width,
                .width = width,
                .run = run,
                .shape = .{ .words = .{ .start = start, .len = len } },
            });
        }

        /// A control or a picture, placed as a word is: on this line if it
        /// fits and on the next if it does not, never wider than the column.
        /// Its bottom sits where the words' descent ends, so a control's own
        /// label lines up near their baseline and a picture stands on the
        /// line. A control too wide is cut to the column; a picture comes
        /// already fitted to it, keeping its shape.
        fn box(self: *Self, index: u32, run: page_mod.Run) Error!void {
            const size: Size = switch (run) {
                .control => |which| self.metrics.control(self.page, self.page.controls.items[which]),
                .picture => |which| self.metrics.picture(self.page, which, self.room),
                .text, .line_break => unreachable,
            };
            const width = @min(size.w, self.room);
            if (self.pen > 0 and self.pen + width > self.room) try self.endLine(false);
            const descent = self.metrics.height(.body) - self.metrics.ascent(.body);
            self.ascent = @max(self.ascent, size.h - descent);
            self.descent = @max(self.descent, descent);
            self.pen += width;
            try self.out.frags.append(self.gpa, .{
                .x = self.x0 + self.pen - width,
                .width = width,
                .run = index,
                .shape = .{ .box = size.h },
            });
        }

        /// A preformatted block: its words placed a letter at a time wherever
        /// the line runs out, and its line ends where the page put them.
        fn verbatim(self: *Self, block: Block) Error!void {
            for (self.page.runsOf(block), @as(usize, block.first)..) |run, index| switch (run) {
                .text => |text| try self.cut(@intCast(index), text.look.face, text.start, self.page.textOf(text)),
                .control, .picture => try self.box(@intCast(index), run),
                .line_break => try self.endLine(true),
            };
        }

        /// The words of runs `first` up to `last`, broken onto lines at their
        /// spaces. A word runs on from one run into the next where a link or
        /// a change of face falls inside it, so a line never breaks where two
        /// runs meet unless there is a space there.
        fn flow(self: *Self, first: u32, last: u32) Error!void {
            var here = Spot{ .run = first, .at = 0 };
            while (here.run < last) {
                const run = self.page.runs.items[here.run];
                const text = switch (run) {
                    .text => |text| text,
                    .control, .picture => {
                        try self.box(here.run, run);
                        here = .{ .run = here.run + 1, .at = 0 };
                        continue;
                    },
                    .line_break => {
                        try self.endLine(true);
                        here = .{ .run = here.run + 1, .at = 0 };
                        continue;
                    },
                };
                const words = self.page.textOf(text);
                if (here.at == words.len) {
                    here = .{ .run = here.run + 1, .at = 0 };
                    continue;
                }
                if (words[here.at] == ' ') {
                    // The space goes with the word before it. A line that
                    // ends here hands it back; one at the start of a line
                    // follows nothing and is not placed.
                    if (self.occupied()) {
                        const space = self.metrics.width(text.look.face, " ");
                        try self.add(here.run, text.look.face, text.start + @as(u32, @intCast(here.at)), 1, space);
                    }
                    here.at += 1;
                    continue;
                }
                const end = self.wordEnd(here, last);
                const width = self.widthBetween(here, end);
                if (self.pen > 0 and self.pen + width > self.room) try self.endLine(false);
                try self.place(here, end, width);
                here = end;
            }
        }

        /// Where the word starting at `from` ends: at the next space, or at
        /// the end of a run followed by something that is not words, or by
        /// nothing.
        fn wordEnd(self: *const Self, from: Spot, last: u32) Spot {
            var spot = from;
            while (true) {
                const words = self.page.textOf(self.textAt(spot.run));
                if (std.mem.indexOfScalarPos(u8, words, spot.at, ' ')) |space| return .{ .run = spot.run, .at = space };
                const next = spot.run + 1;
                if (next == last or self.page.runs.items[next] != .text) return .{ .run = spot.run, .at = words.len };
                spot = .{ .run = next, .at = 0 };
            }
        }

        fn widthBetween(self: *const Self, from: Spot, to: Spot) i32 {
            var total: i32 = 0;
            var index = from.run;
            while (index <= to.run) : (index += 1) {
                const piece = self.pieceOf(index, from, to);
                total += self.metrics.width(self.textAt(index).look.face, piece.words);
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
                if (piece.words.len == 0) continue;
                const face = self.textAt(index).look.face;
                if (long) {
                    try self.cut(index, face, piece.start, piece.words);
                } else {
                    // A word inside one run, which is nearly every word, was
                    // measured whole already.
                    const wide = if (from.run == to.run) width else self.metrics.width(face, piece.words);
                    try self.add(index, face, piece.start, @intCast(piece.words.len), wide);
                }
            }
        }

        const Piece = struct { start: u32, words: []const u8 };

        /// What of run `index`'s words lies between `from` and `to`.
        fn pieceOf(self: *const Self, index: u32, from: Spot, to: Spot) Piece {
            const text = self.textAt(index);
            const words = self.page.textOf(text);
            const begin: usize = if (index == from.run) from.at else 0;
            const end: usize = if (index == to.run) to.at else words.len;
            return .{ .start = text.start + @as(u32, @intCast(begin)), .words = words[begin..end] };
        }

        /// Words placed a letter at a time wherever the line runs out: a word
        /// longer than the line, or preformatted text, whose spaces are not
        /// places to break but part of what it says.
        fn cut(self: *Self, index: u32, face: Face, start: u32, words: []const u8) Error!void {
            var rest = words;
            var at = start;
            while (rest.len > 0) {
                var n = self.metrics.fit(face, rest, self.room - self.pen);
                if (n == 0) {
                    if (self.occupied()) {
                        try self.endLine(false);
                        continue;
                    }
                    // Not even one letter fits an empty line. It goes on
                    // anyway, or nothing ever would.
                    n = text_lib.charWidth(rest, 0);
                }
                try self.add(index, face, at, @intCast(n), self.metrics.width(face, rest[0..n]));
                rest = rest[n..];
                at += @intCast(n);
                if (rest.len > 0) try self.endLine(false);
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
    pub fn control(_: Fixed, _: *const Page, which: page_mod.Control) Size {
        return switch (which.kind) {
            .line => |line| .{ .w = @as(i32, line.letters) * 6, .h = 24 },
            .submit, .reset => .{ .w = 30, .h = 24 },
            .tick => .{ .w = 24, .h = 24 },
            .hidden => .{ .w = 0, .h = 0 },
        };
    }
    /// The size the page gives, or thirty by twenty, fitted to the room and
    /// keeping its shape.
    pub fn picture(_: Fixed, page: *const Page, index: u16, room: i32) Size {
        const which = page.pictures.items[index];
        const w: i32 = which.width orelse 30;
        const h: i32 = which.height orelse 20;
        if (w <= room) return .{ .w = w, .h = h };
        return .{ .w = room, .h = @divTrunc(h * room, w) };
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
        const words = frag.shape.words;
        return self.page.text.items[words.start..][0..words.len];
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
    builder.look.face = .heading;
    try builder.words("Title");
    builder.look.face = .body;
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
    builder.look.ink = .link;
    try builder.words("cccc");
    builder.link = null;
    builder.look.ink = .text;
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

test "a control sits among the words as a word does, and its line is as tall as it is" {
    var b = Built{};
    defer b.deinit();
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try builder.words("Find ");
    try builder.addControl(.{ .line = .{ .letters = 10 } }, "q", "", .{});
    try builder.words(" now");
    try builder.finish();
    b.layout = try build(testing.allocator, &b.page, 600, eighteen, Fixed{});

    try testing.expectEqual(@as(usize, 1), b.layout.lines.items.len);
    // A body line's descent is four, so a control twenty-four tall reaches
    // twenty above the baseline.
    const line = b.layout.lines.items[0];
    try testing.expectEqual(@as(i32, 20), line.baseline);
    try testing.expectEqual(@as(i32, 24), line.height);
    const frags = b.line(0);
    try testing.expectEqual(@as(usize, 3), frags.len);
    try testing.expectEqual(@as(i32, 30), frags[1].x);
    try testing.expectEqual(@as(i32, 60), frags[1].width);
    try testing.expectEqualStrings(" now", b.fragText(frags[2]));
}

test "a picture stands on the line as a word does, fitted to the column" {
    var b = Built{};
    defer b.deinit();
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try builder.words("see ");
    try builder.addPicture("https://a.org/a.png", "", 60, 40);
    try builder.words(" wide");
    try builder.addPicture("https://a.org/b.png", "", 1200, 600);
    try builder.finish();
    b.layout = try build(testing.allocator, &b.page, 600, eighteen, Fixed{});

    const lines = b.layout.lines.items;
    try testing.expectEqual(@as(usize, 2), lines.len);
    // The small one after the first word, standing where the words' descent
    // ends: the line is as tall as it and that descent.
    const first = b.line(0);
    try testing.expectEqual(@as(i32, 24), first[1].x);
    try testing.expectEqual(@as(i32, 60), first[1].width);
    try testing.expectEqual(Frag.Shape{ .box = 40 }, first[1].shape);
    try testing.expectEqual(@as(i32, 40), lines[0].height);
    // The wide one on a line of its own, as wide as the column and as tall as
    // its shape then makes it.
    const second = b.line(1);
    try testing.expectEqual(@as(i32, 600), second[0].width);
    try testing.expectEqual(Frag.Shape{ .box = 300 }, second[0].shape);
    try testing.expectEqual(@as(i32, 300), lines[1].height);
}

test "a block's lines lean where it says, by the room each leaves" {
    var b = Built{};
    defer b.deinit();
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try builder.boundary(.{ .alignment = .center });
    try builder.words("abcd");
    try builder.boundary(.{ .alignment = .end });
    try builder.words("ab");
    try builder.finish();
    b.layout = try build(testing.allocator, &b.page, 60, eighteen, Fixed{});

    // Ten letters of room: four in the middle leave three either side, and
    // two at the end leave eight before them.
    try testing.expectEqual(@as(i32, 18), b.line(0)[0].x);
    try testing.expectEqual(@as(i32, 48), b.line(1)[0].x);
}

test "a place in the page is found again once the page is laid out anew" {
    var b = try paragraph("aaaa bbbb cccc dddd eeee ffff", 30);
    defer b.deinit();
    // One word a line: the fourth begins with the fourth word.
    const mark = b.layout.markAt(3 * 18 + 5).?;
    try testing.expectEqual(@as(i32, 3 * 18), mark.y);

    // Twice as wide, two words a line: the fourth word ends the second.
    b.layout.deinit(testing.allocator);
    b.layout = try build(testing.allocator, &b.page, 60, eighteen, Fixed{});
    try testing.expectEqual(@as(?i32, 18), b.layout.lineOf(mark.place));
}

test "a link's words are their own fragment beside the text around them" {
    var b = Built{};
    defer b.deinit();
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try builder.words("see ");
    builder.link = try builder.addLink("https://a.org/");
    builder.look.ink = .link;
    try builder.words("here");
    builder.link = null;
    builder.look.ink = .text;
    try builder.words(" now");
    try builder.finish();
    b.layout = try build(testing.allocator, &b.page, 600, eighteen, Fixed{});

    const frags = b.line(0);
    try testing.expectEqual(@as(usize, 3), frags.len);
    try testing.expectEqualStrings("here", b.fragText(frags[1]));
    try testing.expectEqual(@as(i32, 24), frags[1].x);
    try testing.expectEqual(@as(i32, 24), frags[1].width);
}
