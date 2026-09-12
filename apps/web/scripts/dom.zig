//! The document a script sees.
//!
//! The page's own tree, given to a script in the terms a script expects: an
//! element is an object with an `id`, a `className`, a `style`, children and a
//! `textContent`, and the document is where elements are found and made. The
//! tree behind it is lexbor's, the same one the reader reads the page from,
//! so what a script does to it is what the reader draws next time it reads.
//!
//! Nothing of the tree is mirrored or cached: an element object holds a pointer
//! to a lexbor node and nothing else, and every method is lexbor's own call, so
//! nothing here can fall out of step with the page.
//!
//! What a page keeps -- cookies, and what it puts by -- is kept here too, and
//! handed to the reader to send. What a page asks for that this reader cannot
//! give is given as an empty shape rather than left out: a script that finds no
//! `getComputedStyle` stops where one that finds an empty one goes on.
//!
//! A context is made for one page and freed with it, so a node a script was
//! given never outlives the tree it pointed into.

const std = @import("std");
const qjs = @import("quickjs");
const lexbor = @import("lexbor");
const url = @import("url");

const Context = qjs.Context;
const Value = qjs.Value;

/// What the reader does when a script asks for a page of its own: the text it
/// came to, taken there and then.
pub const Fetch = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?[*:0]u8;

/// What the reader does when a script asks to be taken somewhere: a page
/// setting `location.href`, or saying `location.assign` or `location.replace`,
/// is a page sending the reader on, which is what a redirect is.
pub const Go = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void;

/// The browser's cookie jar. It belongs to the reader, not a page context:
/// pages go away on navigation while their cookies must remain for the site
/// that sent the next page. Reading writes into caller-owned space; writing
/// hands the full `document.cookie` assignment back to the browser.
pub const CookieRead = *const fn (?*anyopaque, [*:0]const u8, [*]u8, usize) callconv(.c) usize;
pub const CookieWrite = *const fn (?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) void;

/// The clock, in thousandths of a second: what a timer is measured against.
/// Handed in rather than asked for, this machine's being one thing and the
/// reader's being another.
pub const Clock = *const fn () callconv(.c) u32;

/// A cookie a script has written. What a *site* sets is not taken yet: the
/// reader reads no `Set-Cookie` out of an answer, so a cookie here is one a
/// script wrote, which is what a page looking for one back will find.
const Crumb = struct { name: []const u8, value: []const u8, domain: []const u8, path: []const u8 };

/// A listener a script has put on an element.
const Watch = struct { node: *lexbor.Node, kind: []const u8, handler: Value };

/// What a script has asked to be called later.
const Timer = struct { id: u32, handler: Value, due: u32, every: u32, animation: bool = false };

const Page = struct {
    tree: *lexbor.Document,
    address: []const u8,
    user_agent: []const u8,
    fetch: ?Fetch,
    go: ?Go = null,
    cookie_read: ?CookieRead = null,
    cookie_write: ?CookieWrite = null,
    taken: ?*anyopaque,
    clock: Clock,
    crumbs: std.ArrayList(Crumb) = .empty,
    stored: std.StringHashMap([]const u8) = undefined,
    watches: std.ArrayList(Watch) = .empty,
    timers: std.ArrayList(Timer) = .empty,
    /// Lexbor's own selectors engine and the parser behind it, so `a[href]`
    /// means what a stylesheet says it means.
    css: ?*lexbor.CssMemory = null,
    parser: ?*lexbor.CssParser = null,
    selectors: ?*lexbor.Selectors = null,
    next_timer: u32 = 0,
    /// How many of the page's scripts have run, and how many of those threw.
    /// Counted rather than assumed: a reader that says how many ran is one a
    /// person can tell apart from one that ran none.
    ran: u32 = 0,
    threw: u32 = 0,
    /// What a script has reached for and this reader had no answer to, so
    /// that each is said once and not again. The last of them and how many
    /// there were is what the reader shows: a page that stops is a page that
    /// will not say why, and this is the only asking it will do.
    noted: std.StringHashMap(void) = undefined,
    asked_last: []const u8 = "",
    asked_count: u32 = 0,
    /// The last exception a page threw, copied before the engine gives its
    /// temporary words back. A count says that a script failed; its words say
    /// where the browser shape stopped being one it knew.
    error_last: []const u8 = "",
    error_script: []const u8 = "",
    changed: bool = false,
    /// Whether the event being told was asked to go no further.
    prevented: bool = false,
};

/// The engine's own heap: what a document's lists are kept on, so the document
/// asks nothing of the machine it runs on but what the engine already has.
const Heap = struct {
    ctx: *Context,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = &alloc,
        .resize = &resize,
        .free = &drop,
        .remap = &remap,
    };

    fn allocator(self: *Heap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(held: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        _ = alignment;
        const it: *Heap = @ptrCast(@alignCast(held));
        return @ptrCast(qjs.alloc(it.ctx, len));
    }

    /// Growth is a new block and a copy: the engine's heap has no way to say
    /// whether a block has room to spare.
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        return new_len == 0;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn drop(held: *anyopaque, bytes: []u8, _: std.mem.Alignment, _: usize) void {
        const it: *Heap = @ptrCast(@alignCast(held));
        qjs.release(it.ctx, bytes.ptr);
    }
};

var heap_of: Heap = undefined;
var gpa: std.mem.Allocator = undefined;

/// One class: everything the document hands a script carries a node inside it.
var node_class: qjs.ClassId = 0;
/// The runtime the class above was made for: a new runtime needs a new one.
var class_for: ?*qjs.Runtime = null;

fn page(ctx: *Context) ?*Page {
    return @ptrCast(@alignCast(qjs.heldOf(ctx)));
}

/// Say, once a page, that a script reached for something this reader has no
/// answer for.
///
/// A page that stops where it found nothing gives no sign of why: it stops,
/// and that is all. Saying what it reached for turns a page that will not
/// draw into a list of what to give it next, which is what a reader without
/// these things needs. Said once each, so a page asking in a loop is not a
/// page shouting.
fn missing(ctx: *Context, what: []const u8) void {
    const it = page(ctx) orelse return;
    const got = it.noted.getOrPut(what) catch return;
    if (got.found_existing) return;
    got.key_ptr.* = keep(what);
    it.asked_last = got.key_ptr.*;
    it.asked_count += 1;
    const js = @import("js");
    js.note(@ptrCast(got.key_ptr.*.ptr));
}

/// Say the document has been changed, and so reads differently.
fn markChanged(ctx: *Context) void {
    if (page(ctx)) |it| it.changed = true;
}

fn nodeOf(value: Value) ?*lexbor.Node {
    return @ptrCast(@alignCast(qjs.nodeOf(value, node_class)));
}

/// An element, as a script sees it.
fn element(ctx: *Context, node: *lexbor.Node) Value {
    const made = qjs.newObjectIn(ctx, @intCast(node_class));
    qjs.setNode(made, node);
    _ = qjs.addList(ctx, made, &node_methods, node_methods.len);
    _ = qjs.addList(ctx, made, &node_gets, node_gets.len);
    return made;
}

/// The text of a value, and the caller gives it back. This distinct empty
/// slice means a failed conversion is not mistaken for an allocated empty JS
/// string, which must still be released.
const no_words: []const u8 = "";

fn words(ctx: *Context, value: Value) []const u8 {
    const got = qjs.textOf(ctx, value) orelse return no_words;
    return std.mem.span(got);
}

fn freeWords(ctx: *Context, value: Value, text: []const u8) void {
    _ = value;
    if (text.ptr == no_words.ptr) return;
    qjs.freeText(ctx, @ptrCast(text.ptr));
}

/// A copy of `bytes`, kept on the engine's heap: a word a script handed over is
/// freed when the call ends, so anything kept past it must be a copy.
fn keep(bytes: []const u8) []const u8 {
    const out = gpa.allocSentinel(u8, bytes.len, 0) catch return "";
    @memcpy(out, bytes);
    return out;
}

// ---------------------------------------------------------------------------
// Attributes, text and markup
// ---------------------------------------------------------------------------

fn attributeOf(node: *lexbor.Node, name: []const u8) ?[]const u8 {
    var len: usize = 0;
    const got = lexbor.lxb_dom_element_get_attribute(@ptrCast(node), name.ptr, name.len, &len) orelse return null;
    return got[0..len];
}

fn attributeSet(ctx: *Context, node: *lexbor.Node, name: []const u8, value: []const u8) void {
    _ = lexbor.lxb_dom_element_set_attribute(@ptrCast(node), name.ptr, name.len, value.ptr, value.len);
    markChanged(ctx);
}

fn jsGetAttribute(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = nodeOf(this) orelse return qjs.nullValue();
    const name = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], name);
    return if (attributeOf(node, name)) |got| qjs.newString(ctx, got.ptr, got.len) else qjs.nullValue();
}

fn jsSetAttribute(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const name = words(ctx, argv[0]);
    const value = words(ctx, argv[1]);
    attributeSet(ctx, node, name, value);
    freeWords(ctx, argv[0], name);
    freeWords(ctx, argv[1], value);
    return qjs.undefinedValue();
}

fn jsHasAttribute(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    const name = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], name);
    const yes = lexbor.lxb_dom_element_has_attribute(@ptrCast(node), name.ptr, name.len);
    return qjs.newBool(ctx, @intFromBool(yes));
}

fn jsRemoveAttribute(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const name = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], name);
    _ = lexbor.lxb_dom_element_remove_attribute(@ptrCast(node), name.ptr, name.len);
    markChanged(ctx);
    return qjs.undefinedValue();
}

fn jsToggleAttribute(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    const name = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], name);
    const had = lexbor.lxb_dom_element_has_attribute(@ptrCast(node), name.ptr, name.len);
    if (had) {
        _ = lexbor.lxb_dom_element_remove_attribute(@ptrCast(node), name.ptr, name.len);
        markChanged(ctx);
    } else {
        attributeSet(ctx, node, name, "");
    }
    return qjs.newBool(ctx, @intFromBool(!had));
}

/// Text lexbor allocated for a caller. It is copied into QuickJS or an
/// address before the caller is done, then returned to its document.
const NodeText = struct {
    node: *lexbor.Node,
    data: ?[*]const u8,
    bytes: []const u8,

    fn deinit(self: NodeText) void {
        const data = self.data orelse return;
        _ = lexbor.lexbor_destroy_text(self.node.owner_document.?, @constCast(data));
    }
};

fn textOfNode(node: *lexbor.Node) NodeText {
    var len: usize = 0;
    const got = lexbor.lxb_dom_node_text_content(node, &len) orelse return .{ .node = node, .data = null, .bytes = "" };
    return .{ .node = node, .data = got, .bytes = got[0..len] };
}

fn jsTextContent(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = textOfNode(node);
    defer text.deinit();
    return qjs.newString(ctx, text.bytes.ptr, text.bytes.len);
}

fn jsSetTextContent(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = words(ctx, value);
    defer freeWords(ctx, value, text);
    while (lexbor.lexbor_first_child(node)) |each| lexbor.lxb_dom_node_remove(each);
    if (text.len > 0) {
        if (lexbor.lxb_dom_document_create_text_node(node.owner_document.?, text.ptr, text.len)) |leaf| {
            if (lexbor.lxb_dom_node_append_child(node, @ptrCast(@alignCast(leaf))) != .ok) return qjs.undefinedValue();
        }
    }
    markChanged(ctx);
    return qjs.undefinedValue();
}

fn jsInnerHtml(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    var out: lexbor.Text = .{ .data = null, .length = 0 };
    if (lexbor.lxb_html_serialize_deep_str(node, &out) != 0) return qjs.newString(ctx, "", 0);
    if (out.data) |data| {
        const result = qjs.newString(ctx, data, out.length);
        _ = lexbor.lexbor_destroy_text(node.owner_document.?, @constCast(data));
        return result;
    }
    return qjs.newString(ctx, "", 0);
}

/// The element and its children, as markup: what `outerHTML` means, and what
/// serialising the node itself says.
fn jsOuterHtml(ctx: *Context, this: Value) callconv(.c) Value {
    return jsInnerHtml(ctx, this);
}

fn jsSetInnerHtml(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const markup = words(ctx, value);
    defer freeWords(ctx, value, markup);
    while (lexbor.lexbor_first_child(node)) |each| lexbor.lxb_dom_node_remove(each);
    if (markup.len > 0) {
        const into = lexbor.lxb_html_document_parse_fragment(
            node.owner_document.?,
            @ptrCast(node),
            markup.ptr,
            markup.len,
        );
        while (into) |held| {
            const each = lexbor.lexbor_first_child(held) orelse break;
            lexbor.lxb_dom_node_remove(each);
            if (lexbor.lxb_dom_node_append_child(node, each) != .ok) break;
        }
    }
    markChanged(ctx);
    return qjs.undefinedValue();
}

// ---------------------------------------------------------------------------
// Its class, and its style
// ---------------------------------------------------------------------------

/// The classes an element has, as words. They stand in the attribute, so they
/// live as long as the document does.
fn classesOf(node: *lexbor.Node) std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    const named = attributeOf(node, "class") orelse return list;
    var at = std.mem.tokenizeAny(u8, named, " \t\n\r");
    while (at.next()) |one| list.append(gpa, one) catch {};
    return list;
}

fn classesSet(ctx: *Context, node: *lexbor.Node, list: []const []const u8) void {
    var joined: std.ArrayList(u8) = .empty;
    for (list, 0..) |one, at| {
        if (at > 0) joined.append(gpa, ' ') catch {};
        joined.appendSlice(gpa, one) catch {};
    }
    attributeSet(ctx, node, "class", joined.items);
    joined.deinit(gpa);
}

fn jsClassList(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const list = qjs.newObjectIn(ctx, @intCast(node_class));
    qjs.setNode(list, node);
    _ = qjs.addList(ctx, list, &list_methods, list_methods.len);
    // Also the classes it has, so a script may count them.
    var have = classesOf(node);
    defer have.deinit(gpa);
    for (have.items, 0..) |one, at| {
        _ = qjs.setAt(ctx, list, @intCast(at), qjs.newString(ctx, one.ptr, one.len));
    }
    return list;
}

