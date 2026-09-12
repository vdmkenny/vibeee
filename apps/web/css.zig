//! A page's cascade as the reader reads it: whether an element shows, the
//! colours it asks for, which way its lines lean, and its retained geometry.
//!
//! Upstream works out what every element is given, from stylesheets and
//! `style` attributes, by specificity and by order. This turns its answer for
//! one element into the few things this reader draws or will lay out;
//! everything else a stylesheet says is left where it is.
//!
//! A page's `<style>` elements and `style` attributes are upstream's to apply
//! while the page is parsed. The stylesheets it links to are fetched by the
//! window, and each is handed to `apply` for the window the page is read for.
//! `apply` gives upstream only the rules that say something this reader
//! draws or retains for future box layout: matching a rule is a walk of the
//! whole tree, and most of a site's rules remain of no use here.
//!
//! What an older page says with attributes rather than a stylesheet is read
//! here too, below anything a stylesheet says, as a browser reads it: a colour
//! in `bgcolor` or on a `<font>`, and a block's `align`. A page read with its
//! stylesheets off has no cascade, and none of this is asked.

const std = @import("std");
const lib = @import("lib");
const lexbor = @import("lexbor");
const media = @import("media.zig");
const page_mod = @import("page.zig");
const url = @import("url");

const rgb = lib.rgb;
const Allocator = std.mem.Allocator;
const Node = lexbor.Node;
const Keyword = lexbor.Keyword;
const Alignment = page_mod.Alignment;

/// A colour a page asks for.
pub const Paint = union(enum) {
    colour: rgb.Colour,
    /// What the element would have had anyway, which is its parent's.
    current,
    /// None of its own: what is under it shows through.
    transparent,
};

/// Whether the page lets an element be seen: not taken out of it with
/// `display: none`, not hidden with `visibility`, and not made wholly
/// see-through, which is how a page hides what waits for a script or a
/// pointer to show it.
pub fn shows(node: *const Node) bool {
    if (valueOf(lexbor.Display, node, .display)) |display| {
        if (display.a == .none) return false;
    }
    if (valueOf(lexbor.Single, node, .visibility)) |visibility| {
        if (visibility.kind == .hidden or visibility.kind == .collapse) return false;
    }
    if (valueOf(lexbor.Channel, node, .opacity)) |alpha| {
        if (opacity(alpha.*) == 0) return false;
    }
    return true;
}

/// Whether an element's words belong to the block they stand in rather than
/// to one of their own: a page that says `display: inline`, `inline-block`
/// or `contents` says as much, whatever the element is called. A page that
/// dresses a row of links, or of words, in elements of their own means them
/// read as one line, and a block a piece would be the reader's shape and not
/// the page's.
pub fn flows(node: *const Node) bool {
    const display = valueOf(lexbor.Display, node, .display) orelse return false;
    return switch (display.a) {
        .@"inline", .inline_block, .contents => true,
        else => false,
    };
}

/// The geometry upstream resolved for `node`, limited to the units the first
/// box-layout pass will understand. Unsupported CSS values remain `auto`.
pub fn boxStyle(node: *const Node, fallback: page_mod.BoxStyle.Display) page_mod.BoxStyle {
    return .{
        .display = displayOf(node) orelse fallback,
        .position = positionOf(node),
        .direction = directionOf(node),
        .gap = gapOf(node),
        .justify = justifyOf(node),
        .items = itemsOf(node),
        .edges = .{
            .top = lengthOf(node, .top),
            .right = lengthOf(node, .right),
            .bottom = lengthOf(node, .bottom),
            .left = lengthOf(node, .left),
        },
        .width = lengthOf(node, .width),
        .height = lengthOf(node, .height),
        .min_width = lengthOf(node, .min_width),
        .min_height = lengthOf(node, .min_height),
        .max_width = lengthOf(node, .max_width),
        .max_height = lengthOf(node, .max_height),
    };
}

fn displayOf(node: *const Node) ?page_mod.BoxStyle.Display {
    const display = valueOf(lexbor.Display, node, .display) orelse return null;
    for ([_]Keyword{ display.a, display.b, display.c }) |part| switch (part) {
        .flex, .inline_flex => return .flex,
        .block => return .block,
        .@"inline", .inline_block, .contents => return .@"inline",
        else => {},
    };
    return null;
}

fn positionOf(node: *const Node) page_mod.BoxStyle.Position {
    const position = valueOf(lexbor.Position, node, .position) orelse return .static;
    return switch (position.kind) {
        .absolute => .absolute,
        .fixed => .fixed,
        else => .static,
    };
}

fn lengthOf(node: *const Node, property: lexbor.Property) page_mod.Unit {
    const length = valueOf(lexbor.LengthPercentage, node, property) orelse return .auto;
    return unitOf(length);
}

