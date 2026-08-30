//! The socket bridge: streams and datagrams carried over shared rings.
//!
//! Data never crosses the service channel. A granted socket is a shared
//! segment (control page and two rings, `proto.socket`), an event netd
//! signals when there is something to read or room to write, and one
//! doorbell every client shares to say "someone produced". netd walks its
//! socket table on each doorbell wake, which is what keeps the wait set
//! fixed however many sockets exist.
//!
//! Slots own their segment for the service's lifetime and hand the same
//! one to each successive socket, because segments cannot be unmapped:
//! reuse makes socket churn allocation-free. One socket lives on a slot
//! at a time; the tools are this machine's own.
//!
//! Establishment is deferred the way ping is: the reply token waits for
//! the handshake, the next connection, or the resolver, so a client's
//! call blocks exactly as long as the network does.

const hosts = @import("lib").hosts;
const log = @import("ulib").log;
const lwip = @import("lwip.zig");
const out = @import("ulib").out;
const proto = @import("proto").net;
const socket = @import("proto").socket;
const std = @import("std");
const sys = @import("sys");

const MAX_SOCKS = 8;
const MAX_RESOLVES = 4;
const BACKLOG = 4;
const HOSTS_PATH = "/etc/hosts";

const Kind = enum { free, tcp, listener, udp };

const Sock = struct {
    kind: Kind = .free,
    tcp: ?*lwip.TcpPcb = null,
    udp: ?*lwip.UdpPcb = null,

    /// The slot's permanent segment and event, made on first use.
    shm: u32 = 0,
    ev_app: u32 = 0,
    view: ?socket.View = null,

    /// A connect or accept whose reply waits.
    pending: bool = false,
    pending_token: u32 = 0,

    /// Received bytes the ring could not yet take: one pbuf held back,
    /// consumed from `held_at` as the client makes room.
    held: ?*lwip.Pbuf = null,
    held_at: u16 = 0,

    /// Connections a listener accepted before anyone asked.
    backlog: [BACKLOG]?*lwip.TcpPcb = @splat(null),

    peer_addr: u32 = 0,
    peer_port: u16 = 0,
};

var socks: [MAX_SOCKS]Sock = @splat(.{});
var resolves: [MAX_RESOLVES]Resolve = @splat(.{});
var service: u32 = 0;
var doorbell: u32 = 0;

const Resolve = struct {
    used: bool = false,
    token: u32 = 0,
    /// The name, zero terminated, alive until the resolver answers.
    name: [proto.ResolveReq.NAME_MAX + 1]u8 = @splat(0),
    addr: lwip.Ip4Addr = .{},
};

/// Make the doorbell and remember the channel replies go out on. Returns
/// the doorbell for the event loop's wait set.
pub fn init(channel: u32) ?u32 {
    service = channel;
    const bell = sys.eventCreate();
    if (bell < 0) return null;
    doorbell = @intCast(bell);
    return doorbell;
}

/// One request from the channel. Everything socket-shaped lands here; the
/// reply goes out now or when the network answers.
pub fn handle(message: *const sys.Message, token: u32) void {
    const bytes = message.bytes();
    if (bytes.len < @sizeOf(proto.Req)) return refuse(token);
    const req: *const proto.Req = @ptrCast(@alignCast(bytes.ptr));

    switch (req.tag) {
        .tcp_connect => tcpConnect(req, token),
        .tcp_listen => tcpListen(req, token),
        .tcp_accept => tcpAccept(req, token),
        .udp_open => udpOpen(req, token),
        .sock_close => sockClose(req, token),
        .resolve => resolve(bytes, token),
        else => refuse(token),
    }
}

