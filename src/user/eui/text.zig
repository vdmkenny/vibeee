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
//!
//! Measured in pixels rather than columns, because the face is proportional.
//! A terminal is the only thing here that wants a grid, and it has its own.

const std = @import("std");
const draw = @import("draw.zig");
const scroll = @import("scroll.zig");
const eui_context_menu = @import("context_menu.zig");
const str = @import("lib").str;
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

/// Walk the visual lines of `text` wrapped at `width` pixels.
///
/// One definition of a line, used by drawing and by cursor movement alike. Two
/// would drift, and the symptom is a cursor that draws in a different place
/// from the one it edits at.
pub const Lines = struct {
    text: []const u8,
    font: *const draw.Font,
    width: i32,
    pos: usize = 0,
    finished: bool = false,

    pub fn next(self: *Lines) ?Line {
        if (self.finished) return null;

        const start = self.pos;
        var i = start;
        var x: i32 = 0;
        // Where the last space was, so a break can fall between words.
        var space: ?usize = null;

        while (i < self.text.len) {
            const byte = self.text[i];
            if (byte == '\n') {
                self.pos = i + 1;
                if (self.pos > self.text.len) self.finished = true;
                return .{ .start = start, .end = i, .next = i + 1 };
            }

            const n = sequenceLength(byte);
            const advance: i32 = @intCast(self.font.measure(self.text[i..@min(i + n, self.text.len)]));

            // Never breaks before the first character: a window narrower than
            // one glyph would otherwise produce lines that hold nothing and
            // never advance.
            if (x + advance > self.width and i > start) {
                // Breaking after the space keeps it on the line above, where a
                // trailing space is invisible, rather than starting the next
                // line with one.
                const at = if (space) |sp| sp + 1 else i;
                self.pos = at;
                return .{ .start = start, .end = at, .next = at };
            }

            if (byte == ' ') space = i;
            i += n;
            x += advance;
        }

        self.finished = true;
        return .{ .start = start, .end = self.text.len, .next = self.text.len };
    }
};

pub fn lines(text: []const u8, font: *const draw.Font, width: i32) Lines {
    return .{ .text = text, .font = font, .width = @max(width, 1) };
}

/// How many visual lines `text` occupies.
pub fn count(text: []const u8, font: *const draw.Font, width: i32) usize {
    var n: usize = 0;
    var it = lines(text, font, width);
    while (it.next()) |_| n += 1;
    return n;
}

/// Which visual line an offset falls on, and how far along it in pixels.
pub const Position = struct { line: usize, x: i32 };

pub fn positionOf(text: []const u8, font: *const draw.Font, width: i32, offset: usize) Position {
    var index: usize = 0;
    var it = lines(text, font, width);
    var last = Line{ .start = 0, .end = 0, .next = 0 };
    var last_index: usize = 0;

    while (it.next()) |line| : (index += 1) {
        // The first line that has not gone past the offset yet. `next` rather
        // than `end`, so an offset on a newline belongs to the line that
        // newline terminates rather than to the one after it.
        if (offset < line.next) {
            const upto = text[line.start..@min(@max(offset, line.start), line.end)];
            return .{ .line = index, .x = @intCast(font.measure(upto)) };
        }
        last = line;
        last_index = index;
    }

    // Past every line, which is where the cursor sits at the end of the text.
    // Reached by falling through rather than by a test inside the loop: a
    // document ending in a newline has a last line that is empty and holds
    // nothing to compare against, and treating the end of the text as part of
    // the line before it put the cursor at the end of the previous line until
    // the next character was typed.
    return .{ .line = last_index, .x = @intCast(font.measure(text[last.start..last.end])) };
}

/// The line at `index`, or the last one.
pub fn lineAt(text: []const u8, font: *const draw.Font, width: i32, index: usize) Line {
    var it = lines(text, font, width);
    var last = Line{ .start = 0, .end = 0, .next = 0 };
    var i: usize = 0;

    while (it.next()) |line| : (i += 1) {
        last = line;
        if (i == index) return line;
    }
    return last;
}

