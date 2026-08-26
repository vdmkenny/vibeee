//! Setting a display mode, per adapter.
//!
//! One interface, several backends. What firmware left us is always available
//! and always the fallback; a backend that knows the adapter can do better,
//! and which one that is comes from the same probe that binds every other
//! driver. Adding a generation is one entry in the table plus its module.
//!
//! Netbooks of this era are overwhelmingly Intel integrated graphics, and the
//! ones that matter fall into three families that share a modeset structure.
//! The table below names them by the machines they shipped in rather than only
//! by their part numbers, because that is how anyone will look one up.

const gen3_backend = @import("gen3.zig");
const probe = @import("../../../kernel/probe.zig");

pub const Error = error{
    /// The backend recognises the adapter but cannot drive that mode.
    Unsupported,
    /// The adapter did not respond as its documentation says it should.
    Hardware,
};

pub const Mode = struct {
    width: u16,
    height: u16,
    bpp: u8 = 32,
    refresh: u8 = 60,
};

/// Where the adapter put the framebuffer once a mode is set.
pub const Framebuffer = struct {
    phys: usize,
    /// Bytes per scanline, which is not width times bytes per pixel.
    pitch: u32,
    width: u16,
    height: u16,
    bpp: u8,
};

pub const Backend = struct {
    /// Short name, as it appears in the boot log.
    name: []const u8,
    /// The family, for a log line someone can read without a PCI database.
    describes: []const u8,
    /// How sure this backend is that it knows the adapter.
    fits: *const fn (dev: probe.Device) probe.Confidence,
    /// Program the adapter. Null while a backend is identified but not yet
    /// written, which is what makes this table an honest status board rather
    /// than a claim.
    set: ?*const fn (dev: probe.Device, want: Mode) Error!Framebuffer = null,
    /// The size the panel already runs at, when the backend can tell. What
    /// makes `set` usable on a machine nobody has characterised: the panel
    /// describes itself instead of being looked up.
    native: ?*const fn (dev: probe.Device) ?Mode = null,
    /// Report the adapter's registers. Reading is safe where writing is not,
    /// so a backend can carry this long before it can carry `set`, and on
    /// hardware without public documentation it is what `set` gets written
    /// from.
    inspect: ?*const fn (dev: probe.Device, w: *std.Io.Writer) void = null,
};

/// Match any of a list of PCI device ids from one vendor.
fn anyOf(comptime vendor: u16, comptime devices: []const u16) fn (probe.Device) probe.Confidence {
    return struct {
        fn f(dev: probe.Device) probe.Confidence {
            if (dev.vendor != vendor) return .no;
            for (devices) |id| {
                if (dev.device == id) return .exact;
            }
            return .no;
        }
    }.f;
}

/// Intel gen4: 965 and GM45. Found in the larger ultraportables of the same
/// years rather than in netbooks proper, and close enough to gen3 to be worth
/// naming here.
const gen4 = [_]u16{
    0x2A02, // GM965
    0x2A12, // GL960
    0x2A42, // GM45, Mobile 4 Series
};

/// Intel gen5: Ironlake, in the last of the small machines before the line
/// stopped being called a netbook.
const gen5 = [_]u16{
    0x0046, // Arrandale
};

/// GMA 500, which is not Intel graphics at all: a licensed PowerVR core with
/// nothing in common with the rest. Named so the log can say what it is rather
/// than falling through to a generic line, and left undriven, which is what
/// every open driver for it eventually concluded too.
const poulsbo = [_]u16{
    0x8108, // US15W
    0x8109,
};

pub const backends = [_]Backend{
    .{
        .name = "intel-gen3",
        .describes = "GMA 900/950/3150",
        .fits = &anyOf(0x8086, &gen3_backend.devices),
        .set = &gen3_backend.set,
        .native = &gen3_backend.native,
        .inspect = &gen3_backend.inspect,
    },
    .{
        .name = "intel-gen4",
        .describes = "GMA X3100/4500",
        .fits = &anyOf(0x8086, &gen4),
    },
    .{
        .name = "intel-gen5",
        .describes = "Ironlake",
        .fits = &anyOf(0x8086, &gen5),
    },
    .{
        .name = "poulsbo",
        .describes = "GMA 500, PowerVR",
        .fits = &anyOf(0x8086, &poulsbo),
    },
};

/// The best backend for an adapter, or null when nothing knows it.
pub fn backendFor(dev: probe.Device) ?*const Backend {
    var best: ?*const Backend = null;
    var rank: probe.Confidence = .no;

    for (&backends) |*backend| {
        const fit = backend.fits(dev);
        if (@intFromEnum(fit) > @intFromEnum(rank)) {
            rank = fit;
            best = backend;
        }
    }
    return best;
}

// ---------------------------------------------------------------------------
// Which machine gets which backend
//
// The register programming cannot be tested without the hardware; which family
// an adapter belongs to can, and getting that wrong is how a machine ends up
// with the wrong modeset attempted on it.
// ---------------------------------------------------------------------------

const std = @import("std");

fn adapter(vendor: u16, device: u16) probe.Device {
    return .{
        .bus = "pci",
        .location = .{ 0, 2, 0 },
        .vendor = vendor,
        .device = device,
        .class = 0x03,
        .subclass = 0x00,
        .prog_if = 0,
        .description = "display controller",
    };
}

fn nameFor(vendor: u16, device: u16) ?[]const u8 {
    const backend = backendFor(adapter(vendor, device)) orelse return null;
    return backend.name;
}

test "the netbooks this is for land on gen3" {
    // Eee PC 701 and 900.
    try std.testing.expectEqualStrings("intel-gen3", nameFor(0x8086, 0x2592).?);
    // Eee PC 901/1000, Aspire One AOA110/150, HP Mini 110.
    try std.testing.expectEqualStrings("intel-gen3", nameFor(0x8086, 0x27AE).?);
    // Eee PC 1001PX, Aspire One D255, HP Mini 210.
    try std.testing.expectEqualStrings("intel-gen3", nameFor(0x8086, 0xA011).?);
}

test "the larger machines of the same years land on their own families" {
    try std.testing.expectEqualStrings("intel-gen4", nameFor(0x8086, 0x2A42).?);
    try std.testing.expectEqualStrings("intel-gen5", nameFor(0x8086, 0x0046).?);
}

test "GMA 500 is recognised as itself rather than as Intel graphics" {
    // Shares a vendor id with the rest and nothing else. Naming it is what
    // stops a gen3 modeset being attempted on a PowerVR core.
    try std.testing.expectEqualStrings("poulsbo", nameFor(0x8086, 0x8108).?);
}

test "an adapter nothing knows falls through to the firmware's mode" {
    // QEMU's Bochs adapter, and anything else this has never seen.
    try std.testing.expectEqual(@as(?[]const u8, null), nameFor(0x1234, 0x1111));
    try std.testing.expectEqual(@as(?[]const u8, null), nameFor(0x8086, 0xFFFF));
}
