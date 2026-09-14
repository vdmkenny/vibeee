//! A page's cascade as the browser reads it: whether an element shows, the
//! colours it asks for, which way its lines lean, and its retained geometry.
//!
//! Upstream works out what every element is given, from stylesheets and
//! `style` attributes, by specificity and by order. This turns its answer for
//! one element into the few things this browser draws or will lay out;
//! everything else a stylesheet says is left where it is.
//!
//! A page's `<style>` elements and `style` attributes are upstream's to apply
//! while the page is parsed. The stylesheets it links to are fetched by the
//! window, and each is handed to `apply` for the window the page is read for.
//! `apply` gives upstream only the rules that say something this browser
//! draws or retains for future box layout: matching a rule is a walk of the
//! whole tree, and most of a site's rules remain of no use here.
//!
//! What an older page says with attributes rather than a stylesheet is read
//! here too, below anything a stylesheet says, as a browser reads it: a colour
//! in `bgcolor` or on a `<font>`, and a block's `align`. A page read with its
//! stylesheets off has no cascade, and none of this is asked.

const std = @import("std");
const lib = @import("lib");
const lexbor = @import("lexbor.zig");
const links = @import("links.zig");
const media = @import("media.zig");
const page_mod = @import("page.zig");
const url = @import("url.zig");

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
/// read as one line, and a block a piece would be the browser's shape and not
/// the page's.
pub fn flows(node: *const Node) bool {
    const display = valueOf(lexbor.Display, node, .display) orelse return false;
    return switch (display.a) {
        .@"inline", .inline_block, .contents => true,
        else => false,
    };
}

/// What the cascade says of `node` as a box: whether it is a flex container,
/// and the room it and its items are given, in the units the layout reads. A
/// length in a unit it does not read is `auto`.
pub fn boxStyle(node: *const Node, fallback: page_mod.BoxStyle.Display) page_mod.BoxStyle {
    const flexing = flexOf(node);
    return .{
        .display = displayOf(node) orelse fallback,
        .direction = directionOf(node),
        .wrap = wrapOf(node),
        .gap = gapOf(node),
        .justify = justifyOf(node),
        .items = itemsOf(node),
        .self_align = selfOf(node),
        .grow = flexing.grow,
        .shrink = flexing.shrink,
        .basis = flexing.basis,
        .columns = tracksOf(node),
        .span = spanOf(node),
        .out_of_flow = outOfFlow(node),
        .width = lengthOf(node, .width),
        .height = lengthOf(node, .height),
        .min_width = lengthOf(node, .min_width),
        .min_height = lengthOf(node, .min_height),
        .max_width = lengthOf(node, .max_width),
        .max_height = lengthOf(node, .max_height),
        .margin = edgesOf(node, .margin, .{ .margin_top, .margin_right, .margin_bottom, .margin_left }),
        .padding = edgesOf(node, .padding, .{ .padding_top, .padding_right, .padding_bottom, .padding_left }),
        .border = linesOf(node),
        .radius = radiusOf(node),
    };
}

/// The lines a box draws along its sides: from the `border` shorthand for
/// all four, a side's own shorthand such as `border-left` for that side,
/// and a side's colour written on its own taking the colour alone.
fn linesOf(node: *const Node) page_mod.BoxStyle.Lines {
    var lines = page_mod.BoxStyle.Lines{};
    if (valueOf(lexbor.Border, node, .border)) |all| {
        const line = lineOf(all);
        lines = .{ .top = line, .right = line, .bottom = line, .left = line };
    }
    const sides = [_]*page_mod.BoxStyle.Line{ &lines.top, &lines.right, &lines.bottom, &lines.left };
    const shorthands = [_]lexbor.Property{ .border_top, .border_right, .border_bottom, .border_left };
    const colours = [_]lexbor.Property{ .border_top_color, .border_right_color, .border_bottom_color, .border_left_color };
    for (sides, shorthands, colours) |side, shorthand, colour| {
        if (valueOf(lexbor.Border, node, shorthand)) |one| side.* = lineOf(one);
        if (valueOf(lexbor.Colour, node, colour)) |given| side.colour = colourOf(given);
    }
    return lines;
}

