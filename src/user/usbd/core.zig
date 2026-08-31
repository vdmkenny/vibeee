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

const hc = @import("hc.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const proto_devices = @import("proto").devices;
const usb = @import("lib").usb;

/// How many devices one machine of this class plausibly carries. The
/// table is fixed: a bus that cannot grow without bound is one that
/// cannot exhaust memory while something is being plugged in.
pub const MAX_DEVICES = 16;

pub const Device = struct {
    live: bool = false,
    /// Which controller and which of its ports.
    controller: u8 = 0,
    port: u8 = 0,
    address: u7 = 0,
    speed: usb.Speed = .high,
    descriptor: usb.Device = .{},
    signature: usb.Signature = .{},
    /// The driver the device manager named, empty when nobody claimed it.
    driver: proto_devices.Assignment = .{},
};

var devices: [MAX_DEVICES]Device = @splat(.{});
var addresses = usb.Addresses{};

pub fn all() []const Device {
    return &devices;
}

/// The address the bus gave whatever sits on a port, or zero when
/// nothing there enumerated.
pub fn addressAt(controller: u8, port: u8) u8 {
    for (&devices) |*entry| {
        if (entry.live and entry.controller == controller and entry.port == port) return entry.address;
    }
    return 0;
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
            forget(controller, index);
            continue;
        }
        if (known(controller, index)) continue;

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

        enumerate(controller, index, settled.speed, ops);
    }
}

fn known(controller: u8, port: u8) bool {
    for (devices) |entry| {
        if (entry.live and entry.controller == controller and entry.port == port) return true;
    }
    return false;
}

fn forget(controller: u8, port: u8) void {
    for (&devices) |*entry| {
        if (!entry.live or entry.controller != controller or entry.port != port) continue;
        addresses.release(entry.address);
        log.begin("usbd", .key);
        out.text("port ");
        out.decimal(port + 1);
        out.text(": device unplugged");
        log.end();
        entry.* = .{};
    }
}

/// The conversation every device has when it arrives.
fn enumerate(controller: u8, port: u8, speed: usb.Speed, ops: hc.HcOps) void {
    // The first question is how big an answer the device can give: until
    // that is known every read has to be short enough for the smallest
    // packet any device may use.
    var first: [8]u8 = @splat(0);
    _ = ops.control(0, speed, 8, usb.Setup.getDescriptor(.device, 0, first.len), &first) catch |err| {
        return sayFailure(port, "would not describe itself", err);
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
    _ = ops.control(0, speed, packet_zero, usb.Setup.setAddress(address), &nothing) catch |err| {
        addresses.release(address);
        return sayFailure(port, "would not take an address", err);
    };
    // The device switches address after the status stage, and is
    // entitled to two milliseconds to do it.
    @import("sys").sleepMicros(2_000);

    var full: [usb.Device.BYTES]u8 = @splat(0);
    _ = ops.control(address, speed, packet_zero, usb.Setup.getDescriptor(.device, 0, full.len), &full) catch |err| {
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
    var configuration: [256]u8 = @splat(0);
    var described: usize = 0;

    if (ops.control(address, speed, packet_zero, usb.Setup.getDescriptor(.configuration, 0, header.len), &header)) |_| {
        if (usb.Configuration.parse(&header)) |config| {
            const wanted = @min(config.total_length, configuration.len);
            described = ops.control(
                address,
                speed,
                packet_zero,
                usb.Setup.getDescriptor(.configuration, 0, @intCast(wanted)),
                configuration[0..wanted],
            ) catch 0;
        }
    } else |_| {}

    const slot = free() orelse {
        addresses.release(address);
        log.warn("usbd", "the device table is full");
        return;
    };

    slot.* = .{
        .live = true,
        .controller = controller,
        .port = port,
        .address = address,
        .speed = speed,
        .descriptor = descriptor,
        .signature = usb.signatureOf(descriptor, configuration[0..described]),
    };

    // Which driver wants it is not this file's decision. The manager
    // holds every manifest, so a class nobody here knows is still
    // matched, and a device with no driver is still a device the
    // listing shows.
    askForDriver(slot);
    say(slot);
}

fn free() ?*Device {
    for (&devices) |*entry| {
        if (!entry.live) return entry;
    }
    return null;
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
