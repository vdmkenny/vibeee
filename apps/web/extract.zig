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
//! with `nav` or a role, and hides what it hides with an attribute. Those are
//! the page's own words about its parts, which is why they are what decides,
//! rather than guesses from class names that differ on every site.
//!
//! A form's controls are the toolkit's own on screen, so the walk keeps what
//! each one is: its kind, its name, and what it holds to begin with. A button
//! that does nothing until a script says what is not kept, because nothing
//! here runs the script.
//!
//! A picture is kept as where it is, what the page says it shows, and the
//! size the page gives it. Fetching it is the window's to do, once the words
//! are on screen.
//!
//! Iterative rather than recursive. A page can nest thousands deep, a stack
//! frame per level is a stack this machine does not have to spare, and a walk
//! that follows the tree's own links needs no stack at all.

const std = @import("std");
const Bounded = @import("lib").bounded.Bounded;
const lexbor = @import("lexbor.zig");
const page_mod = @import("page.zig");
const url = @import("url.zig");

const Node = lexbor.Node;
const Tag = lexbor.Tag;
const Block = page_mod.Block;
const Builder = page_mod.Builder;

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
        .p, .div, .section, .article, .header, .footer, .main, .aside, .figure, .figcaption, .address, .center, .fieldset, .details, .summary, .dl, .dt, .dd, .table, .caption, .tr, .td, .th => .block,
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

const List = struct { ordered: bool, next: u32 };

