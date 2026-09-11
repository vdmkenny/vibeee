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
pub const Element = opaque {};

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
    title = 0x00bd,
    tr = 0x00be,
    tt = 0x00c0,
    ul = 0x00c2,
    @"var" = 0x00c3,
    _,
};

/// A node, as far as this program reaches into one.
///
/// Only the fields ahead of `type` are named, and they are named in
/// upstream's order because that is what fixes where `type` sits. Reaching
/// past it would mean mirroring the rest of the struct, and the rest of the
/// struct is not this program's business.
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

pub extern fn lxb_dom_node_text_content(node: *Node, len: *usize) ?[*]const u8;
pub extern fn lxb_dom_element_get_attribute(element: *Node, name: [*]const u8, name_len: usize, value_len: *usize) ?[*]const u8;

/// A string as upstream keeps one: a pointer and a length.
const Str = extern struct {
    data: ?[*]const u8,
    length: usize,
};

/// Where a text node's words sit: straight after the node's head, which is
/// twelve words long. Pinned on the C side with the rest of the head.
const TEXT_AT = 12 * @sizeOf(usize);

/// The words a text node holds, read where the parser keeps them.
///
/// Read in place rather than through `lxb_dom_node_text_content`, which makes
/// a copy of every text node it is asked about and keeps each until the
/// document goes: a page's worth of words held twice for the length of the
/// walk, on a machine where that is the difference that matters.
pub fn wordsOf(node: *const Node) []const u8 {
    std.debug.assert(node.type == .text);
    const str: *const Str = @ptrFromInt(@intFromPtr(node) + TEXT_AT);
    const data = str.data orelse return "";
    return data[0..str.length];
}

/// An attribute's value, or nothing where the element has none.
pub fn attribute(node: *Node, name: []const u8) ?[]const u8 {
    std.debug.assert(node.type == .element);
    var len: usize = 0;
    const value = lxb_dom_element_get_attribute(node, name.ptr, name.len, &len) orelse return null;
    return value[0..len];
}

/// Every interface begins with a node, which is what upstream's own
/// `lxb_dom_interface_node` says by casting rather than by reaching.
pub fn nodeOf(interface: anytype) *Node {
    return @ptrCast(@alignCast(interface));
}

comptime {
    // This side of the layout `lexborport/layout_check.c` pins on the other.
    const word = @sizeOf(usize);
    if (@offsetOf(Node, "local_name") != word) @compileError("a node does not begin with one pointer");
    if (@offsetOf(Node, "owner_document") != 4 * word) @compileError("the names are not three words");
    if (@offsetOf(Node, "type") != 11 * word) @compileError("the head of a node is not eleven words");
}

/// The text under `node`, or nothing where there is none.
///
/// Owned by the document and gone when it is destroyed, so a caller that
/// wants it afterwards copies it.
pub fn textOf(node: *Node) ?[]const u8 {
    var len: usize = 0;
    const text = lxb_dom_node_text_content(node, &len) orelse return null;
    return text[0..len];
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
