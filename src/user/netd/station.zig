//! The station: what a radio is doing above its driver.
//!
//! The driver tunes and hears; this file decides where to tune, what the
//! hearing amounts to, and what to say back. With no network named that is
//! a scan: the radio walks the channels its regulatory plan allows, dwells
//! long enough on each to hear a beacon, and keeps an account of every
//! network it hears. With one named it is a join, which `lib.join` decides
//! the steps of and this file carries out.
//!
//! The radio is reached through the device contract's hooks and the radio
//! table an interface carries. No driver is named here: a second radio is
//! a second table, and this file does not change.

const std = @import("std");
const dev_mod = @import("dev.zig");
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const settings = @import("proto").settings;
const sys = @import("sys");

const join_mod = lib.join;
const mlme = lib.mlme;
const proto_net = @import("proto").net;
const wifi = lib.wifi;

/// Room for the longest frame the join writes: an association request
/// carrying the rates and the security element, or a key frame wrapped in
/// a data frame.
const FRAME_MAX = 512;

/// Room for traffic either way: an ethernet frame at its longest, and the
/// radio header that wraps one.
const DATA_MAX = 1600;

/// How many networks the scan keeps. A home hears a dozen; a flat in a
/// city hears more, and the rest are heard again on the next pass.
const MAX_NETWORKS = 32;

/// How long the radio listens on a channel: two beacon intervals, so a
/// network beaconing at the usual hundred milliseconds is heard.
const DWELL_MICROS: u64 = 200_000;

/// How far a network's signal may wander before it is worth reordering the
/// list for, in decibels. Below this the account is the same account.
const SIGNAL_SLACK: u16 = 3;

/// How long to leave a network alone after failing to join it. Long
/// enough not to hammer an access point that refused, short enough that
/// one which was merely out of earshot is picked up again without anybody
/// asking twice.
const RETRY_MICROS: u64 = 10_000_000;

/// How often what the radio has heard is handed to the machine's pool. The
/// kernel needs a seed's worth in total and the radio is a bonus on top of the
/// interrupt timing it already has, so this is slow on purpose: often enough
/// to matter on a machine that is listening, rare enough to cost nothing.
const STIR_MICROS: u64 = 1_000_000;

/// How often the radio's long calibration runs.
///
/// The long one measures the noise floor, and measuring it means waiting on
/// the hardware to say it has finished. That wait is the reference's own, and
/// its patience runs to fifty milliseconds of looking; a dwell is two hundred.
/// So on the dwell's cadence a slow measurement costs a quarter of the machine
/// and an unjoined radio is the busiest thing on it. A noise floor follows the
/// room rather than the channel, and the room does not change five times a
/// second.
const LONG_CAL_MICROS: u64 = 30_000_000;

/// How often the radio's own upkeep runs: the short calibration, and the
/// judgement of how willing the baseband should be to decide a signal has
/// begun.
///
/// Its own cadence, not the sweep's. A joined radio sits on one channel
/// for hours and needs both as much as a sweeping one does: what drifts
/// is the silicon's, and a room's noise does not hold still because a
/// station stopped moving.
const UPKEEP_MICROS: u64 = DWELL_MICROS;

