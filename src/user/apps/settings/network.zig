//! The Network pane: every interface the service lists, wired or wireless,
//! with what the settings say it should do, and for a radio the networks it
//! has heard and the one it is told to join.
//!
//! Every control here has the same verb in the `net` command and the same
//! row in the bar's menu, because all three edit one thing: the slot of the
//! `net` domain bound to the interface, through `ulib.netconfig`. The pane
//! reads the service for what is and the store for what is wanted, and
//! writes only the store; the service watches it and applies the change.

const eui = @import("eui");
const lib = @import("lib");
const netconfig = @import("ulib").netconfig;
const proto = @import("proto");
const std = @import("std");

const app = @import("../settings.zig");
const ipv4 = lib.ipv4;
const net = proto.net;
const str = lib.str;
const text = eui.text;
const theme = eui.theme;
const wifi = lib.wifi;

const ctx = &proto.app.ctx;

/// How many heard networks the pane shows. The service keeps more; a list
/// longer than this is a list nobody scrolls to the end of.
const MAX_SHOWN = 16;

var model: netconfig.Model = .{};
/// The service's event: an address, a link or a network heard. The frame
/// sleeps on it, and the pane reads again when it fires.
var wake: ?u32 = null;
var networks: [MAX_SHOWN]net.Network = undefined;
var network_count: usize = 0;
var table_state: eui.table.State = .{ .striped = true };
var prompt: eui.prompt.Prompt = .{};
/// What a note under the wireless group says, when something was refused.
var note: []const u8 = "";

/// The three lines of a static claim, one set per interface, edited in
/// place and applied on the button.
const Line = text.Field(48);

/// How an interface gets its address.
const Mode = enum(u1) { dhcp, static };

const Claim = struct {
    address: Line = .{},
    gateway: Line = .{},
    dns: Line = .{},
    /// Whether the fields hold what the slot holds, or something being typed.
    filled: bool = false,
    /// Which way the choice stands: what the slot says, until somebody picks
    /// the other, and then what they picked until it is applied. Without
    /// this the choice snaps back the moment it is made, because a claim
    /// nobody has typed yet is not in the slot to be read.
    picked: ?Mode = null,
};

var claims: [netconfig.MAX_IFACES]Claim = @splat(.{});

/// What a question on the sheet is about.
const Pending = union(enum) {
    none,
    /// The key for the network at this index in the list.
    key: usize,
};

var pending: Pending = .none;

const JOIN_CHOICES = [_]eui.prompt.Choice{
    .{ .label = "Join", .letter = 'j' },
    .{ .label = "Cancel", .letter = 'c' },
};

pub fn load() void {
    wake = net.watch() catch null;
    model = netconfig.Model.load();
    for (&claims) |*claim| {
        claim.address.init(.{ .hint = "192.0.2.50/24" });
        claim.gateway.init(.{ .hint = "gateway, or none" });
        claim.dns.init(.{ .hint = "dns, or none" });
        claim.filled = false;
        claim.picked = null;
    }
    readNetworks();
}

/// The event the frame sleeps on, when the service gave one.
pub fn wakeEvent() ?u32 {
    return wake;
}

/// The service said something changed: read it all again. Always a fresh
/// pass, since a signal that moved is a row that changed.
pub fn changed() bool {
    model.refresh();
    readNetworks();
    return true;
}

fn readNetworks() void {
    network_count = 0;
    while (network_count < MAX_SHOWN) : (network_count += 1) {
        networks[network_count] = net.networkAt(network_count) orelse break;
    }
}

pub fn promptOpen() bool {
    return prompt.isOpen();
}

pub fn key(code: proto.app.KeyCode, mods: proto.app.Modifiers) bool {
    _ = mods;
    if (!prompt.isOpen()) return false;
    if (eui.prompt.key(&prompt, code)) |choice| {
        answer(choice);
        return true;
    }
    return !prompt.takesText();
}

pub fn typed(codepoint: u32) bool {
    if (!prompt.isOpen() or prompt.takesText()) return false;
    if (eui.prompt.letter(&prompt, codepoint)) |choice| answer(choice);
    return true;
}