fn jsClassAdd(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = @as(?*lexbor.Node, @ptrCast(@alignCast(qjs.nodeOf(this, node_class)))) orelse return qjs.undefinedValue();
    var have = classesOf(node);
    const wanted = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], wanted);
    for (have.items) |one| {
        if (std.mem.eql(u8, one, wanted)) {
            have.deinit(gpa);
            return qjs.undefinedValue();
        }
    }
    have.append(gpa, keep(wanted)) catch {};
    classesSet(ctx, node, have.items);
    have.deinit(gpa);
    return qjs.undefinedValue();
}

fn jsClassRemove(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = @as(?*lexbor.Node, @ptrCast(@alignCast(qjs.nodeOf(this, node_class)))) orelse return qjs.undefinedValue();
    const gone = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], gone);
    var have = classesOf(node);
    var kept: std.ArrayList([]const u8) = .empty;
    for (have.items) |one| {
        if (!std.mem.eql(u8, one, gone)) kept.append(gpa, one) catch {};
    }
    classesSet(ctx, node, kept.items);
    kept.deinit(gpa);
    have.deinit(gpa);
    return qjs.undefinedValue();
}

fn jsClassHas(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = @as(?*lexbor.Node, @ptrCast(@alignCast(qjs.nodeOf(this, node_class)))) orelse return qjs.newBool(ctx, 0);
    const wanted = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], wanted);
    var have = classesOf(node);
    defer have.deinit(gpa);
    for (have.items) |one| {
        if (std.mem.eql(u8, one, wanted)) return qjs.newBool(ctx, 1);
    }
    return qjs.newBool(ctx, 0);
}

fn jsClassToggle(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const there = jsClassHas(ctx, this, argc, argv);
    const yes = qjs.truthOf(ctx, there) > 0;
    qjs.free(ctx, there);
    if (yes) {
        _ = jsClassRemove(ctx, this, argc, argv);
    } else {
        _ = jsClassAdd(ctx, this, argc, argv);
    }
    return qjs.newBool(ctx, @intFromBool(!yes));
}

const list_methods = [_]qjs.ListEntry{
    qjs.ListEntry.method("add", 1, &jsClassAdd),
    qjs.ListEntry.method("remove", 1, &jsClassRemove),
    qjs.ListEntry.method("contains", 1, &jsClassHas),
    qjs.ListEntry.method("toggle", 1, &jsClassToggle),
};

/// `element.style`: read and written as the page's own `style` attribute.
fn jsStyle(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const style = qjs.newObjectIn(ctx, @intCast(node_class));
    qjs.setNode(style, node);
    _ = qjs.addList(ctx, style, &style_methods, style_methods.len);
    return style;
}

fn jsStyleValue(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc == 0) return qjs.newString(ctx, "", 0);
    const node = nodeOf(this) orelse return qjs.newString(ctx, "", 0);
    const name = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], name);
    const value = styleValue(node, name) orelse return qjs.newString(ctx, "", 0);
    return qjs.newString(ctx, value.ptr, value.len);
}

fn jsStyleSet(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc < 2) return qjs.undefinedValue();
    const node = @as(?*lexbor.Node, @ptrCast(@alignCast(qjs.nodeOf(this, node_class)))) orelse return qjs.undefinedValue();
    const name = words(ctx, argv[0]);
    const value = words(ctx, argv[1]);
    const was = attributeOf(node, "style") orelse "";
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    var declarations = std.mem.splitScalar(u8, was, ';');
    while (declarations.next()) |one| {
        const declaration = std.mem.trim(u8, one, &std.ascii.whitespace);
        const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse continue;
        const property = std.mem.trim(u8, declaration[0..colon], &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(property, name)) continue;
        appendStyle(&joined, property, std.mem.trim(u8, declaration[colon + 1 ..], &std.ascii.whitespace));
    }
    appendStyle(&joined, name, value);
    attributeSet(ctx, node, "style", joined.items);
    freeWords(ctx, argv[0], name);
    freeWords(ctx, argv[1], value);
    return qjs.undefinedValue();
}

fn styleValue(node: *lexbor.Node, want: []const u8) ?[]const u8 {
    const text = attributeOf(node, "style") orelse return null;
    var declarations = std.mem.splitScalar(u8, text, ';');
    while (declarations.next()) |one| {
        const declaration = std.mem.trim(u8, one, &std.ascii.whitespace);
        const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse continue;
        const property = std.mem.trim(u8, declaration[0..colon], &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(property, want)) return std.mem.trim(u8, declaration[colon + 1 ..], &std.ascii.whitespace);
    }
    return null;
}

fn appendStyle(into: *std.ArrayList(u8), name: []const u8, value: []const u8) void {
    if (into.items.len > 0) into.append(gpa, ' ') catch {};
    into.appendSlice(gpa, name) catch {};
    into.appendSlice(gpa, ": ") catch {};
    into.appendSlice(gpa, value) catch {};
    into.append(gpa, ';') catch {};
}

fn setStyle(ctx: *Context, node: *lexbor.Node, name: []const u8, value: []const u8) void {
    const was = attributeOf(node, "style") orelse "";
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    var declarations = std.mem.splitScalar(u8, was, ';');
    while (declarations.next()) |one| {
        const declaration = std.mem.trim(u8, one, &std.ascii.whitespace);
        const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse continue;
        const property = std.mem.trim(u8, declaration[0..colon], &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(property, name)) continue;
        appendStyle(&joined, property, std.mem.trim(u8, declaration[colon + 1 ..], &std.ascii.whitespace));
    }
    appendStyle(&joined, name, value);
    attributeSet(ctx, node, "style", joined.items);
}

fn jsStyleText(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.newString(ctx, "", 0);
    const text = attributeOf(node, "style") orelse return qjs.newString(ctx, "", 0);
    return qjs.newString(ctx, text.ptr, text.len);
}

fn jsSetStyleText(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = words(ctx, value);
    defer freeWords(ctx, value, text);
    attributeSet(ctx, node, "style", text);
    return qjs.undefinedValue();
}

fn jsStyleDisplay(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.newString(ctx, "", 0);
    const text = styleValue(node, "display") orelse return qjs.newString(ctx, "", 0);
    return qjs.newString(ctx, text.ptr, text.len);
}

fn jsSetStyleDisplay(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = words(ctx, value);
    defer freeWords(ctx, value, text);
    setStyle(ctx, node, "display", text);
    return qjs.undefinedValue();
}

const style_methods = [_]qjs.ListEntry{
    qjs.ListEntry.method("setProperty", 2, &jsStyleSet),
    qjs.ListEntry.method("getPropertyValue", 1, &jsStyleValue),
    qjs.ListEntry.accessor("cssText", &jsStyleText, &jsSetStyleText),
    qjs.ListEntry.accessor("display", &jsStyleDisplay, &jsSetStyleDisplay),
};

// ---------------------------------------------------------------------------
// Changing the tree
// ---------------------------------------------------------------------------

fn jsAppendChild(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const child = nodeOf(argv[0]) orelse return qjs.undefinedValue();
    if (lexbor.lxb_dom_node_append_child(node, child) != .ok) return qjs.undefinedValue();
    markChanged(ctx);
    return qjs.dup(ctx, argv[0]);
}

fn jsInsertBefore(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const child = nodeOf(argv[0]) orelse return qjs.undefinedValue();
    if (argc > 1) {
        if (nodeOf(argv[1])) |before| {
            if (lexbor.lxb_dom_node_insert_before_spec(node, child, before) != .ok) return qjs.undefinedValue();
            markChanged(ctx);
            return qjs.dup(ctx, argv[0]);
        }
    }
    if (lexbor.lxb_dom_node_append_child(node, child) != .ok) return qjs.undefinedValue();
    markChanged(ctx);
    return qjs.dup(ctx, argv[0]);
}

fn jsRemoveChild(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const child = nodeOf(argv[0]) orelse return qjs.undefinedValue();
    if (lexbor.lxb_dom_node_remove_child(node, child) != .ok) return qjs.undefinedValue();
    markChanged(ctx);
    return qjs.dup(ctx, argv[0]);
}

fn jsReplaceChild(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc < 2) return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const made = nodeOf(argv[0]) orelse return qjs.undefinedValue();
    const gone = nodeOf(argv[1]) orelse return qjs.undefinedValue();
    if (lexbor.lxb_dom_node_replace_child(node, made, gone) != .ok) return qjs.undefinedValue();
    markChanged(ctx);
    return qjs.dup(ctx, argv[1]);
}

fn jsRemove(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    _ = argv;
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    if (lexbor.lexbor_parent(node) != null) lexbor.lxb_dom_node_remove(node);
    markChanged(ctx);
    return qjs.undefinedValue();
}

// ---------------------------------------------------------------------------
// Finding elements
// ---------------------------------------------------------------------------

const Found = struct { nodes: std.ArrayList(*lexbor.Node) };

fn foundOne(node: *lexbor.Node, spec: u32, taken: ?*anyopaque) callconv(.c) lexbor.Status {
    _ = spec;
    const found: *Found = @ptrCast(@alignCast(taken));
    found.nodes.append(gpa, node) catch {};
    return .ok;
}

/// What a selector found, under `node`.
fn seek(ctx: *Context, node: *lexbor.Node, selector: []const u8) Found {
    var found: Found = .{ .nodes = .empty };
    const it = page(ctx) orelse return found;
    const parser = it.parser orelse return found;
    const parsed = lexbor.lxb_css_selectors_parse(parser, selector.ptr, selector.len) orelse return found;
    defer lexbor.lxb_css_selector_list_destroy(parsed);
    if (it.selectors) |engine| {
        _ = lexbor.lxb_selectors_find(engine, node, parsed, &foundOne, &found);
    }
    return found;
}

/// The one element a selector names, or nothing.
fn firstOf(ctx: *Context, node: ?*lexbor.Node, selector: []const u8) Value {
    const at = node orelse return qjs.nullValue();
    var found = seek(ctx, at, selector);
    defer found.nodes.deinit(gpa);
    return if (found.nodes.items.len > 0) element(ctx, found.nodes.items[0]) else qjs.nullValue();
}

/// Every element a selector names.
fn allOf(ctx: *Context, node: ?*lexbor.Node, selector: []const u8) Value {
    var found: Found = .{ .nodes = .empty };
    defer found.nodes.deinit(gpa);
    if (node) |at| found = seek(ctx, at, selector);
    const out = qjs.newArray(ctx);
    for (found.nodes.items, 0..) |each, at| {
        _ = qjs.setAt(ctx, out, @intCast(at), element(ctx, each));
    }
    return out;
}

/// Where a search begins: an element's own `querySelector` starts from itself,
/// and a document's from its root, a document being no element.
fn fromHere(ctx: *Context, this: Value) ?*lexbor.Node {
    if (nodeOf(this)) |node| return node;
    if (page(ctx)) |it| return lexbor.lxb_dom_document_root(it.tree);
    return null;
}

fn jsQuerySelector(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const selector = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], selector);
    return firstOf(ctx, fromHere(ctx, this), selector);
}

fn jsQuerySelectorAll(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const selector = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], selector);
    return allOf(ctx, fromHere(ctx, this), selector);
}

fn jsMatches(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    const selector = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], selector);
    var found: Found = .{ .nodes = .empty };
    defer found.nodes.deinit(gpa);
    const it = page(ctx) orelse return qjs.newBool(ctx, 0);
    const parsed = (it.parser orelse return qjs.newBool(ctx, 0));
    const list = lexbor.lxb_css_selectors_parse(parsed, selector.ptr, selector.len) orelse return qjs.newBool(ctx, 0);
    defer lexbor.lxb_css_selector_list_destroy(list);
    if (it.selectors) |engine| {
        _ = lexbor.lxb_selectors_match_node(engine, node, list, &foundOne, &found);
    }
    const yes = found.nodes.items.len > 0;
    return qjs.newBool(ctx, @intFromBool(yes));
}

fn jsClosest(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    var node = nodeOf(this) orelse return qjs.nullValue();
    while (true) {
        const one = element(ctx, node);
        const does = jsMatches(ctx, one, argc, argv);
        const yes = qjs.truthOf(ctx, does) > 0;
        qjs.free(ctx, does);
        if (yes) return one;
        qjs.free(ctx, one);
        node = lexbor.lexbor_parent(node) orelse return qjs.nullValue();
    }
}

/// Every element of a kind, or of a class, or carrying an attribute, under the
/// document's root.
fn gathered(ctx: *Context, found: *Found, comptime shape: enum { first, all }) Value {
    if (found.nodes.items.len == 0) return switch (shape) {
        .first => qjs.nullValue(),
        .all => qjs.newArray(ctx),
    };
    if (shape == .first) return element(ctx, found.nodes.items[0]);
    const out = qjs.newArray(ctx);
    for (found.nodes.items, 0..) |each, at| {
        _ = qjs.setAt(ctx, out, @intCast(at), element(ctx, each));
    }
    return out;
}

fn byName(ctx: *Context, comptime kind: enum { tag, class }, name: []const u8) Value {
    const it = page(ctx) orelse return qjs.newArray(ctx);
    const root = lexbor.lxb_dom_document_root(it.tree) orelse return qjs.newArray(ctx);
    const held = lexbor.lxb_dom_collection_create(it.tree) orelse return qjs.newArray(ctx);
    defer _ = lexbor.lxb_dom_collection_destroy(held, true);
    if (lexbor.lxb_dom_collection_init(held, 16) != .ok) return qjs.newArray(ctx);
    const ok = switch (kind) {
        .tag => lexbor.lxb_dom_elements_by_tag_name(@ptrCast(root), held, name.ptr, name.len),
        .class => lexbor.lxb_dom_elements_by_class_name(@ptrCast(root), held, name.ptr, name.len),
    };
    if (ok != .ok) return qjs.newArray(ctx);
    var found: Found = .{ .nodes = .empty };
    defer found.nodes.deinit(gpa);
    for (0..lexbor.lexbor_collection_length(held)) |at| {
        const each = lexbor.lexbor_collection_element(held, at) orelse continue;
        found.nodes.append(gpa, @ptrCast(@alignCast(each))) catch {};
    }
    return gathered(ctx, &found, .all);
}

