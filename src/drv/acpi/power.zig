//! Power control: soft-off and reset.

const console = @import("../../kernel/console.zig");
const port = @import("../../arch/x86/port.zig");
const tables = @import("tables.zig");

/// Bit 13 of the PM1 control register commits the sleep type in bits 10-12.
const SLP_EN: u16 = 1 << 13;

/// Bit 0 of the same register: set when the chipset is in ACPI mode rather
/// than the legacy mode firmware leaves it in.
const SCI_EN: u16 = 1 << 0;

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
    if (port.inw(info.pm1a_control) & SCI_EN != 0) return true;
    if (info.smi_command == 0 or info.acpi_enable == 0) return false;

    port.outb(info.smi_command, info.acpi_enable);

    // Firmware answers in its own time and this runs with interrupts off, so
    // the wait counts spins rather than microseconds: there is no clock to
    // read here that is still advancing.
    var spins: u32 = 0;
    while (spins < 20_000_000) : (spins += 1) {
        if (port.inw(info.pm1a_control) & SCI_EN != 0) return true;
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

            const a: u16 = (@as(u16, info.slp_typ_a) << 10) | SLP_EN;
            console.debug("shutdown", "sleeping with {x:0>4}", .{a});
            port.outw(info.pm1a_control, a);

            // The second register exists on chipsets that split the power
            // management block; writing it when absent is harmless.
            if (info.pm1b_control != 0) {
                const b: u16 = (@as(u16, info.slp_typ_b) << 10) | SLP_EN;
                port.outw(info.pm1b_control, b);
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