fn unitOf(length: *const lexbor.LengthPercentage) page_mod.Unit {
    return switch (length.kind) {
        .auto => .auto,
        .percentage => .{ .percent = length.value.percentage.num },
        .length => switch (length.value.length.unit) {
            .undef, .px => .{ .px = length.value.length.num },
            .vw => .{ .vw = length.value.length.num },
            .vh => .{ .vh = length.value.length.num },
            else => .auto,
        },
        else => .auto,
    };
}

/// Which way a flex container's items run: `flex-direction: column`, or
/// across it reversed, which this reader reads as across it.
fn directionOf(node: *const Node) page_mod.BoxStyle.Direction {
    const direction = valueOf(lexbor.Single, node, .flex_direction) orelse return .row;
    return switch (direction.kind) {
        .column, .column_reverse => .column,
        else => .row,
    };
}

/// Where a flex container's items go along its main axis, as
/// `justify-content` says: `space-between` puts the room it has left between
/// them, and anything else this reader does not spread leaves them at its
/// start.
fn justifyOf(node: *const Node) page_mod.BoxStyle.Justify {
    const justify = valueOf(lexbor.Single, node, .justify_content) orelse return .start;
    return switch (justify.kind) {
        .center => .center,
        .end, .flex_end, .right => .end,
        .space_between => .between,
        else => .start,
    };
}

/// Where they go across it, as `align-items` says.
fn itemsOf(node: *const Node) page_mod.BoxStyle.Items {
    const items = valueOf(lexbor.Single, node, .align_items) orelse return .start;
    return switch (items.kind) {
        .center => .center,
        .end, .flex_end => .end,
        else => .start,
    };
}

/// The room a flex container leaves between its items, from `gap`, or from
/// `row-gap` or `column-gap` alone where only one of them is written.
/// Upstream reads none of the three, so the value is kept as it was written
/// and read back as the length of a `width`.
fn gapOf(node: *const Node) page_mod.Unit {
    if (cascadeOf(node) == null) return .auto;
    for ([_][]const u8{ "gap", "row-gap", "column-gap" }) |name| {
        const declaration = lexbor.lxb_dom_element_style_by_name(node, name.ptr, name.len) orelse continue;
        const custom = customOf(declaration) orelse continue;
        return lengthIn(cascadeOf(node).?.parser, "width", firstOf(custom.value.slice()));
    }
    return .auto;
}

/// Whether a property upstream keeps by name is one of the three a gap may
/// be written in.
fn isGap(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "gap") or
        std.ascii.eqlIgnoreCase(name, "row-gap") or
        std.ascii.eqlIgnoreCase(name, "column-gap");
}

/// The first of the words a value is written in, which for a `gap` of one
/// length is the whole of it.
fn firstOf(value: []const u8) []const u8 {
    var words = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
    return words.next() orelse "";
}

/// `value` read by upstream as the value of `property`, where it is a length.
fn lengthIn(parser: *lexbor.CssParser, comptime property: []const u8, value: []const u8) page_mod.Unit {
    if (value.len == 0) return .auto;
    var buf: [96]u8 = undefined;
    const written = std.fmt.bufPrint(&buf, property ++ ":{s}", .{value}) catch return .auto;
    const list = lexbor.lxb_css_declaration_list_parse(parser, written.ptr, written.len) orelse return .auto;
    const first = list.first orelse return .auto;
    if (first.kind != .declaration) return .auto;
    const declaration: *const lexbor.Declaration = @fieldParentPtr("rule", first);
    if (declaration.property != .width) return .auto;
    return unitOf(@ptrCast(@alignCast(declaration.value orelse return .auto)));
}

/// Whether the page keeps an element's spaces and line ends as written:
/// `white-space: pre` or `pre-wrap`, which is how a page asks for words to
/// stand where they were typed, a table of them, or a line of a program.
pub fn keepsSpaces(node: *const Node) bool {
    const spacing = valueOf(lexbor.Single, node, .white_space) orelse return false;
    return switch (spacing.kind) {
        .pre, .pre_wrap => true,
        else => false,
    };
}

/// Whether a list's entries carry no marker: `list-style-type: none`, or
/// `list-style: none`, which is how a page says a list is its furniture
/// rather than a list of things. A bullet on each of a row of links is the
/// reader's noise, not the page's.
pub fn markerless(node: *const Node) bool {
    if (cascadeOf(node) == null) return false;
    for (&[_][]const u8{ "list-style-type", "list-style" }) |name| {
        const declaration = lexbor.lxb_dom_element_style_by_name(node, name.ptr, name.len) orelse continue;
        const custom = customOf(declaration) orelse continue;
        if (saysNone(custom.value.slice())) return true;
    }
    return false;
}

/// Whether the words of a property upstream keeps as they were written say
/// none somewhere in them. The shorthand carries a picture and a place
/// beside its type, in any order, so the whole value is looked through.
fn saysNone(value: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
    while (words.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "none")) return true;
    }
    return false;
}

