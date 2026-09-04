//! The machine's randomness.
//!
//! There is no hardware random source on this computer, so the surprise comes
//! from timing. Interrupts land at moments that vary with caches, memory
//! refresh, bus traffic and the devices themselves, and the kernel is the only
//! thing that sees every one of them. Each contributes the gap since the last.
//!
//! Those gaps go into a pool, the pool seeds a stream cipher, and the cipher
//! answers every request. What comes out never repeats and says nothing about
//! what came before it.
//!
//! Programs ask through the `random` syscall. A driver holding a source of its
//! own, such as a radio hearing a room, adds to the pool through `random_stir`,
//! so what one process can hear improves what every process draws.

const std = @import("std");
const lib = @import("lib");
const clock = @import("clock.zig");
const console = @import("console.zig");
const hal = @import("hal.zig");

/// Interrupt timing, filled in the interrupt path and stirred in by whoever
/// next asks for randomness. Nothing here hashes: an interrupt handler that
/// hashed would cost more than the sample is worth.
var jitter: lib.entropy.Jitter = .{};

/// Everything heard, and the cipher seeded from it.
var pool: lib.entropy.Pool = .{};
var csprng: std.Random.DefaultCsprng = undefined;
var seeded = false;

/// Said once, when the pool first has enough in it to answer for a secret.
/// A machine that never says it is a machine whose randomness nothing can
/// depend on, and that is worth being able to see.
var announced = false;

/// Record the moment an interrupt landed. Called from the interrupt path,
/// where interrupts are already off.
///
/// The pool has to fill whether or not anyone is asking, so a full batch is
/// stirred in here rather than waiting for a request. That costs one hash per
/// SAMPLES interrupts, which at the timer's rate is a few a second; hashing
/// every interrupt is what would be too much.
pub fn sample(ticks: u64) void {
    jitter.sample(ticks);
    _ = jitter.drain(&pool);
}

/// Mix something in from outside the kernel.
pub fn stir(bytes: []const u8) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    pool.stir(bytes);
}

/// Fill `into`, and say whether the machine has heard enough for the answer to
/// be worth calling unguessable.
///
/// A caller that gets `false` still gets bytes, and they still differ from
/// every other draw, but they came from a pool nobody has told enough. That is
/// the answer a caller with a secret to keep has to check.
pub fn fill(into: []u8) bool {
    const ready = draw(into);

    // Said outside the guard: the console writes to a framebuffer, and holding
    // interrupts off for that would be a long silence for one line.
    if (ready and !announced) {
        announced = true;
        console.info("random", "the pool has heard enough; draws are unguessable from here", .{});
    }
    return ready;
}

/// The part that touches the pool, with interrupts held off around all of it:
/// every interrupt is a sample, so an interrupt landing inside this would be
/// two things writing the same state.
fn draw(into: []u8) bool {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    const ready = pool.draw(&seed);
    if (!ready) {
        // Too early to have heard enough. The clock and the pool's own state
        // give a seed that does not repeat, which is the most a machine that
        // has just started can offer.
        if (seeded) {
            csprng.fill(into);
            return false;
        }
        lib.entropy.fromClock(clock.monotonicMicros(), &pool.state, &seed);
    }

    if (seeded) csprng.addEntropy(&seed) else {
        csprng = .init(seed);
        seeded = true;
    }
    csprng.fill(into);
    return ready;
}
