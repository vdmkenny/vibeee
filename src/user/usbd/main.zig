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

const acm = @import("acm.zig");
const core = @import("core.zig");
const ftdi = @import("ftdi.zig");
const hid = @import("hid.zig");
const hub = @import("hub.zig");
const uhci = @import("uhci.zig");
const ohci = @import("ohci.zig");
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
const serial = @import("serial.zig");
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
        .ops = hc.unitOps(uhci, unit),
        .listen = hc.unitListen(uhci, unit),
    };
    break :blk rows;
} ++ blk: {
    var rows: [ohci.MAX_UNITS]Driver = undefined;
    for (&rows, 0..) |*row, unit| row.* = .{
        .name = ohci.name,
        .ops = hc.unitOps(ohci, unit),
        .listen = hc.unitListen(ohci, unit),
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
    acm.driver,
    ftdi.driver,
};

/// An ICH7 puts one high speed controller and four companions on the bus,
/// an ICH9 two and six, and an AMD southbridge two and five.
const MAX_CONTROLLERS = 8;

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
    _ = core.stirred();
    settle();

    // The name goes up once the bus has been walked, because that is what
    // the boot is waiting for. A name published at the top of this function
    // says the process started, which is not the same thing: the machine
    // would report a finished boot with its own disks still undiscovered.
    const channel = sys.svcRegister(proto.SERVICE) catch standDown();
    service = @intCast(channel);

    // The ports found on the walk above go up under a name of their own:
    // what a serial port is has nothing to do with the bus it was found
    // on, and a program wanting one should not have to know which
    // service happens to be driving it.
    serial.start();
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
    sys.claimDevice(location) catch {
        log.warn("usbd", "the controller is already claimed");
        return .settled;
    };

    if (!driver.ops.open(location)) {
        sys.releaseDevice(location) catch {};
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
            sys.releaseDevice(location) catch {};
            return .settled;
        }
    } else {
        log.warn("usbd", "no interrupt line; controller unused");
        sys.releaseDevice(location) catch {};
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
    // The channel, every controller's interrupt, the serial service's
    // own pair, every offered volume's doorbell, the machine waking, and
    // the request to go at the end. The set is rebuilt whenever a disk
    // comes or goes, which is the only time it changes.
    const SOURCES = 1 + MAX_CONTROLLERS + SERIAL_SOURCES +
        @import("lib").volume.MAX_VOLUMES + 2;
    comptime {
        if (SOURCES > lib.limits.MAX_WAIT_HANDLES) @compileError("usbd waits on more than one wait can cover");
    }
    var sources: [SOURCES]u32 = undefined;
    var source_count: usize = 0;
    quit_event = quit.event();

    // The machine coming back from a sleep. A controller that lost its
    // power lost every conversation the bus was holding, so the bus is put
    // down and built again, which is what `usb rebuild` asks for by hand.
    wake_event = sys.watchWake() catch 0;
    if (wake_event == 0) {
        log.warn("usbd", "no wake watch; the bus would stay down after a sleep");
    }

    while (true) {
        source_count = watchList(&sources);
        // Nothing is due at any particular time: a bus with nothing
        // being plugged into it waits here indefinitely.
        const woke = sys.waitMany(sources[0..source_count], sys.FOREVER) catch continue;

        const index: usize = @intCast(woke);
        // The supervisor's request to go. The volumes go with the process:
        // the kernel withdraws what it offered when the offerer is gone.
        if (quit_event != 0 and sources[index] == quit_event) sys.exit(0);
        dispatch(index, sources[index]);

        // A transfer made for anything above may have waited on the very
        // interrupt that finished a watched endpoint's read, and taken it.
        // So the class drivers look at their endpoints after every event,
        // not only after a controller's: a keyboard typed on while a disk
        // is busy is otherwise not heard until something else interrupts.
        for (CLASSES) |driver| {
            if (driver.ops.woke) |look| look();
        }

        // After the transfers this event caused: a UHCI controller raises no
        // interrupt for a port change or a rebuild seen during one.
        serviceDueControllers();

        // After the drivers, not only after a root port changed. A hub's
        // ports are the hub driver's to watch, and what it finds arrives
        // here two calls away from the walk: a disk plugged into a hub was
        // enumerated and driven and never offered to the kernel, and one
        // unplugged from a hub left its volume mounted over nothing.
        if (core.stirred()) settle();
        out.flush();
    }
}

fn dispatch(index: usize, woke_on: u32) void {
    if (wake_event != 0 and woke_on == wake_event) {
        _ = rebuild();
        return;
    }
    if (index == 0) return drain();

    if (index <= controller_count) return serviceController(index - 1);

    // A program asking about a serial port, or saying it has written
    // something to one.
    if (serial.channel() != 0 and woke_on == serial.channel()) return serial.drain();
    if (serial.doorbell() != 0 and woke_on == serial.doorbell()) return serial.pump();

    // A volume's doorbell: the kernel wants blocks.
    if (volume.forDoorbell(woke_on)) |offered| volume.serve(offered);
}

