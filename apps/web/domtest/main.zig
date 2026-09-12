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
//! or what the tree reads as now.

const std = @import("std");
const js = @import("js");
const dom = @import("dom");
const css = @import("../css.zig");
const extract = @import("../extract.zig");
const lexbor = @import("lexbor");
const rgb = @import("lib").rgb;
const page_mod = @import("../page.zig");
const url = @import("url");

const heap = std.heap.page_allocator;

/// The page every test starts from, with the script stood in its body.
const PAGE =
    \\<!DOCTYPE html><html><head><title>Hello</title></head><body>
    \\<p id="one">first</p>
    \\<p class="noted">second</p>
    \\<div class="noted"><p id="two">deep</p></div>
    \\<script>{s}</script>
    \\</body></html>
;

/// Markup with `script` stood in it, as a page's own script would be.
fn with(script: []const u8) []const u8 {
    return std.fmt.allocPrint(heap, PAGE, .{script}) catch @panic("out of memory");
}

const Opened = struct {
    at: *js.Engine,
    tree: *lexbor.Document,

    fn end(self: Opened) void {
        dom.release(self.at);
        js.close(self.at);
        lexbor.lxb_style_destroy(self.tree);
        _ = lexbor.lxb_html_document_destroy(self.tree);
    }
};

/// A page, parsed, with a document bound into it.
fn opened(markup: []const u8) ?Opened {
    const tree = lexbor.lxb_html_document_create() orelse return null;
    if (lexbor.lxb_style_init(tree) != .ok) {
        _ = lexbor.lxb_html_document_destroy(tree);
        return null;
    }
    if (lexbor.lxb_html_document_parse(tree, markup.ptr, markup.len) != .ok) {
        lexbor.lxb_style_destroy(tree);
        _ = lexbor.lxb_html_document_destroy(tree);
        return null;
    }
    const at = js.open(machineOf()) orelse {
        lexbor.lxb_style_destroy(tree);
        _ = lexbor.lxb_html_document_destroy(tree);
        return null;
    };
    if (!dom.bind(at, tree, "http://example.test/one", "vibeee", null, null, &clock, &testGo, null, null)) {
        js.close(at);
        lexbor.lxb_style_destroy(tree);
        _ = lexbor.lxb_html_document_destroy(tree);
        return null;
    }
    return .{ .at = at, .tree = tree };
}

/// What the tree reads as: the page's own markup, after the script has run.
fn read(tree: *lexbor.Document) []const u8 {
    var out: lexbor.Text = .{ .data = null, .length = 0 };
    const root = lexbor.lxb_dom_document_root(tree) orelse return "";
    if (lexbor.lxb_html_serialize_tree_str(root, &out) != 0) return "";
    return if (out.data) |data| data[0..out.length] else "";
}

fn clock() callconv(.c) u32 {
    return 0;
}

/// Where a script has asked to be taken, which is what a redirect is. Copied,
/// since the engine gives the address back as soon as the call is over.
var went_in: [256]u8 = undefined;
var went: ?[]const u8 = null;

fn testGo(_: ?*anyopaque, where: [*:0]const u8) callconv(.c) void {
    const asked = std.mem.span(where);
    const kept = @min(asked.len, went_in.len);
    @memcpy(went_in[0..kept], asked[0..kept]);
    went = went_in[0..kept];
}

var machine: ?*js.Machine = null;

fn machineOf() *js.Machine {
    if (machine) |it| return it;
    const made = js.start() orelse @panic("no machine");
    machine = made;
    return made;
}

/// Run `script` in a fresh page and give back what it said.
fn says(script: []const u8, want: []const u8) !void {
    const markup = with(script);
    const it = opened(markup) orelse return error.NoPage;
    defer it.end();
    dom.load(it.at, it.tree);
    const got = js.run(it.at, script, "<test>", false) orelse {
        std.debug.print("\n  script: {s}\n  threw:\n", .{script});
        if (dom.errorLast(it.at)) |error_text| std.debug.print("  first error: {s}\n", .{error_text});
        js.tellError(it.at);
        return error.Threw;
    };
    defer js.giveBack(it.at, got);
    const text = std.mem.span(got);
    if (!std.mem.eql(u8, text, want)) {
        std.debug.print("\n  said: {s}\n  want: {s}\n", .{ text, want });
        return error.NotWhatWasSaid;
    }
}

