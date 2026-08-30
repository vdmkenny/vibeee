//! The boot watchdog.
//!
//! The target machine has no serial port, and a boot that stops without
//! saying why looks the same as one that is merely taking its time. The
//! watchdog is armed before anything that can stall, and stood down by
//! `init` through `boot_ok` once the system is usable. A boot that has not
//! reported by the deadline ends in the panic screen, whose QR code carries
//! what was running, instead of a panel that simply never changes again.
//!
//! The check rides the timer tick, so it only sees a system whose CPU is
//! still taking interrupts. A hang that has disappeared into the firmware's
//! own code is beyond any software's reach: those are defended against by
//! writing what was being reached for before it was reached.

const clock = @import("clock.zig");
const panic_mod = @import("panic.zig");

/// When the boot must have reported by, or null once it has.
var deadline_us: ?u64 = null;

/// Arm the watchdog for `seconds`. Called once, from the boot path, before
/// anything that can stall gets a chance to.
pub fn arm(seconds: u32) void {
    deadline_us = clock.monotonicMicros() + @as(u64, seconds) * 1_000_000;
}

/// The boot has reported ready; the watchdog stands down for good.
pub fn disarm() void {
    deadline_us = null;
}

/// Called from the timer tick.
pub fn onTick() void {
    const d = deadline_us orelse return;
    if (clock.monotonicMicros() < d) return;

    // Say what it was before ending: from here the screen belongs to the
    // panic renderer and this is the last ordinary line the boot log gets.
    deadline_us = null;
    panic_mod.kpanic("boot watchdog: nothing reported ready in time", null);
}
