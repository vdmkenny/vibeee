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
const lexbor = @import("lexbor.zig");
const page_mod = @import("page.zig");
const url = @import("url.zig");

const Node = lexbor.Node;
const Tag = lexbor.Tag;
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

/// How deep lists may nest before an entry stops stepping further in. Past
/// this the indent would leave a column a few letters wide.
const LIST_MAX = 16;
/// How many links may be open around one word. Nested links are not valid
/// markup and the parser mostly undoes them; this is the bound on the rest.
const LINK_MAX = 16;

const List = struct { ordered: bool, next: u32 };

const Walker = struct {
    builder: *Builder,
    base: url.Url,

    lists: [LIST_MAX]List = undefined,
    /// How deep in lists, which can exceed what `lists` holds: past the
    /// bound an entry is bulleted and steps no further.
    list_depth: u16 = 0,
    quote_depth: u16 = 0,
    pre_depth: u16 = 0,
    heading_depth: u16 = 0,
    mono_depth: u16 = 0,

    links: [LINK_MAX]u16 = undefined,
    link_depth: u16 = 0,

    const Error = Builder.Error;

    /// What the next block is, given everything the walk is inside.
    fn context(self: *const Walker, kind: page_mod.Kind, marker: page_mod.Marker) page_mod.Context {
        const steps = @min(self.list_depth, LIST_MAX) + self.quote_depth;
        return .{
            .kind = if (self.pre_depth > 0) .preformatted else kind,
            .depth = @intCast(@min(steps, std.math.maxInt(u8))),
            .quoted = self.quote_depth > 0,
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
        b.face = if (self.heading_depth > 0) .heading else if (self.mono_depth > 0 or self.pre_depth > 0) .mono else .body;
        b.link = if (self.link_depth > 0 and self.link_depth <= LINK_MAX) self.links[self.link_depth - 1] else page_mod.NO_LINK;
        b.ink = if (b.link != page_mod.NO_LINK) .link else .text;
    }

    /// Arrive at a node. True for an element whose leaving matters, which is
    /// also one the walk goes inside.
    fn enter(self: *Walker, node: *Node) Error!bool {
        switch (node.type) {
            .text => {
                try self.builder.words(lexbor.wordsOf(node));
                return false;
            },
            .element => {},
            else => return false,
        }

        const tag = lexbor.tagOf(node) orelse return false;
        if (unread(node)) return false;
        switch (roleOf(tag)) {
            .hidden => return false,
            .none => return true,
            .block => try self.boundary(.paragraph),
            .heading => {
                self.heading_depth += 1;
                try self.boundary(.heading);
            },
            .list, .ordered => {
                try self.boundary(.paragraph);
                if (self.list_depth < LIST_MAX) {
                    self.lists[self.list_depth] = .{
                        .ordered = roleOf(tag) == .ordered,
                        .next = startOf(node),
                    };
                }
                self.list_depth += 1;
            },
            .item => {
                const marker: page_mod.Marker = marker: {
                    if (self.list_depth == 0 or self.list_depth > LIST_MAX) break :marker .bullet;
                    const list = &self.lists[self.list_depth - 1];
                    if (!list.ordered) break :marker .bullet;
                    defer list.next +%= 1;
                    break :marker .{ .number = list.next };
                };
                try self.builder.boundary(self.context(.item, marker));
            },
            .quote => {
                self.quote_depth += 1;
                try self.boundary(.paragraph);
            },
            .preformatted => {
                self.pre_depth += 1;
                try self.builder.boundary(self.context(.preformatted, .none));
            },
            .rule => {
                try self.builder.rule();
                try self.builder.boundary(self.context(.paragraph, .none));
                return false;
            },
            .line_break => {
                try self.builder.lineBreak();
                return false;
            },
            .link => {
                const link = try self.linkFor(node);
                if (self.link_depth < LINK_MAX) self.links[self.link_depth] = link;
                self.link_depth += 1;
            },
            .mono => self.mono_depth += 1,
            .image => {
                // What the picture is, where the page said: a reader without
                // pictures reads the description instead, and a picture that
                // gave none is one the page did not think worth describing.
                const alt = std.mem.trim(u8, lexbor.attribute(node, "alt") orelse "", " \t\r\n");
                if (alt.len > 0) {
                    const ink = self.builder.ink;
                    self.builder.ink = .dim;
                    try self.builder.words(" [");
                    try self.builder.words(alt);
                    try self.builder.words("] ");
                    self.builder.ink = ink;
                }
                return false;
            },
        }
        self.restyle();
        return true;
    }

    fn leave(self: *Walker, node: *Node) Error!void {
        const tag = lexbor.tagOf(node) orelse return;
        switch (roleOf(tag)) {
            .hidden, .none, .rule, .line_break, .image => {},
            .block, .item => try self.boundary(.paragraph),
            .heading => {
                self.heading_depth -|= 1;
                try self.boundary(.paragraph);
            },
            .list, .ordered => {
                self.list_depth -|= 1;
                try self.boundary(.paragraph);
            },
            .quote => {
                self.quote_depth -|= 1;
                try self.boundary(.paragraph);
            },
            .preformatted => {
                self.pre_depth -|= 1;
                try self.boundary(.paragraph);
            },
            .link => self.link_depth -|= 1,
            .mono => self.mono_depth -|= 1,
        }
        self.restyle();
    }

    /// The link an anchor makes, or none for one that goes nowhere this
    /// reader follows: no address, another scheme, a place on this page.
    fn linkFor(self: *Walker, node: *Node) Error!u16 {
        const href = lexbor.attribute(node, "href") orelse return page_mod.NO_LINK;
        var buf: [url.ADDRESS_MAX]u8 = undefined;
        const resolved = url.resolve(self.base, href, &buf) orelse return page_mod.NO_LINK;
        return self.builder.addLink(resolved);
    }
};

/// Where an ordered list starts counting: its `start`, or one.
fn startOf(node: *Node) u32 {
    const start = lexbor.attribute(node, "start") orelse return 1;
    return std.fmt.parseInt(u32, std.mem.trim(u8, start, " \t"), 10) catch 1;
}

/// Whether the page says an element is not for reading: navigation, or
/// something it hides from everyone, or from anyone listening to it read.
fn unread(node: *Node) bool {
    if (lexbor.attribute(node, "hidden") != null) return true;
    if (std.ascii.eqlIgnoreCase(lexbor.attribute(node, "aria-hidden") orelse "", "true")) return true;
    return std.ascii.eqlIgnoreCase(lexbor.attribute(node, "role") orelse "", "navigation");
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
        const main = lexbor.tagOf(node) == .main or
            std.ascii.eqlIgnoreCase(lexbor.attribute(node, "role") orelse "", "main");
        if (main and lexbor.attribute(node, "hidden") == null) return node;
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
