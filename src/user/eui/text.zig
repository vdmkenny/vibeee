//! Editable text: a buffer, the lines it breaks into, and a control that edits
//! it.
//!
//! Split the way the terminal is, and for the same reason. The buffer and the
//! line walker are arithmetic over bytes with no window in sight, so they can
//! be tested on the host; the control on top of them is the part that needs a
//! surface and a keyboard.
//!
//! Soft wrapped rather than horizontally scrolled. On a panel 800 pixels wide
//! a document that runs off the side is a document read one scroll bar drag at
//! a time, and wrapping means the cursor only ever has to move in two
//! directions.

const std = @import("std");
const draw = @import("draw.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;
const KeyCode = widget.KeyCode;

/// How many bytes a UTF-8 sequence starting with this byte occupies.
///
/// Everything here moves by whole characters, because a cursor between the two
/// halves of an accented letter is a cursor that can delete half of one.
pub fn sequenceLength(first: u8) usize {
    if (first < 0x80) return 1;
    if (first & 0xE0 == 0xC0) return 2;
    if (first & 0xF0 == 0xE0) return 3;
    if (first & 0xF8 == 0xF0) return 4;
    return 1;
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

// ---------------------------------------------------------------------------
// The buffer
// ---------------------------------------------------------------------------

/// Text in storage the caller owns.
///
/// A flat array, moved on every edit. A gap buffer would be faster and is not
/// needed: the documents this opens are kilobytes, and moving a few of those
/// is thousands of times less work than drawing the result.
pub const Buffer = struct {
    bytes: []u8,
    len: usize = 0,

    pub fn slice(self: *const Buffer) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn clear(self: *Buffer) void {
        self.len = 0;
    }

    /// Insert at a byte offset. False when it would not fit, which the caller
    /// has to notice: silently dropping what someone typed is worse than
    /// refusing it.
    pub fn insert(self: *Buffer, at: usize, text: []const u8) bool {
        if (self.len + text.len > self.bytes.len) return false;
        const point = @min(at, self.len);

        std.mem.copyBackwards(
            u8,
            self.bytes[point + text.len ..][0 .. self.len - point],
            self.bytes[point..self.len],
        );
        @memcpy(self.bytes[point..][0..text.len], text);
        self.len += text.len;
        return true;
    }

    pub fn remove(self: *Buffer, from: usize, to: usize) void {
        const start = @min(from, self.len);
        const end = @min(@max(to, start), self.len);
        if (end == start) return;

        std.mem.copyForwards(u8, self.bytes[start..], self.bytes[end..self.len]);
        self.len -= end - start;
    }

    /// The offset of the character before `at`.
    pub fn before(self: *const Buffer, at: usize) usize {
        if (at == 0) return 0;
        var i = @min(at, self.len) - 1;
        while (i > 0 and isContinuation(self.bytes[i])) i -= 1;
        return i;
    }

    /// The offset of the character after `at`.
    pub fn after(self: *const Buffer, at: usize) usize {
        if (at >= self.len) return self.len;
        return @min(at + sequenceLength(self.bytes[at]), self.len);
    }
};

// ---------------------------------------------------------------------------
// Lines
// ---------------------------------------------------------------------------

pub const Line = struct {
    start: usize,
    /// One past the last byte shown. A wrapped line's break is not shown, and
    /// neither is the newline that ends a hard one.
    end: usize,
    /// The offset the next line starts at, which skips a newline and does not
    /// skip a wrap.
    next: usize,
};

/// Walk the visual lines of `text` wrapped at `columns` characters.
///
/// One definition of a line, used by drawing and by cursor movement alike. Two
/// would drift, and the symptom is a cursor that draws in a different place
/// from the one it edits at.
pub const Lines = struct {
    text: []const u8,
    columns: usize,
    pos: usize = 0,
    finished: bool = false,

    pub fn next(self: *Lines) ?Line {
        if (self.finished) return null;

        const start = self.pos;
        var i = start;
        var column: usize = 0;
        // Where the last space was, so a break can fall between words.
        var space: ?usize = null;

        while (i < self.text.len) {
            const byte = self.text[i];
            if (byte == '\n') {
                self.pos = i + 1;
                if (self.pos > self.text.len) self.finished = true;
                return .{ .start = start, .end = i, .next = i + 1 };
            }

            if (column == self.columns) {
                // Breaking after the space keeps it on the line above, where a
                // trailing space is invisible, rather than starting the next
                // line with one.
                const at = if (space) |s| s + 1 else i;
                self.pos = at;
                return .{ .start = start, .end = at, .next = at };
            }

            if (byte == ' ') space = i;
            i += sequenceLength(byte);
            column += 1;
        }

        self.finished = true;
        return .{ .start = start, .end = self.text.len, .next = self.text.len };
    }
};

pub fn lines(text: []const u8, columns: usize) Lines {
    return .{ .text = text, .columns = @max(columns, 1) };
}

/// How many visual lines `text` occupies.
pub fn count(text: []const u8, columns: usize) usize {
    var n: usize = 0;
    var it = lines(text, columns);
    while (it.next()) |_| n += 1;
    return n;
}

/// Which visual line an offset falls on, and how far along it.
pub const Position = struct { line: usize, column: usize };

pub fn positionOf(text: []const u8, columns: usize, offset: usize) Position {
    var index: usize = 0;
    var it = lines(text, columns);

    while (it.next()) |line| {
        // `next` rather than `end`, so an offset on a newline belongs to the
        // line it terminates rather than to the one after.
        if (offset < line.next or line.next == text.len) {
            return .{ .line = index, .column = columnOf(text[line.start..@min(@max(offset, line.start), line.end)]) };
        }
        index += 1;
    }
    return .{ .line = index -| 1, .column = 0 };
}

/// The line at `index`, or the last one.
pub fn lineAt(text: []const u8, columns: usize, index: usize) Line {
    var it = lines(text, columns);
    var last = Line{ .start = 0, .end = 0, .next = 0 };
    var i: usize = 0;

    while (it.next()) |line| : (i += 1) {
        last = line;
        if (i == index) return line;
    }
    return last;
}

/// The offset `column` characters into a line.
pub fn offsetIn(text: []const u8, line: Line, column: usize) usize {
    var i = line.start;
    var n: usize = 0;
    while (i < line.end and n < column) : (n += 1) {
        i += sequenceLength(text[i]);
    }
    return i;
}

fn columnOf(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) i += sequenceLength(text[i]);
    return n;
}

// ---------------------------------------------------------------------------
// The control
// ---------------------------------------------------------------------------

/// What an editable text area remembers between passes.
pub const Editor = struct {
    /// Byte offset of the insertion point.
    cursor: usize = 0,
    /// Where a selection began, or null when there is none.
    anchor: ?usize = null,
    /// First visual line shown.
    scroll: usize = 0,
    /// The column to aim for when moving up and down, so a cursor crossing a
    /// short line comes back to where it was rather than staying at its end.
    goal: ?usize = null,
    /// Set on any change to the text, for the caller's modified flag.
    edited: bool = false,

    pub fn selection(self: *const Editor) ?struct { from: usize, to: usize } {
        const anchor = self.anchor orelse return null;
        if (anchor == self.cursor) return null;
        return .{ .from = @min(anchor, self.cursor), .to = @max(anchor, self.cursor) };
    }

    /// Put the cursor somewhere, extending or dropping the selection.
    fn moveTo(self: *Editor, offset: usize, extend: bool) void {
        if (extend) {
            if (self.anchor == null) self.anchor = self.cursor;
        } else {
            self.anchor = null;
        }
        self.cursor = offset;
    }

    fn deleteSelection(self: *Editor, buffer: *Buffer) bool {
        const span = self.selection() orelse return false;
        buffer.remove(span.from, span.to);
        self.cursor = span.from;
        self.anchor = null;
        self.edited = true;
        return true;
    }
};

pub fn columnsIn(area: Rect) usize {
    const w: usize = @intCast(@max(area.w - 4, 1));
    return @max(w / @as(usize, draw.mono_font.width), 1);
}

pub fn rowsIn(area: Rect) usize {
    const h: usize = @intCast(@max(area.h - 4, 1));
    return @max(h / @as(usize, draw.mono_font.height), 1);
}

/// An editable, scrolling, soft-wrapped text area.
///
/// Monospaced, because wrapping and cursor movement are arithmetic on column
/// counts and a proportional face would make every one of them a measurement.
pub fn edit(ctx: *widget.Context, area: Rect, state: *Editor, buffer: *Buffer) void {
    const entry = ctx.slotFor(area) orelse return;
    const act = ctx.interact(entry, area);

    const columns = columnsIn(area);
    const rows = rowsIn(area);
    const cw: i32 = @intCast(draw.mono_font.width);
    const ch: i32 = @intCast(draw.mono_font.height);

    var changed = false;

    if (act.over and ctx.pressedThisPass()) {
        const text = buffer.slice();
        const line_index = state.scroll +
            @as(usize, @intCast(@max(@divTrunc(ctx.pointer_y - area.y - 2, ch), 0)));
        const line = lineAt(text, columns, line_index);
        const column: usize = @intCast(@max(@divTrunc(ctx.pointer_x - area.x - 2, cw), 0));
        state.moveTo(offsetIn(text, line, column), false);
        state.goal = null;
        changed = true;
    }

    if (act.over) {
        const wheel = ctx.takeWheel();
        if (wheel != 0) {
            const total = count(buffer.slice(), columns);
            const limit = total -| rows;
            state.scroll = @min(if (wheel < 0) state.scroll + 3 else state.scroll -| 3, limit);
            changed = true;
        }
    }

    if (ctx.takeKeyFor(entry)) |code| {
        if (key(state, buffer, @enumFromInt(code), ctx.key_mods, columns, rows)) changed = true;
    }
    if (ctx.takeTextFor(entry)) |codepoint| {
        if (insert(state, buffer, codepoint)) changed = true;
    }

    // Follow the cursor. Done after every input rather than in each branch, so
    // a caller that moved the cursor itself gets it too.
    const here = positionOf(buffer.slice(), columns, state.cursor);
    if (here.line < state.scroll) {
        state.scroll = here.line;
        changed = true;
    }
    if (here.line >= state.scroll + rows) {
        state.scroll = here.line + 1 - rows;
        changed = true;
    }

    if (changed or ctx.needsPaint(entry, .idle)) {
        entry.visual = .idle;
        paint(ctx.surface, area, state, buffer, columns, rows, act.focused);
        ctx.addDamage(area);
    }
}

fn insert(state: *Editor, buffer: *Buffer, codepoint: u32) bool {
    if (codepoint < 0x20 and codepoint != '\t') return false;

    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(codepoint), &utf8) catch return false;

    _ = state.deleteSelection(buffer);
    if (!buffer.insert(state.cursor, utf8[0..n])) return false;

    state.cursor += n;
    state.goal = null;
    state.edited = true;
    return true;
}

