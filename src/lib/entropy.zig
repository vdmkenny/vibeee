//! Unpredictable bytes, gathered from what the machine cannot foresee.
//!
//! This computer has no dedicated source of randomness. What it does have
//! is a radio, and a radio in a room hears things nobody arranged: the
//! exact moment a frame lands, how strong it was, and above all the
//! frames it could not decode at all, which are the band's noise written
//! down. Stir enough of that together and what comes out is as hard to
//! guess as the room was.
//!
//! The pool is a hash over everything stirred in. Drawing does not hand
//! back what is in it: the answer is a hash of the pool and a count that
//! never repeats, and the pool moves on afterwards, so bytes drawn say
//! nothing about the bytes drawn next or the ones stirred in before.

const std = @import("std");
const testing = std.testing;

pub const Pool = struct {
    pub const Hash = std.crypto.hash.sha2.Sha256;

    /// How many bytes a draw can serve from one turn of the hash.
    pub const BLOCK = Hash.digest_length;

    /// How many stirrings a pool wants before what it gives is worth
    /// calling unpredictable. A frame's worth of noise carries far less
    /// than a frame's worth of surprise, so this counts stirrings rather
    /// than bytes and asks for many.
    pub const ENOUGH = 64;

    state: [BLOCK]u8 = @splat(0),
    stirred: u32 = 0,
    drawn: u64 = 0,

    /// Mix something in. Anything may be stirred in: nothing that goes in
    /// can make the pool worse, and whatever was unpredictable about it
    /// stays so.
    pub fn stir(self: *Pool, bytes: []const u8) void {
        var hash = Hash.init(.{});
        hash.update(&self.state);
        hash.update(bytes);
        hash.final(&self.state);
        self.stirred +|= 1;
    }

    /// Whether enough has been heard for a draw to mean anything.
    pub fn ready(self: Pool) bool {
        return self.stirred >= ENOUGH;
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

        // Move the pool on, so what was drawn cannot be worked back to
        // what is left.
        self.stir(&self.state);
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

    for (0..Pool.ENOUGH) |i| pool.stir(&[_]u8{@intCast(i & 0xFF)});
    try testing.expect(pool.ready());
    try testing.expect(pool.draw(&bytes));
}

test "two pools that heard different things draw differently, and one never repeats itself" {
    var quiet = Pool{};
    var busy = Pool{};
    for (0..Pool.ENOUGH) |i| {
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
    for (0..Pool.ENOUGH) |_| pool.stir("noise");

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
