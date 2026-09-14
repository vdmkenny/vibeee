//! The document a script sees.
//!
//! The page's own tree, given to a script in the terms a script expects: an
//! element is an object with an `id`, a `className`, a `style`, children and a
//! `textContent`, and the document is where elements are found and made. The
//! tree behind it is lexbor's, the same one the browser reads the page from,
//! so what a script does to it is what the browser draws next time it reads.
//!
//! Nothing of the tree is mirrored or cached: an element object holds a
//! pointer to a lexbor node and nothing else, and every method is lexbor's
//! own call. Each node has one object, made the first time a script is given
//! it and kept, so that two askings answer with the same object, as a script
//! expects them to, and what a script puts on it stays put.
//!
//! What a script wants from outside its page goes through the browser, and
//! never waits for it: a page it asks for with `fetch`, a script it inserts
//! by its address, are asks the browser takes one at a time and answers on a
//! later pass, and where a script sends the browser is a going the browser
//! takes once the script has returned. The cookies and what a site puts by
//! are the browser's to keep, since they outlive the page; the document reads
//! and writes them through it.
//!
//! What a page asks for that this browser cannot give is given as an empty
//! shape rather than left out, and noted: a script that finds no
//! `getComputedStyle` stops where one that finds an empty one goes on, and a
//! page that stops says nothing about why.
//!
//! A context is made for one page and freed with it, so a node a script was
//! given never outlives the tree it pointed into. Everything the document
//! keeps for a page is on the engine's own heap, so it counts against the
//! bound a page's scripts have between them.

const std = @import("std");
const js = @import("js");
const qjs = @import("quickjs");
const cookie = @import("cookie.zig");
const css = @import("css.zig");
const form_mod = @import("form.zig");
const http = @import("http.zig");
const lexbor = @import("lexbor.zig");
const links = @import("links.zig");
const media = @import("media.zig");
const storage = @import("storage.zig");
const url = @import("url.zig");

const Allocator = std.mem.Allocator;
const Bounded = @import("lib").bounded.Bounded;
const Context = qjs.Context;
const Value = qjs.Value;
const Node = lexbor.Node;

/// What the document asks of the browser around it: where what outlives the
/// page is kept, and what is true of the window the page is in.
pub const Host = struct {
    /// The browser's own heap, for what outlives the page.
    gpa: Allocator,
    /// The cookies the browser keeps while it runs.
    jar: *cookie.Jar,
    /// What a page's site puts by, which the browser keeps while it runs.
    store: *storage.Storage,
    /// The window the page is drawn in, or none for a browser with none.
    screen: ?media.Screen = null,
    /// What the browser calls itself to a site.
    user_agent: []const u8,
};

/// How many scripts a page names by address that are fetched for it, and
/// what they may come to between them. A page's own scripts are a handful,
/// a site's a few dozen; one that names more is run with those it names
/// first.
pub const SCRIPTS_MAX = 32;
pub const SCRIPTS_BYTES_MAX = 2 * 1024 * 1024;

/// The scripts a page names by address, in the order it names them.
pub const Scripts = links.Queue(SCRIPTS_MAX, SCRIPTS_BYTES_MAX);

/// A script the browser fetched for the page, by the address the page named.
pub const Fetched = struct { address: []const u8, text: []const u8 };

/// What a script asks the browser to fetch: an address, what to send with it
/// where it asks by POST, and whether it is a script to run, which says
/// what the site is told the browser takes. The slices are the document's
/// until the ask is answered.
pub const Ask = struct {
    id: u32,
    address: []const u8,
    sent: ?http.Payload = null,
    script: bool = false,
};

/// What an ask came to.
pub const Answer = struct {
    status: u16 = 0,
    body: []const u8 = "",
    /// It never reached the site, or was refused before it did.
    failed: bool = false,
};

/// Where a script asked the browser to go, and a form's answers to send there
/// where it sends one by POST. The slices are the document's until the next
/// ask for a going.
pub const Going = struct {
    address: []const u8,
    sent: ?[]const u8 = null,
};

/// What a page's scripts came to, for the browser to say.
pub const Report = struct {
    /// How many of the page's scripts have run, and how many of those threw.
    ran: u32 = 0,
    threw: u32 = 0,
    /// The last exception a page threw, or nothing.
    error_last: []const u8 = "",
    /// The last thing a page reached for and this browser had no answer to,
    /// and how many such things there were.
    missing_last: []const u8 = "",
    missing_count: u32 = 0,
};

/// The most asks a page may have open at once. A page asking for more is a
/// page fetching the world, and is answered with a refusal.
const ASKS_MAX = 32;

/// The least often a repeating timer runs. A page that asks for every
/// millisecond gets this, which keeps a window with one such page in it from
/// keeping the processor for itself.
const INTERVAL_MIN_MS = 50;

/// How soon a frame is drawn, as a page asks with `requestAnimationFrame`:
/// what a page that animates is told, at a pace this panel can draw.
const FRAME_MS = 50;

/// The most the line `document.cookie` reads comes to.
const COOKIES_MAX = 8 * 1024;

/// The most a script's `on...` attribute, a selector or a property name
/// comes to.
const NAME_MAX = 64;

/// A listener a script has put on an element.
const Watch = struct { node: *Node, kind: []const u8, handler: Value };

/// What a script has asked to be called later.
const Timer = struct {
    id: u32,
    handler: Value,
    /// When it is due, on the page's clock, and how often it repeats: nought
    /// for once.
    due: u32,
    every: u32,
    /// Asked for as a frame, which is handed the clock when it runs.
    frame: bool,
};

/// An ask, and what to do with its answer.
const Pending = struct {
    ask: Ask,
    /// Handed to the browser already, which is answering it.
    taken: bool = false,
    kind: union(enum) {
        /// `fetch`: the promise's two ends.
        fetch: [2]Value,
        /// `XMLHttpRequest`: the request object, told when the answer is in.
        xhr: Value,
        /// A script inserted by its address: run when it comes.
        script: *Node,
    },
};

/// The document, as one page's scripts see it.
pub const Document = struct {
    ctx: *Context,
    machine: *js.Machine,
    tree: *lexbor.Document,
    /// The rules the page's stylesheets gave the tree, matched again under
    /// what a script changes.
    rules: *const css.Rules,
    host: Host,
    /// The engine's heap as an allocator: what everything below is kept on.
    heap: Heap,
    gpa: Allocator,

    /// Where the page is, and its site, which what it puts by is kept for.
    address: []const u8,
    store: ?*storage.Bucket,
    /// The one object each node is given as.
    wrappers: std.AutoHashMapUnmanaged(*Node, Value) = .empty,
    /// What every element object inherits.
    node_proto: Value,
    watches: std.ArrayList(Watch) = .empty,
    timers: std.ArrayList(Timer) = .empty,
    next_timer: u32 = 0,
    asks: std.ArrayList(Pending) = .empty,
    next_ask: u32 = 0,
    going: ?Going = null,
    /// Lexbor's own selectors engine and the parser behind it, so `a[href]`
    /// means what a stylesheet says it means.
    parser: ?*lexbor.CssParser = null,
    selectors: ?*lexbor.Selectors = null,
    /// The script element being run, which is where `document.write` puts
    /// what it writes.
    running: ?*Node = null,
    /// Which of the page's scripts have run, so that one a script adds
    /// while they run is run after them and none is run twice.
    ran_nodes: std.AutoHashMapUnmanaged(*Node, void) = .empty,
    report: Report = .{},
    /// What a script has reached for and this browser had no answer to, so
    /// that each is said once and not again.
    noted: std.StringHashMapUnmanaged(void) = .empty,
    /// Whether a script has changed the tree since the browser last asked.
    changed: bool = false,
    /// The nearest node holding everything a script changed that a
    /// stylesheet's rules could read differently, since the rules were last
    /// matched: what is matched again before the tree is read.
    restyle: ?*Node = null,
    /// Whether the event being told was asked to go no further, and whether
    /// what it would do was refused.
    stopped: bool = false,
    prevented: bool = false,
};

