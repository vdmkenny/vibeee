//! net: the network interfaces, up the chain from `netd`.
//!
//! A read with one lever: `net` shows the interfaces, their link and how
//! much moved; `net -p [address]` sends one hand-built ARP request per
//! interface ("who has this address"), the whole of outbound traffic until
//! the stack lands, and the next `net` shows who answered. The default ask
//! is QEMU's slirp gateway.

const lib = @import("lib");
const net = @import("proto").net;
const ink = @import("ulib").ink;
const out = @import("ulib").out;
const str = @import("ulib").str;

const DEFAULT_ASK = 0x0A000202; // 10.0.2.2

pub fn run(args: []const []const u8) void {
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
        out.text(switch (err) {
            error.NoService => "net: the network service is not answering\n",
            else => "net: the service would not say\n",
        });
        out.flush();
        return;
    };

    if (count.count == 0) {
        out.text("no network interfaces\n");
        out.flush();
        return;
    }

    var i: u32 = 0;
    while (i < count.count) : (i += 1) {
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
        printInterface(&reply.iface);
    }
    out.flush();
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

fn driverOf(name: [8]u8) []const u8 {
    var end = name.len;
    while (end > 0 and (name[end - 1] == 0 or name[end - 1] == ' ')) end -= 1;
    return name[0..end];
}