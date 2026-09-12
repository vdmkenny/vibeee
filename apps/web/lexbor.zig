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

/// The document a page parses into.
pub const Document = opaque {};
/// An element in it, which is what most of these calls are made on.
pub const Element = opaque {};
/// What a search of the tree turned up.
pub const Collection = opaque {};
/// A length of markup, serialised.
pub const Text = extern struct { data: ?[*]const u8, length: usize };
/// Lexbor's own selectors engine.
pub const Selectors = opaque {};

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
pub extern fn lxb_html_document_body_element_noi(document: *Document) ?*Element;
pub extern fn lxb_html_document_head_element_noi(document: *Document) ?*Element;
pub extern fn lexbor_first_child(node: *Node) ?*Node;
pub extern fn lexbor_next(node: *Node) ?*Node;
pub extern fn lexbor_prev(node: *Node) ?*Node;
pub extern fn lexbor_parent(node: *Node) ?*Node;
pub extern fn lexbor_collection_length(collection: *Collection) usize;
pub extern fn lexbor_collection_element(collection: *Collection, at: usize) ?*Element;
pub extern fn lexbor_destroy_text(document: *Document, text: [*]u8) ?*anyopaque;
pub extern fn lxb_html_serialize_tree_str(node: *Node, out: *Text) c_int;

/// A selector list, parsed: what `lxb_selectors_find` is given.
pub const CssSelectorList = opaque {};
/// The CSS parser's tokenizer, which a parser may be given its own of.
pub const CssTokenizer = opaque {};

/// Lexbor's DOM operation result. `ok` means the specification-level tree
/// operation was valid and applied; anything else leaves the tree alone.
pub const DomException = enum(c_int) { ok = 0, _ };

pub extern fn lxb_dom_node_text_content(node: *Node, len: *usize) ?[*]const u8;
pub extern fn lxb_dom_node_text_content_set(node: *Node, text: [*]const u8, len: usize) Status;
pub extern fn lxb_dom_node_append_child(parent: *Node, child: *Node) DomException;
pub extern fn lxb_dom_node_insert_before(into: *Node, node: *Node) void;
pub extern fn lxb_dom_node_insert_before_spec(parent: *Node, node: *Node, before: *Node) DomException;
pub extern fn lxb_dom_node_remove(node: *Node) void;
pub extern fn lxb_dom_node_remove_child(parent: *Node, child: *Node) DomException;
pub extern fn lxb_dom_node_replace_child(parent: *Node, node: *Node, child: *Node) DomException;
pub extern fn lxb_dom_node_clone(node: *Node, deep: bool) ?*Node;
pub extern fn lxb_dom_element_set_attribute(element: *Node, name: [*]const u8, name_len: usize, value: [*]const u8, value_len: usize) Status;
pub extern fn lxb_dom_element_remove_attribute(element: *Node, name: [*]const u8, name_len: usize) Status;
pub extern fn lxb_dom_element_tag_name(element: *Node, len: *usize) ?[*:0]const u8;
pub extern fn lxb_dom_document_root(document: *Document) ?*Node;
pub extern fn lxb_dom_document_create_element(document: *Document, name: [*]const u8, name_len: usize, reserved: ?*anyopaque) ?*Element;
pub extern fn lxb_dom_document_create_text_node(document: *Document, text: [*]const u8, len: usize) ?*Node;
pub extern fn lxb_html_document_parse_fragment(document: *Document, element: *Node, html: [*]const u8, size: usize) ?*Node;
pub extern fn lxb_html_serialize_deep_str(node: *Node, out: *Text) c_int;
pub extern fn lxb_dom_collection_create(document: *Document) ?*Collection;
pub extern fn lxb_dom_collection_init(collection: *Collection, start: usize) Status;
pub extern fn lxb_dom_collection_destroy(collection: *Collection, itself: bool) ?*Collection;
pub extern fn lxb_dom_elements_by_tag_name(root: *Node, collection: *Collection, name: [*]const u8, len: usize) Status;
pub extern fn lxb_dom_elements_by_class_name(root: *Node, collection: *Collection, name: [*]const u8, len: usize) Status;
pub extern fn lxb_dom_elements_by_attr(root: *Node, collection: *Collection, name: [*]const u8, name_len: usize, value: [*]const u8, value_len: usize, regardless: bool) Status;
pub extern fn lxb_selectors_create() ?*Selectors;
pub extern fn lxb_selectors_init(engine: *Selectors) Status;
pub extern fn lxb_selectors_find(engine: *Selectors, root: *Node, list: *const CssSelectorList, found: *const fn (*Node, u32, ?*anyopaque) callconv(.c) Status, taken: ?*anyopaque) Status;
pub extern fn lxb_selectors_match_node(engine: *Selectors, node: *Node, list: *const CssSelectorList, found: *const fn (*Node, u32, ?*anyopaque) callconv(.c) Status, taken: ?*anyopaque) Status;
pub extern fn lxb_selectors_destroy(engine: *Selectors, itself: bool) ?*Selectors;
pub extern fn lxb_css_memory_create() ?*CssMemory;
pub extern fn lxb_css_memory_destroy(memory: *CssMemory, itself: bool) ?*CssMemory;
pub extern fn lxb_css_parser_create() ?*CssParser;
pub extern fn lxb_css_parser_init(parser: *CssParser, tokenizer: ?*CssTokenizer) Status;
pub extern fn lxb_css_parser_selectors_init(parser: *CssParser) Status;
pub extern fn lxb_css_parser_selectors_destroy(parser: *CssParser) void;
pub extern fn lxb_css_parser_destroy(parser: *CssParser, itself: bool) ?*CssParser;
pub extern fn lxb_css_selectors_parse(parser: *CssParser, data: [*]const u8, length: usize) ?*CssSelectorList;
pub extern fn lxb_css_selector_list_destroy(list: *CssSelectorList) void;

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
    align_items = 0x0003,
    background_color = 0x0006,
    bottom = 0x0012,
    color = 0x0015,
    display = 0x0017,
    flex_direction = 0x001b,
    height = 0x002a,
    justify_content = 0x0030,
    left = 0x0031,
    max_height = 0x003a,
    max_width = 0x003b,
    min_height = 0x003c,
    min_width = 0x003d,
    opacity = 0x003e,
    position = 0x004a,
    right = 0x004b,
    text_align = 0x004d,
    top = 0x005a,
    visibility = 0x005d,
    white_space = 0x005e,
    width = 0x005f,
    _,
};

