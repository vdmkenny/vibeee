//! Page frames as a bitmap, and the policy for where each kind goes.
//!
//! One bit per frame, `@ctz` over words to skip what is taken. A buddy
//! allocator would buy cheaper contiguous allocation, but the contiguous
//! consumers here are device rings: few, small, and mostly long-lived, so
//! what they need is not speed but a region ordinary churn has not
//! checkerboarded.
//!
//! That region is the band: the lowest free frames, preferred for device
//! runs and avoided by everything else. Single frames rove above it, and a
//! kernel heap's large blocks start above it, so after weeks of churn the
//! band still holds the unbroken runs a hotplugged disk or a restarted
//! driver asks for. It is a preference, not a carve: under real pressure
//! singles spill into the band rather than failing with memory free,
//! because correctness beats placement.
//!
//! Pure over a caller's words, so the policy is host-tested: the stress a
//! machine would need weeks of uptime to apply is a loop here.

const std = @import("std");

pub const Word = u32;
pub const BITS_PER_WORD = @bitSizeOf(Word);

/// Who is asking for a contiguous run, which decides where it goes.
pub const Origin = enum {
    /// A DMA engine's rings or buffers: served from the band up, so the ask
    /// meets clean memory first.
    device,
    /// Anything else that needs physical contiguity, the kernel heap's large
    /// blocks above all: served from above the band, so its churn never
    /// breaks the band up.
    general,
};

/// How large the band should be on a machine with `total` frames, given the
/// cap the budget sets.
///
/// The cap does not scale with memory, because what the band holds does not:
/// a machine of this class carries the same few controllers whether it has
/// 128 MiB or 4 GiB, and their rings tally the same. What does scale is the
/// guard for small machines, where a fixed cap would be a disproportionate
/// slice: never more than a sixteenth of what there is.
pub fn bandFrames(total: usize, cap: usize) usize {
    return @min(cap, total / 16);
}

