//! The Enhanced Host Controller Interface, revision 1.0: the high speed USB
//! host controller.
//!
//! The shapes the kernel and the driver both use. The kernel takes the
//! controller from the firmware at boot, before any driver runs, and the
//! driver takes it again at open.

const std = @import("std");
const pci = @import("pci.zig");

/// The capability registers, a dword each, from the aperture's base.
pub const CapabilityRegister = enum(u32) {
    /// CAPLENGTH, with HCIVERSION in its upper half.
    length = 0x00,
    /// HCSPARAMS.
    structural = 0x04,
    /// HCCPARAMS.
    capabilities = 0x08,
};

/// HCCPARAMS.
pub const Capabilities = packed struct(u32) {
    addresses_64bit: bool = false,
    programmable_frame_list: bool = false,
    async_park: bool = false,
    _3: u1 = 0,
    isochronous_threshold: u4 = 0,
    /// EECP: where the first extended capability sits in configuration
    /// space, or zero for none.
    extended_capabilities: u8 = 0,
    _16: u16 = 0,

    /// Where the legacy support capability sits. Null when there is no
    /// extended capability, or when the capability would run past the end
    /// of configuration space.
    pub fn legacy(self: Capabilities) ?LegacyPlace {
        const base = self.extended_capabilities;
        if (base < pci.HEADER_BYTES) return null;
        if (@as(u16, base) + @sizeOf(LegacyCapability) > pci.SPACE_BYTES) return null;
        return .{ .base = base };
    }
};

/// What an extended capability is. Legacy support is the one the
/// specification defines.
pub const ExtendedCapabilityId = enum(u8) {
    legacy_support = 0x01,
    _,
};

/// The legacy support capability, as configuration space lays it out from
/// the extended capabilities pointer.
pub const LegacyCapability = extern struct {
    support: LegacySupport,
    control: LegacyControl,

    pub const Register = std.meta.FieldEnum(LegacyCapability);
};

/// Where the legacy support capability sits in configuration space, as
/// `Capabilities.legacy` found it.
pub const LegacyPlace = struct {
    base: u8,

    /// The configuration space offset of `register`.
    pub fn at(self: LegacyPlace, comptime register: LegacyCapability.Register) u8 {
        return self.base + @offsetOf(LegacyCapability, @tagName(register));
    }
};

/// USBLEGSUP: the ownership semaphore. The system sets its bit and waits
/// for the firmware to clear its own.
pub const LegacySupport = packed struct(u32) {
    id: ExtendedCapabilityId = .legacy_support,
    /// Where the next extended capability sits, or zero for none.
    next: u8 = 0,
    firmware_owned: bool = false,
    _17: u7 = 0,
    system_owned: bool = false,
    _25: u7 = 0,

    /// The semaphore taken from a firmware that kept it: its bit cleared
    /// and the system's set.
    pub fn seized(self: LegacySupport) LegacySupport {
        return .{ .id = self.id, .next = self.next, .system_owned = true };
    }
};

/// The events USBLEGCTLSTS names, in the order both of its halves list them.
pub const LegacyEvents = packed struct(u16) {
    /// USBINT.
    transfer: bool = false,
    /// USBERRINT.
    transfer_error: bool = false,
    port_change: bool = false,
    frame_rollover: bool = false,
    host_error: bool = false,
    async_advance: bool = false,
    _6: u7 = 0,
    /// The system owned bit changed.
    ownership_change: bool = false,
    /// The PCI command register was written.
    command_write: bool = false,
    /// A base address register was written.
    bar_write: bool = false,
};

