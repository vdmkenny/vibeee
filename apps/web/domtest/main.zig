//! The reader's document, tested on this machine.
//!
//! QuickJS and lexbor are built for the host here rather than for the target,
//! so a page can be parsed, a script run in it, and the tree read back, which
//! is the only way to know that what a script sees is what the page is. It is
//! where Zig meets two vendored trees: a value handed to the wrong kind of
//! call, matches gathered in a callback and lost, a title asked for before the
//! parser had settled it, none of which a check of either alone would catch.
//!
//! Each test runs a script in a page and asks what came of it: what it said,
//! what the tree reads as now, or what it asked the reader for.

const std = @import("std");
const js = @import("js");
const qjs = @import("quickjs");
const cookie = @import("../cookie.zig");
const css = @import("../css.zig");
const dom = @import("../dom.zig");
const extract = @import("../extract.zig");
const lexbor = @import("../lexbor.zig");
const page_mod = @import("../page.zig");
const rgb = @import("lib").rgb;
const storage = @import("../storage.zig");
const url = @import("../url.zig");

const heap = std.heap.page_allocator;
const testing = std.testing;

/// The page every test starts from, with the script stood in its body.
const PAGE =
    \\<!DOCTYPE html><html><head><title>Hello</title></head><body>
    \\<p id="one">first</p>
    \\<p class="noted">second</p>
    \\<div class="noted"><p id="two">deep</p></div>
    \\<script>{s}</script>
    \\</body></html>
;

const ADDRESS = "http://example.test/one";

/// Markup with `script` stood in it, as a page's own script would be.
fn with(script: []const u8) []const u8 {
    return std.fmt.allocPrint(heap, PAGE, .{script}) catch @panic("out of memory");
}

/// What the reader keeps around a page, for the pages here to share.
var jar: cookie.Jar = .{};
var store: storage.Storage = .{};
/// The rules a test's stylesheet gave the page.
var rules: css.Rules = .empty;

/// A page, parsed, with a document bound into it and its scripts run.
const Opened = struct {
    doc: *dom.Document,
    tree: *lexbor.Document,

    /// Let the page go, and with it what the reader kept around it, so that
    /// each test starts with nothing and leaks nothing.
    fn end(self: Opened) void {
        dom.close(self.doc);
        lexbor.lxb_style_destroy(self.tree);
        _ = lexbor.lxb_html_document_destroy(self.tree);
        jar.deinit(testing.allocator);
        store.deinit(testing.allocator);
        rules.deinit(heap);
        rules = .empty;
    }

    /// Run `script` on the page, and give back what it ended in, as words.
    fn run(self: Opened, script: []const u8) ![:0]const u8 {
        const machine = machineOf();
        machine.enter();
        const ended = machine.run(self.doc.ctx, script, "<test>", .global);
        defer qjs.free(self.doc.ctx, ended);
        if (qjs.isException(ended)) {
            std.debug.print("\n  script: {s}\n  threw: {s}\n", .{ script, dom.reportOf(self.doc).error_last });
            machine.tellError(self.doc.ctx);
            return error.Threw;
        }
        return qjs.sliceOf(self.doc.ctx, ended) orelse "";
    }

    /// What the tree reads as: the page's own markup, after the scripts.
    fn markup(self: Opened) []const u8 {
        var out: lexbor.Text = .{ .data = null, .length = 0 };
        const root = lexbor.lxb_dom_document_root(self.tree) orelse return "";
        if (lexbor.lxb_html_serialize_tree_str(root, &out) != 0) return "";
        return if (out.data) |data| data[0..out.length] else "";
    }

    /// The page as the reader reads it from the tree now.
    fn page(self: Opened) !page_mod.Page {
        const base = url.parse(ADDRESS) orelse return error.NoBase;
        var read: page_mod.Page = .{};
        errdefer read.deinit(heap);
        try extract.extract(heap, self.tree, base, &read);
        return read;
    }
};

var clock_us: u64 = 0;

fn clock() u64 {
    return clock_us;
}

fn say(text: []const u8) void {
    std.debug.print("  script says: {s}\n", .{text});
}

fn machineOf() *js.Machine {
    return js.start(&clock, &say) orelse @panic("no machine");
}

