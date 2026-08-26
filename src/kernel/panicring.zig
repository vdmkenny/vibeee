//! A panic that survives the reboot.
//!
//! The Eee PC 701 has no serial port, so a fault leaves the machine by
//! photograph. That works for a fault you are watching; it does not work for
//! one that happens while your back is turned, or for a machine that resets
//! itself before you can read the screen.
//!
//! One page of low memory, below the first megabyte where the allocator never
//! reaches and no boot path writes, holds the last panic across a warm reboot.
//! The next boot finds it, puts it in the kernel log, and clears it, so the
//! answer to "what happened overnight" is `log` rather than a camera.
//!
//! Not trusted blindly. Firmware is entitled to use low memory during POST, so
//! the record carries a magic and a checksum, and anything that does not add
//! up is treated as no record at all rather than as a garbled panic.

const std = @import("std");
const hal = @import("hal.zig");

/// Physical page holding the record.
///
/// The whole first megabyte is reserved from the allocator, so nothing here is
/// ever handed out. Choosing which page took some care: 0x7000 looked free and
/// is written twice over before the kernel runs, once by stage1's stack
/// growing down from 0x7C00 and once by stage2's E820 scratch. The map in
/// `boot/stage2.asm` lists what uses what, and this page is named there so the
/// next scratch buffer does not land on it.
///
/// Firmware may still use low memory during POST, which is why the record is
/// checksummed rather than trusted: a clobbered page reads as no record at all.
pub const PHYS: u32 = 0x1000;

/// 'PANC'.
pub const MAGIC: u32 = 0x50414E43;

const PAGE = 4096;

const Header = extern struct {
    magic: u32,
    /// Bytes of text following the header.
    len: u32,
    /// Sum over the text. Firmware clobbering half the page is far more likely
    /// than it happening to leave a valid length behind, so this is what turns
    /// a plausible-looking page into a rejected one.
    checksum: u32,
    /// How many panics this machine has recorded. Survives with the page, so a
    /// machine crashing in a loop says so rather than looking like one crash.
    sequence: u32,
};

pub const CAPACITY = PAGE - @sizeOf(Header);

fn header() *volatile Header {
    return @ptrFromInt(hal.physToVirt(PHYS));
}

fn text() [*]volatile u8 {
    return @ptrFromInt(hal.physToVirt(PHYS) + @sizeOf(Header));
}

fn sum(bytes: []const u8) u32 {
    var out: u32 = 0;
    for (bytes) |b| out = out *% 31 +% b;
    return out;
}

/// Write the record. Called from the panic path, so it must not fail and must
/// not depend on anything that might itself be broken.
pub fn record(payload: []const u8) void {
    const h = header();
    // Read the old sequence before overwriting, so a crash loop counts up.
    const previous = if (h.magic == MAGIC) h.sequence else 0;

    const n = @min(payload.len, CAPACITY);
    const dst = text();
    for (0..n) |i| dst[i] = payload[i];

    h.len = n;
    h.checksum = sum(payload[0..n]);
    h.sequence = previous +| 1;
    // Magic last: a record is only valid once everything else in it is.
    h.magic = MAGIC;
}

pub const Previous = struct {
    text: []const u8,
    /// How many panics have been recorded on this machine, including this one.
    sequence: u32,
};

/// Take the record left by the last boot, if there is one.
///
/// Cleared as it is read, so it is reported once rather than on every boot
/// until the next fault overwrites it.
pub fn take(out: []u8) ?Previous {
    const h = header();
    if (h.magic != MAGIC) return null;

    const len = h.len;
    const sequence = h.sequence;
    if (len == 0 or len > CAPACITY) {
        clear();
        return null;
    }

    const n = @min(len, out.len);
    const src = text();
    for (0..n) |i| out[i] = src[i];

    // Checked over what was recorded rather than over what fitted, so a
    // caller with a small buffer does not reject a good record.
    var whole: u32 = 0;
    for (0..len) |i| whole = whole *% 31 +% src[i];

    clear();
    if (whole != h.checksum) return null;
    return .{ .text = out[0..n], .sequence = sequence };
}

fn clear() void {
    header().magic = 0;
}
