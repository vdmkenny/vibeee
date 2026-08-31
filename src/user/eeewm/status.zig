//! The right end of the bar: what the machine says about itself.
//!
//! A row of indicators laid out from the right edge, each one a fixed width
//! and most of them a picture rather than a word. A network's name is as long
//! as somebody made it and the bar has eight hundred pixels for everything,
//! so what is shown here is an icon and at most a number, and the words are in
//! the menu the icon opens.
//!
//! The layout is arithmetic and lives here rather than in the painter, because
//! the painter and the hit test have to agree about where everything is and
//! two copies of that agree only until one of them is edited.
//!
//! The arithmetic itself is `eui.row`'s and is tested there; what is here is
//! which indicators exist and how wide each one sits.

const std = @import("std");
const draw = @import("eui").draw;
const icons = @import("eui").icon;
const row = @import("eui").row;

const Rect = draw.Rect;

/// What the bar can show, in the order they sit, leftmost first. The clock is
/// last because it is the one thing that is always there and the rightmost
/// thing is the easiest to find.
pub const Indicator = enum {
    network,
    sound,
    battery,
    keymap,
    clock,

    /// How wide this one sits. An icon on its own is the icon plus the space
    /// either side of it; one that carries a number is that much wider.
    pub fn width(self: Indicator) i32 {
        const icon: i32 = @intCast(icons.WIDTH);
        return switch (self) {
            .network, .sound => icon + PAD * 2,
            // The icon, then room for "100%" beside it.
            .battery => icon + GAP + 30 + PAD * 2,
            // Two letters, which is what a keymap is named by.
            .keymap => 18 + PAD * 2,
            .clock => 40 + PAD * 2,
        };
    }

    /// Whether pressing it opens something. The two that only report do not.
    pub fn opensMenu(self: Indicator) bool {
        return switch (self) {
            .network, .sound => true,
            .battery, .keymap, .clock => false,
        };
    }
};

/// Space either side of an indicator's contents, and between an icon and the
/// number beside it.
pub const PAD: i32 = 6;
pub const GAP: i32 = 4;

pub const Slot = struct {
    which: Indicator,
    area: Rect,
};

pub const MAX = std.meta.fields(Indicator).len;

/// Where each of `shown` sits, laid from the right edge of `strip`.
///
/// The arithmetic is `eui.row`'s, so the painter and the hit test read the
/// same rectangles and a narrow screen drops the leftmost indicator rather
/// than drawing two on top of each other.
pub fn place(strip: Rect, shown: []const Indicator, into: []Slot) []Slot {
    var widths: [MAX]i32 = undefined;
    const wanted = @min(shown.len, MAX);
    for (shown[0..wanted], 0..) |which, i| widths[i] = which.width();

    var cells: [MAX]Rect = undefined;
    const placed = row.place(strip, .right, widths[0..wanted], &cells);

    // `row` drops from the far end, so what survived is the tail of what was
    // asked for.
    const dropped = wanted - placed.len;
    for (placed, 0..) |cell, i| into[i] = .{ .which = shown[dropped + i], .area = cell };
    return into[0..placed.len];
}

/// Which indicator is under a point, if any.
pub fn at(slots: []const Slot, x: i32, y: i32) ?Indicator {
    for (slots) |slot| {
        if (slot.area.contains(x, y)) return slot.which;
    }
    return null;
}

/// Where the row begins, so the tabs know how much room they are left.
pub fn leftEdge(strip: Rect, slots: []const Slot) i32 {
    if (slots.len == 0) return strip.right();
    return slots[0].area.x;
}
