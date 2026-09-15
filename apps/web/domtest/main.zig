//! The browser's document, tested on this machine.
//!
//! QuickJS and lexbor are built for the host here rather than for the target,
//! so a page can be parsed, a script run in it, and the tree read back, which
//! is the only way to know that what a script sees is what the page is. It is
//! where Zig meets two vendored trees: a value handed to the wrong kind of
//! call, matches gathered in a callback and lost, a title asked for before the
//! parser had settled it, none of which a check of either alone would catch.
//!
//! Each test runs a script in a page and asks what came of it: what it said,
//! what the tree reads as now, or what it asked the browser for.

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

/// What the browser keeps around a page, for the pages here to share.
var jar: cookie.Jar = .{};
var store: storage.Storage = .{};
/// The rules a test's stylesheet gave the page.
var rules: css.Rules = .{};

/// A page, parsed, with a document bound into it and its scripts run.
const Opened = struct {
    doc: *dom.Document,
    tree: *lexbor.Document,

    /// Let the page go, and with it what the browser kept around it, so that
    /// each test starts with nothing and leaks nothing.
    fn end(self: Opened) void {
        dom.close(self.doc);
        lexbor.lxb_style_destroy(self.tree);
        _ = lexbor.lxb_html_document_destroy(self.tree);
        jar.deinit(testing.allocator);
        store.deinit(testing.allocator);
        rules.deinit(heap);
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

    /// The page as the browser reads it from the tree now, with its scripts
    /// running.
    fn page(self: Opened) !page_mod.Page {
        return self.pageWith(true);
    }

    /// The same, said to be read with the page's scripts running or not.
    fn pageWith(self: Opened, scripted: bool) !page_mod.Page {
        const base = url.parse(ADDRESS) orelse return error.NoBase;
        var read: page_mod.Page = .{};
        errdefer read.deinit(heap);
        try extract.extract(heap, self.tree, base, null, scripted, &read);
        return read;
    }
};

var clock_us: u64 = 0;

/// What every reading of the clock adds to it, for a test that needs time
/// to pass while something runs. Nought leaves the clock where a test puts
/// it, which is what the timer tests need.
var clock_step_us: u64 = 0;

fn clock() u64 {
    defer clock_us += clock_step_us;
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
    // The page's own style elements, applied as the browser applies them.
    css.reapply(heap, tree, null, &rules);
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

test "a cookie a script writes is read back, and is the browser's to keep" {
    const it = try opened(with("document.cookie = 'a=1';"), true);
    defer it.end();
    const got = try it.run("document.cookie");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("a=1", got);
    try testing.expect(jar.has(url.parse(ADDRESS).?, false));
}

test "what a page puts by is read back, and is the browser's to keep for the site" {
    const it = try opened(with("localStorage.setItem('k', 'v'); localStorage.setItem('gone', 'x'); localStorage.removeItem('gone');"), true);
    defer it.end();
    const got = try it.run("localStorage.getItem('k') + localStorage.length + localStorage.key(0) + localStorage.getItem('gone')");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("v1knull", got);
    const site = store.bucketFor(testing.allocator, "http://example.test") orelse return error.NoSite;
    try testing.expectEqualStrings("v", site.get("k").?);
}

test "an element's attributes are a list, by index and by name" {
    const it = try opened("<!DOCTYPE html><html><body><p id=\"a\" class=\"x\" data-k=\"v\">a</p></body></html>", true);
    defer it.end();
    try testing.expectEqualStrings("3", try it.run("String(document.getElementById('a').attributes.length)"));
    try testing.expectEqualStrings("class", try it.run("document.getElementById('a').attributes[1].name"));
    try testing.expectEqualStrings("v", try it.run("document.getElementById('a').attributes['data-k'].value"));
    try testing.expectEqualStrings("a", try it.run("document.getElementById('a').attributes.getNamedItem('id').value"));
    try testing.expectEqualStrings("null", try it.run("String(document.getElementById('a').attributes.getNamedItem('nope'))"));
    try testing.expectEqualStrings("true", try it.run("String(document.getElementById('a').attributes.item(0).specified)"));
}

test "the document is a node of its own kind, as a library keeping one tells" {
    const it = try opened(with(""), true);
    defer it.end();
    try testing.expectEqualStrings("9", try it.run("String(document.nodeType)"));
    try testing.expectEqualStrings("#document", try it.run("document.nodeName"));
    try testing.expectEqualStrings("true", try it.run("String(document.ownerDocument === null && document.parentNode === null)"));
    try testing.expectEqualStrings("HTML", try it.run("document.documentElement.nodeName"));
}

test "the page says where it is, and what the browser is called" {
    try says("", "location.href", ADDRESS);
    try says("", "location.hostname + location.pathname + location.protocol", "example.test/onehttp:");
    try says("", "document.location.href === window.location.href && top.location.href === location.href ? 'same' : 'not'", "same");
    try says("", "navigator.userAgent", "vibeee");
    try says("", "String(innerWidth) + 'x' + innerHeight", "640x480");
    try says("", "String(matchMedia('(max-width: 700px)').matches)", "true");
}

/// A page's words, as the shell prints them.
fn wordsOf(page: *const page_mod.Page) []const u8 {
    var text: std.Io.Writer.Allocating = .init(heap);
    page_mod.writeText(page, &text.writer) catch @panic("out of memory");
    return text.written();
}

test "a noscript fallback is the page only where its scripts do not run" {
    const it = try opened(
        "<!DOCTYPE html><html><body><p>real</p><noscript><p>turn scripts on</p></noscript></body></html>",
        false,
    );
    defer it.end();
    var with_scripts = try it.pageWith(true);
    defer with_scripts.deinit(heap);
    try testing.expect(std.mem.indexOf(u8, wordsOf(&with_scripts), "turn scripts on") == null);
    try testing.expect(std.mem.indexOf(u8, wordsOf(&with_scripts), "real") != null);
    var without = try it.pageWith(false);
    defer without.deinit(heap);
    try testing.expect(std.mem.indexOf(u8, wordsOf(&without), "turn scripts on") != null);
}

test "the page can ask which declarations the browser reads" {
    try says("", "String(CSS.supports('display', 'flex'))", "true");
    try says("", "String(CSS.supports('display', 'banana'))", "false");
    try says("", "String(CSS.supports('gallop', '4px'))", "false");
    // A variable stands for whatever the page set it to, and is written into
    // the sheet before the cascade reads it.
    try says("", "String(CSS.supports('color', 'var(--test, red)'))", "true");
    try says("", "String(CSS.supports('--own', 'red'))", "true");
    // What upstream keeps by name and the browser goes on to read.
    try says("", "String(CSS.supports('overflow', 'hidden'))", "true");
    try says("", "String(CSS.supports('gap', '4px'))", "true");
}

test "a support condition joins its sides the way a stylesheet writes them" {
    try says("", "String(CSS.supports('(display: flex)'))", "true");
    try says("", "String(CSS.supports('(display: flex) and (color: red)'))", "true");
    try says("", "String(CSS.supports('(display: flex) and (display: banana)'))", "false");
    try says("", "String(CSS.supports('(display: banana) or (color: red)'))", "true");
    try says("", "String(CSS.supports('not (display: banana)'))", "true");
    try says("", "String(CSS.supports('((display: flex))'))", "true");
    // Mixing the two words without brackets to say which binds first is not
    // a condition, and neither is a question about anything but a
    // declaration.
    try says("", "String(CSS.supports('(display: flex) and (color: red) or (color: blue)'))", "false");
    try says("", "String(CSS.supports('selector(a > b)'))", "false");
    try says("", "String(CSS.supports('display: flex'))", "false");
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

test "a link to a place on the page is a link, and a click the browser tells is refused and read" {
    const it = try opened(
        "<!DOCTYPE html><html><body><p><a href=\"#\" id=\"link\">Click</a>: <span id=\"said\">no</span></p>" ++
            "<p><a href=\"javascript:void(0)\" id=\"other\">Other</a></p><h2 id=\"place\">Place</h2>" ++
            "<script>document.getElementById('link').addEventListener('click', function (ev) {" ++
            "ev.preventDefault(); document.getElementById('said').textContent = 'clicked'; });</script></body></html>",
        true,
    );
    defer it.end();
    var page = try it.page();
    defer page.deinit(heap);
    try testing.expectEqual(@as(usize, 2), page.links.items.len);
    const link = page.links.items[0];
    try testing.expectEqual(page_mod.Link.Goes.here, link.goes);
    try testing.expectEqualStrings("", page.string(link.address));
    try testing.expectEqual(page_mod.Link.Goes.script, page.links.items[1].goes);
    try testing.expectEqualStrings("void(0)", page.string(page.links.items[1].address));
    try testing.expect(page.placeOf("place") != null);

    try testing.expect(dom.click(it.doc, @ptrCast(@alignCast(link.node.?))));
    try testing.expect(dom.changed(it.doc));
    var again = try it.page();
    defer again.deinit(heap);
    try testing.expect(std.mem.containsAtLeast(u8, again.text.items, 1, "clicked"));
}

test "a handler put on the element the script got earlier is still there when the browser clicks" {
    const it = try opened(with("document.getElementById('one').onclick = function (ev) { ev.preventDefault(); window.__clicked = 1; };"), true);
    defer it.end();
    var page = try it.page();
    defer page.deinit(heap);
    // The browser clicks the node the page kept for the paragraph's link-less
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

test "a script sends the browser somewhere, and the going is taken once" {
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

test "fetch asks the browser, and the answer keeps the promise" {
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

test "a list's value is its chosen entry's, a script may choose, and a choice made on it is told" {
    const it = try opened(
        "<!DOCTYPE html><html><body><form action=\"/go\"><select name=\"s\" id=\"s\">" ++
            "<option value=\"a\">Ay</option><option selected>Bee</option><option value=\"c\">Cee</option>" ++
            "</select></form><script>var told = ''; document.getElementById('s').addEventListener('change', function (ev) { told = ev.target.value; });</script></body></html>",
        true,
    );
    defer it.end();
    const got = try it.run("var s = document.getElementById('s'); s.value + s.selectedIndex + s.options.length");
    defer qjs.freeText(it.doc.ctx, got.ptr);
    try testing.expectEqualStrings("Bee13", got);

    const set = try it.run("s.value = 'c'; s.selectedIndex + '' + s.options[2].selected");
    defer qjs.freeText(it.doc.ctx, set.ptr);
    try testing.expectEqualStrings("2true", set);

    // The page's control: the list, its entries, and the one chosen.
    var page = try it.page();
    defer page.deinit(heap);
    try testing.expectEqual(@as(usize, 1), page.controls.items.len);
    const choose = page.controls.items[0].kind.choose;
    try testing.expectEqual(@as(u16, 3), choose.count);
    try testing.expectEqual(@as(u16, 2), choose.chosen);
    try testing.expectEqualStrings("Ay", page.string(page.options.items[choose.first].label));
    try testing.expectEqualStrings("Bee", page.string(page.options.items[choose.first + 1].value));

    // The person reading chooses the first: the list is told, and the form
    // sends what was chosen.
    dom.chose(it.doc, @ptrCast(@alignCast(page.controls.items[0].node.?)), 0);
    const told = try it.run("told + '/' + s.selectedIndex");
    defer qjs.freeText(it.doc.ctx, told.ptr);
    try testing.expectEqualStrings("a/0", told);
    _ = try it.run("document.forms[0].submit(); 1");
    const going = dom.takeGoing(it.doc) orelse return error.Nowhere;
    try testing.expectEqualStrings("http://example.test/go?s=a", going.address);
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

test "a script the page names by address runs from what the browser fetched, in order" {
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
    // is applied as the browser applies one that came by its address.
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

test "a rule's pseudo-class functions are read for the names inside them, and an nth is left as an an+b" {
    const it = try opened(
        "<!DOCTYPE html><html><head><style>p:nth-child(2n+1) { color: #111111; }</style></head><body>" ++
            "<p id=\"one\">first</p><p class=\"noted\">second</p><p class=\"noted\" id=\"two\">third</p>" ++
            "<script>document.getElementById('two').classList.add('picked');" ++
            "document.getElementById('one').classList.add('gone');</script></body></html>",
        false,
    );
    defer it.end();
    // The an+b of an nth is not a list; the list its `of` names is one,
    // and so are the lists inside `:is()`, `:not()` and `:where()`.
    css.apply(heap, it.tree,
        \\p:nth-child(1 of .picked) { color: #222222; }
        \\p:not(.gone):nth-last-of-type(1) { color: #333333; }
        \\:is(#none, .gone) { visibility: hidden; }
        \\:where(.noted):lang(en) { color: #444444; }
    , null, &rules);
    var before = try it.page();
    defer before.deinit(heap);
    try testing.expect(std.mem.findScalar(rgb.Colour, before.palette.items, .hex(0x111111)) != null);
    try testing.expect(std.mem.findScalar(rgb.Colour, before.palette.items, .hex(0x222222)) == null);
    try testing.expect(std.mem.findScalar(rgb.Colour, before.palette.items, .hex(0x333333)) != null);
    try testing.expect(std.mem.containsAtLeast(u8, before.text.items, 1, "first"));

    dom.load(it.doc, &.{});
    try testing.expect(dom.changed(it.doc));
    var after = try it.page();
    defer after.deinit(heap);
    // The class the script gave the third paragraph is read through the
    // nth's `of`, and the one it gave the first through `:is()`.
    try testing.expect(std.mem.findScalar(rgb.Colour, after.palette.items, .hex(0x222222)) != null);
    try testing.expect(!std.mem.containsAtLeast(u8, after.text.items, 1, "first"));
}

test "a stylesheet's flex and grid words are read: the shorthand, wrapping, the columns a grid names and the columns a cell spans" {
    const it = try opened(
        "<!DOCTYPE html><html><body><div id=\"row\"><p id=\"a\">a</p><p id=\"b\">b</p></div>" ++
            "<div id=\"grid\"><p id=\"c\">c</p></div><div id=\"fit\"><p>d</p></div><div id=\"most\"><p>e</p></div></body></html>",
        false,
    );
    defer it.end();
    css.apply(heap, it.tree,
        \\#row { display: flex; flex-flow: row wrap; gap: 1rem; align-items: center; }
        \\#a { flex: 1; align-self: flex-end; }
        \\#b { flex: 0 0 120px; }
        \\#grid { display: grid; grid-template-columns: 160px repeat(2, 1fr) minmax(100px, 2fr); grid-gap: 8px; }
        \\#c { grid-column: 1 / -1; }
        \\#fit { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); }
        \\#most { display: grid; grid-template-columns: minmax(0, max-content) minmax(100px, 300px) fit-content(200px); }
    , null, &rules);
    var page = try it.page();
    defer page.deinit(heap);
    const boxes = page.containers.items;
    var at: usize = 0;
    while (at < boxes.len and boxes[at].style.display != .flex) at += 1;
    try testing.expect(at + 5 < boxes.len);
    const row = boxes[at].style;
    try testing.expect(row.wrap);
    try testing.expectEqual(page_mod.Unit{ .rem = 1 }, row.gap);
    try testing.expectEqual(page_mod.BoxStyle.Items.center, row.items);
    const a = boxes[at + 1].style;
    try testing.expectEqual(@as(f32, 1), a.grow);
    try testing.expectEqual(@as(f32, 1), a.shrink);
    try testing.expectEqual(page_mod.Unit{ .px = 0 }, a.basis);
    try testing.expectEqual(@as(?page_mod.BoxStyle.Items, .end), a.self_align);
    const b = boxes[at + 2].style;
    try testing.expectEqual(@as(f32, 0), b.grow);
    try testing.expectEqual(@as(f32, 0), b.shrink);
    try testing.expectEqual(page_mod.Unit{ .px = 120 }, b.basis);
    const grid = boxes[at + 3].style;
    try testing.expectEqual(page_mod.BoxStyle.Display.grid, grid.display);
    try testing.expectEqual(page_mod.Unit{ .px = 8 }, grid.gap);
    const named = grid.columns.named.slice();
    try testing.expectEqual(@as(usize, 4), named.len);
    try testing.expectEqual(page_mod.Track{ .length = .{ .px = 160 } }, named[0]);
    try testing.expectEqual(page_mod.Track{ .share = 1 }, named[1]);
    try testing.expectEqual(page_mod.Track{ .share = 1 }, named[2]);
    try testing.expectEqual(page_mod.Track{ .share = 2 }, named[3]);
    try testing.expectEqual(@as(u8, 255), boxes[at + 4].style.span);
    try testing.expectEqual(page_mod.Unit{ .px = 150 }, boxes[at + 5].style.columns.fit);
    // A minmax is its most: a share where that is left to the words, and
    // a length where it is one.
    const most = boxes[at + 7].style.columns.named.slice();
    try testing.expectEqual(@as(usize, 3), most.len);
    try testing.expectEqual(page_mod.Track{ .share = 1 }, most[0]);
    try testing.expectEqual(page_mod.Track{ .length = .{ .px = 300 } }, most[1]);
    try testing.expectEqual(page_mod.Track{ .share = 1 }, most[2]);
}

test "a sheet's variables stand for what its root sets, or the fallback, and a positioned box is out of the flow" {
    const it = try opened("<!DOCTYPE html><html><body><p id=\"a\">a</p><p id=\"b\">b</p></body></html>", false);
    defer it.end();
    css.apply(heap, it.tree,
        \\:root { --gap: 12px; --ink: #123456; --room: var(--gap); }
        \\html { --gap: 20px; }
        \\@supports (display: grid) { :root { --wide: 300px; } }
        \\#a { display: flex; gap: var(--gap); color: var(--ink); padding: var(--room); margin: var(--nowhere, 4px); width: var(--wide); }
        \\#b { position: absolute; }
    , null, &rules);
    var page = try it.page();
    defer page.deinit(heap);
    const boxes = page.containers.items;
    var at: usize = 0;
    while (at < boxes.len and boxes[at].style.display != .flex) at += 1;
    try testing.expect(at + 1 < boxes.len);
    const a = boxes[at].style;
    // The later setting of the gap, on html, is the one read.
    try testing.expectEqual(page_mod.Unit{ .px = 20 }, a.gap);
    try testing.expectEqual(page_mod.Unit{ .px = 20 }, a.padding.left);
    try testing.expectEqual(page_mod.Unit{ .px = 4 }, a.margin.top);
    try testing.expectEqual(page_mod.Unit{ .px = 300 }, a.width);
    try testing.expect(std.mem.findScalar(rgb.Colour, page.palette.items, .hex(0x123456)) != null);
    try testing.expect(!a.lifted());
    try testing.expect(boxes[at + 1].style.lifted());
}

test "a page that sets its own text size is measured in it" {
    const it = try opened("<!DOCTYPE html><html><body><p id=\"a\">a</p></body></html>", false);
    defer it.end();
    css.apply(heap, it.tree,
        \\html { font-size: 62.5%; }
        \\#a { width: 10rem; height: 2em; }
    , null, &rules);
    var page = try it.page();
    defer page.deinit(heap);
    // Ten pixels a rem, as the page asked; an em is still the size the
    // browser's own text starts at.
    try testing.expectEqual(@as(?f32, 10), page.root_text);
    var at: usize = 0;
    const boxes = page.containers.items;
    while (at < boxes.len and boxes[at].style.width != .rem) at += 1;
    try testing.expect(at < boxes.len);
    try testing.expectEqual(page_mod.Unit{ .rem = 10 }, boxes[at].style.width);
    try testing.expectEqual(page_mod.Unit{ .em = 2 }, boxes[at].style.height);
}

test "a box that cuts off what spills past it says so, whichever way overflow is written" {
    const it = try opened("<!DOCTYPE html><html><body><p id=\"a\">a</p><p id=\"b\">b</p><p id=\"c\">c</p></body></html>", false);
    defer it.end();
    css.apply(heap, it.tree,
        \\#a { overflow: hidden; height: 20px; }
        \\#b { overflow-y: auto; height: 20px; }
        \\#c { overflow: visible; height: 20px; }
    , null, &rules);
    var page = try it.page();
    defer page.deinit(heap);
    const boxes = page.containers.items;
    var at: usize = 0;
    while (at < boxes.len and boxes[at].style.height == .auto) at += 1;
    try testing.expect(at + 2 < boxes.len);
    try testing.expect(boxes[at].style.clips);
    try testing.expect(boxes[at + 1].style.clips);
    try testing.expect(!boxes[at + 2].style.clips);
}

test "which side a box floats to is read, the start of a line being the left" {
    const it = try opened("<!DOCTYPE html><html><body><p id=\"a\">a</p><p id=\"b\">b</p><p id=\"c\">c</p></body></html>", false);
    defer it.end();
    css.apply(heap, it.tree,
        \\#a { float: left; }
        \\#b { float: inline-end; }
        \\#c { float: none; }
    , null, &rules);
    var page = try it.page();
    defer page.deinit(heap);
    const boxes = page.containers.items;
    var at: usize = 0;
    while (at < boxes.len and boxes[at].style.float == .none) at += 1;
    try testing.expect(at + 2 < boxes.len);
    try testing.expectEqual(page_mod.BoxStyle.Float.left, boxes[at].style.float);
    try testing.expectEqual(page_mod.BoxStyle.Float.right, boxes[at + 1].style.float);
    try testing.expectEqual(page_mod.BoxStyle.Float.none, boxes[at + 2].style.float);
}

test "a picture is fetched from the source its page gives for a window this wide, and a stand-in is passed over" {
    const it = try opened(
        "<!DOCTYPE html><html><body>" ++
            "<img id=\"a\" src=\"data:image/gif;base64,R0lGOD\" srcset=\"a-480.jpg 480w, a-1200.jpg 1200w, a-800.jpg 800w\" width=\"200\" height=\"100\">" ++
            "<img id=\"b\" data-src=\"lazy.jpg\" width=\"200\" height=\"100\">" ++
            "<picture><source srcset=\"p.webp 1x, p2.webp 2x\"><img id=\"c\" alt=\"c\" width=\"200\" height=\"100\"></picture>" ++
            "<img id=\"d\" src=\"plain.jpg\" srcset=\"big.jpg 2000w\" width=\"200\" height=\"100\">" ++
            "</body></html>",
        false,
    );
    defer it.end();
    var page = try it.page();
    defer page.deinit(heap);
    try testing.expectEqual(@as(usize, 4), page.pictures.items.len);
    try testing.expectEqualStrings("http://example.test/a-800.jpg", page.string(page.pictures.items[0].source));
    try testing.expectEqualStrings("http://example.test/lazy.jpg", page.string(page.pictures.items[1].source));
    try testing.expectEqualStrings("http://example.test/p.webp", page.string(page.pictures.items[2].source));
    try testing.expectEqualStrings("http://example.test/plain.jpg", page.string(page.pictures.items[3].source));
}

test "words a page hides from sight but not from a screen reader are not drawn, and the other way round they are" {
    const it = try opened(
        "<!DOCTYPE html><html><body><a class=\"skip\">Skip to content</a><span class=\"cut\">Cut away</span>" ++
            "<span class=\"small\">Small</span><span class=\"spilling\">Spilling</span><p>Shown</p>" ++
            "<span aria-hidden=\"true\">Seen</span><span hidden>Gone</span></body></html>",
        false,
    );
    defer it.end();
    css.apply(heap, it.tree,
        \\.skip { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
        \\.cut { clip-path: inset(50%); }
        \\.small { position: absolute; width: 1px; height: 1px; overflow: hidden; }
        \\.spilling { position: absolute; width: 1px; height: 1px; }
    , null, &rules);
    var page = try it.page();
    defer page.deinit(heap);
    try testing.expect(!std.mem.containsAtLeast(u8, page.text.items, 1, "Skip"));
    try testing.expect(!std.mem.containsAtLeast(u8, page.text.items, 1, "Cut"));
    try testing.expect(!std.mem.containsAtLeast(u8, page.text.items, 1, "Small"));
    try testing.expect(std.mem.containsAtLeast(u8, page.text.items, 1, "Spilling"));
    try testing.expect(std.mem.containsAtLeast(u8, page.text.items, 1, "Shown"));
    try testing.expect(std.mem.containsAtLeast(u8, page.text.items, 1, "Seen"));
    try testing.expect(!std.mem.containsAtLeast(u8, page.text.items, 1, "Gone"));
}

test "a template's content is cloned into the page, and stays out of it on its own" {
    const it = try opened(
        "<!DOCTYPE html><html><body><template id=\"t\"><p class=\"made\">From the template</p></template>" ++
            "<div id=\"into\"></div><script>var t = document.getElementById('t');" ++
            "var copy = t.content.cloneNode(true); document.getElementById('into').appendChild(copy);" ++
            "window.found = t.content.querySelector('.made') !== null;</script></body></html>",
        true,
    );
    defer it.end();
    try testing.expectEqualStrings("true", try it.run("String(window.found)"));
    try testing.expectEqualStrings("1", try it.run("String(document.querySelectorAll('#into .made').length)"));
    var page = try it.page();
    defer page.deinit(heap);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, page.text.items, "From the template"));
}

test "a picture is as large as the stylesheet says, in pixels or ems, under the most it says" {
    const it = try opened(
        "<!DOCTYPE html><html><body>" ++
            "<img id=\"a\" src=\"a.png\" width=\"400\" height=\"300\">" ++
            "<img id=\"b\" src=\"b.png\">" ++
            "<img id=\"c\" src=\"c.png\" width=\"400\" height=\"300\">" ++
            "<img id=\"d\" src=\"d.png\" width=\"400\" height=\"300\"></body></html>",
        false,
    );
    defer it.end();
    css.apply(heap, it.tree,
        \\#a { width: 48px; height: 2em; }
        \\#b { width: 100px; }
        \\#c { max-width: 200px; }
        \\#d { width: 50%; }
    , null, &rules);
    var page = try it.page();
    defer page.deinit(heap);
    const pictures = page.pictures.items;
    try testing.expectEqual(@as(usize, 4), pictures.len);
    try testing.expectEqual(@as(?u16, 48), pictures[0].width);
    try testing.expectEqual(@as(?u16, 32), pictures[0].height);
    try testing.expectEqual(@as(?u16, 100), pictures[1].width);
    try testing.expectEqual(@as(?u16, null), pictures[1].height);
    try testing.expectEqual(@as(?u16, 200), pictures[2].width);
    try testing.expectEqual(@as(?u16, 300), pictures[2].height);
    // A share is left to the layout, and the attributes stand.
    try testing.expectEqual(@as(?u16, 400), pictures[3].width);
}

test "Headers is a class with its methods on its prototype, keeping names whatever their case" {
    const it = try opened(with(""), true);
    defer it.end();
    try testing.expectEqualStrings("function", try it.run("typeof Headers.prototype.has"));
    try testing.expectEqualStrings("x", try it.run("new Headers({'Content-Type': 'x'}).get('content-type')"));
    try testing.expectEqualStrings("true", try it.run("String(new Headers([['A', '1']]).has('a'))"));
    try testing.expectEqualStrings("1, 2", try it.run("var h = new Headers(); h.append('a', '1'); h.append('a', '2'); h.get('A')"));
    try testing.expectEqualStrings("null", try it.run("var g = new Headers({a: '1'}); g.delete('a'); String(g.get('a'))"));
    try testing.expectEqualStrings("a=1;b=2;", try it.run("var s = ''; new Headers({a: '1', B: '2'}).forEach(function (v, k) { s += k + '=' + v + ';' }); s"));
    try testing.expectEqualStrings("a,b", try it.run("new Headers({a: '1', b: '2'}).keys().join(',')"));
    try testing.expectEqualStrings("2", try it.run("String(new Headers(new Headers({a: '1', b: '2'})).entries().length)"));
}

test "Intl writes numbers, dates, lists and relative times as English does, and reads back what it was asked" {
    const it = try opened(with(""), true);
    defer it.end();
    try testing.expectEqualStrings("1,234,567.891", try it.run("new Intl.NumberFormat().format(1234567.891)"));
    try testing.expectEqualStrings("$1,234.50", try it.run("new Intl.NumberFormat('en-US', {style: 'currency', currency: 'USD'}).format(1234.5)"));
    try testing.expectEqualStrings("12%", try it.run("new Intl.NumberFormat('en', {style: 'percent'}).format(0.12)"));
    try testing.expectEqualStrings("1.2K", try it.run("new Intl.NumberFormat('en', {notation: 'compact'}).format(1234)"));
    try testing.expectEqualStrings("1.01", try it.run("new Intl.NumberFormat('en', {maximumFractionDigits: 2}).format(1.005)"));
    try testing.expectEqualStrings("1,2", try it.run("[1, 2].map(new Intl.NumberFormat().format).join(',')"));
    try testing.expectEqualStrings("integer:1 group:, integer:234 decimal:. fraction:5", try it.run("new Intl.NumberFormat().formatToParts(1234.5).map(function (p) { return p.type + ':' + p.value }).join(' ')"));
    try testing.expectEqualStrings("1,234.5", try it.run("(1234.5).toLocaleString()"));
    try testing.expectEqualStrings("3", try it.run("String(new Intl.NumberFormat('de-DE').resolvedOptions().maximumFractionDigits)"));
    try testing.expectEqualStrings("de-DE", try it.run("new Intl.NumberFormat('de-DE').resolvedOptions().locale"));

    try testing.expectEqualStrings("9/14/2026", try it.run("new Intl.DateTimeFormat('en-US').format(new Date(Date.UTC(2026, 8, 14, 15, 4, 5)))"));
    try testing.expectEqualStrings("Monday, September 14, 2026 at 3:04 PM", try it.run("new Intl.DateTimeFormat('en-US', {dateStyle: 'full', timeStyle: 'short'}).format(Date.UTC(2026, 8, 14, 15, 4, 5))"));
    try testing.expectEqualStrings("Sep 14, 2026, 3:04:05 PM", try it.run("new Date(Date.UTC(2026, 8, 14, 15, 4, 5)).toLocaleString('en-US', {dateStyle: 'medium', timeStyle: 'medium'})"));
    try testing.expectEqualStrings("9/14/2026, 3:04:05 PM", try it.run("new Date(Date.UTC(2026, 8, 14, 15, 4, 5)).toLocaleString()"));
    try testing.expectEqualStrings("15:04", try it.run("new Date(Date.UTC(2026, 8, 14, 15, 4, 5)).toLocaleTimeString('en-US', {hour: '2-digit', minute: '2-digit', hour12: false})"));
    try testing.expectEqualStrings("September 14", try it.run("new Date(Date.UTC(2026, 8, 14)).toLocaleDateString('en-US', {month: 'long', day: 'numeric'})"));
    try testing.expectEqualStrings("UTC", try it.run("Intl.DateTimeFormat().resolvedOptions().timeZone"));
    try testing.expectEqualStrings("month:September literal:  day:14", try it.run("new Intl.DateTimeFormat('en', {month: 'long', day: 'numeric'}).formatToParts(Date.UTC(2026, 8, 14)).map(function (p) { return p.type + ':' + p.value }).join(' ')"));
    try testing.expectEqualStrings("Invalid time value", try it.run("try { new Intl.DateTimeFormat().format(NaN) } catch (e) { e.message }"));
    try testing.expectEqualStrings("string", try it.run("typeof new Intl.DateTimeFormat().format()"));

    try testing.expectEqualStrings("one other few", try it.run("var pr = new Intl.PluralRules('en'); var po = new Intl.PluralRules('en', {type: 'ordinal'}); [pr.select(1), pr.select(2), po.select(3)].join(' ')"));
    try testing.expectEqualStrings("a, b, and c", try it.run("new Intl.ListFormat('en').format(['a', 'b', 'c'])"));
    try testing.expectEqualStrings("a or b", try it.run("new Intl.ListFormat('en', {type: 'disjunction'}).format(['a', 'b'])"));
    try testing.expectEqualStrings("yesterday|in 3 days|2 hours ago", try it.run("var rf = new Intl.RelativeTimeFormat('en', {numeric: 'auto'}); [rf.format(-1, 'day'), rf.format(3, 'days'), rf.format(-2, 'hour')].join('|')"));
    try testing.expectEqualStrings("a,B,c", try it.run("['c', 'B', 'a'].sort(new Intl.Collator('en').compare).join(',')"));
    try testing.expectEqualStrings("en Latn US en-Latn-US", try it.run("var l = new Intl.Locale('EN-latn-us').maximize(); [l.language, l.script, l.region, l.toString()].join(' ')"));
    try testing.expectEqualStrings("undefined", try it.run("String(new Intl.Locale('en').script)"));
    try testing.expectEqualStrings("en-US,nl-BE", try it.run("Intl.DateTimeFormat.supportedLocalesOf(['en-US', 'nl_be']).join(',')"));
    try testing.expectEqualStrings("true", try it.run("String(new Intl.NumberFormat() instanceof Intl.NumberFormat && Intl.NumberFormat.prototype.constructor === Intl.NumberFormat)"));
    try testing.expectEqualStrings("0", try it.run("String(Object.keys(new Intl.NumberFormat()).length)"));
}

test "a rule is tried against an element that could carry it, whatever its selector reaches for" {
    const it = try opened(
        "<!DOCTYPE html><html><body><div id=\"box\" class=\"card wide\"><p class=\"words\">one</p>" ++
            "<span data-note=\"yes\">two</span></div><section><p>three</p></section></body></html>",
        false,
    );
    defer it.end();
    css.apply(heap, it.tree,
        \\#box { color: #111111; }
        \\.card .words { color: #222222; }
        \\section p { color: #333333; }
        \\span[data-note] { color: #444444; }
        \\* { background: #f0f0f0; }
        \\.wide > span { color: #555555; }
        \\.nothing-here { color: #666666; }
    , null, &rules);
    // Everything the rules say is found: the id, the class through a
    // descendant, the tag through one, the attribute, and the catch-all.
    _ = try it.run("document.getElementById('box').appendChild(document.createElement('b'))");
    try testing.expect(dom.changed(it.doc));
    var page = try it.page();
    defer page.deinit(heap);
    var painted: usize = 0;
    for (page.runs.items) |run| {
        switch (run) {
            .text => |text| if (text.look.paint != .none) {
                painted += 1;
            },
            else => {},
        }
    }
    try testing.expect(painted >= 3);
    // Each rule found its element: the colours they declare are the page's.
    for ([_]rgb.Colour{
        .{ .r = 0x22, .g = 0x22, .b = 0x22 }, // .card .words, through a class
        .{ .r = 0x33, .g = 0x33, .b = 0x33 }, // section p, through a tag
        .{ .r = 0x55, .g = 0x55, .b = 0x55 }, // .wide > span, the nearer of two
    }) |want| {
        var found = false;
        for (page.palette.items) |kept| {
            if (kept.eql(want)) found = true;
        }
        try testing.expect(found);
    }
}

test "what a script puts in the page is matched again where it went, not over the whole page" {
    const it = try opened(
        "<!DOCTYPE html><html><body><div id=\"one\"><p>a</p></div><div id=\"two\"><p>b</p></div>" ++
            "<div id=\"three\"><p>c</p></div></body></html>",
        false,
    );
    defer it.end();
    css.apply(heap, it.tree, ".lit { color: #f00; }", null, &rules);

    // Three scattered places to match again, not the page.
    _ = try it.run("['one', 'two', 'three'].forEach(function (id) { var e = document.createElement('span'); e.className = 'lit'; document.getElementById(id).appendChild(e) })");
    try testing.expectEqual(@as(usize, 3), it.doc.restyle.len);
    try testing.expect(dom.changed(it.doc));
    try testing.expectEqual(@as(usize, 0), it.doc.restyle.len);
    // The rules found what went in: what the browser reads of the page
    // gives those words the colour the sheet says.
    _ = try it.run("['one', 'two', 'three'].forEach(function (id) { document.querySelector('#' + id + ' span').textContent = 'lit' })");
    try testing.expect(dom.changed(it.doc));
    var page = try it.page();
    defer page.deinit(heap);
    var lit: usize = 0;
    for (page.runs.items) |run| {
        switch (run) {
            .text => |text| if (text.look.paint != .none) {
                lit += 1;
            },
            else => {},
        }
    }
    try testing.expect(lit >= 3);

    // Something put inside a place already noted adds nothing to match.
    _ = try it.run("document.querySelector('#one span').appendChild(document.createElement('b'))");
    try testing.expectEqual(@as(usize, 1), it.doc.restyle.len);
    _ = try it.run("document.querySelector('#one span b').appendChild(document.createElement('i'))");
    try testing.expectEqual(@as(usize, 1), it.doc.restyle.len);
    // A place holding one already noted takes its place, rather than both
    // being matched.
    _ = try it.run("var held = document.createElement('div'); var inner = document.createElement('u'); held.appendChild(inner); document.body.appendChild(held)");
    try testing.expectEqual(@as(usize, 2), it.doc.restyle.len);
    try testing.expect(dom.changed(it.doc));

    // Past what may be kept apart, the page itself is matched again.
    _ = try it.run("for (var i = 0; i < 40; i++) { var e = document.createElement('span'); document.body.insertBefore(e, document.body.firstChild) }");
    try testing.expectEqual(@as(usize, 1), it.doc.restyle.len);
    try testing.expect(dom.changed(it.doc));
}

test "how long a page's scripts held the browser is counted, and the longest stretch named" {
    clock_us = 0;
    clock_step_us = 0;
    const it = try opened(with("var seen = 0;"), true);
    defer it.end();
    try testing.expectEqual(@as(u64, 0), dom.reportOf(it.doc).ran_us);

    // A timer whose run takes a while is the longest stretch, and is named.
    _ = try it.run("setTimeout(function () { seen = 1 }, 0)");
    clock_step_us = std.time.us_per_s;
    defer clock_step_us = 0;
    try testing.expect(dom.loop(it.doc));
    const report = dom.reportOf(it.doc);
    try testing.expectEqualStrings("a timer", report.longest_what);
    try testing.expect(report.longest_us >= std.time.us_per_s);
    try testing.expect(report.ran_us >= report.longest_us);
    try testing.expectEqualStrings("1", try it.run("String(seen)"));
}

test "a frame holds an empty document of its own, which a script may measure in" {
    const it = try opened(with(""), true);
    defer it.end();
    try testing.expectEqualStrings("9 BODY", try it.run("var f = document.createElement('iframe'); document.body.appendChild(f); [f.contentDocument.nodeType, f.contentDocument.body.nodeName].join(' ')"));
    try testing.expectEqualStrings("true", try it.run("String(f.contentWindow.document === f.contentDocument)"));
    // The same document each time it is asked for, and a script may put
    // something in it and read it back.
    try testing.expectEqualStrings("true", try it.run("String(f.contentDocument === f.contentDocument)"));
    try testing.expectEqualStrings("DIV block", try it.run("var d = f.contentDocument.createElement('div'); f.contentDocument.body.appendChild(d); d.style.display = 'block'; [f.contentDocument.body.firstChild.nodeName, f.contentWindow.getComputedStyle(d).display].join(' ')"));
    // What a script library does to find out an element's default display:
    // it writes a page into the frame and measures in it.
    try testing.expectEqualStrings("B here", try it.run("var w = f.contentWindow.document; w.write('<b>here</b>'); w.close(); [w.body.lastChild.nodeName, w.body.lastChild.textContent].join(' ')"));
    try testing.expectEqualStrings("null null", try it.run("var p = document.createElement('p'); [String(p.contentDocument), String(p.contentWindow)].join(' ')"));
    // A document a script makes to work in, which is what a stylesheet
    // rewriter does to resolve the addresses a sheet names.
    try testing.expectEqualStrings("9 HEAD BODY 1", try it.run("var m = document.implementation.createHTMLDocument('Away'); var b = m.createElement('base'); m.head.appendChild(b); [m.nodeType, m.head.nodeName, m.body.nodeName, m.head.childNodes.length - 1].join(' ')"));
    try testing.expectEqualStrings("Away", try it.run("m.querySelector('title').textContent"));
    // A style set on an element in one is that document's to keep.
    try testing.expectEqualStrings("red", try it.run("var e = m.createElement('p'); m.body.appendChild(e); e.style.color = 'red'; e.style.color"));
}

test "a page is loading while its scripts run, and complete once it is told it is loaded" {
    var read: dom.Scripts = .{};
    defer read.deinit(heap);
    const it = try opened(
        "<!DOCTYPE html><html><head><script>var seen = [document.readyState];" ++
            "document.addEventListener('DOMContentLoaded', function () { seen.push('dom:' + document.readyState) });" ++
            "window.addEventListener('load', function () { seen.push('load:' + document.readyState) });</script>" ++
            "<script src=\"https://example.org/late.js\"></script></head><body></body></html>",
        false,
    );
    defer it.end();
    // The first script has run and the second is still to come.
    try testing.expectEqualStrings("loading", try it.run("document.readyState"));
    try testing.expectEqual(dom.Loading.waiting, dom.loadNext(it.doc, &.{}));
    try testing.expectEqualStrings("loading", try it.run("document.readyState"));

    const fetched = [_]dom.Fetched{.{ .address = "https://example.org/late.js", .text = "seen.push('late:' + document.readyState);" }};
    try testing.expectEqual(dom.Loading.done, dom.loadNext(it.doc, &fetched));
    try testing.expectEqualStrings("loading,late:loading,dom:interactive,load:complete", try it.run("seen.join(',')"));
    try testing.expectEqualStrings("complete", try it.run("document.readyState"));
}

test "a posted message reaches the window on a later loop, and a channel's ports each other" {
    clock_us = 0;
    const it = try opened(with(
        \\var got = []; window.addEventListener('message', function (e) { got.push('w:' + e.data + ':' + (e.source === window)); });
        \\window.onmessage = function (e) { got.push('on:' + e.data); };
        \\var ch = new MessageChannel(); ch.port1.onmessage = function (e) { got.push('p1:' + e.data); };
        \\ch.port2.addEventListener('message', function (e) { got.push('p2:' + e.data); }); ch.port2.start();
        \\window.postMessage('hello', '*'); ch.port2.postMessage(1); ch.port1.postMessage({ n: 2 });
    ), true);
    defer it.end();
    try testing.expectEqual(@as(?u32, 0), dom.waits(it.doc));
    try testing.expectEqualStrings("", try it.run("got.join(' ')"));
    try testing.expect(dom.loop(it.doc));
    try testing.expectEqualStrings("w:hello:true on:hello p1:1 p2:[object Object]", try it.run("got.join(' ')"));
    try testing.expect(dom.waits(it.doc) == null);
    // A message posted while one is delivered follows it, in the same loop.
    try testing.expectEqualStrings("undefined", try it.run("got = []; window.addEventListener('message', function (e) { if (e.data === 'a') window.postMessage('b', '*'); }); window.postMessage('a', '*'); String(undefined)"));
    try testing.expect(dom.loop(it.doc));
    try testing.expectEqualStrings("w:a:true on:a w:b:true on:b", try it.run("got.join(' ')"));
}

test "a page script tells its element it has loaded, or that it could not be fetched" {
    var read: dom.Scripts = .{};
    defer read.deinit(heap);
    const it = try opened(
        "<!DOCTYPE html><html><head><script>var seen = [];</script>" ++
            "<script src=\"https://example.org/a.js\" onload=\"seen.push('loaded ' + this.getAttribute('src'))\" onerror=\"seen.push('failed')\"></script>" ++
            "<script src=\"https://example.org/gone.js\" onload=\"seen.push('loaded gone')\" onerror=\"seen.push('failed gone')\"></script>" ++
            "</head><body></body></html>",
        false,
    );
    defer it.end();
    const fetched = [_]dom.Fetched{
        .{ .address = "https://example.org/a.js", .text = "seen.push('ran');" },
        .{ .address = "https://example.org/gone.js", .text = "" },
    };
    try testing.expectEqual(dom.Loading.done, dom.loadNext(it.doc, &fetched));
    try testing.expectEqualStrings("ran|loaded https://example.org/a.js|failed gone", try it.run("seen.join('|')"));
}

test "performance answers its entry queries with lists, and DOMParser gives a document of its own" {
    const it = try opened(with(""), true);
    defer it.end();
    try testing.expectEqualStrings("0 0 true", try it.run("[performance.getEntriesByType('navigation').length, performance.getEntriesByName('x').length, Array.isArray(performance.getEntries())].join(' ')"));
    try testing.expectEqualStrings("Tom & Jerry <3", try it.run("new DOMParser().parseFromString('Tom &amp; Jerry &lt;3', 'text/html').documentElement.textContent"));
    try testing.expectEqualStrings("9 #document 1 HTML BODY HEAD", try it.run("var d = new DOMParser().parseFromString('<p id=\"a\">one</p><p>two</p>', 'text/html'); [d.nodeType, d.nodeName, d.documentElement.nodeType, d.documentElement.nodeName, d.body.nodeName, d.head.nodeName].join(' ')"));
    try testing.expectEqualStrings("2 one two", try it.run("var ps = d.body.querySelectorAll('p'); [ps.length, ps[0].textContent, d.getElementById('a').nextSibling.textContent].join(' ')"));
    try testing.expectEqualStrings("undefined", try it.run("String(d.body.body)"));
    // The page's own tree is untouched by it.
    try testing.expectEqualStrings("true", try it.run("var before = document.querySelectorAll('p').length; new DOMParser().parseFromString('<p>x</p><p>y</p>', 'text/html'); String(document.querySelectorAll('p').length === before)"));
    // Past the most kept, the oldest is let go, and what was kept of it reads as nothing.
    try testing.expectEqualStrings("null", try it.run("var first = new DOMParser().parseFromString('<b>first</b>', 'text/html').body; for (var i = 0; i < 70; i++) new DOMParser().parseFromString('<i>' + i + '</i>', 'text/html'); String(first.firstChild)"));
}

test "a box with room and a ground of its own is kept as a block with both, for the layout to set" {
    const it = try opened(
        "<!DOCTYPE html><html><body><p>plain</p><div class=\"card\"><p>inside</p></div>" ++
            "<div class=\"panel\"><p>dark</p></div><p class=\"three\">three</p></body></html>",
        false,
    );
    defer it.end();
    css.apply(heap, it.tree,
        \\.card { background: #eef; padding: 16px; margin: 20px 0; margin-left: 4px; border: 1px solid #a2a9b1; border-left: 10px solid #f28500; border-radius: 6px; }
        \\.panel { background: #2b2d42 url(none.png) no-repeat; color: #edf2f4; }
        \\.three { padding: 1px 2px 3px; border-top: none; border-bottom: solid; border-bottom-color: #2a9d8f; }
    , null, &rules);
    var page = try it.page();
    defer page.deinit(heap);
    var grounded: usize = 0;
    var card: ?page_mod.Container = null;
    var three: ?page_mod.Container = null;
    for (page.containers.items) |box| {
        if (box.ground != .none) grounded += 1;
        if (box.ground != .none and card == null) card = box;
        switch (box.style.padding.bottom) {
            .px => |px| if (px == 3) {
                three = box;
            },
            else => {},
        }
    }
    // The card and the panel: a ground from a colour alone, and one from
    // the shorthand that also names a picture.
    try testing.expectEqual(@as(usize, 2), grounded);
    const kept = card orelse return error.NoCard;
    try testing.expectEqual(page_mod.BoxStyle.Display.block, kept.style.display);
    // One value is every side's; two are the top and bottom and the right
    // and left; a longhand takes the side it names.
    try testing.expectEqualDeep(page_mod.BoxStyle.Edges{ .top = .{ .px = 16 }, .right = .{ .px = 16 }, .bottom = .{ .px = 16 }, .left = .{ .px = 16 } }, kept.style.padding);
    try testing.expectEqualDeep(page_mod.BoxStyle.Edges{ .top = .{ .px = 20 }, .right = .{ .px = 0 }, .bottom = .{ .px = 20 }, .left = .{ .px = 4 } }, kept.style.margin);
    // Three leave the left its right's.
    try testing.expectEqualDeep(page_mod.BoxStyle.Edges{ .top = .{ .px = 1 }, .right = .{ .px = 2 }, .bottom = .{ .px = 3 }, .left = .{ .px = 2 } }, (three orelse return error.NoThree).style.padding);
    // The lines along the card's sides: one all round, the left its own
    // wider and orange, and the corners rounded.
    try testing.expectEqualDeep(page_mod.BoxStyle.Line{ .width = .{ .px = 1 }, .colour = .hex(0xa2a9b1) }, kept.style.border.top);
    try testing.expectEqualDeep(page_mod.BoxStyle.Line{ .width = .{ .px = 10 }, .colour = .hex(0xf28500) }, kept.style.border.left);
    try testing.expectEqualDeep(page_mod.Unit{ .px = 6 }, kept.style.radius);
    // A line drawn as none is no line, and one whose colour stands alone
    // takes that colour.
    try testing.expectEqualDeep(page_mod.BoxStyle.Line{}, (three orelse return error.NoThree).style.border.top);
    try testing.expectEqualDeep(page_mod.BoxStyle.Line{ .width = .{ .px = 3 }, .colour = .hex(0x2a9d8f) }, (three orelse return error.NoThree).style.border.bottom);
    try testing.expect(std.mem.findScalar(rgb.Colour, page.palette.items, .hex(0xeeeeff)) != null);
    try testing.expect(std.mem.findScalar(rgb.Colour, page.palette.items, .hex(0x2b2d42)) != null);
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
    // The document, the html and body elements, the main and its two.
    try testing.expectEqual(@as(usize, 6), page.containers.items.len);
    const main = page.containers.items[3].style;
    try testing.expectEqual(page_mod.BoxStyle.Display.flex, main.display);
    try testing.expectEqual(page_mod.BoxStyle.Direction.column, main.direction);
    try testing.expectEqualDeep(page_mod.Unit{ .px = 8 }, main.gap);
    try testing.expectEqualDeep(page_mod.Unit{ .vw = 80 }, main.width);
    try testing.expectEqualDeep(page_mod.Unit{ .vh = 12 }, main.min_height);
    try testing.expectEqual(page_mod.BoxStyle.Justify.between, main.justify);
    try testing.expectEqual(page_mod.BoxStyle.Items.center, main.items);
    const p = page.containers.items[4].style;
    try testing.expectEqualDeep(page_mod.Unit{ .percent = 50 }, p.width);
    try testing.expectEqualDeep(page_mod.Unit{ .px = 400 }, p.max_width);
    // Each paragraph is held by the container, and owns the block it made.
    var kids = page.childrenOf(3);
    try testing.expectEqual(@as(?u32, 4), kids.next());
    try testing.expectEqual(@as(?u32, 5), kids.next());
    try testing.expectEqual(@as(?u32, null), kids.next());
    for (page.blocks.items, 4..) |block, index| try testing.expectEqual(@as(u32, @intCast(index)), block.owner);
}
