//! Composition root: the one place that is allowed to know about kernel core,
//! the architecture layer and concrete drivers at the same time, and wire them
//! together.
//!
//! Keeping this outside `kernel/` is what lets the layering rule stay strict
//! (see tools/check-layering.zig). Kernel core defines the shape of a bus
//! enumeration and of driver binding; the bus drivers know how to find devices;
//! neither imports the other, and this file introduces them.

const std = @import("std");
const console = @import("kernel/console.zig");
const display = @import("kernel/display.zig");
const input = @import("kernel/input.zig");
const probe = @import("kernel/probe.zig");
const bootinfo = @import("kernel/bootinfo.zig");
const drivers = @import("drivers.zig");
const ramdisk = @import("drv/block/ramdisk.zig");
const acpi = @import("drv/acpi/tables.zig");
const madt = @import("drv/acpi/madt.zig");
const acpi_power = @import("drv/acpi/power.zig");
const irq = @import("kernel/irq.zig");
const clock = @import("kernel/clock.zig");
const cmos = @import("drv/rtc/cmos.zig");
const shutdown = @import("kernel/shutdown.zig");
const smbios = @import("drv/platform/smbios.zig");
const sysinfo = @import("kernel/sysinfo.zig");
const kbd = @import("drv/input/i8042.zig");
const mouse = @import("drv/input/ps2mouse.zig");
const uart = @import("drv/serial/uart16550.zig");
const block = @import("kernel/block.zig");
const pci = @import("drv/bus/pci.zig");
const sched = @import("kernel/sched.zig");
const usermode = @import("arch/x86/usermode.zig");
const elf = @import("kernel/elf.zig");
const heap = @import("kernel/heap.zig");
const vfs = @import("kernel/vfs.zig");
const hal = @import("kernel/hal.zig");

/// Bring up devices that need no bus enumeration to find.
///
/// Serial comes first and unconditionally: if the machine has a port, every
/// line after this one is also readable as text, which is worth more than the
/// eighty lines the driver costs.
/// Attach a serial port, if there is one, before anything else logs.
///
/// Separate from the rest of device bring-up purely so it happens first: every
/// line after this point is then readable as text on a machine that has a port.
pub fn earlyConsole() void {
    if (uart.init()) |io| {
        console.setMirror(uart.write);
        console.info("serial", "16550 at {x:0>3}, mirroring console", .{io});
    }
}

/// Hand firmware-derived identity to the kernel's information service.
///
/// Done here because it is the one place allowed to know about both the
/// firmware tables and the kernel at once.
fn publishPlatform() void {
    const ram = smbios.memoryHardware();

    sysinfo.setPlatform(.{
        .acpi_rsdp = acpi_root,
        .system_manufacturer = smbios.systemManufacturer(),
        .system_product = smbios.systemProduct(),
        .bios_vendor = smbios.biosVendor(),
        .bios_version = smbios.biosVersion(),
        .smbios_table = if (smbios.get()) |i| i.table else null,

        .ram_total_mb = if (ram) |r| r.total_mb else 0,
        .ram_devices = if (ram) |r| r.devices else 0,
        .ram_speed_mhz = if (ram) |r| r.speed_mhz else 0,
        .ram_type = if (ram) |r| r.typeName() else "",

    });

    if (smbios.systemProduct()) |product| {
        console.info("board", "{s} {s}", .{ smbios.systemManufacturer() orelse "", product });
    }
}

/// Report the console's geometry once the framebuffer, if any, is running.
pub fn reportVideo() void {
    const px = console.pixelSize();
    if (px.width != 0) {
        console.info("video", "{d}x{d} pixels, {d}x{d} text, font {s}", .{
            px.width, px.height, console.width(), console.height(), console.fontName(),
        });
        const fb = console.framebufferLayout();
        console.info("video", "framebuffer at {x:0>8}, pitch {d}", .{ fb.addr, fb.pitch });
    } else {
        console.info("video", "{d}x{d} text mode", .{ console.width(), console.height() });
    }
}

/// Read the firmware's description of the machine.
///
/// Separate from `earlyDevices` and called well before it: the interrupt
/// controller is chosen from the MADT, and that happens before there is a heap
/// or a driver of any kind. Reading tables needs neither.
pub fn readFirmwareTables(bi: *const bootinfo.BootInfo) void {
    acpi_root = bi.rsdp;
    acpi.init(bi.rsdp);
}