pub const Map = struct {
    words: []Word,
    /// Frames below this are never handed out at all.
    floor: usize = 0,
    /// Frames in [floor, band) are the device band.
    band: usize = 0,
    /// One past the last managed frame.
    limit: usize = 0,
    free: usize = 0,
    /// Where the single-frame rove continues from, so repeated allocation
    /// does not rescan from the band every time.
    hint: usize = 0,

    /// Everything starts taken; the caller releases what the memory map says
    /// is usable. Defaulting to "used" means an absent map fails safe.
    pub fn init(words: []Word, floor: usize, band: usize, limit: usize) Map {
        @memset(words, ~@as(Word, 0));
        return .{
            .words = words,
            .floor = floor,
            .band = @max(band, floor),
            .limit = @min(limit, words.len * BITS_PER_WORD),
            .hint = @max(band, floor),
        };
    }

    pub fn isUsed(self: *const Map, frame: usize) bool {
        return (self.words[frame / BITS_PER_WORD] &
            (@as(Word, 1) << @intCast(frame % BITS_PER_WORD))) != 0;
    }

    fn mark(self: *Map, frame: usize) void {
        self.words[frame / BITS_PER_WORD] |= @as(Word, 1) << @intCast(frame % BITS_PER_WORD);
    }

    fn clear(self: *Map, frame: usize) void {
        self.words[frame / BITS_PER_WORD] &= ~(@as(Word, 1) << @intCast(frame % BITS_PER_WORD));
    }

    /// Take a frame out of circulation, wherever it is. For the boot walk
    /// that carves the kernel image and firmware regions out.
    pub fn reserve(self: *Map, frame: usize) void {
        if (frame >= self.limit or self.isUsed(frame)) return;
        self.mark(frame);
        self.free -= 1;
    }

    /// The opposite: a frame the memory map says may be used.
    pub fn release(self: *Map, frame: usize) void {
        if (frame >= self.words.len * BITS_PER_WORD or !self.isUsed(frame)) return;
        self.clear(frame);
        self.free += 1;
    }

    /// One frame, from wherever the rove is.
    ///
    /// Above the band first, in two passes around the rove, and only then
    /// from the band itself: the band is the last memory spent, not memory
    /// that cannot be spent.
    pub fn one(self: *Map) ?usize {
        if (self.findFree(self.hint, self.limit)) |f| return self.take(f);
        if (self.findFree(self.band, self.hint)) |f| return self.take(f);
        if (self.findFree(self.floor, self.band)) |f| return self.take(f);
        return null;
    }

    fn take(self: *Map, frame: usize) usize {
        self.mark(frame);
        self.free -= 1;
        self.hint = frame + 1;
        if (self.hint >= self.limit) self.hint = self.band;
        return frame;
    }

    pub fn give(self: *Map, frame: usize) void {
        if (frame >= self.words.len * BITS_PER_WORD) return;
        if (!self.isUsed(frame)) return; // double free: ignore, not corrupt
        self.clear(frame);
        self.free += 1;
    }

    /// `count` contiguous frames below `ceiling`, or null.
    ///
    /// A device ask walks up from the floor and so meets the band first; a
    /// general ask starts above the band and falls back into it only when
    /// nothing above fits, which is the pressure the band yields to.
    pub fn run(self: *Map, count: usize, ceiling: usize, origin: Origin) ?usize {
        if (count == 0) return null;
        const top = @min(ceiling, self.limit);

        return switch (origin) {
            .device => self.findRun(self.floor, top, count),
            .general => self.findRun(self.band, top, count) orelse
                self.findRun(self.floor, top, count),
        };
    }

    fn findRun(self: *Map, from: usize, top: usize, count: usize) ?usize {
        var f = from;
        while (f + count <= top) {
            var length: usize = 0;
            while (length < count and !self.isUsed(f + length)) : (length += 1) {}
            if (length == count) {
                for (0..count) |i| {
                    self.mark(f + i);
                }
                self.free -= count;
                return f;
            }
            f += length + 1;
        }
        return null;
    }

    /// The longest unbroken free run below `ceiling`, in frames.
    ///
    /// The reading that makes fragmentation visible before it is a failure:
    /// free bytes say how much there is, and this says how much of it is
    /// usable by the things that need it in one piece.
    pub fn largestRun(self: *const Map, ceiling: usize) usize {
        const top = @min(ceiling, self.limit);
        var longest: usize = 0;
        var current: usize = 0;

        var f = self.floor;
        while (f < top) {
            // Whole words at a time where the answer is uniform, which is
            // most of the map most of the time.
            if (f % BITS_PER_WORD == 0 and f + BITS_PER_WORD <= top) {
                const word = self.words[f / BITS_PER_WORD];
                if (word == 0) {
                    current += BITS_PER_WORD;
                    f += BITS_PER_WORD;
                    continue;
                }
                if (word == ~@as(Word, 0)) {
                    longest = @max(longest, current);
                    current = 0;
                    f += BITS_PER_WORD;
                    continue;
                }
            }
            if (self.isUsed(f)) {
                longest = @max(longest, current);
                current = 0;
            } else {
                current += 1;
            }
            f += 1;
        }
        return @max(longest, current);
    }

    /// How many frames of [floor, band) are free: how much of the clean
    /// region is still clean.
    pub fn bandFree(self: *const Map) usize {
        var n: usize = 0;
        var f = self.floor;
        while (f < self.band) : (f += 1) {
            if (!self.isUsed(f)) n += 1;
        }
        return n;
    }

    /// First free frame in [from, to), skipping taken words whole.
    fn findFree(self: *const Map, from: usize, to: usize) ?usize {
        if (from >= to) return null;
        var w = from / BITS_PER_WORD;
        const w_end = (to + BITS_PER_WORD - 1) / BITS_PER_WORD;
        while (w < w_end and w < self.words.len) : (w += 1) {
            if (self.words[w] == ~@as(Word, 0)) continue;
            const inverted = ~self.words[w];
            const first: usize = @ctz(inverted);
            const frame = w * BITS_PER_WORD + first;
            if (frame >= from and frame < to) return frame;
            // The first free bit is out of range; walk the rest of the word.
            var b = first;
            while (b < BITS_PER_WORD) : (b += 1) {
                const f = w * BITS_PER_WORD + b;
                if (f >= to) return null;
                if (f >= from and (inverted & (@as(Word, 1) << @intCast(b))) != 0) return f;
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A small machine: 1024 frames, floor at 8, band to 64.
fn smallMap(words: []Word) Map {
    var map = Map.init(words, 8, 64, 1024);
    for (8..1024) |f| map.release(f);
    return map;
}

test "the band is a fixed budget with a guard for small machines" {
    const MIB_FRAMES = 1024 * 1024 / 4096;

    // The class this system runs on: 128 MiB to 4 GiB. The budget holds
    // across the middle and the top, and shrinks proportionally below.
    try testing.expectEqual(8 * MIB_FRAMES, bandFrames(128 * MIB_FRAMES, 8 * MIB_FRAMES));
    try testing.expectEqual(8 * MIB_FRAMES, bandFrames(512 * MIB_FRAMES, 8 * MIB_FRAMES));
    try testing.expectEqual(8 * MIB_FRAMES, bandFrames(4096 * MIB_FRAMES, 8 * MIB_FRAMES));
    try testing.expectEqual(4 * MIB_FRAMES, bandFrames(64 * MIB_FRAMES, 8 * MIB_FRAMES));
    try testing.expectEqual(2 * MIB_FRAMES, bandFrames(32 * MIB_FRAMES, 8 * MIB_FRAMES));
}

test "singles stay out of the band until nothing else is left" {
    var words: [32]Word = undefined;
    var map = smallMap(&words);

    // The first single lands at the band's top edge, not at the floor.
    try testing.expectEqual(@as(?usize, 64), map.one());
    try testing.expectEqual(@as(usize, 64 - 8), map.bandFree());

    // Fill everything above the band; the band stays whole.
    var taken: usize = 1;
    while (taken < 1024 - 64) : (taken += 1) {
        try testing.expect(map.one() != null);
    }
    try testing.expectEqual(@as(usize, 64 - 8), map.bandFree());

    // Now the band is the last resort, and it answers rather than failing
    // with memory free.
    try testing.expectEqual(@as(?usize, 8), map.one());
    var left: usize = 64 - 8 - 1;
    while (left > 0) : (left -= 1) {
        try testing.expect(map.one() != null);
    }
    try testing.expectEqual(@as(?usize, null), map.one());
    try testing.expectEqual(@as(usize, 0), map.free);
}

test "a device run meets the band first and a general run never does" {
    var words: [32]Word = undefined;
    var map = smallMap(&words);

    try testing.expectEqual(@as(?usize, 8), map.run(16, 1024, .device));
    try testing.expectEqual(@as(?usize, 64), map.run(16, 1024, .general));

    // A general ask that cannot be served above falls into the band, because
    // failing with memory free would be placement beating correctness.
    var f: usize = 80;
    while (f < 1024) : (f += 1) map.reserve(f);
    const fallback = map.run(16, 1024, .general) orelse return error.TestUnexpectedResult;
    try testing.expect(fallback < 64);
}

test "a device run larger than the band still succeeds" {
    var words: [32]Word = undefined;
    var map = smallMap(&words);

    // The band is 56 frames; the ask is 128. It is served across the band's
    // edge, since a device ask walks the whole space from the floor.
    const got = map.run(128, 1024, .device) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 8), got);
}

test "the ceiling is honoured" {
    var words: [32]Word = undefined;
    var map = smallMap(&words);

    // Nothing below frame 16 is free once taken; a ceiling of 16 refuses.
    for (8..16) |f| map.reserve(f);
    try testing.expectEqual(@as(?usize, null), map.run(4, 16, .device));
    try testing.expect(map.run(4, 64, .device) != null);
}

test "reserve and release keep the count honest" {
    var words: [32]Word = undefined;
    var map = smallMap(&words);
    const was = map.free;

    map.reserve(100);
    try testing.expectEqual(was - 1, map.free);
    // Reserving what is already taken changes nothing.
    map.reserve(100);
    try testing.expectEqual(was - 1, map.free);

    map.give(100);
    try testing.expectEqual(was, map.free);
    // A double free is ignored rather than corrupting the count.
    map.give(100);
    try testing.expectEqual(was, map.free);
}

test "the largest run is what a contiguous ask could actually get" {
    var words: [32]Word = undefined;
    var map = smallMap(&words);

    try testing.expectEqual(@as(usize, 1024 - 8), map.largestRun(1024));

    // A single frame in the middle splits it.
    map.reserve(500);
    try testing.expectEqual(@as(usize, 1024 - 501), map.largestRun(1024));

    // And the reading agrees with what run() can serve: take the whole of
    // it, and what remains to be read is the other side of the split.
    const biggest = map.largestRun(1024);
    try testing.expect(map.run(biggest, 1024, .device) != null);
    try testing.expectEqual(@as(usize, 500 - 8), map.largestRun(1024));
    try testing.expect(map.run(biggest, 1024, .device) == null);
}

test "the largest run reads the same across word boundaries" {
    var words: [4]Word = undefined;
    var map = Map.init(&words, 0, 0, 128);
    for (0..128) |f| map.release(f);

    // A run that starts mid-word, crosses two whole words and ends mid-word.
    for (0..20) |f| map.reserve(f);
    for (110..128) |f| map.reserve(f);
    try testing.expectEqual(@as(usize, 90), map.largestRun(128));
}

// ---------------------------------------------------------------------------
// The stress: weeks of uptime as a loop
// ---------------------------------------------------------------------------

/// The machine's own shape: 512 MiB of 4 KiB frames, the floor at 1 MiB,
/// the band to 8 MiB.
const STRESS_FRAMES = 131072;
const STRESS_FLOOR = 256;
const STRESS_BAND = 2048;

const Stress = struct {
    map: Map,
    prng: std.Random.DefaultPrng,
    /// What churn holds, so frees pick a real allocation.
    singles: std.ArrayList(usize),
    runs: std.ArrayList(struct { at: usize, len: usize }),
    gpa: std.mem.Allocator,
    /// What the whole machine holds when idle, for the occupancy target.
    managed: usize,

    fn init(gpa: std.mem.Allocator, words: []Word, seed: u64) Stress {
        var map = Map.init(words, STRESS_FLOOR, STRESS_BAND, STRESS_FRAMES);
        // The kernel image sits inside the band on the real machine, so it
        // does here: frames 256..640, reserved before anything runs.
        for (STRESS_FLOOR..STRESS_FRAMES) |f| map.release(f);
        for (256..640) |f| map.reserve(f);

        return .{
            .map = map,
            .prng = std.Random.DefaultPrng.init(seed),
            .singles = .empty,
            .runs = .empty,
            .gpa = gpa,
            .managed = map.free,
        };
    }

    fn deinit(self: *Stress) void {
        self.singles.deinit(self.gpa);
        self.runs.deinit(self.gpa);
    }

    /// One step of what a running machine does: user pages and heap blocks
    /// taken and given back, oscillating around a working set rather than
    /// drifting, the way a machine that is used and not merely filled does.
    fn churn(self: *Stress) !void {
        const random = self.prng.random();
        const used = self.managed - self.map.free;
        const above_target = used * 10 > self.managed * 3;

        if (above_target) {
            if (random.boolean() and self.runs.items.len > 0) {
                const at = random.uintLessThan(usize, self.runs.items.len);
                const held = self.runs.swapRemove(at);
                for (held.at..held.at + held.len) |f| self.map.give(f);
            } else if (self.singles.items.len > 0) {
                const at = random.uintLessThan(usize, self.singles.items.len);
                self.map.give(self.singles.swapRemove(at));
            }
            return;
        }

        if (random.uintLessThan(u8, 4) == 0) {
            // A kernel heap block: a thread stack, a large buffer.
            const len = @as(usize, 2) + random.uintLessThan(usize, 15);
            if (self.map.run(len, STRESS_FRAMES, .general)) |at| {
                try self.runs.append(self.gpa, .{ .at = at, .len = len });
            }
        } else {
            // A page: a surface growing, a process starting.
            if (self.map.one()) |f| try self.singles.append(self.gpa, f);
        }
    }
};

test "device runs survive heavy churn without touching a broken region" {
    // Four machines' worth of different luck, half a million operations
    // each: the seeds change where every hole lands, and the property has to
    // hold wherever they land.
    for ([_]u64{ 0x0701, 0x2007, 0xEEE, 0xA51157 }) |seed| {
        var words: [STRESS_FRAMES / BITS_PER_WORD]Word = undefined;
        var stress = Stress.init(testing.allocator, &words, seed);
        defer stress.deinit();

        // The drivers' own arenas, taken at boot and held: two USB
        // controllers, two sound devices, a couple of NICs.
        var arenas: [6]struct { at: usize, len: usize } = undefined;
        for (&arenas, 0..) |*arena, n| {
            const len = 24 + n * 8;
            const at = stress.map.run(len, STRESS_FRAMES, .device) orelse
                return error.TestUnexpectedResult;
            arena.* = .{ .at = at, .len = len };
        }

        const resting = stress.map.bandFree();
        var i: usize = 0;
        while (i < 500_000) : (i += 1) {
            try stress.churn();

            // A hotplugged disk: a ublk data area taken and given back.
            if (i % 500 == 499) {
                const at = stress.map.run(16, STRESS_FRAMES, .device) orelse
                    return error.TestUnexpectedResult;
                // From the band, which the churn above has not touched.
                try testing.expect(at < STRESS_BAND);
                for (at..at + 16) |f| stress.map.give(f);
            }

            // A service restart: one driver's arena given back and asked for
            // again mid-churn, which is the moment the old allocator had
            // nothing clean to answer with.
            if (i % 10_000 == 9_999) {
                const random = stress.prng.random();
                const which = random.uintLessThan(usize, arenas.len);
                const old_arena = arenas[which];
                for (old_arena.at..old_arena.at + old_arena.len) |f| stress.map.give(f);

                const at = stress.map.run(old_arena.len, STRESS_FRAMES, .device) orelse
                    return error.TestUnexpectedResult;
                try testing.expect(at < STRESS_BAND);
                arenas[which] = .{ .at = at, .len = old_arena.len };
            }
        }

        // Weeks of churn later the band holds exactly what it held at rest:
        // the arenas, and nothing that spilled.
        try testing.expectEqual(resting, stress.map.bandFree());
        try testing.expectEqual(@as(usize, 0), bandStrays(&stress));
    }
}

/// Frames the churn holds inside the band, which should be none while
/// anything above is free.
fn bandStrays(stress: *const Stress) usize {
    var strays: usize = 0;
    for (stress.singles.items) |f| {
        if (f < STRESS_BAND) strays += 1;
    }
    for (stress.runs.items) |held| {
        if (held.at < STRESS_BAND) strays += 1;
    }
    return strays;
}

test "a checkerboard above the band cannot break a device ask" {
    // The failure the band exists to prevent, applied deliberately: every
    // other frame above the band taken, so the largest run up there is one
    // frame and a sixteen-frame ask has nowhere to go but down.
    var words: [STRESS_FRAMES / BITS_PER_WORD]Word = undefined;
    var map = Map.init(&words, STRESS_FLOOR, STRESS_BAND, STRESS_FRAMES);
    for (STRESS_FLOOR..STRESS_FRAMES) |f| map.release(f);

    var f: usize = STRESS_BAND;
    while (f < STRESS_FRAMES) : (f += 2) map.reserve(f);

    // Free memory is plentiful and useless: a quarter of the machine, in
    // pieces of one.
    try testing.expect(map.free > STRESS_FRAMES / 4);

    // The device ask lands in the band, whole.
    const ring = map.run(16, STRESS_FRAMES, .device) orelse
        return error.TestUnexpectedResult;
    try testing.expect(ring < STRESS_BAND);

    // A general ask that no longer fits above falls into the band too,
    // because failing with a quarter of the machine free would be placement
    // beating correctness.
    const spilled = map.run(4, STRESS_FRAMES, .general) orelse
        return error.TestUnexpectedResult;
    try testing.expect(spilled < STRESS_BAND);

    // And the reading says exactly what happened: the largest run is the
    // band's remainder, not the useless quarter.
    try testing.expect(map.largestRun(STRESS_FRAMES) < STRESS_BAND - STRESS_FLOOR);
    try testing.expect(map.largestRun(STRESS_FRAMES) > 1);
}

test "without the band the same churn breaks the low region" {
    // The same machine with the band turned off, which is the allocator as
    // it was: this is the failure the band exists to prevent, kept as a test
    // so the reason cannot quietly rot.
    var words: [STRESS_FRAMES / BITS_PER_WORD]Word = undefined;
    var stress = Stress.init(testing.allocator, &words, 0x0701);
    defer stress.deinit();
    stress.map.band = stress.map.floor;
    stress.map.hint = stress.map.floor;

    var i: usize = 0;
    while (i < 200_000) : (i += 1) try stress.churn();

    // The low eight mebibytes are churned like everywhere else.
    var used_low: usize = 0;
    for (STRESS_FLOOR..STRESS_BAND) |f| {
        if (stress.map.isUsed(f)) used_low += 1;
    }
    // More than the kernel image alone: churn moved in.
    try testing.expect(used_low > 640 - 256);
}

test "under pressure every frame is reachable and everything comes back" {
    var words: [64]Word = undefined;
    var map = Map.init(&words, 4, 32, 2048);
    for (4..2048) |f| map.release(f);
    const all = map.free;

    // Take absolutely everything as singles: the band does not strand a
    // single frame.
    var taken: usize = 0;
    while (map.one()) |_| taken += 1;
    try testing.expectEqual(all, taken);
    try testing.expectEqual(@as(usize, 0), map.free);
    try testing.expectEqual(@as(?usize, null), map.run(1, 2048, .device));

    // Give it all back; the map is whole again.
    for (4..2048) |f| map.give(f);
    try testing.expectEqual(all, map.free);
    try testing.expectEqual(@as(usize, 2048 - 4), map.largestRun(2048));
}