/// USBLEGCTLSTS: which events interrupt the firmware, and which occurred.
/// The first six occurred bits mirror USBSTS and are read only. The last
/// three clear when written as one.
pub const LegacyControl = packed struct(u32) {
    enabled: LegacyEvents = .{},
    occurred: LegacyEvents = .{},

    /// Every interrupt into the firmware off, and the occurred bits that
    /// can be cleared, cleared.
    pub const RELEASED = LegacyControl{ .occurred = .{
        .ownership_change = true,
        .command_write = true,
        .bar_write = true,
    } };

    /// Whether any event interrupts the firmware.
    pub fn armed(self: LegacyControl) bool {
        var enabled = self.enabled;
        enabled._6 = 0;
        return enabled != LegacyEvents{};
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn word(value: anytype) u32 {
    return @bitCast(value);
}

fn legacyAt(pointer: u8) ?LegacyPlace {
    return (Capabilities{ .extended_capabilities = pointer }).legacy();
}

test "register words are the specification's" {
    try testing.expectEqual(@as(u32, 0x08), @intFromEnum(CapabilityRegister.capabilities));
    try testing.expectEqual(@as(u32, 0x0000_0001), word(Capabilities{ .addresses_64bit = true }));
    try testing.expectEqual(@as(u32, 0x0000_00F0), word(Capabilities{ .isochronous_threshold = 0xF }));
    try testing.expectEqual(@as(u32, 0x0000_6800), word(Capabilities{ .extended_capabilities = 0x68 }));

    try testing.expectEqual(@as(u32, 0x0000_0001), word(LegacySupport{}));
    try testing.expectEqual(@as(u32, 0x0000_7001), word(LegacySupport{ .next = 0x70 }));
    try testing.expectEqual(@as(u32, 0x0001_0001), word(LegacySupport{ .firmware_owned = true }));
    try testing.expectEqual(@as(u32, 0x0100_0001), word(LegacySupport{ .system_owned = true }));

    try testing.expectEqual(@as(u32, 0x0000_0001), word(LegacyControl{ .enabled = .{ .transfer = true } }));
    try testing.expectEqual(@as(u32, 0x0000_0020), word(LegacyControl{ .enabled = .{ .async_advance = true } }));
    try testing.expectEqual(@as(u32, 0x0000_2000), word(LegacyControl{ .enabled = .{ .ownership_change = true } }));
    try testing.expectEqual(@as(u32, 0x0000_8000), word(LegacyControl{ .enabled = .{ .bar_write = true } }));
    try testing.expectEqual(@as(u32, 0x0001_0000), word(LegacyControl{ .occurred = .{ .transfer = true } }));
    try testing.expectEqual(@as(u32, 0x0010_0000), word(LegacyControl{ .occurred = .{ .host_error = true } }));
    try testing.expectEqual(@as(u32, 0x2000_0000), word(LegacyControl{ .occurred = .{ .ownership_change = true } }));
    try testing.expectEqual(@as(u32, 0x8000_0000), word(LegacyControl{ .occurred = .{ .bar_write = true } }));
    try testing.expectEqual(@as(u32, 0xE000_0000), word(LegacyControl.RELEASED));
}

test "a seized semaphore keeps the capability's identity and drops the firmware's bit" {
    const held: LegacySupport = @bitCast(@as(u32, 0x0101_0A01));
    try testing.expectEqual(@as(u32, 0x0100_0A01), word(held.seized()));
    const reserved: LegacySupport = @bitCast(@as(u32, 0xFFFF_0001));
    try testing.expectEqual(@as(u32, 0x0100_0001), word(reserved.seized()));
}

test "the legacy support registers are past the header and inside the space" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(LegacyCapability));
    try testing.expectEqual(@as(u8, 0x68), legacyAt(0x68).?.at(.support));
    try testing.expectEqual(@as(u8, 0x6C), legacyAt(0x68).?.at(.control));
    try testing.expectEqual(@as(u8, 0x44), legacyAt(0x40).?.at(.control));
    try testing.expectEqual(@as(u8, 0xFC), legacyAt(0xF8).?.at(.control));
    try testing.expectEqual(@as(?LegacyPlace, null), legacyAt(0x00));
    try testing.expectEqual(@as(?LegacyPlace, null), legacyAt(0x3C));
    try testing.expectEqual(@as(?LegacyPlace, null), legacyAt(0xF9));
    try testing.expectEqual(@as(?LegacyPlace, null), legacyAt(0xFC));
}

test "only an enabled event arms the firmware" {
    try testing.expect(!LegacyControl.RELEASED.armed());
    // Every occurred bit, and every reserved bit among the enables.
    try testing.expect(!@as(LegacyControl, @bitCast(@as(u32, 0xFFFF_1FC0))).armed());
    try testing.expect(@as(LegacyControl, @bitCast(@as(u32, 0x0000_0001))).armed());
    try testing.expect(@as(LegacyControl, @bitCast(@as(u32, 0x0000_0020))).armed());
    try testing.expect(@as(LegacyControl, @bitCast(@as(u32, 0x0000_2000))).armed());
    try testing.expect(@as(LegacyControl, @bitCast(@as(u32, 0x0000_8000))).armed());
}