/// One side as a stylesheet writes it. No line where it is not drawn, or is
/// drawn in nothing; every way of drawing one is drawn as a solid line
/// here. A width unsaid is the middle one, as a stylesheet means it.
fn lineOf(border: *const lexbor.Border) page_mod.BoxStyle.Line {
    switch (border.style) {
        .undef, .none, .hidden => return .{},
        else => {},
    }
    const width: page_mod.Unit = switch (border.width.kind) {
        .thin => .{ .px = 1 },
        .undef, .medium => .{ .px = 3 },
        .thick => .{ .px = 5 },
        .length => switch (border.width.length.unit) {
            .undef, .px => .{ .px = @floatCast(border.width.length.num) },
            else => .auto,
        },
        else => .auto,
    };
    if (paintOf(&border.colour)) |given| {
        if (given == .transparent) return .{};
    }
    return .{ .width = width, .colour = colourOf(&border.colour) };
}

/// A colour value as one of the system's colours, or nothing where it is
/// the words' own or none.
fn colourOf(colour: *const lexbor.Colour) ?rgb.Colour {
    return switch (paintOf(colour) orelse return null) {
        .colour => |given| given,
        .current, .transparent => null,
    };
}

/// How far a box's corners are rounded, from `border-radius`, which
/// upstream keeps as written: the first length of it, read as a width.
fn radiusOf(node: *const Node) page_mod.Unit {
    const written = customValue(node, "border-radius") orelse return .auto;
    return lengthIn(cascadeOf(node).?.parser, "width", firstOf(written));
}

/// What the page wrote for a property upstream keeps by name, where it
/// wrote one: a gap, a radius or a grid's columns, which upstream does not
/// read.
fn customValue(node: *const Node, name: []const u8) ?[]const u8 {
    if (node.type != .element or cascadeOf(node) == null) return null;
    const declaration = lexbor.lxb_dom_element_style_by_name(node, name.ptr, name.len) orelse return null;
    const custom = customOf(declaration) orelse return null;
    return custom.value.slice();
}

/// The room on a box's four sides, from the `margin` or `padding` shorthand
/// where the page wrote one, with a longhand such as `margin-left` written on
/// its own taking the side it names.
fn edgesOf(node: *const Node, shorthand: lexbor.Property, longhands: [4]lexbor.Property) page_mod.BoxStyle.Edges {
    var edges = page_mod.BoxStyle.Edges{};
    if (valueOf(lexbor.Sides, node, shorthand)) |sides| edges = expanded(sides);
    const each = [_]*page_mod.Unit{ &edges.top, &edges.right, &edges.bottom, &edges.left };
    for (longhands, each) |property, side| {
        if (lengthMaybe(node, property)) |unit| side.* = unit;
    }
    return edges;
}

/// The four sides a shorthand gives, from the one to four values the page
/// wrote. Upstream keeps them in the order written, top, right, bottom and
/// left, and leaves the rest unwritten; a shorthand means one value for
/// every side, two for the top and bottom and the right and left, and
/// three leave the left its right's.
fn expanded(sides: *const lexbor.Sides) page_mod.BoxStyle.Edges {
    const written = [_]*const lexbor.LengthPercentage{ &sides.top, &sides.right, &sides.bottom, &sides.left };
    var count: usize = 0;
    while (count < written.len and written[count].kind != .undef) count += 1;
    const top = unitOf(written[0]);
    return switch (count) {
        0 => .{},
        1 => .{ .top = top, .right = top, .bottom = top, .left = top },
        2 => .{ .top = top, .right = unitOf(written[1]), .bottom = top, .left = unitOf(written[1]) },
        3 => .{ .top = top, .right = unitOf(written[1]), .bottom = unitOf(written[2]), .left = unitOf(written[1]) },
        else => .{ .top = top, .right = unitOf(written[1]), .bottom = unitOf(written[2]), .left = unitOf(written[3]) },
    };
}

fn displayOf(node: *const Node) ?page_mod.BoxStyle.Display {
    const display = valueOf(lexbor.Display, node, .display) orelse return null;
    for ([_]Keyword{ display.a, display.b, display.c }) |part| switch (part) {
        .flex, .inline_flex => return .flex,
        .grid, .inline_grid => return .grid,
        .block => return .block,
        .@"inline", .inline_block, .contents => return .@"inline",
        else => {},
    };
    return null;
}

fn lengthOf(node: *const Node, property: lexbor.Property) page_mod.Unit {
    return lengthMaybe(node, property) orelse .auto;
}

