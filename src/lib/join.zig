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
//!
//! What this station does not have, and what that leaves open
//! ---------------------------------------------------------
//!
//! Management frames are not protected. 802.11w — protected management
//! frames, the thing that makes a deauthentication a frame only the
//! access point could have written — is not offered here, so every
//! management frame this station acts on is unauthenticated, and the only
//! thing saying the access point sent it is the address in it. An address
//! is a claim anybody in earshot can make.
//!
//! What is done about that is the part that does not need the standard:
//!
//!  - a frame that changes the state of a join is believed only when it
//!    is addressed to this station by name, never when it is addressed
//!    to the room;
//!  - one answer of each kind is taken per exchange, so a second
//!    authentication or association response arriving after the first was
//!    acted on changes nothing;
//!  - a cell that ends the association is not believed twice inside a
//!    moment, which is what bounds how much an attacker can drive rather
//!    than what makes the first one trustworthy.
//!
//! What remains open is everything else 802.11w is for. Somebody who
//! knows this station's address — which is in every frame it sends — can
//! forge a farewell to it, or an authentication or association response
//! ahead of the real one, and neither can be told from the real thing
//! without keys on management frames. The answer here is that such a join
//! fails and is tried again. It is not tricked into weaker protection:
//! what the network says about its own protection is compared with what
//! it said when the association was made, a cell whose advertisement
//! cannot be joined with the configured secret is not joined at all, and
//! a beacon is not enough to choose a cell by — several are heard before
//! one is picked, and the strongest joinable one wins.
//!
//! Making a farewell trustworthy needs 802.11w end to end: negotiating
//! it in the security element, deriving the integrity keys it specifies,
//! carrying its information elements, and checking a code on every
//! management frame after the exchange. That is a piece of work of its
//! own and is not in this file.

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

/// How long the name is listened for before one of the cells answering to
/// it is chosen.
///
/// Choosing on the first beacon is choosing on whichever cell spoke
/// first, and an attacker's radio can speak first every time: it can
/// advertise the name with no protection at all, or with a protection
/// this station cannot use, and either way the join is over before the
/// real network has had its turn. Waiting out a pass means the choice is
/// made between the cells actually in earshot. The caller sets the length
/// it waits, because the caller is what knows how long its own sweep of
/// the band takes.
pub const SEEK_MICROS: u64 = 2_000_000;

/// How soon after one believed farewell another is believed.
///
/// A cell that ends an association says so once, and a station that has
/// acted on it is no longer joined, so a second arriving hard on the
/// heels of the first has nothing to act on. Management frames are
/// unauthenticated here, so this is what bounds how much of the state of
/// a join a stranger can move in a burst rather than any claim that the
/// first one was genuine.
pub const FAREWELL_GAP_MICROS: u64 = 500_000;

/// How long after this station's own last frame of the exchange an
/// unprotected key frame from the cell is still believed.
///
/// The exchange's last frame is answered in the clear when the cell has
/// not shown it holds the keys yet, because a cell that did not hear it
/// sends its own message again unprotected and waiting for an answer it
/// can read. That window closes the moment the cell is heard under the
/// key, and in any case when this long has passed: a cell that has said
/// nothing sealed in all that time is not one that missed a frame.
pub const CLEAR_EAPOL_MICROS: u64 = 2_000_000;

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

/// How many cells answering to one name are kept while the name is being
/// listened for. A house hears one; a block of flats hears several, and
/// the point of waiting is to choose between them.
const MAX_CELLS = 8;

/// A cell heard answering to the name, and what it said about its own
/// protection, kept exactly as it said it.
const Candidate = struct {
    bss: mlme.Bss,
    rsn: ieee80211.Rsn.Transcript,
};

