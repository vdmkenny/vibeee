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
    /// whether any port changed while doing it.
    serviceIrq: *const fn () bool,
    /// One control transfer to `address` on endpoint zero. `data` is the
    /// buffer for the data stage, empty for none; returns how many bytes
    /// moved.
    control: *const fn (
        address: u7,
        speed: usb.Speed,
        max_packet: u16,
        setup: usb.Setup,
        data: []u8,
    ) Error!usize,
    /// One bulk transfer on an open pipe, in whichever direction the pipe
    /// runs. The pipe's toggle is advanced by what actually moved, so a
    /// short answer leaves it where the device thinks it is.
    bulk: *const fn (pipe: *usb.Pipe, data: []u8) Error!usize,
    /// The largest bulk transfer this controller will carry in one go.
    /// A driver moving more than this splits it and keeps its own place.
    bulkLimit: *const fn () usize,
};

/// One driven controller and what the bus knows about it.
pub const Controller = struct {
    name: []const u8,
    ops: HcOps,
    location: pci.Location,
    irq: u32 = 0,
    irq_gsi: ?u32 = null,
};
