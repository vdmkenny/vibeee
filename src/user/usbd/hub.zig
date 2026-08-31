//! A hub: more ports, on a port.
//!
//! What a hub does is what a controller's root ports do, one level down.
//! It reports which of its ports changed, and it is asked to power them,
//! reset them and say what speed the thing on them talks. So this driver
//! is the same shape as the port handling in a controller, expressed in
//! control transfers instead of registers, and what it finds is handed to
//! the same enumeration everything else goes through.
//!
//! Nothing polls. A hub has an interrupt endpoint that says nothing until
//! a port changes, and the controller watches it in hardware: a hub with
//! nothing being plugged into it costs no interrupts and no time.

const class = @import("class.zig");
const core = @import("core.zig");
const hc = @import("hc.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const sys = @import("sys");
const table = @import("ulib").table;
const usb = @import("lib").usb;

pub const name = "hub";

pub const CLASS = usb.Class.hub;

/// How many hubs at once. A chain longer than this is one the
/// specification does not allow either: five deep is the limit, and
/// nobody reaches it by accident.
pub const MAX_HUBS = 4;

/// The most ports one hub is driven with. Bigger hubs exist; their extra
/// ports are ignored rather than the hub being refused.
pub const MAX_PORTS = 8;

/// The status endpoint reports a bitmap: one bit per port, plus a bit for
/// the hub itself at the bottom.
const STATUS_BYTES: u8 = 2;

const Hub = struct {
    live: bool = false,
    address: u7 = 0,
    controller: u8 = 0,
    /// Where the hub itself sits, so a device on it can be told where it
    /// is in turn.
    route: usb.Route = .{},
    watch: u8 = 0,
    ops: hc.HcOps = undefined,
    zero: usb.Pipe = .{},
    ports: u8 = 0,
    power_on_ms: u16 = 100,
};

var hubs: [MAX_HUBS]Hub = @splat(.{});

pub const ops = class.ClassOps{ .attach = attach, .detach = detach, .woke = woke };
pub const driver = class.ClassDriver{ .name = name, .ops = ops };

pub fn all() []const Hub {
    return &hubs;
}

// ---------------------------------------------------------------------------
// Coming and going
// ---------------------------------------------------------------------------

fn attach(target: class.Target) bool {
    // A hub's interface says nothing but that it is one; what matters is
    // the class descriptor and the one endpoint underneath.
    const view = usb.interfaceFor(target.configuration, CLASS, target.signature.subclass, target.signature.protocol) orelse {
        log.warn(name, "the device carries no hub interface");
        return false;
    };
    const endpoint = view.find(.interrupt, .in) orelse {
        log.warn(name, "the hub has no endpoint to report changes on");
        return false;
    };

    var described: [usb.Hub.BYTES + 8]u8 = @splat(0);
    const moved = target.control(usb.hub_requests.descriptor(described.len), &described) catch {
        log.warn(name, "the hub would not describe itself");
        return false;
    };
    const described_hub = usb.Hub.parse(described[0..moved]) orelse {
        log.warn(name, "the hub's description is not one");
        return false;
    };

    const slot = table.free(&hubs) orelse {
        log.warn(name, "no room for another hub");
        return false;
    };

    slot.* = .{
        .live = true,
        .address = target.address,
        .controller = target.controller,
        // A device on this hub is reached through it, whatever this hub
        // is itself reached through.
        .route = .{ .hub = target.address, .port = 0 },
        .ops = target.ops,
        .zero = target.zero(),
        .ports = @min(described_hub.ports, MAX_PORTS),
        .power_on_ms = described_hub.power_on_ms,
    };

    power(slot);

    slot.watch = target.ops.watch(target.pipe(endpoint), STATUS_BYTES) catch {
        log.warn(name, "the controller would not watch the hub");
        slot.* = .{};
        return false;
    };

    log.begin(name, .key);
    out.decimal(slot.ports);
    out.text(if (slot.ports == 1) " port" else " ports");
    log.end();

    // Whatever is already plugged into it was plugged in before anybody
    // was watching, so the ports are looked at once rather than waited on.
    look(slot);
    return true;
}

fn detach(address: u7) void {
    const hub = table.by(&hubs, "address", address) orelse return;
    hub.ops.unwatch(hub.watch);
    hub.* = .{};
}

/// Switch the ports on and give them the moment the hub asked for. A hub
/// that switches them all together takes the request once and ignores the
/// rest, which costs nothing and saves knowing which kind it is.
fn power(hub: *Hub) void {
    var port: u8 = 1;
    while (port <= hub.ports) : (port += 1) {
        hc.command(hub.ops, hub.zero, usb.hub_requests.setPort(port, .power)) catch {};
    }
    sys.sleepMicros(@as(u32, hub.power_on_ms) * 1000);
}

// ---------------------------------------------------------------------------
// What changed
// ---------------------------------------------------------------------------

/// The controller interrupted, so a watched hub may have something to
/// say. The report names which ports changed; each one is then asked what
/// it changed to, because the bitmap says that something happened and
/// never what.
fn woke() void {
    var report: [STATUS_BYTES]u8 = @splat(0);
    for (&hubs) |*hub| {
        if (!hub.live) continue;
        while (hub.ops.collect(hub.watch, &report)) |moved| {
            if (moved == 0) break;
            look(hub);
        }
    }
}

/// Every port of one hub, asked what it is.
fn look(hub: *Hub) void {
    var port: u8 = 1;
    while (port <= hub.ports) : (port += 1) settle(hub, port);
}

fn settle(hub: *Hub, port: u8) void {
    const status = statusOf(hub, port) orelse return;

    // The change bits stay set until they are cleared, so a port answered
    // once would answer the same thing forever.
    if (status.connection_changed) {
        clear(hub, port, .connection_changed);
    }
    if (status.enable_changed) clear(hub, port, .enable_changed);

    if (!status.connected) {
        core.departed(hub.controller, hub.route, port - 1);
        return;
    }

    // A port with something on it that is not yet enabled needs a reset,
    // which is what makes the device answer to address zero.
    if (!status.enabled) {
        if (!reset(hub, port)) return;
    }

    const settled = statusOf(hub, port) orelse return;
    if (!settled.connected or !settled.enabled) return;

    const route = usb.Route{ .hub = hub.address, .port = @intCast(port) };
    core.arrived(hub.controller, route, port - 1, settled.speed(), hub.ops);
}

fn reset(hub: *Hub, port: u8) bool {
    hc.command(hub.ops, hub.zero, usb.hub_requests.setPort(port, .reset)) catch return false;

    // The hub does the reset itself and says when it is done. Asked
    // rather than waited out: a device that is ready sooner should not be
    // kept waiting, and one that never finishes should not hang the bus.
    var attempts: u8 = 0;
    while (attempts < 20) : (attempts += 1) {
        sys.sleepMicros(10_000);
        const status = statusOf(hub, port) orelse return false;
        if (status.reset_changed) {
            clear(hub, port, .reset_changed);
            // The device is at address zero now and needs the settling
            // time the specification gives it before it is spoken to.
            sys.sleepMicros(10_000);
            return status.enabled or !status.resetting;
        }
    }
    log.warn(name, "a port would not finish resetting");
    return false;
}

fn statusOf(hub: *Hub, port: u8) ?usb.PortStatus {
    var answer: [usb.PortStatus.BYTES]u8 = @splat(0);
    const moved = hub.ops.control(hub.zero, usb.hub_requests.portStatus(port), &answer) catch return null;
    if (moved < answer.len) return null;
    return usb.PortStatus.parse(&answer);
}

fn clear(hub: *Hub, port: u8, feature: usb.PortFeature) void {
    hc.command(hub.ops, hub.zero, usb.hub_requests.clearPort(port, feature)) catch {};
}
