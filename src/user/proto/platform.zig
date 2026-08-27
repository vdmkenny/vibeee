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
    /// What the battery is doing, and what it was built as.
    battery,
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

/// The battery as the firmware describes it.
///
/// Capacities are left in the unit the firmware reports them in rather than
/// converted, because converting milliamp-hours to milliwatt-hours needs a
/// voltage that is itself one of these numbers, and doing it here would lose
/// precision twice and hide which reading was measured.
///
/// A capacity of `UNKNOWN` is the firmware saying it does not know, which is
/// not the same as zero and is worth being able to tell apart.
pub const Battery = extern struct {
    present: u8 = 0,
    /// Capacities are in mAh rather than mWh.
    in_milliamps: u8 = 0,
    charging: u8 = 0,
    discharging: u8 = 0,
    critical: u8 = 0,
    _reserved: [3]u8 = @splat(0),

    /// What it holds now, and how fast that is changing.
    remaining: u32 = 0,
    rate: u32 = 0,
    voltage_mv: u32 = 0,

    /// What it was built to hold, and what it last managed to. The pair that
    /// says how worn it is: nothing else reports wear, it is inferred from
    /// these two and from nothing else.
    design: u32 = 0,
    last_full: u32 = 0,
    design_voltage_mv: u32 = 0,

    /// The thresholds the firmware wants acted on.
    warning: u32 = 0,
    low: u32 = 0,

    pub const UNKNOWN: u32 = 0xFFFF_FFFF;

    pub fn isPresent(self: Battery) bool {
        return self.present != 0;
    }

    /// Charge as a percentage of what it can currently hold, which is the
    /// number a person means by "how full is it".
    pub fn charge(self: Battery) ?u32 {
        return percent(self.remaining, self.last_full);
    }

    /// What it can hold against what it was built to hold. The one number that
    /// says whether the pack is worn out, and the reason `_BIF` is read at all.
    pub fn health(self: Battery) ?u32 {
        return percent(self.last_full, self.design);
    }

    fn percent(part: u32, whole: u32) ?u32 {
        if (whole == 0 or whole == UNKNOWN or part == UNKNOWN) return null;
        return @intCast(@min(@as(u64, part) * 100 / whole, 999));
    }
};

pub const Rep = extern struct {
    status: Status = .ok,
    _reserved: [3]u8 = @splat(0),
    battery: Battery = .{},
};

comptime {
    if (@sizeOf(Rep) > sys.MAX_PAYLOAD) {
        @compileError("a platform reply must fit in one channel payload");
    }
}

pub const Error = error{ NoService, Refused };

/// Ask, and say whether it was done.
///
/// A power-off that works never returns, so a reply is by itself the news that
/// it did not: the machine is still running to receive one.
pub fn ask(tag: Tag) Error!void {
    var reply = Rep{};
    return call(tag, &reply);
}

/// The same, keeping the answer. What a question rather than an instruction
/// needs.
pub fn call(tag: Tag, into: *Rep) Error!void {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) return error.NoService;
    defer _ = sys.close(@intCast(channel));

    const request = Req{ .tag = tag };
    const message = sys.Message.init(std.mem.asBytes(&request), &.{});

    var reply = sys.Message{};
    if (sys.callMsg(@intCast(channel), &message, &reply) < 0) return error.Refused;

    const bytes = reply.bytes();
    if (bytes.len < @sizeOf(Rep)) return error.Refused;

    into.* = @as(*const Rep, @alignCast(@ptrCast(bytes.ptr))).*;
    if (into.status != .ok) return error.Refused;
}