const State = struct {
    radio: ?*dev_mod.NicDev = null,
    plan: wifi.Regulatory = .conservative,
    networks: lib.Bounded(mlme.Bss, MAX_NETWORKS) = .{},
    /// Whether the account is in the order it is offered in. Cleared when
    /// a network is heard, and put right on the next read rather than on
    /// every beacon: a sort per frame is work nobody asked for.
    ordered: bool = false,
    /// Which of the band's channels the radio is on.
    channel_index: usize = 0,
    /// The channel configuration holds the radio on, or null to sweep.
    /// A radio told where to listen stays there: what a sweep is for is
    /// finding out what is in earshot, and a person who already knows has
    /// nothing to find.
    held: ?u8 = null,
    /// Dwells finished. A sweep of the plan is as many as there are
    /// channels in it, which is when a radio that has heard nothing has
    /// had its chance and is worth asking about.
    hops: usize = 0,
    next_hop_at: u64 = 0,
    next_upkeep_at: u64 = 0,
    next_stir_at: u64 = 0,
    next_long_cal_at: u64 = 0,
    /// Whether the configuration says this interface is to be joining
    /// anything.
    ///
    /// A slot switched off stops the joining and not the listening. What
    /// somebody switched off is an interface, not the radio: the power is
    /// the wireless key's business, and a radio that stopped hearing when
    /// an interface went down is one nobody could scan with before
    /// deciding to bring it up.
    on: bool = true,
    full_said: bool = false,
    /// The join in hand, or none while no network is named.
    join: ?join_mod.Join = null,
    /// Where the join writes the frames it wants sent.
    frame: [FRAME_MAX]u8 = @splat(0),
    /// Where traffic is turned from one framing into the other. Both
    /// directions can be in hand at once, because the stack answers some
    /// frames as they arrive, so neither borrows the other's room.
    dressed: [DATA_MAX]u8 = @splat(0),
    undressed: [DATA_MAX]u8 = @splat(0),
    plain: [DATA_MAX]u8 = @splat(0),
    opened: [DATA_MAX]u8 = @splat(0),
    /// Frames heard while an exchange was in hand. The one thing that
    /// separates a cell that never answered from an answer that was not
    /// understood.
    heard_joining: u32 = 0,
    /// Of those, the ones this station was addressed by name in, and the
    /// ones that were the answer it was waiting for. Between them they
    /// separate a cell that never replied from a reply that arrived and
    /// was not accepted.
    heard_for_us: u32 = 0,
    heard_auth: u32 = 0,
    /// Frames the exchange asked to have sent. Against what the radio
    /// reports sending, this says whether anything was lost between
    /// deciding to speak and speaking.
    sent_joining: u32 = 0,
    /// What the last authentication meant for this station actually said,
    /// and whether it came from the cell being joined. Every test the join
    /// puts an answer through, reported rather than inferred.
    last_auth: ?struct {
        sequence: u16,
        status: u16,
        from_cell: bool,
        /// What the join was doing when it arrived. An answer that lands
        /// while the exchange is not waiting for one is an answer nothing
        /// looks at, however right it is.
        state_then: join_mod.State,
    } = null,
    /// Why the last attempt stopped, in the words a screen needs. Kept past
    /// the attempt, because what somebody wants to know is why the thing
    /// they asked for did not happen.
    stopped: proto_net.Stopped = .none,
    /// Which step of the exchange it was on when it gave up.
    failed_in: join_mod.State = .idle,
    /// What a heard frame asked for, carried out from the loop rather
    /// than where it was decided. Deciding happens inside the driver's
    /// walk of its receive ring, and tuning resets the radio underneath
    /// that walk, which leaves the ring and the hardware disagreeing
    /// about where it is.
    pending: ?join_mod.Action = null,
    /// The number the next sealed frame carries. A number is never used
    /// twice under one key, so it only counts up and starts again with a
    /// new key.
    tx_numbering: lib.wpa2.TxNumbering = .{},
    /// Where the numbering under each of the cell's keys has got to, which
    /// is what tells a frame that has arrived from one that is arriving
    /// again.
    numbering: lib.wpa2.Numbering = .{},
    /// What to be on, kept past the join that failed so it can be tried
    /// again without anybody asking twice, and when to try.
    wanted: ?settings.NetSlot = null,
    retry_at: u64 = 0,
    /// How fast to talk to the cell, and the account of how each rate
    /// has fared that decides it.
    speed: lib.rates.Choice = .{},
    /// The number the next frame this station sends carries. Every frame
    /// in a cell is numbered, so the far end can tell a repeat from a new
    /// one.
    sequence: u12 = 0,
};

var state: State = .{};

/// Take the radio's hooks. Called once, before any driver starts.
pub fn init() void {
    dev_mod.radio_rx = heard;
    dev_mod.radio_tx = send;
    dev_mod.radio_tx_done = sent;
    dev_mod.radio_up = begin;
    dev_mod.radio_down = forget;
    dev_mod.radio_config = configure;
}

/// How far the radio has got with the network it was told to join, and why
/// it stopped where it did. Read by anything that lists interfaces, so the
/// pane, the menu bar and `net` all say the same thing.
pub fn joining() proto_net.Joining {
    const attempt = state.join orelse {
        return if (state.wanted != null) .stopped else .idle;
    };
    return switch (attempt.state) {
        .idle, .seeking => .looking,
        .tuning, .authenticating, .associating, .handshaking => .connecting,
        .joined => .connected,
        .failed => .stopped,
    };
}

pub fn stopped() proto_net.Stopped {
    return state.stopped;
}

/// The networks the scan has heard, newest last.
pub fn networks() []const mlme.Bss {
    order();
    return state.networks.slice();
}

/// Put the account in the order it is offered in: strongest first.
///
/// Done here, once, because the Settings pane, the bar's menu and
/// `net wifi scan` all read this list, and a list that is ordered by
/// whoever shows it is three orders that drift apart.
fn order() void {
    if (state.ordered) return;
    // Stable and small: a dozen networks, and two of equal strength keep
    // the order they were heard in.
    std.sort.insertion(mlme.Bss, state.networks.mutable(), {}, mlme.Bss.strongerFirst);
    state.ordered = true;
}

/// One of them, by index, or null past the last.
///
/// A caller walks this from zero, so the order is settled at the start of a
/// walk and left alone through it. Reordering underneath one would show a
/// network twice and skip another.
pub fn network(index: usize) ?mlme.Bss {
    if (index == 0) order();
    return state.networks.at(index);
}

