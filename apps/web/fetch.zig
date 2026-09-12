//! One page, or one picture on a page, coming over the network: reaching the
//! site, asking for it, and taking the answer as it arrives.
//!
//! Driven from outside rather than running on its own: `advance` takes the
//! next step and says what to wait on before the one after, and a window and
//! a shell each wait in their own way. Reaching a site blocks, because a TLS
//! handshake is several round trips and there is no half of one to come
//! back to; every step after it takes what has arrived and returns. So a
//! window paints "connecting" before it takes the step that blocks, and
//! stays drawn while a page arrives a piece at a time.
//!
//! The connection an answer came on is kept where the site keeps it, and the
//! next request to the same site is sent on it: reaching the site and sealing
//! the connection is the step that blocks, and a page's stylesheets and its
//! pictures need it once rather than once each.
//!
//! A site on the blocklist a fetch is given is not reached at all: the
//! request to one, a redirect to one included, fails before anything is
//! sent.

const std = @import("std");
const sys = @import("sys");
const ulib = @import("ulib");
const Bounded = @import("lib").bounded.Bounded;

const blocklist_mod = @import("blocklist.zig");
const http = @import("http.zig");
const url = @import("url");

const Wire = ulib.wire.Wire;

/// The most a page may be.
///
/// Four megabytes covers an article with its scripts and stylesheets written
/// into it, which is most of what an ordinary page weighs now. Past it the
/// page is refused rather than cut: half a document parses into a tree that
/// is wrong in ways nothing downstream can see.
pub const PAGE_MAX = 4 * 1024 * 1024;

/// The most a picture's file may be. A picture made for a page is a few
/// hundred kilobytes; one past this was made for printing rather than for
/// reading beside words.
pub const PICTURE_MAX = 1024 * 1024;

/// The most one stylesheet may be. A site's whole look is a few hundred
/// kilobytes; a bundle past a megabyte is left out rather than read.
pub const SHEET_MAX = 1024 * 1024;

/// The most an answer may be, for what was asked.
fn limitOf(wanted: http.Wanted) usize {
    return switch (wanted) {
        .page => PAGE_MAX,
        .style => SHEET_MAX,
        .picture => PICTURE_MAX,
    };
}

/// A connection kept after an answer, and where it goes.
const Kept = struct {
    wire: Wire,
    scheme: url.Scheme,
    host: Bounded(u8, HOST_MAX) = .{},
    port: u16,

    fn goesTo(self: *const Kept, where: url.Url) bool {
        return self.scheme == where.scheme and self.port == where.port and
            std.ascii.eqlIgnoreCase(self.host.slice(), where.host);
    }
};

/// The longest a host's name can be.
const HOST_MAX = 255;

/// How many times one request may be sent on to somewhere else.
const REDIRECTS_MAX = 5;

/// How long a site may say nothing before the fetch gives up on it.
pub const STALL_US: u64 = 30 * std.time.us_per_s;

/// Every way a page can fail to arrive: the connection's own, the
/// protocol's, and these.
pub const Failure = ulib.wire.Error || http.Error || error{
    /// Not an address this reader can ask a site for.
    BadAddress,
    /// Sent on somewhere else more times than a page should need.
    RedirectLoop,
    /// The site said nothing for too long.
    Stalled,
    /// The site is on the blocklist, and so was not reached.
    Blocked,
};

pub const State = union(enum) {
    idle,
    /// The site is to be reached at the next step, which blocks.
    connecting,
    /// Asked, and taking what arrives.
    receiving,
    done,
    failed: Failure,
};

/// What a fetch waits on before its next step.
pub const Wait = union(enum) {
    /// Nothing: the next step can be taken now, and it is the one that
    /// blocks.
    none,
    /// The site, by this handle: a piece arriving, or the connection ending.
    site: u32,
    /// Nothing ever again: the fetch is over, done or failed.
    over,
};

/// A complete response, before a redirect turns this fetch to the next one.
/// The browser uses it for state that belongs to responses rather than their
/// bodies, notably Set-Cookie fields.
pub const ResponseHook = *const fn ([]const u8, *const http.Response) void;
pub const RedirectHook = *const fn ([]const u8, []const u8) void;
pub const CookieHook = *const fn ([]const u8) []const u8;

