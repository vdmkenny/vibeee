//! The page on screen: the lines of its layout that fall inside the window,
//! its controls and pictures, and what a click, a key or the wheel does to
//! it.
//!
//! Painted only where something changed. A page that has not moved paints
//! nothing on a pass. One that scrolled moves the rows that stay on screen
//! with `Surface.shift` and paints only the band it uncovered, because
//! moving a row is one copy and drawing its text is a glyph at a time. Only
//! a new page, a new width, a picture arriving or the window being uncovered
//! paints all of it.
//!
//! A page's controls are the toolkit's own: its text field, its button, its
//! check box, run each pass where the layout put them, clipped to the view so
//! that one half scrolled out neither paints nor answers outside it. What is
//! typed in them and which boxes are ticked is kept here, for as long as the
//! page is shown.
//!
//! A page's pictures are drawn from what `pictures` keeps, sampled to the
//! room the layout gave them. One that has not arrived is stood in for by what
//! the page says it shows, in a frame the size the page gives it where it
//! gives one, so the words around it are already where they will stay.

const std = @import("std");
const eui = @import("eui");
const layout_mod = @import("layout.zig");
const page_mod = @import("page.zig");
const pictures_mod = @import("pictures.zig");

const Rect = eui.Rect;
const Surface = eui.Surface;
const Theme = eui.Theme;
const Control = page_mod.Control;
const Face = page_mod.Face;
const Page = page_mod.Page;
const Layout = layout_mod.Layout;
const Size = layout_mod.Size;
const Spacing = layout_mod.Spacing;
const Pictures = pictures_mod.Pictures;

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

/// What a page is drawn on, which shows through a picture's see-through
/// parts.
pub fn ground() eui.draw.Color {
    return eui.theme.current().surface_hot;
}

/// What a face is on this system, measured at the size it is drawn, and the
/// room the page's controls and pictures take.
const Metrics = struct {
    scale: i32,
    pictures: *const Pictures,

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
    pub fn control(self: Metrics, page: *const Page, which: Control) Size {
        const t = eui.theme.current();
        return switch (which.kind) {
            .line => |line| .{ .w = @as(i32, line.letters) * self.width(.body, "n") + 2 * t.padding, .h = t.control_height },
            .submit, .reset => |press| .{ .w = self.width(.body, page.string(press.label)) + 4 * t.padding, .h = t.control_height },
            .tick => .{ .w = t.control_height, .h = t.control_height },
            .hidden => .{ .w = 0, .h = 0 },
        };
    }

    /// The room a picture takes in a column `room` wide: the size it is drawn
    /// at once it is here, and until then the size the page gives it where it
    /// gives both sides, never wider than the column and keeping its shape.
    /// Where neither is known, or it will not come, what stands in for it
    /// takes the room instead.
    pub fn picture(self: Metrics, page: *const Page, index: u16, room: i32) Size {
        const which = page.pictures.items[index];
        const state = self.pictures.stateOf(index);
        const coming = switch (state) {
            .waiting, .coming => self.pictures.expected(),
            .here, .failed => false,
        };
        const drawn: ?Size = switch (state) {
            .here => |kept| drawnSize(which, kept.own),
            .waiting, .coming, .failed => if (coming) givenSize(which) else null,
        };
        if (drawn) |size| return fitted(size, self.scale, room);
        return self.standIn(page, which, coming, room);
    }

    /// The room what stands in for a picture takes: what the page says it
    /// shows, on one line in a frame, or while it is coming and the page says
    /// nothing, a frame with the picture sign in it. One that will not come
    /// and of which the page says nothing takes no room.
    fn standIn(self: Metrics, page: *const Page, which: page_mod.Picture, coming: bool, room: i32) Size {
        const t = eui.theme.current();
        const alt = page.string(which.alt);
        if (alt.len > 0) return .{ .w = @min(self.width(.body, alt) + 2 * t.padding, room), .h = t.control_height };
        if (coming) return .{ .w = t.control_height, .h = t.control_height };
        return .{ .w = 0, .h = 0 };
    }
};

/// The size a picture is drawn at, in the page's pixels: what the page gives,
/// with a side it leaves out taken from the picture's own shape, and the
/// picture's own size where the page gives neither.
fn drawnSize(which: page_mod.Picture, own: pictures_mod.Size) Size {
    const w: i32 = own.w;
    const h: i32 = own.h;
    if (which.width) |given| {
        const given_w: i32 = given;
        return .{ .w = given_w, .h = if (which.height) |given_h| given_h else @divTrunc(given_w * h, @max(w, 1)) };
    }
    if (which.height) |given| {
        const given_h: i32 = given;
        return .{ .w = @divTrunc(given_h * w, @max(h, 1)), .h = given_h };
    }
    return .{ .w = w, .h = h };
}

/// The size the page gives a picture, where it gives both sides: room that
/// can be kept for it before it arrives.
fn givenSize(which: page_mod.Picture) ?Size {
    return .{ .w = which.width orelse return null, .h = which.height orelse return null };
}

