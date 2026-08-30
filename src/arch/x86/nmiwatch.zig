//! The dead man's switch: an interrupt no `cli` can silence.
//!
//! A P6 performance counter counts unhalted core cycles and delivers its
//! overflow through the local APIC's performance LVT as an NMI, the one
//! delivery that pierces disabled interrupts. Each firing asks a single
//! question: has the timer tick advanced since last time? Yes rearms and
//! leaves. No means the machine is frozen, and the handler is standing on
//! the corpse holding the interrupted program counter, which goes straight
//! to the panic screen.
//!
//! What it cannot catch is itself evidence: a load against a hung bus, or
//! a CPU seized into system management mode, blocks even NMI. A freeze
//! that leaves no panic screen behind is convicted of exactly that class.
//!
//! Not armed under emulation: TCG accepts the counter registers and never
//! counts, an armed watchdog that can never fire is a lie in the boot log.

const console = @import("../../kernel/console.zig");
const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const lapic = @import("lapic.zig");
const panic = @import("../../kernel/panic.zig");
const timer = @import("timer.zig");

/// P6 performance-monitoring registers: the event select and its counter.
const EVTSEL0_MSR: u32 = 0x186;
const PERFCTR0_MSR: u32 = 0xC1;

/// Unhalted core cycles, counted in both rings, interrupt on overflow,
/// counter enabled.
const EventSelect = packed struct(u32) {
    event: u8 = 0x79,
    umask: u8 = 0,
    user: bool = true,
    kernel: bool = true,
    edge: bool = false,
    pin_control: bool = false,
    interrupt: bool = true,
    _21: u1 = 0,
    enable: bool = true,
    invert: bool = false,
    counter_mask: u8 = 0,
};

/// Cycles between firings. The counter is written with this value's two's
/// complement, sign-extended by the hardware, and overflows to zero after
/// exactly this many cycles: roughly two and a half seconds at the target
/// machine's 630 MHz, and still whole seconds on anything this kernel
/// plausibly boots on. Precision is not the point; dead is dead.
const PERIOD_CYCLES: u32 = 1_500_000_000;

var armed = false;
var last_ticks: u64 = 0;

pub fn isArmed() bool {
    return armed;
}

/// Start the watchdog. `emulated` comes from the board identity, because
/// an emulator's counters accept every write and count nothing.
pub fn arm(emulated: bool) void {
    if (emulated) return;
    if (!lapic.active()) return;
    if (!cpu.Features.detect().msr) return;

    last_ticks = timer.tickCount();
    reload();
    cpu.writeMsr(EVTSEL0_MSR, @as(u32, @bitCast(EventSelect{})));
    lapic.armPerformanceNmi();
    armed = true;
    console.info("watchdog", "nmi armed: a frozen machine panics instead of posing", .{});
}

fn reload() void {
    // Two's complement, so the count runs up toward overflow. The hardware
    // sign-extends bit 31 through the counter's full width.
    const preload: u32 = @bitCast(-%@as(i32, @intCast(PERIOD_CYCLES)));
    cpu.writeMsr(PERFCTR0_MSR, preload);
}

/// One firing. True when the watchdog owns this NMI; a stray NMI on an
/// unarmed machine stays the fault path's to report. Does not return when
/// the machine is judged dead.
pub fn onNmi(frame: *idt.Frame) bool {
    if (!armed) return false;

    const ticks = timer.tickCount();
    if (ticks != last_ticks) {
        last_ticks = ticks;
        reload();
        // Delivery masked the performance LVT; unmasking it is the rearm.
        lapic.armPerformanceNmi();
        return true;
    }

    // No tick in an entire period: interrupts are dead and this NMI is the
    // only thing still running. Say where the machine was standing.
    var r = panic.Report{
        .vector = frame.vector,
        .pc = frame.eip,
        .sp = @intFromPtr(frame) + @sizeOf(idt.Frame),
        .fp = frame.ebp,
        .from_user = frame.cs & 3 == 3,
        .message = "watchdog: the timer stopped ticking",
    };
    r.addReg("eax", frame.eax);
    r.addReg("ebx", frame.ebx);
    r.addReg("ecx", frame.ecx);
    r.addReg("edx", frame.edx);
    r.addReg("esi", frame.esi);
    r.addReg("edi", frame.edi);
    panic.report(&r);
}
