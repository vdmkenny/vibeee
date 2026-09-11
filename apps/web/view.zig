//! The page on screen: the lines of its layout that fall inside the window,
//! and what a click, a key or the wheel does to it.
//!
//! Painted only where something changed. A page that has not moved paints
//! nothing on a pass. One that scrolled moves the rows that stay on screen
//! with `Surface.shift` and paints only the band it uncovered, because
//! moving a row is one copy and drawing its text is a glyph at a time. Only
//! a new page, a new width or the window being uncovered paints all of it.

const std = @import("std");
const eui = @import("eui");
const layout_mod = @import("layout.zig");
const page_mod = @import("page.zig");

const Rect = eui.Rect;
const Surface = eui.Surface;
const Theme = eui.Theme;
const Face = page_mod.Face;
const Page = page_mod.Page;
const NO_LINK = page_mod.NO_LINK;

/// The widest a column of text is set, in the interface's own pixels: about
/// seventy-five letters of the body face, past which the eye loses its way
/// back to the start of the next line.
pub const MEASURE = 480;

/// The least room either side of the column.
const MARGIN = 16;

/// Lines the wheel moves a page by for each step it turns.
const WHEEL_LINES = 3;

/// What a face is on this system, measured at the size it is drawn.
const Metrics = struct {
    scale: i32,

    fn font(face: Face) *const eui.draw.Font {
        return switch (face) {
            .body => eui.draw.ui_font,
            .heading => eui.draw.title_font,
            .mono => eui.draw.mono_font,
        };
    }

    pub fn width(self: Metrics, face: Face, bytes: []const u8) i32 {
        return @as(i32, @intCast(font(face).measure(bytes))) * self.scale;
    }

    pub fn height(self: Metrics, face: Face) i32 {
        return @as(i32, @intCast(font(face).height)) * self.scale;
    }

    pub fn ascent(self: Metrics, face: Face) i32 {
        return @as(i32, @intCast(font(face).ascent)) * self.scale;
    }

    pub fn fit(self: Metrics, face: Face, bytes: []const u8, room: i32) usize {
        const glyphs: usize = @intCast(@max(@divTrunc(room, self.scale), 0));
        return font(face).fit(bytes, glyphs).len;
    }
};