/// The engine's own heap: what a document's lists are kept on, so a page's
/// bookkeeping counts against the bound its scripts have.
const Heap = struct {
    ctx: *Context,

    const vtable: Allocator.VTable = .{
        .alloc = &alloc,
        .resize = &resize,
        .free = &drop,
        .remap = &remap,
    };

    fn allocator(self: *Heap) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(held: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
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

/// One class: everything the document hands a script carries a node inside
/// it. Its objects inherit the element's methods from one prototype, so an
/// element object is nothing but its node.
var node_class: qjs.ClassId = 0;
/// The runtime the class above was made for: a new runtime needs a new one.
var class_for: ?*qjs.Runtime = null;

const class_def = qjs.ClassDef{
    .class_name = "Node",
    .finalizer = null,
    .gc_mark = null,
    .call = null,
    .exotic = null,
};

fn documentOf(ctx: *Context) ?*Document {
    return @ptrCast(@alignCast(qjs.heldOf(ctx)));
}

// ---------------------------------------------------------------------------
// Opening, and what the browser asks afterwards
// ---------------------------------------------------------------------------

/// Give a page's tree to a script, at `address`. None where the engine has
/// no room for a page, which is a page that reads as though it had no
/// scripts.
pub fn open(machine: *js.Machine, tree: *lexbor.Document, rules: *const css.Rules, address: []const u8, host: Host) ?*Document {
    const ctx = machine.open() orelse return null;
    var heap = Heap{ .ctx = ctx };
    const it = heap.allocator().create(Document) catch {
        machine.close(ctx);
        return null;
    };
    it.* = .{
        .ctx = ctx,
        .machine = machine,
        .tree = tree,
        .rules = rules,
        .host = host,
        .heap = heap,
        .gpa = undefined,
        .address = "",
        .store = null,
        .node_proto = qjs.undefinedValue(),
    };
    it.gpa = it.heap.allocator();
    it.address = keep(it, address);
    it.store = if (url.parse(address)) |where| host.store.bucketFor(host.gpa, originOf(where)) else null;
    qjs.setHeld(ctx, it);

    const rt = qjs.runtimeOf(ctx);
    // Once per runtime, and not once per page: a class belongs to the
    // runtime, and one made again for every page is one the runtime keeps
    // holding, page after page.
    if (class_for != rt) {
        qjs.newClassId(&node_class);
        _ = qjs.newClass(rt, node_class, &class_def);
        class_for = rt;
    }
    it.node_proto = qjs.newObject(ctx);
    _ = qjs.addList(ctx, it.node_proto, &node_methods, node_methods.len);
    _ = qjs.addList(ctx, it.node_proto, &node_gets, node_gets.len);
    qjs.setClassProto(ctx, node_class, qjs.dup(ctx, it.node_proto));

    if (lexbor.lxb_css_parser_create()) |parser| {
        _ = lexbor.lxb_css_parser_init(parser, null);
        _ = lexbor.lxb_css_parser_selectors_init(parser);
        it.parser = parser;
    }
    if (lexbor.lxb_selectors_create()) |engine| {
        _ = lexbor.lxb_selectors_init(engine);
        it.selectors = engine;
    }

    furnish(it);
    return it;
}

/// Let go of the page: everything the scripts made and kept, the objects
/// the nodes were given as, and the context itself.
pub fn close(it: *Document) void {
    const ctx = it.ctx;
    for (it.watches.items) |watch| {
        it.gpa.free(watch.kind);
        qjs.free(ctx, watch.handler);
    }
    it.watches.deinit(it.gpa);
    for (it.timers.items) |timer| qjs.free(ctx, timer.handler);
    it.timers.deinit(it.gpa);
    for (it.asks.items) |*pending| dropPending(it, pending);
    it.asks.deinit(it.gpa);
    if (it.going) |going| freeGoing(it, going);
    var wrappers = it.wrappers.valueIterator();
    while (wrappers.next()) |value| qjs.free(ctx, value.*);
    it.wrappers.deinit(it.gpa);
    it.ran_nodes.deinit(it.gpa);
    var noted = it.noted.keyIterator();
    while (noted.next()) |name| it.gpa.free(name.*);
    it.noted.deinit(it.gpa);
    if (it.report.error_last.len > 0) it.gpa.free(it.report.error_last);
    qjs.free(ctx, it.node_proto);
    if (it.selectors) |engine| _ = lexbor.lxb_selectors_destroy(engine, true);
    if (it.parser) |parser| {
        lexbor.lxb_css_parser_selectors_destroy(parser);
        _ = lexbor.lxb_css_parser_destroy(parser, true);
    }
    it.gpa.free(it.address);
    qjs.setHeld(ctx, null);
    const machine = it.machine;
    it.gpa.destroy(it);
    machine.close(ctx);
}

/// Run what the page carries, in the order it carries it: each script
/// element's own words, or the text the browser fetched for the address it
/// names, where it fetched one. A script that adds a script to the page as
/// it runs has that one run after it. Then the document is told it is
/// ready, which is what a page waits for.
pub fn load(it: *Document, fetched: []const Fetched) void {
    while (nextScript(it)) |node| {
        it.ran_nodes.put(it.gpa, node, {}) catch return;
        runElement(it, node, fetched);
    }
    loaded(it);
}

/// What running the page's scripts as far as they are here came to.
pub const Loading = enum {
    /// Every script the page carries has run, and it has been told it is
    /// ready.
    done,
    /// The next script in the page's order is one by address whose text has
    /// not come: the page waits for it.
    waiting,
};

/// Run the page's scripts in its order as far as their text is here, and
/// stop at the first named by an address the browser has not brought yet,
/// so that a page is shown and its scripts run as each one comes. Once the
/// last has run the document is told it is ready.
pub fn loadNext(it: *Document, fetched: []const Fetched) Loading {
    while (nextScript(it)) |node| {
        if (lexbor.attribute(node, "src")) |named| {
            var buf: [url.ADDRESS_MAX]u8 = undefined;
            if (resolvedFrom(it, named, &buf)) |resolved| {
                if (fetchedText(fetched, resolved) == null) return .waiting;
            }
        }
        it.ran_nodes.put(it.gpa, node, {}) catch return .done;
        runElement(it, node, fetched);
    }
    loaded(it);
    return .done;
}

/// Tell the page it is ready, which is what a page waits for.
fn loaded(it: *Document) void {
    const root = lexbor.lxb_dom_document_root(it.tree) orelse return;
    _ = tell(it, root, "DOMContentLoaded", false);
    _ = tell(it, root, "load", false);
}

/// The text the browser fetched for `address`, where it fetched one.
fn fetchedText(fetched: []const Fetched, address: []const u8) ?[]const u8 {
    for (fetched) |script| {
        if (std.mem.eql(u8, script.address, address)) return script.text;
    }
    return null;
}

/// Run `source` as a link's own script, which is what a link whose address
/// is a script does when it is followed.
pub fn run(it: *Document, source: []const u8) void {
    runText(it, source, "<link>");
    _ = it.machine.runJobs();
}

/// The first of the page's scripts that has not run.
fn nextScript(it: *Document) ?*Node {
    const root = lexbor.lxb_dom_document_root(it.tree) orelse return null;
    var at = lexbor.following(root, root);
    while (at) |node| : (at = lexbor.following(node, root)) {
        if (lexbor.tagOf(node) != .script or !isJavaScript(node)) continue;
        if (it.ran_nodes.contains(node)) continue;
        return node;
    }
    return null;
}

/// Whether a script element holds a script this engine runs: one of no
/// type, or of one of the types script is written under. A module is not
/// run, nothing here resolving what one imports, and neither is what is
/// written under a type that is data rather than script.
fn isJavaScript(node: *Node) bool {
    const kind = std.mem.trim(u8, lexbor.attribute(node, "type") orelse "", &std.ascii.whitespace);
    if (kind.len == 0) return true;
    for (script_types) |known| {
        if (std.ascii.eqlIgnoreCase(kind, known)) return true;
    }
    return false;
}

const script_types = [_][]const u8{ "text/javascript", "application/javascript", "text/ecmascript", "application/ecmascript", "text/jscript" };

/// Run one script element: the text the browser fetched for the address it
/// names, or its own words.
fn runElement(it: *Document, node: *Node, fetched: []const Fetched) void {
    const was_running = it.running;
    it.running = node;
    defer it.running = was_running;
    if (lexbor.attribute(node, "src")) |named| {
        var buf: [url.ADDRESS_MAX]u8 = undefined;
        const resolved = resolvedFrom(it, named, &buf) orelse return;
        const text = fetchedText(fetched, resolved) orelse return;
        if (text.len > 0) runText(it, text, "<script src>");
        return;
    }
    const text = textOfNode(node);
    defer text.deinit();
    if (text.bytes.len > 0) runText(it, text.bytes, "<script>");
}

/// Run `source` as a script of the page's, counting it and what it threw.
fn runText(it: *Document, source: []const u8, name: [*:0]const u8) void {
    it.report.ran += 1;
    it.machine.enter();
    const ended = it.machine.run(it.ctx, source, name, .global);
    if (qjs.isException(ended)) {
        it.report.threw += 1;
        reportError(it);
    }
    qjs.free(it.ctx, ended);
}

/// Where the page's scripts are, by the addresses they name, in order: what
/// the browser fetches before the page's scripts run.
pub fn scriptsOf(gpa: Allocator, document: *lexbor.Document, base: url.Url, into: *Scripts) Allocator.Error!void {
    const root = lexbor.lxb_dom_document_root(document) orelse return;
    var at = lexbor.following(root, root);
    while (at) |node| : (at = lexbor.following(node, root)) {
        if (lexbor.tagOf(node) != .script or !isJavaScript(node)) continue;
        const named = lexbor.attribute(node, "src") orelse continue;
        var buf: [url.ADDRESS_MAX]u8 = undefined;
        const resolved = url.resolve(base, std.mem.trim(u8, named, &std.ascii.whitespace), &buf) orelse continue;
        try into.add(gpa, resolved, "");
    }
}

/// A click on `node`, told to it and to everything it stands inside. True
/// where a script asked for the click to go no further, which is a link that
/// is not followed and a form that is not sent.
pub fn click(it: *Document, node: *Node) bool {
    it.machine.enter();
    return tell(it, node, "click", true);
}

/// An entry of a list was chosen by the person reading: the entry is the
/// one chosen from here on, and the list is told, as a browser tells it.
pub fn chose(it: *Document, select: *Node, index: usize) void {
    var count: usize = 0;
    var at = lexbor.following(select, select);
    while (at) |here| : (at = lexbor.following(here, select)) {
        if (!isTag(here, "OPTION")) continue;
        if (count == index) attributeSet(it, here, "selected", "") else if (attributeOf(here, "selected") != null) attributeRemove(it, here, "selected");
        count += 1;
    }
    it.machine.enter();
    _ = tell(it, select, "input", true);
    _ = tell(it, select, "change", true);
    _ = it.machine.runJobs();
}

/// The entry of a list that is chosen: the first the page says is, or its
/// first, as a browser has it. Nothing for a list with no entries.
fn chosenOption(select: *Node) ?*Node {
    var first: ?*Node = null;
    var at = lexbor.following(select, select);
    while (at) |here| : (at = lexbor.following(here, select)) {
        if (!isTag(here, "OPTION")) continue;
        if (attributeOf(here, "selected") != null) return here;
        if (first == null) first = here;
    }
    return first;
}

/// Which of a list's entries is chosen, counted from nought, or none for a
/// list with no entries.
fn chosenIndex(select: *Node) ?usize {
    const chosen = chosenOption(select) orelse return null;
    var count: usize = 0;
    var at = lexbor.following(select, select);
    while (at) |here| : (at = lexbor.following(here, select)) {
        if (!isTag(here, "OPTION")) continue;
        if (here == chosen) return count;
        count += 1;
    }
    return null;
}

/// What an entry of a list sends: its value, or its words where it has none,
/// which `buf` then holds.
fn optionValue(option: *Node, buf: *NodeText) []const u8 {
    if (attributeOf(option, "value")) |value| return value;
    buf.* = textOfNode(option);
    return buf.bytes;
}

/// A form about to be sent, told to it. True where a script refused it.
pub fn submitted(it: *Document, form: *Node) bool {
    it.machine.enter();
    return tell(it, form, "submit", true);
}

/// Run what the scripts left waiting: the promises they made, and the timers
/// that are due. True where anything ran.
pub fn loop(it: *Document) bool {
    var ran = it.machine.runJobs();
    const at = now(it);
    // What is due now, by id: a timer may clear itself or another, or set
    // one, while it runs, so the list is not walked while they do.
    var due: std.ArrayList(u32) = .empty;
    defer due.deinit(it.gpa);
    for (it.timers.items) |timer| {
        if (timer.due <= at) due.append(it.gpa, timer.id) catch break;
    }
    for (due.items) |id| {
        const index = timerIndex(it, id) orelse continue;
        const timer = it.timers.items[index];
        const handler = qjs.dup(it.ctx, timer.handler);
        defer qjs.free(it.ctx, handler);
        const stamp = if (timer.frame) qjs.newUint(it.ctx, at) else qjs.undefinedValue();
        it.machine.enter();
        const called = qjs.call(it.ctx, handler, qjs.undefinedValue(), 1, &[_]Value{stamp});
        if (qjs.isException(called)) reportError(it);
        qjs.free(it.ctx, called);
        ran = true;
        const current = timerIndex(it, id) orelse continue;
        if (timer.every > 0) {
            it.timers.items[current].due = at + timer.every;
        } else {
            qjs.free(it.ctx, it.timers.items[current].handler);
            _ = it.timers.orderedRemove(current);
        }
    }
    if (it.machine.runJobs()) ran = true;
    return ran;
}

/// Whether a script has changed the page since the last time this was
/// asked, and so whether the browser must read it again.
pub fn changed(it: *Document) bool {
    defer it.changed = false;
    settleStyles(it);
    return it.changed;
}

/// How long until the next timer a script set is due, in milliseconds: what
/// a window with the page on screen waits for, where it would otherwise wait
/// for nothing.
pub fn waits(it: *Document) ?u32 {
    const at = now(it);
    var soonest: ?u32 = null;
    for (it.timers.items) |timer| {
        const wait = timer.due -| at;
        if (soonest == null or wait < soonest.?) soonest = wait;
    }
    return soonest;
}

/// Where a script asked the browser to go, if it did: taken once.
pub fn takeGoing(it: *Document) ?Going {
    defer it.going = null;
    return it.going;
}

/// Whether the scripts have asked for anything the browser has not taken yet.
pub fn asking(it: *const Document) bool {
    for (it.asks.items) |pending| {
        if (!pending.taken) return true;
    }
    return false;
}

/// The next ask the browser has not taken yet, which it is then answering.
pub fn nextAsk(it: *Document) ?Ask {
    for (it.asks.items) |*pending| {
        if (pending.taken) continue;
        pending.taken = true;
        return pending.ask;
    }
    return null;
}

/// What an ask came to: the promise is kept, the request told, or the script
/// run.
pub fn answer(it: *Document, id: u32, got: Answer) void {
    const index = for (it.asks.items, 0..) |pending, i| {
        if (pending.ask.id == id) break i;
    } else return;
    var pending = it.asks.orderedRemove(index);
    defer dropPending(it, &pending);
    const ctx = it.ctx;
    it.machine.enter();
    switch (pending.kind) {
        .fetch => |ends| {
            if (got.failed) {
                const why = qjs.newError(ctx);
                _ = qjs.setStr(ctx, why, "message", str(ctx, "the site could not be reached"));
                callOnce(it, ends[1], why);
            } else {
                callOnce(it, ends[0], response(it, pending.ask.address, got));
            }
        },
        .xhr => |request| {
            _ = qjs.setStr(ctx, request, "readyState", qjs.newInt(ctx, 4));
            _ = qjs.setStr(ctx, request, "status", qjs.newInt(ctx, if (got.failed) 0 else got.status));
            _ = qjs.setStr(ctx, request, "responseText", str(ctx, got.body));
            _ = qjs.setStr(ctx, request, "response", str(ctx, got.body));
            callHandler(it, request, "onreadystatechange", request);
            callHandler(it, request, if (got.failed) "onerror" else "onload", request);
        },
        .script => |node| {
            if (!got.failed and got.status / 100 == 2) {
                const was_running = it.running;
                it.running = node;
                runText(it, got.body, "<script src>");
                it.running = was_running;
                _ = tell(it, node, "load", false);
            } else {
                _ = tell(it, node, "error", false);
            }
        },
    }
    _ = it.machine.runJobs();
}

/// What the page's scripts came to so far.
pub fn reportOf(it: *const Document) Report {
    return it.report;
}

// ---------------------------------------------------------------------------
// Words, nodes and objects
// ---------------------------------------------------------------------------

/// A copy of `bytes` on the page's heap: a word a script handed over is
/// freed when the call ends, so anything kept past it must be a copy.
fn keep(it: *Document, bytes: []const u8) []const u8 {
    return it.gpa.dupe(u8, bytes) catch "";
}

fn str(ctx: *Context, bytes: []const u8) Value {
    return qjs.newStringOf(ctx, bytes);
}

/// A value's words, given back with `freeText`; nothing for one that has
/// none.
fn words(ctx: *Context, value: Value) ?[:0]const u8 {
    return qjs.sliceOf(ctx, value);
}

/// The `index`th argument's words, or nothing where there is no such one.
fn argument(ctx: *Context, argc: c_int, argv: [*]const Value, index: usize) ?[:0]const u8 {
    if (index >= @as(usize, @intCast(argc))) return null;
    return words(ctx, argv[index]);
}

fn nodeOf(value: Value) ?*Node {
    return @ptrCast(@alignCast(qjs.nodeOf(value, node_class)));
}

/// The object a node is given as: the one it was given as before, or a new
/// one kept for the next time. The caller holds one reference to what comes
/// back.
fn wrap(it: *Document, node: *Node) Value {
    if (it.wrappers.get(node)) |kept| return qjs.dup(it.ctx, kept);
    const made = qjs.newObjectIn(it.ctx, @intCast(node_class));
    qjs.setNode(made, node);
    it.wrappers.put(it.gpa, node, qjs.dup(it.ctx, made)) catch {};
    return made;
}

/// A node as a value, or null for none.
fn wrapped(it: *Document, node: ?*Node) Value {
    return if (node) |each| wrap(it, each) else qjs.nullValue();
}

/// The page's root: where the document's own events are told, and where a
/// listener put on the window or the document goes.
fn rootOf(it: *Document) ?*Node {
    return lexbor.lxb_dom_document_root(it.tree);
}

/// The node `this` is, or the page's root for the document and the window.
fn nodeOrRoot(it: *Document, this: Value) ?*Node {
    return nodeOf(this) orelse rootOf(it);
}

/// Say the document has been changed, and so reads differently.
fn markChanged(it: *Document) void {
    it.changed = true;
}

/// Note that what is under `node` may read differently to the stylesheets'
/// rules now: the rules are matched again there before the tree is read,
/// once for everything changed in between, under the nearest node that
/// holds all of it.
fn noteRestyle(it: *Document, node: *Node) void {
    const had = it.restyle orelse {
        it.restyle = node;
        return;
    };
    if (!holds(had, node)) it.restyle = commonAncestor(had, node);
}

/// Match the stylesheets' rules again where a script's changes call for it.
fn settleStyles(it: *Document) void {
    const root = it.restyle orelse return;
    it.restyle = null;
    css.restyle(it.tree, it.rules, root);
}

/// Whether `node` is `ancestor` or under it.
fn holds(ancestor: *Node, node: *Node) bool {
    var at: ?*Node = node;
    while (at) |each| : (at = each.parent) {
        if (each == ancestor) return true;
    }
    return false;
}

/// The nearest node that is or holds both `a` and `b`.
fn commonAncestor(a: *Node, b: *Node) *Node {
    var at: ?*Node = a;
    while (at) |each| : (at = each.parent) {
        if (holds(each, b)) return each;
    }
    return a;
}

/// Say, once a page, that a script reached for something this browser has no
/// answer for. A page that stops where it found nothing gives no sign of
/// why; saying what it reached for turns a page that will not draw into a
/// list of what to give it next.
fn missing(it: *Document, what: []const u8) void {
    const got = it.noted.getOrPut(it.gpa, what) catch return;
    if (got.found_existing) return;
    got.key_ptr.* = keep(it, what);
    it.report.missing_last = got.key_ptr.*;
    it.report.missing_count += 1;
    var line: [NAME_MAX + 16]u8 = undefined;
    it.machine.say(std.fmt.bufPrint(&line, "no {s}", .{what}) catch "no such API");
}

/// Keep the exception the context holds as the last a page threw, and say
/// it.
fn reportError(it: *Document) void {
    var buf: [js.Machine.ERROR_MAX]u8 = undefined;
    const text = js.Machine.errorText(it.ctx, &buf);
    if (it.report.error_last.len > 0) it.gpa.free(it.report.error_last);
    it.report.error_last = keep(it, text);
    it.machine.say(text);
}

/// The clock, in milliseconds since the machine started: what a timer is
/// measured against.
fn now(it: *Document) u32 {
    return @truncate(it.machine.clock() / std.time.us_per_ms);
}

/// The site the page is on: its scheme and host, which is what it keeps
/// things by.
fn originOf(where: url.Url) []const u8 {
    const S = struct {
        var buf: [url.ADDRESS_MAX]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    where.writeOrigin(&w) catch return "";
    return w.buffered();
}

/// `reference` as a whole address, resolved against the page's, in `buf`.
fn resolvedFrom(it: *Document, reference: []const u8, buf: *[url.ADDRESS_MAX]u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, reference, &std.ascii.whitespace);
    const base = url.parse(it.address) orelse return null;
    return url.resolve(base, trimmed, buf);
}

fn attributeOf(node: *Node, name: []const u8) ?[]const u8 {
    if (node.type != .element) return null;
    return lexbor.attribute(node, name);
}

fn attributeSet(it: *Document, node: *Node, name: []const u8, value: []const u8) void {
    if (node.type != .element) return;
    var change = Change.of(it, node, name, value);
    change.before();
    _ = lexbor.lxb_dom_element_set_attribute(node, name.ptr, name.len, value.ptr, value.len);
    change.after();
    markChanged(it);
}

fn attributeRemove(it: *Document, node: *Node, name: []const u8) void {
    if (node.type != .element) return;
    var change = Change.of(it, node, name, "");
    change.before();
    _ = lexbor.lxb_dom_element_remove_attribute(node, name.ptr, name.len);
    change.after();
    markChanged(it);
}

/// An attribute is what a selector reads, and one changed on an element can
/// change what the rules say of it, of what is under it and of what stands
/// beside it. Only the rules that read the names changing are matched
/// again: unmatched before the change, while the old value still holds,
/// and matched again after it. A class token the element keeps is not a
/// change; the `style` attribute the cascade reads for itself.
const Change = struct {
    it: *Document,
    /// The names changing: an attribute's own, an id's old and new, or the
    /// class tokens gained and lost.
    names: Bounded([]const u8, 16) = .{},

    fn of(it: *Document, node: *Node, name: []const u8, value: []const u8) Change {
        var change = Change{ .it = it };
        if (std.ascii.eqlIgnoreCase(name, "style")) return change;
        const old = attributeOf(node, name) orelse "";
        if (std.ascii.eqlIgnoreCase(name, "class")) {
            change.tokens(old, value);
            change.tokens(value, old);
        } else if (std.ascii.eqlIgnoreCase(name, "id")) {
            if (old.len > 0) change.names.append(old) catch {};
            if (value.len > 0 and !std.mem.eql(u8, old, value)) change.names.append(value) catch {};
        } else {
            change.names.append(name) catch {};
        }
        return change;
    }

    /// The tokens in `these` that are not in `those`.
    fn tokens(self: *Change, these: []const u8, those: []const u8) void {
        var each = std.mem.tokenizeAny(u8, these, &std.ascii.whitespace);
        while (each.next()) |token| {
            var other = std.mem.tokenizeAny(u8, those, &std.ascii.whitespace);
            const kept = while (other.next()) |had| {
                if (std.mem.eql(u8, had, token)) break true;
            } else false;
            if (!kept) self.names.append(token) catch return;
        }
    }

    fn before(self: *Change) void {
        for (self.names.slice()) |name| css.unmatch(self.it.tree, self.it.rules, name);
    }

    fn after(self: *Change) void {
        for (self.names.slice()) |name| css.rematch(self.it.tree, self.it.rules, name);
    }
};

/// Text lexbor allocated for a caller, given back to its document once read.
const NodeText = struct {
    node: *Node,
    data: ?[*]const u8,
    bytes: []const u8,

    fn deinit(self: NodeText) void {
        const data = self.data orelse return;
        _ = lexbor.lexbor_destroy_text(self.node.owner_document.?, @constCast(data));
    }
};

fn textOfNode(node: *Node) NodeText {
    var len: usize = 0;
    const got = lexbor.lxb_dom_node_text_content(node, &len) orelse return .{ .node = node, .data = null, .bytes = "" };
    return .{ .node = node, .data = got, .bytes = got[0..len] };
}

/// The tag of an element, as words, in the upper case a script sees it in.
fn tagOf(node: *Node) []const u8 {
    if (node.type != .element) return "";
    var len: usize = 0;
    const name = lexbor.lxb_dom_element_tag_name(node, &len) orelse return "";
    return name[0..len];
}

fn isTag(node: *Node, want: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tagOf(node), want);
}

/// Call `handler` once with `argument`, which it takes, and let go of both.
fn callOnce(it: *Document, handler: Value, argument_value: Value) void {
    defer qjs.free(it.ctx, argument_value);
    const called = qjs.call(it.ctx, handler, qjs.undefinedValue(), 1, &[_]Value{argument_value});
    if (qjs.isException(called)) reportError(it);
    qjs.free(it.ctx, called);
}

/// Call the function an object keeps under `name`, where it keeps one, with
/// `with` as its argument.
fn callHandler(it: *Document, object: Value, name: [*:0]const u8, with: Value) void {
    const handler = qjs.getStr(it.ctx, object, name);
    defer qjs.free(it.ctx, handler);
    if (qjs.isFunction(it.ctx, handler) == 0) return;
    const called = qjs.call(it.ctx, handler, object, 1, &[_]Value{with});
    if (qjs.isException(called)) reportError(it);
    qjs.free(it.ctx, called);
}

/// A promise already kept, with `value`.
fn settled(ctx: *Context, value: Value) Value {
    var ends: [2]Value = undefined;
    const made = qjs.promise(ctx, &ends);
    defer qjs.free(ctx, ends[0]);
    defer qjs.free(ctx, ends[1]);
    const done = qjs.call(ctx, ends[0], qjs.undefinedValue(), 1, &[_]Value{value});
    qjs.free(ctx, done);
    qjs.free(ctx, value);
    return made;
}

/// A function of the document's, as a property of `into`.
fn give(ctx: *Context, into: Value, name: [*:0]const u8, arity: u8, impl: qjs.Method) void {
    _ = qjs.setStr(ctx, into, name, qjs.newFunction(ctx, name, arity, impl));
}

/// Nothing at all: given rather than left out, since a script that finds no
/// `scrollIntoView` stops where one that finds one which does nothing goes on.
fn jsNothing(_: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return qjs.undefinedValue();
}

fn jsNone(_: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return qjs.nullValue();
}

fn jsNo(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return qjs.newBool(ctx, 0);
}

fn jsYes(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return qjs.newBool(ctx, 1);
}

/// Nought: a size or a place this browser has nothing to say about, given
/// rather than left out so a page that asks does not stop.
fn jsZero(ctx: *Context, _: Value) callconv(.c) Value {
    return qjs.newInt(ctx, 0);
}

fn jsSetNothing(_: *Context, _: Value, _: Value) callconv(.c) Value {
    return qjs.undefinedValue();
}

/// An empty object, for a page that makes something and expects a shape.
fn jsEmpty(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return qjs.newObject(ctx);
}

// ---------------------------------------------------------------------------
// Attributes, text and markup
// ---------------------------------------------------------------------------

fn jsGetAttribute(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.nullValue();
    const name = argument(ctx, argc, argv, 0) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, name.ptr);
    return if (attributeOf(node, name)) |got| str(ctx, got) else qjs.nullValue();
}