fn key(
    state: *Editor,
    buffer: *Buffer,
    code: KeyCode,
    mods: widget.Modifiers,
    columns: usize,
    rows: usize,
) bool {
    const text = buffer.slice();
    const extend = mods.shift;

    switch (code) {
        .left => {
            state.moveTo(buffer.before(state.cursor), extend);
            state.goal = null;
        },
        .right => {
            state.moveTo(buffer.after(state.cursor), extend);
            state.goal = null;
        },
        .up => vertical(state, text, columns, -1, extend),
        .down => vertical(state, text, columns, 1, extend),
        .page_up => vertical(state, text, columns, -@as(i32, @intCast(rows)), extend),
        .page_down => vertical(state, text, columns, @intCast(rows), extend),
        .home => {
            const here = positionOf(text, columns, state.cursor);
            state.moveTo(lineAt(text, columns, here.line).start, extend);
            state.goal = null;
        },
        .end => {
            const here = positionOf(text, columns, state.cursor);
            state.moveTo(lineAt(text, columns, here.line).end, extend);
            state.goal = null;
        },
        .enter, .kp_enter => {
            _ = state.deleteSelection(buffer);
            if (!buffer.insert(state.cursor, "\n")) return true;
            state.cursor += 1;
            state.goal = null;
            state.edited = true;
        },
        .tab => {
            _ = state.deleteSelection(buffer);
            if (!buffer.insert(state.cursor, "    ")) return true;
            state.cursor += 4;
            state.goal = null;
            state.edited = true;
        },
        .backspace => {
            if (!state.deleteSelection(buffer)) {
                const from = buffer.before(state.cursor);
                if (from == state.cursor) return true;
                buffer.remove(from, state.cursor);
                state.cursor = from;
                state.edited = true;
            }
            state.goal = null;
        },
        .delete => {
            if (!state.deleteSelection(buffer)) {
                buffer.remove(state.cursor, buffer.after(state.cursor));
                state.edited = true;
            }
            state.goal = null;
        },
        else => return false,
    }
    return true;
}

