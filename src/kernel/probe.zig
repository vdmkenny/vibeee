//! Hardware probing and driver binding.
//!
//! The registry is built at comptime; binding happens at runtime by asking each
//! candidate driver how confident it is. That ordering is what lets one image
//! boot on hardware it was not designed for: the GMA900 driver answers `.exact`
//! only on 8086:2592, while the VESA driver answers `.weak` on any VGA-class
//! device, so an unknown machine still gets a framebuffer instead of a black
//! screen.
//!
//! See design/00-vibeee.md §4.

const std = @import("std");
const console = @import("console.zig");
const hal = @import("hal.zig");

pub const Confidence = enum(u8) {
    /// Not my device.
    no = 0,
    /// Generic class-level match — works, but dumbly.
    weak = 1,
    /// Recognised family; most functionality available.
    strong = 2,
    /// Exact device match, all quirks known.
    exact = 3,
};

pub const Match = union(enum) {
    /// Vendor+device.
    pci_id: struct { vendor: u16, device: u16 },
    /// Class+subclass, for generic fallback drivers.
    pci_class: struct { class: u8, subclass: u8 },
    /// Legacy device with no bus presence (i8042, PIT, RTC, CMOS).
    platform: []const u8,
};

pub const Driver = struct {
    name: []const u8,
    kind: enum { bus, block, video, input, net, audio, usb, platform, misc },
    match: []const Match,
    /// Returns how well this driver fits. Drivers that need to touch the device
    /// to be sure (the Synaptics/Elantech probe ladder) do it here.
    probe: *const fn (dev: Device) Confidence,
    /// Left null while a driver is designed but not yet implemented, so the
    /// probe table doubles as an honest status board.
    attach: ?*const fn (dev: Device) void = null,
};

/// A device offered for binding.
///
/// Bus-neutral on purpose: `location` is whatever identifies the device on its
/// own bus (PCI bus/slot/function today, USB bus/port/interface later), and the
/// bus driver is responsible for filling it in and for the description.
pub const Device = struct {
    bus: []const u8,
    location: [3]u16,
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    prog_if: u8,
    description: []const u8,
};

/// Generic class-level probe used by fallback drivers.
fn classProbe(comptime class: u8, comptime subclass: u8) fn (Device) Confidence {
    return struct {
        fn f(dev: Device) Confidence {
            return if (dev.class == class and dev.subclass == subclass) .weak else .no;
        }
    }.f;
}

/// Exact-ID probe, for drivers that know precisely one device.
fn exactProbe(comptime vendor: u16, comptime device: u16) fn (Device) Confidence {
    return struct {
        fn f(dev: Device) Confidence {
            return if (dev.vendor == vendor and dev.device == device) .exact else .no;
        }
    }.f;
}

