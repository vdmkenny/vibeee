//! web: a reader for pages.
//!
//! What `design/00-vibeee.md` settled on: a reader for simple pages rather
//! than a general browser. It asks a site for one page, reads the words out
//! of the markup, and sets them in this system's own faces in a column the
//! width a line reads best at. It runs nothing a page sends. Of what a page's
//! stylesheets say, it follows what a column of text can show: what they
//! hide, the colours of words and of what they sit on, and which way lines
//! lean. A page's pictures come after its words, one at a time, what the page
//! says each one shows standing in for it until it is here.
//!
//! The parts each have a file: `url` for where things are, `http` and
//! `fetch` for getting them, `source` for a page as it came and what it reads
//! as, `lexbor`, `css`, `media` and `extract` for reading markup and its
//! stylesheets into a `page`, `layout` for where its words go, `pictures` for
//! what it shows among them, and `view` for the part on screen. This file is
//! the window around them and the order they run in.
//!
//! A page's stylesheets are fetched after its markup, on the connection it
//! came on, and its words are read once they are here. Their media queries
//! are asked about the window the page is drawn in, so a window that changes
//! size reads the page again where they answer differently.
//!
//! `web -t <address>` prints a page's words instead of opening a window, so
//! whatever the window can read, the shell can too.
//!
//! Where it starts, whether it fetches pictures, whether it follows a page's
//! stylesheets, whether it asks for the versions of pages made for small
//! screens and whether pages are drawn light or dark are settings, in the
//! `web` domain the store keeps: `cfg web` lists them, the menu at the end of
//! the strip changes them and makes the page on screen the home page, and a
//! window that is open takes a change as it is made.
//!
//! Not part of the system. It is built into `home/bin/` and versioned on its
//! own.

const std = @import("std");
const eui = @import("eui");
const lib = @import("lib");
const proto = @import("proto");
const sys = @import("sys");
const ulib = @import("ulib");

const env = ulib.env;
const file = ulib.file;
const heap = ulib.heap;
const out = ulib.out;
const paths = ulib.paths;
const str = lib.str;
const Bounded = lib.bounded.Bounded;

const blocklist_mod = @import("blocklist.zig");
/// The names on the list, as the build wrote them out. Fetched and written
/// by `gen_blocklist.zig`, which `build.zig` runs for every reader it builds.
const blocklist_data = @import("blocklist_data");
const charset = @import("charset.zig");
const cookie_mod = @import("cookie.zig");
const css = @import("css.zig");
const fetch_mod = @import("fetch.zig");
const form_mod = @import("form.zig");
const http = @import("http.zig");
const media = @import("media.zig");
const page_mod = @import("page.zig");
const pictures_mod = @import("pictures.zig");
const scripts = @import("page_scripts");
const source_mod = @import("source.zig");
const url = @import("url");
const view_mod = @import("view.zig");
/// What the reader and its script worker say to each other, §5 of
/// design/13-script-worker.md. Both sides import this one module, so both
/// spell the protocol the same way.
const worker_proto = @import("worker_proto");
/// Where a page's scripts run: in a worker of its own, which is
/// design/13-script-worker.md. The reader holds the page, the network, the
/// cookies and the window; the worker holds what a page can corrupt.
const script_host = @import("script_host");
/// The machine under the host: two pipes and a program between them. The
/// only part of this that makes syscalls, and the only part of it that
/// cannot be tested on this machine.
const script_host_sys = @import("script_host_sys");

// The routines lexbor's C calls by name.
comptime {
    _ = @import("clibc");
}

// The protocol the reader will send its worker, written and read here in the
// compiler so that a change to it is a change this build fails on, and not
// something found at runtime on a machine with no debugger.
comptime {
    var into: [worker_proto.HEADER_LEN + 1]u8 = undefined;
    const frame = worker_proto.encode(.{ .stop = {} }, &into) catch unreachable;
    const stopped = worker_proto.decode(frame) catch unreachable;
    std.debug.assert(stopped.tag() == .stop);
    std.debug.assert(stopped.direction() == .to_worker);
}

const ctx = &proto.app.ctx;
const gpa = heap.allocator;

const Rect = eui.Rect;
const KeyCode = eui.widget.KeyCode;
const Modifiers = eui.widget.Modifiers;
const Page = page_mod.Page;
const Source = source_mod.Source;
const Tree = source_mod.Tree;

/// How soon after a pass the step of a fetch that blocks runs: straight
/// away, but after the pass that says what is about to happen has been
/// drawn.
const SOON_US: usize = 1;
/// How often a page arriving is checked on for a site gone quiet.
const WATCH_US: usize = 1_000_000;
/// Nothing to check: the window sleeps until something happens.
const IDLE_US: usize = std.math.maxInt(usize);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

var address: eui.text.Field(url.ADDRESS_MAX) = .{};
var view: view_mod.View = .{};
/// The page on screen.
var shown: Page = .{};
/// The page on screen as it came, kept to read it again in a window it reads
/// differently in.
var source: Source = .{};
/// The page on screen as a tree, kept while it is on screen: a script works
/// on it, and the reader reads the page from it again where one has changed
/// it.
var document: ?Tree = null;
/// The script running on the page on screen, where the reader runs one
/// itself. A page in a window is the worker's, so this is nothing: the
/// reader opens no engine of its own over a page it has given away.
var in_page: ?*scripts.Page = null;
/// Where the page on screen's scripts run: the worker's process, the channel
/// to it, and what the reader says of them when the worker goes.
var scripts_host: script_host.Host = .{};
/// The window the page on screen was read for, and the one it is drawn in
/// now, as a stylesheet asks about a window. None before there is a window.
var read_for: ?media.Screen = null;
var window: ?media.Screen = null;
/// A page whose markup has come and whose stylesheets are still coming.
var reading: ?Reading = null;
var fetch: fetch_mod.Fetch = .{};
/// Cookies are the browser's session state, rather than a document's: they
/// cross redirects and pages while this reader remains open.
var cookie_jar: cookie_mod.Jar = .{};
/// The address a text-mode script asked to be taken to. Text mode has no
/// window loop to own navigation, so it records the request and `readBody`
/// hands it back to `printText`'s existing redirect loop.
var text_redirect: ?url.Address = null;
var text_base: url.Address = .{};
var text_trace = false;
/// The pictures of the page on screen, and the fetch that brings them.
var pictures: pictures_mod.Pictures = .{};
/// The fetch a script asks for: kept apart from the page's own, which is
/// mid-page, and from the pictures', which may be mid-picture. A script's
/// question must not be asked on the connection the page is coming down.
var script_fetch: fetch_mod.Fetch = .{ .asking = .{ .wanted = .page } };
var history: History = .{};

/// The reader's settings as the store last had them, and the event that says
/// they changed, where the store is there to give one.
var choices: proto.settings.Web = .{};
var settings_changed: ?u32 = null;

/// What the window sleeps on besides its own events: the settings changing,
/// and the site while a page is coming from one.
var wakes: Bounded(u32, 3) = .{};

/// How much of the rule under the strip was last painted, in thousandths.
var drawn_progress: ?u16 = null;
/// How far down to open the page being fetched: where it was left, when it
/// is one being gone back to.
var pending_scroll: i32 = 0;
/// Where the keyboard goes on the next pass: to the field when the reader
/// opens with nowhere to go, and to the page once one has arrived.
var focus_next: ?enum { field, page } = null;
/// The page being visited was followed to the version for small screens it
/// names, and is followed no further: once for each place gone to.
var followed_mobile = false;
/// The site that named the version for small screens being gone on to, and
/// the site that version is on, until it has come.
var detour: ?Detour = null;
/// Sites whose version for small screens sent the reader straight on to
/// another site, as a site that tells phones from other readers by what a
/// reader calls itself does. Not gone on to again while the reader runs.
var refused: Bounded(Host, REFUSED_MAX) = .{};
const REFUSED_MAX = 16;

/// A site's name, as long as one may be.
const Host = Bounded(u8, 255);

/// The answers the form last sent had, and where they were sent. Kept so that
/// the page those answers made can be fetched again — which fetching a page
/// again, or going back to one and on again, asks for — by sending them
/// again, rather than by asking for the empty form the site answers a GET
/// with. One form's answers, the last sent, being all a reader with one page
/// on screen needs.
var sending: Sending = .{};

const Sending = struct {
    /// Where they were sent: empty where no form has been sent yet.
    at: url.Address = .{},
    answers: [ANSWERS_MAX]u8 = undefined,
    len: usize = 0,

    /// The answers, where they were sent to `target`.
    fn forTarget(self: *const Sending, target: []const u8) ?[]const u8 {
        if (self.at.isEmpty() or !std.mem.eql(u8, self.at.slice(), target)) return null;
        return self.answers[0..self.len];
    }
};

/// The most a form's answers may come to, written as a query. A search is a
/// dozen words; this leaves room for a form with a page of them, and none for
/// one that sends a file.
const ANSWERS_MAX = 8 * 1024;

const Detour = struct { from: Host = .{}, to: Host = .{} };
/// The tab still names the page before this one. Said on the next pass
/// rather than when the page changes, because the first page can arrive
/// before there is a window to say it on.
var title_stale = true;

/// How the page on screen got here, for the status line. None for a page the
/// reader wrote itself to say why another is not here.
var arrived: ?Arrival = null;

