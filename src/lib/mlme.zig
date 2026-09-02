//! 802.11 management: the frames a station exchanges to find, authenticate
//! with and join an access point, and the account of a network a scan keeps.
//!
//! Pure and host-tested. The state machine that decides when each of these
//! is sent runs in the driver, over a radio; what is here is only the bytes,
//! so a test builds a frame, reads it back, and checks the two agree. The
//! addresses are the header's, which `ieee80211` already writes and parses;
//! this file is the body after it, and the elements after that.
//!
//! The frames are the standard's, and small: a station that only ever joins
//! one infrastructure network with a pre-shared key needs open-system
//! authentication, an association request that offers its rates and its
//! security element, and the deauthentication that ends it. The rest of the
//! management repertoire, a station never sends.

const std = @import("std");
const ieee80211 = @import("ieee80211.zig");
const wifi = @import("wifi.zig");
const mac = @import("mac.zig");

const Header = ieee80211.Header;
const FrameControl = ieee80211.FrameControl;
const Capability = ieee80211.Beacon.Capability;

// ---------------------------------------------------------------------------
// The words the standard fixes: how a station proves itself, and why a
// request or an association ended
// ---------------------------------------------------------------------------

/// How a station proves itself. Only open system is used here: on a WPA2
/// network the real proof is the four-way handshake above, and the
/// authentication frame is a formality that says "open" and succeeds.
pub const AuthAlgorithm = enum(u16) {
    open_system = 0,
    shared_key = 1,
    /// The authentication of WPA3, which this station reads the name of but
    /// does not speak.
    sae = 3,
    _,
};

/// Why an authentication or association request succeeded or failed. Only
/// the outcomes this station tells apart are named; any other is a failure
/// it reports by its number.
pub const Status = enum(u16) {
    success = 0,
    unspecified = 1,
    capability_mismatch = 10,
    denied_association = 12,
    denied_auth_algorithm = 13,
    denied_auth_sequence = 14,
    challenge_failure = 15,
    timeout = 16,
    denied_rates = 18,
    _,

    pub fn ok(self: Status) bool {
        return self == .success;
    }
};

/// Why an association ended, in a deauthentication or disassociation frame:
/// the reason a scan-and-join retries, asks for the passphrase again, or
/// gives up.
pub const Reason = enum(u16) {
    unspecified = 1,
    prior_authentication_invalid = 2,
    leaving = 3,
    inactivity = 4,
    overload = 5,
    class2_from_unauthenticated = 6,
    class3_from_unassociated = 7,
    disassociation_leaving = 8,
    association_without_authentication = 9,
    invalid_information_element = 13,
    michael_failure = 14,
    four_way_handshake_timeout = 15,
    group_key_handshake_timeout = 16,
    information_element_mismatch = 17,
    invalid_pairwise_cipher = 19,
    invalid_akmp = 20,
    /// The four-way handshake found the wrong key: how a mistyped
    /// passphrase reaches the person who typed it.
    ieee8021x_auth_failed = 23,
    _,
};

// ---------------------------------------------------------------------------
// The rates a b/g station offers, in the two elements that carry them
// ---------------------------------------------------------------------------

comptime {
    if (wifi.b_rates.len != 4 or wifi.g_rates.len != 8) {
        @compileError("the supported-rates split assumes four b rates and eight g rates");
    }
}

/// The mark on a rate the network requires rather than merely allows.
const RATE_BASIC: u8 = 0x80;

