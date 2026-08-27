//! A device interrupt, handed to userspace as something it can wait on.
//!
//! The mechanism that lets a driver live outside the kernel. The kernel's own
//! handler does the only two things that must happen in interrupt context:
//! it masks the line so the device cannot re-raise it, and it signals an event
//! so whoever is waiting wakes. Everything after that, reading the device,
//! working out what happened, deciding what to do, runs in Ring 3 with the
//! line held down.
//!
//! That is what makes a crashed driver survivable. A server that dies leaves
//! its line masked rather than the machine livelocked in a handler that never
//! stops firing, and the supervisor restarts it and it attaches again.
//! `design/00-vibeee.md` §6.

const console = @import("console.zig");
const event_mod = @import("event.zig");
const hal = @import("hal.zig");
const heap = @import("heap.zig");

pub const Error = error{ OutOfMemory, Busy, Unsupported };

/// One line, held by one process.
///
/// Sharing a level-triggered line between servers is what PCI needs and what
/// the design describes; nothing here has two drivers on one line yet, and
/// refusing the second attach is both simpler and more honest than a
/// half-built sharing protocol.
pub const IrqEvent = struct {
    gsi: u32,
    /// What the waiter blocks on. Counting, so an interrupt that arrives
    /// between servicing and waiting again is not lost.
    ready: event_mod.Event = .{},
    /// Armed by the first wait, not by attaching: a driver that has attached
    /// but is not ready to service the device yet should not be handed one.
    armed: bool = false,
    /// The handler masked the line and is waiting for the driver to say it has
    /// finished with the device.
    held: bool = false,
    /// How many interrupts have been delivered, which is the first thing
    /// anyone asks when a device has gone quiet.
    count: u64 = 0,
    refs: u32 = 1,
};

/// As many lines as an IOAPIC has inputs.
const MAX = 24;

var attached: [MAX]?*IrqEvent = @splat(null);

/// Take a line for userspace.
pub fn attach(gsi: u32) Error!*IrqEvent {
    if (gsi >= MAX) return error.Unsupported;
    if (attached[gsi] != null) return error.Busy;
    // Something in the kernel already answers for it. The two cannot both
    // handle a line: whichever ran second would find it already masked.
    if (hal.gsiClaimed(gsi)) return error.Busy;

    const self = heap.allocator.create(IrqEvent) catch return error.OutOfMemory;
    self.* = .{ .gsi = gsi };

    if (!hal.claimGsi(gsi, onInterrupt)) {
        heap.allocator.destroy(self);
        return error.Unsupported;
    }

    attached[gsi] = self;
    return self;
}

/// Let the line through. Called by the first wait, and by every acknowledgement
/// after the driver has finished with the device.
pub fn arm(self: *IrqEvent) void {
    const first = !self.armed;
    self.armed = true;
    self.held = false;
    hal.setGsiMask(self.gsi, false);
    // The first opening of a line is the moment a machine with a disputed
    // pin finds out, and the service that opened it cannot say so once the
    // console belongs to the shell.
    if (first) console.debug("irq", "line {d} unmasked", .{self.gsi});
}

/// The driver has finished with the device, so the line may fire again.
///
/// Acknowledging a line that was not held is not an error: a driver that
/// polled its device and found nothing to do should say so rather than having
/// to remember whether an interrupt was outstanding.
pub fn acknowledge(self: *IrqEvent) void {
    arm(self);
}

pub fn retain(self: *IrqEvent) void {
    self.refs += 1;
}

/// Give the line back.
///
/// It is left masked. A line whose driver has gone is a line nothing will
/// service, and the safe answer to that is silence rather than a handler that
/// fires forever.
pub fn release(self: *IrqEvent) void {
    self.refs -= 1;
    if (self.refs > 0) return;

    hal.releaseGsi(self.gsi);
    if (self.gsi < MAX) attached[self.gsi] = null;
    heap.allocator.destroy(self);
}

/// One line's state, for anything reporting on what is attached.
pub const Snapshot = struct {
    gsi: u32,
    armed: bool,
    held: bool,
    count: u64,
};

/// Walk the attached lines, lowest first.
pub fn forEach(context: anytype, comptime visit: fn (@TypeOf(context), Snapshot) void) void {
    for (attached, 0..) |maybe, gsi| {
        const self = maybe orelse continue;
        visit(context, .{
            .gsi = @intCast(gsi),
            .armed = self.armed,
            .held = self.held,
            .count = self.count,
        });
    }
}

/// What the kernel does in interrupt context, and no more.
fn onInterrupt(_: *hal.InterruptFrame) void {
    // The vector is not carried through, so the line is found by what it is
    // attached to. With at most twenty-four of them and one attached at a
    // time, a scan is cheaper than a second table to keep in step.
    for (attached) |maybe| {
        const self = maybe orelse continue;
        if (!self.armed or self.held) continue;

        // Masked before the event is signalled, so a level-triggered device
        // still asserting cannot re-enter the moment interrupts are on again.
        hal.setGsiMask(self.gsi, true);
        self.held = true;
        self.count += 1;
        if (self.count == 1) console.debug("irq", "line {d} delivered its first", .{self.gsi});

        // A line delivering this often is a source nobody manages to quiet,
        // and the machine it saturates cannot run the tool that would say
        // so: the count is narrated from here, once per hundred thousand.
        if (self.count % 100_000 == 0) {
            console.fail("line {d} has fired {d} times", .{ self.gsi, self.count });
        }
        self.ready.signalLocked();
        return;
    }
}
