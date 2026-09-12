//! Where every word of a page goes, and every control and picture among
//! them, in a column a given number of pixels wide.
//!
//! Done once for a page and a width, not once a frame. The lines are what a
//! view draws from, and scrolling is only which of them are on screen. A word
//! is measured once, where it is placed, and the words of one run that land
//! on one line are one fragment drawn with one call, because the space
//! between them is in the text already.
//!
//! A table set as a grid has columns as wide as its cells need where they fit
//! the column, and its cells' words are set in them as a block's are in the
//! page's. Its cells' lines stand side by side, so lines are kept in the
//! order of their tops, each with how far down the page it or any before it
//! reaches, which is what finding the first line on screen halves over.
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

/// A box on the page, from the column's left edge and the page's top.
pub const Area = struct { x: i32, y: i32, w: i32, h: i32 };

/// A table set as a grid: where it is, and its cells' boxes among the
/// layout's.
pub const Table = struct { area: Area, first: u32, count: u32 };

/// The window a page is read in, which is what a length written `vw` or `vh`
/// is a share of.
pub const Viewport = struct { w: i32, h: i32 };

/// One item of a flex container: where it landed, and which of the page's
/// boxes it is. Words of the container's own, which no element of the page
/// holds, are one with no box.
pub const Placed = struct {
    area: Area,
    container: ?u32 = null,
};

/// Where one cell of a grid is, and which of the page's cells it is.
pub const Box = struct { area: Area, cell: u32 };

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
    /// The table cell it is in, among the page's, where it is in one.
    cell: ?u32 = null,
    /// How far down the page this line or any before it reaches.
    reach: i32 = 0,
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
    /// Between a table cell's words and its edges.
    cell: i32,
    /// The rule between a table's cells.
    hairline: i32,

    pub fn forLine(height: i32) Spacing {
        return .{
            .paragraph = @divTrunc(height * 2, 3),
            .above_heading = height,
            .below_heading = @divTrunc(height, 3),
            .item = @divTrunc(height, 6),
            .indent = height + 4,
            .inset = @divTrunc(height, 2),
            .rule = height,
            .cell = @divTrunc(height, 4),
            .hairline = @max(@divTrunc(height, 18), 1),
        };
    }
};

