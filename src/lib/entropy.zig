//! Unpredictable bytes, gathered from what the machine cannot predict.
//!
//! This computer has no hardware random source. What it has is timing.
//! Interrupts land at moments that vary with caches, memory refresh, bus
//! traffic and the devices themselves, and the gaps between them are hard to
//! guess from outside. A radio adds more where there is one: the exact moment
//! a frame lands, how strong it was, and the frames it could not decode,
//! which are the band's noise.
//!
//! The pool is a hash over everything stirred in. Drawing does not hand back
//! what is in it: the answer is a hash of the pool and a count that never
//! repeats, and the pool moves on afterwards, so bytes drawn say nothing
//! about the bytes drawn next or the ones stirred in before.

const std = @import("std");
const testing = std.testing;

pub const Pool = struct {
    pub const Hash = std.crypto.hash.sha2.Sha256;

    /// How many bytes a draw can serve from one turn of the hash.
    pub const BLOCK = Hash.digest_length;

    /// How many bits of surprise a pool wants before what it gives is worth
    /// calling unguessable. A seed for a cipher holds this many, and wanting
    /// more than the thing being seeded can hold would be theatre.
    pub const ENOUGH = BLOCK * 8;

    /// What one stirring is worth when the caller offers no estimate. Bytes
    /// carry far less surprise than they do size, so this is small and it
    /// takes many.
    pub const A_LITTLE = 4;

    state: [BLOCK]u8 = @splat(0),
    /// Bits of surprise believed to be in the pool. An estimate, and the only
    /// honest kind: nothing here can measure what it was told.
    heard: u32 = 0,
    drawn: u64 = 0,

    /// Mix something in, worth whatever a source with no estimate is worth.
    /// Anything may be stirred in: nothing that goes in can make the pool
    /// worse, and whatever was unpredictable about it stays so.
    pub fn stir(self: *Pool, bytes: []const u8) void {
        self.credit(bytes, A_LITTLE);
    }

    /// Mix something in that the source can say more about. A source knowing
    /// how many of its own bits are hard to guess says so here, which is what
    /// lets one that hears a lot at once count for a lot at once.
    pub fn credit(self: *Pool, bytes: []const u8, bits: u32) void {
        var hash = Hash.init(.{});
        hash.update(&self.state);
        hash.update(bytes);
        hash.final(&self.state);
        self.heard +|= bits;
    }

    /// Whether enough has been heard for a draw to mean anything.
    pub fn ready(self: Pool) bool {
        return self.heard >= ENOUGH;
    }

    /// Fill `into` with drawn bytes, or say the pool is not ready and
    /// leave it untouched. A caller that needs a secret needs the answer
    /// to this, not bytes that merely look like an answer.
    pub fn draw(self: *Pool, into: []u8) bool {
        if (!self.ready()) return false;

        var at: usize = 0;
        while (at < into.len) {
            var counted: [8]u8 = undefined;
            std.mem.writeInt(u64, &counted, self.drawn, .little);
            self.drawn +%= 1;

            var hash = Hash.init(.{});
            hash.update(&self.state);
            hash.update(&counted);
            var block: [BLOCK]u8 = undefined;
            hash.final(&block);

            const take = @min(BLOCK, into.len - at);
            @memcpy(into[at..][0..take], block[0..take]);
            at += take;
        }

        // Move the pool on, so what was drawn cannot be worked back to what
        // is left. Worth nothing: this is the pool's own state, and a pool
        // that credited itself for reading itself would climb on its own.
        self.credit(&self.state, 0);
        return true;
    }
};

/// Interrupt timing, collected where hashing would cost too much.
///
/// The interrupt path can afford a subtract and a store, not a hash. Samples
/// go into a ring as they arrive and are stirred into a pool in one batch by
/// whoever next needs randomness.
///
/// What is kept is the gap since the previous sample rather than the counter
/// itself, and only its low bits. The high bits say what time it is, which is
/// no secret; the low bits are where the variation is.
pub const Jitter = struct {
    /// How many samples the ring holds. Also how many must arrive before a
    /// drain counts as a full batch.
    pub const SAMPLES = 32;

    /// The width kept from each gap.
    pub const Sample = u16;

    ring: [SAMPLES]Sample = @splat(0),
    at: usize = 0,
    /// Samples since the last drain. More than SAMPLES means the oldest were
    /// overwritten, which costs nothing: the ring still holds SAMPLES fresh
    /// ones.
    since: usize = 0,
    last: u64 = 0,

    /// Record one moment.
    pub fn sample(self: *Jitter, ticks: u64) void {
        const gap = ticks -% self.last;
        self.last = ticks;
        self.ring[self.at] = @truncate(gap);
        self.at = (self.at + 1) % SAMPLES;
        self.since +|= 1;
    }

    /// Whether a whole ring of samples has arrived since the last drain.
    pub fn full(self: Jitter) bool {
        return self.since >= SAMPLES;
    }

    /// Whether the samples differ from each other at all.
    ///
    /// A timer firing on an exact division of a counter gives the same gap
    /// every time, which is a batch that looks like evidence and is not. Real
    /// hardware varies because interrupt latency depends on what the machine
    /// was doing; an emulated one need not.
    pub fn varied(self: Jitter) bool {
        return !std.mem.allEqual(Sample, &self.ring, self.ring[0]);
    }

    /// Stir a batch into a pool and start counting again, and say whether one
    /// went in.
    ///
    /// Two things stop a batch. A partial ring holds samples the previous
    /// drain already stirred, so a caller asking repeatedly cannot talk the
    /// pool into believing it has heard more than the interrupts delivered.
    /// A ring whose samples are all identical carries nothing at all, and
    /// counting it would let a machine whose interrupts arrive like clockwork
    /// claim a randomness it does not have.
    pub fn drain(self: *Jitter, pool: *Pool) bool {
        if (!self.full()) return false;
        if (!self.varied()) {
            // Start again rather than testing the same samples at every
            // interrupt from here.
            self.since = 0;
            return false;
        }
        // A bit an interrupt: what is hard to guess about when one landed is
        // a fraction of the gap's low bits, and claiming a whole bit for each
        // is already generous.
        pool.credit(std.mem.sliceAsBytes(self.ring[0..]), SAMPLES);
        self.since = 0;
        return true;
    }
};