/// Run `script` as a page's own script and give back the markup the tree
/// reads as afterwards, which is what a script that changes the page does.
fn reads(script: []const u8, want: []const u8) !void {
    const markup = with(script);
    const it = opened(markup) orelse return error.NoPage;
    defer it.end();
    dom.load(it.at, it.tree);
    const tree = read(it.tree);
    if (!std.mem.containsAtLeast(u8, tree, 1, want)) {
        std.debug.print("\n  read: {s}\n  want: {s}\n", .{ tree, want });
        return error.NotWhatWasRead;
    }
}

/// Read a page, let a script change its tree, then read the same tree again.
fn rereads(script: []const u8) !page_mod.Page {
    const markup = with("");
    defer heap.free(markup);
    const it = opened(markup) orelse return error.NoPage;
    defer it.end();
    dom.load(it.at, it.tree);

    const base = url.parse("http://example.test/one") orelse return error.NoBase;
    var first: page_mod.Page = .{};
    defer first.deinit(heap);
    try extract.extract(heap, it.tree, base, &first);

    const changed = js.run(it.at, script, "<test>", false) orelse {
        std.debug.print("\n  script: {s}\n  threw:\n", .{script});
        if (dom.errorLast(it.at)) |error_text| std.debug.print("  first error: {s}\n", .{error_text});
        js.tellError(it.at);
        return error.Threw;
    };
    defer js.giveBack(it.at, changed);
    if (!dom.changed(it.at)) return error.NotChanged;

    var again: page_mod.Page = .{};
    errdefer again.deinit(heap);
    try extract.extract(heap, it.tree, base, &again);
    return again;
}

test "an element is found by its id" {
    try says("document.getElementById('one').textContent", "first");
}

test "its tag is named as a tag is" {
    try says("document.getElementById('one').tagName", "P");
}

test "text is written into it" {
    try says("document.getElementById('one').textContent = 'changed'; document.getElementById('one').textContent", "changed");
}

test "a class is added" {
    try says("document.getElementById('one').classList.add('new'); document.getElementById('one').className", "new");
}

test "a class it has is said to be there" {
    try says("document.getElementById('one').classList.add('new'); document.getElementById('one').classList.contains('new')", "true");
}

test "an attribute is set and read" {
    try says("document.getElementById('one').setAttribute('data-x', 'y'); document.getElementById('one').getAttribute('data-x')", "y");
}

test "an attribute is taken away" {
    try says("var e = document.getElementById('one'); e.setAttribute('data-x', 'y'); e.removeAttribute('data-x'); String(e.hasAttribute('data-x'))", "false");
}

test "every element of a kind is found" {
    try says("document.getElementsByTagName('p').length", "3");
}

test "every element of a class is found" {
    try says("document.getElementsByClassName('noted').length", "2");
}

test "a selector finds them all" {
    try says("document.querySelectorAll('p').length", "3");
}

test "a selector finds one" {
    try says("document.querySelector('#two').textContent", "deep");
}

test "a selector finds by class" {
    try says("document.querySelectorAll('.noted').length", "2");
}

test "an element says whether it matches" {
    try says("String(document.getElementById('one').matches('p'))", "true");
}

test "the nearest ancestor matching is found" {
    try says("document.getElementById('two').closest('div').tagName", "DIV");
}

test "an element is made and put somewhere" {
    try reads("var p = document.createElement('p'); p.textContent = 'new'; document.body.appendChild(p);", "<p>new</p>");
}

test "an element takes itself away" {
    try reads("document.getElementById('one').remove();", "second");
}

test "markup is written and read" {
    try says("document.getElementById('one').innerHTML = '<b>bold</b>'; document.getElementById('one').innerHTML", "<b>bold</b>");
}