/// The offset nearest `x` pixels into a line.
///
/// Nearest rather than the one it falls inside, so clicking the right half of
/// a character puts the cursor after it, which is where a click there means.
pub fn offsetAt(text: []const u8, font: *const draw.Font, line: Line, x: i32) usize {
    var i = line.start;
    var pen: i32 = 0;

    while (i < line.end) {
        const n = sequenceLength(text[i]);
        const advance: i32 = @intCast(font.measure(text[i..@min(i + n, text.len)]));
        if (x < pen + @divTrunc(advance, 2)) return i;
        pen += advance;
        i += n;
    }
    return line.end;
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
    /// The pixel column to aim for when moving up and down, so a cursor
    /// crossing a short line comes back to where it was rather than staying at
    /// its end.
    goal: ?i32 = null,
    /// Set on any change to the text, for the caller's modified flag.
    edited: bool = false,
    bar: scroll.State = .{},

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

/// The face text is edited in. The interface face, not the terminal's: a
/// document is read, and a grid is for a program that draws one.
pub const face: *const draw.Font = draw.ui_font;

/// Which line and column an offset is at, counted from one because that is
/// how every other thing that says "line 9" counts.
pub const Place = struct { line: usize, column: usize };

pub fn placeOf(text: []const u8, offset: usize) Place {
    var at = Place{ .line = 1, .column = 1 };
    var i: usize = 0;
    while (i < offset and i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            at.line += 1;
            at.column = 1;
        } else if (text[i] & 0xC0 != 0x80) {
            // Continuation bytes are the same character as the byte before
            // them, so a column is characters rather than bytes.
            at.column += 1;
        }
    }
    return at;
}

/// How many lines the document has.
pub fn lineCount(text: []const u8) usize {
    var n: usize = 1;
    for (text) |byte| {
        if (byte == '\n') n += 1;
    }
    return n;
}

/// The inside of a text area: its frame and padding taken off.
pub fn inner(area: Rect) Rect {
    return area.inset(2);
}

/// The same, less the scrollbar, which is what the text actually wraps into.
fn writable(area: Rect, scrollable: bool) Rect {
    var box = inner(area);
    if (scrollable) box.w -= scroll.WIDTH;
    return box;
}

pub fn rowsIn(area: Rect) usize {
    const h: usize = @intCast(@max(inner(area).h, 1));
    return @max(h / @as(usize, face.height), 1);
}