/// Microseconds until the station next needs the loop, for the wait
/// deadline. Null while there is no radio.
pub fn nextDeadline() ?u64 {
    if (state.radio == null) return null;
    // Something a frame asked for is owed now.
    if (state.pending != null) return 0;
    const now = sys.clockMicros();
    const hop_in: u64 = if (state.next_hop_at > now) state.next_hop_at - now else 0;
    // The upkeep is owed whatever else is happening.
    const upkeep_in: u64 = if (state.next_upkeep_at > now) state.next_upkeep_at - now else 0;

    const attempt = state.join orelse {
        // Nothing in hand: the sweep, or the moment a failed join is due
        // to be tried again, whichever comes first.
        if (state.wanted == null) return @min(upkeep_in, hop_in);
        const retry_in: u64 = if (state.retry_at > now) state.retry_at - now else 0;
        return @min(upkeep_in, @min(hop_in, retry_in));
    };
    const owed = owedIn(attempt, now);

    // A join still looking rides the sweep, so whichever comes first. One
    // that has found its network owns the radio and the sweep is not
    // happening, so the sweep's deadline is not one to wake for.
    if (sweeping(attempt)) {
        return @min(upkeep_in, if (owed) |soon| @min(hop_in, soon) else hop_in);
    }
    return if (owed) |soon| @min(upkeep_in, soon) else upkeep_in;
}

/// Whether the join still leaves the radio free to sweep the band. Read
/// the same way wherever it matters: a pass that sweeps without renewing
/// the dwell, or renews one it does not sweep, is a loop that never
/// waits.
fn sweeping(attempt: join_mod.Join) bool {
    return switch (attempt.state) {
        .idle, .seeking => true,
        .tuning, .authenticating, .associating, .handshaking, .joined, .failed => false,
    };
}

/// How long until the join next needs looking at, or null while it needs
/// nothing. Waiting on a reply is the only thing it waits for, and it
/// waits exactly as long as it is worth waiting.
fn owedIn(attempt: join_mod.Join, now: u64) ?u64 {
    if (attempt.settling) return 0;
    return switch (attempt.state) {
        // The radio has been pointed at the channel; the next step is
        // owed now.
        .tuning => 0,
        .authenticating, .associating, .handshaking => if (attempt.deadline > now) attempt.deadline - now else 0,
        // Joined, and owed a look when the cell has been quiet for as long
        // as anybody would wait for it.
        .joined => if (attempt.deadline > now) attempt.deadline - now else 0,
        // Nothing owed: not started, still listening, finished either way.
        .idle, .seeking, .failed => null,
    };
}

/// Run whatever the station owes: a hop when the dwell is over.
pub fn tick() void {
    var now = sys.clockMicros();

    // What the radio has heard, handed to the machine's pool. The kernel sees
    // every interrupt and no radio; this is the one process that sees one, so
    // giving it up is this service's to do and nobody asks for it.
    if (now >= state.next_stir_at) {
        state.next_stir_at = now + STIR_MICROS;
        contribute();
    }

    // Whatever a frame asked for, now that the driver is no longer in the
    // middle of handing it over.
    if (state.pending) |what| {
        state.pending = null;
        act(what);
        // Tuning resets the radio and waits for it, which takes as long as
        // it takes. A deadline dated from before that is short by however
        // long it was, and the step it belongs to gives up early.
        now = sys.clockMicros();
    }

    // The radio's own upkeep, whether or not it is sweeping.
    maintain(now);

    // A join that failed comes round again on its own. The next attempt
    // is dated first and unconditionally: a deadline left in the past is
    // a loop that never waits.
    if (state.on and state.join == null and state.wanted != null and now >= state.retry_at) {
        state.retry_at = now + RETRY_MICROS;
        if (radio()) |it| seek(it.nic, state.wanted.?);
    }

    if (state.join) |*attempt| {
        act(attempt.tick(now, &state.frame));
        // A join that is still looking wants the sweep to carry on; one
        // that has found its network owns the channel it found it on.
        if (state.join) |a| {
            if (!sweeping(a)) return;
        }
    }
    if (state.radio == null or now < state.next_hop_at) return;
    hop();
}

/// The cell this station belongs to, or none while it belongs to none.
/// Traffic can only be dressed for a cell, so this is what says whether
/// there is any traffic to carry.
fn cell() ?lib.mac.Address {
    const attempt = state.join orelse return null;
    if (attempt.state != .joined) return null;
    return attempt.bssid();
}

/// The keys the join earned and keeps up to date, or none on an open
/// network, or before there is a join.
fn keysOf() ?lib.wpa2.Keys {
    const attempt = state.join orelse return null;
    return attempt.keys();
}