fn jsSetAttribute(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const name = argument(ctx, argc, argv, 0) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, name.ptr);
    const value = argument(ctx, argc, argv, 1) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, value.ptr);
    attributeSet(it, node, name, value);
    return qjs.undefinedValue();
}

fn jsHasAttribute(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    const name = argument(ctx, argc, argv, 0) orelse return qjs.newBool(ctx, 0);
    defer qjs.freeText(ctx, name.ptr);
    return qjs.newBool(ctx, @intFromBool(attributeOf(node, name) != null));
}

fn jsRemoveAttribute(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const name = argument(ctx, argc, argv, 0) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, name.ptr);
    attributeRemove(it, node, name);
    return qjs.undefinedValue();
}

fn jsToggleAttribute(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newBool(ctx, 0);
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    const name = argument(ctx, argc, argv, 0) orelse return qjs.newBool(ctx, 0);
    defer qjs.freeText(ctx, name.ptr);
    const had = attributeOf(node, name) != null;
    if (had) attributeRemove(it, node, name) else attributeSet(it, node, name, "");
    return qjs.newBool(ctx, @intFromBool(!had));
}

/// The names of an element's attributes, as `getAttributeNames` says them.
fn jsAttributeNames(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    const out = qjs.newArray(ctx);
    const node = nodeOf(this) orelse return out;
    if (node.type != .element) return out;
    var index: u32 = 0;
    var at = lexbor.lxb_dom_element_first_attribute_noi(node);
    while (at) |attr| : (at = lexbor.lxb_dom_element_next_attribute_noi(attr)) {
        var len: usize = 0;
        const name = lexbor.lxb_dom_attr_qualified_name(attr, &len) orelse continue;
        _ = qjs.setAt(ctx, out, index, str(ctx, name[0..len]));
        index += 1;
    }
    return out;
}

/// `element.dataset`: the `data-` attributes, each under its name with the
/// `data-` taken off and its dashes turned to capitals, as a page reads them
/// far more often than it writes them. What is read is what the element has
/// now; a value put on the object goes nowhere.
fn jsDataset(ctx: *Context, this: Value) callconv(.c) Value {
    const out = qjs.newObject(ctx);
    const node = nodeOf(this) orelse return out;
    if (node.type != .element) return out;
    var at = lexbor.lxb_dom_element_first_attribute_noi(node);
    while (at) |attr| : (at = lexbor.lxb_dom_element_next_attribute_noi(attr)) {
        var len: usize = 0;
        const name = (lexbor.lxb_dom_attr_qualified_name(attr, &len) orelse continue)[0..len];
        if (!std.mem.startsWith(u8, name, "data-")) continue;
        var camel: [NAME_MAX:0]u8 = undefined;
        var n: usize = 0;
        var up = false;
        for (name["data-".len..]) |c| {
            if (n == NAME_MAX) break;
            if (c == '-') {
                up = true;
                continue;
            }
            camel[n] = if (up) std.ascii.toUpper(c) else c;
            up = false;
            n += 1;
        }
        camel[n] = 0;
        var value_len: usize = 0;
        const value = if (lexbor.lxb_dom_attr_value_noi(attr, &value_len)) |got| got[0..value_len] else "";
        _ = qjs.setStr(ctx, out, camel[0..n :0], str(ctx, value));
    }
    return out;
}

fn jsTextContent(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = textOfNode(node);
    defer text.deinit();
    return str(ctx, text.bytes);
}

fn jsSetTextContent(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = words(ctx, value) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, text.ptr);
    if (node.type == .text) {
        _ = lexbor.lxb_dom_node_text_content_set(node, text.ptr, text.len);
    } else {
        while (node.first_child) |each| lexbor.lxb_dom_node_remove(each);
        if (text.len > 0) {
            if (lexbor.lxb_dom_document_create_text_node(it.tree, text.ptr, text.len)) |leaf| {
                _ = lexbor.lxb_dom_node_append_child(node, leaf);
            }
        }
    }
    markChanged(it);
    return qjs.undefinedValue();
}

/// What is inside an element, as markup.
fn jsInnerHtml(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    return serialised(ctx, node, .inside);
}

/// The element and what is inside it, as markup.
fn jsOuterHtml(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    return serialised(ctx, node, .whole);
}

fn serialised(ctx: *Context, node: *Node, which: enum { inside, whole }) Value {
    var out: lexbor.Text = .{ .data = null, .length = 0 };
    const status = switch (which) {
        .inside => lexbor.lxb_html_serialize_deep_str(node, &out),
        .whole => lexbor.lxb_html_serialize_tree_str(node, &out),
    };
    if (status != 0) return str(ctx, "");
    const data = out.data orelse return str(ctx, "");
    defer _ = lexbor.lexbor_destroy_text(node.owner_document.?, @constCast(data));
    return str(ctx, data[0..out.length]);
}

/// `markup`, parsed as it would be inside `node`: a fragment whose children
/// are the nodes it makes.
fn fragmentOf(it: *Document, node: *Node, markup: []const u8) ?*Node {
    return lexbor.lxb_html_document_parse_fragment(it.tree, node, markup.ptr, markup.len);
}

/// Move what `from` holds into `parent`, before `before` or at its end.
fn moveChildren(it: *Document, from: *Node, parent: *Node, before: ?*Node) void {
    while (from.first_child) |each| {
        lexbor.lxb_dom_node_remove(each);
        if (!insert(it, parent, each, before)) break;
    }
}

fn jsSetInnerHtml(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const markup = words(ctx, value) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, markup.ptr);
    while (node.first_child) |each| lexbor.lxb_dom_node_remove(each);
    // Markup written in is markup, and not a script: what a browser does
    // with a script element written this way is nothing, and so is this.
    if (markup.len > 0) {
        if (fragmentOf(it, node, markup)) |held| {
            while (held.first_child) |each| {
                lexbor.lxb_dom_node_remove(each);
                if (lexbor.lxb_dom_node_append_child(node, each) != .ok) break;
            }
        }
    }
    markChanged(it);
    noteRestyle(it, node);
    return qjs.undefinedValue();
}

/// Replace the element itself with markup, as `outerHTML` written to says.
fn jsSetOuterHtml(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const parent = node.parent orelse return qjs.undefinedValue();
    const markup = words(ctx, value) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, markup.ptr);
    if (fragmentOf(it, parent, markup)) |held| moveChildren(it, held, parent, node);
    lexbor.lxb_dom_node_remove(node);
    markChanged(it);
    return qjs.undefinedValue();
}

/// Markup put beside an element, or inside it at either end, as a page says
/// with `insertAdjacentHTML`.
fn jsInsertHtml(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const where = argument(ctx, argc, argv, 0) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, where.ptr);
    const markup = argument(ctx, argc, argv, 1) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, markup.ptr);
    const held = fragmentOf(it, node, markup) orelse return qjs.undefinedValue();
    if (std.ascii.eqlIgnoreCase(where, "beforebegin")) {
        if (node.parent) |parent| moveChildren(it, held, parent, node);
    } else if (std.ascii.eqlIgnoreCase(where, "afterend")) {
        if (node.parent) |parent| moveChildren(it, held, parent, node.next);
    } else if (std.ascii.eqlIgnoreCase(where, "afterbegin")) {
        moveChildren(it, held, node, node.first_child);
    } else {
        moveChildren(it, held, node, null);
    }
    markChanged(it);
    return qjs.undefinedValue();
}

/// `document.write`: markup put where the running script stands, after it,
/// or at the end of the body once the page has loaded.
fn jsWrite(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(it.gpa);
    for (0..@intCast(argc)) |i| {
        const piece = argument(ctx, argc, argv, i) orelse continue;
        defer qjs.freeText(ctx, piece.ptr);
        written.appendSlice(it.gpa, piece) catch break;
    }
    if (it.running) |script| {
        if (script.parent) |parent| {
            if (fragmentOf(it, parent, written.items)) |held| moveChildren(it, held, parent, script.next);
        }
    } else if (lexbor.lxb_html_document_body_element_noi(it.tree)) |body| {
        const node = lexbor.nodeOf(body);
        if (fragmentOf(it, node, written.items)) |held| moveChildren(it, held, node, null);
    }
    markChanged(it);
    return qjs.undefinedValue();
}

// ---------------------------------------------------------------------------
// Its class, and its style
// ---------------------------------------------------------------------------

/// The classes an element has, as words that stand in the attribute.
fn classesOf(node: *Node) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, attributeOf(node, "class") orelse "", &std.ascii.whitespace);
}

fn hasClass(node: *Node, wanted: []const u8) bool {
    var classes = classesOf(node);
    while (classes.next()) |one| {
        if (std.mem.eql(u8, one, wanted)) return true;
    }
    return false;
}

/// The element's classes with `added` among them and `removed` not, written
/// back as its attribute.
fn changeClasses(it: *Document, node: *Node, added: ?[]const u8, removed: ?[]const u8) void {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(it.gpa);
    var classes = classesOf(node);
    while (classes.next()) |one| {
        if (removed) |gone| if (std.mem.eql(u8, one, gone)) continue;
        if (added) |wanted| if (std.mem.eql(u8, one, wanted)) continue;
        if (joined.items.len > 0) joined.append(it.gpa, ' ') catch return;
        joined.appendSlice(it.gpa, one) catch return;
    }
    if (added) |wanted| {
        if (joined.items.len > 0) joined.append(it.gpa, ' ') catch return;
        joined.appendSlice(it.gpa, wanted) catch return;
    }
    attributeSet(it, node, "class", joined.items);
}

/// `element.classList`: a list over the element's own attribute, made afresh
/// each time it is asked for, since it is the attribute that is kept.
fn jsClassList(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const list = qjs.newObjectIn(ctx, @intCast(node_class));
    qjs.setNode(list, node);
    _ = qjs.addList(ctx, list, &list_methods, list_methods.len);
    var count: u32 = 0;
    var classes = classesOf(node);
    while (classes.next()) |one| : (count += 1) _ = qjs.setAt(ctx, list, count, str(ctx, one));
    _ = qjs.setStr(ctx, list, "length", qjs.newUint(ctx, count));
    return list;
}

fn jsClassAdd(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    for (0..@intCast(argc)) |i| {
        const wanted = argument(ctx, argc, argv, i) orelse continue;
        defer qjs.freeText(ctx, wanted.ptr);
        if (!hasClass(node, wanted)) changeClasses(it, node, wanted, null);
    }
    return qjs.undefinedValue();
}

fn jsClassRemove(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    for (0..@intCast(argc)) |i| {
        const gone = argument(ctx, argc, argv, i) orelse continue;
        defer qjs.freeText(ctx, gone.ptr);
        if (hasClass(node, gone)) changeClasses(it, node, null, gone);
    }
    return qjs.undefinedValue();
}

fn jsClassHas(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    const wanted = argument(ctx, argc, argv, 0) orelse return qjs.newBool(ctx, 0);
    defer qjs.freeText(ctx, wanted.ptr);
    return qjs.newBool(ctx, @intFromBool(hasClass(node, wanted)));
}

/// `toggle(name, force)`: on where it was off and off where it was on, or as
/// `force` says.
fn jsClassToggle(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newBool(ctx, 0);
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    const wanted = argument(ctx, argc, argv, 0) orelse return qjs.newBool(ctx, 0);
    defer qjs.freeText(ctx, wanted.ptr);
    const had = hasClass(node, wanted);
    const on = if (argc > 1) qjs.truthOf(ctx, argv[1]) > 0 else !had;
    if (on != had) changeClasses(it, node, if (on) wanted else null, if (on) null else wanted);
    return qjs.newBool(ctx, @intFromBool(on));
}

const list_methods = [_]qjs.ListEntry{
    .method("add", 1, &jsClassAdd),
    .method("remove", 1, &jsClassRemove),
    .method("contains", 1, &jsClassHas),
    .method("toggle", 1, &jsClassToggle),
};

/// The declarations of a `style` attribute, one at a time.
const Declarations = struct {
    parts: std.mem.SplitIterator(u8, .scalar),

    const Declaration = struct { property: []const u8, value: []const u8 };

    fn of(text: []const u8) Declarations {
        return .{ .parts = std.mem.splitScalar(u8, text, ';') };
    }

    fn next(self: *Declarations) ?Declaration {
        while (self.parts.next()) |one| {
            const colon = std.mem.indexOfScalar(u8, one, ':') orelse continue;
            return .{
                .property = std.mem.trim(u8, one[0..colon], &std.ascii.whitespace),
                .value = std.mem.trim(u8, one[colon + 1 ..], &std.ascii.whitespace),
            };
        }
        return null;
    }
};

/// What the element's own `style` attribute says for `property`.
fn styleValue(node: *Node, property: []const u8) ?[]const u8 {
    var declarations = Declarations.of(attributeOf(node, "style") orelse return null);
    while (declarations.next()) |declaration| {
        if (std.ascii.eqlIgnoreCase(declaration.property, property)) return declaration.value;
    }
    return null;
}

/// Write `property: value` into the element's `style` attribute, in place of
/// what it said for the property, or take the property out for an empty
/// value.
fn setStyle(it: *Document, node: *Node, property: []const u8, value: []const u8) void {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(it.gpa);
    var declarations = Declarations.of(attributeOf(node, "style") orelse "");
    while (declarations.next()) |declaration| {
        if (std.ascii.eqlIgnoreCase(declaration.property, property)) continue;
        appendStyle(it, &joined, declaration.property, declaration.value);
    }
    if (value.len > 0) appendStyle(it, &joined, property, value);
    attributeSet(it, node, "style", joined.items);
}

fn appendStyle(it: *Document, into: *std.ArrayList(u8), property: []const u8, value: []const u8) void {
    if (into.items.len > 0) into.append(it.gpa, ' ') catch return;
    into.print(it.gpa, "{s}: {s};", .{ property, value }) catch {};
}

/// The style properties a page reads and writes by name, and what each is
/// called in a stylesheet.
const Styled = struct { property: [*:0]const u8, css: []const u8 };

const styled = [_]Styled{
    .{ .property = "display", .css = "display" },
    .{ .property = "visibility", .css = "visibility" },
    .{ .property = "opacity", .css = "opacity" },
    .{ .property = "color", .css = "color" },
    .{ .property = "backgroundColor", .css = "background-color" },
    .{ .property = "background", .css = "background" },
    .{ .property = "textAlign", .css = "text-align" },
    .{ .property = "width", .css = "width" },
    .{ .property = "height", .css = "height" },
    .{ .property = "maxWidth", .css = "max-width" },
    .{ .property = "maxHeight", .css = "max-height" },
    .{ .property = "minHeight", .css = "min-height" },
    .{ .property = "position", .css = "position" },
    .{ .property = "top", .css = "top" },
    .{ .property = "left", .css = "left" },
    .{ .property = "right", .css = "right" },
    .{ .property = "bottom", .css = "bottom" },
    .{ .property = "fontSize", .css = "font-size" },
    .{ .property = "fontWeight", .css = "font-weight" },
    .{ .property = "transform", .css = "transform" },
    .{ .property = "transition", .css = "transition" },
    .{ .property = "overflow", .css = "overflow" },
    .{ .property = "zIndex", .css = "z-index" },
    .{ .property = "cursor", .css = "cursor" },
    .{ .property = "margin", .css = "margin" },
    .{ .property = "padding", .css = "padding" },
    .{ .property = "border", .css = "border" },
};