/// The doorbell rang: some client produced. Walk every live socket and
/// move what moved.
pub fn drainRings() void {
    for (&socks) |*s| {
        switch (s.kind) {
            .tcp => {
                drainTcpTx(s);
                drainHeldRx(s);
            },
            .udp => drainUdpTx(s),
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Ops
// ---------------------------------------------------------------------------

fn tcpConnect(req: *const proto.Req, token: u32) void {
    const s = takeSlot(.tcp) orelse return refuse(token);
    const pcb = lwip.tcp_new() orelse {
        s.kind = .free;
        return refuse(token);
    };
    s.tcp = pcb;
    lwip.tcp_arg(pcb, s);
    lwip.tcp_recv(pcb, recvCb);
    lwip.tcp_sent(pcb, sentCb);
    lwip.tcp_err(pcb, errCb);

    s.peer_addr = req.param;
    s.peer_port = @truncate(req.param2);
    const to = lwip.toWire(req.param);
    if (lwip.tcp_connect(pcb, &to, s.peer_port, connectedCb) != .ok) {
        dropPcb(s);
        s.kind = .free;
        return refuse(token);
    }
    s.pending = true;
    s.pending_token = token;
}

fn tcpListen(req: *const proto.Req, token: u32) void {
    const s = takeSlot(.listener) orelse return refuse(token);
    const fresh = lwip.tcp_new() orelse {
        s.kind = .free;
        return refuse(token);
    };

    const any = lwip.Ip4Addr{};
    if (lwip.tcp_bind(fresh, &any, @truncate(req.param)) != .ok) {
        lwip.tcp_abort(fresh);
        s.kind = .free;
        return refuse(token);
    }

    // Listening swaps the pcb for a smaller one; the original is spent.
    const backlog: u8 = @truncate(@min(@max(req.param2, 1), BACKLOG));
    const listening = lwip.tcp_listen_with_backlog(fresh, backlog) orelse {
        lwip.tcp_abort(fresh);
        s.kind = .free;
        return refuse(token);
    };
    s.tcp = listening;
    lwip.tcp_arg(listening, s);
    lwip.tcp_accept(listening, acceptCb);

    var reply = proto.Rep{ .body = .{ .listener = indexOf(s) } };
    replyPlain(token, &reply);
}

fn tcpAccept(req: *const proto.Req, token: u32) void {
    const s = sockAt(req.index, .listener) orelse return refuse(token);
    if (s.pending) return refuse(token);

    // A connection that arrived before the question is answered from the
    // backlog; otherwise the token waits for the next one.
    for (&s.backlog) |*held| {
        if (held.*) |pcb| {
            held.* = null;
            grantAccepted(pcb, token);
            return;
        }
    }
    s.pending = true;
    s.pending_token = token;
}

fn udpOpen(req: *const proto.Req, token: u32) void {
    const s = takeSlot(.udp) orelse return refuse(token);
    const view = slotView(s, .udp) orelse {
        s.kind = .free;
        return refuse(token);
    };
    const pcb = lwip.udp_new() orelse {
        s.kind = .free;
        return refuse(token);
    };
    s.udp = pcb;

    const ports: proto.UdpPorts = @bitCast(req.param2);
    const any = lwip.Ip4Addr{};
    if (lwip.udp_bind(pcb, &any, ports.local) != .ok) {
        lwip.udp_remove(pcb);
        s.udp = null;
        s.kind = .free;
        return refuse(token);
    }
    if (req.param != 0) {
        const to = lwip.toWire(req.param);
        if (lwip.udp_connect(pcb, &to, ports.remote) != .ok) {
            lwip.udp_remove(pcb);
            s.udp = null;
            s.kind = .free;
            return refuse(token);
        }
    }
    lwip.udp_recv(pcb, udpRecvCb, s);

    s.peer_addr = req.param;
    s.peer_port = ports.remote;
    view.ctrl.state = .established;
    grant(s, token, .udp);
}

fn sockClose(req: *const proto.Req, token: u32) void {
    const index = req.index;
    if (index >= MAX_SOCKS) return refuse(token);
    const s = &socks[index];

    switch (s.kind) {
        .tcp => {
            // What the client pushed before asking to finish still goes
            // out; the FIN follows the data.
            drainTcpTx(s);
            if (s.view) |view| {
                if (view.ctrl.state != .closed) {
                    view.ctrl.state = .closed;
                    view.ctrl.cause = .finished;
                }
            }
            dropHeld(s);
            if (s.tcp) |pcb| {
                quietPcb(pcb);
                // A refused graceful close leaves the pcb, so the abort
                // path is what guarantees the slot comes back.
                if (lwip.tcp_close(pcb) != .ok) lwip.tcp_abort(pcb);
                s.tcp = null;
            }
        },
        .listener => {
            for (&s.backlog) |*held| {
                if (held.*) |pcb| {
                    lwip.tcp_abort(pcb);
                    held.* = null;
                }
            }
            if (s.pending) refuse(s.pending_token);
            s.pending = false;
            if (s.tcp) |pcb| {
                quietPcb(pcb);
                if (lwip.tcp_close(pcb) != .ok) lwip.tcp_abort(pcb);
                s.tcp = null;
            }
        },
        .udp => {
            drainUdpTx(s);
            if (s.udp) |pcb| {
                lwip.udp_remove(pcb);
                s.udp = null;
            }
        },
        .free => return refuse(token),
    }

    s.kind = .free;
    var reply = proto.Rep{};
    replyPlain(token, &reply);
}

fn resolve(bytes: []const u8, token: u32) void {
    if (bytes.len < @sizeOf(proto.ResolveReq)) return refuse(token);
    const req: *const proto.ResolveReq = @ptrCast(@alignCast(bytes.ptr));
    const name = req.slice();
    if (name.len == 0) return refuse(token);

    // The hosts table outranks every server, which is what makes a name
    // answerable on a machine with no network at all.
    var table: [2048]u8 = undefined;
    if (readHosts(&table)) |text| {
        if (hosts.lookup(text, name)) |addr| {
            var reply = proto.Rep{ .body = .{ .resolved = .{
                .addr = addr,
                .source = .hosts,
            } } };
            return replyPlain(token, &reply);
        }
    }

    const slot = takeResolve() orelse return refuse(token);
    slot.token = token;
    @memcpy(slot.name[0..name.len], name);
    slot.name[name.len] = 0;

    const asked: [*:0]const u8 = @ptrCast(&slot.name);
    switch (lwip.dns_gethostbyname(asked, &slot.addr, dnsFoundCb, slot)) {
        .ok => {
            answerResolve(slot, lwip.fromWire(slot.addr));
        },
        .inprogress => {},
        else => {
            slot.used = false;
            refuse(token);
        },
    }
}

// ---------------------------------------------------------------------------
// lwIP calling back
// ---------------------------------------------------------------------------

fn connectedCb(arg: ?*anyopaque, pcb: *lwip.TcpPcb, err: lwip.Err) callconv(.c) lwip.Err {
    _ = pcb;
    _ = err;
    const s = sockOf(arg) orelse return .ok;
    if (s.view) |view| view.ctrl.state = .established;
    sayPeer(s, "stream open to ");
    if (s.pending) {
        s.pending = false;
        grant(s, s.pending_token, .tcp);
    }
    return .ok;
}

fn recvCb(arg: ?*anyopaque, pcb: *lwip.TcpPcb, p: ?*lwip.Pbuf, err: lwip.Err) callconv(.c) lwip.Err {
    _ = err;
    const s = sockOf(arg) orelse {
        if (p) |pb| _ = lwip.pbuf_free(pb);
        return .ok;
    };
    const view = s.view orelse return .ok;

    const pb = p orelse {
        // The peer finished sending; what is already in the ring stays
        // readable, and the state says why nothing more will follow.
        if (view.ctrl.state == .established) view.ctrl.state = .peer_closed;
        _ = sys.eventSignal(s.ev_app);
        return .ok;
    };

    // One delivery may be held back while the client drains; a second
    // stays with lwIP, which re-offers it with the next segment.
    if (s.held != null) return .mem;

    _ = pcb;
    s.held = pb;
    s.held_at = 0;
    drainHeldRx(s);
    return .ok;
}

fn sentCb(arg: ?*anyopaque, pcb: *lwip.TcpPcb, len: u16) callconv(.c) lwip.Err {
    _ = pcb;
    _ = len;
    const s = sockOf(arg) orelse return .ok;
    // Acknowledged bytes freed send-queue room: move more of the ring,
    // and tell the client, whose push may have been refused.
    drainTcpTx(s);
    _ = sys.eventSignal(s.ev_app);
    return .ok;
}

fn errCb(arg: ?*anyopaque, err: lwip.Err) callconv(.c) void {
    const s = sockOf(arg) orelse return;
    // The pcb is already gone.
    s.tcp = null;
    dropHeld(s);

    if (s.view) |view| {
        const opening = view.ctrl.state == .opening;
        view.ctrl.state = .closed;
        view.ctrl.cause = switch (err) {
            .rst => if (opening) socket.Cause.refused else socket.Cause.reset,
            .abrt => .aborted,
            else => .aborted,
        };
    }
    if (s.pending) {
        s.pending = false;
        refuse(s.pending_token);
        s.kind = .free;
    }
    _ = sys.eventSignal(s.ev_app);
}

fn acceptCb(arg: ?*anyopaque, newpcb: ?*lwip.TcpPcb, err: lwip.Err) callconv(.c) lwip.Err {
    const s = sockOf(arg) orelse return .ok;
    const pcb = newpcb orelse return .ok;
    if (err != .ok) return .ok;

    if (s.pending) {
        s.pending = false;
        grantAccepted(pcb, s.pending_token);
        return .ok;
    }
    for (&s.backlog) |*held| {
        if (held.* == null) {
            held.* = pcb;
            return .ok;
        }
    }
    // Nobody asking and nowhere to keep it.
    lwip.tcp_abort(pcb);
    return .abrt;
}

fn udpRecvCb(
    arg: ?*anyopaque,
    pcb: *lwip.UdpPcb,
    p: *lwip.Pbuf,
    addr: *const lwip.Ip4Addr,
    port: u16,
) callconv(.c) void {
    _ = pcb;
    defer _ = lwip.pbuf_free(p);
    const s = sockOf(arg) orelse return;
    const view = s.view orelse return;

    // A datagram enters whole or not at all; a full ring drops it, which
    // is what datagrams are for.
    const span = socket.datagramSpan(p.tot_len);
    if (view.rx.writable() < span) return;

    const head = socket.DatagramHead{
        .len = p.tot_len,
        .port = port,
        .addr = lwip.fromWire(addr.*),
    };
    _ = view.rx.push(std.mem.asBytes(&head));
    pushPbuf(view.rx, p, 0, p.tot_len);
    const pad = span - @sizeOf(socket.DatagramHead) - p.tot_len;
    const zeros: [8]u8 = @splat(0);
    _ = view.rx.push(zeros[0..pad]);

    _ = sys.eventSignal(s.ev_app);
}

fn dnsFoundCb(name: [*:0]const u8, addr: ?*const lwip.Ip4Addr, arg: ?*anyopaque) callconv(.c) void {
    _ = name;
    const slot: *Resolve = @ptrCast(@alignCast(arg orelse return));
    if (!slot.used) return;
    const found = addr orelse {
        const token = slot.token;
        slot.used = false;
        return refuse(token);
    };
    answerResolve(slot, lwip.fromWire(found.*));
}

// ---------------------------------------------------------------------------
// Moving bytes
// ---------------------------------------------------------------------------

/// Ring to stack: write as much tx as the send queue takes, consuming only
/// what was accepted, then let the segments go out.
fn drainTcpTx(s: *Sock) void {
    const view = s.view orelse return;
    const pcb = s.tcp orelse return;
    if (view.ctrl.state == .opening) return;

    var moved = false;
    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = view.tx.peek(&chunk, 0);
        if (n == 0) break;
        if (lwip.tcp_write(pcb, &chunk, @intCast(n), lwip.TCP_WRITE_COPY) != .ok) break;
        view.tx.skip(n);
        moved = true;
    }
    if (moved) {
        _ = lwip.tcp_output(pcb);
        // Consumed ring bytes are room the client may be waiting for.
        _ = sys.eventSignal(s.ev_app);
    }
}

/// The held delivery into the ring, as far as it goes. Frees and
/// acknowledges what enters; the window only reopens for consumed bytes.
fn drainHeldRx(s: *Sock) void {
    const view = s.view orelse return;
    const pb = s.held orelse return;

    var chunk: [512]u8 = undefined;
    var entered: u16 = 0;
    while (s.held_at < pb.tot_len) {
        const want: u16 = @min(chunk.len, pb.tot_len - s.held_at);
        const got = lwip.pbuf_copy_partial(pb, &chunk, want, s.held_at);
        if (got == 0) break;
        const took: u16 = @truncate(view.rx.push(chunk[0..got]));
        s.held_at += took;
        entered += took;
        if (took < got) break;
    }

    if (entered != 0) {
        if (s.tcp) |pcb| lwip.tcp_recved(pcb, entered);
        _ = sys.eventSignal(s.ev_app);
    }
    if (s.held_at >= pb.tot_len) {
        _ = lwip.pbuf_free(pb);
        s.held = null;
        s.held_at = 0;
    }
}

/// Ring to stack, datagram at a time: each record leaves whole, and a
/// half-written record waits for its rest.
fn drainUdpTx(s: *Sock) void {
    const view = s.view orelse return;
    const pcb = s.udp orelse return;

    var moved = false;
    while (true) {
        var head = socket.DatagramHead{};
        if (view.tx.peek(std.mem.asBytes(&head), 0) < @sizeOf(socket.DatagramHead)) break;
        const span = socket.datagramSpan(head.len);
        if (view.tx.readable() < span) break;

        const p = lwip.pbuf_alloc(.transport, head.len, .ram) orelse break;
        var filled: u16 = 0;
        var chunk: [512]u8 = undefined;
        while (filled < head.len) {
            const want: u16 = @min(chunk.len, head.len - filled);
            const got = view.tx.peek(chunk[0..want], @sizeOf(socket.DatagramHead) + filled);
            if (got == 0) break;
            _ = lwip.pbuf_take_at(p, &chunk, @truncate(got), filled);
            filled += @truncate(got);
        }

        const sent = if (head.addr != 0) blk: {
            const to = lwip.toWire(head.addr);
            break :blk lwip.udp_sendto(pcb, p, &to, head.port);
        } else lwip.udp_send(pcb, p);
        _ = lwip.pbuf_free(p);
        _ = sent;

        view.tx.skip(span);
        moved = true;
    }
    if (moved) _ = sys.eventSignal(s.ev_app);
}

/// A pbuf chain into a ring, from `from`, at most `len` bytes.
fn pushPbuf(ring: anytype, p: *lwip.Pbuf, from: u16, len: u16) void {
    var chunk: [512]u8 = undefined;
    var at = from;
    const end = from + len;
    while (at < end) {
        const want: u16 = @min(chunk.len, end - at);
        const got = lwip.pbuf_copy_partial(p, &chunk, want, at);
        if (got == 0) return;
        _ = ring.push(chunk[0..got]);
        at += got;
    }
}

// ---------------------------------------------------------------------------
// Slots, grants and replies
// ---------------------------------------------------------------------------

fn takeSlot(kind: Kind) ?*Sock {
    for (&socks) |*s| {
        if (s.kind != .free) continue;
        s.kind = kind;
        s.pending = false;
        s.held = null;
        s.held_at = 0;
        s.backlog = @splat(null);
        s.tcp = null;
        s.udp = null;
        return s;
    }
    log.warn("netd", "every socket slot is spoken for");
    return null;
}

/// The slot's permanent segment, sized for the larger kind and re-dressed
/// for this use: fresh indices, opening state.
fn slotView(s: *Sock, kind: socket.Kind) ?socket.View {
    if (s.view == null) {
        const created = sys.shmCreate(socket.shmBytes(.tcp));
        if (created < 0) return null;
        const base = sys.shmMap(@intCast(created), .{ .writable = true }) orelse {
            _ = sys.close(@intCast(created));
            return null;
        };
        const ev = sys.eventCreate();
        if (ev < 0) return null;
        s.shm = @intCast(created);
        s.ev_app = @intCast(ev);
        s.view = socket.View.of(base, kind);
    } else {
        const base: [*]u8 = @ptrCast(@volatileCast(s.view.?.ctrl));
        s.view = socket.View.of(base, kind);
    }

    const view = s.view.?;
    view.ctrl.* = .{};
    return view;
}

fn sockAt(index: u32, kind: Kind) ?*Sock {
    if (index >= MAX_SOCKS) return null;
    const s = &socks[index];
    if (s.kind != kind) return null;
    return s;
}

fn sockOf(arg: ?*anyopaque) ?*Sock {
    return @ptrCast(@alignCast(arg orelse return null));
}

fn indexOf(s: *Sock) u32 {
    return @intCast((@intFromPtr(s) - @intFromPtr(&socks)) / @sizeOf(Sock));
}

/// An accepted connection into its own slot, granted to whoever asked.
fn grantAccepted(pcb: *lwip.TcpPcb, token: u32) void {
    const s = takeSlot(.tcp) orelse {
        lwip.tcp_abort(pcb);
        return refuse(token);
    };
    s.tcp = pcb;
    lwip.tcp_arg(pcb, s);
    lwip.tcp_recv(pcb, recvCb);
    lwip.tcp_sent(pcb, sentCb);
    lwip.tcp_err(pcb, errCb);
    const peer = lwip.tcpPeer(pcb);
    s.peer_addr = peer.addr;
    s.peer_port = peer.port;
    sayPeer(s, "stream accepted from ");
    grant(s, token, .tcp);
}

/// The granting reply: the socket's numbers and the three handles.
fn grant(s: *Sock, token: u32, kind: socket.Kind) void {
    const view = slotView(s, kind) orelse {
        log.warn("netd", "no segment for the socket");
        dropPcb(s);
        s.kind = .free;
        return refuse(token);
    };
    view.ctrl.state = .established;

    var reply = proto.Rep{ .body = .{ .sock = .{
        .sock = indexOf(s),
        .peer_addr = s.peer_addr,
        .peer_port = s.peer_port,
        .kind = kind,
    } } };

    var message = sys.Message.init(std.mem.asBytes(&reply), &.{ s.shm, s.ev_app, doorbell });
    const rc = sys.replyMsg(service, token, &message);
    if (rc < 0) {
        log.warn("netd", "the grant reply was refused");
    } else {
        log.say("netd", .dim, "socket granted");
    }
}

fn quietPcb(pcb: *lwip.TcpPcb) void {
    lwip.tcp_arg(pcb, null);
}

fn dropPcb(s: *Sock) void {
    if (s.tcp) |pcb| {
        quietPcb(pcb);
        lwip.tcp_abort(pcb);
        s.tcp = null;
    }
    if (s.udp) |pcb| {
        lwip.udp_remove(pcb);
        s.udp = null;
    }
}

fn dropHeld(s: *Sock) void {
    if (s.held) |pb| {
        _ = lwip.pbuf_free(pb);
        s.held = null;
        s.held_at = 0;
    }
}

fn takeResolve() ?*Resolve {
    for (&resolves) |*r| {
        if (r.used) continue;
        r.used = true;
        r.name = @splat(0);
        return r;
    }
    return null;
}

fn answerResolve(slot: *Resolve, addr: u32) void {
    const token = slot.token;
    slot.used = false;
    var reply = proto.Rep{ .body = .{ .resolved = .{ .addr = addr, .source = .dns } } };
    replyPlain(token, &reply);
}

fn readHosts(buf: []u8) ?[]const u8 {
    const file = sys.open(HOSTS_PATH, .{});
    if (file < 0) return null;
    defer _ = sys.close(@intCast(file));
    const n = sys.read(@intCast(file), buf);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

fn refuse(token: u32) void {
    var reply = proto.Rep{ .status = .refused };
    replyPlain(token, &reply);
}

fn replyPlain(token: u32, reply: *const proto.Rep) void {
    var message = sys.Message.init(std.mem.asBytes(reply), &.{});
    _ = sys.replyMsg(service, token, &message);
}

fn sayPeer(s: *Sock, what: []const u8) void {
    log.begin("netd", .dim);
    out.text(what);
    var field: [21]u8 = undefined;
    out.text(@import("lib").ipv4.textWithPort(s.peer_addr, s.peer_port, &field));
    log.end();
}
