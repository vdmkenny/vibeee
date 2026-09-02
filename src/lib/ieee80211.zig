//! 802.11 frames: what one says, and how it becomes an ethernet frame.
//!
//! Pure and host-tested. A radio driver hands bytes here and receives a
//! parsed header; the stack above only ever sees ethernet, because every
//! netif in this system speaks one framing. The variable-length parts of
//! the header, the fourth address, the QoS word and the HT control word,
//! are modelled from the start: a later high-throughput radio changes
//! which of them appear, not what this file is.

const std = @import("std");
const mac = @import("mac.zig");

/// A frame's kind. Two bits on the wire, and the discriminator for what
/// the rest of the frame means.
pub const Kind = enum(u2) {
    management = 0,
    control = 1,
    data = 2,
    extension = 3,
};

/// The subtypes this system acts on. Four bits, meaningful only beside a
/// kind, so the values repeat across kinds and each has its own set.
pub const ManagementSubtype = enum(u4) {
    association_request = 0,
    association_response = 1,
    reassociation_request = 2,
    reassociation_response = 3,
    probe_request = 4,
    probe_response = 5,
    beacon = 8,
    disassociation = 10,
    authentication = 11,
    deauthentication = 12,
    action = 13,
    _,
};

pub const DataSubtype = enum(u4) {
    data = 0,
    null_data = 4,
    qos_data = 8,
    qos_null = 12,
    _,

    /// Whether this subtype carries the QoS control word. Bit 3 of the
    /// subtype is the QoS flag, which is what makes the test a mask and
    /// not a list.
    pub fn hasQos(self: DataSubtype) bool {
        return @intFromEnum(self) & 0x8 != 0;
    }

    /// Whether the frame carries a payload at all.
    pub fn hasPayload(self: DataSubtype) bool {
        return @intFromEnum(self) & 0x4 == 0;
    }
};

/// The first two bytes of every frame.
pub const FrameControl = packed struct(u16) {
    version: u2 = 0,
    kind: Kind = .management,
    subtype: u4 = 0,
    /// Toward the distribution system: a frame this station sends to its
    /// access point.
    to_ds: bool = false,
    /// From the distribution system: a frame the access point relays here.
    from_ds: bool = false,
    more_fragments: bool = false,
    retry: bool = false,
    power_management: bool = false,
    more_data: bool = false,
    /// Payload is encrypted; the cipher's header follows the 802.11 one.
    protected: bool = false,
    /// Ordered service for a legacy frame, and the presence of the HT
    /// control word on a QoS frame from a high-throughput radio.
    order: bool = false,

    pub fn management(subtype: ManagementSubtype) FrameControl {
        return .{ .kind = .management, .subtype = @intFromEnum(subtype) };
    }

    pub fn data(subtype: DataSubtype) FrameControl {
        return .{ .kind = .data, .subtype = @intFromEnum(subtype) };
    }

    pub fn managementSubtype(self: FrameControl) ManagementSubtype {
        return @enumFromInt(self.subtype);
    }

    pub fn dataSubtype(self: FrameControl) DataSubtype {
        return @enumFromInt(self.subtype);
    }
};

/// Sequence control: which fragment of which frame.
pub const SequenceControl = packed struct(u16) {
    fragment: u4 = 0,
    sequence: u12 = 0,
};

/// The QoS control word, present on QoS data frames.
pub const QosControl = packed struct(u16) {
    tid: u4 = 0,
    end_of_service_period: bool = false,
    ack_policy: u2 = 0,
    amsdu: bool = false,
    _8: u8 = 0,
};

/// How the four address fields are used, which the two distribution-system
/// bits decide between. Named because the mapping is the one thing about
/// 802.11 addressing that cannot be read off the frame.
pub const Topology = enum {
    /// No access point: addresses are destination, source, cell.
    adhoc,
    /// This station to its access point.
    to_ap,
    /// The access point to this station.
    from_ap,
    /// Two access points relaying: the only case with a fourth address.
    bridged,

    pub fn of(control: FrameControl) Topology {
        return switch ((@as(u2, @intFromBool(control.from_ds)) << 1) |
            @intFromBool(control.to_ds)) {
            0b00 => .adhoc,
            0b01 => .to_ap,
            0b10 => .from_ap,
            0b11 => .bridged,
        };
    }
};

