//! PCI configuration space, reached through the kernel.
//!
//! The two configuration ports are one shared index pair for the whole
//! machine, and this process is not the only one talking to them: the
//! firmware interpreter reads config space too, from its own process. An
//! access made with raw ports here can interleave with one made there, and
//! the transfer lands on whatever the other selected. The kernel is the one
//! place an access cannot be interleaved, so every access is a syscall.
//!
//! The addressing half is `lib.pci`; this is the crossing.

const lib = @import("lib");
const sys = @import("sys");
const std = @import("std");
const log = @import("log.zig");
const out = @import("out.zig");

pub const Location = lib.pci.Location;
pub const Command = lib.pci.Command;
pub const InterruptPin = lib.pci.InterruptPin;
pub const MemoryBar = lib.pci.MemoryBar;
pub const CommandStatus = lib.pci.CommandStatus;
pub const IoBar = lib.pci.IoBar;
pub const CAPABILITIES_OFFSET = lib.pci.CAPABILITIES_OFFSET;
pub const CapabilityPointer = lib.pci.CapabilityPointer;
pub const Capability = lib.pci.Capability;
pub const MsiControl = lib.pci.MsiControl;
pub const CapabilityId = lib.pci.CapabilityId;
pub const PcieDeviceControl = lib.pci.PcieDeviceControl;
pub const PcieLinkControl = lib.pci.PcieLinkControl;
pub const parse = lib.pci.parse;
pub const COMMAND_OFFSET = lib.pci.COMMAND_OFFSET;
pub const BAR0_OFFSET = lib.pci.BAR0_OFFSET;

fn packedLocation(loc: Location) u32 {
    return loc.encode();
}

/// A dword of configuration space. The register is dword-granular.
pub fn read(loc: Location, register: u8) u32 {
    return sys.pciRead(packedLocation(loc), register);
}

/// A dword written into configuration space.
pub fn write(loc: Location, register: u8, value: u32) void {
    sys.pciWrite(packedLocation(loc), register, value);
}

/// One byte of configuration space, at any offset.
pub fn read8(loc: Location, register: u8) u8 {
    const dword = read(loc, register);
    return @truncate(dword >> @intCast((register & 3) * 8));
}

/// A BAR at the given index, zero when the device reports none there.
/// The physical base of a memory window, or null when the slot holds
/// something unmappable: an I/O window, nothing the firmware assigned an
/// address to, or a 64-bit pair placed beyond the low four gigabytes.
/// Every driver mapping registers asks this same question, and asking it
/// in one place is what keeps a driver from mapping an I/O port number as
/// if it were memory.
pub fn memoryBase(loc: Location, index: u8) ?lib.Phys {
    const window: MemoryBar = @bitCast(bar(loc, index));
    // A 64-bit window is a pair whose upper half lives in the next slot,
    // and a pair claimed by the last slot has no next slot to live in.
    if (window.kind == .bits64 and index >= 5) return null;
    const upper = if (window.kind == .bits64) bar(loc, index + 1) else 0;
    return lib.Phys.of(lib.pci.memoryWindowBase(window, upper) orelse return null);
}

/// A device's register aperture, opened the one way every memory-mapped
/// driver opens one: the window at BAR `index` decoded, its placement
/// checked against the reach of a 32-bit mapping, its registers mapped,
/// and decode and mastering switched on. Null means the failure is already
/// narrated under `tag`, with `what` naming the part whose registers were
/// wanted.
///
/// The whole window the driver asks for is taken to be registers. A driver
/// that knows how far into its window it actually reaches calls
/// `openApertureNeeding` instead, and is then served even by a part whose
/// window is smaller than the driver assumed.
pub fn openAperture(
    loc: Location,
    index: u8,
    bytes: u32,
    tag: []const u8,
    comptime what: []const u8,
) ?[*]volatile u32 {
    return openApertureNeeding(loc, index, bytes, bytes, tag, what);
}