pub const View = struct {
    page: ?*const Page = null,
    layout: layout_mod.Layout = .{},
    scroll: i32 = 0,
    /// Where the page was last painted, and at what scroll: what a pass
    /// compares against to know how little it can paint.
    painted: ?Painted = null,
    /// The link under the pointer, for the status line to say where it goes.
    hover: u16 = NO_LINK,

    const Painted = struct { area: Rect, scroll: i32 };

    /// Show `page`, starting `scroll` pixels down. Laid out on the next pass,
    /// at the width the window has then.
    pub fn show(self: *View, gpa: std.mem.Allocator, page: *const Page, scroll: i32) void {
        self.layout.deinit(gpa);
        self.page = page;
        self.scroll = @max(scroll, 0);
        self.painted = null;
        self.hover = NO_LINK;
    }

    pub fn deinit(self: *View, gpa: std.mem.Allocator) void {
        self.layout.deinit(gpa);
        self.* = .{};
    }

    /// How far down the page the view is, as a percentage.
    pub fn position(self: *const View, area: Rect) u8 {
        const reach = self.layout.height - area.h;
        if (reach <= 0) return 100;
        return @intCast(@divTrunc(@min(self.scroll, reach) * 100, reach));
    }

    /// Draw the page into `area` and take what the pointer and the keyboard
    /// did to it. Returns the link clicked this pass, if one was.
    pub fn run(self: *View, gpa: std.mem.Allocator, ctx: *eui.Context, area: Rect) ?u16 {
        const page = self.page orelse return null;
        const t = eui.theme.current();
        const metrics = Metrics{ .scale = eui.theme.textScale() };
        const column = columnOf(area, metrics.scale);
        const spacing = layout_mod.Spacing.forLine(metrics.height(.body));

        // Laid out again only when the column's width changed: a pass that
        // is only a scroll or a pointer moving reuses every line.
        if (self.layout.width != column.w) {
            self.layout.deinit(gpa);
            self.layout = layout_mod.build(gpa, page, column.w, spacing, metrics) catch .{ .width = column.w };
            self.painted = null;
        }

        const entry = ctx.slotFor(area) orelse return null;
        const it = ctx.interact(entry, area);

        const line = metrics.height(.body);
        var scroll = self.scroll;
        if (it.over) scroll -= @as(i32, ctx.takeWheel()) * line * WHEEL_LINES;
        if (ctx.takeKeyFor(entry)) |key| {
            const leaf = area.h - line;
            scroll = switch (key) {
                .up => scroll - line,
                .down => scroll + line,
                .page_up => scroll - leaf,
                .page_down, .space => scroll + leaf,
                .home => 0,
                .end => std.math.maxInt(i32),
                else => scroll,
            };
        }
        // A line's worth of room after the last one, so the end of a page
        // does not sit on the status bar.
        const reach = @max(self.layout.height + line - area.h, 0);
        scroll = std.math.clamp(scroll, 0, reach);

        self.hover = if (it.over) self.linkAt(page, column, area, ctx.pointer_x, ctx.pointer_y) else NO_LINK;
        const clicked: ?u16 = if (it.clicked and self.hover != NO_LINK) self.hover else null;

        const before = self.painted;
        self.scroll = scroll;
        self.painted = .{ .area = area, .scroll = scroll };

        const whole = ctx.damaged or before == null or !sameRect(before.?.area, area);
        if (whole) {
            self.paint(ctx.surface, page, column, area, area, t, metrics, spacing);
            ctx.addDamage(area);
        } else if (scroll != before.?.scroll) {
            const dy = scroll - before.?.scroll;
            if (@abs(dy) >= area.h) {
                self.paint(ctx.surface, page, column, area, area, t, metrics, spacing);
            } else {
                ctx.surface.shift(area, dy);
                const band: Rect = if (dy > 0)
                    .{ .x = area.x, .y = area.bottom() - dy, .w = area.w, .h = dy }
                else
                    .{ .x = area.x, .y = area.y, .w = area.w, .h = -dy };
                self.paint(ctx.surface, page, column, area, band, t, metrics, spacing);
            }
            ctx.addDamage(area);
        }
        return clicked;
    }

    /// Paint the lines that fall in `band`, a part of `area`.
    fn paint(self: *const View, surface: Surface, page: *const Page, column: Rect, area: Rect, band: Rect, t: *const Theme, metrics: Metrics, spacing: layout_mod.Spacing) void {
        const s = surface.clipped(band);
        s.fill(band, t.surface_hot);

        // A preformatted band reaches past its first and last lines by its
        // inset, so the lines just outside `band` may still paint inside it.
        const top = band.y - area.y + self.scroll - spacing.inset;
        const bottom = band.bottom() - area.y + self.scroll + spacing.inset;
        const lines = self.layout.lines.items;
        var i = self.layout.lineAt(top);
        while (i < lines.len and lines[i].y < bottom) : (i += 1) {
            self.drawLine(s, page, column, area, i, t, metrics, spacing);
        }
    }

    fn drawLine(self: *const View, s: Surface, page: *const Page, column: Rect, area: Rect, index: usize, t: *const Theme, metrics: Metrics, spacing: layout_mod.Spacing) void {
        const lines = self.layout.lines.items;
        const line = lines[index];
        const block = page.blocks.items[line.block];
        const y = area.y + line.y - self.scroll;
        const indent = @as(i32, block.depth) * spacing.indent;
        const x = column.x + indent;
        const w = column.w - indent;

        switch (block.kind) {
            .rule => {
                s.fill(.{ .x = x, .y = y + @divTrunc(line.height, 2), .w = w, .h = 1 }, t.line);
                return;
            },
            .preformatted => {
                const last = index + 1 == lines.len or lines[index + 1].block != line.block;
                const top = y - (if (line.leads) spacing.inset else 0);
                const bottom = y + line.height + (if (last) spacing.inset else 0);
                s.fill(.{ .x = x, .y = top, .w = w, .h = bottom - top }, t.surface);
                s.fill(.{ .x = x, .y = top, .w = 2 * metrics.scale, .h = bottom - top }, t.line);
            },
            else => {},
        }

        if (block.quoted) {
            // A bar down a quotation's margin, half a step outside its text.
            const bar_x = x - @divTrunc(spacing.indent, 2);
            s.fill(.{ .x = bar_x, .y = y, .w = 2 * metrics.scale, .h = line.height }, t.line);
        }

        if (line.leads) self.drawMarker(s, block, x, y + line.baseline, t, metrics);

        for (self.layout.fragsOf(line)) |frag| {
            const source = page.runs.items[frag.run];
            const text = page.text.items[frag.start..][0..frag.len];
            const ink = switch (source.ink) {
                .text => t.text,
                .dim => t.text_dim,
                .link => t.accent,
            };
            const left = column.x + frag.x;
            s.textIn(Metrics.font(source.face), left, y + line.baseline - metrics.ascent(source.face), text, ink);
            if (source.ink == .link) {
                s.fill(.{ .x = left, .y = y + line.baseline + metrics.scale, .w = frag.width, .h = metrics.scale }, t.accent);
            }
        }
    }

    /// A list entry's bullet or number, set in the margin and ending a little
    /// short of the text it belongs to.
    fn drawMarker(self: *const View, s: Surface, block: page_mod.Block, text_x: i32, baseline: i32, t: *const Theme, metrics: Metrics) void {
        _ = self;
        var digits: [12]u8 = undefined;
        const marker: []const u8 = switch (block.marker) {
            .none => return,
            .bullet => "\u{2022}",
            .number => |n| std.fmt.bufPrint(&digits, "{d}.", .{n}) catch return,
        };
        const width = metrics.width(.body, marker);
        const gap = 6 * metrics.scale;
        s.textIn(Metrics.font(.body), text_x - gap - width, baseline - metrics.ascent(.body), marker, t.text_dim);
    }

    /// The link at a point in the window, or none.
    fn linkAt(self: *const View, page: *const Page, column: Rect, area: Rect, x: i32, y: i32) u16 {
        const doc_y = y - area.y + self.scroll;
        const index = self.layout.lineAt(doc_y);
        if (index >= self.layout.lines.items.len) return NO_LINK;
        const line = self.layout.lines.items[index];
        if (doc_y < line.y) return NO_LINK;
        for (self.layout.fragsOf(line)) |frag| {
            const left = column.x + frag.x;
            if (x >= left and x < left + frag.width) return page.runs.items[frag.run].link;
        }
        return NO_LINK;
    }
};

/// The column a page is set in: the measure, or less where the window is
/// narrower, centred in what there is.
fn columnOf(area: Rect, scale: i32) Rect {
    const width = @max(@min(MEASURE * scale, area.w - 2 * MARGIN * scale), 1);
    return .{ .x = area.x + @divTrunc(area.w - width, 2), .y = area.y, .w = width, .h = area.h };
}

fn sameRect(a: Rect, b: Rect) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
}
