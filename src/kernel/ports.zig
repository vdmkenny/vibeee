//! Which I/O ports a process may touch.
//!
//! Held by the kernel on the architecture's behalf: port I/O is an x86 notion,
//! but the set belongs to a process and the kernel is what owns processes. What
//! the bits are copied into, and how the CPU consults them, is `arch`'s
//! business and stays there.
//!
//! Stored as denials because that is what the hardware reads: a set bit traps.
//! Naming the inversion once, here, is the whole reason this is a type rather
//! than a bare array that every caller has to remember to invert.

const std = @import("std");

/// Every port an x86 machine has.
pub const COUNT = 65536;

pub const BYTES = COUNT / 8;

pub const PortSet = struct {
    denied: std.StaticBitSet(COUNT) = std.StaticBitSet(COUNT).initFull(),

    /// Let `count` ports through, starting at `base`.
    pub fn allow(self: *PortSet, base: usize, count: usize) void {
        if (count == 0) return;
        self.denied.setRangeValue(.{ .start = base, .end = @min(base + count, COUNT) }, false);
    }

    pub fn deny(self: *PortSet, base: usize, count: usize) void {
        if (count == 0) return;
        self.denied.setRangeValue(.{ .start = base, .end = @min(base + count, COUNT) }, true);
    }

    pub fn allows(self: *const PortSet, port: usize) bool {
        return port < COUNT and !self.denied.isSet(port);
    }

    /// The bits as the hardware wants them: one byte per eight ports, lowest
    /// port in the lowest bit.
    pub fn bytes(self: *const PortSet) *const [BYTES]u8 {
        return @ptrCast(&self.denied.masks);
    }
};

comptime {
    // The hardware reads a flat little-endian bitmap. A bit set stores its
    // masks in the same order on this architecture, which is what makes the
    // cast above a view rather than a conversion.
    if (@sizeOf(std.StaticBitSet(COUNT)) != BYTES) {
        @compileError("the port set must be exactly the bitmap the hardware reads");
    }
    if (@import("builtin").cpu.arch.endian() != .little) {
        @compileError("the port bitmap's byte order follows the architecture's");
    }
}

test "allowing a range leaves everything else denied" {
    var set = PortSet{};
    try std.testing.expect(!set.allows(0x80));

    set.allow(0x80, 1);
    try std.testing.expect(set.allows(0x80));
    try std.testing.expect(!set.allows(0x7F));
    try std.testing.expect(!set.allows(0x81));
}

test "a range crosses byte boundaries without gaps" {
    var set = PortSet{};
    set.allow(0x1F0, 8);

    for (0x1F0..0x1F8) |port| try std.testing.expect(set.allows(port));
    try std.testing.expect(!set.allows(0x1EF));
    try std.testing.expect(!set.allows(0x1F8));
}

test "grants accumulate rather than replace" {
    var set = PortSet{};
    set.allow(0x60, 1);
    set.allow(0x64, 1);

    try std.testing.expect(set.allows(0x60));
    try std.testing.expect(set.allows(0x64));
    try std.testing.expect(!set.allows(0x62));
}

test "the lowest port is the lowest bit of the first byte" {
    var set = PortSet{};
    set.allow(0, 1);
    // Denials are ones, so allowing port 0 clears bit 0.
    try std.testing.expectEqual(@as(u8, 0xFE), set.bytes()[0]);
}
