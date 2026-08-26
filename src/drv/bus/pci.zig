//! PCI configuration space access and bus enumeration.
//!
//! Mechanism 1 (the 0xCF8/0xCFC port pair) is used here. The 701 also exposes
//! MCFG/ECAM at 0xE0000000 (verified), which is faster and reaches extended
//! config space; that path lands with ACPI table parsing in M1, behind the same
//! interface.

const port = @import("../../arch/x86/port.zig");

const CONFIG_ADDRESS: u16 = 0xCF8;
const CONFIG_DATA: u16 = 0xCFC;

pub const Address = struct {
    bus: u8,
    slot: u5,
    func: u3,
};

/// What goes in the configuration address port, laid out as the bus reads it.
///
/// A packed struct rather than four shifts: the field widths are the
/// declaration, and a slot number too large to fit is a compile error rather
/// than a quiet overlap into the bus field.
const ConfigAddress = packed struct(u32) {
    /// Dword aligned: the bus ignores the low two bits and so does this.
    offset: u8,
    func: u3,
    slot: u5,
    bus: u8,
    _reserved: u7 = 0,
    enable: bool = true,
};

fn configAddress(addr: Address, offset: u8) u32 {
    return @bitCast(ConfigAddress{
        .bus = addr.bus,
        .slot = addr.slot,
        .func = addr.func,
        .offset = offset & 0xFC,
    });
}

pub fn configRead32(addr: Address, offset: u8) u32 {
    port.outl(CONFIG_ADDRESS, configAddress(addr, offset));
    return port.inl(CONFIG_DATA);
}

pub fn configRead16(addr: Address, offset: u8) u16 {
    const v = configRead32(addr, offset);
    return @truncate(v >> (@as(u5, @truncate(offset & 2)) * 8));
}

pub fn configRead8(addr: Address, offset: u8) u8 {
    const v = configRead32(addr, offset);
    return @truncate(v >> (@as(u5, @truncate(offset & 3)) * 8));
}

pub fn configWrite32(addr: Address, offset: u8, value: u32) void {
    port.outl(CONFIG_ADDRESS, configAddress(addr, offset));
    port.outl(CONFIG_DATA, value);
}

pub const CLASS_OFFSET: u8 = 0x08;
pub const HEADER_TYPE_OFFSET: u8 = 0x0E;
pub const BAR0_OFFSET: u8 = 0x10;
pub const INTERRUPT_LINE_OFFSET: u8 = 0x3C;

pub const Callback = *const fn (addr: Address, vendor: u16, device: u16) void;

/// Brute-force scan of all 256 buses. Recursive bridge-following would be
/// tidier, but on a machine whose entire topology is known and tiny the flat
/// scan is simpler and cannot miss a device behind a bridge we mis-parse.
pub fn enumerate(cb: Callback) void {
    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        var slot: u8 = 0;
        while (slot < 32) : (slot += 1) {
            scanSlot(@truncate(bus), @truncate(slot), cb);
        }
    }
}

fn scanSlot(bus: u8, slot: u5, cb: Callback) void {
    const base = Address{ .bus = bus, .slot = slot, .func = 0 };
    const id = configRead32(base, 0x00);
    const vendor: u16 = @truncate(id);
    if (vendor == 0xFFFF) return; // nothing here

    cb(base, vendor, @truncate(id >> 16));

    // Bit 7 of the header type means multi-function. Without it, probing
    // functions 1-7 can return aliases of function 0 on some bridges.
    const header_type = configRead8(base, HEADER_TYPE_OFFSET);
    if (header_type & 0x80 == 0) return;

    var func: u8 = 1;
    while (func < 8) : (func += 1) {
        const a = Address{ .bus = bus, .slot = slot, .func = @truncate(func) };
        const fid = configRead32(a, 0x00);
        const fvendor: u16 = @truncate(fid);
        if (fvendor == 0xFFFF) continue;
        cb(a, fvendor, @truncate(fid >> 16));
    }
}

/// Human-readable class name, for the probe table. Covers the classes that
/// appear on this machine plus the common ones; anything else prints its
/// numeric class so an unfamiliar device is still identifiable.
pub fn describe(class: u8, subclass: u8) []const u8 {
    return switch (class) {
        0x00 => "legacy device",
        0x01 => switch (subclass) {
            0x01 => "IDE controller",
            0x06 => "SATA controller",
            0x08 => "NVMe controller",
            else => "mass storage controller",
        },
        0x02 => "ethernet controller",
        0x03 => "display controller",
        0x04 => switch (subclass) {
            0x03 => "audio device (HDA)",
            else => "multimedia controller",
        },
        0x05 => "memory controller",
        0x06 => switch (subclass) {
            0x00 => "host bridge",
            0x01 => "ISA/LPC bridge",
            0x04 => "PCI-to-PCI bridge",
            else => "bridge",
        },
        0x07 => "communication controller",
        0x08 => "system peripheral",
        0x09 => "input device",
        0x0C => switch (subclass) {
            0x03 => "USB controller",
            0x05 => "SMBus controller",
            else => "serial bus controller",
        },
        0x0D => "wireless controller",
        else => "unknown device",
    };
}