/// The length a property is set to, or nothing where it is not set: what
/// tells a side a shorthand gave from one a longhand takes for itself.
fn lengthMaybe(node: *const Node, property: lexbor.Property) ?page_mod.Unit {
    const length = valueOf(lexbor.LengthPercentage, node, property) orelse return null;
    return unitOf(length);
}

fn unitOf(length: *const lexbor.LengthPercentage) page_mod.Unit {
    return switch (length.kind) {
        .auto => .auto,
        .percentage => .{ .percent = @floatCast(length.value.percentage.num) },
        // A bare number is a length of nought, which a page writes as `0`.
        .number => .{ .px = @floatCast(length.value.percentage.num) },
        .length => switch (length.value.length.unit) {
            .undef, .px => .{ .px = @floatCast(length.value.length.num) },
            .em, .rem => .{ .em = @floatCast(length.value.length.num) },
            .vw => .{ .vw = @floatCast(length.value.length.num) },
            .vh => .{ .vh = @floatCast(length.value.length.num) },
            else => .auto,
        },
        else => .auto,
    };
}

/// Which way a flex container's items run: `flex-direction: column`, or
/// across it reversed, which this browser reads as across it; from the
/// `flex-flow` shorthand where the page wrote that instead.
fn directionOf(node: *const Node) page_mod.BoxStyle.Direction {
    const kind: Keyword = if (valueOf(lexbor.Single, node, .flex_direction)) |direction|
        direction.kind
    else if (valueOf(lexbor.FlexFlow, node, .flex_flow)) |flow|
        flow.direction
    else
        return .row;
    return switch (kind) {
        .column, .column_reverse => .column,
        else => .row,
    };
}

/// Whether a box is taken out of the flow: `position: absolute`, or `fixed`,
/// which this browser lays out where the box is rather than where the
/// window's edge is, but without room in the flow either way.
fn outOfFlow(node: *const Node) bool {
    const position = valueOf(lexbor.Single, node, .position) orelse return false;
    return position.kind == .absolute or position.kind == .fixed;
}

/// Whether a flex container's items go on to another row when they do not
/// fit: `flex-wrap`, or the `flex-flow` shorthand, wrapping either way up.
fn wrapOf(node: *const Node) bool {
    const kind: Keyword = if (valueOf(lexbor.Single, node, .flex_wrap)) |wrap|
        wrap.kind
    else if (valueOf(lexbor.FlexFlow, node, .flex_flow)) |flow|
        flow.wrap
    else
        return false;
    return kind == .wrap or kind == .wrap_reverse;
}

/// How a flex item grows, shrinks and what it starts from.
const Flexing = struct { grow: f32 = 0, shrink: f32 = 1, basis: page_mod.Unit = .auto };

/// The `flex` shorthand, then the longhands written on their own. In the
/// shorthand a growth written alone starts the item from nothing, a start
/// written alone lets it grow, and `none` holds it at what it starts from.
fn flexOf(node: *const Node) Flexing {
    var flexing = Flexing{};
    if (valueOf(lexbor.Flex, node, .flex)) |flex| switch (flex.kind) {
        .undef => {
            const grown = flex.grow.kind != .undef;
            flexing.grow = if (grown) @floatCast(flex.grow.number.num) else 1;
            flexing.shrink = if (flex.shrink.kind != .undef) @floatCast(flex.shrink.number.num) else 1;
            flexing.basis = if (flex.basis.kind != .undef) unitOf(&flex.basis) else if (grown) .{ .px = 0 } else .auto;
        },
        .none => flexing = .{ .grow = 0, .shrink = 0, .basis = .auto },
        else => {},
    };
    if (valueOf(lexbor.NumberType, node, .flex_grow)) |grow| flexing.grow = @floatCast(grow.number.num);
    if (valueOf(lexbor.NumberType, node, .flex_shrink)) |shrink| flexing.shrink = @floatCast(shrink.number.num);
    if (lengthMaybe(node, .flex_basis)) |basis| flexing.basis = basis;
    return flexing;
}

/// Where a flex container's items go along its main axis, as
/// `justify-content` says: `space-between` puts the room it has left between
/// them, and anything else this browser does not spread leaves them at its
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

/// Where they go across it, as `align-items` says: stretched to the row
/// where it says nothing, or something this browser does not tell apart.
fn itemsOf(node: *const Node) page_mod.BoxStyle.Items {
    const items = valueOf(lexbor.Single, node, .align_items) orelse return .stretch;
    return crossOf(items.kind) orelse .stretch;
}

