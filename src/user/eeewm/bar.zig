//! The status bar: what is running, where, and what the machine is doing.
//!
//! Server-drawn into the scanout buffer rather than being a client, because it
//! is furniture: it is always present, it must be correct while a client is
//! wedged, and giving it a surface of its own would cost a megabyte and a half
//! to save nothing. design/10-gui.md §4.4.
//!
//! Twenty-two pixels tall, which at 133 DPI is one line of interface text with
//! room to breathe and leaves 458 rows for tiles.

const std = @import("std");
const draw = @import("eui").draw;
const layout = @import("layout.zig");
const str = @import("ulib").str;
const sys = @import("sys");
const theme = @import("eui").theme;

const Rect = draw.Rect;
const Surface = draw.Surface;

/// Width of one tag pip. Four of them cost 56 px of a 800 px bar, which is
/// what a fifth tag would not be worth.
const PIP_WIDTH: i32 = 14;

pub fn paint(surface: Surface, width: i32, desktop: *const layout.Desktop) void {
    const t = theme.current();
    const height = t.bar_height;

    surface.fill(.{ .x = 0, .y = 0, .w = width, .h = height }, t.bar);
    // A hairline rather than a bevel: it separates without spending a row on
    // looking like it does.
    surface.fill(.{ .x = 0, .y = height - 1, .w = width, .h = 1 }, t.bar_line);

    var x = paintTags(surface, desktop);
    x = paintLayout(surface, x, desktop);
    paintTitle(surface, x, width, desktop);
    paintClock(surface, width);
}

/// Tag pips. Filled for the tag being viewed, outlined for a tag holding
/// windows, and absent otherwise, so the bar shows where things are without
/// needing labels.
fn paintTags(surface: Surface, desktop: *const layout.Desktop) i32 {
    const t = theme.current();
    const occupied = desktop.occupied();

    var x: i32 = 0;
    for (0..layout.TAGS) |i| {
        const area = Rect{ .x = x, .y = 0, .w = PIP_WIDTH, .h = t.bar_height - 1 };
        const current = desktop.tag == i;

        if (current) surface.fill(area, t.accent);

        var label: [2]u8 = .{ '1' + @as(u8, @intCast(i)), 0 };
        surface.textCentred(
            area,
            label[0..1],
            if (current) t.accent_text else if (occupied[i]) t.bar_text else t.text_dim,
        );

        x += PIP_WIDTH;
    }
    return x;
}

/// One letter for the layout, clickable to cycle it.
fn paintLayout(surface: Surface, x: i32, desktop: *const layout.Desktop) i32 {
    const t = theme.current();
    const area = Rect{ .x = x + t.padding, .y = 0, .w = 14, .h = t.bar_height - 1 };
    surface.textCentred(area, desktop.layout().glyph(), t.bar_text);
    return area.right();
}

fn paintTitle(surface: Surface, x: i32, width: i32, desktop: *const layout.Desktop) void {
    const t = theme.current();
    const index = desktop.focused orelse return;

    const area = Rect{
        .x = x + t.padding,
        .y = 0,
        // Stops short of the clock, so a long title is truncated rather than
        // drawn over it.
        .w = width - x - CLOCK_WIDTH - t.padding * 2,
        .h = t.bar_height - 1,
    };
    if (area.w <= 0) return;

    const clip = surface.clipped(area);
    clip.text(area.x, @divTrunc(area.h - Surface.textHeight(), 2), desktop.windows[index].name(), t.bar_text);
}

const CLOCK_WIDTH: i32 = 46;

fn paintClock(surface: Surface, width: i32) void {
    const t = theme.current();
    const area = Rect{ .x = width - CLOCK_WIDTH, .y = 0, .w = CLOCK_WIDTH - 4, .h = t.bar_height - 1 };

    const us = sys.realtimeMicros() orelse return;
    const minutes = @divFloor(@divFloor(us, 1_000_000), 60);

    var buf: [8]u8 = @splat(0);
    const hour: usize = @intCast(@divFloor(@mod(minutes, 1440), 60));
    const minute: usize = @intCast(@mod(minutes, 60));

    buf[0] = '0' + @as(u8, @intCast(hour / 10));
    buf[1] = '0' + @as(u8, @intCast(hour % 10));
    buf[2] = ':';
    buf[3] = '0' + @as(u8, @intCast(minute / 10));
    buf[4] = '0' + @as(u8, @intCast(minute % 10));

    surface.textCentred(area, buf[0..5], t.bar_text);
}

/// Route a click on the bar. Tags select, the layout glyph cycles.
pub fn click(x: i32, desktop: *layout.Desktop) void {
    const t = theme.current();

    if (x < PIP_WIDTH * layout.TAGS) {
        desktop.view(@intCast(@divTrunc(x, PIP_WIDTH)));
        return;
    }

    const glyph_start = PIP_WIDTH * layout.TAGS + t.padding;
    if (x >= glyph_start and x < glyph_start + 14) desktop.cycleLayout();
}