/// `element.style`: read and written as the page's own `style` attribute.
fn jsStyle(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    return styleObject(ctx, node, &style_gets);
}

fn styleObject(ctx: *Context, node: *Node, gets: []const qjs.ListEntry) Value {
    const style = qjs.newObjectIn(ctx, @intCast(node_class));
    qjs.setNode(style, node);
    _ = qjs.addList(ctx, style, &style_methods, style_methods.len);
    _ = qjs.addList(ctx, style, gets.ptr, @intCast(gets.len));
    return style;
}

fn jsStyleGet(ctx: *Context, this: Value, magic: c_int) callconv(.c) Value {
    const node = nodeOf(this) orelse return str(ctx, "");
    return str(ctx, styleValue(node, styled[@intCast(magic)].css) orelse "");
}

fn jsStyleSet(ctx: *Context, this: Value, value: Value, magic: c_int) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = words(ctx, value) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, text.ptr);
    setStyle(it, node, styled[@intCast(magic)].css, text);
    return qjs.undefinedValue();
}

/// The style the cascade gave an element, as far as this browser reads it:
/// what its own attribute says, and for `display`, whether the cascade
/// hides it.
fn jsComputedGet(ctx: *Context, this: Value, magic: c_int) callconv(.c) Value {
    const node = nodeOf(this) orelse return str(ctx, "");
    const which = styled[@intCast(magic)];
    if (styleValue(node, which.css)) |value| return str(ctx, value);
    if (std.mem.eql(u8, which.css, "display") and !css.shows(node)) return str(ctx, "none");
    return str(ctx, "");
}

fn jsStyleValue(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return str(ctx, "");
    const name = argument(ctx, argc, argv, 0) orelse return str(ctx, "");
    defer qjs.freeText(ctx, name.ptr);
    return str(ctx, styleValue(node, name) orelse "");
}

fn jsStyleSetProperty(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const name = argument(ctx, argc, argv, 0) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, name.ptr);
    const value = argument(ctx, argc, argv, 1) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, value.ptr);
    setStyle(it, node, name, value);
    return qjs.undefinedValue();
}

fn jsStyleRemove(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const name = argument(ctx, argc, argv, 0) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, name.ptr);
    setStyle(it, node, name, "");
    return qjs.undefinedValue();
}

fn jsStyleText(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return str(ctx, "");
    return str(ctx, attributeOf(node, "style") orelse "");
}

fn jsSetStyleText(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = words(ctx, value) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, text.ptr);
    attributeSet(it, node, "style", text);
    return qjs.undefinedValue();
}

const style_methods = [_]qjs.ListEntry{
    .method("setProperty", 2, &jsStyleSetProperty),
    .method("getPropertyValue", 1, &jsStyleValue),
    .method("removeProperty", 1, &jsStyleRemove),
};

/// The named properties of an element's own style, read and written, and of
/// a computed one, read.
const style_gets = styleEntries(&jsStyleGet, &jsStyleSet) ++ [_]qjs.ListEntry{
    .accessor("cssText", &jsStyleText, &jsSetStyleText),
};
const computed_gets = styleEntries(&jsComputedGet, null);

fn styleEntries(get: qjs.GetterMagic, set: ?qjs.SetterMagic) [styled.len]qjs.ListEntry {
    var out: [styled.len]qjs.ListEntry = undefined;
    for (styled, 0..) |which, i| out[i] = .accessorMagic(which.property, get, set, @intCast(i));
    return out;
}

// ---------------------------------------------------------------------------
// Changing the tree
// ---------------------------------------------------------------------------

/// Put `child` into `parent`, before `before` or at its end. A fragment
/// gives up what it holds instead of going in itself. A script put in by its
/// address is asked for, to run when it comes, and one holding its own words
/// runs now, as a browser runs one. True where it went in.
fn insert(it: *Document, parent: *Node, child: *Node, before: ?*Node) bool {
    if (child.type == .document_fragment) {
        moveChildren(it, child, parent, before);
        return true;
    }
    const placed = if (before) |at|
        lexbor.lxb_dom_node_insert_before_spec(parent, child, at)
    else
        lexbor.lxb_dom_node_append_child(parent, child);
    if (placed != .ok) return false;
    markChanged(it);
    noteRestyle(it, child);
    if (lexbor.tagOf(child) == .script and isJavaScript(child) and !it.ran_nodes.contains(child)) {
        it.ran_nodes.put(it.gpa, child, {}) catch return true;
        if (lexbor.attribute(child, "src")) |named| {
            var buf: [url.ADDRESS_MAX]u8 = undefined;
            if (resolvedFrom(it, named, &buf)) |resolved| _ = ask(it, resolved, null, .{ .script = child });
        } else {
            runElement(it, child, &.{});
        }
    }
    return true;
}

/// A node from an argument: the node it is, or a text node of the words it
/// is, which is what `append` and `before` take.
fn nodeFromArgument(it: *Document, value: Value) ?*Node {
    if (nodeOf(value)) |node| return node;
    const text = words(it.ctx, value) orelse return null;
    defer qjs.freeText(it.ctx, text.ptr);
    return lexbor.lxb_dom_document_create_text_node(it.tree, text.ptr, text.len);
}

fn jsAppendChild(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    if (argc < 1) return qjs.undefinedValue();
    const child = nodeOf(argv[0]) orelse return qjs.undefinedValue();
    if (!insert(it, node, child, null)) return qjs.undefinedValue();
    return qjs.dup(ctx, argv[0]);
}

fn jsInsertBefore(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    if (argc < 1) return qjs.undefinedValue();
    const child = nodeOf(argv[0]) orelse return qjs.undefinedValue();
    const before = if (argc > 1) nodeOf(argv[1]) else null;
    if (!insert(it, node, child, before)) return qjs.undefinedValue();
    return qjs.dup(ctx, argv[0]);
}

fn jsRemoveChild(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    if (argc < 1) return qjs.undefinedValue();
    const child = nodeOf(argv[0]) orelse return qjs.undefinedValue();
    if (lexbor.lxb_dom_node_remove_child(node, child) != .ok) return qjs.undefinedValue();
    markChanged(it);
    return qjs.dup(ctx, argv[0]);
}

fn jsReplaceChild(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    if (argc < 2) return qjs.undefinedValue();
    const made = nodeOf(argv[0]) orelse return qjs.undefinedValue();
    const gone = nodeOf(argv[1]) orelse return qjs.undefinedValue();
    if (lexbor.lxb_dom_node_replace_child(node, made, gone) != .ok) return qjs.undefinedValue();
    markChanged(it);
    noteRestyle(it, made);
    return qjs.dup(ctx, argv[1]);
}

fn jsRemove(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    if (node.parent != null) {
        lexbor.lxb_dom_node_remove(node);
        markChanged(it);
    }
    return qjs.undefinedValue();
}

/// Where `append`, `prepend`, `before`, `after` and `replaceWith` put what
/// they are given, each of which may be a node or words.
const Beside = enum { append, prepend, before, after, replace_with };

fn putBeside(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value, where: Beside) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const first = node.first_child;
    for (0..@intCast(argc)) |i| {
        const given = nodeFromArgument(it, argv[i]) orelse continue;
        switch (where) {
            .append => _ = insert(it, node, given, null),
            .prepend => _ = insert(it, node, given, first),
            .before, .replace_with => if (node.parent) |parent| {
                _ = insert(it, parent, given, node);
            },
            .after => if (node.parent) |parent| {
                _ = insert(it, parent, given, node.next);
            },
        }
    }
    if (where == .replace_with and node.parent != null) {
        lexbor.lxb_dom_node_remove(node);
        markChanged(it);
    }
    return qjs.undefinedValue();
}

fn jsAppend(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return putBeside(ctx, this, argc, argv, .append);
}

fn jsPrepend(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return putBeside(ctx, this, argc, argv, .prepend);
}

fn jsBefore(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return putBeside(ctx, this, argc, argv, .before);
}

fn jsAfter(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return putBeside(ctx, this, argc, argv, .after);
}

fn jsReplaceWith(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return putBeside(ctx, this, argc, argv, .replace_with);
}

/// Whether one node stands inside another, or is it.
fn jsContains(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    if (argc < 1) return qjs.newBool(ctx, 0);
    var at: ?*Node = nodeOf(argv[0]) orelse return qjs.newBool(ctx, 0);
    while (at) |each| : (at = each.parent) {
        if (each == node) return qjs.newBool(ctx, 1);
    }
    return qjs.newBool(ctx, 0);
}

fn jsClone(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const node = nodeOf(this) orelse return qjs.nullValue();
    const deep = argc > 0 and qjs.truthOf(ctx, argv[0]) > 0;
    return wrapped(it, lexbor.lxb_dom_node_clone(node, deep));
}

/// Whether the node is in the page: its root is the document.
fn jsConnected(ctx: *Context, this: Value) callconv(.c) Value {
    var at: ?*Node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    while (at) |each| : (at = each.parent) {
        if (each.type == .document) return qjs.newBool(ctx, 1);
    }
    return qjs.newBool(ctx, 0);
}

// ---------------------------------------------------------------------------
// Finding elements
// ---------------------------------------------------------------------------

/// What a search of the tree turned up, in document order.
const Found = struct { it: *Document, nodes: std.ArrayList(*Node) = .empty };

fn foundOne(node: *Node, _: u32, taken: ?*anyopaque) callconv(.c) lexbor.Status {
    const found: *Found = @ptrCast(@alignCast(taken));
    found.nodes.append(found.it.gpa, node) catch {};
    return .ok;
}

/// What a selector finds under `node`, or whether it matches `node` itself.
fn seek(it: *Document, node: *Node, selector: []const u8, how: enum { under, itself }) Found {
    var found: Found = .{ .it = it };
    const parser = it.parser orelse return found;
    const engine = it.selectors orelse return found;
    const parsed = lexbor.lxb_css_selectors_parse(parser, selector.ptr, selector.len) orelse return found;
    defer lexbor.lxb_css_selector_list_destroy(parsed);
    switch (how) {
        .under => _ = lexbor.lxb_selectors_find(engine, node, parsed, &foundOne, &found),
        .itself => _ = lexbor.lxb_selectors_match_node(engine, node, parsed, &foundOne, &found),
    }
    return found;
}

/// Every element in `found`, as an array; or the first alone, or null.
fn gathered(it: *Document, found: *Found, shape: enum { first, all }) Value {
    defer found.nodes.deinit(it.gpa);
    switch (shape) {
        .first => return wrapped(it, if (found.nodes.items.len > 0) found.nodes.items[0] else null),
        .all => {
            const out = qjs.newArray(it.ctx);
            for (found.nodes.items, 0..) |each, at| _ = qjs.setAt(it.ctx, out, @intCast(at), wrap(it, each));
            return out;
        },
    }
}

/// Every element of a kind, of a class, or with an attribute of a value,
/// under `root`, as lexbor gathers them.
fn collected(it: *Document, root: *Node, what: union(enum) { tag: []const u8, class: []const u8, attribute: struct { name: []const u8, value: []const u8 } }) Found {
    var found: Found = .{ .it = it };
    const held = lexbor.lxb_dom_collection_create(it.tree) orelse return found;
    defer _ = lexbor.lxb_dom_collection_destroy(held, true);
    if (lexbor.lxb_dom_collection_init(held, 16) != .ok) return found;
    const status = switch (what) {
        .tag => |name| lexbor.lxb_dom_elements_by_tag_name(root, held, name.ptr, name.len),
        .class => |name| lexbor.lxb_dom_elements_by_class_name(root, held, name.ptr, name.len),
        .attribute => |pair| lexbor.lxb_dom_elements_by_attr(root, held, pair.name.ptr, pair.name.len, pair.value.ptr, pair.value.len, false),
    };
    if (status != .ok) return found;
    for (0..lexbor.lexbor_collection_length(held)) |at| {
        const each = lexbor.lexbor_collection_element(held, at) orelse continue;
        found.nodes.append(it.gpa, lexbor.nodeOf(each)) catch break;
    }
    return found;
}

fn jsQuerySelector(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const from = nodeOrRoot(it, this) orelse return qjs.nullValue();
    const selector = argument(ctx, argc, argv, 0) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, selector.ptr);
    var found = seek(it, from, selector, .under);
    return gathered(it, &found, .first);
}

fn jsQuerySelectorAll(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newArray(ctx);
    const from = nodeOrRoot(it, this) orelse return qjs.newArray(ctx);
    const selector = argument(ctx, argc, argv, 0) orelse return qjs.newArray(ctx);
    defer qjs.freeText(ctx, selector.ptr);
    var found = seek(it, from, selector, .under);
    return gathered(it, &found, .all);
}

fn matchesSelector(it: *Document, node: *Node, selector: []const u8) bool {
    var found = seek(it, node, selector, .itself);
    defer found.nodes.deinit(it.gpa);
    return found.nodes.items.len > 0;
}

fn jsMatches(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newBool(ctx, 0);
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    const selector = argument(ctx, argc, argv, 0) orelse return qjs.newBool(ctx, 0);
    defer qjs.freeText(ctx, selector.ptr);
    return qjs.newBool(ctx, @intFromBool(matchesSelector(it, node, selector)));
}

fn jsClosest(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    var at: ?*Node = nodeOf(this) orelse return qjs.nullValue();
    const selector = argument(ctx, argc, argv, 0) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, selector.ptr);
    while (at) |node| : (at = node.parent) {
        if (node.type != .element) continue;
        if (matchesSelector(it, node, selector)) return wrap(it, node);
    }
    return qjs.nullValue();
}

fn jsGetById(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const root = rootOf(it) orelse return qjs.nullValue();
    const name = argument(ctx, argc, argv, 0) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, name.ptr);
    var found = collected(it, root, .{ .attribute = .{ .name = "id", .value = name } });
    return gathered(it, &found, .first);
}

fn jsGetByTag(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newArray(ctx);
    const from = nodeOrRoot(it, this) orelse return qjs.newArray(ctx);
    const name = argument(ctx, argc, argv, 0) orelse return qjs.newArray(ctx);
    defer qjs.freeText(ctx, name.ptr);
    var found = collected(it, from, .{ .tag = name });
    return gathered(it, &found, .all);
}

fn jsGetByClass(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newArray(ctx);
    const from = nodeOrRoot(it, this) orelse return qjs.newArray(ctx);
    const name = argument(ctx, argc, argv, 0) orelse return qjs.newArray(ctx);
    defer qjs.freeText(ctx, name.ptr);
    var found = collected(it, from, .{ .class = name });
    return gathered(it, &found, .all);
}

fn jsGetByName(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newArray(ctx);
    const root = rootOf(it) orelse return qjs.newArray(ctx);
    const name = argument(ctx, argc, argv, 0) orelse return qjs.newArray(ctx);
    defer qjs.freeText(ctx, name.ptr);
    var found = collected(it, root, .{ .attribute = .{ .name = "name", .value = name } });
    return gathered(it, &found, .all);
}

/// The elements of a kind, as the document gathers them: `document.forms`,
/// `document.images`, `document.links`, `document.scripts`.
fn jsCollection(ctx: *Context, _: Value, magic: c_int) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newArray(ctx);
    const root = rootOf(it) orelse return qjs.newArray(ctx);
    var found = collected(it, root, .{ .tag = collections[@intCast(magic)].tag });
    return gathered(it, &found, .all);
}

const collections = [_]struct { property: [*:0]const u8, tag: []const u8 }{
    .{ .property = "forms", .tag = "form" },
    .{ .property = "images", .tag = "img" },
    .{ .property = "links", .tag = "a" },
    .{ .property = "scripts", .tag = "script" },
};

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

fn jsAddListener(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    if (argc < 2 or qjs.isFunction(ctx, argv[1]) == 0) return qjs.undefinedValue();
    // Put on the window, or on the document, it is put on the page's root:
    // that is where a page's own events are told.
    const node = nodeOrRoot(it, this) orelse return qjs.undefinedValue();
    const kind = words(ctx, argv[0]) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, kind.ptr);
    it.watches.append(it.gpa, .{
        .node = node,
        .kind = keep(it, kind),
        .handler = qjs.dup(ctx, argv[1]),
    }) catch {};
    return qjs.undefinedValue();
}

/// Take away the listener a script put there: the very one, told by what it
/// is rather than by what it does.
fn jsRemoveListener(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    if (argc < 2) return qjs.undefinedValue();
    const node = nodeOrRoot(it, this) orelse return qjs.undefinedValue();
    const kind = words(ctx, argv[0]) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, kind.ptr);
    for (it.watches.items, 0..) |watch, at| {
        if (watch.node != node or !std.mem.eql(u8, watch.kind, kind)) continue;
        if (qjs.sameAs(ctx, watch.handler, argv[1]) == 0) continue;
        it.gpa.free(watch.kind);
        qjs.free(ctx, watch.handler);
        _ = it.watches.orderedRemove(at);
        break;
    }
    return qjs.undefinedValue();
}