/// Parse `text` into a page with its cascade, and open a document over it
/// at the test's address. The page's scripts are run where `load` says.
fn opened(text: []const u8, load: bool) !Opened {
    const tree = lexbor.lxb_html_document_create() orelse return error.NoPage;
    if (lexbor.lxb_style_init(tree) != .ok) return error.NoPage;
    if (lexbor.lxb_html_document_parse(tree, text.ptr, text.len) != .ok) return error.NoPage;
    const doc = dom.open(machineOf(), tree, &rules, ADDRESS, .{
        .gpa = testing.allocator,
        .jar = &jar,
        .store = &store,
        .screen = .{ .width = 640, .height = 480 },
        .user_agent = "vibeee",
    }) orelse return error.NoPage;
    const it = Opened{ .doc = doc, .tree = tree };
    if (load) dom.load(doc, &.{});
    return it;
}

/// Run `script` as the page's own script and then ask `question` of the
/// page: what it says is what came back.
fn says(script: []const u8, question: []const u8, want: []const u8) !void {
    const it = try opened(with(script), true);
    defer it.end();
    const got = try it.run(question);
    defer qjs.freeText(it.doc.ctx, got.ptr);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("\n  said: {s}\n  want: {s}\n", .{ got, want });
        return error.NotWhatWasSaid;
    }
}

/// Run `script` as a page's own script and give back the markup the tree
/// reads as afterwards, which is what a script that changes the page does.
fn reads(script: []const u8, want: []const u8) !void {
    const it = try opened(with(script), true);
    defer it.end();
    const tree = it.markup();
    if (!std.mem.containsAtLeast(u8, tree, 1, want)) {
        std.debug.print("\n  read: {s}\n  want: {s}\n", .{ tree, want });
        return error.NotWhatWasRead;
    }
}

test "an element is found by its id, and is the same element each time" {
    try says("", "document.getElementById('one').textContent", "first");
    try says("", "String(document.getElementById('one') === document.querySelector('#one'))", "true");
}

test "its tag is named as a tag is" {
    try says("", "document.getElementById('one').tagName", "P");
}

test "text is written into it" {
    try says("document.getElementById('one').textContent = 'changed';", "document.getElementById('one').textContent", "changed");
}

test "a class is added, said to be there, and taken away" {
    try says("var e = document.getElementById('one'); e.classList.add('new');", "document.getElementById('one').className", "new");
    try says("var e = document.getElementById('one'); e.classList.add('new');", "String(e.classList.contains('new'))", "true");
    try says("var e = document.getElementById('one'); e.classList.add('a', 'b'); e.classList.remove('a');", "e.className", "b");
    try says("var e = document.getElementById('one'); e.classList.toggle('x');", "String(e.classList.toggle('x'))", "false");
}

test "an attribute is set, read and taken away" {
    try says("document.getElementById('one').setAttribute('data-x', 'y');", "document.getElementById('one').getAttribute('data-x')", "y");
    try says("var e = document.getElementById('one'); e.setAttribute('data-x', 'y'); e.removeAttribute('data-x');", "String(e.hasAttribute('data-x'))", "false");
    try says("var e = document.getElementById('one'); e.setAttribute('data-first-name', 'ada');", "e.dataset.firstName", "ada");
    try says("var e = document.getElementById('one');", "e.id + '/' + e.getAttribute('nothing')", "one/null");
}

test "elements are found by kind, by class, by name and by selector" {
    try says("", "document.getElementsByTagName('p').length", "3");
    try says("", "document.getElementsByClassName('noted').length", "2");
    try says("", "document.querySelectorAll('p').length", "3");
    try says("", "document.querySelector('#two').textContent", "deep");
    try says("", "document.querySelectorAll('.noted').length", "2");
    try says("", "document.getElementById('two').parentElement.querySelectorAll('p').length", "1");
}

test "an element says whether it matches, and finds its nearest ancestor that does" {
    try says("", "String(document.getElementById('one').matches('p'))", "true");
    try says("", "document.getElementById('two').closest('div').tagName", "DIV");
}

test "an element is made and put somewhere, and takes itself away" {
    try reads("var p = document.createElement('p'); p.textContent = 'new'; document.body.appendChild(p);", "<p>new</p>");
    try reads("document.getElementById('one').remove();", "second");
    try reads("var f = document.createDocumentFragment(); f.appendChild(document.createElement('b')); document.body.append(f, 'tail');", "<b></b>tail");
    try reads("document.getElementById('one').replaceWith(document.createComment('gone'));", "<!--gone-->");
}