/// Kept from the handover so `publishPlatform` can pass it on. The tables are
/// read long before anything can be published, and the address is the one
/// thing a userspace interpreter needs that it cannot find for itself without
/// mapping and searching the BIOS area again.
var acpi_root: u32 = 0;

/// How this machine wires its interrupts, as the firmware describes it.
///
/// Here rather than inside the architecture because knowing about ACPI and
/// knowing about the IOAPIC at the same time is the composition root's job:
/// another board would answer this from a device tree without a line of the
/// interrupt code changing.
pub fn interruptRouting() ?irq.Routing {
    return madt.parse();
}

pub fn earlyDevices(bi: *const bootinfo.BootInfo) void {
    smbios.init();
    publishPlatform();

    shutdown.setPowerOps(.{ .off = acpi_power.off, .reset = acpi_power.reset });

    if (acpi.get()) |a| {
        if (a.s5_found) {
            console.info("acpi", "pm1a {x:0>4}, S5 type {d}", .{ a.pm1a_control, a.slp_typ_a });
        } else {
            console.warn("acpi: no S5 in DSDT; power off will fall back", .{});
        }
    }

    // The RTC is read exactly once. From here on the wall clock runs off the
    // monotonic counter, so nothing pays for a CMOS round trip to ask the time.
    const t = cmos.now();
    if (cmos.looksUnset(t)) {
        console.warn("rtc: clock not set; timestamps and TLS will be wrong until corrected", .{});
    } else {
        clock.setCivil(.{
            .year = t.year,
            .month = t.month,
            .day = t.day,
            .hour = t.hour,
            .minute = t.minute,
            .second = t.second,
        }, "rtc");
        console.info("rtc", "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
            t.year, t.month, t.day, t.hour, t.minute, t.second,
        });
    }

    kbd.init();

    // The pointer is clamped to the screen, so the display has to be up first.
    // Text mode reports no pixel geometry, so the pointer is bounded by the
    // cell grid at the VGA font's size. A pointer free to leave the screen
    // would be worse than one confined to an approximation.
    const screen = console.pixelSize();
    if (screen.width > 0) {
        input.setPointerBounds(screen.width, screen.height);
    } else {
        input.setPointerBounds(console.width() * 9, console.height() * 16);
    }
    _ = mouse.init();

    // The display becomes acquirable only once something has actually set a
    // graphics mode. In text mode there is nothing a compositor could map.
    if (bi.hasFramebuffer() and bi.fb_bpp == 32) {
        display.present(bi.fb_addr, .{
            .width = @intCast(bi.fb_width),
            .height = @intCast(bi.fb_height),
            .stride_px = @intCast(bi.fb_pitch / 4),
            .buffers = 1,
            // A VESA framebuffer offers no page flip, no hardware cursor and
            // no vertical blank. The GMA900 driver will fill these in.
            .caps = 0,
            .bytes = @intCast(@as(usize, bi.fb_pitch) * bi.fb_height),
        });
    }
}

/// Enumerate every bus this machine has and bind drivers to what turns up.
pub fn probeHardware(bi: *const bootinfo.BootInfo) void {
    probe.begin(&drivers.table);
    enumeratePci();
    // The USB handover inside the walk asks the firmware to stop emulating
    // input; the keyboard controller's own settings must survive that.
    kbd.reassert();
    // Attach before reporting, so the table shows what actually came up rather
    // than what merely matched.
    probe.attachAll();
    probe.report();

    reportStorage();
    mountFilesystems(bi);
}

/// Names for auto-mounted media, e.g. "/media/hd1p1". Static storage because a
/// Mount keeps the path and there is nowhere else for it to live.
var media_names: [vfs.MAX_MOUNTS][vfs.MAX_PATH]u8 = undefined;
var media_used: usize = 0;

/// Mount every filesystem found.
///
/// The first mountable partition becomes the root; the rest appear under
/// /media, which is where removable media will land once usbd can enumerate it.
///
/// Volumes are recognised by content rather than by the MBR type byte: the type
/// byte is a hint that is frequently wrong, and mounting has to validate the
/// boot sector anyway.
/// Register the root filesystem stage2 loaded into RAM, if there is one.
///
/// Returns the device so the mount pass can prefer it: the RAM copy is the one
/// medium guaranteed to be readable, whatever the machine's storage turns out
/// to be doing.
fn registerRootfs(bi: *const bootinfo.BootInfo) ?*const block.Device {
    if (bi.rootfs_phys == 0 or bi.rootfs_len == 0) return null;
    return ramdisk.register(bi.rootfs_phys, bi.rootfs_len, false);
}