/// Where a box puts itself across its container's axis, as `align-self`
/// says; nothing where it takes the container's word.
fn selfOf(node: *const Node) ?page_mod.BoxStyle.Items {
    const self_align = valueOf(lexbor.Single, node, .align_self) orelse return null;
    return crossOf(self_align.kind);
}

fn crossOf(kind: Keyword) ?page_mod.BoxStyle.Items {
    return switch (kind) {
        .start, .flex_start => .start,
        .center => .center,
        .end, .flex_end => .end,
        .stretch => .stretch,
        else => null,
    };
}

/// The columns a grid names, from `grid-template-columns`, which upstream
/// keeps as written: each a length read as a width, a share in `fr`, or
/// `auto` and its kin, which are a share; `repeat()` names a run of them,
/// and with `auto-fill` or `auto-fit` as many of one least width as fit.
fn tracksOf(node: *const Node) page_mod.Tracks {
    var tracks = page_mod.Tracks{};
    var rest = customValue(node, "grid-template-columns") orelse return tracks;
    const parser = cascadeOf(node).?.parser;
    while (nextTerm(&rest)) |term| addTracks(&tracks, parser, term);
    return tracks;
}

/// The tracks one term names: one, or the run a `repeat()` names.
fn addTracks(tracks: *page_mod.Tracks, parser: *lexbor.CssParser, term: []const u8) void {
    if (functionOf(term, "repeat")) |inside| {
        const comma = std.mem.indexOfScalar(u8, inside, ',') orelse return;
        const count = std.mem.trim(u8, inside[0..comma], &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(count, "auto-fill") or std.ascii.eqlIgnoreCase(count, "auto-fit")) {
            var listed = inside[comma + 1 ..];
            tracks.fit = leastOf(parser, nextTerm(&listed) orelse return);
            return;
        }
        for (0..std.fmt.parseInt(usize, count, 10) catch return) |_| {
            var listed = inside[comma + 1 ..];
            while (nextTerm(&listed)) |each| tracks.named.append(trackOf(parser, each)) catch return;
        }
        return;
    }
    tracks.named.append(trackOf(parser, term)) catch {};
}

/// One track: a share, or a length. A `minmax(least, most)` is its most
/// where that is a share, and its least otherwise.
fn trackOf(parser: *lexbor.CssParser, term: []const u8) page_mod.Track {
    if (functionOf(term, "minmax")) |inside| {
        const comma = std.mem.indexOfScalar(u8, inside, ',') orelse return .{ .share = 1 };
        const most = std.mem.trim(u8, inside[comma + 1 ..], &std.ascii.whitespace);
        if (shareOf(most)) |share| return .{ .share = share };
        return trackOf(parser, std.mem.trim(u8, inside[0..comma], &std.ascii.whitespace));
    }
    if (shareOf(term)) |share| return .{ .share = share };
    for ([_][]const u8{ "auto", "max-content", "min-content" }) |word| {
        if (std.ascii.eqlIgnoreCase(term, word)) return .{ .share = 1 };
    }
    return .{ .length = lengthIn(parser, "width", term) };
}

/// The least width of a `minmax()`, or of a plain length, which is what as
/// many columns as fit are counted by.
fn leastOf(parser: *lexbor.CssParser, term: []const u8) page_mod.Unit {
    if (functionOf(term, "minmax")) |inside| {
        const comma = std.mem.indexOfScalar(u8, inside, ',') orelse return .auto;
        return lengthIn(parser, "width", std.mem.trim(u8, inside[0..comma], &std.ascii.whitespace));
    }
    return lengthIn(parser, "width", term);
}

/// A share of the room, written `2fr`.
fn shareOf(term: []const u8) ?f32 {
    if (term.len < 3 or !std.ascii.endsWithIgnoreCase(term, "fr")) return null;
    return std.fmt.parseFloat(f32, term[0 .. term.len - 2]) catch null;
}

/// What is inside `name(...)`, where `term` is that function.
fn functionOf(term: []const u8, name: []const u8) ?[]const u8 {
    if (term.len < name.len + 2 or !std.ascii.startsWithIgnoreCase(term, name)) return null;
    if (term[name.len] != '(' or term[term.len - 1] != ')') return null;
    return term[name.len + 1 .. term.len - 1];
}

