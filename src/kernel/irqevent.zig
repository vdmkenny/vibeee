//! A device interrupt, handed to userspace as something it can wait on.
//!
//! The mechanism that lets a driver live outside the kernel. The kernel's own
//! handler does the only two things that must happen in interrupt context:
//! it asks the architecture to hold interrupt completion, and it signals an
//! event so whoever is waiting wakes. Everything after that, reading the
//! device, working out what happened, deciding what to do, runs in Ring 3 with
//! completion held.
//!
//! That is what makes a crashed driver survivable. A server that dies leaves
//! its interrupt quarantined rather than the machine livelocked in a handler
//! that never stops firing, and the supervisor restarts it and attaches again.
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
    token: hal.IrqToken,
    /// What the waiter blocks on. Counting, so an interrupt that arrives
    /// between servicing and waiting again is not lost.
    ready: event_mod.Event = .{},
    /// Armed by the first wait. A delivery that arrives earlier remains counted
    /// and held until that first wait consumes it.
    armed: bool = false,
    /// Interrupt completion is deferred until the driver says it has finished
    /// with the device.
    held: bool = false,
    /// How many interrupts have been delivered, which is the first thing
    /// anyone asks when a device has gone quiet.
    count: u64 = 0,
    refs: u32 = 1,
};

const MAX = hal.IRQ_LINE_COUNT;

/// How many owners one line may have. The machine's wiring shares lines
/// between devices that end up in different services, and each such
/// service holds its own event on the shared line.
const PER_LINE = 4;

/// One line's claim and everyone attached to it. A level line's deferred
/// completion belongs to the line, not to any one owner: it is owed until
/// every owner handed the delivery has acknowledged its own device.
const Line = struct {
    token: hal.IrqToken = undefined,
    claimed: bool = false,
    /// Acknowledgements outstanding for the delivery currently held.
    owed: u8 = 0,
    events: [PER_LINE]?*IrqEvent = @splat(null),

    fn empty(self: *const Line) bool {
        for (self.events) |slot| {
            if (slot != null) return false;
        }
        return true;
    }
};

var lines: [MAX]Line = @splat(.{});

/// Take a line for userspace, or join one already taken. A shared level
/// line's completion waits for every owner; a shared edge line owes
/// nothing and simply wakes them all.
pub fn attach(gsi: u32) Error!*IrqEvent {
    if (gsi >= MAX) return error.Unsupported;

    const self = heap.allocator.create(IrqEvent) catch return error.OutOfMemory;
    const flags = hal.saveAndDisableInterrupts();
    const line = &lines[gsi];

    if (!line.claimed) {
        if (hal.gsiClaimed(gsi)) {
            hal.restoreInterrupts(flags);
            heap.allocator.destroy(self);
            return error.Busy;
        }
        const token = hal.claimGsi(gsi, onInterrupt) orelse {
            hal.restoreInterrupts(flags);
            heap.allocator.destroy(self);
            return error.Unsupported;
        };
        line.token = token;
        line.claimed = true;
    }

    const slot = for (&line.events) |*candidate| {
        if (candidate.* == null) break candidate;
    } else {
        hal.restoreInterrupts(flags);
        heap.allocator.destroy(self);
        return error.Busy;
    };

    self.* = .{ .gsi = gsi, .token = line.token };
    slot.* = self;
    hal.restoreInterrupts(flags);
    return self;
}

/// Mark the owner ready to consume deliveries. The IOAPIC route itself was
/// established at boot and is never rewritten here.
pub fn arm(self: *IrqEvent) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    // A line's three firsts are narrated once each: armed, delivered,
    // completed. On a machine with no serial port, which of the three is
    // missing when a boot stops is the whole diagnosis, so each is said
    // after its step has actually happened.
    const first = !self.armed;
    self.armed = true;
    if (first) {
        hal.armIrq(self.token);
        console.debug("irq", "line {d} armed", .{self.gsi});
    }

    // A level line may have asserted before it had an owner. The unclaimed
    // handler quarantines its EOI; adopting that pending delivery here closes
    // the attach-to-first-wait race without touching the IOAPIC at runtime.
    if (!self.held and hal.irqAwaitingAck(self.token) and lineOf(self.gsi).owed == 0) {
        self.held = true;
        lineOf(self.gsi).owed = 1;
        self.count += 1;
        if (self.count == 1) console.debug("irq", "line {d} adopted a waiting delivery", .{self.gsi});
        self.ready.signalLocked();
    }
}