/// The colour of an element's words, where the page gives one: in a
/// stylesheet, or as the `color` of a `<font>` or the `text` of a body.
pub fn ink(node: *Node) ?Paint {
    if (paint(node, .color)) |given| return given;
    return switch (lexbor.tagOf(node) orelse return null) {
        .font => attributeColour(node, "color"),
        .body => attributeColour(node, "text"),
        else => null,
    };
}

/// What the page paints under an element, where it paints anything: its
/// `background-color`, the colour among what its `background` says, or its
/// `bgcolor`.
pub fn ground(node: *Node) ?Paint {
    if (paint(node, .background_color)) |given| return given;
    if (shorthandGround(node)) |given| return given;
    return attributeColour(node, "bgcolor");
}

/// Which way the page lines up an element's lines, where it says: in a
/// stylesheet, by `align`, or by the element being a `<center>`.
pub fn alignment(node: *Node) ?Alignment {
    if (valueOf(lexbor.Single, node, .text_align)) |text_align| {
        if (alignmentOf(text_align.kind)) |given| return given;
    }
    if (cascadeOf(node) == null) return null;
    if (lexbor.tagOf(node) == .center) return .center;
    return aligns.get(std.mem.trim(u8, lexbor.attribute(node, "align") orelse return null, &std.ascii.whitespace));
}

/// What `align` says, as the words it may be.
const aligns = std.StaticStringMapWithEql(Alignment, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ "left", .start },
    .{ "justify", .start },
    .{ "center", .center },
    .{ "middle", .center },
    .{ "right", .end },
});

fn alignmentOf(kind: Keyword) ?Alignment {
    return switch (kind) {
        .left, .start, .justify => .start,
        .center => .center,
        .right, .end => .end,
        else => null,
    };
}

/// The colour the cascade gives an element for `property`, where it gives
/// one.
fn paint(node: *const Node, property: lexbor.Property) ?Paint {
    return paintOf(valueOf(lexbor.Colour, node, property) orelse return null);
}

/// The colour among the words of an element's `background`, which upstream
/// keeps as the sheet wrote them. Each is read by upstream as the value of a
/// `background-color` until one is a colour.
fn shorthandGround(node: *const Node) ?Paint {
    const cascade = cascadeOf(node) orelse return null;
    const declaration = lexbor.lxb_dom_element_style_by_name(node, "background", "background".len) orelse return null;
    const custom = customOf(declaration) orelse return null;
    var parts = Parts{ .text = custom.value.slice() };
    while (parts.next()) |part| {
        if (colourIn(cascade.parser, "background-color", part)) |given| return given;
    }
    return null;
}

/// A colour an attribute gives, as a browser reads one: as a stylesheet
/// would, or as hex digits without their `#`.
fn attributeColour(node: *Node, name: []const u8) ?Paint {
    const cascade = cascadeOf(node) orelse return null;
    const given = std.mem.trim(u8, lexbor.attribute(node, name) orelse return null, &std.ascii.whitespace);
    if (colourIn(cascade.parser, "color", given)) |colour| return colour;
    var hashed: [8]u8 = undefined;
    return colourIn(cascade.parser, "color", std.fmt.bufPrint(&hashed, "#{s}", .{given}) catch return null);
}

/// `value` read by upstream as the value of `property`, where it is a colour.
fn colourIn(parser: *lexbor.CssParser, comptime property: []const u8, value: []const u8) ?Paint {
    var buf: [96]u8 = undefined;
    const written = std.fmt.bufPrint(&buf, property ++ ":{s}", .{value}) catch return null;
    const list = lexbor.lxb_css_declaration_list_parse(parser, written.ptr, written.len) orelse return null;
    const first = list.first orelse return null;
    if (first.kind != .declaration) return null;
    const declaration: *const lexbor.Declaration = @fieldParentPtr("rule", first);
    if (declaration.property != .color and declaration.property != .background_color) return null;
    return paintOf(@ptrCast(@alignCast(declaration.value orelse return null)));
}

/// What the cascade gave `node` for `property`, in the shape that property's
/// values take, or nothing where no rule said.
fn valueOf(comptime Value: type, node: *const Node, property: lexbor.Property) ?*const Value {
    if (node.type != .element or cascadeOf(node) == null) return null;
    const declaration = lexbor.lxb_dom_element_style_by_id(node, property) orelse return null;
    if (declaration.property != property) return null;
    return @ptrCast(@alignCast(declaration.value orelse return null));
}

/// The cascade of the document `node` is in, where it has one.
fn cascadeOf(node: *const Node) ?*lexbor.DocumentCss {
    return lexbor.domOf(node.owner_document orelse return null).css;
}

/// What a declaration of a property upstream does not read holds, where it
/// is one.
fn customOf(declaration: *const lexbor.Declaration) ?*const lexbor.Custom {
    if (declaration.property != .custom) return null;
    return @ptrCast(@alignCast(declaration.value orelse return null));
}

