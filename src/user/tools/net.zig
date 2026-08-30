//! net: the network interfaces, read from `netd` and steered through cfgd.
//!
//! Reads ask the service; writes go through the settings store, whose watch
//! event is how the service learns. The tool never asks netd to remember
//! anything, which is what keeps one writer of configuration in the system.
//!
//!   net                          the interfaces, their links and addresses
//!   net wired up | down          enable or disable the role, persistently
//!   net wired dhcp               clear the static claim; DHCP asks
//!   net wired static 192.168.178.50/24 [gw 192.168.178.1] [dns a[,b]]
//!   net -p [address]             one ARP probe beneath the stack
//!   net -s                       ask again after each probe reply

const lib = @import("lib");
const net = @import("proto").net;
const settings = @import("proto").settings;
const ink = @import("ulib").ink;
const out = @import("ulib").out;
const str = @import("ulib").str;

const DEFAULT_ASK = 0x0A000202; // 10.0.2.2

pub fn run(args: []const []const u8) void {
    if (args.len > 0 and str.eql(args[0], "wired")) {
        configure(args[1..]);
        return;
    }

    // `-p` and then an optional dotted address, or nothing for the read.
    var probe = false;
    var ask: u32 = DEFAULT_ASK;
    for (args) |arg| {
        if (str.eql(arg, "-p")) {
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

/// The write verbs: each one is a settings change, and the service applies
/// it when the watch fires. Said plainly when the store is volatile, the
/// same way `cfg` says it.
fn configure(args: []const []const u8) void {
    if (args.len == 0) {
        say("net: wired needs a verb: up, down, dhcp, static\n");
        return;
    }

    var cfg = settings.load("net");

    if (str.eql(args[0], "up")) {
        cfg.wired_enabled = true;
    } else if (str.eql(args[0], "down")) {
        cfg.wired_enabled = false;
    } else if (str.eql(args[0], "dhcp")) {
        cfg.wired_enabled = true;
        cfg.wired_address = .{};
        cfg.wired_gateway = .{};
    } else if (str.eql(args[0], "static")) {
        if (args.len < 2) {
            say("net: static needs an address like 192.168.178.50/24\n");
            return;
        }
        const claim = lib.ipv4.Cidr.parse(args[1]) orelse {
            say("net: that is not an address/prefix\n");
            return;
        };
        cfg.wired_enabled = true;
        cfg.wired_address = claim;

        var at: usize = 2;
        while (at < args.len) : (at += 2) {
            if (at + 1 >= args.len) {
                say("net: a keyword without its value\n");
                return;
            }
            if (str.eql(args[at], "gw")) {
                cfg.wired_gateway = lib.ipv4.Maybe.parse(args[at + 1]) orelse {
                    say("net: that gateway is not an address\n");
                    return;
                };
            } else if (str.eql(args[at], "dns")) {
                cfg.wired_dns = lib.ipv4.Pair.parse(args[at + 1]) orelse {
                    say("net: dns takes one address, or two with a comma\n");
                    return;
                };
            } else {
                say("net: only gw and dns follow a static address\n");
                return;
            }
        }
    } else {
        say("net: the verbs are up, down, dhcp and static\n");
        return;
    }

    settings.save("net", cfg) catch {
        say("net: the settings store would not take it\n");
        return;
    };
    say("configured; the service applies it now\n");
}

fn printInterface(iface: *const net.Iface) void {
    const driver_name = driverOf(iface.driver);
    ink.write(.key, driver_name);

    out.text(if (iface.up != 0) "  up    " else "  down  ");
    if (iface.up != 0) {
        out.decimal(iface.mbps);
        out.text(" Mbit ");
        out.text(switch (iface.duplex) {
            .half => "half",
            .full => "full",
            else => "unknown",
        });
    } else {
        out.text("       ");
    }
    out.text("  mac ");
    const spelled = lib.mac.text(iface.mac);
    out.text(&spelled);
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

fn driverOf(name: [8]u8) []const u8 {
    var end = name.len;
    while (end > 0 and (name[end - 1] == 0 or name[end - 1] == ' ')) end -= 1;
    return name[0..end];
}

fn say(text: []const u8) void {
    out.text(text);
    out.flush();
}
