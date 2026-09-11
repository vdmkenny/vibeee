//! A page as this reader keeps it: the words in order, and what each run of
//! them is.
//!
//! The parser builds a tree of every element and attribute a page had, which
//! is far more than a reader draws and, on a large page, several times the
//! page's own size. So the tree is walked once into this and let go: one
//! buffer of text, runs over it, blocks over the runs, and the strings, links,
//! forms, controls and pictures the runs refer to beside them. Nothing here
//! points into the tree, so the tree can go the moment the walk ends.
//!
//! Pure and host-tested. Whether a space landed inside a link or outside it
//! is decided here, and is not something to find out on the panel.

const std = @import("std");
const rgb = @import("lib").rgb;
const Charset = @import("charset.zig").Charset;

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

/// One of the page's own colours, by its place in `Page.palette`. `none` is
/// no colour of the page's, which leaves the theme's.
pub const Swatch = enum(u8) {
    none = 0,
    _,

    /// The swatch for the colour at `place` in the palette.
    fn at(place: usize) Swatch {
        return @enumFromInt(place + 1);
    }

    /// Where its colour is in the palette, or nothing for the theme's.
    fn index(self: Swatch) ?usize {
        return if (self == .none) null else @intFromEnum(self) - 1;
    }
};

/// How words look. Packed, so that two looks compare as one small value.
pub const Look = packed struct(u12) {
    face: Face = .body,
    ink: Ink = .text,
    /// The colour the page gives the words, where it gives one.
    paint: Swatch = .none,
};

/// Which way a block's lines lean.
pub const Alignment = enum(u2) { start, center, end };

/// The colours a page gives something it shows: its words, and what they sit
/// on.
pub const Colours = packed struct(u16) {
    ink: Swatch = .none,
    ground: Swatch = .none,
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
    /// One of the page's controls, where the page put it among the words.
    control: u16,
    /// One of the page's pictures, where the page put it among the words.
    picture: u16,
    /// The line ends here: a `<br>`, or a line end in preformatted text.
    line_break,
};

pub const Kind = union(enum) {
    paragraph,
    heading,
    /// A list entry, with its marker in the margin.
    item,
    /// Text whose spaces and line ends are the page's own.
    preformatted,
    /// A horizontal rule: no runs, only the line.
    rule,
    /// A table set as a grid. Its runs are its cells', one cell after
    /// another.
    table: Grid,
};

/// A table's cells, among the page's, and the columns and rows they make.
pub const Grid = struct {
    first: u32 = 0,
    count: u32 = 0,
    columns: u16 = 0,
    rows: u16 = 0,
};

/// One cell of a table set as a grid.
pub const Cell = struct {
    /// Its runs, among the page's.
    first: u32,
    count: u32 = 0,
    /// Where it sits in its table, and how many columns and rows it spans.
    row: u16,
    column: u16,
    across: u16 = 1,
    down: u16 = 1,
    /// A header's, which says what the cells in its row or column hold.
    header: bool = false,
    ground: Swatch = .none,
    alignment: Alignment = .start,
};

/// What a cell is, as the page gives it.
pub const CellSpec = struct {
    header: bool = false,
    across: u16 = 1,
    down: u16 = 1,
    /// Across every column the table comes to have, as a caption is.
    whole_row: bool = false,
    ground: Swatch = .none,
    alignment: Alignment = .start,
};

/// The most columns a table is set in. A cell past them is left out, words
/// and all.
pub const COLUMNS_MAX = 32;
/// The most rows one cell spans.
pub const SPAN_MAX = 64;

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
    /// What the page paints under it, where it paints anything.
    ground: Swatch = .none,
    alignment: Alignment = .start,
    /// Its runs, which a block still to be opened does not have.
    first: u32 = 0,
    count: u32 = 0,
};

/// Where a string is among the page's strings. Empty is the empty string.
pub const Span = struct { at: u32 = 0, len: u32 = 0 };