/// A parsed header, by value. The wire bytes stay where they arrived and
/// nothing here points into them, so a driver may recycle its buffer the
/// moment the payload has been copied on.
pub const Header = struct {
    control: FrameControl = .{},
    duration: u16 = 0,
    addr1: mac.Address = @splat(0),
    addr2: mac.Address = @splat(0),
    addr3: mac.Address = @splat(0),
    /// Present only between two access points.
    addr4: ?mac.Address = null,
    sequence: SequenceControl = .{},
    qos: ?QosControl = null,
    /// The high-throughput control word, when a radio that has one says so.
    ht_control: ?u32 = null,
    /// How many bytes of frame the header occupied.
    len: usize = 0,

    /// The shortest a header can be: control, duration, three addresses,
    /// sequence control.
    pub const MIN = 24;

    pub fn parse(frame: []const u8) ?Header {
        if (frame.len < MIN) return null;

        var head = Header{
            .control = @bitCast(std.mem.readInt(u16, frame[0..2], .little)),
            .duration = std.mem.readInt(u16, frame[2..4], .little),
            .addr1 = frame[4..10].*,
            .addr2 = frame[10..16].*,
            .addr3 = frame[16..22].*,
            .sequence = @bitCast(std.mem.readInt(u16, frame[22..24], .little)),
            .len = MIN,
        };

        if (Topology.of(head.control) == .bridged) {
            if (frame.len < head.len + 6) return null;
            head.addr4 = frame[head.len..][0..6].*;
            head.len += 6;
        }

        if (head.control.kind == .data and head.control.dataSubtype().hasQos()) {
            if (frame.len < head.len + 2) return null;
            head.qos = @bitCast(std.mem.readInt(u16, frame[head.len..][0..2], .little));
            head.len += 2;

            // The order bit means something else entirely on a QoS frame:
            // a high-throughput control word follows.
            if (head.control.order) {
                if (frame.len < head.len + 4) return null;
                head.ht_control = std.mem.readInt(u32, frame[head.len..][0..4], .little);
                head.len += 4;
            }
        }

        return head;
    }

    /// Write the header into `into`, returning how much it used.
    pub fn write(self: Header, into: []u8) ?usize {
        var at: usize = 0;
        if (into.len < MIN) return null;

        std.mem.writeInt(u16, into[0..2], @bitCast(self.control), .little);
        std.mem.writeInt(u16, into[2..4], self.duration, .little);
        @memcpy(into[4..10], &self.addr1);
        @memcpy(into[10..16], &self.addr2);
        @memcpy(into[16..22], &self.addr3);
        std.mem.writeInt(u16, into[22..24], @bitCast(self.sequence), .little);
        at = MIN;

        if (self.addr4) |fourth| {
            if (into.len < at + 6) return null;
            @memcpy(into[at..][0..6], &fourth);
            at += 6;
        }
        if (self.qos) |word| {
            if (into.len < at + 2) return null;
            std.mem.writeInt(u16, into[at..][0..2], @bitCast(word), .little);
            at += 2;
        }
        if (self.ht_control) |word| {
            if (into.len < at + 4) return null;
            std.mem.writeInt(u32, into[at..][0..4], word, .little);
            at += 4;
        }
        return at;
    }

    /// Who the frame is for and who sent it, as ethernet understands the
    /// question. The distribution-system bits decide which address field
    /// answers which half.
    pub fn endpoints(self: Header) struct { destination: mac.Address, source: mac.Address } {
        return switch (Topology.of(self.control)) {
            .adhoc => .{ .destination = self.addr1, .source = self.addr2 },
            .to_ap => .{ .destination = self.addr3, .source = self.addr2 },
            .from_ap => .{ .destination = self.addr1, .source = self.addr3 },
            .bridged => .{ .destination = self.addr3, .source = self.addr4 orelse self.addr2 },
        };
    }

    /// Which station this frame's cell belongs to.
    pub fn bssid(self: Header) mac.Address {
        return switch (Topology.of(self.control)) {
            .adhoc => self.addr3,
            .to_ap => self.addr1,
            .from_ap => self.addr2,
            .bridged => self.addr1,
        };
    }
};

/// The 802.2 header that carries an ethertype inside an 802.11 frame.
pub const Snap = struct {
    pub const BYTES = 8;
    /// Both service access points name SNAP, and the control byte is an
    /// unnumbered information frame.
    const PREFIX = [_]u8{ 0xAA, 0xAA, 0x03, 0x00, 0x00, 0x00 };

    pub fn ethertypeOf(payload: []const u8) ?u16 {
        if (payload.len < BYTES) return null;
        if (!std.mem.eql(u8, payload[0..PREFIX.len], &PREFIX)) return null;
        return std.mem.readInt(u16, payload[6..8], .big);
    }

    pub fn write(into: []u8, ethertype: u16) ?usize {
        if (into.len < BYTES) return null;
        @memcpy(into[0..PREFIX.len], &PREFIX);
        std.mem.writeInt(u16, into[6..8], ethertype, .big);
        return BYTES;
    }
};

