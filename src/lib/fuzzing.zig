//! Where a fuzz target's choices come from.
//!
//! A target here is a function that builds one input, runs the code under
//! test on it, and asserts what must hold. What it does not do is decide the
//! input: it asks for each part of it, and this says who answers.
//!
//! Two answer. The fuzzer hands out values through a `std.testing.Smith`,
//! searching for choices that reach code nothing else has. A seeded generator
//! hands out values from a fixed seed, which finds far less but runs in
//! `make test` and runs the same target.
//!
//! Both are needed because neither is enough on its own. The search is what
//! finds the rare case, and it does not work on this toolchain
//! (`make fuzz` says why). The seeded run is bounded and reproducible, which
//! is what a gate needs, and is no good at all at finding anything rare.
//!
//! **Do not try to drive a `Smith` from random bytes.** It has an encoding of
//! its own, so bytes put in do not map onto values that come out: `eos` reads
//! one byte and calls any non-zero value the end of the stream, and `value`
//! and `index` return their minimum for almost every input. A generator
//! pointed at one produces the same trivial input every time, which is a test
//! that passes without testing anything. That is what this union is for.
//!
//! Test-only, and in `lib` because the targets are not: they sit beside the
//! code they test, in `kernel/`, in `arch/` and in `user/`, and this is the
//! one place all three can reach. Nothing outside a test block names it, so
//! nothing of it reaches the image.

const std = @import("std");

pub const Choices = union(enum) {
    /// The fuzzer, searching for inputs that reach new code.
    fuzzer: *std.testing.Smith,
    /// A generator, for a bounded run of the same target.
    seeded: std.Random,

    /// Any value of an integer type.
    pub fn int(self: Choices, comptime T: type) T {
        return switch (self) {
            .fuzzer => |smith| smith.value(T),
            .seeded => |random| random.int(T),
        };
    }

    /// A position in something `len` long. `len` must not be zero.
    pub fn below(self: Choices, len: usize) usize {
        return switch (self) {
            .fuzzer => |smith| smith.index(len),
            .seeded => |random| random.uintLessThan(usize, len),
        };
    }

    /// A count from one to `at_most`, for how many times to do something.
    pub fn upTo(self: Choices, at_most: u8) u8 {
        return switch (self) {
            .fuzzer => |smith| smith.valueRangeAtMost(u8, 1, at_most),
            .seeded => |random| random.intRangeAtMost(u8, 1, at_most),
        };
    }

    /// One case of an enum, for choosing between kinds of input.
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

/// Run `target` against a generator, `rounds` times, from a fixed seed.
///
/// What stands in for the search on a toolchain whose search does not build.
/// The seed is written down rather than taken from the clock: a run that
/// fails has to fail again on the next run, or there is nothing to debug.
pub fn seeded(
    comptime target: fn (Choices) anyerror!void,
    seed: u64,
    rounds: usize,
) anyerror!void {
    var prng = std.Random.DefaultPrng.init(seed);
    for (0..rounds) |_| try target(.{ .seeded = prng.random() });
}
