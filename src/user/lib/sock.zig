//! The client side of a socket: rings in, rings out, events between.
//!
//! A tool asks `netd` for a socket and receives three handles with the
//! grant: the shared segment, the socket's own event, and the service's
//! doorbell. From then on data moves through `proto.socket` rings and the
//! channel is only for teardown. The tool produces tx and consumes rx;
//! ringing the doorbell says "produced", and the socket's event says the
//! service did.

const proto = @import("proto").net;
const socket = @import("proto").socket;
const std = @import("std");
const sys = @import("sys");

pub const Error = error{ NoService, Refused, TimedOut };

/// One granted socket, stream or datagram.
pub const Sock = struct {
    channel: u32,
    id: u32,
    shm: u32,
    ev_app: u32,
    doorbell: u32,
    view: socket.View,
    kind: socket.Kind,
    peer_addr: u32,
    peer_port: u16,

    /// A stream to `addr`:`port`. Blocks for the handshake.
    pub fn connect(addr: u32, port: u16) Error!Sock {
        return granted(.tcp_connect, 0, addr, port);
    }

    /// A datagram socket. A zero remote address only listens; a zero
    /// local port lets the stack pick one.
    pub fn udp(remote_addr: u32, remote_port: u16, local_port: u16) Error!Sock {
        const ports = proto.UdpPorts{ .remote = remote_port, .local = local_port };
        return granted(.udp_open, 0, remote_addr, @bitCast(ports));
    }

    /// As much of `bytes` as the tx ring takes, doorbell rung when any.
    pub fn send(self: *const Sock, bytes: []const u8) u32 {
        const n = self.view.tx.push(bytes);
        if (n != 0) _ = sys.eventSignal(self.doorbell);
        return n;
    }

    /// As much as `into` holds from the rx ring; consuming makes room,
    /// which the doorbell tells the service about.
    pub fn recv(self: *const Sock, into: []u8) u32 {
        const n = self.view.rx.pop(into);
        if (n != 0) _ = sys.eventSignal(self.doorbell);
        return n;
    }

    /// One whole datagram into the tx ring, or false when it does not
    /// fit yet. `addr` zero sends where the socket is connected.
    pub fn sendDatagram(self: *const Sock, addr: u32, port: u16, bytes: []const u8) bool {
        if (bytes.len > std.math.maxInt(u16)) return false;
        const len: u16 = @intCast(bytes.len);
        const span = socket.datagramSpan(len);
        if (self.view.tx.writable() < span) return false;

        const head = socket.DatagramHead{ .len = len, .port = port, .addr = addr };
        _ = self.view.tx.push(std.mem.asBytes(&head));
        _ = self.view.tx.push(bytes);
        const zeros: [8]u8 = @splat(0);
        _ = self.view.tx.push(zeros[0 .. span - @sizeOf(socket.DatagramHead) - len]);
        _ = sys.eventSignal(self.doorbell);
        return true;
    }

    pub const Datagram = struct { addr: u32, port: u16, len: u16 };

    /// The next datagram's payload into `into`, its origin in the result.
    /// A payload longer than `into` is truncated, the record consumed.
    pub fn recvDatagram(self: *const Sock, into: []u8) ?Datagram {
        var head = socket.DatagramHead{};
        if (self.view.rx.peek(std.mem.asBytes(&head), 0) < @sizeOf(socket.DatagramHead)) return null;
        const span = socket.datagramSpan(head.len);
        if (self.view.rx.readable() < span) return null;

        const take: u16 = @intCast(@min(head.len, into.len));
        _ = self.view.rx.peek(into[0..take], @sizeOf(socket.DatagramHead));
        self.view.rx.skip(span);
        _ = sys.eventSignal(self.doorbell);
        return .{ .addr = head.addr, .port = head.port, .len = take };
    }

    pub fn state(self: *const Sock) socket.State {
        return self.view.ctrl.state;
    }

    pub fn cause(self: *const Sock) socket.Cause {
        return self.view.ctrl.cause;
    }

    /// Nothing left unsent: the service consumed the whole tx ring.
    pub fn flushed(self: *const Sock) bool {
        return self.view.tx.readable() == 0;
    }

    /// The handle a wait set listens on for this socket's news.
    pub fn waitHandle(self: *const Sock) u32 {
        return self.ev_app;
    }

    /// Finish the conversation and give the handles back.
    pub fn close(self: *const Sock) void {
        var reply = proto.Rep{};
        callOn(self.channel, .{ .tag = .sock_close, .index = self.id }, &reply, &.{}, null) catch {};
        _ = sys.close(self.shm);
        _ = sys.close(self.ev_app);
        _ = sys.close(self.doorbell);
        _ = sys.close(self.channel);
    }
};