/// An editable, scrolling, soft-wrapped text area.
pub fn edit(ctx: *widget.Context, area: Rect, state: *Editor, buffer: *Buffer) void {
    const entry = ctx.slotFor(area) orelse return;
    const act = ctx.interact(entry, area);
    const entry_index = act.index;

    const rows = rowsIn(area);
    const line_height: i32 = @intCast(face.height);

    // Whether there is a scrollbar changes how wide the text may be, which
    // changes how many lines there are. Measured against the narrower width so
    // the answer cannot flip back and forth between the two.
    const wrapped = count(buffer.slice(), face, writable(area, true).w);
    const scrollable = wrapped > rows;
    const box = writable(area, scrollable);

    var changed = false;

    // Where the pointer is, in the text. One conversion, used by the click
    // that puts the cursor somewhere and by the drag that selects.
    const under = struct {
        fn at(state_in: *const Editor, buffer_in: *const Buffer, box_in: Rect, ctx_in: *const widget.Context, height: i32) usize {
            const text = buffer_in.slice();
            const line_index = state_in.scroll +
                @as(usize, @intCast(@max(@divTrunc(ctx_in.pointer_y - box_in.y, height), 0)));
            const line = lineAt(text, face, box_in.w, line_index);
            return offsetAt(text, face, line, ctx_in.pointer_x - box_in.x);
        }
    }.at;

    if (act.over and ctx.pressedThisPass()) {
        // Held with shift, a click extends what is selected rather than
        // starting again, which is how a long selection is made without
        // dragging across a screen this size.
        state.moveTo(under(state, buffer, box, ctx, line_height), ctx.key_mods.shift);
        state.goal = null;
        changed = true;
    }

    // Dragging selects. The press already put the cursor where it started,
    // so every move after it extends from there.
    if (act.holding and !ctx.pressedThisPass()) {
        const to = under(state, buffer, box, ctx, line_height);
        if (to != state.cursor) {
            state.moveTo(to, true);
            state.goal = null;
            changed = true;
        }
    }

    // The other button offers what can be done to the text, wherever the
    // pointer is: over a selection or not, the rows are the same and the ones
    // that do not apply do nothing.
    if (act.over and ctx.rightPressedThisPass()) {
        eui_context_menu.open(ctx, entry_index, &MENU_ROWS);
        ctx.damage();
    }

    if (act.over) {
        const wheel = ctx.takeWheel();
        if (wheel != 0) {
            const limit = wrapped -| rows;
            state.scroll = @min(if (wheel < 0) state.scroll + 3 else state.scroll -| 3, limit);
            changed = true;
        }
    }

    // The keyboard's way to the same menu: the key next to the space bar
    // that has this picture on it, and the chord for a keyboard without one.
    // A menu reachable only by pointer is a menu that stops working when the
    // touchpad does.
    const asked_for_menu = ctx.pending_key == @intFromEnum(KeyCode.menu) or
        (ctx.pending_key == @intFromEnum(KeyCode.f10) and ctx.key_mods.shift);
    if (ctx.focus == entry_index and asked_for_menu) {
        ctx.pending_key = 0;
        const here = positionOf(buffer.slice(), face, box.w, state.cursor);
        const row: i32 = @intCast(here.line -| state.scroll);
        eui_context_menu.openAt(box.x + here.x, box.y + (row + 1) * line_height, entry_index, &MENU_ROWS);
        ctx.damage();
    }

    if (ctx.takeKeyFor(entry)) |code| {
        if (key(state, buffer, @enumFromInt(code), ctx.key_mods, box.w, rows, ctx.clipboard)) changed = true;
    }
    if (ctx.takeTextFor(entry)) |codepoint| {
        if (insert(state, buffer, codepoint)) changed = true;
    }

    // Follow the cursor. Done after every input rather than in each branch, so
    // a caller that moved the cursor itself gets it too.
    const here = positionOf(buffer.slice(), face, box.w, state.cursor);
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
        paint(ctx.surface, area, box, state, buffer, rows, act.focused);
        ctx.addDamage(area);
    }

    // Last, so it stands over the text it belongs to.
    if (eui_context_menu.openedBy(entry_index)) {
        if (eui_context_menu.run(ctx)) |row| {
            if (commandOf(row)) |command| {
                if (run(state, buffer, command, ctx.clipboard)) ctx.damage();
            }
        }
    }

    // After the text, so it draws over the frame rather than under it.
    if (scrollable) {
        const bar = Rect{
            .x = inner(area).right() - scroll.WIDTH,
            .y = box.y,
            .w = scroll.WIDTH,
            .h = box.h,
        };
        const dragged = ctx.scrollbar(bar, &state.bar, state.scroll, wrapped, rows);
        if (dragged != state.scroll) {
            state.scroll = dragged;
            ctx.damage();
        }
    }
}

/// What cut, copy and paste do, and what the other mouse button offers.
///
/// Held here rather than in each program: every text field on the system
/// should answer the same three chords, and a program that had to implement
/// them is a program that will implement two of them.
pub const Command = enum { cut, copy, paste, select_all };

pub fn run(state: *Editor, buffer: *Buffer, what: Command, clip: widget.Clipboard) bool {
    switch (what) {
        .copy => {
            const span = state.selection() orelse return false;
            clip.put(buffer.slice()[span.from..span.to]);
            return false;
        },
        .cut => {
            const span = state.selection() orelse return false;
            clip.put(buffer.slice()[span.from..span.to]);
            return state.deleteSelection(buffer);
        },
        .paste => {
            const text = clip.get();
            if (text.len == 0) return false;
            _ = state.deleteSelection(buffer);
            if (!buffer.insert(state.cursor, text)) return false;
            state.cursor += text.len;
            state.goal = null;
            state.edited = true;
            return true;
        },
        .select_all => {
            if (buffer.len == 0) return false;
            state.anchor = 0;
            state.cursor = buffer.len;
            state.goal = null;
            return true;
        },
    }
}

