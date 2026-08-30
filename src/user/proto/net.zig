//! What `net` and `netd` say to each other.
//!
//! Wire types only, so a tool and the service compile the same shapes and
//! neither can drift. One interface at a time, asked for by index, which is
//! how a caller walks a list of unknown length: ask until `end`.

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
};

pub const Req = extern struct {
    tag: Tag,
    _reserved: [3]u8 = @splat(0),
    /// Which interface, for the requests that address one.
    index: u32 = 0,
    /// The request's number: the address to ask about, for `arp_probe`
    /// and `ping`.
    param: u32 = 0,
    /// The request's second number: the deadline in milliseconds, for `ping`.
    param2: u32 = 0,
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
};

comptime {
    if (@sizeOf(Rep) > sys.MAX_PAYLOAD) {
        @compileError("a network reply must fit in one channel payload");
    }
    if (@sizeOf(Req) != 16) @compileError("a network request is sixteen bytes");
    if (@sizeOf(Iface) != 56) @compileError("an interface record is 56 bytes");
    if (@sizeOf(AddressInfo) != 16) @compileError("an address record is sixteen bytes");
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

