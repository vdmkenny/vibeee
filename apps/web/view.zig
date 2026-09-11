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
const Layout = layout_mod.Layout;
const Spacing = layout_mod.Spacing;

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
    layout: Layout = .{},
    scroll: i32 = 0,
    /// Where the page was last painted, and at what scroll: what a pass
    /// compares against to know how little it can paint.
    painted: ?Painted = null,
    /// The link under the pointer, for the status line to say where it goes.
    hover: ?u16 = null,

    const Painted = struct { area: Rect, scroll: i32 };

    /// Show `page`, starting `scroll` pixels down. Laid out on the next pass,
    /// at the width the window has then.
    pub fn show(self: *View, gpa: std.mem.Allocator, page: *const Page, scroll: i32) void {
        self.layout.deinit(gpa);
        self.page = page;
        self.scroll = @max(scroll, 0);
        self.painted = null;
        self.hover = null;
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
        const metrics = Metrics{ .scale = eui.theme.textScale() };
        const column = columnOf(area, metrics.scale);
        const spacing = Spacing.forLine(metrics.height(.body));

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

        self.hover = if (it.over) self.linkAt(page, column, area, ctx.pointer_x, ctx.pointer_y) else null;
        const clicked = if (it.clicked) self.hover else null;

        const before = self.painted;
        self.scroll = scroll;
        self.painted = .{ .area = area, .scroll = scroll };

        const pass = Pass{
            .view = self,
            .page = page,
            .surface = ctx.surface,
            .theme = eui.theme.current(),
            .metrics = metrics,
            .spacing = spacing,
            .column = column,
            .area = area,
        };
        const was = before orelse {
            pass.paint(area);
            ctx.addDamage(area);
            return clicked;
        };
        if (ctx.damaged or !std.meta.eql(was.area, area)) {
            pass.paint(area);
            ctx.addDamage(area);
        } else if (scroll != was.scroll) {
            const dy = scroll - was.scroll;
            if (@abs(dy) >= area.h) {
                pass.paint(area);
            } else {
                ctx.surface.shift(area, dy);
                pass.paint(if (dy > 0)
                    .{ .x = area.x, .y = area.bottom() - dy, .w = area.w, .h = dy }
                else
                    .{ .x = area.x, .y = area.y, .w = area.w, .h = -dy });
            }
            ctx.addDamage(area);
        }
        return clicked;
    }

    /// The link at a point in the window, if there is one there.
    fn linkAt(self: *const View, page: *const Page, column: Rect, area: Rect, x: i32, y: i32) ?u16 {
        const doc_y = y - area.y + self.scroll;
        const index = self.layout.lineAt(doc_y);
        if (index >= self.layout.lines.items.len) return null;
        const line = self.layout.lines.items[index];
        if (doc_y < line.y) return null;
        for (self.layout.fragsOf(line)) |frag| {
            const left = column.x + frag.x;
            if (x >= left and x < left + frag.width) return page.runs.items[frag.run].text.link;
        }
        return null;
    }
};

/// One pass's painting: what it paints on, and what every line needs to be
/// drawn with.
const Pass = struct {
    view: *const View,
    page: *const Page,
    surface: Surface,
    theme: *const Theme,
    metrics: Metrics,
    spacing: Spacing,
    /// The column the page is set in, and the view it scrolls in.
    column: Rect,
    area: Rect,

    /// Paint the lines that fall in `band`, a part of the view.
    fn paint(self: Pass, band: Rect) void {
        const s = self.surface.clipped(band);
        s.fill(band, self.theme.surface_hot);

        // A preformatted band reaches past its first and last lines by its
        // inset, so the lines just outside `band` may still paint inside it.
        const top = band.y - self.area.y + self.view.scroll - self.spacing.inset;
        const bottom = band.bottom() - self.area.y + self.view.scroll + self.spacing.inset;
        const lines = self.view.layout.lines.items;
        var i = self.view.layout.lineAt(top);
        while (i < lines.len and lines[i].y < bottom) : (i += 1) self.line(s, i);
    }

    fn line(self: Pass, s: Surface, index: usize) void {
        const lines = self.view.layout.lines.items;
        const at = lines[index];
        const block = self.page.blocks.items[at.block];
        const t = self.theme;
        const scale = self.metrics.scale;
        const y = self.area.y + at.y - self.view.scroll;
        const indent = @as(i32, block.depth) * self.spacing.indent;
        const x = self.column.x + indent;
        const w = self.column.w - indent;

        switch (block.kind) {
            .rule => {
                s.fill(.{ .x = x, .y = y + @divTrunc(at.height, 2), .w = w, .h = 1 }, t.line);
                return;
            },
            .preformatted => {
                const last = index + 1 == lines.len or lines[index + 1].block != at.block;
                const top = y - (if (at.leads) self.spacing.inset else 0);
                const bottom = y + at.height + (if (last) self.spacing.inset else 0);
                s.fill(.{ .x = x, .y = top, .w = w, .h = bottom - top }, t.surface);
                s.fill(.{ .x = x, .y = top, .w = 2 * scale, .h = bottom - top }, t.line);
            },
            else => {},
        }

        if (block.quoted) {
            // A bar down a quotation's margin, half a step outside its text.
            s.fill(.{ .x = x - @divTrunc(self.spacing.indent, 2), .y = y, .w = 2 * scale, .h = at.height }, t.line);
        }

        if (at.leads) self.marker(s, block.marker, x, y + at.baseline);

        for (self.view.layout.fragsOf(at)) |frag| {
            const text = self.page.runs.items[frag.run].text;
            const face = text.look.face;
            const ink = switch (text.look.ink) {
                .text => t.text,
                .dim => t.text_dim,
                .link => t.accent,
            };
            const left = self.column.x + frag.x;
            s.textIn(Metrics.font(face), left, y + at.baseline - self.metrics.ascent(face), self.page.text.items[frag.start..][0..frag.len], ink);
            if (text.look.ink == .link) {
                s.fill(.{ .x = left, .y = y + at.baseline + scale, .w = frag.width, .h = scale }, t.accent);
            }
        }
    }

    /// A list entry's bullet or number, in the margin and ending a little
    /// short of the words it belongs to.
    fn marker(self: Pass, s: Surface, which: page_mod.Marker, text_x: i32, baseline: i32) void {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        which.write(&w, "\u{2022}") catch return;
        const shown = w.buffered();
        if (shown.len == 0) return;
        const width = self.metrics.width(.body, shown);
        const gap = 6 * self.metrics.scale;
        s.textIn(Metrics.font(.body), text_x - gap - width, baseline - self.metrics.ascent(.body), shown, self.theme.text_dim);
    }
};

/// The column a page is set in: the measure, or less where the window is
/// narrower, centred in what there is.
fn columnOf(area: Rect, scale: i32) Rect {
    const width = @max(@min(MEASURE * scale, area.w - 2 * MARGIN * scale), 1);
    return .{ .x = area.x + @divTrunc(area.w - width, 2), .y = area.y, .w = width, .h = area.h };
}
