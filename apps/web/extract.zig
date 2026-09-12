//! A parsed page, walked into what this reader keeps.
//!
//! Each element is asked one question: what does it do to the words inside
//! it? Most do nothing, and their words read as the text around them. A few
//! start a block, a few change the face or make a link, and a few hold
//! nothing a reader should see. The answer is `Role`, and the walk is that
//! table applied in document order.
//!
//! Only the page's own content is walked, and only what the page itself says
//! is for reading. A page marks its content with `main` and its navigation
//! with `nav` or a role, and hides what it hides with an attribute or with its
//! stylesheets. Those are the page's own words about its parts, which is why
//! they are what decides, rather than guesses from class names that differ on
//! every site.
//!
//! What a page's stylesheets say is asked of each element as the walk arrives
//! at it: whether it shows at all, the colour of its words, what is painted
//! under it, which way its lines lean, and its box geometry. Colours and
//! alignment are handed down the way the cascade hands them down, so the walk
//! keeps what each element changed and puts it back as it leaves the element.
//!
//! A form's controls are the toolkit's own on screen, so the walk keeps what
//! each one is: its kind, its name, what it holds to begin with, and the
//! colours the page gives it. A button that does nothing until a script says
//! what is not kept, because nothing here runs the script.
//!
//! A picture is kept as where it is, what the page says it shows, and the
//! size the page gives it. Fetching it is the window's to do, once the words
//! are on screen.

const std = @import("std");
const Bounded = @import("lib").bounded.Bounded;
const css = @import("css.zig");
const lexbor = @import("lexbor");
const media = @import("media.zig");
const page_mod = @import("page.zig");
const url = @import("url");

const Node = lexbor.Node;
const Tag = lexbor.Tag;
const Alignment = page_mod.Alignment;
const Block = page_mod.Block;
const Builder = page_mod.Builder;
const Swatch = page_mod.Swatch;

/// What an element does to the words inside it.
const Role = enum {
    /// Nothing a reader sees: a script, a stylesheet, the head, and the
    /// page's navigation.
    hidden,
    /// Starts a block of body text and ends it.
    block,
    heading,
    /// A list, whose entries are bulleted or numbered.
    list,
    ordered,
    item,
    quote,
    preformatted,
    rule,
    line_break,
    /// A table: set as a grid where it holds data, and read a cell at a time
    /// where it lays a page out.
    table,
    /// A table's row, one of its cells, and its caption.
    row,
    cell,
    caption,
    link,
    /// Code, keys, output: the monospaced face.
    mono,
    image,
    /// A form, whose controls send their answers together.
    form,
    /// One of a form's controls: a line to type in, a box, a button.
    input,
    /// A button, whose label is the words inside it.
    button,
    /// A list to choose from, of which the reader shows the chosen entry.
    select,
    /// Room to type more than a line in, of which the reader offers a line.
    textarea,
    /// Nothing: the words read as the text around them.
    none,
};

fn roleOf(tag: Tag) Role {
    return switch (tag) {
        .script, .style, .head, .template, .svg, .math, .iframe, .title, .base, .nav, .option => .hidden,
        .p, .div, .section, .article, .header, .footer, .main, .aside, .figure, .figcaption, .address, .center, .fieldset, .details, .summary, .dl, .dt, .dd => .block,
        .table => .table,
        .tr => .row,
        .td, .th => .cell,
        .caption => .caption,
        .h1, .h2, .h3, .h4, .h5, .h6 => .heading,
        .ul => .list,
        .ol => .ordered,
        .li => .item,
        .blockquote => .quote,
        .pre => .preformatted,
        .hr => .rule,
        .br => .line_break,
        .a => .link,
        .code, .kbd, .samp, .tt, .@"var" => .mono,
        .img => .image,
        .form => .form,
        .input => .input,
        .button => .button,
        .select => .select,
        .textarea => .textarea,
        else => .none,
    };
}

/// What a role asks of the walk besides its own step. Three answers, packed
/// into one small value for each role.
const Traits = packed struct(u3) {
    /// The walk goes inside it. One whose inside a reader never sees, or
    /// whose inside is its own step, is passed over whole.
    walks: bool = true,
    /// It ends a block where it ends.
    bounds: bool = false,
    /// Being inside one changes how words look or where they sit, so how
    /// many are open is counted.
    counts: bool = false,
};