/// A size in the page's pixels as the interface draws it: never wider than
/// `room`, and keeping its shape where it has to be narrower.
fn fitted(size: Size, scale: i32, room: i32) Size {
    const w = size.w * scale;
    const h = size.h * scale;
    if (w <= room) return .{ .w = w, .h = h };
    return .{ .w = room, .h = @max(@divTrunc(h * room, @max(w, 1)), 1) };
}

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
    /// The page is to be laid out again on the next pass: a picture arrived
    /// or gave up, and the room it takes changed with it.
    stale: bool = false,
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

    /// Lay the page out again on the next pass.
    pub fn relayout(self: *View) void {
        self.stale = true;
    }

    /// How far down the page the view is, as a percentage.
    pub fn position(self: *const View, area: Rect) u8 {
        const reach = self.layout.height - area.h;
        if (reach <= 0) return 100;
        return @intCast(@divTrunc(@min(self.scroll, reach) * 100, reach));
    }

    /// The first of the page's pictures at or below the top of the view,
    /// which is where fetching them goes on from: what is being looked at
    /// comes first.
    pub fn pictureFrom(self: *const View) u16 {
        const page = self.page orelse return 0;
        const lines = self.layout.lines.items;
        var i = self.layout.lineAt(self.scroll);
        while (i < lines.len) : (i += 1) {
            for (self.layout.fragsOf(lines[i])) |frag| switch (page.runs.items[frag.run]) {
                .picture => |index| return index,
                .text, .control, .line_break => {},
            };
        }
        return 0;
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
    pub fn run(self: *View, gpa: std.mem.Allocator, ctx: *eui.Context, area: Rect, pictures: *const Pictures) ?Action {
        const page = self.page orelse return null;
        const metrics = Metrics{ .scale = eui.theme.textScale(), .pictures = pictures };
        const column = columnOf(area, metrics.scale);
        const spacing = Spacing.forLine(metrics.height(.body));

        // Laid out again only when the column's width changed or a picture
        // changed the room it takes: a pass that is only a scroll or a
        // pointer moving reuses every line. The words at the top of the view
        // stay there, whatever moved above them.
        if (self.stale or self.layout.width != column.w) {
            const mark = self.layout.markAt(self.scroll);
            self.layout.deinit(gpa);
            self.layout = layout_mod.build(gpa, page, column.w, spacing, metrics) catch .{ .width = column.w };
            if (mark) |kept| {
                if (self.layout.lineOf(kept.place)) |y| self.scroll = @max(y + (self.scroll - kept.y), 0);
            }
            self.stale = false;
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
            .pictures = pictures,
            .surface = ctx.surface,
            .theme = eui.theme.current(),
            .metrics = metrics,
            .spacing = spacing,
            .column = column,
            .area = area,
        };

        // What is painted this pass: all of it, the band a scroll uncovered,
        // or nothing. A page painted afresh counts as moved, because laid
        // out again its controls may stand somewhere new.
        const moved = if (before) |was| was.scroll != scroll else true;
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
                    .text, .picture, .line_break => continue,
                };
                const rect = pass.boxRect(lines[i], frag);
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

    /// The link at a point in the window, if there is one there: words that
    /// go somewhere, or a picture inside a link.
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
                .picture => |which| page.pictures.items[which].link,
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
    pictures: *const Pictures,
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
        s.fill(band, ground());

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
                .picture => |which| {
                    self.picture(s, at, frag, which);
                    continue;
                },
                .control, .line_break => continue,
            };
            const words = frag.shape.words;
            const face = text.look.face;
            const ink = switch (text.look.ink) {
                .text => t.text,
                .dim => t.text_dim,
                .link => t.accent,
            };
            const left = self.column.x + frag.x;
            s.textIn(Metrics.font(face), left, y + at.baseline - self.metrics.ascent(face), self.page.text.items[words.start..][0..words.len], ink);
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

    /// A picture that is here, sampled to the room the layout gave it; one
    /// that is not, stood in for by a frame holding what the page says it
    /// shows, or the picture sign where it says nothing.
    fn picture(self: Pass, s: Surface, at: layout_mod.Line, frag: layout_mod.Frag, index: u16) void {
        const rect = self.boxRect(at, frag);
        if (rect.isEmpty()) return;
        switch (self.pictures.stateOf(index)) {
            .here => |kept| return eui.thumb.paint(s, rect, .{
                .pixels = kept.picture.pixels,
                .width = kept.picture.width,
                .height = kept.picture.height,
            }, .up),
            .waiting, .coming, .failed => {},
        }

        const t = self.theme;
        s.frame(rect, t.line);
        const alt = self.page.string(self.page.pictures.items[index].alt);
        if (alt.len == 0) return s.iconCentred(rect, .picture, t.text_dim);
        // Inside the frame and in from its sides, on the first line of it.
        const inside = Rect{ .x = rect.x + t.padding, .y = rect.y + 1, .w = rect.w - 2 * t.padding, .h = rect.h - 2 };
        const top = rect.y + @divTrunc(@min(rect.h, t.control_height) - self.metrics.height(.body), 2);
        s.clipped(inside).textIn(Metrics.font(.body), inside.x, top, alt, t.text_dim);
    }

    /// Where a control or a picture is drawn: as wide as the layout made it
    /// and as tall as it said, with its bottom where the words' descent ends.
    fn boxRect(self: Pass, at: layout_mod.Line, frag: layout_mod.Frag) Rect {
        const descent = self.metrics.height(.body) - self.metrics.ascent(.body);
        const bottom = self.area.y + at.y - self.view.scroll + at.baseline + descent;
        const h = frag.shape.box;
        return .{ .x = self.column.x + frag.x, .y = bottom - h, .w = frag.width, .h = h };
    }
};

/// The column a page is set in: the measure, or less where the window is
/// narrower, centred in what there is.
fn columnOf(area: Rect, scale: i32) Rect {
    const width = @max(@min(MEASURE * scale, area.w - 2 * MARGIN * scale), 1);
    return .{ .x = area.x + @divTrunc(area.w - width, 2), .y = area.y, .w = width, .h = area.h };
}