fn jsGetById(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    const it = page(ctx) orelse return qjs.nullValue();
    const root = lexbor.lxb_dom_document_root(it.tree) orelse return qjs.nullValue();
    const held = lexbor.lxb_dom_collection_create(it.tree) orelse return qjs.nullValue();
    defer _ = lexbor.lxb_dom_collection_destroy(held, true);
    if (lexbor.lxb_dom_collection_init(held, 4) != .ok) return qjs.nullValue();
    const name = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], name);
    if (lexbor.lxb_dom_elements_by_attr(@ptrCast(root), held, "id", 2, name.ptr, name.len, false) != .ok) return qjs.nullValue();
    var found: Found = .{ .nodes = .empty };
    defer found.nodes.deinit(gpa);
    for (0..lexbor.lexbor_collection_length(held)) |at| {
        const each = lexbor.lexbor_collection_element(held, at) orelse continue;
        found.nodes.append(gpa, @ptrCast(@alignCast(each))) catch {};
    }
    return gathered(ctx, &found, .first);
}

fn jsGetByTag(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    const name = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], name);
    return byName(ctx, .tag, name);
}

fn jsGetByClass(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    const name = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], name);
    return byName(ctx, .class, name);
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

fn jsAddListener(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc < 2) return qjs.undefinedValue();
    if (qjs.isFunction(ctx, argv[1]) == 0) return qjs.undefinedValue();
    const it = page(ctx) orelse return qjs.undefinedValue();
    // Put on the window, or on the document, it is put on the page's root:
    // that is where a page's own events are told.
    const node = nodeOf(this) orelse (lexbor.lxb_dom_document_root(it.tree) orelse return qjs.undefinedValue());
    const kind = words(ctx, argv[0]);
    it.watches.append(gpa, .{
        .node = node,
        .kind = keep(kind),
        .handler = qjs.dup(ctx, argv[1]),
    }) catch return qjs.undefinedValue();
    freeWords(ctx, argv[0], kind);
    return qjs.undefinedValue();
}

fn jsPrevent(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    if (page(ctx)) |it| it.prevented = true;
    return qjs.undefinedValue();
}

const event_methods = [_]qjs.ListEntry{
    qjs.ListEntry.method("preventDefault", 0, &jsPrevent),
};

fn jsNewEvent(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    const event = qjs.newObject(ctx);
    _ = qjs.addList(ctx, event, &event_methods, event_methods.len);
    const kind = if (argc > 0) words(ctx, argv[0]) else "";
    defer if (argc > 0) freeWords(ctx, argv[0], kind);
    _ = qjs.setStr(ctx, event, "type", qjs.newString(ctx, kind.ptr, kind.len));
    return event;
}

fn jsNewCustomEvent(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const event = jsNewEvent(ctx, this, argc, argv);
    if (argc > 1) _ = qjs.setStr(ctx, event, "detail", qjs.getStr(ctx, argv[1], "detail"));
    return event;
}

fn jsAbortController(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    const controller = qjs.newObject(ctx);
    _ = qjs.setStr(ctx, controller, "signal", qjs.newObject(ctx));
    _ = qjs.setStr(ctx, controller, "abort", qjs.function(ctx, @ptrCast(&jsNothing), "abort", 0, .generic, 0));
    return controller;
}

fn jsDispatchEvent(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc < 1) return qjs.newBool(ctx, 1);
    const it = page(ctx) orelse return qjs.newBool(ctx, 1);
    const type_value = qjs.getStr(ctx, argv[0], "type");
    defer qjs.free(ctx, type_value);
    const kind = words(ctx, type_value);
    defer freeWords(ctx, type_value, kind);
    const node = nodeOf(this) orelse (lexbor.lxb_dom_document_root(it.tree) orelse return qjs.newBool(ctx, 1));
    tell(ctx, node, kind, true);
    return qjs.newBool(ctx, @intFromBool(!it.prevented));
}

/// Tell `node`, and each thing it stands inside, that `kind` has happened.
fn tell(ctx: *Context, node: *lexbor.Node, kind: []const u8, climb: bool) void {
    const it = page(ctx) orelse return;
    it.prevented = false;
    var at: ?*lexbor.Node = node;
    while (at) |each| {
        const event = qjs.newObject(ctx);
        _ = qjs.addList(ctx, event, &event_methods, event_methods.len);
        const target = element(ctx, node);
        _ = qjs.setStr(ctx, event, "type", qjs.newString(ctx, kind.ptr, kind.len));
        _ = qjs.setStr(ctx, event, "target", qjs.dup(ctx, target));
        // A handler may add or remove listeners, which can move or free the
        // watches array. Take owned references to this event's handlers first:
        // additions wait for the next event and removals cannot invalidate the
        // slice being walked now.
        var handlers: std.ArrayList(Value) = .empty;
        defer {
            for (handlers.items) |handler| qjs.free(ctx, handler);
            handlers.deinit(gpa);
        }
        for (it.watches.items) |watch| {
            if (watch.node != each or !std.mem.eql(u8, watch.kind, kind)) continue;
            handlers.append(gpa, qjs.dup(ctx, watch.handler)) catch continue;
        }
        for (handlers.items) |handler| {
            const called = qjs.call(ctx, handler, target, 1, &[_]Value{event});
            if (qjs.isException(called) != 0) reportError(ctx);
            qjs.free(ctx, called);
        }
        qjs.free(ctx, target);
        qjs.free(ctx, event);
        at = if (climb) lexbor.lexbor_parent(each) else null;
    }
}

fn jsClick(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    _ = argv;
    if (nodeOf(this)) |node| tell(ctx, node, "click", true);
    return qjs.undefinedValue();
}

fn jsAttachShadow(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    _ = argv;
    return qjs.dup(ctx, this);
}

// ---------------------------------------------------------------------------
// What a page asks for and this reader has nothing to say about
// ---------------------------------------------------------------------------

/// Nothing at all: given rather than left out, since a script that finds no
/// `scrollIntoView` stops where one that finds one which does nothing goes on.
fn jsNothing(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = ctx;
    _ = this;
    _ = argc;
    _ = argv;
    return qjs.undefinedValue();
}

fn jsYes(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    return qjs.newBool(ctx, 1);
}

/// A size and a place, as nothing: this reader sets a page in one column and
/// keeps no geometry, so where something is, is noughts rather than a guess.
fn jsBox(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    missing(ctx, "getBoundingClientRect");
    const box = qjs.newObject(ctx);
    inline for (.{ "x", "y", "width", "height", "top", "left", "right", "bottom" }) |side| {
        _ = qjs.setStr(ctx, box, side, qjs.newInt(ctx, 0));
    }
    return box;
}

/// The style a page has been given, read as an empty one: what the cascade
/// made of it is not a thing a script can be told here yet.
fn jsComputed(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    missing(ctx, "getComputedStyle");
    const style = qjs.newObject(ctx);
    _ = qjs.addList(ctx, style, &style_methods, style_methods.len);
    return style;
}

/// An observer: a page may watch for something to happen, and nothing it can
/// watch for ever happens here, so it is given one that watches and is silent.
fn jsWatcher(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    missing(ctx, "observers");
    const watcher = qjs.newObject(ctx);
    inline for (.{ "observe", "unobserve", "disconnect", "takeRecords" }) |call| {
        _ = qjs.setStr(ctx, watcher, call, qjs.function(ctx, @ptrCast(&jsNothing), call, 0, .generic, 0));
    }
    return watcher;
}

/// A browser base class. The reader's nodes are handed to scripts as objects
/// rather than constructed through these classes, but component bootstraps
/// legitimately extend `HTMLElement`/`EventTarget` before they touch a node.
/// A constructable empty object lets those classes initialise; the DOM-facing
/// methods remain on objects the document hands out.
fn jsPlatformClass(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    return qjs.newObject(ctx);
}

fn jsParamsGet(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = ctx;
    _ = this;
    _ = argc;
    _ = argv;
    return qjs.nullValue();
}

fn jsParamsHas(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    return qjs.newBool(ctx, 0);
}

fn jsParamsText(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    return qjs.newString(ctx, "", 0);
}

const params_methods = [_]qjs.ListEntry{
    qjs.ListEntry.method("get", 1, &jsParamsGet),
    qjs.ListEntry.method("has", 1, &jsParamsHas),
    qjs.ListEntry.method("set", 2, &jsNothing),
    qjs.ListEntry.method("append", 2, &jsNothing),
    qjs.ListEntry.method("delete", 1, &jsNothing),
    qjs.ListEntry.method("toString", 0, &jsParamsText),
};

fn jsUrlParams(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    const params = qjs.newObject(ctx);
    _ = qjs.addList(ctx, params, &params_methods, params_methods.len);
    return params;
}

fn jsCustomElementDefine(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = ctx;
    _ = this;
    _ = argc;
    _ = argv;
    // Custom element construction is not a separate rendering pipeline yet,
    // but registering one must not stop the rest of the page from loading.
    return qjs.undefinedValue();
}

fn jsCustomElementGet(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = ctx;
    _ = this;
    _ = argc;
    _ = argv;
    return qjs.undefinedValue();
}

const custom_elements_methods = [_]qjs.ListEntry{
    qjs.ListEntry.method("define", 2, &jsCustomElementDefine),
    qjs.ListEntry.method("get", 1, &jsCustomElementGet),
};

// ---------------------------------------------------------------------------
// The element
// ---------------------------------------------------------------------------

fn jsId(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    return if (attributeOf(node, "id")) |got| qjs.newString(ctx, got.ptr, got.len) else qjs.nullValue();
}

fn jsSetId(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = words(ctx, value);
    defer freeWords(ctx, value, text);
    attributeSet(ctx, node, "id", text);
    return qjs.undefinedValue();
}

fn jsClassName(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    return if (attributeOf(node, "class")) |got| qjs.newString(ctx, got.ptr, got.len) else qjs.nullValue();
}

fn jsSetClassName(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = words(ctx, value);
    defer freeWords(ctx, value, text);
    attributeSet(ctx, node, "class", text);
    return qjs.undefinedValue();
}

fn jsTagName(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    var len: usize = 0;
    const name = lexbor.lxb_dom_element_tag_name(@ptrCast(node), &len) orelse return qjs.undefinedValue();
    return qjs.newString(ctx, @ptrCast(name), len);
}

fn jsParent(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.nullValue();
    const above = lexbor.lexbor_parent(node) orelse return qjs.nullValue();
    return element(ctx, above);
}

fn jsChildren(ctx: *Context, this: Value, elements_only: bool) Value {
    const node = nodeOf(this) orelse return qjs.newArray(ctx);
    const out = qjs.newArray(ctx);
    var at: u32 = 0;
    var each = lexbor.lexbor_first_child(node);
    while (each) |one| {
        defer each = lexbor.lexbor_next(one);
        if (elements_only and one.type != .element) continue;
        _ = qjs.setAt(ctx, out, at, element(ctx, one));
        at += 1;
    }
    return out;
}

fn jsChildElements(ctx: *Context, this: Value) callconv(.c) Value {
    return jsChildren(ctx, this, true);
}

fn jsChildNodes(ctx: *Context, this: Value) callconv(.c) Value {
    return jsChildren(ctx, this, false);
}

fn jsFirstChild(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.nullValue();
    const each = lexbor.lexbor_first_child(node) orelse return qjs.nullValue();
    return element(ctx, each);
}

fn jsLastChild(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.nullValue();
    var last: ?*lexbor.Node = null;
    var each = lexbor.lexbor_first_child(node);
    while (each) |one| {
        last = one;
        each = lexbor.lexbor_next(one);
    }
    return if (last) |one| element(ctx, one) else qjs.nullValue();
}

/// The next or previous *element*, skipping the text between them.
fn siblingElement(ctx: *Context, this: Value, comptime which: enum { next, previous }) Value {
    const node = nodeOf(this) orelse return qjs.nullValue();
    var each = switch (which) {
        .next => lexbor.lexbor_next(node),
        .previous => lexbor.lexbor_prev(node),
    };
    while (each) |one| {
        if (one.type == .element) return element(ctx, one);
        each = switch (which) {
            .next => lexbor.lexbor_next(one),
            .previous => lexbor.lexbor_prev(one),
        };
    }
    return qjs.nullValue();
}

fn jsNextElement(ctx: *Context, this: Value) callconv(.c) Value {
    return siblingElement(ctx, this, .next);
}

fn jsPreviousElement(ctx: *Context, this: Value) callconv(.c) Value {
    return siblingElement(ctx, this, .previous);
}

/// The neighbour, whatever it is: `nextSibling` says what stands next to an
/// element, text included, where `nextElementSibling` says the next element.
fn jsNextSibling(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.nullValue();
    return if (lexbor.lexbor_next(node)) |each| element(ctx, each) else qjs.nullValue();
}

fn jsPreviousSibling(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.nullValue();
    return if (lexbor.lexbor_prev(node)) |each| element(ctx, each) else qjs.nullValue();
}

fn jsValueOf(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    return if (attributeOf(node, "value")) |got| qjs.newString(ctx, got.ptr, got.len) else qjs.nullValue();
}

fn jsSetValue(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = words(ctx, value);
    defer freeWords(ctx, value, text);
    attributeSet(ctx, node, "value", text);
    return qjs.undefinedValue();
}

fn flagOf(node: *lexbor.Node, name: []const u8) bool {
    return lexbor.lxb_dom_element_has_attribute(@ptrCast(node), name.ptr, name.len);
}