const traits = std.EnumArray(Role, Traits).init(.{
    .hidden = .{ .walks = false },
    .block = .{ .bounds = true },
    .heading = .{ .bounds = true, .counts = true },
    .list = .{ .bounds = true },
    .ordered = .{ .bounds = true },
    .item = .{ .bounds = true },
    .quote = .{ .bounds = true, .counts = true },
    .preformatted = .{ .bounds = true, .counts = true },
    .rule = .{ .walks = false },
    .line_break = .{ .walks = false },
    .table = .{ .bounds = true },
    .row = .{ .bounds = true },
    .cell = .{ .bounds = true },
    .caption = .{ .bounds = true },
    .link = .{ .counts = true },
    .mono = .{ .counts = true },
    .image = .{ .walks = false },
    .form = .{ .bounds = true },
    .input = .{ .walks = false },
    .button = .{ .walks = false },
    .select = .{ .walks = false },
    .textarea = .{ .walks = false },
    .none = .{},
});

/// What an `<input>` is, by its `type`. A type not named here is a line to
/// type in, which is what the specification makes of one it does not know.
const Input = enum { line, secret, hidden, submit, image, reset, check, radio, inert };

const inputs = std.StaticStringMapWithEql(Input, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ "text", .line },
    .{ "search", .line },
    .{ "email", .line },
    .{ "url", .line },
    .{ "tel", .line },
    .{ "number", .line },
    .{ "password", .secret },
    .{ "hidden", .hidden },
    .{ "submit", .submit },
    .{ "image", .image },
    .{ "reset", .reset },
    .{ "checkbox", .check },
    .{ "radio", .radio },
    .{ "button", .inert },
    .{ "file", .inert },
});

/// What a `<button>` does, by its `type`; one of no type sends its form.
const Press = enum { submit, reset, inert };

const presses = std.StaticStringMapWithEql(Press, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ "submit", .submit },
    .{ "reset", .reset },
    .{ "button", .inert },
});

/// How deep lists may nest before an entry stops stepping further in. Past
/// this the indent would leave a column a few letters wide.
const LIST_MAX = 16;

/// The widest a control asks to be, in letters: past this it would be wider
/// than the column it sits in.
const LETTERS_MAX = 60;

const List = struct {
    ordered: bool,
    next: u32,
    /// Whether the page says its entries carry no marker: `list-style: none`,
    /// which is how a list of links, or of a page's own furniture, is written.
    markerless: bool = false,
};

/// Words enough for a button's label, or a list's chosen entry.
const Label = Bounded(u8, 64);

/// What a page's stylesheets give the words the walk is among: their colour,
/// what is painted under the blocks they are in, and which way those blocks'
/// lines lean.
const Style = struct {
    ink: Swatch = .none,
    ground: Swatch = .none,
    alignment: Alignment = .start,
};

/// An element that changed the style, and the style it changed, put back as
/// the walk leaves the element.
const Frame = struct { node: *const Node, was: Style };

/// How many elements changing the style the walk keeps track of at once. One
/// nested deeper keeps the style it is in.
const STYLE_DEPTH = 64;

/// How a table the walk is inside is read: as a grid, or a cell at a time.
const Table = enum { grid, cells };

/// How many tables inside tables the walk keeps track of. One deeper is read
/// a cell at a time.
const TABLES_MAX = 16;

