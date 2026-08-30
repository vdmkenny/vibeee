//! netd: the network interface service.
//!
//! One process, one thread, one event loop, per design/08-network.md §1: a
//! 630 MHz core buys no parallelism from threads and pays locks. Everything
//! here waits on `wait_many`: the service channel and the interrupt lines of
//! the adapters it was handed. Nothing polls.
//!
//! Started by init once the platform service has published its name, which
//! only happens with the firmware fully settled. The /svc name doubles as
//! the claim, so a second instance finds the name taken and steps aside
//! rather than fight the first for the hardware.
//!
//! The drivers themselves live beside this file, one module each, behind one
//! interface (`dev.zig`). What is not here yet is the stack: for now an
//! interface is probed, opened, its link reported and its traffic counted.
//! That is the part QEMU can test, and it is what `net` shows.

const atl2 = @import("atl2.zig");
const rtl8139 = @import("rtl8139.zig");
const dev = @import("dev.zig");
const e1000 = @import("e1000.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const proto = @import("proto").net;
const proto_platform = @import("proto").platform;
const std = @import("std");
const sys = @import("sys");
const str = @import("lib").str;
const lib = @import("lib");

/// The drivers this build knows, each with the ids that recognise its card.
/// Adding a driver is one line here and a module beside; startup does not
/// change.
const Driver = struct {
    name: []const u8,
    vendor: u16,
    device: u16,
    ops: dev.NicOps,
};

const DRIVERS = [_]Driver{
    .{ .name = e1000.name, .vendor = e1000.vendor, .device = e1000.device_id, .ops = e1000.ops },
    .{ .name = atl2.name, .vendor = atl2.vendor, .device = atl2.device_id, .ops = atl2.ops },
    .{ .name = rtl8139.name, .vendor = rtl8139.vendor, .device = rtl8139.device_id, .ops = rtl8139.ops },
};

/// How many interfaces a machine of this class can have behind one service.
const MAX_IFACES = 4;

var ifaces: [MAX_IFACES]dev.NicDev = @splat(.{ .name = "", .ops = undefined, .location = .{ .bus = 0, .device = 0, .function = 0 } });
var count: usize = 0;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ call netdMain
        \\ hlt
    );
}

export fn netdMain() callconv(.c) noreturn {
    // The claim, before the hardware: a second instance started for a second
    // adapter must stand down cleanly, not duel the first.
    const channel = sys.svcRegister(proto.SERVICE);
    if (channel < 0) {
        log.note("netd", "already serving; letting this instance stand down");
        sys.exit(0);
    }

    probe();
    const discovered = count;
    count = 0;
    for (0..discovered) |i| {
        var candidate = ifaces[i];
        if (!attach(&candidate)) continue;
        ifaces[count] = candidate;
        count += 1;
        log.note("netd", "driving the hardware");
    }

    if (count == 0) {
        log.warn("netd", "no adapter matched a driver");
    }

    serve(@intCast(channel));
}

/// Walk the bus once, from the kernel's own table, and take every device a
/// driver here knows. The kernel has already bound its built-ins; anything
/// left undriven is offered to userspace, which is exactly this walk.
fn probe() void {
    var buf: [2048]u8 = @splat(0);
    const table = sys.sysinfo("pci", buf[0..]);
    if (table <= 0) return;
    const text = buf[0..@intCast(table)];

    var lines = str.lines(text);
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var fields = str.fields(line);
        const at = fields.next() orelse continue;
        const vendor = str.fromHex(fields.next() orelse continue);
        const device = str.fromHex(fields.next() orelse continue);
        _ = str.fromHex(fields.next() orelse continue); // class
        _ = str.fromHex(fields.next() orelse continue); // subclass
        _ = fields.next() orelse continue; // what the kernel bound
        const state = fields.next() orelse continue;

        // Two drivers on one device is worse than the wrong one of them.
        if (str.eql(str.trim(state), "driven")) continue;
        if (count == MAX_IFACES) return;

        for (DRIVERS) |driver| {
            if (vendor != driver.vendor or device != driver.device) continue;
            const loc = pci.parse(at) orelse continue;

            ifaces[count] = .{
                .name = driver.name,
                .ops = driver.ops,
                .location = loc,
            };
            const iface_bus = loc.bus;
            const iface_dev = loc.device;
            const iface_fn = loc.function;
            log.begin("netd", .key);
            out.text(driver.name);
            out.text(" at ");
            out.hex(iface_bus, 2);
            out.byte(':');
            out.hex(iface_dev, 2);
            out.byte('.');
            out.decimal(iface_fn);
            out.text(" is ours to drive");
            log.end();
            count += 1;
        }
    }
}

