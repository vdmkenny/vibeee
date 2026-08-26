//! 16550 UART.
//!
//! The target machine has no serial port. This driver exists anyway, for two
//! reasons that both pay for its eighty lines many times over:
//!
//!   * **QEMU has one.** Mirroring the console to it turns kernel debugging
//!     from screenshot archaeology into readable, greppable, scrollable text.
//!   * **Other machines have one.** A generic netbook or development board is
//!     far easier to bring up when the very first boot can talk.
//!
//! Probed rather than assumed: a port that is not there reads back 0xFF, and
//! the loopback self-test below distinguishes a real UART from a floating bus.

const std = @import("std");
const port = @import("../../arch/x86/port.zig");

/// Standard PC port assignments. COM1 first because that is where everything
/// looks by default.
const CANDIDATES = [_]u16{ 0x3F8, 0x2F8, 0x3E8, 0x2E8 };

const REG_DATA = 0;
const REG_INT_ENABLE = 1;
const REG_DIVISOR_LOW = 0;
const REG_DIVISOR_HIGH = 1;
const REG_FIFO_CTRL = 2;
const REG_LINE_CTRL = 3;
const REG_MODEM_CTRL = 4;
const REG_LINE_STATUS = 5;

const LSR_TX_EMPTY: u8 = 1 << 5;
const LCR_DLAB: u8 = 1 << 7;
const LCR_8N1: u8 = 0x03;

var base: ?u16 = null;

/// 115200 baud: divisor 1 from the 115200 Hz base clock.
const DIVISOR: u16 = 1;

fn configure(io: u16) void {
    port.outb(io + REG_INT_ENABLE, 0x00); // polled output only
    port.outb(io + REG_LINE_CTRL, LCR_DLAB);
    port.outb(io + REG_DIVISOR_LOW, @truncate(DIVISOR));
    port.outb(io + REG_DIVISOR_HIGH, @truncate(DIVISOR >> 8));
    port.outb(io + REG_LINE_CTRL, LCR_8N1);
    port.outb(io + REG_FIFO_CTRL, 0xC7); // enable and clear FIFOs, 14-byte trigger
    port.outb(io + REG_MODEM_CTRL, 0x0B); // DTR, RTS, OUT2
}

/// Put the UART in loopback mode and check a byte comes back.
///
/// Reading a register is not enough to prove a UART is present: an absent port
/// reads 0xFF, and some chipsets float. Loopback proves something is actually
/// answering.
fn probe(io: u16) bool {
    configure(io);

    port.outb(io + REG_MODEM_CTRL, 0x1E); // loopback on
    port.outb(io + REG_DATA, 0xAE);
    const echoed = port.inb(io + REG_DATA);
    port.outb(io + REG_MODEM_CTRL, 0x0B); // loopback off

    return echoed == 0xAE;
}

pub fn init() ?u16 {
    for (CANDIDATES) |io| {
        if (probe(io)) {
            base = io;
            configure(io);
            return io;
        }
    }
    return null;
}

pub fn present() bool {
    return base != null;
}

fn putByte(io: u16, byte: u8) void {
    // Bounded wait: a UART with no reader attached still drains, but a
    // misconfigured one must not hang the machine that is trying to report why.
    var spins: u32 = 0;
    while (port.inb(io + REG_LINE_STATUS) & LSR_TX_EMPTY == 0 and spins < 100_000) : (spins += 1) {}
    port.outb(io + REG_DATA, byte);
}

/// Write bytes, translating bare newlines for terminals that expect CRLF.
pub fn write(bytes: []const u8) void {
    const io = base orelse return;
    for (bytes) |b| {
        if (b == '\n') putByte(io, '\r');
        putByte(io, b);
    }
}