const Walker = struct {
    builder: *Builder,
    base: url.Url,

    /// How many elements of each counted role the walk is inside.
    inside: std.EnumArray(Role, u16) = .initFill(0),
    /// The lists the walk is inside, innermost last, and how many more are
    /// open past the bound: an entry of one of those is bulleted and steps
    /// no further in.
    lists: Bounded(List, LIST_MAX) = .{},
    lists_past: u16 = 0,
    /// Where the words of the open link go. Links do not nest: the parser
    /// closes one before it opens another.
    link: ?u16 = null,
    style: Style = .{},
    frames: Bounded(Frame, STYLE_DEPTH) = .{},
    /// The tables the walk is inside, innermost last, and how many more are
    /// open past the bound.
    tables: Bounded(Table, TABLES_MAX) = .{},
    tables_past: u16 = 0,
    /// The open retained boxes, root first. A box is linked to its parent as
    /// it closes, after all of its descendants have filled their own ranges.
    containers: std.ArrayList(u32) = .empty,

    const Error = Builder.Error;

    fn beginContainer(self: *Walker, node: *const Node, display: page_mod.BoxStyle.Display) Error!void {
        const index = std.math.cast(u32, self.builder.page.containers.items.len) orelse return;
        try self.builder.page.containers.append(self.builder.gpa, .{ .style = css.boxStyle(node, display) });
        try self.containers.append(self.builder.gpa, index);
        // What is read inside it, until it closes, is its to be set in.
        self.builder.owner = index;
    }

    fn endContainer(self: *Walker) Error!void {
        const child = self.containers.pop() orelse return;
        const parent = self.containers.getLastOrNull() orelse return;
        self.builder.owner = parent;
        const box = &self.builder.page.containers.items[parent];
        if (box.children.count == 0) box.children.first = @intCast(self.builder.page.container_children.items.len);
        try self.builder.page.container_children.append(self.builder.gpa, child);
        box.children.count +|= 1;
    }

    /// Whether the innermost table the walk is inside is set as a grid.
    fn inGrid(self: *const Walker) bool {
        const open = self.tables.slice();
        return self.tables_past == 0 and open.len > 0 and open[open.len - 1] == .grid;
    }

    /// What a table's cell is, as the page gives it: a header or not, how
    /// many columns and rows it spans, its ground, and the side its lines
    /// lean to, which for a header is the middle unless the page says.
    fn cellOf(self: *const Walker, node: *Node) page_mod.CellSpec {
        const header = lexbor.tagOf(node) == .th;
        return .{
            .header = header,
            .across = spanOf(node, "colspan"),
            .down = spanOf(node, "rowspan"),
            .ground = self.style.ground,
            .alignment = if (header) css.alignment(node) orelse .center else self.style.alignment,
        };
    }

    /// What the next block is, given everything the walk is inside.
    fn context(self: *const Walker, kind: page_mod.Kind, marker: page_mod.Marker) Block {
        const steps = self.lists.len + self.inside.get(.quote);
        return .{
            .kind = if (self.inside.get(.preformatted) > 0) .preformatted else kind,
            .depth = @intCast(@min(steps, std.math.maxInt(u8))),
            .quoted = self.inside.get(.quote) > 0,
            .marker = marker,
            .ground = self.style.ground,
            .alignment = self.style.alignment,
        };
    }

    /// A block boundary, unless an entry's marker is still waiting for the
    /// first words to carry it: `<li><p>` is one entry, not an empty entry
    /// and a paragraph.
    fn boundary(self: *Walker, kind: page_mod.Kind) Error!void {
        const next = self.builder.next;
        if (next.kind == .item and next.marker != .none and self.builder.open == null) return;
        try self.builder.boundary(self.context(kind, .none));
    }

    /// Put the builder's look back in step with what the walk is inside.
    fn restyle(self: *Walker) void {
        const b = self.builder;
        b.link = if (self.inside.get(.link) > 0) self.link else null;
        b.look = .{
            .face = if (self.inside.get(.heading) > 0)
                .heading
            else if (self.inside.get(.mono) + self.inside.get(.preformatted) > 0)
                .mono
            else
                .body,
            .ink = if (b.link != null) .link else .text,
            .paint = self.style.ink,
        };
    }

    /// The marker the next entry of the innermost list carries.
    fn nextMarker(self: *Walker) page_mod.Marker {
        if (self.lists_past > 0) return .bullet;
        const list = self.lists.last() orelse return .bullet;
        if (list.markerless) return .none;
        if (!list.ordered) return .bullet;
        defer list.next +%= 1;
        return .{ .number = list.next };
    }

    /// Arrive at a node. True for an element the walk goes inside, whose
    /// leaving then matters too.
    fn enter(self: *Walker, node: *Node) Error!bool {
        switch (node.type) {
            .text => {
                try self.builder.words(lexbor.wordsOf(node));
                return false;
            },
            .element => {},
            else => return false,
        }
        const role = roleOf(lexbor.tagOf(node) orelse return false);
        if (unread(node)) return false;

        if (role != .hidden) try self.beginContainer(node, displayFor(role));

        const t = traits.get(role);
        // What it holds is read in the style it sets, taken before any block
        // it begins so that the block has it too.
        if (t.walks) try self.take(node);
        if (t.counts) self.inside.getPtr(role).* += 1;
        // A page that keeps an element's spaces and line ends as written
        // asks for it read as it was typed, whatever the element is called.
        if (css.keepsSpaces(node)) self.inside.getPtr(.preformatted).* += 1;
        switch (role) {
            .hidden, .mono, .none => {},
            // A page that says an element is inline, or is no more than its
            // contents, means its words read where they stand, in the block
            // around them: `display` says as much whatever the element is
            // called, and a block a piece would be the reader's shape and
            // not the page's.
            .block, .quote => if (!css.flows(node)) try self.boundary(.paragraph),
            .heading => try self.boundary(.heading),
            .list, .ordered => {
                try self.boundary(.paragraph);
                self.lists.append(.{
                    .ordered = role == .ordered,
                    .next = startOf(node),
                    .markerless = css.markerless(node),
                }) catch {
                    self.lists_past += 1;
                };
            },
            .item => try self.builder.boundary(self.context(.item, self.nextMarker())),
            .preformatted => try self.builder.boundary(self.context(.preformatted, .none)),
            .rule => {
                try self.builder.rule();
                try self.builder.boundary(self.context(.paragraph, .none));
            },
            .line_break => try self.builder.lineBreak(),
            .table => {
                self.tables.append(if (dataTable(node)) .grid else .cells) catch {
                    self.tables_past += 1;
                };
                if (self.inGrid()) try self.builder.beginTable() else try self.boundary(.paragraph);
            },
            .row => if (self.inGrid()) self.builder.beginRow() else try self.boundary(.paragraph),
            // A row that is not set as a grid is read a row at a time: each
            // of its cells is a stretch of the row's line, beside the one
            // before it, unless what it holds is blocks of its own.
            .cell => if (self.inGrid())
                try self.builder.beginCell(self.cellOf(node))
            else if (blockish(node))
                try self.boundary(.paragraph)
            else
                self.builder.oweSpace(),
            .caption => if (self.inGrid()) {
                // A caption is a row of its own, across the whole table.
                self.builder.beginRow();
                try self.builder.beginCell(.{
                    .header = true,
                    .whole_row = true,
                    .ground = self.style.ground,
                    .alignment = css.alignment(node) orelse .center,
                });
            } else try self.boundary(.paragraph),
            .link => self.link = try self.linkFor(node),
            .image => try self.picture(node),
            .form => {
                try self.boundary(.paragraph);
                self.builder.form = try self.formFor(node);
            },
            .input => try self.input(node),
            .button => try self.button(node),
            .select => try self.select(node),
            .textarea => try self.textarea(node),
        }
        if (!t.walks) {
            if (role != .hidden) try self.endContainer();
            return false;
        }
        self.restyle();
        return true;
    }

    fn leave(self: *Walker, node: *Node) Error!void {
        const role = roleOf(lexbor.tagOf(node) orelse return);
        const t = traits.get(role);
        if (t.counts) self.inside.getPtr(role).* -|= 1;
        if (css.keepsSpaces(node)) self.inside.getPtr(.preformatted).* -|= 1;
        switch (role) {
            .list, .ordered => {
                if (self.lists_past > 0) self.lists_past -= 1 else _ = self.lists.pop();
            },
            .form => self.builder.form = null,
            .table => {
                const grid = self.inGrid();
                if (self.tables_past > 0) self.tables_past -= 1 else _ = self.tables.pop();
                if (grid) try self.builder.endTable();
            },
            .row => if (self.inGrid()) self.builder.endRow(),
            .cell => if (self.inGrid())
                self.builder.endCell()
            else if (blockish(node))
                try self.boundary(.paragraph),
            .caption => if (self.inGrid()) self.builder.endCell(),
            else => {},
        }
        self.untake(node);
        if (role != .hidden) try self.endContainer();
        // A cell that is a stretch of its row's line does not end that line:
        // the words of the cell after it belong on it too.
        const ends = t.bounds and !css.flows(node) and
            !(role == .cell and !self.inGrid() and !blockish(node));
        if (ends) try self.boundary(.paragraph);
        self.restyle();
    }

    /// Take the style an element sets, keeping the one it replaces for when
    /// the walk leaves it. A link's words are in the colour it gives them, or
    /// in the theme's for a link: never in the colour of the words around it
    /// unless the page says so.
    fn take(self: *Walker, node: *Node) Error!void {
        const tag = lexbor.tagOf(node);
        var next = self.style;
        if (css.ink(node)) |given| {
            next.ink = try self.swatchOf(given, self.style.ink);
        } else if (tag == .a) {
            next.ink = .none;
        }
        // What the page itself is painted on is the page's, not a block's.
        if (tag != .body and tag != .html) {
            if (css.ground(node)) |given| next.ground = try self.swatchOf(given, self.style.ground);
        }
        if (css.alignment(node)) |given| next.alignment = given;
        if (std.meta.eql(next, self.style)) return;
        self.frames.append(.{ .node = node, .was = self.style }) catch return;
        self.style = next;
    }

    /// Put back the style an element replaced, as the walk leaves it.
    fn untake(self: *Walker, node: *const Node) void {
        const frame = self.frames.last() orelse return;
        if (frame.node != node) return;
        self.style = frame.was;
        _ = self.frames.pop();
    }

    /// The swatch for a colour the page gives, where `inherited` is the one
    /// it would have had anyway.
    fn swatchOf(self: *Walker, given: css.Paint, inherited: Swatch) Error!Swatch {
        return switch (given) {
            .colour => |colour| self.builder.swatch(colour),
            // What is under a ground that shows through shows, and words in
            // the current colour are in the colour they were already.
            .current, .transparent => inherited,
        };
    }

    /// The style the walk begins in, where it begins inside the page rather
    /// than at its top: what the elements around its start hand down.
    fn inherit(self: *Walker, root: *Node) Error!void {
        var ink: ?css.Paint = null;
        var ground: ?css.Paint = null;
        var alignment: ?Alignment = null;
        var at = root.parent;
        while (at) |node| : (at = node.parent) {
            if (node.type != .element) continue;
            if (ink == null) ink = css.ink(node);
            if (alignment == null) alignment = css.alignment(node);
            const tag = lexbor.tagOf(node);
            if (ground == null and tag != .body and tag != .html) ground = css.ground(node);
        }
        if (ink) |given| self.style.ink = try self.swatchOf(given, .none);
        if (ground) |given| self.style.ground = try self.swatchOf(given, .none);
        if (alignment) |given| self.style.alignment = given;
    }

    /// What the page is painted on: its body's ground, or its root's.
    fn pageGround(self: *Walker, top: *Node) Error!Swatch {
        var body: ?css.Paint = null;
        var root: ?css.Paint = null;
        var at = lexbor.following(top, top);
        while (at) |node| : (at = lexbor.following(node, top)) {
            switch (lexbor.tagOf(node) orelse continue) {
                .html => root = css.ground(node),
                .body => {
                    body = css.ground(node);
                    break;
                },
                else => {},
            }
        }
        return self.swatchOf(body orelse root orelse return .none, .none);
    }

    /// The colours an element gives itself rather than those it inherits,
    /// which is what a form's control is drawn in.
    fn coloursOf(self: *Walker, node: *Node) Error!page_mod.Colours {
        return .{
            .ink = if (css.ink(node)) |given| try self.swatchOf(given, .none) else .none,
            .ground = if (css.ground(node)) |given| try self.swatchOf(given, .none) else .none,
        };
    }

    /// The link an anchor makes, or none for one that goes nowhere this
    /// reader follows: no address, another scheme, a place on this page.
    fn linkFor(self: *Walker, node: *Node) Error!?u16 {
        const href = lexbor.attribute(node, "href") orelse return null;
        var buf: [url.ADDRESS_MAX]u8 = undefined;
        const resolved = url.resolve(self.base, href, &buf) orelse return null;
        return self.builder.addLink(resolved);
    }

    /// A picture: where it is, what the page says it shows, and the size the
    /// page gives it. One the page makes too small to see is a counter or a
    /// spacer, and is not kept; one with nowhere this reader can fetch it
    /// from is kept all the same, for what the page says it shows.
    fn picture(self: *Walker, node: *Node) Error!void {
        const width = pixelsOf(node, "width");
        const height = pixelsOf(node, "height");
        if (@min(width orelse SEEN_MIN, height orelse SEEN_MIN) < SEEN_MIN) return;

        const alt = std.mem.trim(u8, lexbor.attribute(node, "alt") orelse "", &std.ascii.whitespace);
        var buf: [url.ADDRESS_MAX]u8 = undefined;
        const source = url.resolve(self.base, lexbor.attribute(node, "src") orelse "", &buf) orelse "";
        try self.builder.addPicture(source, alt, width, height);
    }

    /// Words the page gives about something the reader does not show as it
    /// is, set dim in brackets: a list's chosen entry.
    fn aside(self: *Walker, text: []const u8) Error!void {
        if (text.len == 0) return;
        const look = self.builder.look;
        defer self.builder.look = look;
        self.builder.look.ink = .dim;
        try self.builder.words(" [");
        try self.builder.words(text);
        try self.builder.words("] ");
    }

    /// The form an element makes: where its answers go, resolved against the
    /// page, and how they are sent.
    fn formFor(self: *Walker, node: *Node) Error!?u16 {
        var buf: [url.ADDRESS_MAX]u8 = undefined;
        const action = std.mem.trim(u8, lexbor.attribute(node, "action") orelse "", &std.ascii.whitespace);
        // A form with no action sends its answers back to the page it is on.
        const target = if (action.len == 0)
            std.fmt.bufPrint(&buf, "{f}", .{self.base}) catch return null
        else
            url.resolve(self.base, action, &buf) orelse return null;
        const method: page_mod.Form.Method = if (lexbor.attributeIs(node, "method", "post")) .post else .get;
        return self.builder.addForm(target, method);
    }

    fn input(self: *Walker, node: *Node) Error!void {
        const b = self.builder;
        const name = lexbor.attribute(node, "name") orelse "";
        const value = lexbor.attribute(node, "value");
        const colours = try self.coloursOf(node);
        switch (inputs.get(lexbor.attribute(node, "type") orelse "text") orelse .line) {
            .line, .secret => |kind| try b.addControl(.{ .line = .{
                .letters = lettersOf(node, "size", 20),
                .secret = kind == .secret,
                .hint = try b.keep(lexbor.attribute(node, "placeholder") orelse ""),
            } }, name, value orelse "", colours),
            .hidden => try b.addControl(.hidden, name, value orelse "", .{}),
            .submit => {
                const label = value orelse "Submit";
                try b.addControl(.{ .submit = .{ .label = try b.keep(label) } }, name, label, colours);
            },
            .image => {
                // An image button says where on the picture it was pressed,
                // which a reader without the picture cannot, so it sends
                // nothing of its own.
                const label = lexbor.attribute(node, "alt") orelse "Submit";
                try b.addControl(.{ .submit = .{ .label = try b.keep(label) } }, "", label, colours);
            },
            .reset => {
                const label = value orelse "Reset";
                try b.addControl(.{ .reset = .{ .label = try b.keep(label) } }, "", label, colours);
            },
            .check, .radio => |kind| try b.addControl(.{ .tick = .{
                .ticked = lexbor.hasAttribute(node, "checked"),
                .radio = kind == .radio,
            } }, name, value orelse "on", colours),
            // A button for a script, and a file to send, which is not
            // something this reader does.
            .inert => {},
        }
    }

    fn button(self: *Walker, node: *Node) Error!void {
        const b = self.builder;
        const label = textWithin(node);
        const colours = try self.coloursOf(node);
        switch (presses.get(lexbor.attribute(node, "type") orelse "submit") orelse .submit) {
            .submit => try b.addControl(
                .{ .submit = .{ .label = try b.keep(label.slice()) } },
                lexbor.attribute(node, "name") orelse "",
                lexbor.attribute(node, "value") orelse "",
                colours,
            ),
            .reset => try b.addControl(.{ .reset = .{ .label = try b.keep(label.slice()) } }, "", "", colours),
            .inert => {},
        }
    }

    /// A list to choose from sends its chosen entry, which the reader shows
    /// and does not offer to change: there is no list to pick from in the
    /// toolkit yet.
    fn select(self: *Walker, node: *Node) Error!void {
        const chosen = chosenOption(node) orelse return;
        const label = textWithin(chosen);
        try self.builder.addControl(.hidden, lexbor.attribute(node, "name") orelse "", lexbor.attribute(chosen, "value") orelse label.slice(), .{});
        try self.aside(label.slice());
    }

    fn textarea(self: *Walker, node: *Node) Error!void {
        const b = self.builder;
        try b.addControl(.{ .line = .{
            .letters = lettersOf(node, "cols", 30),
            .hint = try b.keep(lexbor.attribute(node, "placeholder") orelse ""),
        } }, lexbor.attribute(node, "name") orelse "", textWithin(node).slice(), try self.coloursOf(node));
    }
};