/// The ethertypes this system tells apart before the stack sees them.
pub const Ethertype = struct {
    pub const ipv4: u16 = 0x0800;
    pub const arp: u16 = 0x0806;
    /// Authentication traffic, which belongs to the supplicant and never
    /// reaches the stack.
    pub const eapol: u16 = 0x888E;
};

/// An 802.11 data frame turned into the ethernet frame the stack expects:
/// the fourteen-byte header written into `into`, the payload following it.
/// Returns the whole ethernet frame's length.
///
/// One copy, into the caller's buffer, because the two framings overlap in
/// neither length nor field order and the driver's receive slot is not
/// ours to rewrite.
pub fn toEthernet(frame: []const u8, into: []u8) ?usize {
    const head = Header.parse(frame) orelse return null;
    if (head.control.kind != .data) return null;
    if (!head.control.dataSubtype().hasPayload()) return null;

    const body = frame[head.len..];
    const ethertype = Snap.ethertypeOf(body) orelse return null;
    const payload = body[Snap.BYTES..];

    const ETH_HEADER = 14;
    if (into.len < ETH_HEADER + payload.len) return null;

    const ends = head.endpoints();
    @memcpy(into[0..6], &ends.destination);
    @memcpy(into[6..12], &ends.source);
    std.mem.writeInt(u16, into[12..14], ethertype, .big);
    @memcpy(into[ETH_HEADER..][0..payload.len], payload);
    return ETH_HEADER + payload.len;
}

/// The reverse: an ethernet frame as a data frame addressed to the access
/// point this station is joined to.
pub fn fromEthernet(
    ethernet: []const u8,
    bssid: mac.Address,
    sequence: SequenceControl,
    into: []u8,
) ?usize {
    const ETH_HEADER = 14;
    if (ethernet.len < ETH_HEADER) return null;

    const head = Header{
        .control = blk: {
            var c = FrameControl.data(.data);
            c.to_ds = true;
            break :blk c;
        },
        // Addressed to the access point, from this station, for whoever
        // the ethernet frame named.
        .addr1 = bssid,
        .addr2 = ethernet[6..12].*,
        .addr3 = ethernet[0..6].*,
        .sequence = sequence,
    };

    const wrote = head.write(into) orelse return null;
    const snap = Snap.write(into[wrote..], std.mem.readInt(u16, ethernet[12..14], .big)) orelse return null;
    const payload = ethernet[ETH_HEADER..];
    if (into.len < wrote + snap + payload.len) return null;
    @memcpy(into[wrote + snap ..][0..payload.len], payload);
    return wrote + snap + payload.len;
}

// ---------------------------------------------------------------------------
// Management frames: what a beacon and its kin carry
// ---------------------------------------------------------------------------

/// The fixed part of a beacon or probe response: when it was sent, how
/// often, and what the cell offers.
pub const Beacon = struct {
    pub const FIXED = 12;

    timestamp: u64,
    /// Beacon interval in time units of 1024 microseconds.
    interval: u16,
    capability: Capability,
    /// The information elements that follow, in the frame they came in.
    elements: []const u8,

    pub const Capability = packed struct(u16) {
        ess: bool = false,
        ibss: bool = false,
        _2: u2 = 0,
        privacy: bool = false,
        short_preamble: bool = false,
        _6: u4 = 0,
        short_slot_time: bool = false,
        _11: u5 = 0,
    };

    pub fn parse(body: []const u8) ?Beacon {
        if (body.len < FIXED) return null;
        return .{
            .timestamp = std.mem.readInt(u64, body[0..8], .little),
            .interval = std.mem.readInt(u16, body[8..10], .little),
            .capability = @bitCast(std.mem.readInt(u16, body[10..12], .little)),
            .elements = body[FIXED..],
        };
    }
};

/// The information elements this system reads or writes.
pub const ElementId = enum(u8) {
    ssid = 0,
    supported_rates = 1,
    ds_parameter = 3,
    tim = 5,
    country = 7,
    erp = 42,
    ht_capabilities = 45,
    rsn = 48,
    extended_rates = 50,
    ht_operation = 61,
    vendor = 221,
    _,
};