fn mountFilesystems(bi: *const bootinfo.BootInfo) void {
    var mounted_root = false;

    // The RAM root wins over anything on disk. On the target this is not a
    // preference but a necessity: the medium the machine booted from is behind
    // a USB reader and unreachable until usbd exists.
    if (registerRootfs(bi)) |rd| {
        if (vfs.mount("/", rd, false)) |_| {
            mounted_root = true;
            reportMount("/", rd);
        } else |err| {
            console.warn("vfs: RAM root will not mount: {s}", .{@errorName(err)});
        }
    }

    for (block.list(), 0..) |*dev, i| {
        if (!block.isMountCandidate(i)) continue;

        if (!mounted_root) {
            if (vfs.mount("/", dev, false)) |_| {
                mounted_root = true;
                reportMount("/", dev);
                continue;
            } else |_| {}
        }

        if (media_used >= media_names.len) continue;
        const path = std.fmt.bufPrint(&media_names[media_used], "/media/{s}", .{dev.name}) catch continue;
        media_used += 1;

        // Anything that is not the boot volume is treated as removable: it is
        // the safe assumption, and it only affects unmount expectations.
        if (vfs.mount(path, dev, true)) |_| {
            reportMount(path, dev);
        } else |err| switch (err) {
            error.NotFat, error.Unsupported => {},
            else => console.warn("vfs: cannot mount {s}: {s}", .{ dev.name, @errorName(err) }),
        }
    }

    if (!mounted_root) console.warn("vfs: no root filesystem", .{});
}

fn reportMount(path: []const u8, dev: *const block.Device) void {
    const r = vfs.resolve(path) catch return;
    const vol = &r.mount.volume;
    console.info("mount", "{s} on {s} ({s}, {d} MiB)", .{
        path,
        dev.name,
        @tagName(vol.kind),
        @as(u64, vol.cluster_count) * vol.clusterSize() / (1024 * 1024),
    });
}

/// Read a file into freshly allocated memory.
fn readFile(path: []const u8) ?[]u8 {
    const entry = vfs.stat(path) catch |err| {
        console.warn("vfs: {s}: {s}", .{ path, @errorName(err) });
        return null;
    };

    const buf = heap.allocator.alloc(u8, entry.size) catch {
        console.warn("vfs: no memory for {s} ({d} bytes)", .{ path, entry.size });
        return null;
    };

    const n = vfs.readFile(path, buf) catch |err| {
        console.warn("vfs: reading {s}: {s}", .{ path, @errorName(err) });
        heap.allocator.free(buf);
        return null;
    };
    return buf[0..n];
}

fn reportStorage() void {
    const devs = block.list();
    if (devs.len == 0) {
        console.warn("block: no storage found", .{});
        return;
    }
    var total: u64 = 0;
    for (devs) |d| {
        if (d.offset == 0) total += d.bytes();
    }
    console.info("block", "{d} device(s), {d} MiB total", .{ devs.len, total / (1024 * 1024) });
}

