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
    descriptor: usb.Device,
    signature: usb.Signature,
    /// The configuration as the device wrote it, for finding interfaces
    /// and endpoints in.
    configuration: []const u8,
    ops: hc.HcOps,

    /// A pipe on this device from an endpoint of its configuration.
    pub fn pipe(self: Target, endpoint: usb.Endpoint) usb.Pipe {
        return endpoint.open(self.address, self.speed);
    }

    /// A control transfer to this device's endpoint zero.
    pub fn control(self: Target, setup: usb.Setup, data: []u8) hc.Error!usize {
        return self.ops.control(self.address, self.speed, self.descriptor.max_packet_zero, setup, data);
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
};

pub const ClassDriver = struct {
    name: []const u8,
    ops: ClassOps,
};
