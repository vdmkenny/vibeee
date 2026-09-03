//! net: the network interfaces, read from `netd` and steered through cfgd.
//!
//! Reads ask the service; writes go through the settings store, whose watch
//! event is how the service learns. The tool never asks netd to remember
//! anything, which is what keeps one writer of configuration in the system.
//!
//! An interface is named the way the listing prints it ("atl2", "e1000.1"),
//! by class ("ether", "wifi"), or by bus location ("03:00.0"). Naming one
//! edits the configuration slot that already matches it, or claims a free
//! slot when none does.
//!
//!   net                          the interfaces, their links and addresses
//!   net <iface> up | down        enable or disable it, persistently
//!   net <iface> dhcp             clear the static claim; DHCP asks
//!   net <iface> static 192.0.2.7/24 [gw 192.0.2.1] [dns a[,b]]
//!   net -p [address]             one ARP probe beneath the stack

const std = @import("std");
const lib = @import("lib");
const net = @import("proto").net;
const settings = @import("proto").settings;
const ink = @import("ulib").ink;
const out = @import("ulib").out;

const DEFAULT_ASK = 0x0A000202; // 10.0.2.2

pub fn run(args: []const []const u8) void {
    if (args.len > 0 and std.mem.eql(u8, args[0], "scan")) {
        scan();
        return;
    }

    // A first word that is not a flag names an interface to configure.
    if (args.len > 0 and args[0].len > 0 and args[0][0] != '-') {
        const matcher = lib.ifmatch.Match.parse(args[0]) orelse {
            say("net: that names no interface, class or location\n");
            return;
        };
        configure(args[0], matcher, args[1..]);
        return;
    }

    // `-p` and then an optional dotted address, or nothing for the read.
    var probe = false;
    var ask: u32 = DEFAULT_ASK;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-p")) {
            probe = true;
        } else if (lib.ipv4.parse(arg)) |addr| {
            ask = addr;
        }
    }

    var count = net.Rep{};
    net.call(.count, 0, 0, &count) catch |err| {
        say(switch (err) {
            error.NoService => "net: the network service is not answering\n",
            else => "net: the service would not say\n",
        });
        return;
    };

    if (count.body.count == 0) {
        say("no network interfaces\n");
        return;
    }

    var i: u32 = 0;
    while (i < count.body.count) : (i += 1) {
        if (probe) {
            var sent = net.Rep{};
            net.call(.arp_probe, i, ask, &sent) catch {
                continue;
            };
            var spelled_field: [15]u8 = @splat(0);
            out.text("probe sent: who has ");
            out.text(lib.ipv4.text(ask, &spelled_field));
            out.text("\n");
            continue;
        }

        var reply = net.Rep{};
        net.call(.status, i, 0, &reply) catch |err| {
            if (err == error.End) break;
            continue;
        };
        printInterface(&reply.body.iface);

        var addressed = net.Rep{};
        if (net.call(.address, i, 0, &addressed)) |_| {
            printAddress(&addressed.body.address);
        } else |_| {}
    }
    out.flush();
}