fn flagSet(ctx: *Context, node: *lexbor.Node, name: []const u8, yes: bool) void {
    if (yes) {
        attributeSet(ctx, node, name, "");
    } else {
        _ = lexbor.lxb_dom_element_remove_attribute(@ptrCast(node), name.ptr, name.len);
        markChanged(ctx);
    }
}

fn jsChecked(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    return qjs.newBool(ctx, @intFromBool(flagOf(node, "checked")));
}

fn jsSetChecked(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    flagSet(ctx, node, "checked", qjs.truthOf(ctx, value) > 0);
    return qjs.undefinedValue();
}

fn jsDisabled(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    return qjs.newBool(ctx, @intFromBool(flagOf(node, "disabled")));
}

fn jsHidden(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    return qjs.newBool(ctx, @intFromBool(flagOf(node, "hidden")));
}

fn jsSetHidden(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    flagSet(ctx, node, "hidden", qjs.truthOf(ctx, value) > 0);
    return qjs.undefinedValue();
}

fn jsHref(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.nullValue();
    return if (attributeOf(node, "href")) |got| qjs.newString(ctx, got.ptr, got.len) else qjs.nullValue();
}

fn jsSrc(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.nullValue();
    return if (attributeOf(node, "src")) |got| qjs.newString(ctx, got.ptr, got.len) else qjs.nullValue();
}

fn jsNodeType(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    return qjs.newInt(ctx, @intFromEnum(node.type));
}

const node_methods = [_]qjs.ListEntry{
    qjs.ListEntry.method("getAttribute", 1, &jsGetAttribute),
    qjs.ListEntry.method("setAttribute", 2, &jsSetAttribute),
    qjs.ListEntry.method("hasAttribute", 1, &jsHasAttribute),
    qjs.ListEntry.method("removeAttribute", 1, &jsRemoveAttribute),
    qjs.ListEntry.method("toggleAttribute", 1, &jsToggleAttribute),
    qjs.ListEntry.method("appendChild", 1, &jsAppendChild),
    qjs.ListEntry.method("insertBefore", 2, &jsInsertBefore),
    qjs.ListEntry.method("replaceChild", 2, &jsReplaceChild),
    qjs.ListEntry.method("removeChild", 1, &jsRemoveChild),
    qjs.ListEntry.method("remove", 0, &jsRemove),
    qjs.ListEntry.method("prepend", 1, &jsPrepend),
    qjs.ListEntry.method("contains", 1, &jsContains),
    qjs.ListEntry.method("cloneNode", 1, &jsClone),
    qjs.ListEntry.method("insertAdjacentHTML", 2, &jsInsertHtml),
    qjs.ListEntry.method("removeEventListener", 2, &jsRemoveListener),
    qjs.ListEntry.method("submit", 0, &jsSubmit),
    qjs.ListEntry.method("requestSubmit", 0, &jsSubmit),
    qjs.ListEntry.method("addEventListener", 2, &jsAddListener),
    qjs.ListEntry.method("dispatchEvent", 1, &jsDispatchEvent),
    qjs.ListEntry.method("querySelector", 1, &jsQuerySelector),
    qjs.ListEntry.method("querySelectorAll", 1, &jsQuerySelectorAll),
    qjs.ListEntry.method("matches", 1, &jsMatches),
    qjs.ListEntry.method("closest", 1, &jsClosest),
    qjs.ListEntry.method("click", 0, &jsClick),
    qjs.ListEntry.method("attachShadow", 1, &jsAttachShadow),
    qjs.ListEntry.method("getBoundingClientRect", 0, &jsBox),
    qjs.ListEntry.method("scrollIntoView", 0, &jsScrollInto),
    qjs.ListEntry.method("focus", 0, &jsFocus),
    qjs.ListEntry.method("blur", 0, &jsBlur),
};

const node_gets = [_]qjs.ListEntry{
    qjs.ListEntry.accessor("textContent", &jsTextContent, &jsSetTextContent),
    qjs.ListEntry.accessor("innerHTML", &jsInnerHtml, &jsSetInnerHtml),
    qjs.ListEntry.accessor("innerText", &jsTextContent, &jsSetTextContent),
    qjs.ListEntry.accessor("id", &jsId, &jsSetId),
    qjs.ListEntry.accessor("className", &jsClassName, &jsSetClassName),
    qjs.ListEntry.accessor("classList", &jsClassList, null),
    qjs.ListEntry.accessor("style", &jsStyle, null),
    qjs.ListEntry.accessor("tagName", &jsTagName, null),
    qjs.ListEntry.accessor("nodeName", &jsTagName, null),
    qjs.ListEntry.accessor("nodeType", &jsNodeType, null),
    qjs.ListEntry.accessor("parentNode", &jsParent, null),
    qjs.ListEntry.accessor("parentElement", &jsParent, null),
    qjs.ListEntry.accessor("children", &jsChildElements, null),
    qjs.ListEntry.accessor("childNodes", &jsChildNodes, null),
    qjs.ListEntry.accessor("firstChild", &jsFirstChild, null),
    qjs.ListEntry.accessor("lastChild", &jsLastChild, null),
    qjs.ListEntry.accessor("firstElementChild", &jsFirstChild, null),
    qjs.ListEntry.accessor("lastElementChild", &jsLastChild, null),
    qjs.ListEntry.accessor("nextElementSibling", &jsNextElement, null),
    qjs.ListEntry.accessor("previousElementSibling", &jsPreviousElement, null),
    qjs.ListEntry.accessor("nextSibling", &jsNextSibling, null),
    qjs.ListEntry.accessor("previousSibling", &jsPreviousSibling, null),
    qjs.ListEntry.accessor("childElementCount", &jsChildElementCount, null),
    qjs.ListEntry.accessor("outerHTML", &jsOuterHtml, &jsSetOuterHtml),
    qjs.ListEntry.accessor("value", &jsValueOf, &jsSetValue),
    qjs.ListEntry.accessor("checked", &jsChecked, &jsSetChecked),
    qjs.ListEntry.accessor("disabled", &jsDisabled, null),
    qjs.ListEntry.accessor("hidden", &jsHidden, &jsSetHidden),
    qjs.ListEntry.accessor("href", &jsHref, null),
    qjs.ListEntry.accessor("src", &jsSrc, null),
    qjs.ListEntry.accessor("type", &jsType, null),
    qjs.ListEntry.accessor("name", &jsName, &jsSetName),
    qjs.ListEntry.accessor("title", &jsTitle2, null),
    qjs.ListEntry.accessor("alt", &jsAlt, null),
    qjs.ListEntry.accessor("placeholder", &jsPlaceholder, null),
    qjs.ListEntry.accessor("action", &jsAction, null),
    qjs.ListEntry.accessor("offsetWidth", &jsZero, null),
    qjs.ListEntry.accessor("offsetHeight", &jsZero, null),
    qjs.ListEntry.accessor("offsetTop", &jsZero, null),
    qjs.ListEntry.accessor("offsetLeft", &jsZero, null),
    qjs.ListEntry.accessor("clientWidth", &jsZero, null),
    qjs.ListEntry.accessor("clientHeight", &jsZero, null),
    qjs.ListEntry.accessor("scrollTop", &jsZero, null),
    qjs.ListEntry.accessor("scrollLeft", &jsZero, null),
};

// ---------------------------------------------------------------------------
// Asking for a page of your own
// ---------------------------------------------------------------------------

fn jsAnswerText(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    _ = argv;
    const body = qjs.getStr(ctx, this, "__body");
    defer qjs.free(ctx, body);
    const text = words(ctx, body);
    return qjs.newString(ctx, text.ptr, text.len);
}

fn jsAnswerJson(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    _ = argv;
    const body = qjs.getStr(ctx, this, "__body");
    defer qjs.free(ctx, body);
    const text = words(ctx, body);
    return qjs.parseJson(ctx, text.ptr, text.len, "<fetch>");
}

const answer_methods = [_]qjs.ListEntry{
    qjs.ListEntry.method("text", 0, &jsAnswerText),
    qjs.ListEntry.method("json", 0, &jsAnswerJson),
};

extern fn free(got: ?*anyopaque) void;

/// `fetch`: ask for a page, and come back with it. The asking is done there and
/// then, the reader having one way in and out of the network and a script's next
/// line often wanting the answer.
fn jsFetch(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    const it = page(ctx) orelse return qjs.undefinedValue();
    const asked = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], asked);
    const body = if (it.fetch) |call| call(it.taken, @ptrCast(asked.ptr)) else blk: {
        missing(ctx, "fetch");
        break :blk null;
    };
    const answer = qjs.newObject(ctx);
    _ = qjs.addList(ctx, answer, &answer_methods, answer_methods.len);
    _ = qjs.setStr(ctx, answer, "ok", qjs.newBool(ctx, @intFromBool(body != null)));
    _ = qjs.setStr(ctx, answer, "status", qjs.newInt(ctx, if (body != null) 200 else 0));
    _ = qjs.setStr(ctx, answer, "__body", qjs.newString(ctx, if (body) |got| got else "", if (body) |got| std.mem.len(got) else 0));
    if (body) |got| free(got);

    var resolvers: [2]Value = undefined;
    const promise = qjs.promise(ctx, &resolvers);
    const done = qjs.call(ctx, resolvers[0], qjs.undefinedValue(), 1, &[_]Value{answer});
    qjs.free(ctx, done);
    qjs.free(ctx, resolvers[0]);
    qjs.free(ctx, resolvers[1]);
    qjs.free(ctx, answer);
    return promise;
}

fn jsXhrOpen(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const asked = words(ctx, argv[1]);
    _ = qjs.setStr(ctx, this, "__url", qjs.newString(ctx, asked.ptr, asked.len));
    freeWords(ctx, argv[1], asked);
    _ = qjs.setStr(ctx, this, "readyState", qjs.newInt(ctx, 1));
    return qjs.undefinedValue();
}

fn jsXhrSend(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    _ = argv;
    var body: ?[*:0]u8 = null;
    {
        const asked = qjs.getStr(ctx, this, "__url");
        const name = words(ctx, asked);
        if (page(ctx)) |it| {
            if (it.fetch) |call| body = call(it.taken, @ptrCast(name.ptr));
        }
        freeWords(ctx, asked, name);
        qjs.free(ctx, asked);
    }
    _ = qjs.setStr(ctx, this, "readyState", qjs.newInt(ctx, 4));
    _ = qjs.setStr(ctx, this, "status", qjs.newInt(ctx, if (body != null) 200 else 0));
    _ = qjs.setStr(ctx, this, "responseText", qjs.newString(ctx, if (body) |got| got else "", if (body) |got| std.mem.len(got) else 0));
    if (body) |got| free(got);
    // What the page asked to be told with, where it asked.
    inline for (.{ "onreadystatechange", "onload" }) |held| {
        const told = qjs.getStr(ctx, this, held);
        if (qjs.isFunction(ctx, told) != 0) {
            const done = qjs.call(ctx, told, this, 0, null);
            qjs.free(ctx, done);
        }
        qjs.free(ctx, told);
    }
    return qjs.undefinedValue();
}

const xhr_methods = [_]qjs.ListEntry{
    qjs.ListEntry.method("open", 2, &jsXhrOpen),
    qjs.ListEntry.method("send", 0, &jsXhrSend),
};

fn jsNewXhr(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    const request = qjs.newObject(ctx);
    _ = qjs.addList(ctx, request, &xhr_methods, xhr_methods.len);
    _ = qjs.setStr(ctx, request, "readyState", qjs.newInt(ctx, 0));
    return request;
}

// ---------------------------------------------------------------------------
// What a page keeps
// ---------------------------------------------------------------------------

fn jsCookie(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    const it = page(ctx) orelse return qjs.newString(ctx, "", 0);
    if (it.cookie_read) |read| {
        var line: [8 * 1024]u8 = undefined;
        const len = @min(read(it.taken, @ptrCast(it.address.ptr), &line, line.len), line.len);
        return qjs.newString(ctx, &line, len);
    }
    var joined: std.ArrayList(u8) = .empty;
    for (it.crumbs.items, 0..) |crumb, at| {
        if (at > 0) joined.appendSlice(gpa, "; ") catch {};
        joined.appendSlice(gpa, crumb.name) catch {};
        joined.append(gpa, '=') catch {};
        joined.appendSlice(gpa, crumb.value) catch {};
    }
    defer joined.deinit(gpa);
    return qjs.newString(ctx, joined.items.ptr, joined.items.len);
}

fn jsSetCookie(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    _ = this;
    const it = page(ctx) orelse return qjs.undefinedValue();
    const given = words(ctx, value);
    defer freeWords(ctx, value, given);
    const cut = std.mem.indexOfScalar(u8, given, '=') orelse given.len;
    const name = given[0..cut];
    const what = if (cut < given.len) given[cut + 1 ..] else "";
    for (it.crumbs.items) |*crumb| {
        if (std.mem.eql(u8, crumb.name, name)) {
            gpa.free(crumb.value);
            crumb.value = keep(what);
            if (it.cookie_write) |write| write(it.taken, @ptrCast(it.address.ptr), @ptrCast(given.ptr));
            markChanged(ctx);
            return qjs.undefinedValue();
        }
    }
    it.crumbs.append(gpa, .{
        .name = keep(name),
        .value = keep(what),
        .domain = keep(it.address),
        .path = keep("/"),
    }) catch {};
    if (it.cookie_write) |write| write(it.taken, @ptrCast(it.address.ptr), @ptrCast(given.ptr));
    markChanged(ctx);
    return qjs.undefinedValue();
}

fn jsStoreGet(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    const it = page(ctx) orelse return qjs.nullValue();
    const key = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], key);
    return if (it.stored.get(key)) |got| qjs.newString(ctx, got.ptr, got.len) else qjs.nullValue();
}