/// A paragraph of text that is read, wrapped into `area` and nothing more.
///
/// Returns the height it took, so whatever comes under it knows where to
/// start: a page whose prose is one line longer in another language should
/// push what follows down rather than draw over it.
pub fn paragraph(surface: Surface, area: Rect, words: []const u8, ink: draw.Color) i32 {
    const line_height: i32 = @intCast(face.height);
    const clipped = surface.clipped(area);

    var y = area.y;
    var it = lines(words, face, area.w);
    while (it.next()) |line| {
        clipped.text(area.x, y, words[line.start..line.end], ink);
        y += line_height;
    }
    return y - area.y;
}

/// Every chord a text field or a document answers, and what it does.
///
/// Here rather than in whatever draws a help page: these belong to the
/// toolkit, work in every window without any program asking for them, and a
/// list kept somewhere else is a list that says the old ones.
pub const CHORDS = [_]struct { chord: []const u8, says: []const u8 }{
    .{ .chord = "Ctrl+X", .says = "cut what is selected" },
    .{ .chord = "Ctrl+C", .says = "copy it" },
    .{ .chord = "Ctrl+V", .says = "paste" },
    .{ .chord = "Ctrl+A", .says = "select everything" },
    .{ .chord = "Ctrl+W", .says = "delete the word before the cursor" },
    .{ .chord = "Ctrl+U", .says = "delete to the start of the line" },
    .{ .chord = "Ctrl+Left, Ctrl+Right", .says = "move a word at a time" },
    .{ .chord = "Ctrl+Home, Ctrl+End", .says = "the start and end of the document" },
    .{ .chord = "Shift+any of these", .says = "select while moving" },
    .{ .chord = "Menu, Shift+F10", .says = "the menu the other mouse button opens" },
};

/// The rows the other mouse button opens, in the order every system puts
/// them, each with the chord that does the same thing.
const MENU_ROWS = [_]widget.MenuItem{
    .{ .label = "Cut", .mark = .cut, .detail = "Ctrl+X" },
    .{ .label = "Copy", .mark = .copy, .detail = "Ctrl+C" },
    .{ .label = "Paste", .mark = .paste, .detail = "Ctrl+V" },
    .{ .kind = .separator },
    .{ .label = "Select all", .mark = .select_all, .detail = "Ctrl+A" },
};