/// The outside display a tag has without a stylesheet. The retained model
/// only distinguishes the modes its first box-layout pass will support.
fn displayFor(role: Role) page_mod.BoxStyle.Display {
    return switch (role) {
        .block, .heading, .list, .ordered, .item, .quote, .preformatted, .rule, .table, .row, .cell, .caption, .form => .block,
        else => .@"inline",
    };
}

/// Whether a table holds data, to be set as a grid, rather than laying a page
/// out, to be read a cell at a time: it says it is a table or a grid, draws a
/// border, or has a caption, a head or a header cell; and it holds no table
/// of its own, which a table of data does not.
fn dataTable(table: *Node) bool {
    if (lexbor.attributeIs(table, "role", "presentation") or lexbor.attributeIs(table, "role", "none")) return false;
    var data = lexbor.attributeIs(table, "role", "table") or lexbor.attributeIs(table, "role", "grid");
    if (lexbor.attribute(table, "border")) |border| {
        if (!std.mem.eql(u8, std.mem.trim(u8, border, &std.ascii.whitespace), "0")) data = true;
    }
    var rows: usize = 0;
    var blocky = false;
    var at = lexbor.following(table, table);
    while (at) |node| : (at = lexbor.following(node, table)) {
        switch (lexbor.tagOf(node) orelse continue) {
            .table => return false,
            .th, .caption, .thead => data = true,
            .tr => rows += 1,
            .td => blocky = blocky or blockish(node),
            else => {},
        }
    }
    // A table whose cells hold no blocks is a table of records whenever it
    // has rows to speak of: a list of results, a glossary, a timetable, the
    // like. A table that lays a page out puts a column of the page in a cell,
    // and that cell holds blocks, so it is read a row at a time instead. A
    // grid is what a browser makes of a table, and this reader has one.
    return data or (rows >= 2 and !blocky);
}