pub const Layout = struct {
    lines: std.ArrayList(Line) = .empty,
    frags: std.ArrayList(Frag) = .empty,
    /// The tables set as grids, and where each of their cells is.
    tables: std.ArrayList(Table) = .empty,
    boxes: std.ArrayList(Box) = .empty,
    /// Where each item of the page's flex containers was put.
    placed: std.ArrayList(Placed) = .empty,
    /// How tall the whole page is.
    height: i32 = 0,
    /// The column it was laid out for, which is what says it needs doing
    /// again.
    width: i32 = 0,

    pub fn deinit(self: *Layout, gpa: std.mem.Allocator) void {
        self.lines.deinit(gpa);
        self.frags.deinit(gpa);
        self.tables.deinit(gpa);
        self.boxes.deinit(gpa);
        self.placed.deinit(gpa);
        self.* = .{};
    }

    pub fn fragsOf(self: *const Layout, line: Line) []const Frag {
        return self.frags.items[line.first..][0..line.count];
    }

    pub fn boxesOf(self: *const Layout, table: Table) []const Box {
        return self.boxes.items[table.first..][0..table.count];
    }

    /// The first line that it or a line before it reaches below `y`, which is
    /// where drawing a view that starts at `y` begins. Found by halving over
    /// how far down the lines reach, which only grows: a long page has
    /// thousands of lines, and a scroll asks this every pass.
    pub fn lineAt(self: *const Layout, y: i32) usize {
        return std.sort.partitionPoint(Line, self.lines.items, y, reachesAbove);
    }

    fn reachesAbove(y: i32, line: Line) bool {
        return line.reach <= y;
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
    // A page laid out for a column alone reads shares of the window as
    // shares of a window as wide as it is tall.
    return buildIn(gpa, page, .{ .w = width, .h = width }, spacing, metrics);
}

/// As `build`, for the window `viewport`: what `vw` and `vh` are shares of,
/// and how wide the column is.
pub fn buildIn(gpa: std.mem.Allocator, page: *const Page, viewport: Viewport, spacing: Spacing, metrics: anytype) Error!Layout {
    var out = Layout{ .width = viewport.w };
    errdefer out.deinit(gpa);

    var p = Placer(@TypeOf(metrics)){ .gpa = gpa, .page = page, .out = &out, .metrics = metrics, .spacing = spacing, .viewport = viewport };
    try p.whole();

    // A table's cells' lines stand side by side, and one may reach below the
    // next, so how far down any has reached is carried along.
    var reach: i32 = 0;
    for (out.lines.items) |*line| {
        reach = @max(reach, line.y + line.height);
        line.reach = reach;
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
        spacing: Spacing,
        /// The window `vw` and `vh` are shares of, and the column's width.
        viewport: Viewport,

        y: i32 = 0,
        block: u32 = 0,
        leads: bool = false,
        /// The block set last, which is what the room above the next one is
        /// read from. Each flex item's first block follows nothing.
        previous: ?Block = null,
        /// Where the box being set starts from the column's edge, and where
        /// it ends. Every block is set between them, stepped in by its depth.
        left: i32 = 0,
        right: i32 = 0,
        /// Which of the page's blocks each of its boxes holds, where the page
        /// kept any and one of them asks for box layout. Empty where none do.
        spans: []Owns = &.{},
        /// For each of the page's boxes, the box holding it.
        parents: []u32 = &.{},
        /// Which way the block's lines lean.
        alignment: page_mod.Alignment = .start,
        /// The table cell being set, among the page's, while one is.
        cell: ?u32 = null,
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

        /// Lay the whole page out. A page that kept boxes, one of which asks
        /// for box layout, is set box by box; any other page is a column of
        /// blocks, as it has always been.
        fn whole(self: *Self) Error!void {
            self.right = self.viewport.w;
            if (!self.cover()) return self.blocks(0, self.page.blocks.items.len);
            defer {
                self.gpa.free(self.spans);
                self.gpa.free(self.parents);
                self.spans = &.{};
                self.parents = &.{};
            }
            try self.container(0, 0, @max(self.viewport.w, 0));
        }

        /// The blocks `first` up to `last`, one after another down the page.
        fn blocks(self: *Self, first: usize, last: usize) Error!void {
            for (first..last) |index| try self.layBlock(index);
        }

        /// One of the page's blocks, set between `left` and `right` and
        /// stepped in by its depth, below whatever came before it.
        fn layBlock(self: *Self, index: usize) Error!void {
            const block = self.page.blocks.items[index];
            if (self.previous) |before| self.y += gap(self.spacing, before, block);
            self.previous = block;

            self.block = @intCast(index);
            self.leads = true;
            self.alignment = block.alignment;
            self.startLine();

            const inset: i32 = if (block.kind == .preformatted) self.spacing.inset else 0;
            self.x0 = self.left + @as(i32, block.depth) * self.spacing.indent + inset;
            // Never narrower than a few letters: a list nested past the
            // column's edge still has to put its words somewhere.
            self.room = @max(self.right - self.x0 - inset, self.spacing.indent * 2);

            switch (block.kind) {
                .rule => {
                    try self.out.lines.append(self.gpa, .{
                        .y = self.y,
                        .height = self.spacing.rule,
                        .baseline = 0,
                        .first = @intCast(self.out.frags.items.len),
                        .count = 0,
                        .block = self.block,
                        .leads = true,
                    });
                    self.y += self.spacing.rule;
                    return;
                },
                .table => |grid| return self.table(grid),
                else => {},
            }

            self.y += inset;
            if (block.kind == .preformatted) {
                try self.verbatim(block);
            } else {
                try self.flow(block.first, block.first + block.count);
            }
            try self.endLine(false);
            self.y += inset;
        }

        /// What the box `index` holds, set in a box `room` wide from `x`:
        /// its own blocks, and the boxes it holds among them, in the order
        /// they come.
        fn container(self: *Self, index: u32, x: i32, room: i32) Error!void {
            const span = self.owns(index);
            if (span.first >= span.end) return;
            const keep_left = self.left;
            const keep_right = self.right;
            defer {
                self.left = keep_left;
                self.right = keep_right;
            }
            self.left = x;
            self.right = x + room;
            if (self.page.containers.items[index].style.display == .flex) return self.flex(index, x, room);

            var at = span.first;
            var kid: usize = 0;
            const children = self.page.childrenOf(self.page.containers.items[index]);
            while (at < span.end) {
                if (kid < children.len) {
                    const there = self.owns(children[kid]);
                    if (there.end <= at) {
                        kid += 1;
                        continue;
                    }
                    if (there.first <= at) {
                        const next = children[kid];
                        kid += 1;
                        try self.container(next, x, room);
                        at = @max(at, self.owns(next).end);
                        continue;
                    }
                }
                try self.layBlock(at);
                at += 1;
            }
        }

        /// Which of the page's blocks the box `index` holds, where the page
        /// kept it: nothing for a box it did not keep.
        fn owns(self: *const Self, index: u32) Owns {
            if (index >= self.spans.len) return .{};
            return self.spans[index];
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
                .cell = self.cell,
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
            const size = self.sizeOf(run);
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

        /// The room a control or a picture takes, a picture fitted to the room
        /// there is.
        fn sizeOf(self: *const Self, run: page_mod.Run) Size {
            return switch (run) {
                .control => |which| self.metrics.control(self.page, self.page.controls.items[which]),
                .picture => |which| self.metrics.picture(self.page, which, self.room),
                .text, .line_break => unreachable,
            };
        }

        /// What a cell's words need at the least, which is their widest word
        /// or box, and would take at the most, which is their longest line
        /// with nothing but their own line ends to break it.
        fn extent(self: *const Self, cell: page_mod.Cell) Extent {
            var out: Extent = .{};
            var line: i32 = 0;
            for (self.page.cellRuns(cell)) |run| switch (run) {
                .text => |text| {
                    const face = text.look.face;
                    const words = self.page.textOf(text);
                    line += self.metrics.width(face, words);
                    var each = std.mem.tokenizeScalar(u8, words, ' ');
                    while (each.next()) |word| out.least = @max(out.least, self.metrics.width(face, word));
                },
                .control, .picture => {
                    const size = self.sizeOf(run);
                    out.least = @max(out.least, size.w);
                    line += size.w;
                },
                .line_break => {
                    out.most = @max(out.most, line);
                    line = 0;
                },
            };
            out.most = @max(out.most, line);
            return out;
        }

        /// A table set as a grid where what its cells need at the least fits
        /// the room, and its cells one after another where it does not.
        ///
        /// Each column is as wide as its widest cell would be on one line,
        /// where every column fits so; otherwise each has what it needs and a
        /// share of the rest by how much more it would take. A cell's words
        /// are set in its column as a block's are in the page's. A row is as
        /// tall as its tallest cell, and a cell spanning rows stretches the
        /// last of them where it needs more.
        fn table(self: *Self, grid: page_mod.Grid) Error!void {
            const cells = self.page.cellsOf(grid);
            const columns: usize = grid.columns;
            const pad = self.spacing.cell;
            const hairline = self.spacing.hairline;

            // Cells a column wide first, then those across several, which
            // widen their columns only by what the columns lack.
            var least: [page_mod.COLUMNS_MAX]i32 = @splat(0);
            var most: [page_mod.COLUMNS_MAX]i32 = @splat(0);
            for (cells) |cell| {
                const at = spanOf(cell, columns);
                if (at.end - at.start != 1) continue;
                const need = self.extent(cell);
                least[at.start] = @max(least[at.start], need.least);
                most[at.start] = @max(most[at.start], need.most);
            }
            for (cells) |cell| {
                const at = spanOf(cell, columns);
                if (at.end - at.start == 1) continue;
                const need = self.extent(cell);
                const between = @as(i32, @intCast(at.end - at.start - 1)) * (2 * pad + hairline);
                spread(least[at.start..at.end], need.least - between);
                spread(most[at.start..at.end], need.most - between);
            }

            // What the columns' words have once each cell's padding and the
            // rules around and between them are off.
            const room = self.room - @as(i32, @intCast(columns)) * (2 * pad + hairline) - hairline;
            const least_sum = sum(least[0..columns]);
            if (least_sum > room) return self.linear(cells);
            const most_sum = sum(most[0..columns]);

            // Where each column's box starts; the last is where the table's
            // last rule ends.
            var edges: [page_mod.COLUMNS_MAX + 1]i32 = undefined;
            edges[0] = self.x0 + hairline;
            for (0..columns) |c| {
                const width = if (most_sum <= room)
                    most[c]
                else
                    least[c] + @divTrunc((room - least_sum) * (most[c] - least[c]), most_sum - least_sum);
                edges[c + 1] = edges[c] + width + 2 * pad + hairline;
            }

            const rows: usize = grid.rows;
            const tops = try self.gpa.alloc(i32, rows);
            defer self.gpa.free(tops);
            const bottoms = try self.gpa.alloc(i32, rows);
            defer self.gpa.free(bottoms);
            // How far down each row must reach for cells spanning into it.
            const needs = try self.gpa.alloc(i32, rows);
            defer self.gpa.free(needs);
            @memset(needs, 0);

            const top = self.y;
            const first_line = self.out.lines.items.len;
            var y = top + hairline;
            var next: usize = 0;
            for (0..rows) |r| {
                tops[r] = y;
                var bottom = y;
                while (next < cells.len and cells[next].row == r) : (next += 1) {
                    const cell = cells[next];
                    const at = spanOf(cell, columns);
                    const left = edges[at.start] + pad;
                    const width = edges[at.end] - hairline - pad - left;
                    const end = try self.setCell(grid.first + @as(u32, @intCast(next)), cell, left, width, y + pad) + pad;
                    const last = @min(r + cell.down - 1, rows - 1);
                    if (last == r) bottom = @max(bottom, end) else needs[last] = @max(needs[last], end);
                }
                bottoms[r] = @max(bottom, needs[r]);
                y = bottoms[r] + hairline;
            }

            const first_box: u32 = @intCast(self.out.boxes.items.len);
            for (cells, grid.first..) |cell, index| {
                const at = spanOf(cell, columns);
                const last = @min(@as(usize, cell.row) + cell.down - 1, rows - 1);
                try self.out.boxes.append(self.gpa, .{
                    .area = .{
                        .x = edges[at.start],
                        .y = tops[cell.row],
                        .w = edges[at.end] - hairline - edges[at.start],
                        .h = bottoms[last] - tops[cell.row],
                    },
                    .cell = @intCast(index),
                });
            }
            try self.out.tables.append(self.gpa, .{
                .area = .{ .x = self.x0, .y = top, .w = edges[columns] - self.x0, .h = y - top },
                .first = first_box,
                .count = @intCast(cells.len),
            });

            // Lines side by side are kept in the order of their tops.
            std.sort.block(Line, self.out.lines.items[first_line..], {}, topAbove);
            self.y = y;
        }

        /// Set a cell's words `width` wide from `x`, its first line's top at
        /// `top`, and say where they end.
        fn setCell(self: *Self, index: u32, cell: page_mod.Cell, x: i32, width: i32, top: i32) Error!i32 {
            const x0 = self.x0;
            const room = self.room;
            defer {
                self.x0 = x0;
                self.room = room;
                self.cell = null;
            }
            self.x0 = x;
            self.room = @max(width, 1);
            self.alignment = cell.alignment;
            self.cell = index;
            self.y = top;
            self.leads = true;
            self.startLine();
            try self.flow(cell.first, cell.first + cell.count);
            try self.endLine(false);
            return self.y;
        }

        /// A flex container: the boxes it holds, and any words of its own
        /// between them, set one after another along its main axis with the
        /// room its `gap` says between them, and moved along that axis and
        /// across it as its `justify-content` and `align-items` say.
        ///
        /// An item is as long as it says it is, in pixels or as a share of
        /// the room or of the window, held between the least and most it
        /// says; one that says nothing is as long as its words come to, set
        /// in a share of what the others leave, which is all the room there
        /// is for it however much more its words would take.
        fn flex(self: *Self, index: u32, x: i32, room: i32) Error!void {
            const style = self.page.containers.items[index].style;
            const down = style.direction == .column;
            // The room its items share is what it is given, where it says.
            const wide = @max(self.sized(style.width, style.min_width, style.max_width, room) orelse room, 0);
            var items = try self.gather(index);
            defer items.deinit(self.gpa);
            if (items.items.len == 0) return;

            const between = self.resolved(style.gap, wide) orelse 0;
            const top = self.y;
            const keep = self.previous;
            defer self.previous = keep;
            const first_line = self.out.lines.items.len;

            // What each item is given along the main axis and across it,
            // where it says: the rest is what its words come to.
            var taken: i32 = 0;
            var asking: i32 = 0;
            for (items.items) |*item| {
                item.main = if (down)
                    self.sized(item.style.height, item.style.min_height, item.style.max_height, wide)
                else
                    self.sized(item.style.width, item.style.min_width, item.style.max_width, wide);
                item.cross = if (down)
                    self.sized(item.style.width, item.style.min_width, item.style.max_width, wide)
                else
                    self.sized(item.style.height, item.style.min_height, item.style.max_height, wide);
                if (item.main) |main| taken += main else asking += 1;
            }
            const gaps = between * @as(i32, @intCast(items.items.len - 1));
            const share = if (down or asking == 0)
                0
            else
                @max(@divTrunc(@max(wide - taken - gaps, 0), asking), 1);

            // Each item's words are set where it would go, then measured,
            // and moved to where it does go once every one of them is known.
            for (items.items) |*item| {
                const along = item.main orelse share;
                self.y = if (down) self.y else top;
                item.x = x;
                item.y = self.y;
                item.first = self.out.lines.items.len;
                self.previous = null;
                try self.setItem(item, x, @max(if (down) (item.cross orelse wide) else along, 1));
                item.lines = self.out.lines.items.len - item.first;
                for (self.out.lines.items[item.first..][0..item.lines]) |line| {
                    for (self.out.fragsOf(line)) |frag| item.wide = @max(item.wide, frag.x + frag.width - x);
                    item.tall = @max(item.tall, line.y + line.height - item.y);
                }
                if (item.main == null) {
                    item.main = self.held(
                        if (down) item.tall else item.wide,
                        if (down) item.style.min_height else item.style.min_width,
                        if (down) item.style.max_height else item.style.max_width,
                        wide,
                    );
                }
            }

            // More than the room there is: every item is held to a share of
            // it, in proportion to what it asked for, the last taking what
            // does not divide. Nothing of a page is set outside the column.
            var main_total: i32 = gaps;
            for (items.items) |item| main_total += item.main.?;
            if (main_total > wide) {
                var all: i32 = 0;
                for (items.items) |item| all += item.main.?;
                const left = @max(wide - gaps, 0);
                var done: i32 = 0;
                for (items.items, 0..) |*item, each| {
                    item.main = if (each + 1 == items.items.len or all <= 0)
                        @max(left - done, 0)
                    else
                        @divTrunc(left * item.main.?, all);
                    done += item.main.?;
                }
                main_total = gaps;
                for (items.items) |item| main_total += item.main.?;
            }

            // Across the axis an item is as wide or as tall as it says, or
            // as its words came out; down a column it stretches.
            var across_room: i32 = if (down) wide else 0;
            for (items.items) |*item| {
                item.cross = item.cross orelse if (down) wide else item.tall;
                if (!down) across_room = @max(across_room, item.cross.?);
            }

            var along: i32 = switch (style.justify) {
                .start, .between => 0,
                .center => @max(@divTrunc(wide - main_total, 2), 0),
                .end => @max(wide - main_total, 0),
            };
            const between_extra: i32 = if (style.justify == .between and items.items.len > 1)
                @divTrunc(@max(wide - main_total, 0), @as(i32, @intCast(items.items.len - 1)))
            else
                0;

            for (items.items) |item| {
                const offset: i32 = switch (style.items) {
                    .start => 0,
                    .center => @divTrunc(across_room - item.cross.?, 2),
                    .end => across_room - item.cross.?,
                };
                const area: Area = if (down)
                    .{ .x = x + offset, .y = top + along, .w = item.cross.?, .h = item.main.? }
                else
                    .{ .x = x + along, .y = top + offset, .w = item.main.?, .h = item.cross.? };
                try self.out.placed.append(self.gpa, .{ .area = area, .container = item.container });
                self.shift(item, area.x - item.x, area.y - item.y);
                along += item.main.? + between + between_extra;
            }

            // The container is as long as its items come to, or as it says.
            var tall = if (down) main_total else across_room;
            for ([_]page_mod.Unit{ style.min_height, style.height }) |unit| {
                if (self.resolved(unit, self.viewport.h)) |least| tall = @max(tall, least);
            }
            if (self.resolved(style.max_height, self.viewport.h)) |most| tall = @min(tall, most);
            self.y = top + tall;
            // Lines side by side are kept in the order of their tops.
            std.sort.block(Line, self.out.lines.items[first_line..], {}, topAbove);
        }

        /// What a flex container holds, in the order it comes: each box
        /// among its blocks, and each block of its own between them. Words
        /// of its own that no element holds are an item of their own, as a
        /// browser makes one.
        fn gather(self: *Self, index: u32) Error!std.ArrayList(Item) {
            var items: std.ArrayList(Item) = .empty;
            errdefer items.deinit(self.gpa);
            const span = self.owns(index);
            const children = self.page.childrenOf(self.page.containers.items[index]);
            var at = span.first;
            var kid: usize = 0;
            while (at < span.end) {
                var which: ?u32 = null;
                while (kid < children.len) {
                    const next = children[kid];
                    if (next >= self.page.containers.items.len) {
                        kid += 1;
                        continue;
                    }
                    const there = self.owns(next);
                    if (there.end <= at) {
                        kid += 1;
                        continue;
                    }
                    if (there.first > at) break;
                    which = next;
                    kid += 1;
                    break;
                }
                if (which) |next| {
                    try items.append(self.gpa, .{ .container = next, .style = self.page.containers.items[next].style });
                    at = @max(at, self.owns(next).end);
                    continue;
                }
                try items.append(self.gpa, .{ .block = at });
                at += 1;
            }
            return items;
        }

        /// Set what one flex item holds, in a box `width` wide from `x`.
        fn setItem(self: *Self, item: *const Item, x: i32, width: i32) Error!void {
            if (item.container) |which| return self.container(which, x, width);
            if (item.block) |which| {
                const keep_left = self.left;
                const keep_right = self.right;
                defer {
                    self.left = keep_left;
                    self.right = keep_right;
                }
                self.left = x;
                self.right = x + width;
                return self.layBlock(which);
            }
        }

        /// Move the lines of one item, and the words on them, to where the
        /// item goes.
        fn shift(self: *Self, item: Item, by_x: i32, by_y: i32) void {
            for (self.out.lines.items[item.first..][0..item.lines]) |*line| {
                line.y += by_y;
                for (self.out.frags.items[line.first..][0..line.count]) |*frag| frag.x += by_x;
            }
        }

        /// What a length says in pixels, where it says: nothing where a page
        /// says `auto`, or a unit this reader does not read.
        fn resolved(self: *const Self, unit: page_mod.Unit, base: i32) ?i32 {
            const value: f64 = switch (unit) {
                .auto => return null,
                .px => unit.px,
                .percent => unit.percent / 100 * @as(f64, @floatFromInt(base)),
                .vw => unit.vw / 100 * @as(f64, @floatFromInt(self.viewport.w)),
                .vh => unit.vh / 100 * @as(f64, @floatFromInt(self.viewport.h)),
            };
            return @intFromFloat(@round(value));
        }

        /// `size` held between the least and most a box says, where it says.
        fn held(self: *const Self, size: i32, least: page_mod.Unit, most: page_mod.Unit, base: i32) i32 {
            var value = size;
            if (self.resolved(least, base)) |low| value = @max(value, low);
            if (self.resolved(most, base)) |high| value = @min(value, high);
            return value;
        }

        /// What a box is given on one axis: the length it says, held between
        /// the least and most it says. Nothing where it says nothing.
        fn sized(self: *const Self, unit: page_mod.Unit, least: page_mod.Unit, most: page_mod.Unit, base: i32) ?i32 {
            const size = self.resolved(unit, base) orelse return self.resolved(least, base);
            return self.held(size, least, most, base);
        }

        /// Say which of the page's blocks each of the boxes it kept holds,
        /// and whether together they hold the whole of it: only then is the
        /// page set box by box. A page that kept none, or none that ask for
        /// box layout, keeps the column of blocks it has always had.
        fn cover(self: *Self) bool {
            const boxes = self.page.containers.items;
            if (boxes.len == 0) return false;
            var asked = false;
            for (boxes) |each| {
                if (each.style.display == .flex) asked = true;
            }
            if (!asked) return false;

            const spans = self.gpa.alloc(Owns, boxes.len) catch return false;
            const parents = self.gpa.alloc(u32, boxes.len) catch {
                self.gpa.free(spans);
                return false;
            };
            @memset(spans, .{ .first = std.math.maxInt(u32), .end = 0 });
            @memset(parents, 0);
            self.foster(parents, 0);
            // Every block is held by the box it was opened in and by every
            // box that holds that one.
            for (self.page.blocks.items, 0..) |block, index| {
                var at = block.owner;
                for (0..spans.len + 1) |_| {
                    if (at >= spans.len) break;
                    const at_index: u32 = @intCast(index);
                    spans[at].first = @min(spans[at].first, at_index);
                    spans[at].end = @max(spans[at].end, at_index + 1);
                    if (at == 0) break;
                    at = parents[at];
                }
            }
            for (spans) |*span| {
                if (span.first > span.end) span.* = .{};
            }
            self.spans = spans;
            self.parents = parents;
            return spans[0].first == 0 and spans[0].end == self.page.blocks.items.len;
        }

        /// Note the box holding each of the page's boxes, down from the one
        /// at `index`.
        fn foster(self: *Self, parents: []u32, index: u32) void {
            for (self.page.childrenOf(self.page.containers.items[index])) |kid| {
                if (kid == 0 or kid >= parents.len) continue;
                parents[kid] = index;
                self.foster(parents, kid);
            }
        }

        /// A table too wide to set as a grid: its cells one after another, a
        /// row's close together and the rows apart.
        fn linear(self: *Self, cells: []const page_mod.Cell) Error!void {
            for (cells, 0..) |cell, i| {
                if (i > 0) self.y += if (cell.row != cells[i - 1].row) self.spacing.paragraph else self.spacing.item;
                self.leads = true;
                self.alignment = cell.alignment;
                self.startLine();
                try self.flow(cell.first, cell.first + cell.count);
                try self.endLine(false);
            }
        }
    };
}

/// What a cell's words need at the least and would take at the most.
const Extent = struct { least: i32 = 0, most: i32 = 0 };

/// Which of the page's blocks one of the boxes it kept holds: those from
/// `first` up to `end`, which is past the last of them.
const Owns = struct { first: u32 = 0, end: u32 = 0 };

/// One item of a flex container, before it is put where it goes: the box it
/// is, or the one block of the container's own words it is; what it is given
/// along the container's main axis, `main`, and across it, `cross`, where it
/// is given anything; and what its words came to, `wide` and `tall`, set
/// from `x` and `y`, before they were moved to where it goes.
const Item = struct {
    container: ?u32 = null,
    block: ?u32 = null,
    style: page_mod.BoxStyle = .{},
    main: ?i32 = null,
    cross: ?i32 = null,
    wide: i32 = 0,
    tall: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    first: usize = 0,
    lines: usize = 0,
};

/// The columns a cell spans, from the first to past the last, kept inside
/// the table's.
const Span = struct { start: usize, end: usize };

fn spanOf(cell: page_mod.Cell, columns: usize) Span {
    const start = @min(@as(usize, cell.column), columns - 1);
    return .{ .start = start, .end = @max(@min(@as(usize, cell.column) + cell.across, columns), start + 1) };
}

/// Widen `columns`, which a cell spans, by what the cell needs past their
/// sum: shared evenly, the last taking what does not divide.
fn spread(columns: []i32, needs: i32) void {
    const short = needs - sum(columns);
    if (short <= 0) return;
    const count: i32 = @intCast(columns.len);
    for (columns) |*width| width.* += @divTrunc(short, count);
    columns[columns.len - 1] += @rem(short, count);
}

fn sum(values: []const i32) i32 {
    var total: i32 = 0;
    for (values) |value| total += value;
    return total;
}

fn topAbove(_: void, a: Line, b: Line) bool {
    return a.y < b.y;
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

/// A table of words, a row a slice, set as a grid.
fn tableOf(b: *Built, rows: []const []const []const u8) !void {
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try builder.beginTable();
    for (rows) |row| {
        builder.beginRow();
        for (row) |words| {
            try builder.beginCell(.{});
            try builder.words(words);
        }
    }
    try builder.endTable();
    try builder.finish();
}

test "a table's columns are as wide as their widest cells where they fit" {
    var b = Built{};
    defer b.deinit();
    try tableOf(&b, &.{ &.{ "ab", "abcdef" }, &.{ "a", "b" } });
    b.layout = try build(testing.allocator, &b.page, 600, eighteen, Fixed{});

    // Four between each cell's words and its edges, and a rule of one
    // between the cells and around them: 1 + 4 + 12 + 4 + 1 + 4 + 36 + 4 + 1.
    try testing.expectEqual(@as(i32, 67), b.layout.tables.items[0].area.w);
    // The first row's cells stand side by side, and the second's below them.
    const lines = b.layout.lines.items;
    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqual(lines[0].y, lines[1].y);
    try testing.expectEqual(@as(i32, 5), b.line(0)[0].x);
    try testing.expectEqual(@as(i32, 26), b.line(1)[0].x);
    try testing.expect(lines[2].y > lines[0].y);
    // A point in the first row finds its lines.
    try testing.expectEqual(@as(usize, 0), b.layout.lineAt(lines[0].y + 1));
}

test "a table narrower than its words shares the room, and one too narrow reads a cell at a time" {
    var b = Built{};
    defer b.deinit();
    try tableOf(&b, &.{&.{ "aa bb", "cc dd ee" }});
    // Fifty-four for the words: twenty-four they need, thirty more shared by
    // how much more each would take, eighteen to thirty-six.
    b.layout = try build(testing.allocator, &b.page, 73, eighteen, Fixed{});
    const boxes = b.layout.boxes.items;
    try testing.expectEqual(@as(i32, 22 + 8), boxes[0].area.w);
    try testing.expectEqual(@as(i32, 32 + 8), boxes[1].area.w);

    // Words longer than a block's least room is wide, rules and padding and
    // all, read a cell at a time.
    var narrow = Built{};
    defer narrow.deinit();
    try tableOf(&narrow, &.{&.{ "aaaaaaa", "bbbbbbb" }});
    narrow.layout = try build(testing.allocator, &narrow.page, 30, eighteen, Fixed{});
    try testing.expectEqual(@as(usize, 0), narrow.layout.tables.items.len);
    const lines = narrow.layout.lines.items;
    try testing.expect(lines.len >= 2 and lines[1].y > lines[0].y);
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

/// One thing a flex container holds in a page built for a test: words of its
/// own, or a box of the page's with words in it and a style of its own.
const Held = struct {
    words: []const u8,
    style: page_mod.BoxStyle = .{},
    /// Words no element holds, which are held by the container itself.
    own: bool = false,
};

/// A page of paragraphs, each in the box the page keeps for it, and all of
/// them in one container at the page's root, `wide` pixels wide.
fn flexed(wide: i32, container: page_mod.BoxStyle, held: []const Held) !Built {
    var b = Built{};
    var builder = page_mod.Builder{ .gpa = testing.allocator, .page = &b.page };
    try b.page.containers.append(testing.allocator, .{ .style = container });
    for (held) |item| {
        if (item.own) continue;
        try b.page.containers.append(testing.allocator, .{ .style = item.style });
    }
    for (held, 1..) |item, index| {
        if (!item.own) try b.page.container_children.append(testing.allocator, @intCast(index));
    }
    b.page.containers.items[0].children = .{ .first = 0, .count = @intCast(b.page.container_children.items.len) };
    var box: u32 = 1;
    for (held) |item| {
        builder.owner = if (item.own) 0 else box;
        if (!item.own) box += 1;
        try builder.boundary(.{});
        try builder.words(item.words);
    }
    try builder.finish();
    b.layout = try build(testing.allocator, &b.page, wide, eighteen, Fixed{});
    return b;
}

const flex = page_mod.BoxStyle{ .display = .flex };

test "a flex container sets its boxes in a row, with the gap it says between them" {
    // Two letters a box: twelve pixels, and ten between them.
    var b = try flexed(200, .{ .display = .flex, .gap = .{ .px = 10 } }, &.{
        .{ .words = "aa" }, .{ .words = "bb" }, .{ .words = "cc" },
    });
    defer b.deinit();
    const placed = b.layout.placed.items;
    try testing.expectEqual(@as(usize, 3), placed.len);
    for (placed, [_]i32{ 0, 22, 44 }) |item, x| {
        try testing.expectEqual(x, item.area.x);
        try testing.expectEqual(@as(i32, 12), item.area.w);
        try testing.expectEqual(@as(i32, 0), item.area.y);
        try testing.expectEqual(@as(i32, 18), item.area.h);
    }
    // Every word stands beside the one before it, on the same line.
    try testing.expectEqual(@as(usize, 3), b.layout.lines.items.len);
    for (b.layout.lines.items) |line| try testing.expectEqual(@as(i32, 0), line.y);
    try testing.expectEqual(@as(i32, 0), b.line(0)[0].x);
    try testing.expectEqual(@as(i32, 22), b.line(1)[0].x);
    try testing.expectEqual(@as(i32, 18), b.layout.height);
}

test "a column stacks its items down the page" {
    var b = try flexed(200, .{ .display = .flex, .direction = .column, .gap = .{ .px = 4 } }, &.{
        .{ .words = "aa" }, .{ .words = "bb" },
    });
    defer b.deinit();
    const placed = b.layout.placed.items;
    try testing.expectEqual(@as(i32, 0), placed[0].area.y);
    try testing.expectEqual(@as(i32, 22), placed[1].area.y);
    try testing.expectEqual(@as(i32, 18), placed[0].area.h);
    try testing.expectEqual(@as(i32, 40), b.layout.height);
    // Each is as wide as the room, and its words start at its left.
    try testing.expectEqual(@as(i32, 200), placed[0].area.w);
}

test "what an item is given: pixels, a share, or a share of the window, held as it says" {
    var b = try flexed(200, flex, &.{
        .{ .words = "aa", .style = .{ .width = .{ .px = 50 } } },
        .{ .words = "bb", .style = .{ .width = .{ .percent = 25 } } },
        .{ .words = "cc", .style = .{ .width = .{ .vw = 10 } } },
        .{ .words = "dd", .style = .{ .min_width = .{ .px = 40 } } },
        .{ .words = "ee", .style = .{ .width = .{ .px = 60 }, .max_width = .{ .px = 30 } } },
    });
    defer b.deinit();
    const placed = b.layout.placed.items;
    try testing.expectEqual(@as(usize, 5), placed.len);
    for (placed, [_]i32{ 0, 50, 100, 120, 160 }) |item, x| try testing.expectEqual(x, item.area.x);
    for (placed, [_]i32{ 50, 50, 20, 40, 30 }) |item, w| try testing.expectEqual(w, item.area.w);
}

test "a flex container is as tall as it says, in a share of the window's height" {
    // Fifty per cent of a window as tall as the column is wide: a hundred.
    var b = try flexed(200, .{ .display = .flex, .min_height = .{ .vh = 50 } }, &.{.{ .words = "aa" }});
    defer b.deinit();
    try testing.expectEqual(@as(i32, 100), b.layout.height);
    try testing.expectEqual(@as(i32, 18), b.layout.placed.items[0].area.h);
}

test "an item's words are set in the width it is given" {
    var b = try flexed(200, flex, &.{.{ .words = "aaaa bbbb", .style = .{ .width = .{ .px = 30 } } }});
    defer b.deinit();
    // Four letters a line at six pixels a letter, so two lines of eighteen.
    try testing.expectEqual(@as(usize, 2), b.layout.lines.items.len);
    try testing.expectEqualStrings("aaaa", b.fragText(b.line(0)[0]));
    const area = b.layout.placed.items[0].area;
    try testing.expectEqual(@as(i32, 30), area.w);
    try testing.expectEqual(@as(i32, 36), area.h);
    try testing.expectEqual(@as(i32, 24), b.line(0)[0].width);
}

test "items are moved along the row as the container says" {
    // Two boxes of twelve: a hundred and seventy-six left over.
    const words = [_]Held{ .{ .words = "aa" }, .{ .words = "bb" } };
    var middle = try flexed(200, .{ .display = .flex, .justify = .center }, &words);
    defer middle.deinit();
    try testing.expectEqual(@as(i32, 88), middle.layout.placed.items[0].area.x);

    var ending = try flexed(200, .{ .display = .flex, .justify = .end }, &words);
    defer ending.deinit();
    try testing.expectEqual(@as(i32, 176), ending.layout.placed.items[0].area.x);

    var apart = try flexed(200, .{ .display = .flex, .justify = .between }, &words);
    defer apart.deinit();
    try testing.expectEqual(@as(i32, 0), apart.layout.placed.items[0].area.x);
    try testing.expectEqual(@as(i32, 188), apart.layout.placed.items[1].area.x);
    // And the words go with them.
    try testing.expectEqual(@as(i32, 188), apart.line(1)[0].x);
}

test "items are moved across the row as the container says" {
    // One line of eighteen beside two of thirty-six.
    var b = try flexed(200, .{ .display = .flex, .items = .center }, &.{
        .{ .words = "aa" },
        .{ .words = "aaaa bbbb", .style = .{ .width = .{ .px = 30 } } },
    });
    defer b.deinit();
    const placed = b.layout.placed.items;
    try testing.expectEqual(@as(i32, 9), placed[0].area.y);
    try testing.expectEqual(@as(i32, 0), placed[1].area.y);
    try testing.expectEqual(@as(i32, 36), b.layout.height);

    var footed = try flexed(200, .{ .display = .flex, .items = .end }, &.{ .{ .words = "aa" }, .{ .words = "aaaa bbbb", .style = .{ .width = .{ .px = 30 } } } });
    defer footed.deinit();
    try testing.expectEqual(@as(i32, 18), footed.layout.placed.items[0].area.y);
}

test "words of a flex container's own are an item of their own" {
    var b = try flexed(200, .{ .display = .flex, .gap = .{ .px = 10 } }, &.{
        .{ .words = "aa" }, .{ .words = "bb", .own = true }, .{ .words = "cc" },
    });
    defer b.deinit();
    const placed = b.layout.placed.items;
    try testing.expectEqual(@as(usize, 3), placed.len);
    try testing.expectEqual(@as(?u32, 1), placed[0].container);
    try testing.expectEqual(@as(?u32, null), placed[1].container);
    for (placed, [_]i32{ 0, 22, 44 }) |item, x| try testing.expectEqual(x, item.area.x);
}

test "items asking for more than the room there is are held to a share of it" {
    // Forty and thirty ask for seventy of the sixty there is: each keeps
    // what it asked for of sixty, and the last takes what does not divide.
    var b = try flexed(60, flex, &.{
        .{ .words = "aa", .style = .{ .width = .{ .px = 40 } } },
        .{ .words = "bb", .style = .{ .width = .{ .px = 30 } } },
    });
    defer b.deinit();
    const placed = b.layout.placed.items;
    try testing.expectEqual(@as(i32, 0), placed[0].area.x);
    try testing.expectEqual(@as(i32, 34), placed[0].area.w);
    try testing.expectEqual(@as(i32, 34), placed[1].area.x);
    try testing.expectEqual(@as(i32, 26), placed[1].area.w);
}

test "a page whose boxes ask for no box layout keeps the column it had" {
    var held = try flexed(60, .{ .display = .block }, &.{.{ .words = "aaaa bbbb cccc" }});
    defer held.deinit();
    var plain = try paragraph("aaaa bbbb cccc", 60);
    defer plain.deinit();
    try testing.expectEqual(plain.layout.lines.items.len, held.layout.lines.items.len);
    for (plain.layout.lines.items, held.layout.lines.items) |want, got| {
        try testing.expectEqual(want.y, got.y);
        try testing.expectEqual(want.height, got.height);
    }
    try testing.expectEqual(@as(i32, 0), held.line(0)[0].x);
    try testing.expectEqual(@as(usize, 0), held.layout.placed.items.len);
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