/// One ordinary frame, dressed as the cell expects and handed to the
/// radio.
fn send(nic: *dev_mod.NicDev, frame: []const u8) bool {
    const key = if (keysOf()) |keys| keys.pairwise else null;
    return sendWithKey(nic, frame, key);
}

fn sendWithKey(nic: *dev_mod.NicDev, frame: []const u8, key: ?lib.wpa2.Key) bool {
    const bssid = cell() orelse return false;

    state.sequence +%= 1;
    const length = lib.ieee80211.fromEthernet(
        frame,
        bssid,
        .{ .sequence = state.sequence },
        &state.plain,
    ) orelse return false;
    const built = state.plain[0..length];

    const radio_ops = nic.ops.radio orelse return false;
    const series = state.speed.series();

    // An open network takes the frame as it stands.
    const installed = key orelse return radio_ops.transmitAt(nic, built, series);

    // Otherwise sealed under this station's own key, with a number that
    // is never used twice.
    const head = lib.ieee80211.Header.parse(built) orelse return false;
    const pn = state.tx_numbering.next(installed) orelse return false;
    const sealed = lib.wpa2.Ccmp.protect(
        installed.bytes,
        head,
        pn,
        0,
        built[head.len..],
        &state.dressed,
    ) orelse return false;
    return radio_ops.transmitAt(nic, state.dressed[0..sealed], series);
}

/// What became of a frame. The account this feeds is what decides how
/// fast the next one goes.
fn sent(_: *dev_mod.NicDev, outcome: lib.rates.Outcome) void {
    state.speed.report(outcome);
}

/// The reverse, for a frame the cell sent: undressed and handed to the
/// stack, which knows nothing about radios.
fn carry(nic: *dev_mod.NicDev, frame: []const u8) void {
    const bssid = cell() orelse return;
    const head = lib.ieee80211.Header.parse(frame) orelse return;
    if (head.control.kind != .data or head.control.more_fragments or head.sequence.fragment != 0) return;
    if (head.qos) |qos| {
        if (qos.amsdu) return;
    }

    // Traffic of this cell, spoken by its access point, addressed to this
    // station or to the room. A radio hears every cell on the channel and
    // every station in this one; what those say is somebody else's
    // business, and a frame claiming to be the access point's from
    // somewhere else is nobody's.
    if (lib.ieee80211.Topology.of(head.control) != .from_ap) return;
    if (!lib.mac.eql(head.addr2, bssid)) return;
    if (!lib.mac.eql(head.addr1, nic.mac) and !lib.mac.isGroup(head.addr1)) return;

    var plain = frame;
    if (keysOf()) |keys| {
        // A protected network carries nothing in the clear. Whether a
        // frame is protected is the association's to decide and not the
        // frame's: taking the frame's word for it is what lets anybody in
        // earshot put traffic on this machine's network without holding
        // the key. What arrives unprotected here is either somebody
        // else's or nobody's, and what arrives numbered where a frame has
        // already been is one already delivered.
        if (state.numbering.open(keys, frame, &state.opened)) |opened| {
            plain = opened;
            if (state.join) |*attempt| {
                // The cell speaking under the key is the cell proving it
                // holds it, which is the moment the association is real on
                // both sides rather than only on this one. Said once, at
                // that moment: until then this station is joined and the
                // cell may still be waiting to be told.
                const proving = if (attempt.handshake) |shake|
                    shake.confirmed != keys.pairwise.generation and
                        state.numbering.current_heard == keys.pairwise.generation
                else
                    false;
                attempt.pairwiseHeard(state.numbering.current_heard);
                if (proving) log.note(nic.name, "the cell answered under the key; the association holds at both ends");
            }
        } else {
            // One exception, and it closes for good the moment the cell
            // shows it holds the keys: the key exchange's own frames
            // before it does. An access point that did not hear the last
            // frame of an exchange sends its own again, and sends it in
            // the clear, because it has installed nothing yet. Refusing
            // that leaves this station holding keys the cell does not
            // have, with nothing to do but wait to be put out.
            if (state.numbering.current_heard == keys.pairwise.generation or
                keys.previous != null or head.control.protected or lib.mac.isGroup(head.addr1)) return;
            const payload = join_mod.eapolOf(frame) orelse return;
            const key = lib.wpa2.KeyFrame.parse(payload) orelse return;
            if (!key.info.pairwise or !key.info.install or !key.info.mic) return;
        }
    } else if (head.control.protected) {
        // And an open network has no key to open one with.
        return;
    }

    // The cell's authentication traffic is the join's: the next group key,
    // handed out for as long as the station stays. The stack never sees it.
    if (join_mod.eapolOf(plain)) |payload| {
        if (lib.mac.isGroup(head.addr1)) return;
        if (state.join) |*attempt| {
            act(attempt.carried(payload, &state.frame));
        }
        return;
    }

    const length = lib.ieee80211.toEthernet(plain, &state.undressed) orelse return;
    dev_mod.deliverRx(nic, .{ .frame = state.undressed[0..length], .ok = true });
}

