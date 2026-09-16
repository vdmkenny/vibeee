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
const lib = @import("lib");
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

/// What a driver answers for, taken from the one declaration both this table
/// and the driver manifests are written from.
///
/// The kernel's `Match` and the shared one are the same shape, so this is a
/// change of type and not of meaning: what the probe reads and what a
/// manifest says cannot come apart.
fn answersFor(comptime name: []const u8) []const probe.Match {
    return comptime blk: {
        const shared = lib.driver.matchesOf(name);
        var out: [shared.len]probe.Match = undefined;
        for (shared, &out) |one, *into| {
            into.* = switch (one) {
                .part => |p| .{ .pci_id = .{ .vendor = p.vendor, .device = p.device } },
                .family => |f| .{ .pci_class = .{ .class = f.class, .subclass = f.subclass } },
                .platform => |what| .{ .platform = what },
            };
        }
        const kept = out;
        break :blk &kept;
    };
}

/// How sure the driver named is about a device, from the same declaration.
fn answering(comptime name: []const u8) fn (Device) Confidence {
    return struct {
        fn f(dev: Device) Confidence {
            return lib.driver.bestOf(lib.driver.matchesOf(name), .{
                .vendor = dev.vendor,
                .device = dev.device,
                .class = dev.class,
                .subclass = dev.subclass,
                .interface = dev.prog_if,
            });
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
        .name = "ata-ich6",
        .kind = .block,
        .match = &.{.{ .pci_id = .{ .vendor = 0x8086, .device = 0x2653 } }},
        .probe = &exact(0x8086, 0x2653),
        .attach = &attachAta,
    },
    .{
        .name = "ata",
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
        // one. Named for what it does, which is to keep the mode already set
        // rather than to set one.
        .name = "firmware-set",
        .kind = .video,
        .match = &.{.{ .pci_class = .{ .class = 0x03, .subclass = 0x00 } }},
        .probe = &class(0x03, 0x00),
        .attach = &attachDisplay,
    },

    // -- USB -------------------------------------------------------------
    .{
        // The programming interface is what tells the three USB controller
        // generations sharing one class apart, and the shared table names
        // it, so this entry and the manifest cannot disagree about which
        // controller is whose.
        .name = "ehci",
        .kind = .usb,
        .match = answersFor("ehci"),
        .probe = &answering("ehci"),
    },
    .{
        .name = "uhci",
        .kind = .usb,
        .match = answersFor("uhci"),
        .probe = &answering("uhci"),
    },
    .{
        .name = "ohci",
        .kind = .usb,
        .match = answersFor("ohci"),
        .probe = &answering("ohci"),
    },

    // -- Audio -----------------------------------------------------------
    .{
        .name = "hda",
        .kind = .audio,
        .match = answersFor("hda"),
        .probe = &answering("hda"),
    },

    .{
        // The AC'97 controller of the Intel chipset line, which is what an
        // emulator gives a machine and what a great deal of the era's
        // hardware carried. The target has the newer one above.
        .name = "ac97",
        .kind = .audio,
        .match = answersFor("ac97"),
        .probe = &answering("ac97"),
    },

    .{
        .name = "es1370",
        .kind = .audio,
        .match = answersFor("es1370"),
        .probe = &answering("es1370"),
    },

    // -- Network ---------------------------------------------------------
    .{
        .name = "atl2",
        .kind = .net,
        .match = answersFor("atl2"),
        .probe = &answering("atl2"),
    },
    .{
        .name = "atl1e",
        .kind = .net,
        .match = answersFor("atl1e"),
        .probe = &answering("atl1e"),
    },
    .{
        .name = "ar5212",
        .kind = .net,
        .match = answersFor("ar5212"),
        .probe = &answering("ar5212"),
        // The part declares class 02:00, which is what an ethernet
        // controller declares. It is a radio.
        .describes = "wireless controller",
    },
    .{
        // The emulator's default NIC, and a card of the era. Having it means
        // the network stack can be exercised in emulation long before the
        // reverse-engineered Atheros driver works.
        .name = "e1000",
        .kind = .net,
        .match = answersFor("e1000"),
        .probe = &answering("e1000"),
    },
    .{
        .name = "e100",
        .kind = .net,
        .match = answersFor("e100"),
        .probe = &answering("e100"),
    },
    .{
        // The Realtek 8139: QEMU's other emulated NIC, and a card a wide
        // slice of the era's hardware carried. Lives in netd.
        .name = "rtl8139",
        .kind = .net,
        .match = answersFor("rtl8139"),
        .probe = &answering("rtl8139"),
    },

    // The chipset's own bridges and its SMBus controller are not here. This
    // table is the drivers a build contains, and an entry naming one it does
    // not have makes a device read as spoken for by something that will never
    // come. What they are is already said by the class they report, and
    // nothing here needs to drive them: the parts behind the LPC bridge are
    // reached through the firmware's own methods, and nothing asks the SMBus
    // anything the embedded controller has not already answered.
};

/// Both ATA entries share this. The task-file registers are the legacy port
/// pairs, so one call covers every channel however many PCI functions the
/// chipset exposes, hence the guard against a second function attaching the
/// same hardware twice. The function itself is still needed: the bus-master
/// registers are in its fourth BAR, and it is what has to be told to address
/// memory.
var ata_attached = false;

fn attachAta(dev: Device) anyerror!void {
    if (ata_attached) return;
    ata_attached = true;
    ata.init(.{ .at = dev.location, .vendor = dev.vendor, .device = dev.device });
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
    display.restore = &restoreMode;

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
    // The console draws straight into the framebuffer, so a mode it could
    // not follow is not set at all: in text mode there is nothing to follow
    // with, and that is known before the adapter is touched.
    if (console.framebufferLayout().addr == 0) return error.Unsupported;
    const before = console.pixelSize();

    const fb = try apply(.{ .width = width, .height = height, .bpp = bpp });

    if (!console.adoptFramebuffer(fb.phys, fb.pitch, fb.width, fb.height)) {
        // The adapter goes back to where the console still is, rather than
        // being left showing a mode nothing draws for.
        _ = apply(.{
            .width = @intCast(before.width),
            .height = @intCast(before.height),
            .bpp = bpp,
        }) catch {};
        return error.Failed;
    }

    announce(fb);
}

/// Set the mode that is already set, the adapter having been powered down and
/// up and forgotten it.
///
/// Nothing moves, which is what makes this right where `requestMode` is not:
/// the geometry is the one already in hand, so a compositor's buffer is still
/// the right shape and the console, if it is the one drawing, has nothing to
/// re-lay. Its grid is redrawn all the same, because the adapter clears the
/// pixels as it takes a mode.
fn restoreMode() display.ModeError!void {
    const geometry = display.describe();
    const fb = try apply(.{
        .width = geometry.width,
        .height = geometry.height,
        .bpp = modeset.Mode.adapter_choice,
    });
    _ = console.adoptFramebuffer(fb.phys, fb.pitch, fb.width, fb.height);
    announce(fb);
}

/// Ask the bound adapter for a mode, in the errors the display speaks.
fn apply(want: modeset.Mode) display.ModeError!modeset.Framebuffer {
    const backend = display_backend orelse return error.Unsupported;
    const set = backend.set orelse return error.Unsupported;

    return set(display_dev, want) catch |err| switch (err) {
        error.Unsupported => error.Unsupported,
        error.Hardware => error.Failed,
    };
}

/// Say where the pixels ended up, and take the pointer plane again.
///
/// Both belong to whatever mode is now set and neither survives a change of
/// one: the write-combining range is worked out from where the scanout buffer
/// is, and the plane's picture goes in the memory after it.
fn announce(fb: modeset.Framebuffer) void {
    display.present(fb.phys, .{
        .width = fb.width,
        .height = fb.height,
        .stride_px = @intCast(fb.pitch / 4),
        .bytes = fb.pitch * fb.height,
    });
    console.info("video", "{d}x{d} native, panel fitter off", .{ fb.width, fb.height });

    const backend = display_backend orelse return;
    const bindPointer = backend.pointer orelse return;
    const plane = bindPointer(display_dev, fb) orelse {
        console.info("video", "no pointer plane, the pointer is drawn in software", .{});
        return;
    };
    display.setPointer(plane);
    console.info("video", "pointer plane, {d} by {d}", .{ plane.side, plane.side });
}
