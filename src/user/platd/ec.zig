//! The embedded controller, driven.
//!
//! Half of what this machine's firmware describes lives behind the EC: the
//! battery, the backlight, the hotkeys. The DSDT reaches all of it through an
//! EmbeddedControl operation region, and an operation region is a promise the
//! operating system has to keep: uACPI asks the host to do the actual byte
//! moving. With nobody answering, every method that touches the EC fails, and
//! the DSDT's fallback paths poll the controller by hand from AML, unbounded.
//!
//! On this machine the controller is also the keyboard controller, one KB3310
//! behind two port pairs. A wedged handshake takes the keyboard with it, which
//! is why every wait here has a deadline: a controller that stops answering
//! costs a refused method, never the machine.
//!
//! The hotkeys arrive here too. A key sets the SCI event bit, the query
//! command asks which one, and the answer names a `_Qxx` method in the DSDT.
//! Those methods are AML, so the general-purpose event only queues a drain and
//! the serve loop runs it.

const log = @import("ulib").log;
const out = @import("ulib").out;
const ports = @import("ulib").ports;
const sys = @import("sys");
const uacpi = @import("uacpi.zig");
const work = @import("work.zig");

// ---------------------------------------------------------------------------
// The controller
// ---------------------------------------------------------------------------

/// Where the firmware said it is, read from `_CRS`: data first, then
/// command/status, the order the specification fixes.
var data_port: u16 = 0;
var status_port: u16 = 0;

/// Which general-purpose event the controller raises.
var gpe: u16 = 0;
var has_gpe = false;

var node: ?*uacpi.Node = null;

pub fn present() bool {
    return node != null;
}

pub fn driven() bool {
    return node != null and status_port != 0;
}

/// The status register, as the specification lays it out.
const EcStatus = packed struct(u8) {
    /// The controller has a byte waiting to be read.
    output_full: bool = false,
    /// The controller has not yet taken the last byte written.
    input_full: bool = false,
    _2: u2 = 0,
    _command: bool = false,
    /// The query queue is not empty.
    event: bool = false,
    _6: u2 = 0,
};

fn status() EcStatus {
    return @bitCast(ports.in8(status_port));
}

/// Commands the specification defines.
const Command = enum(u8) {
    read = 0x80,
    write = 0x81,
    query = 0x84,
};

/// The longest one handshake phase may take before the controller is declared
/// unresponsive. Generous against a real answer, which arrives in microseconds.
const DEADLINE_US = 20_000;

/// How long to be off the CPU between looks when the first look said not yet.
const BREATHER_US = 50;

/// The handshake is the one register-level wait in this service, and it is a
/// wait with nothing to subscribe to: the controller offers no message for
/// "your byte is ready", only the status bit. The events it does offer, the
/// query queue, arrive as interrupts and are waited on properly. So the bit is
/// read, and between reads the thread yields rather than spins.
fn wait(comptime field: []const u8, set: bool) bool {
    const until = sys.clockMicros() + DEADLINE_US;
    while (true) {
        if (@field(status(), field) == set) return true;
        if (sys.clockMicros() >= until) return silent();
        sys.sleepMicros(BREATHER_US);
    }
}

/// Said once, the first time bytecode reaches the controller at all: the
/// boundary between interpreting and touching the machine, which is the line
/// that matters when a boot stops between the two.
var said_reached = false;

fn reached() void {
    if (said_reached) return;
    said_reached = true;
    log.say("platd", .dim, "bytecode reached the controller");
}

/// Said once. A controller that misses one deadline has usually missed them
/// all, and the first is the one that says where things stood.
var said_silent = false;

fn silent() bool {
    if (!said_silent) {
        said_silent = true;
        log.warn("platd", "the controller went silent mid-handshake");
    }
    return false;
}

fn command(cmd: Command) bool {
    if (!wait("input_full", false)) return false;
    ports.out8(status_port, @intFromEnum(cmd));
    return true;
}

fn push(byte: u8) bool {
    if (!wait("input_full", false)) return false;
    ports.out8(data_port, byte);
    return true;
}

fn pull() ?u8 {
    if (!wait("output_full", true)) return null;
    return ports.in8(data_port);
}

pub fn read(address: u8) ?u8 {
    if (!command(.read)) return null;
    if (!push(address)) return null;
    return pull();
}

pub fn write(address: u8, value: u8) bool {
    if (!command(.write)) return false;
    if (!push(address)) return false;
    return push(value);
}

/// Which event the controller is raising, or null when it is raising none.
fn query() ?u8 {
    if (!status().event) return null;
    if (!command(.query)) return null;
    const which = pull() orelse return null;
    // Zero is the controller saying the queue was empty after all.
    return if (which == 0) null else which;
}

// ---------------------------------------------------------------------------
// Finding it
// ---------------------------------------------------------------------------

/// The id the specification assigns to every embedded controller.
const HID = "PNP0C09";