/// The next term of a value, and the rest after it: a term ends at a space
/// outside any parentheses, so a `repeat()` with spaces inside is one term.
fn nextTerm(rest: *[]const u8) ?[]const u8 {
    const text = std.mem.trimStart(u8, rest.*, &std.ascii.whitespace);
    if (text.len == 0) return null;
    var depth: usize = 0;
    var end: usize = 0;
    while (end < text.len) : (end += 1) {
        switch (text[end]) {
            '(' => depth += 1,
            ')' => depth -|= 1,
            ' ', '\t', '\n', '\r' => if (depth == 0) break,
            else => {},
        }
    }
    rest.* = text[end..];
    return text[0..end];
}

/// How many of a grid's columns a box spans, from `grid-column`: `span n`,
/// or the lines it runs from and to, `a / b`, with `-1` the row's end.
fn spanOf(node: *const Node) u8 {
    const written = customValue(node, "grid-column") orelse return 1;
    var words = std.mem.tokenizeAny(u8, written, " \t/");
    var from: ?i32 = null;
    var span: ?i32 = null;
    var spanning = false;
    while (words.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "span")) {
            spanning = true;
            continue;
        }
        const n = std.fmt.parseInt(i32, word, 10) catch {
            spanning = false;
            continue;
        };
        if (spanning) {
            span = n;
        } else if (from == null) {
            from = n;
        } else if (n == -1) {
            span = std.math.maxInt(u8);
        } else if (n > from.?) {
            span = n - from.?;
        }
        spanning = false;
    }
    return @intCast(std.math.clamp(span orelse 1, 1, std.math.maxInt(u8)));
}

/// The room a flex or grid container leaves between its items, from `gap`,
/// or from `row-gap` or `column-gap` alone where only one of them is
/// written, or from the names the grid's gap went by before.
/// Upstream reads none of the three, so the value is kept as it was written
/// and read back as the length of a `width`.
fn gapOf(node: *const Node) page_mod.Unit {
    for (GAPS) |name| {
        const written = customValue(node, name) orelse continue;
        return lengthIn(cascadeOf(node).?.parser, "width", firstOf(written));
    }
    return .auto;
}

/// The names a gap may be written under, the last three being what the
/// grid's gap was called before it was every container's.
const GAPS = [_][]const u8{ "gap", "row-gap", "column-gap", "grid-gap", "grid-row-gap", "grid-column-gap" };