/// The same, for a driver that can name how much of the window it needs:
/// `registers` is one past the highest register offset it touches.
///
/// What is mapped is the smaller of the window the part reports and the
/// window the driver asked for. Mapping the driver's number regardless is
/// how a mapping comes to run off the end of one device's registers and
/// into the next address: every read past the window's end then answers
/// whatever else lives there, which is a driver that misbehaves in ways
/// no amount of reading its own source explains. A window too small to
/// hold `registers` is refused rather than mapped short, because a driver
/// whose highest register lies outside the window cannot work at all.
pub fn openApertureNeeding(
    loc: Location,
    index: u8,
    bytes: u32,
    registers: u32,
    tag: []const u8,
    comptime what: []const u8,
) ?[*]volatile u32 {
    const base = memoryBase(loc, index) orelse {
        log.fail(tag, "the " ++ what ++ " exposes no register aperture");
        return null;
    };
    const real = sizeWindow(loc, index, bytes, tag, what) orelse {
        log.fail(tag, "the " ++ what ++ " reports no register window");
        return null;
    };
    if (real < registers) {
        log.fail(tag, "the " ++ what ++ "'s window is too small for the registers its driver uses");
        return null;
    }

    const mapped = @min(real, bytes);
    if (base.plus(mapped - 1) == null) {
        log.fail(tag, "the " ++ what ++ " exposes no register aperture");
        return null;
    }

    const aperture = sys.mapDevice(base, mapped) orelse {
        log.fail(tag, "cannot map registers");
        return null;
    };
    enableMemoryAndMaster(loc);
    return aperture;
}

/// The device's own account of its window at BAR `index`, taken while
/// decoding is off and restored before it matters: the real size, which is
/// what the mapping is cut to. A window of another shape than the driver
/// assumes, or smaller than it asks for, is narrated rather than refused,
/// because a part may decode less than the family's maximum and still hold
/// every register the driver touches; the narration names the device whose
/// account disagrees. Null when the part reports no window at all.
///
/// Writes the BAR and the command word, so on firmware that traps those,
/// ownership of the device comes first.
pub fn sizeWindow(loc: Location, index: u8, bytes: u32, tag: []const u8, comptime what: []const u8) ?u32 {
    const register = lib.pci.BAR0_OFFSET + 4 * index;
    const raw = bar(loc, index);
    const base = @as(MemoryBar, @bitCast(raw)).base();
    const saved = readCommand(loc);
    var probing = saved;
    probing.memory_space = false;
    writeCommand(loc, probing);
    write(loc, register, std.math.maxInt(u32));
    const mask: MemoryBar = @bitCast(bar(loc, index));
    write(loc, register, raw);
    writeCommand(loc, saved);
    _ = read(loc, COMMAND_OFFSET);

    const claimed = -%mask.base();
    if (claimed == 0) return null;
    if (!std.math.isPowerOfTwo(claimed) or !std.mem.isAligned(base, claimed)) {
        log.say(tag, .dim, "the " ++ what ++ "'s window is not the shape its driver assumes");
    } else if (claimed < bytes) {
        log.say(tag, .dim, "the " ++ what ++ "'s window is smaller than its driver assumes; mapped as far as it goes");
    }
    return claimed;
}

/// One past the highest offset in a register enum: the smallest window that
/// can carry every register a driver names. Answered from the enum rather
/// than written as a number beside it, so the two cannot drift.
pub fn registersEnd(comptime Register: type, comptime width: u32) u32 {
    var end: u32 = 0;
    inline for (comptime std.meta.fields(Register)) |field| {
        end = @max(end, @as(u32, field.value) + width);
    }
    return end;
}

pub fn bar(loc: Location, index: u8) u32 {
    return read(loc, lib.pci.BAR0_OFFSET + 4 * index);
}

/// Where the capability with `id` sits in this device's list, or null when
/// it has none.
///
/// The list is walked rather than assumed: the pointer is whatever the
/// silicon says it is. Bounded, because a list that points at itself is
/// silicon nobody should spin on, and configuration space has room for no
/// more entries than this.
pub fn capabilityAt(loc: Location, id: lib.pci.CapabilityId) ?u8 {
    return lib.pci.capabilityAt(loc, read, id);
}

/// Make the device deliver its interrupts on its pin, and say whether it
/// had to be told to.
///
/// A device with message-signalled interrupts enabled asserts no pin, so a
/// driver waiting on the line waits for ever, and the device looks exactly
/// like one with nothing to say. This system routes pins; a device left
/// with messages enabled by firmware is turned back.
pub fn useIntx(loc: Location) bool {
    const at = capabilityAt(loc, .msi) orelse return false;
    const capability: Capability = @bitCast(read(loc, at));

    var control: MsiControl = @bitCast(capability.control);
    if (!control.enable) return false;

    control.enable = false;
    var next = capability;
    next.control = @bitCast(control);
    write(loc, at, @bitCast(next));
    _ = read(loc, at);
    return true;
}