/// Find the controller and take over its operation region.
///
/// Between namespace load and namespace initialisation, so `_INI` methods
/// already run with a working EC. Installing the handler is also what makes
/// uACPI evaluate `_REG`, which tells the DSDT to use the region rather than
/// its hand-rolled fallbacks.
pub fn bind() void {
    node = uacpi.firstWithHid(HID);
    const found = node orelse return;

    if (uacpi.uacpi_for_each_device_resource(found, "_CRS", takePorts, null) != .ok or
        status_port == 0)
    {
        log.warn("platd", "an embedded controller with no usable ports; leaving it alone");
        node = null;
        return;
    }

    _ = sys.ioportGrant(data_port, 1);
    _ = sys.ioportGrant(status_port, 1);

    var value: u64 = 0;
    if (uacpi.uacpi_eval_simple_integer(found, "_GPE", &value) == .ok) {
        gpe = @truncate(value);
        has_gpe = true;
    }

    // On the root, not on the controller's own node: a handler covers the
    // regions beneath where it is installed, and these DSDTs declare a
    // controller region in each consumer's own scope. One controller owns
    // the whole space on this machine.
    if (uacpi.uacpi_install_address_space_handler(
        uacpi.namespace_root(),
        .embedded_controller,
        region,
        null,
    ) != .ok) {
        log.warn("platd", "the embedded controller refused a region handler");
        node = null;
        return;
    }

    log.begin("platd", .key);
    out.text("embedded controller on ports 0x");
    out.hex(data_port, 2);
    out.text("/0x");
    out.hex(status_port, 2);
    if (has_gpe) {
        out.text(", event ");
        out.decimal(gpe);
    }
    log.end();
}

/// `_CRS` in the fixed order: the first port is data, the second is
/// command/status.
fn takePorts(_: ?*anyopaque, resource: *const uacpi.Resource) callconv(.c) uacpi.Walk {
    const port: u16 = switch (resource.kind) {
        .io => resource.body.io.minimum,
        .fixed_io => resource.body.fixed_io.address,
        else => return .proceed,
    };

    if (data_port == 0) {
        data_port = port;
        return .proceed;
    }
    status_port = port;
    return .stop;
}

// ---------------------------------------------------------------------------
// The operation region
// ---------------------------------------------------------------------------

/// What uACPI calls when AML touches an EmbeddedControl field.
///
/// Byte at a time whatever the field's width: that is the wire protocol, and
/// wider fields are the interpreter asking for consecutive bytes.
fn region(op: uacpi.RegionOp, data: ?*anyopaque) callconv(.c) uacpi.Status {
    switch (op) {
        .attach, .detach => return .ok,
        .read => {
            reached();
            const rw: *uacpi.RegionRw = @alignCast(@ptrCast(data.?));
            var value: u64 = 0;
            var i: u8 = 0;
            while (i < rw.byte_width) : (i += 1) {
                const byte = read(@truncate(rw.offset + i)) orelse return .hardware_timeout;
                value |= @as(u64, byte) << @intCast(i * 8);
            }
            rw.value = value;
            return .ok;
        },
        .write => {
            reached();
            const rw: *uacpi.RegionRw = @alignCast(@ptrCast(data.?));
            var i: u8 = 0;
            while (i < rw.byte_width) : (i += 1) {
                const byte: u8 = @truncate(rw.value >> @intCast(i * 8));
                if (!write(@truncate(rw.offset + i), byte)) return .hardware_timeout;
            }
            return .ok;
        },
        else => return .not_implemented,
    }
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/// Start listening for the controller's own event.
///
/// After general-purpose events are finalised, because the handler is
/// installed against one of them. Replaces whatever `_Lxx` the DSDT offered
/// for this event: draining the query queue is the host's job once the host
/// drives the controller.
pub fn listen() void {
    if (!driven() or !has_gpe) return;

    if (uacpi.uacpi_install_gpe_handler(null, gpe, .edge, raised, null) != .ok) {
        log.warn("platd", "the controller's event is not installable; hotkeys stay dead");
        return;
    }
    _ = uacpi.uacpi_enable_gpe(null, gpe);

    // The queue has been filling since power-on, and a controller holding a
    // query is busy to everything else that talks to it, the firmware's own
    // trap handler included: it waits for the controller to go idle while the
    // controller waits for the host to take the query. Emptied here, before
    // any method can walk into that.
    drainQueries(null);
}

/// The event fired. Interrupt context: queue the drain and get out.
fn raised(_: ?*anyopaque, _: ?*uacpi.Node, _: u16) callconv(.c) u32 {
    _ = work.submit(drainQueries, null);
    return uacpi.INTERRUPT_HANDLED | uacpi.GPE_REENABLE;
}

/// Ask the controller what happened until it says nothing more did, and run
/// the `_Qxx` method each answer names. Serve loop only: those methods are AML.
fn drainQueries(_: ?*anyopaque) callconv(.c) void {
    // Bounded by the queue a controller can hold, so a stuck event bit cannot
    // turn this into the loop that never returns.
    var rounds: u8 = 0;
    while (rounds < 16) : (rounds += 1) {
        const which = query() orelse return;
        runQuery(which);
    }
}

fn runQuery(which: u8) void {
    const HEX = "0123456789ABCDEF";
    var name = [5:0]u8{ '_', 'Q', HEX[which >> 4], HEX[which & 0xF], 0 };

    if (uacpi.uacpi_eval(node, name[0..4 :0], null, null) != .ok) {
        log.begin("platd", .dim);
        out.text("the controller raised 0x");
        out.hex(which, 2);
        out.text(" and its method failed");
        log.end();
    }
}

/// Tell every region's `_REG` that the controller is answered.
///
/// After the namespace is initialised, because installing the handler early
/// cannot run these. `_REG` is how the bytecode learns its regions work:
/// methods on this firmware test a flag `_REG` sets and take a fallback
/// through system management mode when it is clear, and one of those
/// fallbacks does not come back.
pub fn connect() void {
    if (!driven()) return;
    _ = uacpi.uacpi_reg_all_opregions(uacpi.namespace_root(), .embedded_controller);
}