fn lineOf(gsi: u32) *Line {
    return &lines[gsi];
}

/// The driver has finished with the device, so the line may fire again.
///
/// Acknowledging a line that was not held is not an error: a driver that
/// polled its device and found nothing to do should say so rather than having
/// to remember whether an interrupt was outstanding.
pub fn acknowledge(self: *IrqEvent) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    if (!self.held) return;
    self.held = false;

    // The line's completion goes to the controller only when the last
    // owner of this delivery has spoken for its device.
    const line = lineOf(self.gsi);
    if (line.owed > 0) {
        line.owed -= 1;
        if (line.owed == 0) hal.acknowledgeIrq(self.token);
    }
}

pub fn retain(self: *IrqEvent) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    self.refs += 1;
}

/// Give the line back.
///
/// A pending EOI is completed before the handler is removed. If the device is
/// still asserting, the unclaimed-vector path quarantines the next delivery
/// rather than allowing an interrupt storm.
pub fn release(self: *IrqEvent) void {
    const flags = hal.saveAndDisableInterrupts();
    self.refs -= 1;
    if (self.refs > 0) {
        hal.restoreInterrupts(flags);
        return;
    }

    // A held delivery is acknowledged on the way out, through the same
    // shared accounting every other acknowledgement uses.
    if (self.held and self.gsi < MAX) {
        self.held = false;
        const line = lineOf(self.gsi);
        if (line.owed > 0) {
            line.owed -= 1;
            if (line.owed == 0) hal.acknowledgeIrq(self.token);
        }
    }
    if (self.gsi < MAX) {
        const line = &lines[self.gsi];
        for (&line.events) |*slot| {
            if (slot.* == self) slot.* = null;
        }
        // The claim outlives every owner but not the last one.
        if (line.empty() and line.claimed) {
            line.claimed = false;
            hal.releaseGsi(self.gsi);
        }
    }
    hal.restoreInterrupts(flags);
    heap.allocator.destroy(self);
}

/// One line's state, for anything reporting on what is attached.
pub const Snapshot = struct {
    gsi: u32,
    armed: bool,
    held: bool,
    count: u64,
};

/// Walk the attached lines, lowest first, one row per owner.
pub fn forEach(context: anytype, comptime visit: fn (@TypeOf(context), Snapshot) void) void {
    for (lines, 0..) |line, gsi| {
        for (line.events) |maybe| {
            const self = maybe orelse continue;
            visit(context, .{
                .gsi = @intCast(gsi),
                .armed = self.armed,
                .held = self.held,
                .count = self.count,
            });
        }
    }
}

/// What the kernel does in interrupt context, and no more: one deferral
/// for the line, one wake for every owner on it. Each owner reads its own
/// device and says "not mine" cheaply when the delivery was a neighbour's.
fn onInterrupt(frame: *hal.InterruptFrame) void {
    for (&lines) |*line| {
        if (!line.claimed or !hal.irqMatches(line.token, frame)) continue;

        hal.deferIrq(line.token);
        const level = line.token.trigger == .level;
        for (line.events) |maybe| {
            const self = maybe orelse continue;
            self.held = level;
            if (level) line.owed += 1;
            self.count += 1;
            if (self.count == 1) console.debug("irq", "line {d} delivered its first", .{self.gsi});

            // A line delivering this often is a source nobody manages to
            // quiet, and the machine it saturates cannot run the tool that
            // would say so: narrated from here, once per hundred thousand.
            if (self.count % 100_000 == 0) {
                console.fail("line {d} has fired {d} times", .{ self.gsi, self.count });
            }
            self.ready.signalLocked();
        }
        return;
    }
}