/// The keywords and kinds of value this reader tells apart, numbered as
/// upstream numbers them. Anything else is a value it does not act on.
pub const Keyword = enum(c_uint) {
    auto = 0x000c,
    length = 0x0014,
    flex_start = 0x0005,
    flex_end = 0x0006,
    center = 0x0007,
    space_between = 0x0008,
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
    block = 0x00e7,
    @"inline" = 0x00e8,
    flex = 0x00ed,
    contents = 0x00fd,
    inline_block = 0x00fe,
    inline_flex = 0x0100,
    number = 0x0108,
    row = 0x0104,
    row_reverse = 0x0105,
    column = 0x0106,
    column_reverse = 0x0107,
    start = 0x010d,
    end = 0x010e,
    justify = 0x014a,
    collapse = 0x0165,
    pre = 0x0166,
    pre_wrap = 0x0167,
    static = 0x0145,
    absolute = 0x0147,
    fixed = 0x0149,
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

/// `position`, one keyword.
pub const Position = extern struct { kind: Keyword };

/// A number, and whether it was written with a point.
pub const Number = extern struct { num: f64, is_float: bool };

/// A CSS dimension, retaining only the unit kinds a box layout understands.
pub const Length = extern struct { num: f64, is_float: bool, unit: Unit };

/// A length, a percentage, or a keyword such as `auto`.
pub const LengthPercentage = extern struct {
    kind: Keyword,
    value: extern union {
        length: Length,
        percentage: Number,
    },
};

pub const Unit = enum(c_uint) {
    undef = 0,
    px = 0x0007,
    vh = 0x0011,
    vw = 0x0015,
    _,
};

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
    if (@sizeOf(Position) != @sizeOf(c_uint)) @compileError("a position is not one keyword");
    if (@offsetOf(LengthPercentage, "value") != @alignOf(f64)) @compileError("a length value does not follow its kind");
    if (@sizeOf(LengthPercentage) != @alignOf(f64) + @sizeOf(Length)) @compileError("a length value is not one kind and one union");
}
