//! The station: what a radio is doing above its driver.
//!
//! The driver tunes and hears; this file decides where to tune and what
//! the hearing amounts to. In this pass that is a scan: the radio walks the
//! channels its regulatory plan allows, dwells long enough on each to hear
//! a beacon, and keeps an account of every network it hears, said once to
//! the log as it appears. Joining a network, with the authentication,
//! association and key exchange that takes, is what the next pass owes;
//! the frames for it are already in `lib.mlme` and `lib.wpa2`.
//!
//! The radio is reached through the device contract's hooks and one
//! driver, because there is one radio in the machine this is for. A second
//! radio driver plugs into the same three hooks.

const ar5212 = @import("ar5212.zig");
const dev_mod = @import("dev.zig");
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const settings = @import("proto").settings;
const sys = @import("sys");

const mlme = lib.mlme;
const wifi = lib.wifi;

/// How many networks the scan keeps. A home hears a dozen; a flat in a
/// city hears more, and the rest are heard again on the next pass.
const MAX_NETWORKS = 32;

/// How long the radio listens on a channel: two beacon intervals, so a
/// network beaconing at the usual hundred milliseconds is heard.
const DWELL_MICROS: u64 = 200_000;

const State = struct {
    radio: ?*dev_mod.NicDev = null,
    plan: wifi.Regulatory = .conservative,
    networks: lib.Bounded(mlme.Bss, MAX_NETWORKS) = .{},
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
    full_said: bool = false,
};

var state: State = .{};

/// Take the radio's hooks. Called once, before any driver starts.
pub fn init() void {
    dev_mod.radio_rx = heard;
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
    const now = sys.clockMicros();
    return if (state.next_hop_at > now) state.next_hop_at - now else 0;
}

/// Run whatever the station owes: a hop when the dwell is over.
pub fn tick() void {
    if (state.radio == null) return;
    if (sys.clockMicros() < state.next_hop_at) return;
    hop();
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
    state.plan = role.regdomain;
    state.held = if (role.channel == 0) null else role.channel;
    if (state.held) |number| _ = ar5212.tune(.{ .number = number });
    ar5212.setSelfPower(role.txpower.resolve(role.regdomain).half_dbm);
}

/// Move to the next channel the plan allows, taking the noise floor the
/// last dwell measured on the way.
fn hop() void {
    ar5212.calibrate(true);
    state.next_hop_at = sys.clockMicros() + DWELL_MICROS;

    // As long as a sweep would have taken, whether one was made or not: a
    // radio held on one channel has heard as much of that channel by now
    // as a sweeping one has heard of the band.
    state.hops += 1;
    if (state.hops == wifi.ghz2_channels.len) {
        if (state.radio) |nic| ar5212.sayIfUnheard(nic);
    }

    // Told where to listen, so there is nowhere to move to.
    if (state.held != null) return;

    var index = state.channel_index;
    for (0..wifi.ghz2_channels.len) |_| {
        index = (index + 1) % wifi.ghz2_channels.len;
        if (state.plan.allows(wifi.ghz2_channels[index])) break;
    }
    if (ar5212.tune(.{ .number = wifi.ghz2_channels[index] })) state.channel_index = index;
}

/// A frame from the radio. Beacons and probe responses become the scan's
/// account; a network heard again is refreshed, a new one is said.
fn heard(nic: *dev_mod.NicDev, frame: []const u8, signal: wifi.Signal, rate: ?wifi.Legacy) void {
    _ = rate;
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
