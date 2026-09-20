//! One host controller, whichever kind it is.
//!
//! The shape every controller driver compiles against, so the bus above
//! sees an EHCI and a UHCI as one thing: ports that report what is
//! plugged into them, and a way to ask a device a question. Enumeration,
//! addressing and driver matching all live above this line and know
//! nothing about schedules or frame lists.

const pci = @import("ulib").pci;
const usb = @import("lib").usb;

/// What a port currently is.
pub const PortState = struct {
    connected: bool = false,
    /// Set once the port has been reset and the device may be addressed.
    enabled: bool = false,
    /// Meaningless until enabled.
    speed: usb.Speed = .high,
    /// Whether the connection changed since last asked, which is what
    /// makes a port worth looking at again.
    changed: bool = false,
    /// The port belongs to another controller: a full or low speed
    /// device on a high speed controller's port is handed to its
    /// companion rather than driven here.
    released: bool = false,
};

pub const Error = error{
    /// The device did not answer in time.
    Timeout,
    /// The device answered, and the answer was a failure.
    Stalled,
    /// The controller could not carry the request at all.
    Refused,
};

/// What one pass over a controller's interrupt amounted to.
pub const Service = enum {
    quiet,
    /// Causes were acknowledged, and nothing above the controller has to
    /// act on them. On a shared edge line, saying so at the
    /// acknowledgement wakes the line's other owners.
    serviced,
    ports_changed,
    /// The controller was reset and rebuilt, or closed for good: every
    /// device the bus knew on it describes a conversation that no longer
    /// exists.
    reborn,
};

/// Outcome of one wait step during a transfer.
///
/// A wait acknowledges transfer and failure causes only. A root port change
/// stays latched and a rebuild is recorded, and `serviceIrq` reports both:
/// after the transfer the controller interrupts again, or, on a controller
/// with no interrupt for them, `serviceDue` says so.
pub const Rest = enum {
    waited,
    /// Causes were acknowledged. On a shared edge line, saying so at the
    /// acknowledgement wakes the line's other owners.
    worked,
    /// The controller failed and was rebuilt or closed. The transfer's
    /// schedule no longer exists.
    reborn,
};

/// What a controller must provide.
pub const HcOps = struct {
    /// Map registers, take the controller from the firmware, and start
    /// its schedules. No ports touched yet.
    open: *const fn (loc: pci.Location) bool,
    /// How many ports this controller has.
    ports: *const fn () u8,
    /// One port's state, from the controller's own registers.
    port: *const fn (index: u8) PortState,
    /// Reset a port and leave it enabled, or released to a companion.
    /// Returns the state it settled in.
    resetPort: *const fn (index: u8) PortState,
    /// Acknowledge whatever the controller interrupted about, and say
    /// what it amounted to: nothing, a port changing, or the controller
    /// having been rebuilt underneath everything the bus knew about it.
    serviceIrq: *const fn () Service,
    /// One control transfer on a device's endpoint zero. The pipe says
    /// who, how fast, how big a packet, and by what route; `data` is the
    /// buffer for the data stage, empty for none. Returns how many bytes
    /// moved.
    control: *const fn (pipe: usb.Pipe, setup: usb.Setup, data: []u8) Error!usize,
    /// One bulk transfer on an open pipe, in whichever direction the pipe
    /// runs. The pipe's toggle is advanced by what actually moved, so a
    /// short answer leaves it where the device thinks it is.
    bulk: *const fn (pipe: *usb.Pipe, data: []u8) Error!usize,
    /// The largest bulk transfer this controller will carry in one go.
    /// A driver moving more than this splits it and keeps its own place.
    bulkLimit: *const fn () usize,
    /// Leave a read standing on an endpoint that reads. The controller
    /// visits it in hardware and interrupts only when the device answers
    /// with something, so a keyboard nobody is typing on and a serial
    /// port nobody is sending to both cost nothing.
    ///
    /// For an interrupt endpoint that is the endpoint's own polling; for
    /// a bulk one it is the same standing question, asked once a frame.
    /// Either way `wanted` is how much is asked for each time, which must
    /// be at least one of the endpoint's packets: a device answering with
    /// more than was asked for is a failed transfer, not a truncated one.
    watch: *const fn (pipe: usb.Pipe, wanted: u16) Error!u8,
    /// Whatever arrived on a watched endpoint since last asked. The watch
    /// is re-armed by the asking, so a caller that stops asking stops
    /// receiving.
    collect: *const fn (watch: u8, into: []u8) ?usize,
    /// The most one watch will take in at a time, which bounds how much
    /// a device may send between two visits without losing any.
    watchLimit: *const fn () usize,
    /// Stop watching, because the device is gone.
    unwatch: *const fn (watch: u8) void,
    /// Stop the schedules and leave the controller doing nothing, for a
    /// machine about to take the power away from it.
    ///
    /// Everything the bus knew about the devices on it describes a
    /// conversation that will not survive: nothing may be asked of the
    /// controller again until `rebuild`.
    quiesce: *const fn () void,
    /// Build it again after it has lost its state: schedules running, and
    /// its ports the caller's to walk afresh, as at the first open.
    /// Answering false leaves the controller closed.
    rebuild: *const fn () bool,
    /// Whether a transfer's wait left a port change or a rebuild for
    /// `serviceIrq` that raises no interrupt. Null for a controller whose
    /// waits disable such an interrupt and enable it again after the
    /// transfer.
    serviceDue: ?*const fn () bool = null,
};