fn paintOf(colour: *const lexbor.Colour) ?Paint {
    return switch (colour.kind) {
        .current_color => .current,
        .transparent => .transparent,
        .hex => {
            const hex = colour.u.hex;
            // Three and four digits are a digit a channel, each standing for
            // itself twice over: `#fa0` is `#ffaa00`.
            const short = switch (hex.length) {
                .three, .four => true,
                .six, .eight => false,
                _ => return null,
            };
            const alpha = if (hex.length == .four) doubled(hex.a) else hex.a;
            if (alpha == 0) return .transparent;
            if (!short) return .{ .colour = rgb.Colour.of(hex.r, hex.g, hex.b) };
            return .{ .colour = rgb.Colour.of(doubled(hex.r), doubled(hex.g), doubled(hex.b)) };
        },
        .rgb, .rgba => {
            const channels = colour.u.rgb;
            if (opacity(channels.a) == 0) return .transparent;
            return .{ .colour = rgb.Colour.of(level(channels.r), level(channels.g), level(channels.b)) };
        },
        else => .{ .colour = named[colour.kind.named() orelse return null] },
    };
}

/// A hex digit as the byte it stands for in a colour written with one digit
/// a channel: `f` is `ff`.
fn doubled(digit: u8) u8 {
    return digit << 4 | digit;
}

/// One channel of `rgb()`, as a byte: a number is out of 255, and a
/// percentage out of a hundred.
fn level(channel: lexbor.Channel) u8 {
    const value: f64 = switch (channel.kind) {
        .number => channel.value.num,
        .percentage => channel.value.num * 255 / 100,
        else => 0,
    };
    return @intFromFloat(@round(std.math.clamp(value, 0, 255)));
}

/// How opaque an `rgb()` is, from nought to one. One that says nothing is
/// wholly opaque.
fn opacity(channel: lexbor.Channel) f64 {
    return switch (channel.kind) {
        .number => channel.value.num,
        .percentage => channel.value.num / 100,
        else => 1,
    };
}

/// The words of a value: apart by spaces, and by the commas and slashes
/// between a `background`'s layers and sizes, with a bracketed group kept
/// whole, as `rgb(0, 0, 0)` is.
const Parts = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *Parts) ?[]const u8 {
        while (self.at < self.text.len and apart(self.text[self.at])) self.at += 1;
        if (self.at == self.text.len) return null;
        const start = self.at;
        var depth: usize = 0;
        while (self.at < self.text.len) : (self.at += 1) {
            switch (self.text[self.at]) {
                '(' => depth += 1,
                ')' => depth -|= 1,
                else => |c| if (depth == 0 and apart(c)) break,
            }
        }
        return self.text[start..self.at];
    }

    fn apart(c: u8) bool {
        return std.ascii.isWhitespace(c) or c == ',' or c == '/';
    }
};

// ---------------------------------------------------------------------------
// A page's own stylesheets
// ---------------------------------------------------------------------------

/// The most stylesheets of its own a page is read with, and the most they
/// may come to between them. Most pages link fewer than ten; one that links
/// more is drawn with those it names first.
pub const SHEETS_MAX = 16;
pub const SHEETS_BYTES_MAX = 2 * 1024 * 1024;

/// The stylesheets a page links to, in the order it names them, each with the
/// media its link names; and how many have been handed out to fetch, and what
/// those came to.
pub const Sheets = struct {
    links: std.ArrayList(Link) = .empty,
    taken: usize = 0,
    spent: usize = 0,

    /// A stylesheet to fetch: where it is, and the media its link names,
    /// which are empty for every medium.
    pub const Link = struct { address: []const u8, media: []const u8 };

    pub fn deinit(self: *Sheets, gpa: Allocator) void {
        for (self.links.items) |link| {
            gpa.free(link.address);
            gpa.free(link.media);
        }
        self.links.deinit(gpa);
        self.* = .{};
    }

    fn add(self: *Sheets, gpa: Allocator, address: []const u8, asked: []const u8) Allocator.Error!void {
        if (self.links.items.len == SHEETS_MAX) return;
        const kept_address = try gpa.dupe(u8, address);
        errdefer gpa.free(kept_address);
        const kept_media = try gpa.dupe(u8, asked);
        errdefer gpa.free(kept_media);
        try self.links.append(gpa, .{ .address = kept_address, .media = kept_media });
    }

    /// The next stylesheet to fetch, or nothing once every one has been, or
    /// once those that came have used what a page's may come to.
    pub fn next(self: *Sheets) ?Link {
        if (self.taken == self.links.items.len or self.spent >= SHEETS_BYTES_MAX) return null;
        defer self.taken += 1;
        return self.links.items[self.taken];
    }

    /// Count one that came against what they may come to.
    pub fn took(self: *Sheets, bytes: usize) void {
        self.spent +|= bytes;
    }
};