/// The supported-rates and extended-rates elements a b/g station offers:
/// the four 802.11b rates marked basic, then the eight OFDM rates, split
/// because the first element holds at most eight rates and the rest go in
/// the second.
pub fn writeRates(into: []u8) ?usize {
    var supported: [8]u8 = undefined;
    for (wifi.b_rates, 0..) |rate, i| supported[i] = @intFromEnum(rate) | RATE_BASIC;
    for (wifi.g_rates[0..4], 0..) |rate, i| supported[4 + i] = @intFromEnum(rate);

    var extended: [wifi.g_rates.len - 4]u8 = undefined;
    for (wifi.g_rates[4..], 0..) |rate, i| extended[i] = @intFromEnum(rate);

    var at: usize = 0;
    at += ieee80211.writeElement(into[at..], .supported_rates, &supported) orelse return null;
    at += ieee80211.writeElement(into[at..], .extended_rates, &extended) orelse return null;
    return at;
}

// ---------------------------------------------------------------------------
// The frames, each built onto a header the caller has addressed
// ---------------------------------------------------------------------------

/// Set the frame's kind and clear the distribution-system bits, which a
/// management frame does not use, leaving the addresses the caller gave.
fn managementHeader(header: Header, subtype: ieee80211.ManagementSubtype) Header {
    var head = header;
    head.control = FrameControl.management(subtype);
    return head;
}

/// The authentication frame: open system, sequence one for the request and
/// two for the answer, and a status the answer carries.
pub const Auth = struct {
    pub const FIXED = 6;

    algorithm: AuthAlgorithm = .open_system,
    sequence: u16 = 1,
    status: Status = .success,

    pub fn write(header: Header, self: Auth, into: []u8) ?usize {
        const head = managementHeader(header, .authentication);
        const wrote = head.write(into) orelse return null;
        if (into.len < wrote + FIXED) return null;
        std.mem.writeInt(u16, into[wrote..][0..2], @intFromEnum(self.algorithm), .little);
        std.mem.writeInt(u16, into[wrote + 2 ..][0..2], self.sequence, .little);
        std.mem.writeInt(u16, into[wrote + 4 ..][0..2], @intFromEnum(self.status), .little);
        return wrote + FIXED;
    }

    pub fn parse(frame: []const u8) ?Auth {
        const head = Header.parse(frame) orelse return null;
        if (head.control.kind != .management or head.control.managementSubtype() != .authentication) return null;
        const body = frame[head.len..];
        if (body.len < FIXED) return null;
        return .{
            .algorithm = @enumFromInt(std.mem.readInt(u16, body[0..2], .little)),
            .sequence = std.mem.readInt(u16, body[2..4], .little),
            .status = @enumFromInt(std.mem.readInt(u16, body[4..6], .little)),
        };
    }
};

/// The association request: what the station can do, how often it will wake
/// to listen, the network's name, the rates it offers, and, for a protected
/// network, the security element the four-way handshake is bound to.
pub const AssocRequest = struct {
    pub const FIXED = 4;

    capability: Capability = .{ .ess = true },
    listen_interval: u16 = 1,

    /// Write the request. `rsn` is the security element's payload, or empty
    /// for an open network.
    pub fn write(header: Header, self: AssocRequest, ssid: wifi.Ssid, rsn: []const u8, into: []u8) ?usize {
        const head = managementHeader(header, .association_request);
        var at = head.write(into) orelse return null;
        if (into.len < at + FIXED) return null;
        std.mem.writeInt(u16, into[at..][0..2], @bitCast(self.capability), .little);
        std.mem.writeInt(u16, into[at + 2 ..][0..2], self.listen_interval, .little);
        at += FIXED;

        at += ieee80211.writeElement(into[at..], .ssid, ssid.slice()) orelse return null;
        at += writeRates(into[at..]) orelse return null;
        if (rsn.len > 0) at += ieee80211.writeElement(into[at..], .rsn, rsn) orelse return null;
        return at;
    }

    pub const Parsed = struct {
        capability: Capability,
        listen_interval: u16,
        elements: []const u8,
    };

    pub fn parse(frame: []const u8) ?Parsed {
        const head = Header.parse(frame) orelse return null;
        if (head.control.kind != .management or head.control.managementSubtype() != .association_request) return null;
        const body = frame[head.len..];
        if (body.len < FIXED) return null;
        return .{
            .capability = @bitCast(std.mem.readInt(u16, body[0..2], .little)),
            .listen_interval = std.mem.readInt(u16, body[2..4], .little),
            .elements = body[FIXED..],
        };
    }
};

