//! How much noise the baseband is asked to ignore.
//!
//! A receiver decides for itself when a signal has begun, and one too
//! willing to decide finds signals in noise: it starts demodulating, fails
//! on the timing, and says so, a thousand times a second. A real frame
//! arriving in the middle of that has nothing listening for it, so a radio
//! in a loud room hears nothing at all rather than hearing less.
//!
//! What answers that is not a better guess at the right thresholds but a
//! willingness to change them: the room is not knowable in advance and does
//! not stay the same. So the levels here are stepped up while the baseband
//! is giving up too often and back down when it is not, which is what the
//! vendor's own driver does with the same numbers.
//!
//! Three things are raised, because the failures have three shapes. The
//! noise level is how much signal must be there at all; the spur level is
//! how much power a single tone may carry before it is disbelieved; the
//! first step is how far the search for a signal's beginning moves each
//! time. All of them cost sensitivity, which is why they come back down.

const std = @import("std");
const regs_mod = @import("regs.zig");
const Regs = regs_mod.Regs;

/// The vendor's own ladders. Each is indexed by its level, and the last
/// entry of each is as deaf as this driver will make the radio.
const noise_levels = [_]struct { total: i8, coarse_high: i7, coarse_low: i8, firpwr: i8 }{
    .{ .total = -55, .coarse_high = -14, .coarse_low = -64, .firpwr = -78 },
    .{ .total = -55, .coarse_high = -14, .coarse_low = -64, .firpwr = -78 },
    .{ .total = -55, .coarse_high = -14, .coarse_low = -64, .firpwr = -78 },
    .{ .total = -55, .coarse_high = -14, .coarse_low = -64, .firpwr = -78 },
    .{ .total = -62, .coarse_high = -12, .coarse_low = -70, .firpwr = -80 },
};

const spur_levels = [_]u7{ 2, 4, 6, 8, 10, 12, 14, 16 };
const firstep_levels = [_]u6{ 0, 4, 8 };

/// How often the baseband may give up before it is asked to be harder to
/// convince, and how seldom before it is asked to be easier. Counted over
/// one period; between the two the level is left where it is, so a room
/// that is merely busy does not oscillate.
const OFDM_TOO_OFTEN = 500;
const OFDM_SELDOM = 200;
const CCK_TOO_OFTEN = 200;
const CCK_SELDOM = 100;

/// One ladder of settings, and where on it the radio stands.
///
/// The rung is an integer exactly wide enough for its own ladder, so a
/// rung off the end of one cannot be held, let alone used to index it:
/// the bound is the type rather than a check anybody has to remember.
fn Ladder(comptime rungs: anytype) type {
    return struct {
        const Self = @This();
        const Rung = std.math.IntFittingRange(0, rungs.len - 1);

        rung: Rung = 0,

        fn raise(self: *Self) void {
            if (self.rung < rungs.len - 1) self.rung += 1;
        }

        fn lower(self: *Self) void {
            if (self.rung > 0) self.rung -= 1;
        }

        fn at(self: Self) @TypeOf(rungs[0]) {
            return rungs[self.rung];
        }
    };
}

pub const State = struct {
    noise: Ladder(noise_levels) = .{},
    spur: Ladder(spur_levels) = .{},
    firstep: Ladder(firstep_levels) = .{},

    /// Put the radio back to hearing everything it can, and start again
    /// from there. For a radio coming up, which has learned nothing yet.
    pub fn begin(self: *State, regs: Regs) void {
        self.* = .{};
        self.apply(regs);
    }

    /// Put back what was learned. A reset returns these registers to what
    /// the tables say, and a channel change is not a new room: what the
    /// old one taught still holds.
    pub fn restore(self: State, regs: Regs) void {
        self.apply(regs);
    }

    /// What a period of listening came to, and what to do about it.
    ///
    /// Raised a rung at a time rather than jumped: the level that works is
    /// the lowest one that does, and every rung above it is sensitivity
    /// given away. Answers whether anything moved, which is worth saying
    /// once when it does.
    pub fn heard(self: *State, regs: Regs, ofdm: u32, cck: u32) bool {
        const before = self.*;

        if (ofdm > OFDM_TOO_OFTEN) {
            self.noise.raise();
            self.spur.raise();
        } else if (cck > CCK_TOO_OFTEN) {
            self.firstep.raise();
        } else if (ofdm < OFDM_SELDOM and cck < CCK_SELDOM) {
            self.noise.lower();
            self.spur.lower();
            self.firstep.lower();
        }

        if (std.meta.eql(self.*, before)) return false;
        self.apply(regs);
        return true;
    }

    /// Where the radio stands, for saying so.
    pub fn rungs(self: State) struct { noise: usize, spur: usize, firstep: usize } {
        return .{ .noise = self.noise.rung, .spur = self.spur.rung, .firstep = self.firstep.rung };
    }

    fn apply(self: State, regs: Regs) void {
        const wanted = self.noise.at();

        regs.set(.phy_desired_size, regs_mod.PhyDesiredSize, "total", wanted.total);

        var gain = regs.get(.phy_agc_control1, regs_mod.PhyAgcControl1);
        gain.coarse_high = wanted.coarse_high;
        gain.coarse_low = wanted.coarse_low;
        regs.put(.phy_agc_control1, gain);

        var signal = regs.get(.phy_find_signal, regs_mod.PhyFindSignal);
        signal.firpwr = wanted.firpwr;
        signal.firstep = self.firstep.at();
        regs.put(.phy_find_signal, signal);

        regs.set(.phy_timing5, regs_mod.PhyTiming5, "cycle_power_threshold1", self.spur.at());
    }
};
