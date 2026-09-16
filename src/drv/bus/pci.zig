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

/// Let a kernel driver's device address memory itself, and decode the I/O
/// window its registers are in.
///
/// Read first and write the union, so whatever the firmware already enabled
/// stays enabled. The status half of the dword is written as zero, which
/// preserves every write-one-to-clear bit in it.
pub fn enableIoAndMaster(at: lib.pci.Location) void {
    const selector = selectorFor(at, lib.pci.COMMAND_OFFSET);
    var command: lib.pci.Command = @bitCast(@as(u16, @truncate(pcicfg.read(selector))));
    command.io_space = true;
    command.bus_master = true;
    pcicfg.write(selector, @as(u16, @bitCast(command)));
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

/// Whether a device still answers at that place. The device table asks again
/// after a walk, because a part that is switched off leaves the bus without
/// any notice.
pub fn answers(at: lib.pci.Location) bool {
    const identity: lib.pci.Identity = @bitCast(configRead32(at, lib.pci.Identity.OFFSET));
    return identity.vendor != lib.pci.NO_DEVICE;
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
    const id: lib.pci.Identity = @bitCast(configRead32(base, lib.pci.Identity.OFFSET));
    if (id.vendor == lib.pci.NO_DEVICE) return;

    cb(base, @intFromEnum(id.vendor), id.device);

    // Bit 7 of the header type means multi-function. Without it, probing
    // functions 1-7 can return aliases of function 0 on some bridges.
    const header_type = configRead8(base, HEADER_TYPE_OFFSET);
    if (header_type & 0x80 == 0) return;

    var func: u8 = 1;
    while (func < 8) : (func += 1) {
        const a = lib.pci.Location{ .bus = bus, .device = slot, .function = @truncate(func) };
        const fid: lib.pci.Identity = @bitCast(configRead32(a, lib.pci.Identity.OFFSET));
        if (fid.vendor == lib.pci.NO_DEVICE) continue;
        cb(a, @intFromEnum(fid.vendor), fid.device);
    }
}

// ---------------------------------------------------------------------------
// Across a suspend to memory
// ---------------------------------------------------------------------------

/// One function's header as it stood, so it can be put back.
///
/// Suspending to memory takes the power off the bus, and every function comes
/// back at its reset values: no address assigned, nothing decoded, no bus
/// mastering. The addresses themselves are the firmware's to choose and it
/// chose them before this kernel ran, so nothing here could work them out
/// again. They are copied out instead, while they are still there to copy.
const Stowed = struct {
    at: lib.pci.Location,
    /// The header from the command word to the interrupt line, which is every
    /// word of it that is written rather than read. The identity words above
    /// it are the part's own and outlive the power.
    words: [WORDS]u32,

    const FIRST = lib.pci.COMMAND_OFFSET;
    const LAST: u8 = 0x3C;
    const WORDS = (LAST - FIRST) / @sizeOf(u32) + 1;

    fn offsetOf(index: usize) u8 {
        return FIRST + @as(u8, @intCast(index)) * @sizeOf(u32);
    }
};

/// How many functions this remembers. Every machine this runs on has a
/// handful; a bus with more than this is one where the last few come back at
/// their reset values, which is said rather than silently allowed.
const STOWED_MAX = 48;

var stowed: [STOWED_MAX]Stowed = undefined;
var stowed_count: usize = 0;
var stowed_overflowed = false;

/// Copy every function's header out, before the power goes.
pub fn stow() void {
    stowed_count = 0;
    stowed_overflowed = false;
    enumerate(&stowOne);
}

fn stowOne(at: lib.pci.Location, _: u16, _: u16) void {
    if (stowed_count == stowed.len) {
        stowed_overflowed = true;
        return;
    }
    const kept = &stowed[stowed_count];
    kept.at = at;
    for (&kept.words, 0..) |*word, i| word.* = configRead32(at, Stowed.offsetOf(i));
    stowed_count += 1;
}

/// Put them all back, in the order they were found.
///
/// Bus order, which puts every bridge before what is behind it: a bridge that
/// has forgotten which buses it forwards hides everything on the far side, so
/// it has to be answering again before anything there is written to.
///
/// The command word goes last of each function's, because it is the one that
/// says what the part decodes: enabled while its addresses were still at
/// their reset values, a part would answer for memory that belongs to
/// something else.
pub fn restore() void {
    for (stowed[0..stowed_count]) |kept| {
        var i = kept.words.len;
        while (i > 1) {
            i -= 1;
            configWrite32(kept.at, Stowed.offsetOf(i), kept.words[i]);
        }
        // Zeroes above the command half, which is where the status bits are:
        // writing back what was read there would clear every one that has
        // been set since.
        configWrite32(kept.at, Stowed.FIRST, @as(u16, @truncate(kept.words[0])));
    }
    if (stowed_overflowed) {
        console.warn("pci: more functions than can be stowed; the last are at their reset values", .{});
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
            const id: lib.pci.Identity = @bitCast(configRead32(a, lib.pci.Identity.OFFSET));
            if (id.vendor == lib.pci.NO_DEVICE) continue;

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