/// The association response: whether the join was granted, and the
/// association identifier the access point assigns when it is.
pub const AssocResponse = struct {
    pub const FIXED = 6;
    /// The two high bits an access point sets in the identifier on the wire,
    /// above the fourteen that are the number itself.
    const AID_FIXED: u16 = 0xC000;

    capability: Capability = .{ .ess = true },
    status: Status = .success,
    /// The association identifier, the fourteen-bit number itself.
    aid: u16 = 0,

    pub fn write(header: Header, self: AssocResponse, into: []u8) ?usize {
        const head = managementHeader(header, .association_response);
        var at = head.write(into) orelse return null;
        if (into.len < at + FIXED) return null;
        std.mem.writeInt(u16, into[at..][0..2], @bitCast(self.capability), .little);
        std.mem.writeInt(u16, into[at + 2 ..][0..2], @intFromEnum(self.status), .little);
        std.mem.writeInt(u16, into[at + 4 ..][0..2], self.aid | AID_FIXED, .little);
        at += FIXED;
        // A granted station is offered the rates the cell runs at.
        at += writeRates(into[at..]) orelse return null;
        return at;
    }

    pub fn parse(frame: []const u8) ?AssocResponse {
        const head = Header.parse(frame) orelse return null;
        if (head.control.kind != .management or head.control.managementSubtype() != .association_response) return null;
        const body = frame[head.len..];
        if (body.len < FIXED) return null;
        return .{
            .capability = @bitCast(std.mem.readInt(u16, body[0..2], .little)),
            .status = @enumFromInt(std.mem.readInt(u16, body[2..4], .little)),
            .aid = std.mem.readInt(u16, body[4..6], .little) & ~AID_FIXED,
        };
    }
};

/// The probe request a scan sends to make hidden and quiet networks answer:
/// a name, or none for every network at once, and the rates the asker has.
pub const ProbeRequest = struct {
    pub fn write(header: Header, ssid: wifi.Ssid, into: []u8) ?usize {
        const head = managementHeader(header, .probe_request);
        var at = head.write(into) orelse return null;
        at += ieee80211.writeElement(into[at..], .ssid, ssid.slice()) orelse return null;
        at += writeRates(into[at..]) orelse return null;
        return at;
    }
};

/// A deauthentication or disassociation frame: the end of an association,
/// and why. One shape for both, because they differ only in their subtype
/// and in that deauthentication also undoes the authentication beneath.
pub const Farewell = struct {
    pub const FIXED = 2;

    subtype: ieee80211.ManagementSubtype,
    reason: Reason,

    pub fn deauthentication(reason: Reason) Farewell {
        return .{ .subtype = .deauthentication, .reason = reason };
    }

    pub fn disassociation(reason: Reason) Farewell {
        return .{ .subtype = .disassociation, .reason = reason };
    }

    pub fn write(header: Header, self: Farewell, into: []u8) ?usize {
        const head = managementHeader(header, self.subtype);
        const wrote = head.write(into) orelse return null;
        if (into.len < wrote + FIXED) return null;
        std.mem.writeInt(u16, into[wrote..][0..2], @intFromEnum(self.reason), .little);
        return wrote + FIXED;
    }

    pub fn parse(frame: []const u8) ?Farewell {
        const head = Header.parse(frame) orelse return null;
        if (head.control.kind != .management) return null;
        const subtype = head.control.managementSubtype();
        if (subtype != .deauthentication and subtype != .disassociation) return null;
        const body = frame[head.len..];
        if (body.len < FIXED) return null;
        return .{
            .subtype = subtype,
            .reason = @enumFromInt(std.mem.readInt(u16, body[0..2], .little)),
        };
    }
};

