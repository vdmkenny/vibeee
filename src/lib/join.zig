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
const eth = @import("eth.zig");
const ieee80211 = @import("ieee80211.zig");
const mac = @import("mac.zig");
const mlme = @import("mlme.zig");
const wifi = @import("wifi.zig");
const wpa2 = @import("wpa2.zig");

/// How long an answer is waited for before the step is tried again.
pub const REPLY_MICROS: u64 = 300_000;

/// How long a joined station goes without hearing its access point before
/// it takes the connection for gone.
///
/// An access point beacons about ten times a second, and a station hears
/// its own traffic besides. Silence this long is not a lost frame or two:
/// it is an access point that has been switched off, moved out of earshot,
/// or rebooted without saying goodbye. Waiting it out is what stops an
/// interface standing connected with nothing on the other end.
pub const SILENCE_MICROS: u64 = 6_000_000;

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
    /// A key is configured and the network offering that name has no
    /// protection at all. A station that joined it anyway would put the
    /// traffic somebody meant to protect into the clear.
    unprotected,
    /// The radio could not be pointed at the channel it was heard on.
    untuned,
    /// It was joined, and the access point sent a farewell.
    disconnected,
    /// It was joined, and no frame was heard before the silence deadline.
    silence,
    /// The access point refused.
    refused,
    /// It stopped answering.
    timed_out,
    /// The key exchange failed: the access point opened it and never
    /// finished, which is what a secret it does not share looks like.
    bad_key,
    /// It answered, and this station could not make that answer check
    /// out. Told apart from the one above because the fault is here.
    unverified,
    /// The frame could not be built, which trying again would not change.
    unsent,

    pub fn spell(self: Failure) []const u8 {
        return switch (self) {
            .unsupported => "its protection is not one this system speaks",
            .no_key => "it needs a key and none is set",
            .unprotected => "it is open and a password is set for it",
            .untuned => "the radio could not be tuned to its channel",
            .disconnected => "the access point ended it",
            .silence => "the access point went silent",
            .refused => "the access point refused",
            .timed_out => "it stopped answering",
            .bad_key => "the key was not accepted",
            .unverified => "the access point answered the key exchange and this station could not check its answer",
            .unsent => "the request could not be built",
        };
    }
};

/// What the station should do about the pass just taken.
pub const Action = union(enum) {
    /// Nothing to do.
    none,
    /// Send this many bytes of the buffer that was passed in, as they are.
    send: usize,
    /// Send this many bytes of the buffer as traffic to the cell: an
    /// Ethernet frame, dressed and sealed the way every frame after the
    /// join is.
    traffic: usize,
    /// Point the radio here first: the network was heard on this channel.
    tune: wifi.Channel,
    /// Joined. What to install, and what the cell is.
    joined: Joined,
    /// Give up, for this reason.
    failed: Failure,
};