fn jsPrevent(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    if (documentOf(ctx)) |it| it.prevented = true;
    _ = qjs.setStr(ctx, this, "defaultPrevented", qjs.newBool(ctx, 1));
    return qjs.undefinedValue();
}

fn jsStop(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    if (documentOf(ctx)) |it| it.stopped = true;
    return qjs.undefinedValue();
}

/// `initEvent`, which the oldest pages still say.
fn jsInitEvent(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc > 0) _ = qjs.setStr(ctx, this, "type", qjs.dup(ctx, argv[0]));
    return qjs.undefinedValue();
}

const event_methods = [_]qjs.ListEntry{
    .method("preventDefault", 0, &jsPrevent),
    .method("stopPropagation", 0, &jsStop),
    .method("stopImmediatePropagation", 0, &jsStop),
    .method("initEvent", 1, &jsInitEvent),
};

/// An event of `kind`, with nothing in it yet but what every event has.
fn eventOf(ctx: *Context, kind: []const u8) Value {
    const event = qjs.newObject(ctx);
    _ = qjs.addList(ctx, event, &event_methods, event_methods.len);
    _ = qjs.setStr(ctx, event, "type", str(ctx, kind));
    _ = qjs.setStr(ctx, event, "bubbles", qjs.newBool(ctx, 1));
    _ = qjs.setStr(ctx, event, "cancelable", qjs.newBool(ctx, 1));
    _ = qjs.setStr(ctx, event, "defaultPrevented", qjs.newBool(ctx, 0));
    return event;
}

fn jsNewEvent(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const kind = argument(ctx, argc, argv, 0) orelse return eventOf(ctx, "");
    defer qjs.freeText(ctx, kind.ptr);
    return eventOf(ctx, kind);
}

fn jsNewCustomEvent(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const event = jsNewEvent(ctx, this, argc, argv);
    if (argc > 1) _ = qjs.setStr(ctx, event, "detail", qjs.getStr(ctx, argv[1], "detail"));
    return event;
}

/// `document.createEvent`, which is `new Event` said the old way.
fn jsCreateEvent(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return eventOf(ctx, "");
}

/// `dispatchEvent(event)`: the event a script made, told to the node and to
/// what it stands inside. True unless a handler asked it to go no further.
fn jsDispatchEvent(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newBool(ctx, 1);
    if (argc < 1) return qjs.newBool(ctx, 1);
    const node = nodeOrRoot(it, this) orelse return qjs.newBool(ctx, 1);
    const type_value = qjs.getStr(ctx, argv[0], "type");
    defer qjs.free(ctx, type_value);
    const kind = words(ctx, type_value) orelse return qjs.newBool(ctx, 1);
    defer qjs.freeText(ctx, kind.ptr);
    const bubbles_value = qjs.getStr(ctx, argv[0], "bubbles");
    defer qjs.free(ctx, bubbles_value);
    const prevented = dispatch(it, node, qjs.dup(ctx, argv[0]), kind, qjs.truthOf(ctx, bubbles_value) > 0);
    return qjs.newBool(ctx, @intFromBool(!prevented));
}

/// Tell `node`, and where `bubbles` everything it stands inside, that `kind`
/// has happened, with a new event. True where a handler refused what the
/// event would do.
fn tell(it: *Document, node: *Node, kind: []const u8, bubbles: bool) bool {
    return dispatch(it, node, eventOf(it.ctx, kind), kind, bubbles);
}

/// Tell `node` and, where `bubbles`, everything it stands inside, with
/// `event`, which is taken. Each node's listeners are called first, then the
/// handler a script put on its object under `on` and the kind, then the one
/// the page wrote as an attribute of the same name.
fn dispatch(it: *Document, node: *Node, event: Value, kind: []const u8, bubbles: bool) bool {
    const ctx = it.ctx;
    defer qjs.free(ctx, event);
    it.prevented = false;
    it.stopped = false;
    _ = qjs.setStr(ctx, event, "target", wrap(it, node));

    var named: [NAME_MAX:0]u8 = undefined;
    const on = std.fmt.bufPrintZ(&named, "on{s}", .{kind}) catch return false;

    var at: ?*Node = node;
    while (at) |each| : (at = if (bubbles and !it.stopped) each.parent else null) {
        const current = wrap(it, each);
        defer qjs.free(ctx, current);
        _ = qjs.setStr(ctx, event, "currentTarget", qjs.dup(ctx, current));

        // A handler may add or remove listeners, which moves the list: the
        // handlers for this node are taken first, and additions wait for the
        // next event.
        var handlers: std.ArrayList(Value) = .empty;
        defer {
            for (handlers.items) |handler| qjs.free(ctx, handler);
            handlers.deinit(it.gpa);
        }
        for (it.watches.items) |watch| {
            if (watch.node != each or !std.mem.eql(u8, watch.kind, kind)) continue;
            handlers.append(it.gpa, qjs.dup(ctx, watch.handler)) catch break;
        }
        for (handlers.items) |handler| {
            if (it.stopped) break;
            const called = qjs.call(ctx, handler, current, 1, &[_]Value{event});
            if (qjs.isException(called)) reportError(it);
            qjs.free(ctx, called);
        }
        if (it.stopped) break;
        callHandler(it, current, on.ptr, event);
        if (it.stopped) break;
        if (attributeOf(each, on)) |source| runAttribute(it, current, source, event);
    }
    return it.prevented;
}

/// A handler the page wrote as an attribute: a function of `event` whose
/// body is the attribute's words, called with the element as `this`.
fn runAttribute(it: *Document, current: Value, source: []const u8, event: Value) void {
    const ctx = it.ctx;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(it.gpa);
    buf.print(it.gpa, "(function(event){{{s}\n}})", .{source}) catch return;
    const made = it.machine.run(ctx, buf.items, "<attribute>", .global);
    defer qjs.free(ctx, made);
    if (qjs.isException(made)) return reportError(it);
    const called = qjs.call(ctx, made, current, 1, &[_]Value{event});
    if (qjs.isException(called)) reportError(it);
    qjs.free(ctx, called);
}

fn jsClick(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    if (nodeOf(this)) |node| _ = tell(it, node, "click", true);
    return qjs.undefinedValue();
}

// ---------------------------------------------------------------------------
// What a page asks for and this browser has nothing to say about
// ---------------------------------------------------------------------------

/// A size and a place, as noughts: this browser sets a page in one column and
/// keeps no geometry, so where something is, is noughts rather than a guess.
fn jsBox(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    if (documentOf(ctx)) |it| missing(it, "getBoundingClientRect");
    const box = qjs.newObject(ctx);
    inline for (.{ "x", "y", "width", "height", "top", "left", "right", "bottom" }) |side| {
        _ = qjs.setStr(ctx, box, side, qjs.newInt(ctx, 0));
    }
    return box;
}

/// The style the cascade gave an element, as far as this browser reads it.
fn jsComputed(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newObject(ctx);
    missing(it, "getComputedStyle");
    if (argc < 1) return qjs.newObject(ctx);
    const node = nodeOf(argv[0]) orelse return qjs.newObject(ctx);
    settleStyles(it);
    return styleObject(ctx, node, &computed_gets);
}

/// An observer: a page may watch for something to happen, and nothing it can
/// watch for ever happens here, so it is given one that watches and is silent.
fn jsWatcher(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    if (documentOf(ctx)) |it| missing(it, "observers");
    const watcher = qjs.newObject(ctx);
    inline for (.{ "observe", "unobserve", "disconnect", "takeRecords" }) |name| give(ctx, watcher, name, 0, &jsNothing);
    return watcher;
}

/// Asked of a browser with no way to answer: `scrollIntoView`, `focus` and
/// `blur`, `alert`, `confirm` and `prompt`, and the walking of a history this
/// browser keeps for itself. Each says what it was.
fn jsAsked(ctx: *Context, _: Value, _: c_int, _: [*]const Value, magic: c_int) callconv(.c) Value {
    if (documentOf(ctx)) |it| missing(it, asked_for[@intCast(magic)]);
    return qjs.undefinedValue();
}

const asked_for = [_][]const u8{ "scrollIntoView", "focus", "blur", "alert", "confirm", "prompt", "history" };

fn askedMethod(comptime name: [*:0]const u8, comptime which: usize) qjs.ListEntry {
    const S = struct {
        fn call(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
            return jsAsked(ctx, this, argc, argv, which);
        }
    };
    return .method(name, 0, &S.call);
}

/// A browser base class. The browser's nodes are handed to scripts as objects
/// rather than made through these, but a page's own components extend
/// `HTMLElement` before they touch a node, and need a constructor to extend.
fn jsPlatformClass(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return qjs.newObject(ctx);
}

/// `new Image()`: an image element not yet in the page.
fn jsNewImage(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const made = lexbor.lxb_dom_document_create_element(it.tree, "img", 3, null) orelse return qjs.nullValue();
    return wrap(it, lexbor.nodeOf(made));
}

/// `matchMedia`: what a stylesheet's query says of the window the page is
/// in, which is the same question the browser asks of its stylesheets.
fn jsMedia(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newObject(ctx);
    const query = qjs.newObject(ctx);
    const asked = argument(ctx, argc, argv, 0);
    defer if (asked) |text| qjs.freeText(ctx, text.ptr);
    const text: []const u8 = asked orelse "";
    _ = qjs.setStr(ctx, query, "matches", qjs.newBool(ctx, @intFromBool(media.matches(text, it.host.screen))));
    _ = qjs.setStr(ctx, query, "media", str(ctx, text));
    inline for (.{ "addListener", "removeListener", "addEventListener", "removeEventListener" }) |name| give(ctx, query, name, 2, &jsNothing);
    return query;
}

/// The clock, as a page asks for it: milliseconds since the machine started.
fn jsNow(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newInt(ctx, 0);
    return qjs.newUint(ctx, now(it));
}

/// `atob` and `btoa`: text from base64 and back, which pages use for what
/// they keep and send.
fn jsAtob(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const text = argument(ctx, argc, argv, 0) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, text.ptr);
    const size = std.base64.standard.Decoder.calcSizeForSlice(text) catch return qjs.nullValue();
    const out = it.gpa.alloc(u8, size) catch return qjs.nullValue();
    defer it.gpa.free(out);
    std.base64.standard.Decoder.decode(out, text) catch return qjs.nullValue();
    return str(ctx, out);
}

fn jsBtoa(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const text = argument(ctx, argc, argv, 0) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, text.ptr);
    const out = it.gpa.alloc(u8, std.base64.standard.Encoder.calcSize(text.len)) catch return qjs.nullValue();
    defer it.gpa.free(out);
    return str(ctx, std.base64.standard.Encoder.encode(out, text));
}

// ---------------------------------------------------------------------------
// The element
// ---------------------------------------------------------------------------

/// An attribute read and written as a property: `input.type`, `img.alt`,
/// `a.title`, and the rest, which a page says far more often than
/// `getAttribute`. An attribute the element does not have reads as empty.
const Reflected = struct { property: [*:0]const u8, attribute: []const u8 };

const reflected = [_]Reflected{
    .{ .property = "id", .attribute = "id" },
    .{ .property = "className", .attribute = "class" },
    .{ .property = "value", .attribute = "value" },
    .{ .property = "href", .attribute = "href" },
    .{ .property = "src", .attribute = "src" },
    .{ .property = "type", .attribute = "type" },
    .{ .property = "name", .attribute = "name" },
    .{ .property = "title", .attribute = "title" },
    .{ .property = "alt", .attribute = "alt" },
    .{ .property = "placeholder", .attribute = "placeholder" },
    .{ .property = "action", .attribute = "action" },
    .{ .property = "method", .attribute = "method" },
    .{ .property = "htmlFor", .attribute = "for" },
    .{ .property = "rel", .attribute = "rel" },
    .{ .property = "target", .attribute = "target" },
    .{ .property = "lang", .attribute = "lang" },
    .{ .property = "role", .attribute = "role" },
    .{ .property = "content", .attribute = "content" },
};

fn jsReflectedGet(ctx: *Context, this: Value, magic: c_int) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const which = reflected[@intCast(magic)];
    // A list's value is its chosen entry's, and a text area's its words.
    if (std.mem.eql(u8, which.attribute, "value")) {
        if (isTag(node, "SELECT")) {
            var text = NodeText{ .node = node, .data = null, .bytes = "" };
            defer text.deinit();
            return str(ctx, if (chosenOption(node)) |chosen| optionValue(chosen, &text) else "");
        }
        if (isTag(node, "TEXTAREA")) {
            const text = textOfNode(node);
            defer text.deinit();
            return str(ctx, text.bytes);
        }
    }
    return str(ctx, attributeOf(node, which.attribute) orelse "");
}

fn jsReflectedSet(ctx: *Context, this: Value, value: Value, magic: c_int) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const text = words(ctx, value) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, text.ptr);
    const which = reflected[@intCast(magic)];
    if (std.mem.eql(u8, which.attribute, "value") and isTag(node, "SELECT")) {
        // The entry with that value is the one chosen, and no other.
        var at = lexbor.following(node, node);
        while (at) |here| : (at = lexbor.following(here, node)) {
            if (!isTag(here, "OPTION")) continue;
            var held = NodeText{ .node = here, .data = null, .bytes = "" };
            defer held.deinit();
            const matches = std.mem.eql(u8, optionValue(here, &held), text);
            if (matches) attributeSet(it, here, "selected", "") else if (attributeOf(here, "selected") != null) attributeRemove(it, here, "selected");
        }
        return qjs.undefinedValue();
    }
    attributeSet(it, node, which.attribute, text);
    return qjs.undefinedValue();
}

/// `select.selectedIndex`: which entry is chosen, counted from nought, or
/// minus one for a list with none.
fn jsSelectedIndex(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.newInt(ctx, -1);
    return qjs.newInt(ctx, if (chosenIndex(node)) |index| @intCast(index) else -1);
}

fn jsSetSelectedIndex(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    var wanted: i32 = 0;
    _ = qjs.toInt(ctx, &wanted, value);
    var count: i32 = 0;
    var at = lexbor.following(node, node);
    while (at) |here| : (at = lexbor.following(here, node)) {
        if (!isTag(here, "OPTION")) continue;
        if (count == wanted) attributeSet(it, here, "selected", "") else if (attributeOf(here, "selected") != null) attributeRemove(it, here, "selected");
        count += 1;
    }
    return qjs.undefinedValue();
}

/// `select.options`: its entries, in order.
fn jsOptions(ctx: *Context, this: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newArray(ctx);
    const out = qjs.newArray(ctx);
    const node = nodeOf(this) orelse return out;
    var count: u32 = 0;
    var at = lexbor.following(node, node);
    while (at) |here| : (at = lexbor.following(here, node)) {
        if (!isTag(here, "OPTION")) continue;
        _ = qjs.setAt(ctx, out, count, wrap(it, here));
        count += 1;
    }
    _ = qjs.setStr(ctx, out, "length", qjs.newUint(ctx, count));
    return out;
}

/// An attribute that is there or not, read and written as a boolean:
/// `checked`, `disabled`, `hidden`, and the rest.
const Flagged = struct { property: [*:0]const u8, attribute: []const u8 };

const flagged = [_]Flagged{
    .{ .property = "checked", .attribute = "checked" },
    .{ .property = "disabled", .attribute = "disabled" },
    .{ .property = "hidden", .attribute = "hidden" },
    .{ .property = "readOnly", .attribute = "readonly" },
    .{ .property = "required", .attribute = "required" },
    .{ .property = "selected", .attribute = "selected" },
    .{ .property = "multiple", .attribute = "multiple" },
    .{ .property = "open", .attribute = "open" },
};

fn jsFlagGet(ctx: *Context, this: Value, magic: c_int) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.newBool(ctx, 0);
    return qjs.newBool(ctx, @intFromBool(attributeOf(node, flagged[@intCast(magic)].attribute) != null));
}

fn jsFlagSet(ctx: *Context, this: Value, value: Value, magic: c_int) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const name = flagged[@intCast(magic)].attribute;
    if (qjs.truthOf(ctx, value) > 0) attributeSet(it, node, name, "") else attributeRemove(it, node, name);
    return qjs.undefinedValue();
}

fn jsTagName(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    return switch (node.type) {
        .element => str(ctx, tagOf(node)),
        .text => str(ctx, "#text"),
        .comment => str(ctx, "#comment"),
        .document => str(ctx, "#document"),
        .document_fragment => str(ctx, "#document-fragment"),
        else => qjs.undefinedValue(),
    };
}

fn jsNodeType(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    return qjs.newInt(ctx, @intFromEnum(node.type));
}

/// The ways about the tree: a node's neighbours, with or without the text
/// between elements.
const Way = enum { parent, first_child, last_child, first_element, last_element, next, previous, next_element, previous_element };