/// The interrupt line the firmware routed this device to, if any.
pub fn interruptLine(loc: Location) u8 {
    return read8(loc, lib.pci.INTERRUPT_LINE_OFFSET);
}

pub fn interruptPin(loc: Location) InterruptPin {
    return @enumFromInt(read8(loc, lib.pci.INTERRUPT_PIN_OFFSET));
}

/// The command dword whole, the status half included.
pub fn readCommandStatus(loc: Location) CommandStatus {
    return @bitCast(read(loc, lib.pci.COMMAND_OFFSET));
}

/// Clear the device's account of bus trouble: the account bits are
/// write-one-to-clear and the command half ignores what it already holds,
/// so the dword goes back exactly as it came.
pub fn clearStatus(loc: Location) void {
    write(loc, lib.pci.COMMAND_OFFSET, read(loc, lib.pci.COMMAND_OFFSET));
}

/// Append the device's account of bus trouble to a log line the caller
/// holds open, and clear the account so a later error writes a fresh one.
/// Says nothing when the account is clean.
pub fn tellBusTrouble(loc: Location) void {
    const account = readCommandStatus(loc).status;
    if (account.received_master_abort) out.text("; the bus answered nobody");
    if (account.received_target_abort) out.text("; the bus broke off mid-answer");
    if (account.master_parity_error or account.parity_error) out.text("; parity failed");
    if (account.signaled_system_error) out.text("; the part raised a system error");
    clearStatus(loc);
}

pub fn readCommand(loc: Location) Command {
    return @bitCast(@as(u16, @truncate(read(loc, lib.pci.COMMAND_OFFSET))));
}

pub fn writeCommand(loc: Location, value: Command) void {
    // Zero in the status half preserves every W1C diagnostic bit.
    write(loc, lib.pci.COMMAND_OFFSET, @as(u16, @bitCast(value)));
}

/// Turn on what a driver needs from the command register: memory decoding and
/// bus mastering. Reading first and writing the union keeps whatever the
/// firmware already enabled.
pub fn enableMemoryAndMaster(loc: Location) void {
    var next = readCommand(loc);
    next.memory_space = true;
    next.bus_master = true;
    writeCommand(loc, next);
}

pub fn enableIoAndMaster(loc: Location) void {
    var next = readCommand(loc);
    next.io_space = true;
    next.bus_master = true;
    writeCommand(loc, next);
}

/// Allow legacy INTx only after the driver has initialized its handler path.
/// Kept separate from decode and bus mastering to preserve that order.
pub fn enableInterrupt(loc: Location) void {
    var next = readCommand(loc);
    next.interrupt_disable = false;
    writeCommand(loc, next);
}

/// Stop legacy interrupts and DMA before a driver releases device memory.
pub fn disableInterruptAndMaster(loc: Location) void {
    var next = readCommand(loc);
    next.interrupt_disable = true;
    next.bus_master = false;
    writeCommand(loc, next);
    _ = read(loc, lib.pci.COMMAND_OFFSET);
}

/// The root-bus bridge whose window contains `bus`, or null for the root
/// bus itself and for a bus nothing on the root claims. One level of
/// bridges is what this machine has; a deeper machine repeats the walk.
pub fn carrierOf(bus: u8) ?Location {
    if (bus == 0) return null;

    var device: u5 = 0;
    while (true) : (device += 1) {
        var function: u3 = 0;
        while (true) : (function += 1) {
            const loc = Location{ .bus = 0, .device = device, .function = function };
            const id = read(loc, 0);
            if (id != 0xFFFF_FFFF) {
                // Header type 1 is a bridge; its window is the pair of bus
                // numbers at the fixed offsets the specification gives them.
                const header = read8(loc, 0x0E);
                if (header & 0x7F == 1) {
                    const secondary = read8(loc, 0x19);
                    const subordinate = read8(loc, 0x1A);
                    if (bus >= secondary and bus <= subordinate) return loc;
                }
                if (function == 0 and header & 0x80 == 0) break;
            } else if (function == 0) break;

            if (function == 7) break;
        }
        if (device == 31) break;
    }
    return null;
}