/// Whether a cell holds blocks of its own. A table that lays a page out puts
/// a column of the page in a cell, and such a cell reads as the blocks it
/// holds; a cell that holds no more than words, links and the like is a line
/// of the row it is in, which is how a table of results, of a glossary, or of
/// anything else set in rows reads.
fn blockish(cell: *Node) bool {
    var at = lexbor.following(cell, cell);
    while (at) |node| : (at = lexbor.following(node, cell)) {
        switch (roleOf(lexbor.tagOf(node) orelse continue)) {
            .block, .heading, .list, .ordered, .item, .quote, .preformatted, .table, .form, .rule => return true,
            else => {},
        }
    }
    return false;
}

/// How many columns or rows a cell spans, by the attribute that says, and
/// one where it says nothing a table can use.
fn spanOf(node: *Node, which: []const u8) u16 {
    const given = lexbor.attribute(node, which) orelse return 1;
    const span = std.fmt.parseInt(u16, std.mem.trim(u8, given, &std.ascii.whitespace), 10) catch return 1;
    return @max(span, 1);
}

/// Where an ordered list starts counting: its `start`, or one.
fn startOf(node: *Node) u32 {
    const start = lexbor.attribute(node, "start") orelse return 1;
    return std.fmt.parseInt(u32, std.mem.trim(u8, start, &std.ascii.whitespace), 10) catch 1;
}

