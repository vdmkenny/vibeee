//! The driver table: every driver this build contains, and how to match it.
//!
//! Lives outside `kernel/` because which drivers a build includes is a
//! composition decision, not kernel core's business. The kernel supplies the
//! matching engine and the confidence ranking; this file supplies the
//! candidates, and the two meet in `platform.zig`.
//!
//! **Adding a driver** is one entry here plus its module. Nothing else changes:
//! ranking, attachment order and reporting all read this table.
//!
//! Confidence is what decides binding, not order. An exact vendor:device match
//! beats a class-level fallback, so a generic driver can sit alongside a
//! specific one without either needing to know about the other, which is what
//! lets one image boot both the target machine and hardware it has never seen.

const std = @import("std");
const probe = @import("kernel/probe.zig");
const ata = @import("drv/block/ata.zig");
const console = @import("kernel/console.zig");
const display = @import("kernel/display.zig");
const modeset = @import("drv/video/modeset/modeset.zig");

const Device = probe.Device;
const Confidence = probe.Confidence;

/// Matches one exact vendor:device pair.
fn exact(comptime vendor: u16, comptime device: u16) fn (Device) Confidence {
    return struct {
        fn f(dev: Device) Confidence {
            return if (dev.vendor == vendor and dev.device == device) .exact else .no;
        }
    }.f;
}

/// Matches any device of a PCI class, for generic fallbacks.
fn class(comptime c: u8, comptime sub: u8) fn (Device) Confidence {
    return struct {
        fn f(dev: Device) Confidence {
            return if (dev.class == c and dev.subclass == sub) .weak else .no;
        }
    }.f;
}

/// Matches when the named modeset backend is the best fit for the adapter.
///
/// The families are described once, where the machines they shipped in are
/// listed; this only asks which one won.
fn modesetFamily(comptime name: []const u8) fn (Device) Confidence {
    return struct {
        fn f(dev: Device) Confidence {
            const backend = modeset.backendFor(dev) orelse return .no;
            if (!std.mem.eql(u8, backend.name, name)) return .no;
            // A family that has no modeset written yet is recognised but not
            // preferred: it still binds ahead of the generic entry, and the
            // log says which it was, which is most of the value on a machine
            // nobody has run this on before.
            return if (backend.set != null) .exact else .strong;
        }
    }.f;
}

