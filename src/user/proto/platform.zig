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
    /// One device from the firmware's namespace, by position. How a caller
    /// finds out what this machine actually offers.
    device,
    /// One name under a named device, by position. What the six columns of
    /// `device` cannot say: a vendor's methods are called whatever the vendor
    /// called them, and nothing can guess at those.
    child,
};

pub const Req = extern struct {
    tag: Tag,
    /// Which one, for the requests that walk a list.
    index: u8 = 0,
    _reserved: [2]u8 = @splat(0),
    /// Whose children to walk, for `child`. Four characters, because that is
    /// what a namespace name is.
    name: [4]u8 = @splat(0),
};

pub const Status = enum(u8) {
    ok,
    /// The firmware refused, or there is no method for it.
    refused,
    /// Nothing here answers that.
    unknown,
    /// Nothing at that position. How a caller walking a list finds the end.
    end,
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

/// The methods worth knowing a device has.
///
/// Presence, not behaviour: whether the firmware defines the method. What it
/// does when called is its own business and is not asked here.
pub const Methods = packed struct(u8) {
    /// `_BCL`: the brightness levels this panel accepts.
    brightness_levels: bool = false,
    /// `_BCM`: set one of them.
    brightness_set: bool = false,
    /// `_BQC`: which one is in use.
    brightness_now: bool = false,
    /// `_BIF`: what a battery was built as.
    battery_info: bool = false,
    /// `_BST`: what it is doing.
    battery_state: bool = false,
    /// `_STA`: whether the device is there and switched on.
    power_state: bool = false,
    _reserved: u2 = 0,
};

pub const Device = extern struct {
    /// Four characters, which is all the format has room for.
    name: [4]u8 = @splat(0),
    methods: Methods = .{},
    _reserved: [3]u8 = @splat(0),
};

pub const Rep = extern struct {
    status: Status = .ok,
    _reserved: [3]u8 = @splat(0),
    battery: Battery = .{},
    device: Device = .{},
};

comptime {
    if (@sizeOf(Rep) > sys.MAX_PAYLOAD) {
        @compileError("a platform reply must fit in one channel payload");
    }
}

pub const Error = error{ NoService, Refused, End };

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
    return callAt(tag, 0, into);
}

pub fn callAt(tag: Tag, index: u8, into: *Rep) Error!void {
    return callUnder(tag, "", index, into);
}

/// The same, naming what to look under.
pub fn callUnder(tag: Tag, name: []const u8, index: u8, into: *Rep) Error!void {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) return error.NoService;
    defer _ = sys.close(@intCast(channel));

    var request = Req{ .tag = tag, .index = index };
    @memcpy(request.name[0..@min(name.len, 4)], name[0..@min(name.len, 4)]);

    const message = sys.Message.init(std.mem.asBytes(&request), &.{});

    var reply = sys.Message{};
    if (sys.callMsg(@intCast(channel), &message, &reply) < 0) return error.Refused;

    const bytes = reply.bytes();
    if (bytes.len < @sizeOf(Rep)) return error.Refused;

    into.* = @as(*const Rep, @alignCast(@ptrCast(bytes.ptr))).*;

    return switch (into.status) {
        .ok => {},
        .end => error.End,
        else => error.Refused,
    };
}
