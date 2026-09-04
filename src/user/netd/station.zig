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

/// How long to leave a network alone after failing to join it. Long
/// enough not to hammer an access point that refused, short enough that
/// one which was merely out of earshot is picked up again without anybody
/// asking twice.
const RETRY_MICROS: u64 = 10_000_000;

const State = struct {
    radio: ?*dev_mod.NicDev = null,
    plan: wifi.Regulatory = .conservative,
    networks: lib.Bounded(mlme.Bss, MAX_NETWORKS) = .{},
    /// Which of the band's channels the radio is on.
    channel_index: usize = 0,
    /// The network configuration last named, so being unable to join it is
    /// said once rather than at every pass of the settings.
    asked: wifi.Ssid = .{},
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
    /// Which step of the exchange it was on when it gave up.
    failed_in: join_mod.State = .idle,
    /// What a heard frame asked for, carried out from the loop rather
    /// than where it was decided. Deciding happens inside the driver's
    /// walk of its receive ring, and tuning resets the radio underneath
    /// that walk, which leaves the ring and the hardware disagreeing
    /// about where it is.
    pending: ?join_mod.Action = null,
    /// The keys the join earned, where it earned any, and the number the
    /// next sealed frame carries. A number is never used twice under one
    /// key, so it only counts up and starts again with a new key.
    keys: ?lib.wpa2.Handshake.Keys = null,
    pn: lib.wpa2.Ccmp.Pn = 0,
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
    dev_mod.radio_config = configure;
}

/// The networks the scan has heard, newest last.
pub fn networks() []const mlme.Bss {
    return state.networks.slice();
}

/// One of them, by index, or null past the last.
pub fn network(index: usize) ?mlme.Bss {
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

    const attempt = state.join orelse {
        // Nothing in hand: the sweep, or the moment a failed join is due
        // to be tried again, whichever comes first.
        if (state.wanted == null) return hop_in;
        const retry_in: u64 = if (state.retry_at > now) state.retry_at - now else 0;
        return @min(hop_in, retry_in);
    };
    const owed = owedIn(attempt, now);

    // A join still looking rides the sweep, so whichever comes first. One
    // that has found its network owns the radio and the sweep is not
    // happening, so its deadline is not one to wake for; a join waiting on
    // nothing at all asks for no wake, and the traffic wakes it instead.
    if (sweeping(attempt)) return if (owed) |soon| @min(hop_in, soon) else hop_in;
    return owed;
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
        // Nothing owed: not started, still listening, finished either way.
        .idle, .seeking, .joined, .failed => null,
    };
}