const Arrival = struct {
    bytes: usize,
    /// How long it took to come, or none for a file read here.
    us: ?u64 = null,
    /// What the site answered, or none for a file.
    status: ?u16 = null,
};

/// A page between its markup arriving and its words being read: what came so
/// far, the tree its markup parsed into, and the stylesheets it links to,
/// fetched one after another.
const Reading = struct {
    source: Source,
    tree: Tree,
    links: css.Sheets = .{},
    /// The media the link to the stylesheet being fetched names.
    asked: []const u8 = "",

    fn deinit(self: *Reading) void {
        self.tree.close();
        self.links.deinit(gpa);
    }
};

/// Where the reader is and where it has been, one entry per page gone to,
/// with how far down each was left so that going back returns to the place.
const History = struct {
    const MAX = 32;

    const Entry = struct {
        address: url.Address = .{},
        scroll: i32 = 0,
    };

    entries: Bounded(Entry, MAX) = .{},
    at: usize = 0,

    fn current(self: *History) ?*Entry {
        return if (self.entries.isEmpty()) null else &self.entries.mutable()[self.at];
    }

    /// A new page. Whatever was ahead of the current one is forgotten, as it
    /// is whenever somewhere new is gone to from a page gone back to; the
    /// oldest goes when the list is full.
    fn push(self: *History, where: []const u8) void {
        if (!self.entries.isEmpty()) self.entries.truncate(self.at + 1);
        if (self.entries.isFull()) self.entries.remove(0);
        var entry: Entry = .{};
        _ = entry.address.set(where);
        self.entries.append(entry) catch unreachable;
        self.at = self.entries.len - 1;
    }

    fn canBack(self: *const History) bool {
        return self.at > 0;
    }

    fn canForward(self: *const History) bool {
        return self.at + 1 < self.entries.len;
    }
};

// ---------------------------------------------------------------------------
// Starting
// ---------------------------------------------------------------------------

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    // Read before anything is asked of a site, by the window or the shell.
    choices = proto.settings.load("web");
    apply();
    // Where this reader runs a page's scripts: in a worker of its own,
    // started for a page and let go on the next. The reader keeps the page,
    // the network, the cookies and the window, and the worker keeps what a
    // page can corrupt (design/13-script-worker.md).
    scripts_host = .forWorker(script_host_sys.platform, gpa);
    const first = env.arg(frame, 1);
    if (first) |flag| {
        if (std.mem.eql(u8, flag, "-t")) printText(env.arg(frame, 2) orelse usage());
    }

    address.init(.{ .hint = "an address, or a file on this machine" });
    view.show(gpa, &shown, 0);
    settings_changed = proto.settings.watch("web") catch null;
    if (first) |target| typed(target) else home();
    sleepOn(null);

    proto.app.run("web", "web", 800, 480, .{
        .draw = draw,
        .key = key,
        .tick = tick,
        // The frame begins with what it is handed here, so a first page
        // already on its way is handed over as one.
        .tick_us = if (fetch.busy() or reading != null) SOON_US else IDLE_US,
        .wakes = wakes.slice(),
        .woken = woken,
    });
}

fn usage() noreturn {
    out.trouble("usage: web [address]    web -t <address>\n");
    sys.exit(2);
}

// ---------------------------------------------------------------------------
// Going places
// ---------------------------------------------------------------------------

/// Go to what a person typed.
fn typed(text: []const u8) void {
    var buf: [url.ADDRESS_MAX]u8 = undefined;
    go(addressFrom(text, &buf) orelse return failed(error.NotAnAddress, text));
}

/// Go to the home page the settings name. With none named there is nowhere to
/// go, and the keyboard goes to the address instead.
fn home() void {
    const where = choices.homepage.slice();
    if (where.len == 0) {
        focus_next = .field;
        return;
    }
    typed(where);
}

/// Put the settings into effect: what sites are asked for, whether pictures
/// are fetched, the sites kept away from, and the shade pages are drawn in.
fn apply() void {
    const kept = keptFrom();
    for (fetches()) |one| {
        one.asking.mobile = choices.mobile;
        one.blocklist = kept;
    }
    pictures.enabled = choices.images;
    inShade(pageShade());
}

/// The sites the reader keeps away from, while ad protection is on: those
/// that serve ads, and those that count and follow the people reading. None
/// where it is off, which is how it is turned off.
fn keptFrom() ?blocklist_mod.Blocklist {
    if (!choices.ad_protection) return null;
    return .{ .hashes = &blocklist_data.hashes };
}

/// The `Cookie` line for the request about to be made, written here so it
/// lasts until the request has gone: the engine hands back a string of its
/// own, and it is given back at once.
var cookie_line: [8 * 1024]u8 = undefined;
var cookie_len: usize = 0;

/// What the reader sends as `Cookie` for `target`, from the session jar.
fn cookiesFrom(target: []const u8) []const u8 {
    const where = url.parse(target) orelse return blankCookies();
    const line = cookie_jar.write(where, true, &cookie_line);
    if (text_trace and line.len > 0) traceCookies("->", where.host, cookie_jar.count());
    cookie_len = line.len;
    return line;
}

fn blankCookies() []const u8 {
    cookie_len = 0;
    return cookie_line[0..0];
}

/// The text a page is allowed to see through `document.cookie`: the session
/// jar, without cookies a server marked HttpOnly.
fn cookiesForScript(address_: []const u8, into: []u8) usize {
    const where = url.parse(address_) orelse return 0;
    return cookie_jar.write(where, false, into).len;
}

/// A `document.cookie` assignment, kept past this document and sent to the
/// next page or redirect on the matching site.
fn setScriptCookie(address_: []const u8, assignment: []const u8) void {
    const where = url.parse(address_) orelse return;
    cookie_jar.take(gpa, where, assignment, false);
}

/// Every Set-Cookie field in one response. Fetch calls this before it follows
/// a Location, so redirect cookies are present on the request that follows.
fn takeResponseCookies(address_: []const u8, response: *const http.Response) void {
    const where = url.parse(address_) orelse return;
    const before = cookie_jar.count();
    cookie_jar.takeHead(gpa, where, response.head.slice());
    if (text_trace and cookie_jar.count() > before) traceCookies("<-", where.host, cookie_jar.count() - before);
}

fn traceCookies(direction: []const u8, host: []const u8, count: usize) void {
    var line: [128]u8 = undefined;
    out.text(std.fmt.bufPrint(&line, "cookies {s} {s}: {d}\n", .{ direction, host, count }) catch return);
}

/// The page's fetch, which brings its stylesheets too, and its pictures'.
fn fetches() [2]*fetch_mod.Fetch {
    return .{ &fetch, &pictures.fetch };
}

/// The shade pages are drawn in: the one the settings name, or where they
/// leave it to the interface, the interface's.
fn pageShade() lib.rgb.Shade {
    return switch (choices.theme) {
        .auto => eui.theme.shade(),
        .light => .light,
        .dark => .dark,
    };
}

/// Draw pages in `shade`, and tell sites and stylesheets so. Where the
/// settings leave the shade to the interface it follows the interface's,
/// which can change under a window that is open, so every pass puts it into
/// effect as well. A page's pictures are laid over its ground, so those that
/// showed the last one through them are let go of and asked for again.
fn inShade(shade: lib.rgb.Shade) void {
    const was = view.shade;
    view.shade = shade;
    for (fetches()) |one| one.asking.shade = shade;
    if (shade == was) return;
    if (pictures.reground(gpa, view.ground())) view.relayout();
}

/// Go on to the version of the page made for small screens, which the page
/// on site `from` named, as a redirect would: the history keeps one entry,
/// and it names where the reader went.
fn goMobile(where: []const u8, from: []const u8) void {
    followed_mobile = true;
    var next: Detour = .{};
    _ = next.from.set(from);
    if (url.parse(where)) |to| _ = next.to.set(to.host);
    detour = next;
    if (history.current()) |entry| _ = entry.address.set(where);
    visit(where);
}

/// Whether the version for small screens a page on `host` names has sent
/// the reader on elsewhere.
fn refusedBy(host: []const u8) bool {
    for (refused.slice()) |site| {
        if (std.ascii.eqlIgnoreCase(site.slice(), host)) return true;
    }
    return false;
}

/// A page has come at `final`. Where it came after a detour to a version for
/// small screens and is on another site than that version, the version sent
/// the reader on, and the site that named it is remembered as one whose
/// version is not gone on to again. The oldest remembered goes when there is
/// no more room.
fn landed(final: url.Url) void {
    const went = detour orelse return;
    detour = null;
    if (std.ascii.eqlIgnoreCase(final.host, went.to.slice()) or refusedBy(went.from.slice())) return;
    if (refused.isFull()) refused.remove(0);
    refused.append(went.from) catch unreachable;
}

/// Follow a link on the page on screen.
fn follow(link: u16) void {
    go(shown.address(link) orelse return);
}

/// Go somewhere new, which the history remembers.
/// Go somewhere new, which the history remembers. What a form last sent is
/// forgotten: a page gone to by its address is the form itself, and not the
/// page the answers made last time.
fn go(where: []const u8) void {
    sending = .{};
    // A script normally says `/next`, `next`, or `?page=2`, not the whole
    // address it is already on. Links are resolved while the page is read,
    // but a script is handed straight here, so give its relative destination
    // the same base before it is made a new history entry.
    if (url.parse(where) == null) {
        if (url.parse(source.base.slice())) |base| {
            var resolved: [url.ADDRESS_MAX]u8 = undefined;
            if (url.resolve(base, where, &resolved)) |whole| return visitNew(whole);
        }
    }
    visitNew(where);
}

