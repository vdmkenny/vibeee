//! What the HTML parser offers, as this program calls it.
//!
//! The parser is C, vendored under `third_party/lexbor` and compiled into
//! this program the way netd compiles lwIP into itself. Only the calls used
//! are declared: a header translated whole would carry a thousand names for
//! the sake of the dozen that are wanted, and every one of them would be a
//! shape to keep in step with an upstream nobody here reads.
//!
//! Nothing below allocates on this side. The parser owns every pointer it
//! answers with, and a document destroyed takes all of them with it, which
//! is why the text a walk collects is copied out before the document goes.

const std = @import("std");

/// Every call answers with one of these. Zero is the only one that means it
/// worked. Of the rest only running out of memory is named, because it is
/// the one a person can do something about; every other failure means the
/// page could not be read.
pub const Status = enum(c_uint) {
    ok = 0,
    no_memory = 2,
    _,
};

/// What a node is. The tree a page parses into is mostly the first two.
pub const NodeType = enum(c_int) {
    undef = 0,
    element = 1,
    attribute = 2,
    text = 3,
    cdata_section = 4,
    entity_reference = 5,
    entity = 6,
    processing_instruction = 7,
    comment = 8,
    document = 9,
    document_type = 10,
    document_fragment = 11,
    notation = 12,
    last_entry = 13,
    _,
};

pub const Document = opaque {};

/// The elements this reader has a rule for, numbered as upstream numbers
/// them: an element's `local_name` is its number. Every value is pinned
/// against upstream's own constant in `lexborport/layout_check.c`, so a
/// renumbering upstream fails the build rather than turning paragraphs into
/// something else.
///
/// A tag not named here is not unknown to the parser. It is one this reader
/// has no separate rule for, and its words read as the text around them.
pub const Tag = enum(usize) {
    a = 0x0007,
    address = 0x000a,
    article = 0x0014,
    aside = 0x0015,
    b = 0x0017,
    base = 0x0018,
    blockquote = 0x001f,
    body = 0x0020,
    br = 0x0021,
    button = 0x0022,
    canvas = 0x0023,
    caption = 0x0024,
    center = 0x0025,
    code = 0x0028,
    dd = 0x002d,
    details = 0x0030,
    div = 0x0034,
    dl = 0x0035,
    dt = 0x0036,
    em = 0x0037,
    fieldset = 0x0052,
    figcaption = 0x0053,
    figure = 0x0054,
    font = 0x0055,
    footer = 0x0056,
    form = 0x0058,
    h1 = 0x005c,
    h2 = 0x005d,
    h3 = 0x005e,
    h4 = 0x005f,
    h5 = 0x0060,
    h6 = 0x0061,
    head = 0x0062,
    header = 0x0063,
    hr = 0x0065,
    html = 0x0066,
    i = 0x0067,
    iframe = 0x0068,
    img = 0x006a,
    input = 0x006b,
    kbd = 0x006e,
    li = 0x0072,
    link = 0x0074,
    main = 0x0076,
    math = 0x007b,
    nav = 0x0087,
    noscript = 0x008c,
    ol = 0x008e,
    option = 0x0090,
    p = 0x0092,
    pre = 0x0097,
    samp = 0x00a1,
    script = 0x00a2,
    section = 0x00a4,
    select = 0x00a5,
    strong = 0x00ad,
    style = 0x00ae,
    summary = 0x00b0,
    svg = 0x00b2,
    table = 0x00b3,
    td = 0x00b5,
    template = 0x00b6,
    textarea = 0x00b7,
    th = 0x00ba,
    thead = 0x00bb,
    title = 0x00bd,
    tr = 0x00be,
    tt = 0x00c0,
    ul = 0x00c2,
    @"var" = 0x00c3,
    _,
};

/// A node, field for field in upstream's order.
///
/// `type` is its last field, so this is the whole of upstream's struct and a
/// text node's words sit straight after it. Both sides pin that: the sizes
/// and offsets below, and `lexborport/layout_check.c` against the headers.
pub const Node = extern struct {
    /// The event target upstream puts first: one pointer this side never
    /// follows.
    event_target: ?*anyopaque,

    local_name: usize,
    prefix: usize,
    ns: usize,

    owner_document: ?*Document,

    next: ?*Node,
    prev: ?*Node,
    parent: ?*Node,
    first_child: ?*Node,
    last_child: ?*Node,
    user: ?*anyopaque,

    type: NodeType,
};