/// Service one controller: walk its ports when one changed, and sweep its
/// devices and walk every controller when it was rebuilt.
fn serviceController(which: usize) void {
    const controller = &controllers[which];
    const outcome = controller.ops.serviceIrq();
    switch (outcome) {
        .quiet => {},
        .ports_changed => {
            if (core.scan(@intCast(which), controller.ops) > 0) scanAll();
        },
        .reborn => {
            // Every controller is walked, not just this one: a surrendered
            // controller's ports fall to the companions.
            core.forgetController(@intCast(which));
            scanAll();
        },
    }
    sys.irqAck(controller.irq, outcome != .quiet);
}

/// Service the controllers whose transfer waits left a port change or a
/// rebuild. A service's own transfers can leave more, so this repeats,
/// up to `DUE_ROUNDS` times, until none is due.
fn serviceDueControllers() void {
    for (0..DUE_ROUNDS) |_| {
        var serviced = false;
        for (controllers[0..controller_count], 0..) |controller, which| {
            const due = controller.ops.serviceDue orelse continue;
            if (!due()) continue;
            serviceController(which);
            serviced = true;
        }
        if (!serviced) return;
    }
}

const DUE_ROUNDS = 4;

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
    count += serial.watching(into[count..]);
    count += volume.doorbells(into[count..]);
    if (wake_event != 0) {
        into[count] = wake_event;
        count += 1;
    }
    if (quit_event != 0) {
        into[count] = quit_event;
        count += 1;
    }
    return count;
}

/// The machine waking from a sleep, or zero when nothing offered one.
var wake_event: u32 = 0;

/// How many handles the serial service waits on: the channel programs
/// ask it on, and the doorbell they ring.
const SERIAL_SOURCES = 2;

/// Match the offered volumes to the disks that are actually there. Called
/// after a scan, which is the only thing that changes either list.
/// Match the offered volumes to the disks that are actually there, by
/// where each disk sits rather than by the address it was given.
///
/// An address is the walk's to hand out, and a bus put down and brought
/// back hands them out afresh: a disk that never moved can come back with
/// another address because one in front of it was taken away meanwhile.
/// Matching on the address would then mount one disk's volume over
/// another's, which is the one mistake here that loses somebody's files.
fn settle() void {
    // Every disk that is there keeps or takes a volume, and its offer
    // follows it to whatever address it came back with.
    for (umass.all(), 0..) |disk, i| {
        if (!disk.live) continue;
        const where = disk.place();
        if (volume.forPlace(where)) |already| {
            volume.readdress(already, disk.address);
        } else {
            _ = volume.offer(umass.at(i).?);
        }
    }

    // And every offer with no disk under it any more goes, after the
    // matching rather than before it: a disk that came back at another
    // address must have claimed its own offer first.
    for (volume.all()) |offered| {
        if (offered.live and !diskAt(offered.where)) volume.withdraw(offered.address);
    }
}

fn diskAt(where: umass.Place) bool {
    for (umass.all()) |disk| {
        if (disk.live and disk.place().same(where)) return true;
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
    const req = proto.requestIn(message) orelse return refuse(token);
    if (!proto.known(req.tag)) return refuse(token);

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
        .rebuild => replyBody(token, .{ .count = rebuild() }),
    }
}

/// Put the bus down and bring it back, and say how many devices are on it
/// afterwards.
///
/// Everything the bus knew is given up first, and deliberately: a
/// controller that has been stopped has lost the conversations it was
/// holding, and a device the bus still believed in would be one it asked
/// questions of that nothing is answering. Whatever is really there is
/// found again by the walk, so a stick that never moved comes back as a
/// volume and a mount, and one taken away while the bus was down is
/// simply not there.
fn rebuild() u32 {
    for (controllers[0..controller_count]) |controller| controller.ops.quiesce();
    for (0..controller_count) |which| core.forgetController(@intCast(which));

    var carried: usize = 0;
    for (controllers[0..controller_count]) |controller| {
        if (controller.ops.rebuild()) carried += 1;
    }
    if (carried == 0) {
        // Nothing to bring back is not a failure. A machine with no
        // controller on it says so once at boot and has nothing more to
        // say every time it wakes.
        if (controller_count > 0) log.fail("usbd", "no controller came back");
    } else {
        log.begin("usbd", .key);
        out.decimal(carried);
        out.text(if (carried == 1) " controller rebuilt" else " controllers rebuilt");
        log.end();
    }

    scanAll();
    _ = core.stirred();
    settle();

    var live: u32 = 0;
    for (core.all()) |entry| {
        if (entry.live) live += 1;
    }
    return live;
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
    proto.answer(service, token, reply);
}

comptime {
    _ = lib;
}