/// The write verbs: each one is a settings change, applied to the slot that
/// matches the named interface, and the service applies it when the watch
/// fires.
fn configure(spelled: []const u8, matcher: lib.ifmatch.Match, args: []const []const u8) void {
    if (args.len == 0) {
        say("net: an interface needs a verb: up, down, dhcp, static, join, forget\n");
        return;
    }

    var cfg = settings.load("net");

    var wants: [settings.NET_SLOTS]settings.NetSlot = undefined;
    inline for (0..settings.NET_SLOTS) |i| wants[i] = settings.netSlot(cfg, i);

    const chosen = resolveSlot(spelled, matcher, &wants) orelse return;
    var want = &wants[chosen];

    if (std.mem.eql(u8, args[0], "up")) {
        want.enabled = true;
    } else if (std.mem.eql(u8, args[0], "down")) {
        want.enabled = false;
    } else if (std.mem.eql(u8, args[0], "dhcp")) {
        want.askDhcp();
    } else if (std.mem.eql(u8, args[0], "static")) {
        if (args.len < 2) {
            say("net: static needs an address like 192.0.2.7/24\n");
            return;
        }
        const claim = lib.ipv4.Cidr.parse(args[1]) orelse {
            say("net: that is not an address/prefix\n");
            return;
        };
        var gateway = lib.ipv4.Maybe{};
        var dns = lib.ipv4.Pair{};
        var at: usize = 2;
        while (at < args.len) : (at += 2) {
            if (at + 1 >= args.len) {
                say("net: a keyword without its value\n");
                return;
            }
            if (std.mem.eql(u8, args[at], "gw")) {
                gateway = lib.ipv4.Maybe.parse(args[at + 1]) orelse {
                    say("net: that gateway is not an address\n");
                    return;
                };
            } else if (std.mem.eql(u8, args[at], "dns")) {
                dns = lib.ipv4.Pair.parse(args[at + 1]) orelse {
                    say("net: dns takes one address, or two with a comma\n");
                    return;
                };
            } else {
                say("net: only gw and dns follow a static address\n");
                return;
            }
        }
        want.claimStatic(claim, gateway, dns);
    } else if (std.mem.eql(u8, args[0], "join")) {
        // The name, and the key unless the network is open.
        if (args.len < 2) {
            say("net: join needs the network's name, and its key unless it is open\n");
            return;
        }
        const ssid = lib.wifi.Ssid.of(args[1]) orelse {
            say("net: a network name is up to 32 characters\n");
            return;
        };
        const psk: lib.wifi.Psk = if (args.len >= 3) (lib.wifi.Psk.parse(args[2]) orelse {
            say("net: a key is a passphrase of 8 to 63 characters, or 64 hex digits\n");
            return;
        }) else .none;
        want.join(ssid, psk);
    } else if (std.mem.eql(u8, args[0], "forget")) {
        want.forget();
    } else {
        say("net: the verbs are up, down, dhcp, static, join and forget\n");
        return;
    }

    inline for (0..settings.NET_SLOTS) |i| {
        if (i == chosen) settings.setNetSlot(&cfg, i, wants[i]);
    }

    settings.save("net", cfg) catch {
        say("net: the settings store would not take it\n");
        return;
    };
    say("configured; the service applies it now\n");
}

/// Which configuration slot speaks for the named interface: the one whose
/// matcher already says so, or a free slot claimed with this matcher. Null
/// after its own message when neither exists.
fn resolveSlot(
    spelled: []const u8,
    matcher: lib.ifmatch.Match,
    wants: *[settings.NET_SLOTS]settings.NetSlot,
) ?usize {
    for (wants, 0..) |want, i| {
        if (want.match.eql(matcher)) return i;
    }

    // A new claim on a driver or a place should name hardware that exists;
    // a class claim may provision for hardware still in a drawer. With the
    // service away the check cannot run, and configuration stays editable.
    switch (matcher) {
        .driver, .location => {
            if (interfaceExists(matcher)) |there| {
                if (!there) {
                    say("net: no interface answers to ");
                    say(spelled);
                    say("; `net` lists them\n");
                    return null;
                }
            } else {
                say("recording unchecked: the service is not answering\n");
            }
        },
        else => {},
    }

    for (wants, 0..) |want, i| {
        if (want.match == .none) {
            wants[i].match = matcher;
            return i;
        }
    }

    say("net: every configuration slot is taken; `cfg net` shows them, and\n" ++
        "an emptied match (cfg net if0_match \"\") frees its slot\n");
    return null;
}

/// Whether the service lists an interface this matcher covers, or null when
/// it is not answering.
fn interfaceExists(matcher: lib.ifmatch.Match) ?bool {
    var i: u32 = 0;
    while (true) : (i += 1) {
        var reply = net.Rep{};
        net.call(.status, i, 0, &reply) catch |err| switch (err) {
            error.NoService => return null,
            else => return false,
        };
        const iface = &reply.body.iface;
        const covered = switch (matcher) {
            .driver => |name| name.is(labelOf(&iface.driver)),
            .location => |at| @as(u16, @bitCast(at)) == iface.location,
            else => false,
        };
        if (covered) return true;
    }
}

