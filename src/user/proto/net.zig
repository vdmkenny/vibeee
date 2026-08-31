//! What `net` and `netd` say to each other.
//!
//! Wire types only, so a tool and the service compile the same shapes and
//! neither can drift. One interface at a time, asked for by index, which is
//! how a caller walks a list of unknown length: ask until `end`.

const socket = @import("socket.zig");
const std = @import("std");
const sys = @import("sys");

pub const SERVICE = "net";

pub const Tag = enum(u8) {
    /// How many interfaces there are, in `count`.
    count,
    /// One interface, at `index`.
    status,
    /// Send one ARP request from the interface at `index`: a diagnostic
    /// beneath the stack, whose reply proves the ring and the line carry
    /// the real thing.
    arp_probe,
    /// One ICMP echo to the address in `param`, with `param2` milliseconds
    /// of patience. The reply is deferred until the answer or the deadline:
    /// the caller's call blocks exactly as long as the ping does.
    ping,
    /// The stack's address story for the interface at `index`.
    address,
    /// Open a stream to `param`:`param2`. The reply waits for the handshake
    /// and grants the socket: `body.sock` and the three handles.
    tcp_connect,
    /// Listen on port `param` with backlog `param2`; `body.listener` names
    /// the listener for `tcp_accept`.
    tcp_listen,
    /// The next connection on listener `index`. Deferred until one arrives;
    /// grants a socket like `tcp_connect`.
    tcp_accept,
    /// A datagram socket: `param` the remote address or zero, `param2` the
    /// two ports as `UdpPorts`. Granted at once.
    udp_open,
    /// Finish socket `index`: FIN for a stream, teardown for the rest.
    sock_close,
    /// A name to an address, `ResolveReq` shaped: the hosts table first,
    /// then DNS. Deferred while a server is asked.
    resolve,
};

/// The two ports of `udp_open`, packed into its second parameter.
pub const UdpPorts = packed struct(u32) {
    /// Who to talk to; zero with a zero remote address listens only.
    remote: u16 = 0,
    /// Local binding; zero lets the stack pick.
    local: u16 = 0,
};

pub const Req = extern struct {
    tag: Tag,
    _reserved: [3]u8 = @splat(0),
    /// Which interface or socket, for the requests that address one.
    index: u32 = 0,
    /// The request's number: the address to ask about, for `arp_probe`,
    /// `ping`, `tcp_connect` and `udp_open`; the port for `tcp_listen`.
    param: u32 = 0,
    /// The request's second number: the deadline in milliseconds for
    /// `ping`, the port for `tcp_connect`, the backlog for `tcp_listen`,
    /// the `UdpPorts` for `udp_open`.
    param2: u32 = 0,
};

/// `resolve` carries a name instead of numbers; the tag stays first, which
/// is how the service tells the two request shapes apart.
pub const ResolveReq = extern struct {
    tag: Tag = .resolve,
    len: u8 = 0,
    _reserved: [2]u8 = @splat(0),
    name: [NAME_MAX]u8 = @splat(0),

    pub const NAME_MAX = 60;

    pub fn of(name: []const u8) ?ResolveReq {
        if (name.len == 0 or name.len > NAME_MAX) return null;
        var req = ResolveReq{ .len = @intCast(name.len) };
        @memcpy(req.name[0..name.len], name);
        return req;
    }

    pub fn slice(self: *const ResolveReq) []const u8 {
        return self.name[0..@min(self.len, NAME_MAX)];
    }
};

pub const Status = enum(u8) {
    ok,
    /// The service is up but no driver there.
    refused,
    /// Nothing at that index: how a caller walking a list finds the end.
    end,
    /// The deadline passed before an answer did.
    timed_out,
};

pub const Duplex = enum(u8) {
    unknown = 0,
    half = 1,
    full = 2,
};

pub const Iface = extern struct {
    /// What the interface answers to: driver name plus ordinal, as
    /// configuration matches it.
    driver: [12]u8 = @splat(0),
    /// Where it sits on the bus, packed as `lib.pci.Location`.
    location: u16 = 0,
    mac: [6]u8 = @splat(0),
    /// Link up and carrying.
    up: u8 = 0,
    duplex: Duplex = .unknown,
    mbps: u16 = 0,

    rx_pkts: u32 = 0,
    rx_bytes: u32 = 0,
    tx_pkts: u32 = 0,
    tx_bytes: u32 = 0,

    /// Replies the ring has carried, and the last peer that answered: the
    /// traffic proof beneath the stack.
    arp_replies: u32 = 0,
    peer_ip: u32 = 0,
    peer_mac: [6]u8 = @splat(0),
    _pad: u16 = 0,
};

