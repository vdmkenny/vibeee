//! net: the network interfaces, up the chain from `netd`.
//!
//! A read, for now: which interfaces exist, their link, and how much moved.
//! Configuration follows the stack.

const lib = @import("lib");
const net = @import("proto").net;
const ink = @import("ulib").ink;
const out = @import("ulib").out;

pub fn run(_: []const []const u8) void {
    var count = net.Rep{};
    net.call(.count, 0, &count) catch |err| {
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
        var reply = net.Rep{};
        net.call(.status, i, &reply) catch |err| {
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
}

fn driverOf(name: [8]u8) []const u8 {
    var end = name.len;
    while (end > 0 and (name[end - 1] == 0 or name[end - 1] == ' ')) end -= 1;
    return name[0..end];
}

/// A MAC address as hex pairs, the way every interface listing spells one.
fn macText(mac: [6]u8) [17]u8 {
    const hexdigits = "0123456789abcdef";
    var text: [17]u8 = undefined;
    for (mac, 0..) |byte, i| {
        text[i * 3] = hexdigits[byte >> 4];
        text[i * 3 + 1] = hexdigits[byte & 0xF];
        if (i < 5) text[i * 3 + 2] = ':';
    }
    return text;
}
