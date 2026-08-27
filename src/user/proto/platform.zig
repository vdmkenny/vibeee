//! What a program asks `platd` for.
//!
//! Everything here goes through the firmware's own methods, which is the whole
//! reason it is a service rather than a syscall: entering a sleep state means
//! evaluating `_PTS` and the `_S5_` package the BIOS shipped, and reading a
//! battery means evaluating `_BST` over the embedded controller. None of that
//! can be worked out from outside, and an interpreter belongs in a process.

const std = @import("std");
const sys = @import("sys");

pub const SERVICE = "platform";

pub const Tag = enum(u8) {
    /// Off. The firmware is asked properly, which is what this exists for.
    power_off,
    /// Off and on again.
    reboot,
};

pub const Req = extern struct {
    tag: Tag,
    _reserved: [3]u8 = @splat(0),
};

pub const Status = enum(u8) {
    ok,
    /// The firmware refused, or there is no method for it.
    refused,
    /// Nothing here answers that.
    unknown,
};

pub const Rep = extern struct {
    status: Status = .ok,
    _reserved: [3]u8 = @splat(0),
};

pub const Error = error{ NoService, Refused };

/// Ask, and say whether it was done.
///
/// A power-off that works never returns, so a reply is by itself the news that
/// it did not: the machine is still running to receive one.
pub fn ask(tag: Tag) Error!void {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) return error.NoService;
    defer _ = sys.close(@intCast(channel));

    const request = Req{ .tag = tag };
    const message = sys.Message.init(std.mem.asBytes(&request), &.{});

    var reply = sys.Message{};
    if (sys.callMsg(@intCast(channel), &message, &reply) < 0) return error.Refused;

    const bytes = reply.bytes();
    if (bytes.len < @sizeOf(Rep)) return error.Refused;
    if (@as(*const Rep, @alignCast(@ptrCast(bytes.ptr))).status != .ok) return error.Refused;
}
