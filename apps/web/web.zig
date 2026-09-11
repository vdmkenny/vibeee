//! web: a reader for pages.
//!
//! What `design/00-vibeee.md` settled on: a reader for simple pages rather
//! than a general browser. It asks a site for one page, reads the words out
//! of the markup, and sets them in this system's own faces in a column the
//! width a line reads best at. It runs nothing a page sends and follows no
//! stylesheet; what it shows is what the page says. A page's pictures come
//! after its words, one at a time, what the page says each one shows standing
//! in for it until it is here.
//!
//! The parts each have a file: `url` for where things are, `http` and
//! `fetch` for getting them, `lexbor` and `extract` for reading markup into
//! a `page`, `layout` for where its words go, `pictures` for what it shows
//! among them, and `view` for the part on screen. This file is the window
//! around them and the order they run in.
//!
//! `web -t <address>` prints a page's words instead of opening a window, so
//! whatever the window can read, the shell can too.
//!
//! Where it starts and whether it fetches pictures are settings, in the `web`
//! domain the store keeps: `cfg web` lists them, and a window that is open
//! takes a change as it is made.
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

const charset = @import("charset.zig");
const extract = @import("extract.zig");
const fetch_mod = @import("fetch.zig");
const form_mod = @import("form.zig");
const http = @import("http.zig");
const lexbor = @import("lexbor.zig");
const page_mod = @import("page.zig");
const pictures_mod = @import("pictures.zig");
const url = @import("url.zig");
const view_mod = @import("view.zig");

// The routines lexbor's C calls by name.
comptime {
    _ = @import("clibc");
}

const ctx = &proto.app.ctx;
const gpa = heap.allocator;

const Rect = eui.Rect;
const KeyCode = eui.widget.KeyCode;
const Modifiers = eui.widget.Modifiers;
const Page = page_mod.Page;

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
var fetch: fetch_mod.Fetch = .{};
/// The pictures of the page on screen, and the fetch that brings them.
var pictures: pictures_mod.Pictures = .{};
var history: History = .{};

/// The reader's settings as the store last had them, and the event that says
/// they changed, where the store is there to give one.
var choices: proto.settings.Web = .{};
var settings_changed: ?u32 = null;

/// What the window sleeps on besides its own events: the settings changing,
/// and the site while a page is coming from one.
var wakes: Bounded(u32, 2) = .{};

