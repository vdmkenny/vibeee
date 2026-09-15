//! A serial port on a communications device, in the abstract control
//! model every one of them speaks.
//!
//! Two interfaces make one port: the first takes the requests that set
//! the line up, the second carries the bytes. Finding which is which is
//! the awkward part and is in `lib.usb`, where it is tested against the
//! shapes real devices write; what is here is the arrangement.
//!
//! Nothing polls from this side. The bytes endpoint has a read standing
//! on it, which the controller carries in hardware: the device answers
//! with nothing until somebody at the other end of the wire speaks, and
//! only an answer ends the transfer and raises an interrupt. A port with
//! nothing coming in costs no time at all.
//!
//! The read stands only while a program has the port. Bytes arriving
//! with nobody to take them go nowhere, and a device that talks to
//! itself, which is what an instrument reporting once a second is, would
//! otherwise wake this process forever for something nobody wants. The
//! notice endpoint is the other way about: it says nothing until the far
//! end's line changes, so it stands from the moment the device arrives
//! and what it says is worth showing whether or not anybody has the port.
//!
//! **One read stands at a time**, which bounds what may arrive between
//! two visits to this process without being lost. That is a controller's
//! packet or eight of them depending on which one is carrying the
//! device; the ring says so when it happens rather than losing bytes
//! quietly.

const class = @import("class.zig");
const hc = @import("hc.zig");
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const serial = @import("serial.zig");
const table = @import("ulib").table;
const usb = @import("lib").usb;

const cdc = usb.cdc;
const Held = lib.serial.Held;
const Line = lib.serial.Line;

pub const name = "acm";

/// How many at once. Each takes two of its controller's standing reads,
/// and a machine with more serial adapters than this plugged in wants a
/// bigger table in more places than this one.
pub const MAX_DEVICES = 2;

/// The most one standing read takes in, which is what the buffer that
/// collects it has to hold.
const READ_MAX = 512;

/// What a port is set to before anybody asks for anything else.
///
/// Nothing about a serial line is discoverable: both ends have to have
/// been told, and a device bridging to a real wire runs at whatever it
/// was last set to. This is the rate everything that is not a modem
/// uses, and a program that wants another says so.
const DEFAULT: Line = .{ .rate = 115200, .bits = 8, .parity = .none, .stop = .one };

/// What the host holds up as soon as it has the port: a great many
/// devices send nothing at all until data terminal ready is set, it
/// being the only way the far end knows anybody is listening.
const HOLDING: Held = .{ .dtr = true, .rts = true };

const Device = struct {
    live: bool = false,
    address: u7 = 0,
    /// The interface every request goes to, which with the address is
    /// what names this port to the rest of the service.
    control: u8 = 0,
    ops: hc.HcOps = undefined,
    /// The device's own control endpoint, kept because every request
    /// that sets the line up goes to it.
    zero: usb.Pipe = .{},
    /// The pipe bytes arrive on, kept rather than opened once: the read
    /// stands only while somebody has the port, and each one begins
    /// afresh.
    reading: usb.Pipe = .{},
    /// The pipe bytes leave on. Its toggle is this driver's to keep.
    writing: usb.Pipe = .{},
    /// The address of each bulk endpoint, for taking it out of a halt.
    reading_at: u8 = 0,
    writing_at: u8 = 0,
    /// How much one standing read asks for.
    wanted: u16 = 0,
    /// The standing read on the bytes, while a program has the port.
    bytes_watch: ?u8 = null,
    /// The standing read on the notice endpoint, where the device has
    /// somewhere to say what its line is doing.
    notice_watch: ?u8 = null,

    fn which(self: *const Device) serial.Which {
        return .{ .address = self.address, .interface = self.control };
    }
};

var devices: [MAX_DEVICES]Device = @splat(.{});

pub const ops = class.ClassOps{ .attach = attach, .detach = detach, .woke = woke };
pub const driver = class.ClassDriver{ .name = name, .ops = ops };

