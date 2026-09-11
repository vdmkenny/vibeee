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
    /// Nothing a reader sees: a script, a stylesheet, the head, the page's
    /// navigation, and a button, which does nothing without the scripts
    /// this reader never runs.
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
    /// Nothing: the words read as the text around them.
    none,
};

fn roleOf(tag: Tag) Role {
    return switch (tag) {
        .script, .style, .head, .template, .svg, .math, .iframe, .select, .textarea, .title, .base, .nav, .button => .hidden,
        .p, .div, .section, .article, .header, .footer, .main, .aside, .figure, .figcaption, .address, .center, .form, .fieldset, .details, .summary, .dl, .dt, .dd, .table, .caption, .tr, .td, .th => .block,
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
    .none = .{},
});

/// How deep lists may nest before an entry stops stepping further in. Past
/// this the indent would leave a column a few letters wide.
const LIST_MAX = 16;

const List = struct { ordered: bool, next: u32 };

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
            .image => try self.describe(node),
        }
        if (!t.walks) return false;
        self.restyle();
        return true;
    }

    fn leave(self: *Walker, node: *Node) Error!void {
        const role = roleOf(lexbor.tagOf(node) orelse return);
        const t = traits.get(role);
        if (t.counts) self.inside.getPtr(role).* -|= 1;
        if (role == .list or role == .ordered) {
            if (self.lists_past > 0) self.lists_past -= 1 else _ = self.lists.pop();
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

    /// What a picture is, where the page said: a reader without pictures
    /// reads the description instead, and a picture that gave none is one
    /// the page did not think worth describing.
    fn describe(self: *Walker, node: *Node) Error!void {
        const alt = std.mem.trim(u8, lexbor.attribute(node, "alt") orelse "", &std.ascii.whitespace);
        if (alt.len == 0) return;
        const look = self.builder.look;
        defer self.builder.look = look;
        self.builder.look.ink = .dim;
        try self.builder.words(" [");
        try self.builder.words(alt);
        try self.builder.words("] ");
    }
};

/// Where an ordered list starts counting: its `start`, or one.
fn startOf(node: *Node) u32 {
    const start = lexbor.attribute(node, "start") orelse return 1;
    return std.fmt.parseInt(u32, std.mem.trim(u8, start, &std.ascii.whitespace), 10) catch 1;
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

/// Walk `document` into `page`. Links are resolved against `base`, which is
/// the address the page came from.
pub fn extract(gpa: std.mem.Allocator, document: *lexbor.Document, base: url.Url, page: *page_mod.Page) Builder.Error!void {
    var builder = Builder{ .gpa = gpa, .page = page };
    if (lexbor.titleOf(document)) |title| try builder.title(title);

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