/// Send the answers in `sending` to `where`, and go to the page that comes
/// back, which the history remembers.
fn send(where: []const u8) void {
    visitNew(where);
}

/// Go somewhere for the first time, which the history remembers.
fn visitNew(where: []const u8) void {
    followed_mobile = false;
    detour = null;
    if (history.current()) |entry| entry.scroll = view.scroll;
    // Kept before anything else happens: `where` may be an address on the
    // page on screen, which going replaces.
    history.push(where);
    pending_scroll = 0;
    visit(history.current().?.address.slice());
}

fn back() void {
    if (!history.canBack()) return;
    history.current().?.scroll = view.scroll;
    history.at -= 1;
    revisit();
}

fn forward() void {
    if (!history.canForward()) return;
    history.current().?.scroll = view.scroll;
    history.at += 1;
    revisit();
}

fn reload() void {
    const entry = history.current() orelse return;
    entry.scroll = view.scroll;
    revisit();
}

/// Go to the history's current entry again, at the place it was left.
fn revisit() void {
    const entry = history.current() orelse return;
    followed_mobile = false;
    detour = null;
    pending_scroll = entry.scroll;
    visit(entry.address.slice());
}

/// Fetch `target`, or read it here when it is a file, without touching the
/// history.
fn visit(target: []const u8) void {
    abandon();
    address.setFromStart(target);
    const where = url.parse(target) orelse return failed(error.NotAnAddress, target);
    if (where.scheme == .file) return openFile(where);
    // A page on one of the sites the reader keeps away from is not gone to:
    // the page itself is what a tracker writes, no less than a picture from
    // one is.
    if (fetch.refuses(where)) return failed(error.Blocked, where.host);
    // What a form last sent, where it was sent here: the page is fetched by
    // sending the answers again, rather than by asking for the empty form the
    // site answers a GET with.
    fetch.asking.sent = if (sending.forTarget(target)) |answers| .{ .form = answers } else .nothing;

    fetch.asking.cookies = cookiesFrom(target);
    fetch.response_hook = &takeResponseCookies;
    fetch.cookies_for = &cookiesFrom;
    // The network is the page's while it comes: the pictures of the one on
    // screen wait.
    pictures.pause(gpa);
    fetch.begin(gpa, target);
    _ = settle(.none);
}

fn stop() void {
    fetch.cancel(gpa);
    if (reading != null) {
        // What of its stylesheets came is what it is drawn with.
        fetch.asking.wanted = .page;
        return finish();
    }
    if (history.current()) |entry| address.setFromStart(entry.address.slice());
    // The page on screen stays, and so do its pictures still to come.
    waitFor(.none);
}

/// An address from what was typed: one written out whole, as it is; a file
/// on this machine, by its path; and a site's bare name, sealed. A site that
/// speaks only in the clear has to be asked for with `http://` in front.
fn addressFrom(typed_text: []const u8, buf: []u8) ?[]const u8 {
    const text = std.mem.trim(u8, typed_text, &std.ascii.whitespace);
    if (text.len == 0) return null;
    if (url.parse(text)) |whole| return std.fmt.bufPrint(buf, "{f}", .{whole}) catch null;

    // A name that is a file here is that file, which is what `web page.html`
    // means, and something written as a path is a file whether it is there
    // or not, so that a missing one is said to be missing.
    const path_shaped = text[0] == '/' or std.mem.startsWith(u8, text, "./") or std.mem.startsWith(u8, text, "../");
    if (path_shaped or file.factsOf(text) != null) return fileAddress(text, buf);

    // A site's bare name: one word, with a dot in it.
    if (std.mem.indexOfAny(u8, text, &std.ascii.whitespace) != null or std.mem.indexOfScalar(u8, text, '.') == null) return null;
    var sealed: [url.ADDRESS_MAX]u8 = undefined;
    const whole = url.parse(std.fmt.bufPrint(&sealed, "https://{s}", .{text}) catch return null) orelse return null;
    return std.fmt.bufPrint(buf, "{f}", .{whole}) catch null;
}

/// `file://` and the whole path, from one that may be relative to where the
/// reader was started.
fn fileAddress(path: []const u8, buf: []u8) ?[]const u8 {
    var whole: [url.ADDRESS_MAX]u8 = undefined;
    const absolute = if (path[0] == '/') path else relative: {
        var here: [url.ADDRESS_MAX]u8 = undefined;
        const len = sys.getcwd(&here) catch return null;
        break :relative paths.joined(here[0..len], path, &whole) orelse return null;
    };
    return std.fmt.bufPrint(buf, "file://{s}", .{absolute}) catch null;
}

// ---------------------------------------------------------------------------
// Fetching
// ---------------------------------------------------------------------------

fn tick() bool {
    const said = pumpHost();
    const drew = step();
    // What a script left waiting, which the page is read again for where it
    // changed the page.
    if (in_page) |page| {
        if (scripts.loop(page)) {
            readAgain();
            return true;
        }
    }
    return drew or said;
}

/// What the worker has said, where this reader has one: read until it has
/// nothing more to say, and say what is worth saying of it.
///
/// A `page` from it will be the page on screen (§5). Until a page can be
/// serialized that is not a message this reader can act on, so what comes
/// across today is what a script could not have and the worker's own going,
/// and the page on screen stays as the reader read it.
fn pumpHost() bool {
    var said = false;
    while (scripts_host.take()) |message| {
        said = true;
        switch (message) {
            // TODO(13): the page as the worker has it. This is the one
            // message that carries a whole page, and its shape is still
            // open (§11); what is on screen is what the reader read.
            .page => {},
            .script_error => |it| ulib.log.note("script", it.text),
            .missing => |it| {
                var line: [worker_proto.NAME_MAX + 16]u8 = undefined;
                ulib.log.note("scripts", std.fmt.bufPrint(&line, "no {s}", .{it.text}) catch "no API");
            },
            // Where a page wants to go, what it wants fetched, and what its
            // cookies say: the reader's to do, and not done yet (§4). A
            // worker that has gone has been marked by the host already.
            .navigate, .fetch_request, .cookie_value, .stopped => {},
            // Nothing else comes this way: the rest are the reader's words.
            else => {},
        }
    }
    return said;
}

fn woken(index: usize) bool {
    if (settings_changed != null and wakes.at(index) == settings_changed) {
        adopt(proto.settings.load("web"));
        return true;
    }
    // It may have been the worker that woke the reader.
    _ = pumpHost();
    _ = step();
    // A piece arrived, which the status line counts, whatever else it did.
    return true;
}

/// Take `next` as the reader's settings, from the store or from the menu,
/// and do what changing each asks. Asking for versions for small screens or
/// not, following stylesheets or not and keeping away from the blocklist or
/// not make the page on screen another page, which is fetched again.
/// Pictures turned off give their room to what the page says they show, and
/// turned on come as they would have. Another shade is drawn on the next
/// pass.
fn adopt(next: proto.settings.Web) void {
    const was = choices;
    choices = next;
    apply();
    if (next.mobile != was.mobile or next.styles != was.styles or next.ad_protection != was.ad_protection) return reload();
    if (next.scripts != was.scripts) return scriptsAgain(next.scripts);
    if (next.images != was.images) {
        if (!next.images) pictures.pause(gpa);
        view.relayout();
    }
    waitFor(.none);
}

/// Scripts turned off: what is on screen stays, and nothing runs on it any
/// more. Scripts turned on: the page's scripts run on the tree it was read
/// from, and it is read again, so what they make of it is what is drawn.
fn scriptsAgain(enabled: bool) void {
    if (!enabled) {
        if (in_page) |page| scripts.close(page);
        in_page = null;
        // Where a worker had them, it is let go: with scripts off, no worker
        // is started for a page at all (§9).
        scripts_host.stop(.scripts_off);
        waitFor(.none);
        return;
    }
    if (document != null) {
        // A page's scripts are the worker's to run: the reader opens none
        // of its own over the tree, so they are never run in both places at
        // once.
        startHost(&source);
        readAgain();
    }
    waitFor(.none);
}

/// Take the next step of whatever is on its way: the page, its stylesheets,
/// or once it is on screen, its pictures. True when there is something new
/// to draw.
fn step() bool {
    if (fetch.busy()) return settle(fetch.advance(gpa));
    if (reading != null) {
        nextSheet();
        return true;
    }
    switch (pictures.advance(gpa, &shown, view.pictureFrom())) {
        .wait => |wait| waitFor(wait),
        .settled => {
            view.relayout();
            waitFor(.none);
        },
        .idle => {
            rest();
            return false;
        },
    }
    return true;
}

/// Nothing to wait on but the settings: the window sleeps until something
/// happens.
fn rest() void {
    sleepOn(null);
    proto.app.retick(idleFor());
}

