//! Power control: soft-off and reset.

const std = @import("std");
const console = @import("../../kernel/console.zig");
const hal = @import("../../kernel/hal.zig");
const sched = @import("../../kernel/sched.zig");
const tables = @import("tables.zig");
const kbc = @import("../input/i8042.zig");

/// The PM1 control register. Writing `sleep_enable` commits `sleep_type`,
/// and `acpi_mode` says the chipset listens to any of this at all rather
/// than routing power management to the firmware's own handler.
const Pm1Control = packed struct(u16) {
    acpi_mode: bool = false,
    _1: u9 = 0,
    sleep_type: u3 = 0,
    sleep_enable: bool = false,
    _14: u2 = 0,
};

fn pm1(at: u16) Pm1Control {
    return @bitCast(hal.inw(at));
}

/// Hand the machine from legacy mode into ACPI mode.
///
/// Until this happens the sleep registers do nothing: in legacy mode the
/// chipset routes power management to the firmware's own handler and ignores
/// writes to PM1 control. Firmware hands the kernel a machine in legacy mode,
/// which is why a soft-off that works under an emulator, where the fallback
/// ports do the work, does nothing at all on the real one.
///
/// No AML is involved. The command port and the value written to it both come
/// from the FADT, which is why this works long before there is an interpreter.
fn enterAcpiMode(info: tables.Info) bool {
    if (pm1(info.pm1a_control).acpi_mode) return true;
    if (info.smi_command == 0 or info.acpi_enable == 0) return false;

    hal.outb(info.smi_command, info.acpi_enable);

    // Firmware answers in its own time and this runs with interrupts off, so
    // the wait counts spins rather than microseconds: there is no clock to
    // read here that is still advancing.
    var spins: u32 = 0;
    while (spins < 20_000_000) : (spins += 1) {
        if (pm1(info.pm1a_control).acpi_mode) return true;
        std.atomic.spinLoopHint();
    }
    return false;
}

/// Emulator soft-off ports. Tried only after ACPI fails, and harmless on real
/// hardware: each is an unclaimed I/O port there, so the write is discarded.
const EMULATOR_PORTS = [_]struct { port: u16, value: u16 }{
    .{ .port = 0x604, .value = 0x2000 }, // QEMU
    .{ .port = 0xB004, .value = 0x2000 }, // Bochs and older QEMU
    .{ .port = 0x4004, .value = 0x3400 }, // VirtualBox
};

/// Ask the chipset for one of the sleep states the tables named.
///
/// Two writes rather than one, the way ACPICA does it: buggy firmware of this
/// era cannot take SLP_TYP and SLP_EN in the same write, which is one way a
/// perfectly formed sleep request does nothing at all. What is already in the
/// register is carried over, because the SCI_EN bit keeps the chipset in ACPI
/// mode and clearing it mid-request is another.
fn commit(info: tables.Info, state: tables.SleepType) void {
    write(info.pm1a_control, pm1(info.pm1a_control), state.a);
    // The second register exists on chipsets that split the power management
    // block; writing it when absent is harmless.
    if (info.pm1b_control != 0) {
        write(info.pm1b_control, pm1(info.pm1b_control), state.b);
    }
}

fn write(at: u16, held: Pm1Control, typ: u8) void {
    const slp = Pm1Control{
        .acpi_mode = held.acpi_mode,
        .sleep_type = @truncate(typ),
        .sleep_enable = false,
    };
    var go = slp;
    go.sleep_enable = true;

    hal.outw(at, @bitCast(slp));
    hal.outw(at, @bitCast(go));
}

/// Power the machine off. Returns only if every method failed.
pub fn off() void {
    if (tables.get()) |info| {
        if (info.off.found and info.pm1a_control != 0) {
            // Each step says what it is about to do. A machine that stops
            // here stops with the screen still on and nothing else to go on,
            // so the last line printed is the only way to tell which write it
            // was that never came back.
            console.debug("shutdown", "pm1a {x:0>4} = {x:0>4}, s5 type {d}, smi {x:0>4}/{x:0>2}", .{
                info.pm1a_control, hal.inw(info.pm1a_control),
                info.off.a,        info.smi_command,
                info.acpi_enable,
            });

            const in_acpi = enterAcpiMode(info);
            console.debug("shutdown", "acpi mode {}, pm1a now {x:0>4}", .{
                in_acpi, hal.inw(info.pm1a_control),
            });

            commit(info, info.off);

            // Power does not drop instantly; give the hardware time before
            // concluding it did not work. A sleep rather than a spin: the
            // machine is going down, not computing, and the scheduler is up.
            sched.sleepMicros(100_000);
        }
    }

    console.debug("shutdown", "acpi would not sleep; trying the emulator ports", .{});
    for (EMULATOR_PORTS) |p| hal.outw(p.port, p.value);
}

/// Stop the machine with its memory alive, told where it is to come back to.
///
/// Called with the processor's state already written out and the trampoline
/// already at `wake_at`, so the machine may stop between any two of the
/// instructions below. Returning at all means it would not: the caller finds
/// out by being called at all, and nothing has been lost.
pub fn suspendToMemory(wake_at: u32) callconv(.c) void {
    const info = tables.get() orelse return;
    if (!info.suspend_to_memory.found or info.pm1a_control == 0) return;

    // Before the sleep write, and the one thing that must not be skipped: the
    // firmware reads this address out of memory it kept alive, and a machine
    // whose vector was never written wakes with nowhere to go.
    if (!tables.setWakingVector(wake_at)) {
        console.warn("suspend: the firmware's table would not take a waking vector", .{});
        return;
    }
    if (!enterAcpiMode(info)) {
        console.warn("suspend: the chipset would not enter acpi mode", .{});
        return;
    }

    commit(info, info.suspend_to_memory);
}

/// Restart the machine.
///
/// The keyboard controller's reset line is the most widely supported method and
/// needs no tables. The triple fault is the last resort: an empty IDT makes the
/// next interrupt unrecoverable, which every x86 implements as a reset.
pub fn reset() void {
    kbc.resetMachine();

    // The reset line needs a moment to take before the machine is asked, one
    // last time, to leave.
    sched.sleepMicros(10_000);

    hal.resetByTripleFault();
}
