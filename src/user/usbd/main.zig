//! usbd: the USB bus service.
//!
//! One process, one event loop, and the same shape every driver service
//! here has: the device manager says which controllers are ours, the
//! platform service says which line each interrupts on, and everything
//! after that happens because something happened. A port changes, the
//! controller interrupts, the bus enumerates what arrived. An idle bus
//! takes no interrupts and this process costs nothing.
//!
//! What a device turns out to be is not decided here. The bus reads the
//! descriptors and asks the device manager which driver fits, so a class
//! this build has never met is served by a manifest and a program rather
//! than by a change to this file.

const core = @import("core.zig");
const ehci = @import("ehci.zig");
const hc = @import("hc.zig");
const irqroute = @import("ulib").irqroute;
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const proto = @import("proto").usb;
const proto_devices = @import("proto").devices;
const std = @import("std");
const str = @import("ulib").str;
const sys = @import("sys");

/// The controller drivers this build carries. Which silicon each fits is
/// the device manager's knowledge, in `/lib/drivers/*.man`.
const Driver = struct {
    name: []const u8,
    ops: hc.HcOps,
    /// Told its interrupt once the line is routed, for the drivers whose
    /// transfers wait on it.
    listen: ?*const fn (irq: u32) void = null,
};

const DRIVERS = [_]Driver{
    .{ .name = ehci.name, .ops = ehci.ops, .listen = ehci.listenOn },
};

/// One controller each for the machine's high-speed bus and whatever a
/// second one turns out to be.
const MAX_CONTROLLERS = 2;

var controllers: [MAX_CONTROLLERS]hc.Controller = undefined;
var controller_count: usize = 0;
var service: u32 = 0;

export fn _start() callconv(.c) noreturn {
    usbdMain();
}

fn usbdMain() noreturn {
    const channel = sys.svcRegister(proto.SERVICE);
    if (channel < 0) {
        log.note("usbd", "already serving; letting this instance stand down");
        sys.exit(0);
    }
    service = @intCast(channel);

    claim();
    if (controller_count == 0) {
        log.warn("usbd", "no host controller matched a driver");
    }

    // The first look at the ports: the machine's own devices are already
    // plugged in and will never announce themselves.
    for (controllers[0..controller_count], 0..) |controller, i| {
        core.scan(@intCast(i), controller.ops);
    }
    out.flush();

    serve();
}

fn claim() void {
    var index: u32 = 0;
    while (controller_count < MAX_CONTROLLERS) : (index += 1) {
        var assignment = proto_devices.Assignment{};
        proto_devices.claimNext(proto.SERVICE, index, &assignment) catch break;

        for (DRIVERS) |driver| {
            if (!str.eql(driver.name, assignment.driverSlice())) continue;
            attach(driver, @bitCast(assignment.location));
        }
    }
}

fn attach(driver: Driver, location: pci.Location) void {
    if (sys.claimDevice(location) < 0) {
        log.warn("usbd", "the controller is already claimed");
        return;
    }

    if (!driver.ops.open(location)) {
        _ = sys.releaseDevice(location);
        return;
    }

    var controller = hc.Controller{
        .name = driver.name,
        .ops = driver.ops,
        .location = location,
    };

    if (irqroute.routedLine("usbd", location)) |gsi| {
        if (sys.irqAttach(gsi)) |taken| {
            controller.irq = taken;
            controller.irq_gsi = gsi;
            pci.enableInterrupt(location);
            if (driver.listen) |tell| tell(taken);
        } else |_| {
            log.warn("usbd", "the interrupt line was refused; controller unused");
            _ = sys.releaseDevice(location);
            return;
        }
    } else {
        log.warn("usbd", "no interrupt line; controller unused");
        _ = sys.releaseDevice(location);
        return;
    }

    controllers[controller_count] = controller;
    controller_count += 1;
    log.note("usbd", "driving the controller");
}

// ---------------------------------------------------------------------------
// The event loop
// ---------------------------------------------------------------------------

