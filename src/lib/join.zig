//! Joining a network: the order the standard puts it in, as a value.
//!
//! Finding the network, authenticating, associating and proving the key are
//! four exchanges that must happen in that order, each with its own answer to
//! wait for and its own way of going wrong. That sequence is the whole of
//! joining, and none of it needs a radio to be right: it is frames in and
//! frames out. So it is written here as a value the station drives, and a
//! test plays the access point against it, from the first beacon to the keys.
//!
//! The station hands it what the radio heard and what the clock says, and is
//! told what to do: tune here, send this, we are joined, give up. Nothing in
//! this file touches a register, allocates, or knows what a radio is; the
//! frames come from `mlme.zig` and the key exchange from `wpa2.zig`, both
//! already tested against the standard's own vectors.

const std = @import("std");
const ieee80211 = @import("ieee80211.zig");
const mac = @import("mac.zig");
const mlme = @import("mlme.zig");
const wifi = @import("wifi.zig");
const wpa2 = @import("wpa2.zig");

/// How long an answer is waited for before the step is tried again.
pub const REPLY_MICROS: u64 = 300_000;

/// How many times a step is tried before the join is given up. The air is
/// lossy and a frame going missing is ordinary; an access point that has
/// answered none of three is one that is not going to.
pub const TRIES = 3;

/// Where a join has got to.
pub const State = enum {
    /// Nothing is wanted.
    idle,
    /// A network is named but has not been heard yet.
    seeking,
    /// Heard, and the radio is being pointed at its channel.
    tuning,
    /// Asked to authenticate.
    authenticating,
    /// Authenticated, and asked to associate.
    associating,
    /// Associated, and proving the key.
    handshaking,
    /// Joined: the keys are the caller's to install and the carrier is up.
    joined,
    /// Given up. `failure` says why.
    failed,
};

/// Why a join ended.
pub const Failure = enum {
    /// The network's protection is not one this system speaks.
    unsupported,
    /// It needs a key and none was configured.
    no_key,
    /// The access point refused.
    refused,
    /// It stopped answering.
    timed_out,
    /// The key exchange failed: the wrong secret, or a torn exchange.
    bad_key,

    pub fn spell(self: Failure) []const u8 {
        return switch (self) {
            .unsupported => "its protection is not one this system speaks",
            .no_key => "it needs a key and none is set",
            .refused => "the access point refused",
            .timed_out => "it stopped answering",
            .bad_key => "the key was not accepted",
        };
    }
};

/// What the station should do about the pass just taken.
pub const Action = union(enum) {
    /// Nothing to do.
    none,
    /// Send this many bytes of the buffer that was passed in.
    send: usize,
    /// Point the radio here first: the network was heard on this channel.
    tune: wifi.Channel,
    /// Joined. What to install, and what the cell is.
    joined: Joined,
    /// Give up, for this reason.
    failed: Failure,
};

/// The end of a join: the cell, the identifier it gave, and the keys, which
/// an open network does not have.
pub const Joined = struct {
    bssid: mac.Address,
    aid: u14,
    keys: ?wpa2.Handshake.Keys = null,
};

/// The security element this station offers, and the one the key exchange is
/// bound to. Both sides must see the same bytes, which is why there is one
/// spelling of it.
const OFFERED_RSN = ieee80211.Rsn.psk_ccmp;

/// The same thing with the two bytes an information element carries in
/// front of it. The association request has those written for it; the key
/// exchange carries the element whole, because what both ends check is
/// that the bytes seen in the association are the bytes seen here.
const OFFERED_RSN_ELEMENT =
    [_]u8{ @intFromEnum(ieee80211.ElementId.rsn), OFFERED_RSN.len } ++ OFFERED_RSN;

/// Room for the key frame the handshake writes before it is wrapped in a
/// data frame.
const KEY_FRAME_MAX = wpa2.KeyFrame.HEAD + wpa2.KEY_DATA_MAX;