/// The registry. Entries are ordered most-specific-first only as a tie-break;
/// confidence is what actually decides. Adding a driver is one entry here plus
/// its module — no #ifdefs, no build-time hardware assumptions.
///
/// IDs are from docs/research/, all HIGH confidence unless noted.
pub const registry = [_]Driver{
    .{
        .name = "gma900",
        .kind = .video,
        .match = &.{.{ .pci_id = .{ .vendor = 0x8086, .device = 0x2592 } }},
        .probe = &exactProbe(0x8086, 0x2592),
    },
    .{
        .name = "vesafb",
        .kind = .video,
        .match = &.{.{ .pci_class = .{ .class = 0x03, .subclass = 0x00 } }},
        .probe = &classProbe(0x03, 0x00),
    },
    .{
        .name = "ata_ich",
        .kind = .block,
        .match = &.{.{ .pci_id = .{ .vendor = 0x8086, .device = 0x2653 } }},
        .probe = &exactProbe(0x8086, 0x2653),
    },
    .{
        .name = "ata_generic",
        .kind = .block,
        .match = &.{.{ .pci_class = .{ .class = 0x01, .subclass = 0x01 } }},
        .probe = &classProbe(0x01, 0x01),
    },
    .{
        .name = "ehci",
        .kind = .usb,
        .match = &.{.{ .pci_class = .{ .class = 0x0C, .subclass = 0x03 } }},
        .probe = &struct {
            fn f(dev: Device) Confidence {
                if (dev.class != 0x0C or dev.subclass != 0x03) return .no;
                // prog_if 0x20 = EHCI, 0x00 = UHCI, 0x10 = OHCI.
                return switch (dev.prog_if) {
                    0x20 => .strong,
                    else => .no,
                };
            }
        }.f,
    },
    .{
        .name = "uhci",
        .kind = .usb,
        .match = &.{.{ .pci_class = .{ .class = 0x0C, .subclass = 0x03 } }},
        .probe = &struct {
            fn f(dev: Device) Confidence {
                if (dev.class != 0x0C or dev.subclass != 0x03) return .no;
                return if (dev.prog_if == 0x00) .strong else .no;
            }
        }.f,
    },
    .{
        .name = "hda",
        .kind = .audio,
        .match = &.{.{ .pci_class = .{ .class = 0x04, .subclass = 0x03 } }},
        .probe = &struct {
            fn f(dev: Device) Confidence {
                if (dev.vendor == 0x8086 and dev.device == 0x2668) return .exact; // ICH6 + ALC662
                return if (dev.class == 0x04 and dev.subclass == 0x03) .strong else .no;
            }
        }.f,
    },
    .{
        .name = "atl2",
        .kind = .net,
        .match = &.{.{ .pci_id = .{ .vendor = 0x1969, .device = 0x2048 } }},
        .probe = &exactProbe(0x1969, 0x2048),
    },
    .{
        .name = "ath5k",
        .kind = .net,
        .match = &.{.{ .pci_id = .{ .vendor = 0x168C, .device = 0x001C } }},
        .probe = &exactProbe(0x168C, 0x001C),
    },
    .{
        .name = "i801smb",
        .kind = .bus,
        .match = &.{.{ .pci_id = .{ .vendor = 0x8086, .device = 0x266A } }},
        .probe = &exactProbe(0x8086, 0x266A),
    },
    .{
        .name = "lpc_ich",
        .kind = .platform,
        .match = &.{.{ .pci_id = .{ .vendor = 0x8086, .device = 0x2641 } }},
        .probe = &exactProbe(0x8086, 0x2641),
    },
};

const Binding = struct {
    dev: Device,
    driver: ?*const Driver,
    confidence: Confidence,
};

var bindings: [64]Binding = undefined;
var binding_count: usize = 0;

/// Start a probing pass. Bus drivers then call `consider` for each device they
/// find, and `report` prints the outcome.
pub fn begin() void {
    binding_count = 0;
}

/// Offer one device for binding. Called by bus drivers; the composition root
/// (src/platform.zig) is what connects the two, so kernel core needs no
/// knowledge of which buses exist.
pub fn consider(dev: Device) void {
    if (binding_count >= bindings.len) return;

    var best: ?*const Driver = null;
    var best_conf: Confidence = .no;
    inline for (&registry) |*drv| {
        const c = drv.probe(dev);
        if (@intFromEnum(c) > @intFromEnum(best_conf)) {
            best_conf = c;
            best = drv;
        }
    }

    bindings[binding_count] = .{ .dev = dev, .driver = best, .confidence = best_conf };
    binding_count += 1;
}

/// Print what bound to what. This table is the porting worksheet on unfamiliar
/// hardware and the first thing to ask for in a bug report.
pub fn report() void {
    if (binding_count == 0) {
        console.warn("no pci devices; config access may be broken", .{});
        return;
    }

    var bound: usize = 0;
    for (bindings[0..binding_count]) |b| {
        if (b.driver != null) bound += 1;
    }
    console.debug("pci", "{d} devices, {d} bound", .{ binding_count, bound });

    // The per-device table is a porting and bug-report aid, not something a
    // user needs at every boot.
    if (!console.isVerbose()) return;

    for (bindings[0..binding_count]) |b| {
        console.setColor(.dark_grey, .black);
        console.printf("  {x:0>2}:{x:0>2}.{d} {x:0>4}:{x:0>4} ", .{
            b.dev.location[0], b.dev.location[1], b.dev.location[2], b.dev.vendor, b.dev.device,
        });

        if (b.driver) |d| {
            console.setColor(switch (b.confidence) {
                .exact => .light_green,
                .strong => .light_cyan,
                .weak => .yellow,
                .no => .dark_grey,
            }, .black);
            console.printf("{s: <12}", .{d.name});
            console.setColor(.dark_grey, .black);
            // Trailing '*' marks a driver that is matched but not yet
            // implemented — better than printing a name that implies it runs.
            console.printf("{s: <7}{s}", .{
                @tagName(b.confidence),
                if (d.attach == null) "* " else "  ",
            });
        } else {
            console.printf("{s: <12}{s: <9}", .{ "-", "" });
        }

        console.printf("{s}\n", .{b.dev.description});
        console.setColor(.light_grey, .black);
    }
}


