//! The serial adapter one company makes and several copy.
//!
//! No class, no descriptors that say anything: what this chip wants said
//! to it is numbers its maker chose, and those are in `ftdi/regs.zig`
//! beside this file, where they can be checked on the build machine. What
//! is here is the arrangement: find the bulk pair, set the line, and read
//! the bytes.
//!
//! **What the line is doing rides in front of the bytes.** There is no
//! notice endpoint; two status bytes come at the head of every packet
//! instead, even when there are no bytes behind them. So what arrives is
//! split by packet rather than taken as one run, and the head of each is
//! read as the state of the line.
//!
//! **The read only stands while a program has the port.** The chip
//! answers every read after its own wait whether or not anything came,
//! so a read left standing on an adapter nobody is using would wake this
//! machine sixty times a second for two bytes of nothing. Closed, it
//! costs what an unplugged cable costs.

const class = @import("class.zig");
const hc = @import("hc.zig");
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const serial = @import("serial.zig");
const table = @import("ulib").table;
const usb = @import("lib").usb;

const ftdi = @import("ftdi/regs.zig");
const Held = lib.serial.Held;
const Line = lib.serial.Line;
const State = lib.serial.State;

pub const name = "ftdi";

/// How many ports at once. A chip with four of them is one device and
/// four rows here, which is what this is sized for.
pub const MAX_PORTS = 4;

/// The most one standing read takes in, which the buffer collecting it
/// has to hold.
const READ_MAX = 512;

/// What a port is set to before anybody asks. Nothing about a serial
/// line is discoverable, and the chip keeps whatever the last machine
/// left it at, so this is set rather than read.
const DEFAULT: Line = .{ .rate = 115200, .bits = 8, .parity = .none, .stop = .one };

/// What the host holds up: a great many devices on the other end of one
/// of these send nothing until they are told somebody is here.
const HOLDING: Held = .{ .dtr = true, .rts = true };

const Port = struct {
    live: bool = false,
    address: u7 = 0,
    /// Which interface this port is, which with the address is what
    /// names it to the rest of the service.
    interface: u8 = 0,
    /// Which port the chip's own requests call it, which is not the
    /// same number: a chip with one port calls it nothing at all.
    channel: ftdi.Channel = ftdi.ONE_PORT,
    ops: hc.HcOps = undefined,
    zero: usb.Pipe = .{},
    /// Kept rather than opened once, because the read only stands while
    /// somebody has the port and each standing read begins afresh.
    reading: usb.Pipe = .{},
    writing: usb.Pipe = .{},
    reading_at: u8 = 0,
    writing_at: u8 = 0,
    /// How large a packet is, which is how what arrives is split.
    packet: u16 = 0,
    /// How much one standing read asks for.
    wanted: u16 = 0,
    watch: ?u8 = null,
    /// What was last said about the line, so the same thing arriving on
    /// the head of every packet is said once.
    state: State = .{},
    line: Line = DEFAULT,

    fn which(self: *const Port) serial.Which {
        return .{ .address = self.address, .interface = self.interface };
    }
};

var ports: [MAX_PORTS]Port = @splat(.{});

pub const ops = class.ClassOps{ .attach = attach, .detach = detach, .woke = woke };
pub const driver = class.ClassDriver{ .name = name, .ops = ops };

/// What a serial port does, for the service that offers it.
///
/// No way to hold the line at break: the chip has a bit for it and no
/// timer, so holding it would mean this service doing nothing else for
/// as long as it lasted.
const serial_ops = serial.Ops{
    .setLine = setLine,
    .hold = hold,
    .send = send,
    .opened = opened,
};

// ---------------------------------------------------------------------------
// Coming and going
// ---------------------------------------------------------------------------

fn attach(target: class.Target) bool {
    if (target.descriptor.vendor != ftdi.VENDOR or !ftdi.known(target.descriptor.product)) {
        log.warn(name, "the device is not one of the parts this drives");
        return false;
    }

    const configuration = usb.Configuration.parse(target.configuration) orelse {
        log.warn(name, "the device's configuration will not read");
        return false;
    };
    const limit = target.ops.watchLimit();

    // One port per interface that carries a bulk pair. A chip with one
    // of them names it nothing in its requests; one with several numbers
    // them from one, which is why this is not the interface number.
    var offered: usize = 0;
    for (0..configuration.interfaces) |i| {
        const number: u8 = @intCast(i);
        const view = usb.interfaceIn(target.configuration, .{ .numbered = number }) orelse continue;
        const read = view.find(.bulk, .in) orelse continue;
        const write = view.find(.bulk, .out) orelse continue;
        if (read.max_packet <= ftdi.HEADER) continue;
        const wanted = usb.cdc.readSize(read.max_packet, limit) orelse continue;

        const slot = table.free(&ports) orelse break;
        slot.* = .{
            .live = true,
            .address = target.address,
            .interface = number,
            .channel = if (configuration.interfaces <= 1)
                ftdi.ONE_PORT
            else
                @intCast(i + 1),
            .ops = target.ops,
            .zero = target.zero(),
            .reading = target.pipe(read),
            .writing = target.pipe(write),
            .reading_at = read.address().byte(),
            .writing_at = write.address().byte(),
            .packet = read.max_packet,
            .wanted = wanted,
        };

        settle(slot);
        if (serial.offer(slot.which(), &serial_ops, .{
            .vendor = target.descriptor.vendor,
            .product = target.descriptor.product,
            // What its line is doing comes in front of the bytes, so
            // there is always something to say; it is simply only said
            // while somebody has the port open.
            .reports = true,
            .line = DEFAULT,
            .held = HOLDING,
        })) {
            offered += 1;
        } else {
            slot.* = .{};
        }
    }

    if (offered == 0) log.warn(name, "the device carries no port this drives");
    return offered != 0;
}