/// The sheet, over the pane, when a question stands.
pub fn runPrompt(area: eui.Rect) void {
    if (!prompt.isOpen()) return;
    if (eui.prompt.run(ctx, area, &prompt)) |choice| answer(choice);
}

// ---------------------------------------------------------------------------
// The pane
// ---------------------------------------------------------------------------

pub fn draw(pane: eui.Rect) i32 {
    const t = theme.current();
    var y = pane.y;

    y = app.group(&y, .{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, "Interfaces");
    if (model.count == 0) {
        ctx.labelDim(.{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, if (model.serving) "No interfaces" else "The network service is not answering");
        y += t.control_height;
    }
    for (0..model.count) |i| {
        y = drawInterface(pane, y, i);
        if (i + 1 < model.count) y = app.rule(pane, y);
    }

    if (model.radio()) |radio| {
        y += t.padding;
        y = app.group(&y, .{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, "Wireless");
        y = drawWireless(pane, y, radio);
    }
    return y + t.padding;
}

/// One interface: its name and state, whether it is enabled, its address,
/// and how it gets one.
fn drawInterface(pane: eui.Rect, from: i32, index: usize) i32 {
    const t = theme.current();
    var y = from;
    const iface = &model.ifaces[index];
    const address = &model.addresses[index];

    // The name and what the link is doing, with the switch beside it.
    var state_buf: [40]u8 = undefined;
    var state = str.Builder{ .buf = &state_buf };
    if (iface.up != 0) {
        state.text("up, ");
        state.number(iface.mbps);
        state.text(" Mbit");
    } else if (iface.kind == .radio and iface.channel != 0) {
        state.text("scanning channel ");
        state.number(iface.channel);
    } else {
        state.text("down");
    }
    const toggle_w = t.control_height * 4;
    ctx.rowText(.{ .x = pane.x, .y = y, .w = pane.w - toggle_w, .h = t.control_height }, net.nameOf(iface), t.text);
    // The switch reports a press, not a state: what it should become is the
    // opposite of what it is.
    const enabled = if (model.slotOf(index)) |slot| slot.enabled else false;
    if (ctx.toggle(.{ .x = pane.right() - toggle_w, .y = y, .w = toggle_w, .h = t.control_height }, "Enabled", enabled)) {
        if (model.setEnabled(index, !enabled)) commit();
    }
    y += t.control_height;
    ctx.labelDim(.{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, state.done());
    y += t.control_height;

    // The address the stack holds, and where it came from.
    var addr_buf: [64]u8 = undefined;
    var line = str.Builder{ .buf = &addr_buf };
    if (address.addr != 0) {
        var field: [15]u8 = undefined;
        line.text(ipv4.text(address.addr, &field));
        line.byte('/');
        line.number(address.prefix);
        if (address.gateway != 0) {
            line.text(" via ");
            line.text(ipv4.text(address.gateway, &field));
        }
        line.text(switch (address.source) {
            .static_claim => ", static",
            .dhcp => ", from DHCP",
            .none => "",
        });
    } else {
        line.text(if (iface.up != 0) "no address yet" else "no address");
    }
    ctx.labelDim(.{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, line.done());
    y += t.control_height;

    // DHCP or a claim: what the slot says, or what was picked and not yet
    // applied. DHCP applies at once, since there is nothing to type; a claim
    // waits for the address to be written and the button pressed.
    const claimed = if (model.slotOf(index)) |slot| slot.address.isSet() else false;
    const stored: Mode = if (claimed) .static else .dhcp;
    const mode = claims[index].picked orelse stored;
    const picked = ctx.choiceOf(.{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, mode, &.{ "DHCP", "Static address" });
    y += t.control_height;
    if (picked != mode) {
        claims[index].picked = picked;
        switch (picked) {
            .dhcp => if (model.setDhcp(index)) commit(),
            .static => {
                fill(index);
                claims[index].filled = true;
            },
        }
        ctx.damage();
    }
    if (mode == .static or picked == .static) {
        if (!claims[index].filled) fill(index);
        y = drawClaim(pane, y, index);
    }
    return y;
}

/// Put the slot's claim into the fields.
fn fill(index: usize) void {
    const claim = &claims[index];
    var buf: [48]u8 = undefined;
    var spelled = str.Builder{ .buf = &buf };
    if (model.slotOf(index)) |slot| {
        slot.address.spell(&spelled);
        claim.address.set(spelled.done());
        spelled = .{ .buf = &buf };
        slot.gateway.spell(&spelled);
        claim.gateway.set(spelled.done());
        spelled = .{ .buf = &buf };
        slot.dns.spell(&spelled);
        claim.dns.set(spelled.done());
    } else {
        claim.address.set("");
        claim.gateway.set("");
        claim.dns.set("");
    }
    claim.filled = true;
}

/// The three lines of a claim and the button that applies them.
fn drawClaim(pane: eui.Rect, from: i32, index: usize) i32 {
    const t = theme.current();
    const claim = &claims[index];
    var y = from;
    const rows = [_]struct { label: []const u8, line: *Line }{
        .{ .label = "Address", .line = &claim.address },
        .{ .label = "Gateway", .line = &claim.gateway },
        .{ .label = "DNS", .line = &claim.dns },
    };
    var applied = false;
    for (rows) |row| {
        if (ctx.fieldRow(.{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, row.label, row.line)) applied = true;
        y += t.control_height + t.gap;
    }
    const button_w = t.control_height * 3;
    if (ctx.button(.{ .x = pane.right() - button_w, .y = y, .w = button_w, .h = t.control_height }, "Apply")) applied = true;
    if (applied) applyClaim(index);
    return y + t.control_height + t.padding;
}

fn applyClaim(index: usize) void {
    const claim = &claims[index];
    const address = ipv4.Cidr.parse(claim.address.slice()) orelse {
        note = "The address is written a.b.c.d/nn.";
        ctx.damage();
        return;
    };
    const gateway_text = claim.gateway.slice();
    const gateway: ipv4.Maybe = if (gateway_text.len == 0) .{} else ipv4.Maybe.parse(gateway_text) orelse {
        note = "The gateway is not an address.";
        ctx.damage();
        return;
    };
    const dns_text = claim.dns.slice();
    const dns: ipv4.Pair = if (dns_text.len == 0) .{} else ipv4.Pair.parse(dns_text) orelse {
        note = "DNS takes one address, or two with a comma.";
        ctx.damage();
        return;
    };
    note = "";
    // Applied: the slot holds the claim now, so the choice reads it from
    // there rather than from what was picked.
    if (model.setStatic(index, address, gateway, dns)) {
        claims[index].picked = null;
        commit();
    }
}

/// The networks heard, the one chosen, and the buttons that join and forget.
fn drawWireless(pane: eui.Rect, from: i32, radio: usize) i32 {
    const t = theme.current();
    var y = from;

    // What the radio is told to join, or that it is told nothing.
    var status_buf: [64]u8 = undefined;
    var status = str.Builder{ .buf = &status_buf };
    const joined: ?wifi.Ssid = if (model.slotOf(radio)) |slot| (if (slot.ssid.len > 0) slot.ssid else null) else null;
    if (joined) |ssid| {
        status.text("Joining \"");
        status.text(ssid.slice());
        status.text("\"");
    } else {
        status.text("No network chosen");
    }
    ctx.labelDim(.{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, status.done());
    y += t.control_height;

    // The table of what was heard.
    const columns = [_]eui.table.Column{
        .{ .title = "Network", .width = 80, .flex = true },
        .{ .title = "Channel", .width = 56, .right = true },
        .{ .title = "Signal", .width = 90 },
        .{ .title = "Security", .width = 64 },
    };
    var rows: [MAX_SHOWN]eui.table.Row = undefined;
    var cells: [MAX_SHOWN][2][16]u8 = undefined;
    for (0..network_count) |i| {
        const network = &networks[i];
        var channel = str.Builder{ .buf = &cells[i][0] };
        channel.number(network.channel);
        var signal = str.Builder{ .buf = &cells[i][1] };
        signal.signed(network.dbm);
        signal.text(" dBm ");
        signal.text(network.strength());
        rows[i] = .{
            .cells = .{ network.name(), channel.done(), signal.done(), network.security.spell(), "", "" },
            .marked = if (joined) |ssid| std.mem.eql(u8, ssid.slice(), network.name()) else false,
            .icon = .wifi,
        };
    }
    const shown = @max(network_count, 1);
    const table_h = eui.table.rowHeight() * @as(i32, @intCast(shown + 1)) + 2;
    const activated = ctx.table(.{ .x = pane.x, .y = y, .w = pane.w, .h = table_h }, &table_state, &columns, rows[0..network_count]);
    y += table_h + t.gap;
    if (network_count == 0) {
        ctx.labelDim(.{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, "Nothing heard yet; the radio is listening.");
        y += t.control_height;
    }
    if (activated) |row| askToJoin(radio, row);

    // Join what is selected; forget what was joined.
    const button_w = t.control_height * 3;
    var x = pane.right();
    if (network_count > 0) {
        x -= button_w;
        if (ctx.button(.{ .x = x, .y = y, .w = button_w, .h = t.control_height }, "Join")) askToJoin(radio, table_state.selected);
        x -= t.gap;
    }
    if (joined != null) {
        x -= button_w;
        if (ctx.button(.{ .x = x, .y = y, .w = button_w, .h = t.control_height }, "Forget")) {
            if (model.forget(radio)) commit();
        }
    }
    if (note.len > 0) {
        ctx.labelDim(.{ .x = pane.x, .y = y, .w = @max(x - pane.x - t.gap, 0), .h = t.control_height }, note);
    }
    return y + t.control_height;
}

/// Join the network at a row: at once when it is open, after a question
/// for its key when it is protected, and not at all when it is something
/// this system cannot join.
fn askToJoin(radio: usize, row: usize) void {
    if (row >= network_count) return;
    const network = &networks[row];
    const ssid = wifi.Ssid.of(network.name()) orelse return;

    if (!network.security.joinable()) {
        note = "That network's protection is not one this system can join.";
        ctx.damage();
        return;
    }
    if (network.security == .open) {
        note = "";
        if (model.join(radio, ssid, .none)) commit();
        return;
    }

    var question_buf: [64]u8 = undefined;
    var question = str.Builder{ .buf = &question_buf };
    question.text("Key for \"");
    question.text(network.name());
    question.text("\"");
    prompt.askText(question.done(), &JOIN_CHOICES, .{ .hint = "8 to 63 characters, or 64 hex digits", .secret = true });
    pending = .{ .key = row };
    ctx.damage();
}

/// The answer to whatever stood on the sheet.
fn answer(choice: usize) void {
    const asked = pending;
    var typed_buf: [eui.prompt.TEXT_MAX]u8 = undefined;
    const raw = prompt.line();
    @memcpy(typed_buf[0..raw.len], raw);
    const line = typed_buf[0..raw.len];
    prompt.dismiss();
    pending = .none;
    ctx.damage();

    switch (asked) {
        .none => {},
        .key => |row| {
            if (choice != 0 or row >= network_count) return;
            const radio = model.radio() orelse return;
            const ssid = wifi.Ssid.of(networks[row].name()) orelse return;
            const psk = wifi.Psk.parse(line) orelse {
                note = "A key is a passphrase of 8 to 63 characters, or 64 hex digits.";
                return;
            };
            if (psk == .none) {
                note = "That network needs a key.";
                return;
            }
            note = "";
            if (model.join(radio, ssid, psk)) commit();
        },
    }
}

/// Hand the change to the store; the service applies it.
fn commit() void {
    model.save() catch {
        note = "The settings store would not take it.";
        ctx.damage();
        return;
    };
    ctx.damage();
}
