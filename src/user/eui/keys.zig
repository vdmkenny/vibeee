//! The keys, named, along the bottom of a window.
//!
//! A program driven from the keyboard has to say so somewhere, and the row
//! along the bottom is where every such program has said it since function
//! keys had labels printed above them. The file manager, the editor, the
//! viewer and the launcher all want the same row, which is why the shape is
//! here and not in any of them.
//!
//! A key and what it does read as one thing, so the eye can skip along the
//! row. Two ways of saying it: a chip in the accent where the row is the
//! interface, as in a file manager driven entirely from these keys, and plain
//! coloured text where the row is a footnote under something else. What does
//! not fit is dropped rather than squeezed: half a word is worse than no
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

/// How the chord is drawn.
pub const Style = enum {
    /// A filled chip in the accent. For a row that is the interface.
    chip,
    /// The accent as ink, on the bar's own ground. For a row that sits under
    /// something else and should not compete with it.
    plain,
};

/// Which end the row packs against.
pub const Align = enum { left, right };

/// Where one named key sits, once it is known to fit.
pub const Placed = struct {
    chip: Rect,
    /// Where the label starts, to the right of the chip.
    label_x: i32,
    key: []const u8,
    label: []const u8,
};

/// How wide a named key needs, chord and label and the air after it.
pub fn width(entry: Key, style: Style) i32 {
    const t = theme.current();
    return chipWidth(entry.key, style) + t.padding + Surface.textWidth(entry.label) + t.menu_padding;
}

fn chipWidth(key: []const u8, style: Style) i32 {
    // Plain text needs no room around it; a chip is a shape and does.
    return Surface.textWidth(key) + switch (style) {
        .chip => theme.current().padding,
        .plain => 0,
    };
}

/// Place as many keys as fit in `area`, left to right, stopping at the first
/// one that would run past `limit`.
///
/// `limit` is where the row must stop, which is not always its right edge: a
/// count or a message often sits at the other end, and a key drawn under it
/// is two things in one place.
pub fn place(area: Rect, limit: i32, entries: []const Key, style: Style, into: []Placed) []Placed {
    const t = theme.current();
    var n: usize = 0;
    var x = area.x + t.padding;

    for (entries) |entry| {
        if (n == into.len) break;

        const chip = Rect{
            .x = x,
            .y = area.y + t.padding,
            .w = chipWidth(entry.key, style),
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

/// The same, packed against the right edge instead: the whole row measured
/// first, then laid out from where it has to start to end where it should.
pub fn placeRight(area: Rect, entries: []const Key, style: Style, into: []Placed) []Placed {
    const t = theme.current();

    var total: i32 = 0;
    for (entries) |entry| total += width(entry, style);

    const from = Rect{
        .x = @max(area.x, area.right() - t.padding - total),
        .y = area.y,
        .w = area.w,
        .h = area.h,
    };
    return place(from, area.right(), entries, style, into);
}

/// The whole row: the ground, the rule above it, and the keys that fit.
///
/// Returns where the row stopped, so a caller with something to say on the
/// same line knows what is left.
/// The whole row on the bar's own ground, which is what a window's bottom
/// edge is.
/// The strip along the bottom of a window: what the keys do, as chips from
/// the left, and one thing being said against the right edge.
///
/// Every window with keys along its bottom draws this, and each one drew it
/// for itself: the same two halves, placed and coloured three times over.
/// What is said on the right is dropped rather than overlapped when the keys
/// have taken the room, because a count running into a chip is worse than no
/// count.
pub fn bar(surface: Surface, area: Rect, entries: []const Key, said: []const u8) void {
    const t = theme.current();
    const after = paint(surface, area, entries, area.right(), .chip);
    if (said.len == 0) return;

    const said_w = Surface.textWidth(said);
    if (after + said_w >= area.right()) return;

    surface.text(
        area.right() - t.menu_padding - said_w,
        area.y + @divTrunc(area.h - Surface.textHeight(), 2),
        said,
        t.bar_text,
    );
}

pub fn paint(surface: Surface, area: Rect, entries: []const Key, limit: i32, style: Style) i32 {
    const t = theme.current();

    surface.fill(area, t.bar);
    surface.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, t.line);

    var buf: [MAX]Placed = undefined;
    return render(surface, place(area, limit, entries, style, &buf), area, style, t.bar_text) orelse
        area.x + t.padding;
}

/// Draw an already placed row, without touching the ground under it: what a
/// caller with something else on the same strip wants.
///
/// The ink is the caller's, because only the caller knows what the row is
/// sitting on: the same words in the bar's ink would be invisible on a pale
/// strip, and in the page's ink invisible on a dark one.
pub fn drawPlaced(surface: Surface, shown: []const Placed, area: Rect, style: Style, ink: draw.Color) void {
    _ = render(surface, shown, area, style, ink);
}

fn render(surface: Surface, shown: []const Placed, area: Rect, style: Style, ink: draw.Color) ?i32 {
    const t = theme.current();
    const baseline = area.y + @divTrunc(area.h - Surface.textHeight(), 2);

    for (shown) |one| {
        switch (style) {
            .chip => {
                surface.fill(one.chip, t.accent);
                surface.textCentred(one.chip, one.key, t.accent_text);
            },
            .plain => surface.text(one.chip.x, baseline, one.key, t.accent),
        }
        surface.text(one.label_x, baseline, one.label, ink);
    }

    if (shown.len == 0) return null;
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
    const shown = place(area, area.right(), &entries, .chip, &buf);
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
    const shown = place(narrow, narrow.right(), &entries, .chip, &buf);

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
    const all = place(area, area.right(), &entries, .chip, &wide);
    const some = place(area, 100, &entries, .chip, &tight);

    try testing.expect(some.len < all.len);
}

test "a row with nowhere to put anything places nothing" {
    const none = Rect{ .x = 0, .y = 0, .w = 0, .h = 22 };
    var buf: [MAX]Placed = undefined;
    try testing.expectEqual(@as(usize, 0), place(none, none.right(), &.{
        .{ .key = "Tab", .label = "pane" },
    }, .chip, &buf).len);
}

test "no more keys are placed than the caller has room for" {
    const area = Rect{ .x = 0, .y = 0, .w = 4000, .h = 22 };
    const entries = [_]Key{
        .{ .key = "a", .label = "one" },
        .{ .key = "b", .label = "two" },
        .{ .key = "c", .label = "three" },
    };
    var two: [2]Placed = undefined;
    try testing.expectEqual(@as(usize, 2), place(area, area.right(), &entries, .chip, &two).len);
}