test "markup is written and read, inside an element and around it" {
    try says("document.getElementById('one').innerHTML = '<b>bold</b>';", "document.getElementById('one').innerHTML", "<b>bold</b>");
    try says("", "document.getElementById('one').outerHTML", "<p id=\"one\">first</p>");
    try reads("document.getElementById('one').outerHTML = '<h1>top</h1>';", "<h1>top</h1>");
    try reads("document.getElementById('one').insertAdjacentHTML('afterend', '<i>after</i>');", "</p><i>after</i>");
}

test "the ways about the tree skip the words between elements where they say" {
    try says("", "document.body.firstElementChild.id", "one");
    try says("", "document.getElementById('one').nextElementSibling.className", "noted");
    try says("", "String(document.body.firstChild.nodeType)", "3");
    try says("", "document.body.children.length", "4");
}

test "the title is read and written" {
    try says("", "document.title", "Hello");
    try reads("document.title = 'Bye';", "<title>Bye</title>");
}

test "a cookie a script writes is read back, and is the reader's to keep" {
    const it = try opened(with("document.cookie = 'a=1';"), true);
    defer it.end();
    const got = try it.run("document.cookie");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("a=1", got);
    try testing.expect(jar.has(url.parse(ADDRESS).?, false));
}

test "what a page puts by is read back, and is the reader's to keep for the site" {
    const it = try opened(with("localStorage.setItem('k', 'v'); localStorage.setItem('gone', 'x'); localStorage.removeItem('gone');"), true);
    defer it.end();
    const got = try it.run("localStorage.getItem('k') + localStorage.length + localStorage.key(0) + localStorage.getItem('gone')");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("v1knull", got);
    const site = store.bucketFor(testing.allocator, "http://example.test") orelse return error.NoSite;
    try testing.expectEqualStrings("v", site.get("k").?);
}

test "the page says where it is, and what the reader is called" {
    try says("", "location.href", ADDRESS);
    try says("", "location.hostname + location.pathname + location.protocol", "example.test/onehttp:");
    try says("", "document.location.href === window.location.href && top.location.href === location.href ? 'same' : 'not'", "same");
    try says("", "navigator.userAgent", "vibeee");
    try says("", "String(innerWidth) + 'x' + innerHeight", "640x480");
    try says("", "String(matchMedia('(max-width: 700px)').matches)", "true");
}

test "what is not here is an empty shape, and is noted" {
    const it = try opened(with("getComputedStyle(document.body).getPropertyValue('color'); document.body.getBoundingClientRect();"), true);
    defer it.end();
    const report = dom.reportOf(it.doc);
    try testing.expectEqual(@as(u32, 2), report.missing_count);
    try testing.expectEqualStrings("getBoundingClientRect", report.missing_last);
}

test "typeof is an operator this engine runs" {
    try says("", "typeof document + typeof nothing", "objectundefined");
}

test "an event is told to its listeners, to the handler on the element, and to the attribute" {
    try says(
        "var got = '';" ++
            "var e = document.getElementById('one');" ++
            "e.addEventListener('click', function () { got += 'listener '; });" ++
            "e.onclick = function () { got += 'property '; };" ++
            "e.setAttribute('onclick', \"got += 'attribute ' + event.type\");" ++
            "document.addEventListener('click', function (ev) { got += ' bubbled to ' + ev.currentTarget.tagName; });" ++
            "e.click();",
        "got",
        "listener property attribute click bubbled to HTML",
    );
}

test "a handler put on the element the script got earlier is still there when the reader clicks" {
    const it = try opened(with("document.getElementById('one').onclick = function (ev) { ev.preventDefault(); window.__clicked = 1; };"), true);
    defer it.end();
    var page = try it.page();
    defer page.deinit(heap);
    // The reader clicks the node the page kept for the paragraph's link-less
    // words: the element itself, which the walk noted.
    const node = lexbor.lxb_dom_document_root(it.tree).?;
    var found: ?*lexbor.Node = null;
    var at = lexbor.following(node, node);
    while (at) |each| : (at = lexbor.following(each, node)) {
        if (lexbor.tagOf(each) == .p) {
            found = each;
            break;
        }
    }
    try testing.expect(dom.click(it.doc, found.?));
    const got = try it.run("String(window.__clicked)");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("1", got);
}

