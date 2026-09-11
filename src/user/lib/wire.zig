//! A connection, sealed or in the clear, asked the same questions either way.
//!
//! Two programs reach the network with TLS on top or without it: a chat
//! client whose networks say which, and a reader whose addresses do. Both ask
//! a connection the same five things, so the answers live here once, with
//! the reaching that makes one: the authorities are read the first time a
//! sealed connection wants them, and kept.
//!
//! What a failure is called stays with each program. The error says what
//! happened; a chat client says it could not reach a network, and a reader
//! that it could not reach a site, and both are right for the person reading
//! them.

const heap = @import("heap.zig");
const sock = @import("sock.zig");
const time = @import("time.zig");
const tls = @import("tls.zig");

/// What a read came to: bytes, nothing yet, or finished and why. Three
/// answers rather than a count, because a caller has to tell the second from
/// the third, and a connection that folded both into zero would leave a
/// window waiting on something that had already ended.
pub const Read = tls.Stream.Read;

/// Why a connection could not be made.
pub const Error = tls.Error;

pub const Wire = union(enum) {
    plain: sock.Sock,
    secure: *tls.Stream,

    /// As much of `bytes` as went, which for a sealed connection is all of
    /// them or none: a record is written whole.
    pub fn send(self: Wire, bytes: []const u8) usize {
        return switch (self) {
            .plain => |socket| socket.send(bytes),
            .secure => |stream| if (stream.send(bytes)) bytes.len else 0,
        };
    }

    pub fn recv(self: Wire, into: []u8) Read {
        return switch (self) {
            .plain => |socket| plain: {
                const n = socket.recv(into);
                if (n != 0) break :plain .{ .got = n };
                break :plain if (socket.state() == .closed) .{ .done = .cut } else .quiet;
            },
            .secure => |stream| stream.recv(into),
        };
    }

    /// What to wait on for there to be more.
    pub fn waitHandle(self: Wire) u32 {
        return switch (self) {
            .plain => |socket| socket.waitHandle(),
            .secure => |stream| stream.waitHandle(),
        };
    }

    pub fn finished(self: Wire) bool {
        return switch (self) {
            .plain => |socket| socket.state() == .closed,
            .secure => |stream| stream.ending != null or stream.socket.state() == .closed,
        };
    }

    pub fn close(self: Wire) void {
        switch (self) {
            .plain => |socket| socket.close(),
            .secure => |stream| stream.close(heap.allocator),
        }
    }
};

/// The authorities a sealed connection is checked against, read the first
/// time one is wanted. Parsing them is real work on this machine and the
/// answer is the same every time, so a program holds one of these for its
/// whole life.
pub const Trust = struct {
    roots: ?tls.Roots = null,

    fn get(self: *Trust, when: i64) Error!*tls.Roots {
        if (self.roots == null) self.roots = try tls.Roots.open(heap.allocator, when);
        return &self.roots.?;
    }
};

/// Reach `address` on `port`, sealed or not. `host` is the name that was
/// asked for rather than the address it resolved to, because that is what a
/// certificate is issued for.
pub fn open(trust: *Trust, address: u32, port: u16, host: []const u8, sealed: bool) Error!Wire {
    if (!sealed) {
        const socket = sock.Sock.connect(address, port) catch return error.Unreachable;
        return .{ .plain = socket };
    }

    // A clock that is not set reads as zero, which a sealed connection
    // refuses rather than checking a certificate's dates against nothing.
    const when = time.now();
    const roots = try trust.get(when);
    return .{ .secure = try tls.Stream.connect(heap.allocator, roots, address, port, host, when) };
}
