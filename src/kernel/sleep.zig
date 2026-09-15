//! Suspending the machine to memory, and coming back.
//!
//! The machine stops with its memory refreshed and nothing else powered, and
//! on waking it is put back together from what memory held. Which makes this
//! the opposite of `shutdown.zig` in one way that decides everything else: a
//! shutdown may lose whatever it has not written out, and a suspend must lose
//! nothing at all, because the same programs go on running afterwards with
//! the same open files and the same half-drawn windows.
//!
//! What it does still write out is the filesystems. A suspended machine is
//! running on its battery, and a battery that runs out while it sleeps ends
//! the same way a power cut does, with whatever was only in a cache gone.
//!
//! The split with `platd` is the one the rest of the power states use: the
//! firmware's own methods are a program's business and the processor is the
//! kernel's, so the service asks and this does. What is here is the part only
//! the kernel can do.

const block = @import("block.zig");
const console = @import("console.zig");
const display = @import("display.zig");
const event = @import("event.zig");
const hal = @import("hal.zig");

/// What this machine can be asked about sleeping, registered by the
/// composition root.
pub const Ops = struct {
    /// Stop the machine, told the physical address the firmware must be
    /// given to come back to. Called with everything already saved and
    /// interrupts off, and returns only if the machine refused.
    enter: ?*const fn (wake_at: u32) callconv(.c) void = null,
    /// What the board copies out before the power goes, and puts back once
    /// the processor is running again. The buses are the reason it exists:
    /// every part on one comes back addressing nothing, and the addresses
    /// were firmware's to choose before this kernel ran.
    stow: ?*const fn () void = null,
    restore: ?*const fn () void = null,
};

var ops: Ops = .{};

pub fn setOps(o: Ops) void {
    ops = o;
}

/// Whether the machine can be suspended at all.
///
/// Three things have to be true. The architecture has to have a way back, the
/// firmware has to offer the state, and the screen has to be something a
/// driver can put back: a display left as firmware set it comes back from a
/// suspend dark, still being drawn into and no longer being read, which is
/// worse than never sleeping.
pub fn offered() bool {
    return hal.caps.sleeps_to_memory and ops.enter != null and display.canResume();
}

pub const Outcome = enum {
    /// It slept, and this is the other side.
    woke,
    /// It was asked and would not. Nothing was lost.
    refused,
    /// Nothing here can.
    unoffered,
};

/// The events that say the machine has been asleep, one for each service
/// that asked for one.
///
/// One each rather than one shared, because an event here is a count and a
/// signal on it releases whichever waiter reaches it first: four services
/// watching one event would leave three of them asleep with their devices
/// dead. So each gets its own and every one is signalled.
///
/// An event at all, rather than the sleep telling each service in turn,
/// because a service told directly would be told while the teller is inside
/// its own request and can answer nothing: the network's driver asks the
/// platform service where its adapter's interrupt goes as it takes the
/// adapter, and a platform service waiting for the network to finish is a
/// platform service that cannot answer that. Signalled and let go of, each
/// service comes back on its own loop and everything it needs is running.
///
/// Room for more than this machine has services that drive hardware, which
/// is four: the bus, the network, the sound and the desktop.
var watchers: [8]*event.Event = undefined;
var watcher_count: usize = 0;

pub fn watch() ?*event.Event {
    forgetTheGone();
    if (watcher_count == watchers.len) return null;

    const waiting = event.create() catch return null;
    // Two holds: the one making it gives, which is this module's and keeps
    // the table's entry a pointer worth following, and one for the caller,
    // which its handle takes over. Both from here, so a live watcher is
    // never momentarily indistinguishable from a dead one.
    event.retain(waiting);
    watchers[watcher_count] = waiting;
    watcher_count += 1;
    return waiting;
}

/// Let go of the watchers nobody else holds.
///
/// A service that exits closes its handle and what is left is this module's
/// own hold, which is how one is recognised. Without this, a service its
/// supervisor restarts would take a fresh slot every time until the table was
/// full of events nothing is waiting on.
fn forgetTheGone() void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    var i: usize = 0;
    while (i < watcher_count) {
        if (watchers[i].refs.count > 1) {
            i += 1;
            continue;
        }
        event.release(watchers[i]);
        watcher_count -= 1;
        watchers[i] = watchers[watcher_count];
    }
}

/// Put the machine to sleep, and return when it wakes.
///
/// The caller is left running: this is a call that takes a few seconds and
/// comes back, which is the whole difference from a shutdown.
pub fn toMemory() Outcome {
    if (!offered()) return .unoffered;
    const enter = ops.enter.?;

    // Written out before the machine stops, not after it comes back: a
    // suspend that never wakes must lose no more than a power cut does.
    block.flushAll() catch |err| {
        console.warn("suspend: flushing did not finish: {s}", .{@errorName(err)});
    };

    console.field("suspend", "sleeping", .{});

    // Off across the whole of it. An interrupt taken between the state being
    // stowed and the machine stopping would run a handler on a machine
    // half-way out the door, and one taken on the way back would run it
    // before the controllers are pointed anywhere.
    const was = hal.saveAndDisableInterrupts();
    if (ops.stow) |away| away();
    const slept = hal.sleepToMemory(enter);
    if (slept) {
        if (ops.restore) |back| back();
    }
    hal.restoreInterrupts(was);

    if (!slept) {
        console.warn("suspend: the machine would not sleep", .{});
        return .refused;
    }

    // After the board is back and interrupts are on again, so a service
    // woken by this finds a machine it can work on.
    for (watchers[0..watcher_count]) |waiting| waiting.signal();

    console.field("suspend", "awake", .{});
    return .woke;
}