pub const Join = struct {
    /// This station's own address, which every frame it sends carries.
    station: mac.Address,

    /// What is wanted, and what to join it with.
    want: wifi.Ssid = .{},
    psk: wifi.Psk = .none,
    /// This station's nonce for the key exchange. Drawn by the caller,
    /// because a value cannot draw a random number and stay one.
    snonce: wpa2.Nonce = @splat(0),

    state: State = .idle,
    failure: Failure = .timed_out,
    /// Where it was when it gave up. A join that ran out of attempts says
    /// only that nothing answered; which step nothing answered at is the
    /// thing worth knowing.
    failed_in: State = .idle,
    /// The network being joined, once one has been heard.
    bss: ?mlme.Bss = null,
    /// What the access point granted.
    aid: u14 = 0,

    handshake: ?wpa2.Handshake = null,
    /// The key frame the handshake writes, before it is wrapped.
    scratch: [KEY_FRAME_MAX]u8 = @splat(0),

    /// When the step in hand stops being waited for, and how many attempts
    /// it has left.
    deadline: u64 = 0,
    left: u8 = 0,
    /// The keys, once the exchange has finished, held until the caller is
    /// told to install them.
    earned: ?wpa2.Handshake.Keys = null,
    /// The last frame of the exchange has been handed over, so the join is
    /// finished on the next look.
    settling: bool = false,

    sequence: u12 = 0,

    /// Ask to join a network. `snonce` is this station's nonce for the key
    /// exchange, which the caller draws.
    pub fn wants(self: *Join, ssid: wifi.Ssid, psk: wifi.Psk, snonce: wpa2.Nonce) void {
        self.want = ssid;
        self.psk = psk;
        self.snonce = snonce;
        self.state = if (ssid.len == 0) .idle else .seeking;
        self.bss = null;
        self.handshake = null;
        self.earned = null;
        self.settling = false;
        self.aid = 0;
        self.left = TRIES;
    }

    /// Stop wanting anything. The caller takes the association down.
    pub fn stop(self: *Join) void {
        self.* = .{ .station = self.station };
    }

    /// The cell being joined, or all zeroes before one is found.
    pub fn bssid(self: *const Join) mac.Address {
        return if (self.bss) |found| found.bssid else @splat(0);
    }

    /// The keys, once they have been earned.
    pub fn keys(self: *const Join) ?wpa2.Handshake.Keys {
        return self.earned;
    }

    // -----------------------------------------------------------------------
    // What the radio heard
    // -----------------------------------------------------------------------

    /// A frame arrived. Anything not part of this join is ignored, which is
    /// most of what a radio hears.
    pub fn heard(self: *Join, frame: []const u8, signal: wifi.Signal, now: u64, into: []u8) Action {
        return switch (self.state) {
            .seeking => self.sawBeacon(frame, signal),
            .authenticating => self.sawAuth(frame, now, into),
            .associating => self.sawAssoc(frame, now, into),
            .handshaking => self.sawKey(frame, now, into),
            else => .none,
        };
    }

    /// Time passed: send the step in hand, or try it again, or give up.
    pub fn tick(self: *Join, now: u64, into: []u8) Action {
        // The last frame of the exchange has gone; the join is finished.
        if (self.settling) {
            self.settling = false;
            self.state = .joined;
            return .{ .joined = .{ .bssid = self.bssid(), .aid = self.aid, .keys = self.earned } };
        }

        switch (self.state) {
            // The radio has been pointed at the channel; ask to authenticate.
            .tuning => return self.sendAuth(now, into),
            .authenticating, .associating, .handshaking => {
                if (now < self.deadline) return .none;
                return self.retry(now, into);
            },
            else => return .none,
        }
    }

    // -----------------------------------------------------------------------
    // Finding it
    // -----------------------------------------------------------------------

    fn sawBeacon(self: *Join, frame: []const u8, signal: wifi.Signal) Action {
        const seen = mlme.Bss.fromBeacon(frame, signal) orelse return .none;
        if (!seen.ssid.eql(self.want)) return .none;

        // What this system cannot join is said now rather than after three
        // exchanges that were never going to work.
        if (!seen.security.joinable()) return self.give(.unsupported);
        if (seen.security != .open and self.psk == .none) return self.give(.no_key);

        self.bss = seen;
        self.state = .tuning;
        self.left = TRIES;
        return .{ .tune = .{ .number = seen.channel } };
    }

    // -----------------------------------------------------------------------
    // Authenticating
    // -----------------------------------------------------------------------

    fn sendAuth(self: *Join, now: u64, into: []u8) Action {
        const len = mlme.Auth.write(self.toAp(), .{ .sequence = 1 }, into) orelse return .none;
        self.state = .authenticating;
        self.deadline = now + REPLY_MICROS;
        return .{ .send = len };
    }

    fn sawAuth(self: *Join, frame: []const u8, now: u64, into: []u8) Action {
        if (self.farewell(frame)) |ended| return ended;
        const answer = mlme.Auth.parse(frame) orelse return .none;
        if (!self.fromAp(frame)) return .none;
        // The station's own request, heard back, is not an answer to it.
        if (answer.sequence != 2) return .none;
        if (!answer.status.ok()) return self.give(.refused);
        self.left = TRIES;
        return self.sendAssoc(now, into);
    }

    // -----------------------------------------------------------------------
    // Associating
    // -----------------------------------------------------------------------

    fn sendAssoc(self: *Join, now: u64, into: []u8) Action {
        const protected = (self.bss orelse return .none).security != .open;
        const rsn: []const u8 = if (protected) &OFFERED_RSN else &.{};
        const len = mlme.AssocRequest.write(self.toAp(), .{}, self.want, rsn, into) orelse return .none;
        self.state = .associating;
        self.deadline = now + REPLY_MICROS;
        return .{ .send = len };
    }

    fn sawAssoc(self: *Join, frame: []const u8, now: u64, into: []u8) Action {
        _ = into;
        if (self.farewell(frame)) |ended| return ended;
        const answer = mlme.AssocResponse.parse(frame) orelse return .none;
        if (!self.fromAp(frame)) return .none;
        if (!answer.status.ok()) return self.give(.refused);

        self.aid = @truncate(answer.aid);
        const found = self.bss orelse return .none;

        // An open network is joined the moment it says so; a protected one
        // has still to prove the key.
        if (found.security == .open) {
            self.state = .joined;
            return .{ .joined = .{ .bssid = found.bssid, .aid = self.aid, .keys = null } };
        }

        const pmk = wpa2.pmkOf(self.psk, self.want) orelse return self.give(.no_key);
        self.handshake = .{
            .pmk = pmk,
            .station = self.station,
            .ap = found.bssid,
            .snonce = self.snonce,
            .rsn = &OFFERED_RSN_ELEMENT,
        };
        self.state = .handshaking;
        // The access point speaks first here, so this is a wait rather than
        // a send: the deadline is what makes a silent one give up.
        self.deadline = now + REPLY_MICROS;
        self.left = TRIES;
        return .none;
    }

    // -----------------------------------------------------------------------
    // Proving the key
    // -----------------------------------------------------------------------

    fn sawKey(self: *Join, frame: []const u8, now: u64, into: []u8) Action {
        if (self.farewell(frame)) |ended| return ended;
        const payload = eapolOf(frame) orelse return .none;
        if (!self.fromAp(frame)) return .none;
        // A pointer into the field, not to a copy of it: the exchange's
        // state, the transient key above all, has to outlive this pass.
        if (self.handshake == null) return .none;
        const shake = &self.handshake.?;

        return switch (shake.answer(payload, &self.scratch)) {
            .ignored => .none,
            .refused => self.give(.bad_key),
            .reply => |len| blk: {
                const wrapped = self.wrapEapol(self.scratch[0..len], into) orelse break :blk .none;
                // The exchange finishes on the frame this station sends
                // last, and the keys are installed after it has gone: a
                // frame enciphered with a key the access point has not
                // acknowledged is a frame nobody can read.
                // Latched once. The exchange's last frame can be asked
                // for again, and answering it again is not a second
                // joining.
                if (self.earned == null and shake.keys() != null) {
                    self.earned = shake.keys();
                    self.settling = true;
                } else if (shake.keys() == null) {
                    self.deadline = now + REPLY_MICROS;
                    self.left = TRIES;
                }
                break :blk .{ .send = wrapped };
            },
        };
    }

    // -----------------------------------------------------------------------
    // Going wrong
    // -----------------------------------------------------------------------

    /// The access point ending it, whichever way it said so.
    fn farewell(self: *Join, frame: []const u8) ?Action {
        if (mlme.Farewell.parse(frame) == null) return null;
        if (!self.fromAp(frame)) return null;
        return self.give(.refused);
    }

    /// Try the step in hand again, or give up when there are no tries left.
    fn retry(self: *Join, now: u64, into: []u8) Action {
        self.left -|= 1;
        if (self.left == 0) return self.give(.timed_out);

        return switch (self.state) {
            // The two steps this station speaks first are asked again.
            .authenticating => self.sendAuth(now, into),
            .associating => self.sendAssoc(now, into),
            // The key exchange is the access point's to open, so there is
            // nothing to ask again: it is waited through once more, and the
            // attempts running out is what ends it.
            .handshaking => blk: {
                self.deadline = now + REPLY_MICROS;
                break :blk .none;
            },
            else => .none,
        };
    }

    fn give(self: *Join, why: Failure) Action {
        self.failed_in = self.state;
        self.state = .failed;
        self.failure = why;
        return .{ .failed = why };
    }

    // -----------------------------------------------------------------------
    // Frames
    // -----------------------------------------------------------------------

    /// A header addressed from this station to the cell it is joining.
    fn toAp(self: *Join) ieee80211.Header {
        const cell = self.bssid();
        self.sequence +%= 1;
        return .{
            .addr1 = cell,
            .addr2 = self.station,
            .addr3 = cell,
            .sequence = .{ .sequence = self.sequence },
        };
    }

    /// Whether a frame came from the cell being joined, and is for this
    /// station. A radio hears every cell on the channel.
    fn fromAp(self: *const Join, frame: []const u8) bool {
        const found = self.bss orelse return false;
        const head = ieee80211.Header.parse(frame) orelse return false;
        return mac.eql(head.bssid(), found.bssid) and
            (mac.eql(head.addr1, self.station) or mac.isGroup(head.addr1));
    }

    /// Wrap a key frame as a data frame to the access point.
    fn wrapEapol(self: *Join, payload: []const u8, into: []u8) ?usize {
        var head = self.toAp();
        head.control = ieee80211.FrameControl.data(.data);
        head.control.to_ds = true;

        const wrote = head.write(into) orelse return null;
        const snap = ieee80211.Snap.write(into[wrote..], ieee80211.Ethertype.eapol) orelse return null;
        if (into.len < wrote + snap + payload.len) return null;
        @memcpy(into[wrote + snap ..][0..payload.len], payload);
        return wrote + snap + payload.len;
    }
};