/// Every network the radio has heard, one per line, or why there are none.
fn scan() void {
    var has_radio = false;
    var i: usize = 0;
    while (net.interfaceAt(i)) |iface| : (i += 1) {
        if (iface.kind == .radio) has_radio = true;
    }
    if (!has_radio) {
        say(if (net.interfaceCount() == 0) "net: the network service is not answering\n" else "no radio in this machine\n");
        return;
    }

    var index: usize = 0;
    while (net.networkAt(index)) |network| : (index += 1) {
        printNetwork(&network);
    }
    if (index == 0) say("no networks heard yet; the radio is still listening\n");
    out.flush();
}

fn printNetwork(network: *const net.Network) void {
    out.text("  ");
    ink.write(.key, network.name());
    out.text("  channel ");
    out.decimal(network.channel);
    out.text("  ");
    if (network.dbm < 0) {
        out.text("-");
        out.decimal(@intCast(-@as(i32, network.dbm)));
    } else {
        out.decimal(@intCast(network.dbm));
    }
    out.text(" dBm ");
    out.text(network.strength());
    out.text("  ");
    out.text(network.security.spell());
    out.byte('\n');
}

fn printInterface(iface: *const net.Iface) void {
    ink.write(.key, labelOf(&iface.driver));

    out.text(if (iface.up != 0) "  up    " else "  down  ");
    if (iface.up != 0) {
        out.decimal(iface.mbps);
        out.text(" Mbit ");
        out.text(switch (iface.duplex) {
            .half => "half",
            .full => "full",
            else => "unknown",
        });
    } else if (iface.kind == .radio and iface.channel != 0) {
        out.text("channel ");
        out.decimal(iface.channel);
    } else {
        out.text("       ");
    }
    out.text("  mac ");
    const spelled = lib.mac.text(iface.mac);
    out.text(&spelled);
    out.text("  at ");
    var place_field: [8]u8 = undefined;
    out.text(lib.pci.spell(@bitCast(iface.location), &place_field));
    out.byte('\n');

    out.text("    rx ");
    out.decimal(iface.rx_pkts);
    out.text(" packets, ");
    out.decimal(iface.rx_bytes);
    out.text(" bytes;  tx ");
    out.decimal(iface.tx_pkts);
    out.text(" packets, ");
    out.decimal(iface.tx_bytes);
    out.text(" bytes\n");

    if (iface.arp_replies != 0 and iface.peer_ip != 0) {
        var peer_field: [15]u8 = @splat(0);
        const peer = lib.ipv4.text(iface.peer_ip, &peer_field);
        const peer_mac = lib.mac.text(iface.peer_mac);
        out.text("    peer   ");
        out.text(peer);
        out.text(" at ");
        out.text(&peer_mac);
        if (lib.ipv4.isPrivate(iface.peer_ip)) out.text(" (private)");
        out.text(", answering for ");
        out.decimal(iface.arp_replies);
        out.text(" asks\n");
    }
}

fn printAddress(info: *const net.AddressInfo) void {
    if (info.addr == 0) return;
    var field: [15]u8 = @splat(0);
    out.text("    addr   ");
    out.text(lib.ipv4.text(info.addr, &field));
    out.byte('/');
    out.decimal(info.prefix);
    if (info.gateway != 0) {
        out.text(" via ");
        out.text(lib.ipv4.text(info.gateway, &field));
    }
    switch (info.source) {
        .static_claim => out.text(", static"),
        .dhcp => {
            out.text(", dhcp lease ");
            out.decimal(info.lease_remaining_s);
            out.text("s left");
        },
        .none => {},
    }
    out.byte('\n');
}

fn labelOf(name: *const [12]u8) []const u8 {
    var end = name.len;
    while (end > 0 and (name[end - 1] == 0 or name[end - 1] == ' ')) end -= 1;
    return name[0..end];
}

fn say(text: []const u8) void {
    out.text(text);
    out.flush();
}