fn commandOf(row: usize) ?Command {
    return switch (row) {
        0 => .cut,
        1 => .copy,
        2 => .paste,
        4 => .select_all,
        else => null,
    };
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
    width: i32,
    rows: usize,
    clip: widget.Clipboard,
) bool {
    const text = buffer.slice();
    const extend = mods.shift;

    // The three chords, before the keys they are held with mean anything
    // else: Ctrl+C is not a C, and a field that typed one would be a field
    // nobody could copy out of.
    if (mods.control) {
        const what: ?Command = switch (code) {
            .x => .cut,
            .c => .copy,
            .v => .paste,
            .a => .select_all,
            else => null,
        };
        if (what) |command| {
            _ = run(state, buffer, command, clip);
            return true;
        }

        // The two the shell answers, so a field and a prompt take the same
        // corrections: back over a word, and away with the line.
        switch (code) {
            .w => {
                if (!state.deleteSelection(buffer)) {
                    const from = str.wordBefore(text, state.cursor);
                    if (from < state.cursor) {
                        buffer.remove(from, state.cursor);
                        state.cursor = from;
                        state.edited = true;
                    }
                }
                state.goal = null;
                return true;
            },
            .u => {
                const here = positionOf(text, face, width, state.cursor);
                const from = lineAt(text, face, width, here.line).start;
                state.anchor = null;
                if (from < state.cursor) {
                    buffer.remove(from, state.cursor);
                    state.cursor = from;
                    state.edited = true;
                }
                state.goal = null;
                return true;
            },
            else => {},
        }
    }

    switch (code) {
        .left => {
            const to = if (mods.control) str.wordBefore(text, state.cursor) else buffer.before(state.cursor);
            state.moveTo(to, extend);
            state.goal = null;
        },
        .right => {
            const to = if (mods.control) str.wordAfter(text, state.cursor) else buffer.after(state.cursor);
            state.moveTo(to, extend);
            state.goal = null;
        },
        .up => vertical(state, text, width, -1, extend),
        .down => vertical(state, text, width, 1, extend),
        .page_up => vertical(state, text, width, -@as(i32, @intCast(rows)), extend),
        .page_down => vertical(state, text, width, @intCast(rows), extend),
        // Held with the modifier the two ends are the document's, which is
        // what every editor has meant by it for thirty years.
        .home => {
            if (mods.control) {
                state.moveTo(0, extend);
            } else {
                const here = positionOf(text, face, width, state.cursor);
                state.moveTo(lineAt(text, face, width, here.line).start, extend);
            }
            state.goal = null;
        },
        .end => {
            if (mods.control) {
                state.moveTo(text.len, extend);
            } else {
                const here = positionOf(text, face, width, state.cursor);
                state.moveTo(lineAt(text, face, width, here.line).end, extend);
            }
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

fn vertical(state: *Editor, text: []const u8, width: i32, by: i32, extend: bool) void {
    const here = positionOf(text, face, width, state.cursor);
    const goal = state.goal orelse here.x;

    const target: usize = if (by < 0)
        here.line -| @as(usize, @intCast(-by))
    else
        here.line + @as(usize, @intCast(by));

    const line = lineAt(text, face, width, target);
    state.moveTo(offsetAt(text, face, line, goal), extend);
    // Kept across the move, so a run of Up keys tracks the original column
    // rather than the shortest line it passed through.
    state.goal = goal;
}

fn paint(
    surface: Surface,
    area: Rect,
    box: Rect,
    state: *const Editor,
    buffer: *const Buffer,
    rows: usize,
    focused: bool,
) void {
    const t = theme.current();
    const text = buffer.slice();
    const line_height: i32 = @intCast(face.height);

    surface.fill(area, t.surface_hot);
    surface.frame(area, if (focused) t.accent else t.line);

    const span = state.selection();
    const clipped = surface.clipped(box);

    var it = lines(text, face, box.w);
    var index: usize = 0;
    var drawn: usize = 0;

    while (it.next()) |line| : (index += 1) {
        if (index < state.scroll) continue;
        if (drawn >= rows) break;

        const y = box.y + @as(i32, @intCast(drawn)) * line_height;
        var x = box.x;
        var i = line.start;

        while (i < line.end) {
            const n = sequenceLength(text[i]);
            const piece = text[i..@min(i + n, text.len)];
            const advance: i32 = @intCast(face.measure(piece));
            const selected = if (span) |sp| i >= sp.from and i < sp.to else false;

            if (selected) {
                clipped.fill(.{ .x = x, .y = y, .w = advance, .h = line_height }, t.accent);
            }
            clipped.text(x, y, piece, if (selected) t.accent_text else t.text);

            x += advance;
            i += n;
        }

        // A newline inside the selection shows as a marked space, so a
        // multi-line selection does not look like it stops at each line end.
        if (span) |sp| {
            if (line.next > line.end and line.end >= sp.from and line.end < sp.to) {
                const space: i32 = @intCast(face.advance(' '));
                clipped.fill(.{ .x = x, .y = y, .w = space, .h = line_height }, t.accent);
            }
        }

        drawn += 1;
    }

    if (focused and span == null) paintCursor(clipped, box, state, text, line_height);
}

fn paintCursor(
    surface: Surface,
    box: Rect,
    state: *const Editor,
    text: []const u8,
    line_height: i32,
) void {
    const here = positionOf(text, face, box.w, state.cursor);
    if (here.line < state.scroll) return;

    const x = box.x + here.x;
    const y = box.y + @as(i32, @intCast(here.line - state.scroll)) * line_height;
    // A bar between characters rather than a block over one: this is an
    // insertion point, and a block says the character under it is selected.
    surface.fill(.{ .x = x, .y = y, .w = 1, .h = line_height }, theme.current().text);
}

/// A one-line text field.
///
/// The same editor with Enter meaning "done" rather than "new line". Returns
/// true on the pass where Enter was pressed, which is what a field is usually
/// waiting for.
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

    edit(ctx, area, state, buffer);
    return accepted;
}