/// Bytes for a caller with nowhere better to turn: the clock, and
/// whatever it can add that differs between machines. Anyone who knows
/// roughly when this was drawn can narrow down what came out, so this is
/// a fallback and not a source. It is here because a radio that has heard
/// nothing yet should not stop a join outright.
pub fn fromClock(micros: u64, salt: []const u8, into: []u8) void {
    var counter: u64 = 0;
    var at: usize = 0;
    while (at < into.len) {
        var stamp: [16]u8 = undefined;
        std.mem.writeInt(u64, stamp[0..8], micros, .little);
        std.mem.writeInt(u64, stamp[8..16], counter, .little);
        counter +%= 1;

        var hash = Pool.Hash.init(.{});
        hash.update(&stamp);
        hash.update(salt);
        var block: [Pool.BLOCK]u8 = undefined;
        hash.final(&block);

        const take = @min(block.len, into.len - at);
        @memcpy(into[at..][0..take], block[0..take]);
        at += take;
    }
}

test "the fallback differs by moment and by machine, and fills what it is given" {
    var early: [40]u8 = @splat(0);
    var late: [40]u8 = @splat(0);
    var elsewhere: [40]u8 = @splat(0);

    fromClock(1_000_000, "\x02\x00\x00\x00\x00\x01", &early);
    fromClock(1_000_001, "\x02\x00\x00\x00\x00\x01", &late);
    fromClock(1_000_000, "\x02\x00\x00\x00\x00\x02", &elsewhere);

    try testing.expect(!std.mem.eql(u8, &early, &late));
    try testing.expect(!std.mem.eql(u8, &early, &elsewhere));
    // Past the first turn of the hash as well as within it.
    try testing.expect(!std.mem.allEqual(u8, early[Pool.BLOCK..], 0));
}

test "a pool gives nothing until it has heard enough" {
    var pool = Pool{};
    var bytes: [32]u8 = @splat(0xAA);

    try testing.expect(!pool.ready());
    try testing.expect(!pool.draw(&bytes));
    // Refused, and untouched: a caller that ignores the answer gets no
    // half-random rubbish to mistake for a secret.
    try testing.expectEqual(@as(u8, 0xAA), bytes[0]);

    for (0..Pool.ENOUGH / Pool.A_LITTLE) |i| pool.stir(&[_]u8{@intCast(i & 0xFF)});
    try testing.expect(pool.ready());
    try testing.expect(pool.draw(&bytes));
}

test "two pools that heard different things draw differently, and one never repeats itself" {
    var quiet = Pool{};
    var busy = Pool{};
    for (0..Pool.ENOUGH / Pool.A_LITTLE) |i| {
        quiet.stir(&[_]u8{@intCast(i & 0xFF)});
        busy.stir(&[_]u8{@intCast((i +% 1) & 0xFF)});
    }

    var from_quiet: [32]u8 = undefined;
    var from_busy: [32]u8 = undefined;
    try testing.expect(quiet.draw(&from_quiet));
    try testing.expect(busy.draw(&from_busy));
    try testing.expect(!std.mem.eql(u8, &from_quiet, &from_busy));

    var again: [32]u8 = undefined;
    try testing.expect(quiet.draw(&again));
    try testing.expect(!std.mem.eql(u8, &from_quiet, &again));
}

test "a draw longer than one turn of the hash is filled all the way, and stirring is not commutative" {
    var pool = Pool{};
    for (0..Pool.ENOUGH / Pool.A_LITTLE) |_| pool.stir("noise");

    var long: [Pool.BLOCK * 2 + 7]u8 = @splat(0);
    try testing.expect(pool.draw(&long));
    // Both halves came from different turns, so neither is the other.
    try testing.expect(!std.mem.eql(u8, long[0..Pool.BLOCK], long[Pool.BLOCK..][0..Pool.BLOCK]));
    try testing.expect(!std.mem.allEqual(u8, long[Pool.BLOCK * 2 ..], 0));

    var forward = Pool{};
    var backward = Pool{};
    forward.stir("a");
    forward.stir("b");
    backward.stir("b");
    backward.stir("a");
    try testing.expect(!std.mem.eql(u8, &forward.state, &backward.state));
}

