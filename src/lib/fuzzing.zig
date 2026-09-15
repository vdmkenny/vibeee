//! Choice source for fuzz targets.
//!
//! A target asks for each part of its input through `Choices`. Two
//! implementations: the fuzzer's `Smith`, and a seeded generator for a bounded
//! run of the same target in `make test`.
//!
//! Do not feed a `Smith` random bytes. It has its own encoding: `eos` treats
//! any non-zero byte as end of stream, and `value` and `index` return their
//! minimum for almost every input.
//!
//! Test-only. In `lib` because targets live in `kernel/`, `arch/` and `user/`.
//! Nothing outside a test block names it.

const std = @import("std");

pub const Choices = union(enum) {
    fuzzer: *std.testing.Smith,
    seeded: std.Random,

    /// Any value of an integer type.
    pub fn int(self: Choices, comptime T: type) T {
        return switch (self) {
            .fuzzer => |smith| smith.value(T),
            .seeded => |random| random.int(T),
        };
    }

    /// A position in something `len` long. `len` must be non-zero.
    pub fn below(self: Choices, len: usize) usize {
        return switch (self) {
            .fuzzer => |smith| smith.index(len),
            .seeded => |random| random.uintLessThan(usize, len),
        };
    }

    /// A count from 1 to `at_most`.
    pub fn upTo(self: Choices, at_most: u8) u8 {
        return switch (self) {
            .fuzzer => |smith| smith.valueRangeAtMost(u8, 1, at_most),
            .seeded => |random| random.intRangeAtMost(u8, 1, at_most),
        };
    }

    /// One case of an enum.
    pub fn one(self: Choices, comptime T: type) T {
        return switch (self) {
            .fuzzer => |smith| smith.value(T),
            .seeded => |random| random.enumValue(T),
        };
    }

    /// Yes or no.
    pub fn odds(self: Choices, in: u8) bool {
        return self.below(in) == 0;
    }

    /// Fill `out` with bytes.
    pub fn bytes(self: Choices, out: []u8) void {
        switch (self) {
            .fuzzer => |smith| for (out) |*b| {
                b.* = smith.value(u8);
            },
            .seeded => |random| random.bytes(out),
        }
    }
};

/// Run `target` against a generator, `rounds` times.
///
/// The seed is fixed, not taken from the clock, so a failing run repeats.
pub fn seeded(
    comptime target: fn (Choices) anyerror!void,
    seed: u64,
    rounds: usize,
) anyerror!void {
    var prng = std.Random.DefaultPrng.init(seed);
    for (0..rounds) |_| try target(.{ .seeded = prng.random() });
}
