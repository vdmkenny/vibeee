//! The row of volumes across the top of a window.
//!
//! Where a window that works on files says which volume it is working on: the
//! system, home, the settings, and whatever is plugged in. The file manager
//! drew this, and a contact sheet wants exactly the same row against exactly
//! the same volumes, so it is here rather than in either of them.
//!
//! Each place says how full it is beside its name. That is what somebody
//! about to copy onto a card wants to know before they copy onto it, and the
//! gauge is the same width whatever the volume is called, so two of them can
//! be compared at a glance: a bar as wide as its cell would give every volume
//! a scale of its own.
//!
//! Drawn when what it would draw changes and not otherwise. A pass arrives
//! for every movement of the pointer anywhere in the window, and a strip
//! refilled and re-sent for a picture nobody had touched is the cost of the
//! whole strip paid for nothing.

const std = @import("std");
const draw = @import("draw.zig");
const gauge = @import("gauge.zig");
const keys = @import("keys.zig");
const mounts = @import("lib").mounts;
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

/// How full a volume is, as a bar. Fixed so two volumes compare.
const GAUGE_WIDTH: i32 = 38;
const GAUGE_HEIGHT: i32 = 7;

/// The longest reading a cell shows beside its gauge, which is what its
/// width is measured against.
const SAID_MAX = 16;

/// How tall the row is.
pub fn height() i32 {
    return theme.stripHeight();
}

/// What is left of a window underneath it.
pub fn below(area: Rect) Rect {
    const used = height();
    return .{ .x = area.x, .y = area.y + used, .w = area.w, .h = area.h - used };
}

/// What a caller gets back from a pass: which place was pressed, if any, and
/// where the row stopped, so a caller with something else on the same strip
/// knows what is left.
pub const Pass = struct {
    chose: ?usize = null,
    after: i32 = 0,
};

/// Draw the row and take a press.
///
/// `current` is the place being worked on, which the caller knows because it
/// knows where it is; `hint` is what the keyboard does to whatever is under
/// the cursor, drawn against the right edge where the row stops being a list
/// of places.
pub fn strip(
    ctx: *widget.Context,
    area: Rect,
    list: *const mounts.List,
    current: ?usize,
    hint: []const keys.Key,
) Pass {
    const t = theme.current();
    const entry = ctx.slotFor(area) orelse return paint(ctx, area, list, current, hint);
    entry.seen = true;

    const shape = fingerprint(list, current);
    if (!ctx.damaged and entry.detail == shape) return press(ctx, area, list);
    entry.detail = shape;

    ctx.surface.fill(area, t.surface_pressed);
    ctx.surface.fill(.{ .x = area.x, .y = area.bottom() - 1, .w = area.w, .h = 1 }, t.line);
    ctx.addDamage(area);
    return paint(ctx, area, list, current, hint);
}

/// What the row would draw, as one number. What is not here cannot make it
/// repaint.
fn fingerprint(list: *const mounts.List, current: ?usize) i32 {
    var mark = widget.Fingerprint{};
    mark.number(list.slice().len);
    mark.number(current orelse list.slice().len);
    for (list.slice()) |volume| {
        mark.text(volume.path());
        mark.number(volume.free);
        mark.number(volume.size);
    }
    return mark.done();
}

/// A press on a place, for the passes that draw nothing.
fn press(ctx: *widget.Context, area: Rect, list: *const mounts.List) Pass {
    var out = Pass{ .after = area.x };
    if (!ctx.pressedThisPass()) {
        for (list.slice()) |volume| {
            const w = width(volume);
            if (out.after + w > area.right()) break;
            out.after += w;
        }
        return out;
    }

    for (list.slice(), 0..) |volume, index| {
        const w = width(volume);
        if (out.after + w > area.right()) break;

        const cell = Rect{ .x = out.after, .y = area.y, .w = w, .h = area.h - 1 };
        if (cell.contains(ctx.pointer_x, ctx.pointer_y)) out.chose = index;
        out.after += w;
    }
    return out;
}