pub extern fn lxb_html_document_create() ?*Document;
pub extern fn lxb_html_document_destroy(document: *Document) ?*Document;
pub extern fn lxb_html_document_parse(document: *Document, html: [*]const u8, size: usize) Status;
pub extern fn lxb_html_document_title(document: *Document, len: *usize) ?[*]const u8;

pub extern fn lxb_dom_element_get_attribute(element: *Node, name: [*]const u8, name_len: usize, value_len: *usize) ?[*]const u8;
pub extern fn lxb_dom_element_has_attribute(element: *Node, name: [*]const u8, name_len: usize) bool;

/// A string as upstream keeps one: a pointer and a length.
pub const Str = extern struct {
    data: ?[*]const u8,
    length: usize,

    pub fn slice(self: Str) []const u8 {
        const data = self.data orelse return "";
        return data[0..self.length];
    }
};

/// A text node: a node, and its words straight after it.
const CharacterData = extern struct {
    node: Node,
    data: Str,
};

/// The words a text node holds, read where the parser keeps them.
///
/// Read in place rather than through upstream's call for a node's text,
/// which makes a copy of every text node it is asked about and keeps each
/// until the document goes: a page's worth of words held twice for the
/// length of the walk, on a machine where that is the difference that
/// matters.
pub fn wordsOf(node: *const Node) []const u8 {
    std.debug.assert(node.type == .text);
    const text: *const CharacterData = @fieldParentPtr("node", node);
    return text.data.slice();
}

/// An attribute's value, or nothing where the element has none. One written
/// without a value, as `checked` and `hidden` are, has the empty one: the
/// parser keeps no value for it at all, which reads as absent unless asked
/// about separately.
pub fn attribute(node: *Node, name: []const u8) ?[]const u8 {
    std.debug.assert(node.type == .element);
    var len: usize = 0;
    if (lxb_dom_element_get_attribute(node, name.ptr, name.len, &len)) |value| return value[0..len];
    return if (hasAttribute(node, name)) "" else null;
}

/// Whether an element has an attribute at all, whatever its value.
pub fn hasAttribute(node: *Node, name: []const u8) bool {
    return lxb_dom_element_has_attribute(node, name.ptr, name.len);
}

/// Whether an element's attribute is `value`, compared as HTML compares a
/// keyword: without regard to case.
pub fn attributeIs(node: *Node, name: []const u8, value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(attribute(node, name) orelse return false, value);
}

/// Whether an attribute written as words apart by spaces, as `rel` is, has
/// `word` among them, compared without regard to case.
pub fn attributeHas(node: *Node, name: []const u8, word: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, attribute(node, name) orelse return false, &std.ascii.whitespace);
    while (words.next()) |each| {
        if (std.ascii.eqlIgnoreCase(each, word)) return true;
    }
    return false;
}

/// Every interface begins with a node, which is what upstream's own
/// `lxb_dom_interface_node` says by casting rather than by reaching.
pub fn nodeOf(interface: anytype) *Node {
    return @ptrCast(@alignCast(interface));
}

/// The node after `node` in document order, going no further than `root`.
///
/// What every walk of a tree here steps with. A page can nest thousands
/// deep, a stack frame per level is a stack this machine does not have to
/// spare, and a walk that follows the tree's own links needs no stack at all.
pub fn following(node: *Node, root: *Node) ?*Node {
    if (node.first_child) |child| return child;
    var at = node;
    while (at != root) {
        if (at.next) |sibling| return sibling;
        at = at.parent orelse return null;
    }
    return null;
}

comptime {
    // This side of the layout `lexborport/layout_check.c` pins on the other.
    const word = @sizeOf(usize);
    if (@offsetOf(Node, "local_name") != word) @compileError("a node does not begin with one pointer");
    if (@offsetOf(Node, "owner_document") != 4 * word) @compileError("the names are not three words");
    if (@offsetOf(Node, "type") != 11 * word) @compileError("the head of a node is not eleven words");
    if (@sizeOf(Node) != 12 * word) @compileError("a node is not twelve words");
    if (@offsetOf(CharacterData, "data") != 12 * word) @compileError("a text node's words do not follow its node");
}

/// What element this node is, or nothing where it is not one.
pub fn tagOf(node: *const Node) ?Tag {
    if (node.type != .element) return null;
    return @enumFromInt(node.local_name);
}

/// The document's title, or nothing where the page gave none.
pub fn titleOf(document: *Document) ?[]const u8 {
    var len: usize = 0;
    const text = lxb_html_document_title(document, &len) orelse return null;
    return text[0..len];
}

