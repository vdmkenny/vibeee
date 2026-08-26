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

const probe = @import("kernel/probe.zig");
const ata = @import("drv/block/ata.zig");

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
    .{
        .name = "gma900",
        .kind = .video,
        .match = &.{.{ .pci_id = .{ .vendor = 0x8086, .device = 0x2592 } }},
        .probe = &exact(0x8086, 0x2592),
    },
    .{
        .name = "vesafb",
        .kind = .video,
        .match = &.{.{ .pci_class = .{ .class = 0x03, .subclass = 0x00 } }},
        .probe = &class(0x03, 0x00),
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
