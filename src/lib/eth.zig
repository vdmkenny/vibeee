//! Ethernet frames and, for now, the one kind that matters: ARP.
//!
//! Pure, so the frame arithmetic is host-tested and shared by the service
//! and its tools. Until the IP stack lands, an ARP request is the whole of
//! outbound traffic: a hand-built frame the wire understands without any
//! software above it, and the reply is the proof that rings, buffers and
//! interrupts all carry the real thing.
//!
//! The frame is described as one enum of positions rather than as a struct:
//! a struct the compiler pads would silently disagree with the wire, and a
//! table of offsets is what a frame actually is. The golden byte test below
//! then pins the whole layout at compile time.

const std = @import("std");

/// An EtherType, the two bytes that say what a frame carries.
pub const EtherType = enum(u16) {
    arp = 0x0806,
    ipv4 = 0x0800,
    ipv6 = 0x86DD,
    _,
};

/// An ARP operation: one asks, two answers.
pub const Op = enum(u16) {
    request = 1,
    reply = 2,
    _,
};

/// Every position that matters, inside a whole frame. The names are the
/// bytes; an ARP request for "who has a.b.c.d" writes these slots and the
/// wire understands it.
pub const At = enum(u8) {
    mac_dst = 0,
    mac_src = 6,
    ether_type = 12,
    htype = 14,
    ptype = 16,
    hlen = 18,
    plen = 19,
    op = 20,
    sender_mac = 22,
    sender_ip = 28,
    target_mac = 32,
    target_ip = 38,
    end = 42,
};

/// A whole frame's worth: 14 bytes of header, 28 of ARP.
pub const FRAME: usize = @intFromEnum(At.end);

comptime {
    if (@intFromEnum(At.end) != 42) @compileError("an ARP frame is 42 bytes");
}

/// One ARP request that already says who is asking and for whom:
/// "who has `target`, tell `source`". The destination is everybody.
pub fn arpRequest(
    out: *[FRAME]u8,
    source_mac: [6]u8,
    source_addr: u32,
    target_addr: u32,
) void {
    @memset(out[@intFromEnum(At.mac_dst)..@intFromEnum(At.ether_type)], 0xFF); // broadcast
    @memcpy(
        out[@intFromEnum(At.mac_src)..@intFromEnum(At.ether_type)],
        &source_mac,
    );
    write16(out, .ether_type, @intFromEnum(EtherType.arp));

    write16(out, .htype, 1); // ethernet
    write16(out, .ptype, 0x0800); // ipv4
    out[@intFromEnum(At.hlen)] = 6;
    out[@intFromEnum(At.plen)] = 4;
    write16(out, .op, @intFromEnum(Op.request));
    @memcpy(
        out[@intFromEnum(At.sender_mac)..@intFromEnum(At.sender_ip)],
        &source_mac,
    );
    write32(out, .sender_ip, source_addr);
    @memset(out[@intFromEnum(At.target_mac)..@intFromEnum(At.target_ip)], 0x00);
    write32(out, .target_ip, target_addr);
}

/// What an ARP reply says: the peer that answered, by hardware and by
/// protocol address. Null for anything else, including a frame that is not
/// ARP or is a request: a pointer into the frame, alive as long as it is.
pub fn arpPeer(frame: []const u8) ?struct { mac: [6]u8, addr: u32 } {
    if (frame.len < FRAME) return null;
    if (std.mem.readInt(u16, frame[@intFromEnum(At.ether_type)..][0..2], .big) !=
        @intFromEnum(EtherType.arp)) return null;
    if (std.mem.readInt(u16, frame[@intFromEnum(At.op)..][0..2], .big) !=
        @intFromEnum(Op.reply)) return null;

    var mac: [6]u8 = undefined;
    @memcpy(&mac, frame[@intFromEnum(At.sender_mac)..@intFromEnum(At.sender_ip)]);
    return .{
        .mac = mac,
        .addr = std.mem.readInt(u32, frame[@intFromEnum(At.sender_ip)..][0..4], .big),
    };
}

fn write16(frame: []u8, at: At, value: u16) void {
    std.mem.writeInt(u16, frame[@intFromEnum(at)..][0..2], value, .big);
}

fn write32(frame: []u8, at: At, value: u32) void {
    std.mem.writeInt(u32, frame[@intFromEnum(at)..][0..4], value, .big);
}

test "a built request is the frame a wire expects" {
    const mac = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    var frame: [FRAME]u8 = undefined;
    arpRequest(&frame, mac, 0x0A00020F, 0x0A000202);

    const want = [_]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x52, 0x54, 0x00, 0x12, 0x34, 0x56,
        0x08, 0x06, // ARP
        0x00, 0x01, // ethernet
        0x08, 0x00, // ipv4
        0x06, 0x04, // 6-byte hardware, 4-byte protocol
        0x00, 0x01, // request
        0x52, 0x54, 0x00, 0x12, 0x34, 0x56,
        0x0A, 0x00, 0x02, 0x0F, // 10.0.2.15
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x0A, 0x00, 0x02, 0x02, // 10.0.2.2
    };
    try std.testing.expectEqualSlices(u8, &want, &frame);
}

test "a reply names its peer, a request names nobody" {
    var frame: [FRAME]u8 = undefined;
    arpRequest(&frame, .{ 1, 2, 3, 4, 5, 6 }, 0x0A00020F, 0x0A000202);
    try std.testing.expectEqual(null, arpPeer(&frame));

    // Turn the request into a reply: operation 2, addresses swapped, and
    // the target mac now known.
    write16(&frame, .op, 2);
    const peer_mac = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    @memcpy(frame[@intFromEnum(At.sender_mac)..@intFromEnum(At.sender_ip)], &peer_mac);
    write32(&frame, .sender_ip, 0x0A000202);
    @memcpy(frame[@intFromEnum(At.target_mac)..@intFromEnum(At.target_ip)], frame[@intFromEnum(At.mac_src)..@intFromEnum(At.ether_type)]);
    write32(&frame, .target_ip, 0x0A00020F);

    const peer = arpPeer(&frame).?;
    try std.testing.expectEqualSlices(u8, &peer_mac, &peer.mac);
    try std.testing.expectEqual(@as(u32, 0x0A000202), peer.addr);
}

test "a frame that is not ARP names nobody" {
    var frame: [FRAME]u8 = @splat(0);
    write16(&frame, .ether_type, @intFromEnum(EtherType.ipv4));
    try std.testing.expectEqual(null, arpPeer(&frame));
}