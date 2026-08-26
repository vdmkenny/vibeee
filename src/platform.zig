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
const pci = @import("drv/bus/pci.zig");
const sched = @import("kernel/sched.zig");
const usermode = @import("arch/x86/usermode.zig");
const elf = @import("kernel/elf.zig");
const hal = @import("kernel/hal.zig");

/// Enumerate every bus this machine has and bind drivers to what turns up.
pub fn probeHardware() void {
    probe.begin();
    enumeratePci();
    probe.report();
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
    const image = @embedFile("user_hello");

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

    console.debug("user", "entry {x:0>8}, brk {x:0>8}, {d} byte image", .{
        loaded.entry, loaded.brk, image.len,
    });

    // From here the low half of the address space belongs to the process.
    space.activate();

    usermode.enter(
        loaded.entry,
        stack_top,
        @intFromPtr(t.stack.ptr) + t.stack.len,
    );
}
