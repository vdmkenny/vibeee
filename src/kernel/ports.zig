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

    pub const Error = error{
        /// The range reaches past the last port. Refused whole rather than
        /// clamped: a caller that asked for ports the machine does not have
        /// has the wrong idea about its device, and a bitmap indexed past
        /// its end is kernel memory.
        OutOfRange,
    };

    /// The bits `count` ports from `base` occupy, or the error when they
    /// would not all fit. Checked without adding the two, since the sum of
    /// two words the caller chose can wrap back inside the range.
    fn span(base: usize, count: usize) Error!std.bit_set.Range {
        if (base >= COUNT or count > COUNT - base) return error.OutOfRange;
        return .{ .start = base, .end = base + count };
    }

    /// Let `count` ports through, starting at `base`.
    pub fn allow(self: *PortSet, base: usize, count: usize) Error!void {
        self.denied.setRangeValue(try span(base, count), false);
    }

    pub fn deny(self: *PortSet, base: usize, count: usize) Error!void {
        self.denied.setRangeValue(try span(base, count), true);
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

    try set.allow(0x80, 1);
    try std.testing.expect(set.allows(0x80));
    try std.testing.expect(!set.allows(0x7F));
    try std.testing.expect(!set.allows(0x81));
}

test "a range crosses byte boundaries without gaps" {
    var set = PortSet{};
    try set.allow(0x1F0, 8);

    for (0x1F0..0x1F8) |port| try std.testing.expect(set.allows(port));
    try std.testing.expect(!set.allows(0x1EF));
    try std.testing.expect(!set.allows(0x1F8));
}

test "grants accumulate rather than replace" {
    var set = PortSet{};
    try set.allow(0x60, 1);
    try set.allow(0x64, 1);

    try std.testing.expect(set.allows(0x60));
    try std.testing.expect(set.allows(0x64));
    try std.testing.expect(!set.allows(0x62));
}

test "the lowest port is the lowest bit of the first byte" {
    var set = PortSet{};
    try set.allow(0, 1);
    // Denials are ones, so allowing port 0 clears bit 0.
    try std.testing.expectEqual(@as(u8, 0xFE), set.bytes()[0]);
}

test "a range past the last port is refused whole, wrapped sums included" {
    var set = PortSet{};
    try std.testing.expectError(error.OutOfRange, set.allow(COUNT, 1));
    try std.testing.expectError(error.OutOfRange, set.allow(COUNT - 1, 2));
    // A base and count whose sum wraps to a small number: the pair the
    // check has to see through.
    try std.testing.expectError(error.OutOfRange, set.allow(std.math.maxInt(usize) - 1, 2));
    try std.testing.expect(!set.allows(0));
    try std.testing.expect(!set.allows(COUNT - 1));

    // The last port is reachable, and an empty range is nothing to do.
    try set.allow(COUNT - 1, 1);
    try std.testing.expect(set.allows(COUNT - 1));
    try set.allow(0x80, 0);
    try std.testing.expect(!set.allows(0x80));
}