/// Smaller than this a side, a picture is a counter or a spacer rather than
/// something to look at.
const SEEN_MIN = 3;

/// A size a page gives in pixels: the number an attribute starts with, or
/// nothing where it gives none, or gives a share of the column instead.
fn pixelsOf(node: *Node, name: []const u8) ?u16 {
    const given = std.mem.trim(u8, lexbor.attribute(node, name) orelse return null, &std.ascii.whitespace);
    if (std.mem.endsWith(u8, given, "%")) return null;
    const digits = std.mem.indexOfNone(u8, given, "0123456789") orelse given.len;
    if (digits == 0) return null;
    return std.fmt.parseInt(u16, given[0..digits], 10) catch std.math.maxInt(u16);
}

/// How many letters wide a control asks to be, by the attribute that says,
/// within what a column holds.
fn lettersOf(node: *Node, which: []const u8, default: u16) u16 {
    const asked = lexbor.attribute(node, which) orelse return default;
    const letters = std.fmt.parseInt(u16, std.mem.trim(u8, asked, &std.ascii.whitespace), 10) catch return default;
    return std.math.clamp(letters, 1, LETTERS_MAX);
}

/// The words inside `node`, their spaces made single, as many whole words
/// as a label holds.
fn textWithin(node: *Node) Label {
    var label: Label = .{};
    var at = lexbor.following(node, node);
    while (at) |here| : (at = lexbor.following(here, node)) {
        if (here.type != .text) continue;
        var words = std.mem.tokenizeAny(u8, lexbor.wordsOf(here), &std.ascii.whitespace);
        while (words.next()) |word| {
            const gap: usize = if (label.isEmpty()) 0 else 1;
            if (label.len + gap + word.len > Label.CAPACITY) return label;
            if (gap > 0) _ = label.extend(" ");
            _ = label.extend(word);
        }
    }
    return label;
}

