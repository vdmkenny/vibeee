//! What a driver for a kind of device compiles against.
//!
//! A controller driver knows about schedules; a class driver knows about
//! what a device does. Between them is this: a device that has been
//! addressed and described, and the controller it is reached through.
//! Nothing here knows which classes exist, which is what lets the bus
//! carry a driver it was not built around.

const hc = @import("hc.zig");
const usb = @import("lib").usb;

/// One enumerated device, handed to whichever driver the device manager
/// named for it.
pub const Target = struct {
    address: u7,
    speed: usb.Speed,
    /// Where it sits, which is how a driver names what it found and how
    /// it recognises the same device again after a restart.
    controller: u8,
    port: u8,
    /// Which hub carries it, if any. Travels with every transfer,
    /// because a fast controller reaching a slow device through a hub
    /// has to address the split halves at the hub itself.
    route: usb.Route = .{},
    descriptor: usb.Device,
    signature: usb.Signature,
    /// The configuration as the device wrote it, for finding interfaces
    /// and endpoints in.
    configuration: []const u8,
    ops: hc.HcOps,

    /// A pipe on this device from an endpoint of its configuration.
    pub fn pipe(self: Target, endpoint: usb.Endpoint) usb.Pipe {
        return endpoint.open(self.address, self.speed, self.route);
    }

    /// The device's own control endpoint, which every request goes to.
    pub fn zero(self: Target) usb.Pipe {
        return .{
            .address = self.address,
            .speed = self.speed,
            .max_packet = self.descriptor.max_packet_zero,
            .route = self.route,
        };
    }

    /// A control transfer to this device's endpoint zero.
    pub fn control(self: Target, setup: usb.Setup, data: []u8) hc.Error!usize {
        return self.ops.control(self.zero(), setup, data);
    }

    /// The same, for a request that carries nothing.
    pub fn command(self: Target, setup: usb.Setup) hc.Error!void {
        return hc.command(self.ops, self.zero(), setup);
    }
};

/// What a class driver must provide.
pub const ClassOps = struct {
    /// Take a device. Answering false leaves it listed and undriven,
    /// which is what an unfamiliar variant of a familiar class should
    /// look like rather than a failure.
    attach: *const fn (target: Target) bool,
    /// Give it up: it was unplugged, or the driver is being stopped.
    detach: *const fn (address: u7) void,
    /// The controller interrupted. A driver with endpoints being watched
    /// looks at them here; one without does not need this at all.
    woke: ?*const fn () void = null,
};

pub const ClassDriver = struct {
    name: []const u8,
    ops: ClassOps,
};
