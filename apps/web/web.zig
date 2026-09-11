//! web: a reader for pages.
//!
//! What `design/00-vibeee.md` settled on: a reader for simple pages rather
//! than a general browser. It asks a site for one page, reads the words out
//! of the markup, and sets them in this system's own faces in a column the
//! width a line reads best at. It runs nothing a page sends, draws no
//! pictures and follows no stylesheet; what it shows is what the page says.
//!
//! The parts each have a file: `url` for where things are, `http` and
//! `fetch` for getting them, `lexbor` and `extract` for reading markup into
//! a `page`, `layout` for where its words go, and `view` for the part on
//! screen. This file is the window around them and the order they run in.
//!
//! `web -t <address>` prints a page's words instead of opening a window, so
//! whatever the window can read, the shell can too.
//!
//! Not part of the system. It is built into `home/bin/` and versioned on its
//! own.

const std = @import("std");
const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const ulib = @import("ulib");

const env = ulib.env;
const file = ulib.file;
const heap = ulib.heap;
const out = ulib.out;
const paths = ulib.paths;

const extract = @import("extract.zig");
const fetch_mod = @import("fetch.zig");
const lexbor = @import("lexbor.zig");
const page_mod = @import("page.zig");
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
const NO_LINK = page_mod.NO_LINK;

/// How soon after a pass the part of a fetch that blocks runs: straight
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
var trust: ulib.wire.Trust = .{};
var history: History = .{};

