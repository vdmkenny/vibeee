//! The page on screen: the lines of its layout that fall inside the window,
//! its controls, and what a click, a key or the wheel does to it.
//!
//! Painted only where something changed. A page that has not moved paints
//! nothing on a pass. One that scrolled moves the rows that stay on screen
//! with `Surface.shift` and paints only the band it uncovered, because
//! moving a row is one copy and drawing its text is a glyph at a time. Only
//! a new page, a new width or the window being uncovered paints all of it.
//!
//! A page's controls are the toolkit's own: its text field, its button, its
//! check box, run each pass where the layout put them, clipped to the view so
//! that one half scrolled out neither paints nor answers outside it. What is
//! typed in them and which boxes are ticked is kept here, for as long as the
//! page is shown.

const std = @import("std");
const eui = @import("eui");
const layout_mod = @import("layout.zig");
const page_mod = @import("page.zig");

const Rect = eui.Rect;
const Surface = eui.Surface;
const Theme = eui.Theme;
const Control = page_mod.Control;
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

/// The most a line in a page's form holds.
const LINE_MAX = 256;

/// A line to type in, as the toolkit keeps one.
const Line = eui.text.Field(LINE_MAX);

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

    /// The room a control takes: the toolkit's own height, and a width from
    /// what it holds.
    pub fn control(self: Metrics, page: *const Page, which: Control) layout_mod.Size {
        const t = eui.theme.current();
        return switch (which.kind) {
            .line => |line| .{ .w = @as(i32, line.letters) * self.width(.body, "n") + 2 * t.padding, .h = t.control_height },
            .submit, .reset => |press| .{ .w = self.width(.body, page.string(press.label)) + 4 * t.padding, .h = t.control_height },
            .tick => .{ .w = t.control_height, .h = t.control_height },
            .hidden => .{ .w = 0, .h = 0 },
        };
    }
};

/// What a pass of the page was asked to do.
pub const Action = union(enum) {
    /// Follow a link.
    follow: u16,
    /// Send a form.
    submit: Submit,
};