/// Where a form's answers go, and how.
pub const Form = struct {
    /// Already resolved against the page's own address.
    action: Span,
    method: Method,

    pub const Method = enum {
        /// In the address, as a query: what a search is.
        get,
        /// In the body of a request: what logging in and ordering are.
        post,
    };
};

/// A control a page asks a person to fill in or to press.
pub const Control = struct {
    kind: ControlKind,
    /// The form its answer is part of, where it is inside one.
    form: ?u16 = null,
    /// The name its answer goes under. One without a name sends nothing.
    name: Span = .{},
    /// What it sends: a line's words to begin with, a box's value when it
    /// is ticked, a button's when it is the one pressed.
    value: Span = .{},
    /// The colours the page gives it, where it gives any.
    colours: Colours = .{},
};

pub const ControlKind = union(enum) {
    /// A line to type in.
    line: Line,
    /// Sent with its form and never shown.
    hidden,
    /// Sends its form, with its own answer among the rest.
    submit: Press,
    /// Puts its form back the way it arrived.
    reset: Press,
    /// A box that is ticked or not.
    tick: Tick,

    pub const Line = struct {
        /// About how many letters wide it is drawn.
        letters: u16 = 20,
        /// Shown as stars.
        secret: bool = false,
        /// What it says, dimly, while it is empty.
        hint: Span = .{},
        /// Which of the page's lines it is, for whoever keeps what is typed.
        slot: u16 = 0,
    };

    pub const Press = struct {
        /// What the button says.
        label: Span = .{},
    };

    pub const Tick = struct {
        ticked: bool = false,
        /// One of a group sharing its name, of which only one is ticked.
        radio: bool = false,
        /// Which of the page's boxes it is.
        slot: u16 = 0,
    };
};

/// A picture the page shows among its words.
pub const Picture = struct {
    /// Where it is, resolved against the page's own address, or empty where
    /// the page gave nowhere this reader can fetch it from.
    source: Span,
    /// What the page says it shows. It stands in for the picture until the
    /// picture arrives, and wherever it cannot.
    alt: Span,
    /// The size the page gives it, in the page's own pixels, where it gives
    /// one.
    width: ?u16 = null,
    height: ?u16 = null,
    /// Where it goes when it is clicked, where it sits inside a link.
    link: ?u16 = null,
};

