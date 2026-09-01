//! A scrolling table of rows.
//!
//! The control every list of things ends up wanting: columns with headings, a
//! selection that survives a refresh, a scrollbar, and the keys a person will
//! try without being told. Kept out of `widget.zig` because it is as large as
//! the rest of the controls put together and shares nothing with them beyond
//! the pass machinery.

const draw = @import("draw.zig");
const icons = @import("icon.zig");
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
    /// This column takes whatever width is left over. The one that holds a
    /// name, usually: the numbers beside it are as wide as numbers get, and
    /// stretching one of those would leave a column of figures adrift from
    /// its heading. Without one, the last column stretches.
    flex: bool = false,
};

pub const Row = struct {
    cells: [MAX_COLUMNS][]const u8 = @splat(""),
    /// Indent applied to the column marked `tree`, for showing a tree in a
    /// table.
    depth: u8 = 0,
    /// Drawn in the accent colour. For the one row that is the subject of
    /// whatever the window is about.
    marked: bool = false,
    /// A picture before the first cell. The column is indented for it when
    /// any row in the table has one, so names still line up under each other.
    icon: ?icons.Icon = null,
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
    /// Every other row on a quieter ground. What a wide table of short rows
    /// needs to be read across: the eye follows the stripe rather than
    /// counting down from the top.
    striped: bool = false,
    /// The heading drawn in the accent, for a table that is the focus of a
    /// window holding more than one.
    head_accent: bool = false,
    /// Which column the rows are ordered by, and which way. The table does
    /// not sort: it says what was asked for, and the caller sorts, because
    /// only the caller knows whether a column of text is a number, a size or
    /// a name.
    sort: ?Sort = null,
};

pub const Sort = struct {
    column: usize,
    /// Descending is what a column of numbers is asked for first: somebody
    /// clicking "cpu" wants the busy one, not the idle one.
    descending: bool = true,

    /// The mark drawn beside the heading, which is the only thing that says
    /// which way a list is ordered.
    pub fn mark(self: Sort) icons.Icon {
        return if (self.descending) .sort_down else .sort_up;
    }
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

    // The headings are what a table is sorted by. Clicking one orders by it,
    // and clicking it again turns it round: the first click on a new column
    // is descending, because a column of numbers is asked for largest first.
    const header = Rect{ .x = area.x, .y = area.y, .w = area.w, .h = row_h };
    if (act.over and ctx.pressedThisPass() and header.contains(ctx.pointer_x, ctx.pointer_y)) {
        if (columnAt(columns, area, ctx.pointer_x)) |index| {
            if (state.sort) |current| {
                state.sort = if (current.column == index)
                    .{ .column = index, .descending = !current.descending }
                else
                    .{ .column = index };
            } else {
                state.sort = .{ .column = index };
            }
            ctx.damage();
        }
    }

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

/// Which heading a point falls on.
fn columnAt(columns: []const Column, area: Rect, x: i32) ?usize {
    var at = area.x + 2;
    for (columns, 0..) |_, i| {
        const w = columnWidth(columns, i, area.w);
        if (x >= at and x < at + w) return i;
        at += w;
    }
    return null;
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
    h.flag(state.striped);
    h.flag(state.head_accent);
    if (state.sort) |by| {
        h.number(by.column);
        h.flag(by.descending);
    }
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
    const head = Rect{ .x = area.x, .y = area.y, .w = area.w, .h = row_h };
    surface.fill(head, if (state.head_accent) t.accent else t.surface_pressed);

    var x = area.x + 2;
    for (columns, 0..) |column, i| {
        const w = columnWidth(columns, i, area.w);
        const ordered = if (state.sort) |by| by.column == i else false;
        const head_ink = if (state.head_accent)
            t.accent_text
        else if (ordered)
            t.text
        else
            t.text_dim;

        const title_x = if (column.right)
            x + columnWidth(columns, i, area.w) - 2 - Surface.textWidth(column.title)
        else
            x;
        surface.text(title_x, area.y + 2, column.title, head_ink);
        if (ordered) {
            surface.icon(
                title_x + Surface.textWidth(column.title) + 2,
                area.y + 2,
                state.sort.?.mark(),
                head_ink,
            );
        }
        x += w;
    }
    surface.fill(.{ .x = area.x, .y = area.y + row_h, .w = area.w, .h = 1 }, t.line);

    // One row with a picture indents them all, so the names line up whether
    // or not the row above has one.
    var pictured = false;
    for (rows) |row| {
        if (row.icon != null) pictured = true;
    }

    const last = @min(state.scroll + visible, rows.len);
    var y = body.y;
    for (rows[@min(state.scroll, rows.len)..last], state.scroll..) |row, index| {
        const line = Rect{ .x = body.x, .y = y, .w = body.w, .h = row_h };
        const selected = index == state.selected;

        if (selected) {
            surface.fill(line, if (focused) t.accent else t.surface_pressed);
        } else if (hovered == index) {
            surface.fill(line, t.surface_hot);
        } else if (state.striped and index % 2 == 1) {
            surface.fill(line, t.surface_hot);
        }

        const ink = if (selected and focused)
            t.accent_text
        else if (row.marked)
            t.accent
        else
            t.text;

        if (row.icon) |which| {
            surface.icon(line.x + 3, Surface.iconTopFor(y + 2), which, ink);
        }

        var cx = line.x + 2;
        for (columns, 0..) |column, i| {
            const w = columnWidth(columns, i, area.w);
            const cell = row.cells[i];
            const indent: i32 = (if (column.tree) @as(i32, row.depth) * 10 else 0) +
                (if (i == 0 and pictured) Surface.iconSize() + 4 else 0);

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
    const stretched = flexColumn(columns);
    if (index != stretched) return columns[index].width;

    var used: i32 = 0;
    for (columns, 0..) |c, i| {
        if (i != stretched) used += c.width;
    }
    return @max(total - used - 4, columns[index].width);
}

/// Which column takes the leftover width.
fn flexColumn(columns: []const Column) usize {
    for (columns, 0..) |c, i| {
        if (c.flex) return i;
    }
    return columns.len -| 1;
}

