//! netd: the network interface service.
//!
//! One process, one thread, one event loop, per design/08-network.md §1: a
//! 630 MHz core buys no parallelism from threads and pays locks. Everything
//! here waits on `wait_many`: the service channel and the interrupt lines of
//! the adapters it was handed. Nothing polls.
//!
//! Started by the device manager when an ethernet device matches; the /svc
//! name doubles as the claim, so a second instance finds the name taken and
//! steps aside rather than fight the first for the hardware.
//!
//! The drivers themselves live beside this file, one module each, behind one
//! interface (`dev.zig`). What is not here yet is the stack: for now an
//! interface is probed, opened, its link reported and its traffic counted.
//! That is the part QEMU can test, and it is what `net` shows.

const dev = @import("dev.zig");
const e1000 = @import("e1000.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const proto = @import("proto").net;
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
    if (count == 0) {
        log.warn("netd", "no adapter matched a driver");
    } else {
        for (ifaces[0..count]) |*iface| {
            if (attach(iface)) log.note("netd", "driving the hardware");
        }
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
            log.note("netd", "the adapter is ours to drive");
            count += 1;
        }
    }
}

/// Map, open and interrupt-wire one interface.
fn attach(iface: *dev.NicDev) bool {
    const line = pci.interruptLine(iface.location);
    if (line != 0 and line != 0xFF) {
        iface.irq = sys.irqAttach(line) catch {
            log.warn("netd", "the interrupt line refused to attach");
            return false;
        };
    }

    if (!iface.ops.open(iface.location, iface)) {
        log.warn("netd", "the adapter did not open");
        if (iface.irq != 0) _ = sys.close(iface.irq);
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
        return false;
    }
    return true;
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
        if (iface.irq != 0) {
            sources[source_count] = iface.irq;
            source_count += 1;
        }
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

    const request: *const proto.Req = @alignCast(@ptrCast(bytes.ptr));

    if (request.tag == .count) {
        reply.count = @intCast(count);
        return .ok;
    }

    if (request.index >= count) return .end;

    const iface = &ifaces[request.index];
    reply.iface = .{
        .up = @intFromBool(iface.state.up),
        .duplex = iface.state.duplex,
        .mbps = iface.state.mbps,
        .mac = iface.mac,
        .rx_pkts = @truncate(iface.stats.rx_pkts),
        .rx_bytes = @truncate(iface.stats.rx_bytes),
        .tx_pkts = @truncate(iface.stats.tx_pkts),
        .tx_bytes = @truncate(iface.stats.tx_bytes),
    };
    @memcpy(reply.iface.driver[0..@min(iface.name.len, 8)], iface.name[0..@min(iface.name.len, 8)]);

    // Fresh link state: the adapter may have seen a change whose line
    // arrived between asks, and this is a read of it either way.
    iface.state = iface.ops.link(iface);
    reply.iface.up = @intFromBool(iface.state.up);

    return .ok;
}

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