test "a gap is what is kept, so a steady counter still records what varied" {
    var jitter = Jitter{};

    // A perfectly regular clock says the same thing every time. The first
    // sample sets the origin and its own gap means nothing, so take one more
    // than the ring holds and let it be overwritten.
    var ticks: u64 = 1000;
    jitter.sample(ticks);
    for (0..Jitter.SAMPLES) |_| {
        ticks += 500;
        jitter.sample(ticks);
    }
    try testing.expect(std.mem.allEqual(Jitter.Sample, &jitter.ring, 500));

    // A jittery one does not.
    var uneven = Jitter{};
    ticks = 1000;
    uneven.sample(ticks);
    for (0..Jitter.SAMPLES) |i| {
        ticks += 500 + i;
        uneven.sample(ticks);
    }
    try testing.expect(!std.mem.allEqual(Jitter.Sample, &uneven.ring, 500));
}

test "a batch is full only once a whole ring of samples has arrived since the last drain" {
    var jitter = Jitter{};
    var pool = Pool{};

    try testing.expect(!jitter.full());
    for (0..Jitter.SAMPLES - 1) |i| jitter.sample(i * 7);
    try testing.expect(!jitter.full());
    try testing.expect(!jitter.drain(&pool));

    // Draining reset the count, so the ring has to fill again.
    for (0..Jitter.SAMPLES) |i| jitter.sample(i * 11);
    try testing.expect(jitter.full());
    try testing.expect(jitter.drain(&pool));
    try testing.expect(!jitter.full());
}

test "what the interrupts saw reaches the pool, and different timings reach it differently" {
    var quiet = Pool{};
    var busy = Pool{};
    const before = quiet.state;

    var one = Jitter{};
    var other = Jitter{};
    for (0..Jitter.SAMPLES) |i| {
        one.sample(i * 500);
        other.sample(i * 500 + i);
    }
    _ = one.drain(&quiet);
    _ = other.drain(&busy);

    try testing.expect(!std.mem.eql(u8, &before, &quiet.state));
    try testing.expect(!std.mem.eql(u8, &quiet.state, &busy.state));
}

test "enough interrupts make a pool ready to draw on" {
    var jitter = Jitter{};
    var pool = Pool{};

    var ticks: u64 = 0;
    for (0..Pool.ENOUGH / Jitter.SAMPLES) |round| {
        for (0..Jitter.SAMPLES) |i| {
            ticks += 4000 + (round * 13 + i * 7) % 97;
            jitter.sample(ticks);
        }
        try testing.expect(jitter.drain(&pool));
    }

    try testing.expect(pool.ready());
    var bytes: [32]u8 = undefined;
    try testing.expect(pool.draw(&bytes));
}

test "asking repeatedly does not talk a pool into thinking it heard more" {
    var jitter = Jitter{};
    var pool = Pool{};

    // One full batch, then a thousand requests with no interrupts behind them.
    for (0..Jitter.SAMPLES) |i| jitter.sample(i * 37);
    try testing.expect(jitter.drain(&pool));
    const after_one = pool.heard;

    for (0..1000) |_| try testing.expect(!jitter.drain(&pool));
    try testing.expectEqual(after_one, pool.heard);
    try testing.expect(!pool.ready());
}

test "a batch that is all one value is not evidence of anything" {
    var jitter = Jitter{};
    var pool = Pool{};

    // A timer firing on an exact division of the counter: every gap the same.
    var ticks: u64 = 0;
    for (0..Jitter.SAMPLES * 4) |_| {
        ticks += 11_931;
        jitter.sample(ticks);
        try testing.expect(!jitter.drain(&pool));
    }
    try testing.expectEqual(@as(u32, 0), pool.heard);

    // One interrupt that landed late is enough to make the batch worth having.
    for (0..Jitter.SAMPLES - 1) |_| {
        ticks += 11_931;
        jitter.sample(ticks);
    }
    ticks += 11_940;
    jitter.sample(ticks);
    try testing.expect(jitter.drain(&pool));
    try testing.expectEqual(@as(u32, Jitter.SAMPLES), pool.heard);
}

test "a pool is ready once it has seen a bit an interrupt for the size of a seed" {
    var jitter = Jitter{};
    var pool = Pool{};

    // 256 interrupts, which at the timer's 100 Hz is under three seconds, and
    // far sooner on a machine doing anything at all.
    var ticks: u64 = 0;
    var seen: usize = 0;
    while (!pool.ready()) : (seen += 1) {
        ticks += 11_931 + seen % 13;
        jitter.sample(ticks);
        _ = jitter.drain(&pool);
    }
    try testing.expectEqual(Pool.ENOUGH, seen);
}