var wakes: [1]u32 = .{0};

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
        buf: [url.ADDRESS_MAX]u8 = undefined,
        len: usize = 0,
        scroll: i32 = 0,

        fn address(self: *const Entry) []const u8 {
            return self.buf[0..self.len];
        }

        fn set(self: *Entry, text: []const u8) void {
            const n = @min(text.len, self.buf.len);
            @memcpy(self.buf[0..n], text[0..n]);
            self.len = n;
        }
    };

    entries: [MAX]Entry = undefined,
    count: usize = 0,
    at: usize = 0,

    fn current(self: *History) ?*Entry {
        return if (self.count == 0) null else &self.entries[self.at];
    }

    /// A new page. Whatever was ahead of the current one is forgotten, as it
    /// is whenever somewhere new is gone to from a page gone back to; the
    /// oldest goes when the list is full.
    fn push(self: *History, text: []const u8) void {
        if (self.count > 0) self.count = self.at + 1;
        if (self.count == MAX) {
            for (0..MAX - 1) |i| self.entries[i] = self.entries[i + 1];
            self.count -= 1;
        }
        self.entries[self.count] = .{};
        self.entries[self.count].set(text);
        self.at = self.count;
        self.count += 1;
    }

    fn canBack(self: *const History) bool {
        return self.at > 0;
    }

    fn canForward(self: *const History) bool {
        return self.at + 1 < self.count;
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
    if (first) |target| typed(target) else focus_next = .field;

    proto.app.run("web", "web", 800, 480, .{
        .draw = draw,
        .key = key,
        .tick = tick,
        .tick_us = IDLE_US,
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
    const target = addressFrom(text, &buf) orelse return problem(
        "That is not an address",
        "An address is a site's name, like example.org, a whole address beginning with http:// or https://, or a file on this machine.",
    );
    go(target);
}

/// Follow a link on the page on screen.
fn follow(link: u16) void {
    const target = shown.address(link) orelse return;
    go(target);
}

/// Go somewhere new, which the history remembers.
fn go(where: []const u8) void {
    // Copied first: `where` may be an address on the page on screen, and
    // the page on screen is replaced by going.
    var buf: [url.ADDRESS_MAX]u8 = undefined;
    const target = buf[0..@min(where.len, buf.len)];
    @memcpy(target, where[0..target.len]);

    if (history.current()) |entry| entry.scroll = view.scroll;
    history.push(target);
    pending_scroll = 0;
    visit(target);
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
    visit(entry.address());
}

/// Fetch `target`, or read it here when it is a file, without touching the
/// history.
fn visit(target: []const u8) void {
    address.set(target);
    ctx.damage();

    const where = url.parse(target) orelse return problem("That is not an address", target);
    if (where.scheme == .file) return openFile(where);

    fetch.begin(gpa, target);
    proto.app.wakeOn(&.{});
    proto.app.retick(SOON_US);
}

fn stop() void {
    fetch.cancel(gpa);
    proto.app.wakeOn(&.{});
    proto.app.retick(IDLE_US);
    if (history.current()) |entry| address.set(entry.address());
    ctx.damage();
}

/// An address from what was typed: one written out whole, as it is; a file
/// on this machine, by its path; and a site's bare name, sealed. A site that
/// speaks only in the clear has to be asked for with `http://` in front.
fn addressFrom(typed_text: []const u8, buf: []u8) ?[]const u8 {
    const text = std.mem.trim(u8, typed_text, " \t");
    if (text.len == 0) return null;
    if (url.parse(text)) |whole| return url.format(whole, buf);

    // A name that is a file here is that file, which is what `web page.html`
    // means and what a person typing a path means.
    if (file.factsOf(text) != null) return fileAddress(text, buf);

    if (std.mem.indexOfAny(u8, text, " \t") != null or std.mem.indexOfScalar(u8, text, '.') == null) return null;
    var joined: [url.ADDRESS_MAX]u8 = undefined;
    const sealed = std.fmt.bufPrint(&joined, "https://{s}", .{text}) catch return null;
    return url.format(url.parse(sealed) orelse return null, buf);
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
    switch (fetch.phase) {
        .connecting => {
            fetch.connect(&trust);
            return settle();
        },
        .receiving => return fetch.stall(sys.clockMicros()) and settle(),
        .idle, .done, .failed => {
            proto.app.retick(IDLE_US);
            return false;
        },
    }
}

fn woken(_: usize) bool {
    fetch.pump(gpa);
    _ = settle();
    // A piece arrived, which the status line counts, whatever else it did.
    return true;
}

/// Act on where the fetch has got to. True when there is something new to
/// draw.
fn settle() bool {
    switch (fetch.phase) {
        .idle => return false,
        .connecting => {
            // Sent on somewhere else: reached again on the next chance.
            address.set(fetch.address());
            proto.app.wakeOn(&.{});
            proto.app.retick(SOON_US);
        },
        .receiving => {
            wakes[0] = fetch.waitHandle() orelse return false;
            proto.app.wakeOn(&wakes);
            proto.app.retick(WATCH_US);
        },
        .done => {
            proto.app.wakeOn(&.{});
            proto.app.retick(IDLE_US);
            arrive();
        },
        .failed => {
            proto.app.wakeOn(&.{});
            proto.app.retick(IDLE_US);
            failed(fetch.failure);
            fetch.cancel(gpa);
        },
    }
    ctx.damage();
    return true;
}

/// The page is here: read it, show it, and give back what it arrived in.
fn arrive() void {
    defer fetch.cancel(gpa);
    const final = fetch.address();
    address.set(final);
    if (history.current()) |entry| entry.set(final);

    arrived = .{
        .bytes = fetch.received(),
        .us = sys.clockMicros() -| fetch.started_us,
        .status = fetch.response.status,
    };

    const base = url.parse(final) orelse return problem("That is not an address", final);
    show(fetch.body.bytes.items, base, kindOf(fetch.response.contentType(), final));
}

/// A file on this machine, read whole.
fn openFile(where: url.Url) void {
    const path = where.file();
    const facts = file.factsOf(path) orelse return problem("There is no such file", path);
    if (facts.size > fetch_mod.PAGE_MAX) return problem("This file is too large", "It is over 4 MB, which is more than this reader reads.");

    const bytes = gpa.alloc(u8, facts.size) catch return problem("Not enough memory", "This file needs more memory than the machine has free.");
    defer gpa.free(bytes);
    const got = file.readWhole(path, bytes) orelse return problem("This file could not be read", path);

    arrived = .{ .bytes = got };
    show(bytes[0..got], where, kindOf(null, path));
}

/// What a body is, from what the site said it was, or from a file's name.
const Kind = union(enum) {
    markup,
    plain,
    other: []const u8,
};

fn kindOf(content_type: ?[]const u8, name: []const u8) Kind {
    const said = content_type orelse {
        // Nothing said: a file's own name, and otherwise markup, which is
        // what a page that says nothing about itself almost always is.
        for ([_][]const u8{ ".txt", ".md", ".log" }) |plain| {
            if (std.ascii.endsWithIgnoreCase(name, plain)) return .plain;
        }
        return .markup;
    };
    const end = std.mem.indexOfScalar(u8, said, ';') orelse said.len;
    const media = std.mem.trim(u8, said[0..end], " \t");
    if (std.ascii.eqlIgnoreCase(media, "text/html") or std.ascii.eqlIgnoreCase(media, "application/xhtml+xml")) return .markup;
    if (std.ascii.eqlIgnoreCase(media, "text/plain")) return .plain;
    return .{ .other = media };
}

/// Read `bytes` into a page and put it on screen.
fn show(bytes: []const u8, base: url.Url, kind: Kind) void {
    var fresh: Page = .{};
    toPage(bytes, base, kind, &fresh) catch |err| {
        fresh.deinit(gpa);
        return switch (err) {
            error.OutOfMemory => problem("Not enough memory", "This page needs more memory than the machine has free."),
            error.Unreadable => problem("This page could not be read", "The parser would not take it."),
            error.NotAPage => problem("This is not a page", switch (kind) {
                .other => |media| media,
                else => "",
            }),
        };
    };
    replace(&fresh);
    focus_next = .page;
}

const ReadError = error{ OutOfMemory, Unreadable, NotAPage };

/// Read `bytes` into `page`, as markup or as plain text.
fn toPage(bytes: []const u8, base: url.Url, kind: Kind, page: *Page) ReadError!void {
    switch (kind) {
        .other => return error.NotAPage,
        .plain => {
            var builder = page_mod.Builder{ .gpa = gpa, .page = page };
            try builder.boundary(.{ .kind = .preformatted });
            builder.face = .mono;
            try builder.words(bytes);
            try builder.finish();
        },
        .markup => {
            const document = lexbor.lxb_html_document_create() orelse return error.OutOfMemory;
            defer _ = lexbor.lxb_html_document_destroy(document);
            switch (lexbor.lxb_html_document_parse(document, bytes.ptr, bytes.len)) {
                .ok => {},
                .no_memory => return error.OutOfMemory,
                _ => return error.Unreadable,
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
}

/// A page saying why the one asked for is not here.
fn problem(heading: []const u8, detail: []const u8) void {
    var fresh: Page = .{};
    var builder = page_mod.Builder{ .gpa = gpa, .page = &fresh };
    build: {
        builder.boundary(.{ .kind = .heading }) catch break :build;
        builder.face = .heading;
        builder.words(heading) catch break :build;
        builder.face = .body;
        builder.boundary(.{}) catch break :build;
        builder.words(detail) catch break :build;
        builder.finish() catch break :build;
    }
    arrived = null;
    replace(&fresh);
}

fn failed(why: fetch_mod.Failure) void {
    var detail: [512]u8 = undefined;
    const site = fetch.host();
    const said = switch (why) {
        .no_name => .{ "Nothing answers to that name", std.fmt.bufPrint(&detail, "{s} is not a name the network knows. It may be misspelt, or this machine may not be connected.", .{site}) catch site },
        .cannot_reach => .{ "The site could not be reached", std.fmt.bufPrint(&detail, "{s} did not answer. It may be down, or not listening where it was asked.", .{site}) catch site },
        .refused => .{ "No shared way to encrypt this", std.fmt.bufPrint(&detail, "{s} and this reader could not agree on a sealed connection ({s}), so nothing was sent.", .{ site, ulib.tls.last_failure }) catch site },
        .no_clock => .{ "The clock is not set", "A sealed page cannot be read until it is: a certificate's dates mean nothing without it." },
        .no_authorities => .{ "The certificate authorities could not be read", "They are kept in /share/ca.store, and a sealed page cannot be checked without them." },
        .no_randomness => .{ "Not enough randomness yet", "The machine has not gathered enough to seal a connection with. Try again in a moment." },
        .malformed => .{ "That was not a page", std.fmt.bufPrint(&detail, "{s} answered with something that is not HTTP.", .{site}) catch site },
        .too_large => .{ "This page is too large", "It is over 4 MB, which is more than this reader reads." },
        .truncated => .{ "The page was cut short", "The connection ended before all of it arrived." },
        .unanswered => .{ "The site did not answer", std.fmt.bufPrint(&detail, "{s} closed the connection without sending anything back.", .{site}) catch site },
        .redirect_loop => .{ "Sent round in circles", std.fmt.bufPrint(&detail, "{s} kept sending the request on somewhere else.", .{site}) catch site },
        .stalled => .{ "The site stopped answering", "Nothing arrived for thirty seconds, so the reader gave up waiting." },
        .out_of_memory => .{ "Not enough memory", "This page needs more memory than the machine has free." },
    };
    problem(said[0], said[1]);
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
    if (view.run(gpa, ctx, parts.body)) |link| follow(link);
    status(parts.bottom, parts.body);
}

/// Where the strip's parts go: the way back, the way forward, the key that
/// fetches again or stops, and the field in what is left.
const Strip = struct {
    back: Rect,
    forward: Rect,
    reload: Rect,
    field: Rect,

    fn of(area: Rect) Strip {
        const t = eui.theme.current();
        const size = t.control_height;
        const y = area.y + @divTrunc(area.h - size, 2);
        const back_x = area.x + t.padding;
        const forward_x = back_x + size + 2;
        const reload_x = forward_x + size + 2;
        const field_x = reload_x + size + t.gap;
        return .{
            .back = .{ .x = back_x, .y = y, .w = size, .h = size },
            .forward = .{ .x = forward_x, .y = y, .w = size, .h = size },
            .reload = .{ .x = reload_x, .y = y, .w = size, .h = size },
            .field = .{ .x = field_x, .y = y, .w = area.right() - t.padding - field_x, .h = size },
        };
    }
};

fn strip(area: Rect, at: Strip) void {
    if (ctx.tool(at.back, .back, history.canBack())) back();
    if (ctx.tool(at.forward, .forward, history.canForward())) forward();
    // One key, two jobs: while a page is coming it stops it, and otherwise
    // it fetches the page again.
    const loading = fetch.phase == .connecting or fetch.phase == .receiving;
    if (ctx.tool(at.reload, if (loading) .cross else .reload, loading or history.count > 0)) {
        if (loading) stop() else reload();
    }
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
    return switch (fetch.phase) {
        .connecting => 30,
        .receiving => if (fetch.expected()) |total|
            @intCast(@max(30, @min(1000, fetch.received() * 1000 / @max(total, 1))))
        else
            30,
        else => 0,
    };
}

fn status(area: Rect, body: Rect) void {
    var left_buf: [url.ADDRESS_MAX + 32]u8 = undefined;
    var right_buf: [48]u8 = undefined;

    const left: []const u8 = if (view.hover != NO_LINK)
        shown.address(view.hover) orelse ""
    else switch (fetch.phase) {
        .connecting => std.fmt.bufPrint(&left_buf, "Reaching {s}", .{fetch.host()}) catch "",
        .receiving => std.fmt.bufPrint(&left_buf, "Reading from {s}", .{fetch.host()}) catch "",
        else => if (shown.title.items.len > 0) shown.title.items else address.slice(),
    };

    const right: []const u8 = switch (fetch.phase) {
        .receiving => if (fetch.expected()) |total|
            std.fmt.bufPrint(&right_buf, "{d} KB of {d} KB", .{ kb(fetch.received()), kb(total) }) catch ""
        else
            std.fmt.bufPrint(&right_buf, "{d} KB so far", .{kb(fetch.received())}) catch "",
        .connecting => "",
        else => arrivedText(&right_buf, body),
    };

    eui.statusbar.run(ctx, area, &.{
        .{ .text = left },
        .{ .text = right, .width = 150 },
    });
}

/// What the page on screen cost to fetch, or how far down it the view is
/// once that is no longer news.
fn arrivedText(buf: []u8, body: Rect) []const u8 {
    const got = arrived orelse return "";
    if (got.status) |code| {
        if (code >= 400) return std.fmt.bufPrint(buf, "the site said {d}", .{code}) catch "";
    }
    if (view.scroll > 0) return std.fmt.bufPrint(buf, "{d}%", .{view.position(body)}) catch "";
    const us = got.us orelse return std.fmt.bufPrint(buf, "{d} KB", .{kb(got.bytes)}) catch "";
    const tenths = us / 100_000;
    return std.fmt.bufPrint(buf, "{d} KB in {d}.{d} s", .{ kb(got.bytes), tenths / 10, tenths % 10 }) catch "";
}

fn kb(bytes: u64) u64 {
    return (bytes + 1023) / 1024;
}

fn key(code: KeyCode, mods: Modifiers) bool {
    if (mods.alt and code == .left) {
        back();
        return true;
    }
    if (mods.alt and code == .right) {
        forward();
        return true;
    }
    if (code == .f5 or (mods.control and code == .r)) {
        reload();
        return true;
    }
    if (mods.control and code == .l) {
        focus_next = .field;
        return true;
    }
    if (code == .escape and fetch.phase != .idle and fetch.phase != .done and fetch.phase != .failed) {
        stop();
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// From the shell
// ---------------------------------------------------------------------------

/// `web -t`: the page's words on standard output, and nothing drawn.
fn printText(target: []const u8) noreturn {
    var buf: [url.ADDRESS_MAX]u8 = undefined;
    const where_text = addressFrom(target, &buf) orelse {
        out.fault("web", target, "not an address");
        sys.exit(2);
    };
    const where = url.parse(where_text) orelse {
        out.fault("web", target, "not an address");
        sys.exit(2);
    };

    var page: Page = .{};
    if (where.scheme == .file) {
        const path = where.file();
        const facts = file.factsOf(path) orelse fatal(path, "cannot open");
        if (facts.size > fetch_mod.PAGE_MAX) fatal(path, "larger than this reads");
        const bytes = gpa.alloc(u8, facts.size) catch fatal(path, "no room to read it");
        const got = file.readWhole(path, bytes) orelse fatal(path, "cannot read");
        toPage(bytes[0..got], where, kindOf(null, path), &page) catch |err| fatal(path, readWord(err));
    } else {
        fetch.begin(gpa, where_text);
        while (true) {
            switch (fetch.phase) {
                .connecting => fetch.connect(&trust),
                .receiving => {
                    // Woken by the site, or once a second to notice one
                    // that has gone quiet.
                    sys.eventWait(fetch.waitHandle().?, WATCH_US) catch {};
                    fetch.pump(gpa);
                    _ = fetch.stall(sys.clockMicros());
                },
                .done => break,
                .failed => fatal(fetch.host(), failureWord(fetch.failure)),
                .idle => unreachable,
            }
        }
        const final = url.parse(fetch.address()) orelse fatal(fetch.address(), "not an address");
        toPage(fetch.body.bytes.items, final, kindOf(fetch.response.contentType(), fetch.address()), &page) catch |err|
            fatal(fetch.address(), readWord(err));
    }

    page_mod.writeText(&page, Terminal{});
    out.flush();
    sys.exit(0);
}

const Terminal = struct {
    pub fn text(_: Terminal, bytes: []const u8) void {
        out.text(bytes);
    }
};

fn fatal(what: []const u8, why: []const u8) noreturn {
    out.fault("web", what, why);
    sys.exit(1);
}

/// Why a page that arrived could not be read, in a shell line's few words.
fn readWord(err: ReadError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "not enough memory to read it",
        error.Unreadable => "the parser would not take it",
        error.NotAPage => "not a page",
    };
}

/// The same failures, in the few words a shell line has room for.
fn failureWord(why: fetch_mod.Failure) []const u8 {
    return switch (why) {
        .no_name => "no such name",
        .cannot_reach => "could not reach it",
        .refused => "the sealed connection was refused",
        .no_clock => "the clock is not set",
        .no_authorities => "the certificate authorities could not be read",
        .no_randomness => "not enough randomness to seal with",
        .malformed => "not HTTP",
        .too_large => "larger than this reads",
        .truncated => "cut short",
        .unanswered => "closed without answering",
        .redirect_loop => "sent round in circles",
        .stalled => "stopped answering",
        .out_of_memory => "not enough memory",
    };
}