test "the title is read" {
    try says("document.title", "Hello");
}

test "the title is written" {
    try reads("document.title = 'Bye';", "<title>Bye</title>");
}

test "a cookie is written and read" {
    try says("document.cookie = 'a=1'; document.cookie", "a=1");
}

test "what a page puts by is read back" {
    try says("localStorage.setItem('k', 'v'); localStorage.getItem('k')", "v");
}

test "the page says where it is" {
    try says("location.href", "http://example.test/one");
}

test "and which part of it" {
    try says("location.hostname", "example.test");
}

test "and what the reader is called" {
    try says("navigator.userAgent", "vibeee");
}

test "what is not here is an empty shape" {
    // Asked without `typeof`: upstream's peephole for `typeof` is a signed
    // shift that overflows, which Zig's C compiler -- unlike the C one -- turns
    // into a panic, so a script saying `typeof` cannot be run here. What the
    // test is for is that the shape is there and empty, not the operator.
    try says("getComputedStyle(document.body).getPropertyValue('color')", "");
}

test "and a box is noughts" {
    try says("document.body.getBoundingClientRect().width", "0");
}

test "an event is told" {
    try says(
        "var got = 'none';" ++
            "document.getElementById('one').addEventListener('click', function () { got = 'clicked'; });" ++
            "document.getElementById('one').click(); got",
        "clicked",
    );
}

test "a script has added to the page" {
    try reads(
        "var p = document.createElement('p');" ++
            "p.textContent = 'added';" ++
            "document.body.appendChild(p);" ++
            "window.__result = document.body.textContent;",
        "added",
    );
}

test "what a script left waiting ran, and said so" {
    const script = "var got = 'none'; setTimeout(function () { got = 'later'; }, 0);";
    const markup = with(script);
    const it = opened(markup) orelse return error.NoPage;
    defer it.end();
    dom.load(it.at, it.tree);
    if (!dom.loop(it.at)) return error.NothingRan;
    const got = js.run(it.at, "got", "<test>", false) orelse return error.Threw;
    defer js.giveBack(it.at, got);
    try std.testing.expectEqualStrings("later", std.mem.span(got));
}

test "a script sends the reader somewhere" {
    const script = "location.href = 'http://else.test/two';";
    const markup = with(script);
    const it = opened(markup) orelse return error.NoPage;
    defer it.end();
    went = null;
    dom.load(it.at, it.tree);
    try std.testing.expectEqualStrings("http://else.test/two", went orelse return error.Nowhere);
}

test "and says where it is, as the document says it too" {
    try says("document.location.href", "http://example.test/one");
}

test "and is sent by assign, as a page that has moved says" {
    const script = "location.assign('http://else.test/three');";
    const markup = with(script);
    const it = opened(markup) orelse return error.NoPage;
    defer it.end();
    went = null;
    dom.load(it.at, it.tree);
    try std.testing.expectEqualStrings("http://else.test/three", went orelse return error.Nowhere);
}

test "and is sent by replacing the whole location" {
    const script = "window.location = 'http://else.test/four';";
    const markup = with(script);
    const it = opened(markup) orelse return error.NoPage;
    defer it.end();
    went = null;
    dom.load(it.at, it.tree);
    try std.testing.expectEqualStrings("http://else.test/four", went orelse return error.Nowhere);
}

test "and by the document's, which pages reach for as often" {
    const script = "document.location = 'http://else.test/five';";
    const markup = with(script);
    const it = opened(markup) orelse return error.NoPage;
    defer it.end();
    went = null;
    dom.load(it.at, it.tree);
    try std.testing.expectEqualStrings("http://else.test/five", went orelse return error.Nowhere);
}

test "and says where it is, however it is asked" {
    try says("window.location.href", "http://example.test/one");
    try says("top.location.href", "http://example.test/one");
}

test "and names its parsed path and protocol" {
    try says("location.protocol + location.pathname", "http:/one");
}