/// One information element: its identity and its bytes.
pub const Element = struct {
    id: ElementId,
    payload: []const u8,
};

/// Walk the information elements of a management frame's body. An element
/// whose length runs past the frame ends the walk, since nothing after it
/// can be trusted to start where it claims.
pub const Elements = struct {
    rest: []const u8,

    pub fn next(self: *Elements) ?Element {
        if (self.rest.len < 2) return null;
        const len: usize = self.rest[1];
        if (self.rest.len < 2 + len) {
            self.rest = &.{};
            return null;
        }
        const found = Element{ .id = @enumFromInt(self.rest[0]), .payload = self.rest[2 .. 2 + len] };
        self.rest = self.rest[2 + len ..];
        return found;
    }
};

pub fn elements(body: []const u8) Elements {
    return .{ .rest = body };
}

/// The first element of a kind, if the body has one.
pub fn element(body: []const u8, id: ElementId) ?[]const u8 {
    var it = elements(body);
    while (it.next()) |found| {
        if (found.id == id) return found.payload;
    }
    return null;
}

/// Write one element: its identity, its length, its bytes.
pub fn writeElement(into: []u8, id: ElementId, payload: []const u8) ?usize {
    if (payload.len > std.math.maxInt(u8) or into.len < 2 + payload.len) return null;
    into[0] = @intFromEnum(id);
    into[1] = @intCast(payload.len);
    @memcpy(into[2..][0..payload.len], payload);
    return 2 + payload.len;
}