fn jsWay(ctx: *Context, this: Value, magic: c_int) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const node = nodeOf(this) orelse return qjs.nullValue();
    const way: Way = @enumFromInt(magic);
    return wrapped(it, switch (way) {
        .parent => node.parent,
        .first_child => node.first_child,
        .last_child => node.last_child,
        .next => node.next,
        .previous => node.prev,
        .first_element => elementFrom(node.first_child, .next),
        .last_element => elementFrom(node.last_child, .previous),
        .next_element => elementFrom(node.next, .next),
        .previous_element => elementFrom(node.prev, .previous),
    });
}

/// The first element at or after `from`, going the way said.
fn elementFrom(from: ?*Node, direction: enum { next, previous }) ?*Node {
    var at = from;
    while (at) |node| {
        if (node.type == .element) return node;
        at = switch (direction) {
            .next => node.next,
            .previous => node.prev,
        };
    }
    return null;
}

fn wayEntry(comptime name: [*:0]const u8, comptime way: Way) qjs.ListEntry {
    return .accessorMagic(name, &jsWay, null, @intFromEnum(way));
}

fn jsChildren(ctx: *Context, this: Value, magic: c_int) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newArray(ctx);
    const out = qjs.newArray(ctx);
    const node = nodeOf(this) orelse return out;
    const elements_only = magic != 0;
    var at: u32 = 0;
    var each = node.first_child;
    while (each) |one| : (each = one.next) {
        if (elements_only and one.type != .element) continue;
        _ = qjs.setAt(ctx, out, at, wrap(it, one));
        at += 1;
    }
    _ = qjs.setStr(ctx, out, "length", qjs.newUint(ctx, at));
    return out;
}

fn jsChildElementCount(ctx: *Context, this: Value) callconv(.c) Value {
    const node = nodeOf(this) orelse return qjs.newInt(ctx, 0);
    var count: u32 = 0;
    var each = node.first_child;
    while (each) |one| : (each = one.next) {
        if (one.type == .element) count += 1;
    }
    return qjs.newUint(ctx, count);
}

fn jsOwnerDocument(ctx: *Context, _: Value) callconv(.c) Value {
    const global = qjs.globalOf(ctx);
    defer qjs.free(ctx, global);
    return qjs.getStr(ctx, global, "document");
}

/// The form a control belongs to, which is the nearest form it stands in.
fn formOf(node: *Node) ?*Node {
    var at: ?*Node = node;
    while (at) |each| : (at = each.parent) {
        if (each.type == .element and isTag(each, "FORM")) return each;
    }
    return null;
}

fn jsForm(ctx: *Context, this: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const node = nodeOf(this) orelse return qjs.nullValue();
    return wrapped(it, formOf(node));
}

/// `form.elements`: its controls, in order.
fn jsElements(ctx: *Context, this: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newArray(ctx);
    const node = nodeOf(this) orelse return qjs.newArray(ctx);
    var found = seek(it, node, "input, select, textarea, button", .under);
    return gathered(it, &found, .all);
}

const node_methods = [_]qjs.ListEntry{
    .method("getAttribute", 1, &jsGetAttribute),
    .method("setAttribute", 2, &jsSetAttribute),
    .method("hasAttribute", 1, &jsHasAttribute),
    .method("removeAttribute", 1, &jsRemoveAttribute),
    .method("toggleAttribute", 1, &jsToggleAttribute),
    .method("getAttributeNames", 0, &jsAttributeNames),
    .method("appendChild", 1, &jsAppendChild),
    .method("insertBefore", 2, &jsInsertBefore),
    .method("replaceChild", 2, &jsReplaceChild),
    .method("removeChild", 1, &jsRemoveChild),
    .method("remove", 0, &jsRemove),
    .method("append", 1, &jsAppend),
    .method("prepend", 1, &jsPrepend),
    .method("before", 1, &jsBefore),
    .method("after", 1, &jsAfter),
    .method("replaceWith", 1, &jsReplaceWith),
    .method("contains", 1, &jsContains),
    .method("cloneNode", 1, &jsClone),
    .method("insertAdjacentHTML", 2, &jsInsertHtml),
    .method("addEventListener", 2, &jsAddListener),
    .method("removeEventListener", 2, &jsRemoveListener),
    .method("dispatchEvent", 1, &jsDispatchEvent),
    .method("querySelector", 1, &jsQuerySelector),
    .method("querySelectorAll", 1, &jsQuerySelectorAll),
    .method("getElementsByTagName", 1, &jsGetByTag),
    .method("getElementsByClassName", 1, &jsGetByClass),
    .method("matches", 1, &jsMatches),
    .method("closest", 1, &jsClosest),
    .method("click", 0, &jsClick),
    .method("submit", 0, &jsSubmit),
    .method("requestSubmit", 0, &jsSubmit),
    .method("reset", 0, &jsNothing),
    .method("attachShadow", 1, &jsAttachShadow),
    .method("getBoundingClientRect", 0, &jsBox),
    .method("setAttributeNS", 3, &jsSetAttributeNs),
    askedMethod("scrollIntoView", 0),
    askedMethod("focus", 1),
    askedMethod("blur", 2),
};

const node_gets = reflectedEntries() ++ flaggedEntries() ++ [_]qjs.ListEntry{
    .accessor("textContent", &jsTextContent, &jsSetTextContent),
    .accessor("innerText", &jsTextContent, &jsSetTextContent),
    .accessor("nodeValue", &jsTextContent, &jsSetTextContent),
    .accessor("innerHTML", &jsInnerHtml, &jsSetInnerHtml),
    .accessor("outerHTML", &jsOuterHtml, &jsSetOuterHtml),
    .accessor("classList", &jsClassList, null),
    .accessor("style", &jsStyle, null),
    .accessor("dataset", &jsDataset, null),
    .accessor("tagName", &jsTagName, null),
    .accessor("nodeName", &jsTagName, null),
    .accessor("nodeType", &jsNodeType, null),
    .accessor("isConnected", &jsConnected, null),
    .accessor("ownerDocument", &jsOwnerDocument, null),
    .accessor("form", &jsForm, null),
    .accessor("elements", &jsElements, null),
    .accessor("selectedIndex", &jsSelectedIndex, &jsSetSelectedIndex),
    .accessor("options", &jsOptions, null),
    wayEntry("parentNode", .parent),
    wayEntry("parentElement", .parent),
    wayEntry("firstChild", .first_child),
    wayEntry("lastChild", .last_child),
    wayEntry("firstElementChild", .first_element),
    wayEntry("lastElementChild", .last_element),
    wayEntry("nextSibling", .next),
    wayEntry("previousSibling", .previous),
    wayEntry("nextElementSibling", .next_element),
    wayEntry("previousElementSibling", .previous_element),
    .accessorMagic("children", &jsChildren, null, 1),
    .accessorMagic("childNodes", &jsChildren, null, 0),
    .accessor("childElementCount", &jsChildElementCount, null),
    .accessor("offsetWidth", &jsZero, null),
    .accessor("offsetHeight", &jsZero, null),
    .accessor("offsetTop", &jsZero, null),
    .accessor("offsetLeft", &jsZero, null),
    .accessor("clientWidth", &jsZero, null),
    .accessor("clientHeight", &jsZero, null),
    .accessor("scrollWidth", &jsZero, null),
    .accessor("scrollHeight", &jsZero, null),
    .accessor("scrollTop", &jsZero, &jsSetNothing),
    .accessor("scrollLeft", &jsZero, &jsSetNothing),
};

fn reflectedEntries() [reflected.len]qjs.ListEntry {
    var out: [reflected.len]qjs.ListEntry = undefined;
    for (reflected, 0..) |which, i| out[i] = .accessorMagic(which.property, &jsReflectedGet, &jsReflectedSet, @intCast(i));
    return out;
}

fn flaggedEntries() [flagged.len]qjs.ListEntry {
    var out: [flagged.len]qjs.ListEntry = undefined;
    for (flagged, 0..) |which, i| out[i] = .accessorMagic(which.property, &jsFlagGet, &jsFlagSet, @intCast(i));
    return out;
}

/// `setAttributeNS`: the attribute, whatever the namespace.
fn jsSetAttributeNs(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc < 3) return qjs.undefinedValue();
    return jsSetAttribute(ctx, this, argc - 1, argv + 1);
}

/// `attachShadow`: the element itself stands for its shadow, so a component
/// that puts its markup in the shadow puts it in the page.
fn jsAttachShadow(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return qjs.dup(ctx, this);
}

// ---------------------------------------------------------------------------
// Asking for a page of your own
// ---------------------------------------------------------------------------

/// Ask the browser for `address`, sending `sent` where the ask is a POST.
/// Nothing where the page has too many asks open already.
fn ask(it: *Document, address: []const u8, sent: ?http.Payload, kind: @FieldType(Pending, "kind")) ?u32 {
    if (it.asks.items.len == ASKS_MAX) return null;
    it.next_ask += 1;
    const kept_address = keep(it, address);
    const kept_sent: ?http.Payload = if (sent) |payload| .{ .bytes = keep(it, payload.bytes), .kind = keep(it, payload.kind) } else null;
    it.asks.append(it.gpa, .{
        .ask = .{ .id = it.next_ask, .address = kept_address, .sent = kept_sent, .script = kind == .script },
        .kind = kind,
    }) catch {
        it.gpa.free(kept_address);
        if (kept_sent) |payload| {
            it.gpa.free(payload.bytes);
            it.gpa.free(payload.kind);
        }
        return null;
    };
    return it.next_ask;
}

/// Let go of an ask and what it holds.
fn dropPending(it: *Document, pending: *Pending) void {
    it.gpa.free(pending.ask.address);
    if (pending.ask.sent) |payload| {
        it.gpa.free(payload.bytes);
        it.gpa.free(payload.kind);
    }
    switch (pending.kind) {
        .fetch => |ends| {
            qjs.free(it.ctx, ends[0]);
            qjs.free(it.ctx, ends[1]);
        },
        .xhr => |request| qjs.free(it.ctx, request),
        .script => {},
    }
}

fn freeGoing(it: *Document, going: Going) void {
    it.gpa.free(going.address);
    if (going.sent) |body| it.gpa.free(body);
}

/// Say where a script asked to be taken, with what it sends there. The
/// last asking is the one that counts, as it is in a browser.
fn goTo(it: *Document, address: []const u8, sent: ?[]const u8) void {
    var buf: [url.ADDRESS_MAX]u8 = undefined;
    const resolved = resolvedFrom(it, address, &buf) orelse return;
    if (it.going) |old| freeGoing(it, old);
    it.going = .{ .address = keep(it, resolved), .sent = if (sent) |body| keep(it, body) else null };
}

/// What a `fetch` sends, from the options a script gives: the `body` where
/// the `method` is not GET, as the kind its headers say, or plain text. The
/// words are the engine's, given back with `freeText`.
const Sending = struct {
    bytes: [:0]const u8,
    kind: ?[:0]const u8,

    fn payload(self: Sending) http.Payload {
        return .{ .bytes = self.bytes, .kind = self.kind orelse "text/plain;charset=UTF-8" };
    }

    fn deinit(self: Sending, ctx: *Context) void {
        qjs.freeText(ctx, self.bytes.ptr);
        if (self.kind) |kind| qjs.freeText(ctx, kind.ptr);
    }
};

fn sentOf(it: *Document, options: Value) ?Sending {
    const ctx = it.ctx;
    if (!qjs.isObject(options)) return null;
    const method = qjs.getStr(ctx, options, "method");
    defer qjs.free(ctx, method);
    const how = words(ctx, method) orelse return null;
    defer qjs.freeText(ctx, how.ptr);
    if (std.ascii.eqlIgnoreCase(how, "get") or std.ascii.eqlIgnoreCase(how, "head")) return null;
    const body = qjs.getStr(ctx, options, "body");
    defer qjs.free(ctx, body);
    const bytes = words(ctx, if (qjs.isUndefined(body) or qjs.isNull(body)) str(ctx, "") else qjs.dup(ctx, body)) orelse return null;
    const headers = qjs.getStr(ctx, options, "headers");
    defer qjs.free(ctx, headers);
    var kind: ?[:0]const u8 = null;
    if (qjs.isObject(headers)) {
        for ([_][*:0]const u8{ "Content-Type", "content-type" }) |name| {
            const given = qjs.getStr(ctx, headers, name);
            defer qjs.free(ctx, given);
            if (qjs.isUndefined(given)) continue;
            kind = words(ctx, given);
            break;
        }
    }
    return .{ .bytes = bytes, .kind = kind };
}

/// The answer a `fetch` came to, as a script reads one: `ok`, `status`, and
/// `text()` and `json()`, each a promise of the body.
fn response(it: *Document, address: []const u8, got: Answer) Value {
    const ctx = it.ctx;
    const out = qjs.newObject(ctx);
    _ = qjs.addList(ctx, out, &answer_methods, answer_methods.len);
    _ = qjs.setStr(ctx, out, "ok", qjs.newBool(ctx, @intFromBool(got.status / 100 == 2)));
    _ = qjs.setStr(ctx, out, "status", qjs.newInt(ctx, got.status));
    _ = qjs.setStr(ctx, out, "statusText", str(ctx, ""));
    _ = qjs.setStr(ctx, out, "url", str(ctx, address));
    _ = qjs.setStr(ctx, out, "redirected", qjs.newBool(ctx, 0));
    _ = qjs.setStr(ctx, out, "headers", headersObject(ctx));
    _ = qjs.setStr(ctx, out, "__body", str(ctx, got.body));
    return out;
}

fn jsAnswerText(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return settled(ctx, qjs.getStr(ctx, this, "__body"));
}

fn jsAnswerJson(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    const body = qjs.getStr(ctx, this, "__body");
    defer qjs.free(ctx, body);
    const text = words(ctx, body) orelse return settled(ctx, qjs.nullValue());
    defer qjs.freeText(ctx, text.ptr);
    const parsed = qjs.parseJson(ctx, text.ptr, text.len, "<fetch>");
    if (qjs.isException(parsed)) {
        if (documentOf(ctx)) |it| reportError(it);
        return settled(ctx, qjs.nullValue());
    }
    return settled(ctx, parsed);
}

fn jsAnswerClone(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return qjs.dup(ctx, this);
}

const answer_methods = [_]qjs.ListEntry{
    .method("text", 0, &jsAnswerText),
    .method("json", 0, &jsAnswerJson),
    .method("clone", 0, &jsAnswerClone),
};

/// `Headers`, as far as a page reads them: a shape with nothing in it.
fn headersObject(ctx: *Context) Value {
    const headers = qjs.newObject(ctx);
    give(ctx, headers, "get", 1, &jsNone);
    give(ctx, headers, "has", 1, &jsNo);
    inline for (.{ "set", "append", "delete", "forEach" }) |name| give(ctx, headers, name, 2, &jsNothing);
    return headers;
}

fn jsNewHeaders(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return headersObject(ctx);
}

/// `fetch`: ask the browser for a page, and promise its answer, which comes
/// on a later pass.
fn jsFetch(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    var ends: [2]Value = undefined;
    const made = qjs.promise(ctx, &ends);
    const asked = argument(ctx, argc, argv, 0) orelse {
        refuse(it, ends, "fetch: nothing to fetch");
        return made;
    };
    defer qjs.freeText(ctx, asked.ptr);
    var buf: [url.ADDRESS_MAX]u8 = undefined;
    const resolved_address = resolvedFrom(it, asked, &buf) orelse {
        refuse(it, ends, "fetch: not an address");
        return made;
    };
    const sent = if (argc > 1) sentOf(it, argv[1]) else null;
    defer if (sent) |sending| sending.deinit(ctx);
    const payload: ?http.Payload = if (sent) |sending| sending.payload() else null;
    if (ask(it, resolved_address, payload, .{ .fetch = ends }) == null) refuse(it, ends, "fetch: too many at once");
    return made;
}

/// Break a promise, with a reason, and let go of its two ends.
fn refuse(it: *Document, ends: [2]Value, why: []const u8) void {
    const ctx = it.ctx;
    const reason = qjs.newError(ctx);
    _ = qjs.setStr(ctx, reason, "message", str(ctx, why));
    callOnce(it, ends[1], reason);
    qjs.free(ctx, ends[0]);
    qjs.free(ctx, ends[1]);
}

fn jsXhrOpen(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc > 0) _ = qjs.setStr(ctx, this, "__method", qjs.dup(ctx, argv[0]));
    if (argc > 1) _ = qjs.setStr(ctx, this, "__url", qjs.dup(ctx, argv[1]));
    _ = qjs.setStr(ctx, this, "readyState", qjs.newInt(ctx, 1));
    return qjs.undefinedValue();
}

fn jsXhrSend(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const asked = qjs.getStr(ctx, this, "__url");
    defer qjs.free(ctx, asked);
    const address = words(ctx, asked) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, address.ptr);
    var buf: [url.ADDRESS_MAX]u8 = undefined;
    const resolved_address = resolvedFrom(it, address, &buf) orelse return qjs.undefinedValue();
    const method = qjs.getStr(ctx, this, "__method");
    defer qjs.free(ctx, method);
    const how = words(ctx, method) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, how.ptr);
    const posts = !std.ascii.eqlIgnoreCase(how, "get") and !std.ascii.eqlIgnoreCase(how, "head");
    const body = if (posts and argc > 0) words(ctx, argv[0]) else null;
    defer if (body) |text| qjs.freeText(ctx, text.ptr);
    const sent: ?http.Payload = if (posts) .{ .bytes = body orelse "", .kind = "text/plain;charset=UTF-8" } else null;
    _ = ask(it, resolved_address, sent, .{ .xhr = qjs.dup(ctx, this) });
    return qjs.undefinedValue();
}