/// The radio and the table it answers through, or none while there is no
/// radio or the interface is a wire.
fn radio() ?struct { nic: *dev_mod.NicDev, ops: dev_mod.RadioOps } {
    const nic = state.radio orelse return null;
    const ops = nic.ops.radio orelse return null;
    return .{ .nic = nic, .ops = ops };
}

fn begin(nic: *dev_mod.NicDev) void {
    state.radio = nic;
    state.channel_index = 0;
    state.hops = 0;
    state.next_hop_at = sys.clockMicros() + DWELL_MICROS;
}

/// The radio has gone. Everything here was about that radio, and a station
/// still holding it asks the loop to wake for a sweep of a band nothing is
/// listening to.
fn forget(nic: *dev_mod.NicDev) void {
    if (state.radio != nic) return;
    state.radio = null;
    state.join = null;
    state.pending = null;
    state.wanted = null;
    state.held = null;
    state.hops = 0;
    state.networks.clear();
    state.ordered = true;
    if (dev_mod.changed) |tell| tell();
}

/// The slot's plan and ceiling, whenever the configuration says.
fn configure(nic: *dev_mod.NicDev, role: settings.NetSlot) void {
    if (nic.class != .wifi) return;
    const ops = nic.ops.radio orelse return;

    const held = if (role.channel == 0) null else role.channel;
    const moved = !std.meta.eql(state.plan, role.regdomain) or state.held != held;
    state.plan = role.regdomain;

    // A slot switched off stops the joining. What it leaves is the
    // listening: a radio that went on authenticating and retrying through
    // being switched off would be doing exactly what somebody switched
    // off, and one that stopped hearing would leave nobody able to scan
    // before deciding to switch it on.
    const was_on = state.on;
    state.on = role.enabled;
    if (was_on and !state.on) leave(nic, ops);

    // Where the radio may be pointed, and where it is held, are terms of
    // a join. A station told to sit on a channel its cell is not on is
    // not joined to that cell any longer, and one whose plan changed may
    // no longer speak where it is standing. So a join in hand is given up
    // and asked for again under what was just said, rather than left
    // standing on terms nobody agreed to.
    if (moved) {
        if (state.join != null) leave(nic, ops);
        // Only where something changed: a settings pass saying the same
        // thing again would otherwise reset the radio and lose the dwell.
        if (held) |number| {
            if (!state.plan.allows(number) or !ops.tune(nic, .{ .number = number })) {
                // Do not certify a hold the radio failed to establish.
                state.held = null;
                state.wanted = if (role.enabled and role.ssid.len != 0) role else null;
                state.stopped = .untuned;
                state.retry_at = sys.clockMicros() + RETRY_MICROS;
                log.warn(nic.name, "channel hold failed; join deferred for retry");
                ops.setPower(nic, role.txpower.resolve(role.regdomain).half_dbm);
                return;
            }
        }
    }
    state.held = held;

    // What is wanted is a name and the secret to join it with. Acted on
    // when either changes, so a settings pass saying the same thing again
    // does not restart a join that is already running, and a password
    // corrected for the network already being tried is tried with.
    if (state.on and (moved or !was_on or !sameConnection(state.wanted, role))) {
        leave(nic, ops);
        if (role.ssid.len != 0) seek(nic, role);
    }

    // Told something new, so what it heard as the radio it used to be is
    // not evidence about the radio it now is. Counted and reported again
    // from here, which is what makes a channel named after the boot worth
    // naming at all.
    if (moved) {
        state.hops = 0;
        if (ops.watchAgain) |again| again(nic);
    }
    ops.setPower(nic, role.txpower.resolve(role.regdomain).half_dbm);
}

/// The network this radio is on, or trying to be on, for saying so. One
/// name, from the one place that holds it.
fn wantedName() []const u8 {
    const want = state.wanted orelse return "";
    return want.ssid.slice();
}

/// Whether a slot asks for the connection already in hand.
///
/// Only what decides a join counts. A ceiling or a regulatory plan
/// changing is not a reason to drop a connection and build it again; a
/// password is, and one compared by the network's name alone is a
/// correction that never takes, since the name it corrects is the name it
/// already had.
fn sameConnection(want: ?settings.NetSlot, role: settings.NetSlot) bool {
    const have = want orelse return role.ssid.len == 0;
    return std.mem.eql(u8, have.ssid.slice(), role.ssid.slice()) and have.psk.eql(role.psk);
}