/// The authentication payload of a data frame, or null when the frame
/// carries something else. What the supplicant reads and the stack never
/// sees.
pub fn eapolOf(frame: []const u8) ?[]const u8 {
    const head = ieee80211.Header.parse(frame) orelse return null;
    if (head.control.kind != .data) return null;
    if (!head.control.dataSubtype().hasPayload()) return null;

    const body = frame[head.len..];
    const ethertype = ieee80211.Snap.ethertypeOf(body) orelse return null;
    if (ethertype != ieee80211.Ethertype.eapol) return null;
    return body[ieee80211.Snap.BYTES..];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const AP = mac.Address{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
const US = mac.Address{ 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B };
const CHANNEL = 6;
const SSID = "home network";
const PASSPHRASE = "correct horse battery";

/// The access point's side, enough of it to answer a join.
const FakeAp = struct {
    protected: bool,
    anonce: wpa2.Nonce = @splat(0xA1),
    replay: u64 = 1,
    gtk: wpa2.Gtk = .{ .index = 1, .key = @splat(0x5C) },

    fn beacon(self: FakeAp, into: []u8) usize {
        var elements: [96]u8 = @splat(0);
        var at: usize = 0;
        at += ieee80211.writeElement(elements[at..], .ssid, SSID).?;
        at += ieee80211.writeElement(elements[at..], .ds_parameter, &.{CHANNEL}).?;
        if (self.protected) {
            at += ieee80211.writeElement(elements[at..], .rsn, &ieee80211.Rsn.psk_ccmp).?;
        }

        const head = ieee80211.Header{
            .control = ieee80211.FrameControl.management(.beacon),
            .addr1 = @splat(0xFF),
            .addr2 = AP,
            .addr3 = AP,
        };
        const wrote = head.write(into).?;
        std.mem.writeInt(u64, into[wrote..][0..8], 0, .little);
        std.mem.writeInt(u16, into[wrote + 8 ..][0..2], 100, .little);
        std.mem.writeInt(u16, into[wrote + 10 ..][0..2], @bitCast(ieee80211.Beacon.Capability{
            .ess = true,
            .privacy = self.protected,
        }), .little);
        @memcpy(into[wrote + 12 ..][0..at], elements[0..at]);
        return wrote + 12 + at;
    }

    fn fromAp() ieee80211.Header {
        return .{ .addr1 = US, .addr2 = AP, .addr3 = AP };
    }

    fn authOk(into: []u8) usize {
        return mlme.Auth.write(fromAp(), .{ .sequence = 2 }, into).?;
    }

    fn assocOk(aid: u16, into: []u8) usize {
        return mlme.AssocResponse.write(fromAp(), .{ .aid = aid }, into).?;
    }

    fn refuse(into: []u8) usize {
        return mlme.AssocResponse.write(fromAp(), .{ .status = .denied_rates }, into).?;
    }

    /// Wrap a key frame as the access point sends one.
    fn wrap(payload: []const u8, into: []u8) usize {
        var head = fromAp();
        head.control = ieee80211.FrameControl.data(.data);
        head.control.from_ds = true;
        const wrote = head.write(into).?;
        const snap = ieee80211.Snap.write(into[wrote..], ieee80211.Ethertype.eapol).?;
        @memcpy(into[wrote + snap ..][0..payload.len], payload);
        return wrote + snap + payload.len;
    }

    fn messageOne(self: FakeAp, into: []u8) usize {
        var key: [KEY_FRAME_MAX]u8 = @splat(0);
        const len = wpa2.KeyFrame.write(&key, .{ .pairwise = true, .ack = true }, 16, self.replay, self.anonce, &.{}).?;
        return wrap(key[0..len], into);
    }

    fn messageThree(self: *FakeAp, snonce: wpa2.Nonce, into: []u8) usize {
        const pmk = wpa2.derive(PASSPHRASE, SSID);
        const ptk = wpa2.ptkOf(pmk, AP, US, self.anonce, snonce);

        var data: [96]u8 = @splat(0);
        var used: usize = 0;
        used += ieee80211.writeElement(data[used..], .rsn, &ieee80211.Rsn.psk_ccmp).?;
        used += wpa2.writeGtk(data[used..], self.gtk).?;
        if (used % 8 != 0) {
            data[used] = 0xDD;
            used += 8 - used % 8;
        }

        var wrapped: [128]u8 = @splat(0);
        const sealed = wpa2.wrap(ptk.kek, data[0..used], &wrapped).?;

        self.replay += 1;
        var key: [KEY_FRAME_MAX]u8 = @splat(0);
        const len = wpa2.KeyFrame.write(&key, .{
            .pairwise = true,
            .ack = true,
            .mic = true,
            .install = true,
            .secure = true,
            .encrypted = true,
        }, 16, self.replay, self.anonce, sealed).?;
        wpa2.KeyFrame.sign(key[0..len], ptk.kck);
        return wrap(key[0..len], into);
    }
};

fn station() Join {
    return .{ .station = US };
}

fn wanted(join: *Join) void {
    join.wants(wifi.Ssid.of(SSID).?, wifi.Psk.parse(PASSPHRASE).?, @splat(0x5B));
}

test "a protected network is found, authenticated, associated and proved" {
    var ap = FakeAp{ .protected = true };
    var join = station();
    wanted(&join);

    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    // The beacon names the channel to point the radio at.
    const beacon = ap.beacon(&air);
    switch (join.heard(air[0..beacon], .{ .dbm = -50 }, 0, &out)) {
        .tune => |channel| try testing.expectEqual(@as(u8, CHANNEL), channel.number),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(State.tuning, join.state);

    // Tuned, the station asks to authenticate.
    const auth_len = switch (join.tick(0, &out)) {
        .send => |n| n,
        else => return error.TestUnexpectedResult,
    };
    const asked = mlme.Auth.parse(out[0..auth_len]).?;
    try testing.expectEqual(mlme.AuthAlgorithm.open_system, asked.algorithm);
    try testing.expectEqual(@as(u16, 1), asked.sequence);
    try testing.expectEqualSlices(u8, &AP, &ieee80211.Header.parse(out[0..auth_len]).?.addr1);

    // Answered, it asks to associate, offering its name, rates and element.
    const ok = FakeAp.authOk(&air);
    const assoc_len = switch (join.heard(air[0..ok], .{}, 100, &out)) {
        .send => |n| n,
        else => return error.TestUnexpectedResult,
    };
    const request = mlme.AssocRequest.parse(out[0..assoc_len]).?;
    try testing.expectEqualStrings(SSID, ieee80211.element(request.elements, .ssid).?);
    try testing.expect(ieee80211.element(request.elements, .supported_rates) != null);
    const offered = ieee80211.element(request.elements, .rsn).?;
    try testing.expectEqualSlices(u8, &ieee80211.Rsn.psk_ccmp, offered);

    // Granted, it waits for the access point to open the key exchange.
    const granted = FakeAp.assocOk(7, &air);
    try testing.expectEqual(Action.none, join.heard(air[0..granted], .{}, 200, &out));
    try testing.expectEqual(State.handshaking, join.state);
    try testing.expectEqual(@as(u14, 7), join.aid);

    // The first key frame is answered with the second, as EAPOL.
    const one = ap.messageOne(&air);
    const two_len = switch (join.heard(air[0..one], .{}, 300, &out)) {
        .send => |n| n,
        else => return error.TestUnexpectedResult,
    };
    const two = eapolOf(out[0..two_len]) orelse return error.TestUnexpectedResult;
    const parsed_two = wpa2.KeyFrame.parse(two).?;
    try testing.expect(parsed_two.info.mic and parsed_two.info.pairwise);
    try testing.expect(ieee80211.Header.parse(out[0..two_len]).?.control.to_ds);

    // The third is answered with the fourth, and only then are there keys.
    const three = ap.messageThree(join.snonce, &air);
    const four_len = switch (join.heard(air[0..three], .{}, 400, &out)) {
        .send => |n| n,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(eapolOf(out[0..four_len]) != null);

    // The join finishes on the look after the last frame has gone.
    switch (join.tick(500, &out)) {
        .joined => |done| {
            try testing.expectEqualSlices(u8, &AP, &done.bssid);
            try testing.expectEqual(@as(u14, 7), done.aid);
            const earned = done.keys orelse return error.TestUnexpectedResult;
            try testing.expectEqualSlices(u8, &ap.gtk.key, &earned.gtk.key);

            // The pairwise key is the one both sides derive.
            const pmk = wpa2.derive(PASSPHRASE, SSID);
            const ptk = wpa2.ptkOf(pmk, AP, US, ap.anonce, join.snonce);
            try testing.expectEqualSlices(u8, &ptk.tk, &earned.tk);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(State.joined, join.state);
}

test "an open network is joined the moment it grants the association" {
    var ap = FakeAp{ .protected = false };
    var join = station();
    join.wants(wifi.Ssid.of(SSID).?, .none, @splat(0));

    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    const beacon = ap.beacon(&air);
    _ = join.heard(air[0..beacon], .{}, 0, &out);
    _ = join.tick(0, &out);
    const ok = FakeAp.authOk(&air);
    const assoc_len = switch (join.heard(air[0..ok], .{}, 100, &out)) {
        .send => |n| n,
        else => return error.TestUnexpectedResult,
    };
    // Nothing is offered where there is nothing to protect.
    const request = mlme.AssocRequest.parse(out[0..assoc_len]).?;
    try testing.expectEqual(@as(?[]const u8, null), ieee80211.element(request.elements, .rsn));

    const granted = FakeAp.assocOk(3, &air);
    switch (join.heard(air[0..granted], .{}, 200, &out)) {
        .joined => |done| {
            try testing.expectEqual(@as(u14, 3), done.aid);
            try testing.expectEqual(@as(?wpa2.Handshake.Keys, null), done.keys);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a network this system cannot join is refused before anything is sent" {
    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    // Protected, but no key configured.
    var ap = FakeAp{ .protected = true };
    var join = station();
    join.wants(wifi.Ssid.of(SSID).?, .none, @splat(0));
    const beacon = ap.beacon(&air);
    try testing.expectEqual(Action{ .failed = .no_key }, join.heard(air[0..beacon], .{}, 0, &out));

    // The old cipher: named, and not joined.
    var wep = station();
    wanted(&wep);
    var elements: [32]u8 = @splat(0);
    const named = ieee80211.writeElement(&elements, .ssid, SSID).?;
    const head = ieee80211.Header{
        .control = ieee80211.FrameControl.management(.beacon),
        .addr1 = @splat(0xFF),
        .addr2 = AP,
        .addr3 = AP,
    };
    const wrote = head.write(&air).?;
    std.mem.writeInt(u64, air[wrote..][0..8], 0, .little);
    std.mem.writeInt(u16, air[wrote + 8 ..][0..2], 100, .little);
    std.mem.writeInt(u16, air[wrote + 10 ..][0..2], @bitCast(ieee80211.Beacon.Capability{ .ess = true, .privacy = true }), .little);
    @memcpy(air[wrote + 12 ..][0..named], elements[0..named]);
    try testing.expectEqual(Action{ .failed = .unsupported }, wep.heard(air[0 .. wrote + 12 + named], .{}, 0, &out));
}

test "a refusal ends the join, and so does silence after three tries" {
    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    // Refused outright.
    var ap = FakeAp{ .protected = true };
    var join = station();
    wanted(&join);
    _ = join.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = join.tick(0, &out);
    _ = join.heard(air[0..FakeAp.authOk(&air)], .{}, 100, &out);
    const refused = FakeAp.refuse(&air);
    try testing.expectEqual(Action{ .failed = .refused }, join.heard(air[0..refused], .{}, 200, &out));

    // Silence: the request goes again, then again, then it gives up.
    var quiet = station();
    wanted(&quiet);
    _ = quiet.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = quiet.tick(0, &out);
    try testing.expectEqual(State.authenticating, quiet.state);

    // Before the deadline nothing happens.
    try testing.expectEqual(Action.none, quiet.tick(REPLY_MICROS - 1, &out));

    // Past it the request is sent again, twice, and the third look gives up.
    var now: u64 = REPLY_MICROS;
    switch (quiet.tick(now, &out)) {
        .send => {},
        else => return error.TestUnexpectedResult,
    }
    now += REPLY_MICROS;
    switch (quiet.tick(now, &out)) {
        .send => {},
        else => return error.TestUnexpectedResult,
    }
    now += REPLY_MICROS;
    try testing.expectEqual(Action{ .failed = .timed_out }, quiet.tick(now, &out));
}

test "the wrong key is told apart from a network that stopped answering" {
    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    var ap = FakeAp{ .protected = true };
    var join = station();
    // The right words for a different network: the master key differs, so
    // the third message's code will not check out.
    join.wants(wifi.Ssid.of(SSID).?, wifi.Psk.parse("a different secret").?, @splat(0x5B));

    _ = join.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = join.tick(0, &out);
    _ = join.heard(air[0..FakeAp.authOk(&air)], .{}, 100, &out);
    _ = join.heard(air[0..FakeAp.assocOk(7, &air)], .{}, 200, &out);

    // The first message is answered whatever the key is; the third is where
    // a wrong one is found out, because it is the first the access point
    // signs.
    _ = join.heard(air[0..ap.messageOne(&air)], .{}, 300, &out);
    const three = ap.messageThree(join.snonce, &air);
    try testing.expectEqual(Action{ .failed = .bad_key }, join.heard(air[0..three], .{}, 400, &out));
}

test "frames from another cell on the channel are not mistaken for answers" {
    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    var ap = FakeAp{ .protected = true };
    var join = station();
    wanted(&join);
    _ = join.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = join.tick(0, &out);

    // Another access point's answer, addressed to somebody else.
    const OTHER = mac.Address{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    const elsewhere = ieee80211.Header{ .addr1 = US, .addr2 = OTHER, .addr3 = OTHER };
    const len = mlme.Auth.write(elsewhere, .{ .sequence = 2 }, &air).?;
    try testing.expectEqual(Action.none, join.heard(air[0..len], .{}, 100, &out));
    try testing.expectEqual(State.authenticating, join.state);

    // The station's own request, heard back off the air, is not an answer.
    const own = mlme.Auth.write(.{ .addr1 = AP, .addr2 = US, .addr3 = AP }, .{ .sequence = 1 }, &air).?;
    try testing.expectEqual(Action.none, join.heard(air[0..own], .{}, 100, &out));
    try testing.expectEqual(State.authenticating, join.state);
}
