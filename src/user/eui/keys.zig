//! The keys, named, along the bottom of a window.
//!
//! A program driven from the keyboard has to say so somewhere, and the row
//! along the bottom is where every such program has said it since function
//! keys had labels printed above them. The file manager, the editor, the
//! viewer and the launcher all want the same row, which is why the shape is
//! here and not in any of them.
//!
//! A key is a chip in the accent with the label beside it, so the chord and
//! what it does read as one thing and the eye can skip along the row. What
//! does not fit is dropped rather than squeezed: half a word is worse than no
//! word, and the keys are ordered so the first ones are the ones worth
//! keeping.
//!
//! The placement is pure and tested here; the painting is the surface's.

const std = @import("std");
const draw = @import("draw.zig");
const theme = @import("theme.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

/// Most keys one row names. Beyond this the row is a legend nobody reads.
pub const MAX = 10;

pub const Key = struct {
    /// What is pressed, as the keyboard has it: "Tab", "F5", "Esc".
    key: []const u8,
    /// What it does, in one word where one word will do.
    label: []const u8,
};

/// Where one named key sits, once it is known to fit.
pub const Placed = struct {
    chip: Rect,
    /// Where the label starts, to the right of the chip.
    label_x: i32,
    key: []const u8,
    label: []const u8,
};

/// How wide a named key needs, chip and label and the air after it.
pub fn width(entry: Key) i32 {
    const t = theme.current();
    return chipWidth(entry.key) + t.padding + Surface.textWidth(entry.label) + t.menu_padding;
}

fn chipWidth(key: []const u8) i32 {
    return Surface.textWidth(key) + theme.current().padding;
}

/// Place as many keys as fit in `area`, left to right, stopping at the first
/// one that would run past `limit`.
///
/// `limit` is where the row must stop, which is not always its right edge: a
/// count or a message often sits at the other end, and a key drawn under it
/// is two things in one place.
pub fn place(area: Rect, limit: i32, entries: []const Key, into: []Placed) []Placed {
    const t = theme.current();
    var n: usize = 0;
    var x = area.x + t.padding;

    for (entries) |entry| {
        if (n == into.len) break;

        const chip = Rect{
            .x = x,
            .y = area.y + t.padding,
            .w = chipWidth(entry.key),
            .h = @max(0, area.h - t.padding * 2),
        };
        const label_x = chip.right() + t.padding;
        if (label_x + Surface.textWidth(entry.label) > limit) break;

        into[n] = .{ .chip = chip, .label_x = label_x, .key = entry.key, .label = entry.label };
        n += 1;
        x = label_x + Surface.textWidth(entry.label) + t.menu_padding;
    }

    return into[0..n];
}

/// The whole row: the ground, the rule above it, and the keys that fit.
///
/// Returns where the row stopped, so a caller with something to say on the
/// same line knows what is left.
pub fn paint(surface: Surface, area: Rect, entries: []const Key, limit: i32) i32 {
    const t = theme.current();

    surface.fill(area, t.bar);
    surface.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, t.line);

    var buf: [MAX]Placed = undefined;
    const shown = place(area, limit, entries, &buf);

    const baseline = area.y + @divTrunc(area.h - Surface.textHeight(), 2);
    for (shown) |one| {
        surface.fill(one.chip, t.accent);
        surface.textCentred(one.chip, one.key, t.accent_text);
        surface.text(one.label_x, baseline, one.label, t.bar_text);
    }

    if (shown.len == 0) return area.x + t.padding;
    const last = shown[shown.len - 1];
    return last.label_x + Surface.textWidth(last.label) + t.menu_padding;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "keys are placed left to right, each after the last" {
    const area = Rect{ .x = 0, .y = 100, .w = 800, .h = 22 };
    const entries = [_]Key{
        .{ .key = "Tab", .label = "pane" },
        .{ .key = "Ret", .label = "open" },
        .{ .key = "F5", .label = "copy" },
    };

    var buf: [MAX]Placed = undefined;
    const shown = place(area, area.right(), &entries, &buf);
    try testing.expectEqual(@as(usize, 3), shown.len);

    for (shown, 0..) |one, i| {
        try testing.expect(one.label_x > one.chip.right());
        if (i > 0) try testing.expect(one.chip.x > shown[i - 1].chip.x);
        try testing.expect(one.chip.y >= area.y);
        try testing.expect(one.chip.bottom() <= area.bottom());
    }
}

test "what does not fit is dropped, not squeezed" {
    const entries = [_]Key{
        .{ .key = "Tab", .label = "pane" },
        .{ .key = "Ret", .label = "open" },
        .{ .key = "F5", .label = "copy" },
        .{ .key = "F6", .label = "move" },
    };

    const narrow = Rect{ .x = 0, .y = 0, .w = 90, .h = 22 };
    var buf: [MAX]Placed = undefined;
    const shown = place(narrow, narrow.right(), &entries, &buf);

    try testing.expect(shown.len < entries.len);
    for (shown) |one| {
        try testing.expect(one.label_x + Surface.textWidth(one.label) <= narrow.right());
    }
}

test "the limit is where the row stops, not the edge" {
    const area = Rect{ .x = 0, .y = 0, .w = 800, .h = 22 };
    const entries = [_]Key{
        .{ .key = "Tab", .label = "pane" },
        .{ .key = "Ret", .label = "open" },
        .{ .key = "F5", .label = "copy" },
    };

    var wide: [MAX]Placed = undefined;
    var tight: [MAX]Placed = undefined;
    const all = place(area, area.right(), &entries, &wide);
    const some = place(area, 100, &entries, &tight);

    try testing.expect(some.len < all.len);
}

test "a row with nowhere to put anything places nothing" {
    const none = Rect{ .x = 0, .y = 0, .w = 0, .h = 22 };
    var buf: [MAX]Placed = undefined;
    try testing.expectEqual(@as(usize, 0), place(none, none.right(), &.{
        .{ .key = "Tab", .label = "pane" },
    }, &buf).len);
}

test "no more keys are placed than the caller has room for" {
    const area = Rect{ .x = 0, .y = 0, .w = 4000, .h = 22 };
    const entries = [_]Key{
        .{ .key = "a", .label = "one" },
        .{ .key = "b", .label = "two" },
        .{ .key = "c", .label = "three" },
    };
    var two: [2]Placed = undefined;
    try testing.expectEqual(@as(usize, 2), place(area, area.right(), &entries, &two).len);
}
