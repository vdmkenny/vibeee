//! PCI configuration space, reached over the mechanism-one ports.
//!
//! The two ports every x86 chipset answers at, granted once for the life of
//! the process and addressed with the lanes in `lib.pci`. A driver server
//! holds the driver capability anyway; what this adds is the one place that
//! knows how a configuration read is actually made, so no driver reaches for
//! raw port numbers of its own.
//!
//! The addressing half is `lib.pci`; this is the port dance.

const lib = @import("lib");
const ports = @import("ports.zig");
const sys = @import("sys");

pub const Location = lib.pci.Location;
pub const parse = lib.pci.parse;

const CONFIG_ADDRESS: u16 = 0xCF8;
const CONFIG_DATA: u16 = 0xCFC;

/// The grant, asked for once. A config access without it is a fault, and the
/// ask is cheap enough that laziness costs more than it saves.
var granted = false;

fn open() bool {
    if (granted) return true;
    if (sys.ioportGrant(CONFIG_ADDRESS, 8) < 0) return false;
    granted = true;
    return true;
}

/// A dword of configuration space. The register is dword-granular.
pub fn read(loc: Location, register: u8) u32 {
    if (!open()) return 0xFFFF_FFFF;
    ports.out32(CONFIG_ADDRESS, loc.address(register));
    return ports.in32(CONFIG_DATA);
}

/// A dword written into configuration space.
pub fn write(loc: Location, register: u8, value: u32) void {
    if (!open()) return;
    ports.out32(CONFIG_ADDRESS, loc.address(register));
    ports.out32(CONFIG_DATA, value);
}

/// One byte of configuration space, at any offset.
pub fn read8(loc: Location, register: u8) u8 {
    const dword = read(loc, register);
    return @truncate(dword >> @intCast((register & 3) * 8));
}

/// One byte written into configuration space.
pub fn write8(loc: Location, register: u8, value: u8) void {
    const shift: u5 = @intCast((register & 3) * 8);
    const mask: u32 = ~@as(u32, @as(u8, 0xFF) << shift);
    const dword = read(loc, register);
    write(loc, register, (dword & mask) | (@as(u32, value) << shift));
}

/// A BAR at the given index, zero when the device reports none there.
pub fn bar(loc: Location, index: u8) u32 {
    return read(loc, 0x10 + 4 * index);
}

/// The interrupt line the firmware routed this device to, if any.
pub fn interruptLine(loc: Location) u8 {
    return read8(loc, 0x3C);
}

/// Turn on what a driver needs from the command register: memory decoding and
/// bus mastering. Reading first and writing the union keeps whatever the
/// firmware already enabled.
pub fn enableMemoryAndMaster(loc: Location) void {
    if (!open()) return;
    const command = read(loc, 0x04);
    write(loc, 0x04, command | 0x06);
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