/// What a serial port does, for the service that offers it. One table
/// for every port this driver carries: which device is which is in the
/// `Which` each call is given.
const serial_ops = serial.Ops{
    .setLine = setLine,
    .hold = hold,
    .send = send,
    .breaking = breaking,
    .opened = opened,
};

// ---------------------------------------------------------------------------
// Coming and going
// ---------------------------------------------------------------------------

fn attach(target: class.Target) bool {
    if (!cdc.speaksSerial(target.signature.protocol)) {
        log.warn(name, "the interface is not a serial port");
        return false;
    }
    const port = cdc.portIn(target.configuration) orelse {
        log.warn(name, "the device describes no serial port");
        return false;
    };

    const limit = target.ops.watchLimit();
    const wanted = readSize(port.read.max_packet, limit) orelse {
        log.warn(name, "the device sends packets larger than the controller takes in one go");
        return false;
    };

    const slot = table.free(&devices) orelse {
        log.warn(name, "no room for another serial port");
        return false;
    };

    slot.* = .{
        .live = true,
        .address = target.address,
        .control = port.control,
        .ops = target.ops,
        .zero = target.zero(),
        .reading = target.pipe(port.read),
        .writing = target.pipe(port.write),
        .reading_at = port.read.address().byte(),
        .writing_at = port.write.address().byte(),
        .wanted = wanted,
    };

    // The line and the two lines that say a program is here. A device
    // bridging to a real wire has no other way to know what rate to run
    // at, and its power-on default is nobody's to depend on. Refusals
    // are noted and carried past, because devices that refuse these and
    // work perfectly well are common enough that every driver for this
    // class does the same.
    if (!setLine(slot.which(), DEFAULT)) log.note(name, "the device would not take a line setting");
    if (!hold(slot.which(), HOLDING)) log.note(name, "the device would not take the control lines");

    // Optional, and genuinely so: a port with nowhere to say what its
    // line is doing works, its state simply never changes.
    if (port.notice) |endpoint| {
        const room: u16 = @intCast(@min(endpoint.max_packet, limit));
        if (target.ops.watch(target.pipe(endpoint), room)) |taken| {
            slot.notice_watch = taken;
        } else |_| {
            log.note(name, "the device's notice endpoint was refused; its line state will not change");
        }
    }

    if (!serial.offer(slot.which(), &serial_ops, .{
        .vendor = target.descriptor.vendor,
        .product = target.descriptor.product,
        .reports = slot.notice_watch != null,
        .line = DEFAULT,
        .held = HOLDING,
    })) {
        forget(slot);
        return false;
    }
    return true;
}

/// A program took the port, or gave it back.
fn opened(which: serial.Which, open: bool) void {
    const device = forWhich(which) orelse return;
    if (!open) return stopReading(device);
    if (device.bytes_watch != null) return;

    // Both pipes out of whatever halt or half-finished conversation the
    // last program left, which puts the device's own count of packets
    // back to the beginning as well. Without it a fresh read is a packet
    // out of step with the device and the transfer never completes. A
    // pipe that was not halted does not mind being told so.
    for ([_]u8{ device.reading_at, device.writing_at }) |endpoint| {
        hc.command(device.ops, device.zero, usb.Setup.clearHalt(endpoint)) catch {};
    }
    device.reading.toggle = false;
    device.writing.toggle = false;

    device.bytes_watch = device.ops.watch(device.reading, device.wanted) catch {
        log.warn(name, "the controller would not read the device");
        return;
    };
}

fn stopReading(device: *Device) void {
    const watch = device.bytes_watch orelse return;
    device.ops.unwatch(watch);
    device.bytes_watch = null;
}

fn detach(address: u7) void {
    serial.withdraw(address);
    for (&devices) |*device| {
        if (!device.live or device.address != address) continue;
        forget(device);
    }
}

