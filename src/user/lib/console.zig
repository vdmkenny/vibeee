//! The console, as a program needs to know it.
//!
//! Its shape, which decides how much fits on a screen and therefore how any
//! full-screen program lays itself out. In `ulib` because three separate
//! places were asking the same question and parsing the same answer, and
//! because a program written in Zig should reach it the same way a program
//! written in C reaches it through `ioctl`.

const info = @import("info.zig");
const str = @import("lib").str;

pub const Size = struct {
    columns: usize,
    rows: usize,

    /// What to assume when nothing answers. The smallest terminal anybody has
    /// ever standardised on, so a layout built against it fits anywhere.
    pub const fallback = Size{ .columns = 80, .rows = 24 };
};

/// How many cells the console has. Asked of the console rather than assumed:
/// a program that drew an 80x24 box on a 100x30 screen would leave a border of
/// stale pixels and have no way to find out.
pub fn size() Size {
    var buf: [64]u8 = @splat(0);
    var it = str.split(info.ask("console", &buf), 'x');

    const columns = str.toUnsigned(it.next() orelse "");
    const rows = str.toUnsigned(it.next() orelse "");
    if (columns == 0 or rows == 0) return Size.fallback;

    return .{ .columns = columns, .rows = rows };
}