/// The robust security element: which ciphers and which key management a
/// cell uses. Only the one combination this system joins with is read
/// out in full; anything else is a cell it does not join.
pub const Rsn = struct {
    /// The cipher and key-management suites, under the standard's prefix.
    pub const Suite = enum(u8) {
        use_group = 0,
        wep40 = 1,
        tkip = 2,
        ccmp = 4,
        wep104 = 5,
        _,
    };
    pub const Akm = enum(u8) {
        eap = 1,
        psk = 2,
        sae = 8,
        _,
    };
    const OUI = [_]u8{ 0x00, 0x0F, 0xAC };
    const VERSION: u16 = 1;

    group: Suite,
    pairwise_ccmp: bool,
    psk: bool,
    /// Simultaneous authentication of equals: the key management WPA3
    /// personal uses. Read only so a scan can name such a network; this
    /// system does not join one.
    sae: bool,

    /// The element this station offers: version one, CCMP for the group
    /// and the pair, a pre-shared key, no capabilities.
    pub const psk_ccmp = [_]u8{ 0x01, 0x00 } ++ OUI ++ [_]u8{@intFromEnum(Suite.ccmp)} ++
        [_]u8{ 0x01, 0x00 } ++ OUI ++ [_]u8{@intFromEnum(Suite.ccmp)} ++
        [_]u8{ 0x01, 0x00 } ++ OUI ++ [_]u8{@intFromEnum(Akm.psk)} ++
        [_]u8{ 0x00, 0x00 };

    pub fn parse(payload: []const u8) ?Rsn {
        if (payload.len < 2 or std.mem.readInt(u16, payload[0..2], .little) != VERSION) return null;
        var at: usize = 2;
        // Each part is optional after the one before: a cell may say only
        // its version and mean the defaults for the rest.
        var out = Rsn{ .group = .ccmp, .pairwise_ccmp = true, .psk = false, .sae = false };
        if (payload.len < at + 4) return out;
        out.group = suiteOf(payload[at..][0..4]) orelse return null;
        at += 4;

        out.pairwise_ccmp = false;
        if (payload.len < at + 2) return out;
        const pairwise = std.mem.readInt(u16, payload[at..][0..2], .little);
        at += 2;
        for (0..pairwise) |_| {
            if (payload.len < at + 4) return null;
            if (suiteOf(payload[at..][0..4]) == .ccmp) out.pairwise_ccmp = true;
            at += 4;
        }

        if (payload.len < at + 2) return out;
        const akms = std.mem.readInt(u16, payload[at..][0..2], .little);
        at += 2;
        for (0..akms) |_| {
            if (payload.len < at + 4) return null;
            if (std.mem.eql(u8, payload[at..][0..3], &OUI)) switch (@as(Akm, @enumFromInt(payload[at + 3]))) {
                .psk => out.psk = true,
                .sae => out.sae = true,
                else => {},
            };
            at += 4;
        }
        return out;
    }

    fn suiteOf(bytes: *const [4]u8) ?Suite {
        if (!std.mem.eql(u8, bytes[0..3], &OUI)) return null;
        return @enumFromInt(bytes[3]);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const AP = mac.Address{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
const US = mac.Address{ 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B };
const PEER = mac.Address{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };

test "frame control packs the way the wire reads it" {
    // Data frame, subtype 0, from the distribution system.
    const wire: u16 = 0x0208;
    const control: FrameControl = @bitCast(wire);
    try std.testing.expectEqual(Kind.data, control.kind);
    try std.testing.expectEqual(@as(u4, 0), control.subtype);
    try std.testing.expect(control.from_ds);
    try std.testing.expect(!control.to_ds);
    try std.testing.expectEqual(wire, @as(u16, @bitCast(control)));
}

test "a beacon parses as management with the cell it announces" {
    var frame: [Header.MIN]u8 = @splat(0);
    const head = Header{
        .control = FrameControl.management(.beacon),
        .addr1 = @splat(0xFF),
        .addr2 = AP,
        .addr3 = AP,
    };
    _ = head.write(&frame);

    const seen = Header.parse(&frame).?;
    try std.testing.expectEqual(Kind.management, seen.control.kind);
    try std.testing.expectEqual(ManagementSubtype.beacon, seen.control.managementSubtype());
    try std.testing.expectEqual(@as(usize, Header.MIN), seen.len);
    try std.testing.expectEqualSlices(u8, &AP, &seen.bssid());
}

test "a qos frame's header grows by its control word, and again for ht" {
    var frame: [40]u8 = @splat(0);
    var head = Header{
        .control = FrameControl.data(.qos_data),
        .qos = .{ .tid = 6 },
    };
    head.control.from_ds = true;
    _ = head.write(&frame);
    try std.testing.expectEqual(@as(usize, Header.MIN + 2), Header.parse(&frame).?.len);

    head.control.order = true;
    head.ht_control = 0x1234_5678;
    _ = head.write(&frame);
    const seen = Header.parse(&frame).?;
    try std.testing.expectEqual(@as(usize, Header.MIN + 6), seen.len);
    try std.testing.expectEqual(@as(?u32, 0x1234_5678), seen.ht_control);
    try std.testing.expectEqual(@as(u4, 6), seen.qos.?.tid);
}

test "addresses answer to the direction the frame travelled" {
    var to_ap = Header{ .control = FrameControl.data(.data), .addr1 = AP, .addr2 = US, .addr3 = PEER };
    to_ap.control.to_ds = true;
    const out_ends = to_ap.endpoints();
    try std.testing.expectEqualSlices(u8, &PEER, &out_ends.destination);
    try std.testing.expectEqualSlices(u8, &US, &out_ends.source);
    try std.testing.expectEqualSlices(u8, &AP, &to_ap.bssid());

    var from_ap = Header{ .control = FrameControl.data(.data), .addr1 = US, .addr2 = AP, .addr3 = PEER };
    from_ap.control.from_ds = true;
    const in_ends = from_ap.endpoints();
    try std.testing.expectEqualSlices(u8, &US, &in_ends.destination);
    try std.testing.expectEqualSlices(u8, &PEER, &in_ends.source);
    try std.testing.expectEqualSlices(u8, &AP, &from_ap.bssid());
}

test "a received data frame becomes the ethernet frame the stack reads" {
    var frame: [64]u8 = @splat(0);
    var head = Header{ .control = FrameControl.data(.data), .addr1 = US, .addr2 = AP, .addr3 = PEER };
    head.control.from_ds = true;
    const wrote = head.write(&frame).?;
    const snap = Snap.write(frame[wrote..], Ethertype.ipv4).?;
    const payload = [_]u8{ 0x45, 0x00, 0xDE, 0xAD };
    @memcpy(frame[wrote + snap ..][0..payload.len], &payload);

    var ethernet: [64]u8 = @splat(0);
    const len = toEthernet(frame[0 .. wrote + snap + payload.len], &ethernet).?;

    try std.testing.expectEqual(@as(usize, 14 + payload.len), len);
    try std.testing.expectEqualSlices(u8, &US, ethernet[0..6]);
    try std.testing.expectEqualSlices(u8, &PEER, ethernet[6..12]);
    try std.testing.expectEqual(Ethertype.ipv4, std.mem.readInt(u16, ethernet[12..14], .big));
    try std.testing.expectEqualSlices(u8, &payload, ethernet[14..len]);
}

test "an ethernet frame becomes a frame addressed to the access point" {
    var ethernet: [32]u8 = @splat(0);
    @memcpy(ethernet[0..6], &PEER);
    @memcpy(ethernet[6..12], &US);
    std.mem.writeInt(u16, ethernet[12..14], Ethertype.arp, .big);
    const payload = [_]u8{ 1, 2, 3, 4, 5, 6 };
    @memcpy(ethernet[14..20], &payload);

    var frame: [64]u8 = @splat(0);
    const len = fromEthernet(ethernet[0..20], AP, .{ .sequence = 7 }, &frame).?;

    const head = Header.parse(frame[0..len]).?;
    try std.testing.expect(head.control.to_ds);
    try std.testing.expect(!head.control.from_ds);
    try std.testing.expectEqualSlices(u8, &AP, &head.addr1);
    try std.testing.expectEqualSlices(u8, &US, &head.addr2);
    try std.testing.expectEqualSlices(u8, &PEER, &head.addr3);
    try std.testing.expectEqual(@as(u12, 7), head.sequence.sequence);
    try std.testing.expectEqual(Ethertype.arp, Snap.ethertypeOf(frame[head.len..len]).?);
    try std.testing.expectEqualSlices(u8, &payload, frame[head.len + Snap.BYTES .. len]);
}

test "a frame that is truncated, unframed or empty is refused rather than guessed" {
    var frame: [Header.MIN]u8 = @splat(0);
    const head = Header{ .control = FrameControl.data(.data) };
    _ = head.write(&frame);

    var ethernet: [64]u8 = @splat(0);
    // No SNAP header follows, so there is no ethertype to carry over.
    try std.testing.expectEqual(@as(?usize, null), toEthernet(&frame, &ethernet));
    try std.testing.expectEqual(@as(?Header, null), Header.parse(frame[0 .. Header.MIN - 1]));

    // A null data frame carries nothing and must not be forwarded as if
    // it did.
    var empty = Header{ .control = FrameControl.data(.null_data) };
    empty.control.from_ds = true;
    _ = empty.write(&frame);
    try std.testing.expectEqual(@as(?usize, null), toEthernet(&frame, &ethernet));
}

test "the elements of a beacon are walked, found by kind, and a torn one ends the walk" {
    var body: [64]u8 = @splat(0);
    var at: usize = Beacon.FIXED;
    std.mem.writeInt(u16, body[8..10], 100, .little);
    std.mem.writeInt(u16, body[10..12], @bitCast(Beacon.Capability{ .ess = true, .privacy = true }), .little);
    at += writeElement(body[at..], .ssid, "home").?;
    at += writeElement(body[at..], .ds_parameter, &.{6}).?;
    at += writeElement(body[at..], .rsn, &Rsn.psk_ccmp).?;

    const beacon = Beacon.parse(body[0..at]).?;
    try std.testing.expectEqual(@as(u16, 100), beacon.interval);
    try std.testing.expect(beacon.capability.ess and beacon.capability.privacy);
    try std.testing.expectEqualStrings("home", element(beacon.elements, .ssid).?);
    try std.testing.expectEqual(@as(u8, 6), element(beacon.elements, .ds_parameter).?[0]);
    try std.testing.expectEqual(@as(?[]const u8, null), element(beacon.elements, .tim));

    const rsn = Rsn.parse(element(beacon.elements, .rsn).?).?;
    try std.testing.expect(rsn.pairwise_ccmp and rsn.psk);
    try std.testing.expectEqual(Rsn.Suite.ccmp, rsn.group);

    // An element claiming more bytes than the frame has ends the walk
    // without yielding it.
    var torn = elements(&[_]u8{ 0, 1, 'a', 3, 5, 1 });
    try std.testing.expectEqualStrings("a", torn.next().?.payload);
    try std.testing.expectEqual(@as(?Element, null), torn.next());
}

test "a cell with a different cipher or key management is not one this station joins with" {
    // TKIP for the pair, and enterprise key management.
    var payload = Rsn.psk_ccmp;
    payload[11] = @intFromEnum(Rsn.Suite.tkip);
    payload[17] = @intFromEnum(Rsn.Akm.eap);
    const rsn = Rsn.parse(&payload).?;
    try std.testing.expect(!rsn.pairwise_ccmp);
    try std.testing.expect(!rsn.psk);
    // A version this file does not know is refused.
    payload[0] = 2;
    try std.testing.expectEqual(@as(?Rsn, null), Rsn.parse(&payload));
}