/// The end of a join: the cell, and the identifier it gave. The keys, where
/// the network has any, are the join's to keep, since the cell renews them
/// for as long as the station stays.
pub const Joined = struct {
    bssid: mac.Address,
    aid: u14,
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
    /// Where in the world the radio is, which decides the channels it may
    /// be pointed at. A network heard on a channel outside the plan is one
    /// this station does not answer: hearing a frame is not permission to
    /// transmit one.
    plan: wifi.Regulatory = .conservative,
    /// This station's nonce for the key exchange. Drawn by the caller,
    /// because a value cannot draw a random number and stay one.
    snonce: wpa2.Nonce = @splat(0),

    state: State = .idle,
    failure: Failure = .timed_out,
    /// Where it was when it gave up. A join that ran out of attempts says
    /// only that nothing answered; which step nothing answered at is the
    /// thing worth knowing.
    failed_in: State = .idle,
    /// The network being joined, once one has been heard, and the
    /// security element it advertised.
    bss: ?mlme.Bss = null,
    ap_rsn: ieee80211.Rsn.Transcript = .{},
    held: ?u8 = null,
    farewell_reason: ?mlme.Reason = null,
    farewell_destination: mac.Address = @splat(0),
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
    earned: ?wpa2.Keys = null,
    /// Keys staged for this response only. Enqueue permits local use, not
    /// an assumption that the AP has received M4 or switched its keys.
    pending: ?wpa2.Keys = null,
    response: ?wpa2.Handshake.Response = null,
    /// The last frame of the exchange has been handed over, so the join is
    /// finished on the next look.
    settling: bool = false,

    sequence: u12 = 0,

    /// Ask to join a network. `snonce` is this station's nonce for the key
    /// exchange, which the caller draws.
    pub fn wants(self: *Join, ssid: wifi.Ssid, psk: wifi.Psk, plan: wifi.Regulatory, snonce: wpa2.Nonce) void {
        self.want = ssid;
        self.psk = psk;
        self.plan = plan;
        self.snonce = snonce;
        self.state = if (ssid.len == 0) .idle else .seeking;
        self.bss = null;
        self.handshake = null;
        self.earned = null;
        self.pending = null;
        self.response = null;
        self.farewell_reason = null;
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
    pub fn keys(self: *const Join) ?wpa2.Keys {
        return self.earned;
    }

    pub fn pairwiseHeard(self: *Join, generation: u32) void {
        if (self.handshake) |*shake| {
            if (generation == shake.pairwise_at) shake.confirmed = generation;
        }
    }

    /// Protection for the current reply, not the current association.
    pub fn responseKey(self: *const Join) ?wpa2.Key {
        const response = self.response orelse return null;
        const shake = self.handshake orelse return null;
        if (response.kind == .m4 and shake.confirmed != response.generation) return shake.was;
        return if (self.earned) |installed| installed.pairwise else null;
    }

    /// The identified reply was enqueued, not necessarily transmitted or
    /// ACKed. Retain its original protection for retries until peer proof.
    pub fn sent(self: *Join, response: wpa2.Handshake.Response, enqueued: bool) void {
        const expected = self.response orelse return;
        if (!std.meta.eql(expected, response)) return;
        self.response = null;
        if (!enqueued) return;
        const ready = self.pending orelse return;
        if (response.kind == .m2 or response.generation != ready.pairwise.generation) return;
        self.pending = null;
        const first_keys = self.earned == null;
        self.earned = ready;
        // The exchange that earns the first keys is the join, and it ends
        // on this frame.
        if (first_keys and self.state == .handshaking) self.settling = true;
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
            .joined => self.sawJoined(frame, now),
            else => .none,
        };
    }

    /// A frame heard while joined. Two things matter after a join: that
    /// the access point is still there, and that it has not ended the
    /// association. Both are answered by the frames it sends, whatever
    /// they carry.
    fn sawJoined(self: *Join, frame: []const u8, now: u64) Action {
        if (!self.fromCell(frame)) return .none;
        if (self.farewell(frame)) |ended| return ended;
        self.deadline = now + SILENCE_MICROS;
        return .none;
    }

    /// Time passed: send the step in hand, or try it again, or give up.
    pub fn tick(self: *Join, now: u64, into: []u8) Action {
        // The last frame of the exchange has gone; the join is finished.
        if (self.settling) {
            self.settling = false;
            self.state = .joined;
            self.deadline = now + SILENCE_MICROS;
            return .{ .joined = .{ .bssid = self.bssid(), .aid = self.aid } };
        }

        switch (self.state) {
            // The radio has been pointed at the channel; ask to authenticate.
            .tuning => {
                if (!self.channelAllowed()) return self.give(.untuned);
                return self.sendAuth(now, into);
            },
            .authenticating, .associating, .handshaking => {
                if (now < self.deadline) return .none;
                return self.retry(now, into);
            },
            // Joined, and nothing has been heard from the cell for as long
            // as anybody would wait.
            .joined => {
                if (now < self.deadline) return .none;
                return self.give(.silence);
            },
            else => return .none,
        }
    }

    /// The radio was pointed where the last pass asked, or could not be.
    ///
    /// A station that could not tune has heard nothing on that channel and
    /// must not carry on as though it had: the frames it would send next
    /// would go out wherever the radio still happens to be.
    pub fn tuned(self: *Join, ok: bool) Action {
        if (self.state != .tuning) return .none;
        if (ok and self.channelAllowed()) return .none;
        return self.give(.untuned);
    }

    pub fn channelAllowed(self: *const Join) bool {
        const found = self.bss orelse return false;
        return found.channel != 0 and self.plan.allows(found.channel) and
            (self.held == null or self.held.? == found.channel);
    }

    // -----------------------------------------------------------------------
    // Finding it
    // -----------------------------------------------------------------------

    fn sawBeacon(self: *Join, frame: []const u8, signal: wifi.Signal) Action {
        var advertised = ieee80211.Rsn.Transcript{};
        const seen = mlme.Bss.fromBeacon(frame, signal, &advertised) orelse return .none;
        if (!seen.ssid.eql(self.want)) return .none;

        // What this system cannot join is said now rather than after three
        // exchanges that were never going to work.
        if (!seen.security.joinable()) return self.give(.unsupported);
        if (seen.security != .open and self.psk == .none) return self.give(.no_key);
        // And what it must not join: a password is set for this name, so
        // an open network answering to it is not the network somebody
        // meant. Whether the traffic will be protected is the person's
        // decision, taken when they set the password, not the access
        // point's to take again.
        if (seen.security == .open and self.psk != .none) return self.give(.unprotected);

        // A network heard on a channel the plan does not allow is one this
        // station may not transmit on, and one that named no channel is
        // one there is nowhere to point the radio at. Hearing a frame is
        // not permission to answer it.
        if (seen.channel == 0 or !self.plan.allows(seen.channel) or
            (self.held != null and self.held.? != seen.channel)) return .none;

        self.bss = seen;
        // What the network said about its own protection, kept exactly as
        // it said it: the key exchange's third message repeats it, and the
        // two being the same is what says nobody talked the network down
        // in between.
        self.ap_rsn = advertised;
        self.state = .tuning;
        self.left = TRIES;
        return .{ .tune = .{ .number = seen.channel } };
    }

    // -----------------------------------------------------------------------
    // Authenticating
    // -----------------------------------------------------------------------

    fn sendAuth(self: *Join, now: u64, into: []u8) Action {
        const len = mlme.Auth.write(self.toAp(), .{ .sequence = 1 }, into) orelse return self.give(.unsent);
        self.state = .authenticating;
        self.deadline = now + REPLY_MICROS;
        return .{ .send = len };
    }

    fn sawAuth(self: *Join, frame: []const u8, now: u64, into: []u8) Action {
        if (self.farewell(frame)) |ended| return ended;
        const answer = mlme.Auth.parse(frame) orelse return .none;
        if (!self.answeredUs(frame)) return .none;
        // The station's own request, heard back, is not an answer to it.
        if (answer.sequence != 2) return .none;
        // And an answer in a scheme this station did not ask for is not an
        // answer to what it asked.
        if (answer.algorithm != .open_system) return .none;
        if (!answer.status.ok()) return self.give(.refused);
        self.left = TRIES;
        return self.sendAssoc(now, into);
    }

    // -----------------------------------------------------------------------
    // Associating
    // -----------------------------------------------------------------------

    fn sendAssoc(self: *Join, now: u64, into: []u8) Action {
        const protected = (self.bss orelse return self.give(.unsent)).security != .open;
        const rsn: []const u8 = if (protected) &OFFERED_RSN else &.{};
        const len = mlme.AssocRequest.write(self.toAp(), .{}, self.want, rsn, into) orelse
            return self.give(.unsent);
        self.state = .associating;
        self.deadline = now + REPLY_MICROS;
        return .{ .send = len };
    }

    fn sawAssoc(self: *Join, frame: []const u8, now: u64, into: []u8) Action {
        _ = into;
        if (self.farewell(frame)) |ended| return ended;
        const answer = mlme.AssocResponse.parse(frame) orelse return .none;
        if (!self.answeredUs(frame)) return .none;
        if (!answer.status.ok()) return self.give(.refused);

        self.aid = @truncate(answer.aid);
        const found = self.bss orelse return .none;

        // An open network is joined the moment it says so; a protected one
        // has still to prove the key. An open one where a password is set
        // is not joined at all, which the beacon already said and this
        // says again: what was heard and what was associated with are two
        // separate frames, and only one of them was checked.
        if (found.security == .open) {
            if (self.psk != .none) return self.give(.unprotected);
            self.state = .joined;
            self.deadline = now + SILENCE_MICROS;
            return .{ .joined = .{ .bssid = found.bssid, .aid = self.aid } };
        }

        const pmk = wpa2.pmkOf(self.psk, self.want) orelse return self.give(.no_key);
        self.handshake = .{
            .pmk = pmk,
            .station = self.station,
            .ap = found.bssid,
            .snonce = self.snonce,
            .seed = self.snonce,
            .rsn = &OFFERED_RSN_ELEMENT,
            .ap_rsn = self.ap_rsn,
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
        const head = ieee80211.Header.parse(frame) orelse return .none;
        if (head.control.protected or ieee80211.Topology.of(head.control) != .from_ap) return .none;
        const payload = eapolOf(frame) orelse return .none;
        if (!self.answeredUs(frame)) return .none;
        const key = wpa2.KeyFrame.parse(payload) orelse return .none;
        if (!key.info.pairwise) return .none;
        // A pointer into the field, not to a copy of it: the exchange's
        // state, the transient key above all, has to outlive this pass.
        if (self.handshake == null) return .none;
        const shake = &self.handshake.?;
        self.response = null;
        self.pending = null;

        return switch (shake.answer(payload, &self.scratch)) {
            .ignored => .none,
            .refused => self.give(.bad_key),
            .reply => |len| blk: {
                const wrapped = self.wrapEapol(self.scratch[0..len], into) orelse break :blk .none;
                // The exchange finishes on the frame this station sends
                // last, and the keys go in once it has gone: `sent` says
                // when. Latched once. The exchange's last frame can be
                // asked for again, and answering it again is not a second
                // joining.
                self.response = shake.response;
                if (shake.response.?.kind == .m4) {
                    self.pending = shake.keys();
                } else if (shake.response.?.kind == .m2) {
                    self.deadline = now + REPLY_MICROS;
                    self.left = TRIES;
                }
                break :blk .{ .send = wrapped };
            },
        };
    }

    /// An authentication payload that arrived as traffic after the join:
    /// the cell handing out its next group key. Answered as traffic too,
    /// since everything after the join is sealed, and the keys are kept
    /// up to date for whoever asks for them.
    pub fn carried(self: *Join, payload: []const u8, into: []u8) Action {
        if (self.state != .joined) return .none;
        if (self.handshake == null) return .none;
        const shake = &self.handshake.?;
        self.response = null;
        self.pending = null;
        const key = wpa2.KeyFrame.parse(payload) orelse return .none;
        if (!key.info.pairwise and (self.earned == null or
            self.earned.?.pairwise.generation != shake.pairwise_at)) return .none;

        return switch (shake.answer(payload, &self.scratch)) {
            .ignored, .refused => .none,
            .reply => |len| blk: {
                const response = shake.response.?;
                // A lost initial M4 is retried in the clear even after
                // local carrier-up. A rekey M4 retains the old TX key.
                if (response.kind == .m4 and shake.was == null and shake.confirmed != response.generation) {
                    const written = self.wrapEapol(self.scratch[0..len], into) orelse break :blk .none;
                    self.response = response;
                    self.pending = shake.keys();
                    break :blk .{ .send = written };
                }
                const written = eth.write(into, self.bssid(), self.station, eth.EtherType.eapol, self.scratch[0..len]) orelse break :blk .none;
                // Taken up once the answer has gone, not before: a key
                // renewal is answered under the key being renewed.
                self.response = response;
                if (response.kind == .m4 or (response.kind == .group2 and
                    self.earned != null and self.earned.?.pairwise.generation == response.generation))
                    self.pending = shake.keys();
                break :blk .{ .traffic = written };
            },
        };
    }

    // -----------------------------------------------------------------------
    // Going wrong
    // -----------------------------------------------------------------------

    /// The access point ending it, whichever way it said so.
    fn farewell(self: *Join, frame: []const u8) ?Action {
        const ended = mlme.Farewell.parse(frame) orelse return null;
        if (!self.fromCell(frame)) return null;
        const head = ieee80211.Header.parse(frame).?;
        if (!mac.eql(head.addr1, self.station) and !mac.eql(head.addr1, mac.broadcast)) return null;
        self.farewell_reason = ended.reason;
        self.farewell_destination = head.addr1;
        return self.give(if (self.state == .joined) .disconnected else .refused);
    }

    /// Try the step in hand again, or give up when there are no tries left.
    fn retry(self: *Join, now: u64, into: []u8) Action {
        self.left -|= 1;
        if (self.left == 0) return self.give(self.unanswered());

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

    /// What it means that nothing more came. An exchange the access point
    /// opened and never finished is a key it did not accept: its third
    /// message is the first thing it signs, and a station whose secret is
    /// wrong cannot verify it, nor sign the second message so that the
    /// access point would send it.
    fn unanswered(self: *const Join) Failure {
        if (self.state != .handshaking) return .timed_out;
        const shake = self.handshake orelse return .timed_out;
        if (!shake.begun()) return .timed_out;
        // An exchange the access point opened and never answered is a
        // secret it does not share. One it answered and this station
        // could not check is a fault on this side, and saying the first
        // where the second is true sends somebody to retype a password
        // that was right all along.
        return if (shake.answered()) .unverified else .bad_key;
    }

    fn give(self: *Join, why: Failure) Action {
        self.failed_in = self.state;
        self.state = .failed;
        self.failure = why;
        // A join that has failed is not about to finish, however far it
        // had got: the last frame of an exchange may have gone out just
        // before the cell said goodbye.
        self.settling = false;
        self.response = null;
        self.pending = null;
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

    /// Whether a frame was spoken by the cell being joined. A radio hears
    /// every cell on the channel, and an access point's own frames are the
    /// only ones that say anything about the join.
    fn fromCell(self: *const Join, frame: []const u8) bool {
        const found = self.bss orelse return false;
        const head = ieee80211.Header.parse(frame) orelse return false;
        return mac.eql(head.bssid(), found.bssid) and mac.eql(head.addr2, found.bssid);
    }

    /// Whether it is that cell answering this station by name.
    ///
    /// An exchange between two stations is addressed to one of them. A
    /// frame sent to the room says nothing about which station's request
    /// it answers, so one is not an answer to this station's.
    fn answeredUs(self: *const Join, frame: []const u8) bool {
        if (!self.fromCell(frame)) return false;
        const head = ieee80211.Header.parse(frame) orelse return false;
        return mac.eql(head.addr1, self.station);
    }

    /// Wrap a key frame as a data frame to the access point.
    fn wrapEapol(self: *Join, payload: []const u8, into: []u8) ?usize {
        var head = self.toAp();
        head.control = ieee80211.FrameControl.data(.data);
        head.control.to_ds = true;

        const wrote = head.write(into) orelse return null;
        const snap = ieee80211.Snap.write(into[wrote..], eth.EtherType.eapol) orelse return null;
        if (into.len < wrote + snap + payload.len) return null;
        @memcpy(into[wrote + snap ..][0..payload.len], payload);
        return wrote + snap + payload.len;
    }
};

/// The authentication payload of a data frame, or null when the frame
/// carries something else. What the supplicant reads and the stack never
/// sees.
pub fn eapolOf(frame: []const u8) ?[]const u8 {
    const carried = ieee80211.carriedBy(frame) orelse return null;
    if (carried.ethertype != eth.EtherType.eapol) return null;
    return carried.payload;
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
    channel: u8 = CHANNEL,
    anonce: wpa2.Nonce = @splat(0xA1),
    replay: u64 = 1,
    gtk: wpa2.Gtk = .{ .index = 1, .key = @splat(0x5C) },

    fn beacon(self: FakeAp, into: []u8) usize {
        var elements: [96]u8 = @splat(0);
        var at: usize = 0;
        at += ieee80211.writeElement(elements[at..], .ssid, SSID).?;
        at += ieee80211.writeElement(elements[at..], .ds_parameter, &.{self.channel}).?;
        if (self.protected) {
            at += ieee80211.writeElement(elements[at..], .rsn, &ieee80211.Rsn.psk_ccmp).?;
        }

        const head = ieee80211.Header{
            .control = ieee80211.FrameControl.management(.beacon),
            .addr1 = mac.broadcast,
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

    fn goodbye(into: []u8) usize {
        return mlme.Farewell.write(fromAp(), mlme.Farewell.deauthentication(.leaving), into).?;
    }

    /// Wrap a key frame as the access point sends one.
    fn wrap(payload: []const u8, into: []u8) usize {
        var head = fromAp();
        head.control = ieee80211.FrameControl.data(.data);
        head.control.from_ds = true;
        const wrote = head.write(into).?;
        const snap = ieee80211.Snap.write(into[wrote..], eth.EtherType.eapol).?;
        @memcpy(into[wrote + snap ..][0..payload.len], payload);
        return wrote + snap + payload.len;
    }

    fn messageOne(self: FakeAp, into: []u8) usize {
        var key: [KEY_FRAME_MAX]u8 = @splat(0);
        const len = wpa2.KeyFrame.write(&key, .{
            .info = .{ .pairwise = true, .ack = true },
            .key_length = 16,
            .replay = self.replay,
            .nonce = self.anonce,
        }).?;
        return wrap(key[0..len], into);
    }

    /// The group key handshake's first message, sealed under the pairwise
    /// key, as the key frame alone: after the join it travels as traffic,
    /// which the station undresses before the join sees it.
    fn groupMessage(self: *FakeAp, snonce: wpa2.Nonce, gtk: wpa2.Gtk, into: []u8) usize {
        const pmk = wpa2.derive(PASSPHRASE, SSID);
        const ptk = wpa2.ptkOf(pmk, AP, US, self.anonce, snonce);

        var data: [64]u8 = @splat(0);
        var used = wpa2.writeGtk(&data, gtk).?;
        if (used % 8 != 0) {
            data[used] = 0xDD;
            used += 8 - used % 8;
        }
        var wrapped: [128]u8 = @splat(0);
        const sealed = wpa2.wrap(ptk.kek, data[0..used], &wrapped).?;

        self.replay += 1;
        const len = wpa2.KeyFrame.write(into, .{
            .info = .{
                .ack = true,
                .mic = true,
                .secure = true,
                .encrypted = true,
            },
            .key_length = 16,
            .replay = self.replay,
            .data = sealed,
        }).?;
        wpa2.KeyFrame.sign(into[0..len], ptk.kck);
        return len;
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
            .info = .{
                .pairwise = true,
                .ack = true,
                .mic = true,
                .install = true,
                .secure = true,
                .encrypted = true,
            },
            .key_length = 16,
            .replay = self.replay,
            .nonce = self.anonce,
            .data = sealed,
        }).?;
        wpa2.KeyFrame.sign(key[0..len], ptk.kck);
        return wrap(key[0..len], into);
    }
};

fn station() Join {
    return .{ .station = US };
}

fn wanted(join: *Join) void {
    join.wants(wifi.Ssid.of(SSID).?, wifi.Psk.parse(PASSPHRASE).?, .conservative, @splat(0x5B));
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
    // And not before it has gone: the keys are not the join's to hand
    // over until the frame that proves them is away.
    try testing.expectEqual(@as(?wpa2.Keys, null), join.keys());
    try testing.expectEqual(Action.none, join.tick(450, &out));
    join.sent(join.response.?, true);

    // The join finishes on the look after the last frame has gone.
    switch (join.tick(500, &out)) {
        .joined => |done| {
            try testing.expectEqualSlices(u8, &AP, &done.bssid);
            try testing.expectEqual(@as(u14, 7), done.aid);
            const earned = join.keys() orelse return error.TestUnexpectedResult;
            try testing.expectEqualSlices(u8, &ap.gtk.key, &earned.groupKey(ap.gtk.index).?.bytes);

            // The pairwise key is the one both sides derive.
            const pmk = wpa2.derive(PASSPHRASE, SSID);
            const ptk = wpa2.ptkOf(pmk, AP, US, ap.anonce, join.snonce);
            try testing.expectEqualSlices(u8, &ptk.tk, &earned.pairwise.bytes);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(State.joined, join.state);
}

test "an open network is joined the moment it grants the association" {
    var ap = FakeAp{ .protected = false };
    var join = station();
    join.wants(wifi.Ssid.of(SSID).?, .none, .conservative, @splat(0));

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
            try testing.expectEqual(@as(?wpa2.Keys, null), join.keys());
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
    join.wants(wifi.Ssid.of(SSID).?, .none, .conservative, @splat(0));
    const beacon = ap.beacon(&air);
    try testing.expectEqual(Action{ .failed = .no_key }, join.heard(air[0..beacon], .{}, 0, &out));

    // The old cipher: named, and not joined.
    var wep = station();
    wanted(&wep);
    var elements: [32]u8 = @splat(0);
    const named = ieee80211.writeElement(&elements, .ssid, SSID).?;
    const head = ieee80211.Header{
        .control = ieee80211.FrameControl.management(.beacon),
        .addr1 = mac.broadcast,
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

test "a secret the network does not share is told apart from an answer this station cannot check" {
    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    // The right words for a different network. An access point cannot
    // check this station's second message under a key it does not share,
    // so it sends no third message at all: the exchange it opened and
    // never finished is the whole of what says the secret is wrong.
    var ap = FakeAp{ .protected = true };
    var join = station();
    join.wants(wifi.Ssid.of(SSID).?, wifi.Psk.parse("a different secret").?, .conservative, @splat(0x5B));

    _ = join.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = join.tick(0, &out);
    _ = join.heard(air[0..FakeAp.authOk(&air)], .{}, 100, &out);
    _ = join.heard(air[0..FakeAp.assocOk(7, &air)], .{}, 200, &out);
    _ = join.heard(air[0..ap.messageOne(&air)], .{}, 300, &out);
    try testing.expectEqual(State.handshaking, join.state);

    try testing.expectEqual(Action{ .failed = .bad_key }, waitOut(&join, &out));

    // A third message that arrives and does not check out is a different
    // answer: the network did reply, and this station could not make its
    // reply hold. Saying the first where this is true sends somebody to
    // retype a password that was right all along.
    var second = FakeAp{ .protected = true };
    var refusing = station();
    refusing.wants(wifi.Ssid.of(SSID).?, wifi.Psk.parse("a different secret").?, .conservative, @splat(0x5B));
    _ = refusing.heard(air[0..second.beacon(&air)], .{}, 0, &out);
    _ = refusing.tick(0, &out);
    _ = refusing.heard(air[0..FakeAp.authOk(&air)], .{}, 100, &out);
    _ = refusing.heard(air[0..FakeAp.assocOk(7, &air)], .{}, 200, &out);
    _ = refusing.heard(air[0..second.messageOne(&air)], .{}, 300, &out);

    const three = second.messageThree(refusing.snonce, &air);
    try testing.expectEqual(Action.none, refusing.heard(air[0..three], .{}, 400, &out));
    try testing.expectEqual(Action{ .failed = .unverified }, waitOut(&refusing, &out));
}

/// Run the clock until the join gives up, and say how.
fn waitOut(join: *Join, out: []u8) Action {
    var waits: usize = 0;
    while (waits < 10) : (waits += 1) {
        const what = join.tick(join.deadline, out);
        if (what != .none) return what;
    }
    return .none;
}

test "a cell that says goodbye as the exchange ends leaves nothing to settle" {
    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    var ap = FakeAp{ .protected = true };
    var join = station();
    wanted(&join);
    _ = join.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = join.tick(0, &out);
    _ = join.heard(air[0..FakeAp.authOk(&air)], .{}, 100, &out);
    _ = join.heard(air[0..FakeAp.assocOk(7, &air)], .{}, 200, &out);
    _ = join.heard(air[0..ap.messageOne(&air)], .{}, 300, &out);
    _ = join.heard(air[0..ap.messageThree(join.snonce, &air)], .{}, 400, &out);
    join.sent(join.response.?, true);
    try testing.expect(join.settling);

    // Between the last frame going out and the next look, the cell ends it.
    try testing.expectEqual(Action{ .failed = .refused }, join.heard(air[0..FakeAp.goodbye(&air)], .{}, 450, &out));
    try testing.expectEqual(Action.none, join.tick(500, &out));
    try testing.expectEqual(State.failed, join.state);
}

test "the cell's next group key is taken and answered as traffic" {
    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    var ap = FakeAp{ .protected = true };
    var join = station();
    wanted(&join);
    _ = join.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = join.tick(0, &out);
    _ = join.heard(air[0..FakeAp.authOk(&air)], .{}, 100, &out);
    _ = join.heard(air[0..FakeAp.assocOk(7, &air)], .{}, 200, &out);
    _ = join.heard(air[0..ap.messageOne(&air)], .{}, 300, &out);
    _ = join.heard(air[0..ap.messageThree(join.snonce, &air)], .{}, 400, &out);
    join.sent(join.response.?, true);
    try testing.expect(join.tick(500, &out) == .joined);
    const before = join.keys().?;

    // Before the join, or from a cell that is not this one, nothing.
    const renewed = wpa2.Gtk{ .index = 2, .key = .{ 0xC0, 0xFF, 0xEE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };
    const len = ap.groupMessage(join.snonce, renewed, &air);
    const traffic = switch (join.carried(air[0..len], &out)) {
        .traffic => |n| n,
        else => return error.TestUnexpectedResult,
    };
    // An Ethernet frame to the cell, from this station, carrying the answer.
    try testing.expectEqualSlices(u8, &AP, out[0..6]);
    try testing.expectEqualSlices(u8, &US, out[6..12]);
    try testing.expectEqual(eth.EtherType.eapol, eth.carriedBy(&out));
    try testing.expect(wpa2.KeyFrame.parse(out[eth.HEADER..traffic]) != null);

    // The renewed key is not in hand until that answer has gone: it is
    // sealed under the keys the cell still holds.
    try testing.expectEqual(@as(?wpa2.Key, null), join.keys().?.groupKey(2));
    join.sent(join.response.?, true);

    const after = join.keys().?;
    try testing.expectEqualSlices(u8, &before.pairwise.bytes, &after.pairwise.bytes);
    try testing.expectEqualSlices(u8, &before.groupKey(1).?.bytes, &after.groupKey(1).?.bytes);
    try testing.expectEqualSlices(u8, &renewed.key, &after.groupKey(2).?.bytes);
}

test "a password set for a name means that name is not joined without one" {
    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    // An open network answering to the name a password is set for. It may
    // be the same network with its protection switched off, or somebody
    // else's radio using the name; either way the traffic somebody meant
    // to protect would go out in the clear.
    var open = FakeAp{ .protected = false };
    var join = station();
    wanted(&join);
    try testing.expectEqual(
        Action{ .failed = .unprotected },
        join.heard(air[0..open.beacon(&air)], .{ .dbm = -40 }, 0, &out),
    );

    // And again where the beacon said one thing and the association
    // another: what was heard and what was associated with are two
    // separate frames.
    var ap = FakeAp{ .protected = true };
    var second = station();
    wanted(&second);
    _ = second.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = second.tick(0, &out);
    _ = second.heard(air[0..FakeAp.authOk(&air)], .{}, 100, &out);
    second.bss.?.security = .open;
    try testing.expectEqual(
        Action{ .failed = .unprotected },
        second.heard(air[0..FakeAp.assocOk(7, &air)], .{}, 200, &out),
    );
}

test "a joined station notices being put out, and being left in silence" {
    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    var ap = FakeAp{ .protected = true };
    var join = station();
    wanted(&join);
    _ = join.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = join.tick(0, &out);
    _ = join.heard(air[0..FakeAp.authOk(&air)], .{}, 100, &out);
    _ = join.heard(air[0..FakeAp.assocOk(7, &air)], .{}, 200, &out);
    _ = join.heard(air[0..ap.messageOne(&air)], .{}, 300, &out);
    _ = join.heard(air[0..ap.messageThree(join.snonce, &air)], .{}, 400, &out);
    join.sent(join.response.?, true);
    try testing.expect(join.tick(500, &out) == .joined);

    // The cell says goodbye. A station that ignored this would stand
    // connected to an access point that has forgotten it.
    try testing.expectEqual(
        Action{ .failed = .disconnected },
        join.heard(air[0..FakeAp.goodbye(&air)], .{}, 600, &out),
    );

    // And silence says the same thing more slowly.
    var quiet = station();
    wanted(&quiet);
    _ = quiet.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = quiet.tick(0, &out);
    _ = quiet.heard(air[0..FakeAp.authOk(&air)], .{}, 100, &out);
    _ = quiet.heard(air[0..FakeAp.assocOk(7, &air)], .{}, 200, &out);
    _ = quiet.heard(air[0..ap.messageOne(&air)], .{}, 300, &out);
    _ = quiet.heard(air[0..ap.messageThree(quiet.snonce, &air)], .{}, 400, &out);
    quiet.sent(quiet.response.?, true);
    try testing.expect(quiet.tick(500, &out) == .joined);
    try testing.expectEqual(Action.none, quiet.tick(500 + SILENCE_MICROS - 1, &out));
    // A beacon from the cell is the cell still being there.
    _ = quiet.heard(air[0..ap.beacon(&air)], .{}, 500 + SILENCE_MICROS - 1, &out);
    try testing.expectEqual(Action.none, quiet.tick(500 + SILENCE_MICROS, &out));
    try testing.expectEqual(
        Action{ .failed = .silence },
        quiet.tick(500 + 2 * SILENCE_MICROS, &out),
    );
}

test "a radio that could not be tuned does not carry on as though it had" {
    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    var ap = FakeAp{ .protected = true };
    var join = station();
    wanted(&join);
    try testing.expect(join.heard(air[0..ap.beacon(&air)], .{}, 0, &out) == .tune);
    try testing.expectEqual(Action{ .failed = .untuned }, join.tuned(false));
    // Nothing goes out on whatever channel the radio is still on.
    try testing.expectEqual(Action.none, join.tick(100, &out));
}

test "a network on a channel the plan does not allow is left alone" {
    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    // A network above what the narrowest plan permits transmitting on.
    var ap = FakeAp{ .protected = true, .channel = 13 };
    var join = station();
    join.wants(wifi.Ssid.of(SSID).?, wifi.Psk.parse(PASSPHRASE).?, .conservative, @splat(0x5B));
    try testing.expectEqual(Action.none, join.heard(air[0..ap.beacon(&air)], .{}, 0, &out));
    try testing.expectEqual(State.seeking, join.state);

    // And one whose beacon named no channel at all: there is nowhere to
    // point the radio.
    var unnamed = FakeAp{ .protected = true, .channel = 0 };
    var second = station();
    wanted(&second);
    try testing.expectEqual(Action.none, second.heard(air[0..unnamed.beacon(&air)], .{}, 0, &out));
    try testing.expectEqual(State.seeking, second.state);
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

test "a tick at a deadline that has passed never leaves the deadline where it was" {
    // The station above this asks how long it may wait by looking at the
    // state and the deadline. A tick that acts on a deadline already passed
    // and leaves it there is a wait of nothing, every pass, forever.
    var ap = FakeAp{ .protected = true };
    var join = station();
    wanted(&join);

    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);
    const beacon = ap.beacon(&air);
    _ = join.heard(air[0..beacon], .{ .dbm = -50 }, 0, &out);
    try testing.expectEqual(State.tuning, join.state);

    var now: u64 = 0;
    for (0..TRIES * 4) |_| {
        _ = join.tick(now, &out);
        switch (join.state) {
            // The states that wait on an answer are the ones the deadline is
            // for, and every one of them must be waiting on a later moment.
            .authenticating, .associating, .handshaking => try testing.expect(join.deadline > now),
            // Anything else asks for no wake at all.
            .idle, .seeking, .tuning, .joined, .failed => {},
        }
        now = @max(now + 1, join.deadline);
    }
    try testing.expectEqual(State.failed, join.state);
}

test "a frame that will not fit ends the join instead of stalling it" {
    var ap = FakeAp{ .protected = true };
    var join = station();
    wanted(&join);

    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);
    const beacon = ap.beacon(&air);
    _ = join.heard(air[0..beacon], .{ .dbm = -50 }, 0, &out);
    try testing.expectEqual(State.tuning, join.state);

    // Nowhere to write the request. Trying again would not make room, so the
    // join ends rather than sitting in a state whose deadline nobody moves.
    var cramped: [4]u8 = @splat(0);
    try testing.expectEqual(Failure.unsent, switch (join.tick(0, &cramped)) {
        .failed => |why| why,
        else => return error.TestUnexpectedResult,
    });
    try testing.expectEqual(State.failed, join.state);
}

test "failed M4 enqueue cannot be committed by M2 and initial M4 retries remain plaintext" {
    var ap = FakeAp{ .protected = true };
    var join = station();
    wanted(&join);
    var air: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    _ = join.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = join.tick(0, &out);
    _ = join.heard(air[0..FakeAp.authOk(&air)], .{}, 100, &out);
    _ = join.heard(air[0..FakeAp.assocOk(7, &air)], .{}, 200, &out);
    _ = join.heard(air[0..ap.messageOne(&air)], .{}, 300, &out);
    var third: [512]u8 = undefined;
    const three = ap.messageThree(join.snonce, &third);
    _ = join.heard(third[0..three], .{}, 400, &out);
    const m4 = join.response.?;
    join.sent(m4, false);
    try testing.expect(join.keys() == null);

    ap.replay += 1;
    _ = join.heard(air[0..ap.messageOne(&air)], .{}, 410, &out);
    try testing.expectEqual(.m2, join.response.?.kind);
    join.sent(m4, true); // A stale completion is not this M2's completion.
    try testing.expect(join.keys() == null);
    join.sent(join.response.?, true);
    try testing.expect(join.keys() == null);
    try testing.expect(!join.settling);

    _ = join.heard(third[0..three], .{}, 420, &out);
    try testing.expectEqual(.m4, join.response.?.kind);
    join.sent(join.response.?, true);
    try testing.expect(join.tick(430, &out) == .joined);
    const generation = join.keys().?.pairwise.generation;
    const retry = join.carried(eapolOf(third[0..three]).?, &out);
    try testing.expect(retry == .send);
    try testing.expect(!ieee80211.Header.parse(out[0..retry.send]).?.control.protected);
    try testing.expect(join.responseKey() == null);
    try testing.expectEqual(.m4, join.response.?.kind);
    join.sent(join.response.?, true);
    try testing.expectEqual(generation, join.keys().?.pairwise.generation);
    try testing.expect(!join.settling);
}

test "rekey M4 retries keep the old TX generation until new pairwise proof" {
    var ap = FakeAp{ .protected = true };
    var join = station();
    wanted(&join);
    var air: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    _ = join.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = join.tick(0, &out);
    _ = join.heard(air[0..FakeAp.authOk(&air)], .{}, 100, &out);
    _ = join.heard(air[0..FakeAp.assocOk(7, &air)], .{}, 200, &out);
    _ = join.heard(air[0..ap.messageOne(&air)], .{}, 300, &out);
    _ = join.heard(air[0..ap.messageThree(join.snonce, &air)], .{}, 400, &out);
    join.sent(join.response.?, true);
    _ = join.tick(500, &out);
    const old = join.keys().?.pairwise;
    join.pairwiseHeard(old.generation);

    ap.anonce = @splat(0xA2);
    ap.replay += 1;
    const one = ap.messageOne(&air);
    try testing.expect(join.carried(eapolOf(air[0..one]).?, &out) == .traffic);
    const snonce = wpa2.KeyFrame.parse(out[eth.HEADER..]).?.nonce;
    join.sent(join.response.?, true);
    const three = ap.messageThree(snonce, &air);
    try testing.expect(join.carried(eapolOf(air[0..three]).?, &out) == .traffic);
    try testing.expectEqual(old.generation, join.responseKey().?.generation);
    const m4 = join.response.?;
    join.sent(m4, false);
    var intervening: [512]u8 = undefined;
    ap.replay += 1;
    const other_one = ap.messageOne(&intervening);
    try testing.expect(join.carried(eapolOf(intervening[0..other_one]).?, &out) == .traffic);
    try testing.expectEqual(.m2, join.response.?.kind);
    join.sent(join.response.?, true);
    try testing.expectEqual(old.generation, join.keys().?.pairwise.generation);
    try testing.expect(join.carried(eapolOf(air[0..three]).?, &out) == .traffic);
    join.sent(join.response.?, true);
    const fresh = join.keys().?.pairwise;
    try testing.expect(fresh.generation != old.generation);
    try testing.expectEqual(old.generation, join.keys().?.previous.?.generation);
    try testing.expect(join.carried(eapolOf(air[0..three]).?, &out) == .traffic);
    try testing.expectEqual(old.generation, join.responseKey().?.generation);
    join.sent(join.response.?, true);
    join.pairwiseHeard(fresh.generation);
    try testing.expect(join.carried(eapolOf(air[0..three]).?, &out) == .traffic);
    try testing.expectEqual(fresh.generation, join.responseKey().?.generation);
}

test "farewells for another station are ignored and tune boundaries recheck policy" {
    var join = station();
    var ap = FakeAp{ .protected = false };
    var air: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    join.wants(wifi.Ssid.of(SSID).?, .none, .conservative, @splat(0));
    _ = join.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    join.held = 11;
    try testing.expectEqual(Action{ .failed = .untuned }, join.tuned(true));

    join.state = .joined;
    join.deadline = SILENCE_MICROS;
    var head = FakeAp.fromAp();
    head.addr1[5] ^= 1;
    const wrong = mlme.Farewell.write(head, mlme.Farewell.deauthentication(.inactivity), &air).?;
    try testing.expectEqual(Action.none, join.heard(air[0..wrong], .{}, 1, &out));
    try testing.expect(join.farewell_reason == null);
    const right = FakeAp.goodbye(&air);
    try testing.expectEqual(Action{ .failed = .disconnected }, join.heard(air[0..right], .{}, 2, &out));
    try testing.expectEqual(mlme.Reason.leaving, join.farewell_reason.?);
    try testing.expectEqualSlices(u8, &US, &join.farewell_destination);
}
