//! The strip along the bottom of a window.
//!
//! Where a program says what it is looking at and what just happened, in
//! fields that stay in the same place so a glance finds the one wanted. The
//! shape every desktop settled on, and worth having once rather than as a
//! label each application positions slightly differently.
//!
//! Deliberately short. On a panel 480 pixels tall a status bar that cost a
//! control's height would be a control's height taken from the document, so
//! it is sized to its text and nothing more.

const draw = @import("draw.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

/// Most fields one bar holds. More than this and none of them can be read.
pub const MAX_PANELS = 4;

pub const Panel = struct {
    text: []const u8 = "",
    /// Width in pixels. Zero takes whatever is left over, and at most one
    /// panel should ask for that: the one holding the thing that varies, which
    /// is usually a path.
    width: i32 = 0,
    /// Right-aligned, for a count that should line up as it changes.
    right: bool = false,
};

/// How tall the bar is: its text plus the rule above it and a little air.
pub fn height() i32 {
    return Surface.textHeight() + 5;
}

/// The rectangle a status bar occupies at the bottom of `area`, and the
/// rectangle left for everything else.
pub const Split = struct { body: Rect, bar: Rect };

pub fn split(area: Rect) Split {
    const h = height();
    return .{
        .body = .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h - h },
        .bar = .{ .x = area.x, .y = area.bottom() - h, .w = area.w, .h = h },
    };
}

/// Draw the bar. It reads rather than responds, so there is nothing to return.
pub fn run(ctx: *widget.Context, area: Rect, panels: []const Panel) void {
    const t = theme.current();

    // Compared against what it drew last pass, since the fields change
    // constantly and almost every pass leaves them the same.
    const entry = ctx.slotFor(area) orelse return;
    entry.seen = true;

    var mark = widget.Fingerprint{};
    for (panels) |panel| mark.text(panel.text);
    const signature = mark.done();

    if (!ctx.damaged and entry.detail == signature) return;
    entry.detail = signature;

    ctx.surface.fill(area, t.surface);
    ctx.surface.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, t.line);

    const baseline = area.y + 3;
    var x = area.x;

    for (panels, 0..) |panel, i| {
        const w = if (panel.width > 0) panel.width else remaining(panels, area.w);
        const field = Rect{ .x = x, .y = area.y + 1, .w = w, .h = area.h - 1 };

        // A hairline between fields rather than a sunken box around each: at
        // this height a border would leave two pixels for the text.
        if (i > 0) ctx.surface.fill(.{ .x = x, .y = field.y + 1, .w = 1, .h = field.h - 2 }, t.line);

        const clipped = ctx.surface.clipped(field);
        const text_x = if (panel.right)
            field.right() - t.padding - Surface.textWidth(panel.text)
        else
            field.x + t.padding;

        clipped.text(text_x, baseline, panel.text, t.text_dim);
        x += w;
    }

    ctx.addDamage(area);
}

/// What is left after every panel that asked for a fixed width.
fn remaining(panels: []const Panel, total: i32) i32 {
    var used: i32 = 0;
    for (panels) |panel| used += panel.width;
    return @max(total - used, 0);
}