pub const table = [_]probe.Driver{
    // -- Storage ---------------------------------------------------------
    .{
        // The Eee PC 701's ICH6-M in combined mode. Same driver as the generic
        // entry below; the separate match exists so the boot log says which
        // machine was recognised, and so machine-specific quirks have somewhere
        // to attach later.
        .name = "ata_ich",
        .kind = .block,
        .match = &.{.{ .pci_id = .{ .vendor = 0x8086, .device = 0x2653 } }},
        .probe = &exact(0x8086, 0x2653),
        .attach = &attachAta,
    },
    .{
        .name = "ata_generic",
        .kind = .block,
        .match = &.{.{ .pci_class = .{ .class = 0x01, .subclass = 0x01 } }},
        .probe = &class(0x01, 0x01),
        .attach = &attachAta,
    },

    // -- Video -----------------------------------------------------------
    //
    // One entry per modeset family rather than per part. Which one an adapter
    // belongs to, and which machines it shipped in, is
    // `drv/video/modeset/modeset.zig`; here they only need to bind.
    .{
        .name = "intel-gen3",
        .kind = .video,
        .match = &.{.{ .pci_class = .{ .class = 0x03, .subclass = 0x00 } }},
        .probe = &modesetFamily("intel-gen3"),
        .attach = &attachDisplay,
    },
    .{
        .name = "intel-gen4",
        .kind = .video,
        .match = &.{.{ .pci_class = .{ .class = 0x03, .subclass = 0x00 } }},
        .probe = &modesetFamily("intel-gen4"),
        .attach = &attachDisplay,
    },
    .{
        .name = "intel-gen5",
        .kind = .video,
        .match = &.{.{ .pci_class = .{ .class = 0x03, .subclass = 0x00 } }},
        .probe = &modesetFamily("intel-gen5"),
        .attach = &attachDisplay,
    },
    .{
        .name = "poulsbo",
        .kind = .video,
        .match = &.{.{ .pci_class = .{ .class = 0x03, .subclass = 0x00 } }},
        .probe = &modesetFamily("poulsbo"),
        .attach = &attachDisplay,
    },
    .{
        // Whatever firmware left on the screen. Always available, always the
        // fallback, and on a machine whose only output is that screen it is
        // what makes an unrecognised adapter a working one rather than a dead
        // one.
        .name = "vesafb",
        .kind = .video,
        .match = &.{.{ .pci_class = .{ .class = 0x03, .subclass = 0x00 } }},
        .probe = &class(0x03, 0x00),
        .attach = &attachDisplay,
    },

    // -- USB -------------------------------------------------------------
    .{
        .name = "ehci",
        .kind = .usb,
        .match = &.{.{ .pci_class = .{ .class = 0x0C, .subclass = 0x03 } }},
        .probe = &struct {
            fn f(dev: Device) Confidence {
                // prog_if distinguishes the three USB controller generations
                // sharing one class: 0x00 UHCI, 0x10 OHCI, 0x20 EHCI.
                if (dev.class != 0x0C or dev.subclass != 0x03) return .no;
                return if (dev.prog_if == 0x20) .strong else .no;
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

    // -- Audio -----------------------------------------------------------
    .{
        .name = "hda",
        .kind = .audio,
        .match = &.{.{ .pci_class = .{ .class = 0x04, .subclass = 0x03 } }},
        .probe = &struct {
            fn f(dev: Device) Confidence {
                // ICH6 with the ALC662 codec, verified on the target.
                if (dev.vendor == 0x8086 and dev.device == 0x2668) return .exact;
                return if (dev.class == 0x04 and dev.subclass == 0x03) .strong else .no;
            }
        }.f,
    },

    // -- Network ---------------------------------------------------------
    .{
        .name = "atl2",
        .kind = .net,
        .match = &.{.{ .pci_id = .{ .vendor = 0x1969, .device = 0x2048 } }},
        .probe = &exact(0x1969, 0x2048),
    },
    .{
        .name = "ath5k",
        .kind = .net,
        .match = &.{.{ .pci_id = .{ .vendor = 0x168C, .device = 0x001C } }},
        .probe = &exact(0x168C, 0x001C),
    },
    .{
        // QEMU's default NIC. Not present on any real target, but having it
        // means the network stack can be exercised in emulation long before the
        // reverse-engineered Atheros driver works.
        .name = "e1000",
        .kind = .net,
        .match = &.{.{ .pci_id = .{ .vendor = 0x8086, .device = 0x100E } }},
        .probe = &exact(0x8086, 0x100E),
    },
    .{
        // The Realtek 8139: QEMU's other emulated NIC, and a card a wide
        // slice of the era's hardware carried. Lives in netd.
        .name = "rtl8139",
        .kind = .net,
        .match = &.{.{ .pci_id = .{ .vendor = 0x10EC, .device = 0x8139 } }},
        .probe = &exact(0x10EC, 0x8139),
    },

    // -- Platform --------------------------------------------------------
    .{
        .name = "i801smb",
        .kind = .bus,
        .match = &.{.{ .pci_id = .{ .vendor = 0x8086, .device = 0x266A } }},
        .probe = &exact(0x8086, 0x266A),
    },
    .{
        .name = "lpc_ich",
        .kind = .platform,
        .match = &.{.{ .pci_id = .{ .vendor = 0x8086, .device = 0x2641 } }},
        .probe = &exact(0x8086, 0x2641),
    },
};

/// Both ATA entries share this. The controller is addressed through the legacy
/// port pairs rather than its BARs, so one call covers every channel however
/// many PCI functions the chipset exposes, hence the guard against a second
/// function attaching the same hardware twice.
var ata_attached = false;

fn attachAta(dev: Device) anyerror!void {
    _ = dev;
    if (ata_attached) return;
    ata_attached = true;
    ata.init();
}

var display_attached = false;
/// The adapter that answered, kept so its registers can be reported later.
var display_dev: Device = undefined;
var display_backend: ?*const modeset.Backend = null;

/// What the panel runs at, for a caller that should not have to know the
/// machine it is on.
fn panelMode() ?display.Panel {
    const backend = display_backend orelse return null;
    const ask = backend.native orelse return null;
    const mode = ask(display_dev) orelse return null;
    return .{ .width = mode.width, .height = mode.height };
}

/// Report the display adapter's registers, for `display regs`.
fn reportDisplayRegisters(w: *std.Io.Writer) void {
    const backend = display_backend orelse return;
    const f = backend.inspect orelse return;
    f(display_dev, w);
}

/// Bring up the display.
///
/// Nothing here sets a mode yet: firmware left one on the screen and that is
/// what the console is already drawing to. What this does is say which
/// adapter was recognised and what would drive it, which on a machine nobody
/// has run this on before is the difference between a diagnosable panel and a
/// blank one.
fn attachDisplay(dev: Device) anyerror!void {
    // The adapter answers on more than one PCI function for the same silicon,
    // so the first function that resolves a backend speaks for all of them.
    if (display_attached) return;

    const backend = modeset.backendFor(dev) orelse {
        console.info("video", "unrecognised adapter, keeping firmware mode", .{});
        return;
    };
    display_attached = true;
    display_dev = dev;
    display_backend = backend;
    if (backend.inspect != null) display.setReporter(&reportDisplayRegisters);
    if (backend.native != null) display.setPanelQuery(&panelMode);

    display.setAdapter(.{
        .backend = backend.name,
        .family = backend.describes,
        .can_set = backend.set != null,
    });

    if (backend.set == null) {
        console.info("video", "{s} ({s}), no modeset, keeping firmware mode", .{
            backend.name,
            backend.describes,
        });
        return;
    }

    display.setMode = &requestMode;

    // A backend that can read the panel is asked for it here. Firmware sets a
    // mode without knowing what will run, and on these machines that means a
    // smaller plane stretched to fit; the panel's own size is always the better
    // answer and is the one thing the adapter can be sure of.
    const panel = panelMode() orelse return;
    requestMode(panel.width, panel.height, 32) catch |err| {
        console.warn("video: {s} kept the firmware's mode, {d}x{d} refused: {s}", .{
            backend.name, panel.width, panel.height, @errorName(err),
        });
        return;
    };
}

/// Ask the bound adapter for a mode, and bring the console with it.
///
/// The console draws straight into the framebuffer, so a mode change it did
/// not follow would leave every glyph landing at the wrong offset.
fn requestMode(width: u16, height: u16, bpp: u8) display.ModeError!void {
    const backend = display_backend orelse return error.Unsupported;
    const set = backend.set orelse return error.Unsupported;

    const fb = set(display_dev, .{ .width = width, .height = height, .bpp = bpp }) catch |err| {
        return switch (err) {
            error.Unsupported => error.Unsupported,
            error.Hardware => error.Failed,
        };
    };

    if (!console.adoptFramebuffer(fb.phys, fb.pitch, fb.width, fb.height)) return error.Failed;

    display.present(fb.phys, .{
        .width = fb.width,
        .height = fb.height,
        .stride_px = @intCast(fb.pitch / 4),
        .bytes = fb.pitch * fb.height,
    });
    console.info("video", "{d}x{d} native, panel fitter off", .{ fb.width, fb.height });
}