// ---------------------------------------------------------------------------
// What a scan makes of a beacon: the account a chooser shows and a join uses
// ---------------------------------------------------------------------------

/// One network as a scan found it: enough to show it in a list, to decide
/// whether it can be joined, and to join it. Everything here is read from a
/// beacon or a probe response, save the signal, which the radio measures.
pub const Bss = struct {
    bssid: mac.Address,
    ssid: wifi.Ssid,
    /// The channel it announced, or zero when the beacon named none.
    channel: u8 = 0,
    security: wifi.Security,
    capability: Capability,
    signal: wifi.Signal = .{},

    /// Read a beacon or probe response. The signal is the radio's, passed
    /// in because the frame does not carry it.
    pub fn fromBeacon(frame: []const u8, signal: wifi.Signal) ?Bss {
        const head = Header.parse(frame) orelse return null;
        if (head.control.kind != .management) return null;
        const subtype = head.control.managementSubtype();
        if (subtype != .beacon and subtype != .probe_response) return null;

        const beacon = ieee80211.Beacon.parse(frame[head.len..]) orelse return null;
        const name = ieee80211.element(beacon.elements, .ssid) orelse &.{};
        const ssid = wifi.Ssid.of(name) orelse return null;

        var channel: u8 = 0;
        if (ieee80211.element(beacon.elements, .ds_parameter)) |ds| {
            if (ds.len >= 1) channel = ds[0];
        }

        return .{
            .bssid = head.bssid(),
            .ssid = ssid,
            .channel = channel,
            .security = securityOf(beacon.capability, beacon.elements),
            .capability = beacon.capability,
            .signal = signal,
        };
    }
};

