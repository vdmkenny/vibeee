//! The power-management no-touch ranges, as the early probe published them.
//!
//! The kernel identified the machine and named the ranges through `sysinfo`;
//! this module only reads the answer. No machine knowledge lives here, and
//! none of it reaches a driver that was not asked.

const std = @import("std");
const sys = @import("sys");

/// Whether `[base, base+len)` overlaps any published power-management
/// range. Base and length pairs in hex; how many the kernel sends is its
/// business, so the loop reads pairs until the text runs out.
pub fn overlapsPm(base: u16, len: u16) bool {
    var buf: [48]u8 = undefined;
    const n = sys.sysinfo("acpi.pm", &buf);
    if (n <= 0) return false;
    const text = buf[0..@intCast(n)];

    var words = std.mem.splitScalar(u8, text, ' ');
    while (words.next()) |base_word| {
        const len_word = words.next() orelse return false;
        const rbase = std.fmt.parseUnsigned(u16, base_word, 16) catch continue;
        const rlen = std.fmt.parseUnsigned(u16, len_word, 16) catch continue;
        if (base < rbase + rlen and rbase < base + len) return true;
    }
    return false;
}
