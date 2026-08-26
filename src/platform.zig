//! Composition root: the one place that is allowed to know about kernel core,
//! the architecture layer and concrete drivers at the same time, and wire them
//! together.
//!
//! Keeping this outside `kernel/` is what lets the layering rule stay strict
//! (see tools/check-layering.zig). Kernel core defines the shape of a bus
//! enumeration and of driver binding; the bus drivers know how to find devices;
//! neither imports the other, and this file introduces them.

const console = @import("kernel/console.zig");
const probe = @import("kernel/probe.zig");
const ata = @import("drv/block/ata.zig");
const block = @import("kernel/block.zig");
const pci = @import("drv/bus/pci.zig");
const sched = @import("kernel/sched.zig");
const usermode = @import("arch/x86/usermode.zig");
const elf = @import("kernel/elf.zig");
const fat = @import("kernel/fat.zig");
const heap = @import("kernel/heap.zig");
const hal = @import("kernel/hal.zig");

/// Enumerate every bus this machine has and bind drivers to what turns up.
pub fn probeHardware() void {
    probe.begin();
    enumeratePci();
    probe.report();

    // Storage comes up after the bus scan so the probe table reflects what was
    // found before any driver starts touching hardware.
    ata.init();
    reportStorage();
    mountBootVolume();
}

/// The mounted boot filesystem, if one was found.
var boot_volume: ?fat.Volume = null;

/// Mount the first FAT partition found. Deliberately by content rather than by
/// the MBR type byte: the type byte is a hint that is often wrong, and `mount`
/// already has to validate the boot sector anyway.
fn mountBootVolume() void {
    for (block.list()) |*dev| {
        if (dev.offset == 0) continue; // whole disks, not partitions
        const vol = fat.mount(dev) catch continue;
        boot_volume = vol;
        console.debug("fat", "{s}: {s}, {d} clusters of {d} B ({d} MiB)", .{
            dev.name,
            @tagName(vol.kind),
            vol.cluster_count,
            vol.clusterSize(),
            @as(u64, vol.cluster_count) * vol.clusterSize() / (1024 * 1024),
        });
        return;
    }
    console.warn("fat: no filesystem found", .{});
}

/// Read a file from the boot filesystem into freshly allocated memory.
fn readBootFile(name: []const u8) ?[]u8 {
    const vol = if (boot_volume) |*v| v else return null;

    const entry = fat.lookup(vol, name) catch |err| {
        console.warn("fat: {s}: {s}", .{ name, @errorName(err) });
        return null;
    };

    const buf = heap.allocator.alloc(u8, entry.size) catch {
        console.warn("fat: no memory for {s} ({d} bytes)", .{ name, entry.size });
        return null;
    };

    const n = fat.readFile(vol, entry, buf) catch |err| {
        console.warn("fat: reading {s}: {s}", .{ name, @errorName(err) });
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
    const image = readBootFile("HELLO") orelse blk: {
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