/// The stylesheets `document` links to that could be for a window, in the
/// order it names them, resolved against `base`, each with the media its
/// link names: every `<link rel="stylesheet">` that is not an alternate or
/// turned off, and whose media could be a window of some size. Whether they
/// are for the window a page is drawn in is asked when it is read.
pub fn sheetsOf(gpa: Allocator, document: *lexbor.Document, base: url.Url, into: *Sheets) Allocator.Error!void {
    const root = lexbor.nodeOf(document);
    var at = lexbor.following(root, root);
    while (at) |node| : (at = lexbor.following(node, root)) {
        if (lexbor.tagOf(node) != .link) continue;
        if (!lexbor.attributeHas(node, "rel", "stylesheet") or lexbor.attributeHas(node, "rel", "alternate")) continue;
        if (lexbor.hasAttribute(node, "disabled")) continue;
        const asked = std.mem.trim(u8, lexbor.attribute(node, "media") orelse "", &std.ascii.whitespace);
        if (!media.couldMatch(asked)) continue;
        var buf: [url.ADDRESS_MAX]u8 = undefined;
        try into.add(gpa, url.resolve(base, lexbor.attribute(node, "href") orelse continue, &buf) orelse continue, asked);
    }
}

/// Apply a stylesheet to `document` as it reads on `screen`: its rules for
/// the window, and of those only the ones that say something this reader
/// draws or retains for box layout.
pub fn apply(gpa: Allocator, document: *lexbor.Document, text: []const u8, screen: ?media.Screen) void {
    const dom = lexbor.domOf(document);
    const cascade = dom.css orelse return;

    // Handed over with its media blocks resolved, since the top of a sheet
    // is where upstream reads every rule whole. Resolving only ever leaves
    // text out, so the sheet's own length is room enough.
    const flat = gpa.alloc(u8, text.len) catch return;
    defer gpa.free(flat);
    var w: std.Io.Writer = .fixed(flat);
    media.flatten(text, screen, &w) catch return;
    const rules = w.buffered();

    const sheet = lexbor.lxb_css_stylesheet_create(cascade.memory) orelse return;
    if (lexbor.lxb_css_stylesheet_parse(sheet, cascade.parser, rules.ptr, rules.len) != .ok) return;
    const root = sheet.root orelse return;
    if (root.kind != .list) return;
    const list: *const lexbor.RuleList = @fieldParentPtr("rule", root);
    var at = list.first;
    while (at) |rule| : (at = rule.next) {
        if (rule.kind != .style) continue;
        const style: *lexbor.StyleRule = @fieldParentPtr("rule", rule);
        if (honoured(style)) _ = lexbor.lxb_dom_document_style_attach(dom, style);
    }
}

