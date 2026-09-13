//! web: a reader for pages.
//!
//! What `design/00-vibeee.md` settled on: a reader for simple pages rather
//! than a general browser. It asks a site for one page, reads the words out
//! of the markup, and sets them in this system's own faces in a column the
//! width a line reads best at. Of what a page's stylesheets say, it follows
//! what a column of text can show: what they hide, the colours of words and
//! of what they sit on, which way lines lean, and the boxes a page sets side
//! by side. A page's pictures come after its words, one at a time, what the
//! page says each one shows standing in for it until it is here.
//!
//! A page's scripts run in the reader, on the tree the page was read from,
//! under bounds: how much they may hold, how deep they may call, and how long
//! each may run before it is stopped. What they change is read again and
//! drawn. What they ask for from outside the page, a page fetched or a script
//! by its address, they are answered on a later pass, the way a stylesheet
//! comes; nothing a script does waits on the network. Where a script sends
//! the reader, the reader goes once the script has returned.
//!
//! The parts each have a file: `url` for where things are, `http` and
//! `fetch` for getting them, `cookie` for what sites set, `source` for a page
//! as it came and what it reads as, `lexbor`, `css`, `media` and `extract`
//! for reading markup and its stylesheets into a `page`, `dom` for what a
//! script sees of it and `storage` for what it puts by, `layout` for where
//! its words go, `pictures` for what it shows among them, `view` for the part
//! on screen, and `failure` for what is said when a page does not come. This
//! file is the window around them and the order they run in.
//!
//! A page's stylesheets and scripts are fetched after its markup, on the
//! connection it came on, and its words are read once they are here. Their
//! media queries are asked about the window the page is drawn in, so a
//! window that changes size reads the page again where they answer
//! differently.
//!
//! `web -t <address>` prints a page's words instead of opening a window: the
//! same pipeline, pumped by the shell until nothing more is on its way, so
//! whatever the window can read, the shell can too.
//!
//! Where it starts, whether it fetches pictures, whether it follows a page's
//! stylesheets and runs its scripts, whether it asks for the versions of
//! pages made for small screens, whether pages are drawn light or dark and
//! whether the blocklist is kept to are settings, in the `web` domain the
//! store keeps: `cfg web` lists them, the menu at the end of the strip
//! changes them and makes the page on screen the home page, and a window
//! that is open takes a change as it is made.
//!
//! Not part of the system. It is built into `home/bin/` and versioned on its
//! own.

const std = @import("std");
const eui = @import("eui");
const js = @import("js");
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
const dom = @import("dom.zig");
const failure = @import("failure.zig");
const fetch_mod = @import("fetch.zig");
const form_mod = @import("form.zig");
const http = @import("http.zig");
const links = @import("links.zig");
const media = @import("media.zig");
const page_mod = @import("page.zig");
const pictures_mod = @import("pictures.zig");
const source_mod = @import("source.zig");
const storage_mod = @import("storage.zig");
const url = @import("url.zig");
const view_mod = @import("view.zig");

// The routines lexbor's and QuickJS's C call by name.
comptime {
    _ = @import("clibc");
}

const ctx = &proto.app.ctx;
const gpa = heap.allocator;

const Rect = eui.Rect;
const KeyCode = eui.widget.KeyCode;
const Modifiers = eui.widget.Modifiers;
const Failure = failure.Failure;
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
/// How long the shell gives a page's scripts after the page is here, for
/// what they set to run soon and what they asked for.
const SETTLE_US: u64 = 3 * std.time.us_per_s;

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
/// The page on screen as a tree, kept while its scripts run on it: what they
/// change, the reader reads the page from again.
var document: ?Tree = null;
/// The scripts running on the page on screen, where any are.
var scripts: ?*dom.Document = null;
/// The window the page on screen was read for, and the one it is drawn in
/// now, as a stylesheet asks about a window. None before there is a window.
var read_for: ?media.Screen = null;
var window: ?media.Screen = null;
/// A page whose markup has come and whose stylesheets and scripts are still
/// coming.
var reading: ?Reading = null;
/// The page's fetch, which brings its stylesheets and scripts too.
var fetch: fetch_mod.Fetch = .{};
/// What a script asks for, fetched apart from the page's own, which may be
/// mid-page, and from the pictures', which may be mid-picture.
var script_fetch: fetch_mod.Fetch = .{};
/// Which of the scripts' asks that fetch is answering.
var current_ask: ?u32 = null;
/// The cookies sites set and scripts write, kept while the reader is open:
/// they belong to a site, and go with every request to it.
var jar: cookie_mod.Jar = .{};
/// What sites put by through their scripts, kept while the reader is open.
var store: storage_mod.Storage = .{};
/// The pictures of the page on screen, and the fetch that brings them.
var pictures: pictures_mod.Pictures = .{};
var history: History = .{};