/// Map, open and interrupt-wire one interface.
fn attach(iface: *dev.NicDev) bool {
    if (sys.claimDevice(iface.location) < 0) {
        log.warn("netd", "the adapter is already claimed");
        return false;
    }
    var keep_claim = false;
    defer if (!keep_claim) {
        _ = sys.releaseDevice(iface.location);
    };

    const line = routedLine(iface);

    // Lines are shared on this machine's wiring, and the kernel hands a
    // line to one holder. One process holding it once is enough: every
    // driver on the line gets the wake, and each reads its own ISR and
    // says "not mine" with no other cost. So a line already taken here is
    // shared, not refused.
    if (line) |gsi| {
        iface.irq_gsi = gsi;
        var shared = false;
        for (ifaces[0..count]) |other| {
            if (other.irq != 0 and other.irq_gsi == gsi) {
                iface.irq = other.irq;
                shared = true;
                break;
            }
        }
        if (!shared) {
            iface.irq = sys.irqAttach(gsi) catch {
                log.warn("netd", "the interrupt line refused to attach");
                return false;
            };
            iface.irq_owned = true;
            log.begin("netd", .dim);
            out.text("line ");
            out.decimal(gsi);
            out.text(" taken");
            log.end();
        }
    } else {
        // An adapter with no line still opens; it just never hears anything.
        // Worth a line of its own, because everything after looks like a
        // silent wire.
        log.warn("netd", "the firmware assigned no interrupt line");
    }

    if (!iface.ops.open(iface.location, iface)) {
        log.warn("netd", "the adapter did not open");
        releaseIrq(iface);
        return false;
    }

    // Walked by what the adapter said when it opened.
    log.begin(iface.name, .key);
    out.text("link ");
    sayLink(iface.state);
    out.text(", mac ");
    const spelled = lib.mac.text(iface.mac);
    out.text(&spelled);
    log.end();

    if (!iface.ops.start(iface)) {
        log.warn("netd", "the adapter did not start");
        iface.ops.stop(iface);
        releaseIrq(iface);
        return false;
    }

    keep_claim = true;
    return true;
}

fn releaseIrq(iface: *dev.NicDev) void {
    if (iface.irq_owned and iface.irq != 0) _ = sys.close(iface.irq);
    iface.irq = 0;
    iface.irq_gsi = null;
    iface.irq_owned = false;
}

/// Which line this adapter's interrupt arrives on.
///
/// The firmware's routing table is the answer for the interrupt model this
/// system runs; the number in configuration space answers for the mode it
/// does not. Where the platform service cannot say, the legacy number is
/// what remains, alive but possibly deaf.
fn routedLine(iface: *dev.NicDev) ?u32 {
    const pin = pci.interruptPin(iface.location).acpiIndex() orelse {
        log.warn("netd", "the adapter exposes no routable interrupt pin");
        return null;
    };
    var ask = proto_platform.RouteAsk{
        .pin = pin,
        .device = @truncate(iface.location.device),
    };
    if (pci.carrierOf(iface.location.bus)) |bridge| {
        ask.behind_bridge = true;
        ask.bridge_device = @truncate(bridge.device);
        ask.bridge_function = @truncate(bridge.function);
    }

    // The platform service owns the routing tables and comes up in parallel
    // with this one: the device manager spawns drivers as devices match,
    // while the firmware's own bring-up takes its hundreds of milliseconds.
    // Waited out rather than raced, the way init waits for a name; a real
    // refusal, as against an absent service, falls through at once.
    var waited: u32 = 0;
    while (waited < 2_000_000) : (waited += 20_000) {
        if (proto_platform.routePci(ask)) |gsi| {
            log.begin("netd", .dim);
            out.text("the firmware routes this interrupt to line ");
            out.decimal(gsi);
            log.end();
            return gsi;
        } else |err| {
            if (err != error.NoService) break;
            sys.sleepMicros(20_000);
        }
    }

    log.say("netd", .dim, "no routing table answer; using the legacy line");
    const legacy = pci.interruptLine(iface.location);
    return if (legacy == 0 or legacy == 0xFF) null else legacy;
}

// ---------------------------------------------------------------------------
// The event loop
// ---------------------------------------------------------------------------