/// Unpredictable bytes for anything that asks, and whether they are worth
/// calling unguessable.
///
/// The kernel holds the machine's randomness, because it sees every interrupt
/// and every program needs the answer. What netd has that the kernel does not
/// is the radio: the exact moment a frame lands, and the frames it could not
/// decode at all, which are the band's noise. That goes into the same pool, so
/// a machine with a radio has a better one than a machine without.
pub fn draw(into: []u8) bool {
    contribute();
    return sys.random(into);
}

/// Give the kernel whatever the radio has heard since last time.
fn contribute() void {
    const found = radio() orelse return;
    const from = found.ops.draw orelse return;
    var noise: [lib.entropy.Pool.BLOCK]u8 = undefined;
    if (from(found.nic, &noise)) sys.randomStir(&noise);
}

/// A nonce for the key exchange.
///
/// The radio's own noise is stirred in first where it has any, so a join on a
/// machine that has been listening draws on what it heard.
fn nonce(nic: *dev_mod.NicDev) lib.wpa2.Nonce {
    var value: lib.wpa2.Nonce = @splat(0);
    if (!draw(&value)) {
        log.say(nic.name, .dim, "not enough heard yet; the key exchange nonce is unrepeatable rather than unguessable");
    }
    return value;
}

/// Start looking for a network and joining it.
fn seek(nic: *dev_mod.NicDev, role: settings.NetSlot) void {
    state.wanted = role;
    if (role.channel != 0) {
        const ops = nic.ops.radio orelse return;
        if (!state.plan.allows(role.channel)) {
            state.stopped = .untuned;
            return;
        }
        if (state.held != role.channel) {
            if (!ops.tune(nic, .{ .number = role.channel })) {
                state.stopped = .untuned;
                return;
            }
            state.held = role.channel;
        }
    }
    state.heard_joining = 0;
    state.stopped = .none;
    state.heard_for_us = 0;
    state.heard_auth = 0;
    state.sent_joining = 0;
    state.last_auth = null;
    var attempt = join_mod.Join{ .station = nic.mac };
    attempt.wants(role.ssid, role.psk, state.plan, nonce(nic));
    attempt.held = state.held;
    state.join = attempt;

    log.begin(nic.name, .key);
    out.text("looking for \"");
    out.text(role.ssid.slice());
    out.text("\"");
    log.end();
}

/// Leave whatever the radio belongs to, and stop whatever it was joining.
fn leave(nic: *dev_mod.NicDev, ops: dev_mod.RadioOps) void {
    if (state.join) |*attempt| attempt.stop();
    state.join = null;
    state.pending = null;
    state.wanted = null;
    state.numbering.clear();
    state.tx_numbering = .{};
    // A different cell's distance and interference have nothing to do
    // with this one's.
    state.speed.forget();
    ops.answerFor(nic, null);
    dev_mod.deliverLink(nic, .{});
}

