//! A scrolling table of rows.
//!
//! The control every list of things ends up wanting: columns with headings, a
//! selection that survives a refresh, a scrollbar, and the keys a person will
//! try without being told. Kept out of `widget.zig` because it is as large as
//! the rest of the controls put together and shares nothing with them beyond
//! the pass machinery.

const draw = @import("draw.zig");
const scroll = @import("scroll.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;
const KeyCode = widget.KeyCode;

/// Enough for a process list, which is the widest thing here. A row is a fixed
/// array rather than a slice so the caller can build one on the stack.
pub const MAX_COLUMNS = 6;

pub const Column = struct {
    title: []const u8,
    /// Width in pixels. The last column is stretched to fill whatever is left,
    /// so for that one this is a minimum.
    width: i32,
    /// Numbers read better right-aligned against each other. Names do not.
    right: bool = false,
    /// This column carries `Row.depth` as indentation. The tree is drawn on
    /// whichever column names the thing, which is rarely the first.
    tree: bool = false,
};

pub const Row = struct {
    cells: [MAX_COLUMNS][]const u8 = @splat(""),
    /// Indent applied to the column marked `tree`, for showing a tree in a
    /// table.
    depth: u8 = 0,
    /// Drawn in the accent colour. For the one row that is the subject of
    /// whatever the window is about.
    marked: bool = false,
};

/// What the control remembers between passes.
///
/// The caller owns it: which row is selected outlives any one pass, and a
/// table that forgot the selection every refresh would be unusable for the
/// thing tables are for.
pub const State = struct {
    selected: usize = 0,
    scroll: usize = 0,
    bar: scroll.State = .{},
};

pub fn rowHeight() i32 {
    return Surface.textHeight() + 4;
}

/// Draw and run the table. Returns the row activated this pass, by double
/// click or by Enter, or null.
pub fn run(
    ctx: *widget.Context,
    area: Rect,
    state: *State,
    columns: []const Column,
    rows: []const Row,
) ?usize {
    const entry = ctx.slotFor(area) orelse return null;
    const act = ctx.interact(entry, area);

    const row_h = rowHeight();
    const header_h = row_h + 1;
    const body = Rect{
        .x = area.x,
        .y = area.y + header_h,
        .w = area.w,
        .h = area.h - header_h,
    };
    const visible = @max(@as(usize, @intCast(@max(@divTrunc(body.h, row_h), 0))), 1);

    const hovered: ?usize = if (act.over and body.contains(ctx.pointer_x, ctx.pointer_y)) blk: {
        const index = state.scroll + @as(usize, @intCast(@divTrunc(ctx.pointer_y - body.y, row_h)));
        break :blk if (index < rows.len) index else null;
    } else null;

    var activated: ?usize = null;

    if (hovered) |index| {
        if (ctx.pressedThisPass()) {
            // A second click on the row already selected opens it, which is
            // what a double click amounts to without tracking the interval.
            if (state.selected == index) activated = index;
            state.selected = index;
            ctx.damage();
        }
    }

    if (act.over) {
        const wheel = ctx.takeWheel();
        if (wheel != 0) {
            state.scroll = wheeled(state.scroll, wheel, rows.len, visible);
            ctx.damage();
        }
    }

    if (ctx.takeKeyFor(entry)) |code| {
        const before = state.selected;
        switch (@as(KeyCode, @enumFromInt(code))) {
            .up => state.selected -|= 1,
            .down => state.selected += 1,
            .page_up => state.selected -|= visible,
            .page_down => state.selected += visible,
            .home => state.selected = 0,
            .end => state.selected = rows.len -| 1,
            .enter, .space => activated = state.selected,
            else => {},
        }
        if (state.selected >= rows.len) state.selected = rows.len -| 1;
        if (state.selected != before) ctx.damage();
    }

    // Keep the selection on screen. Done after every input rather than in each
    // branch, so a caller that changes the selection itself gets it too.
    if (state.selected < state.scroll) state.scroll = state.selected;
    if (state.selected >= state.scroll + visible) state.scroll = state.selected + 1 - visible;
    if (state.scroll + visible > rows.len) state.scroll = rows.len -| visible;

    // Repaint when anything visible differs from last pass. A table's contents
    // change under it constantly, so comparing what would be drawn is the only
    // check that is both cheap and right.
    const signature = fingerprint(rows, state, hovered, act.focused, visible);
    if (ctx.needsPaint(entry, .idle) or entry.detail != signature) {
        entry.detail = signature;
        entry.visual = .idle;
        paint(ctx.surface, area, body, columns, rows, state, hovered, act.focused, visible);
        ctx.addDamage(area);
    }

    // After the rows, or they would be drawn over it.
    const bar = Rect{
        .x = body.right() - scroll.WIDTH,
        .y = body.y,
        .w = scroll.WIDTH,
        .h = body.h,
    };
    const dragged = ctx.scrollbar(bar, &state.bar, state.scroll, rows.len, visible);
    if (dragged != state.scroll and rows.len > visible) {
        state.scroll = dragged;
        ctx.damage();
    }

    return activated;
}

fn wheeled(at: usize, wheel: i8, count: usize, visible: usize) usize {
    const step: usize = 3;
    const limit = count -| visible;
    const moved = if (wheel < 0) at + step else at -| step;
    return @min(moved, limit);
}

/// Everything the table would draw, hashed.
fn fingerprint(
    rows: []const Row,
    state: *const State,
    hovered: ?usize,
    focused: bool,
    visible: usize,
) i32 {
    var h = widget.Fingerprint{};
    h.number(state.scroll);
    h.number(state.selected);
    h.number(hovered orelse ~@as(usize, 0));
    h.flag(focused);
    h.number(rows.len);

    const last = @min(state.scroll + visible, rows.len);
    for (rows[@min(state.scroll, rows.len)..last]) |row| {
        for (row.cells) |cell| h.text(cell);
        h.number(row.depth);
    }

    return h.done();
}

fn paint(
    surface: Surface,
    area: Rect,
    body_full: Rect,
    columns: []const Column,
    rows: []const Row,
    state: *const State,
    hovered: ?usize,
    focused: bool,
    visible: usize,
) void {
    const t = theme.current();
    const row_h = rowHeight();
    // The rows stop where the scrollbar starts, so nothing is drawn under it.
    const body = if (rows.len > visible)
        Rect{ .x = body_full.x, .y = body_full.y, .w = body_full.w - scroll.WIDTH, .h = body_full.h }
    else
        body_full;

    surface.fill(area, t.surface);

    // Headings, then a rule. A heading that scrolled with the rows would be
    // worse than none.
    var x = area.x + 2;
    for (columns, 0..) |column, i| {
        const w = columnWidth(columns, i, area.w);
        surface.text(x, area.y + 2, column.title, t.text_dim);
        x += w;
    }
    surface.fill(.{ .x = area.x, .y = area.y + row_h, .w = area.w, .h = 1 }, t.line);

    const last = @min(state.scroll + visible, rows.len);
    var y = body.y;
    for (rows[@min(state.scroll, rows.len)..last], state.scroll..) |row, index| {
        const line = Rect{ .x = body.x, .y = y, .w = body.w, .h = row_h };
        const selected = index == state.selected;

        if (selected) {
            surface.fill(line, if (focused) t.accent else t.surface_pressed);
        } else if (hovered == index) {
            surface.fill(line, t.surface_hot);
        }

        const ink = if (selected and focused)
            t.accent_text
        else if (row.marked)
            t.accent
        else
            t.text;

        var cx = line.x + 2;
        for (columns, 0..) |column, i| {
            const w = columnWidth(columns, i, area.w);
            const cell = row.cells[i];
            const indent: i32 = if (column.tree) @as(i32, row.depth) * 10 else 0;

            if (column.right) {
                const text_w = Surface.textWidth(cell);
                surface.text(cx + w - text_w - 6, y + 2, cell, ink);
            } else {
                surface.text(cx + indent, y + 2, cell, ink);
            }
            cx += w;
        }

        y += row_h;
    }

    surface.frame(area, if (focused) t.accent else t.line);
}

/// The last column absorbs the leftover width, so a table always fills its area
/// however the caller sized the ones before it.
fn columnWidth(columns: []const Column, index: usize, total: i32) i32 {
    if (index + 1 < columns.len) return columns[index].width;

    var used: i32 = 0;
    for (columns[0 .. columns.len - 1]) |c| used += c.width;
    return @max(total - used - 4, columns[index].width);
}