/// A listening port. `ready` carries a count per connection waiting, so a
/// caller waits in `wait_many` and accepts only what has already arrived.
pub const Listener = struct {
    channel: u32,
    id: u32,
    ready: u32,

    pub fn listen(port: u16) Error!Listener {
        const channel = try serviceChannel();
        errdefer _ = sys.close(channel);

        var reply = proto.Rep{};
        var handles: [1]u32 = undefined;
        try callOn(channel, .{ .tag = .tcp_listen, .param = port, .param2 = 1 }, &reply, &.{}, &handles);
        return .{ .channel = channel, .id = reply.body.listener, .ready = handles[0] };
    }

    /// The handle a wait set listens on for arrivals.
    pub fn waitHandle(self: *const Listener) u32 {
        return self.ready;
    }

    /// The next connection. Blocks until one arrives; waiting on `ready`
    /// first makes it return at once.
    pub fn accept(self: *const Listener) Error!Sock {
        var reply = proto.Rep{};
        var handles: [proto.GRANT_HANDLES]u32 = undefined;
        try callOn(self.channel, .{ .tag = .tcp_accept, .index = self.id }, &reply, &.{}, &handles);
        return fromGrant(try serviceChannel(), &reply, handles[0..proto.GRANT_HANDLES].*);
    }

    pub fn close(self: *const Listener) void {
        var reply = proto.Rep{};
        callOn(self.channel, .{ .tag = .sock_close, .index = self.id }, &reply, &.{}, null) catch {};
        _ = sys.close(self.ready);
        _ = sys.close(self.channel);
    }
};

/// A host argument to an address: dotted text parses directly, anything
/// else goes through the resolver. What every tool taking a host wants.
pub fn addressOf(name: []const u8) Error!u32 {
    if (@import("lib").ipv4.parse(name)) |addr| return addr;
    const answer = try resolve(name);
    return answer.addr;
}

/// A name to an address: the hosts table first, then DNS, netd asking.
pub fn resolve(name: []const u8) Error!proto.Resolved {
    const req = proto.ResolveReq.of(name) orelse return error.Refused;
    const channel = try serviceChannel();
    defer _ = sys.close(channel);

    const message = sys.Message.init(std.mem.asBytes(&req), &.{});
    var answer = sys.Message{};
    if (sys.callMsg(channel, &message, &answer) < 0) return error.Refused;
    const reply = repOf(&answer) orelse return error.Refused;
    if (reply.status != .ok) return error.Refused;
    return reply.body.resolved;
}

// ---------------------------------------------------------------------------
// The grant plumbing
// ---------------------------------------------------------------------------

fn granted(tag: proto.Tag, index: u32, param: u32, param2: u32) Error!Sock {
    const channel = try serviceChannel();
    errdefer _ = sys.close(channel);

    var reply = proto.Rep{};
    var handles: [proto.GRANT_HANDLES]u32 = undefined;
    try callOn(
        channel,
        .{ .tag = tag, .index = index, .param = param, .param2 = param2 },
        &reply,
        &.{},
        &handles,
    );
    return fromGrant(channel, &reply, handles);
}

fn fromGrant(channel: u32, reply: *const proto.Rep, handles: [proto.GRANT_HANDLES]u32) Error!Sock {
    const grant = reply.body.sock;
    const base = sys.shmMap(handles[0], .{ .writable = true }) orelse return error.Refused;
    return .{
        .channel = channel,
        .id = grant.sock,
        .shm = handles[0],
        .ev_app = handles[1],
        .doorbell = handles[2],
        .view = socket.View.of(base, grant.kind),
        .kind = grant.kind,
        .peer_addr = grant.peer_addr,
        .peer_port = grant.peer_port,
    };
}

fn serviceChannel() Error!u32 {
    const channel = sys.svcConnect(proto.SERVICE);
    if (channel < 0) return error.NoService;
    return @intCast(channel);
}

/// One request, one reply, the handles kept when the caller wants them:
/// however many the caller's slice asks for, in the order the reply sent.
fn callOn(
    channel: u32,
    request: proto.Req,
    reply: *proto.Rep,
    send_handles: []const u32,
    take_handles: ?[]u32,
) Error!void {
    const message = sys.Message.init(std.mem.asBytes(&request), send_handles);
    var answer = sys.Message{};
    if (sys.callMsg(channel, &message, &answer) < 0) return error.Refused;

    reply.* = (repOf(&answer) orelse return error.Refused).*;
    switch (reply.status) {
        .ok => {},
        .timed_out => return error.TimedOut,
        else => return error.Refused,
    }

    if (take_handles) |into| {
        const got = answer.handleSlice();
        if (got.len < into.len) return error.Refused;
        @memcpy(into, got[0..into.len]);
    }
}

fn repOf(answer: *const sys.Message) ?*const proto.Rep {
    const bytes = answer.bytes();
    if (bytes.len < @sizeOf(proto.Rep)) return null;
    return @ptrCast(@alignCast(bytes.ptr));
}