test "a listener may change listeners while it is told" {
    const script =
        "var e = document.getElementById('one'); var n = 0;" ++
        "function once() { n++; e.removeEventListener('click', once);" ++
        "e.addEventListener('click', function () { n += 10; }); }" ++
        "e.addEventListener('click', once); e.click(); e.click();";
    const it = opened(with(script)) orelse return error.NoPage;
    defer it.end();
    dom.load(it.at, it.tree);
    const got = js.run(it.at, "String(n)", "<test>", false) orelse return error.Threw;
    defer js.giveBack(it.at, got);
    try std.testing.expectEqualStrings("11", std.mem.span(got));
}

test "a timer may clear itself while it runs" {
    const script = "var n = 0; var id = setInterval(function () { n++; clearInterval(id); }, 0);";
    const it = opened(with(script)) orelse return error.NoPage;
    defer it.end();
    dom.load(it.at, it.tree);
    try std.testing.expect(dom.loop(it.at));
    try std.testing.expect(!dom.loop(it.at));
    const got = js.run(it.at, "String(n)", "<test>", false) orelse return error.Threw;
    defer js.giveBack(it.at, got);
    try std.testing.expectEqualStrings("1", std.mem.span(got));
}

test "a relative URL is resolved where the page is" {
    try says("new URL('../two?q=three', location.href).href", "http://example.test/two?q=three");
}

test "a component may extend a browser element class" {
    const script = "class Thing extends HTMLElement {}; customElements.define('a-thing', Thing);";
    const it = opened(with(script)) orelse return error.NoPage;
    defer it.end();
    dom.load(it.at, it.tree);
    const got = js.run(it.at, "Thing.name", "<test>", false) orelse return error.Threw;
    defer js.giveBack(it.at, got);
    try std.testing.expectEqualStrings("Thing", std.mem.span(got));
}

test "a constructed event is dispatched" {
    const script = "var n = 0; document.addEventListener('ready', function () { n++; }); document.dispatchEvent(new Event('ready'));";
    const it = opened(with(script)) orelse return error.NoPage;
    defer it.end();
    dom.load(it.at, it.tree);
    const got = js.run(it.at, "String(n)", "<test>", false) orelse return error.Threw;
    defer js.giveBack(it.at, got);
    try std.testing.expectEqualStrings("1", std.mem.span(got));
}

test "a component may attach its shadow host" {
    try says("document.createElement('div').attachShadow({ mode: 'open' }).nodeType", "1");
}

test "a display set by script is used when the page is read again" {
    var page = try rereads("document.getElementById('one').style.display = 'none';");
    defer page.deinit(heap);
    try std.testing.expect(!std.mem.containsAtLeast(u8, page.text.items, 1, "first"));
    try std.testing.expect(std.mem.containsAtLeast(u8, page.text.items, 1, "second"));
}

test "a cssText visibility set by script is used when the page is read again" {
    var page = try rereads("document.getElementById('one').style.cssText = 'visibility: hidden';");
    defer page.deinit(heap);
    try std.testing.expect(!std.mem.containsAtLeast(u8, page.text.items, 1, "first"));
    try std.testing.expect(std.mem.containsAtLeast(u8, page.text.items, 1, "second"));
}

test "a setProperty colour set by script is used when the page is read again" {
    var page = try rereads("document.getElementById('one').style.setProperty('color', '#123456'); 'changed';");
    defer page.deinit(heap);
    try std.testing.expect(std.mem.findScalar(rgb.Colour, page.palette.items, .hex(0x123456)) != null);
}