test "a script sends the reader somewhere, and the going is taken once" {
    const cases = [_][]const u8{
        "location.href = 'http://else.test/two';",
        "location.assign('/two');",
        "window.location = 'two';",
        "document.location = 'http://else.test/two';",
    };
    for (cases) |script| {
        const it = try opened(with(script), true);
        defer it.end();
        const going = dom.takeGoing(it.doc) orelse return error.Nowhere;
        try testing.expect(std.mem.endsWith(u8, going.address, "/two"));
        try testing.expect(dom.takeGoing(it.doc) == null);
    }
}

test "a form a script sends goes as its answers, by GET in the address and by POST as a body" {
    const it = try opened(
        "<html><body><form id=f action='/find' method='get'><input name='q' value='eee pc'><input type='checkbox' name='c' checked></form>" ++
            "<form id=g action='/login' method='post'><input name='u' value='ada'></form>" ++
            "<script>document.getElementById('f').submit();</script></body></html>",
        true,
    );
    defer it.end();
    const first = dom.takeGoing(it.doc) orelse return error.Nowhere;
    try testing.expectEqualStrings("http://example.test/find?q=eee+pc&c=on", first.address);
    try testing.expect(first.sent == null);
    const got = try it.run("document.getElementById('g').submit(); 'sent'");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    const second = dom.takeGoing(it.doc) orelse return error.Nowhere;
    try testing.expectEqualStrings("http://example.test/login", second.address);
    try testing.expectEqualStrings("u=ada", second.sent.?);
}

test "what a script left waiting runs when it is due, and says so" {
    clock_us = 0;
    const it = try opened(with("var got = 'none'; setTimeout(function () { got = 'later'; }, 100);"), true);
    defer it.end();
    try testing.expectEqual(@as(?u32, 100), dom.waits(it.doc));
    try testing.expect(!dom.loop(it.doc));
    clock_us = 100 * std.time.us_per_ms;
    try testing.expect(dom.loop(it.doc));
    try testing.expect(dom.waits(it.doc) == null);
    const got = try it.run("got");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("later", got);
}

test "a timer may clear itself while it runs, and a listener change listeners while it is told" {
    clock_us = 0;
    const it = try opened(with("var n = 0; var id = setInterval(function () { n++; clearInterval(id); }, 0);"), true);
    defer it.end();
    clock_us = 100 * std.time.us_per_ms;
    try testing.expect(dom.loop(it.doc));
    try testing.expect(dom.waits(it.doc) == null);
    const got = try it.run("String(n)");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("1", got);

    try says(
        "var e = document.getElementById('one'); var n = 0;" ++
            "function once() { n++; e.removeEventListener('click', once);" ++
            "e.addEventListener('click', function () { n += 10; }); }" ++
            "e.addEventListener('click', once); e.click(); e.click();",
        "String(n)",
        "11",
    );
}

test "a script that runs too long is stopped, and the page goes on" {
    const it = try opened(with("window.__before = 1; for (;;) {} window.__after = 1;"), false);
    defer it.end();
    // The clock runs while the script does: each look at it is a moment on.
    const S = struct {
        fn ticking() u64 {
            clock_us += 300 * std.time.us_per_ms;
            return clock_us;
        }
    };
    const machine = machineOf();
    const was = machine.clock;
    machine.clock = &S.ticking;
    defer machine.clock = was;
    dom.load(it.doc, &.{});
    try testing.expectEqual(@as(u32, 1), dom.reportOf(it.doc).threw);
    try testing.expect(machine.interrupted);
    const got = try it.run("String(window.__before) + String(window.__after)");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("1undefined", got);
}

test "fetch asks the reader, and the answer keeps the promise" {
    const it = try opened(with("var got = ''; fetch('/api?x=1').then(function (r) { return r.json(); }).then(function (v) { got = v.name + r_status; }); var r_status = '';"), true);
    defer it.end();
    try testing.expect(dom.asking(it.doc));
    const ask = dom.nextAsk(it.doc) orelse return error.NotAsked;
    try testing.expectEqualStrings("http://example.test/api?x=1", ask.address);
    try testing.expect(ask.sent == null and !ask.script);
    try testing.expect(dom.nextAsk(it.doc) == null);
    dom.answer(it.doc, ask.id, .{ .status = 200, .body = "{\"name\": \"ada\"}" });
    _ = dom.loop(it.doc);
    const got = try it.run("got");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("ada", got);
}