/// Carry out what the join asked for.
fn act(what: join_mod.Action) void {
    const it = radio() orelse return;
    switch (what) {
        .none => {},
        .send => |length| {
            state.sent_joining +|= 1;
            const response = if (state.join) |attempt| attempt.response else null;
            // Whether the queue took it, which is not whether the far
            // end heard it: what retires a key is the cell speaking under
            // it, not this answer.
            const gone = it.nic.ops.transmit(it.nic, state.frame[0..length]);
            if (response) |id| {
                if (state.join) |*attempt| attempt.sent(id, gone);
            }
        },
        .traffic => |length| {
            const attempt = state.join orelse return;
            const response = attempt.response orelse return;
            const key = attempt.responseKey();
            const gone = sendWithKey(it.nic, state.frame[0..length], key);
            if (state.join) |*current| current.sent(response, gone);
        },
        // The network was heard here, so the radio stops sweeping and
        // stays long enough for the exchange that follows.
        .tune => |channel| {
            const attempt = state.join orelse return;
            const allowed = state.plan.allows(channel.number) and
                (state.held == null or state.held.? == channel.number) and attempt.channelAllowed() and
                attempt.bss.?.channel == channel.number;
            const on = allowed and it.ops.tune(it.nic, channel);
            if (on) {
                state.next_hop_at = sys.clockMicros() + DWELL_MICROS;
                // The cell is known now, so the hardware is told to answer
                // for it before anything is said to it. A frame that is
                // not acknowledged is one the far end sends again and then
                // stops sending, which reads exactly like a cell that
                // never replied.
                it.ops.answerFor(it.nic, .{ .bssid = attempt.bssid() });
            }
            // A radio that did not move is still wherever it was, and the
            // next frame of the exchange would go out on the wrong
            // channel. The join is told, and gives up rather than talking
            // to nobody.
            if (state.join) |*current| {
                const after = current.tuned(on);
                if (after != .none) state.pending = after;
            }
        },
        .joined => |won| settle(it.nic, it.ops, won),
        .failed => |why| {
            if (state.join) |attempt| {
                state.failed_in = attempt.failed_in;
                state.stopped = switch (why) {
                    .unsupported => .unsupported,
                    .no_key => .needs_password,
                    .unprotected => .unprotected,
                    .untuned => .untuned,
                    .disconnected, .silence => .disconnected,
                    .refused => .refused,
                    .bad_key => .wrong_password,
                    .unverified => .unverified,
                    .unsent => .unsent,
                    // Nothing answered. Which step it was on says whether
                    // the network was ever there to answer.
                    .timed_out => if (attempt.failed_in == .seeking) .not_found else .no_answer,
                };
            }
            log.begin(it.nic.name, .warn);
            out.text("could not join \"");
            out.text(wantedName());
            out.text("\": ");
            out.text(why.spell());
            out.text(" while ");
            out.text(std.enums.tagName(join_mod.State, state.failed_in) orelse "somewhere");
            // What the cell said when it ended it, and to whom. A cell
            // that put this station out by name and one that cleared the
            // room are the same word with different meanings.
            if (state.join) |attempt| {
                if (attempt.farewell_reason) |reason| {
                    out.text(", giving reason ");
                    out.decimal(@intFromEnum(reason));
                    out.text(lib.mac.spellIfGroup(attempt.farewell_destination));
                }
            }
            out.text("; ");
            out.decimal(state.heard_joining);
            out.text(" frames heard while it was trying, ");
            out.decimal(state.heard_for_us);
            out.text(" addressed to this station, ");
            out.decimal(state.heard_auth);
            out.text(" of them authentications; it asked to send ");
            out.decimal(state.sent_joining);
            if (state.last_auth) |answer| {
                out.text(". The last authentication meant for it said sequence ");
                out.decimal(answer.sequence);
                out.text(", status ");
                out.decimal(answer.status);
                out.text(if (answer.from_cell) ", from the cell it is joining" else ", from some other cell");
                out.text(", and reached it while ");
                out.text(std.enums.tagName(join_mod.State, answer.state_then) orelse "somewhere");
            } else {
                out.text(". No authentication was addressed to it");
            }
            if (it.ops.tuned(it.nic)) |on| {
                out.text(", on channel ");
                out.decimal(on.number);
            }
            if (state.join) |attempt| {
                if (attempt.bss) |bss| {
                    out.text(", where the network is on ");
                    out.decimal(bss.channel);
                }
            }
            log.end();
            // Nothing answered, so the next thing worth knowing is
            // whether anything was actually said.
            if (it.ops.sayUnanswered) |ask| ask(it.nic);
            // And the radio stops answering for a cell it did not get
            // into, or has been put out of, which it was told to answer
            // for in order to try.
            it.ops.answerFor(it.nic, null);
            // Whatever was carried over it is not being carried now. Said
            // here as well as when a radio is told to leave, because an
            // association can end without anybody here asking.
            dev_mod.deliverLink(it.nic, .{});
            state.numbering.clear();
            state.tx_numbering = .{};
            state.join = null;
            // Kept, and tried again: a network out of earshot now may be
            // in earshot shortly, and nobody should have to ask twice.
            state.retry_at = sys.clockMicros() + RETRY_MICROS;
        },
    }
}

/// Joined: answer for the cell, and say the carrier is up.
fn settle(nic: *dev_mod.NicDev, ops: dev_mod.RadioOps, won: join_mod.Joined) void {
    ops.answerFor(nic, .{ .bssid = won.bssid, .association = won.aid });
    // A new association numbers from the start, both ways, and the cell
    // has not shown it holds anything yet.
    state.tx_numbering = .{};
    state.numbering.clear();

    // What the cell said it can hear. One that named no rates is taken to
    // hear everything this station can say, and the account corrects that
    // soon enough. Something is always offered: a cell with no rates at
    // all is one nothing can be sent to.
    var offered = lib.wifi.Rates.all();
    var short_preamble = false;
    if (state.join) |attempt| {
        if (attempt.bss) |bss| {
            if (bss.rates.slice().len != 0) offered = bss.rates;
            short_preamble = bss.capability.short_preamble;
        }
    }
    state.speed.offer(offered, short_preamble);

    // What the carrier is is the driver's to say, and it says the same
    // thing to whatever asks it later.
    dev_mod.deliverLink(nic, nic.ops.link(nic));

    log.begin(nic.name, .key);
    out.text("joined \"");
    out.text(wantedName());
    out.text("\" on ");
    out.text(&lib.mac.text(won.bssid));
    log.end();
}