pub const Fetch = struct {
    /// What is asked of the site: a page, a stylesheet or a picture, which
    /// says what the site is told the reader takes and how large its answer
    /// may be, and what the request says of the reader besides.
    asking: http.Asking = .{},
    /// The sites not to be reached, where there are any.
    blocklist: ?blocklist_mod.Blocklist = null,
    state: State = .idle,
    /// Where the page is: the address asked for, or after a redirect the one
    /// it was sent on to.
    target: url.Address = .{},

    wire: ?Wire = null,
    /// A connection an earlier answer came on, kept for the next request to
    /// the same site, and whether the connection in use is that one.
    kept: ?Kept = null,
    reused: bool = false,
    response: http.Response = .{},
    body: http.Body = .{ .limit = PAGE_MAX },
    redirects: u8 = 0,
    response_hook: ?ResponseHook = null,
    redirect_hook: ?RedirectHook = null,
    cookies_for: ?CookieHook = null,

    /// When the fetch began, and when the site last said anything.
    started_us: u64 = 0,
    heard_us: u64 = 0,

    pub fn address(self: *const Fetch) []const u8 {
        return self.target.slice();
    }

    /// The host being reached, for saying so.
    pub fn host(self: *const Fetch) []const u8 {
        const where = url.parse(self.address()) orelse return self.address();
        return where.host;
    }

    /// Whether a page is on its way.
    pub fn busy(self: *const Fetch) bool {
        return self.state == .connecting or self.state == .receiving;
    }

    /// Whether the site at `where` is on the blocklist.
    pub fn refuses(self: *const Fetch, where: url.Url) bool {
        const list = self.blocklist orelse return false;
        return list.blocks(where.host);
    }

    /// Begin fetching `target`. Nothing is sent until the first step.
    pub fn begin(self: *Fetch, gpa: std.mem.Allocator, target: []const u8) void {
        self.redirects = 0;
        self.started_us = sys.clockMicros();
        self.aim(gpa, target);
    }

    /// Take the next step, and say what to wait on before the one after.
    pub fn advance(self: *Fetch, gpa: std.mem.Allocator) Wait {
        switch (self.state) {
            .connecting => self.connect(gpa),
            .receiving => {
                self.pump(gpa);
                self.stall(sys.clockMicros());
            },
            .idle, .done, .failed => {},
        }
        return switch (self.state) {
            .connecting => .none,
            .receiving => .{ .site = self.wire.?.waitHandle() },
            .idle, .done, .failed => .over,
        };
    }

    /// Let go of the answer and of the connection it came on, but not of a
    /// connection kept for the next request: what is done with a fetch that
    /// another is to follow.
    pub fn release(self: *Fetch, gpa: std.mem.Allocator) void {
        self.reset(gpa);
        self.state = .idle;
    }

    /// Stop, and give back everything held.
    pub fn cancel(self: *Fetch, gpa: std.mem.Allocator) void {
        self.release(gpa);
        if (self.kept) |kept| kept.wire.close();
        self.kept = null;
    }

    /// How much of the body has arrived, and how much there will be where
    /// the site said.
    pub fn received(self: *const Fetch) usize {
        return self.body.bytes.items.len;
    }

    pub fn expected(self: *const Fetch) ?u64 {
        return self.response.total;
    }

    /// Point at `target`, keeping the count of redirects that led here.
    fn aim(self: *Fetch, gpa: std.mem.Allocator, target: []const u8) void {
        self.reset(gpa);
        self.state = if (self.target.set(target)) .connecting else .{ .failed = error.BadAddress };
    }

    /// Let go of the connection and of whatever arrived on it.
    fn reset(self: *Fetch, gpa: std.mem.Allocator) void {
        self.closeWire();
        self.body.deinit(gpa);
        self.body = .{ .limit = limitOf(self.asking.wanted) };
        self.response = .{};
    }

    /// Reach the site and ask for the page. Blocks for as long as reaching
    /// it takes, which on a connection kept from the last answer is no time.
    fn connect(self: *Fetch, gpa: std.mem.Allocator) void {
        const where = url.parse(self.address()) orelse return self.fail(error.BadAddress);
        const kind: ulib.wire.Kind = switch (where.scheme) {
            .http => .plain,
            .https => .secure,
            .file => return self.fail(error.BadAddress),
        };
        if (self.refuses(where)) return self.fail(error.Blocked);
        self.reused = false;
        const wire = if (self.takeKept(where)) |kept| kept else ulib.wire.open(where.host, where.port, kind) catch |err| return self.fail(err);
        self.wire = wire;

        var stack: [http.REQUEST_MAX]u8 = undefined;
        // A POST carries its answers behind its head, which is more than a
        // request has room for here, so one that sends any is put together
        // in the heap and let go as soon as it is on the wire.
        const heap = switch (self.asking.sent) {
            .nothing => null,
            .form => |answers| gpa.alloc(u8, stack.len + answers.len) catch return self.fail(error.OutOfMemory),
        };
        defer if (heap) |room| gpa.free(room);
        const request = http.request(heap orelse &stack, where, self.asking) orelse return self.fail(error.BadAddress);
        if (wire.send(request) != request.len) return self.failOrRetry(error.Unreachable);
        // The answers are the caller's until they have gone. A fetch asked
        // for again without being given them again asks by GET.
        self.asking.sent = .nothing;

        self.state = .receiving;
        self.heard_us = sys.clockMicros();
    }

    /// The connection kept from the last answer, where it goes to `where`
    /// and the site has not closed it since. One that does not is closed.
    fn takeKept(self: *Fetch, where: url.Url) ?Wire {
        const kept = self.kept orelse return null;
        self.kept = null;
        if (!kept.goesTo(where) or kept.wire.finished()) {
            kept.wire.close();
            return null;
        }
        self.reused = true;
        return kept.wire;
    }

    /// Take whatever has arrived.
    fn pump(self: *Fetch, gpa: std.mem.Allocator) void {
        const wire = self.wire orelse return;
        var chunk: [4096]u8 = undefined;
        while (self.state == .receiving) {
            switch (wire.recv(&chunk)) {
                .got => |n| {
                    self.heard_us = sys.clockMicros();
                    self.response.feed(gpa, chunk[0..n], &self.body) catch |err| return self.fail(err);
                    if (self.response.phase == .done) self.arrived(gpa);
                },
                .quiet => return,
                .done => {
                    self.response.finish() catch |err| return self.failOrRetry(err);
                    self.arrived(gpa);
                },
            }
        }
    }

    /// Give up on a site that has gone quiet.
    fn stall(self: *Fetch, now_us: u64) void {
        if (self.state == .receiving and now_us -| self.heard_us >= STALL_US) self.fail(error.Stalled);
    }

    /// The answer is complete: the page, or somewhere else to ask.
    fn arrived(self: *Fetch, gpa: std.mem.Allocator) void {
        if (self.response_hook) |heard| heard(self.address(), &self.response);
        if (!self.response.redirects()) {
            self.keep();
            self.state = .done;
            return;
        }
        if (self.redirects == REDIRECTS_MAX) return self.fail(error.RedirectLoop);

        const base = url.parse(self.address()) orelse return self.fail(error.BadAddress);
        var next: [url.ADDRESS_MAX]u8 = undefined;
        const target = url.resolve(base, self.response.location().?, &next) orelse return self.fail(error.BadAddress);
        if (self.redirect_hook) |reported| reported(self.address(), target);
        // A redirect can cross hosts, paths, or both. The first request's
        // Cookie line is not the next request's: response cookies were just
        // taken above and the destination chooses which of them belongs.
        if (self.cookies_for) |cookies| self.asking.cookies = cookies(target);
        self.redirects += 1;
        self.aim(gpa, target);
    }

    /// A kept connection the site closed while it waited fails before any of
    /// the answer comes back. The request is sent again on a new connection,
    /// once; anything else is the fetch failing.
    fn failOrRetry(self: *Fetch, why: Failure) void {
        if (!self.reused or !self.response.head.isEmpty()) return self.fail(why);
        self.closeWire();
        self.reused = false;
        self.state = .connecting;
    }

    /// Keep the connection the answer came on for the next request, where
    /// the answer said it would be kept, and close it otherwise.
    fn keep(self: *Fetch) void {
        const wire = self.wire orelse return;
        self.wire = null;
        const where = url.parse(self.address()) orelse return wire.close();
        if (!self.response.reusable() or wire.finished()) return wire.close();
        var kept = Kept{ .wire = wire, .scheme = where.scheme, .port = where.port };
        if (!kept.host.set(where.host)) return wire.close();
        if (self.kept) |old| old.wire.close();
        self.kept = kept;
    }

    fn fail(self: *Fetch, why: Failure) void {
        self.closeWire();
        self.state = .{ .failed = why };
    }

    fn closeWire(self: *Fetch) void {
        if (self.wire) |wire| wire.close();
        self.wire = null;
    }
};