fn jsStoreSet(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    const it = page(ctx) orelse return qjs.undefinedValue();
    const key = words(ctx, argv[0]);
    const value = words(ctx, argv[1]);
    it.stored.put(keep(key), keep(value)) catch {};
    freeWords(ctx, argv[0], key);
    freeWords(ctx, argv[1], value);
    return qjs.undefinedValue();
}

const store_methods = [_]qjs.ListEntry{
    qjs.ListEntry.method("getItem", 1, &jsStoreGet),
    qjs.ListEntry.method("setItem", 2, &jsStoreSet),
    qjs.ListEntry.method("removeItem", 1, &jsStoreRemove),
    qjs.ListEntry.method("clear", 0, &jsStoreClear),
    qjs.ListEntry.method("key", 1, &jsStoreKey),
};

const store_gets = [_]qjs.ListEntry{
    qjs.ListEntry.accessor("length", &jsStoreSize, null),
};

// ---------------------------------------------------------------------------
// Later
// ---------------------------------------------------------------------------

fn now(ctx: *Context) u32 {
    return (page(ctx) orelse return 0).clock();
}

fn jsSetTimer(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    if (argc < 2) return qjs.undefinedValue();
    if (qjs.isFunction(ctx, argv[0]) == 0) return qjs.undefinedValue();
    var after: i32 = 0;
    _ = qjs.toInt(ctx, &after, argv[1]);
    return schedule(ctx, argv[0], @intCast(@max(after, 0)), false);
}

fn schedule(ctx: *Context, handler: Value, after: u32, animation: bool) Value {
    const it = page(ctx) orelse return qjs.undefinedValue();
    it.next_timer += 1;
    it.timers.append(gpa, .{
        .id = it.next_timer,
        .handler = qjs.dup(ctx, handler),
        .due = now(ctx) + after,
        .every = 0,
        .animation = animation,
    }) catch return qjs.undefinedValue();
    return qjs.newUint(ctx, it.next_timer);
}

fn jsSetInterval(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc < 2) return qjs.undefinedValue();
    const it = page(ctx) orelse return qjs.undefinedValue();
    const before = it.timers.items.len;
    const made = jsSetTimer(ctx, this, argc, argv);
    if (it.timers.items.len > before) {
        var after: i32 = 0;
        _ = qjs.toInt(ctx, &after, argv[1]);
        it.timers.items[before].every = @intCast(@max(after, 0));
    }
    return made;
}

fn jsMicrotask(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    if (argc < 1 or qjs.isFunction(ctx, argv[0]) == 0) return qjs.undefinedValue();
    _ = schedule(ctx, argv[0], 0, false);
    return qjs.undefinedValue();
}

fn jsAnimationFrame(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    if (argc < 1 or qjs.isFunction(ctx, argv[0]) == 0) return qjs.undefinedValue();
    return schedule(ctx, argv[0], 16, true);
}

fn jsClearTimer(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    const it = page(ctx) orelse return qjs.undefinedValue();
    var wanted: i32 = 0;
    _ = qjs.toInt(ctx, &wanted, argv[0]);
    for (it.timers.items, 0..) |timer, at| {
        if (timer.id != @as(u32, @bitCast(wanted))) continue;
        qjs.free(ctx, timer.handler);
        _ = it.timers.orderedRemove(at);
        return qjs.undefinedValue();
    }
    return qjs.undefinedValue();
}

// ---------------------------------------------------------------------------
// What pages reach for by name
//
// Not one of these is in the shape of the tree -- they are what scripts on
// real pages say, and say far more often than the careful forms do. `input.type`
// rather than `getAttribute('type')`, `el.prepend` rather than
// `insertBefore(el.firstChild)`, `localStorage.removeItem` rather than a
// script keeping its own ledger. Each is a few lines over what the tree
// already gives, and a page that finds one where it expected it goes on
// where a page that finds none stops.
// ---------------------------------------------------------------------------

/// An attribute read as a property: `input.type`, `img.alt`, `a.title`, and
/// the rest, which a page says far more often than `getAttribute`.
fn valueOfAttribute(ctx: *Context, this: Value, name: []const u8) Value {
    const node = nodeOf(this) orelse return qjs.nullValue();
    return if (attributeOf(node, name)) |got| qjs.newString(ctx, got.ptr, got.len) else qjs.nullValue();
}

fn jsType(ctx: *Context, this: Value) callconv(.c) Value {
    return valueOfAttribute(ctx, this, "type");
}

fn jsName(ctx: *Context, this: Value) callconv(.c) Value {
    return valueOfAttribute(ctx, this, "name");
}

fn jsSetName(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = words(ctx, value);
    defer freeWords(ctx, value, text);
    attributeSet(ctx, node, "name", text);
    return qjs.undefinedValue();
}

fn jsTitle2(ctx: *Context, this: Value) callconv(.c) Value {
    return valueOfAttribute(ctx, this, "title");
}

fn jsAlt(ctx: *Context, this: Value) callconv(.c) Value {
    return valueOfAttribute(ctx, this, "alt");
}

fn jsPlaceholder(ctx: *Context, this: Value) callconv(.c) Value {
    return valueOfAttribute(ctx, this, "placeholder");
}

fn jsAction(ctx: *Context, this: Value) callconv(.c) Value {
    return valueOfAttribute(ctx, this, "action");
}

fn jsChildElementCount(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.newInt(ctx, 0);
    var count: u32 = 0;
    var each = lexbor.lexbor_first_child(node);
    while (each) |one| {
        defer each = lexbor.lexbor_next(one);
        if (one.type == .element) count += 1;
    }
    return qjs.newUint(ctx, count);
}

/// Put `child` first, before whatever is there.
fn jsPrepend(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const child = nodeOf(argv[0]) orelse return qjs.undefinedValue();
    if (lexbor.lexbor_first_child(node)) |first| {
        if (lexbor.lxb_dom_node_insert_before_spec(node, child, first) != .ok) return qjs.undefinedValue();
    } else {
        if (lexbor.lxb_dom_node_append_child(node, child) != .ok) return qjs.undefinedValue();
    }
    markChanged(ctx);
    return qjs.dup(ctx, argv[0]);
}

/// Whether one element stands inside another.
fn jsContains(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    var at = nodeOf(argv[0]) orelse return qjs.newBool(ctx, 0);
    while (true) {
        if (at == node) return qjs.newBool(ctx, 1);
        at = lexbor.lexbor_parent(at) orelse return qjs.newBool(ctx, 0);
    }
}

fn jsClone(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.nullValue();
    const deep = argc > 0 and qjs.truthOf(ctx, argv[0]) > 0;
    const made = lexbor.lxb_dom_node_clone(node, deep) orelse return qjs.nullValue();
    return element(ctx, made);
}

/// Markup put beside an element, or inside it at either end, as a page says
/// with `insertAdjacentHTML`.
fn jsInsertHtml(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc < 2) return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const it = page(ctx) orelse return qjs.undefinedValue();
    const where = words(ctx, argv[0]);
    const markup = words(ctx, argv[1]);
    const held = lexbor.lxb_html_document_parse_fragment(it.tree, node, markup.ptr, markup.len) orelse {
        freeWords(ctx, argv[0], where);
        freeWords(ctx, argv[1], markup);
        return qjs.undefinedValue();
    };
    var each = lexbor.lexbor_first_child(held);
    while (each) |one| {
        const next = lexbor.lexbor_next(one);
        _ = lexbor.lxb_dom_node_remove(one);
        if (std.mem.eql(u8, where, "beforebegin")) {
            _ = lexbor.lxb_dom_node_insert_before(node, one);
        } else if (std.mem.eql(u8, where, "afterend")) {
            if (lexbor.lexbor_next(node)) |after| {
                _ = lexbor.lxb_dom_node_insert_before(after, one);
            } else if (lexbor.lexbor_parent(node)) |above| {
                _ = lexbor.lxb_dom_node_append_child(above, one);
            }
        } else if (std.mem.eql(u8, where, "afterbegin")) {
            if (lexbor.lexbor_first_child(node)) |first| {
                _ = lexbor.lxb_dom_node_insert_before(first, one);
            } else {
                _ = lexbor.lxb_dom_node_append_child(node, one);
            }
        } else {
            _ = lexbor.lxb_dom_node_append_child(node, one);
        }
        each = next;
    }
    freeWords(ctx, argv[0], where);
    freeWords(ctx, argv[1], markup);
    markChanged(ctx);
    return qjs.undefinedValue();
}

/// Take away the listener a script put there: the very one, told by what it
/// is rather than by what it does.
fn jsRemoveListener(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc < 2) return qjs.undefinedValue();
    const it = page(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse (lexbor.lxb_dom_document_root(it.tree) orelse return qjs.undefinedValue());
    const kind = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], kind);
    for (it.watches.items, 0..) |watch, at| {
        if (watch.node != node or !std.mem.eql(u8, watch.kind, kind)) continue;
        if (qjs.sameAs(ctx, watch.handler, argv[1]) == 0) continue;
        gpa.free(watch.kind);
        qjs.free(ctx, watch.handler);
        _ = it.watches.orderedRemove(at);
        return qjs.undefinedValue();
    }
    return qjs.undefinedValue();
}

/// Replace the element itself with markup, as `outerHTML` written to says.
fn jsSetOuterHtml(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const it = page(ctx) orelse return qjs.undefinedValue();
    const above = lexbor.lexbor_parent(node) orelse return qjs.undefinedValue();
    const markup = words(ctx, value);
    defer freeWords(ctx, value, markup);
    const held = lexbor.lxb_html_document_parse_fragment(it.tree, node, markup.ptr, markup.len) orelse return qjs.undefinedValue();
    var each = lexbor.lexbor_first_child(held);
    while (each) |one| {
        const next = lexbor.lexbor_next(one);
        _ = lexbor.lxb_dom_node_remove(one);
        _ = lexbor.lxb_dom_node_insert_before(node, one);
        each = next;
    }
    _ = lexbor.lxb_dom_node_remove(node);
    _ = above;
    markChanged(ctx);
    return qjs.undefinedValue();
}

/// Nought: a size or a place this reader has nothing to say about, given
/// rather than left out so a page that asks does not stop.
fn jsZero(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return qjs.newInt(ctx, 0);
}

/// Not hidden: this reader shows one page at a time, and it is this one.
fn jsNotHidden(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return qjs.newBool(ctx, 0);
}

/// No, and nothing: what a page asking a question of a reader with no way to
/// answer it is told. `confirm` says no, `prompt` says nothing.
fn jsNo(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    return qjs.newBool(ctx, 0);
}

fn jsNone(_: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return qjs.nullValue();
}

/// Asked of a reader with no way to answer: a page's `scrollIntoView`, its
/// `focus` and `blur`, its `alert` and `confirm` and `prompt`, and its
/// walking of a history this reader does not keep. Each says what it was.
fn jsScrollInto(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    missing(ctx, "scrollIntoView");
    return jsNothing(ctx, this, argc, argv);
}

fn jsFocus(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    missing(ctx, "focus");
    return jsNothing(ctx, this, argc, argv);
}

fn jsBlur(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    missing(ctx, "blur");
    return jsNothing(ctx, this, argc, argv);
}

fn jsAlert(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    missing(ctx, "alert");
    return jsNothing(ctx, this, argc, argv);
}

fn jsConfirm(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    missing(ctx, "confirm");
    return jsNothing(ctx, this, argc, argv);
}

fn jsPrompt(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    missing(ctx, "prompt");
    return jsNothing(ctx, this, argc, argv);
}

fn jsHistory(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    missing(ctx, "history");
    return jsNothing(ctx, this, argc, argv);
}

/// The clock, as a page asks for it: thousandths of a second since the
/// machine was started.
fn jsNow(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    return qjs.newUint(ctx, now(ctx));
}

/// What a page asks a media query, which a reader with one column and no
/// window to resize can only answer one way.
fn jsMedia(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    const media = qjs.newObject(ctx);
    _ = qjs.setStr(ctx, media, "matches", qjs.newBool(ctx, 0));
    if (argc > 0) {
        const asked = words(ctx, argv[0]);
        defer freeWords(ctx, argv[0], asked);
        _ = qjs.setStr(ctx, media, "media", qjs.newString(ctx, asked.ptr, asked.len));
    } else {
        _ = qjs.setStr(ctx, media, "media", qjs.newString(ctx, "", 0));
    }
    inline for (.{ "addListener", "removeListener", "addEventListener", "removeEventListener" }) |call| {
        _ = qjs.setStr(ctx, media, call, qjs.function(ctx, @ptrCast(&jsNothing), call, 0, .generic, 0));
    }
    return media;
}

// ---------------------------------------------------------------------------
// The document, and the collections in it
// ---------------------------------------------------------------------------

/// Where the page is, as the document says it: the same as the window's
/// `location`, which is where a page looks for it half the time.
fn jsLocationOf(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return locationOf(ctx);
}

/// The page is read: a script run at the end of a parse is not one waiting
/// for it.
fn jsReadyState(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return qjs.newString(ctx, "complete", 8);
}

/// Where the page came from, as the document says it where `location` says it
/// for the window.
fn jsUrl(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    const it = page(ctx) orelse return qjs.newString(ctx, "", 0);
    return qjs.newString(ctx, it.address.ptr, it.address.len);
}

/// A page is not hidden: this reader shows one page at a time, and it is
/// this one.
fn jsVisible(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return qjs.newString(ctx, "visible", 7);
}

/// The elements of a kind, as the document gathers them: `document.forms`,
/// `document.images`, `document.links`, `document.scripts`.
fn collectionOf(ctx: *Context, tag: []const u8) Value {
    return byName(ctx, .tag, tag);
}

fn jsForms(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return collectionOf(ctx, "form");
}

fn jsImages(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return collectionOf(ctx, "img");
}

fn jsLinks(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return collectionOf(ctx, "a");
}

fn jsScripts(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return collectionOf(ctx, "script");
}