// ---------------------------------------------------------------------------
// The cascade
//
// Upstream's `style` module applies a page's stylesheets as the tree is
// built: every `style` attribute and `<style>` element, once its hooks are in
// the parser. A sheet fetched from elsewhere is parsed and its rules applied
// when it is handed over. What an element ends up with is then asked of it
// one property at a time, cascade and all.
// ---------------------------------------------------------------------------

/// Put the cascade's hooks in the parser. Before the document is parsed.
pub extern fn lxb_style_init(document: *Document) Status;
/// Take them out again, and the cascade's memory with them.
pub extern fn lxb_style_destroy(document: *Document) void;

/// What the cascade gave an element for one property, or nothing where no
/// rule said.
pub extern fn lxb_dom_element_style_by_id(element: *const Node, property: Property) ?*const Declaration;
/// The same, for a property upstream has no number of its own for, by name.
pub extern fn lxb_dom_element_style_by_name(element: *const Node, name: [*]const u8, len: usize) ?*const Declaration;

pub extern fn lxb_css_stylesheet_create(memory: ?*CssMemory) ?*Stylesheet;
pub extern fn lxb_css_stylesheet_parse(sheet: *Stylesheet, parser: *CssParser, data: [*]const u8, len: usize) Status;
/// Read declarations written out the way a `style` attribute writes them.
pub extern fn lxb_css_declaration_list_parse(parser: *CssParser, data: [*]const u8, len: usize) ?*DeclarationList;
/// Apply one rule to every element its selectors match.
pub extern fn lxb_dom_document_style_attach(document: *DomDocument, rule: *StyleRule) Status;

pub const CssMemory = opaque {};
pub const CssParser = opaque {};
pub const SelectorList = opaque {};

/// The properties this reader acts on, numbered as upstream numbers them.
pub const Property = enum(usize) {
    /// One upstream does not read, kept by name with its value as written.
    custom = 0x0001,
    background_color = 0x0006,
    color = 0x0015,
    display = 0x0017,
    opacity = 0x003e,
    text_align = 0x004d,
    visibility = 0x005d,
    white_space = 0x005e,
    _,
};

/// The keywords and kinds of value this reader tells apart, numbered as
/// upstream numbers them. Anything else is a value it does not act on.
pub const Keyword = enum(c_uint) {
    center = 0x0007,
    percentage = 0x0015,
    none = 0x001f,
    hidden = 0x0020,
    left = 0x002f,
    right = 0x0030,
    current_color = 0x0031,
    transparent = 0x0032,
    hex = 0x0033,
    rgb = 0x00db,
    rgba = 0x00dc,
    @"inline" = 0x00e8,
    contents = 0x00fd,
    inline_block = 0x00fe,
    number = 0x0108,
    start = 0x010d,
    end = 0x010e,
    justify = 0x014a,
    collapse = 0x0165,
    pre = 0x0166,
    pre_wrap = 0x0167,
    _,

    /// Upstream's named colours are keywords in a run, in alphabetical
    /// order from `aliceblue` to `yellowgreen`.
    pub const named_first: c_uint = 0x0034;
    pub const named_last: c_uint = 0x00c7;

    /// Which named colour this is, counted from `aliceblue`, where it is one.
    pub fn named(self: Keyword) ?usize {
        const value = @intFromEnum(self);
        if (value < named_first or value > named_last) return null;
        return value - named_first;
    }
};

/// A document as the DOM keeps one, up to where it keeps its cascade.
/// Mirrored as far as that and no further: nothing past it is read.
pub const DomDocument = extern struct {
    node: Node,
    compat_mode: c_uint,
    kind: c_uint,
    doctype: ?*anyopaque,
    element: ?*anyopaque,
    create_interface: ?*const anyopaque,
    clone_interface: ?*const anyopaque,
    destroy_interface: ?*const anyopaque,
    mutation: ?*const anyopaque,
    attr_mutation: ?*const anyopaque,
    mraw: ?*anyopaque,
    text: ?*anyopaque,
    tags: ?*anyopaque,
    attrs: ?*anyopaque,
    prefix: ?*anyopaque,
    ns: ?*anyopaque,
    parser: ?*anyopaque,
    user: ?*anyopaque,
    css: ?*DocumentCss,
};

/// An HTML document begins with the DOM's document, which is what
/// upstream's own `lxb_dom_interface_document` says by casting.
pub fn domOf(document: *Document) *DomDocument {
    return @ptrCast(@alignCast(document));
}

