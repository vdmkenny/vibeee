//! A page's scripts: when they run, and what the reader does about it.
//!
//! The reader keeps a page's tree while the page is on screen, so that a
//! script has something to work on and the reader has something to read it
//! back from. This is the policy around that: give a page's tree to a script
//! when the page is put on screen, run what the page carries, listen for a
//! click or a word typed, and read the page again whenever a script has
//! changed it.
//!
//! The whole of the engine and the document behind it is `src/user/js` and
//! `dom.zig`; this file is only when and why. A reader built without them
//! gets `scripts_off.zig`, which says the same things and does none of them.
//! Which of the two it is, is the build's to say: both are the module
//! `scripts`, and the reader asks for that and nothing more.

const std = @import("std");
const js = @import("js");
const heap = @import("ulib").heap;
const lexbor = @import("lexbor");
const sys = @import("sys");
const dom = @import("dom.zig");
const url = @import("url");

/// A page's tree with a script in it.
pub const Page = js.Engine;

/// The engine, started the first time a page wants one and kept: a runtime is
/// the expensive half, and one freed while a script still has objects in it
/// takes the reader with it. A context is made per page and given back with
/// it, so nothing a script was ever given outlives its tree.
var machine: ?*js.Machine = null;

/// What the reader does when a script asks for a page of its own: it fetches
/// it, there and then. Handed in when a page is opened, and kept, because
/// the network is the reader's business and not the engine's.
var fetcher: ?*const fn ([]const u8) ?[]u8 = null;
var going: ?*const fn ([]const u8) void = null;
var cookie_reader: ?*const fn ([]const u8, []u8) usize = null;
var cookie_writer: ?*const fn ([]const u8, []const u8) void = null;
/// Why the last page was read without its scripts, which the reader shows:
/// stdout is not a thing a person reading a page is looking at.
var why: []const u8 = "no page has been asked for scripts yet";

/// The reader's clock, in thousandths of a second, for a script's timers.
export fn qjsClock() callconv(.c) u32 {
    return @truncate(sys.clockMicros() / std.time.us_per_ms);
}

/// What a script says out loud, and what the engine says it could not give a
/// page, go to the system log: stdout is not somewhere a person reading a
/// page is looking, and a reader that cannot say what it could not do is a
/// reader nobody can find the gaps in.
extern fn qjs_set_say(say: ?*const fn ([*:0]const u8) callconv(.c) void) void;

export fn qjsSay(text: [*:0]const u8) callconv(.c) void {
    @import("ulib").log.note("scripts", std.mem.span(text));
}

/// Where a script has asked to be taken: the reader goes there.
export fn qjsGo(taken: ?*anyopaque, where: [*:0]const u8) callconv(.c) void {
    _ = taken;
    if (going) |call| call(std.mem.span(where));
}

export fn qjsFetch(_: ?*anyopaque, address: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const gpa = heap.allocator;
    const got = (fetcher orelse return null)(std.mem.span(address)) orelse return null;
    defer gpa.free(got);
    // NUL-terminated for C, which gives it back with `free`.
    const out = gpa.allocSentinel(u8, got.len, 0) catch return null;
    @memcpy(out, got);
    return out.ptr;
}

/// The cookies the browser holds for a page, copied into the document's
/// caller-owned space. The jar is the reader's and survives this context.
export fn qjsCookies(_: ?*anyopaque, address: [*:0]const u8, into: [*]u8, cap: usize) callconv(.c) usize {
    const read = cookie_reader orelse return 0;
    return read(std.mem.span(address), into[0..cap]);
}

/// A `document.cookie` assignment, kept by the browser rather than this
/// one context so its next page can send it too.
export fn qjsCookie(_: ?*anyopaque, address: [*:0]const u8, assignment: [*:0]const u8) callconv(.c) void {
    const write = cookie_writer orelse return;
    write(std.mem.span(address), std.mem.span(assignment));
}

fn engine() ?*js.Machine {
    if (machine) |kept| return kept;
    machine = js.start();
    return machine;
}

