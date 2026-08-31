//! What the bus service says about what is plugged in.

const std = @import("std");
const sys = @import("sys");
const usb = @import("lib").usb;

pub const SERVICE = "usb";

pub const Tag = enum(u8) {
    /// How many devices are on the bus.
    count,
    /// One device, at `index`, or `end` past the table.
    device,
    /// How many host controllers are driven.
    controllers,
    /// One port's own state, by `index` across every controller's ports
    /// in turn: `body.port`, or `end` past the last.
    port,
};

pub const Status = enum(u8) { ok, refused, end };

pub const Req = extern struct {
    tag: Tag,
    _pad: [3]u8 = @splat(0),
    index: u32 = 0,
};

pub const DeviceInfo = extern struct {
    vendor: u16 = 0,
    product: u16 = 0,
    version: u16 = 0,
    /// The address the bus gave it; zero means an empty table slot.
    address: u8 = 0,
    /// One based, the way a port is labelled on a machine.
    port: u8 = 0,
    controller: u8 = 0,
    speed: usb.Speed = .high,
    class: usb.Class = .per_interface,
    subclass: u8 = 0,
    protocol: u8 = 0,
    driver_len: u8 = 0,
    driver: [15]u8 = @splat(0),
    _tail: u8 = 0,

    pub fn driverSlice(self: *const DeviceInfo) []const u8 {
        return self.driver[0..@min(self.driver_len, self.driver.len)];
    }
};

/// What a controller says about one of its ports, before anything has
/// been made of it. What `usb ports` shows, and the reason a device that
/// does not enumerate can be told apart from one that is not plugged in.
pub const PortInfo = extern struct {
    controller: u8 = 0,
    /// One based, the way a port is labelled on a machine.
    number: u8 = 0,
    connected: u8 = 0,
    enabled: u8 = 0,
    /// True when the port was handed to a companion controller, which is
    /// what happens to a full or low speed device on this bus.
    released: u8 = 0,
    speed: usb.Speed = .high,
    /// The address the bus gave whatever is here, or zero.
    address: u8 = 0,
    _tail: u8 = 0,
};

pub const Rep = extern struct {
    status: Status = .ok,
    _pad: [3]u8 = @splat(0),
    body: Body = .{ .count = 0 },
};

pub const Body = extern union {
    count: u32,
    device: DeviceInfo,
    port: PortInfo,
};

pub const Error = error{ NoService, Refused, End };

pub fn call(request: Req, into: *Rep) Error!void {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) return error.NoService;
    defer _ = sys.close(@intCast(channel));

    const message = sys.Message.init(std.mem.asBytes(&request), &.{});
    var answer = sys.Message{};
    if (sys.callMsg(@intCast(channel), &message, &answer) < 0) return error.Refused;

    const bytes = answer.bytes();
    if (bytes.len < @sizeOf(Rep)) return error.Refused;
    into.* = @as(*const Rep, @alignCast(@ptrCast(bytes.ptr))).*;

    return switch (into.status) {
        .ok => {},
        .end => error.End,
        .refused => error.Refused,
    };
}

comptime {
    if (@sizeOf(Rep) > sys.MAX_PAYLOAD) @compileError("a usb reply must fit one payload");
}
