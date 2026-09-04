//! How fast to talk to a station that is listening.
//!
//! A radio that always speaks slowly is heard and wastes the air; one that
//! always speaks quickly is not heard at all past a certain distance. What
//! settles it is measurement: send, watch what got through, and keep an
//! account of how each rate has fared.
//!
//! The account is per rate and smoothed, so one lost frame does not
//! condemn a rate and one lucky frame does not promote it. Rates are
//! ranked by what they are actually worth, which is the chance a frame
//! gets through divided by how long it occupies the air. That division
//! matters: the fixed cost of putting any frame on the air weighs more
//! heavily the faster the rate is, so a fast rate that fails a third of
//! the time can be worth less than a slower one that never does.
//!
//! Nothing here talks to hardware. The caller hands over what a cell
//! offers and what became of each frame, and gets back the series of
//! rates to try, fastest first, ending with the one most likely to be
//! heard at all.

const std = @import("std");
const testing = std.testing;

const bounded = @import("bounded.zig");
const wifi = @import("wifi.zig");

/// How many rates the hardware will work down in one go.
pub const SERIES = 4;

/// The frame length rates are compared over. Comparing them needs one at
/// all, because what a rate is worth is how long it takes to put a frame
/// on the air, and that depends on how long the frame is.
pub const REFERENCE_BYTES = 1200;

/// One step of the series: how fast, and how many goes at it.
pub const Step = struct {
    rate: wifi.Legacy,
    tries: u4,
};

pub const Series = bounded.Bounded(Step, SERIES);

/// A series of one: a rate to try, and nothing to fall back to. What a
/// frame sent before anything has been agreed goes out as.
pub fn only(rate: wifi.Legacy, tries: u4) Series {
    var series = Series{};
    series.append(.{ .rate = rate, .tries = tries }) catch unreachable;
    return series;
}

/// What became of a frame that went out.
pub const Outcome = struct {
    rate: wifi.Legacy,
    sent: bool,
};

/// The chance of getting through, counted in hundredths of a percent so
/// the smoothing has somewhere to move.
const FULL: u32 = 10_000;

/// How much a single frame moves the account it belongs to: about an
/// eighth, which follows a link that changes without lurching at every
/// frame that happens to be lost.
const WEIGHT: u32 = 12;
const SCALE: u32 = 100;

/// What a rate is assumed to be worth before anything has been sent at
/// it. Halfway, so an unmeasured fast rate outranks a measured slow one
/// and gets its chance, and one frame's evidence starts correcting it.
const UNMEASURED: u16 = FULL / 2;

/// How many frames go by between one sent to find out about a rate
/// rather than to be quick. Rare enough not to cost throughput, often
/// enough to notice a room that has changed.
const SAMPLE_EVERY: u32 = 16;

/// How many goes each step of the series gets. The last is the one that
/// has to work, so it gets the most.
const FAST_TRIES: u4 = 2;
const FALLBACK_TRIES: u4 = 2;
const RELIABLE_TRIES: u4 = 3;
/// A sample is sent to learn, not to arrive, so it gets one go and the
/// steps behind it carry the frame if it fails.
const SAMPLE_TRIES: u4 = 1;

const Record = struct {
    /// The chance a frame gets through at this rate.
    chance: u16 = UNMEASURED,
    /// Whether anything has ever been sent at it, and how it went.
    tried: u32 = 0,
    won: u32 = 0,
};

