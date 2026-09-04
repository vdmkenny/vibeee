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
/// Which interface the settings below the list belong to.
var iface_table: eui.table.State = .{ .striped = true, .headings = false };

/// How many interface rows are shown before the list scrolls. Almost every
/// machine has two; the rest fit without pushing the networks off the pane.
const VISIBLE_IFACES = 4;
/// The columns of the row that carries the chosen interface's settings.
const NAME_W = 96;
const MODE_W = 132;
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
    .{ .label = "Join", .letter = 'j', .weight = .strong },
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
/// The service's event, as the one-element set the wait takes. Empty before
/// the service has been reached.
pub fn wakeEvents() []const u32 {
    if (wake) |handle| {
        one = handle;
        return (&one)[0..1];
    }
    return &.{};
}

var one: u32 = 0;

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
        return y + t.control_height + t.padding;
    }

    y = drawInterfaces(pane, y);
    y += t.padding;
    y = drawChosen(pane, y);

    y += t.padding;
    y = app.group(&y, .{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, "Wireless");
    if (model.radio()) |radio| {
        y = drawWireless(pane, y, radio);
    } else {
        // Said rather than left out. A section that simply is not there
        // reads as a pane that failed to draw it, and somebody looking for
        // wireless wants to know it is the computer and not the window.
        ctx.labelDim(.{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, "No wireless adapter in this computer.");
        y += t.control_height;
    }
    return y + t.padding;
}

/// Every interface on one row each: what it is called, what it is doing,
/// the address it holds, and whether it is on.
///
/// A table without its headings, which is what a list of two or three
/// self-evident columns wants, with the switch drawn into the end of each
/// row the table hands back.
fn drawInterfaces(pane: eui.Rect, from: i32) i32 {
    const t = theme.current();
    const sw = eui.widget.switchWidth() + t.padding * 2;

    const columns = [_]eui.table.Column{
        .{ .title = "Interface", .width = 92 },
        .{ .title = "Status", .width = 152 },
        .{ .title = "Address", .width = 96, .flex = true },
    };

    var rows: [netconfig.MAX_IFACES]eui.table.Row = undefined;
    var cells: [netconfig.MAX_IFACES][2][64]u8 = undefined;
    for (0..model.count) |i| {
        const iface = &model.ifaces[i];
        rows[i] = .{
            .cells = .{ net.nameOf(iface), stateOf(i, &cells[i][0]), addressOf(i, &cells[i][1]), "", "", "" },
            .icon = if (iface.kind == .radio) .wifi else .ethernet,
        };
    }
    const listed = rows[0..model.count];

    const shown: i32 = @intCast(@min(model.count, VISIBLE_IFACES));
    const height = eui.table.rowHeight() * shown + 2;
    // The switch stands at the end of each row, so the last column stops
    // short of it rather than running underneath.
    const area = eui.Rect{ .x = pane.x, .y = from, .w = pane.w - sw, .h = height };
    _ = ctx.table(area, &iface_table, &columns, listed);

    for (0..model.count) |i| {
        const line = eui.table.rowRect(area, &iface_table, i, model.count) orelse continue;
        const enabled = if (model.slotOf(i)) |slot| slot.enabled else false;
        const at = eui.Rect{ .x = area.right() + t.padding, .y = line.y, .w = sw, .h = line.h };
        if (ctx.onOff(at, enabled) != enabled) {
            if (model.setEnabled(i, !enabled)) commit();
        }
    }
    return from + height;
}

/// What the chosen interface is set to: on or off, and where its address
/// comes from. One row for every interface would be four rows of controls
/// nobody is looking at; this is the one being looked at.
fn drawChosen(pane: eui.Rect, from: i32) i32 {
    const t = theme.current();
    const index = @min(iface_table.selected, model.count - 1);
    var y = from;

    const row = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height };
    var cells: [2]eui.Rect = undefined;
    // The switch's cell carries the gap after it: `place` sets cells side by
    // side, and a control that touches the next one reads as part of it.
    const laid = eui.row.place(row, .left, &.{ NAME_W, MODE_W }, &cells);

    ctx.rowText(laid[0], net.nameOf(&model.ifaces[index]), theme.current().text);

    const claimed = if (model.slotOf(index)) |slot| slot.address.isSet() else false;
    const stored: Mode = if (claimed) .static else .dhcp;
    const mode = claims[index].picked orelse stored;
    const picked = ctx.choiceOf(laid[1], mode, &.{ "DHCP", "Static" });
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

/// What the link is doing, in the words the rest of the system uses.
fn stateOf(index: usize, buf: *[64]u8) []const u8 {
    const iface = &model.ifaces[index];
    var line = str.Builder{ .buf = buf };
    if (iface.up != 0) {
        line.text("Connected, ");
        line.number(iface.mbps);
        line.text(" Mbit/s");
    } else {
        line.text("Not connected");
    }
    return line.done();
}

/// The address the stack holds, and where it came from.
fn addressOf(index: usize, buf: *[64]u8) []const u8 {
    const address = &model.addresses[index];
    if (address.addr == 0) return "No IP address";

    var line = str.Builder{ .buf = buf };
    var field: [15]u8 = undefined;
    line.text(ipv4.text(address.addr, &field));
    line.text(switch (address.source) {
        .static_claim => ", static",
        .dhcp => ", DHCP",
        .none => "",
    });
    return line.done();
}

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
    // What the form is for, so it carries the weight Save and Join do.
    if (ctx.buttonAs(.{ .x = pane.right() - button_w, .y = y, .w = button_w, .h = t.control_height }, "Apply", .strong)) applied = true;
    if (applied) applyClaim(index);
    return y + t.control_height + t.padding;
}

