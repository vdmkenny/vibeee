//! The power-management no-touch ranges, as the early probe published them.
//!
//! The kernel identified the machine and named the ranges through `sysinfo`;
//! this module reads the answer once and serves every overlap question from
//! the copy, so asking is cheap enough for a per-access check. No machine
//! knowledge lives here, and none of it reaches a driver that was not asked.

const std = @import("std");
const sys = @import("sys");

const Range = struct { base: u16, len: u16 };

var ranges: [4]Range = undefined;
var range_count: usize = 0;
var loaded = false;

/// Base and length pairs in hex; how many the kernel sends is its business,
/// so the parse reads pairs until the text runs out.
fn load() void {
    if (loaded) return;
    loaded = true;

    var buf: [48]u8 = undefined;
    const n = sys.sysinfo("acpi.pm", &buf);
    if (n <= 0) return;
    const text = buf[0..@intCast(n)];

    var words = std.mem.splitScalar(u8, text, ' ');
    while (words.next()) |base_word| {
        const len_word = words.next() orelse return;
        const base = std.fmt.parseUnsigned(u16, base_word, 16) catch continue;
        const len = std.fmt.parseUnsigned(u16, len_word, 16) catch continue;
        if (len == 0 or range_count == ranges.len) continue;
        ranges[range_count] = .{ .base = base, .len = len };
        range_count += 1;
    }
}

/// Whether `[base, base+len)` overlaps any published power-management range.
pub fn overlapsPm(base: u16, len: u16) bool {
    load();
    const lo: u32 = base;
    const hi: u32 = lo + len;
    for (ranges[0..range_count]) |range| {
        const rlo: u32 = range.base;
        const rhi: u32 = rlo + range.len;
        if (lo < rhi and rlo < hi) return true;
    }
    return false;
}
