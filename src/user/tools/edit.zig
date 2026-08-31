//! edit: change a text and write it to a file.
//!
//! What the document does with characters is `lib.text`'s, and what a
//! full-screen program does with the console is the pager's. What is left,
//! and all that is here, is the arrangement: get the text from somewhere,
//! turn keys into edits, keep the cursor on screen, and write it out.
//!
//! Where the text comes from is a question with three answers, and none of
//! them is special: a file named on the command line, whatever is being
//! piped in, or nothing at all. A document with no name behind it is an
//! ordinary document that will ask for one when it is saved, which is also
//! what opening a second file from inside relies on.
//!
//! Nothing is written until asked. A file opened and looked at is a file
//! left alone, and a file that would not fit is refused rather than saved
//! back as its own first half.

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
/// Wrapped or not, numbered or not. The same two choices the reader offers,
/// meaning the same thing, because they are the same setting drawn by the
/// same code.
var layout = pager.Layout{};
/// What the bar says until the next key, for the answers to saving and to
/// quitting with unsaved work.
var notice: []const u8 = "";
/// A quit asked for once with unsaved work, waiting to be asked again.
var pending_quit = false;

/// The longest name a file may have here, which bounds both the document's
/// own name and what a prompt will take.
const PATH_MAX = 128;

var path: []const u8 = "";
var path_buf: [PATH_MAX]u8 = @splat(0);

/// A prompt in the bar, and what it is for once it is answered.
const Asking = enum { nothing, open_file, save_as };
var asking: Asking = .nothing;
var prompt: pager.Prompt = undefined;
var prompt_buf: [PATH_MAX]u8 = @splat(0);
var prompt_marks: [2]u32 = @splat(0);

pub fn run(args: []const []const u8) void {
    if (args.len != 0) {
        if (!name(args[0])) {
            say("edit: that name is longer than this holds\n");
            return;
        }
        load();
    } else if (!piped()) {
        // No file and nothing coming in: an empty document with no name,
        // which is what a blank sheet is.
        doc.load("");
    }

    pager.takeScreen();
    defer pager.giveBackScreen();

    while (true) {
        draw();
        if (!handle(pager.key())) break;
    }
}

/// Take a name for the document.
fn name(what: []const u8) bool {
    if (what.len == 0 or what.len > path_buf.len) return false;
    @memcpy(path_buf[0..what.len], what);
    path = path_buf[0..what.len];
    return true;
}

/// Whether something is feeding standard input, and if so take it as the
/// document. A pipe's read end is waitable and the interactive console is
/// not, which is the whole of the question: `log | edit` opens the log,
/// and a bare `edit` at the prompt opens nothing and waits for no one.
fn piped() bool {
    if (sys.waitMany(&[_]u32{sys.STDIN}, sys.FOREVER) < 0) return false;

    var filled: usize = 0;
    while (filled < storage.len) {
        const n = sys.read(sys.STDIN, storage[filled..]);
        if (n <= 0) break;
        filled += @intCast(n);
    }
    if (filled == 0) return false;

    take(filled);
    // Named after nothing: it came from a pipe, and saving it will ask.
    notice = "from standard input; Ctrl+S will ask for a name";
    return true;
}

// ---------------------------------------------------------------------------
// The file
// ---------------------------------------------------------------------------

/// Read the named file, or start an empty document when there is none. A
/// name that does not exist yet is how a new file is written, not an error.
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
    take(filled);
}

/// Take bytes already sitting in the document's own storage as its
/// contents. The read went straight there, so there is nothing to copy:
/// what is left is counting the lines and putting the cursor at the front.
fn take(filled: usize) void {
    doc.len = filled;
    doc.truncated = filled == storage.len;
    doc.dirty = false;
    doc.cursor = .{};
    doc.wanted = 0;
    doc.index();
    top = 0;
    left = 0;

    if (doc.truncated) notice = "too long to hold; saving is refused";
}

/// Save, asking for a name first when the document has none.
fn saveOrAsk() void {
    if (path.len == 0) {
        ask(.save_as, "save as: ");
        return;
    }
    save();
}

/// Write the document out to its file.
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
    if (asking != .nothing) return answer(event);

    const code: sys.KeyCode = @enumFromInt(event.code);
    const held = event.mods();

    // Anything but a second quit clears a pending one: asking to leave and
    // then typing means the answer was no.
    const was_pending = pending_quit;
    pending_quit = false;
    notice = "";

    if (held.control) {
        switch (code) {
            .s => saveOrAsk(),
            .o => ask(.open_file, "open: "),
            .q, .x => return leave(was_pending),
            .a => doc.move(.line_start),
            .e => doc.move(.line_end),
            .w => layout.wrap = !layout.wrap,
            .n => layout.numbers = !layout.numbers,
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

/// Put a question in the bar. Everything behind it stays on screen, and
/// the next keys go to it instead of to the document.
fn ask(what: Asking, label: []const u8) void {
    // Opening over unsaved work would lose it, so that question is asked
    // before the one about which file.
    if (what == .open_file and doc.dirty) {
        notice = "unsaved: save with Ctrl+S first, or press Ctrl+Q twice to leave";
        return;
    }
    asking = what;
    prompt = pager.Prompt.over(label, &prompt_buf, &prompt_marks, if (what == .save_as) "" else path);
}

/// A key while a question is up.
fn answer(event: sys.KeyEvent) bool {
    switch (prompt.key(event)) {
        .typing => return true,
        .cancelled => {
            asking = .nothing;
            notice = "";
            return true;
        },
        .accepted => {},
    }

    const wanted = prompt.answer();
    const what = asking;
    asking = .nothing;

    if (wanted.len == 0) {
        notice = "no name given";
        return true;
    }
    if (!name(wanted)) {
        notice = "that name is longer than this holds";
        return true;
    }

    switch (what) {
        .open_file => load(),
        .save_as => save(),
        .nothing => {},
    }
    return true;
}

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

/// The document, as something the shared drawing can walk.
fn lineOf(ctx: *const anyopaque, n: usize) []const u8 {
    const document: *const text.Document = @ptrCast(@alignCast(ctx));
    return document.line(n);
}

fn lines() pager.Lines {
    return .{ .count = doc.lines, .ctx = &doc, .at = lineOf };
}

fn draw() void {
    const size = pager.frame();
    const where = pager.Cell{ .line = doc.cursor.line, .column = doc.column() };

    // The cursor is what the screen follows. Sideways only when lines are
    // not folded: a wrapped line has no side to run off.
    top = pager.follow(lines(), top, size, layout, where);
    if (layout.wrap) {
        left = 0;
    } else {
        const margin: usize = if (layout.numbers) text.digits(doc.lines) + 1 else 0;
        const width = if (size.columns > margin + 1) size.columns - margin - 1 else 1;
        left = text.follow(left, width, where.column);
    }

    pager.begin();
    pager.body(lines(), top, left, size, layout, where);
    pager.end(bar());
}

fn bar() []const u8 {
    var buf: [pager.MAX_COLUMNS]u8 = undefined;

    // A question takes the whole bar: while one is up there is nothing to
    // say about the document that is more urgent than the answer.
    if (asking != .nothing) return keep(prompt.bar(&buf));

    var line = str.Builder{ .buf = &buf };

    // A document from a pipe, or a blank sheet, has no name yet. Saying so
    // beats a bar that begins with nothing.
    line.text(if (path.len == 0) "(unnamed)" else path);
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
        line.text("   ^S save  ^O open  ^W wrap  ^N numbers  ^Q quit");
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
