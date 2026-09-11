//! One page coming over the network: reaching the site, asking for the page,
//! and taking the answer as it arrives.
//!
//! Driven from outside rather than running on its own. The caller says when
//! the moment has come to reach the site, and when the connection has
//! something. Reaching one blocks, because a TLS handshake is several round
//! trips and there is no half of one to come back to; everything after it
//! takes what has arrived and returns. So a window paints "connecting"
//! before it asks for the part that blocks, and stays drawn while a page
//! arrives a piece at a time.

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

pub const Phase = enum {
    idle,
    /// The site is to be reached at the next chance, which blocks.
    connecting,
    /// Asked, and taking what arrives.
    receiving,
    done,
    failed,
};

/// Why a page did not arrive.
pub const Failure = enum {
    /// Nothing answers to the name.
    no_name,
    /// The site could not be reached at all.
    cannot_reach,
    /// Reached, and the TLS handshake failed. `ulib.tls.last_failure` has
    /// the protocol's own word for why.
    refused,
    no_clock,
    no_authorities,
    no_randomness,
    /// What came back was not HTTP.
    malformed,
    too_large,
    /// The connection ended before the page did.
    truncated,
    /// The site closed the connection without answering.
    unanswered,
    /// Sent on somewhere else more times than a page should need.
    redirect_loop,
    /// The site said nothing for too long.
    stalled,
    out_of_memory,
};

pub const Fetch = struct {
    phase: Phase = .idle,
    failure: Failure = .malformed,

    /// Where the page is: the address asked for, or after a redirect the one
    /// it was sent on to.
    address_buf: [url.ADDRESS_MAX]u8 = undefined,
    address_len: usize = 0,

    wire: ?Wire = null,
    response: http.Response = .{},
    body: http.Body = .{ .limit = PAGE_MAX },
    redirects: u8 = 0,

    /// When the fetch began, and when the site last said anything.
    started_us: u64 = 0,
    heard_us: u64 = 0,

    pub fn address(self: *const Fetch) []const u8 {
        return self.address_buf[0..self.address_len];
    }

    /// The host being reached, for saying so.
    pub fn host(self: *const Fetch) []const u8 {
        const where = url.parse(self.address()) orelse return self.address();
        return where.host;
    }

    /// Begin fetching `target`. Nothing is sent until `connect`.
    pub fn begin(self: *Fetch, gpa: std.mem.Allocator, target: []const u8) void {
        self.cancel(gpa);
        self.redirects = 0;
        self.started_us = sys.clockMicros();
        self.aim(gpa, target);
    }

    /// Point at `target`, keeping the count of redirects that led here.
    fn aim(self: *Fetch, gpa: std.mem.Allocator, target: []const u8) void {
        self.closeWire();
        self.body.deinit(gpa);
        self.body = .{ .limit = PAGE_MAX };
        self.response = .{};
        const len = @min(target.len, self.address_buf.len);
        @memcpy(self.address_buf[0..len], target[0..len]);
        self.address_len = len;
        self.phase = .connecting;
    }

    /// Reach the site and ask for the page. Blocks for as long as reaching
    /// it takes.
    pub fn connect(self: *Fetch, trust: *ulib.wire.Trust) void {
        if (self.phase != .connecting) return;
        const where = url.parse(self.address()) orelse return self.fail(.malformed);

        const addr = ulib.sock.addressOf(where.host) catch return self.fail(.no_name);
        const wire = ulib.wire.open(trust, addr, where.port, where.host, where.scheme.sealed()) catch |err|
            return self.fail(switch (err) {
                error.Unreachable => .cannot_reach,
                error.Refused => .refused,
                error.NoClock => .no_clock,
                error.NoAuthorities => .no_authorities,
                error.NoRandomness => .no_randomness,
                error.OutOfMemory => .out_of_memory,
            });
        self.wire = wire;

        var buf: [url.ADDRESS_MAX + 512]u8 = undefined;
        const request = http.request(&buf, where.host, where.port, where.scheme.defaultPort(), where.path) orelse
            return self.fail(.malformed);
        if (wire.send(request) != request.len) return self.fail(.cannot_reach);

        self.phase = .receiving;
        self.heard_us = sys.clockMicros();
    }

    /// Take whatever has arrived.
    pub fn pump(self: *Fetch, gpa: std.mem.Allocator) void {
        if (self.phase != .receiving) return;
        const wire = self.wire orelse return;

        var chunk: [4096]u8 = undefined;
        while (self.phase == .receiving) {
            switch (wire.recv(&chunk)) {
                .got => |n| {
                    self.heard_us = sys.clockMicros();
                    self.response.feed(gpa, chunk[0..n], &self.body) catch |err| return self.fail(failureOf(err));
                    if (self.response.phase == .done) self.arrived(gpa);
                },
                .quiet => return,
                .done => {
                    self.response.finish() catch |err| return self.fail(failureOf(err));
                    self.arrived(gpa);
                },
            }
        }
    }

    /// Give up on a site that has gone quiet. True when this is what ended
    /// the fetch.
    pub fn stall(self: *Fetch, now_us: u64) bool {
        if (self.phase != .receiving or now_us -| self.heard_us < STALL_US) return false;
        self.fail(.stalled);
        return true;
    }

    /// Stop, and give back everything held.
    pub fn cancel(self: *Fetch, gpa: std.mem.Allocator) void {
        self.closeWire();
        self.body.deinit(gpa);
        self.body = .{ .limit = PAGE_MAX };
        self.response = .{};
        self.phase = .idle;
    }

    pub fn waitHandle(self: *const Fetch) ?u32 {
        const wire = self.wire orelse return null;
        return wire.waitHandle();
    }

    /// How much of the body has arrived, and how much there will be when the
    /// site said.
    pub fn received(self: *const Fetch) usize {
        return self.body.bytes.items.len;
    }

    pub fn expected(self: *const Fetch) ?u64 {
        return self.response.total;
    }

    fn arrived(self: *Fetch, gpa: std.mem.Allocator) void {
        self.closeWire();
        if (!self.response.redirects()) {
            self.phase = .done;
            return;
        }
        if (self.redirects == REDIRECTS_MAX) return self.fail(.redirect_loop);

        const base = url.parse(self.address()) orelse return self.fail(.malformed);
        var next: [url.ADDRESS_MAX]u8 = undefined;
        const target = url.resolve(base, self.response.location().?, &next) orelse return self.fail(.malformed);
        self.redirects += 1;
        self.aim(gpa, target);
    }

    fn fail(self: *Fetch, why: Failure) void {
        self.closeWire();
        self.failure = why;
        self.phase = .failed;
    }

    fn closeWire(self: *Fetch) void {
        if (self.wire) |wire| wire.close();
        self.wire = null;
    }
};

fn failureOf(err: http.Error) Failure {
    return switch (err) {
        error.HeadTooLong, error.Malformed => .malformed,
        error.TooLarge => .too_large,
        error.Truncated => .truncated,
        error.Unanswered => .unanswered,
        error.OutOfMemory => .out_of_memory,
    };
}