/// Give back what a device was holding, whether it went or was never
/// fully taken.
fn forget(device: *Device) void {
    stopReading(device);
    if (device.notice_watch) |watch| device.ops.unwatch(watch);
    device.* = .{};
}

/// How much to ask for each time round: whole packets, as many as the
/// controller will take in one go. Nothing at all where one packet is
/// already more than it takes, since a device answering with more than
/// was asked for is a failed transfer rather than a truncated one.
fn readSize(max_packet: u16, limit: usize) ?u16 {
    if (max_packet == 0 or max_packet > limit) return null;
    return @intCast(limit - (limit % max_packet));
}

// ---------------------------------------------------------------------------
// What arrived
// ---------------------------------------------------------------------------

/// The controller interrupted. Whatever the devices answered with is
/// here, and there is nothing to do when none of them did.
fn woke() void {
    var buffer: [READ_MAX]u8 = undefined;
    for (&devices) |*device| {
        if (!device.live) continue;

        if (device.bytes_watch) |watch| {
            while (device.ops.collect(watch, &buffer)) |moved| {
                if (moved == 0) break;
                serial.arrived(device.which(), buffer[0..moved]);
            }
        }
        if (device.notice_watch) |watch| {
            while (device.ops.collect(watch, &buffer)) |moved| {
                if (moved == 0) break;
                noticed(device, buffer[0..moved]);
            }
        }
    }
}

/// One notice from a device. Only what it says about its line is acted
/// on: the others belong to devices that answer commands over the same
/// endpoint, which is not what a serial port is being driven as here.
fn noticed(device: *Device, bytes: []const u8) void {
    const notice = cdc.Notice.parse(bytes) orelse return;
    if (notice.what != .serial_state) return;
    const state = cdc.stateOf(notice.payload(bytes)) orelse return;
    serial.said(device.which(), state);
}

// ---------------------------------------------------------------------------
// What a port does
// ---------------------------------------------------------------------------

fn forWhich(which: serial.Which) ?*Device {
    for (&devices) |*device| {
        if (!device.live) continue;
        if (device.address == which.address and device.control == which.interface) return device;
    }
    return null;
}

fn setLine(which: serial.Which, line: Line) bool {
    const device = forWhich(which) orelse return false;
    var coding = cdc.LineCoding.of(line);
    const bytes: *[cdc.LineCoding.BYTES]u8 = @ptrCast(&coding);
    const moved = device.ops.control(device.zero, cdc.setLineCoding(device.control), bytes) catch return false;
    return moved == bytes.len;
}

fn hold(which: serial.Which, held: Held) bool {
    const device = forWhich(which) orelse return false;
    hc.command(device.ops, device.zero, cdc.setControlLines(device.control, held)) catch return false;
    return true;
}

fn breaking(which: serial.Which, milliseconds: u16) bool {
    const device = forWhich(which) orelse return false;
    hc.command(device.ops, device.zero, cdc.sendBreak(device.control, milliseconds)) catch return false;
    return true;
}

/// Send what a program wrote, in as many transfers as the controller
/// wants it split into.
///
/// A send that ends on an exact packet is followed by an empty one. A
/// device waiting for a short packet to know a transfer has ended would
/// otherwise sit on the last full one, and devices that do this are
/// common enough that the reference driver for this class carries a list
/// of them.
fn send(which: serial.Which, bytes: []u8) usize {
    const device = forWhich(which) orelse return 0;
    const limit = device.ops.bulkLimit();
    if (limit == 0) return 0;

    var moved: usize = 0;
    while (moved < bytes.len) {
        const take = @min(bytes.len - moved, limit);
        const sent = device.ops.bulk(&device.writing, bytes[moved..][0..take]) catch break;
        moved += sent;
        if (sent < take) break;
    }

    const packet = @max(device.writing.max_packet, 1);
    if (moved != 0 and moved % packet == 0) {
        var nothing: [0]u8 = .{};
        _ = device.ops.bulk(&device.writing, &nothing) catch {};
    }
    return moved;
}
