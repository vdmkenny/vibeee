//! The socket bridge: streams and datagrams carried over shared rings.
//!
//! Data never crosses the service channel. A granted socket is a shared
//! segment (control page and two rings, `proto.socket`), an event netd
//! signals when there is something to read or room to write, and one
//! doorbell every client shares to say "someone produced". netd walks its
//! socket table on each doorbell wake, which is what keeps the wait set
//! fixed however many sockets exist.
//!
//! A socket's segment and event belong to that socket alone, and go back
//! when it does. Reusing a slot's segment across sockets was cheaper and
//! was also a hole: a client that closed still held the handles, and the
//! next client granted that slot inherited a segment and an event somebody
//! else could still write. Segments can be unmapped, so the saving was not
//! worth the company.
//!
//! Who is asking, also: the kernel attests the sender on every message, and
//! a socket belongs to the process that asked for it. Closing or accepting
//! somebody else's socket is refused, which is the whole of the isolation
//! between one client's streams and another's.
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

/// How long a cached `/etc/hosts` is believed.
const HOSTS_TTL_US = 2 * 1_000_000;

/// How many sockets one process may hold at once. Half the table: every
/// socket is a shared segment and an event, and a client that can take all
/// eight can lock every other program on the machine out of the network by
/// opening eight and going to sleep.
const MAX_SOCKS_PER_CLIENT = 4;

/// How many deferred actions one reap may queue for the loop.
const MAX_DEFERRED = 4;

const Kind = enum { free, tcp, listener, udp };

const Sock = struct {
    kind: Kind = .free,
    /// Who asked for this socket. Nobody else may close it, and nobody
    /// else may accept from it.
    owner: u32 = 0,
    tcp: ?*lwip.TcpPcb = null,
    udp: ?*lwip.UdpPcb = null,

    /// This socket's own segment and event, made when it is granted and
    /// given back when it ends. `base` is kept because closing a handle is
    /// not unmapping: without it every socket costs the mapping too.
    shm: u32 = 0,
    ev_app: u32 = 0,
    base: ?[*]u8 = null,
    view: ?socket.View = null,

    /// Where the socket stands, held here as well as in the control page.
    /// The client can write anything into shared memory, so what netd
    /// decides by is its own copy; the page is what it tells the client.
    state: socket.State = .opening,
    cause: socket.Cause = .none,

    /// A connect or accept whose reply waits.
    pending: bool = false,
    pending_token: u32 = 0,

    /// Received bytes the ring could not yet take, chained head to tail and
    /// consumed from `held_at` as the client makes room.
    ///
    /// Every delivery is taken, never refused. A refusal is not backpressure:
    /// while one is outstanding lwIP drops every further segment without
    /// acknowledging it, so the sender learns only when its retransmission
    /// timer expires and a transfer spends its life in whole-second stalls.
    /// Backpressure is the receive window, which is already told only about
    /// bytes the client has taken, so what may be held here is bounded by the
    /// window and needs no bound of its own.
    held: ?*lwip.Pbuf = null,
    held_at: u16 = 0,
    /// The peer has sent its last byte. Told to the client only once every
    /// byte before it has reached the ring.
    peer_done: bool = false,

    /// Connections a listener accepted before anyone asked.
    backlog: [BACKLOG]?*lwip.TcpPcb = @splat(null),

    peer_addr: u32 = 0,
    peer_port: u16 = 0,

    /// Whether `who` is the process this socket belongs to. The one check
    /// standing between one client and another client's stream.
    pub fn mine(self: *const Sock, who: u32) bool {
        return self.owner != 0 and self.owner == who;
    }
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
    doorbell = sys.eventCreate() catch return null;
    return doorbell;
}

