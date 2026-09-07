//! The pair of 8259 interrupt controllers.
//!
//! What delivered every interrupt on a PC before the IOAPIC, and what still
//! delivers them on a machine whose IOAPIC the firmware did not describe.
//! Even where the IOAPIC is used these are set up and then masked: a line
//! left as the firmware had it can deliver a stray interrupt at a vector
//! this kernel has given another meaning, which arrives as a fault nothing
//! can explain.
//!
//! Two of them, the second reaching the CPU through the first one's line
//! two. That cascade is the one thing a caller must not have to remember,
//! so it is remembered here.
//!
//! Here rather than in `idt.zig` because it is a device: the LAPIC and the
//! IOAPIC each have their own file, and this had its ports written out in
//! four places, its data ports named in one of them and typed as numbers
//! in the others.

const port = @import("port.zig");

/// The first controller answers lines 0 to 7, the second 8 to 15.
const Chip = struct {
    command: u16,
    data: u16,

    const first = Chip{ .command = 0x20, .data = 0x21 };
    const second = Chip{ .command = 0xA0, .data = 0xA1 };

    /// Which chip answers for a line, and which of its eight it is.
    fn of(line: u8) struct { chip: Chip, bit: u3 } {
        return .{
            .chip = if (line < 8) first else second,
            .bit = @truncate(line & 7),
        };
    }
};

/// Which line of the first controller the second one reaches the CPU on.
const CASCADE_LINE: u8 = 2;

/// The first initialisation word: what a caller is starting, and how much
/// of the sequence follows.
const Icw1 = packed struct(u8) {
    /// A fourth word follows this sequence.
    icw4: bool = false,
    /// One controller rather than a pair.
    single: bool = false,
    _2: u1 = 0,
    level_triggered: bool = false,
    /// The bit that says this byte is an initialisation word at all.
    initialise: bool = true,
    _5: u3 = 0,
};

/// The fourth: how the controller talks to this processor.
const Icw4 = packed struct(u8) {
    /// The 8086 way, which is every processor since.
    mode_8086: bool = true,
    /// The controller clears its own in-service bit. Not wanted: this
    /// kernel says when an interrupt is finished.
    auto_eoi: bool = false,
    _2: u2 = 0,
    /// Buffered and fully-nested modes, neither of which this uses.
    buffered: bool = false,
    _5: u3 = 0,
};

/// End of interrupt: the word that retires the highest in-service line.
const END_OF_INTERRUPT: u8 = 0x20;

/// Point the two controllers at `base` and `base + 8`.
///
/// The vectors they arrive at by default are the ones the processor uses
/// for its own faults, so a legacy interrupt would arrive as a divide
/// error or a general protection fault. Moving them is the first thing any
/// kernel does.
pub fn remap(base: u8) void {
    const start = Icw1{ .icw4 = true };
    const mode = Icw4{};

    write(Chip.first.command, @bitCast(start));
    write(Chip.second.command, @bitCast(start));

    write(Chip.first.data, base);
    write(Chip.second.data, base + 8);

    // The third word says how the two are wired to each other: the first
    // names the line its partner is on as a bit, the second names the same
    // line as a number.
    write(Chip.first.data, @as(u8, 1) << @truncate(CASCADE_LINE));
    write(Chip.second.data, CASCADE_LINE);

    write(Chip.first.data, @bitCast(mode));
    write(Chip.second.data, @bitCast(mode));
}

/// Stop every line on both controllers.
pub fn maskAll() void {
    port.outb(Chip.first.data, 0xFF);
    port.outb(Chip.second.data, 0xFF);
}

/// Let a line through, or stop it.
pub fn setMask(line: u8, masked: bool) void {
    const at = Chip.of(line);
    const bit = @as(u8, 1) << at.bit;

    var mask = port.inb(at.chip.data);
    if (masked) mask |= bit else mask &= ~bit;
    port.outb(at.chip.data, mask);

    // The second controller reaches the CPU through the first one's line
    // two. Opening a line on it achieves nothing while that cascade is
    // shut, so it is opened here rather than left for every caller.
    if (!masked and line >= 8) setMask(CASCADE_LINE, false);
}

/// Say an interrupt is finished. The second controller is told first: it
/// reports through the first, which cannot retire the cascade until its
/// partner has retired the line behind it.
pub fn endOfInterrupt(line: u8) void {
    if (line >= 8) port.outb(Chip.second.command, END_OF_INTERRUPT);
    port.outb(Chip.first.command, END_OF_INTERRUPT);
}

/// A write to a controller, with the pause it needs between words.
///
/// These chips predate the bus they sit on and cannot answer back to back;
/// the wait is a write to a port nothing uses, which costs a bus cycle.
fn write(at: u16, value: u8) void {
    port.outb(at, value);
    port.ioWait();
}
