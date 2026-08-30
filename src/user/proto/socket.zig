//! The shared-memory shape of one socket, as both sides map it.
//!
//! A socket's data never crosses the service channel: the client and netd
//! share one segment holding a control page and two byte rings, and wake
//! each other through events. This file is the layout both processes
//! compile against, pinned the way every cross-process shape here is, and
//! the arithmetic lives in `lib.spsc`, which is host-tested.
//!
//! Roles are fixed: the client produces tx and consumes rx; netd does the
//! opposite; netd alone writes `state` and `cause`. One writer per word is
//! the whole locking story.

const spsc = @import("lib").spsc;
const std = @import("std");

/// What kind of socket a segment carries, which decides its geometry.
pub const Kind = enum(u8) {
    tcp,
    udp,
};

/// Where a TCP socket stands. The client reads this beside the rings: data
/// may still be waiting in rx after the peer closed, and both are true.
pub const State = enum(u32) {
    /// Asked for, not yet answered: connect in flight.
    opening,
    established,
    /// The peer finished sending; rx drains what remains.
    peer_closed,
    closed,
};

/// Why a socket closed, for the tool that has to tell somebody.
pub const Cause = enum(u32) {
    none,
    /// Nobody listening there.
    refused,
    /// The peer reset the conversation.
    reset,
    /// The stack gave up: retransmissions exhausted or route lost.
    aborted,
    /// Closed because both sides finished, the ordinary end.
    finished,
};

/// The control page, at the start of the segment. Head and tail are
/// free-running `lib.spsc` indices; each is written by exactly one side.
pub const Ctrl = extern struct {
    /// Client produces, netd consumes: bytes toward the wire.
    tx_head: u32 = 0,
    tx_tail: u32 = 0,
    /// netd produces, client consumes: bytes from the wire.
    rx_head: u32 = 0,
    rx_tail: u32 = 0,
    state: State = .opening,
    cause: Cause = .none,
};

/// One page of control, then the two rings.
pub const CTRL_BYTES = 4096;

/// How long each ring is: enough TCP for a full window, half that for the
/// datagrams a small tool exchanges.
pub fn ringBytes(kind: Kind) u32 {
    return switch (kind) {
        .tcp => 16384,
        .udp => 8192,
    };
}

pub fn shmBytes(kind: Kind) u32 {
    return CTRL_BYTES + 2 * ringBytes(kind);
}

/// A datagram in a UDP ring: this head, the payload, then padding to eight
/// bytes so every head is aligned. TCP rings carry bare bytes.
pub const DatagramHead = extern struct {
    /// Payload length, without head or padding.
    len: u16 = 0,
    port: u16 = 0,
    addr: u32 = 0,
};

pub fn datagramSpan(payload_len: u16) u32 {
    return std.mem.alignForward(u32, @sizeOf(DatagramHead) + payload_len, 8);
}

/// Both rings of a mapped segment, over the control page's own indices.
pub const View = struct {
    ctrl: *volatile Ctrl,
    tx: spsc.Ring,
    rx: spsc.Ring,

    pub fn of(base: [*]u8, kind: Kind) View {
        const ctrl: *volatile Ctrl = @ptrCast(@alignCast(base));
        const ring = ringBytes(kind);
        return .{
            .ctrl = ctrl,
            .tx = .{
                .head = @volatileCast(&ctrl.tx_head),
                .tail = @volatileCast(&ctrl.tx_tail),
                .data = base[CTRL_BYTES..][0..ring],
            },
            .rx = .{
                .head = @volatileCast(&ctrl.rx_head),
                .tail = @volatileCast(&ctrl.rx_tail),
                .data = base[CTRL_BYTES + ring ..][0..ring],
            },
        };
    }
};

comptime {
    if (@offsetOf(Ctrl, "tx_head") != 0 or
        @offsetOf(Ctrl, "rx_head") != 8 or
        @offsetOf(Ctrl, "state") != 16 or
        @offsetOf(Ctrl, "cause") != 20)
    {
        @compileError("the socket control page drifted");
    }
    if (@sizeOf(DatagramHead) != 8) @compileError("a datagram head is eight bytes");
    if (shmBytes(.tcp) != 36864 or shmBytes(.udp) != 20480) {
        @compileError("socket segment sizes drifted from the design");
    }
}
