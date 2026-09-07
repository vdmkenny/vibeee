//! PCI configuration space access and bus enumeration.
//!
//! Mechanism 1 (the 0xCF8/0xCFC port pair) is used here. The 701 also exposes
//! MCFG/ECAM at 0xE0000000 (verified), which is faster and reaches extended
//! config space; that path lands with ACPI table parsing in M1, behind the same
//! interface.

const console = @import("../../kernel/console.zig");
const pcicfg = @import("../../kernel/pcicfg.zig");
const lib = @import("lib");

/// Through the kernel's one owner of the pair: an access split by an
/// interrupt, or raced by another process, lands its data on whatever the
/// other selected.
fn selectorFor(at: lib.pci.Location, offset: u8) pcicfg.Selector {
    return .{
        .bus = at.bus,
        .device = at.device,
        .function = at.function,
        .register = @truncate(offset >> 2),
    };
}

pub fn configRead32(at: lib.pci.Location, offset: u8) u32 {
    return pcicfg.read(selectorFor(at, offset));
}

pub fn configRead8(at: lib.pci.Location, offset: u8) u8 {
    const v = configRead32(at, offset);
    return @truncate(v >> (@as(u5, @truncate(offset & 3)) * 8));
}

pub fn configWrite32(at: lib.pci.Location, offset: u8, value: u32) void {
    pcicfg.write(selectorFor(at, offset), value);
}

/// Stop a userspace-owned PCI function before its DMA mappings are reclaimed.
pub fn quiesce(at: lib.pci.Location) void {
    const selector = pcicfg.Selector{
        .bus = at.bus,
        .device = at.device,
        .function = at.function,
        .register = lib.pci.COMMAND_OFFSET / @sizeOf(u32),
    };
    var command: lib.pci.Command = @bitCast(@as(u16, @truncate(pcicfg.read(selector))));
    command.io_space = false;
    command.memory_space = false;
    command.bus_master = false;
    command.interrupt_disable = true;
    pcicfg.write(selector, @as(u16, @bitCast(command)));
    _ = pcicfg.read(selector);
}

/// Whether anything still answers at that place.
///
/// A slot with nothing in it reads as all ones, because no part drove the
/// lines and the bus is pulled up. The one question a table of devices has to
/// be able to ask again: a part that was switched off is gone from the bus
/// without anything saying so.
pub fn answers(at: lib.pci.Location) bool {
    return @as(u16, @truncate(configRead32(at, 0x00))) != lib.pci.NO_DEVICE;
}

pub const HEADER_TYPE_OFFSET = lib.pci.HEADER_TYPE_OFFSET;
pub const BAR0_OFFSET = lib.pci.BAR0_OFFSET;
pub const INTERRUPT_LINE_OFFSET = lib.pci.INTERRUPT_LINE_OFFSET;

pub const Callback = *const fn (at: lib.pci.Location, vendor: u16, device: u16) void;

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
    const base = lib.pci.Location{ .bus = bus, .device = slot, .function = 0 };
    const id = configRead32(base, 0x00);
    const vendor: u16 = @truncate(id);
    if (vendor == lib.pci.NO_DEVICE) return;

    cb(base, vendor, @truncate(id >> 16));

    // Bit 7 of the header type means multi-function. Without it, probing
    // functions 1-7 can return aliases of function 0 on some bridges.
    const header_type = configRead8(base, HEADER_TYPE_OFFSET);
    if (header_type & 0x80 == 0) return;

    var func: u8 = 1;
    while (func < 8) : (func += 1) {
        const a = lib.pci.Location{ .bus = bus, .device = slot, .function = @truncate(func) };
        const fid = configRead32(a, 0x00);
        const fvendor: u16 = @truncate(fid);
        if (fvendor == lib.pci.NO_DEVICE) continue;
        cb(a, fvendor, @truncate(fid >> 16));
    }
}

/// Take active-state power management away from every PCI-to-PCI bridge.
///
/// ASPM is negotiated per link pair, and clearing it on an endpoint stops
/// only that endpoint's transmitter: the root port's side keeps whatever
/// the firmware left in its Link Control, and on this machine that means
/// the root still drops into L0s toward silicon whose L0s handling is its
/// family's best-known defect, until the link falls off the bus entirely
/// under a sustained transfer. An operating system that owns the bus owns
/// both ends of that negotiation; this is the root's half, done once at
/// boot, config space only.
pub fn quietBridgeAspm() void {
    var slot: u8 = 0;
    while (slot < 32) : (slot += 1) {
        var func: u8 = 0;
        while (func < 8) : (func += 1) {
            const a = lib.pci.Location{ .bus = 0, .device = @truncate(slot), .function = @truncate(func) };
            const id = configRead32(a, 0x00);
            if (@as(u16, @truncate(id)) == lib.pci.NO_DEVICE) continue;

            const code: lib.pci.ClassCode = @bitCast(configRead32(a, lib.pci.ClassCode.OFFSET));
            const is_bridge = code.class == .bridge and
                code.subclass == lib.pci.Subclass.pci_bridge;
            if (!is_bridge) continue;

            clearAspm(a);

            if (func == 0) {
                const header_type = configRead8(a, HEADER_TYPE_OFFSET);
                if (header_type & 0x80 == 0) break;
            }
        }
    }
}

/// Take a root port out of the link power states, which on this chipset
/// hang the bridge under load.
///
/// The capability chain is walked by the library, which owns the layout
/// and the bound: a chain that points at itself is silicon nobody should
/// spin on, and this runs at boot across every function of the bus.
fn clearAspm(a: lib.pci.Location) void {
    const at = lib.pci.capabilityAt(a, configRead32, .pcie) orelse return;
    const reg = lib.pci.fieldAt(at, lib.pci.PcieLinkControl.OFFSET) orelse return;

    var link: lib.pci.PcieLinkControl = @bitCast(configRead32(a, reg));
    if (link.aspm == 0) return;

    link.aspm = 0;
    configWrite32(a, reg, @bitCast(link));
    var where: [8]u8 = undefined;
    console.debug("pci", "{s} root port aspm cleared", .{lib.pci.spell(a, &where)});
}

/// Human-readable class name, for the probe table. Covers the classes that
/// appear on this machine plus the common ones; anything else prints its
/// numeric class so an unfamiliar device is still identifiable.
pub fn describe(code: lib.pci.ClassCode) []const u8 {
    const Subclass = lib.pci.Subclass;
    return switch (code.class) {
        .storage => switch (code.subclass) {
            0x01 => "IDE controller",
            0x06 => "SATA controller",
            0x08 => "NVMe controller",
            else => "mass storage controller",
        },
        .network => "network controller",
        .display => "display controller",
        .multimedia => switch (code.subclass) {
            0x03 => "audio device (HDA)",
            else => "multimedia controller",
        },
        .memory => "memory controller",
        .bridge => switch (code.subclass) {
            0x00 => "host bridge",
            Subclass.isa_bridge => "ISA/LPC bridge",
            Subclass.pci_bridge => "PCI-to-PCI bridge",
            else => "bridge",
        },
        .communication => "communication controller",
        .peripheral => "system peripheral",
        .input => "input device",
        .serial_bus => switch (code.subclass) {
            Subclass.usb => "USB controller",
            0x05 => "SMBus controller",
            else => "serial bus controller",
        },
        .wireless => "wireless controller",
        _ => if (@intFromEnum(code.class) == 0) "legacy device" else "unknown device",
        else => "unknown device",
    };
}