fn serve(channel: u32) noreturn {
    // The channel plus one handle per interface's line. Fixed: the number of
    // interfaces is capped above, so the sources never need to grow.
    var sources: [MAX_IFACES + 1]u32 = undefined;
    var source_count: usize = 1;
    sources[0] = channel;
    for (ifaces[0..count]) |iface| {
        if (iface.irq == 0) continue;
        // One handle per line: shared lines are woken in one place, not
        // waited on twice for the same event.
        var already = false;
        for (sources[1..source_count]) |s| {
            if (s == iface.irq) {
                already = true;
                break;
            }
        }
        if (already) continue;
        sources[source_count] = iface.irq;
        source_count += 1;
    }

    while (true) {
        const woke = sys.waitMany(sources[0..source_count], sys.FOREVER);
        if (woke < 0) continue;

        const index = @as(usize, @intCast(woke));
        if (index < source_count) {
            const handle = sources[index];
            if (handle == channel) {
                drain(channel);
                continue;
            }
            // An interrupt line. Which interface it belongs to is the match
            // the attach made; the service runs its handler, then the ack.
            for (ifaces[0..count]) |*iface| {
                if (iface.irq == handle) {
                    iface.irq_count += 1;
                    iface.ops.irq(iface);
                }
            }
            _ = sys.irqAck(handle);
        }
    }
}

fn drain(channel: u32) void {
    while (true) {
        var message = sys.Message{};
        const request = sys.recv(channel, &message, sys.POLL) orelse return;

        var reply = proto.Rep{};
        reply.status = answer(&message, &reply);

        var out_msg = sys.Message{};
        @memcpy(out_msg.data[0..@sizeOf(proto.Rep)], std.mem.asBytes(&reply));
        out_msg.len = @sizeOf(proto.Rep);
        _ = sys.replyMsg(channel, request.token, &out_msg);
    }
}

fn answer(message: *const sys.Message, reply: *proto.Rep) proto.Status {
    const bytes = message.bytes();
    if (bytes.len < @sizeOf(proto.Req)) return .refused;

    const request: *const proto.Req = @ptrCast(@alignCast(bytes.ptr));

    if (request.tag == .count) {
        reply.count = @intCast(count);
        return .ok;
    }

    if (request.index >= count) return .end;

    const iface = &ifaces[request.index];

    // Fresh link state before anything uses it: what the adapter reports
    // and what its registers were told must agree.
    if (iface.ops.sync_link) |sync| {
        sync(iface);
    } else {
        iface.state = iface.ops.link(iface);
    }

    if (request.tag == .arp_probe) {
        // The whole of outbound traffic until the stack lands: one ARP
        // request, hand-built by the pure frame library, asking who holds
        // the target and told where to answer. The reply, when it comes,
        // proves the ring and the line from outside.
        if (!iface.state.up) return .refused;

        var frame: [lib.eth.FRAME]u8 = undefined;
        lib.eth.arpRequest(&frame, iface.mac, PROBE_SOURCE, request.param);
        return if (iface.ops.transmit(iface, &frame)) .ok else .refused;
    }

    reply.iface = .{
        .up = @intFromBool(iface.state.up),
        .duplex = iface.state.duplex,
        .mbps = iface.state.mbps,
        .mac = iface.mac,
        .rx_pkts = @truncate(iface.stats.rx_pkts),
        .rx_bytes = @truncate(iface.stats.rx_bytes),
        .tx_pkts = @truncate(iface.stats.tx_pkts),
        .tx_bytes = @truncate(iface.stats.tx_bytes),
        .arp_replies = @truncate(iface.stats.rx_arp),
    };
    @memcpy(reply.iface.driver[0..@min(iface.name.len, 8)], iface.name[0..@min(iface.name.len, 8)]);
    if (iface.peer) |peer| {
        reply.iface.peer_ip = peer.addr;
        reply.iface.peer_mac = peer.mac;
    }

    return .ok;
}

/// The probe's sender protocol address: none. An address probe carries a
/// zero sender per RFC 5227, which any host answers without an opinion on
/// subnets; a real source address waits for configuration to exist.
const PROBE_SOURCE: u32 = 0; // 0.0.0.0

// ---------------------------------------------------------------------------
// Small spelling helpers
// ---------------------------------------------------------------------------

fn sayLink(state: dev.Link) void {
    if (!state.up) {
        out.text("down");
        return;
    }
    out.decimal(state.mbps);
    out.text(" Mbit ");
    out.text(switch (state.duplex) {
        .half => "half",
        .full => "full",
        else => "unknown",
    });
    out.text(" duplex");
}