pub const Choice = struct {
    /// What the cell offers. A rate outside this is one the far end
    /// cannot hear, whatever this station could manage.
    offered: wifi.Rates = .{},
    /// Whether the cell allows the shorter preamble, which changes what
    /// the slower rates cost and so what they are worth.
    short_preamble: bool = false,

    records: [wifi.known.len]Record = @splat(.{}),
    /// Frames since the last one sent to find something out, and which
    /// rate the next such frame tries.
    since_sample: u32 = 0,
    next_sample: usize = 0,

    /// Take what a cell offers. The account is kept, because a cell that
    /// offered these rates a moment ago is the same cell.
    pub fn offer(self: *Choice, rates: wifi.Rates, short_preamble: bool) void {
        self.offered = rates;
        self.short_preamble = short_preamble;
    }

    /// Forget everything measured. For a different cell, whose distance
    /// and interference have nothing to do with the last one's.
    pub fn forget(self: *Choice) void {
        self.records = @splat(.{});
        self.since_sample = 0;
        self.next_sample = 0;
    }

    /// Take what became of a frame.
    pub fn report(self: *Choice, outcome: Outcome) void {
        const index = indexOf(outcome.rate) orelse return;
        const record = &self.records[index];

        record.tried +|= 1;
        if (outcome.sent) record.won +|= 1;

        const fresh: u32 = if (outcome.sent) FULL else 0;
        record.chance = @intCast((@as(u32, record.chance) * (SCALE - WEIGHT) + fresh * WEIGHT) / SCALE);
    }

    /// What a rate is worth on this link: the chance of arriving, over
    /// the air it takes to try. Zero for a rate the cell does not offer,
    /// so nothing that walks the rates has to check separately.
    pub fn worth(self: *const Choice, rate: wifi.Legacy) u32 {
        if (!self.offered.has(rate)) return 0;
        const air = rate.airtime(REFERENCE_BYTES, self.short_preamble, true);
        if (air == 0) return 0;
        const index = indexOf(rate) orelse return 0;
        return (@as(u32, self.records[index].chance) * 1000) / air;
    }

    /// The best rate the cell offers, ignoring `except`.
    fn bestOther(self: *const Choice, except: ?wifi.Legacy) ?wifi.Legacy {
        var found: ?wifi.Legacy = null;
        var most: u32 = 0;
        for (self.offered.slice()) |rate| {
            if (except) |skip| {
                if (rate == skip) continue;
            }
            const value = self.worth(rate);
            if (found == null or value > most) {
                found = rate;
                most = value;
            }
        }
        return found;
    }

    /// The rate to send at next, and what to fall back through. Fastest
    /// first, ending with the one most likely to be heard at all, so a
    /// frame that fails at the top of the series still has somewhere to
    /// go before it is given up on.
    ///
    /// Every so often the first step is a rate being measured rather than
    /// the best one known: without that, a link that improves is never
    /// found out about, because nothing is ever sent fast enough to
    /// discover it.
    pub fn series(self: *Choice) Series {
        var steps = Series{};
        const reliable = self.offered.slowest() orelse return steps;
        const best = self.bestOther(null) orelse reliable;

        self.since_sample +|= 1;
        if (self.sampled()) |trial| {
            steps.append(.{ .rate = trial, .tries = SAMPLE_TRIES }) catch {};
            steps.append(.{ .rate = best, .tries = FAST_TRIES }) catch {};
        } else {
            steps.append(.{ .rate = best, .tries = FAST_TRIES }) catch {};
            if (self.bestOther(best)) |second| {
                steps.append(.{ .rate = second, .tries = FALLBACK_TRIES }) catch {};
            }
        }

        // The last word, unless it is already the only one said.
        if (steps.slice().len == 0 or steps.at(steps.slice().len - 1).?.rate != reliable) {
            steps.append(.{ .rate = reliable, .tries = RELIABLE_TRIES }) catch {};
        }
        return steps;
    }

    /// The rate this frame should measure, or none because this frame is
    /// being sent to arrive.
    fn sampled(self: *Choice) ?wifi.Legacy {
        if (self.since_sample < SAMPLE_EVERY) return null;
        const offered = self.offered.slice();
        if (offered.len < 2) return null;

        self.since_sample = 0;
        self.next_sample = (self.next_sample + 1) % offered.len;
        return offered[self.next_sample];
    }
};

/// Where a rate sits in the list of every rate this station knows.
fn indexOf(rate: wifi.Legacy) ?usize {
    return std.mem.indexOfScalar(wifi.Legacy, &wifi.known, rate);
}

// ---------------------------------------------------------------------------

/// A cell offering the four slow rates and the four common fast ones.
fn someCell() wifi.Rates {
    var rates = wifi.Rates{};
    for ([_]wifi.Legacy{ .m1, .m2, .m5_5, .m11, .m6, .m12, .m24, .m54 }) |rate| rates.add(rate);
    return rates;
}

test "a choice with nothing offered has nothing to say" {
    var choice = Choice{};
    try testing.expectEqual(@as(usize, 0), choice.series().slice().len);
}

test "the series ends with the rate most likely to be heard, and does not repeat it" {
    var choice = Choice{};
    choice.offer(someCell(), false);

    const steps = choice.series().slice();
    try testing.expect(steps.len >= 2);
    try testing.expectEqual(wifi.Legacy.m1, steps[steps.len - 1].rate);

    // Every step is a rate the cell offered, and none is said twice.
    for (steps, 0..) |step, i| {
        try testing.expect(choice.offered.has(step.rate));
        try testing.expect(step.tries > 0);
        for (steps[i + 1 ..]) |later| try testing.expect(later.rate != step.rate);
    }
}

test "one rate offered is the whole series, said once" {
    var choice = Choice{};
    var single = wifi.Rates{};
    single.add(.m11);
    choice.offer(single, false);

    const steps = choice.series().slice();
    try testing.expectEqual(@as(usize, 1), steps.len);
    try testing.expectEqual(wifi.Legacy.m11, steps[0].rate);
}