/// Words enough for a button's label, or a list's chosen entry.
const Label = Bounded(u8, 64);

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

    const Error = Builder.Error;

    /// What the next block is, given everything the walk is inside.
    fn context(self: *const Walker, kind: page_mod.Kind, marker: page_mod.Marker) Block {
        const steps = self.lists.len + self.inside.get(.quote);
        return .{
            .kind = if (self.inside.get(.preformatted) > 0) .preformatted else kind,
            .depth = @intCast(@min(steps, std.math.maxInt(u8))),
            .quoted = self.inside.get(.quote) > 0,
            .marker = marker,
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
        };
    }

    /// The marker the next entry of the innermost list carries.
    fn nextMarker(self: *Walker) page_mod.Marker {
        if (self.lists_past > 0) return .bullet;
        const list = self.lists.last() orelse return .bullet;
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

        const t = traits.get(role);
        if (t.counts) self.inside.getPtr(role).* += 1;
        switch (role) {
            .hidden, .mono, .none => {},
            .block, .quote => try self.boundary(.paragraph),
            .heading => try self.boundary(.heading),
            .list, .ordered => {
                try self.boundary(.paragraph);
                self.lists.append(.{ .ordered = role == .ordered, .next = startOf(node) }) catch {
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
        if (!t.walks) return false;
        self.restyle();
        return true;
    }

    fn leave(self: *Walker, node: *Node) Error!void {
        const role = roleOf(lexbor.tagOf(node) orelse return);
        const t = traits.get(role);
        if (t.counts) self.inside.getPtr(role).* -|= 1;
        switch (role) {
            .list, .ordered => {
                if (self.lists_past > 0) self.lists_past -= 1 else _ = self.lists.pop();
            },
            .form => self.builder.form = null,
            else => {},
        }
        if (t.bounds) try self.boundary(.paragraph);
        self.restyle();
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
        switch (inputs.get(lexbor.attribute(node, "type") orelse "text") orelse .line) {
            .line, .secret => |kind| try b.addControl(.{ .line = .{
                .letters = lettersOf(node, "size", 20),
                .secret = kind == .secret,
                .hint = try b.keep(lexbor.attribute(node, "placeholder") orelse ""),
            } }, name, value orelse ""),
            .hidden => try b.addControl(.hidden, name, value orelse ""),
            .submit => {
                const label = value orelse "Submit";
                try b.addControl(.{ .submit = .{ .label = try b.keep(label) } }, name, label);
            },
            .image => {
                // An image button says where on the picture it was pressed,
                // which a reader without the picture cannot, so it sends
                // nothing of its own.
                const label = lexbor.attribute(node, "alt") orelse "Submit";
                try b.addControl(.{ .submit = .{ .label = try b.keep(label) } }, "", label);
            },
            .reset => {
                const label = value orelse "Reset";
                try b.addControl(.{ .reset = .{ .label = try b.keep(label) } }, "", label);
            },
            .check, .radio => |kind| try b.addControl(.{ .tick = .{
                .ticked = lexbor.hasAttribute(node, "checked"),
                .radio = kind == .radio,
            } }, name, value orelse "on"),
            // A button for a script, and a file to send, which is not
            // something this reader does.
            .inert => {},
        }
    }

    fn button(self: *Walker, node: *Node) Error!void {
        const b = self.builder;
        const label = textWithin(node);
        switch (presses.get(lexbor.attribute(node, "type") orelse "submit") orelse .submit) {
            .submit => try b.addControl(
                .{ .submit = .{ .label = try b.keep(label.slice()) } },
                lexbor.attribute(node, "name") orelse "",
                lexbor.attribute(node, "value") orelse "",
            ),
            .reset => try b.addControl(.{ .reset = .{ .label = try b.keep(label.slice()) } }, "", ""),
            .inert => {},
        }
    }

    /// A list to choose from sends its chosen entry, which the reader shows
    /// and does not offer to change: there is no list to pick from in the
    /// toolkit yet.
    fn select(self: *Walker, node: *Node) Error!void {
        const chosen = chosenOption(node) orelse return;
        const label = textWithin(chosen);
        try self.builder.addControl(.hidden, lexbor.attribute(node, "name") orelse "", lexbor.attribute(chosen, "value") orelse label.slice());
        try self.aside(label.slice());
    }

    fn textarea(self: *Walker, node: *Node) Error!void {
        const b = self.builder;
        try b.addControl(.{ .line = .{
            .letters = lettersOf(node, "cols", 30),
            .hint = try b.keep(lexbor.attribute(node, "placeholder") orelse ""),
        } }, lexbor.attribute(node, "name") orelse "", textWithin(node).slice());
    }
};

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
    var digits: usize = 0;
    while (digits < given.len and std.ascii.isDigit(given[digits])) digits += 1;
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
    var at = following(node, node);
    while (at) |here| : (at = following(here, node)) {
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
    var at = following(select, select);
    while (at) |here| : (at = following(here, select)) {
        if (lexbor.tagOf(here) != .option) continue;
        if (lexbor.hasAttribute(here, "selected")) return here;
        if (first == null) first = here;
    }
    return first;
}

/// Whether the page says an element is not for reading: navigation, or
/// something it hides from everyone, or from anyone listening to it read.
fn unread(node: *Node) bool {
    return lexbor.hasAttribute(node, "hidden") or
        lexbor.attributeIs(node, "aria-hidden", "true") or
        lexbor.attributeIs(node, "role", "navigation");
}

/// The node after `node` in document order, going no further than `root`.
fn following(node: *Node, root: *Node) ?*Node {
    if (node.first_child) |child| return child;
    var at = node;
    while (at != root) {
        if (at.next) |sibling| return sibling;
        at = at.parent orelse return null;
    }
    return null;
}

/// Where a page's own content is: the `main` element it marks, and otherwise
/// the whole of it. What is outside a page's main is the site around it,
/// its menus, its search, its footer, and a reader that showed all of that
/// would open every article on the site's furniture.
fn contentOf(root: *Node) *Node {
    var at = following(root, root);
    while (at) |node| : (at = following(node, root)) {
        if (node.type != .element) continue;
        const main = lexbor.tagOf(node) == .main or lexbor.attributeIs(node, "role", "main");
        if (main and !lexbor.hasAttribute(node, "hidden")) return node;
    }
    return root;
}

/// Keep where the page says its version for small screens is: a link in its
/// head that is an alternate for a screen no wider than some width, or for a
/// handheld, which is how a site with a separate mobile site names it.
fn mobileVersion(builder: *Builder, root: *Node, base: url.Url) Builder.Error!void {
    var at = following(root, root);
    while (at) |node| : (at = following(node, root)) {
        switch (lexbor.tagOf(node) orelse continue) {
            // The head is over, and with it the links a page says this in.
            .body => return,
            .link => {},
            else => continue,
        }
        if (!hasToken(lexbor.attribute(node, "rel") orelse "", "alternate")) continue;
        const media = lexbor.attribute(node, "media") orelse continue;
        if (std.ascii.findIgnoreCase(media, "max-width") == null and std.ascii.findIgnoreCase(media, "handheld") == null) continue;
        var buf: [url.ADDRESS_MAX]u8 = undefined;
        const address = url.resolve(base, lexbor.attribute(node, "href") orelse "", &buf) orelse continue;
        builder.page.mobile = try builder.keep(address);
        return;
    }
}

/// Whether a list of keywords written apart by spaces, as `rel` is, holds
/// `word`.
fn hasToken(list: []const u8, word: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, list, &std.ascii.whitespace);
    while (words.next()) |each| {
        if (std.ascii.eqlIgnoreCase(each, word)) return true;
    }
    return false;
}

/// Walk `document` into `page`. Links are resolved against `base`, which is
/// the address the page came from.
pub fn extract(gpa: std.mem.Allocator, document: *lexbor.Document, base: url.Url, page: *page_mod.Page) Builder.Error!void {
    var builder = Builder{ .gpa = gpa, .page = page };
    if (lexbor.titleOf(document)) |title| try builder.title(title);
    try mobileVersion(&builder, lexbor.nodeOf(document), base);

    var walker = Walker{ .builder = &builder, .base = base };
    const root = contentOf(lexbor.nodeOf(document));

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
    try builder.finish();
}
