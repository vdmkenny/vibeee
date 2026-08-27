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
    /// Send one ARP request from the interface at `index`: the whole of
    /// outbound traffic until the stack lands, and the reply is the proof
    /// that the ring and the line carry the real thing.
    arp_probe,
};

pub const Req = extern struct {
    tag: Tag,
    _reserved: [3]u8 = @splat(0),
    /// Which interface, for the requests that address one.
    index: u32 = 0,
    /// The request's number: the address to ask about, for `arp_probe`.
    param: u32 = 0,
};

pub const Status = enum(u8) {
    ok,
    /// The service is up but no driver there.
    refused,
    /// Nothing at that index: how a caller walking a list finds the end.
    end,
};

pub const Duplex = enum(u8) {
    unknown = 0,
    half = 1,
    full = 2,
};

pub const Iface = extern struct {
    /// What the driver is called, exactly as the probe table knows it.
    driver: [8]u8 = @splat(0),
    mac: [6]u8 = @splat(0),
    /// Link up and carrying.
    up: u8 = 0,
    duplex: Duplex = .unknown,
    mbps: u16 = 0,
    _pad: u16 = 0,

    rx_pkts: u32 = 0,
    rx_bytes: u32 = 0,
    tx_pkts: u32 = 0,
    tx_bytes: u32 = 0,

    /// Replies the ring has carried, and the last peer that answered: the
    /// traffic proof until the stack replaces the ARP stub.
    arp_replies: u32 = 0,
    peer_ip: u32 = 0,
    peer_mac: [6]u8 = @splat(0),
};

pub const Rep = extern struct {
    status: Status = .ok,
    _reserved: [3]u8 = @splat(0),

    /// For `count`: how many interfaces there are.
    count: u32 = 0,

    /// The interface, for `status`. One `Iface` and a count share the payload
    /// rather than growing the whole reply for a caller that asks for both.
    iface: Iface = .{},
};

comptime {
    if (@sizeOf(Rep) > sys.MAX_PAYLOAD) {
        @compileError("a network reply must fit in one channel payload");
    }
    if (@sizeOf(Req) != 12) @compileError("a network request is twelve bytes");
    if (@sizeOf(Iface) != 52) @compileError("an interface record is 52 bytes");
}

pub const Error = error{ NoService, Refused, End };

pub fn call(tag: Tag, index: u32, param: u32, into: *Rep) Error!void {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) return error.NoService;
    defer _ = sys.close(@intCast(channel));

    var request = Req{ .tag = tag, .index = index, .param = param };
    const message = sys.Message.init(std.mem.asBytes(&request), &.{});

    var reply = sys.Message{};
    if (sys.callMsg(@intCast(channel), &message, &reply) < 0) return error.Refused;

    const bytes = reply.bytes();
    if (bytes.len < @sizeOf(Rep)) return error.Refused;

    into.* = @as(*const Rep, @alignCast(@ptrCast(bytes.ptr))).*;

    return switch (into.status) {
        .ok => {},
        .end => error.End,
        else => error.Refused,
    };
}