/// `addEventListener` on a request: `load` and the rest go under the names
/// the request is told with.
fn jsXhrListen(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc < 2) return qjs.undefinedValue();
    const kind = words(ctx, argv[0]) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, kind.ptr);
    var named: [NAME_MAX:0]u8 = undefined;
    const on = std.fmt.bufPrintZ(&named, "on{s}", .{kind}) catch return qjs.undefinedValue();
    _ = qjs.setStr(ctx, this, on, qjs.dup(ctx, argv[1]));
    return qjs.undefinedValue();
}

const xhr_methods = [_]qjs.ListEntry{
    .method("open", 2, &jsXhrOpen),
    .method("send", 1, &jsXhrSend),
    .method("setRequestHeader", 2, &jsNothing),
    .method("getResponseHeader", 1, &jsNone),
    .method("getAllResponseHeaders", 0, &jsNone),
    .method("addEventListener", 2, &jsXhrListen),
    .method("abort", 0, &jsNothing),
};

fn jsNewXhr(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    const request = qjs.newObject(ctx);
    _ = qjs.addList(ctx, request, &xhr_methods, xhr_methods.len);
    _ = qjs.setStr(ctx, request, "readyState", qjs.newInt(ctx, 0));
    _ = qjs.setStr(ctx, request, "status", qjs.newInt(ctx, 0));
    _ = qjs.setStr(ctx, request, "responseText", str(ctx, ""));
    return request;
}

// ---------------------------------------------------------------------------
// What a page keeps
// ---------------------------------------------------------------------------

/// `document.cookie`: what the browser's jar holds for the page, less what
/// a site marked as its own alone.
fn jsCookie(ctx: *Context, _: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return str(ctx, "");
    const where = url.parse(it.address) orelse return str(ctx, "");
    var line: [COOKIES_MAX]u8 = undefined;
    return str(ctx, it.host.jar.write(where, false, &line));
}

fn jsSetCookie(ctx: *Context, _: Value, value: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const where = url.parse(it.address) orelse return qjs.undefinedValue();
    const given = words(ctx, value) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, given.ptr);
    it.host.jar.take(it.host.gpa, where, given, false);
    return qjs.undefinedValue();
}

fn jsStoreGet(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const store = it.store orelse return qjs.nullValue();
    const key = argument(ctx, argc, argv, 0) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, key.ptr);
    return if (store.get(key)) |got| str(ctx, got) else qjs.nullValue();
}

fn jsStoreSet(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const store = it.store orelse return qjs.undefinedValue();
    const key = argument(ctx, argc, argv, 0) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, key.ptr);
    const value = argument(ctx, argc, argv, 1) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, value.ptr);
    _ = store.put(it.host.gpa, key, value);
    return qjs.undefinedValue();
}

fn jsStoreRemove(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const store = it.store orelse return qjs.undefinedValue();
    const key = argument(ctx, argc, argv, 0) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, key.ptr);
    store.remove(it.host.gpa, key);
    return qjs.undefinedValue();
}

fn jsStoreClear(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const store = it.store orelse return qjs.undefinedValue();
    store.clear(it.host.gpa);
    return qjs.undefinedValue();
}

fn jsStoreKey(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const store = it.store orelse return qjs.nullValue();
    if (argc < 1) return qjs.nullValue();
    var wanted: i32 = 0;
    _ = qjs.toInt(ctx, &wanted, argv[0]);
    if (wanted < 0) return qjs.nullValue();
    return if (store.keyAt(@intCast(wanted))) |key| str(ctx, key) else qjs.nullValue();
}

fn jsStoreSize(ctx: *Context, _: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.newInt(ctx, 0);
    const store = it.store orelse return qjs.newInt(ctx, 0);
    return qjs.newUint(ctx, @intCast(store.count()));
}

const store_methods = [_]qjs.ListEntry{
    .method("getItem", 1, &jsStoreGet),
    .method("setItem", 2, &jsStoreSet),
    .method("removeItem", 1, &jsStoreRemove),
    .method("clear", 0, &jsStoreClear),
    .method("key", 1, &jsStoreKey),
    .accessor("length", &jsStoreSize, null),
};

// ---------------------------------------------------------------------------
// Later
// ---------------------------------------------------------------------------

/// Call `handler` after `after` milliseconds, and every `every` after that
/// where `every` is not nought.
fn schedule(it: *Document, handler: Value, after: u32, every: u32, frame: bool) Value {
    it.next_timer += 1;
    it.timers.append(it.gpa, .{
        .id = it.next_timer,
        .handler = qjs.dup(it.ctx, handler),
        .due = now(it) + after,
        .every = every,
        .frame = frame,
    }) catch return qjs.undefinedValue();
    return qjs.newUint(it.ctx, it.next_timer);
}

/// The milliseconds a script asks for, from its argument, or nought.
fn millisecondsOf(ctx: *Context, argc: c_int, argv: [*]const Value, index: usize) u32 {
    if (index >= @as(usize, @intCast(argc))) return 0;
    var given: f64 = 0;
    _ = qjs.toFloat(ctx, &given, argv[index]);
    if (!(given > 0)) return 0;
    return @intFromFloat(@min(given, std.math.maxInt(u32) / 2));
}

fn jsSetTimeout(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    if (argc < 1 or qjs.isFunction(ctx, argv[0]) == 0) return qjs.undefinedValue();
    return schedule(it, argv[0], millisecondsOf(ctx, argc, argv, 1), 0, false);
}

fn jsSetInterval(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    if (argc < 1 or qjs.isFunction(ctx, argv[0]) == 0) return qjs.undefinedValue();
    const every = @max(millisecondsOf(ctx, argc, argv, 1), INTERVAL_MIN_MS);
    return schedule(it, argv[0], every, every, false);
}

fn jsAnimationFrame(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    if (argc < 1 or qjs.isFunction(ctx, argv[0]) == 0) return qjs.undefinedValue();
    return schedule(it, argv[0], FRAME_MS, 0, true);
}

fn jsMicrotask(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    if (argc < 1 or qjs.isFunction(ctx, argv[0]) == 0) return qjs.undefinedValue();
    _ = schedule(it, argv[0], 0, 0, false);
    return qjs.undefinedValue();
}

fn jsClearTimer(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    if (argc < 1) return qjs.undefinedValue();
    var wanted: i32 = 0;
    _ = qjs.toInt(ctx, &wanted, argv[0]);
    if (wanted <= 0) return qjs.undefinedValue();
    if (timerIndex(it, @intCast(wanted))) |at| {
        qjs.free(ctx, it.timers.items[at].handler);
        _ = it.timers.orderedRemove(at);
    }
    return qjs.undefinedValue();
}

fn timerIndex(it: *Document, id: u32) ?usize {
    for (it.timers.items, 0..) |timer, at| {
        if (timer.id == id) return at;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Where the page is
// ---------------------------------------------------------------------------

/// The parts of an address a page picks apart, put on `into`: `href`,
/// `protocol`, `host`, `hostname`, `origin`, `pathname`, `search`, `hash`.
fn partsInto(ctx: *Context, into: Value, parsed: url.Url) void {
    var href: [url.ADDRESS_MAX]u8 = undefined;
    const canonical = std.fmt.bufPrint(&href, "{f}", .{parsed}) catch "";
    _ = qjs.setStr(ctx, into, "href", str(ctx, canonical));
    var protocol: [16]u8 = undefined;
    _ = qjs.setStr(ctx, into, "protocol", str(ctx, std.fmt.bufPrint(&protocol, "{s}:", .{@tagName(parsed.scheme)}) catch ""));
    var host: [url.ADDRESS_MAX]u8 = undefined;
    var host_writer: std.Io.Writer = .fixed(&host);
    parsed.writeHost(&host_writer) catch {};
    _ = qjs.setStr(ctx, into, "host", str(ctx, host_writer.buffered()));
    _ = qjs.setStr(ctx, into, "hostname", str(ctx, parsed.host));
    _ = qjs.setStr(ctx, into, "origin", str(ctx, originOf(parsed)));
    const query_at = std.mem.indexOfScalar(u8, parsed.path, '?') orelse parsed.path.len;
    _ = qjs.setStr(ctx, into, "pathname", str(ctx, if (query_at == 0) "/" else parsed.path[0..query_at]));
    _ = qjs.setStr(ctx, into, "search", str(ctx, parsed.path[query_at..]));
    _ = qjs.setStr(ctx, into, "hash", str(ctx, ""));
}

/// The page's location, as a script sees it: where it is, and the ways of
/// being sent somewhere else.
fn locationOf(it: *Document) Value {
    const ctx = it.ctx;
    const where = qjs.newObject(ctx);
    if (url.parse(it.address)) |parsed| partsInto(ctx, where, parsed);
    _ = qjs.addList(ctx, where, &where_methods, where_methods.len);
    const href = qjs.atomOf(ctx, "href");
    defer qjs.freeAtom(ctx, href);
    _ = qjs.addAccessor(ctx, where, href, qjs.function(ctx, @ptrCast(&jsHrefOf), "href", 0, .getter, 0), qjs.function(ctx, @ptrCast(&jsSetHref), "href", 1, .setter, 0), qjs.flags.accessor);
    return where;
}

fn jsLocationHere(ctx: *Context, _: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    return locationOf(it);
}

/// The window a script stands in, which is the world its globals are in.
fn jsWindowHere(ctx: *Context, _: Value) callconv(.c) Value {
    return qjs.globalOf(ctx);
}

/// `location = "..."`, and `location.href = "..."`: a page asking to be
/// taken somewhere, which is what a page that has moved says. Asked for
/// where it already is, it is not asked to go anywhere: a page that sends
/// the browser to itself is how a circle starts.
fn jsSetLocation(ctx: *Context, _: Value, value: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const where = words(ctx, value) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, where.ptr);
    if (!std.mem.eql(u8, where, it.address)) goTo(it, where, null);
    return qjs.undefinedValue();
}

fn jsHrefOf(ctx: *Context, _: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return str(ctx, "");
    return str(ctx, it.address);
}

fn jsSetHref(ctx: *Context, this: Value, value: Value) callconv(.c) Value {
    return jsSetLocation(ctx, this, value);
}

/// `location.assign`, `location.replace` and `location.reload`: the ways a
/// page says go, and go again.
fn jsGoTo(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const where = argument(ctx, argc, argv, 0);
    defer if (where) |text| qjs.freeText(ctx, text.ptr);
    goTo(it, where orelse it.address, null);
    return qjs.undefinedValue();
}

fn jsLocationString(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return qjs.getStr(ctx, this, "href");
}

const where_methods = [_]qjs.ListEntry{
    .method("assign", 1, &jsGoTo),
    .method("replace", 1, &jsGoTo),
    .method("reload", 0, &jsGoTo),
    .method("toString", 0, &jsLocationString),
};

/// `new URL(reference, base)`: the browser's own resolver, in the shape a
/// script expects.
fn jsNewUrl(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const reference = argument(ctx, argc, argv, 0) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, reference.ptr);
    var resolved_buf: [url.ADDRESS_MAX]u8 = undefined;
    const whole = if (url.parse(reference) != null) reference else base: {
        const base_text = argument(ctx, argc, argv, 1);
        defer if (base_text) |text| qjs.freeText(ctx, text.ptr);
        const base_url = url.parse(base_text orelse it.address) orelse return qjs.nullValue();
        break :base url.resolve(base_url, reference, &resolved_buf) orelse return qjs.nullValue();
    };
    const parsed = url.parse(whole) orelse return qjs.nullValue();
    const out = qjs.newObject(ctx);
    partsInto(ctx, out, parsed);
    give(ctx, out, "toString", 0, &jsLocationString);
    _ = qjs.setStr(ctx, out, "searchParams", paramsOf(ctx, parsed.path[std.mem.indexOfScalar(u8, parsed.path, '?') orelse parsed.path.len ..]));
    return out;
}

/// `URLSearchParams`: the query as a page reads it, a name at a time. Kept as
/// the words it was made from, which `get` reads through.
fn paramsOf(ctx: *Context, query: []const u8) Value {
    const params = qjs.newObject(ctx);
    _ = qjs.addList(ctx, params, &params_methods, params_methods.len);
    _ = qjs.setStr(ctx, params, "__q", str(ctx, if (query.len > 0 and query[0] == '?') query[1..] else query));
    return params;
}

fn jsNewParams(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const given = argument(ctx, argc, argv, 0);
    defer if (given) |text| qjs.freeText(ctx, text.ptr);
    return paramsOf(ctx, given orelse "");
}

/// The value under `name` in a query, or nothing: `a=1&b=2`, read with its
/// plus signs and percent escapes undone.
fn paramValue(query: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.tokenizeScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equal = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (!std.mem.eql(u8, unescaped(pair[0..equal]) orelse continue, name)) continue;
        return unescaped(if (equal < pair.len) pair[equal + 1 ..] else "");
    }
    return null;
}

/// `text` with its plus signs and percent escapes undone, kept until the
/// next asking. The browser's form encoding read backwards, so a query a
/// script reads matches what one it sends carries.
fn unescaped(text: []const u8) ?[]const u8 {
    const S = struct {
        var buf: [url.ADDRESS_MAX]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    form_mod.writeDecoded(&w, text) catch return null;
    return w.buffered();
}

fn jsParamsGet(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const held = qjs.getStr(ctx, this, "__q");
    defer qjs.free(ctx, held);
    const query = words(ctx, held) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, query.ptr);
    const name = argument(ctx, argc, argv, 0) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, name.ptr);
    return if (paramValue(query, name)) |value| str(ctx, value) else qjs.nullValue();
}

fn jsParamsHas(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const got = jsParamsGet(ctx, this, argc, argv);
    defer qjs.free(ctx, got);
    return qjs.newBool(ctx, @intFromBool(!qjs.isNull(got)));
}

fn jsParamsText(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return qjs.getStr(ctx, this, "__q");
}

const params_methods = [_]qjs.ListEntry{
    .method("get", 1, &jsParamsGet),
    .method("has", 1, &jsParamsHas),
    .method("set", 2, &jsNothing),
    .method("append", 2, &jsNothing),
    .method("delete", 1, &jsNothing),
    .method("toString", 0, &jsParamsText),
};

// ---------------------------------------------------------------------------
// A form sent by a script
// ---------------------------------------------------------------------------

/// Every answer in `node`'s subtree that goes under a name, written into `w`
/// the way a form sends them: a form's own controls, which is what a form
/// sends. The encoding is `form`'s, so a script sends what the browser does.
fn answersIn(node: *Node, w: *std.Io.Writer) void {
    var first = true;
    var at = lexbor.following(node, node);
    while (at) |one| : (at = lexbor.following(one, node)) {
        if (one.type != .element) continue;
        if (!isTag(one, "INPUT") and !isTag(one, "SELECT") and !isTag(one, "TEXTAREA")) continue;
        const named = attributeOf(one, "name") orelse continue;
        if (isTag(one, "INPUT")) {
            const kind = attributeOf(one, "type") orelse "text";
            const ticks = std.ascii.eqlIgnoreCase(kind, "checkbox") or std.ascii.eqlIgnoreCase(kind, "radio");
            if (ticks and attributeOf(one, "checked") == null) continue;
            if (std.ascii.eqlIgnoreCase(kind, "submit") or std.ascii.eqlIgnoreCase(kind, "button")) continue;
        }
        var text = NodeText{ .node = one, .data = null, .bytes = "" };
        defer text.deinit();
        // A box ticked, or a radio button chosen, without a value of its own
        // sends `on`, which is what a form is told; a list sends the entry
        // chosen on it.
        const value = if (isTag(one, "SELECT"))
            optionValue(chosenOption(one) orelse continue, &text)
        else
            attributeOf(one, "value") orelse if (isTag(one, "INPUT")) "on" else words: {
                text = textOfNode(one);
                break :words text.bytes;
            };
        form_mod.writeAnswer(w, first, named, value, .utf8) catch return;
        first = false;
    }
}

/// `form.submit()`: a page sending its own form, which is what a page that
/// says "click here if you are not redirected" is really doing. Sent the way
/// the form says: in the address, as a search is, or in the body of a
/// request, as logging in is.
fn jsSubmit(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = nodeOf(this) orelse return qjs.undefinedValue();
    const form = formOf(node) orelse return qjs.undefinedValue();
    if (tell(it, form, "submit", true)) return qjs.undefinedValue();

    var buf: [form_mod.ANSWERS_MAX]u8 = undefined;
    var answers: std.Io.Writer = .fixed(&buf);
    answersIn(form, &answers);
    const sent = answers.buffered();
    const action = attributeOf(form, "action") orelse it.address;
    if (std.ascii.eqlIgnoreCase(attributeOf(form, "method") orelse "get", "post")) {
        goTo(it, action, sent);
        return qjs.undefinedValue();
    }
    var where: [url.ADDRESS_MAX]u8 = undefined;
    var w: std.Io.Writer = .fixed(&where);
    w.writeAll(action[0 .. std.mem.indexOfScalar(u8, action, '?') orelse action.len]) catch return qjs.undefinedValue();
    if (sent.len > 0) w.print("?{s}", .{sent}) catch return qjs.undefinedValue();
    goTo(it, w.buffered(), null);
    return qjs.undefinedValue();
}