/// How long the window sleeps where there is nothing coming: until a script's
/// next timer is due, or for good where it set none.
fn idleFor() usize {
    const page = in_page orelse return IDLE_US;
    const ms = scripts.waits(page) orelse return IDLE_US;
    return @min(@as(usize, @intCast(@min(ms, std.math.maxInt(u32)))), IDLE_US / std.time.us_per_ms) * std.time.us_per_ms;
}

/// Sleep on the settings, and on `site` while a page is coming from one.
fn sleepOn(site: ?u32) void {
    wakes.clear();
    if (settings_changed) |event| wakes.append(event) catch unreachable;
    if (site) |handle| wakes.append(handle) catch unreachable;
    // The worker's end of the channel, so that what it says wakes the
    // reader instead of waiting to be looked for.
    if (scripts_host.handle()) |handle| wakes.append(handle) catch unreachable;
    proto.app.wakeOn(wakes.slice());
}

/// Wait on what the fetch waits on next, and act on its end: a page's or a
/// stylesheet's. True when there is something new to draw.
fn settle(wait: fetch_mod.Wait) bool {
    waitFor(wait);
    switch (wait) {
        // The step that blocks is also what a redirect is, which the address
        // says as it happens: a page's, and not a stylesheet's.
        .none => if (reading == null) address.setFromStart(fetch.address()),
        .site => {},
        .over => switch (fetch.state) {
            .idle => return false,
            .done => if (reading != null) sheetArrived() else arrive(),
            .failed => |why| if (reading != null) sheetArrived() else {
                detour = null;
                failed(why, fetch.host());
                fetch.cancel(gpa);
            },
            .connecting, .receiving => unreachable,
        },
    }
    return true;
}

/// Wait on what a fetch waits on next: for the step that blocks, the next
/// chance, once this pass has said what it is about to do; for the site, its
/// news, with a look every so often for one gone quiet; for nothing, nothing.
fn waitFor(wait: fetch_mod.Wait) void {
    switch (wait) {
        .none => {
            sleepOn(null);
            proto.app.retick(SOON_US);
        },
        .site => |handle| {
            sleepOn(handle);
            proto.app.retick(WATCH_US);
        },
        .over => rest(),
    }
}

/// The page is here: read it, or go on to the version for small screens it
/// names. The connection it came on stays where its stylesheets are to come
/// on it.
fn arrive() void {
    const final = fetch.address();
    address.setFromStart(final);
    if (history.current()) |entry| _ = entry.address.set(final);

    arrived = .{
        .bytes = fetch.received(),
        .us = sys.clockMicros() -| fetch.started_us,
        .status = fetch.response.status,
    };

    const base = url.parse(final) orelse {
        failed(error.NotAnAddress, final);
        return fetch.cancel(gpa);
    };
    landed(base);
    const said = fetch.response.contentType();
    const body = fetch.body.bytes;
    fetch.body.bytes = .empty;
    const next = take(body, base, kindOf(said, final), charset.fromContentType(said));
    if (reading != null) fetch.release(gpa) else fetch.cancel(gpa);
    // The address the page came from is still the fetch's own until the
    // next is begun, which going on copies it before doing.
    if (next) |mobile| goMobile(mobile.slice(), base.host);
}

/// A file on this machine, read whole.
fn openFile(where: url.Url) void {
    const path = where.file();
    const bytes = file.readAlloc(gpa, path, fetch_mod.PAGE_MAX) catch |err| return failed(err, path);
    arrived = .{ .bytes = bytes.len };
    if (take(.fromOwnedSlice(bytes), where, kindOf(null, path), null)) |next| goMobile(next.slice(), where.host);
}

/// Take a page that has arrived, whose bytes it takes, from a site or from
/// a file. Plain text is a page at once. Markup is parsed, and read into
/// words once its stylesheets are here. What comes back is where to go on
/// to instead, where the page names a version for small screens the
/// settings ask for.
fn take(body: std.ArrayList(u8), base: url.Url, kind: Kind, declared: ?charset.Charset) ?url.Address {
    var bytes = body;
    switch (kind) {
        .other => |media_type| {
            defer bytes.deinit(gpa);
            failed(error.NotAPage, media_type);
            return null;
        },
        .plain => {
            defer bytes.deinit(gpa);
            var fresh: Page = .{};
            plainInto(bytes.items, declared, &fresh) catch |err| {
                fresh.deinit(gpa);
                failed(err, base.host);
                return null;
            };
            present(&fresh, .{});
            return null;
        },
        .markup => {},
    }

    var from = sourceOf(bytes, base, declared);
    var tree = Tree.parse(gpa, &from) catch |err| {
        from.deinit(gpa);
        failed(err, base.host);
        return null;
    };
    if (mobileOf(&tree, base, versionWindow())) |next| {
        tree.close();
        from.deinit(gpa);
        return next;
    }
    reading = .{ .source = from, .tree = tree };
    // A page whose list of stylesheets could not be kept is read with those
    // that were.
    tree.sheets(gpa, base, &reading.?.links) catch {};
    // Its stylesheets from the next chance on.
    waitFor(.none);
    return null;
}

/// Go on to the page's next stylesheet: read one from this machine at once,
/// or fetch one from a site. With none left, read the page.
fn nextSheet() void {
    const r = if (reading) |*open| open else return;
    while (r.links.next()) |link| {
        const where = url.parse(link.address) orelse continue;
        if (where.scheme == .file) {
            const text = readSheet(where) orelse continue;
            r.links.took(text.len);
            r.source.keep(gpa, text, link.media);
            continue;
        }
        r.asked = link.media;
        fetch.asking.wanted = .style;
        fetch.begin(gpa, link.address);
        waitFor(.none);
        return;
    }
    fetch.cancel(gpa);
    fetch.asking.wanted = .page;
    finish();
}

/// A stylesheet is here, or is not coming: kept where it came as one, and
/// on to the next.
fn sheetArrived() void {
    const r = if (reading) |*open| open else return;
    if (fetch.state == .done and isStyle(&fetch.response)) {
        if (fetch.body.bytes.toOwnedSlice(gpa)) |text| {
            r.links.took(text.len);
            r.source.keep(gpa, text, r.asked);
        } else |_| {}
    }
    fetch.release(gpa);
    nextSheet();
}

/// Read the page being read into words, with what of its stylesheets came,
/// as it reads in the window, and put it on screen.
fn finish() void {
    const r = if (reading) |*open| open else return;
    // The tree is kept rather than closed with the reading: it is what a
    // script works on, and what the page is read from again.
    var tree = r.tree;
    defer {
        r.links.deinit(gpa);
        reading = null;
    }
    var fresh: Page = .{};
    forget();
    // A page's scripts run before it is read, so that what they change is
    // what is read, which is the order a browser has them in. Where the
    // setting says no script runs, the page reads as it was written.
    // Otherwise they are the worker's, and it is given the page and left to
    // run them: the reader keeps the page, the network, the cookies and the
    // window, and the worker keeps what a page can corrupt. The reader
    // opens no scripts of its own over the tree it is about to read.
    tree.read(gpa, &r.source, window, &fresh) catch |err| {
        fresh.deinit(gpa);
        tree.close();
        r.source.deinit(gpa);
        return failed(err, if (url.parse(r.source.base.slice())) |base| base.host else "");
    };
    document = tree;
    // `forget` above let go of the page this one replaces. `present` would
    // call it again through `replace`, immediately closing the context just
    // opened over `tree`; that made scripts run once and then disappear before
    // a timer, a redirect, or a script-sent form could happen. Keep this tree
    // and its context together while the page stays on screen.
    source.deinit(gpa);
    source = r.source;
    // The page is on screen and its source is the reader's: now it can be
    // given away. One worker per committed navigation, the one before it
    // killed as this one starts (§6).
    if (choices.scripts) startHost(&source);
    read_for = window;
    showPage(&fresh);
    focus_next = .page;
}

/// Give the page on screen to the host's worker.
///
/// A page the worker cannot be given is a page whose scripts will not run,
/// and is marked as one rather than tried again: a worker that dies on start
/// is not started in a loop (§7). The page on screen is left exactly as the
/// reader read it, which is the whole point.
fn startHost(from: *const Source) void {
    var sheets: worker_proto.Sheets = .{};
    for (from.sheets.items) |sheet| sheets.add(sheet.text) catch break;
    scripts_host.begin(.{
        .address = from.base.slice(),
        .agent = http.USER_AGENT,
        .markup = from.bytes.items,
        .charset = if (from.declared) |it| @tagName(it) else "",
        .sheets = sheets,
    }) catch |err| {
        // What the host could not do is worth having said somewhere a person
        // can look; the status line says the rest of it.
        ulib.log.note("worker", switch (err) {
            error.Refused => "its worker would not start",
            error.Gone => "its worker went as it was being given the page",
            error.TooLarge => "the page is too long to give its worker",
        });
    };
}

/// Let go of the tree the page on screen was read from, and of the script
/// running on it: a page gone from the screen takes both with it, and a node
/// a script was given is nothing once its tree has gone.
fn forget() void {
    if (in_page) |page| scripts.close(page);
    in_page = null;
    if (document) |*tree| tree.close();
    document = null;
}

/// Read the page on screen again from its tree, at the place it was left:
/// what a script has changed is read as the page says it now.
fn readAgain() void {
    const tree = &(document orelse return);
    var fresh: Page = .{};
    tree.read(gpa, &source, window, &fresh) catch return;
    pending_scroll = view.scroll;
    showPage(&fresh);
    title_stale = true;
}

