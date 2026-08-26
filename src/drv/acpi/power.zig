//! Power control: soft-off and reset.

const port = @import("../../arch/x86/port.zig");
const tables = @import("tables.zig");

/// Bit 13 of the PM1 control register commits the sleep type in bits 10-12.
const SLP_EN: u16 = 1 << 13;

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
            const a: u16 = (@as(u16, info.slp_typ_a) << 10) | SLP_EN;
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
