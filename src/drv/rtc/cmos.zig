//! CMOS real-time clock.
//!
//! Generic across every PC, which is why it is worth having even though this
//! machine's coin cell is almost certainly flat after nearly two decades. A
//! wrong wall clock is not merely cosmetic: it breaks TLS certificate
//! validation, so the time has to come from somewhere, and SNTP needs a
//! starting point to correct.

const std = @import("std");
const port = @import("../../arch/x86/port.zig");

const ADDRESS = 0x70;
const DATA = 0x71;

const REG_SECONDS = 0x00;
const REG_MINUTES = 0x02;
const REG_HOURS = 0x04;
const REG_DAY = 0x07;
const REG_MONTH = 0x08;
const REG_YEAR = 0x09;
const REG_STATUS_A = 0x0A;
const REG_STATUS_B = 0x0B;

/// Status register A: the update bit is the only one read.
const StatusA = packed struct(u8) {
    _rate: u7 = 0,
    updating: bool = false,
};

/// Status register B: how the clock encodes what it reports.
const StatusB = packed struct(u8) {
    _0: u1 = 0,
    hours_24: bool = false,
    binary: bool = false,
    _rest: u5 = 0,
};

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

fn read(reg: u8) u8 {
    // Bit 7 of the address port is the NMI disable flag; preserving it as zero
    // keeps NMIs enabled, which is what the BIOS left them as.
    port.outb(ADDRESS, reg);
    return port.inb(DATA);
}

fn updating() bool {
    const a: StatusA = @bitCast(read(REG_STATUS_A));
    return a.updating;
}

fn fromBcd(value: u8) u8 {
    return (value & 0x0F) + ((value >> 4) * 10);
}

/// Read the current time.
///
/// The chip updates its registers roughly once a second and the read is not
/// atomic, so a naive read can catch it mid-carry and return 11:59:60. Reading
/// twice and accepting only a matching pair is the standard fix.
pub fn now() DateTime {
    var last = readRaw();
    var attempts: u8 = 0;
    while (attempts < 10) : (attempts += 1) {
        const current = readRaw();
        if (std.meta.eql(current, last)) return current;
        last = current;
    }
    return last;
}

fn readRaw() DateTime {
    var spins: u32 = 0;
    while (updating() and spins < 1_000_000) : (spins += 1) {}

    var dt = DateTime{
        .second = read(REG_SECONDS),
        .minute = read(REG_MINUTES),
        .hour = read(REG_HOURS),
        .day = read(REG_DAY),
        .month = read(REG_MONTH),
        .year = read(REG_YEAR),
    };

    const status_b = read(REG_STATUS_B);
    const b: StatusB = @bitCast(status_b);
    const is_binary = b.binary;
    const is_24_hour = b.hours_24;

    // The 12-hour PM flag lives in bit 7 of the hours register and has to be
    // stripped before any BCD conversion, or it corrupts the digit.
    const pm = !is_24_hour and (dt.hour & 0x80) != 0;
    dt.hour &= 0x7F;

    if (!is_binary) {
        dt.second = fromBcd(dt.second);
        dt.minute = fromBcd(dt.minute);
        dt.hour = fromBcd(dt.hour);
        dt.day = fromBcd(dt.day);
        dt.month = fromBcd(dt.month);
        dt.year = fromBcd(@truncate(dt.year));
    }

    if (pm and dt.hour < 12) dt.hour += 12;
    if (!pm and !is_24_hour and dt.hour == 12) dt.hour = 0;

    // The register holds two digits. There is no century register worth
    // trusting across chipsets, so the window is pinned: this machine cannot
    // predate its own manufacture, and a dead battery reads back as 2000.
    dt.year = if (dt.year >= 70) 1900 + dt.year else 2000 + dt.year;

    return dt;
}

/// True when the clock is obviously not set, a flat coin cell reads as an
/// impossible or epoch date, and anything depending on time should know.
pub fn looksUnset(dt: DateTime) bool {
    return dt.year < 2000 or dt.month == 0 or dt.month > 12 or dt.day == 0 or dt.day > 31;
}
