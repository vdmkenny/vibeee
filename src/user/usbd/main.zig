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
const hid = @import("hid.zig");
const hub = @import("hub.zig");
const uhci = @import("uhci.zig");
const umass = @import("umass.zig");
const volume = @import("volume.zig");
const ehci = @import("ehci.zig");
const hc = @import("hc.zig");
const names = @import("ulib").info;
const irqroute = @import("ulib").irqroute;
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const proto = @import("proto").usb;
const proto_devices = @import("proto").devices;
const std = @import("std");
const sys = @import("sys");
const quit = @import("ulib").quit;

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
} ++ blk: {
    // One row per companion unit: a chipset hands over its companions as
    // separate functions, and each needs a controller of its own.
    var rows: [uhci.MAX_UNITS]Driver = undefined;
    for (&rows, 0..) |*row, unit| row.* = .{
        .name = uhci.name,
        .ops = uhci.unitOps(unit),
        .listen = uhci.unitListen(unit),
    };
    break :blk rows;
};

/// The class drivers this build carries. Which device each fits is again
/// the device manager's knowledge: a manifest names one of these, and a
/// class nobody here drives is a manifest and a program away.
const CLASSES = [_]@import("class.zig").ClassDriver{
    umass.driver,
    hid.driver,
    hub.driver,
};

/// This family of chipset puts one high speed controller and four
/// companions on the bus, and a machine may carry a card of its own.
const MAX_CONTROLLERS = 6;

var controllers: [MAX_CONTROLLERS]hc.Controller = undefined;
var controller_count: usize = 0;
var service: u32 = 0;

export fn _start() callconv(.c) noreturn {
    usbdMain();
}

fn usbdMain() noreturn {
    // Asked before the work rather than after it, so a second instance does
    // not walk a bus it is not going to serve. The registration below is
    // what actually settles which process is the bus service.
    if (serving()) standDown();

    core.drivers = &CLASSES;
    claim();
    if (controller_count == 0) {
        log.warn("usbd", "no host controller matched a driver");
    }

    // The first look at the ports: the machine's own devices are already
    // plugged in and will never announce themselves.
    scanAll();
    settle();

    // The name goes up once the bus has been walked, because that is what
    // the boot is waiting for. A name published at the top of this function
    // says the process started, which is not the same thing: the machine
    // would report a finished boot with its own disks still undiscovered.
    const channel = sys.svcRegister(proto.SERVICE);
    if (channel < 0) standDown();
    service = @intCast(channel);
    out.flush();

    serve();
}

/// One bus service to a machine, and the other one was here first.
fn standDown() noreturn {
    log.note("usbd", "already serving; letting this instance stand down");
    sys.exit(0);
}

/// Whether something is already answering as the bus service.
fn serving() bool {
    var buf: [512]u8 = @splat(0);
    return names.listContains("svc", proto.SERVICE, &buf);
}

/// Walk every controller, twice when a walk hands ports down: the fast
/// controller releases a full or low speed device to its companion, and
/// the companion, which announces nothing on its own, may already have
/// been walked when the handover lands.
fn scanAll() void {
    var released: u8 = 0;
    for (controllers[0..controller_count], 0..) |controller, i| {
        released += core.scan(@intCast(i), controller.ops);
    }
    if (released == 0) return;
    for (controllers[0..controller_count], 0..) |controller, i| {
        _ = core.scan(@intCast(i), controller.ops);
    }
}

fn claim() void {
    var index: u32 = 0;
    while (controller_count < MAX_CONTROLLERS) : (index += 1) {
        var assignment = proto_devices.Assignment{};
        proto_devices.claimNext(proto.SERVICE, index, &assignment) catch break;

        for (DRIVERS) |driver| {
            if (!std.mem.eql(u8, driver.name, assignment.driverSlice())) continue;
            // Rows sharing a name are the same driver's units; the first
            // with a free controller takes the device.
            if (attach(driver, @bitCast(assignment.location)) == .settled) break;
        }
    }
}

/// What became of one driver row's try at a device: settled means the
/// device is driven or refused for a reason every row would repeat, and
/// the walk stops; a busy unit sends the walk to the next row.
const Attach = enum { settled, unit_busy };

fn attach(driver: Driver, location: pci.Location) Attach {
    if (sys.claimDevice(location) < 0) {
        log.warn("usbd", "the controller is already claimed");
        return .settled;
    }

    if (!driver.ops.open(location)) {
        _ = sys.releaseDevice(location);
        return .unit_busy;
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
            return .settled;
        }
    } else {
        log.warn("usbd", "no interrupt line; controller unused");
        _ = sys.releaseDevice(location);
        return .settled;
    }

    controllers[controller_count] = controller;
    controller_count += 1;
    var where: [8]u8 = undefined;
    log.begin("usbd", .key);
    out.text("driving the controller at ");
    out.text(lib.pci.spell(location, &where));
    log.end();
    return .settled;
}

// ---------------------------------------------------------------------------
// The event loop
// ---------------------------------------------------------------------------