fn serve() noreturn {
    var sources: [1 + MAX_CONTROLLERS]u32 = undefined;
    sources[0] = service;
    var source_count: usize = 1;
    for (controllers[0..controller_count]) |controller| {
        sources[source_count] = controller.irq;
        source_count += 1;
    }

    while (true) {
        // Nothing is due at any particular time: a bus with nothing
        // being plugged into it waits here indefinitely.
        const woke = sys.waitMany(sources[0..source_count], sys.FOREVER);
        if (woke < 0) continue;

        const index: usize = @intCast(woke);
        if (index == 0) {
            drain();
            continue;
        }

        const which = index - 1;
        const controller = &controllers[which];
        // The controller says whether a port changed; only then is the
        // bus walked, and only that controller's ports.
        if (controller.ops.serviceIrq()) {
            core.scan(@intCast(which), controller.ops);
        }
        _ = sys.irqAck(controller.irq);
        out.flush();
    }
}

fn drain() void {
    while (true) {
        var message = sys.Message{};
        const request = sys.recv(service, &message, sys.POLL) orelse return;
        handle(&message, request.token);
    }
}

fn handle(message: *const sys.Message, token: u32) void {
    const bytes = message.bytes();
    if (bytes.len < @sizeOf(proto.Req)) return refuse(token);
    const req: *const proto.Req = @ptrCast(@alignCast(bytes.ptr));

    switch (req.tag) {
        .count => {
            var live: u32 = 0;
            for (core.all()) |entry| {
                if (entry.live) live += 1;
            }
            replyBody(token, .{ .count = live });
        },
        .device => describe(req.index, token),
        .controllers => replyBody(token, .{ .count = @intCast(controller_count) }),
        .port => port(req.index, token),
    }
}

/// Ports numbered across every controller in turn, so one walk covers a
/// machine with more than one of them.
fn port(index: u32, token: u32) void {
    var seen: u32 = 0;
    for (controllers[0..controller_count], 0..) |controller, which| {
        const count = controller.ops.ports();
        if (index < seen + count) {
            const number: u8 = @intCast(index - seen);
            const state = controller.ops.port(number);
            return replyBody(token, .{ .port = .{
                .controller = @intCast(which),
                .number = number + 1,
                .connected = @intFromBool(state.connected),
                .enabled = @intFromBool(state.enabled),
                .released = @intFromBool(state.released),
                .speed = state.speed,
                .address = core.addressAt(@intCast(which), number),
            } });
        }
        seen += count;
    }
    replyEnd(token);
}

fn describe(index: u32, token: u32) void {
    if (index >= core.MAX_DEVICES) return replyEnd(token);
    const entry = core.at(index) orelse {
        // The table is sparse: an empty slot is a row to skip, not the
        // end of the walk.
        return replyBody(token, .{ .device = .{ .address = 0 } });
    };

    var info = proto.DeviceInfo{
        .address = entry.address,
        .port = entry.port + 1,
        .controller = entry.controller,
        .speed = entry.speed,
        .class = entry.signature.class,
        .subclass = entry.signature.subclass,
        .protocol = entry.signature.protocol,
        .vendor = entry.descriptor.vendor,
        .product = entry.descriptor.product,
        .version = entry.descriptor.device_version,
        .driver_len = entry.driver.driver_len,
    };
    @memcpy(&info.driver, &entry.driver.driver);
    replyBody(token, .{ .device = info });
}

fn refuse(token: u32) void {
    var reply = proto.Rep{ .status = .refused };
    replyWith(token, &reply);
}

fn replyEnd(token: u32) void {
    var reply = proto.Rep{ .status = .end };
    replyWith(token, &reply);
}

fn replyBody(token: u32, body: proto.Body) void {
    var reply = proto.Rep{ .body = body };
    replyWith(token, &reply);
}

fn replyWith(token: u32, reply: *const proto.Rep) void {
    var answer = sys.Message.init(std.mem.asBytes(reply), &.{});
    _ = sys.replyMsg(service, token, &answer);
}

comptime {
    _ = lib;
}
