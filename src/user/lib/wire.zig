//! A connection to a named host, sealed or in the clear, asked the same
//! questions either way.
//!
//! What a program that talks over the network holds. It names a host, a port,
//! and whether what goes over the wire is sealed. Finding the host's address,
//! the handshake, and the authorities a sealed connection is checked against
//! all happen here, so a program never touches a socket, a certificate or a
//! name server of its own.
//!
//! What a failure is called stays with each program. The error says what
//! happened; a chat client says it could not reach a network, and a reader
//! that it could not reach a site, and both are right for the person reading
//! them.

const std = @import("std");
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
pub const Error = tls.Error || error{
    /// Nothing answers to the host's name.
    NoName,
};

/// Where the authorities a sealed connection is checked against are kept.
pub const AUTHORITIES = tls.STORE;

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

/// Which of the two a connection is, which is what reaching one asks.
pub const Kind = std.meta.Tag(Wire);

/// Reach `host` on `port`, in the clear or sealed. A sealed connection keeps
/// the name, because a certificate is issued for the name that was asked for
/// rather than for the address it resolved to.
pub fn open(host: []const u8, port: u16, kind: Kind) Error!Wire {
    const address = sock.addressOf(host) catch return error.NoName;
    switch (kind) {
        .plain => return .{ .plain = sock.Sock.connect(address, port) catch return error.Unreachable },
        .secure => {
            // A clock that is not set reads as zero, and a certificate's
            // dates checked against nothing say nothing.
            const when = time.now();
            if (when <= 0) return error.NoClock;
            return .{ .secure = try tls.Stream.connect(heap.allocator, try authorities(when), address, port, host, when) };
        },
    }
}

/// What the protocol called the last sealed connection it refused, for
/// saying why.
pub fn refusal() []const u8 {
    return tls.last_failure;
}

/// The authorities, read the first time a sealed connection wants them and
/// kept for the life of the program: parsing them is real work on this
/// machine, and the answer is the same every time.
var roots: ?tls.Roots = null;

fn authorities(when: i64) Error!*tls.Roots {
    if (roots == null) roots = try tls.Roots.open(heap.allocator, when);
    return &roots.?;
}