/// Whether a property upstream keeps by name is one a gap may be written
/// under.
fn isGap(name: []const u8) bool {
    for (GAPS) |gap| {
        if (std.ascii.eqlIgnoreCase(name, gap)) return true;
    }
    return false;
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
/// browser's noise, not the page's.
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
/// media its link names.
pub const Sheets = links.Queue(SHEETS_MAX, SHEETS_BYTES_MAX);

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

/// The rules that give a page's tree its styles, in the order they were
/// applied, which is the order the cascade weighs them in where two are of
/// the same weight: the rules of the page's own style elements, which the
/// tree applied for itself, and then those of its linked sheets that this
/// browser honours. They live in the document's own memory and go with it.
/// Beside each rule are the names its selectors read, so that when a script
/// changes an element's class, id or an attribute, only the rules that read
/// that name are matched again.
pub const Rules = struct {
    list: std.ArrayList(*lexbor.StyleRule) = .empty,
    /// For each rule, its run of names in `names`.
    reads: std.ArrayList(Reads) = .empty,
    /// The names the rules' selectors read, hashed, each rule's together.
    names: std.ArrayList(u64) = .empty,

    const Reads = struct { first: u32, count: u32 };

    pub fn deinit(self: *Rules, gpa: Allocator) void {
        self.list.deinit(gpa);
        self.reads.deinit(gpa);
        self.names.deinit(gpa);
        self.* = .{};
    }

    /// Keep a rule, with the names its selectors read.
    fn add(self: *Rules, gpa: Allocator, rule: *lexbor.StyleRule) void {
        const first: u32 = @intCast(self.names.items.len);
        if (rule.selector) |list| readNames(gpa, &self.names, list, 0);
        self.list.append(gpa, rule) catch {
            self.names.shrinkRetainingCapacity(first);
            return;
        };
        self.reads.append(gpa, .{ .first = first, .count = @intCast(self.names.items.len - first) }) catch {
            _ = self.list.pop();
            self.names.shrinkRetainingCapacity(first);
        };
    }

    /// Whether the rule at `index` reads `name`.
    fn readsName(self: *const Rules, index: usize, hashed: u64) bool {
        const reads = self.reads.items[index];
        for (self.names.items[reads.first..][0..reads.count]) |name| {
            if (name == hashed) return true;
        }
        return false;
    }
};

/// The names a selector list reads, into `names`: each class, id and
/// attribute in it, and in the lists inside its pseudo-class functions,
/// `:not()` and `:is()` among them, and the `of` an `:nth-child()` names.
fn readNames(gpa: Allocator, names: *std.ArrayList(u64), list: *const lexbor.SelectorList, depth: u32) void {
    if (depth > 8) return;
    var each: ?*const lexbor.SelectorList = list;
    while (each) |one| : (each = one.next) {
        var part: ?*const lexbor.Selector = one.first;
        while (part) |selector| : (part = selector.next) {
            switch (selector.type) {
                .id, .class, .attribute => names.append(gpa, std.hash_map.hashString(selector.name.slice())) catch return,
                .pseudo_class_function => if (selector.u.pseudo.data) |data| switch (selector.function()) {
                    .current, .has, .is, .not, .where => readNames(gpa, names, @ptrCast(@alignCast(data)), depth + 1),
                    .nth_child, .nth_col, .nth_last_child, .nth_last_col, .nth_last_of_type, .nth_of_type => {
                        const anb_of: *const lexbor.AnbOf = @ptrCast(@alignCast(data));
                        if (anb_of.of) |of| readNames(gpa, names, of, depth + 1);
                    },
                    .undef, .dir, .lang, .lexbor_contains, _ => {},
                },
                else => {},
            }
        }
    }
}

/// Keep the rules of the sheets the page's own style elements gave the
/// tree, which the tree applied for itself as it was parsed, so that they
/// are matched again beside the linked sheets' where a script changes what
/// an element is.
pub fn harvest(gpa: Allocator, document: *lexbor.Document, rules: *Rules) void {
    const cascade = lexbor.domOf(document).css orelse return;
    const sheets = cascade.stylesheets orelse return;
    for (0..lexbor.lexbor_array_length_noi(sheets)) |index| {
        const sheet: *const lexbor.Stylesheet = @ptrCast(@alignCast(lexbor.lexbor_array_get_noi(sheets, index) orelse continue));
        const root = sheet.root orelse continue;
        if (root.kind != .list) continue;
        const list: *const lexbor.RuleList = @fieldParentPtr("rule", root);
        var at = list.first;
        while (at) |rule| : (at = rule.next) {
            if (rule.kind != .style) continue;
            rules.add(gpa, @fieldParentPtr("rule", rule));
        }
    }
}

/// Apply a stylesheet to `document` as it reads on `screen`: its rules for
/// the window, and of those only the ones that say something this browser
/// draws or retains for box layout. The rules applied are added to `rules`.
pub fn apply(gpa: Allocator, document: *lexbor.Document, text: []const u8, screen: ?media.Screen, rules: *Rules) void {
    const dom = lexbor.domOf(document);
    const cascade = dom.css orelse return;

    // Handed over with its media blocks resolved, since the top of a sheet
    // is where upstream reads every rule whole. Resolving only ever leaves
    // text out, so the sheet's own length is room enough.
    const flat = gpa.alloc(u8, text.len) catch return;
    defer gpa.free(flat);
    var w: std.Io.Writer = .fixed(flat);
    media.flatten(text, screen, &w) catch return;
    const flattened = w.buffered();
    // And with what its variables stand for written where they are used,
    // since upstream reads `var()` as nothing.
    var replaced = substituted(gpa, flattened) catch return;
    defer replaced.deinit(gpa);
    const written = if (replaced.items.len > 0) replaced.items else flattened;

    const sheet = lexbor.lxb_css_stylesheet_create(cascade.memory) orelse return;
    if (lexbor.lxb_css_stylesheet_parse(sheet, cascade.parser, written.ptr, written.len) != .ok) return;
    const root = sheet.root orelse return;
    if (root.kind != .list) return;
    const list: *const lexbor.RuleList = @fieldParentPtr("rule", root);
    var at = list.first;
    while (at) |rule| : (at = rule.next) {
        if (rule.kind != .style) continue;
        const style: *lexbor.StyleRule = @fieldParentPtr("rule", rule);
        if (!honoured(style)) continue;
        _ = lexbor.lxb_dom_document_style_attach(dom, style);
        rules.add(gpa, style);
    }
}

/// The sheet with every `var()` replaced by what the variable stands for:
/// what the sheet's `:root` and `html` rules set it to, the last setting
/// winning, or the fallback the `var()` names where they set nothing. A
/// variable set on any other element is not read, so a theme a page keeps
/// on a class reads as the page's first. Empty where the sheet uses no
/// variable, which leaves it as it is.
fn substituted(gpa: Allocator, sheet: []const u8) Allocator.Error!std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    if (std.mem.indexOf(u8, sheet, "var(") == null) return out;
    var variables = Variables{};
    defer variables.deinit(gpa);
    try variables.gather(gpa, sheet);
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, sheet.len);
    try variables.write(gpa, sheet, &out, 0);
    return out;
}

