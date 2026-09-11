//! One page coming over the network: reaching the site, asking for the page,
//! and taking the answer as it arrives.
//!
//! Driven from outside rather than running on its own: `advance` takes the
//! next step and says what to wait on before the one after, and a window and
//! a shell each wait in their own way. Reaching a site blocks, because a TLS
//! handshake is several round trips and there is no half of one to come
//! back to; every step after it takes what has arrived and returns. So a
//! window paints "connecting" before it takes the step that blocks, and
//! stays drawn while a page arrives a piece at a time.

const std = @import("std");
const sys = @import("sys");
const ulib = @import("ulib");

const http = @import("http.zig");
const url = @import("url.zig");

const Wire = ulib.wire.Wire;

/// The most a page may be.
///
/// Four megabytes covers an article with its scripts and stylesheets written
/// into it, which is most of what an ordinary page weighs now. Past it the
/// page is refused rather than cut: half a document parses into a tree that
/// is wrong in ways nothing downstream can see.
pub const PAGE_MAX = 4 * 1024 * 1024;

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

pub const Fetch = struct {
    state: State = .idle,
    /// Where the page is: the address asked for, or after a redirect the one
    /// it was sent on to.
    target: url.Address = .{},

    wire: ?Wire = null,
    response: http.Response = .{},
    body: http.Body = .{ .limit = PAGE_MAX },
    redirects: u8 = 0,

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

    /// Begin fetching `target`. Nothing is sent until the first step.
    pub fn begin(self: *Fetch, gpa: std.mem.Allocator, target: []const u8) void {
        self.redirects = 0;
        self.started_us = sys.clockMicros();
        self.aim(gpa, target);
    }

    /// Take the next step, and say what to wait on before the one after.
    pub fn advance(self: *Fetch, gpa: std.mem.Allocator) Wait {
        switch (self.state) {
            .connecting => self.connect(),
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

    /// Stop, and give back everything held.
    pub fn cancel(self: *Fetch, gpa: std.mem.Allocator) void {
        self.reset(gpa);
        self.state = .idle;
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
        self.body = .{ .limit = PAGE_MAX };
        self.response = .{};
    }

    /// Reach the site and ask for the page. Blocks for as long as reaching
    /// it takes.
    fn connect(self: *Fetch) void {
        const where = url.parse(self.address()) orelse return self.fail(error.BadAddress);
        const kind: ulib.wire.Kind = switch (where.scheme) {
            .http => .plain,
            .https => .secure,
            .file => return self.fail(error.BadAddress),
        };
        const wire = ulib.wire.open(where.host, where.port, kind) catch |err| return self.fail(err);
        self.wire = wire;

        var buf: [url.ADDRESS_MAX + 512]u8 = undefined;
        const request = http.request(&buf, where) orelse return self.fail(error.BadAddress);
        if (wire.send(request) != request.len) return self.fail(error.Unreachable);

        self.state = .receiving;
        self.heard_us = sys.clockMicros();
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
                    self.response.finish() catch |err| return self.fail(err);
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
        if (!self.response.redirects()) {
            self.closeWire();
            self.state = .done;
            return;
        }
        if (self.redirects == REDIRECTS_MAX) return self.fail(error.RedirectLoop);

        const base = url.parse(self.address()) orelse return self.fail(error.BadAddress);
        var next: [url.ADDRESS_MAX]u8 = undefined;
        const target = url.resolve(base, self.response.location().?, &next) orelse return self.fail(error.BadAddress);
        self.redirects += 1;
        self.aim(gpa, target);
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
