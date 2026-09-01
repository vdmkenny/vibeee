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
const irq = @import("irq.zig");

pub const Error = error{ OutOfMemory, Busy, Unsupported };

/// One owner's stake in a line.
///
/// A line is shared by up to `PER_LINE` owners, because that is how the
/// machine is wired: PIRQ pins carry several devices, and the devices end up
/// in different services. Every owner is woken per delivery and reads its own
/// device, saying "not mine" cheaply when the cause was a neighbour's.
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

/// How long a level line's completion may stay owed before the kernel
/// concludes its owner is not coming back and completes it itself.
///
/// A service pass is microseconds and a scheduling delay is milliseconds, so
/// a full second of silence is a driver that is alive and stuck, which
/// `release` cannot see: it only fires for one that died. Without this, a
/// stuck owner silences its whole LAPIC priority class forever, every other
/// device in it included, on a machine whose timer and keyboard survive by
/// design and so look fine.
const HELD_BUDGET_US: u64 = 1_000_000;

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
    /// When the current deferral began, for the watchdog that completes a
    /// delivery whose owner has stopped answering.
    held_since_us: u64 = 0,
    /// Completions the watchdog performed for silent owners. Zero on a
    /// healthy machine; anything else names a driver worth looking at.
    forced: u32 = 0,
    /// Wakes passed between owners after a productive service pass, which is
    /// what keeps a shared edge line alive: see `acknowledge`.
    cascades: u32 = 0,
    events: [PER_LINE]?*IrqEvent = @splat(null),

    fn empty(self: *const Line) bool {
        for (self.events) |slot| {
            if (slot != null) return false;
        }
        return true;
    }

    fn owners(self: *const Line) u8 {
        var n: u8 = 0;
        for (self.events) |slot| {
            if (slot != null) n += 1;
        }
        return n;
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

/// The driver has finished a service pass; `found` says whether the pass
/// serviced anything.
///
/// Acknowledging a line that was not held is not an error: a driver that
/// polled its device and found nothing to do should say so rather than having
/// to remember whether an interrupt was outstanding.
///
/// On a shared edge line, a productive pass wakes the other owners. The wire
/// is common: while one device held it low, a neighbour's assertion makes no
/// new edge, so the neighbour's cause would otherwise wait for an edge that
/// can never come. Waking peers after every pass that did work closes that
/// window, and only after work, so a round of quiet passes ends the exchange
/// rather than ping-ponging forever: each cascade implies the hardware moved,
/// and the hardware is finite.
pub fn acknowledge(self: *IrqEvent, found: bool) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    const line = lineOf(self.gsi);

    if (found and self.token.trigger == .edge and line.owners() > 1) {
        line.cascades += 1;
        for (line.events) |maybe| {
            const peer = maybe orelse continue;
            if (peer == self) continue;
            peer.ready.signalLocked();
        }
    }

    if (!self.held) return;
    self.held = false;

    // The line's completion goes to the controller only when the last
    // owner of this delivery has spoken for its device.
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

/// Complete deliveries whose owners have stopped answering.
///
/// Run from the timer tick, which outranks every deferrable vector by
/// design and therefore still fires while one is stuck. Only the marking
/// happens here: the actual completion is retired on the way out of the
/// tick, once the timer's own end-of-interrupt has been sent, because the
/// controller completes strictly from the top of its in-service stack.
///
/// A forced completion is not a repair. If the device is still asserting,
/// the line delivers again and, with its owner still silent, is forced
/// again a budget later: the machine degrades to a slow, narrated limp
/// instead of a silent quarter of its devices, and `sysinfo irq` names the
/// line to look at.
pub fn scrub(now_us: u64) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    for (&lines, 0..) |*line, gsi| {
        if (!line.claimed or line.owed == 0) continue;
        if (now_us -| line.held_since_us < HELD_BUDGET_US) continue;

        line.forced +%= 1;
        line.owed = 0;
        for (line.events) |maybe| {
            const self = maybe orelse continue;
            self.held = false;
        }
        hal.acknowledgeIrq(line.token);
        console.fail("line {d} held past its budget; completed for its silent owner", .{gsi});
    }
}

/// One line's state, for anything reporting on what is attached.
pub const Snapshot = struct {
    gsi: u32,
    armed: bool,
    held: bool,
    count: u64,
    /// How the line fires, which decides its whole discipline.
    trigger: irq.Trigger,
    /// How many owners share the line.
    owners: u8,
    /// Watchdog completions for silent owners; zero on a healthy machine.
    forced: u32,
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
                .trigger = self.token.trigger,
                .owners = line.owners(),
                .forced = line.forced,
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
        if (level and line.owed == 0) line.held_since_us = hal.monotonicMicros();
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