/// The reader's settings as the store last had them, and the event that says
/// they changed, where the store is there to give one.
var choices: proto.settings.Web = .{};
var settings_changed: ?u32 = null;

/// What the window sleeps on besides its own events: the settings changing,
/// and each site something is coming from.
var wakes: Bounded(u32, 4) = .{};
/// How long it sleeps at most, as last planned.
var period_us: usize = IDLE_US;

/// Whether this is `web -t`, printing a page's words to the shell: no
/// window, no pictures, and a failure said on a line rather than as a page.
var shell = false;

/// How much of the rule under the strip was last painted, in thousandths.
var drawn_progress: ?u16 = null;
/// A page was put on screen while a pass was drawing, from what a control
/// on it did: the next pass is asked for at once, so that it is seen.
var repaint_wanted = false;
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

const Detour = struct { from: Host = .{}, to: Host = .{} };

/// The answers the form last sent had, and where they were sent. Kept so that
/// the page those answers made can be fetched again, which fetching a page
/// again, or going back to one and on again, asks for, by sending them again
/// rather than by asking for the empty form the site answers a GET with. One
/// form's answers, the last sent, being all a reader with one page on screen
/// needs.
var sending: Sending = .{};

const Sending = struct {
    /// Where they were sent: empty where no form has been sent yet.
    at: url.Address = .{},
    answers: [form_mod.ANSWERS_MAX]u8 = undefined,
    len: usize = 0,

    /// The answers, where they were sent to `target`.
    fn forTarget(self: *const Sending, target: []const u8) ?[]const u8 {
        if (self.at.isEmpty() or !std.mem.eql(u8, self.at.slice(), target)) return null;
        return self.answers[0..self.len];
    }

    /// Keep `answers` as what was sent to `target`. False where they are
    /// more than a form may send.
    fn keep(self: *Sending, target: []const u8, answers: []const u8) bool {
        self.* = .{};
        if (answers.len > self.answers.len or !self.at.set(target)) return false;
        @memcpy(self.answers[0..answers.len], answers);
        self.len = answers.len;
        return true;
    }
};

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
/// far, the tree its markup parsed into, and the stylesheets and scripts it
/// links to, fetched one after another.
const Reading = struct {
    source: Source,
    tree: Tree,
    sheets: css.Sheets = .{},
    scripts: dom.Scripts = .{},
    /// The link being fetched, and whether it is a stylesheet or a script.
    link: links.Link = .{ .address = "", .media = "" },
    fetching: enum { sheet, script } = .sheet,

    fn deinit(self: *Reading) void {
        self.tree.close(gpa);
        self.sheets.deinit(gpa);
        self.scripts.deinit(gpa);
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
    const first = env.arg(frame, 1);
    if (first) |flag| {
        if (std.mem.eql(u8, flag, "-t")) printText(env.arg(frame, 2) orelse usage());
    }

    address.init(.{ .hint = "an address, or a file on this machine" });
    view.show(gpa, &shown, 0);
    settings_changed = proto.settings.watch("web") catch null;
    if (first) |target| typed(target) else home();
    plan();

    proto.app.run("web", "web", 800, 480, .{
        .draw = draw,
        .key = key,
        .tick = tick,
        // The frame begins with what it is handed here, so a first page
        // already on its way is handed over as one.
        .tick_us = period_us,
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
        one.jar = &jar;
    }
    pictures.enabled = choices.images and !shell;
    inShade(pageShade());
}

/// The sites the reader keeps away from, while ad protection is on: those
/// that serve ads, and those that count and follow the people reading. None
/// where it is off, which is how it is turned off.
fn keptFrom() ?blocklist_mod.Blocklist {
    if (!choices.ad_protection) return null;
    return .{ .hashes = &blocklist_data.hashes };
}

/// The page's fetch, which brings its stylesheets and scripts too, its
/// pictures', and the one that answers its scripts.
fn fetches() [3]*fetch_mod.Fetch {
    return .{ &fetch, &pictures.fetch, &script_fetch };
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

/// Follow a link on the page on screen. The page's scripts are told of the
/// click first, and a script may refuse it, or send the reader somewhere of
/// its own.
fn follow(link: u16) void {
    if (link >= shown.links.items.len) return;
    const it = shown.links.items[link];
    if (scripts) |doc| {
        if (it.node) |node| {
            const prevented = dom.click(doc, @ptrCast(@alignCast(node)));
            if (afterScripts(doc) or prevented) return;
        }
    }
    switch (it.goes) {
        .elsewhere => go(shown.string(it.address)),
        .here => jump(shown.string(it.address)),
        .script => if (scripts) |doc| {
            dom.run(doc, shown.string(it.address));
            _ = afterScripts(doc);
        },
    }
}

/// Go to the place `name` marks on the page on screen, or to its top for a
/// name the page has no place for, which is what a bare `#` asks for.
fn jump(name: []const u8) void {
    const place = shown.placeOf(name);
    view.jumpTo(if (place) |found| .{ .run = found.run, .at = found.at } else null);
    if (history.current()) |entry| entry.scroll = view.scroll;
}

/// What the status line says a link goes to.
fn linkLabel(link: u16, buf: []u8) []const u8 {
    if (link >= shown.links.items.len) return "";
    const it = shown.links.items[link];
    return switch (it.goes) {
        .elsewhere => shown.string(it.address),
        .here => std.fmt.bufPrint(buf, "#{s}", .{shown.string(it.address)}) catch "",
        .script => "a script on this page",
    };
}

/// Go somewhere new, which the history remembers. What a form last sent is
/// forgotten: a page gone to by its address is the form itself, and not the
/// page the answers made last time.
fn go(where: []const u8) void {
    sending = .{};
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
/// history. The page on screen stays until the next is here, but its scripts
/// stop: a page being left is not one to keep running.
fn visit(target: []const u8) void {
    abandon();
    forget();
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
    fetch.asking.sent = if (sending.forTarget(target)) |answers| .{ .bytes = answers } else null;
    // The network is the page's while it comes: the pictures of the one on
    // screen wait.
    pictures.pause(gpa);
    fetch.begin(gpa, target);
    _ = settle(fetch.advance(gpa));
}

fn stop() void {
    fetch.cancel(gpa);
    if (reading != null) {
        // What of its stylesheets and scripts came is what it is read with.
        fetch.asking.wanted = .page;
        return finish();
    }
    if (history.current()) |entry| address.setFromStart(entry.address.slice());
    // The page on screen stays, and so do its pictures still to come.
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
// The loop
// ---------------------------------------------------------------------------

fn tick() bool {
    const drew = step() or repaint_wanted;
    repaint_wanted = false;
    plan();
    return drew;
}

fn woken(index: usize) bool {
    if (settings_changed != null and wakes.at(index) == settings_changed) {
        adopt(proto.settings.load("web"));
    } else {
        _ = step();
    }
    plan();
    // A piece arrived, which the status line counts, whatever else it did.
    return true;
}

/// Take the next step of whatever is on its way: the page, its stylesheets
/// and scripts, what its scripts asked for and set to run, and once it is on
/// screen, its pictures. True when there is something new to draw.
fn step() bool {
    if (fetch.busy()) return settle(fetch.advance(gpa));
    if (reading != null) {
        nextLink();
        return true;
    }
    if (stepScripts()) return true;
    return switch (pictures.advance(gpa, &shown, view.pictureFrom())) {
        .wait => true,
        .settled => {
            view.relayout();
            return true;
        },
        .idle => false,
    };
}

/// Say what the window sleeps on, and for how long, from everything that is
/// on its way: the next chance where a step that blocks is next, a site's
/// news while something is coming from one, the next timer a script set, and
/// nothing at all where nothing is coming.
fn plan() void {
    wakes.clear();
    if (settings_changed) |event| wakes.append(event) catch unreachable;
    var soon = false;
    var watching = false;
    for (fetches()) |one| switch (one.state) {
        .connecting => soon = true,
        .receiving => {
            if (one.handle()) |handle| wakes.append(handle) catch {};
            watching = true;
        },
        .idle, .done, .failed => {},
    };
    if (reading != null and !fetch.busy()) soon = true;
    if (pictures.fetching == null and pictures.busy()) soon = true;
    if (repaint_wanted) soon = true;
    var timer: ?usize = null;
    if (scripts) |doc| {
        if (!script_fetch.busy() and dom.asking(doc)) soon = true;
        if (dom.waits(doc)) |ms| timer = @as(usize, ms) * std.time.us_per_ms;
    }
    period_us = if (soon) SOON_US else if (watching) WATCH_US else IDLE_US;
    if (timer) |us| period_us = @min(period_us, @max(us, 1));
    proto.app.wakeOn(wakes.slice());
    proto.app.retick(period_us);
}

/// Act on what the page's fetch waits on next: a redirect as it happens,
/// and the end of a page's or a link's arriving. True when there is
/// something new to draw.
fn settle(wait: fetch_mod.Wait) bool {
    switch (wait) {
        // The step that blocks is also what a redirect is, which the address
        // says as it happens: a page's, and not a link's.
        .none => if (reading == null) address.setFromStart(fetch.address()),
        .site => {},
        .over => switch (fetch.state) {
            .idle => return false,
            .done => if (reading != null) linkArrived() else arrive(),
            .failed => |why| if (reading != null) linkArrived() else {
                detour = null;
                failed(why, fetch.host());
                fetch.cancel(gpa);
            },
            .connecting, .receiving => unreachable,
        },
    }
    return true;
}

/// Take `next` as the reader's settings, from the store or from the menu,
/// and do what changing each asks. Asking for versions for small screens or
/// not, following stylesheets or not, running scripts or not and keeping
/// away from the blocklist or not make the page on screen another page,
/// which is fetched again. Pictures turned off give their room to what the
/// page says they show, and turned on come as they would have. Another shade
/// is drawn on the next pass.
fn adopt(next: proto.settings.Web) void {
    const was = choices;
    choices = next;
    apply();
    if (next.mobile != was.mobile or next.styles != was.styles or next.scripts != was.scripts or next.ad_protection != was.ad_protection) return reload();
    if (next.images != was.images) {
        if (!next.images) pictures.pause(gpa);
        view.relayout();
    }
}

// ---------------------------------------------------------------------------
// A page arriving
// ---------------------------------------------------------------------------

/// The page is here: read it, or go on to the version for small screens it
/// names. The connection it came on stays where its stylesheets and scripts
/// are to come on it.
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
    const said_kind = fetch.response.contentType();
    const body = fetch.body.bytes;
    fetch.body.bytes = .empty;
    const next = take(body, base, kindOf(said_kind, final), charset.fromContentType(said_kind));
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
/// words once its stylesheets and scripts are here. What comes back is where
/// to go on to instead, where the page names a version for small screens the
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
        tree.close(gpa);
        from.deinit(gpa);
        return next;
    }
    reading = .{ .source = from, .tree = tree };
    const r = &reading.?;
    // A page whose list of links could not be kept is read with those that
    // were.
    tree.sheets(gpa, base, &r.sheets) catch {};
    if (choices.scripts) tree.scripts(gpa, base, &r.scripts) catch {};
    return null;
}

/// Go on to the page's next link: read one from this machine at once, or
/// fetch one from a site. Its stylesheets first, then its scripts. With none
/// left, read the page.
fn nextLink() void {
    const r = if (reading) |*open| open else return;
    while (r.sheets.next()) |link| {
        if (readLink(link, fetch_mod.SHEET_MAX)) |text| {
            r.sheets.took(text.len);
            r.source.keep(gpa, text, link.media);
            continue;
        }
        r.link = link;
        r.fetching = .sheet;
        fetch.asking.wanted = .style;
        fetch.begin(gpa, link.address);
        return;
    }
    while (r.scripts.next()) |link| {
        if (readLink(link, fetch_mod.SCRIPT_MAX)) |text| {
            r.scripts.took(text.len);
            r.source.keepScript(gpa, link.address, text);
            continue;
        }
        r.link = link;
        r.fetching = .script;
        fetch.asking.wanted = .script;
        fetch.begin(gpa, link.address);
        return;
    }
    fetch.cancel(gpa);
    fetch.asking.wanted = .page;
    finish();
}

/// A link's text where it is a file on this machine, read whole; nothing
/// where it is on a site, or a file that could not be read.
fn readLink(link: links.Link, most: usize) ?[]u8 {
    const where = url.parse(link.address) orelse return null;
    if (where.scheme != .file) return null;
    return file.readAlloc(gpa, where.file(), most) catch null;
}

/// A link is here, or is not coming: kept where it came as what it is, and
/// on to the next.
fn linkArrived() void {
    const r = if (reading) |*open| open else return;
    if (fetch.state == .done) {
        const came = switch (r.fetching) {
            .sheet => isStyle(&fetch.response),
            .script => fetch.response.status / 100 == 2,
        };
        if (came) {
            if (fetch.body.bytes.toOwnedSlice(gpa)) |text| switch (r.fetching) {
                .sheet => {
                    r.sheets.took(text.len);
                    r.source.keep(gpa, text, r.link.media);
                },
                .script => {
                    r.scripts.took(text.len);
                    r.source.keepScript(gpa, r.link.address, text);
                },
            } else |_| {}
        }
    }
    fetch.release(gpa);
    nextLink();
}

/// Read the page being read into words, with what of its stylesheets came,
/// as it reads in the window, run its scripts on it where the settings say,
/// and put it on screen.
fn finish() void {
    const r = if (reading) |*open| open else return;
    var tree = r.tree;
    var from = r.source;
    defer {
        r.sheets.deinit(gpa);
        r.scripts.deinit(gpa);
        reading = null;
    }
    const base = url.parse(from.base.slice()) orelse {
        tree.close(gpa);
        from.deinit(gpa);
        return failed(error.NotAnAddress, from.base.slice());
    };
    tree.style(gpa, &from, window);
    // The tree is the page's from here on, and its scripts point into it.
    document = tree;
    const held = &document.?;

    // A page's scripts run before it is read, so that what they change is
    // what is read, which is the order a browser has them in.
    const doc: ?*dom.Document = if (choices.scripts) opened: {
        const engine = machine() orelse break :opened null;
        break :opened dom.open(engine, held.document, &held.rules, from.base.slice(), hostOf());
    } else null;
    if (doc) |it| dom.load(it, from.scripts.items);

    var fresh: Page = .{};
    held.read(gpa, &from, window, &fresh) catch |err| {
        fresh.deinit(gpa);
        if (doc) |it| dom.close(it);
        held.close(gpa);
        document = null;
        from.deinit(gpa);
        return failed(err, base.host);
    };
    source.deinit(gpa);
    source = from;
    scripts = doc;
    read_for = window;
    showPage(&fresh);
    focus_next = .page;
    if (doc) |it| _ = afterScripts(it);
}

/// The engine the page's scripts run in, started the first time a page wants
/// one and kept.
fn machine() ?*js.Machine {
    return js.start(&sys.clockMicros, &said);
}

/// What a script says out loud, and what the document could not give it: to
/// the system's log, or to the shell's failure stream where the shell is
/// printing the page.
fn said(text: []const u8) void {
    if (shell) {
        out.trouble(text);
        out.trouble("\n");
    } else {
        ulib.log.note("scripts", text);
    }
}

/// What a page's scripts get of the reader around them.
fn hostOf() dom.Host {
    return .{
        .gpa = gpa,
        .jar = &jar,
        .store = &store,
        .screen = window,
        .user_agent = http.USER_AGENT,
    };
}

/// Let go of the tree the page on screen was read from, and of the scripts
/// running on it: a page gone from the screen takes both with it, and a node
/// a script was given is nothing once its tree has gone.
fn forget() void {
    if (scripts) |doc| dom.close(doc);
    scripts = null;
    if (document) |*tree| tree.close(gpa);
    document = null;
    script_fetch.cancel(gpa);
    current_ask = null;
}

/// Read the page on screen again from its tree, at the place it was left:
/// what a script has changed is read as the page says it now.
fn readAgain() void {
    const tree = &(document orelse return);
    var fresh: Page = .{};
    tree.read(gpa, &source, window, &fresh) catch {
        fresh.deinit(gpa);
        return;
    };
    pending_scroll = view.scroll;
    showPage(&fresh);
}

/// Let go of a page still being read, for another that is to be gone to.
fn abandon() void {
    const r = if (reading) |*open| open else return;
    r.deinit();
    r.source.deinit(gpa);
    reading = null;
    fetch.asking.wanted = .page;
}

/// Whether an answer is a stylesheet: one that worked, of the kind a
/// stylesheet is or of no kind said.
fn isStyle(response: *const http.Response) bool {
    if (response.status < 200 or response.status >= 300) return false;
    const said_kind = response.contentType() orelse return true;
    return std.ascii.eqlIgnoreCase(http.mediaOf(said_kind), "text/css");
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
    const said_kind = content_type orelse {
        // Nothing said: a file's own name, and otherwise markup, which is
        // what a page that says nothing about itself almost always is.
        inline for (.{ ".txt", ".md", ".log" }) |plain| {
            if (std.ascii.endsWithIgnoreCase(name, plain)) return .plain;
        }
        return .markup;
    };
    const media_type = http.mediaOf(said_kind);
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

/// Plain text as a page: one preformatted block in the monospaced face.
fn plainInto(bytes: []const u8, declared: ?charset.Charset, page: *Page) failure.ReadError!void {
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
/// in, at the place it was left. A page whose scripts hold its tree is read
/// from that tree, which its stylesheets were applied to for the window it
/// came in: what the scripts made of it is worth more than what a narrower
/// window would have hidden.
fn reread() void {
    read_for = window;
    if (document != null) return readAgain();
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
    repaint_wanted = true;
    // Its pictures from the next chance on, once its words are drawn.
    pictures.show(gpa, &shown, .{
        .widest = widest(),
        .scale = @intCast(eui.theme.textScale()),
        .ground = view.ground(),
    });
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

// ---------------------------------------------------------------------------
// The page's scripts
// ---------------------------------------------------------------------------

/// Go on with what the page's scripts have on their way: the ask being
/// answered, the next one to ask, or what they set to run and is now due.
/// True where something happened.
fn stepScripts() bool {
    const doc = scripts orelse return false;
    if (script_fetch.busy()) {
        if (script_fetch.advance(gpa) == .over) answered(doc);
        return true;
    }
    if (dom.nextAsk(doc)) |ask| {
        current_ask = ask.id;
        script_fetch.asking.wanted = if (ask.script) .script else .page;
        script_fetch.asking.sent = ask.sent;
        script_fetch.begin(gpa, ask.address);
        return true;
    }
    if ((dom.waits(doc) orelse return false) > 0) return false;
    _ = dom.loop(doc);
    _ = afterScripts(doc);
    return true;
}

/// The ask being answered has its answer, or will not: the scripts are told.
fn answered(doc: *dom.Document) void {
    const id = current_ask orelse return;
    current_ask = null;
    const got: dom.Answer = if (script_fetch.state == .done)
        .{ .status = script_fetch.response.status, .body = script_fetch.body.bytes.items }
    else
        .{ .failed = true };
    dom.answer(doc, id, got);
    script_fetch.release(gpa);
    _ = afterScripts(doc);
}

/// What the scripts have done since they were last asked: sent the reader
/// somewhere, in which case it goes there and `doc` is no more, or changed
/// the page, which is read again. True where the reader went somewhere.
fn afterScripts(doc: *dom.Document) bool {
    if (dom.takeGoing(doc)) |going| {
        sending = .{};
        if (going.sent) |answers| {
            if (!sending.keep(going.address, answers)) {
                failed(error.LongForm, going.address);
                return true;
            }
        }
        visitNew(going.address);
        return true;
    }
    if (dom.changed(doc)) readAgain();
    return false;
}

// ---------------------------------------------------------------------------
// What went wrong
// ---------------------------------------------------------------------------

/// A page saying why the one asked for is not here, or from the shell, the
/// few words and the end of it.
fn failed(why: Failure, subject: []const u8) void {
    if (shell) fatal(subject, why);
    var buf: [url.ADDRESS_MAX + 256]u8 = undefined;
    const said_why = failure.told(why, subject, &buf);
    var fresh: Page = .{};
    var builder = page_mod.Builder{ .gpa = gpa, .page = &fresh };
    build: {
        builder.boundary(.{ .kind = .heading }) catch break :build;
        builder.look.face = .heading;
        builder.words(said_why.heading) catch break :build;
        builder.look.face = .body;
        builder.boundary(.{}) catch break :build;
        builder.words(said_why.detail) catch break :build;
        builder.finish() catch break :build;
    }
    arrived = null;
    replace(&fresh, .{});
}

/// Say what went wrong on a shell line, and stop.
fn fatal(subject: []const u8, why: Failure) noreturn {
    var buf: [url.ADDRESS_MAX + 256]u8 = undefined;
    out.fault("web", subject, failure.told(why, subject, &buf).word);
    sys.exit(if (why == error.NotAnAddress) 2 else 1);
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
    // read differently, and is only laid out again where it would not. The
    // shade is put into effect first, being one of the things a page is read
    // for: where it is the interface's, the interface can have changed under
    // a window that is open.
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
        .chose => |pick| chose(pick),
    };
    status(parts.bottom, parts.body);
    // Last, so that it stands over the page it hangs over.
    runMenu(bar.menu);
    plan();
}

/// An entry of one of the page's lists was chosen: the page's scripts are
/// told, and what they change is read again.
fn chose(pick: view_mod.Chose) void {
    const doc = scripts orelse return;
    const node = shown.controls.items[pick.control].node orelse return;
    dom.chose(doc, @ptrCast(@alignCast(node)), pick.index);
    _ = afterScripts(doc);
}

/// Send a form's answers where it says: in the address, as its query, for a
/// form that asks by GET, as a search does, and in the body of a POST for one
/// that asks by POST, as logging in and ordering are done. The page's scripts
/// are told first, and may refuse it.
fn submit(sent: view_mod.Submit) void {
    const form = shown.forms.items[sent.form];
    if (scripts) |doc| {
        if (form.node) |node| {
            const prevented = dom.submitted(doc, @ptrCast(@alignCast(node)));
            if (afterScripts(doc) or prevented) return;
        }
    }
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
            var buf: [form_mod.ANSWERS_MAX]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            writeAnswers(&w, sent) catch return failed(error.LongForm, action);
            if (!sending.keep(action, w.buffered())) return failed(error.BadAddress, action);
            visitNew(action);
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
        var label_buf: [url.ADDRESS_MAX]u8 = undefined;
        left.text(linkLabel(link, &label_buf));
    } else switch (fetch.state) {
        .connecting => {
            left.text("Reaching ");
            left.text(fetch.host());
        },
        .receiving => {
            left.text(if (reading != null) "Reading its links from " else "Reading from ");
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

    var said_buf: [96]u8 = undefined;
    eui.statusbar.run(ctx, area, &.{
        .{ .text = left.done() },
        .{ .text = scriptsText(&said_buf), .width = 320 },
        .{ .text = right.done(), .width = 150 },
    });
}

/// What the page's scripts came to, for the status line: how many ran, what
/// the last one threw, or what they reached for and could not have. The only
/// way to tell a reader that ran none from a page that had none.
fn scriptsText(buf: []u8) []const u8 {
    if (!choices.scripts) return "scripts off";
    const doc = scripts orelse return "";
    const report = dom.reportOf(doc);
    if (report.ran == 0) return "no scripts";
    if (report.error_last.len > 0) {
        const line = report.error_last[0 .. std.mem.indexOfScalar(u8, report.error_last, '\n') orelse report.error_last.len];
        return std.fmt.bufPrint(buf, "scripts {d}: {s}", .{ report.ran, line[0..@min(line.len, 72)] }) catch "scripts threw";
    }
    if (report.missing_count > 0) {
        return std.fmt.bufPrint(buf, "scripts {d}, no {s} (+{d})", .{ report.ran, report.missing_last, report.missing_count - 1 }) catch "scripts";
    }
    return std.fmt.bufPrint(buf, "scripts {d}", .{report.ran}) catch "scripts";
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
    } else return false;
    return true;
}

// ---------------------------------------------------------------------------
// From the shell
// ---------------------------------------------------------------------------

/// `web -t`: the page's words on standard output, and nothing drawn. The
/// same page the window would show, pumped by the shell until nothing is on
/// its way: gone on to the version for small screens it names, its scripts
/// run and what they asked for answered, and a moment given for what they
/// set to run soon. With no window to ask about, its stylesheets' rules for
/// windows of some sizes and not others are left out.
fn printText(target: []const u8) noreturn {
    shell = true;
    apply();
    typed(target);

    const started = sys.clockMicros();
    while (true) {
        _ = step();
        plan();
        const coming = fetch.busy() or reading != null or script_fetch.busy() or
            (if (scripts) |doc| dom.asking(doc) else false);
        if (!coming) {
            const waits = if (scripts) |doc| dom.waits(doc) else null;
            if (waits == null or sys.clockMicros() -| started > SETTLE_US) break;
        }
        if (period_us == IDLE_US) break;
        _ = sys.waitMany(wakes.slice(), @min(period_us, WATCH_US)) catch 0;
    }

    var text: std.Io.Writer.Allocating = .init(gpa);
    page_mod.writeText(&shown, &text.writer) catch fatal(target, error.OutOfMemory);
    out.through(text.written());
    out.flush();
    sys.exit(0);
}