fn applyClaim(index: usize) void {
    const claim = &claims[index];
    const address = ipv4.Cidr.parse(claim.address.slice()) orelse {
        note = "The address must be written a.b.c.d/nn.";
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
    const iface = &model.ifaces[radio];
    if (joined) |ssid| {
        status.text(iface.joining.spellNaming());
        if (iface.joining.named()) status.text(ssid.slice());
        // Why it stopped, rather than only that it is not connected: what
        // somebody wants to know is why what they asked for did not happen.
        if (iface.stopped != .none) {
            status.text(": ");
            status.text(iface.stopped.spell());
        }
    } else {
        status.text("Not connected");
    }
    ctx.labelDim(.{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, status.done());
    y += t.control_height;

    // The table of what was heard.
    const columns = [_]eui.table.Column{
        // The name takes what is left, and the rest take what they need:
        // a signal reading is as wide as a signal reading gets, and a name
        // cut short is a name you can still recognise.
        .{ .title = "Network", .width = 80, .flex = true },
        .{ .title = "Ch", .width = 34, .right = true },
        .{ .title = "Signal", .width = 128 },
        .{ .title = "Security", .width = 60 },
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
            .marked = switch (pending) {
                // While the bar is asking, the row it is asking about is
                // the one to look at.
                .key => |row| row == i,
                .none => if (joined) |ssid| std.mem.eql(u8, ssid.slice(), network.name()) else false,
            },
            .icon = eui.icon.signal(network.bars),
        };
    }
    const shown = @max(network_count, 1);
    const table_h = eui.table.rowHeight() * @as(i32, @intCast(shown + 1)) + 2;
    const activated = ctx.table(.{ .x = pane.x, .y = y, .w = pane.w, .h = table_h }, &table_state, &columns, rows[0..network_count]);
    y += table_h + t.gap;
    if (network_count == 0) {
        ctx.labelDim(.{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, "No networks found yet.");
        y += t.control_height;
    }
    if (activated) |row| askToJoin(radio, row);

    // Join what is selected; forget what was joined.
    const button_w = t.control_height * 3;
    var x = pane.right();
    if (network_count > 0) {
        x -= button_w;
        if (ctx.buttonAs(.{ .x = x, .y = y, .w = button_w, .h = t.control_height }, "Join", .strong)) askToJoin(radio, table_state.selected);
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
        note = "This system cannot connect to that kind of protected network.";
        ctx.damage();
        return;
    }
    if (network.security == .open) {
        note = "";
        if (model.join(radio, ssid, .none)) commit();
        return;
    }

    // The name is not in the question. An SSID runs to thirty-two
    // characters, the question is held to half the bar, and a long name
    // would leave the field too narrow to type a password into. Which
    // network is being asked about is said by the list, where the row
    // stays marked while the bar stands.
    prompt.askText("Password", &JOIN_CHOICES, .{ .hint = "8 to 63 characters, or 64 hex digits", .secret = true });
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
                note = "The password is 8 to 63 characters, or 64 hex digits.";
                return;
            };
            if (psk == .none) {
                note = "That network needs a password.";
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
        note = "The setting could not be saved.";
        ctx.damage();
        return;
    };
    ctx.damage();
}