/// Every element carrying a name, as `getElementsByName` asks.
fn jsGetByName(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    const it = page(ctx) orelse return qjs.newArray(ctx);
    const root = lexbor.lxb_dom_document_root(it.tree) orelse return qjs.newArray(ctx);
    const held = lexbor.lxb_dom_collection_create(it.tree) orelse return qjs.newArray(ctx);
    defer _ = lexbor.lxb_dom_collection_destroy(held, true);
    if (lexbor.lxb_dom_collection_init(held, 8) != .ok) return qjs.newArray(ctx);
    const name = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], name);
    if (lexbor.lxb_dom_elements_by_attr(@ptrCast(root), held, "name", 4, name.ptr, name.len, false) != .ok) return qjs.newArray(ctx);
    var found: Found = .{ .nodes = .empty };
    defer found.nodes.deinit(gpa);
    for (0..lexbor.lexbor_collection_length(held)) |at| {
        const each = lexbor.lexbor_collection_element(held, at) orelse continue;
        found.nodes.append(gpa, @ptrCast(@alignCast(each))) catch {};
    }
    return gathered(ctx, &found, .all);
}

// ---------------------------------------------------------------------------
// What a page puts by, and takes away again
// ---------------------------------------------------------------------------

fn jsStoreRemove(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    const it = page(ctx) orelse return qjs.undefinedValue();
    const key = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], key);
    if (it.stored.fetchRemove(key)) |gone| {
        gpa.free(gone.key);
        gpa.free(gone.value);
    }
    return qjs.undefinedValue();
}

fn jsStoreClear(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    _ = argv;
    const it = page(ctx) orelse return qjs.undefinedValue();
    var keys = it.stored.keyIterator();
    while (keys.next()) |key| gpa.free(key.*);
    var values = it.stored.valueIterator();
    while (values.next()) |value| gpa.free(value.*);
    it.stored.clearRetainingCapacity();
    return qjs.undefinedValue();
}

fn jsStoreKey(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    const it = page(ctx) orelse return qjs.nullValue();
    var wanted: i32 = 0;
    _ = qjs.toInt(ctx, &wanted, argv[0]);
    var at: i32 = 0;
    var keys = it.stored.keyIterator();
    while (keys.next()) |key| {
        if (at == wanted) return qjs.newString(ctx, key.ptr, key.len);
        at += 1;
    }
    return qjs.nullValue();
}

fn jsStoreSize(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    const it = page(ctx) orelse return qjs.newInt(ctx, 0);
    return qjs.newUint(ctx, @intCast(it.stored.count()));
}

/// The window a page stands in: what is true of any window, whether or not
/// this reader has one to show. A history it cannot walk, a screen it is
/// drawn on, a clock, and no way to ask a question of the person reading.
fn furnish(ctx: *Context, global: Value) void {
    const history = qjs.newObject(ctx);
    inline for (.{ "back", "forward", "go", "pushState", "replaceState" }) |call| {
        _ = qjs.setStr(ctx, history, call, qjs.function(ctx, @ptrCast(&jsHistory), call, 0, .generic, 0));
    }
    _ = qjs.setStr(ctx, history, "length", qjs.newInt(ctx, 0));
    _ = qjs.setStr(ctx, global, "history", history);

    const screen = qjs.newObject(ctx);
    inline for (.{ "width", "height", "availWidth", "availHeight" }) |side| {
        _ = qjs.setStr(ctx, screen, side, qjs.newInt(ctx, 800));
    }
    _ = qjs.setStr(ctx, screen, "colorDepth", qjs.newInt(ctx, 24));
    _ = qjs.setStr(ctx, global, "screen", screen);

    const clock = qjs.newObject(ctx);
    _ = qjs.setStr(ctx, clock, "now", qjs.function(ctx, @ptrCast(&jsNow), "now", 0, .generic, 0));
    _ = qjs.setStr(ctx, global, "performance", clock);

    inline for (.{
        .{ "matchMedia", &jsMedia, 1 },
        .{ "alert", &jsAlert, 1 },
        .{ "confirm", &jsConfirm, 1 },
        .{ "prompt", &jsPrompt, 1 },
    }) |one| {
        _ = qjs.setStr(ctx, global, one.@"0", qjs.function(ctx, @ptrCast(one.@"1"), one.@"0", one.@"2", .generic, 0));
    }
}

// ---------------------------------------------------------------------------
// A form sent by a script
// ---------------------------------------------------------------------------

/// The tag of an element, as words.
fn tagOf(node: *lexbor.Node) []const u8 {
    var len: usize = 0;
    const name = lexbor.lxb_dom_element_tag_name(@ptrCast(node), &len) orelse return "";
    return (@as([*:0]const u8, @ptrCast(name)))[0..len];
}

fn isTag(node: *lexbor.Node, want: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tagOf(node), want);
}

/// Written into an address, which is not allowed to say everything: what a
/// space becomes, and what anything else that an address means by something
/// becomes.
fn encoded(out: *std.ArrayList(u8), text: []const u8) void {
    for (text) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => out.append(gpa, byte) catch {},
            ' ' => out.append(gpa, '+') catch {},
            else => out.print(gpa, "%{X:0>2}", .{byte}) catch {},
        }
    }
}

/// Every answer in `node`'s subtree that goes under a name: a form's own
/// controls, which is what a form sends.
fn answersIn(node: *lexbor.Node, out: *std.ArrayList(u8), count: *usize) void {
    var each = lexbor.lexbor_first_child(node);
    while (each) |one| {
        const next = lexbor.lexbor_next(one);
        defer each = next;
        if (one.type == .element) {
            const kind = isTag(one, "input") or isTag(one, "select") or isTag(one, "textarea");
            if (kind) {
                if (attributeOf(one, "name")) |named| {
                    if (count.* > 0) out.append(gpa, '&') catch {};
                    encoded(out, named);
                    out.append(gpa, '=') catch {};
                    if (attributeOf(one, "value")) |value| {
                        encoded(out, value);
                    } else {
                        const text = textOfNode(one);
                        defer text.deinit();
                        encoded(out, text.bytes);
                    }
                    count.* += 1;
                }
            }
        }
        answersIn(one, out, count);
    }
}

/// The form an element belongs to, which is itself where it is one.
fn formOf(node: *lexbor.Node) ?*lexbor.Node {
    var at = node;
    while (true) {
        if (at.type == .element and isTag(at, "form")) return at;
        at = lexbor.lexbor_parent(at) orelse return null;
    }
}

/// `form.submit()`: a page sending its own form, which is what a page that
/// says "click here if you are not redirected" is really doing -- the script
/// sends it, and the answer comes back as a page.
///
/// Sent the way the form says, as far as this reader can: in the address, as
/// its query, which is how a search is sent. Sent in the body of a request,
/// which is how logging in is done, is a thing this reader cannot do from
/// here yet, and says so.
fn jsSubmit(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    _ = argv;
    const it = page(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const form = formOf(node) orelse return qjs.undefinedValue();
    tell(ctx, form, "submit", true);
    if ((page(ctx) orelse return qjs.undefinedValue()).prevented) return qjs.undefinedValue();

    const how = attributeOf(form, "method") orelse "get";
    if (std.ascii.eqlIgnoreCase(how, "post")) {
        missing(ctx, "a form sent by post");
        return qjs.undefinedValue();
    }
    const action = attributeOf(form, "action") orelse it.address;

    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(gpa);
    var count: usize = 0;
    answersIn(form, &query, &count);

    var where: std.ArrayList(u8) = .empty;
    defer where.deinit(gpa);
    where.appendSlice(gpa, action) catch return qjs.undefinedValue();
    if (count > 0) {
        where.append(gpa, '?') catch return qjs.undefinedValue();
        where.appendSlice(gpa, query.items) catch return qjs.undefinedValue();
    }
    const asked = where.toOwnedSliceSentinel(gpa, 0) catch return qjs.undefinedValue();
    defer gpa.free(asked);
    if (it.go) |call| call(it.taken, asked.ptr);
    return qjs.undefinedValue();
}

// ---------------------------------------------------------------------------
// Binding, loading, telling
// ---------------------------------------------------------------------------

/// `new URL(reference, base)`: the reader's tested URL resolver in the
/// browser shape scripts expect. It names both the complete resolved address
/// and the parts a page commonly inspects.
fn jsNewUrl(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    if (argc == 0) return qjs.nullValue();
    const reference = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], reference);
    var resolved: [url.ADDRESS_MAX]u8 = undefined;
    const whole = if (url.parse(reference) != null) reference else base: {
        const base_text = if (argc > 1) words(ctx, argv[1]) else (page(ctx) orelse return qjs.nullValue()).address;
        defer if (argc > 1) freeWords(ctx, argv[1], base_text);
        const base_url = url.parse(base_text) orelse return qjs.nullValue();
        break :base url.resolve(base_url, reference, &resolved) orelse return qjs.nullValue();
    };
    const parsed = url.parse(whole) orelse return qjs.nullValue();
    var href: [url.ADDRESS_MAX]u8 = undefined;
    const canonical = std.fmt.bufPrint(&href, "{f}", .{parsed}) catch return qjs.nullValue();
    const out = qjs.newObject(ctx);
    _ = qjs.setStr(ctx, out, "href", qjs.newString(ctx, canonical.ptr, canonical.len));

    var protocol: [16]u8 = undefined;
    const scheme = std.fmt.bufPrint(&protocol, "{s}:", .{@tagName(parsed.scheme)}) catch "";
    _ = qjs.setStr(ctx, out, "protocol", qjs.newString(ctx, scheme.ptr, scheme.len));
    var host: [url.ADDRESS_MAX]u8 = undefined;
    var host_writer: std.Io.Writer = .fixed(&host);
    parsed.writeHost(&host_writer) catch return out;
    const host_text = host_writer.buffered();
    _ = qjs.setStr(ctx, out, "host", qjs.newString(ctx, host_text.ptr, host_text.len));
    _ = qjs.setStr(ctx, out, "hostname", qjs.newString(ctx, parsed.host.ptr, parsed.host.len));
    var origin: [url.ADDRESS_MAX]u8 = undefined;
    const origin_text = std.fmt.bufPrint(&origin, "{s}://{s}", .{ @tagName(parsed.scheme), host_text }) catch "";
    _ = qjs.setStr(ctx, out, "origin", qjs.newString(ctx, origin_text.ptr, origin_text.len));
    const query_at = std.mem.indexOfScalar(u8, parsed.path, '?') orelse parsed.path.len;
    const path = if (query_at == 0) "/" else parsed.path[0..query_at];
    _ = qjs.setStr(ctx, out, "pathname", qjs.newString(ctx, path.ptr, path.len));
    _ = qjs.setStr(ctx, out, "search", qjs.newString(ctx, parsed.path[query_at..].ptr, parsed.path.len - query_at));
    _ = qjs.setStr(ctx, out, "hash", qjs.newString(ctx, "", 0));
    _ = qjs.setStr(ctx, out, "toString", qjs.function(ctx, @ptrCast(&jsUrlString), "toString", 0, .generic, 0));
    return out;
}

fn jsUrlString(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    _ = argv;
    return qjs.getStr(ctx, this, "href");
}

fn reportError(ctx: *Context) void {
    const it = page(ctx) orelse return;
    const exception = qjs.exceptionOf(ctx);
    defer qjs.free(ctx, exception);
    // The exception says what was missing. The stack begins with a minified
    // function name and a column tens of thousands of bytes into a script,
    // which is useful only after the missing operation is known.
    const text = qjs.textOf(ctx, exception) orelse {
        if (it.error_last.len > 0) gpa.free(it.error_last);
        it.error_last = keep("an exception");
        return;
    };
    defer qjs.freeText(ctx, text);
    if (it.error_last.len > 0) gpa.free(it.error_last);
    it.error_last = keep(std.mem.span(text));
}

fn nothingGone(rt: *qjs.Runtime, value: Value) callconv(.c) void {
    _ = rt;
    _ = value;
}

const class_def = qjs.ClassDef{
    .class_name = "Node",
    .finalizer = &nothingGone,
    .gc_mark = null,
    .call = null,
    .exotic = null,
};

