//! The Universal Host Controller Interface, revision 1.1: the full and low
//! speed USB host controller in Intel and VIA chipsets.
//!
//! The shape the kernel and the driver both use. The kernel takes the
//! controller from the firmware at boot, before any driver runs, and the
//! driver takes it again at open.

const std = @import("std");

/// LEGSUP: the traps the firmware's keyboard and mouse emulation runs on.
pub const LegacySupport = packed struct(u16) {
    trap_60_read: bool = false,
    trap_60_write: bool = false,
    trap_64_read: bool = false,
    trap_64_write: bool = false,
    /// The controller's interrupt raises an SMI.
    smi_on_interrupt: bool = false,
    a20_pass_through: bool = false,
    /// Read only: an A20 gate sequence is passing through.
    passing_through: bool = false,
    smi_on_pass_through_end: bool = false,
    /// This bit, the three after it and `pass_through_ended` clear when
    /// written as one.
    trapped_60_read: bool = false,
    trapped_60_write: bool = false,
    trapped_64_read: bool = false,
    trapped_64_write: bool = false,
    /// Read only: the controller's interrupt is active.
    interrupt_active: bool = false,
    /// The controller's interrupt reaches its PCI interrupt line.
    pirq_enabled: bool = false,
    _14: u1 = 0,
    pass_through_ended: bool = false,

    /// Every enable off, `pirq_enabled` included, and every status that
    /// clears, cleared.
    pub const RELEASED = LegacySupport{
        .trapped_60_read = true,
        .trapped_60_write = true,
        .trapped_64_read = true,
        .trapped_64_write = true,
        .pass_through_ended = true,
    };
};

/// The configuration dword LEGSUP is read and written through. The upper
/// half is not part of LEGSUP and is written back as read.
pub const LegacySupportDword = packed struct(u32) {
    legacy: LegacySupport = .{},
    _16: u16 = 0,

    pub const OFFSET: u8 = 0xC0;

    /// This dword with LEGSUP released.
    pub fn released(self: LegacySupportDword) LegacySupportDword {
        return .{ .legacy = .RELEASED, ._16 = self._16 };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn bits(value: LegacySupport) u16 {
    return @bitCast(value);
}

test "the register's bits are the design guide's" {
    try testing.expectEqual(@as(u16, 0x0001), bits(.{ .trap_60_read = true }));
    try testing.expectEqual(@as(u16, 0x0002), bits(.{ .trap_60_write = true }));
    try testing.expectEqual(@as(u16, 0x0004), bits(.{ .trap_64_read = true }));
    try testing.expectEqual(@as(u16, 0x0008), bits(.{ .trap_64_write = true }));
    try testing.expectEqual(@as(u16, 0x0010), bits(.{ .smi_on_interrupt = true }));
    try testing.expectEqual(@as(u16, 0x0020), bits(.{ .a20_pass_through = true }));
    try testing.expectEqual(@as(u16, 0x0040), bits(.{ .passing_through = true }));
    try testing.expectEqual(@as(u16, 0x0080), bits(.{ .smi_on_pass_through_end = true }));
    try testing.expectEqual(@as(u16, 0x0100), bits(.{ .trapped_60_read = true }));
    try testing.expectEqual(@as(u16, 0x0200), bits(.{ .trapped_60_write = true }));
    try testing.expectEqual(@as(u16, 0x0400), bits(.{ .trapped_64_read = true }));
    try testing.expectEqual(@as(u16, 0x0800), bits(.{ .trapped_64_write = true }));
    try testing.expectEqual(@as(u16, 0x1000), bits(.{ .interrupt_active = true }));
    try testing.expectEqual(@as(u16, 0x2000), bits(.{ .pirq_enabled = true }));
    try testing.expectEqual(@as(u16, 0x8000), bits(.{ .pass_through_ended = true }));
    try testing.expectEqual(@as(u16, 0x8F00), bits(LegacySupport.RELEASED));
}

test "released clears LEGSUP and keeps the upper half" {
    try testing.expectEqual(@as(u8, 0xC0), LegacySupportDword.OFFSET);
    const firmware: LegacySupportDword = @bitCast(@as(u32, 0xA5C3_20BF));
    try testing.expectEqual(@as(u32, 0xA5C3_8F00), @as(u32, @bitCast(firmware.released())));
    const everything: LegacySupportDword = @bitCast(@as(u32, 0xFFFF_FFFF));
    try testing.expectEqual(@as(u32, 0xFFFF_8F00), @as(u32, @bitCast(everything.released())));
}
