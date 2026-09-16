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

/// A device's registers behind one base port, named by `Register`, reached
/// through `Io`'s `in8`, `in16`, `in32`, `out8`, `out16` and `out32`.
///
/// Port registers of several widths share one window: the width of each
/// access is the width of the type read or the value written, so a packed
/// struct of sixteen bits goes out as a word with no cast at the call.
pub fn PortWindow(comptime Register: type, comptime Io: type) type {
    comptime {
        if (@typeInfo(Register) != .@"enum") @compileError("a register set is an enum of port offsets");
    }

    return struct {
        const Self = @This();

        base: u16,

        pub fn read(self: Self, comptime T: type, register: Register) T {
            return self.readAt(T, @intFromEnum(register));
        }

        pub fn write(self: Self, register: Register, value: anytype) void {
            self.writeAt(@intFromEnum(register), value);
        }

        /// A register whose offset is computed: a bank the part repeats.
        pub fn readAt(self: Self, comptime T: type, offset: u16) T {
            const port = self.base + offset;
            return @bitCast(switch (@bitSizeOf(T)) {
                8 => Io.in8(port),
                16 => Io.in16(port),
                32 => Io.in32(port),
                else => @compileError("a port register is 8, 16 or 32 bits"),
            });
        }

        pub fn writeAt(self: Self, offset: u16, value: anytype) void {
            const port = self.base + offset;
            switch (@bitSizeOf(@TypeOf(value))) {
                8 => Io.out8(port, @bitCast(value)),
                16 => Io.out16(port, @bitCast(value)),
                32 => Io.out32(port, @bitCast(value)),
                else => @compileError("a port register is 8, 16 or 32 bits"),
            }
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

/// Sixty-four ports that remember what was written, and how wide.
const FakePorts = struct {
    var cells: [64]u8 = @splat(0);
    var widths: [64]u8 = @splat(0);

    fn in8(port: u16) u8 {
        return cells[port];
    }
    fn in16(port: u16) u16 {
        return std.mem.readInt(u16, cells[port..][0..2], .little);
    }
    fn in32(port: u16) u32 {
        return std.mem.readInt(u32, cells[port..][0..4], .little);
    }
    fn out8(port: u16, value: u8) void {
        cells[port] = value;
        widths[port] = 8;
    }
    fn out16(port: u16, value: u16) void {
        std.mem.writeInt(u16, cells[port..][0..2], value, .little);
        widths[port] = 16;
    }
    fn out32(port: u16, value: u32) void {
        std.mem.writeInt(u32, cells[port..][0..4], value, .little);
        widths[port] = 32;
    }
};

test "a port window reaches each register at the width of what is written" {
    const Ports = enum(u16) { command = 0x00, status = 0x02, address = 0x04 };
    const Command = packed struct(u8) { run: bool = false, reset: bool = false, _2: u6 = 0 };
    const window = PortWindow(Ports, FakePorts){ .base = 0x10 };

    window.write(.command, Command{ .reset = true });
    window.write(.status, @as(u16, 0xBEEF));
    window.write(.address, @as(u32, 0x1234_5678));
    window.writeAt(0x20, @as(u8, 0x5A));

    try std.testing.expectEqual(@as(u8, 8), FakePorts.widths[0x10]);
    try std.testing.expectEqual(@as(u8, 16), FakePorts.widths[0x12]);
    try std.testing.expectEqual(@as(u8, 32), FakePorts.widths[0x14]);
    try std.testing.expectEqual(Command{ .reset = true }, window.read(Command, .command));
    try std.testing.expectEqual(@as(u16, 0xBEEF), window.read(u16, .status));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), window.read(u32, .address));
    try std.testing.expectEqual(@as(u8, 0x5A), window.readAt(u8, 0x20));
}

test "a computed offset reaches a repeated bank" {
    var store: [32]u8 align(4) = @splat(0);
    const words = Window(Word, u32){ .base = &store };

    for (0..8) |i| words.writeAt(i * 4, @intCast(i * 0x11));
    for (0..8) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i * 0x11)), words.readAt(i * 4));
    }
}