fn serve() noreturn {
    // The channel, every controller's interrupt, and every offered
    // volume's doorbell. The set is rebuilt whenever a disk comes or
    // goes, which is the only time it changes.
    var sources: [2 + MAX_CONTROLLERS + @import("lib").volume.MAX_VOLUMES]u32 = undefined;
    var source_count: usize = 0;
    quit_event = quit.event();

    while (true) {
        source_count = watchList(&sources);
        // Nothing is due at any particular time: a bus with nothing
        // being plugged into it waits here indefinitely.
        const woke = sys.waitMany(sources[0..source_count], sys.FOREVER);
        if (woke < 0) continue;

        const index: usize = @intCast(woke);
        // The supervisor's request to go. The volumes go with the process:
        // the kernel withdraws what it offered when the offerer is gone.
        if (quit_event != 0 and sources[index] == quit_event) sys.exit(0);
        if (index == 0) {
            drain();
            continue;
        }

        if (index <= controller_count) {
            const which = index - 1;
            const controller = &controllers[which];
            // The controller says what its interrupt amounted to; the
            // bus is walked only when something moved, and a rebuilt
            // controller's book is swept before the walk.
            const outcome = controller.ops.serviceIrq();
            switch (outcome) {
                .quiet => {},
                .ports_changed => {
                    if (core.scan(@intCast(which), controller.ops) > 0) scanAll();
                    settle();
                },
                .reborn => {
                    // The reborn controller's book is swept, and every
                    // controller is walked rather than just this one: a
                    // surrendered controller's ports fall to the
                    // companions, and only a walk of theirs picks the
                    // devices back up.
                    core.forgetController(@intCast(which));
                    scanAll();
                    settle();
                },
            }
            // A transfer finished, and one of the class drivers is
            // probably why. Which one is their own business.
            for (CLASSES) |driver| {
                if (driver.ops.woke) |look| look();
            }
            _ = sys.irqAck(controller.irq, outcome != .quiet);
            out.flush();
            continue;
        }

        // A volume's doorbell: the kernel wants blocks.
        if (volume.forDoorbell(sources[index])) |offered| volume.serve(offered);
    }
}

/// The request to go, or zero when the kernel gave none.
var quit_event: u32 = 0;

/// Everything worth waking for, in one array: the service channel first,
/// then the controllers, then the volumes, then the request to go.
fn watchList(into: []u32) usize {
    into[0] = service;
    var count: usize = 1;
    for (controllers[0..controller_count]) |controller| {
        into[count] = controller.irq;
        count += 1;
    }
    count += volume.doorbells(into[count..]);
    if (quit_event != 0) {
        into[count] = quit_event;
        count += 1;
    }
    return count;
}

/// Match the offered volumes to the disks that are actually there. Called
/// after a scan, which is the only thing that changes either list.
fn settle() void {
    for (volume.all()) |offered| {
        if (offered.live and umass.forAddress(offered.address) == null) {
            volume.withdraw(offered.address);
        }
    }
    for (umass.all(), 0..) |disk, i| {
        if (!disk.live or offered_for(disk.address)) continue;
        _ = volume.offer(umass.at(i).?);
    }
}

fn offered_for(address: u7) bool {
    for (volume.all()) |offered| {
        if (offered.live and offered.address == address) return true;
    }
    return false;
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
        .name => called(req.index, token),
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

/// As long as a path can be written, which the reply carries as an array
/// of exactly this size.
const PATH_MAX = @typeInfo(@FieldType(proto.DeviceInfo, "path")).array.len;

fn describe(index: u32, token: u32) void {
    if (index >= core.MAX_DEVICES) return replyEnd(token);
    const entry = core.at(index) orelse {
        // The table is sparse: an empty slot is a row to skip, not the
        // end of the walk.
        return replyBody(token, .{ .device = .{ .address = 0 } });
    };

    var info = proto.DeviceInfo{
        .address = entry.address,
        .controller = entry.controller,
        .speed = entry.speed,
        .class = entry.signature.class,
        .subclass = entry.signature.subclass,
        .protocol = entry.signature.protocol,
        .vendor = entry.descriptor.vendor,
        .product = entry.descriptor.product,
        .version = entry.descriptor.device_version,
        .driver_len = entry.driver.driver_len,
        .attached = entry.attached,
    };
    @memcpy(&info.driver, &entry.driver.driver);

    var where: [PATH_MAX]u8 = undefined;
    const path = core.pathOf(index, &where);
    info.path_len = @intCast(path.len);
    @memcpy(info.path[0..path.len], path);

    replyBody(token, .{ .device = info });
}

/// What a device calls itself, read once when it arrived.
fn called(index: u32, token: u32) void {
    const entry = core.at(index) orelse return replyBody(token, .{ .text = .{} });

    var text = proto.Text{ .len = @intCast(@min(entry.name_len, proto.NAME_MAX)) };
    @memcpy(text.bytes[0..text.len], entry.nameSlice()[0..text.len]);
    replyBody(token, .{ .text = text });
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