/// What protection a network advertises, named so a scan can show it whether
/// or not this system will join it. The robust-security element decides
/// between the WPA generations; the privacy bit alone, without one, is the
/// old wired-equivalent cipher.
fn securityOf(capability: Capability, elements: []const u8) wifi.Security {
    if (ieee80211.element(elements, .rsn)) |payload| {
        const rsn = ieee80211.Rsn.parse(payload) orelse return .unsupported;
        if (rsn.sae) return .wpa3_sae;
        if (rsn.psk and rsn.pairwise_ccmp) return .wpa2_psk;
        return .unsupported;
    }
    // A first-generation WPA network carries its parameters in a vendor
    // element instead; this system reads the name but does not join one.
    if (ieee80211.element(elements, .vendor)) |vendor| {
        const WPA1 = [_]u8{ 0x00, 0x50, 0xF2, 0x01 };
        if (vendor.len >= WPA1.len and std.mem.eql(u8, vendor[0..WPA1.len], &WPA1)) return .unsupported;
    }
    if (capability.privacy) return .wep;
    return .open;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const AP = mac.Address{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
const US = mac.Address{ 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B };

/// A management header addressed from this station to its access point, the
/// three-address form every frame here uses.
fn toAp() Header {
    return .{ .addr1 = AP, .addr2 = US, .addr3 = AP };
}

test "an open-system authentication is asked and answered" {
    var frame: [64]u8 = @splat(0);
    const len = Auth.write(toAp(), .{ .sequence = 1 }, &frame).?;

    const seen = Auth.parse(frame[0..len]).?;
    try testing.expectEqual(AuthAlgorithm.open_system, seen.algorithm);
    try testing.expectEqual(@as(u16, 1), seen.sequence);
    try testing.expect(seen.status.ok());

    // The access point's answer: sequence two, and a status.
    const answer = Auth.write(.{ .addr1 = US, .addr2 = AP, .addr3 = AP }, .{ .sequence = 2, .status = .denied_rates }, &frame).?;
    const back = Auth.parse(frame[0..answer]).?;
    try testing.expectEqual(@as(u16, 2), back.sequence);
    try testing.expect(!back.status.ok());
    try testing.expectEqual(Status.denied_rates, back.status);
}

test "an association request carries the name, the rates and the security element" {
    const ssid = wifi.Ssid.of("home network").?;
    const rsn = ieee80211.Rsn.psk_ccmp;

    var frame: [128]u8 = @splat(0);
    const len = AssocRequest.write(toAp(), .{}, ssid, &rsn, &frame).?;

    const parsed = AssocRequest.parse(frame[0..len]).?;
    try testing.expect(parsed.capability.ess);
    try testing.expectEqual(@as(u16, 1), parsed.listen_interval);

    // The name is there, the rates parse, and the security element is the
    // one offered.
    const carried_name = ieee80211.element(parsed.elements, .ssid).?;
    try testing.expectEqualStrings("home network", carried_name);
    const carried_rates = ieee80211.element(parsed.elements, .supported_rates).?;
    try testing.expectEqual(@as(usize, 8), carried_rates.len);
    // The 1 Mbit rate is basic, marked with the high bit.
    try testing.expectEqual(@as(u8, @intFromEnum(wifi.Legacy.m1) | RATE_BASIC), carried_rates[0]);
    const carried_rsn = ieee80211.element(parsed.elements, .rsn).?;
    try testing.expect(ieee80211.Rsn.parse(carried_rsn).?.psk);
}

test "an association response grants an identifier, its two high bits stripped" {
    var frame: [64]u8 = @splat(0);
    const len = AssocResponse.write(.{ .addr1 = US, .addr2 = AP, .addr3 = AP }, .{ .status = .success, .aid = 7 }, &frame).?;

    const seen = AssocResponse.parse(frame[0..len]).?;
    try testing.expect(seen.status.ok());
    // The number comes back as itself, without the bits the wire sets above it.
    try testing.expectEqual(@as(u16, 7), seen.aid);

    // A refusal carries no useful identifier, and says why.
    const denied = AssocResponse.write(.{ .addr1 = US, .addr2 = AP, .addr3 = AP }, .{ .status = .denied_rates, .aid = 0 }, &frame).?;
    try testing.expectEqual(Status.denied_rates, AssocResponse.parse(frame[0..denied]).?.status);
}

test "a probe request asks for one network or for all of them" {
    var frame: [64]u8 = @splat(0);

    // A wildcard probe: an empty name, which every access point answers.
    const wild = ProbeRequest.write(toAp(), wifi.Ssid{}, &frame).?;
    const wild_head = Header.parse(frame[0..wild]).?;
    try testing.expectEqual(ieee80211.ManagementSubtype.probe_request, wild_head.control.managementSubtype());
    try testing.expectEqual(@as(usize, 0), ieee80211.element(frame[wild_head.len..wild], .ssid).?.len);

    // A directed probe names the network it is looking for.
    const named = ProbeRequest.write(toAp(), wifi.Ssid.of("cinaed").?, &frame).?;
    const named_head = Header.parse(frame[0..named]).?;
    try testing.expectEqualStrings("cinaed", ieee80211.element(frame[named_head.len..named], .ssid).?);
}

test "a farewell says which kind it is and why" {
    var frame: [64]u8 = @splat(0);
    const len = Farewell.write(toAp(), Farewell.deauthentication(.leaving), &frame).?;

    const seen = Farewell.parse(frame[0..len]).?;
    try testing.expectEqual(ieee80211.ManagementSubtype.deauthentication, seen.subtype);
    try testing.expectEqual(Reason.leaving, seen.reason);

    // A wrong key ends the association with the reason that names it, which a
    // disassociation carries just as well.
    const bad_key = Farewell.write(toAp(), Farewell.disassociation(.ieee8021x_auth_failed), &frame).?;
    const parsed = Farewell.parse(frame[0..bad_key]).?;
    try testing.expectEqual(ieee80211.ManagementSubtype.disassociation, parsed.subtype);
    try testing.expectEqual(Reason.ieee8021x_auth_failed, parsed.reason);
}

/// Assemble a beacon frame for the scan tests: a header from the cell, then
/// the fixed fields and the elements a real beacon carries.
fn beaconFrame(into: []u8, capability: Capability, elements: []const u8) usize {
    var head = Header{ .control = FrameControl.management(.beacon), .addr1 = @splat(0xFF), .addr2 = AP, .addr3 = AP };
    const wrote = head.write(into).?;
    std.mem.writeInt(u64, into[wrote..][0..8], 0x0102_0304_0506_0708, .little);
    std.mem.writeInt(u16, into[wrote + 8 ..][0..2], 100, .little);
    std.mem.writeInt(u16, into[wrote + 10 ..][0..2], @bitCast(capability), .little);
    @memcpy(into[wrote + 12 ..][0..elements.len], elements);
    return wrote + 12 + elements.len;
}

test "a scan reads a protected network's name, channel, cell and security" {
    var elements: [64]u8 = @splat(0);
    var at: usize = 0;
    at += ieee80211.writeElement(elements[at..], .ssid, "cinaed's network").?;
    at += ieee80211.writeElement(elements[at..], .ds_parameter, &.{6}).?;
    at += ieee80211.writeElement(elements[at..], .rsn, &ieee80211.Rsn.psk_ccmp).?;

    var frame: [128]u8 = @splat(0);
    const len = beaconFrame(&frame, .{ .ess = true, .privacy = true }, elements[0..at]);

    const bss = Bss.fromBeacon(frame[0..len], .{ .dbm = -60 }).?;
    try testing.expectEqualStrings("cinaed's network", bss.ssid.slice());
    try testing.expectEqual(@as(u8, 6), bss.channel);
    try testing.expectEqualSlices(u8, &AP, &bss.bssid);
    try testing.expectEqual(wifi.Security.wpa2_psk, bss.security);
    try testing.expect(bss.security.joinable());
    try testing.expectEqual(@as(i8, -60), bss.signal.dbm);
}

test "a scan names every protection, and joins only the two it can" {
    var frame: [128]u8 = @splat(0);

    // An open network: no privacy bit, no security element.
    var open_els: [16]u8 = @splat(0);
    const open_len = beaconFrame(&frame, .{ .ess = true }, open_els[0..ieee80211.writeElement(&open_els, .ssid, "cafe").?]);
    try testing.expectEqual(wifi.Security.open, Bss.fromBeacon(frame[0..open_len], .{}).?.security);

    // Privacy set but no robust-security element: the old cipher, named and
    // refused.
    var wep_els: [16]u8 = @splat(0);
    const wep_len = beaconFrame(&frame, .{ .ess = true, .privacy = true }, wep_els[0..ieee80211.writeElement(&wep_els, .ssid, "old").?]);
    const wep = Bss.fromBeacon(frame[0..wep_len], .{}).?;
    try testing.expectEqual(wifi.Security.wep, wep.security);
    try testing.expect(!wep.security.joinable());

    // A WPA3 network: read, named, and not joined.
    var sae_payload = ieee80211.Rsn.psk_ccmp;
    sae_payload[17] = @intFromEnum(ieee80211.Rsn.Akm.sae);
    var sae_els: [48]u8 = @splat(0);
    var sae_at: usize = 0;
    sae_at += ieee80211.writeElement(sae_els[sae_at..], .ssid, "new").?;
    sae_at += ieee80211.writeElement(sae_els[sae_at..], .rsn, &sae_payload).?;
    const sae_len = beaconFrame(&frame, .{ .ess = true, .privacy = true }, sae_els[0..sae_at]);
    const sae = Bss.fromBeacon(frame[0..sae_len], .{}).?;
    try testing.expectEqual(wifi.Security.wpa3_sae, sae.security);
    try testing.expect(!sae.security.joinable());
}