/// The entry a list to choose from has chosen: the one it marks, or its
/// first.
fn chosenOption(select: *Node) ?*Node {
    var first: ?*Node = null;
    var at = lexbor.following(select, select);
    while (at) |here| : (at = lexbor.following(here, select)) {
        if (lexbor.tagOf(here) != .option) continue;
        if (lexbor.hasAttribute(here, "selected")) return here;
        if (first == null) first = here;
    }
    return first;
}

/// Whether the page says an element is not for reading: navigation, or
/// something it hides, from everyone or from anyone listening to it read,
/// by an attribute or by its stylesheets.
fn unread(node: *Node) bool {
    return lexbor.hasAttribute(node, "hidden") or
        lexbor.attributeIs(node, "aria-hidden", "true") or
        lexbor.attributeIs(node, "role", "navigation") or
        !css.shows(node);
}

/// Where a page's own content is: the `main` element it marks, and otherwise
/// the whole of it. What is outside a page's main is the site around it,
/// its menus, its search, its footer, and a reader that showed all of that
/// would open every article on the site's furniture.
fn contentOf(root: *Node) *Node {
    var at = lexbor.following(root, root);
    while (at) |node| : (at = lexbor.following(node, root)) {
        if (node.type != .element) continue;
        const main = lexbor.tagOf(node) == .main or lexbor.attributeIs(node, "role", "main");
        if (main and !unread(node)) return node;
    }
    return root;
}