export fn dom_bind(
    ctx: *Context,
    tree: *lexbor.Document,
    address: [*:0]const u8,
    user_agent: [*:0]const u8,
    fetch: ?Fetch,
    taken: ?*anyopaque,
    clock: Clock,
    go: ?Go,
    cookie_read: ?CookieRead,
    cookie_write: ?CookieWrite,
) bool {
    heap_of = .{ .ctx = ctx };
    gpa = heap_of.allocator();
    const it = gpa.create(Page) catch return false;
    it.* = .{
        .tree = tree,
        .address = keep(std.mem.span(address)),
        .user_agent = keep(std.mem.span(user_agent)),
        .fetch = fetch,
        .go = go,
        .cookie_read = cookie_read,
        .cookie_write = cookie_write,
        .taken = taken,
        .clock = clock,
        .stored = std.StringHashMap([]const u8).init(gpa),
        .noted = std.StringHashMap(void).init(gpa),
    };

    const rt = qjs.runtimeOf(ctx);
    // Once per runtime, and not once per page: a class belongs to the
    // runtime, and one made again for every page is one the runtime keeps
    // holding, page after page.
    if (class_for != rt) {
        qjs.newClassId(&node_class);
        _ = qjs.newClass(rt, node_class, &class_def);
        class_for = rt;
    }

    it.css = lexbor.lxb_css_memory_create();
    if (lexbor.lxb_css_parser_create()) |parser| {
        _ = lexbor.lxb_css_parser_init(parser, null);
        _ = lexbor.lxb_css_parser_selectors_init(parser);
        it.parser = parser;
    }
    if (lexbor.lxb_selectors_create()) |engine| {
        _ = lexbor.lxb_selectors_init(engine);
        it.selectors = engine;
    }
    qjs.setHeld(ctx, it);

    const global = qjs.globalOf(ctx);
    defer qjs.free(ctx, global);

    const document = qjs.newObject(ctx);
    _ = qjs.addList(ctx, document, &document_methods, document_methods.len);
    _ = qjs.addList(ctx, document, &document_gets, document_gets.len);
    const implementation = qjs.newObject(ctx);
    _ = qjs.setStr(ctx, implementation, "hasFeature", qjs.function(ctx, @ptrCast(&jsYes), "hasFeature", 2, .generic, 0));
    _ = qjs.setStr(ctx, document, "implementation", implementation);
    _ = qjs.setStr(ctx, global, "document", document);
    // The window is the world a script stands in, which is the one the
    // document hangs from: `window.x` and `x` are the same thing, as a page
    // expects them to be. Given as a getter rather than as a copy of the
    // global: a copy is the global holding itself, which is a knot the
    // engine cannot undo when the page is freed, and it says so.
    inline for (.{ "window", "self", "top", "parent" }) |one| {
        const atom = qjs.atomOf(ctx, one);
        defer qjs.freeAtom(ctx, atom);
        _ = qjs.addAccessor(
            ctx,
            global,
            atom,
            qjs.function(ctx, @ptrCast(&jsWindowHere), one, 0, .getter, 0),
            qjs.undefinedValue(),
            qjs.flags.accessor,
        );
    }
    furnish(ctx, global);

    const location = qjs.atomOf(ctx, "location");
    defer qjs.freeAtom(ctx, location);
    _ = qjs.addAccessor(
        ctx,
        global,
        location,
        qjs.function(ctx, @ptrCast(&jsLocationHere), "location", 0, .getter, 0),
        qjs.function(ctx, @ptrCast(&jsSetLocation), "location", 1, .setter, 0),
        qjs.flags.accessor,
    );
    const who = qjs.newObject(ctx);
    _ = qjs.setStr(ctx, who, "userAgent", qjs.newString(ctx, it.user_agent.ptr, it.user_agent.len));
    // A page testing whether its redirect may use cookies or the network is
    // testing capabilities, not whether it happens to know this reader's
    // name. These are the capabilities the document above actually has.
    _ = qjs.setStr(ctx, who, "cookieEnabled", qjs.newBool(ctx, 1));
    _ = qjs.setStr(ctx, who, "onLine", qjs.newBool(ctx, 1));
    _ = qjs.setStr(ctx, who, "language", qjs.newString(ctx, "en", 2));
    _ = qjs.setStr(ctx, global, "navigator", who);

    // Consent-management bootstraps ask for an invisible locator in
    // `window.frames` before they make it. This reader has no nested browsing
    // contexts yet, but an empty frames object lets that bootstrap proceed
    // rather than throwing while it asks the question.
    const frames = qjs.newObject(ctx);
    _ = qjs.setStr(ctx, frames, "length", qjs.newInt(ctx, 0));
    _ = qjs.setStr(ctx, global, "frames", frames);
    _ = qjs.setStr(ctx, global, "postMessage", qjs.function(ctx, @ptrCast(&jsNothing), "postMessage", 2, .generic, 0));

    const store = qjs.newObject(ctx);
    _ = qjs.addList(ctx, store, &store_methods, store_methods.len);
    _ = qjs.addList(ctx, store, &store_gets, store_gets.len);
    _ = qjs.setStr(ctx, global, "localStorage", store);
    _ = qjs.setStr(ctx, global, "sessionStorage", qjs.dup(ctx, store));

    inline for (.{
        .{ "setTimeout", &jsSetTimer },
        .{ "setInterval", &jsSetInterval },
        .{ "clearTimeout", &jsClearTimer },
        .{ "clearInterval", &jsClearTimer },
        .{ "fetch", &jsFetch },
        .{ "requestAnimationFrame", &jsAnimationFrame },
        .{ "queueMicrotask", &jsMicrotask },
        .{ "getComputedStyle", &jsComputed },
        .{ "addEventListener", &jsAddListener },
        .{ "removeEventListener", &jsRemoveListener },
        .{ "dispatchEvent", &jsDispatchEvent },
        .{ "open", &jsNone },
        .{ "close", &jsNothing },
        .{ "scrollTo", &jsNothing },
        .{ "scrollBy", &jsNothing },
    }) |one| {
        _ = qjs.setStr(ctx, global, one.@"0", qjs.function(ctx, @ptrCast(one.@"1"), one.@"0", 1, .generic, 0));
    }
    _ = qjs.setStr(ctx, global, "XMLHttpRequest", qjs.function(ctx, @ptrCast(&jsNewXhr), "XMLHttpRequest", 0, .constructor_or_func, 0));
    _ = qjs.setStr(ctx, global, "URL", qjs.function(ctx, @ptrCast(&jsNewUrl), "URL", 2, .constructor_or_func, 0));
    _ = qjs.setStr(ctx, global, "URLSearchParams", qjs.function(ctx, @ptrCast(&jsUrlParams), "URLSearchParams", 1, .constructor_or_func, 0));
    _ = qjs.setStr(ctx, global, "Event", qjs.function(ctx, @ptrCast(&jsNewEvent), "Event", 1, .constructor_or_func, 0));
    _ = qjs.setStr(ctx, global, "CustomEvent", qjs.function(ctx, @ptrCast(&jsNewCustomEvent), "CustomEvent", 2, .constructor_or_func, 0));
    _ = qjs.setStr(ctx, global, "AbortController", qjs.function(ctx, @ptrCast(&jsAbortController), "AbortController", 0, .constructor_or_func, 0));
    inline for (.{ "MutationObserver", "IntersectionObserver", "ResizeObserver" }) |one| {
        _ = qjs.setStr(ctx, global, one, qjs.function(ctx, @ptrCast(&jsWatcher), one, 0, .constructor_or_func, 0));
    }
    // Component libraries commonly define classes before doing any DOM work.
    // These are the browser base constructors those definitions extend.
    inline for (.{
        "EventTarget",
        "Node",
        "Element",
        "HTMLElement",
        "Document",
        "HTMLDocument",
        "HTMLBodyElement",
        "HTMLDivElement",
        "HTMLIFrameElement",
        "HTMLFormElement",
        "HTMLInputElement",
        "HTMLButtonElement",
        "HTMLAnchorElement",
        "HTMLImageElement",
        "Image",
        "Text",
    }) |one| {
        const constructor = qjs.function(ctx, @ptrCast(&jsPlatformClass), one, 0, .constructor_or_func, 0);
        // `class Child extends HTMLElement` needs an object-valued prototype
        // on its parent constructor, even where this reader's elements are
        // supplied by the document rather than constructed through it.
        const prototype = qjs.newObject(ctx);
        // Svelte and similar renderers inspect descriptors on Node.prototype
        // before using the getters on actual document nodes. Put the reader's
        // node face on every browser-node base prototype: real nodes still
        // carry the same methods directly, while the descriptors are visible.
        if (std.mem.eql(u8, one, "Node") or std.mem.eql(u8, one, "Element") or std.mem.eql(u8, one, "HTMLElement") or std.mem.eql(u8, one, "Text")) {
            _ = qjs.addList(ctx, prototype, &node_methods, node_methods.len);
            _ = qjs.addList(ctx, prototype, &node_gets, node_gets.len);
        }
        _ = qjs.setStr(ctx, constructor, "prototype", prototype);
        _ = qjs.setStr(ctx, global, one, constructor);
    }
    const custom_elements = qjs.newObject(ctx);
    _ = qjs.addList(ctx, custom_elements, &custom_elements_methods, custom_elements_methods.len);
    _ = qjs.setStr(ctx, global, "customElements", custom_elements);
    return true;
}

pub fn bind(
    ctx: *Context,
    tree: *lexbor.Document,
    address: [*:0]const u8,
    user_agent: [*:0]const u8,
    fetch: ?Fetch,
    taken: ?*anyopaque,
    clock: Clock,
    go: ?Go,
    cookie_read: ?CookieRead,
    cookie_write: ?CookieWrite,
) bool {
    return dom_bind(ctx, tree, address, user_agent, fetch, taken, clock, go, cookie_read, cookie_write);
}

/// The page's location, as a script sees it: where it is, and the ways of
/// being sent somewhere else.
fn locationOf(ctx: *Context) Value {
    const it = page(ctx) orelse return qjs.nullValue();
    const where = whereOf(ctx, it.address);
    _ = qjs.addList(ctx, where, &where_methods, where_methods.len);
    _ = qjs.addList(ctx, where, &where_gets, where_gets.len);
    return where;
}

/// The window a script stands in, which is the world its globals are in.
fn jsWindowHere(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return qjs.globalOf(ctx);
}

fn jsLocationHere(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return locationOf(ctx);
}

/// `location = "..."`, and `window.location = "..."`, and
/// `document.location = "..."`: a page asking to be taken somewhere by
/// replacing the whole thing, which is how a great many of them say it and
/// not with `location.href`.
fn jsSetLocation(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    _ = this;
    const where = words(ctx, value);
    defer freeWords(ctx, value, where);
    if (page(ctx)) |it| {
        if (std.mem.eql(u8, where, it.address)) return qjs.undefinedValue();
        if (it.go) |call| call(it.taken, @ptrCast(where.ptr));
    }
    return qjs.undefinedValue();
}

/// Where the page is, as a script may change it: writing `location.href` is
/// asking to be taken there, which is what a page that has moved says.
fn jsHrefOf(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    const it = page(ctx) orelse return qjs.newString(ctx, "", 0);
    return qjs.newString(ctx, it.address.ptr, it.address.len);
}

fn jsSetHref(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    _ = this;
    const where = words(ctx, value);
    defer freeWords(ctx, value, where);
    if (page(ctx)) |it| {
        // Asked for where it already is, it is not asked to go anywhere: a
        // page that sends the reader to itself is how a circle starts.
        if (std.mem.eql(u8, where, it.address)) return qjs.undefinedValue();
        if (it.go) |call| call(it.taken, @ptrCast(where.ptr));
    }
    return qjs.undefinedValue();
}

/// `location.assign` and `location.replace`, and `location.reload`: the ways
/// a page says go, and go again. Replace and reload are the same thing to a
/// reader that keeps no entry per script, as this one does not.
fn jsGoTo(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    const it = page(ctx) orelse return qjs.undefinedValue();
    const where = if (argc > 0) words(ctx, argv[0]) else it.address;
    if (argc > 0 and std.mem.eql(u8, where, it.address)) {
        freeWords(ctx, argv[0], where);
        return qjs.undefinedValue();
    }
    if (it.go) |call| call(it.taken, @ptrCast(where.ptr));
    if (argc > 0) freeWords(ctx, argv[0], where);
    return qjs.undefinedValue();
}

const where_methods = [_]qjs.ListEntry{
    qjs.ListEntry.method("assign", 1, &jsGoTo),
    qjs.ListEntry.method("replace", 1, &jsGoTo),
    qjs.ListEntry.method("reload", 0, &jsGoTo),
};

const where_gets = [_]qjs.ListEntry{
    qjs.ListEntry.accessor("href", &jsHrefOf, &jsSetHref),
};

/// Where the page is, as a script asks: the whole address, and the parts of it
/// a page picks apart.
fn whereOf(ctx: *Context, address: []const u8) Value {
    const where = qjs.newObject(ctx);
    const parsed = url.parse(address) orelse return where;
    var protocol: [16]u8 = undefined;
    const scheme = std.fmt.bufPrint(&protocol, "{s}:", .{@tagName(parsed.scheme)}) catch "";
    _ = qjs.setStr(ctx, where, "protocol", qjs.newString(ctx, scheme.ptr, scheme.len));
    var host: [url.ADDRESS_MAX]u8 = undefined;
    var host_writer: std.Io.Writer = .fixed(&host);
    parsed.writeHost(&host_writer) catch return where;
    const host_text = host_writer.buffered();
    _ = qjs.setStr(ctx, where, "host", qjs.newString(ctx, host_text.ptr, host_text.len));
    _ = qjs.setStr(ctx, where, "hostname", qjs.newString(ctx, parsed.host.ptr, parsed.host.len));
    var origin: [url.ADDRESS_MAX]u8 = undefined;
    const origin_text = std.fmt.bufPrint(&origin, "{s}://{s}", .{ @tagName(parsed.scheme), host_text }) catch "";
    _ = qjs.setStr(ctx, where, "origin", qjs.newString(ctx, origin_text.ptr, origin_text.len));
    const query_at = std.mem.indexOfScalar(u8, parsed.path, '?') orelse parsed.path.len;
    const path = if (query_at == 0) "/" else parsed.path[0..query_at];
    _ = qjs.setStr(ctx, where, "pathname", qjs.newString(ctx, path.ptr, path.len));
    _ = qjs.setStr(ctx, where, "search", qjs.newString(ctx, parsed.path[query_at..].ptr, parsed.path.len - query_at));
    _ = qjs.setStr(ctx, where, "hash", qjs.newString(ctx, "", 0));
    return where;
}

/// Run one script: `node`'s own words, or what its `src` names, now that a
/// script may ask for a page.
fn runOne(ctx: *Context, node: *lexbor.Node) bool {
    if (attributeOf(node, "src")) |named| {
        const it = page(ctx) orelse return false;
        if (it.error_script.len > 0) gpa.free(it.error_script);
        it.error_script = keep(named);
        const got = (it.fetch orelse return false)(it.taken, @ptrCast(named.ptr)) orelse return false;
        const text = std.mem.span(got);
        const run = qjs.run(ctx, text.ptr, text.len, "<script>", 0);
        free(got);
        const failed = qjs.isException(run) != 0;
        if (failed) reportError(ctx);
        qjs.free(ctx, run);
        return !failed;
    }
    const text = textOfNode(node);
    defer text.deinit();
    if (page(ctx)) |it| {
        if (it.error_script.len > 0) gpa.free(it.error_script);
        it.error_script = keep("<inline>");
    }
    if (text.bytes.len == 0) return true;
    const run = qjs.run(ctx, text.bytes.ptr, text.bytes.len, "<script>", 0);
    const failed = qjs.isException(run) != 0;
    if (failed) reportError(ctx);
    qjs.free(ctx, run);
    return !failed;
}

