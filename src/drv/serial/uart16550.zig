//! 16550 UART.
//!
//! The target machine has no serial port. This driver exists anyway, for two
//! reasons that both pay for its eighty lines many times over:
//!
//!   * **QEMU has one.** Mirroring the console to it turns kernel output
//!     from screenshot archaeology into readable, greppable, scrollable text.
//!   * **Other machines have one.** A generic netbook or development board is
//!     far easier to bring up when the very first boot can talk.
//!
//! Probed rather than assumed: a port that is not there reads back 0xFF, and
//! the loopback self-test below distinguishes a real UART from a floating bus.

const hal = @import("../../kernel/hal.zig");

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

/// Line status: the transmit-empty bit is the only one read.
const LineStatus = packed struct(u8) {
    _low: u5 = 0,
    tx_empty: bool = false,
    _high: u2 = 0,
};

/// Line control. The divisor latch bit repurposes the two data registers as
/// the baud divisor while set.
const LCR_DLAB: u8 = 1 << 7;
const LCR_8N1: u8 = 0x03;

var base: ?u16 = null;

/// 115200 baud: divisor 1 from the 115200 Hz base clock.
const DIVISOR: u16 = 1;

fn configure(io: u16) void {
    hal.outb(io + REG_INT_ENABLE, 0x00); // polled output only
    hal.outb(io + REG_LINE_CTRL, LCR_DLAB);
    hal.outb(io + REG_DIVISOR_LOW, @truncate(DIVISOR));
    hal.outb(io + REG_DIVISOR_HIGH, @truncate(DIVISOR >> 8));
    hal.outb(io + REG_LINE_CTRL, LCR_8N1);
    hal.outb(io + REG_FIFO_CTRL, 0xC7); // enable and clear FIFOs, 14-byte trigger
    hal.outb(io + REG_MODEM_CTRL, 0x0B); // DTR, RTS, OUT2
}

/// Put the UART in loopback mode and check a byte comes back.
///
/// Reading a register is not enough to prove a UART is present: an absent port
/// reads 0xFF, and some chipsets float. Loopback proves something is actually
/// answering.
fn probe(io: u16) bool {
    configure(io);

    hal.outb(io + REG_MODEM_CTRL, 0x1E); // loopback on
    hal.outb(io + REG_DATA, 0xAE);
    const echoed = hal.inb(io + REG_DATA);
    hal.outb(io + REG_MODEM_CTRL, 0x0B); // loopback off

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
    while (spins < 100_000) : (spins += 1) {
        const line: LineStatus = @bitCast(hal.inb(io + REG_LINE_STATUS));
        if (line.tx_empty) break;
    }
    hal.outb(io + REG_DATA, byte);
}

/// Write bytes, translating bare newlines for terminals that expect CRLF.
pub fn write(bytes: []const u8) void {
    const io = base orelse return;
    for (bytes) |b| {
        if (b == '\n') putByte(io, '\r');
        putByte(io, b);
    }
}