/// Put a port where it should start: nothing held over from whatever the
/// last machine was doing with it, and a line somebody could use.
///
/// Every one of these is carried past rather than checked, which is what
/// the reference drivers do: a chip that refuses one of them and works
/// perfectly well is a chip somebody owns.
fn settle(port: *Port) void {
    const asks = [_]usb.Setup{
        ftdi.reset(port.channel, .everything),
        ftdi.setFlow(port.channel, .none),
        ftdi.setLatency(port.channel, ftdi.LATENCY_MS),
        ftdi.setData(port.channel, DEFAULT, false),
        ftdi.setBaud(port.channel, DEFAULT.rate),
        ftdi.setLines(port.channel, HOLDING),
    };
    for (asks) |ask| hc.command(port.ops, port.zero, ask) catch {};
}

fn detach(address: u7) void {
    serial.withdraw(address);
    for (&ports) |*port| {
        if (!port.live or port.address != address) continue;
        stopReading(port);
        port.* = .{};
    }
}

// ---------------------------------------------------------------------------
// Only while somebody is listening
// ---------------------------------------------------------------------------

fn opened(which: serial.Which, open: bool) void {
    const port = forWhich(which) orelse return;
    if (!open) return stopReading(port);
    if (port.watch != null) return;

    // Both pipes out of whatever halt or half-finished conversation the
    // last program left, which puts the device's own count of packets
    // back to the beginning as well. Without it a fresh read is a packet
    // out of step with the device and the transfer never completes.
    for ([_]u8{ port.reading_at, port.writing_at }) |endpoint| {
        hc.command(port.ops, port.zero, usb.Setup.clearHalt(endpoint)) catch {};
    }
    hc.command(port.ops, port.zero, ftdi.reset(port.channel, .everything)) catch {};
    port.reading.toggle = false;
    port.writing.toggle = false;

    port.watch = port.ops.watch(port.reading, port.wanted) catch {
        log.warn(name, "the controller would not read the device");
        return;
    };
}

fn stopReading(port: *Port) void {
    const watch = port.watch orelse return;
    port.ops.unwatch(watch);
    port.watch = null;
}

// ---------------------------------------------------------------------------
// What arrived
// ---------------------------------------------------------------------------

fn woke() void {
    var buffer: [READ_MAX]u8 = undefined;
    for (&ports) |*port| {
        const watch = if (port.live) port.watch orelse continue else continue;
        while (port.ops.collect(watch, &buffer)) |moved| {
            if (moved == 0) break;
            unpack(port, buffer[0..moved]);
        }
    }
}

/// One answer from the chip, which is several packets each with its own
/// two bytes of state in front of it. Where they divide is arithmetic,
/// and it is in `ftdi/regs.zig` where it is checked on the build machine.
fn unpack(port: *Port, bytes: []const u8) void {
    var packets = ftdi.packetsIn(bytes, port.packet);
    while (packets.next()) |piece| {
        said(port, piece.state);
        if (piece.bytes.len != 0) serial.arrived(port.which(), piece.bytes);
    }
}

/// What the line is doing, passed on only when it changed: the same
/// answer arrives in front of every packet, and a program woken for each
/// of them would be woken for nothing.
fn said(port: *Port, state: State) void {
    if (state.word() == port.state.word()) return;
    port.state = state;
    serial.said(port.which(), state);
}

// ---------------------------------------------------------------------------
// What a port does
// ---------------------------------------------------------------------------

fn forWhich(which: serial.Which) ?*Port {
    for (&ports) |*port| {
        if (!port.live) continue;
        if (port.address == which.address and port.interface == which.interface) return port;
    }
    return null;
}

fn setLine(which: serial.Which, line: Line) bool {
    const port = forWhich(which) orelse return false;
    hc.command(port.ops, port.zero, ftdi.setData(port.channel, line, false)) catch return false;
    hc.command(port.ops, port.zero, ftdi.setBaud(port.channel, line.rate)) catch return false;
    port.line = line;
    return true;
}

fn hold(which: serial.Which, held: Held) bool {
    const port = forWhich(which) orelse return false;
    hc.command(port.ops, port.zero, ftdi.setLines(port.channel, held)) catch return false;
    return true;
}

/// Send what a program wrote. Nothing rides in front of it: the two
/// status bytes are the chip's to say and go only the other way.
fn send(which: serial.Which, bytes: []u8) usize {
    const port = forWhich(which) orelse return 0;
    const limit = port.ops.bulkLimit();
    if (limit == 0) return 0;

    var moved: usize = 0;
    while (moved < bytes.len) {
        const take = @min(bytes.len - moved, limit);
        const sent = port.ops.bulk(&port.writing, bytes[moved..][0..take]) catch break;
        moved += sent;
        if (sent < take) break;
    }
    return moved;
}