/// Re-measure what drifts, and re-fit the receiver to the room.
///
/// On its own cadence rather than the sweep's, because it is owed whether
/// or not the radio is moving: a station that has joined a network sits on
/// one channel for hours, and calibration that stopped when it found the
/// network is calibration it spends the whole connection without.
fn maintain(now: u64) void {
    if (now < state.next_upkeep_at) return;
    state.next_upkeep_at = now + UPKEEP_MICROS;

    const it = radio() orelse return;
    // The short calibration every period, the long one on its own cadence.
    const long = now >= state.next_long_cal_at;
    if (long) state.next_long_cal_at = now + LONG_CAL_MICROS;
    it.ops.calibrate(it.nic, long);
    // What the period's failures came to. Judged over this length because
    // it is long enough for a count to mean something and short enough to
    // follow a room that changes.
    it.ops.adapt(it.nic);
}

/// Move to the next channel the plan allows.
fn hop() void {
    // Before anything that can return early: this is what says the dwell
    // is not over, and a pass that leaves it in the past is a loop that
    // never waits.
    const now = sys.clockMicros();
    state.next_hop_at = now + DWELL_MICROS;

    const it = radio() orelse return;

    // As long as a sweep would have taken, whether one was made or not: a
    // radio held on one channel has heard as much of that channel by now
    // as a sweeping one has heard of the band.
    state.hops += 1;
    if (state.hops == wifi.ghz2_channels.len) {
        if (it.ops.sayIfUnheard) |ask| ask(it.nic);
    }

    // Told where to listen, so there is nowhere to move to.
    if (state.held != null) return;

    var index = state.channel_index;
    for (0..wifi.ghz2_channels.len) |_| {
        index = (index + 1) % wifi.ghz2_channels.len;
        if (state.plan.allows(wifi.ghz2_channels[index])) break;
    }
    if (it.ops.tune(it.nic, .{ .number = wifi.ghz2_channels[index] })) state.channel_index = index;
}

/// A frame from the radio. Beacons and probe responses become the scan's
/// account; a network heard again is refreshed, a new one is said.
fn heard(nic: *dev_mod.NicDev, frame: []const u8, signal: wifi.Signal, rate: ?wifi.Legacy) void {
    _ = rate;
    // The join sees every frame: the beacons that tell it where its
    // network is, and the replies that carry the exchange forward.
    if (state.join) |*attempt| {
        if (!sweeping(attempt.*)) {
            state.heard_joining +|= 1;
            if (lib.ieee80211.Header.parse(frame)) |head| {
                if (lib.mac.eql(head.addr1, nic.mac)) {
                    state.heard_for_us +|= 1;
                    if (mlme.Auth.parse(frame)) |answer| {
                        state.last_auth = .{
                            .sequence = answer.sequence,
                            .status = @intFromEnum(answer.status),
                            .from_cell = lib.mac.eql(head.bssid(), attempt.bssid()),
                            .state_then = attempt.state,
                        };
                    }
                }
            }
            // Counted before anything decides whether to accept it: an
            // answer that arrived and was turned down is a different
            // fault from one that never came.
            if (mlme.Auth.parse(frame) != null) state.heard_auth +|= 1;
        }
        const what = attempt.heard(frame, signal, sys.clockMicros(), &state.frame);
        switch (what) {
            .none => {},
            // A reply goes out where it was decided. Two frames of one
            // walk can each ask for one, and a single slot kept for later
            // would hold only the second: the first would be built and
            // never sent, while whatever it staged was taken up on the
            // strength of the other going out.
            .send, .traffic => act(what),
            // The rest wait for the loop: tuning resets the radio
            // underneath the driver's walk of its receive ring, and
            // finishing or abandoning a join takes the interface with it.
            else => state.pending = what,
        }
    }

    // Traffic, once there is a cell to have traffic with.
    carry(nic, frame);

    // No transcript: only the network being joined is compared with what
    // its third message repeats, and the join keeps that one itself.
    const seen = mlme.Bss.fromBeacon(frame, signal, null) orelse return;

    for (state.networks.mutable()) |*known| {
        if (lib.mac.eql(known.bssid, seen.bssid)) {
            // A signal wanders by a decibel or two while nothing moves, and
            // a list that reorders on that is a list whose rows swap under
            // the pointer. Only a change worth seeing disturbs the order.
            const moved = @abs(@as(i16, known.signal.dbm) - @as(i16, seen.signal.dbm));
            if (moved > SIGNAL_SLACK) state.ordered = false;
            known.* = seen;
            return;
        }
    }
    state.ordered = false;
    state.networks.append(seen) catch {
        if (!state.full_said) {
            log.note(nic.name, "more networks than the list holds; the rest are not kept");
            state.full_said = true;
        }
        return;
    };
    say(nic, seen);
    if (dev_mod.changed) |tell| tell();
}

fn say(nic: *dev_mod.NicDev, bss: mlme.Bss) void {
    log.begin(nic.name, .key);
    out.text("heard \"");
    out.text(bss.ssid.slice());
    out.text("\" on channel ");
    out.decimal(bss.channel);
    out.text(", ");
    out.signed(bss.signal.dbm);
    out.text(" dBm, ");
    out.text(bss.security.spell());
    log.end();
}
