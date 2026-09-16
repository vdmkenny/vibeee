//! The Intel I/O Controller Hub's LPC bridge and power management block.
//!
//! PMBASE, in the bridge's configuration space, gives the block's base port.
//! The block holds the ACPI, SMI and TCO registers. Field positions are the
//! ICH datasheets'.

const std = @import("std");
const pci = @import("pci.zig");

/// The LPC bridge is function 0 of device 31 on bus 0.
pub const LPC_BRIDGE = pci.Location{ .bus = 0, .device = 31, .function = 0 };

/// PMBASE, in the LPC bridge's configuration space.
pub const PmBase = packed struct(u32) {
    /// Reads as one: the block is in I/O space.
    io_space: bool,
    _1: u6,
    /// The base port, in steps of `PM_BLOCK_BYTES`.
    base_blocks: u9,
    _16: u16,

    pub const OFFSET: u8 = 0x40;

    /// The block's base port, or null when the firmware has not assigned one.
    pub fn base(self: PmBase) ?u16 {
        if (self.base_blocks == 0) return null;
        return @as(u16, self.base_blocks) * PM_BLOCK_BYTES;
    }
};

/// The power management block's length, which is also the step its base
/// moves in.
pub const PM_BLOCK_BYTES: u16 = std.math.pow(u16, 2, @bitOffsetOf(PmBase, "base_blocks"));

/// Registers in the power management block, by offset from its base port.
pub const PmRegister = enum(u16) {
    smi_enable = 0x30,
};

/// SMI_EN: which events raise a system management interrupt. Written back
/// from a read, so its fields have no defaults.
pub const SmiEnable = packed struct(u32) {
    _0: u3,
    /// LEGACY_USB_EN: SMIs from the USB 1.1 legacy keyboard and mouse logic.
    legacy_usb: bool,
    _4: u13,
    /// LEGACY_USB2_EN: SMIs from the USB 2.0 legacy logic.
    legacy_usb2: bool,
    _18: u14,

    /// These enables with both legacy USB enables clear, or null when both
    /// are clear already. Every other bit is kept.
    pub fn withoutLegacyUsb(self: SmiEnable) ?SmiEnable {
        if (!self.legacy_usb and !self.legacy_usb2) return null;
        var quiet = self;
        quiet.legacy_usb = false;
        quiet.legacy_usb2 = false;
        return quiet;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn word(value: anytype) u32 {
    return @bitCast(value);
}

fn pmBase(value: u32) PmBase {
    return @bitCast(value);
}

fn smiEnable(value: u32) SmiEnable {
    return @bitCast(value);
}

test "PMBASE is at 0x40, with the I/O space indicator in bit 0 and the base in bits 15 to 7" {
    try testing.expectEqual(@as(u8, 0x40), PmBase.OFFSET);
    try testing.expectEqual(@as(u16, 0), @bitOffsetOf(PmBase, "io_space"));
    try testing.expectEqual(@as(u16, 7), @bitOffsetOf(PmBase, "base_blocks"));
    try testing.expectEqual(@as(u16, 16), @bitOffsetOf(PmBase, "_16"));
    try testing.expectEqual(@as(u16, 128), PM_BLOCK_BYTES);
}

test "the block's base port is PMBASE bits 15 to 7, and there is none when they are zero" {
    try testing.expectEqual(@as(?u16, 0x0800), pmBase(0x0000_0801).base());
    try testing.expectEqual(@as(?u16, 0xFF80), pmBase(0xFFFF_FFFF).base());
    try testing.expectEqual(@as(?u16, null), pmBase(0xFFFF_007F).base());
    try testing.expectEqual(@as(?u16, null), pmBase(0x0000_0001).base());
}

test "SMI_EN is at 0x30 in the block, with LEGACY_USB_EN in bit 3 and LEGACY_USB2_EN in bit 17" {
    try testing.expectEqual(@as(u16, 0x30), @intFromEnum(PmRegister.smi_enable));
    try testing.expectEqual(@as(u16, 3), @bitOffsetOf(SmiEnable, "legacy_usb"));
    try testing.expectEqual(@as(u16, 17), @bitOffsetOf(SmiEnable, "legacy_usb2"));
    try testing.expect(smiEnable(0x0000_0008).legacy_usb);
    try testing.expect(smiEnable(0x0002_0000).legacy_usb2);
}

test "clearing the legacy USB enables keeps every other bit" {
    try testing.expectEqual(@as(u32, 0xFFFD_FFF7), word(smiEnable(0xFFFF_FFFF).withoutLegacyUsb().?));
    // GBL_SMI_EN, APMC_EN and LEGACY_USB_EN.
    try testing.expectEqual(@as(u32, 0x0000_0021), word(smiEnable(0x0000_0029).withoutLegacyUsb().?));
    // GBL_SMI_EN, APMC_EN and LEGACY_USB2_EN.
    try testing.expectEqual(@as(u32, 0x0000_0021), word(smiEnable(0x0002_0021).withoutLegacyUsb().?));
    try testing.expectEqual(@as(?SmiEnable, null), smiEnable(0xFFFD_FFF7).withoutLegacyUsb());
    try testing.expectEqual(@as(?SmiEnable, null), smiEnable(0).withoutLegacyUsb());
}