test "a rate that keeps failing loses its place to one that does not" {
    var choice = Choice{};
    choice.offer(someCell(), false);

    const started = choice.series().slice()[0].rate;

    // Everything fast fails; the slowest always arrives.
    for (0..200) |_| {
        for ([_]wifi.Legacy{ .m54, .m24, .m12, .m6, .m11, .m5_5 }) |rate| {
            choice.report(.{ .rate = rate, .sent = false });
        }
        choice.report(.{ .rate = .m1, .sent = true });
        choice.report(.{ .rate = .m2, .sent = true });
    }

    try testing.expect(choice.worth(.m54) < choice.worth(.m2));
    const settled = choice.bestOther(null).?;
    try testing.expect(settled == .m1 or settled == .m2);
    try testing.expect(settled != started or started == .m1 or started == .m2);
}

test "a link that carries the fastest rate is talked to at it" {
    var choice = Choice{};
    choice.offer(someCell(), false);

    for (0..200) |_| {
        for (choice.offered.slice()) |rate| choice.report(.{ .rate = rate, .sent = true });
    }

    // All of them arrive, so the one worth most is the quickest.
    try testing.expectEqual(wifi.Legacy.m54, choice.bestOther(null).?);
    try testing.expectEqual(wifi.Legacy.m54, choice.series().slice()[0].rate);
}

test "a fast rate that sometimes fails is still worth more than a slow one that never does" {
    var choice = Choice{};
    var pair = wifi.Rates{};
    pair.add(.m6);
    pair.add(.m54);
    choice.offer(pair, false);

    // Three frames in five arrive at the fastest rate; every frame
    // arrives at the slowest. The fast one still puts more through,
    // because even its failures cost a fraction of the air the slow one
    // spends on a success.
    for (0..400) |i| {
        choice.report(.{ .rate = .m54, .sent = i % 5 < 3 });
        choice.report(.{ .rate = .m6, .sent = true });
    }
    try testing.expectEqual(wifi.Legacy.m54, choice.bestOther(null).?);

    // Once it hardly ever arrives, the air it wastes outweighs its speed
    // and the slow rate wins. That crossover is the whole judgement: a
    // ranking by speed alone never finds it, and one by success alone
    // never leaves the slowest rate.
    for (0..400) |i| {
        choice.report(.{ .rate = .m54, .sent = i % 20 == 0 });
        choice.report(.{ .rate = .m6, .sent = true });
    }
    try testing.expectEqual(wifi.Legacy.m6, choice.bestOther(null).?);
}

test "now and then a frame is sent to find something out rather than to be quick" {
    var choice = Choice{};
    choice.offer(someCell(), false);
    for (0..200) |_| {
        for (choice.offered.slice()) |rate| choice.report(.{ .rate = rate, .sent = true });
    }
    const best = choice.bestOther(null).?;

    var samples: usize = 0;
    for (0..SAMPLE_EVERY * 4) |_| {
        const steps = choice.series().slice();
        if (steps[0].rate != best) {
            samples += 1;
            // A sample is sent to learn, so the frame still has the best
            // rate behind it to arrive by.
            try testing.expect(steps.len >= 2);
            try testing.expectEqual(best, steps[1].rate);
            try testing.expectEqual(SAMPLE_TRIES, steps[0].tries);
        }
    }
    try testing.expect(samples >= 3);
    try testing.expect(samples <= 5);
}

test "an outcome for a rate the cell never offered changes nothing" {
    var choice = Choice{};
    choice.offer(someCell(), false);
    const before = choice.records;

    // A rate this station does not know at all.
    choice.report(.{ .rate = @enumFromInt(99), .sent = false });
    try testing.expectEqualSlices(Record, &before, &choice.records);

    // One it knows but the cell did not offer is still worth nothing to
    // send at, however well it is reported to have gone.
    for (0..50) |_| choice.report(.{ .rate = .m48, .sent = true });
    try testing.expectEqual(@as(u32, 0), choice.worth(.m48));
    try testing.expect(choice.bestOther(null).? != .m48);
}

test "forgetting a cell leaves nothing of what was measured about it" {
    var choice = Choice{};
    choice.offer(someCell(), false);
    for (0..50) |_| choice.report(.{ .rate = .m54, .sent = false });
    try testing.expect(choice.records[indexOf(.m54).?].chance < UNMEASURED);

    choice.forget();
    try testing.expectEqual(UNMEASURED, choice.records[indexOf(.m54).?].chance);
    try testing.expectEqual(@as(u32, 0), choice.records[indexOf(.m54).?].tried);
}