/// Let go of a page still being read, for another that is to be gone to.
fn abandon() void {
    const r = if (reading) |*open| open else return;
    r.deinit();
    r.source.deinit(gpa);
    reading = null;
    fetch.asking.wanted = .page;
}

/// Fetch a page a script asks for, there and then: the line after the one
/// asking often wants the answer, and the reader has nowhere to keep a
/// question open. Blocked on the site, as a stylesheet from one is.
fn fetchForScript(asked: []const u8) ?[]u8 {
    // `src="/site.js"` and `fetch("next.json")` are relative to the page,
    // as a link is. Scripts used to be the one request path that gave those
    // words to the URL parser raw and consequently fetched neither.
    var resolved: [url.ADDRESS_MAX]u8 = undefined;
    const target = if (url.parse(asked) != null) asked else base: {
        const current = if (source.base.slice().len > 0) source.base.slice() else text_base.slice();
        const page = url.parse(current) orelse return null;
        break :base url.resolve(page, asked, &resolved) orelse return null;
    };
    const where = url.parse(target) orelse return null;
    if (where.scheme == .file) {
        return file.readAlloc(gpa, where.file(), fetch_mod.PAGE_MAX) catch null;
    }
    script_fetch.asking.wanted = .page;
    script_fetch.asking.mobile = choices.mobile;
    script_fetch.asking.shade = view.shade;
    script_fetch.asking.cookies = cookiesFrom(target);
    script_fetch.response_hook = &takeResponseCookies;
    script_fetch.cookies_for = &cookiesFrom;
    script_fetch.blocklist = keptFrom();
    defer script_fetch.release(gpa);
    script_fetch.begin(gpa, target);
    while (true) switch (script_fetch.advance(gpa)) {
        .none => {},
        .site => |handle| sys.eventWait(handle, WATCH_US) catch {},
        .over => break,
    };
    if (script_fetch.state != .done) return null;
    return script_fetch.body.bytes.toOwnedSlice(gpa) catch null;
}

/// A stylesheet from this machine, read whole.
fn readSheet(where: url.Url) ?[]u8 {
    return file.readAlloc(gpa, where.file(), fetch_mod.SHEET_MAX) catch null;
}

/// Whether an answer is a stylesheet: one that worked, of the kind a
/// stylesheet is or of no kind said.
fn isStyle(response: *const http.Response) bool {
    if (response.status < 200 or response.status >= 300) return false;
    const said = response.contentType() orelse return true;
    return std.ascii.eqlIgnoreCase(http.mediaOf(said), "text/css");
}

/// A page's markup as it came, taking `bytes`.
fn sourceOf(bytes: std.ArrayList(u8), base: url.Url, declared: ?charset.Charset) Source {
    var from = Source{ .bytes = bytes, .declared = declared, .styled = choices.styles };
    var buf: [url.ADDRESS_MAX]u8 = undefined;
    _ = from.base.set(std.fmt.bufPrint(&buf, "{f}", .{base}) catch "");
    return from;
}

/// What a body is, from what the site said it was, or from a file's name.
const Kind = union(enum) {
    markup,
    plain,
    /// Something else, which says what.
    other: []const u8,
};

const media_kinds = std.StaticStringMapWithEql(Kind, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ "text/html", Kind.markup },
    .{ "application/xhtml+xml", Kind.markup },
    .{ "text/plain", Kind.plain },
});

fn kindOf(content_type: ?[]const u8, name: []const u8) Kind {
    const said = content_type orelse {
        // Nothing said: a file's own name, and otherwise markup, which is
        // what a page that says nothing about itself almost always is.
        inline for (.{ ".txt", ".md", ".log" }) |plain| {
            if (std.ascii.endsWithIgnoreCase(name, plain)) return .plain;
        }
        return .markup;
    };
    const media_type = http.mediaOf(said);
    return media_kinds.get(media_type) orelse .{ .other = media_type };
}

/// The window a page's versions are chosen for: as wide as the column the
/// page is set in, which is what its words have however wide the window is,
/// and as tall as the window. With no window, as the shell has none, a
/// column the measure wide and as tall.
fn versionWindow() media.Screen {
    const measure: f32 = @floatFromInt(view_mod.MEASURE);
    const in = window orelse return .{ .width = measure, .height = measure };
    return .{ .width = @floatFromInt(view_mod.measureIn(@intFromFloat(in.width))), .height = in.height, .scale = in.scale };
}

/// Where to go on to instead of the page parsed as `tree`: the version it
/// names for a window like `screen`, where the settings ask for versions for
/// small screens, none has been gone on to already for this place, the site
/// has not sent the reader back from its version before, and the page is not
/// that version itself.
fn mobileOf(tree: *const Tree, base: url.Url, screen: media.Screen) ?url.Address {
    if (!choices.mobile or followed_mobile or refusedBy(base.host)) return null;
    var buf: [url.ADDRESS_MAX]u8 = undefined;
    const named = tree.versionFor(base, screen, &buf) orelse return null;
    var own: [url.ADDRESS_MAX]u8 = undefined;
    const here = std.fmt.bufPrint(&own, "{f}", .{base}) catch return null;
    if (std.mem.eql(u8, here, named)) return null;
    var next: url.Address = .{};
    return if (next.set(named)) next else null;
}

/// Why what arrived could not be read as a page.
const ReadError = source_mod.Error || error{
    /// It is something other than a page.
    NotAPage,
};

/// Plain text as a page: one preformatted block in the monospaced face.
fn plainInto(bytes: []const u8, declared: ?charset.Charset, page: *Page) ReadError!void {
    // The page reads UTF-8 and nothing else. The encoding is kept all the
    // same: a form answers in it.
    const encoding = charset.sniff(declared, bytes);
    const text = try charset.utf8Of(gpa, bytes, encoding);
    defer text.deinit(gpa);
    page.encoding = encoding;

    var builder = page_mod.Builder{ .gpa = gpa, .page = page };
    try builder.boundary(.{ .kind = .preformatted });
    builder.look.face = .mono;
    try builder.words(text.bytes());
    try builder.finish();
}

/// Put a page that has been read on screen, and give the keyboard to it.
fn present(fresh: *Page, from: Source) void {
    replace(fresh, from);
    focus_next = .page;
}

/// Put `fresh` on screen, read from `from`, which takes the place of the
/// source of the page it replaces.
fn replace(fresh: *Page, from: Source) void {
    forget();
    source.deinit(gpa);
    source = from;
    read_for = window;
    showPage(fresh);
}

/// Read the page on screen again, in the window it now reads differently
/// in, at the place it was left.
fn reread() void {
    read_for = window;
    var fresh: Page = .{};
    source.read(gpa, window, &fresh) catch {
        fresh.deinit(gpa);
        return;
    };
    pending_scroll = view.scroll;
    showPage(&fresh);
}

fn showPage(fresh: *Page) void {
    shown.deinit(gpa);
    shown = fresh.*;
    view.show(gpa, &shown, pending_scroll);
    pending_scroll = 0;
    title_stale = true;
    // Its pictures from the next chance on, once its words are drawn.
    pictures.show(gpa, &shown, .{
        .widest = widest(),
        .scale = @intCast(eui.theme.textScale()),
        .ground = view.ground(),
    });
    waitFor(.none);
}

/// The widest a picture is drawn: the widest the column is, at the size the
/// interface is drawn.
fn widest() u16 {
    return @intCast(view_mod.MEASURE * eui.theme.textScale());
}

/// The window a page is drawn in, as a stylesheet asks about it: in the
/// page's own pixels, which the interface draws at its own scale, and in the
/// shade pages are drawn in, which a stylesheet for either reads.
fn windowOf(area: Rect) media.Screen {
    const scale = eui.theme.textScale();
    return .{
        .width = @floatFromInt(@divTrunc(area.w, scale)),
        .height = @floatFromInt(@divTrunc(area.h, scale)),
        .scale = @floatFromInt(scale),
        .shade = view.shade,
    };
}

/// A page saying why the one asked for is not here.
fn problem(heading: []const u8, detail: []const u8) void {
    var fresh: Page = .{};
    var builder = page_mod.Builder{ .gpa = gpa, .page = &fresh };
    build: {
        builder.boundary(.{ .kind = .heading }) catch break :build;
        builder.look.face = .heading;
        builder.words(heading) catch break :build;
        builder.look.face = .body;
        builder.boundary(.{}) catch break :build;
        builder.words(detail) catch break :build;
        builder.finish() catch break :build;
    }
    arrived = null;
    replace(&fresh, .{});
}

// ---------------------------------------------------------------------------
// What went wrong
// ---------------------------------------------------------------------------

/// Every way the reader can fail to show what was asked for.
const Failure = fetch_mod.Failure || file.AllocError || ReadError || error{
    NotAnAddress,
    /// A form whose answers come to more than this reader sends.
    LongForm,
};

/// What a failure is called: a heading and a sentence for the page that says
/// so, and the few words a shell line has room for. One table, so that the
/// window and the shell never say two different things about one failure.
const Told = struct { heading: []const u8, detail: []const u8, word: []const u8 };

