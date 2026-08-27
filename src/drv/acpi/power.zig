//! Power control: soft-off and reset.

const console = @import("../../kernel/console.zig");
const port = @import("../../arch/x86/port.zig");
const tables = @import("tables.zig");

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
    return @bitCast(port.inw(at));
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

    port.outb(info.smi_command, info.acpi_enable);

    // Firmware answers in its own time and this runs with interrupts off, so
    // the wait counts spins rather than microseconds: there is no clock to
    // read here that is still advancing.
    var spins: u32 = 0;
    while (spins < 20_000_000) : (spins += 1) {
        if (pm1(info.pm1a_control).acpi_mode) return true;
        asm volatile ("pause");
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

/// Power the machine off. Returns only if every method failed.
pub fn off() void {
    if (tables.get()) |info| {
        if (info.s5_found and info.pm1a_control != 0) {
            // Each step says what it is about to do. A machine that stops
            // here stops with the screen still on and nothing else to go on,
            // so the last line printed is the only way to tell which write it
            // was that never came back.
            console.debug("shutdown", "pm1a {x:0>4} = {x:0>4}, s5 type {d}, smi {x:0>4}/{x:0>2}", .{
                info.pm1a_control,  port.inw(info.pm1a_control),
                info.slp_typ_a,     info.smi_command,
                info.acpi_enable,
            });

            const in_acpi = enterAcpiMode(info);
            console.debug("shutdown", "acpi mode {}, pm1a now {x:0>4}", .{
                in_acpi, port.inw(info.pm1a_control),
            });

            const a = Pm1Control{ .sleep_type = @truncate(info.slp_typ_a), .sleep_enable = true };
            console.debug("shutdown", "sleeping with {x:0>4}", .{@as(u16, @bitCast(a))});
            port.outw(info.pm1a_control, @bitCast(a));

            // The second register exists on chipsets that split the power
            // management block; writing it when absent is harmless.
            if (info.pm1b_control != 0) {
                const b = Pm1Control{ .sleep_type = @truncate(info.slp_typ_b), .sleep_enable = true };
                port.outw(info.pm1b_control, @bitCast(b));
            }

            // Power does not drop instantly; give the hardware time before
            // concluding it did not work.
            var spins: u32 = 0;
            while (spins < 10_000_000) : (spins += 1) asm volatile ("pause");
        }
    }

    console.debug("shutdown", "acpi would not sleep; trying the emulator ports", .{});
    for (EMULATOR_PORTS) |p| port.outw(p.port, p.value);
}

/// Restart the machine.
///
/// The keyboard controller's reset line is the most widely supported method and
/// needs no tables. The triple fault is the last resort: an empty IDT makes the
/// next interrupt unrecoverable, which every x86 implements as a reset.
pub fn reset() void {
    var spins: u32 = 0;
    while (port.inb(0x64) & 0x02 != 0 and spins < 100_000) : (spins += 1) {}
    port.outb(0x64, 0xFE);

    spins = 0;
    while (spins < 1_000_000) : (spins += 1) asm volatile ("pause");

    const null_idt = extern struct { limit: u16 align(1), base: u32 align(1) }{
        .limit = 0,
        .base = 0,
    };
    asm volatile (
        \\ lidt (%[idt])
        \\ int $3
        :
        : [idt] "r" (&null_idt),
    );
}
