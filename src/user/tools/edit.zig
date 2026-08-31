//! edit: change a file and write it back.
//!
//! What the document does with characters is `lib.text`'s, and what a
//! full-screen program does with the console is the pager's. What is left,
//! and all that is here, is the arrangement: read the file, turn keys into
//! edits, keep the cursor on screen, and write it out again.
//!
//! Nothing is written until asked. A file opened and looked at is a file
//! left alone, and a file that would not fit is refused rather than saved
//! back as its own first half.

const ink = @import("ulib").ink;
const out = @import("ulib").out;
const pager = @import("ulib").pager;
const str = @import("ulib").str;
const sys = @import("sys");
const text = @import("lib").text;

/// The largest file this edits. Sized against the machine rather than
/// against ambition: a hundred and ninety thousand characters is longer
/// than anything written by hand, and it is memory committed for the whole
/// run whether or not the file needs it.
const CAPACITY = 192 * 1024;

/// How many lines that many characters can be cut into. A file of nothing
/// but newlines reaches this first, which is why it is not derived.
const MAX_LINES = 8192;

var storage: [CAPACITY]u8 = @splat(0);
var index: [MAX_LINES + 1]u32 = @splat(0);

var doc = text.Document{ .bytes = &storage, .line_at = &index };

/// The first row on screen, and the first character of each line, both of
/// which the cursor drags around: a screen too narrow for a line is the same
/// problem as one too short for a file.
var top: usize = 0;
var left: usize = 0;
/// What the bar says until the next key, for the answers to saving and to
/// quitting with unsaved work.
var notice: []const u8 = "";
/// A quit asked for once with unsaved work, waiting to be asked again.
var pending_quit = false;

var path: []const u8 = "";
var path_buf: [128]u8 = @splat(0);

pub fn run(args: []const []const u8) void {
    if (args.len == 0) {
        say("usage: edit <file>\n");
        return;
    }
    if (args[0].len > path_buf.len) {
        say("edit: that name is longer than this holds\n");
        return;
    }
    @memcpy(path_buf[0..args[0].len], args[0]);
    path = path_buf[0..args[0].len];

    load();

    pager.takeScreen();
    defer pager.giveBackScreen();

    while (true) {
        draw();
        if (!handle(pager.key())) break;
    }
}

// ---------------------------------------------------------------------------
// The file
// ---------------------------------------------------------------------------

/// Read the file, or start an empty document when there is none. A name
/// that does not exist yet is how a new file is written, not an error.
fn load() void {
    const file = sys.open(path, .{});
    if (file < 0) {
        doc.load("");
        notice = "new file";
        return;
    }
    defer _ = sys.close(@intCast(file));

    var filled: usize = 0;
    while (filled < storage.len) {
        const n = sys.read(@intCast(file), storage[filled..]);
        if (n <= 0) break;
        filled += @intCast(n);
    }

    // Loading copies within the same array, which is what `load` is for:
    // it counts the lines and puts the cursor at the start. The bytes are
    // already where they belong.
    doc.len = filled;
    doc.truncated = filled == storage.len;
    doc.dirty = false;
    doc.cursor = .{};
    doc.wanted = 0;
    doc.index();

    if (doc.truncated) notice = "too long to hold; saving is refused";
}