pub const Page = struct {
    title: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(Run) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    /// What the page keeps beside its words, one string after another.
    strings: std.ArrayList(u8) = .empty,
    /// Where each link goes, in `strings`.
    links: std.ArrayList(Span) = .empty,
    forms: std.ArrayList(Form) = .empty,
    controls: std.ArrayList(Control) = .empty,
    pictures: std.ArrayList(Picture) = .empty,
    /// The page's own colours, which swatches name.
    palette: std.ArrayList(rgb.Colour) = .empty,
    /// The cells of its tables set as grids.
    cells: std.ArrayList(Cell) = .empty,
    /// How many of the controls are lines to type in, and boxes to tick.
    lines: u16 = 0,
    ticks: u16 = 0,
    /// The encoding the page arrived in, which is the one its forms answer
    /// in.
    encoding: Charset = .utf8,
    /// What the page is painted on, where it paints anything.
    ground: Swatch = .none,

    pub fn deinit(self: *Page, gpa: std.mem.Allocator) void {
        self.title.deinit(gpa);
        self.text.deinit(gpa);
        self.runs.deinit(gpa);
        self.blocks.deinit(gpa);
        self.strings.deinit(gpa);
        self.links.deinit(gpa);
        self.forms.deinit(gpa);
        self.controls.deinit(gpa);
        self.pictures.deinit(gpa);
        self.palette.deinit(gpa);
        self.cells.deinit(gpa);
        self.* = .{};
    }

    pub fn runsOf(self: *const Page, block: Block) []const Run {
        return self.runs.items[block.first..][0..block.count];
    }

    pub fn cellsOf(self: *const Page, grid: Grid) []const Cell {
        return self.cells.items[grid.first..][0..grid.count];
    }

    pub fn cellRuns(self: *const Page, cell: Cell) []const Run {
        return self.runs.items[cell.first..][0..cell.count];
    }

    pub fn textOf(self: *const Page, text: Text) []const u8 {
        return self.text.items[text.start..][0..text.len];
    }

    pub fn string(self: *const Page, span: Span) []const u8 {
        return self.strings.items[span.at..][0..span.len];
    }

    /// The colour a swatch stands for, or nothing for the theme's.
    pub fn colourOf(self: *const Page, swatch: Swatch) ?rgb.Colour {
        const index = swatch.index() orelse return null;
        if (index >= self.palette.items.len) return null;
        return self.palette.items[index];
    }

    /// Where a link goes.
    pub fn address(self: *const Page, link: u16) ?[]const u8 {
        if (link >= self.links.items.len) return null;
        return self.string(self.links.items[link]);
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
    /// The form the walk is inside, where it is inside one.
    form: ?u16 = null,

    next: Block = .{},
    /// The block being filled. Opened by the first thing put in it, so a
    /// boundary with nothing after it before the next leaves no empty block.
    open: ?Block = null,
    /// A space is owed between what came last and whatever comes next. Owed
    /// rather than written, so none lands at the end of a block.
    space: bool = false,
    /// Characters since the last line end in preformatted text, for tabs.
    column: usize = 0,
    /// The table being filled, while one is.
    filling: ?Filling = null,

    pub const Error = std.mem.Allocator.Error;

    /// A table as its cells arrive: the rows begun and the widest any has
    /// been, where the row's next cell goes at the earliest, which columns
    /// cells from rows above still cover, and the cell being filled.
    const Filling = struct {
        rows: u16 = 0,
        columns: u16 = 0,
        column: u16 = 0,
        in_row: bool = false,
        /// The columns a cell from a row above covers in the row being
        /// filled, and for each column how many rows after this one such a
        /// cell still covers.
        covered: std.StaticBitSet(COLUMNS_MAX) = .initEmpty(),
        below: [COLUMNS_MAX]u16 = @splat(0),
        /// Among the page's cells.
        cell: ?u32 = null,
    };

    /// End the block being filled, if anything was put in it, and say what
    /// the next one will be. Inside a table a block is a line of its cell
    /// rather than a block of the page's.
    pub fn boundary(self: *Builder, next: Block) Error!void {
        if (self.filling != null) return self.cellBreak();
        try self.close();
        self.next = next;
    }

    pub fn finish(self: *Builder) Error!void {
        if (self.filling != null) try self.endTable();
        try self.close();
    }

    /// Begin a table set as a grid, as a block of its own.
    pub fn beginTable(self: *Builder) Error!void {
        try self.close();
        var block = self.next;
        block.kind = .{ .table = .{ .first = @intCast(self.page.cells.items.len) } };
        block.marker = .none;
        block.first = @intCast(self.page.runs.items.len);
        block.count = 0;
        self.open = block;
        self.filling = .{};
    }

    /// Begin a row of the table being filled.
    pub fn beginRow(self: *Builder) void {
        self.endCell();
        const fill = if (self.filling) |*table| table else return;
        fill.in_row = true;
        fill.rows +|= 1;
        fill.column = 0;
        // A cell from a row above covers the rows it still reaches into.
        fill.covered = .initEmpty();
        for (&fill.below, 0..) |*left, column| {
            if (left.* == 0) continue;
            fill.covered.set(column);
            left.* -= 1;
        }
    }

    /// Begin a cell of the row being filled, in the first column from where
    /// the row has got to that no cell from above covers.
    pub fn beginCell(self: *Builder, spec: CellSpec) Error!void {
        if (self.filling == null) return;
        if (self.filling.?.in_row) self.endCell() else self.beginRow();
        const fill = &self.filling.?;
        var column = if (spec.whole_row) 0 else fill.column;
        while (column < COLUMNS_MAX and fill.covered.isSet(column)) column += 1;
        if (column == COLUMNS_MAX) return;
        const across: u16 = if (spec.whole_row) 0 else @min(@max(spec.across, 1), COLUMNS_MAX - column);
        const down: u16 = @min(@max(spec.down, 1), SPAN_MAX);
        for (fill.below[column..][0..@max(across, 1)]) |*left| left.* = @max(left.*, down - 1);
        fill.column = column + @max(across, 1);
        if (!spec.whole_row) fill.columns = @max(fill.columns, fill.column);
        try self.page.cells.append(self.gpa, .{
            .first = @intCast(self.page.runs.items.len),
            .row = fill.rows - 1,
            .column = column,
            .across = across,
            .down = down,
            .header = spec.header,
            .ground = spec.ground,
            .alignment = spec.alignment,
        });
        fill.cell = @intCast(self.page.cells.items.len - 1);
        self.space = false;
        self.column = 0;
    }

    /// End the cell being filled.
    pub fn endCell(self: *Builder) void {
        const fill = if (self.filling) |*table| table else return;
        const index = fill.cell orelse return;
        const cell = &self.page.cells.items[index];
        cell.count = @as(u32, @intCast(self.page.runs.items.len)) - cell.first;
        fill.cell = null;
        self.space = false;
    }

    /// End the row being filled.
    pub fn endRow(self: *Builder) void {
        self.endCell();
        if (self.filling) |*fill| fill.in_row = false;
    }

    /// End the table being filled, which ends its block.
    pub fn endTable(self: *Builder) Error!void {
        self.endRow();
        const fill = self.filling orelse return;
        self.filling = null;
        if (self.open) |*block| {
            const grid = &block.kind.table;
            grid.count = @as(u32, @intCast(self.page.cells.items.len)) - grid.first;
            grid.columns = @max(fill.columns, 1);
            for (self.page.cells.items[grid.first..]) |*cell| {
                // A cell across the whole of a row is across every column.
                if (cell.across == 0) cell.across = grid.columns;
                grid.rows = @max(grid.rows, cell.row +| cell.down);
            }
        }
        try self.close();
    }

    /// Inside a table, a line ends where a block would, where the cell has
    /// anything on the line so far.
    fn cellBreak(self: *Builder) Error!void {
        if (self.midLine()) try self.lineBreak();
    }

    /// Whether words and what sits among them have somewhere to go: anywhere
    /// but between the cells of a table.
    fn placing(self: *const Builder) bool {
        const fill = self.filling orelse return true;
        return fill.cell != null;
    }

    /// Whether the cell being filled has nothing in it yet, or there is none
    /// to fill.
    fn cellEmpty(self: *const Builder) bool {
        const fill = self.filling orelse return false;
        const index = fill.cell orelse return true;
        return self.page.runs.items.len == self.page.cells.items[index].first;
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
                if (self.midLine()) self.space = true;
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
        if (!self.placing()) return;
        self.space = false;
        self.column = 0;
        const block = self.opened();
        try self.page.runs.append(self.gpa, .line_break);
        block.count += 1;
    }

    /// A horizontal rule, which is a block of its own, and inside a table
    /// the end of a line of its cell.
    pub fn rule(self: *Builder) Error!void {
        if (self.filling != null) return self.cellBreak();
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

    /// A form, and which one it is.
    pub fn addForm(self: *Builder, action: []const u8, method: Form.Method) Error!?u16 {
        const index = std.math.cast(u16, self.page.forms.items.len) orelse return null;
        try self.page.forms.append(self.gpa, .{ .action = try self.keep(action), .method = method });
        return index;
    }

    /// A control of the form the walk is in. One that shows is placed among
    /// the words where the page put it, the way a word is; a hidden one is
    /// kept for its form's answers alone.
    pub fn addControl(self: *Builder, kind: ControlKind, name: []const u8, value: []const u8, colours: Colours) Error!void {
        const index = std.math.cast(u16, self.page.controls.items.len) orelse return;
        var placed = kind;
        switch (placed) {
            .line => |*line| {
                line.slot = self.page.lines;
                self.page.lines += 1;
            },
            .tick => |*tick| {
                tick.slot = self.page.ticks;
                self.page.ticks += 1;
            },
            .hidden, .submit, .reset => {},
        }
        try self.page.controls.append(self.gpa, .{
            .kind = placed,
            .form = self.form,
            .name = try self.keep(name),
            .value = try self.keep(value),
            .colours = colours,
        });
        if (placed == .hidden) return;
        try self.place(.{ .control = index });
    }

    /// A picture, placed among the words where the page put it, the way a
    /// control is.
    pub fn addPicture(self: *Builder, source: []const u8, alt: []const u8, width: ?u16, height: ?u16) Error!void {
        const index = std.math.cast(u16, self.page.pictures.items.len) orelse return;
        try self.page.pictures.append(self.gpa, .{
            .source = try self.keep(source),
            .alt = try self.keep(alt),
            .width = width,
            .height = height,
            .link = self.link,
        });
        try self.place(.{ .picture = index });
    }

    /// Put something that is not words among them: a control or a picture.
    fn place(self: *Builder, run: Run) Error!void {
        if (!self.placing()) return;
        try self.settleSpace();
        const block = self.opened();
        try self.page.runs.append(self.gpa, run);
        block.count += 1;
    }

    /// The swatch for a colour the page gives: the same one each time it
    /// gives that colour again. Past the last a palette holds, the theme's.
    pub fn swatch(self: *Builder, colour: rgb.Colour) Error!Swatch {
        const palette = &self.page.palette;
        for (palette.items, 0..) |kept, index| {
            if (kept.eql(colour)) return .at(index);
        }
        if (palette.items.len == std.math.maxInt(u8)) return .none;
        try palette.append(self.gpa, colour);
        return .at(palette.items.len - 1);
    }

    /// Keep a string beside the page's words.
    pub fn keep(self: *Builder, bytes: []const u8) Error!Span {
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

    /// Whether the open block's current line has anything on it yet: words,
    /// or a control. A space is owed only between things on a line, never at
    /// the start of one a break has just begun.
    fn midLine(self: *const Builder) bool {
        const block = self.open orelse return false;
        if (block.count == 0 or self.cellEmpty()) return false;
        return self.page.runs.items[self.page.runs.items.len - 1] != .line_break;
    }

    /// The words the open block ends in, where it ends in words, and in a
    /// table where the cell being filled does.
    fn lastText(self: *Builder) ?*Text {
        const block = self.open orelse return null;
        if (block.count == 0 or self.cellEmpty()) return null;
        return switch (self.page.runs.items[self.page.runs.items.len - 1]) {
            .text => |*last| last,
            .control, .picture, .line_break => null,
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
        if (bytes.len == 0 or !self.placing()) return;
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

    /// Write an owed space before the next thing on the line: in that
    /// thing's look, unless it starts a link, which would underline a space
    /// ahead of it. That space goes on the end of the words before instead,
    /// or plainly after a control.
    fn settleSpace(self: *Builder) Error!void {
        if (!self.space) return;
        self.space = false;
        if (!self.midLine()) return;
        if (self.link == null) return self.put(" ");
        if (self.lastText()) |last| {
            try self.page.text.append(self.gpa, ' ');
            last.len += 1;
            return;
        }
        const look = self.look;
        const link = self.link;
        defer {
            self.look = look;
            self.link = link;
        }
        self.look.ink = .text;
        self.link = null;
        try self.put(" ");
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
/// it was, and a control or a picture as the bracketed thing a terminal can
/// show. What `web -t` prints, so the words a window shows and the words a
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
        switch (block.kind) {
            .rule => {
                try w.writeAll("----");
                continue;
            },
            .table => |grid| {
                try writeTable(w, page, grid, indent);
                continue;
            },
            else => {},
        }

        const runs = page.runsOf(block);
        for (runs, 0..) |run, i| switch (run) {
            .text => |text| try w.writeAll(page.textOf(text)),
            .control => |index| try writeControl(w, page, page.controls.items[index]),
            .picture => |index| try writePicture(w, page, page.pictures.items[index]),
            // A break the block ends on is the block's own end already.
            .line_break => if (i + 1 < runs.len) {
                try w.writeByte('\n');
                try w.splatByteAll(' ', indent);
            },
        };
    }
    if (previous != null) try w.writeByte('\n');
}

/// A table as a terminal shows one: a row a line, its cells apart by bars,
/// and a line end inside a cell a space.
fn writeTable(w: *Writer, page: *const Page, grid: Grid, indent: usize) Writer.Error!void {
    var row: ?u16 = null;
    for (page.cellsOf(grid)) |cell| {
        if (row) |at| {
            if (at == cell.row) {
                try w.writeAll(" | ");
            } else {
                try w.writeByte('\n');
                try w.splatByteAll(' ', indent);
            }
        }
        row = cell.row;
        for (page.cellRuns(cell)) |run| switch (run) {
            .text => |text| try w.writeAll(page.textOf(text)),
            .control => |index| try writeControl(w, page, page.controls.items[index]),
            .picture => |index| try writePicture(w, page, page.pictures.items[index]),
            .line_break => try w.writeByte(' '),
        };
    }
}

/// A control as a terminal shows one: a line as what is in it, a button as
/// its label, a box as ticked or not, each in brackets.
fn writeControl(w: *Writer, page: *const Page, control: Control) Writer.Error!void {
    switch (control.kind) {
        .line => |line| {
            const value = page.string(control.value);
            if (value.len > 0) return w.print("[{s}]", .{value});
            try w.writeByte('[');
            try w.splatByteAll('_', @min(line.letters, 16));
            try w.writeByte(']');
        },
        .submit, .reset => |press| try w.print("[{s}]", .{page.string(press.label)}),
        .tick => |tick| try w.writeAll(if (tick.ticked) "[x]" else "[ ]"),
        .hidden => {},
    }
}

/// A picture as a terminal shows one: what the page says it shows, in
/// brackets, or nothing where the page says nothing.
fn writePicture(w: *Writer, page: *const Page, picture: Picture) Writer.Error!void {
    const alt = page.string(picture.alt);
    if (alt.len > 0) try w.print("[{s}]", .{alt});
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

test "a form's controls sit among its words, and a hidden one only among its answers" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    f.builder.form = try f.builder.addForm("https://a.org/find", .get);
    try f.builder.words("Find ");
    try f.builder.addControl(.{ .line = .{ .letters = 8 } }, "q", "", .{});
    try f.builder.addControl(.hidden, "t", "848d6d9e", .{});
    try f.builder.words(" ");
    try f.builder.addControl(.{ .submit = .{ .label = try f.builder.keep("Go") } }, "", "Go", .{});
    try f.builder.finish();

    const page = &f.page;
    try testing.expectEqual(@as(usize, 3), page.controls.items.len);
    try testing.expectEqual(@as(u16, 1), page.lines);
    try testing.expectEqual(@as(?u16, 0), page.controls.items[1].form);
    try testing.expectEqualStrings("848d6d9e", page.string(page.controls.items[1].value));
    // The words, the line, the space between, and the button: the hidden one
    // has no place among them.
    try testing.expectEqual(@as(usize, 4), page.runs.items.len);
    try testing.expect(page.runs.items[1] == .control and page.runs.items[3] == .control);

    var text = try f.written();
    defer text.deinit();
    try testing.expectEqualStrings("Find [________] [Go]\n", text.written());
}

test "a picture sits among the words, and reads as what the page says it shows" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    try f.builder.words("Look ");
    try f.builder.addPicture("https://a.org/eee.jpg", "the machine", 400, null);
    try f.builder.words(" here");
    try f.builder.addPicture("", "", null, null);
    try f.builder.finish();

    const page = &f.page;
    try testing.expectEqual(@as(usize, 2), page.pictures.items.len);
    try testing.expectEqualStrings("https://a.org/eee.jpg", page.string(page.pictures.items[0].source));
    try testing.expectEqual(@as(?u16, 400), page.pictures.items[0].width);
    try testing.expectEqual(@as(?u16, null), page.pictures.items[0].height);
    try testing.expect(page.runs.items[1] == .picture);

    // One that says nothing of what it shows is nothing to a terminal.
    var text = try f.written();
    defer text.deinit();
    try testing.expectEqualStrings("Look [the machine] here\n", text.written());
}

test "a table's cells sit in the columns their rows leave free" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    const b = &f.builder;
    try b.beginTable();
    b.beginRow();
    try b.beginCell(.{ .header = true, .down = 2 });
    try b.words("Name");
    try b.beginCell(.{ .across = 2 });
    try b.words("Spans two");
    b.beginRow();
    try b.beginCell(.{});
    try b.words("b");
    try b.beginCell(.{});
    try b.words("c");
    try b.endTable();
    try b.finish();

    const grid = f.page.blocks.items[0].kind.table;
    try testing.expectEqual(@as(u16, 3), grid.columns);
    try testing.expectEqual(@as(u16, 2), grid.rows);
    // The second row starts past the column the header above reaches down
    // into.
    const cells = f.page.cellsOf(grid);
    try testing.expectEqual(@as(u16, 1), cells[2].column);
    try testing.expectEqual(@as(u16, 2), cells[3].column);

    var text = try f.written();
    defer text.deinit();
    try testing.expectEqualStrings("Name | Spans two\nb | c\n", text.written());
}

test "inside a table a block is a line of its cell, and nothing sits between cells" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    const b = &f.builder;
    try b.beginTable();
    b.beginRow();
    try b.words("stray");
    try b.beginCell(.{ .whole_row = true });
    try b.words("Caption");
    b.beginRow();
    try b.beginCell(.{});
    try b.boundary(.{});
    try b.words("one");
    try b.boundary(.{});
    try b.boundary(.{});
    try b.words("two");
    try b.beginCell(.{});
    try b.words("three");
    try b.endTable();
    try b.finish();

    const grid = f.page.blocks.items[0].kind.table;
    const cells = f.page.cellsOf(grid);
    // The caption comes to be across both columns.
    try testing.expectEqual(@as(u16, 2), cells[0].across);
    // A block begun at a cell's start ends no line, and two in a row end one.
    try testing.expectEqual(@as(usize, 3), f.page.cellRuns(cells[1]).len);

    var text = try f.written();
    defer text.deinit();
    try testing.expectEqualStrings("Caption\none two | three\n", text.written());
}

test "a colour given twice is one swatch, and none is the theme's" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    const red = try f.builder.swatch(.hex(0xCC0000));
    const blue = try f.builder.swatch(.hex(0x0000CC));
    try testing.expect(red != blue and red != .none);
    try testing.expectEqual(red, try f.builder.swatch(.hex(0xCC0000)));
    try testing.expectEqual(@as(usize, 2), f.page.palette.items.len);
    try testing.expectEqual(rgb.Colour.hex(0x0000CC), f.page.colourOf(blue).?);
    try testing.expectEqual(@as(?rgb.Colour, null), f.page.colourOf(.none));
}
