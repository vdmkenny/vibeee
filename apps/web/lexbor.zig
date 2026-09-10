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

/// Every call answers with one of these. Zero is the only one that means it
/// worked; the rest are upstream's and are not enumerated here, because a
/// program that cannot parse a page does the same thing whichever way it
/// failed.
pub const Status = enum(c_uint) {
    ok = 0,
    _,

    pub fn worked(self: Status) bool {
        return self == .ok;
    }
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

/// The elements this reader treats specially. Upstream numbers every tag it
/// knows; these are the few whose number decides something here, and a node's
/// `local_name` is that number for an element.
///
/// A tag not named here is not unknown, it is simply one this reader has no
/// separate rule for.
pub const Tag = enum(usize) {
    body = 0x0020,
    br = 0x0021,
    h1 = 0x005c,
    html = 0x0066,
    li = 0x0072,
    p = 0x0092,
    script = 0x00a2,
    style = 0x00ae,
    _,

    /// Whether what is inside is for the machine rather than the reader. Its
    /// text is text in the tree like any other, and putting it on the page
    /// would set a stylesheet in the middle of an article.
    pub fn machineOnly(self: Tag) bool {
        return self == .script or self == .style;
    }
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