// ---------------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------------

fn jsCreateElement(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const name = argument(ctx, argc, argv, 0) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, name.ptr);
    const made = lexbor.lxb_dom_document_create_element(it.tree, name.ptr, name.len, null) orelse return qjs.nullValue();
    return wrap(it, lexbor.nodeOf(made));
}

/// `createElementNS(namespace, name)`: the element, whatever the namespace.
fn jsCreateElementNs(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    if (argc < 2) return qjs.nullValue();
    return jsCreateElement(ctx, this, argc - 1, argv + 1);
}

fn jsCreateText(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const text = argument(ctx, argc, argv, 0) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, text.ptr);
    return wrapped(it, lexbor.lxb_dom_document_create_text_node(it.tree, text.ptr, text.len));
}

fn jsCreateComment(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    const text = argument(ctx, argc, argv, 0) orelse return qjs.nullValue();
    defer qjs.freeText(ctx, text.ptr);
    return wrapped(it, lexbor.lxb_dom_document_create_comment(it.tree, text.ptr, text.len));
}

fn jsCreateFragment(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    return wrapped(it, lexbor.lxb_dom_document_create_document_fragment(it.tree));
}

/// The page's `<title>` element, found rather than asked for: asking the
/// document for one before the parser has settled it is a way to fall over.
fn titled(it: *Document) ?*Node {
    const root = rootOf(it) orelse return null;
    var found = collected(it, root, .{ .tag = "title" });
    defer found.nodes.deinit(it.gpa);
    return if (found.nodes.items.len > 0) found.nodes.items[0] else null;
}

fn jsTitle(ctx: *Context, _: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return str(ctx, "");
    const node = titled(it) orelse return str(ctx, "");
    const text = textOfNode(node);
    defer text.deinit();
    return str(ctx, text.bytes);
}

fn jsSetTitle(ctx: *Context, _: Value, value: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.undefinedValue();
    const node = titled(it) orelse return qjs.undefinedValue();
    const text = words(ctx, value) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, text.ptr);
    _ = lexbor.lxb_dom_node_text_content_set(node, text.ptr, text.len);
    markChanged(it);
    return qjs.undefinedValue();
}

/// The document's root, its body and its head.
fn jsPart(ctx: *Context, _: Value, magic: c_int) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    return wrapped(it, switch (magic) {
        0 => rootOf(it),
        1 => if (lexbor.lxb_html_document_body_element_noi(it.tree)) |body| lexbor.nodeOf(body) else null,
        else => if (lexbor.lxb_html_document_head_element_noi(it.tree)) |head| lexbor.nodeOf(head) else null,
    });
}

/// The script running now, which a script asks for to find itself.
fn jsCurrentScript(ctx: *Context, _: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return qjs.nullValue();
    return wrapped(it, it.running);
}

fn jsUrl(ctx: *Context, _: Value) callconv(.c) Value {
    const it = documentOf(ctx) orelse return str(ctx, "");
    return str(ctx, it.address);
}

/// The page is read: a script run at the end of a parse is not one waiting
/// for it. And it is not hidden: this browser shows one page at a time.
fn jsWord(ctx: *Context, _: Value, magic: c_int) callconv(.c) Value {
    return str(ctx, document_words[@intCast(magic)].word);
}

const document_words = [_]struct { property: [*:0]const u8, word: []const u8 }{
    .{ .property = "readyState", .word = "complete" },
    .{ .property = "visibilityState", .word = "visible" },
    .{ .property = "referrer", .word = "" },
    .{ .property = "characterSet", .word = "UTF-8" },
    .{ .property = "compatMode", .word = "CSS1Compat" },
};

fn jsNotHidden(ctx: *Context, _: Value) callconv(.c) Value {
    return qjs.newBool(ctx, 0);
}

const document_methods = [_]qjs.ListEntry{
    .method("getElementById", 1, &jsGetById),
    .method("getElementsByTagName", 1, &jsGetByTag),
    .method("getElementsByClassName", 1, &jsGetByClass),
    .method("getElementsByName", 1, &jsGetByName),
    .method("querySelector", 1, &jsQuerySelector),
    .method("querySelectorAll", 1, &jsQuerySelectorAll),
    .method("createElement", 1, &jsCreateElement),
    .method("createElementNS", 2, &jsCreateElementNs),
    .method("createTextNode", 1, &jsCreateText),
    .method("createComment", 1, &jsCreateComment),
    .method("createDocumentFragment", 0, &jsCreateFragment),
    .method("createEvent", 1, &jsCreateEvent),
    .method("addEventListener", 2, &jsAddListener),
    .method("removeEventListener", 2, &jsRemoveListener),
    .method("dispatchEvent", 1, &jsDispatchEvent),
    .method("write", 1, &jsWrite),
    .method("writeln", 1, &jsWrite),
    .method("hasFocus", 0, &jsYes),
};

const document_gets = [_]qjs.ListEntry{
    .accessor("title", &jsTitle, &jsSetTitle),
    .accessor("cookie", &jsCookie, &jsSetCookie),
    .accessorMagic("documentElement", &jsPart, null, 0),
    .accessorMagic("body", &jsPart, null, 1),
    .accessorMagic("head", &jsPart, null, 2),
    .accessorMagic("activeElement", &jsPart, null, 1),
    .accessor("location", &jsLocationHere, &jsSetLocation),
    .accessor("URL", &jsUrl, null),
    .accessor("documentURI", &jsUrl, null),
    .accessor("currentScript", &jsCurrentScript, null),
    .accessor("defaultView", &jsWindowHere, null),
    .accessor("hidden", &jsNotHidden, null),
    .accessorMagic("readyState", &jsWord, null, 0),
    .accessorMagic("visibilityState", &jsWord, null, 1),
    .accessorMagic("referrer", &jsWord, null, 2),
    .accessorMagic("characterSet", &jsWord, null, 3),
    .accessorMagic("compatMode", &jsWord, null, 4),
    .accessorMagic("forms", &jsCollection, null, 0),
    .accessorMagic("images", &jsCollection, null, 1),
    .accessorMagic("links", &jsCollection, null, 2),
    .accessorMagic("scripts", &jsCollection, null, 3),
};

/// The window a page stands in: what is true of any window, whether or not
/// this browser has one to show. A history it cannot walk, a screen it is
/// drawn on, a clock, and no way to ask a question of the person reading.
fn furnish(it: *Document) void {
    const ctx = it.ctx;
    const global = qjs.globalOf(ctx);
    defer qjs.free(ctx, global);

    const document = qjs.newObject(ctx);
    _ = qjs.addList(ctx, document, &document_methods, document_methods.len);
    _ = qjs.addList(ctx, document, &document_gets, document_gets.len);
    const implementation = qjs.newObject(ctx);
    give(ctx, implementation, "hasFeature", 2, &jsYes);
    _ = qjs.setStr(ctx, document, "implementation", implementation);
    _ = qjs.setStr(ctx, global, "document", document);

    // The window is the world a script stands in, which is the one the
    // document hangs from: `window.x` and `x` are the same thing, as a page
    // expects them to be. Given as a getter rather than as a copy of the
    // global: a copy is the global holding itself, which is a knot the
    // engine cannot undo when the page is freed, and it says so.
    inline for (.{ "window", "self", "top", "parent", "globalThis" }) |one| {
        const atom = qjs.atomOf(ctx, one);
        defer qjs.freeAtom(ctx, atom);
        _ = qjs.addAccessor(ctx, global, atom, qjs.function(ctx, @ptrCast(&jsWindowHere), one, 0, .getter, 0), qjs.undefinedValue(), qjs.flags.accessor);
    }
    const location = qjs.atomOf(ctx, "location");
    defer qjs.freeAtom(ctx, location);
    _ = qjs.addAccessor(ctx, global, location, qjs.function(ctx, @ptrCast(&jsLocationHere), "location", 0, .getter, 0), qjs.function(ctx, @ptrCast(&jsSetLocation), "location", 1, .setter, 0), qjs.flags.accessor);

    const who = qjs.newObject(ctx);
    _ = qjs.setStr(ctx, who, "userAgent", str(ctx, it.host.user_agent));
    _ = qjs.setStr(ctx, who, "language", str(ctx, "en"));
    const languages = qjs.newArray(ctx);
    _ = qjs.setAt(ctx, languages, 0, str(ctx, "en"));
    _ = qjs.setStr(ctx, who, "languages", languages);
    _ = qjs.setStr(ctx, who, "platform", str(ctx, "vibeee"));
    _ = qjs.setStr(ctx, who, "cookieEnabled", qjs.newBool(ctx, 1));
    _ = qjs.setStr(ctx, who, "onLine", qjs.newBool(ctx, 1));
    _ = qjs.setStr(ctx, global, "navigator", who);

    // What a page is drawn on and in: as wide and tall as the window the
    // browser has, in the page's own pixels.
    const width: i32 = if (it.host.screen) |screen| @intFromFloat(screen.width) else 800;
    const height: i32 = if (it.host.screen) |screen| @intFromFloat(screen.height) else 480;
    const screen = qjs.newObject(ctx);
    inline for (.{ "width", "availWidth" }) |side| _ = qjs.setStr(ctx, screen, side, qjs.newInt(ctx, width));
    inline for (.{ "height", "availHeight" }) |side| _ = qjs.setStr(ctx, screen, side, qjs.newInt(ctx, height));
    _ = qjs.setStr(ctx, screen, "colorDepth", qjs.newInt(ctx, 24));
    _ = qjs.setStr(ctx, global, "screen", screen);
    _ = qjs.setStr(ctx, global, "innerWidth", qjs.newInt(ctx, width));
    _ = qjs.setStr(ctx, global, "innerHeight", qjs.newInt(ctx, height));
    _ = qjs.setStr(ctx, global, "outerWidth", qjs.newInt(ctx, width));
    _ = qjs.setStr(ctx, global, "outerHeight", qjs.newInt(ctx, height));
    _ = qjs.setStr(ctx, global, "devicePixelRatio", qjs.newInt(ctx, 1));
    _ = qjs.setStr(ctx, global, "scrollX", qjs.newInt(ctx, 0));
    _ = qjs.setStr(ctx, global, "scrollY", qjs.newInt(ctx, 0));

    const history = qjs.newObject(ctx);
    _ = qjs.addList(ctx, history, &history_methods, history_methods.len);
    _ = qjs.setStr(ctx, history, "length", qjs.newInt(ctx, 1));
    _ = qjs.setStr(ctx, history, "state", qjs.nullValue());
    _ = qjs.setStr(ctx, global, "history", history);

    const clock = qjs.newObject(ctx);
    give(ctx, clock, "now", 0, &jsNow);
    inline for (.{ "mark", "measure", "getEntriesByName", "getEntriesByType" }) |name| give(ctx, clock, name, 1, &jsNothing);
    _ = qjs.setStr(ctx, global, "performance", clock);

    // Consent bootstraps ask for a frame in `window.frames` before they make
    // it: an empty list lets them go on.
    const frames = qjs.newObject(ctx);
    _ = qjs.setStr(ctx, frames, "length", qjs.newInt(ctx, 0));
    _ = qjs.setStr(ctx, global, "frames", frames);

    const store = qjs.newObject(ctx);
    _ = qjs.addList(ctx, store, &store_methods, store_methods.len);
    _ = qjs.setStr(ctx, global, "localStorage", store);
    _ = qjs.setStr(ctx, global, "sessionStorage", qjs.dup(ctx, store));

    _ = qjs.addList(ctx, global, &window_methods, window_methods.len);
    _ = qjs.addList(ctx, global, &window_constructors, window_constructors.len);
    inline for (.{ "MutationObserver", "IntersectionObserver", "ResizeObserver", "PerformanceObserver" }) |one| {
        _ = qjs.setStr(ctx, global, one, qjs.newConstructor(ctx, one, 1, &jsWatcher));
    }

    // Browser base classes, which a page's own components extend before
    // they touch a node. What a node is given as inherits from the same
    // prototype, so a node is an instance of each of them, as it should be.
    inline for (.{ "EventTarget", "Node", "Element", "HTMLElement", "Text", "CharacterData", "Document", "HTMLDocument" }) |one| {
        const constructor = qjs.newConstructor(ctx, one, 0, &jsPlatformClass);
        _ = qjs.setStr(ctx, constructor, "prototype", qjs.dup(ctx, it.node_proto));
        _ = qjs.setStr(ctx, global, one, constructor);
    }
    inline for (.{ "HTMLBodyElement", "HTMLDivElement", "HTMLIFrameElement", "HTMLFormElement", "HTMLInputElement", "HTMLButtonElement", "HTMLAnchorElement", "HTMLImageElement", "HTMLScriptElement", "HTMLTemplateElement", "SVGElement", "ShadowRoot", "DocumentFragment" }) |one| {
        const constructor = qjs.newConstructor(ctx, one, 0, &jsPlatformClass);
        _ = qjs.setStr(ctx, constructor, "prototype", qjs.dup(ctx, it.node_proto));
        _ = qjs.setStr(ctx, global, one, constructor);
    }
    const custom = qjs.newObject(ctx);
    inline for (.{ "define", "get", "whenDefined", "upgrade" }) |name| give(ctx, custom, name, 2, &jsNothing);
    _ = qjs.setStr(ctx, global, "customElements", custom);
}

const history_methods = [_]qjs.ListEntry{
    askedMethod("back", 6),
    askedMethod("forward", 6),
    askedMethod("go", 6),
    .method("pushState", 3, &jsNothing),
    .method("replaceState", 3, &jsNothing),
};

const window_methods = [_]qjs.ListEntry{
    .method("setTimeout", 2, &jsSetTimeout),
    .method("setInterval", 2, &jsSetInterval),
    .method("clearTimeout", 1, &jsClearTimer),
    .method("clearInterval", 1, &jsClearTimer),
    .method("requestAnimationFrame", 1, &jsAnimationFrame),
    .method("cancelAnimationFrame", 1, &jsClearTimer),
    .method("requestIdleCallback", 1, &jsSetTimeout),
    .method("cancelIdleCallback", 1, &jsClearTimer),
    .method("queueMicrotask", 1, &jsMicrotask),
    .method("fetch", 2, &jsFetch),
    .method("getComputedStyle", 1, &jsComputed),
    .method("matchMedia", 1, &jsMedia),
    .method("addEventListener", 2, &jsAddListener),
    .method("removeEventListener", 2, &jsRemoveListener),
    .method("dispatchEvent", 1, &jsDispatchEvent),
    .method("atob", 1, &jsAtob),
    .method("btoa", 1, &jsBtoa),
    .method("open", 1, &jsNone),
    .method("close", 0, &jsNothing),
    .method("scrollTo", 2, &jsNothing),
    .method("scrollBy", 2, &jsNothing),
    .method("scroll", 2, &jsNothing),
    .method("postMessage", 2, &jsNothing),
    .method("getSelection", 0, &jsNone),
    askedMethod("alert", 3),
    askedMethod("confirm", 4),
    askedMethod("prompt", 5),
};

const window_constructors = [_]qjs.ListEntry{
    constructorEntry("XMLHttpRequest", 0, &jsNewXhr),
    constructorEntry("URL", 2, &jsNewUrl),
    constructorEntry("URLSearchParams", 1, &jsNewParams),
    constructorEntry("Headers", 1, &jsNewHeaders),
    constructorEntry("Event", 2, &jsNewEvent),
    constructorEntry("CustomEvent", 2, &jsNewCustomEvent),
    constructorEntry("Image", 2, &jsNewImage),
    constructorEntry("AbortController", 0, &jsNewAbortController),
    constructorEntry("FormData", 1, &jsEmpty),
};

/// A constructor a page calls with `new`, as a row of a property list.
fn constructorEntry(comptime name: [*:0]const u8, arity: u8, impl: qjs.Method) qjs.ListEntry {
    return .{
        .name = name,
        .prop_flags = qjs.flags.method,
        .def_type = .cfunc,
        .magic = 0,
        .u = .{ .func = .{
            .length = arity,
            .cproto = @intFromEnum(qjs.CProto.constructor_or_func),
            .which = .{ .generic = impl },
        } },
    };
}

fn jsNewAbortController(ctx: *Context, _: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    const controller = qjs.newObject(ctx);
    const signal = qjs.newObject(ctx);
    _ = qjs.setStr(ctx, signal, "aborted", qjs.newBool(ctx, 0));
    give(ctx, signal, "addEventListener", 2, &jsNothing);
    _ = qjs.setStr(ctx, controller, "signal", signal);
    give(ctx, controller, "abort", 0, &jsNothing);
    return controller;
}
