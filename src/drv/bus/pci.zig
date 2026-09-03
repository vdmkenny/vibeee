//! PCI configuration space access and bus enumeration.
//!
//! Mechanism 1 (the 0xCF8/0xCFC port pair) is used here. The 701 also exposes
//! MCFG/ECAM at 0xE0000000 (verified), which is faster and reaches extended
//! config space; that path lands with ACPI table parsing in M1, behind the same
//! interface.

const console = @import("../../kernel/console.zig");
const pcicfg = @import("../../kernel/pcicfg.zig");
const lib = @import("lib");

pub const Address = struct {
    bus: u8,
    slot: u5,
    func: u3,
};

/// Through the kernel's one owner of the pair: an access split by an
/// interrupt, or raced by another process, lands its data on whatever the
/// other selected.
fn selectorFor(addr: Address, offset: u8) pcicfg.Selector {
    return .{
        .bus = addr.bus,
        .device = addr.slot,
        .function = addr.func,
        .register = @truncate(offset >> 2),
    };
}

pub fn configRead32(addr: Address, offset: u8) u32 {
    return pcicfg.read(selectorFor(addr, offset));
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
    pcicfg.write(selectorFor(addr, offset), value);
}

/// Stop a userspace-owned PCI function before its DMA mappings are reclaimed.
pub fn quiesce(location: [3]u16) void {
    const loc = lib.pci.Location.fromComponents(location[0], location[1], location[2]) orelse return;
    const selector = pcicfg.Selector{
        .bus = loc.bus,
        .device = loc.device,
        .function = loc.function,
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
pub fn answers(location: [3]u16) bool {
    const loc = lib.pci.Location.fromComponents(location[0], location[1], location[2]) orelse return false;
    const addr = Address{ .bus = loc.bus, .slot = loc.device, .func = loc.function };
    return @as(u16, @truncate(configRead32(addr, 0x00))) != lib.pci.NO_DEVICE;
}

pub const CLASS_OFFSET: u8 = 0x08;
pub const HEADER_TYPE_OFFSET = lib.pci.HEADER_TYPE_OFFSET;
pub const BAR0_OFFSET = lib.pci.BAR0_OFFSET;
pub const INTERRUPT_LINE_OFFSET = lib.pci.INTERRUPT_LINE_OFFSET;

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
    if (vendor == lib.pci.NO_DEVICE) return;

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
            const a = Address{ .bus = 0, .slot = @truncate(slot), .func = @truncate(func) };
            const id = configRead32(a, 0x00);
            if (@as(u16, @truncate(id)) == lib.pci.NO_DEVICE) continue;

            const class = configRead32(a, CLASS_OFFSET);
            const is_bridge = @as(u8, @truncate(class >> 24)) == 0x06 and
                @as(u8, @truncate(class >> 16)) == 0x04;
            if (!is_bridge) continue;

            // Walk the capability list for PCI Express (id 0x10); Link
            // Control sits sixteen bytes in, its low two bits are ASPM.
            var at: u8 = @truncate(configRead32(a, 0x34) & 0xFF);
            while (at != 0) {
                const cap = configRead32(a, at);
                if (@as(u8, @truncate(cap)) == 0x10) {
                    const link = configRead32(a, at + 0x10);
                    if (link & 0x3 != 0) {
                        configWrite32(a, at + 0x10, link & ~@as(u32, 0x3));
                        console.debug("pci", "{x:0>2}:{x:0>2}.{d} root port aspm cleared", .{
                            a.bus, a.slot, a.func,
                        });
                    }
                    break;
                }
                at = @truncate(cap >> 8);
            }

            if (func == 0) {
                const header_type = configRead8(a, HEADER_TYPE_OFFSET);
                if (header_type & 0x80 == 0) break;
            }
        }
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