test "a fetch that posts says what it sends, and a request that fails is told so" {
    const it = try opened(with("fetch('/api', { method: 'POST', body: 'a=1', headers: { 'Content-Type': 'application/json' } });" ++
        "var x = new XMLHttpRequest(); var state = ''; x.open('GET', '/other'); x.onerror = function () { state = 'failed ' + x.status; }; x.send();"), true);
    defer it.end();
    const first = dom.nextAsk(it.doc) orelse return error.NotAsked;
    try testing.expectEqualStrings("a=1", first.sent.?.bytes);
    try testing.expectEqualStrings("application/json", first.sent.?.kind);
    const second = dom.nextAsk(it.doc) orelse return error.NotAsked;
    try testing.expectEqualStrings("http://example.test/other", second.address);
    dom.answer(it.doc, second.id, .{ .failed = true });
    dom.answer(it.doc, first.id, .{ .status = 204 });
    const got = try it.run("state");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("failed 0", got);
}

test "a script put in the page by its address is asked for and run when it comes" {
    const it = try opened(with("var s = document.createElement('script'); s.src = 'lib.js'; s.onload = function () { window.__loaded = window.__lib; }; document.head.appendChild(s);"), true);
    defer it.end();
    const ask = dom.nextAsk(it.doc) orelse return error.NotAsked;
    try testing.expect(ask.script);
    try testing.expectEqualStrings("http://example.test/lib.js", ask.address);
    dom.answer(it.doc, ask.id, .{ .status = 200, .body = "window.__lib = 'here';" });
    const got = try it.run("window.__loaded");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("here", got);
    try testing.expectEqual(@as(u32, 2), dom.reportOf(it.doc).ran);
}

test "a script the page names by address runs from what the reader fetched, in order" {
    const it = try opened("<html><body><script src='/a.js'></script><script>window.__b = window.__a + 'b';</script></body></html>", false);
    defer it.end();
    dom.load(it.doc, &.{.{ .address = "http://example.test/a.js", .text = "window.__a = 'a';" }});
    const got = try it.run("window.__b");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("ab", got);
}

test "document.write puts markup after the script that wrote it" {
    try reads("document.write('<b>written</b>');", "<script>document.write('<b>written</b>');</script><b>written</b>");
}

test "a script the page inserts with its own words runs at once" {
    try says("var s = document.createElement('script'); s.textContent = 'window.__ran = 1;'; document.body.appendChild(s);", "String(window.__ran)", "1");
}

test "a display set by script is used when the page is read again" {
    const it = try opened(with(""), true);
    defer it.end();
    var first = try it.page();
    defer first.deinit(heap);
    try testing.expect(std.mem.containsAtLeast(u8, first.text.items, 1, "first"));
    _ = try it.run("document.getElementById('one').style.display = 'none'; 1");
    try testing.expect(dom.changed(it.doc));
    var again = try it.page();
    defer again.deinit(heap);
    try testing.expect(!std.mem.containsAtLeast(u8, again.text.items, 1, "first"));
    try testing.expect(std.mem.containsAtLeast(u8, again.text.items, 1, "second"));
}

test "a style written as words, or by property, is used when the page is read again" {
    const it = try opened(with("document.getElementById('one').style.cssText = 'visibility: hidden'; document.getElementById('two').style.setProperty('color', '#123456');"), true);
    defer it.end();
    var page = try it.page();
    defer page.deinit(heap);
    try testing.expect(!std.mem.containsAtLeast(u8, page.text.items, 1, "first"));
    try testing.expect(std.mem.findScalar(rgb.Colour, page.palette.items, .hex(0x123456)) != null);
    const got = try it.run("document.getElementById('one').style.visibility + '/' + getComputedStyle(document.getElementById('one')).display");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("hidden/none", got);
}

test "a component may extend a browser element class, and a node is one" {
    try says("class Thing extends HTMLElement {}; customElements.define('a-thing', Thing);", "Thing.name + (document.body instanceof HTMLElement)", "Thingtrue");
}

test "a constructed event is dispatched, and may be stopped" {
    try says(
        "var n = 0; document.addEventListener('ready', function () { n++; }); document.dispatchEvent(new Event('ready'));" ++
            "var e = document.getElementById('one'); e.addEventListener('click', function (ev) { ev.stopPropagation(); n += 10; });" ++
            "document.addEventListener('click', function () { n += 100; }); e.click();",
        "String(n)",
        "11",
    );
}

