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
const probe = @import("kernel/probe.zig");
const bootinfo = @import("kernel/bootinfo.zig");
const drivers = @import("drivers.zig");
const ramdisk = @import("drv/block/ramdisk.zig");
const acpi = @import("drv/acpi/tables.zig");
const acpi_power = @import("drv/acpi/power.zig");
const cmos = @import("drv/rtc/cmos.zig");
const shutdown = @import("kernel/shutdown.zig");
const kbd = @import("drv/input/i8042.zig");
const uart = @import("drv/serial/uart16550.zig");
const bcache = @import("kernel/bcache.zig");
const block = @import("kernel/block.zig");
const pci = @import("drv/bus/pci.zig");
const sched = @import("kernel/sched.zig");
const usermode = @import("arch/x86/usermode.zig");
const elf = @import("kernel/elf.zig");
const fat = @import("kernel/fat.zig");
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
        console.debug("serial", "16550 at {x:0>3}, mirroring console", .{io});
    }
}

pub fn earlyDevices(bi: *const bootinfo.BootInfo) void {
    acpi.init(bi.rsdp);
    shutdown.setPowerOps(.{ .off = acpi_power.off, .reset = acpi_power.reset });

    if (acpi.get()) |a| {
        if (a.s5_found) {
            console.debug("acpi", "pm1a {x:0>4}, S5 type {d}", .{ a.pm1a_control, a.slp_typ_a });
        } else {
            console.warn("acpi: no S5 in DSDT; power off will fall back", .{});
        }
    }

    const t = cmos.now();
    if (cmos.looksUnset(t)) {
        console.warn("rtc: clock not set; TLS will fail until time is corrected", .{});
    } else {
        console.debug("rtc", "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
            t.year, t.month, t.day, t.hour, t.minute, t.second,
        });
    }

    kbd.init();
}

/// Enumerate every bus this machine has and bind drivers to what turns up.
pub fn probeHardware(bi: *const bootinfo.BootInfo) void {
    probe.begin(&drivers.table);
    enumeratePci();
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
    console.debug("mount", "{s} on {s} ({s}, {d} MiB)", .{
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
    console.debug("block", "{d} device(s), {d} MiB total", .{ devs.len, total / (1024 * 1024) });
}

fn enumeratePci() void {
    pci.enumerate(struct {
        fn found(addr: pci.Address, vendor: u16, device: u16) void {
            const class_reg = pci.configRead32(addr, pci.CLASS_OFFSET);
            const class: u8 = @truncate(class_reg >> 24);
            const subclass: u8 = @truncate(class_reg >> 16);

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
pub fn enterUserMode() noreturn {
    // Prefer the copy on disk: that path exercises ATA, the partition table and
    // FAT together. The embedded copy is the fallback, so a machine whose
    // storage is not yet working still reaches user mode.
    var from_disk = true;
    const image = readFile("/HELLO") orelse blk: {
        from_disk = false;
        break :blk @embedFile("user_hello");
    };

    var space = hal.AddressSpace.create() catch {
        console.fail("user: cannot create address space", .{});
        sched.exit();
    };

    const loaded = elf.load(&space, image) catch |err| {
        console.fail("user: {s} loading {d}-byte image", .{ @errorName(err), image.len });
        sched.exit();
    };

    const stack_top = usermode.setupStack(&space) catch {
        console.fail("user: cannot map stack", .{});
        sched.exit();
    };

    const t = sched.currentThread() orelse {
        console.fail("user: no current thread to borrow a kernel stack from", .{});
        sched.exit();
    };

    console.debug("user", "entry {x:0>8}, {d} bytes from {s}", .{
        loaded.entry, image.len, if (from_disk) "disk" else "kernel image",
    });

    // From here the low half of the address space belongs to the process.
    space.activate();

    usermode.enter(
        loaded.entry,
        stack_top,
        @intFromPtr(t.stack.ptr) + t.stack.len,
    );
}
