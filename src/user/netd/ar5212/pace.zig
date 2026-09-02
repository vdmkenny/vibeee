//! How the driver waits: a bounded spin for the short waits the reference
//! peppers a reset with, a sleep for the long ones, and a poll of one
//! register field with a ceiling.
//!
//! Nothing here is unbounded. A radio that has gone away costs a bounded
//! spin and a refusal, never the machine.

const regs_mod = @import("regs.zig");
const sys = @import("sys");

const Regs = regs_mod.Regs;

/// Below this a sleep is a scheduler round trip either way, so the wait
/// spins on the clock instead.
const SPIN_BELOW_MICROS = 1000;

pub fn delay(micros: u32) void {
    if (micros < SPIN_BELOW_MICROS) {
        const deadline = sys.clockMicros() + micros;
        while (sys.clockMicros() < deadline) {}
    } else {
        sys.sleepMicros(micros);
    }
}

/// The reference's default patience: five thousand looks, ten
/// microseconds apart.
pub const DEFAULT_TRIES = 5000;
const LOOK_MICROS = 10;

/// Poll `field` of `register` until it reads `wanted`, or the tries run
/// out. True when it did.
pub fn until(regs: Regs, register: regs_mod.R, comptime Word: type, comptime field: []const u8, wanted: anytype, tries: u32) bool {
    var looked: u32 = 0;
    while (looked < tries) : (looked += 1) {
        const word = regs.get(register, Word);
        if (@field(word, field) == wanted) return true;
        delay(LOOK_MICROS);
    }
    return false;
}