/// Take a USB controller away from the firmware's system management code.
///
/// Two shapes of the same eviction. A UHCI controller keeps its trap enables
/// in one configuration word: zeros for the enables and ones over the
/// latched statuses end it. An EHCI controller keeps a formal semaphore in
/// its extended capabilities: the operating system asks, the BIOS releases,
/// and a BIOS that will not is dispossessed, which is the sequence every
/// operating system performs before touching the controller.
fn handOverUsb(addr: pci.Address, prog_if: u8) void {
    switch (prog_if) {
        0x00 => { // UHCI
            const LEGSUP: u8 = 0xC0;
            const RELEASED: u32 = 0x8F00; // enables zero, statuses cleared
            const kept = pci.configRead32(addr, LEGSUP) & 0xFFFF_0000;
            pci.configWrite32(addr, LEGSUP, kept | RELEASED);
            console.debug("usb", "uhci at {x:0>2}:{x:0>2}.{d} handed over", .{
                addr.bus, addr.slot, addr.func,
            });
        },
        0x20 => { // EHCI
            const bar = pci.configRead32(addr, pci.BAR0_OFFSET) & ~@as(u32, 0xF);
            if (bar == 0) return;
            const regs = hal.mapMmio(bar, 0x1000, .uncached) catch return;
            const hccparams: *const volatile u32 = @ptrFromInt(regs + 0x08);
            const eecp: u8 = @truncate((hccparams.* >> 8) & 0xFF);
            if (eecp < 0x40) return;

            // The semaphore: the OS-owned bit asked for, the BIOS-owned bit
            // waited out, and a BIOS that keeps holding is dispossessed.
            const OS_OWNED: u32 = 1 << 24;
            const BIOS_OWNED: u32 = 1 << 16;
            var legsup = pci.configRead32(addr, eecp);
            pci.configWrite32(addr, eecp, legsup | OS_OWNED);
            var patience: u32 = 0;
            while (patience < 100) : (patience += 1) {
                legsup = pci.configRead32(addr, eecp);
                if (legsup & BIOS_OWNED == 0) break;
                const until = clock.monotonicMicros() + 1_000;
                while (clock.monotonicMicros() < until) {}
            }
            if (legsup & BIOS_OWNED != 0) {
                pci.configWrite32(addr, eecp, OS_OWNED);
            }

            // And the trap enables behind it, off; their statuses, cleared.
            pci.configWrite32(addr, eecp + 4, 0xE000_0000);
            console.debug("usb", "ehci at {x:0>2}:{x:0>2}.{d} handed over", .{
                addr.bus, addr.slot, addr.func,
            });
        },
        else => {},
    }
}

fn enumeratePci() void {
    pci.enumerate(struct {
        fn found(addr: pci.Address, vendor: u16, device: u16) void {
            const class_reg = pci.configRead32(addr, pci.CLASS_OFFSET);
            const class: u8 = @truncate(class_reg >> 24);
            const subclass: u8 = @truncate(class_reg >> 16);

            // The firmware runs USB keyboard emulation from system
            // management mode, polled on a periodic trap that shares its
            // interrupt plumbing with whatever else sits on those pins:
            // unmasking such a pin with the emulation live is a machine that
            // stops. Handed over at boot; this machine's own keyboard is not
            // USB, so nothing is lost but the trap.
            if (class == 0x0C and subclass == 0x03) {
                handOverUsb(addr, @truncate((class_reg >> 8) & 0xFF));
            }

            probe.consider(.{
                .bus = "pci",
                .location = .{ addr.bus, addr.slot, addr.func },
                .vendor = vendor,
                .device = device,
                .class = class,
                .subclass = subclass,
                .prog_if = @truncate(class_reg >> 8),
                .description = pci.describe(class, subclass),
            });
        }
    }.found);
}


/// Load the built-in user program into a fresh address space and drop to
/// Ring 3.
///
/// Never returns: the calling thread becomes the user process, and the only way
/// back into the kernel is a trap. Runs from a thread so its kernel stack is the
/// one the CPU switches to on that trap.
pub fn enterUserMode(path: []const u8, args: []const []const u8) noreturn {
    const image = readFile(path) orelse {
        console.fail("user: cannot read {s}", .{path});
        sched.exit();
    };

    var space = hal.AddressSpace.create() catch {
        console.fail("user: cannot create address space", .{});
        sched.exit();
    };

    const loaded = elf.load(&space, image) catch |err| {
        console.fail("user: {s} loading {d}-byte image", .{ @errorName(err), image.len });
        sched.exit();
    };

    const stack_top = usermode.setupStack(&space, args) catch {
        console.fail("user: cannot set up stack", .{});
        sched.exit();
    };

    const t = sched.currentThread() orelse {
        console.fail("user: no current thread to borrow a kernel stack from", .{});
        sched.exit();
    };

    console.debug("user", "entry {x:0>8}, {d} bytes", .{ loaded.entry, image.len });

    // This thread becomes process 1. Recording that is what lets the kernel
    // re-parent orphans onto it: a process whose parent has died still has
    // someone to collect it, which is the difference between a zombie that is
    // eventually freed and one that is never freed.
    sched.setInit(t.id);

    // From here the low half of the address space belongs to the process. The
    // thread records it too, so the scheduler restores it after any switch.
    sched.setAddressSpace(t, space);
    space.activate();
    sched.noteAddressSpace(space.pd_phys);

    usermode.enter(
        loaded.entry,
        stack_top,
        @intFromPtr(t.stack.ptr) + t.stack.len,
    );
}
