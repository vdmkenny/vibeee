//! ARM926EJ-S skeleton: entry, vectors, and the first byte on the wire.
//!
//! Step 4.1 of design/12-arm-port.md, and nothing more. QEMU's versatilepb
//! jumps into `_start` with the MMU off and IRQs masked; this module copies a
//! vector table to address zero, brings up the PL011 and proves the console
//! speaks. It is deliberately not the kernel: `kmain` and the HAL arrive in
//! the later steps, this file is the boot half only.
//!
//! The rules the port lives by (design/12-arm-port.md §3), stated where they
//! bite: the device is a packed struct, the vector copy is `@memcpy`, and the
//! only assembly is what no Zig function exists for: the exception vectors,
//! and the first stack and bss setup that must happen before any Zig can run.

const std = @import("std");
const lib = @import("lib");
const logo = lib.logo;

// ---------------------------------------------------------------------------
// Vectors, as data.
//
// The instructions below are copied to address zero by `installVectors`, not
// executed where the linker put them. Until that copy runs, a fault lands in
// them where the loader left them and loops, which is the diagnosable failure
// the panic screen is for on x86.
// ---------------------------------------------------------------------------
comptime {
    asm (
        \\.section .vectors, "ax", %progbits
        \\.align 4
        \\.global arm_vectors_start
        \\arm_vectors_start:
        \\  b vibeeeEntry        @ reset
        \\  b .                  @ undefined instruction
        \\  b .                  @ software interrupt
        \\  b .                  @ prefetch abort
        \\  b .                  @ data abort
        \\  b .                  @ reserved
        \\  b .                  @ irq
        \\  b .                  @ fiq
        \\.global arm_vectors_end
        \\arm_vectors_end:
        \\  .ltorg
        \\
        \\@ Entry. QEMU starts the machine in SVC mode with interrupts masked,
        \\@ and jumps to _start. This is the part no Zig function exists for:
        \\@ setting the stack pointer, and clearing the bss before Zig runs,
        \\@ because Zig state itself lives in the bss.
        \\.section .text.boot, "ax", %progbits
        \\.align 4
        \\.global _start
        \\_start:
        \\vibeeeEntry:
        \\  ldr sp, =stack_top
        \\  ldr r0, =__bss_start
        \\  ldr r1, =__bss_end
        \\  mov r2, #0
        \\1:
        \\  cmp r0, r1
        \\  strne r2, [r0], #4
        \\  bne 1b
        \\  bl armMain
        \\2:
        \\  b 2b
        \\  .ltorg
    );
}

/// The boundary of the vector table, from the assembly above. Taking the
/// address of an extern declaration is the whole point: the table's size is
/// the difference, so the copy cannot drift from the table.
extern const arm_vectors_start: u8;
extern const arm_vectors_end: u8;

/// Copy the vectors to address zero, where the CPU looks for them. `@memcpy`
/// rather than assembly because copying is a library call; only the table's
/// contents had to be instructions.
fn installVectors() void {
    const src: [*]const u8 = @ptrCast(&arm_vectors_start);
    const len = @intFromPtr(&arm_vectors_end) - @intFromPtr(&arm_vectors_start);
    // `allowzero` because address zero is exactly where the CPU looks for the
    // vectors; the pointer type saying so is what keeps the compiler honest
    // about every other zero the code might produce.
    const dest: [*]allowzero u8 = @ptrFromInt(0);
    @memcpy(dest[0..len], src[0..len]);
}

// ---------------------------------------------------------------------------
// The PL011 console, UART0 on versatilepb.
//
// A packed struct so the offsets are the declaration: the compiler checks the
// register block is laid out as the part expects, and a write reads as what it
// permits rather than as an offset to decode. Only the fields this skeleton
// touches are named; the pads hold the others' places.
// ---------------------------------------------------------------------------
const Uart = packed struct {
    dr: u32, // 0x000 data
    rsr_ecr: u32, // 0x004 receive status / error clear
    _pad0: u32, // 0x008
    _pad1: u32, // 0x00c
    _pad2: u32, // 0x010
    _pad3: u32, // 0x014
    fr: u32, // 0x018 flags
    _pad4: u32, // 0x01c
    ilpr: u32, // 0x020
    ibrd: u32, // 0x024 integer baud divisor
    fbrd: u32, // 0x028 fractional baud divisor
    lcrh: u32, // 0x02c line control
    cr: u32, // 0x030 control
};

comptime {
    if (@offsetOf(Uart, "fr") != 0x18) @compileError("Uart.fr is not at 0x18");
    if (@offsetOf(Uart, "cr") != 0x30) @compileError("Uart.cr is not at 0x30");
    if (@sizeOf(Uart) != 0x38) @compileError(std.fmt.comptimePrint("Uart is {x} bytes, not 0x38", .{@sizeOf(Uart)}));
}

const UART0 = 0x101f_1000;

const FR_TXFF: u32 = 1 << 5; // transmit fifo full
const FR_RXFE: u32 = 1 << 4; // receive fifo empty

/// Volatile because the device writes it too: a read that the compiler hoists
/// out of the wait loop waits on a frozen value forever.
const uart: *volatile Uart = @ptrFromInt(UART0);

fn initUart() void {
    // Off while the line parameters change. QEMU's PL011 resets with the
    // transmitter enabled; the real part does not, and a skeleton should not
    // depend on which one is hosting it.
    uart.cr = 0;
    // 24 MHz uartclk, 115200 baud: 24_000_000 / (16 * 115_200) = 13.02.
    uart.ibrd = 13;
    uart.fbrd = 1;
    uart.lcrh = 0x60; // 8 data bits, fifos on
    uart.cr = 0x301; // uarten | txe | rxe
}

fn putByte(c: u8) void {
    while (uart.fr & FR_TXFF != 0) {}
    uart.dr = c;
}

fn putStr(s: []const u8) void {
    for (s) |c| putByte(c);
}

fn armPanic(msg: []const u8, _: ?usize) noreturn {
    // Idempotent: a panic may be the first thing that reaches this file, and
    // the very case a panic is for is one where the console may not be up.
    initUart();
    putStr("PANIC: ");
    putStr(msg);
    putByte('\n');
    while (true) {}
}

pub const panic = std.debug.FullPanic(armPanic);

export fn armMain() callconv(.c) noreturn {
    installVectors();
    initUart();

    for (logo.lines) |line| {
        putStr(line);
        putByte('\n');
    }
    putStr("vibeee arm skeleton: uart ok, vectors installed\n");
    putStr("type, and the machine answers (nothing else is written yet)\n\n");

    // The echo loop is the idle: proving the wire both ways is what step 4.1
    // owes, and nothing else exists to spend the CPU on yet.
    while (true) {
        if (uart.fr & FR_RXFE == 0) {
            const c: u8 = @truncate(uart.dr);
            putByte(c);
            if (c == '\r') putByte('\n');
        }
    }
}