/// Why a cell heard answering to the name cannot be joined with the
/// secret this station was given.
///
/// A conflict rather than a failure: what the cell advertises is a claim
/// anybody can make, so a name heard only with the wrong protection is
/// not a reason to stop looking. It is remembered by cell, so that a
/// second pass does not take a second look at one that cannot be joined,
/// and said, because "the name is in the air but not with the protection
/// I was given" is the honest answer and is worth more than a timeout.
pub const Conflict = struct {
    bssid: mac.Address,
    kind: Kind,

    pub const Kind = enum {
        /// A secret is configured for this name and the cell offering it
        /// has no protection at all. Joining would put the traffic
        /// somebody meant to protect into the clear, and answering its
        /// key exchange would hand over everything needed to guess the
        /// passphrase offline.
        unprotected,
        /// It needs a secret and none was configured.
        needs_key,
        /// It protects its traffic in a way this system does not speak.
        unsupported,
    };
};

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
    /// Signed key frames that did not check out, kept where the exchange's
    /// own count cannot reach. A join that ended has erased its secrets,
    /// and this is what is left to say why.
    mic_failures: u32 = 0,
    /// The network being joined, once one has been heard, and the
    /// security element it advertised.
    bss: ?mlme.Bss = null,
    ap_rsn: ieee80211.Rsn.Transcript = .{},
    held: ?u8 = null,
    farewell_reason: ?mlme.Reason = null,
    farewell_destination: mac.Address = @splat(0),
    /// What the access point granted.
    aid: u14 = 0,

    /// Cells heard answering to the name, and when the pass that is
    /// collecting them is over.
    found: [MAX_CELLS]?Candidate = @splat(null),
    /// Cells heard answering to the name with protection this station
    /// cannot join it with, remembered by cell so that a later pass does
    /// not take a second look at one.
    refused: [MAX_CELLS]?Conflict = @splat(null),
    /// How long a pass lasts, and when the one in hand is over. Zero
    /// before anything has been heard, which is a pass that has not
    /// begun. The caller sets the length, knowing how long its sweep
    /// takes; a caller that wants the first cell to answer sets nothing.
    seek_for: u64 = SEEK_MICROS,
    seek_until: u64 = 0,
    /// The last cell whose advertisement could not be joined with the
    /// configured secret, for whoever reports what was heard.
    conflict: ?Conflict = null,
    /// Whether this exchange has already taken an answer of each kind.
    /// Management frames are unauthenticated here, so a second answer
    /// arriving after the first was acted on is as likely to be a
    /// forgery as a retransmission, and there is nothing to be gained
    /// from being moved by it twice.
    took_auth: bool = false,
    took_assoc: bool = false,
    /// When the last farewell was believed, which is what the gap
    /// between two of them is measured from.
    farewell_at: ?u64 = null,
    /// When this station's last frame of an exchange was handed over,
    /// which is what bounds how long a later one is answered in the
    /// clear for.
    m4_at: ?u64 = null,

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
        // Everything the last join was holding goes, secrets included,
        // before this one is named: a join named over the top of another
        // is not a reason to leave that one's keys lying about.
        self.stop();
        self.want = ssid;
        self.psk = psk;
        self.plan = plan;
        self.snonce = snonce;
        self.state = if (ssid.len == 0) .idle else .seeking;
        self.left = TRIES;
    }

    /// Stop wanting anything. The caller takes the association down.
    pub fn stop(self: *Join) void {
        self.erase();
        self.* = .{ .station = self.station };
    }

    /// Wipe every secret this join holds: the pairwise master key, the
    /// transient and group keys the exchange earned, the nonces, and the
    /// buffer the key frames were written through.
    ///
    /// A join is a value in its caller's static storage, not a stack
    /// frame about to be reused, so setting it aside leaves the keys
    /// where they were for anything that later reads that memory: a core
    /// dump, a bug that prints it, a second join whose bytes land in the
    /// same place. Called on every path that ends a join, whether it
    /// ended well or badly, and on the way into a new one.
    pub fn erase(self: *Join) void {
        if (self.handshake) |*shake| {
            // Kept before the exchange holding it is destroyed. A count is
            // not a secret, and it is the one thing that tells a secret
            // which is not the network's from a cell that never answered:
            // erased with the keys, every failure reads the same.
            self.mic_failures = shake.mic_failures;
            shake.erase();
        }
        if (self.earned) |*earned| earned.erase();
        if (self.pending) |*staged| staged.erase();
        self.handshake = null;
        self.earned = null;
        self.pending = null;
        wpa2.scrub(&self.scratch);
        wpa2.scrub(&self.snonce);
    }

    /// How many signed key frames from the cell failed their integrity
    /// check. Nothing else says they arrived at all, and their number is
    /// the difference between a secret that is not the network's and an
    /// access point that never answered.
    ///
    /// Answered from the exchange while there is one and from what was kept
    /// of it afterwards, because the moment this matters is the moment the
    /// join has ended and its secrets have gone.
    pub fn micFailures(self: *const Join) u32 {
        return if (self.handshake) |shake| shake.mic_failures else self.mic_failures;
    }

    /// Whether an unprotected key frame from the cell is still worth
    /// answering.
    ///
    /// True only for as long as this station's own last frame of the
    /// exchange may still be the one the cell is waiting for: past that,
    /// a cell sending key frames in the clear is not one that missed an
    /// answer, because one that had the keys would be speaking under
    /// them.
    pub fn expectsClearEapol(self: *const Join, now: u64) bool {
        const sent_at = self.m4_at orelse return false;
        return now < sent_at + CLEAR_EAPOL_MICROS;
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
            .seeking => self.sawBeacon(frame, signal, now),
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
        if (self.farewell(frame, now)) |ended| return ended;
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
            // The name is being listened for: when the pass is over,
            // choose between the cells that answered to it. A pass with
            // nothing heard is not one to wake for.
            .seeking => {
                if (self.seek_until == 0 or now < self.seek_until) return .none;
                return self.choose(now);
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

    /// A beacon or probe response from a cell answering to the name.
    ///
    /// Not joined on the strength of one beacon. Which cell to join is
    /// decided after a pass of listening rather than on the first frame
    /// to arrive, because the first frame to arrive is whichever radio
    /// got there first, and a name on the air is a claim anybody can
    /// make. A cell advertising the name with no protection at all, or
    /// with protection this station does not speak, can otherwise end the
    /// join before the real network has been heard.
    fn sawBeacon(self: *Join, frame: []const u8, signal: wifi.Signal, now: u64) Action {
        var advertised = ieee80211.Rsn.Transcript{};
        const seen = mlme.Bss.fromBeacon(frame, signal, &advertised) orelse return .none;
        if (!seen.ssid.eql(self.want)) return .none;
        // A cell already heard saying something this station cannot join
        // it with is not heard again.
        if (self.banned(seen.bssid)) return .none;

        // A network heard on a channel the plan does not allow is one this
        // station may not transmit on, and one that named no channel is
        // one there is nowhere to point the radio at. Hearing a frame is
        // not permission to answer it.
        if (seen.channel == 0 or !self.plan.allows(seen.channel) or
            (self.held != null and self.held.? != seen.channel)) return .none;

        // The pass starts at the first cell to answer, not when the join
        // was asked for: a pass is time spent hearing things, and a
        // stretch of silence before the first beacon is not part of one.
        if (self.seek_until == 0) self.seek_until = now + self.seek_for;
        self.keep(.{ .bss = seen, .rsn = advertised });
        if (now < self.seek_until) return .none;
        return self.choose(now);
    }

    /// Keep a cell that answered to the name, against the others heard in
    /// this pass. Heard again is heard at its latest signal; a pass that
    /// hears more cells than are kept keeps the strongest of them.
    fn keep(self: *Join, candidate: Candidate) void {
        for (&self.found) |*slot| {
            if (slot.*) |*had| {
                if (!mac.eql(had.bss.bssid, candidate.bss.bssid)) continue;
                had.* = candidate;
                return;
            }
        }
        var weakest = &self.found[0];
        for (&self.found) |*slot| {
            if (slot.* == null) {
                slot.* = candidate;
                return;
            }
            if (weaker(slot.*.?.bss.signal, weakest.*.?.bss.signal)) weakest = slot;
        }
        if (weaker(weakest.*.?.bss.signal, candidate.bss.signal)) weakest.* = candidate;
    }

    /// Take the best of what the pass heard, or say why none of it will
    /// do and listen again.
    fn choose(self: *Join, now: u64) Action {
        var best: ?Candidate = null;
        var needs_key = false;
        for (self.found) |slot| {
            const candidate = slot orelse continue;
            // What cannot be joined with the secret configured for this
            // name is remembered by cell and heard no more, whether or
            // not something else in earshot can be: that the name is
            // also being advertised the wrong way is worth saying.
            if (self.conflictWith(candidate.bss.security)) |kind| {
                if (kind == .needs_key) needs_key = true;
                self.refuse(.{ .bssid = candidate.bss.bssid, .kind = kind });
                continue;
            }
            if (best == null or weaker(best.?.bss.signal, candidate.bss.signal)) best = candidate;
        }

        if (best) |chosen| {
            self.bss = chosen.bss;
            // What the network said about its own protection, kept exactly
            // as it said it: the key exchange's third message repeats it,
            // and the two being the same is what says nobody talked the
            // network down in between.
            self.ap_rsn = chosen.rsn;
            self.state = .tuning;
            self.left = TRIES;
            return .{ .tune = .{ .number = chosen.bss.channel } };
        }

        // A name heard only from cells that protect their traffic, while
        // no secret is configured, is not a conflict to keep looking at:
        // it is a key nobody has given this station, and no amount of
        // listening will produce one.
        if (needs_key) return self.give(.no_key);

        // Otherwise another pass, from the beginning. A cell whose
        // advertisement cannot be joined is as likely to be a stranger's
        // radio as the network somebody meant, so the honest answer is
        // that the name is in the air and not with the protection it was
        // given, and the join is still looking.
        self.seek_until = now + self.seek_for;
        return .none;
    }

    /// Why a cell advertising this protection cannot be joined with the
    /// secret this station was given, or null when it can be.
    fn conflictWith(self: *const Join, security: wifi.Security) ?Conflict.Kind {
        return switch (security) {
            // A password is set for this name, so a cell offering it with
            // no protection at all is not the network somebody meant.
            // Whether the traffic is protected is the person's decision,
            // taken when they set the password, not the access point's to
            // take again: joining would put that traffic in the clear, and
            // answering the cell's key exchange would hand over the
            // material for guessing the password offline.
            .open => if (self.psk != .none) .unprotected else null,
            // Protected, and nothing to protect it with.
            .wpa2_psk => if (self.psk == .none) .needs_key else null,
            // The old cipher, a first-generation network, or a newer key
            // agreement: named, and not joined.
            else => .unsupported,
        };
    }

    /// Remember a cell that cannot be joined, and say so.
    fn refuse(self: *Join, conflict: Conflict) void {
        for (&self.refused) |*slot| {
            if (slot.* == null) {
                slot.* = conflict;
                self.conflict = conflict;
                return;
            }
            if (mac.eql(slot.*.?.bssid, conflict.bssid)) {
                slot.* = conflict;
                self.conflict = conflict;
                return;
            }
        }
        // More cells than are kept: the ones already remembered are the
        // ones that were heard, and the newest is the one worth saying.
        self.conflict = conflict;
    }

    /// Whether this cell has been heard saying something this station
    /// cannot join it with.
    fn banned(self: *const Join, cell: mac.Address) bool {
        for (self.refused) |slot| {
            if (slot) |conflict| {
                if (mac.eql(conflict.bssid, cell)) return true;
            }
        }
        return false;
    }

    /// Which of two signals is the one to join by: the stronger. A report
    /// that carries no absolute figure is ranked below one that does,
    /// because the margin over a noise floor is not the same quantity as
    /// a level and there is no honest way to add the two together.
    fn weaker(one: wifi.Signal, other: wifi.Signal) bool {
        if (one.dbm != 0 or other.dbm != 0) return levelOf(one) < levelOf(other);
        return one.snr_db < other.snr_db;
    }

    fn levelOf(signal: wifi.Signal) i16 {
        return if (signal.dbm != 0) signal.dbm else std.math.minInt(i16);
    }

    // -----------------------------------------------------------------------
    // Authenticating
    // -----------------------------------------------------------------------

    fn sendAuth(self: *Join, now: u64, into: []u8) Action {
        const len = mlme.Auth.write(self.toAp(), .{ .sequence = 1 }, into) orelse return self.give(.unsent);
        self.state = .authenticating;
        self.deadline = now + REPLY_MICROS;
        // This exchange has not taken an answer yet.
        self.took_auth = false;
        return .{ .send = len };
    }

    fn sawAuth(self: *Join, frame: []const u8, now: u64, into: []u8) Action {
        if (self.farewell(frame, now)) |ended| return ended;
        const answer = mlme.Auth.parse(frame) orelse return .none;
        if (!self.answeredUs(frame)) return .none;
        // The station's own request, heard back, is not an answer to it.
        if (answer.sequence != 2) return .none;
        // And an answer in a scheme this station did not ask for is not an
        // answer to what it asked.
        if (answer.algorithm != .open_system) return .none;
        // One answer to this exchange. A second authentication response
        // arriving after the first was acted on cannot be told from a
        // forgery, and there is nothing it could say that would move the
        // join a second time.
        if (self.took_auth) return .none;
        if (!answer.status.ok()) return self.give(.refused);
        self.took_auth = true;
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
        // This exchange has not taken an answer yet.
        self.took_assoc = false;
        return .{ .send = len };
    }

    fn sawAssoc(self: *Join, frame: []const u8, now: u64, into: []u8) Action {
        _ = into;
        if (self.farewell(frame, now)) |ended| return ended;
        const answer = mlme.AssocResponse.parse(frame) orelse return .none;
        if (!self.answeredUs(frame)) return .none;
        if (!answer.status.ok()) return self.give(.refused);
        // One answer to this exchange, as with the authentication above.
        if (self.took_assoc) return .none;
        self.took_assoc = true;

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
        if (self.farewell(frame, now)) |ended| return ended;
        const head = ieee80211.Header.parse(frame) orelse return .none;
        if (head.control.protected or ieee80211.Topology.of(head.control) != .from_ap) return .none;
        const payload = eapolOf(frame) orelse return .none;
        if (!self.answeredUs(frame)) return .none;
        const key = wpa2.KeyFrame.parse(payload) orelse return .none;
        if (!key.info.pairwise) return .none;
        // A pointer into the field, not to a copy of it: the exchange's
        // state, the transient key above all, has to outlive this pass.
        const shake = &(self.handshake orelse return .none);
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
                const response = shake.response.?;
                self.response = response;
                if (response.kind == .m4) {
                    // When this station's last frame went is what bounds
                    // how long the cell's own are answered in the clear:
                    // it is the cell's missing this one that makes it send
                    // them unprotected.
                    self.m4_at = now;
                    self.pending = shake.keys();
                } else if (response.kind == .m2) {
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
        const shake = &(self.handshake orelse return .none);
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
    ///
    /// Unauthenticated, and treated as such. Without protected management
    /// frames, what says the access point sent this is the address in it,
    /// so a farewell is believed only when it names this station and only
    /// once in a while: one addressed to the room is a single frame
    /// anybody in earshot can send to end every association on the
    /// channel, and a burst of them is not several farewells, it is one
    /// played again.
    fn farewell(self: *Join, frame: []const u8, now: u64) ?Action {
        if (!mlme.Farewell.toUs(frame, self.station)) return null;
        const ended = mlme.Farewell.parse(frame) orelse return null;
        if (!self.fromCell(frame)) return null;
        if (self.farewell_at) |at| {
            if (now < at + FAREWELL_GAP_MICROS) return null;
        }
        const head = ieee80211.Header.parse(frame).?;
        self.farewell_at = now;
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
        // Nothing it earned is the caller's to install, and nothing it was
        // holding stays in memory: a join that ended is the commonest
        // place for keys to outlive the association they belonged to.
        self.erase();
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
    ///
    /// Addressed to this station or to the room besides. A frame from the
    /// cell to some other station — another station's association, an
    /// exchange this one is not part of — is not evidence about this
    /// join, and with management frames unprotected there is nothing in
    /// it that says whose it is.
    fn fromCell(self: *const Join, frame: []const u8) bool {
        const found = self.bss orelse return false;
        const head = ieee80211.Header.parse(frame) orelse return false;
        if (!mac.eql(head.addr1, self.station) and !mac.eql(head.addr1, mac.broadcast)) return false;
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
    /// Which cell it speaks for. Another address is another radio
    /// answering to the same name.
    bssid: mac.Address = AP,
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
            .addr2 = self.bssid,
            .addr3 = self.bssid,
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

/// Name the network and take the first cell that answers to it.
///
/// The tests below are about what happens once a cell has been found, so
/// they say a pass lasts nothing: the dwell, and the choosing it is for,
/// have their own tests at the end of this file.
fn wanted(join: *Join) void {
    wantedWith(join, PASSPHRASE);
}

/// The same, joining with another secret, and with none at all.
fn wantedWith(join: *Join, secret: []const u8) void {
    join.wants(wifi.Ssid.of(SSID).?, wifi.Psk.parse(secret).?, .conservative, @splat(0x5B));
    join.seek_for = 0;
}

fn wantedOpen(join: *Join) void {
    join.wants(wifi.Ssid.of(SSID).?, .none, .conservative, @splat(0));
    join.seek_for = 0;
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
    wantedOpen(&join);

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

test "a network this system cannot join is named and left alone" {
    var air: [512]u8 = @splat(0);
    var out: [512]u8 = @splat(0);

    // Protected, but no key configured.
    var ap = FakeAp{ .protected = true };
    var join = station();
    wantedOpen(&join);
    const beacon = ap.beacon(&air);
    try testing.expectEqual(Action{ .failed = .no_key }, join.heard(air[0..beacon], .{}, 0, &out));

    // The old cipher: named, and not joined. What a cell says about
    // itself is a claim anybody can make, so this does not end the join,
    // it is remembered against that cell and said: the name is in the
    // air, but not with a protection this system speaks.
    var wep = station();
    wanted(&wep);
    var elements: [32]u8 = @splat(0);
    var named = ieee80211.writeElement(&elements, .ssid, SSID).?;
    named += ieee80211.writeElement(elements[named..], .ds_parameter, &.{CHANNEL}).?;
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
    try testing.expectEqual(Action.none, wep.heard(air[0 .. wrote + 12 + named], .{}, 0, &out));
    try testing.expectEqual(State.seeking, wep.state);
    try testing.expectEqual(Conflict.Kind.unsupported, wep.conflict.?.kind);
    try testing.expectEqualSlices(u8, &AP, &wep.conflict.?.bssid);
    // And a second pass does not take a second look at it.
    try testing.expectEqual(Action.none, wep.heard(air[0 .. wrote + 12 + named], .{}, SEEK_MICROS, &out));
    try testing.expectEqual(State.seeking, wep.state);
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
    wantedWith(&join, "a different secret");

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
    wantedWith(&refusing, "a different secret");
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
    // to protect would go out in the clear. Not joined, and not the end
    // of the join either: a cell can say what it likes about itself, and
    // while it is the only thing answering to the name, the honest answer
    // is that the name is in the air with the wrong protection on it.
    var open = FakeAp{ .protected = false };
    var join = station();
    wanted(&join);
    try testing.expectEqual(
        Action.none,
        join.heard(air[0..open.beacon(&air)], .{ .dbm = -40 }, 0, &out),
    );
    try testing.expectEqual(State.seeking, join.state);
    try testing.expectEqual(Conflict.Kind.unprotected, join.conflict.?.kind);

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
    wanted(&join);
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
    wantedOpen(&join);
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

/// Join the open test network: heard, authenticated, associated.
///
/// Beacons, an authentication answer and a granted association, which is
/// the whole of an open join. The protected network's own way in is
/// longer and is written out where it is being tested.
fn joinedOpen(join: *Join, air: []u8, out: []u8) void {
    const beacon = (FakeAp{ .protected = false }).beacon(air);
    _ = join.heard(air[0..beacon], .{}, 0, out);
    _ = join.tick(0, out);
    const ok = FakeAp.authOk(air);
    _ = join.heard(air[0..ok], .{}, 100, out);
    const granted = FakeAp.assocOk(3, air);
    _ = join.heard(air[0..granted], .{}, 200, out);
}

test "the cell joined is the strongest that can be joined, not the first to answer" {
    const ROGUE = mac.Address{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    var air: [512]u8 = undefined;
    var out: [512]u8 = undefined;

    // Somebody else's radio, answering to the name with no protection at
    // all and louder than the network is. It speaks first, and it speaks
    // on every pass: a station that joined the first beacon it heard
    // would join this, and answer its key exchange with everything
    // needed to guess the password offline.
    var rogue = FakeAp{ .protected = false, .bssid = ROGUE };
    var home = FakeAp{ .protected = true };

    var join = station();
    join.wants(wifi.Ssid.of(SSID).?, wifi.Psk.parse(PASSPHRASE).?, .conservative, @splat(0x5B));

    const loud = rogue.beacon(&air);
    try testing.expectEqual(Action.none, join.heard(air[0..loud], .{ .dbm = -30 }, 0, &out));
    try testing.expectEqual(State.seeking, join.state);
    // The real network, quieter, heard later in the same pass.
    const quiet = home.beacon(&air);
    try testing.expectEqual(Action.none, join.heard(air[0..quiet], .{ .dbm = -70 }, SEEK_MICROS / 2, &out));
    try testing.expectEqual(State.seeking, join.state);

    // The pass over, the loud one is not what was chosen: it cannot be
    // joined with the secret this station was given, however well it is
    // heard.
    switch (join.tick(SEEK_MICROS, &out)) {
        .tune => |channel| try testing.expectEqual(@as(u8, CHANNEL), channel.number),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualSlices(u8, &AP, &join.bssid());
    try testing.expectEqual(State.tuning, join.state);
    // And what the loud one said is neither forgotten nor a failure.
    try testing.expectEqual(Conflict.Kind.unprotected, join.conflict.?.kind);
    try testing.expectEqualSlices(u8, &ROGUE, &join.conflict.?.bssid);
}

test "a name heard only with the wrong protection is not joined, and does not stop being looked for" {
    var air: [512]u8 = undefined;
    var out: [512]u8 = undefined;

    // Somebody else's radio answering to the name with no protection at
    // all. Whether the traffic is protected was decided when the password
    // was, and a cell can say what it likes about itself, so this is not
    // the network and it is not a reason to give up either.
    const ROGUE = mac.Address{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    var open = FakeAp{ .protected = false, .bssid = ROGUE };
    var join = station();
    join.wants(wifi.Ssid.of(SSID).?, wifi.Psk.parse(PASSPHRASE).?, .conservative, @splat(0x5B));

    const beacon = open.beacon(&air);
    try testing.expectEqual(Action.none, join.heard(air[0..beacon], .{ .dbm = -40 }, 0, &out));
    try testing.expectEqual(@as(u64, SEEK_MICROS), join.seek_until);

    // The pass ends with nothing that can be joined. Not a failure: the
    // honest answer is that the name is in the air and not with the
    // protection it was given, so another pass begins.
    try testing.expectEqual(Action.none, join.tick(SEEK_MICROS, &out));
    try testing.expectEqual(State.seeking, join.state);
    try testing.expectEqual(Conflict.Kind.unprotected, join.conflict.?.kind);
    try testing.expectEqual(@as(u64, 2 * SEEK_MICROS), join.seek_until);

    // That cell is not looked at a second time: it cannot be joined, and
    // a pass spent hearing it again is a pass spent hearing nothing.
    try testing.expectEqual(Action.none, join.heard(air[0..beacon], .{ .dbm = -40 }, SEEK_MICROS + 1, &out));
    try testing.expectEqual(Action.none, join.tick(2 * SEEK_MICROS, &out));
    try testing.expectEqual(State.seeking, join.state);

    // The network itself, heard on a later pass, is joined.
    var home = FakeAp{ .protected = true };
    const real = home.beacon(&air);
    switch (join.heard(air[0..real], .{ .dbm = -75 }, 3 * SEEK_MICROS, &out)) {
        .tune => |channel| try testing.expectEqual(@as(u8, CHANNEL), channel.number),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualSlices(u8, &AP, &join.bssid());
}

test "a farewell is believed only when it names this station, and not twice at once" {
    var air: [512]u8 = undefined;
    var out: [512]u8 = undefined;

    var join = station();
    wantedOpen(&join);
    joinedOpen(&join, &air, &out);
    try testing.expectEqual(State.joined, join.state);

    // Addressed to the room: one frame, from anybody in earshot, to every
    // station on the channel at once. Management frames are not
    // protected here, so there is nothing in it to believe.
    var room = FakeAp.fromAp();
    room.addr1 = mac.broadcast;
    const all = mlme.Farewell.write(room, mlme.Farewell.deauthentication(.leaving), &air).?;
    try testing.expectEqual(Action.none, join.heard(air[0..all], .{}, 300, &out));
    try testing.expect(join.farewell_reason == null);
    try testing.expectEqual(State.joined, join.state);

    // Addressed to another station in the cell, which fromCell already
    // turns away, and one to this station by name, which is the only
    // farewell there is anything to go on in.
    const mine = FakeAp.goodbye(&air);
    try testing.expectEqual(Action{ .failed = .disconnected }, join.heard(air[0..mine], .{}, 400, &out));
    try testing.expectEqual(mlme.Reason.leaving, join.farewell_reason.?);
    try testing.expectEqualSlices(u8, &US, &join.farewell_destination);

    // A second one a moment later is the same one again, or a stranger's,
    // and neither is a second answer to anything.
    var again = station();
    wantedOpen(&again);
    joinedOpen(&again, &air, &out);
    try testing.expectEqual(
        Action{ .failed = .disconnected },
        again.heard(air[0..FakeAp.goodbye(&air)], .{}, 400, &out),
    );
    again.state = .joined;
    try testing.expectEqual(Action.none, again.heard(air[0..FakeAp.goodbye(&air)], .{}, 500, &out));
    try testing.expectEqual(State.joined, again.state);
    try testing.expectEqual(mlme.Reason.leaving, again.farewell_reason.?);
    // Once the gap has passed, one is believed again.
    try testing.expectEqual(
        Action{ .failed = .disconnected },
        again.heard(air[0..FakeAp.goodbye(&air)], .{}, 500 + FAREWELL_GAP_MICROS, &out),
    );
}

test "one answer of each kind is taken per exchange" {
    var air: [512]u8 = undefined;
    var out: [512]u8 = undefined;

    // Authenticated, and then asked to authenticate again by a second
    // answer arriving behind the first. Management frames are
    // unauthenticated, so the second is as likely to be a forgery as a
    // retransmission, and there is nothing it can say that is worth
    // associating a second time for.
    var join = station();
    wanted(&join);
    var ap = FakeAp{ .protected = true };
    _ = join.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = join.tick(0, &out);
    const first = FakeAp.authOk(&air);
    const asked = switch (join.heard(air[0..first], .{}, 100, &out)) {
        .send => |n| n,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(mlme.AssocRequest.parse(out[0..asked]) != null);
    try testing.expectEqual(Action.none, join.heard(air[0..first], .{}, 110, &out));
    try testing.expectEqual(State.associating, join.state);

    // The same for the association's answer: granted once, and a second
    // grant arriving behind it grants nothing.
    _ = join.heard(air[0..FakeAp.assocOk(7, &air)], .{}, 200, &out);
    try testing.expectEqual(State.handshaking, join.state);
    try testing.expectEqual(Action.none, join.heard(air[0..FakeAp.assocOk(9, &air)], .{}, 210, &out));
    // Including what it granted: the second answer's identifier is not
    // this station's.
    try testing.expectEqual(@as(u14, 7), join.aid);
}

test "a join that is stopped leaves none of its keys behind" {
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
    try testing.expect(join.keys() != null);
    try testing.expectEqual(@as(u32, 0), join.micFailures());

    // Stopped, whether because the cell was left or because the radio
    // went away. The keys are this process's to forget, and forgetting
    // where they are is not the same as destroying them.
    join.stop();
    try testing.expectEqual(@as(?wpa2.Keys, null), join.keys());
    try testing.expectEqual(State.idle, join.state);
    try testing.expectEqual(@as(?wpa2.Handshake, null), join.handshake);
    try testing.expect(std.mem.allEqual(u8, &join.scratch, 0));
    try testing.expect(std.mem.allEqual(u8, &join.snonce, 0));
}

test "an unprotected key frame is only believed for a while after this station's last" {
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
    // Nothing to believe before this station has sent its last frame.
    try testing.expect(!join.expectsClearEapol(350));
    _ = join.heard(air[0..ap.messageThree(join.snonce, &air)], .{}, 400, &out);
    join.sent(join.response.?, true);

    // A cell that did not hear it says so by sending its own again in
    // the clear, which is believed for a while.
    try testing.expect(join.expectsClearEapol(400));
    try testing.expect(join.expectsClearEapol(400 + CLEAR_EAPOL_MICROS - 1));
    // And not for ever: one still sending key frames unprotected long
    // after this station's last frame is not one that missed it.
    try testing.expect(!join.expectsClearEapol(400 + CLEAR_EAPOL_MICROS));
}

test "a join that failed still says how many key frames did not check out" {
    var ap = FakeAp{ .protected = true };
    var join = station();
    // A secret that is not the network's, which is what a mistyped
    // passphrase is: the cell's third message is signed under a key this
    // station does not derive, so nothing it sends after the first checks
    // out and the exchange ends in a timeout like any other.
    wantedWith(&join, "not the password");

    var air: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    _ = join.heard(air[0..ap.beacon(&air)], .{}, 0, &out);
    _ = join.tick(0, &out);
    _ = join.heard(air[0..FakeAp.authOk(&air)], .{}, 100, &out);
    _ = join.heard(air[0..FakeAp.assocOk(7, &air)], .{}, 200, &out);
    _ = join.heard(air[0..ap.messageOne(&air)], .{}, 300, &out);
    _ = join.heard(air[0..ap.messageThree(join.snonce, &air)], .{}, 400, &out);
    try testing.expect(join.micFailures() != 0);

    var at: u64 = 400;
    while (join.state != .failed) {
        at += 1_000_000;
        _ = join.tick(at, &out);
    }

    // The join has ended and its keys are gone, which is exactly when this
    // number is worth having: it is the difference between a password that
    // is not this network's and a cell that never answered at all.
    try testing.expectEqual(@as(?wpa2.Keys, null), join.keys());
    try testing.expect(join.micFailures() != 0);

    // And a join started over counts from nothing.
    join.stop();
    try testing.expectEqual(@as(u32, 0), join.micFailures());
}
