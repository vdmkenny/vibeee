//! A device's register window, addressed by name.
//!
//! Every driver maps an aperture and reaches registers inside it at fixed
//! offsets. The window lives here so the volatile access and the alignment
//! proof are written once: a register enum names the offsets, the window is
//! instantiated for the width they are reached at, and the instantiation
//! itself proves every offset is aligned for that width. A misaligned MMIO
//! access splits into two bus transactions on this architecture and lands
//! as something else entirely on others, so the build refuses it rather
//! than the machine discovering it.

const std = @import("std");

/// A mapped aperture whose registers are named by `Register` and reached
/// `Access` bytes at a time. A device with registers of several widths
/// instantiates one window per width over the same base, which is what
/// keeps a byte register from being written as a word.
pub fn Window(comptime Register: type, comptime Access: type) type {
    comptime checkOffsets(Register, @sizeOf(Access));

    return struct {
        const Self = @This();

        base: [*]volatile u8,

        pub fn read(self: Self, register: Register) Access {
            return self.cell(@intFromEnum(register)).*;
        }

        pub fn write(self: Self, register: Register, value: Access) void {
            self.cell(@intFromEnum(register)).* = value;
        }

        /// A register whose offset is computed rather than named: a bank
        /// the hardware repeats, a key cache slot. The caller owns the
        /// arithmetic and the bounds; the alignment is checked here.
        pub fn readAt(self: Self, offset: usize) Access {
            std.debug.assert(offset % @sizeOf(Access) == 0);
            return self.cell(offset).*;
        }

        pub fn writeAt(self: Self, offset: usize, value: Access) void {
            std.debug.assert(offset % @sizeOf(Access) == 0);
            self.cell(offset).* = value;
        }

        /// The same aperture, seen through another register set. One map,
        /// several vocabularies.
        pub fn as(self: Self, comptime Other: type, comptime OtherAccess: type) Window(Other, OtherAccess) {
            return .{ .base = self.base };
        }

        fn cell(self: Self, offset: usize) *volatile Access {
            return @ptrCast(@alignCast(self.base + offset));
        }
    };
}

/// Prove every offset in a register set is aligned for a given width.
/// Called for you by `Window`; public because a driver whose registers
/// arrive through some other mechanism still wants the proof.
pub fn checkOffsets(comptime Register: type, comptime width: usize) void {
    comptime {
        if (@typeInfo(Register) != .@"enum") {
            @compileError("a register set is an enum of byte offsets");
        }
        for (std.meta.fields(Register)) |field| {
            if (field.value % width != 0) {
                @compileError("register " ++ field.name ++ " is misaligned for its access width");
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Word = enum(usize) { first = 0, second = 4 };
const Half = enum(usize) { low = 8, high = 10 };
const Byte = enum(usize) { flag = 12 };

test "a window reads back what it wrote, at the named offsets" {
    var store: [16]u8 align(4) = @splat(0);
    const words = Window(Word, u32){ .base = &store };

    words.write(.first, 0xDEAD_BEEF);
    words.write(.second, 0x1234_5678);

    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), words.read(.first));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), words.read(.second));
    // Little endian, and each register kept to its own bytes.
    try std.testing.expectEqual(@as(u8, 0xEF), store[0]);
    try std.testing.expectEqual(@as(u8, 0x78), store[4]);
}

test "one aperture serves several widths without confusing them" {
    var store: [16]u8 align(4) = @splat(0);
    const words = Window(Word, u32){ .base = &store };
    const halves = words.as(Half, u16);
    const bytes = words.as(Byte, u8);

    halves.write(.low, 0xABCD);
    halves.write(.high, 0x1122);
    bytes.write(.flag, 0x5A);

    try std.testing.expectEqual(@as(u16, 0xABCD), halves.read(.low));
    try std.testing.expectEqual(@as(u16, 0x1122), halves.read(.high));
    try std.testing.expectEqual(@as(u8, 0x5A), bytes.read(.flag));
    // The word window sees the two halves as one register.
    try std.testing.expectEqual(@as(u32, 0x1122_ABCD), words.as(Word, u32).readAt(8));
}

test "a computed offset reaches a repeated bank" {
    var store: [32]u8 align(4) = @splat(0);
    const words = Window(Word, u32){ .base = &store };

    for (0..8) |i| words.writeAt(i * 4, @intCast(i * 0x11));
    for (0..8) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i * 0x11)), words.readAt(i * 4));
    }
}