fn paint(
    ctx: *widget.Context,
    area: Rect,
    list: *const mounts.List,
    current: ?usize,
    hint: []const keys.Key,
) Pass {
    const t = theme.current();
    var out = Pass{ .after = area.x };

    for (list.slice(), 0..) |volume, index| {
        const w = width(volume);
        if (out.after + w > area.right()) break;

        const cell = Rect{ .x = out.after, .y = area.y, .w = w, .h = area.h - 1 };
        if (ctx.pressedThisPass() and cell.contains(ctx.pointer_x, ctx.pointer_y)) out.chose = index;
        one(ctx.surface, cell, volume, current == index);

        out.after += w;
        ctx.surface.fill(.{ .x = out.after - 1, .y = cell.y, .w = 1, .h = cell.h }, t.line);
    }

    if (hint.len != 0) {
        var placed: [keys.MAX]keys.Placed = undefined;
        keys.drawPlaced(ctx.surface, keys.placeRight(area, hint, .plain, &placed), area, .plain, t.text_dim);
    }
    return out;
}

/// How wide one place needs: its name, and its gauge and reading where the
/// device said how full it is.
pub fn width(volume: mounts.Volume) i32 {
    const t = theme.current();
    var w = Surface.textWidth(volume.name()) + t.menu_padding * 2;
    if (volume.known()) {
        var room: [SAID_MAX]u8 = undefined;
        w += t.gap + GAUGE_WIDTH + t.gap + Surface.textWidth(said(volume, &room));
    }
    return w;
}

/// What is left on it, in the words somebody would use.
fn said(volume: mounts.Volume, into: *[SAID_MAX]u8) []const u8 {
    var line = @import("lib").str.Builder{ .buf = into };
    line.bytes(volume.free);
    return line.done();
}

/// One place: its name, how full it is, and what is left.
fn one(surface: Surface, cell: Rect, volume: mounts.Volume, current: bool) void {
    const t = theme.current();
    const ink = if (current) t.accent_text else t.text;

    surface.fill(cell, if (current) t.accent else t.surface_pressed);

    const baseline = cell.y + @divTrunc(cell.h - Surface.textHeight(), 2);
    var x = cell.x + t.menu_padding;
    // Measured once: `width` asked the same question a moment ago, and
    // measuring decodes the name and looks up an advance per letter.
    const named = Surface.textWidth(volume.name());
    surface.text(x, baseline, volume.name(), ink);
    x += named + t.gap;

    if (!volume.known()) return;

    const bar = Rect{
        .x = x,
        .y = cell.y + @divTrunc(cell.h - GAUGE_HEIGHT, 2),
        .w = GAUGE_WIDTH,
        .h = GAUGE_HEIGHT,
    };

    // On the chosen place the ground is already the accent, so the bar is
    // drawn in the ink that reads on it.
    const filled = if (current)
        t.accent_text
    else if (gauge.alarming(volume.percent(), .when_full))
        t.warning
    else
        t.accent;

    surface.fill(bar, if (current) t.accent else t.surface);
    surface.fill(.{ .x = bar.x, .y = bar.y, .w = widget.filledWidth(bar, volume.percent()), .h = bar.h }, filled);
    surface.frame(bar, if (current) t.accent_text else t.border);

    var room: [SAID_MAX]u8 = undefined;
    surface.text(x + GAUGE_WIDTH + t.gap, baseline, said(volume, &room), if (current) ink else t.text_dim);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a place that says how full it is is wider than one that does not" {
    draw.useLinked();
    const quiet = mounts.parse("/media/usb0 on usb0").?;
    const told = mounts.parse("/media/usb0 on usb0 free=50 size=100").?;
    try testing.expect(width(told) > width(quiet));
}

test "the row is a strip tall and leaves the rest of the window" {
    const window = Rect{ .x = 0, .y = 22, .w = 800, .h = 458 };
    const rest = below(window);
    try testing.expectEqual(window.y + height(), rest.y);
    try testing.expectEqual(window.bottom(), rest.bottom());
}