/// Give a page's tree to a script and run what the page carries. None where
/// the engine would not start, which is a page that reads as though it had
/// no scripts.
///
/// The tree comes across as a pointer and nothing more: which kind of tree
/// it is, is the reader's business, and this module is not to be given a
/// second copy of the reader's own files to know.
pub fn open(
    tree: *lexbor.Document,
    address: []const u8,
    user_agent: [*:0]const u8,
    fetch: *const fn ([]const u8) ?[]u8,
    go: *const fn ([]const u8) void,
    cookies: *const fn ([]const u8, []u8) usize,
    set_cookie: *const fn ([]const u8, []const u8) void,
) ?*Page {
    fetcher = fetch;
    going = go;
    cookie_reader = cookies;
    cookie_writer = set_cookie;
    qjs_set_say(&qjsSay);
    // Each way this can fail says which it was: a page read without its
    // scripts looks exactly like one a site sent to a reader with none, and
    // nothing else tells those two apart.
    const machine_at = engine() orelse {
        why = "a runtime would not start";
        js.note(@ptrCast(why.ptr));
        return null;
    };
    const at = js.open(machine_at) orelse {
        why = "a context would not open";
        js.note(@ptrCast(why.ptr));
        return null;
    };
    // The reader can keep an address of this size. A script bridge with a
    // smaller, private buffer made a redirect fail long before the URL layer
    // had a chance to accept it.
    var buf: [url.ADDRESS_MAX + 1]u8 = undefined;
    const where = std.fmt.bufPrintZ(&buf, "{s}", .{address}) catch {
        why = "the address is too long";
        js.note(@ptrCast(why.ptr));
        js.close(at);
        return null;
    };
    if (!dom.bind(at, tree, where.ptr, user_agent, &qjsFetch, null, &qjsClock, &qjsGo, &qjsCookies, &qjsCookie)) {
        why = "the document would not bind";
        js.note(@ptrCast(why.ptr));
        js.close(at);
        return null;
    }
    dom.load(at, tree);
    why = "";
    return at;
}

/// What the page on screen reached for and this reader had no answer to, and
/// how much of that there was.
pub fn askedLast(page: *Page) ?[]const u8 {
    return dom.askedLast(page);
}

pub fn askedCount(page: *Page) u32 {
    return dom.askedCount(page);
}

/// The last exception a page threw, where one did.
pub fn errorLast(page: *Page) ?[]const u8 {
    return dom.errorLast(page);
}

pub fn errorSource(page: *Page) []const u8 {
    return dom.errorSource(page);
}

/// Why the page on screen was read without its scripts, or nothing where it
/// was not.
pub fn whyNot() []const u8 {
    return why;
}

/// How many of the page's scripts have run, and how many of those threw.
pub fn scriptsRan(page: *Page) u32 {
    return dom.scriptsRan(page);
}

pub fn scriptsThrew(page: *Page) u32 {
    return dom.scriptsThrew(page);
}

pub fn close(page: *Page) void {
    dom.release(page);
    js.close(page);
    why = "scripts ran, and were let go with the page";
}

/// A click on the element at `node`. True where a script asked for the click
/// to go no further, which is a link that is not followed.
pub fn click(page: *Page, node: *anyopaque) bool {
    return dom.click(page, node);
}

/// What was typed or ticked in the control at `node`, and whether a form was
/// sent with it.
pub fn typed(page: *Page, node: *anyopaque, sent: bool) void {
    dom.typed(page, node, sent);
}

/// What to send as `Cookie` for a page at `host` and `path`: what the
/// page's scripts have kept for that site, or nothing.
pub fn cookiesFor(page: *Page, host: [*:0]const u8, path: [*:0]const u8) ?[*:0]u8 {
    return dom.cookiesFor(page, host, path);
}

/// Whether a script has changed the page since the last time this was asked,
/// and so whether the reader must read it again.
pub fn changed(page: *Page) bool {
    return dom.changed(page);
}

/// Run what a script left waiting. True where it changed the page, and so
/// where the reader must read it again.
pub fn loop(page: *Page) bool {
    return dom.loop(page) and dom.changed(page);
}

/// When the next timer a script set is due, in thousandths of a second since
/// the machine was started: what a window with a page on screen waits on,
/// where it would otherwise wait on nothing.
pub fn waits(page: *Page) ?u32 {
    return dom.waits(page);
}