export fn dom_load(ctx: *Context, document: *lexbor.Document) void {
    const it = page(ctx) orelse return;
    const root = lexbor.lxb_dom_document_root(document) orelse return;
    const held = lexbor.lxb_dom_collection_create(it.tree) orelse return;
    defer _ = lexbor.lxb_dom_collection_destroy(held, true);
    if (lexbor.lxb_dom_collection_init(held, 8) != .ok) return;
    if (lexbor.lxb_dom_elements_by_tag_name(@ptrCast(root), held, "script", 6) != .ok) return;
    for (0..lexbor.lexbor_collection_length(held)) |at| {
        const element_: ?*lexbor.Element = lexbor.lexbor_collection_element(held, at) orelse continue;
        const node: *lexbor.Node = @ptrCast(@alignCast(element_ orelse continue));
        it.ran += 1;
        if (!runOne(ctx, node)) {
            it.threw += 1;
            break;
        }
    }
    // The document is ready, which is what a page waits for.
    tell(ctx, root, "DOMContentLoaded", true);
    tell(ctx, root, "load", true);
}

pub fn load(ctx: *Context, document: *lexbor.Document) void {
    dom_load(ctx, document);
}

export fn dom_click(ctx: *Context, node: *lexbor.Node) bool {
    tell(ctx, node, "click", true);
    return (page(ctx) orelse return false).prevented;
}

pub fn click(ctx: *Context, node: *lexbor.Node) bool {
    return dom_click(ctx, node);
}

export fn dom_changed_at(ctx: *Context, node: *lexbor.Node, sent: bool) void {
    tell(ctx, node, "input", false);
    tell(ctx, node, "change", false);
    if (sent) tell(ctx, node, "submit", true);
}

pub fn typed(ctx: *Context, node: *lexbor.Node, sent: bool) void {
    dom_changed_at(ctx, node, sent);
}

export fn dom_changed(ctx: *Context) bool {
    const it = page(ctx) orelse return false;
    const was = it.changed;
    it.changed = false;
    return was;
}

pub fn changed(ctx: *Context) bool {
    return dom_changed(ctx);
}

export fn dom_loop(ctx: *Context) bool {
    const it = page(ctx) orelse return false;
    const js = @import("js");
    js.loop(@ptrCast(ctx));
    const at = now(ctx);
    var due: std.ArrayList(u32) = .empty;
    defer due.deinit(gpa);
    for (it.timers.items) |timer| {
        if (timer.due <= at) due.append(gpa, timer.id) catch {};
    }
    var ran = false;
    for (due.items) |id| {
        const index = timerIndex(it, id) orelse continue;
        const timer = it.timers.items[index];
        // The timer can clear itself, clear another timer, or append one while
        // it runs. Its callback is held separately and the live timer is found
        // by its immutable id afterwards.
        const handler = qjs.dup(ctx, timer.handler);
        const stamp = if (timer.animation) qjs.newUint(ctx, at) else qjs.undefinedValue();
        const called = if (timer.animation)
            qjs.call(ctx, handler, qjs.undefinedValue(), 1, &[_]Value{stamp})
        else
            qjs.call(ctx, handler, qjs.undefinedValue(), 0, null);
        if (qjs.isException(called) != 0) reportError(ctx);
        qjs.free(ctx, called);
        if (timer.animation) qjs.free(ctx, stamp);
        qjs.free(ctx, handler);
        ran = true;
        const current = timerIndex(it, id) orelse continue;
        if (timer.every > 0) {
            it.timers.items[current].due = at + timer.every;
        } else {
            qjs.free(ctx, it.timers.items[current].handler);
            _ = it.timers.orderedRemove(current);
        }
    }
    return ran;
}

fn timerIndex(it: *Page, id: u32) ?usize {
    for (it.timers.items, 0..) |timer, at| {
        if (timer.id == id) return at;
    }
    return null;
}

pub fn loop(ctx: *Context) bool {
    return dom_loop(ctx);
}

export fn dom_waits(ctx: *Context, in_ms: *u32) bool {
    const it = page(ctx) orelse return false;
    const at = now(ctx);
    var any = false;
    for (it.timers.items) |timer| {
        const wait = if (timer.due > at) timer.due - at else 0;
        if (any and wait >= in_ms.*) continue;
        in_ms.* = wait;
        any = true;
    }
    return any;
}

pub fn waits(ctx: *Context) ?u32 {
    var at: u32 = 0;
    return if (dom_waits(ctx, &at)) at else null;
}

export fn dom_cookies_for(ctx: *Context, host: [*:0]const u8, path: [*:0]const u8) ?[*:0]u8 {
    _ = path;
    const it = page(ctx) orelse return null;
    const wanted = std.mem.span(host);
    var joined: std.ArrayList(u8) = .empty;
    for (it.crumbs.items, 0..) |crumb, at| {
        if (!std.mem.containsAtLeast(u8, crumb.domain, 1, wanted)) continue;
        if (at > 0) joined.appendSlice(gpa, "; ") catch {};
        joined.appendSlice(gpa, crumb.name) catch {};
        joined.append(gpa, '=') catch {};
        joined.appendSlice(gpa, crumb.value) catch {};
    }
    defer joined.deinit(gpa);
    if (joined.items.len == 0) return null;
    const out = gpa.allocSentinel(u8, joined.items.len, 0) catch return null;
    @memcpy(out, joined.items);
    return out.ptr;
}

pub fn cookiesFor(ctx: *Context, host: [*:0]const u8, path: [*:0]const u8) ?[*:0]u8 {
    return dom_cookies_for(ctx, host, path);
}

/// How many of the page's scripts have run.
export fn dom_scripts_ran(ctx: *Context) u32 {
    return (page(ctx) orelse return 0).ran;
}

/// How many of them threw.
export fn dom_scripts_threw(ctx: *Context) u32 {
    return (page(ctx) orelse return 0).threw;
}

pub fn scriptsRan(ctx: *Context) u32 {
    return dom_scripts_ran(ctx);
}

pub fn scriptsThrew(ctx: *Context) u32 {
    return dom_scripts_threw(ctx);
}

/// The last thing a page reached for and this reader had no answer to.
export fn dom_asked_last(ctx: *Context) ?[*:0]const u8 {
    const it = page(ctx) orelse return null;
    return if (it.asked_last.len == 0) null else @ptrCast(it.asked_last.ptr);
}

/// How many things a page reached for and this reader had no answer to.
export fn dom_asked_count(ctx: *Context) u32 {
    return (page(ctx) orelse return 0).asked_count;
}

pub fn askedLast(ctx: *Context) ?[]const u8 {
    return if (dom_asked_last(ctx)) |got| std.mem.span(got) else null;
}

pub fn askedCount(ctx: *Context) u32 {
    return dom_asked_count(ctx);
}

/// The last exception a page threw, where one did.
pub fn errorLast(ctx: *Context) ?[]const u8 {
    const it = page(ctx) orelse return null;
    return if (it.error_last.len > 0) it.error_last else null;
}

pub fn errorSource(ctx: *Context) []const u8 {
    return (page(ctx) orelse return "").error_script;
}

export fn dom_release(ctx: *Context) void {
    const it = page(ctx) orelse return;
    for (it.watches.items) |watch| {
        gpa.free(watch.kind);
        qjs.free(ctx, watch.handler);
    }
    for (it.timers.items) |timer| qjs.free(ctx, timer.handler);
    for (it.crumbs.items) |crumb| {
        gpa.free(crumb.name);
        gpa.free(crumb.value);
        gpa.free(crumb.domain);
        gpa.free(crumb.path);
    }
    it.crumbs.deinit(gpa);
    it.watches.deinit(gpa);
    it.timers.deinit(gpa);
    var keys = it.stored.keyIterator();
    while (keys.next()) |key| gpa.free(key.*);
    it.stored.deinit();
    var asked = it.noted.keyIterator();
    while (asked.next()) |name| gpa.free(name.*);
    it.noted.deinit();
    if (it.error_last.len > 0) gpa.free(it.error_last);
    if (it.error_script.len > 0) gpa.free(it.error_script);
    if (it.selectors) |engine| _ = lexbor.lxb_selectors_destroy(engine, true);
    if (it.parser) |parser| {
        lexbor.lxb_css_parser_selectors_destroy(parser);
        _ = lexbor.lxb_css_parser_destroy(parser, true);
    }
    if (it.css) |memory| _ = lexbor.lxb_css_memory_destroy(memory, true);
    gpa.free(it.address);
    gpa.free(it.user_agent);
    qjs.setHeld(ctx, null);
    gpa.destroy(it);
}

pub fn release(ctx: *Context) void {
    dom_release(ctx);
}

// ---------------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------------

fn jsCreateElement(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    const it = page(ctx) orelse return qjs.undefinedValue();
    const name = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], name);
    const made = lexbor.lxb_dom_document_create_element(it.tree, name.ptr, name.len, null) orelse return qjs.undefinedValue();
    return element(ctx, @ptrCast(@alignCast(made)));
}

fn jsCreateText(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    _ = this;
    _ = argc;
    const it = page(ctx) orelse return qjs.undefinedValue();
    const text = words(ctx, argv[0]);
    defer freeWords(ctx, argv[0], text);
    const made = lexbor.lxb_dom_document_create_text_node(it.tree, text.ptr, text.len) orelse return qjs.undefinedValue();
    return element(ctx, @ptrCast(@alignCast(made)));
}

fn jsCreateComment(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return jsCreateText(ctx, this, argc, argv);
}

fn jsTitle(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    const node = titled(ctx) orelse return qjs.newString(ctx, "", 0);
    const text = textOfNode(node);
    defer text.deinit();
    return qjs.newString(ctx, text.bytes.ptr, text.bytes.len);
}

/// The page's `<title>` element, found rather than asked for: asking the
/// document for one before the parser has settled it is a way to fall over.
fn titled(ctx: *Context) ?*lexbor.Node {
    const it = page(ctx) orelse return null;
    const root = lexbor.lxb_dom_document_root(it.tree) orelse return null;
    const held = lexbor.lxb_dom_collection_create(it.tree) orelse return null;
    defer _ = lexbor.lxb_dom_collection_destroy(held, true);
    if (lexbor.lxb_dom_collection_init(held, 2) != .ok) return null;
    if (lexbor.lxb_dom_elements_by_tag_name(@ptrCast(root), held, "title", 5) != .ok) return null;
    const each = lexbor.lexbor_collection_element(held, 0) orelse return null;
    return @ptrCast(@alignCast(each));
}

fn jsSetTitle(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    _ = this;
    const node = titled(ctx) orelse return qjs.undefinedValue();
    const text = words(ctx, value);
    defer freeWords(ctx, value, text);
    _ = lexbor.lxb_dom_node_text_content_set(node, text.ptr, text.len);
    markChanged(ctx);
    return qjs.undefinedValue();
}

fn jsRoot(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    const it = page(ctx) orelse return qjs.nullValue();
    const root = lexbor.lxb_dom_document_root(it.tree) orelse return qjs.nullValue();
    return element(ctx, root);
}

fn bodyOrHead(ctx: *Context, comptime which: enum { body, head }) Value {
    const it = page(ctx) orelse return qjs.nullValue();
    const made = switch (which) {
        .body => lexbor.lxb_html_document_body_element_noi(it.tree),
        .head => lexbor.lxb_html_document_head_element_noi(it.tree),
    } orelse return qjs.nullValue();
    return element(ctx, @ptrCast(@alignCast(made)));
}

fn jsBody(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return bodyOrHead(ctx, .body);
}

fn jsHead(ctx: *Context, this: Value) callconv(.c) Value {
    _ = this;
    return bodyOrHead(ctx, .head);
}

const document_methods = [_]qjs.ListEntry{
    qjs.ListEntry.method("getElementById", 1, &jsGetById),
    qjs.ListEntry.method("getElementsByTagName", 1, &jsGetByTag),
    qjs.ListEntry.method("getElementsByClassName", 1, &jsGetByClass),
    qjs.ListEntry.method("querySelector", 1, &jsQuerySelector),
    qjs.ListEntry.method("querySelectorAll", 1, &jsQuerySelectorAll),
    qjs.ListEntry.method("createElement", 1, &jsCreateElement),
    qjs.ListEntry.method("createElementNS", 2, &jsCreateElement),
    qjs.ListEntry.method("createTextNode", 1, &jsCreateText),
    qjs.ListEntry.method("createComment", 1, &jsCreateComment),
    qjs.ListEntry.method("addEventListener", 2, &jsAddListener),
    qjs.ListEntry.method("removeEventListener", 2, &jsRemoveListener),
    qjs.ListEntry.method("dispatchEvent", 1, &jsDispatchEvent),
    qjs.ListEntry.method("getElementsByName", 1, &jsGetByName),
};

const document_gets = [_]qjs.ListEntry{
    qjs.ListEntry.accessor("title", &jsTitle, &jsSetTitle),
    qjs.ListEntry.accessor("cookie", &jsCookie, &jsSetCookie),
    qjs.ListEntry.accessor("documentElement", &jsRoot, null),
    qjs.ListEntry.accessor("body", &jsBody, null),
    qjs.ListEntry.accessor("head", &jsHead, null),
    qjs.ListEntry.accessor("location", &jsLocationOf, &jsSetLocation),
    qjs.ListEntry.accessor("URL", &jsUrl, null),
    qjs.ListEntry.accessor("readyState", &jsReadyState, null),
    qjs.ListEntry.accessor("documentURI", &jsUrl, null),
    qjs.ListEntry.accessor("hidden", &jsNotHidden, null),
    qjs.ListEntry.accessor("visibilityState", &jsVisible, null),
    qjs.ListEntry.accessor("forms", &jsForms, null),
    qjs.ListEntry.accessor("images", &jsImages, null),
    qjs.ListEntry.accessor("links", &jsLinks, null),
    qjs.ListEntry.accessor("scripts", &jsScripts, null),
};