/// One request from the channel. Everything socket-shaped lands here; the
/// reply goes out now or when the network answers.
///
/// The sender rides along. The kernel attests it, so it is the one fact
/// about a caller that cannot be forged, and a socket without one is a
/// socket any process may close.
pub fn handle(message: *const sys.Message, token: u32) void {
    const req = proto.requestIn(message) orelse return refuse(token);
    // A tag this protocol does not define is answered, not switched on: the
    // caller checks too, and this is the entry point rather than a step
    // inside one.
    if (!proto.known(req.tag)) return refuse(token);
    const who = message.sender;

    switch (req.tag) {
        .tcp_connect => tcpConnect(req, who, token),
        .tcp_listen => tcpListen(req, who, token),
        .tcp_accept => tcpAccept(req, who, token),
        .udp_open => udpOpen(req, who, token),
        .sock_close => sockClose(req, who, token),
        .resolve => resolve(message, token),
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

fn tcpConnect(req: *const proto.Req, who: u32, token: u32) void {
    const s = takeSlot(.tcp, who) orelse return refuse(token);
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

fn tcpListen(req: *const proto.Req, who: u32, token: u32) void {
    const s = takeSlot(.listener, who) orelse return refuse(token);
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

    // The grant carries the readiness event: a count per connection waiting
    // in the backlog, so a listener can sit in wait_many beside a stop
    // event instead of blocking inside accept.
    const event = sys.eventCreate() catch {
        lwip.tcp_abort(listening);
        s.kind = .free;
        return refuse(token);
    };
    s.ev_app = event;

    // Drained, but bounded: the event counts, and a client holding one that
    // has been signalled often enough could otherwise keep the service in
    // this loop while every other socket waits.
    for (0..MAX_DEFERRED) |_| sys.eventWait(event, sys.POLL) catch break;

    var reply = proto.Rep{ .body = .{ .listener = indexOf(s) } };
    var message = sys.Message.init(std.mem.asBytes(&reply), &.{event});
    sys.replyMsg(service, token, &message) catch {
        sys.close(event);
        s.ev_app = 0;
        lwip.tcp_abort(listening);
        release(s);
    };
}

fn tcpAccept(req: *const proto.Req, who: u32, token: u32) void {
    const s = sockAt(req.index, .listener) orelse return refuse(token);
    if (!s.mine(who)) return refuse(token);
    if (s.pending) return refuse(token);

    // A connection that arrived before the question is answered from the
    // backlog; otherwise the token waits for the next one.
    for (&s.backlog) |*held| {
        if (held.*) |pcb| {
            held.* = null;
            grantAccepted(pcb, who, token);
            return;
        }
    }
    s.pending = true;
    s.pending_token = token;
}

fn udpOpen(req: *const proto.Req, who: u32, token: u32) void {
    const s = takeSlot(.udp, who) orelse return refuse(token);
    _ = openView(s, .udp) orelse {
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
    setState(s, .established, .none);
    _ = grant(s, token, .udp);
}

fn sockClose(req: *const proto.Req, who: u32, token: u32) void {
    const s = sockAt(req.index, null) orelse return refuse(token);
    if (!s.mine(who)) return refuse(token);

    switch (s.kind) {
        .tcp => {
            // What the client pushed before asking to finish still goes
            // out; the FIN follows the data.
            drainTcpTx(s);
            if (s.state != .closed) setState(s, .closed, .finished);
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

    release(s);
    var reply = proto.Rep{};
    replyPlain(token, &reply);
}

fn resolve(message: *const sys.Message, token: u32) void {
    // The one question on this service that carries a name rather than
    // numbers, so it is read as its own shape.
    const req = proto.resolver.requestIn(message) orelse return refuse(token);
    const name = req.slice();
    if (name.len == 0) return refuse(token);

    // The hosts table outranks every server, which is what makes a name
    // answerable on a machine with no network at all. Cached: a lookup is a
    // synchronous read of another service's files, and paying for it on
    // every name, inside the loop that moves every packet, is a way to make
    // the whole network as slow as the filesystem is today.
    if (hostsTable()) |text| {
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
    setState(s, .established, .none);
    sayPeer(s, "stream open to ");
    if (s.pending) {
        s.pending = false;
        // Aborted on the way through, so the stack is told that rather
        // than being handed back a connection that no longer exists.
        if (!grant(s, s.pending_token, .tcp)) return .abrt;
    }
    return .ok;
}

fn recvCb(arg: ?*anyopaque, pcb: *lwip.TcpPcb, p: ?*lwip.Pbuf, err: lwip.Err) callconv(.c) lwip.Err {
    _ = err;
    const s = sockOf(arg) orelse {
        if (p) |pb| _ = lwip.pbuf_free(pb);
        return .ok;
    };
    // A socket whose segment is gone is a socket that ended: lwIP keeps
    // re-offering what it was given until somebody takes it, so take it.
    if (s.view == null) {
        if (p) |pb| _ = lwip.pbuf_free(pb);
        return .ok;
    }

    const pb = p orelse {
        // The peer finished sending. Whether the client may be told so
        // depends on whether everything it sent has got there.
        s.peer_done = true;
        tellClosed(s);
        return .ok;
    };

    _ = pcb;
    // Taken whether or not the last one has drained: a delivery kept beside
    // what is already here costs a chain link, and refusing it costs every
    // segment behind it.
    if (s.held) |first| {
        lwip.pbuf_cat(first, pb);
    } else {
        s.held = pb;
        s.held_at = 0;
    }
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
    sys.eventSignal(s.ev_app);
    return .ok;
}

fn errCb(arg: ?*anyopaque, err: lwip.Err) callconv(.c) void {
    const s = sockOf(arg) orelse return;
    // The pcb is already gone.
    s.tcp = null;
    dropHeld(s);

    const opening = s.state == .opening;
    setState(s, .closed, switch (err) {
        .rst => if (opening) socket.Cause.refused else socket.Cause.reset,
        else => .aborted,
    });

    // A slot that is only given back while a connect was waiting is a slot
    // that leaks forever: eight of those and the machine has no sockets
    // left, however long ago the connections died. The client does not need
    // this end to read why -- its own mapping of the segment stays readable
    // after ours is closed -- so the whole socket goes now.
    const waiting = s.pending;
    const pending_token = s.pending_token;
    s.pending = false;
    if (waiting) refuse(pending_token);
    sys.eventSignal(s.ev_app);
    release(s);
}

fn acceptCb(arg: ?*anyopaque, newpcb: ?*lwip.TcpPcb, err: lwip.Err) callconv(.c) lwip.Err {
    const s = sockOf(arg) orelse return .ok;
    const pcb = newpcb orelse return .ok;
    if (err != .ok) return .ok;

    if (s.pending) {
        s.pending = false;
        grantAccepted(pcb, s.owner, s.pending_token);
        return .ok;
    }
    for (&s.backlog) |*held| {
        if (held.* == null) {
            held.* = pcb;
            sys.eventSignal(s.ev_app);
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

    sys.eventSignal(s.ev_app);
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
    if (s.state == .opening) return;

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
        sys.eventSignal(s.ev_app);
    }
}

/// The held delivery into the ring, as far as it goes. Frees and
/// acknowledges what enters; the window only reopens for consumed bytes.
fn drainHeldRx(s: *Sock) void {
    const view = s.view orelse return;

    var entered: u16 = 0;
    if (s.held) |pb| {
        var chunk: [512]u8 = undefined;
        while (s.held_at < pb.tot_len) {
            const want: u16 = @min(chunk.len, pb.tot_len - s.held_at);
            const got = lwip.pbuf_copy_partial(pb, &chunk, want, s.held_at);
            if (got == 0) break;
            const took: u16 = @truncate(view.rx.push(chunk[0..got]));
            s.held_at += took;
            entered += took;
            if (took < got) break;
        }
    }

    if (entered != 0) {
        if (s.tcp) |pcb| lwip.tcp_recved(pcb, entered);
    }
    // Told whenever there is anything to take, and not only when this pass
    // put it there. A client that is not waiting when the ring is filled has
    // nothing else to learn from: the window is closed by then, so no segment
    // arrives to drive another pass, and the only thing that would ring the
    // doorbell is the client reading.
    if (view.rx.readable() != 0) sys.eventSignal(s.ev_app);
    if (s.held) |pb| {
        if (s.held_at >= pb.tot_len) {
            _ = lwip.pbuf_free(pb);
            s.held = null;
            s.held_at = 0;
        }
    }
    tellClosed(s);
}

/// Say the peer has finished, once everything it sent has reached the client.
///
/// The state is what tells a reader nothing more will come, so setting it
/// while something still will is how the tail of a transfer goes missing: a
/// client that sees the stream ended stops reading, and whatever was still
/// held back goes with the socket. The wait is bounded by the client, which
/// is reading precisely because it has not seen the end yet.
fn tellClosed(s: *Sock) void {
    if (!s.peer_done or s.held != null) return;
    if (s.state == .established) setState(s, .peer_closed, .none);
    sys.eventSignal(s.ev_app);
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

        // Whole or not at all. The ring is shared memory, so how much is in
        // it is the client's word and can change between the look above and
        // the copy: a record that came up short would go out carrying
        // whatever the pool's last occupant left in the rest of it.
        if (filled != head.len) {
            _ = lwip.pbuf_free(p);
            break;
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
    if (moved) sys.eventSignal(s.ev_app);
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

/// A free slot, for the process asking. Refused once that process holds its
/// share of them, so one program cannot take the table and leave the rest of
/// the machine with nothing to open.
fn takeSlot(kind: Kind, who: u32) ?*Sock {
    var theirs: usize = 0;
    for (&socks) |*s| {
        if (s.kind == .free) continue;
        if (s.owner == who) theirs += 1;
    }
    if (theirs >= MAX_SOCKS_PER_CLIENT) {
        log.warn("netd", "one process has taken every socket it may have");
        return null;
    }

    for (&socks) |*s| {
        if (s.kind != .free) continue;
        s.* = .{ .kind = kind, .owner = who };
        return s;
    }
    log.warn("netd", "every socket slot is spoken for");
    return null;
}

/// This socket's own segment, made now and given back when it ends.
///
/// One per socket rather than one per slot: a segment shared with the
/// previous holder leaves that holder holding a live handle on the next
/// one's traffic, and an event shared the same way lets it keep the
/// service's readiness signal asserted.
fn openView(s: *Sock, kind: socket.Kind) ?socket.View {
    const created = sys.shmCreate(socket.shmBytes(kind)) catch return null;
    const base = sys.shmMap(@intCast(created), .{ .writable = true }) orelse {
        sys.close(@intCast(created));
        return null;
    };
    const event = sys.eventCreate() catch {
        sys.shmUnmap(base);
        sys.close(@intCast(created));
        return null;
    };

    s.shm = @intCast(created);
    s.base = base;
    s.ev_app = event;
    s.view = socket.View.of(base, kind);
    s.view.?.ctrl.* = .{};
    return s.view;
}

/// The socket at `index`, optionally of one kind. Null for an index that
/// names nothing, which is what a stale or invented one names.
fn sockAt(index: u32, kind: ?Kind) ?*Sock {
    if (index >= MAX_SOCKS) return null;
    const s = &socks[index];
    if (s.kind == .free) return null;
    if (kind) |wanted| {
        if (s.kind != wanted) return null;
    }
    return s;
}

/// Move a socket and tell the client, whose own copy of the state is a read
/// of what is written here. The state netd decides by lives on the socket,
/// not in memory the client can write.
fn setState(s: *Sock, state: socket.State, cause: socket.Cause) void {
    s.state = state;
    s.cause = cause;
    if (s.view) |view| {
        view.ctrl.state = state;
        view.ctrl.cause = cause;
    }
}

/// Everything a socket holds, given back: the pcb, the pbuf held for the
/// client, and the segment and event it was granted with. What ends a
/// socket's life, from whichever direction it ended.
fn release(s: *Sock) void {
    dropPcb(s);
    dropHeld(s);
    s.pending = false;
    s.backlog = @splat(null);
    if (s.base) |base| {
        sys.shmUnmap(base);
        s.base = null;
    }
    if (s.shm != 0) {
        sys.close(s.shm);
        s.shm = 0;
    }
    if (s.ev_app != 0) {
        sys.close(s.ev_app);
        s.ev_app = 0;
    }
    s.view = null;
    s.state = .opening;
    s.cause = .none;
    s.kind = .free;
    s.owner = 0;
}

fn sockOf(arg: ?*anyopaque) ?*Sock {
    return @ptrCast(@alignCast(arg orelse return null));
}

fn indexOf(s: *Sock) u32 {
    return @intCast((@intFromPtr(s) - @intFromPtr(&socks)) / @sizeOf(Sock));
}

/// An accepted connection into its own slot, granted to whoever asked.
fn grantAccepted(pcb: *lwip.TcpPcb, who: u32, token: u32) void {
    const s = takeSlot(.tcp, who) orelse {
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
    _ = grant(s, token, .tcp);
}

/// The granting reply: the socket's numbers and the three handles.
/// Hand the client its half of the socket, and answer with whether the
/// connection survived doing so.
///
/// A grant with no segment to give aborts the connection, and a callback
/// that aborted its own has to say so rather than answering as though it
/// still had one: the stack reads that answer and goes on using what it
/// was told is still there.
fn grant(s: *Sock, token: u32, kind: socket.Kind) bool {
    _ = openView(s, kind) orelse {
        log.warn("netd", "no segment for the socket");
        dropPcb(s);
        release(s);
        refuse(token);
        return false;
    };
    setState(s, .established, .none);

    var reply = proto.Rep{ .body = .{ .sock = .{
        .sock = indexOf(s),
        .peer_addr = s.peer_addr,
        .peer_port = s.peer_port,
        .kind = kind,
    } } };

    var message = sys.Message.init(std.mem.asBytes(&reply), &.{ s.shm, s.ev_app, doorbell });
    if (sys.replyMsg(service, token, &message)) |_| {
        log.say("netd", .dim, "socket granted");
        return true;
    } else |_| {
        // Whoever asked is gone, or the answer could not be given. Nothing
        // holds this socket's index now, so keeping it would be a slot no
        // one can ever reclaim.
        log.warn("netd", "the grant reply was refused");
        dropPcb(s);
        release(s);
        return false;
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

/// `/etc/hosts`, read at most once every `HOSTS_TTL_US`.
///
/// A table this small changes when somebody edits it, not on a schedule, so
/// the staleness a cache costs here is a name that resolves the old way for
/// a second or two. What it buys is a name lookup that does not reach into
/// another service while every interface is waiting.
fn hostsTable() ?[]const u8 {
    const now = sys.clockMicros();
    if (hosts_read_at != 0 and now - hosts_read_at < HOSTS_TTL_US) return hosts_bytes[0..hosts_len];

    const file = sys.open(HOSTS_PATH, .{}) catch return staleHosts();
    defer sys.close(file);
    const n = sys.read(file, &hosts_bytes) catch return staleHosts();
    hosts_read_at = now;
    if (n == 0) return staleHosts();
    hosts_len = @intCast(n);
    return hosts_bytes[0..hosts_len];
}

/// What a table that could not be read answers with: the last one, which is
/// better than nothing only because a name in it is still a name.
fn staleHosts() ?[]const u8 {
    if (hosts_len == 0) return null;
    return hosts_bytes[0..hosts_len];
}

var hosts_bytes: [2048]u8 = undefined;
var hosts_len: usize = 0;
var hosts_read_at: u64 = 0;

fn refuse(token: u32) void {
    var reply = proto.Rep{ .status = .refused };
    replyPlain(token, &reply);
}

fn replyPlain(token: u32, reply: *const proto.Rep) void {
    proto.answer(service, token, reply);
}

fn sayPeer(s: *Sock, what: []const u8) void {
    log.begin("netd", .dim);
    out.text(what);
    var field: [21]u8 = undefined;
    out.text(@import("lib").ipv4.textWithPort(s.peer_addr, s.peer_port, &field));
    log.end();
}
