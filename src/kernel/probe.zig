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
    /// Generic class-level match, works, but dumbly.
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
    /// Bring the device up. Left null while a driver is designed but not yet
    /// written, so the probe table doubles as an honest status board.
    attach: ?*const fn (dev: Device) anyerror!void = null,
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

const Binding = struct {
    dev: Device,
    driver: ?*const Driver,
    confidence: Confidence,
    attached: bool = false,
    failed: bool = false,
};

var bindings: [64]Binding = undefined;
var binding_count: usize = 0;

/// Drivers available to bind, supplied by the composition root.
var registry: []const Driver = &.{};

/// Start a probing pass with the given driver set. Bus drivers then call
/// `consider` for each device they find, `attachAll` brings them up, and
/// `report` prints the outcome.
pub fn begin(drivers: []const Driver) void {
    registry = drivers;
    binding_count = 0;
}

/// Offer one device for binding. Called by bus drivers; the composition root
/// (src/platform.zig) is what connects the two, so kernel core needs no
/// knowledge of which buses exist.
pub fn consider(dev: Device) void {
    if (binding_count >= bindings.len) return;

    var best: ?*const Driver = null;
    var best_conf: Confidence = .no;
    for (registry) |*drv| {
        const c = drv.probe(dev);
        if (@intFromEnum(c) > @intFromEnum(best_conf)) {
            best_conf = c;
            best = drv;
        }
    }

    bindings[binding_count] = .{ .dev = dev, .driver = best, .confidence = best_conf };
    binding_count += 1;
}

/// Bring up every bound device.
///
/// Ordered by confidence rather than by discovery: an exact match should
/// initialise before a generic fallback that matched the same class, so the
/// fallback sees hardware already claimed and stays out of the way.
///
/// A driver that fails to attach is recorded, not fatal. One dead device should
/// not cost the machine every other device behind it in the list.
pub fn attachAll() void {
    var level: u8 = @intFromEnum(Confidence.exact);
    while (true) : (level -= 1) {
        for (bindings[0..binding_count]) |*b| {
            if (@intFromEnum(b.confidence) != level) continue;
            const drv = b.driver orelse continue;
            const attach = drv.attach orelse continue;
            if (b.attached or b.failed) continue;

            attach(b.dev) catch |err| {
                b.failed = true;
                console.warn("{s}: attach failed on {s}: {s}", .{
                    drv.name, b.dev.description, @errorName(err),
                });
                continue;
            };
            b.attached = true;
        }
        if (level == @intFromEnum(Confidence.weak)) break;
    }
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
            // The marker states what actually happened, so a driver that
            // exists but failed cannot be mistaken for one that is running.
            console.printf("{s: <7}{s}", .{
                @tagName(b.confidence),
                if (b.failed) "! " else if (b.attached) "  " else "* ",
            });
        } else {
            console.printf("{s: <12}{s: <9}", .{ "-", "" });
        }

        console.printf("{s}\n", .{b.dev.description});
        console.setColor(.light_grey, .black);
    }
}