/// Write the document back over the file it came from.
fn save() void {
    // A document that was cut on the way in would be saved as its own head,
    // which destroys the tail of the file. Refused, always.
    if (doc.truncated) {
        notice = "not saved: this file is longer than the editor holds";
        return;
    }

    const file = sys.open(path, .{ .write = true, .create = true, .truncate = true });
    if (file < 0) {
        notice = "not saved: cannot open the file for writing";
        return;
    }
    defer _ = sys.close(@intCast(file));

    const whole = doc.contents();
    var written: usize = 0;
    while (written < whole.len) {
        const n = sys.write(@intCast(file), whole[written..]);
        if (n <= 0) break;
        written += @intCast(n);
    }

    if (written < whole.len) {
        notice = "not saved: the write stopped short";
        return;
    }
    doc.dirty = false;
    notice = "saved";
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

/// Act on one key. Answers whether the editor carries on.
fn handle(event: sys.KeyEvent) bool {
    const code: sys.KeyCode = @enumFromInt(event.code);
    const held = event.mods();

    // Anything but a second quit clears a pending one: asking to leave and
    // then typing means the answer was no.
    const was_pending = pending_quit;
    pending_quit = false;
    notice = "";

    if (held.control) {
        switch (code) {
            .s => save(),
            .q, .x => return leave(was_pending),
            .a => doc.move(.line_start),
            .e => doc.move(.line_end),
            .home => doc.move(.document_start),
            .end => doc.move(.document_end),
            else => {},
        }
        return true;
    }

    switch (code) {
        .escape => return leave(was_pending),
        .left => doc.move(.left),
        .right => doc.move(.right),
        .up => doc.move(.up),
        .down => doc.move(.down),
        .home => doc.move(.line_start),
        .end => doc.move(.line_end),
        .page_up => doc.moveBy(pager.frame().window, false),
        .page_down => doc.moveBy(pager.frame().window, true),
        .enter => _ = doc.newline(),
        .backspace => _ = doc.backspace(),
        .delete => _ = doc.delete(),
        .tab => {
            // Spaces, because the console draws a tab as one cell and the
            // column arithmetic would then disagree with the screen about
            // where the cursor is.
            var n: usize = 0;
            while (n < TAB) : (n += 1) _ = doc.insert(' ');
        },
        else => {
            // Everything else is whatever the layout made of it, which is
            // how an accented key types an accented character.
            if (event.codepoint >= 0x20 and event.codepoint != 0x7F) {
                _ = doc.insert(@intCast(event.codepoint));
            }
        },
    }
    return true;
}

/// How wide a tab is here.
const TAB = 4;

/// Leaving, which unsaved work makes a question rather than an answer.
fn leave(asked_before: bool) bool {
    if (!doc.dirty or asked_before) return false;
    pending_quit = true;
    notice = "unsaved: press again to leave, or Ctrl+S to save";
    return true;
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

fn draw() void {
    const size = pager.frame();
    // The cursor is what the screen follows, in both directions. One column
    // is kept back so the cursor at the end of a full line has a cell of its
    // own to sit in rather than wrapping the row.
    const width = if (size.columns > 1) size.columns - 1 else 1;
    top = text.follow(top, size.window, doc.cursor.line);
    left = text.follow(left, width, doc.column());

    pager.begin();

    var row: usize = 0;
    while (row < size.window) : (row += 1) {
        const n = top + row;
        if (n < doc.lines) {
            const shown = text.window(doc.line(n), left, width);
            if (n == doc.cursor.line) {
                withCursor(shown, doc.column() - left);
            } else {
                out.text(shown);
            }
        }
        out.byte('\n');
    }

    pager.end(bar());
}

/// One line with the cursor shown in it.
///
/// The cursor is a reversed cell rather than the console's own: the screen
/// is redrawn whole every keystroke, so a cursor drawn into the text lands
/// in the right place by construction and needs no second thing to keep in
/// step with the first.
fn withCursor(line: []const u8, at: usize) void {
    const before = text.window(line, 0, at);
    out.text(before);

    const on = text.window(line, at, 1);
    ink.reverse();
    // Past the end of the line the cursor has no character to sit on, so it
    // sits on a space.
    if (on.len == 0) out.byte(' ') else out.text(on);
    ink.plain();

    out.text(text.window(line, at + 1, line.len));
}

fn bar() []const u8 {
    var buf: [pager.MAX_COLUMNS]u8 = undefined;
    var line = str.Builder{ .buf = &buf };

    line.text(path);
    if (doc.dirty) line.text(" *");
    line.text("  ");
    line.number(doc.cursor.line + 1);
    line.byte(':');
    line.number(doc.column() + 1);
    line.text(" of ");
    line.number(doc.lines);

    if (notice.len != 0) {
        line.text("   ");
        line.text(notice);
    } else {
        line.text("   Ctrl+S save   Ctrl+Q quit");
    }
    return keep(line.done());
}

/// The bar's text outlives the builder it was written in, so it is copied
/// somewhere that lasts as long as the frame being drawn.
var bar_buf: [pager.MAX_COLUMNS]u8 = @splat(0);

fn keep(what: []const u8) []const u8 {
    const n = @min(what.len, bar_buf.len);
    @memcpy(bar_buf[0..n], what[0..n]);
    return bar_buf[0..n];
}

fn say(what: []const u8) void {
    out.text(what);
    out.flush();
}