fn vertical(state: *Editor, text: []const u8, columns: usize, by: i32, extend: bool) void {
    const here = positionOf(text, columns, state.cursor);
    const goal = state.goal orelse here.column;

    const target: usize = if (by < 0)
        here.line -| @as(usize, @intCast(-by))
    else
        here.line + @as(usize, @intCast(by));

    const line = lineAt(text, columns, target);
    state.moveTo(offsetIn(text, line, goal), extend);
    // Kept across the move, so a run of Up keys tracks the original column
    // rather than the shortest line it passed through.
    state.goal = goal;
}

fn paint(
    surface: Surface,
    area: Rect,
    state: *const Editor,
    buffer: *const Buffer,
    columns: usize,
    rows: usize,
    focused: bool,
) void {
    const t = theme.current();
    const text = buffer.slice();
    const cw: i32 = @intCast(draw.mono_font.width);
    const ch: i32 = @intCast(draw.mono_font.height);

    surface.fill(area, t.surface_hot);
    surface.frame(area, if (focused) t.accent else t.line);

    const span = state.selection();
    const inner = surface.clipped(area.inset(2));

    var it = lines(text, columns);
    var index: usize = 0;
    var drawn: usize = 0;

    while (it.next()) |line| : (index += 1) {
        if (index < state.scroll) continue;
        if (drawn >= rows) break;

        const y = area.y + 2 + @as(i32, @intCast(drawn)) * ch;
        var x = area.x + 2;
        var i = line.start;

        while (i < line.end) {
            const n = sequenceLength(text[i]);
            const selected = if (span) |s| i >= s.from and i < s.to else false;

            if (selected) {
                inner.fill(.{ .x = x, .y = y, .w = cw, .h = ch }, t.accent);
            }
            inner.textIn(
                draw.mono_font,
                x,
                y,
                text[i..@min(i + n, text.len)],
                if (selected) t.accent_text else t.text,
            );

            x += cw;
            i += n;
        }

        // A newline inside the selection shows as a marked space, so a
        // multi-line selection does not look like it stops at each line end.
        if (span) |s| {
            if (line.next > line.end and line.end >= s.from and line.end < s.to) {
                inner.fill(.{ .x = x, .y = y, .w = cw, .h = ch }, t.accent);
            }
        }

        drawn += 1;
    }

    if (focused and span == null) paintCursor(inner, area, state, text, columns, cw, ch);
}