test "CSS geometry is retained as direct-child boxes without changing text blocks" {
    const markup =
        \\<!DOCTYPE html><html><body><main><section><span>one</span></section><div>two</div></main></body></html>
    ;
    const it = opened(markup) orelse return error.NoPage;
    defer it.end();
    css.apply(heap, it.tree,
        \\main { display: flex; width: 80vw; min-height: 12vh; }
        \\section { position: absolute; top: 4px; right: 25%; width: 30%; max-width: 400px; }
        \\span { display: inline; left: auto; }
        \\div { position: fixed; bottom: 5vh; height: 20px; min-width: 10vw; max-height: 90%; }
    , null);

    const base = url.parse("http://example.test/one") orelse return error.NoBase;
    var page: page_mod.Page = .{};
    defer page.deinit(heap);
    try extract.extract(heap, it.tree, base, &page);

    try std.testing.expectEqualStrings("onetwo", page.text.items);
    try std.testing.expectEqual(@as(usize, 2), page.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 4), page.containers.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, page.childrenOf(page.containers.items[0]));
    try std.testing.expectEqualSlices(u32, &.{2}, page.childrenOf(page.containers.items[1]));

    try std.testing.expectEqual(page_mod.BoxStyle.Display.flex, page.containers.items[0].style.display);
    try std.testing.expectEqualDeep(page_mod.Unit{ .vw = 80 }, page.containers.items[0].style.width);
    try std.testing.expectEqualDeep(page_mod.Unit{ .vh = 12 }, page.containers.items[0].style.min_height);

    const section = page.containers.items[1].style;
    try std.testing.expectEqual(page_mod.BoxStyle.Display.block, section.display);
    try std.testing.expectEqual(page_mod.BoxStyle.Position.absolute, section.position);
    try std.testing.expectEqualDeep(page_mod.Unit{ .px = 4 }, section.edges.top);
    try std.testing.expectEqualDeep(page_mod.Unit{ .percent = 25 }, section.edges.right);
    try std.testing.expectEqualDeep(page_mod.Unit{ .percent = 30 }, section.width);
    try std.testing.expectEqualDeep(page_mod.Unit{ .px = 400 }, section.max_width);

    const span = page.containers.items[2].style;
    try std.testing.expectEqual(page_mod.BoxStyle.Display.@"inline", span.display);
    try std.testing.expectEqual(page_mod.BoxStyle.Position.static, span.position);
    try std.testing.expectEqualDeep(page_mod.Unit.auto, span.edges.left);

    const div = page.containers.items[3].style;
    try std.testing.expectEqual(page_mod.BoxStyle.Position.fixed, div.position);
    try std.testing.expectEqualDeep(page_mod.Unit{ .vh = 5 }, div.edges.bottom);
    try std.testing.expectEqualDeep(page_mod.Unit{ .px = 20 }, div.height);
    try std.testing.expectEqualDeep(page_mod.Unit{ .vw = 10 }, div.min_width);
    try std.testing.expectEqualDeep(page_mod.Unit{ .percent = 90 }, div.max_height);
}

test "a flex container's direction, gap and alignment are retained" {
    const markup =
        \\<!DOCTYPE html><html><body><main><p>one</p><p>two</p></main></body></html>
    ;
    const it = opened(markup) orelse return error.NoPage;
    defer it.end();
    css.apply(heap, it.tree,
        \\main { display: flex; flex-direction: column; gap: 8px;
        \\        justify-content: space-between; align-items: center; }
        \\p { flex: none; width: 50%; }
    , null);

    const base = url.parse("http://example.test/one") orelse return error.NoBase;
    var page: page_mod.Page = .{};
    defer page.deinit(heap);
    try extract.extract(heap, it.tree, base, &page);

    try std.testing.expectEqual(@as(usize, 3), page.containers.items.len);
    const main = page.containers.items[0].style;
    try std.testing.expectEqual(page_mod.BoxStyle.Display.flex, main.display);
    try std.testing.expectEqual(page_mod.BoxStyle.Direction.column, main.direction);
    try std.testing.expectEqualDeep(page_mod.Unit{ .px = 8 }, main.gap);
    try std.testing.expectEqual(page_mod.BoxStyle.Justify.between, main.justify);
    try std.testing.expectEqual(page_mod.BoxStyle.Items.center, main.items);

    // Each paragraph is held by the container, and owns the block it made.
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, page.childrenOf(page.containers.items[0]));
    for (page.blocks.items, 1..) |block, index| try std.testing.expectEqual(@as(u32, @intCast(index)), block.owner);
}