/// The stack's address story for one interface: what is held, where it came
/// from, and the lease's remaining seconds when DHCP granted it.
pub const AddressInfo = extern struct {
    addr: u32 = 0,
    gateway: u32 = 0,
    lease_remaining_s: u32 = 0,
    prefix: u8 = 0,
    source: AddrSource = .none,
    _pad: u16 = 0,
};

/// Where an interface's address came from.
pub const AddrSource = enum(u8) {
    none = 0,
    static_claim = 1,
    dhcp = 2,
};

pub const Rep = extern struct {
    status: Status = .ok,
    _reserved: [3]u8 = @splat(0),
    /// One request, one answer, one shape at a time: what a union is for,
    /// and what keeps every reply inside a single channel payload.
    body: Body = .{ .count = 0 },
};

pub const Body = extern union {
    /// For `count`: how many interfaces there are.
    count: u32,
    /// For `ping`: the round trip in microseconds.
    rtt_us: u32,
    /// For `status`: the interface.
    iface: Iface,
    /// For `address`: the stack's address story.
    address: AddressInfo,
    /// For `tcp_listen`: which listener to accept on.
    listener: u32,
    /// For the granting ops: which socket the handles belong to.
    sock: SockGrant,
    /// For `resolve`: the answer and where it came from.
    resolved: Resolved,
};

/// A granted socket. The reply's handles are, in order, the shared
/// segment, the socket's own event, and the service's shared doorbell.
pub const SockGrant = extern struct {
    sock: u32 = 0,
    peer_addr: u32 = 0,
    peer_port: u16 = 0,
    kind: socket.Kind = .tcp,
    _pad: u8 = 0,
};

pub const GRANT_HANDLES = 3;

pub const Resolved = extern struct {
    addr: u32 = 0,
    source: ResolveSource = .dns,
    _pad: [3]u8 = @splat(0),
};

/// Who answered a name.
pub const ResolveSource = enum(u8) {
    /// The hosts table, before any server was asked.
    hosts,
    dns,
};

comptime {
    if (@sizeOf(Rep) > sys.MAX_PAYLOAD) {
        @compileError("a network reply must fit in one channel payload");
    }
    if (@sizeOf(Req) != 16) @compileError("a network request is sixteen bytes");
    if (@sizeOf(ResolveReq) != 64) @compileError("a resolve request fills one payload");
    if (@sizeOf(Iface) != 56) @compileError("an interface record is 56 bytes");
    if (@sizeOf(AddressInfo) != 16) @compileError("an address record is sixteen bytes");
    if (@sizeOf(SockGrant) != 12) @compileError("a socket grant is twelve bytes");
}

pub const Error = error{ NoService, Refused, End, TimedOut };

pub fn call(tag: Tag, index: u32, param: u32, into: *Rep) Error!void {
    return callWith(tag, index, param, 0, into);
}

pub fn callWith(tag: Tag, index: u32, param: u32, param2: u32, into: *Rep) Error!void {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) return error.NoService;
    defer _ = sys.close(@intCast(channel));

    var request = Req{ .tag = tag, .index = index, .param = param, .param2 = param2 };
    const message = sys.Message.init(std.mem.asBytes(&request), &.{});

    var reply = sys.Message{};
    if (sys.callMsg(@intCast(channel), &message, &reply) < 0) return error.Refused;

    const bytes = reply.bytes();
    if (bytes.len < @sizeOf(Rep)) return error.Refused;

    into.* = @as(*const Rep, @alignCast(@ptrCast(bytes.ptr))).*;

    return switch (into.status) {
        .ok => {},
        .end => error.End,
        .timed_out => error.TimedOut,
        else => error.Refused,
    };
}

// ---------------------------------------------------------------------------
// What a caller asks about the interfaces
//
// Spelled out once, like the sound graph's. Anything that shows what the
// machine is connected to needs the same three questions answered.
// ---------------------------------------------------------------------------

/// How many interfaces there are, or zero when nothing is serving the
/// network.
pub fn interfaceCount() usize {
    var reply = Rep{};
    call(.count, 0, 0, &reply) catch return 0;
    if (reply.status != .ok) return 0;
    return reply.body.count;
}

/// One interface, by index.
pub fn interfaceAt(index: usize) ?Iface {
    var reply = Rep{};
    call(.status, @intCast(index), 0, &reply) catch return null;
    if (reply.status != .ok) return null;
    return reply.body.iface;
}

/// What the stack has made of that interface's addressing.
pub fn addressOf(index: usize) ?AddressInfo {
    var reply = Rep{};
    call(.address, @intCast(index), 0, &reply) catch return null;
    if (reply.status != .ok) return null;
    return reply.body.address;
}

/// An interface's name, which the protocol carries padded with zeroes.
pub fn nameOf(iface: *const Iface) []const u8 {
    for (iface.driver, 0..) |c, i| {
        if (c == 0) return iface.driver[0..i];
    }
    return &iface.driver;
}