/// What a sheet's variables stand for, by name.
const Variables = struct {
    values: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// How deep a variable may stand for another before it is left unread.
    const DEPTH_MAX = 8;

    fn deinit(self: *Variables, gpa: Allocator) void {
        self.values.deinit(gpa);
    }

    /// Read the `--name: value` declarations of every `:root` and `html`
    /// rule, into the blocks an `@supports` or `@layer` holds, the later
    /// setting of a name replacing the earlier.
    fn gather(self: *Variables, gpa: Allocator, sheet: []const u8) Allocator.Error!void {
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, sheet, at, '{')) |open| {
            const close = closing(sheet, open) orelse return;
            const selector = std.mem.trim(u8, sheet[at..open], &std.ascii.whitespace);
            const inside = sheet[open + 1 .. close];
            if (selector.len > 0 and selector[0] == '@') {
                if (std.ascii.startsWithIgnoreCase(selector, "@supports") or std.ascii.startsWithIgnoreCase(selector, "@layer")) try self.gather(gpa, inside);
            } else if (isRoot(selector)) {
                var declarations = std.mem.splitScalar(u8, inside, ';');
                while (declarations.next()) |declaration| {
                    const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse continue;
                    const name = std.mem.trim(u8, declaration[0..colon], &std.ascii.whitespace);
                    if (!std.mem.startsWith(u8, name, "--")) continue;
                    try self.values.put(gpa, name, std.mem.trim(u8, declaration[colon + 1 ..], &std.ascii.whitespace));
                }
            }
            at = close + 1;
        }
    }

    /// Whether a rule's selectors name the root, alone or among others.
    fn isRoot(selector: []const u8) bool {
        var each = std.mem.splitScalar(u8, selector, ',');
        while (each.next()) |one| {
            const name = std.mem.trim(u8, one, &std.ascii.whitespace);
            if (std.mem.eql(u8, name, ":root") or std.ascii.eqlIgnoreCase(name, "html")) return true;
        }
        return false;
    }

    /// Write `text` into `out` with each `var()` in it replaced, as deep as
    /// a variable stands for another.
    fn write(self: *const Variables, gpa: Allocator, text: []const u8, out: *std.ArrayList(u8), depth: usize) Allocator.Error!void {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, "var(")) |found| {
            try out.appendSlice(gpa, text[at..found]);
            const close = closing(text, found + 3) orelse {
                at = found;
                break;
            };
            const inside = text[found + 4 .. close];
            const comma = std.mem.indexOfScalar(u8, inside, ',');
            const name = std.mem.trim(u8, if (comma) |c| inside[0..c] else inside, &std.ascii.whitespace);
            if (self.values.get(name)) |value| {
                if (depth < DEPTH_MAX) try self.write(gpa, value, out, depth + 1) else try out.appendSlice(gpa, value);
            } else if (comma) |c| {
                try self.write(gpa, std.mem.trim(u8, inside[c + 1 ..], &std.ascii.whitespace), out, depth + 1);
            } else {
                try out.appendSlice(gpa, text[found .. close + 1]);
            }
            at = close + 1;
        }
        try out.appendSlice(gpa, text[at..]);
    }

    /// Where the parenthesis or brace opened at `open` closes, counting the
    /// ones inside it, or nothing where it never does.
    fn closing(text: []const u8, open: usize) ?usize {
        const shut: u8 = if (text[open] == '{') '}' else ')';
        var depth: usize = 0;
        for (text[open..], open..) |c, index| {
            if (c == '{' or c == '(') depth += 1;
            if (c == '}' or c == ')') {
                depth -= 1;
                if (depth == 0) return if (c == shut) index else null;
            }
        }
        return null;
    }
};

