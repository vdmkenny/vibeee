//! How the driver waits: a bounded look at the hardware for the short waits
//! the reference peppers a reset with, a sleep for the long ones.
//!
//! Nothing here is unbounded. A radio that has gone away costs a bounded
//! wait and a refusal, never the machine.
//!
//! A wait is paced by the bus, not by the clock. Reading one of this card's
//! registers is about a microsecond on its own, while reading the clock is a
//! syscall that masks interrupts, reads an ACPI port and divides twice in
//! software. A wait that asked the time between every look spent most of its
//! patience finding out what time it was, and held interrupts off while it
//! did.

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

/// Looks between two readings of the clock. Enough that the clock is a small
/// share of what a wait costs, few enough that the patience stays a real
/// duration rather than a count of bus round trips.
const LOOKS_PER_CHECK = 32;

/// A ceiling on the looks themselves, so that a clock which has stopped
/// cannot turn a bounded wait into an endless one. At a microsecond a look
/// this is about a second, which is far past any patience asked for here.
const MAX_LOOKS = 1 << 20;

/// The reference's default patience: fifty milliseconds.
pub const DEFAULT_MICROS: u32 = 50_000;

/// Waits that ran out. Each one is its whole patience spent looking at a
/// register that never changed, which at the default is fifty milliseconds of
/// this machine doing nothing else, so a count that climbs says where the
/// time went.
pub var exhausted: u32 = 0;

/// Look until `ready` says so, or the patience runs out. True when it did.
///
/// The first look costs one register read and nothing else: a part that is
/// already done is the common case and must not pay for a clock reading.
pub fn looking(
    context: anytype,
    comptime ready: fn (@TypeOf(context)) bool,
    patience_micros: u32,
) bool {
    if (ready(context)) return true;

    const deadline = sys.clockMicros() + patience_micros;
    var looked: usize = 0;
    while (looked < MAX_LOOKS) : (looked += LOOKS_PER_CHECK) {
        for (0..LOOKS_PER_CHECK) |_| {
            if (ready(context)) return true;
        }
        if (sys.clockMicros() >= deadline) break;
    }
    exhausted +%= 1;
    return false;
}

/// Look at `field` of `register` until it reads `wanted`, or the patience
/// runs out. True when it did.
pub fn until(
    regs: Regs,
    register: regs_mod.R,
    comptime Word: type,
    comptime field: []const u8,
    wanted: anytype,
    patience_micros: u32,
) bool {
    const Look = struct {
        regs: Regs,
        register: regs_mod.R,
        wanted: @TypeOf(wanted),

        fn ready(self: @This()) bool {
            return @field(self.regs.get(self.register, Word), field) == self.wanted;
        }
    };
    return looking(
        Look{ .regs = regs, .register = register, .wanted = wanted },
        Look.ready,
        patience_micros,
    );
}