/// The cascade's state on a document: the memory its rules live in and the
/// parser that reads them. Only its head is mirrored, which is what is read.
pub const DocumentCss = extern struct {
    memory: *CssMemory,
    css_selectors: ?*anyopaque,
    parser: *CssParser,
};

pub const RuleKind = enum(c_uint) {
    undef,
    stylesheet,
    list,
    at_rule,
    style,
    bad_style,
    declaration_list,
    declaration,
    _,
};

/// What every rule begins with: its kind, and its place among its siblings.
pub const Rule = extern struct {
    kind: RuleKind,
    next: ?*Rule,
    prev: ?*Rule,
    parent: ?*Rule,
    memory: ?*CssMemory,
    ref_count: usize,
};

pub const RuleList = extern struct {
    rule: Rule,
    first: ?*Rule,
    last: ?*Rule,
};

/// Selectors, and what an element they match is given.
pub const StyleRule = extern struct {
    rule: Rule,
    selector: ?*SelectorList,
    declarations: ?*DeclarationList,
    child: ?*RuleList,
    prelude_begin: usize,
    prelude_end: usize,
};

pub const DeclarationList = extern struct {
    rule: Rule,
    first: ?*Rule,
    last: ?*Rule,
    count: usize,
};

/// One property and its value, which is a pointer to whatever shape the
/// property's values take.
pub const Declaration = extern struct {
    rule: Rule,
    property: Property,
    value: ?*const anyopaque,
    offset: [6]usize,
    important: bool,
};

/// What a declaration of a property upstream does not read holds: its name,
/// and its value as the sheet wrote it.
pub const Custom = extern struct { name: Str, value: Str };

pub const Stylesheet = extern struct {
    root: ?*Rule,
    memory: ?*CssMemory,
    element: ?*anyopaque,
};

/// `display`, as its three keywords.
pub const Display = extern struct { a: Keyword, b: Keyword, c: Keyword };

/// `visibility` and `text-align`, each one keyword.
pub const Single = extern struct { kind: Keyword };

/// A number, and whether it was written with a point.
pub const Number = extern struct { num: f64, is_float: bool };

/// A channel of `rgb()`: a number from 0 to 255, or a percentage.
pub const Channel = extern struct { kind: Keyword, value: Number };

/// A colour as a declaration holds one: written in hex, as `rgb()`, as a
/// name, or as one of the keywords that are not a colour of their own. Only
/// the two shapes read are mirrored; the rest of upstream's union is left
/// to it.
pub const Colour = extern struct {
    kind: Keyword,
    u: extern union {
        /// The channels as written: a digit each in the three and four digit
        /// forms, a byte each in the six and eight. An alpha not written is a
        /// whole byte.
        hex: extern struct { r: u8, g: u8, b: u8, a: u8, length: HexLength },
        rgb: extern struct { r: Channel, g: Channel, b: Channel, a: Channel, old: bool },
    },
};

/// How many digits a hex colour was written with: one a channel or two, each
/// with or without an alpha.
pub const HexLength = enum(c_uint) { three, four, six, eight, _ };

comptime {
    // This side of the shapes `lexborport/layout_check.c` pins on the other.
    const word = @sizeOf(usize);
    if (@offsetOf(DomDocument, "css") != 27 * word + 2 * @sizeOf(c_uint)) @compileError("a document's cascade is not where upstream keeps it");
    if (@offsetOf(DocumentCss, "parser") != 2 * word) @compileError("the cascade's parser is not its third word");
    if (@sizeOf(Rule) != 6 * word) @compileError("a rule's head is not six words");
    if (@offsetOf(StyleRule, "declarations") != 7 * word) @compileError("a style rule's declarations are not its eighth word");
    if (@offsetOf(DeclarationList, "first") != 6 * word) @compileError("a declaration list does not start after its head");
    if (@offsetOf(Declaration, "value") != 7 * word) @compileError("a declaration's value is not its eighth word");
    if (@offsetOf(Declaration, "important") != 14 * word) @compileError("a declaration's importance is not after its six offsets");
    if (@offsetOf(Custom, "value") != 2 * word) @compileError("a custom declaration's value does not follow its name");
    if (@offsetOf(Colour, "u") != @alignOf(f64)) @compileError("a colour's value does not follow its kind");
    if (@sizeOf(Channel) != @alignOf(f64) + @sizeOf(Number)) @compileError("a colour channel is not a kind and a number");
}