/// Match every rule again against `root` and everything under it, as a
/// browser does where a script has put a piece of page in: what the sheets
/// gave each element goes, what it wrote on the element itself stays, and
/// the rules that fit now are applied in their order, each with the
/// tree's own matching walk.
pub fn restyle(document: *lexbor.Document, rules: *const Rules, root: *lexbor.Node) void {
    const cascade = lexbor.domOf(document).css orelse return;
    const engine = cascade.selectors orelse return;
    var at: ?*lexbor.Node = root;
    while (at) |node| : (at = lexbor.following(node, root)) {
        if (node.type == .element) _ = lexbor.lxb_dom_element_style_remove_non_inline(node);
    }
    // The root is one of the elements matched again, not only what is
    // under it: a piece of page put in is matched from its own top.
    lexbor.lxb_selectors_opt_set_noi(engine, lexbor.SELECTORS_MATCH_ROOT);
    for (rules.list.items) |rule| {
        const selector = rule.selector orelse continue;
        _ = lexbor.lxb_selectors_find(engine, root, @ptrCast(selector), &attachTo, rule);
    }
}

/// Give a matched element what a rule declares, as the tree does when it
/// applies a sheet.
fn attachTo(node: *lexbor.Node, specificity: u32, taken: ?*anyopaque) callconv(.c) lexbor.Status {
    const rule: *lexbor.StyleRule = @ptrCast(@alignCast(taken));
    const declarations = rule.declarations orelse return .ok;
    return lexbor.lxb_dom_element_style_list_append(node, declarations, specificity);
}

/// What a script is about to change or has changed an element's `name` to
/// or from: the rules that read it are unmatched while the old value still
/// holds, and matched again once the new one does, and no other rule is
/// touched. `unmatch` goes before the change and `rematch` after it.
pub fn unmatch(document: *lexbor.Document, rules: *const Rules, name: []const u8) void {
    const dom = lexbor.domOf(document);
    const hashed = std.hash_map.hashString(name);
    for (rules.list.items, 0..) |rule, index| {
        if (rules.readsName(index, hashed)) _ = lexbor.lxb_dom_document_style_remove(dom, rule);
    }
}

pub fn rematch(document: *lexbor.Document, rules: *const Rules, name: []const u8) void {
    const dom = lexbor.domOf(document);
    const hashed = std.hash_map.hashString(name);
    for (rules.list.items, 0..) |rule, index| {
        if (rules.readsName(index, hashed)) _ = lexbor.lxb_dom_document_style_attach(dom, rule);
    }
}

/// Whether a rule says anything this browser draws or retains for box layout.
fn honoured(style: *const lexbor.StyleRule) bool {
    const list = style.declarations orelse return false;
    var at = list.first;
    while (at) |rule| : (at = rule.next) {
        if (rule.kind != .declaration) continue;
        const declaration: *const lexbor.Declaration = @fieldParentPtr("rule", rule);
        switch (declaration.property) {
            .display, .position, .width, .height, .min_width, .min_height, .max_width, .max_height, .flex, .flex_basis, .flex_direction, .flex_flow, .flex_grow, .flex_shrink, .flex_wrap, .justify_content, .align_items, .align_self, .visibility, .opacity, .color, .background_color, .text_align, .white_space, .margin, .margin_top, .margin_right, .margin_bottom, .margin_left, .padding, .padding_top, .padding_right, .padding_bottom, .padding_left, .border, .border_top, .border_right, .border_bottom, .border_left, .border_top_color, .border_right_color, .border_bottom_color, .border_left_color => return true,
            .custom => {
                const custom = customOf(declaration) orelse continue;
                const name = custom.name.slice();
                if (std.ascii.eqlIgnoreCase(name, "background") or
                    std.ascii.eqlIgnoreCase(name, "list-style-type") or
                    std.ascii.eqlIgnoreCase(name, "list-style") or
                    std.ascii.eqlIgnoreCase(name, "border-radius") or
                    std.ascii.eqlIgnoreCase(name, "grid-template-columns") or
                    std.ascii.eqlIgnoreCase(name, "grid-column") or
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