fn paintCursor(
    surface: Surface,
    area: Rect,
    state: *const Editor,
    text: []const u8,
    columns: usize,
    cw: i32,
    ch: i32,
) void {
    const here = positionOf(text, columns, state.cursor);
    if (here.line < state.scroll) return;

    const x = area.x + 2 + @as(i32, @intCast(here.column)) * cw;
    const y = area.y + 2 + @as(i32, @intCast(here.line - state.scroll)) * ch;
    // A bar between characters rather than a block over one: this is an
    // insertion point, and a block says the character under it is selected.
    surface.fill(.{ .x = x, .y = y, .w = 1, .h = ch }, theme.current().text);
}

/// A one-line text field.
///
/// The same editor with the wrapping turned off and Enter meaning "done"
/// rather than "new line". Returns true on the pass where Enter was pressed,
/// which is what a field is usually waiting for.
pub fn field(ctx: *widget.Context, area: Rect, state: *Editor, buffer: *Buffer) bool {
    // Enter is taken before the editor sees it, so it never lands in the text.
    const entry = ctx.slotFor(area) orelse return false;
    var accepted = false;

    if (ctx.focus == ctx.indexOf(entry) and ctx.pending_key != 0) {
        const code: KeyCode = @enumFromInt(ctx.pending_key);
        if (code == .enter or code == .kp_enter) {
            ctx.pending_key = 0;
            accepted = true;
        }
    }

    // A field is one line, so its width in columns is what it can hold before
    // the text runs off the end rather than wraps.
    edit(ctx, area, state, buffer);
    return accepted;
}