/// `subject` is what the failure is about: the site, the file, or what was
/// typed. The sentences that name it are written into `buf`.
fn told(why: Failure, subject: []const u8, buf: []u8) Told {
    return switch (why) {
        error.NotAnAddress, error.BadAddress => .{
            .heading = "That is not an address",
            .detail = "An address is a site's name, like example.org, a whole address beginning with http:// or https://, or a file on this machine.",
            .word = "not an address",
        },
        error.NoName => .{
            .heading = "Nothing answers to that name",
            .detail = sentence(buf, "{s} is not a name the network knows. It may be misspelt, or this machine may not be connected.", .{subject}),
            .word = "no such name",
        },
        error.Unreachable => .{
            .heading = "The site could not be reached",
            .detail = sentence(buf, "{s} did not answer. It may be down, or not listening where it was asked.", .{subject}),
            .word = "could not reach it",
        },
        error.Refused => .{
            .heading = "No shared way to encrypt this",
            .detail = sentence(buf, "{s} and this reader could not agree on a sealed connection ({s}), so nothing was sent.", .{ subject, ulib.wire.refusal() }),
            .word = "the sealed connection was refused",
        },
        error.NoClock => .{
            .heading = "The clock is not set",
            .detail = "A sealed page cannot be read until it is: a certificate's dates mean nothing without it.",
            .word = "the clock is not set",
        },
        error.NoAuthorities => .{
            .heading = "The certificate authorities could not be read",
            .detail = "They are kept in " ++ ulib.wire.AUTHORITIES ++ ", and a sealed page cannot be checked without them.",
            .word = "the certificate authorities could not be read",
        },
        error.NoRandomness => .{
            .heading = "Not enough randomness yet",
            .detail = "The machine has not gathered enough to seal a connection with. Try again in a moment.",
            .word = "not enough randomness to seal with",
        },
        error.HeadTooLong, error.Malformed => .{
            .heading = "That was not a page",
            .detail = sentence(buf, "{s} answered with something that is not HTTP.", .{subject}),
            .word = "not HTTP",
        },
        error.TooLarge, error.TooBig => .{
            .heading = "This is too large",
            .detail = std.fmt.comptimePrint("It is over {d} MB, which is more than this reader reads.", .{fetch_mod.PAGE_MAX / (1024 * 1024)}),
            .word = "larger than this reads",
        },
        error.Truncated => .{
            .heading = "The page was cut short",
            .detail = "The connection ended before all of it arrived.",
            .word = "cut short",
        },
        error.Unanswered => .{
            .heading = "The site did not answer",
            .detail = sentence(buf, "{s} closed the connection without sending anything back.", .{subject}),
            .word = "closed without answering",
        },
        error.Blocked => .{
            .heading = "This site is kept from",
            .detail = sentence(buf, "{s} is on the reader's blocklist: the sites that serve ads, and those that count and follow the people reading. Ad protection, in the menu at the end of the strip, turns the list off.", .{subject}),
            .word = "on the blocklist",
        },
        error.RedirectLoop => .{
            .heading = "Sent round in circles",
            .detail = sentence(buf, "{s} kept sending the request on somewhere else.", .{subject}),
            .word = "sent round in circles",
        },
        error.Stalled => .{
            .heading = "The site stopped answering",
            .detail = std.fmt.comptimePrint("Nothing arrived for {d} seconds, so the reader gave up waiting.", .{fetch_mod.STALL_US / std.time.us_per_s}),
            .word = "stopped answering",
        },
        error.OutOfMemory => .{
            .heading = "Not enough memory",
            .detail = "This needs more memory than the machine has free.",
            .word = "not enough memory",
        },
        error.NoFile => .{ .heading = "There is no such file", .detail = subject, .word = "no such file" },
        error.Unreadable => .{ .heading = "This file could not be read", .detail = subject, .word = "cannot read it" },
        error.Unparsable => .{
            .heading = "This page could not be read",
            .detail = "The parser would not take it.",
            .word = "the parser would not take it",
        },
        error.NotAPage => .{ .heading = "This is not a page", .detail = subject, .word = "not a page" },
        error.LongForm => .{
            .heading = "This form sends too much",
            .detail = std.fmt.comptimePrint("Its answers come to more than {d} KB, which is more than this reader sends. One that sends a file, or pages of words, is such a form.", .{ANSWERS_MAX / 1024}),
            .word = "the form sends too much",
        },
    };
}

/// A sentence naming a subject, in `buf`; the subject alone where the
/// sentence would not fit.
fn sentence(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch args[0];
}

/// A page saying why the one asked for is not here.
fn failed(why: Failure, subject: []const u8) void {
    var buf: [url.ADDRESS_MAX + 256]u8 = undefined;
    const said = told(why, subject, &buf);
    problem(said.heading, said.detail);
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

fn draw() void {
    if (title_stale) {
        title_stale = false;
        const title = if (shown.title.items.len > 0) shown.title.items else "web";
        proto.app.connection.setTitle(proto.app.window, title) catch {};
    }

    const surface = ctx.surface;
    const area = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };

    // One strip, not two. A menu bar above a toolbar would cost sixty of the
    // rows a window gets on this panel, so the way back, the way forward and
    // the address share one strip.
    const parts = eui.chrome.split(area, .{ .top = true, .bottom = true });
    const bar = Strip.of(parts.top);

    // The window the page is drawn in, which is what its stylesheets' media
    // queries ask about: a page read for another reads again where it would
    // read differently, and is only laid out again where it would not.
    // The shade is put into effect first, being one of the things a page is
    // read for: where it is the interface's, the interface can have changed
    // under a window that is open.
    inShade(pageShade());
    window = windowOf(parts.body);
    if (!std.meta.eql(read_for, window)) {
        if (source.readsAlike(read_for, window)) read_for = window else reread();
    }

    // Before anything is drawn, so that the control losing the keyboard and
    // the one gaining it both paint on this pass.
    if (focus_next) |where| {
        switch (where) {
            .field => {
                address.selectAll();
                ctx.focusAt(bar.field);
            },
            .page => ctx.focusAt(parts.body),
        }
        focus_next = null;
    }

    strip(parts.top, bar);
    if (view.run(gpa, ctx, parts.body, &pictures)) |act| switch (act) {
        .follow => |link| follow(link),
        .submit => |by| submit(by),
    };
    status(parts.bottom, parts.body);
    // Last, so that it stands over the page it hangs over.
    runMenu(bar.menu);
}

/// Send a form's answers where it says: in the address, as its query, for a
/// form that asks by GET, as a search does, and in the body of a POST for one
/// that asks by POST, as logging in and ordering are done.
fn submit(sent: view_mod.Submit) void {
    const form = shown.forms.items[sent.form];
    const action = shown.string(form.action);
    switch (form.method) {
        // In the address, as its query, which is how a search sends them.
        .get => {
            var buf: [url.ADDRESS_MAX]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            writeQuery(&w, sent, action) catch return failed(error.BadAddress, action);
            go(w.buffered());
        },
        // In the body of a request, which is how logging in and ordering are
        // done. Written where they are kept, since a POST sends them on the
        // step after this one, and keeps them besides, so that the page they
        // make can be fetched again by sending them again.
        .post => {
            sending = .{};
            if (!sending.at.set(action)) return failed(error.BadAddress, action);
            var w: std.Io.Writer = .fixed(&sending.answers);
            writeAnswers(&w, sent) catch return failed(error.LongForm, action);
            sending.len = w.buffered().len;
            send(action);
        },
    }
}

/// The form's address with its answers as the query, in place of any query
/// the address had.
fn writeQuery(w: *std.Io.Writer, sent: view_mod.Submit, action: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(action[0 .. std.mem.indexOfScalar(u8, action, '?') orelse action.len]);
    try w.writeByte('?');
    try writeAnswers(w, sent);
}

/// A form's answers, as a query: `name=value` for each control of it that has
/// a name and an answer, joined with `&`. Sent in the address by a form that
/// asks by GET, and in the body of a request by one that asks by POST.
fn writeAnswers(w: *std.Io.Writer, sent: view_mod.Submit) std.Io.Writer.Error!void {
    var first = true;
    for (shown.controls.items, 0..) |control, index| {
        if (control.form != sent.form) continue;
        const name = shown.string(control.name);
        if (name.len == 0) continue;
        const value = view.answer(&shown, @intCast(index), sent.by) orelse continue;
        try form_mod.writeAnswer(w, first, name, value, shown.encoding);
        first = false;
    }
}

/// Where the strip's parts go: the way back, the way forward, the key that
/// fetches again or stops, the way home, the key that opens the menu at the
/// far end, and the field in what is left between them.
const Strip = struct {
    back: Rect,
    forward: Rect,
    reload: Rect,
    home: Rect,
    field: Rect,
    menu: Rect,

    fn of(area: Rect) Strip {
        const t = eui.theme.current();
        const size = t.control_height;
        const y = area.y + @divTrunc(area.h - size, 2);
        // The keys a hair apart, and the field a gap after the last of them
        // and a gap before the menu's.
        const pitch = size + 2;
        const left = area.x + t.padding;
        const field_x = left + 3 * pitch + size + t.gap;
        const menu_x = area.right() - t.padding - size;
        return .{
            .back = square(left, y, size),
            .forward = square(left + pitch, y, size),
            .reload = square(left + 2 * pitch, y, size),
            .home = square(left + 3 * pitch, y, size),
            .field = .{ .x = field_x, .y = y, .w = menu_x - t.gap - field_x, .h = size },
            .menu = square(menu_x, y, size),
        };
    }

    fn square(x: i32, y: i32, side: i32) Rect {
        return .{ .x = x, .y = y, .w = side, .h = side };
    }
};

