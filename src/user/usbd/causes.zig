//! Interrupt causes latched in a host controller's status register.
//!
//! A pass over a controller's interrupt reads the status register, takes
//! the causes it handles, and reads again until none is latched: a cause
//! that latches after a read keeps the line asserted, and an edge-triggered
//! line raises no new interrupt for it.

const std = @import("std");

/// Status reads in one pass. Bounds a pass over a controller that keeps
/// latching causes.
pub const ROUNDS = 8;

/// The flags set in both `latched` and `taken`, matched by field name.
/// `latched` has a flag for every flag of `taken`; other fields read as
/// their defaults.
pub fn intersect(latched: anytype, taken: anytype) @TypeOf(latched) {
    var both: @TypeOf(latched) = .{};
    inline for (std.meta.fields(@TypeOf(taken))) |field| {
        if (field.type != bool) continue;
        @field(both, field.name) = @field(latched, field.name) and @field(taken, field.name);
    }
    return both;
}

const testing = std.testing;

const Status = packed struct(u8) {
    transfer: bool = false,
    port_change: bool = false,
    rollover: bool = false,
    _3: u4 = 0,
    halted: bool = false,
};

const Enable = packed struct(u8) {
    transfer: bool = false,
    port_change: bool = false,
    rollover: bool = false,
    _3: u5 = 0,
};

test "the causes taken are the latched flags that are also enabled" {
    const latched = Status{ .transfer = true, .rollover = true, .halted = true };
    const taken = intersect(latched, Enable{ .transfer = true, .port_change = true });
    try testing.expectEqual(Status{ .transfer = true }, taken);
}

test "a status with nothing enabled latched takes nothing" {
    const latched = Status{ .rollover = true, .halted = true };
    try testing.expectEqual(Status{}, intersect(latched, Enable{ .transfer = true, .port_change = true }));
    try testing.expectEqual(Status{}, intersect(Status{ .transfer = true }, Enable{}));
}

test "a word intersected with its own type keeps only shared flags" {
    const latched = Status{ .transfer = true, .port_change = true };
    try testing.expectEqual(Status{ .port_change = true }, intersect(latched, Status{ .port_change = true, .halted = true }));
}
