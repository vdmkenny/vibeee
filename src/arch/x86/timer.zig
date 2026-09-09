//! Timer sources.
//!
//! The PIT is the bootstrap clock: always present, needs no ACPI tables, and
//! gives us a periodic interrupt for preemption. It is not the long-term
//! answer, reading it costs a port round-trip, and the research shows this
//! platform has better options, so `monotonicMicros` prefers, in order:
//!
//!   1. HPET, once force-enabled through the LPC bridge (the BIOS does not
//!      declare it in ACPI, so we must do it ourselves)
//!   2. the ACPI PM timer at the port the FADT names
//!   3. the PIT tick counter, below
//!
//! The TSC is deliberately absent from that list: it halts in deep C-states on
//! this CPU, so it is only ever a fast relative counter inside one time slice.
//!
//! See design/00-vibeee.md §6.5.

const console = @import("../../kernel/console.zig");
const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const port = @import("port.zig");
const sched = @import("../../kernel/sched.zig");
const watchdog = @import("../../kernel/watchdog.zig");
const irqevent = @import("../../kernel/irqevent.zig");

const PIT_CHANNEL0 = 0x40;
const PIT_COMMAND = 0x43;

/// The 8253/8254 input frequency, 1.193182 MHz.
const PIT_HZ: u32 = 1_193_182;

/// 100 Hz: a 10 ms tick. Fine enough for scheduling on a single 630 MHz core,
/// coarse enough that the interrupt cost stays negligible.
pub const TICK_HZ: u32 = 100;
pub const TICK_US: u64 = 1_000_000 / TICK_HZ;

/// Written by the interrupt handler, read by everything else. Accessed
/// atomically, not because of SMP, there is one core, but because a plain
/// variable lets the compiler hoist the read out of a polling loop, which
/// silently breaks anything that waits on time passing.
///
/// 32-bit: a 64-bit read-modify-write needs `cmpxchg8b` on this CPU, and 32
/// bits at 100 Hz wraps after 497 days of uptime, which this machine will not
/// see.
var ticks: u32 = 0;

/// Registered once the FADT has been parsed. Until then, zero.
var pm_timer_port: u16 = 0;

/// The PM timer is a free-running counter that wraps, so it is sampled and
/// accumulated rather than read directly. Everything above depends on the
/// monotonic clock never stepping backwards: sleep deadlines are compared
/// against it, and `kernel/clock.zig` derives wall time from it, so a counter
/// that restarts every few seconds would make sleeps end early or never and
/// make the wall clock jump backwards.
var pm_micros: u64 = 0;
var pm_last: u32 = 0;
/// Sub-microsecond part of the conversion, carried across samples so 100
/// samples a second do not lose a microsecond each. In `MICROS_PER_TICK`'s
/// fraction bits.
var pm_fraction: u32 = 0;

pub fn init() void {
    const divisor: u16 = @intCast(PIT_HZ / TICK_HZ);

    // Channel 0, lobyte then hibyte, mode 3 (square wave), binary.
    port.outb(PIT_COMMAND, 0x36);
    port.outb(PIT_CHANNEL0, @truncate(divisor & 0xFF));
    port.outb(PIT_CHANNEL0, @truncate(divisor >> 8));

    idt.setHandler(idt.timerVector(), onTick);
    idt.setIrqMask(0, false);
}

/// The tick at which the deliberate seizure runs; zero means never. Set by
/// the `wedge` boot flag to prove the NMI watchdog end to end: the machine
/// must come back as a panic screen naming the loop below.
var wedge_at: u32 = 0;

pub fn wedgeSoon() void {
    // Refused without the watchdog: seizing a machine nothing can rescue
    // is not a test, it is a hang with extra steps.
    if (!@import("nmiwatch.zig").isArmed()) {
        console.warn("wedge asked, but no nmi watchdog is armed; refusing", .{});
        return;
    }
    wedge_at = @atomicLoad(u32, &ticks, .monotonic) + 10 * TICK_HZ;
    console.warn("wedging in ten seconds to prove the panic path", .{});
}

/// Ticks between watchdog scans: a few times a second against a budget of
/// a second, and the scan is a handful of lines.
const SCRUB_EVERY_TICKS = 32;

fn onTick(_: *idt.Frame) void {
    _ = @atomicRmw(u32, &ticks, .Add, 1, .monotonic);

    // The watchdog for deliveries whose owner has stopped answering. From
    // here because this vector outranks every deferrable one by design, so
    // it still fires while one is stuck.
    if (@atomicLoad(u32, &ticks, .monotonic) % SCRUB_EVERY_TICKS == 0) {
        irqevent.scrub(monotonicMicros());
    }

    if (wedge_at != 0 and @atomicLoad(u32, &ticks, .monotonic) >= wedge_at) {
        // Interrupts are already off in the handler; never returning from
        // it is the seizure. Only the watchdog's NMI can speak after this.
        while (true) {}
    }

    // Sample here rather than relying on something above happening to ask the
    // time: the PM timer's 24-bit counter wraps every 4.69 seconds, and a wrap
    // that passes unsampled is time silently lost from the monotonic clock.
    // Interrupts are already off inside the handler.
    if (pm_timer_port != 0) _ = samplePmTimer();

    if (console.isDebug()) heartbeat();

    sched.onTick();
    watchdog.onTick();
}

/// A quiet machine and a hung one look identical in a still photograph, and
/// the target has no serial port to ask. In debug boots the corner glyph
/// advances from the tick, so it moves exactly as long as interrupts are being
/// taken and freezes the instant they are not.
const HEARTBEAT = [_]u21{ '|', '/', '-', '\\' };
var beat: u32 = 0;