fn strip(area: Rect, at: Strip) void {
    if (ctx.tool(at.back, .back, history.canBack())) back();
    if (ctx.tool(at.forward, .forward, history.canForward())) forward();
    // One key, two jobs: while a page is coming it stops it, and otherwise
    // it fetches the page again.
    const loading = fetch.busy();
    if (ctx.tool(at.reload, if (loading) .cross else .reload, loading or !history.entries.isEmpty())) {
        if (loading) stop() else reload();
    }
    if (ctx.tool(at.home, .home, !choices.homepage.isEmpty())) home();
    if (address.run(ctx, at.field)) typed(address.slice());
    if (ctx.tool(at.menu, .menu, true)) openMenu(at.menu);

    rule(area);
}

// ---------------------------------------------------------------------------
// The menu
// ---------------------------------------------------------------------------

/// What the menu at the end of the strip holds, a row each: the settings a
/// person changes while reading, each of which `cfg` changes as well, and
/// making the page on screen the home page.
const Row = enum { mobile, pictures, styles, scripts, theme, ads, rule, home };

comptime {
    std.debug.assert(std.enums.values(Row).len <= eui.context_menu.MAX_ITEMS);
}

/// Open the menu under its key, at `at`.
fn openMenu(at: Rect) void {
    const entry = ctx.slotFor(at) orelse return;
    var rows: [std.enums.values(Row).len]eui.context_menu.Row = undefined;
    for (&rows, std.enums.values(Row)) |*row, which| row.* = rowOf(which);
    eui.context_menu.openAt(at.x, at.bottom(), ctx.indexOf(entry), &rows);
}

/// The menu, where its key at `at` opened it, and what it was asked to do.
/// Run last, so it stands over the page it hangs over.
fn runMenu(at: Rect) void {
    const entry = ctx.slotFor(at) orelse return;
    if (!eui.context_menu.openedBy(ctx.indexOf(entry))) return;
    switch (eui.context_menu.run(ctx) orelse return) {
        // A command: making the page on screen the home page.
        .row => |index| choose(@enumFromInt(index)),
        // A setting's value, picked out on the row that holds it.
        .value => |picked| set(@enumFromInt(picked.row), picked.at),
    }
}

/// A row of the menu as it reads now. A setting carries the values it may be,
/// which the menu draws as the toggle the rest of the system changes a
/// setting with; the one row that is not a setting is a command.
fn rowOf(row: Row) eui.context_menu.Row {
    return switch (row) {
        .mobile => .{ .setting = .{ .label = "Mobile pages", .values = ON_OFF, .at = atOf(choices.mobile) } },
        .pictures => .{ .setting = .{ .label = "Pictures", .values = ON_OFF, .at = atOf(choices.images) } },
        .styles => .{ .setting = .{ .label = "Page styles", .values = ON_OFF, .at = atOf(choices.styles) } },
        .scripts => .{ .setting = .{ .label = "Page scripts", .values = ON_OFF, .at = atOf(choices.scripts) } },
        .theme => .{ .setting = .{ .label = "Page theme", .values = &SHADES, .at = @intFromEnum(choices.theme) } },
        .ads => .{ .setting = .{ .label = "Ad protection", .values = ON_OFF, .at = atOf(choices.ad_protection) } },
        .rule => .rule,
        .home => .{ .command = homeRow() },
    };
}

/// The two values a setting that is either on or off has: what the menu
/// draws, off first.
const ON_OFF: []const []const u8 = &.{ "off", "on" };

/// The shades pages may be drawn in, as the menu names them: the type's own
/// tags, which are also the words a person reads, so one added to the type
/// turns up here without being written twice.
const SHADES = shades: {
    var named: [std.enums.values(proto.settings.Shade).len][]const u8 = undefined;
    for (std.enums.values(proto.settings.Shade), &named) |shade, *name| name.* = @tagName(shade);
    break :shades named;
};

/// Which of the two a setting that is either on or off is at.
fn atOf(on: bool) usize {
    return @intFromBool(on);
}

/// Making the page on screen the home page: not to be chosen where there is
/// no page, where it is the home page already, or where its address is
/// longer than the setting holds.
fn homeRow() eui.widget.MenuItem {
    const label = "Set as home page";
    const mark: eui.icon.Icon = .home;
    const here = onScreen() orelse return .{ .label = label, .kind = .disabled, .mark = mark };
    if (isHome(here)) return .{ .label = "This is the home page", .kind = .disabled, .mark = mark };
    if (proto.settings.Address.parse(here) == null) {
        return .{ .label = label, .kind = .disabled, .mark = mark, .detail = "too long" };
    }
    return .{ .label = label, .mark = mark };
}

/// Where the page on screen came from: none for a page the reader wrote
/// itself to say why another is not here.
fn onScreen() ?[]const u8 {
    if (arrived == null) return null;
    return (history.current() orelse return null).address.slice();
}

/// Whether `here` is where the home key goes.
fn isHome(here: []const u8) bool {
    var buf: [url.ADDRESS_MAX]u8 = undefined;
    const home_address = addressFrom(choices.homepage.slice(), &buf) orelse return false;
    return std.mem.eql(u8, home_address, here);
}

/// Do what a command of the menu says. The store keeps it and tells every
/// reader that is open; it is taken here at once all the same, so the menu
/// works where there is no store to keep it.
fn choose(row: Row) void {
    var next = switch (row) {
        .home => choices,
        else => return,
    };
    next.homepage = proto.settings.Address.parse(onScreen() orelse return) orelse return;
    proto.settings.save("web", next) catch {};
    adopt(next);
}

/// Put the setting on row `row` at the value `at`, of the values it may be.
/// The store keeps it and tells every reader that is open; it is taken here at
/// once all the same, so the menu works where there is no store to keep it.
fn set(row: Row, at: usize) void {
    var next = choices;
    switch (row) {
        .mobile => next.mobile = at != 0,
        .pictures => next.images = at != 0,
        .styles => next.styles = at != 0,
        .scripts => next.scripts = at != 0,
        .ads => next.ad_protection = at != 0,
        // The menu offers them in the order the type declares them, so the
        // one chosen is the one at that place.
        .theme => next.theme = std.enums.values(proto.settings.Shade)[@min(at, std.enums.values(proto.settings.Shade).len - 1)],
        .rule, .home => return,
    }
    proto.settings.save("web", next) catch {};
    adopt(next);
}

/// The rule under the strip, which is also how far a fetch has got. A page
/// arriving slowly is a state a person sits in, and the rule was there
/// already, so saying so costs no row.
fn rule(area: Rect) void {
    const t = eui.theme.current();
    const done = progress();
    if (!ctx.damaged and drawn_progress == done) return;
    drawn_progress = done;

    const band = Rect{ .x = area.x, .y = area.bottom() - 2, .w = area.w, .h = 2 };
    ctx.surface.fill(.{ .x = band.x, .y = band.y, .w = band.w, .h = 1 }, t.surface);
    ctx.surface.fill(.{ .x = band.x, .y = band.y + 1, .w = band.w, .h = 1 }, t.line);
    if (done > 0) {
        ctx.surface.fill(.{ .x = band.x, .y = band.y, .w = @divTrunc(band.w * done, 1000), .h = 2 }, t.accent);
    }
    ctx.addDamage(band);
}

/// How far along a fetch is, in thousandths: a sliver while the site is
/// being reached, the share of the body where the site said how long it
/// would be, and the same sliver where it did not.
fn progress() u16 {
    return switch (fetch.state) {
        .connecting => 30,
        .receiving => if (fetch.expected()) |total|
            @intCast(@max(30, @min(1000, fetch.received() * 1000 / @max(total, 1))))
        else
            30,
        .idle, .done, .failed => 0,
    };
}