/// How much of the rule under the strip was last painted, in thousandths.
var drawn_progress: ?u16 = null;
/// How far down to open the page being fetched: where it was left, when it
/// is one being gone back to.
var pending_scroll: i32 = 0;
/// Where the keyboard goes on the next pass: to the field when the reader
/// opens with nowhere to go, and to the page once one has arrived.
var focus_next: ?enum { field, page } = null;
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
    const first = env.arg(frame, 1);
    if (first) |flag| {
        if (std.mem.eql(u8, flag, "-t")) printText(env.arg(frame, 2) orelse usage());
    }

    address.init(.{ .hint = "an address, or a file on this machine" });
    view.show(gpa, &shown, 0);
    choices = proto.settings.load("web");
    settings_changed = proto.settings.watch("web") catch null;
    pictures.enabled = choices.images;
    if (first) |target| typed(target) else home();
    sleepOn(null);

    proto.app.run("web", "web", 800, 480, .{
        .draw = draw,
        .key = key,
        .tick = tick,
        // The frame begins with what it is handed here, so a first page
        // already on its way is handed over as one.
        .tick_us = if (fetch.busy()) SOON_US else IDLE_US,
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

/// Follow a link on the page on screen.
fn follow(link: u16) void {
    go(shown.address(link) orelse return);
}

/// Go somewhere new, which the history remembers.
fn go(where: []const u8) void {
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
    pending_scroll = entry.scroll;
    visit(entry.address.slice());
}

/// Fetch `target`, or read it here when it is a file, without touching the
/// history.
fn visit(target: []const u8) void {
    address.set(target);
    const where = url.parse(target) orelse return failed(error.NotAnAddress, target);
    if (where.scheme == .file) return openFile(where);

    // The network is the page's while it comes: the pictures of the one on
    // screen wait.
    pictures.pause(gpa);
    fetch.begin(gpa, target);
    _ = settle(.none);
}

fn stop() void {
    fetch.cancel(gpa);
    if (history.current()) |entry| address.set(entry.address.slice());
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
    return step();
}

fn woken(index: usize) bool {
    if (settings_changed != null and wakes.at(index) == settings_changed) {
        choices = proto.settings.load("web");
        pictures.enabled = choices.images;
        if (!choices.images) pictures.pause(gpa);
        // Pictures turned off give their room to what the page says they
        // show, and turned on come as they would have.
        view.relayout();
        waitFor(.none);
        return true;
    }
    _ = step();
    // A piece arrived, which the status line counts, whatever else it did.
    return true;
}

/// Take the next step of whatever is on its way: the page, or once it is
/// here, its pictures. True when there is something new to draw.
fn step() bool {
    if (fetch.busy()) return settle(fetch.advance(gpa));
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
    proto.app.retick(IDLE_US);
}

/// Sleep on the settings, and on `site` while a page is coming from one.
fn sleepOn(site: ?u32) void {
    wakes.clear();
    if (settings_changed) |event| wakes.append(event) catch unreachable;
    if (site) |handle| wakes.append(handle) catch unreachable;
    proto.app.wakeOn(wakes.slice());
}

/// Wait on what the page's fetch waits on next, and act on its end. True
/// when there is something new to draw.
fn settle(wait: fetch_mod.Wait) bool {
    waitFor(wait);
    switch (wait) {
        // The step that blocks is also what a redirect is, which the address
        // says as it happens.
        .none => address.set(fetch.address()),
        .site => {},
        .over => switch (fetch.state) {
            .idle => return false,
            .done => arrive(),
            .failed => |why| {
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

/// The page is here: read it, show it, and give back what it arrived in.
fn arrive() void {
    defer fetch.cancel(gpa);
    const final = fetch.address();
    address.set(final);
    if (history.current()) |entry| _ = entry.address.set(final);

    arrived = .{
        .bytes = fetch.received(),
        .us = sys.clockMicros() -| fetch.started_us,
        .status = fetch.response.status,
    };

    const base = url.parse(final) orelse return failed(error.NotAnAddress, final);
    const said = fetch.response.contentType();
    show(fetch.body.bytes.items, base, kindOf(said, final), charset.fromContentType(said));
}

/// A file on this machine, read whole.
fn openFile(where: url.Url) void {
    const path = where.file();
    const bytes = file.readAlloc(gpa, path, fetch_mod.PAGE_MAX) catch |err| return failed(err, path);
    defer gpa.free(bytes);
    arrived = .{ .bytes = bytes.len };
    show(bytes, where, kindOf(null, path), null);
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
    const media = http.mediaOf(said);
    return media_kinds.get(media) orelse .{ .other = media };
}

/// Read `bytes` into a page and put it on screen. `declared` is the encoding
/// the site said they are in, where it said one.
fn show(bytes: []const u8, base: url.Url, kind: Kind, declared: ?charset.Charset) void {
    var fresh: Page = .{};
    toPage(bytes, base, kind, declared, &fresh) catch |err| {
        fresh.deinit(gpa);
        return failed(err, switch (kind) {
            .other => |media| media,
            .markup, .plain => base.host,
        });
    };
    replace(&fresh);
    focus_next = .page;
}

/// Why what arrived could not be read as a page.
const ReadError = error{
    OutOfMemory,
    /// The parser would not take it.
    Unparsable,
    /// It is something other than a page.
    NotAPage,
};

/// Read `bytes` into `page`, as markup or as plain text.
fn toPage(bytes: []const u8, base: url.Url, kind: Kind, declared: ?charset.Charset, page: *Page) ReadError!void {
    if (kind == .other) return error.NotAPage;
    // The parser reads UTF-8 and nothing else, and neither does the page.
    // The encoding is kept all the same: a form answers in it.
    const encoding = charset.sniff(declared, bytes);
    const text = try charset.utf8Of(gpa, bytes, encoding);
    defer text.deinit(gpa);
    const utf8 = text.bytes();
    page.encoding = encoding;

    switch (kind) {
        .other => unreachable,
        .plain => {
            var builder = page_mod.Builder{ .gpa = gpa, .page = page };
            try builder.boundary(.{ .kind = .preformatted });
            builder.look.face = .mono;
            try builder.words(utf8);
            try builder.finish();
        },
        .markup => {
            const document = lexbor.lxb_html_document_create() orelse return error.OutOfMemory;
            defer _ = lexbor.lxb_html_document_destroy(document);
            switch (lexbor.lxb_html_document_parse(document, utf8.ptr, utf8.len)) {
                .ok => {},
                .no_memory => return error.OutOfMemory,
                _ => return error.Unparsable,
            }
            try extract.extract(gpa, document, base, page);
        },
    }
}

fn replace(fresh: *Page) void {
    shown.deinit(gpa);
    shown = fresh.*;
    view.show(gpa, &shown, pending_scroll);
    pending_scroll = 0;
    title_stale = true;
    // Its pictures from the next chance on, once its words are drawn.
    pictures.show(gpa, &shown, widest());
    waitFor(.none);
}

/// The widest a picture is drawn: the widest the column is, at the size the
/// interface is drawn.
fn widest() u16 {
    return @intCast(view_mod.MEASURE * eui.theme.textScale());
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
    replace(&fresh);
}

// ---------------------------------------------------------------------------
// What went wrong
// ---------------------------------------------------------------------------

/// Every way the reader can fail to show what was asked for.
const Failure = fetch_mod.Failure || file.AllocError || ReadError || error{
    NotAnAddress,
    /// A form that posts its answers, which this reader does not send.
    PostedForm,
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
        error.PostedForm => .{
            .heading = "This form cannot be sent from here",
            .detail = "It posts its answers, which is how logging in and ordering are done. This reader sends a form's answers in the address, the way a search does, and no other way.",
            .word = "the form posts its answers",
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
}

/// Send a form's answers where it says, the way a search sends them: in the
/// address, as its query.
fn submit(sent: view_mod.Submit) void {
    const form = shown.forms.items[sent.form];
    const action = shown.string(form.action);
    if (form.method == .post) return failed(error.PostedForm, action);

    var buf: [url.ADDRESS_MAX]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeQuery(&w, sent, action) catch return failed(error.BadAddress, action);
    go(w.buffered());
}

/// The form's address with its answers as the query, in place of any query
/// the address had.
fn writeQuery(w: *std.Io.Writer, sent: view_mod.Submit, action: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(action[0 .. std.mem.indexOfScalar(u8, action, '?') orelse action.len]);
    try w.writeByte('?');
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
/// fetches again or stops, the way home, and the field in what is left.
const Strip = struct {
    back: Rect,
    forward: Rect,
    reload: Rect,
    home: Rect,
    field: Rect,

    fn of(area: Rect) Strip {
        const t = eui.theme.current();
        const size = t.control_height;
        const y = area.y + @divTrunc(area.h - size, 2);
        // The keys a hair apart, and the field a gap after the last.
        const pitch = size + 2;
        const left = area.x + t.padding;
        const field_x = left + 3 * pitch + size + t.gap;
        return .{
            .back = square(left, y, size),
            .forward = square(left + pitch, y, size),
            .reload = square(left + 2 * pitch, y, size),
            .home = square(left + 3 * pitch, y, size),
            .field = .{ .x = field_x, .y = y, .w = area.right() - t.padding - field_x, .h = size },
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

    rule(area);
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
            left.text("Reading from ");
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

    eui.statusbar.run(ctx, area, &.{
        .{ .text = left.done() },
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

/// `web -t`: the page's words on standard output, and nothing drawn.
fn printText(target: []const u8) noreturn {
    var buf: [url.ADDRESS_MAX]u8 = undefined;
    const where_text = addressFrom(target, &buf) orelse fatal(target, error.NotAnAddress);
    const where = url.parse(where_text) orelse fatal(target, error.NotAnAddress);

    var page: Page = .{};
    if (where.scheme == .file) {
        const path = where.file();
        const bytes = file.readAlloc(gpa, path, fetch_mod.PAGE_MAX) catch |err| fatal(path, err);
        toPage(bytes, where, kindOf(null, path), null, &page) catch |err| fatal(path, err);
    } else {
        fetch.begin(gpa, where_text);
        while (true) switch (fetch.advance(gpa)) {
            .none => {},
            // Woken by the site, or once a second to notice one that has
            // gone quiet.
            .site => |handle| sys.eventWait(handle, WATCH_US) catch {},
            .over => break,
        };
        switch (fetch.state) {
            .done => {},
            .failed => |why| fatal(fetch.host(), why),
            .idle, .connecting, .receiving => unreachable,
        }
        const final = url.parse(fetch.address()) orelse fatal(fetch.address(), error.NotAnAddress);
        const said = fetch.response.contentType();
        toPage(fetch.body.bytes.items, final, kindOf(said, fetch.address()), charset.fromContentType(said), &page) catch |err|
            fatal(fetch.address(), err);
    }

    var text: std.Io.Writer.Allocating = .init(gpa);
    page_mod.writeText(&page, &text.writer) catch fatal(where_text, error.OutOfMemory);
    out.through(text.written());
    out.flush();
    sys.exit(0);
}

/// Say what went wrong on a shell line, and stop.
fn fatal(subject: []const u8, why: Failure) noreturn {
    var buf: [url.ADDRESS_MAX + 256]u8 = undefined;
    out.fault("web", subject, told(why, subject, &buf).word);
    sys.exit(if (why == error.NotAnAddress) 2 else 1);
}