/// Where the page says its version for a window like `screen` is, written
/// into `buf`: a link in its head that is an alternate for media the window
/// is, which is how a site with a separate site for small screens names it.
/// With no window to ask about, a version for windows of some size is not
/// one for it.
pub fn versionFor(document: *lexbor.Document, base: url.Url, screen: ?media.Screen, buf: *[url.ADDRESS_MAX]u8) ?[]const u8 {
    const root = lexbor.nodeOf(document);
    var at = lexbor.following(root, root);
    while (at) |node| : (at = lexbor.following(node, root)) {
        switch (lexbor.tagOf(node) orelse continue) {
            // The head is over, and with it the links a page says this in.
            .body => return null,
            .link => {},
            else => continue,
        }
        if (!lexbor.attributeHas(node, "rel", "alternate")) continue;
        const asked = std.mem.trim(u8, lexbor.attribute(node, "media") orelse continue, &std.ascii.whitespace);
        if (asked.len == 0 or !media.matches(asked, screen)) continue;
        return url.resolve(base, lexbor.attribute(node, "href") orelse "", buf) orelse continue;
    }
    return null;
}

/// Walk `document` into `page`. Links are resolved against `base`, which is
/// the address the page came from.
pub fn extract(gpa: std.mem.Allocator, document: *lexbor.Document, base: url.Url, page: *page_mod.Page) Builder.Error!void {
    var builder = Builder{ .gpa = gpa, .page = page };
    if (lexbor.titleOf(document)) |title| try builder.title(title);

    var walker = Walker{ .builder = &builder, .base = base };
    defer walker.containers.deinit(gpa);
    const top = lexbor.nodeOf(document);
    page.ground = try walker.pageGround(top);
    const root = contentOf(top);
    try walker.inherit(root);
    walker.restyle();
    try walker.beginContainer(root, .block);

    var node: ?*Node = root.first_child;
    walk: while (node) |here| {
        if (try walker.enter(here)) {
            if (here.first_child) |child| {
                node = child;
                continue;
            }
            try walker.leave(here);
        }
        // Along to the next sibling, or up until there is one, leaving each
        // element on the way up.
        var at = here;
        while (true) {
            if (at.next) |sibling| {
                node = sibling;
                continue :walk;
            }
            const up = at.parent orelse break :walk;
            if (up == root) break :walk;
            try walker.leave(up);
            at = up;
        }
    }
    // The last block is closed before the box holding it is, so that the
    // page's boxes hold the whole of it between them.
    try builder.finish();
    try walker.endContainer();
}