fn status(area: Rect, body: Rect) void {
    var left_buf: [url.ADDRESS_MAX + 32]u8 = undefined;
    var right_buf: [48]u8 = undefined;
    var left = str.Builder{ .buf = &left_buf };
    var right = str.Builder{ .buf = &right_buf };

    if (view.hover) |link| {
        left.text(shown.address(link) orelse "");
    } else switch (fetch.state) {
        .connecting => {
            left.text("Reaching ");
            left.text(fetch.host());
        },
        .receiving => {
            left.text(if (reading != null) "Reading its styles from " else "Reading from ");
            left.text(fetch.host());
        },
        .idle, .done, .failed => left.text(if (shown.title.items.len > 0) shown.title.items else address.slice()),
    }

    switch (fetch.state) {
        .receiving => {
            right.bytes(fetch.received());
            if (fetch.expected()) |total| {
                right.text(" of ");
                right.bytes(std.math.cast(usize, total) orelse std.math.maxInt(usize));
            } else right.text(" so far");
        },
        .connecting => {},
        .idle, .done, .failed => if (pictures.fetching != null) {
            const tally = pictures.tally();
            right.print("picture {d} of {d}", .{ tally.settled + 1, tally.total });
        } else arrivedText(&right, body),
    }

    // How many of the page's scripts ran, which is the only way to tell a
    // reader that ran none from a page that had none: a site that sends its
    // no-scripts page to a reader with scripts looks exactly like one that
    // sends it to a reader without.
    var said: [96]u8 = undefined;
    const scripts_said: []const u8 = if (scripts_host.status() == .stopped)
        // §7: a worker that died took a page's scripts with it and nothing
        // else. What is on screen is the page as it was last read, and stays
        // readable, scrollable and followable.
        "scripts stopped"
    else if (in_page) |page| blk: {
        const ran = scripts.scriptsRan(page);
        const threw = scripts.scriptsThrew(page);
        break :blk if (scripts.errorLast(page)) |error_text|
            std.fmt.bufPrint(&said, "scripts {d}: {s}", .{ ran, error_text[0..@min(error_text.len, 72)] }) catch "scripts threw"
        else if (scripts.askedCount(page) > 0)
            std.fmt.bufPrint(&said, "scripts {d}, no {s} (+{d})", .{
                ran,
                scripts.askedLast(page) orelse "?",
                scripts.askedCount(page) - 1,
            }) catch "scripts"
        else if (threw > 0)
            std.fmt.bufPrint(&said, "scripts {d}, {d} threw", .{ ran, threw }) catch "scripts"
        else
            std.fmt.bufPrint(&said, "scripts {d}", .{ran}) catch "scripts";
    } else if (choices.scripts) said: {
        const because = scripts.whyNot();
        break :said if (because.len == 0) "scripts: none ran" else because;
    } else "scripts off";

    eui.statusbar.run(ctx, area, &.{
        .{ .text = left.done() },
        .{ .text = scripts_said, .width = 320 },
        .{ .text = right.done(), .width = 150 },
    });
}

/// What the page on screen cost to fetch, or how far down it the view is
/// once that is no longer news.
fn arrivedText(b: *str.Builder, body: Rect) void {
    const got = arrived orelse return;
    if (got.status) |code| {
        if (code >= 400) {
            b.text("the site said ");
            b.number(code);
            return;
        }
    }
    if (view.scroll > 0) {
        b.number(view.position(body));
        b.byte('%');
        return;
    }
    b.bytes(got.bytes);
    const us = got.us orelse return;
    b.print(" in {d}.{d} s", .{ us / std.time.us_per_s, us / 100_000 % 10 });
}

fn key(code: KeyCode, mods: Modifiers) bool {
    if (mods.alt and code == .left) {
        back();
    } else if (mods.alt and code == .right) {
        forward();
    } else if (mods.alt and code == .home) {
        home();
    } else if (code == .f5 or (mods.control and code == .r)) {
        reload();
    } else if (mods.control and code == .l) {
        focus_next = .field;
    } else if (code == .escape and fetch.busy()) {
        stop();
    } else if (code == .escape and pictures.busy()) {
        // Stopping with the page already here stops its pictures, which give
        // their room to what the page says they show.
        pictures.halt(gpa);
        view.relayout();
        rest();
    } else return false;
    return true;
}

// ---------------------------------------------------------------------------
// From the shell
// ---------------------------------------------------------------------------

/// `web -t`: the page's words on standard output, and nothing drawn. The
/// same page the window would show: gone on to the version for small screens
/// it names, where the settings ask for those. With no window to ask about,
/// its stylesheets' rules for windows of some sizes and not others are left
/// out.
fn printText(target: []const u8) noreturn {
    text_trace = true;
    var buf: [url.ADDRESS_MAX]u8 = undefined;
    const where_text = addressFrom(target, &buf) orelse fatal(target, error.NotAnAddress);

    var page: Page = .{};
    if (readInto(where_text, &page)) |next| {
        followed_mobile = true;
        _ = readInto(next.slice(), &page);
    }

    var text: std.Io.Writer.Allocating = .init(gpa);
    page_mod.writeText(&page, &text.writer) catch fatal(where_text, error.OutOfMemory);
    out.through(text.written());
    out.flush();
    sys.exit(0);
}

/// Read what is at `where_text` into `page`, from this machine or over the
/// network, stylesheets and all, saying what went wrong and stopping where
/// it cannot. What comes back is where to go on to instead, where the page
/// names a version for small screens that the settings ask for, and `page`
/// is then left as it was.
fn readInto(where_text: []const u8, page: *Page) ?url.Address {
    const where = url.parse(where_text) orelse fatal(where_text, error.NotAnAddress);
    if (where.scheme == .file) {
        const path = where.file();
        const bytes = file.readAlloc(gpa, path, fetch_mod.PAGE_MAX) catch |err| fatal(path, err);
        return readBody(.fromOwnedSlice(bytes), where, kindOf(null, path), null, page);
    }

    if (!fetchNow(where_text)) fatal(fetch.host(), fetch.state.failed);
    const final = url.parse(fetch.address()) orelse fatal(fetch.address(), error.NotAnAddress);
    const said = fetch.response.contentType();
    const body = fetch.body.bytes;
    fetch.body.bytes = .empty;
    return readBody(body, final, kindOf(said, fetch.address()), charset.fromContentType(said), page);
}

/// Read a page's `body`, which it takes, into `page`, as the shell reads
/// one: its stylesheets fetched as it waits for each.
fn readBody(body: std.ArrayList(u8), base: url.Url, kind: Kind, declared: ?charset.Charset, page: *Page) ?url.Address {
    var bytes = body;
    switch (kind) {
        .other => |media_type| fatal(media_type, error.NotAPage),
        .plain => {
            defer bytes.deinit(gpa);
            plainInto(bytes.items, declared, page) catch |err| fatal(base.host, err);
            return null;
        },
        .markup => {},
    }

    var from = sourceOf(bytes, base, declared);
    defer from.deinit(gpa);
    var tree = Tree.parse(gpa, &from) catch |err| fatal(base.host, err);
    defer tree.close();
    if (mobileOf(&tree, base, versionWindow())) |next| return next;

    // Its stylesheets, on the connection it came on, which the page's own
    // address goes with: from here on it names the stylesheet being asked
    // for.
    var links: css.Sheets = .{};
    defer links.deinit(gpa);
    tree.sheets(gpa, base, &links) catch {};
    fetch.release(gpa);
    defer fetch.cancel(gpa);
    while (links.next()) |link| {
        const text = sheetNow(link.address) orelse continue;
        links.took(text.len);
        from.keep(gpa, text, link.media);
    }
    // Text mode is the same browser without a window: scripts run over the
    // same tree, their errors go to the terminal, and a location change is a
    // redirect the caller can follow.
    text_base = from.base;
    text_redirect = null;
    if (scripts.open(tree.document, from.base.slice(), http.USER_AGENT, &fetchForScript, &textGo, &cookiesForScript, &setScriptCookie)) |script| {
        defer scripts.close(script);
        _ = scripts.loop(script);
        if (scripts.errorLast(script)) |error_text| out.fault("script", scripts.errorSource(script), error_text);
        if (text_redirect) |next| return next;
    }
    tree.read(gpa, &from, null, page) catch |err| fatal(from.base.slice(), err);
    return null;
}

/// A text-mode `location` change, resolved like one in a window but retained
/// for `readBody` rather than beginning a second, invisible fetch here.
fn textGo(where: []const u8) void {
    var resolved: [url.ADDRESS_MAX]u8 = undefined;
    const target = if (url.parse(where) != null) where else base: {
        const from = url.parse(text_base.slice()) orelse return;
        break :base url.resolve(from, where, &resolved) orelse return;
    };
    var next: url.Address = .{};
    if (next.set(target)) text_redirect = next;
}

/// A stylesheet's text, read from this machine or fetched as the shell
/// waits, or nothing where it did not come as one.
fn sheetNow(link_address: []const u8) ?[]u8 {
    const where = url.parse(link_address) orelse return null;
    if (where.scheme == .file) return readSheet(where);
    fetch.asking.wanted = .style;
    defer fetch.asking.wanted = .page;
    defer fetch.release(gpa);
    if (!fetchNow(link_address) or !isStyle(&fetch.response)) return null;
    return fetch.body.bytes.toOwnedSlice(gpa) catch null;
}

/// Fetch `target` as a shell waits for it: blocked on the site, woken by it
/// or once a second to notice one gone quiet. True where it arrived.
fn fetchNow(target: []const u8) bool {
    fetch.response_hook = &takeResponseCookies;
    fetch.redirect_hook = &traceRedirect;
    fetch.cookies_for = &cookiesFrom;
    fetch.begin(gpa, target);
    while (true) switch (fetch.advance(gpa)) {
        .none => {},
        .site => |handle| sys.eventWait(handle, WATCH_US) catch {},
        .over => break,
    };
    return fetch.state == .done;
}

/// A target-side trace for `web -t`: redirects are otherwise invisible until
/// the final loop limit, when the one useful fact is the chain that led there.
fn traceRedirect(from: []const u8, to: []const u8) void {
    out.text("redirect ");
    out.text(from);
    out.text(" -> ");
    out.text(to);
    out.text("\n");
}

/// Say what went wrong on a shell line, and stop.
fn fatal(subject: []const u8, why: Failure) noreturn {
    var buf: [url.ADDRESS_MAX + 256]u8 = undefined;
    out.fault("web", subject, told(why, subject, &buf).word);
    sys.exit(if (why == error.NotAnAddress) 2 else 1);
}