test "what a stylesheet says of an element follows the classes a script gives and takes" {
    // The page's own style element is the tree's to read; the linked sheet
    // is applied as the reader applies one that came by its address.
    const it = try opened(
        "<!DOCTYPE html><html><head><style>.own { color: #abcdef; }</style></head><body>" ++
            "<p id=\"one\">first</p><p class=\"noted\">second</p><div class=\"noted\"><p id=\"two\">deep</p></div><p id=\"three\">third</p>" ++
            "<script>var one = document.getElementById('one'); one.classList.add('gone');" ++
            "var two = document.getElementById('two'); two.parentNode.classList.remove('noted');" ++
            "var made = document.createElement('p'); made.id = 'late'; document.body.appendChild(made); made.textContent = 'late';" ++
            "document.getElementById('three').className = 'own';" ++
            "var root = document.documentElement; root.className = 'dark';</script></body></html>",
        false,
    );
    defer it.end();
    css.apply(heap, it.tree,
        \\.gone { display: none; }
        \\.noted p { visibility: hidden; }
        \\#late { color: #123456; }
        \\.dark .noted { color: #654321; }
    , null, &rules);
    var before = try it.page();
    defer before.deinit(heap);
    try testing.expect(std.mem.containsAtLeast(u8, before.text.items, 1, "first"));
    try testing.expect(!std.mem.containsAtLeast(u8, before.text.items, 1, "deep"));
    try testing.expect(std.mem.findScalar(rgb.Colour, before.palette.items, .hex(0x654321)) == null);
    try testing.expect(std.mem.findScalar(rgb.Colour, before.palette.items, .hex(0xabcdef)) == null);

    dom.load(it.doc, &.{});
    try testing.expect(dom.changed(it.doc));
    var after = try it.page();
    defer after.deinit(heap);
    // The class a script gave hides the first paragraph, and the one it took
    // from the container shows the deep one; the paragraph it made is
    // matched by its id, the class on the root reaches the noted one, and
    // the page's own style element is read for the class the third got.
    try testing.expect(!std.mem.containsAtLeast(u8, after.text.items, 1, "first"));
    try testing.expect(std.mem.containsAtLeast(u8, after.text.items, 1, "deep"));
    try testing.expect(std.mem.containsAtLeast(u8, after.text.items, 1, "late"));
    try testing.expect(std.mem.findScalar(rgb.Colour, after.palette.items, .hex(0x123456)) != null);
    try testing.expect(std.mem.findScalar(rgb.Colour, after.palette.items, .hex(0x654321)) != null);
    try testing.expect(std.mem.findScalar(rgb.Colour, after.palette.items, .hex(0xabcdef)) != null);
}

test "the boxes a stylesheet sets side by side are kept for the layout" {
    const it = try opened("<!DOCTYPE html><html><body><main><p>one</p><p>two</p></main></body></html>", false);
    defer it.end();
    css.apply(heap, it.tree,
        \\main { display: flex; flex-direction: column; gap: 8px; width: 80vw; min-height: 12vh;
        \\        justify-content: space-between; align-items: center; }
        \\p { flex: none; width: 50%; max-width: 400px; }
    , null, &rules);
    var page = try it.page();
    defer page.deinit(heap);

    try testing.expectEqualStrings("onetwo", page.text.items);
    try testing.expectEqual(@as(usize, 2), page.blocks.items.len);
    try testing.expectEqual(@as(usize, 3), page.containers.items.len);
    const main = page.containers.items[0].style;
    try testing.expectEqual(page_mod.BoxStyle.Display.flex, main.display);
    try testing.expectEqual(page_mod.BoxStyle.Direction.column, main.direction);
    try testing.expectEqualDeep(page_mod.Unit{ .px = 8 }, main.gap);
    try testing.expectEqualDeep(page_mod.Unit{ .vw = 80 }, main.width);
    try testing.expectEqualDeep(page_mod.Unit{ .vh = 12 }, main.min_height);
    try testing.expectEqual(page_mod.BoxStyle.Justify.between, main.justify);
    try testing.expectEqual(page_mod.BoxStyle.Items.center, main.items);
    const p = page.containers.items[1].style;
    try testing.expectEqualDeep(page_mod.Unit{ .percent = 50 }, p.width);
    try testing.expectEqualDeep(page_mod.Unit{ .px = 400 }, p.max_width);
    // Each paragraph is held by the container, and owns the block it made.
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, page.childrenOf(page.containers.items[0]));
    for (page.blocks.items, 1..) |block, index| try testing.expectEqual(@as(u32, @intCast(index)), block.owner);
}
