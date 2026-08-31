//! The bus: what is plugged in, and what it turned out to be.
//!
//! Enumeration is the same conversation with every device, whatever it
//! is. Reset its port, ask what packet size it can take, give it an
//! address of its own, read what it says it is, and put it in the table.
//! Which driver then wants it is the device manager's question, asked by
//! signature, so a class this file has never heard of is served by
//! dropping in a manifest and a program.
//!
//! Nothing here knows what a controller is beyond the seam in `hc.zig`.

const class = @import("class.zig");
const hc = @import("hc.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const str = @import("ulib").str;
const table = @import("ulib").table;
const proto_devices = @import("proto").devices;
const sys = @import("sys");
const usb = @import("lib").usb;

/// How many devices one machine of this class plausibly carries. The
/// table is fixed: a bus that cannot grow without bound is one that
/// cannot exhaust memory while something is being plugged in.
pub const MAX_DEVICES = 16;

pub const Device = struct {
    live: bool = false,
    /// Which controller, and where on it: a root port, or a port of some
    /// hub that is itself somewhere on the same controller.
    controller: u8 = 0,
    port: u8 = 0,
    route: usb.Route = .{},
    address: u7 = 0,
    speed: usb.Speed = .high,
    descriptor: usb.Device = .{},
    signature: usb.Signature = .{},
    /// The driver the device manager named, empty when nobody claimed it.
    driver: proto_devices.Assignment = .{},
    /// The configuration as the device wrote it, kept so a class driver
    /// can find its own endpoints without asking the device twice.
    configuration: [CONFIGURATION_MAX]u8 = @splat(0),
    described: u16 = 0,
    /// Whether the driver named above took it. A device nobody could
    /// drive stays listed, which is the answer `usb` shows.
    attached: bool = false,
    /// What the device calls itself, if it says. Read once, at
    /// enumeration: a name does not change and asking twice would be two
    /// more control transfers for nothing.
    name: [NAME_MAX]u8 = @splat(0),
    name_len: u8 = 0,

    pub fn nameSlice(self: *const Device) []const u8 {
        return self.name[0..@min(self.name_len, self.name.len)];
    }

    pub fn configurationSlice(self: *const Device) []const u8 {
        return self.configuration[0..@min(self.described, self.configuration.len)];
    }
};

/// A configuration with every interface and endpoint a device of this
/// kind carries. Anything longer belongs to a device asking for more than
/// this bus offers, and is read as far as it fits.
pub const CONFIGURATION_MAX = 256;

/// As much of a device's name as is kept. Longer names exist and are cut:
/// what a listing has room for is shorter than this anyway.
pub const NAME_MAX = 40;

var devices: [MAX_DEVICES]Device = @splat(.{});
var addresses = usb.Addresses{};

/// The class drivers this build carries, named the way their manifests
/// name them. Set once at start, so this file holds no list of classes
/// and a driver is added by adding a driver.
pub var drivers: []const class.ClassDriver = &.{};

pub fn all() []const Device {
    return &devices;
}

/// The address the bus gave whatever sits on a port, or zero when
/// nothing there enumerated.
pub fn addressAt(controller: u8, port: u8) u8 {
    for (&devices) |*entry| {
        if (entry.live and entry.route.hub == 0 and
            entry.controller == controller and entry.port == port) return entry.address;
    }
    return 0;
}

/// Where a device sits, written the way a person would trace it: the
/// controller, then every port down the chain to the device itself.
///
/// Walked from the device upward, because that is the direction the table
/// records, and reversed at the end. A chain that does not terminate is a
/// table that has been corrupted, so the walk is bounded by the table.
pub fn pathOf(index: usize, into: []u8) []const u8 {
    const entry = at(index) orelse return "";

    var ports: [MAX_DEVICES]u8 = undefined;
    var depth: usize = 0;
    var walking = entry;

    while (depth < ports.len) {
        ports[depth] = walking.port + 1;
        depth += 1;
        if (walking.route.hub == 0) break;
        walking = byAddress(walking.route.hub) orelse break;
    }

    var text = str.Builder{ .buf = into };
    text.number(entry.controller);
    var left = depth;
    while (left > 0) {
        left -= 1;
        text.byte(if (left + 1 == depth) '-' else '.');
        text.number(ports[left]);
    }
    return text.done();
}

fn byAddress(address: u7) ?*const Device {
    for (&devices) |*entry| {
        if (entry.live and entry.address == address) return entry;
    }
    return null;
}

pub fn at(index: usize) ?*const Device {
    if (index >= devices.len or !devices[index].live) return null;
    return &devices[index];
}

/// Walk one controller's ports and enumerate whatever is newly on them.
/// Called at start and again on every port-change interrupt, which is
/// the whole of the hot-plug story: nothing polls.
pub fn scan(controller: u8, ops: hc.HcOps) void {
    var index: u8 = 0;
    const ports = ops.ports();
    while (index < ports) : (index += 1) {
        const state = ops.port(index);

        if (!state.connected) {
            forget(controller, .{}, index);
            continue;
        }
        if (known(controller, .{}, index)) continue;

        const settled = ops.resetPort(index);
        if (settled.released) {
            log.begin("usbd", .dim);
            out.text("port ");
            out.decimal(index + 1);
            out.text(": ");
            out.text(settled.speed.spell());
            out.text(" speed, left to the companion controller");
            log.end();
            continue;
        }
        if (!settled.enabled) continue;

        arrived(controller, .{}, index, settled.speed, ops);
    }
}

/// A device has appeared: on a root port when the scan found it, or on a
/// hub's port when the hub driver says so. Either way what happens next is
/// the same conversation, which is why a hub needs nothing of its own here
/// beyond saying where and how fast.
pub fn arrived(controller: u8, route: usb.Route, port: u8, speed: usb.Speed, ops: hc.HcOps) void {
    if (known(controller, route, port)) return;
    enumerate(controller, route, port, speed, ops);
}

/// And has gone.
pub fn departed(controller: u8, route: usb.Route, port: u8) void {
    forget(controller, route, port);
}

fn known(controller: u8, route: usb.Route, port: u8) bool {
    for (devices) |entry| {
        if (entry.live and entry.controller == controller and
            entry.route.hub == route.hub and entry.port == port) return true;
    }
    return false;
}

fn forget(controller: u8, route: usb.Route, port: u8) void {
    for (&devices) |*entry| {
        if (!entry.live or entry.controller != controller or
            entry.route.hub != route.hub or entry.port != port) continue;

        // Everything behind it goes too: a hub unplugged takes its whole
        // branch, and none of it can be asked about any more.
        if (entry.address != 0) forgetBehind(entry.address);
        if (entry.attached) {
            for (drivers) |candidate| {
                if (strEql(candidate.name, entry.driver.driverSlice())) candidate.ops.detach(entry.address);
            }
        }
        addresses.release(entry.address);
        log.begin("usbd", .key);
        out.text("port ");
        out.decimal(port + 1);
        out.text(": device unplugged");
        log.end();
        entry.* = .{};
    }
}

/// Everything hanging off a hub that has itself gone.
fn forgetBehind(hub: u7) void {
    for (&devices) |*entry| {
        if (!entry.live or entry.route.hub != hub) continue;
        forget(entry.controller, entry.route, entry.port);
    }
}

/// What a device is owed between the end of its reset and the first thing
/// said to it. The specification's TRSTRCY is ten milliseconds; this is
/// generous because the cost is paid once per device and the failure it
/// prevents is a device that never appears at all.
const RESET_RECOVERY_US: u32 = 20_000;

/// The conversation every device has when it arrives.
fn enumerate(controller: u8, route: usb.Route, port: u8, speed: usb.Speed, ops: hc.HcOps) void {
    const zero = usb.Pipe{ .speed = speed, .max_packet = 8, .route = route };

    // A device that has just been reset is not listening yet. An emulator
    // answers anyway; real silicon does not, and what that looks like from
    // here is a device that will not describe itself.
    sys.sleepMicros(RESET_RECOVERY_US);

    // The first question is how big an answer the device can give: until
    // that is known every read has to be short enough for the smallest
    // packet any device may use.
    //
    // Asked twice if the first attempt times out. A device that misses the
    // first setup packet after a reset is common enough that the second try
    // is part of the conversation rather than a workaround.
    var first: [8]u8 = @splat(0);
    const question = usb.Setup.getDescriptor(.device, 0, first.len);
    _ = ops.control(zero, question, &first) catch {
        sys.sleepMicros(RESET_RECOVERY_US);
        _ = ops.control(zero, question, &first) catch |err| {
            return sayFailure(port, "would not describe itself", err);
        };
    };

    const packet_zero = usb.Device.packetZeroOf(&first) orelse {
        log.warn("usbd", "a device answered with a packet size that cannot be");
        return;
    };

    const address = addresses.take() orelse {
        log.warn("usbd", "no addresses left on this bus");
        return;
    };

    var nothing: [0]u8 = .{};
    var addressing = zero;
    addressing.max_packet = packet_zero;
    _ = ops.control(addressing, usb.Setup.setAddress(address), &nothing) catch |err| {
        addresses.release(address);
        return sayFailure(port, "would not take an address", err);
    };
    // The device switches address after the status stage, and is
    // entitled to two milliseconds to do it.
    sys.sleepMicros(2_000);

    var full: [usb.Device.BYTES]u8 = @splat(0);
    const named = usb.Pipe{
        .address = address,
        .speed = speed,
        .max_packet = packet_zero,
        .route = route,
    };
    _ = ops.control(named, usb.Setup.getDescriptor(.device, 0, full.len), &full) catch |err| {
        addresses.release(address);
        return sayFailure(port, "went quiet after being addressed", err);
    };

    const descriptor = usb.Device.parse(&full) orelse {
        addresses.release(address);
        log.warn("usbd", "a device's descriptor is not one");
        return;
    };

    // The configuration is read twice: once for its header, which says
    // how long the whole of it is, and once for all of it.
    var header: [usb.Configuration.BYTES]u8 = @splat(0);
    var configuration: [CONFIGURATION_MAX]u8 = @splat(0);
    var described: usize = 0;

    if (ops.control(named, usb.Setup.getDescriptor(.configuration, 0, header.len), &header)) |_| {
        if (usb.Configuration.parse(&header)) |config| {
            const wanted = @min(config.total_length, configuration.len);
            described = ops.control(
                named,
                usb.Setup.getDescriptor(.configuration, 0, @intCast(wanted)),
                configuration[0..wanted],
            ) catch 0;
        }
    } else |_| {}

    const slot = table.free(&devices) orelse {
        addresses.release(address);
        log.warn("usbd", "the device table is full");
        return;
    };

    slot.* = .{
        .live = true,
        .controller = controller,
        .port = port,
        .route = route,
        .address = address,
        .speed = speed,
        .descriptor = descriptor,
        .signature = usb.signatureOf(descriptor, configuration[0..described]),
        .configuration = configuration,
        .described = @intCast(described),
    };

    name(slot, named, ops);

    // Which driver wants it is not this file's decision. The manager
    // holds every manifest, so a class nobody here knows is still
    // matched, and a device with no driver is still a device the
    // listing shows.
    askForDriver(slot);
    hand(slot, ops);
    say(slot);
}

/// Give the device to whichever driver the manager named. A name nobody
/// here answers to leaves the device listed and undriven, which is what a
/// manifest naming a driver this build does not carry should look like.
fn hand(entry: *Device, ops: hc.HcOps) void {
    const wanted = entry.driver.driverSlice();
    if (wanted.len == 0) return;

    for (drivers) |candidate| {
        if (!strEql(candidate.name, wanted)) continue;
        entry.attached = candidate.ops.attach(.{
            .address = entry.address,
            .speed = entry.speed,
            .controller = entry.controller,
            .port = entry.port,
            .route = entry.route,
            .descriptor = entry.descriptor,
            .signature = entry.signature,
            .configuration = entry.configurationSlice(),
            .ops = ops,
        });
        return;
    }
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Ask the device what it calls itself.
///
/// Two more control transfers, once, and only for a device that offers a
/// name at all: the language list first, because a string has to be asked
/// for in a language the device has. A device that will not say keeps the
/// name its class and numbers give it, which is what the listing falls
/// back to.
fn name(entry: *Device, pipe: usb.Pipe, ops: hc.HcOps) void {
    const which = entry.descriptor.product_name;
    if (which == 0) return;

    var languages: [8]u8 = @splat(0);
    const offered = ops.control(pipe, usb.Setup.stringDescriptor(0, 0, languages.len), &languages) catch return;
    const language = usb.firstLanguage(languages[0..offered]) orelse return;

    // Twice the room, because the wire carries two bytes a character and
    // what is kept is UTF-8.
    var wire: [2 * NAME_MAX + 2]u8 = @splat(0);
    const moved = ops.control(pipe, usb.Setup.stringDescriptor(which, language, wire.len), &wire) catch return;

    const text = usb.decodeString(wire[0..moved], &entry.name);
    entry.name_len = @intCast(text.len);
}

/// Ask the device manager which driver fits, by the signature the device
/// gave. A bus with no manager, or no manifest for this class, leaves the
/// device listed and undriven rather than refused.
fn askForDriver(entry: *Device) void {
    var reply = proto_devices.Rep{};
    const numbers = entry.signature.pack();
    const request = proto_devices.Req{ .tag = .lookup, .index = numbers.kind, .a = numbers.part };

    proto_devices.call(request, &reply) catch return;
    entry.driver = reply.body.assignment;
}

fn say(entry: *const Device) void {
    log.begin("usbd", .key);
    out.text("port ");
    out.decimal(entry.port + 1);
    out.text(": ");
    out.hex(entry.descriptor.vendor, 4);
    out.byte(':');
    out.hex(entry.descriptor.product, 4);
    out.text(" ");
    out.text(entry.signature.class.spell());
    out.text(", ");
    out.text(entry.speed.spell());
    out.text(" speed, address ");
    out.decimal(entry.address);
    if (entry.driver.driver_len != 0) {
        out.text(", driven by ");
        out.text(entry.driver.driverSlice());
    }
    log.end();
}

fn sayFailure(port: u8, what: []const u8, err: anyerror) void {
    log.begin("usbd", .warn);
    out.text("port ");
    out.decimal(port + 1);
    out.text(": the device ");
    out.text(what);
    out.text(" (");
    out.text(@errorName(err));
    out.byte(')');
    log.end();
}
