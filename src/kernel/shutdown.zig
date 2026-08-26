//! Orderly shutdown.
//!
//! The ordering is the substance of this file. FAT has no journal, so anything
//! still held in a cache or a device's own buffer is simply lost if power drops
//! first, and the crash-recovery strategy (design/00-vibeee.md §7) assumes a
//! completed write reached the medium. Getting the sequence right here is what
//! makes that assumption true.
//!
//! Each stage is attempted even if an earlier one failed. A wedged device must
//! not prevent the others from being flushed, and a machine that refuses to
//! power off because one unmount failed is worse than one that reports the
//! failure and powers off anyway.

const block = @import("block.zig");
const console = @import("console.zig");
const hal = @import("hal.zig");
const vfs = @import("vfs.zig");

pub const Action = enum { power_off, reboot, halt };

/// Machine-specific power control, registered by the composition root.
///
/// Optional: without it the machine halts instead, which is safe. Halting after
/// a clean flush loses nothing.
pub const PowerOps = struct {
    off: ?*const fn () void = null,
    reset: ?*const fn () void = null,
};

var power: PowerOps = .{};

pub fn setPowerOps(ops: PowerOps) void {
    power = ops;
}

/// Flush and detach every filesystem, then carry out `action`.
///
/// Does not return.
pub fn shutdown(action: Action) noreturn {
    console.putChar('\n');
    console.field("shutdown", "{s}", .{switch (action) {
        .power_off => "powering off",
        .reboot => "rebooting",
        .halt => "halting",
    }});

    unmountAll();
    flushDevices();

    // Interrupts off from here: nothing should be able to start new I/O after
    // the flush, or the work just done would be pointless.
    hal.disableInterrupts();

    switch (action) {
        .power_off => if (power.off) |f| {
            f();
            // Only reached if the firmware ignored the request.
            console.warn("shutdown: power off refused; halting instead", .{});
        },
        .reboot => if (power.reset) |f| {
            f();
            console.warn("shutdown: reset refused; halting instead", .{});
        },
        .halt => {},
    }

    console.field("shutdown", "safe to power off", .{});
    hal.halt();
}

fn unmountAll() void {
    var remaining: usize = 0;

    // Deepest mounts first: a volume mounted beneath another must be detached
    // before the one it sits under.
    var depth: usize = vfs.MAX_PATH;
    while (depth > 0) : (depth -= 1) {
        for (vfs.list()) |*m| {
            if (!m.in_use or m.path().len != depth) continue;

            vfs.umount(m.path()) catch |err| {
                console.warn("shutdown: {s} did not unmount: {s}", .{ m.path(), @errorName(err) });
                remaining += 1;
            };
        }
    }

    if (remaining == 0) {
        console.debug("shutdown", "all filesystems unmounted", .{});
    }
}

/// Flush every drive that was written to.
///
/// Unmounting already flushed the mounted ones; this catches devices with no
/// filesystem on them, and anything a failed unmount left behind.
///
/// Whole drives only, and only those that have been written. A partition
/// forwards its flush to the drive underneath, so flushing the partitions as
/// well asks the same drive the same question once per partition. A drive
/// nothing has written to has nothing to commit, and asking anyway means a
/// machine that only ever read from its disk reports failures at every
/// shutdown for a command it never needed.
fn flushDevices() void {
    for (block.list()) |*dev| {
        if (dev.offset != 0 or !dev.written) continue;
        dev.flush() catch |err| {
            console.warn("shutdown: {s} did not flush: {s}", .{ dev.name, @errorName(err) });
        };
    }
}