/// Run whatever the station owes: a hop when the dwell is over.
pub fn tick() void {
    const now = sys.clockMicros();

    // Whatever a frame asked for, now that the driver is no longer in the
    // middle of handing it over.
    if (state.pending) |what| {
        state.pending = null;
        act(what);
    }

    // A join that failed comes round again on its own. The next attempt
    // is dated first and unconditionally: a deadline left in the past is
    // a loop that never waits.
    if (state.join == null and state.wanted != null and now >= state.retry_at) {
        state.retry_at = now + RETRY_MICROS;
        if (radio()) |it| seek(it.nic, it.ops, state.wanted.?);
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

/// One ordinary frame, dressed as the cell expects and handed to the
/// radio.
fn send(nic: *dev_mod.NicDev, frame: []const u8) bool {
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
    const keys = state.keys orelse return radio_ops.transmitAt(nic, built, series);

    // Otherwise sealed under this station's own key, with a number that
    // is never used twice.
    const head = lib.ieee80211.Header.parse(built) orelse return false;
    state.pn +%= 1;
    const sealed = lib.wpa2.Ccmp.protect(
        keys.tk,
        head,
        state.pn,
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
    if (cell() == null) return;
    const head = lib.ieee80211.Header.parse(frame) orelse return;

    var plain = frame;
    if (head.control.protected) {
        const keys = state.keys orelse return;
        // A frame spoken to the room is sealed with the key the room
        // shares; one spoken to this station, with this station's own.
        const key = if (lib.mac.isGroup(head.addr1)) keys.gtk.key else keys.tk;
        if (head.len >= state.opened.len) return;

        @memcpy(state.opened[0..head.len], frame[0..head.len]);
        const got = lib.wpa2.Ccmp.unprotect(key, frame, state.opened[head.len..]) orelse return;
        plain = state.opened[0 .. head.len + got.len];
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

/// The slot's plan and ceiling, whenever the configuration says.
fn configure(nic: *dev_mod.NicDev, role: settings.NetSlot) void {
    if (nic.class != .wifi) return;
    const ops = nic.ops.radio orelse return;

    const held = if (role.channel == 0) null else role.channel;
    const moved = !std.meta.eql(state.plan, role.regdomain) or state.held != held;
    state.plan = role.regdomain;
    state.held = held;
    if (held) |number| _ = ops.tune(nic, .{ .number = number });

    // A network named is one to be on; named nothing is one to leave.
    // Acted on when the name changes, so a settings pass that says the
    // same thing again does not restart a join that is already running.
    if (!std.mem.eql(u8, state.asked.slice(), role.ssid.slice())) {
        state.asked = role.ssid;
        leave(nic, ops);
        if (role.ssid.len != 0) seek(nic, ops, role);
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

/// A nonce for the key exchange, drawn from what the radio has heard.
/// Where it has heard too little, or has nothing to offer, the clock
/// stands in: weaker, and better than refusing to join over it.
fn nonce(nic: *dev_mod.NicDev, ops: dev_mod.RadioOps) lib.wpa2.Nonce {
    var value: lib.wpa2.Nonce = @splat(0);
    if (ops.draw) |from| {
        if (from(nic, &value)) return value;
    }
    log.say(nic.name, .dim, "not enough heard to draw on; the key exchange nonce comes from the clock");
    lib.entropy.fromClock(sys.clockMicros(), &nic.mac, &value);
    return value;
}

/// Start looking for a network and joining it.
fn seek(nic: *dev_mod.NicDev, ops: dev_mod.RadioOps, role: settings.NetSlot) void {
    state.wanted = role;
    state.heard_joining = 0;
    state.heard_for_us = 0;
    state.heard_auth = 0;
    state.sent_joining = 0;
    state.last_auth = null;
    var attempt = join_mod.Join{ .station = nic.mac };
    attempt.wants(role.ssid, role.psk, nonce(nic, ops));
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
    state.keys = null;
    state.wanted = null;
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
            _ = it.nic.ops.transmit(it.nic, state.frame[0..length]);
        },
        // The network was heard here, so the radio stops sweeping and
        // stays long enough for the exchange that follows.
        .tune => |channel| {
            if (!it.ops.tune(it.nic, channel)) return;
            state.next_hop_at = sys.clockMicros() + DWELL_MICROS;
            // The cell is known now, so the hardware is told to answer for
            // it before anything is said to it. A frame that is not
            // acknowledged is one the far end sends again and then stops
            // sending, which reads exactly like a cell that never replied.
            if (state.join) |attempt| it.ops.answerFor(it.nic, .{ .bssid = attempt.bssid() });
        },
        .joined => |won| settle(it.nic, it.ops, won),
        .failed => |why| {
            if (state.join) |attempt| state.failed_in = attempt.failed_in;
            log.begin(it.nic.name, .warn);
            out.text("could not join \"");
            out.text(state.asked.slice());
            out.text("\": ");
            out.text(why.spell());
            out.text(" while ");
            out.text(std.enums.tagName(join_mod.State, state.failed_in) orelse "somewhere");
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
            // into, which it was told to answer for in order to try.
            it.ops.answerFor(it.nic, null);
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
    state.keys = won.keys;
    state.pn = 0;

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
    out.text(state.asked.slice());
    out.text("\" on ");
    out.text(&lib.mac.text(won.bssid));
    log.end();
}

/// Move to the next channel the plan allows, taking the noise floor the
/// last dwell measured on the way.
fn hop() void {
    // Before anything that can return early: this is what says the dwell
    // is not over, and a pass that leaves it in the past is a loop that
    // never waits.
    state.next_hop_at = sys.clockMicros() + DWELL_MICROS;

    const it = radio() orelse return;
    it.ops.calibrate(it.nic, true);
    // What the last dwell's failures came to. Asked here because a dwell
    // is the period the radio is judged over: long enough for a count to
    // mean something, short enough to follow a room that changes.
    it.ops.adapt(it.nic);

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
        // Held, not carried out: see `pending`. Where two frames of one
        // walk both ask for something, the later one stands, which is the
        // one an exchange is waiting on.
        const what = attempt.heard(frame, signal, sys.clockMicros(), &state.frame);
        if (what != .none) state.pending = what;
    }

    // Traffic, once there is a cell to have traffic with.
    carry(nic, frame);

    const seen = mlme.Bss.fromBeacon(frame, signal) orelse return;

    for (state.networks.mutable()) |*known| {
        if (lib.mac.eql(known.bssid, seen.bssid)) {
            known.* = seen;
            return;
        }
    }
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
