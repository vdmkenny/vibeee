//! Timer sources.
//!
//! The PIT is the bootstrap clock: always present, needs no ACPI tables, and
//! gives us a periodic interrupt for preemption. It is not the long-term
//! answer — reading it costs a port round-trip, and the research shows this
//! platform has better options — so `monotonicMicros` prefers, in order:
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

const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const port = @import("port.zig");
const sched = @import("../../kernel/sched.zig");

const PIT_CHANNEL0 = 0x40;
const PIT_COMMAND = 0x43;

/// The 8253/8254 input frequency, 1.193182 MHz.
const PIT_HZ: u32 = 1_193_182;

/// 100 Hz: a 10 ms tick. Fine enough for scheduling on a single 630 MHz core,
/// coarse enough that the interrupt cost stays negligible.
pub const TICK_HZ: u32 = 100;
pub const TICK_US: u64 = 1_000_000 / TICK_HZ;

/// Written by the interrupt handler, read by everything else. Accessed
/// atomically, not because of SMP — there is one core — but because a plain
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
/// samples a second do not lose a microsecond each.
var pm_remainder: u64 = 0;

pub fn init() void {
    const divisor: u16 = @intCast(PIT_HZ / TICK_HZ);

    // Channel 0, lobyte then hibyte, mode 3 (square wave), binary.
    port.outb(PIT_COMMAND, 0x36);
    port.outb(PIT_CHANNEL0, @truncate(divisor & 0xFF));
    port.outb(PIT_CHANNEL0, @truncate(divisor >> 8));

    idt.setHandler(idt.IRQ_BASE + 0, onTick);
    idt.setPicMask(0, false);
}

fn onTick(_: *idt.Frame) void {
    _ = @atomicRmw(u32, &ticks, .Add, 1, .monotonic);

    // Sample here rather than relying on something above happening to ask the
    // time: the PM timer's 24-bit counter wraps every 4.69 seconds, and a wrap
    // that passes unsampled is time silently lost from the monotonic clock.
    // Interrupts are already off inside the handler.
    if (pm_timer_port != 0) _ = samplePmTimer();

    sched.onTick();
}

pub fn tickCount() u64 {
    return @atomicLoad(u32, &ticks, .monotonic);
}

/// Adopt the ACPI PM timer as the monotonic source.
///
/// The accumulator continues from wherever the PIT had reached, so the clock
/// does not jump when the source changes underneath it.
pub fn setPmTimerPort(p: u16) void {
    const was = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(was);

    pm_micros = @as(u64, @atomicLoad(u32, &ticks, .monotonic)) * TICK_US;
    pm_remainder = 0;
    pm_last = readPmTimer(p);
    pm_timer_port = p;
}

const PM_MASK: u32 = 0x00FF_FFFF;

fn readPmTimer(p: u16) u32 {
    // 24 bits on this chipset. The upper byte is not guaranteed to be zero on
    // every implementation, so it is masked rather than assumed.
    return @as(u32, @truncate(port.inl(p))) & PM_MASK;
}

/// Fold everything the counter has advanced since the last sample into the
/// accumulator.
///
/// Must be called more often than the counter wraps — every 4.69 seconds at
/// 3.579545 MHz — or the time in between is lost. The timer interrupt samples
/// it at 100 Hz, which is a margin of four hundred.
fn samplePmTimer() u64 {
    const now = readPmTimer(pm_timer_port);
    // Unsigned wrapping subtraction, masked back to the counter width: this is
    // the whole wrap handling, and it works for any number of wraps up to one.
    const delta: u64 = (now -% pm_last) & PM_MASK;
    pm_last = now;

    const scaled = delta * 1_000_000 + pm_remainder;
    pm_micros += scaled / PM_TIMER_HZ;
    pm_remainder = scaled % PM_TIMER_HZ;
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