/// Whether a rule says anything this reader draws or retains for box layout.
fn honoured(style: *const lexbor.StyleRule) bool {
    const list = style.declarations orelse return false;
    var at = list.first;
    while (at) |rule| : (at = rule.next) {
        if (rule.kind != .declaration) continue;
        const declaration: *const lexbor.Declaration = @fieldParentPtr("rule", rule);
        switch (declaration.property) {
            .display, .position, .top, .right, .bottom, .left, .width, .height, .min_width, .min_height, .max_width, .max_height, .flex_direction, .justify_content, .align_items, .visibility, .opacity, .color, .background_color, .text_align, .white_space => return true,
            .custom => {
                const custom = customOf(declaration) orelse continue;
                const name = custom.name.slice();
                if (std.ascii.eqlIgnoreCase(name, "background") or
                    std.ascii.eqlIgnoreCase(name, "list-style-type") or
                    std.ascii.eqlIgnoreCase(name, "list-style") or
                    isGap(name)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Upstream's named colours, in its order, which is alphabetical.
const named = [_]rgb.Colour{
    .{ .r = 0xF0, .g = 0xF8, .b = 0xFF }, // aliceblue
    .{ .r = 0xFA, .g = 0xEB, .b = 0xD7 }, // antiquewhite
    .{ .r = 0x00, .g = 0xFF, .b = 0xFF }, // aqua
    .{ .r = 0x7F, .g = 0xFF, .b = 0xD4 }, // aquamarine
    .{ .r = 0xF0, .g = 0xFF, .b = 0xFF }, // azure
    .{ .r = 0xF5, .g = 0xF5, .b = 0xDC }, // beige
    .{ .r = 0xFF, .g = 0xE4, .b = 0xC4 }, // bisque
    .{ .r = 0x00, .g = 0x00, .b = 0x00 }, // black
    .{ .r = 0xFF, .g = 0xEB, .b = 0xCD }, // blanchedalmond
    .{ .r = 0x00, .g = 0x00, .b = 0xFF }, // blue
    .{ .r = 0x8A, .g = 0x2B, .b = 0xE2 }, // blueviolet
    .{ .r = 0xA5, .g = 0x2A, .b = 0x2A }, // brown
    .{ .r = 0xDE, .g = 0xB8, .b = 0x87 }, // burlywood
    .{ .r = 0x5F, .g = 0x9E, .b = 0xA0 }, // cadetblue
    .{ .r = 0x7F, .g = 0xFF, .b = 0x00 }, // chartreuse
    .{ .r = 0xD2, .g = 0x69, .b = 0x1E }, // chocolate
    .{ .r = 0xFF, .g = 0x7F, .b = 0x50 }, // coral
    .{ .r = 0x64, .g = 0x95, .b = 0xED }, // cornflowerblue
    .{ .r = 0xFF, .g = 0xF8, .b = 0xDC }, // cornsilk
    .{ .r = 0xDC, .g = 0x14, .b = 0x3C }, // crimson
    .{ .r = 0x00, .g = 0xFF, .b = 0xFF }, // cyan
    .{ .r = 0x00, .g = 0x00, .b = 0x8B }, // darkblue
    .{ .r = 0x00, .g = 0x8B, .b = 0x8B }, // darkcyan
    .{ .r = 0xB8, .g = 0x86, .b = 0x0B }, // darkgoldenrod
    .{ .r = 0xA9, .g = 0xA9, .b = 0xA9 }, // darkgray
    .{ .r = 0x00, .g = 0x64, .b = 0x00 }, // darkgreen
    .{ .r = 0xA9, .g = 0xA9, .b = 0xA9 }, // darkgrey
    .{ .r = 0xBD, .g = 0xB7, .b = 0x6B }, // darkkhaki
    .{ .r = 0x8B, .g = 0x00, .b = 0x8B }, // darkmagenta
    .{ .r = 0x55, .g = 0x6B, .b = 0x2F }, // darkolivegreen
    .{ .r = 0xFF, .g = 0x8C, .b = 0x00 }, // darkorange
    .{ .r = 0x99, .g = 0x32, .b = 0xCC }, // darkorchid
    .{ .r = 0x8B, .g = 0x00, .b = 0x00 }, // darkred
    .{ .r = 0xE9, .g = 0x96, .b = 0x7A }, // darksalmon
    .{ .r = 0x8F, .g = 0xBC, .b = 0x8F }, // darkseagreen
    .{ .r = 0x48, .g = 0x3D, .b = 0x8B }, // darkslateblue
    .{ .r = 0x2F, .g = 0x4F, .b = 0x4F }, // darkslategray
    .{ .r = 0x2F, .g = 0x4F, .b = 0x4F }, // darkslategrey
    .{ .r = 0x00, .g = 0xCE, .b = 0xD1 }, // darkturquoise
    .{ .r = 0x94, .g = 0x00, .b = 0xD3 }, // darkviolet
    .{ .r = 0xFF, .g = 0x14, .b = 0x93 }, // deeppink
    .{ .r = 0x00, .g = 0xBF, .b = 0xFF }, // deepskyblue
    .{ .r = 0x69, .g = 0x69, .b = 0x69 }, // dimgray
    .{ .r = 0x69, .g = 0x69, .b = 0x69 }, // dimgrey
    .{ .r = 0x1E, .g = 0x90, .b = 0xFF }, // dodgerblue
    .{ .r = 0xB2, .g = 0x22, .b = 0x22 }, // firebrick
    .{ .r = 0xFF, .g = 0xFA, .b = 0xF0 }, // floralwhite
    .{ .r = 0x22, .g = 0x8B, .b = 0x22 }, // forestgreen
    .{ .r = 0xFF, .g = 0x00, .b = 0xFF }, // fuchsia
    .{ .r = 0xDC, .g = 0xDC, .b = 0xDC }, // gainsboro
    .{ .r = 0xF8, .g = 0xF8, .b = 0xFF }, // ghostwhite
    .{ .r = 0xFF, .g = 0xD7, .b = 0x00 }, // gold
    .{ .r = 0xDA, .g = 0xA5, .b = 0x20 }, // goldenrod
    .{ .r = 0x80, .g = 0x80, .b = 0x80 }, // gray
    .{ .r = 0x00, .g = 0x80, .b = 0x00 }, // green
    .{ .r = 0xAD, .g = 0xFF, .b = 0x2F }, // greenyellow
    .{ .r = 0x80, .g = 0x80, .b = 0x80 }, // grey
    .{ .r = 0xF0, .g = 0xFF, .b = 0xF0 }, // honeydew
    .{ .r = 0xFF, .g = 0x69, .b = 0xB4 }, // hotpink
    .{ .r = 0xCD, .g = 0x5C, .b = 0x5C }, // indianred
    .{ .r = 0x4B, .g = 0x00, .b = 0x82 }, // indigo
    .{ .r = 0xFF, .g = 0xFF, .b = 0xF0 }, // ivory
    .{ .r = 0xF0, .g = 0xE6, .b = 0x8C }, // khaki
    .{ .r = 0xE6, .g = 0xE6, .b = 0xFA }, // lavender
    .{ .r = 0xFF, .g = 0xF0, .b = 0xF5 }, // lavenderblush
    .{ .r = 0x7C, .g = 0xFC, .b = 0x00 }, // lawngreen
    .{ .r = 0xFF, .g = 0xFA, .b = 0xCD }, // lemonchiffon
    .{ .r = 0xAD, .g = 0xD8, .b = 0xE6 }, // lightblue
    .{ .r = 0xF0, .g = 0x80, .b = 0x80 }, // lightcoral
    .{ .r = 0xE0, .g = 0xFF, .b = 0xFF }, // lightcyan
    .{ .r = 0xFA, .g = 0xFA, .b = 0xD2 }, // lightgoldenrodyellow
    .{ .r = 0xD3, .g = 0xD3, .b = 0xD3 }, // lightgray
    .{ .r = 0x90, .g = 0xEE, .b = 0x90 }, // lightgreen
    .{ .r = 0xD3, .g = 0xD3, .b = 0xD3 }, // lightgrey
    .{ .r = 0xFF, .g = 0xB6, .b = 0xC1 }, // lightpink
    .{ .r = 0xFF, .g = 0xA0, .b = 0x7A }, // lightsalmon
    .{ .r = 0x20, .g = 0xB2, .b = 0xAA }, // lightseagreen
    .{ .r = 0x87, .g = 0xCE, .b = 0xFA }, // lightskyblue
    .{ .r = 0x77, .g = 0x88, .b = 0x99 }, // lightslategray
    .{ .r = 0x77, .g = 0x88, .b = 0x99 }, // lightslategrey
    .{ .r = 0xB0, .g = 0xC4, .b = 0xDE }, // lightsteelblue
    .{ .r = 0xFF, .g = 0xFF, .b = 0xE0 }, // lightyellow
    .{ .r = 0x00, .g = 0xFF, .b = 0x00 }, // lime
    .{ .r = 0x32, .g = 0xCD, .b = 0x32 }, // limegreen
    .{ .r = 0xFA, .g = 0xF0, .b = 0xE6 }, // linen
    .{ .r = 0xFF, .g = 0x00, .b = 0xFF }, // magenta
    .{ .r = 0x80, .g = 0x00, .b = 0x00 }, // maroon
    .{ .r = 0x66, .g = 0xCD, .b = 0xAA }, // mediumaquamarine
    .{ .r = 0x00, .g = 0x00, .b = 0xCD }, // mediumblue
    .{ .r = 0xBA, .g = 0x55, .b = 0xD3 }, // mediumorchid
    .{ .r = 0x93, .g = 0x70, .b = 0xDB }, // mediumpurple
    .{ .r = 0x3C, .g = 0xB3, .b = 0x71 }, // mediumseagreen
    .{ .r = 0x7B, .g = 0x68, .b = 0xEE }, // mediumslateblue
    .{ .r = 0x00, .g = 0xFA, .b = 0x9A }, // mediumspringgreen
    .{ .r = 0x48, .g = 0xD1, .b = 0xCC }, // mediumturquoise
    .{ .r = 0xC7, .g = 0x15, .b = 0x85 }, // mediumvioletred
    .{ .r = 0x19, .g = 0x19, .b = 0x70 }, // midnightblue
    .{ .r = 0xF5, .g = 0xFF, .b = 0xFA }, // mintcream
    .{ .r = 0xFF, .g = 0xE4, .b = 0xE1 }, // mistyrose
    .{ .r = 0xFF, .g = 0xE4, .b = 0xB5 }, // moccasin
    .{ .r = 0xFF, .g = 0xDE, .b = 0xAD }, // navajowhite
    .{ .r = 0x00, .g = 0x00, .b = 0x80 }, // navy
    .{ .r = 0xFD, .g = 0xF5, .b = 0xE6 }, // oldlace
    .{ .r = 0x80, .g = 0x80, .b = 0x00 }, // olive
    .{ .r = 0x6B, .g = 0x8E, .b = 0x23 }, // olivedrab
    .{ .r = 0xFF, .g = 0xA5, .b = 0x00 }, // orange
    .{ .r = 0xFF, .g = 0x45, .b = 0x00 }, // orangered
    .{ .r = 0xDA, .g = 0x70, .b = 0xD6 }, // orchid
    .{ .r = 0xEE, .g = 0xE8, .b = 0xAA }, // palegoldenrod
    .{ .r = 0x98, .g = 0xFB, .b = 0x98 }, // palegreen
    .{ .r = 0xAF, .g = 0xEE, .b = 0xEE }, // paleturquoise
    .{ .r = 0xDB, .g = 0x70, .b = 0x93 }, // palevioletred
    .{ .r = 0xFF, .g = 0xEF, .b = 0xD5 }, // papayawhip
    .{ .r = 0xFF, .g = 0xDA, .b = 0xB9 }, // peachpuff
    .{ .r = 0xCD, .g = 0x85, .b = 0x3F }, // peru
    .{ .r = 0xFF, .g = 0xC0, .b = 0xCB }, // pink
    .{ .r = 0xDD, .g = 0xA0, .b = 0xDD }, // plum
    .{ .r = 0xB0, .g = 0xE0, .b = 0xE6 }, // powderblue
    .{ .r = 0x80, .g = 0x00, .b = 0x80 }, // purple
    .{ .r = 0x66, .g = 0x33, .b = 0x99 }, // rebeccapurple
    .{ .r = 0xFF, .g = 0x00, .b = 0x00 }, // red
    .{ .r = 0xBC, .g = 0x8F, .b = 0x8F }, // rosybrown
    .{ .r = 0x41, .g = 0x69, .b = 0xE1 }, // royalblue
    .{ .r = 0x8B, .g = 0x45, .b = 0x13 }, // saddlebrown
    .{ .r = 0xFA, .g = 0x80, .b = 0x72 }, // salmon
    .{ .r = 0xF4, .g = 0xA4, .b = 0x60 }, // sandybrown
    .{ .r = 0x2E, .g = 0x8B, .b = 0x57 }, // seagreen
    .{ .r = 0xFF, .g = 0xF5, .b = 0xEE }, // seashell
    .{ .r = 0xA0, .g = 0x52, .b = 0x2D }, // sienna
    .{ .r = 0xC0, .g = 0xC0, .b = 0xC0 }, // silver
    .{ .r = 0x87, .g = 0xCE, .b = 0xEB }, // skyblue
    .{ .r = 0x6A, .g = 0x5A, .b = 0xCD }, // slateblue
    .{ .r = 0x70, .g = 0x80, .b = 0x90 }, // slategray
    .{ .r = 0x70, .g = 0x80, .b = 0x90 }, // slategrey
    .{ .r = 0xFF, .g = 0xFA, .b = 0xFA }, // snow
    .{ .r = 0x00, .g = 0xFF, .b = 0x7F }, // springgreen
    .{ .r = 0x46, .g = 0x82, .b = 0xB4 }, // steelblue
    .{ .r = 0xD2, .g = 0xB4, .b = 0x8C }, // tan
    .{ .r = 0x00, .g = 0x80, .b = 0x80 }, // teal
    .{ .r = 0xD8, .g = 0xBF, .b = 0xD8 }, // thistle
    .{ .r = 0xFF, .g = 0x63, .b = 0x47 }, // tomato
    .{ .r = 0x40, .g = 0xE0, .b = 0xD0 }, // turquoise
    .{ .r = 0xEE, .g = 0x82, .b = 0xEE }, // violet
    .{ .r = 0xF5, .g = 0xDE, .b = 0xB3 }, // wheat
    .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, // white
    .{ .r = 0xF5, .g = 0xF5, .b = 0xF5 }, // whitesmoke
    .{ .r = 0xFF, .g = 0xFF, .b = 0x00 }, // yellow
    .{ .r = 0x9A, .g = 0xCD, .b = 0x32 }, // yellowgreen
};

comptime {
    if (named.len != Keyword.named_last - Keyword.named_first + 1) {
        @compileError("the named colours and upstream's run of them are not the same length");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn hexOf(r: u8, g: u8, b: u8, a: u8, length: lexbor.HexLength) lexbor.Colour {
    return .{ .kind = .hex, .u = .{ .hex = .{ .r = r, .g = g, .b = b, .a = a, .length = length } } };
}

test "a hex colour written with a digit a channel is each digit twice over" {
    try testing.expect(std.meta.eql(paintOf(&hexOf(0xf, 0xf, 0xf, 0xff, .three)).?, Paint{ .colour = .hex(0xFFFFFF) }));
    try testing.expect(std.meta.eql(paintOf(&hexOf(0xf, 0xa, 0x0, 0xff, .three)).?, Paint{ .colour = .hex(0xFFAA00) }));
    try testing.expect(std.meta.eql(paintOf(&hexOf(0x12, 0x34, 0x56, 0xff, .six)).?, Paint{ .colour = .hex(0x123456) }));
}

test "the four and eight digit forms say how see-through a colour is" {
    try testing.expect(paintOf(&hexOf(0xf, 0xf, 0xf, 0x0, .four)).? == .transparent);
    try testing.expect(paintOf(&hexOf(0xf, 0xf, 0xf, 0x8, .four)).? == .colour);
    try testing.expect(paintOf(&hexOf(0x12, 0x34, 0x56, 0x00, .eight)).? == .transparent);
    try testing.expect(paintOf(&hexOf(0x12, 0x34, 0x56, 0x80, .eight)).? == .colour);
}