pub const Submit = struct {
    form: u16,
    /// The button that sent it, where one did rather than Enter in one of
    /// its lines.
    by: ?u16,
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
    /// What is typed in the page's lines, and which of its boxes are ticked.
    lines: []Line = &.{},
    ticks: []bool = &.{},
    /// The control the keyboard is in, which it stays in when a scroll moves
    /// the control.
    focused: ?u16 = null,

    const Painted = struct { area: Rect, scroll: i32 };

    /// Show `page`, starting `scroll` pixels down. Laid out on the next pass,
    /// at the width the window has then.
    pub fn show(self: *View, gpa: std.mem.Allocator, page: *const Page, scroll: i32) void {
        self.deinit(gpa);
        self.page = page;
        self.scroll = @max(scroll, 0);
        // A page whose controls have no room to keep what is typed still
        // reads; its controls are simply not drawn.
        self.lines = gpa.alloc(Line, page.lines) catch &.{};
        self.ticks = gpa.alloc(bool, page.ticks) catch &.{};
        self.restore(page, null);
    }

    pub fn deinit(self: *View, gpa: std.mem.Allocator) void {
        self.layout.deinit(gpa);
        gpa.free(self.lines);
        gpa.free(self.ticks);
        self.* = .{};
    }

    /// How far down the page the view is, as a percentage.
    pub fn position(self: *const View, area: Rect) u8 {
        const reach = self.layout.height - area.h;
        if (reach <= 0) return 100;
        return @intCast(@divTrunc(@min(self.scroll, reach) * 100, reach));
    }

    /// What a control sends with its form, if it sends anything: a line what
    /// is typed in it, a hidden one its value, a ticked box its value, and a
    /// button its own when it is the one that sent the form.
    pub fn answer(self: *const View, page: *const Page, index: u16, by: ?u16) ?[]const u8 {
        const control = page.controls.items[index];
        return switch (control.kind) {
            .line => |line| if (line.slot < self.lines.len) self.lines[line.slot].slice() else null,
            .hidden => page.string(control.value),
            .tick => |tick| if (tick.slot < self.ticks.len and self.ticks[tick.slot]) page.string(control.value) else null,
            .submit => if (by == index) page.string(control.value) else null,
            .reset => null,
        };
    }

    /// Draw the page into `area` and take what the pointer and the keyboard
    /// did to it and to its controls.
    pub fn run(self: *View, gpa: std.mem.Allocator, ctx: *eui.Context, area: Rect) ?Action {
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

        // What is painted this pass: all of it, the band a scroll uncovered,
        // or nothing.
        const moved = if (before) |was| was.scroll != scroll else false;
        const repainted: ?Rect = if (before == null or ctx.damaged or !std.meta.eql(before.?.area, area))
            area
        else if (!moved)
            null
        else band: {
            const dy = scroll - before.?.scroll;
            if (@abs(dy) >= area.h) break :band area;
            ctx.surface.shift(area, dy);
            break :band if (dy > 0)
                Rect{ .x = area.x, .y = area.bottom() - dy, .w = area.w, .h = dy }
            else
                Rect{ .x = area.x, .y = area.y, .w = area.w, .h = -dy };
        };
        if (repainted) |band| {
            pass.paint(band);
            ctx.addDamage(area);
        }

        const acted = self.runControls(ctx, pass, repainted, moved);
        if (it.clicked) {
            if (self.hover) |link| return .{ .follow = link };
        }
        return acted;
    }

    /// The page's controls that are on screen, run where the layout put
    /// them. A control in ground this pass painted over paints again, and
    /// the keyboard stays in the control it was in when a scroll moves it.
    fn runControls(self: *View, ctx: *eui.Context, pass: Pass, repainted: ?Rect, moved: bool) ?Action {
        const whole = ctx.surface;
        ctx.surface = whole.clipped(pass.area);
        defer ctx.surface = whole;

        var acted: ?Action = null;
        var focused: ?u16 = null;
        const lines = self.layout.lines.items;
        var i = self.layout.lineAt(self.scroll);
        while (i < lines.len and lines[i].y < self.scroll + pass.area.h) : (i += 1) {
            for (self.layout.fragsOf(lines[i])) |frag| {
                const index = switch (pass.page.runs.items[frag.run]) {
                    .control => |which| which,
                    .text, .line_break => continue,
                };
                const rect = pass.controlRect(lines[i], frag, pass.page.controls.items[index]);
                if (repainted) |band| {
                    if (!band.intersect(rect).isEmpty()) ctx.repaintAt(rect);
                }
                if (moved and self.focused == index) ctx.focusAt(rect);
                if (self.runControl(ctx, pass.page, index, rect)) |act| acted = act;
                if (ctx.focusedAt(rect)) focused = index;
            }
        }
        self.focused = focused;
        return acted;
    }

    fn runControl(self: *View, ctx: *eui.Context, page: *const Page, index: u16, rect: Rect) ?Action {
        const control = page.controls.items[index];
        switch (control.kind) {
            .line => |line| {
                if (line.slot >= self.lines.len) return null;
                // Enter in a line sends its form, which is how a form with
                // no button to press is sent.
                if (self.lines[line.slot].run(ctx, rect)) return sent(control, null);
            },
            .submit => |press| if (ctx.button(rect, page.string(press.label))) return sent(control, index),
            .reset => |press| if (ctx.button(rect, page.string(press.label))) {
                if (control.form) |form| self.restore(page, form);
            },
            .tick => |tick| {
                if (tick.slot >= self.ticks.len) return null;
                const ticked = ctx.checkbox(rect, "", self.ticks[tick.slot]);
                if (ticked != self.ticks[tick.slot]) self.tickBox(page, control, ticked);
            },
            .hidden => {},
        }
        return null;
    }

    /// Tick or untick a box. A radio button ticked unticks the rest of its
    /// group, and one already ticked stays so: a group always has its one.
    fn tickBox(self: *View, page: *const Page, control: Control, ticked: bool) void {
        const tick = control.kind.tick;
        if (!tick.radio) {
            self.ticks[tick.slot] = ticked;
            return;
        }
        if (!ticked) return;
        const name = page.string(control.name);
        for (page.controls.items) |other| switch (other.kind) {
            .tick => |box| if (box.radio and box.slot < self.ticks.len and other.form == control.form and std.mem.eql(u8, page.string(other.name), name)) {
                self.ticks[box.slot] = false;
            },
            .line, .hidden, .submit, .reset => {},
        };
        self.ticks[tick.slot] = true;
    }

    /// Put the lines and boxes of one form, or of the whole page, back the
    /// way the page had them.
    fn restore(self: *View, page: *const Page, only: ?u16) void {
        for (page.controls.items) |control| {
            if (only) |form| {
                if (control.form != form) continue;
            }
            switch (control.kind) {
                .line => |line| if (line.slot < self.lines.len) {
                    const field = &self.lines[line.slot];
                    const value = page.string(control.value);
                    if (only == null) {
                        field.init(.{ .initial = value, .hint = page.string(line.hint), .secret = line.secret });
                    } else {
                        field.set(value);
                    }
                },
                .tick => |tick| if (tick.slot < self.ticks.len) {
                    self.ticks[tick.slot] = tick.ticked;
                },
                .hidden, .submit, .reset => {},
            }
        }
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
            if (x < left or x >= left + frag.width) continue;
            return switch (page.runs.items[frag.run]) {
                .text => |text| text.link,
                .control, .line_break => null,
            };
        }
        return null;
    }
};

/// A form sent by the control, where the control is in a form.
fn sent(control: Control, by: ?u16) ?Action {
    return .{ .submit = .{ .form = control.form orelse return null, .by = by } };
}

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

    /// Paint the lines that fall in `band`, a part of the view. Controls are
    /// the toolkit's to paint, after this.
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
            const text = switch (self.page.runs.items[frag.run]) {
                .text => |text| text,
                .control, .line_break => continue,
            };
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

    /// Where a control is drawn: as wide as the layout made it and as tall
    /// as it is, with its bottom where the words' descent ends.
    fn controlRect(self: Pass, at: layout_mod.Line, frag: layout_mod.Frag, control: Control) Rect {
        const size = self.metrics.control(self.page, control);
        const descent = self.metrics.height(.body) - self.metrics.ascent(.body);
        const bottom = self.area.y + at.y - self.view.scroll + at.baseline + descent;
        return .{ .x = self.column.x + frag.x, .y = bottom - size.h, .w = frag.width, .h = size.h };
    }
};

/// The column a page is set in: the measure, or less where the window is
/// narrower, centred in what there is.
fn columnOf(area: Rect, scale: i32) Rect {
    const width = @max(@min(MEASURE * scale, area.w - 2 * MARGIN * scale), 1);
    return .{ .x = area.x + @divTrunc(area.w - width, 2), .y = area.y, .w = width, .h = area.h };
}