/// A control transfer that carries no data: a request goes out and only
/// its status comes back. Most of what a class driver sends is this, so
/// it is written once rather than once per driver.
pub fn command(ops: HcOps, pipe: usb.Pipe, setup: usb.Setup) Error!void {
    var nothing: [0]u8 = .{};
    _ = try ops.control(pipe, setup, &nothing);
}

/// One driver body bound to one of its units at compile time: the ops table
/// stays instance-blind and the binding costs nothing at run time.
///
/// For a chipset that carries several controllers of one kind as separate
/// functions. `Driver` keeps them in `units` and takes one first in each of
/// `open`, `portCount`, `portState`, `resetPort`, `serviceIrq`, `control`,
/// `bulk`, `bulkLimit`, `watch`, `collect`, `watchLimit`, `unwatch`,
/// `quiesce`, `rebuild` and `listen`, and in `serviceDue` if it declares one.
pub fn unitOps(comptime Driver: type, comptime unit: usize) HcOps {
    const bound = Bound(Driver, unit);
    return .{
        .open = bound.open,
        .ports = bound.ports,
        .port = bound.port,
        .resetPort = bound.resetPort,
        .serviceIrq = bound.serviceIrq,
        .control = bound.control,
        .bulk = bound.bulk,
        .bulkLimit = bound.bulkLimit,
        .watch = bound.watch,
        .collect = bound.collect,
        .watchLimit = bound.watchLimit,
        .unwatch = bound.unwatch,
        .quiesce = bound.quiesce,
        .rebuild = bound.rebuild,
        .serviceDue = if (@hasDecl(Driver, "serviceDue")) bound.serviceDue else null,
    };
}

/// Where a bound unit is told its interrupt line.
pub fn unitListen(comptime Driver: type, comptime unit: usize) *const fn (u32) void {
    return Bound(Driver, unit).listen;
}

fn Bound(comptime Driver: type, comptime unit: usize) type {
    return struct {
        const self = &Driver.units[unit];

        fn open(loc: pci.Location) bool {
            return Driver.open(self, loc);
        }
        fn ports() u8 {
            return Driver.portCount(self);
        }
        fn port(index: u8) PortState {
            return Driver.portState(self, index);
        }
        fn resetPort(index: u8) PortState {
            return Driver.resetPort(self, index);
        }
        fn serviceIrq() Service {
            return Driver.serviceIrq(self);
        }
        fn control(pipe: usb.Pipe, setup: usb.Setup, data: []u8) Error!usize {
            return Driver.control(self, pipe, setup, data);
        }
        fn bulk(pipe: *usb.Pipe, data: []u8) Error!usize {
            return Driver.bulk(self, pipe, data);
        }
        fn bulkLimit() usize {
            return Driver.bulkLimit(self);
        }
        fn watch(pipe: usb.Pipe, wanted: u16) Error!u8 {
            return Driver.watch(self, pipe, wanted);
        }
        fn collect(index: u8, into: []u8) ?usize {
            return Driver.collect(self, index, into);
        }
        fn watchLimit() usize {
            return Driver.watchLimit(self);
        }
        fn unwatch(index: u8) void {
            Driver.unwatch(self, index);
        }
        fn quiesce() void {
            Driver.quiesce(self);
        }
        fn rebuild() bool {
            return Driver.rebuild(self);
        }
        fn serviceDue() bool {
            return Driver.serviceDue(self);
        }
        fn listen(irq: u32) void {
            Driver.listen(self, irq);
        }
    };
}

/// One driven controller and what the bus knows about it.
pub const Controller = struct {
    name: []const u8,
    ops: HcOps,
    location: pci.Location,
    irq: u32 = 0,
    irq_gsi: ?u32 = null,
};