fn heartbeat() void {
    beat +%= 1;
    // A phase step every quarter second: watching the corner for one second
    // answers whether the kernel is alive. Handed to the console, which owns
    // the paint: it keeps the pulse above every line its own output draws.
    if (beat % (TICK_HZ / 4) != 0) return;
    console.setPulse(HEARTBEAT[(beat / (TICK_HZ / 4)) % HEARTBEAT.len]);
}

pub fn tickCount() u64 {
    return @atomicLoad(u32, &ticks, .monotonic);
}

/// Whether the counter at `p` is actually running.
///
/// A firmware that names a port it does not drive would otherwise stop the
/// clock dead, and every sleep and deadline with it. A live counter moves
/// every 279 nanoseconds, so it has changed by the second read on real
/// silicon; the bound is for the port that never will.
pub fn pmTimerRuns(p: u16) bool {
    const first = readPmTimer(p);
    var looked: u32 = 0;
    while (looked < PM_PROBE_LOOKS) : (looked += 1) {
        if (readPmTimer(p) != first) return true;
    }
    return false;
}

const PM_PROBE_LOOKS = 500_000;

/// Adopt the ACPI PM timer as the monotonic source.
///
/// The accumulator continues from wherever the PIT had reached, so the clock
/// does not jump when the source changes underneath it.
pub fn setPmTimerPort(p: u16) void {
    const was = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(was);

    pm_micros = @as(u64, @atomicLoad(u32, &ticks, .monotonic)) * TICK_US;
    pm_fraction = 0;
    pm_last = readPmTimer(p);
    pm_timer_port = p;
}

const PM_MASK: u32 = 0x00FF_FFFF;

/// Microseconds one counter tick is worth, in thirty-two fraction bits.
///
/// The counter runs at 3.579545 MHz and the accumulator wants microseconds,
/// which is a division by a constant that is not a power of two. On a 32-bit
/// part that is a call into a software routine, and this is the clock that
/// every deadline, every wait and every program asking the time goes through.
/// A multiply by the reciprocal is one instruction, and carrying the fraction
/// between samples holds the error to 8.6 microseconds a day against the
/// crystal's own 8.6 seconds.
const MICROS_PER_TICK: u32 = 1_199_864_032;

fn readPmTimer(p: u16) u32 {
    // 24 bits on this chipset. The upper byte is not guaranteed to be zero on
    // every implementation, so it is masked rather than assumed.
    return @as(u32, @truncate(port.inl(p))) & PM_MASK;
}

/// Two words multiplied into one double word, which on this part is a single
/// instruction rather than the three a 64-bit multiply would take.
fn mulWide(a: u32, b: u32) u64 {
    return @as(u64, a) * @as(u64, b);
}

/// What `delta` ticks come to, given the fraction left over from last time:
/// whole microseconds, and the fraction to carry into the next sample.
fn micronsOf(delta: u32, fraction: u32) struct { micros: u64, fraction: u32 } {
    const advanced = mulWide(delta, MICROS_PER_TICK) + fraction;
    return .{ .micros = advanced >> 32, .fraction = @truncate(advanced) };
}

/// Fold everything the counter has advanced since the last sample into the
/// accumulator.
///
/// Must be called more often than the counter wraps, every 4.69 seconds at
/// 3.579545 MHz, or the time in between is lost. The timer interrupt samples
/// it at 100 Hz, which is a margin of four hundred.
fn samplePmTimer() u64 {
    const now = readPmTimer(pm_timer_port);
    // Unsigned wrapping subtraction, masked back to the counter width: this is
    // the whole wrap handling, and it works for any number of wraps up to one.
    const delta: u32 = (now -% pm_last) & PM_MASK;
    pm_last = now;

    const step = micronsOf(delta, pm_fraction);
    pm_micros += step.micros;
    pm_fraction = step.fraction;
    return pm_micros;
}

const PM_TIMER_HZ: u64 = 3_579_545;

pub fn monotonicMicros() u64 {
    if (pm_timer_port == 0) {
        return @as(u64, @atomicLoad(u32, &ticks, .monotonic)) * TICK_US;
    }

    // Sampling mutates the accumulator, so it cannot race the timer interrupt
    // doing the same thing.
    const was = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(was);
    return samplePmTimer();
}

/// Name of the clock currently in use, for the boot log. Saying which source
/// won matters: the difference between a 10 ms and a 0.3 us resolution clock
/// is visible in everything from scheduling to benchmarks.
pub fn sourceName() []const u8 {
    if (pm_timer_port != 0) return "acpi-pm";
    return "pit";
}

const testing = @import("std").testing;

test "the reciprocal converts ticks the way the division it replaces did" {
    // Counted the exact way, with a remainder, against the fixed point that
    // stands in for it. A whole counter's worth of ticks, at the sizes a
    // sample actually sees, must not part company by a microsecond.
    const steps = [_]u32{ 1, 2, 7, 35_795, 35_796, 100_000, PM_MASK / 2, PM_MASK };
    for (steps) |delta| {
        var fraction: u32 = 0;
        var fast: u64 = 0;

        var remainder: u64 = 0;
        var exact: u64 = 0;

        for (0..64) |_| {
            const step = micronsOf(delta, fraction);
            fast += step.micros;
            fraction = step.fraction;

            const scaled = @as(u64, delta) * 1_000_000 + remainder;
            exact += scaled / PM_TIMER_HZ;
            remainder = scaled % PM_TIMER_HZ;
        }

        const apart = if (fast > exact) fast - exact else exact - fast;
        try testing.expect(apart <= 1);
    }
}

test "a tick is worth what the counter's frequency says" {
    // One second of ticks is one second of microseconds.
    const step = micronsOf(PM_TIMER_HZ, 0);
    try testing.expectEqual(@as(u64, 1_000_000), step.micros);
}
