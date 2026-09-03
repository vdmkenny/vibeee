//! An address in the machine's own address space.
//!
//! Distinct from an ordinary number because nothing else tells the two
//! apart, and the difference is the one a bus master cannot survive being
//! wrong about. A driver programs a device with one of these; hand it an
//! address from a process's own space instead and the device writes to
//! whatever happens to live at that number, which on this machine is
//! whatever the kernel put there. There is no unit between a device and
//! memory that would refuse it.
//!
//! So the conversion is spelled out at both ends. Where a driver writes
//! one of these into a device register it says `.addr()`, which is the
//! moment worth being able to find.

const std = @import("std");

pub const Phys = enum(u32) {
    /// No address. What an unassigned window reads as, and what a device
    /// is given to stop it addressing anything at all.
    none = 0,
    _,

    pub fn of(value: u32) Phys {
        return @enumFromInt(value);
    }

    /// The number a device is programmed with.
    pub fn addr(self: Phys) u32 {
        return @intFromEnum(self);
    }

    pub fn isSet(self: Phys) bool {
        return self != .none;
    }

    /// A place `offset` bytes further on, or null where that would leave
    /// the addresses this machine has. A run of descriptors is addressed
    /// this way and the sum is the one a driver gets wrong.
    pub fn plus(self: Phys, offset: u32) ?Phys {
        const sum = std.math.add(u32, self.addr(), offset) catch return null;
        return of(sum);
    }
};

test "an address knows itself from a number" {
    const at = Phys.of(0x0026_3000);
    try std.testing.expectEqual(@as(u32, 0x0026_3000), at.addr());
    try std.testing.expect(at.isSet());
    try std.testing.expect(!Phys.none.isSet());
}

test "a run that leaves the machine's addresses has no end" {
    try std.testing.expectEqual(Phys.of(0x1000), Phys.of(0).plus(0x1000).?);
    try std.testing.expect(Phys.of(0xFFFF_F000).plus(0x2000) == null);
}
