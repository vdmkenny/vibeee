//! Pad: a text editor.
//!
//! Opens a file, edits it, writes it back. Plain text for now; the styled
//! writing `design/00-vibeee.md` §10.8 describes needs a document model that
//! carries runs of attributes, and a plain editor that works is worth more
//! than a rich one that does not.
//!
//! Everything it does with text is `libeui`'s, which is where an editable area
//! belongs: the next program that needs one should not write a second.

const std = @import("std");
const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const str = @import("ulib").str;

const theme = eui.theme;
const Rect = eui.Rect;
const text = eui.text;

/// The largest document. Sized against what this machine has rather than what
/// a desktop would allow: half a megabyte of editable text is more than
/// anything on a four gigabyte disk here, and it is committed memory.
const CAPACITY = 64 * 1024;

/// The frame's context, which is where every control call goes. The frame
/// also owns the connection, which the dialog borrows for its own window.
const ctx = &proto.app.ctx;
const connection = &proto.app.connection;

var storage: [CAPACITY]u8 = undefined;
var document: text.Buffer = undefined;
var editor: text.Editor = .{};

/// Where the document came from and where Save writes it back.
var file_path: [128]u8 = @splat(0);
var file_len: usize = 0;

/// What the menus offer. The application names its commands; the bar draws
/// them and says which one was chosen.
///
/// The editing half is the toolkit's: the menu names the same operations
/// every text field on the system already answers by chord and by the other
/// mouse button, so choosing Copy here and pressing Ctrl+C go to one
/// implementation.
const Command = enum(u16) {
    new,
    open,
    save,
    save_as,
    close,
    cut,
    copy,
    paste,
    select_all,
    status_bar,
};

const MENUS = [_]eui.menubar.Menu{
    .{ .label = "File", .items = &.{
        .{ .label = "New", .id = @intFromEnum(Command.new), .shortcut = "Ctrl+N" },
        .{ .label = "Open...", .id = @intFromEnum(Command.open), .shortcut = "Ctrl+O" },
        eui.menubar.Item.separator,
        .{ .label = "Save", .id = @intFromEnum(Command.save), .shortcut = "Ctrl+S" },
        .{ .label = "Save as...", .id = @intFromEnum(Command.save_as), .shortcut = "Ctrl+Shift+S" },
        eui.menubar.Item.separator,
        .{ .label = "Close", .id = @intFromEnum(Command.close), .shortcut = "Ctrl+Q" },
    } },
    .{ .label = "Edit", .items = &.{
        .{ .label = "Cut", .id = @intFromEnum(Command.cut), .shortcut = "Ctrl+X" },
        .{ .label = "Copy", .id = @intFromEnum(Command.copy), .shortcut = "Ctrl+C" },
        .{ .label = "Paste", .id = @intFromEnum(Command.paste), .shortcut = "Ctrl+V" },
        eui.menubar.Item.separator,
        .{ .label = "Select all", .id = @intFromEnum(Command.select_all), .shortcut = "Ctrl+A" },
    } },
    .{ .label = "View", .items = &.{
        .{ .label = "Status bar", .id = @intFromEnum(Command.status_bar) },
    } },
};

/// What View turns off. On to start with, which is what a plain editor looks
/// like before anybody changes anything.
///
/// Lines are always wrapped. On a screen this narrow the alternative is a
/// document that runs off the right edge, and a person who wanted the line
/// whole would have to scroll to read a sentence.
var show_status = true;

var menus: eui.menubar.State = .{};

/// The open and save dialog, which is a floating window of its own.
var dialog: proto.FileDialog = .{};
/// What the dialog is being asked for, since one window serves both.
var asking: proto.dialog.Purpose = .open;

var modified = false;
var status: []const u8 = "";

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    document = .{ .bytes = &storage };

    // A path on the command line is a document to open, which is how the
    // file manager hands one over and how a shell does the same thing.
    const argc: usize = frame[0];
    if (argc >= 2) {
        setPath(std.mem.span(@as([*:0]const u8, @ptrFromInt(frame[2]))));
        open();
    }

    proto.app.run("pad", "Pad", 460, 320, .{
        .draw = draw,
        .key = key,
        .event = own,
    });
}

/// The dialog is a window of its own, so what belongs to it goes to it.
fn own(event: proto.wm.Ev) bool {
    if (!dialog.owns(event)) return false;
    if (dialog.handle(connection, event)) finishDialog();
    return true;
}

/// Everything the menus answer: the chords written beside their commands, the
/// modifier and a letter, and the keys that walk an open one.
///
/// One call, because the menu table already says what each command is called
/// and which chord runs it. A second table of keycodes here is the one that
/// would go stale.
fn key(code: proto.app.KeyCode, mods: proto.app.Modifiers) bool {
    return switch (eui.menubar.key(&menus, code, mods, &MENUS)) {
        .ignored => false,
        .taken => true,
        .chosen => |id| blk: {
            run_command(@enumFromInt(id));
            break :blk true;
        },
    };
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

fn path() []const u8 {
    return file_path[0..file_len];
}

fn setPath(value: []const u8) void {
    const n = @min(value.len, file_path.len);
    @memcpy(file_path[0..n], value[0..n]);
    file_len = n;
}

/// The last component, which is what a person calls the document.
fn baseName() []const u8 {
    const full = path();
    var i = full.len;
    while (i > 0) : (i -= 1) {
        if (full[i - 1] == '/') return full[i..];
    }
    return full;
}

fn ask(purpose: proto.dialog.Purpose) void {
    asking = purpose;
    dialog.show(connection, purpose, baseName()) catch {
        status = "Cannot open the dialog.";
    };
}

fn open() void {
    const where = path();
    if (where.len == 0) {
        ask(.open);
        return;
    }

    const handle = sys.open(where, .{});
    if (handle < 0) {
        status = "No such file.";
        ctx.damage();
        return;
    }
    defer _ = sys.close(@intCast(handle));

    document.clear();
    while (true) {
        var chunk: [512]u8 = undefined;
        const n = sys.read(@intCast(handle), &chunk);
        if (n <= 0) break;
        if (!document.insert(document.len, chunk[0..@intCast(n)])) {
            status = "Only part of it fits.";
            break;
        }
    }

    if (status.len == 0) status = if (document.len == 0) "Opened; it is empty." else "Opened.";
    editor = .{};
    modified = false;
    setTitle();
    ctx.damage();
}

fn save() void {
    const where = path();
    if (where.len == 0) {
        ask(.save);
        return;
    }

    const handle = sys.open(where, .{ .write = true, .create = true, .truncate = true });
    if (handle < 0) {
        status = "Cannot write there.";
        ctx.damage();
        return;
    }
    defer _ = sys.close(@intCast(handle));

    const written = sys.write(@intCast(handle), document.slice());
    if (written < 0 or @as(usize, @intCast(written)) != document.len) {
        status = "Only part of it was written.";
        ctx.damage();
        return;
    }

    modified = false;
    editor.edited = false;
    status = "Saved.";
    setTitle();
    ctx.damage();
}

fn newDocument() void {
    document.clear();
    editor = .{};
    file_len = 0;
    modified = false;
    status = "New.";
    setTitle();
    ctx.damage();
}

/// Act on what the dialog came back with.
fn finishDialog() void {
    switch (dialog.result) {
        .pending => return,
        .cancelled => status = "",
        .chosen => {
            setPath(dialog.chosen());
            status = "";
            switch (asking) {
                .open => open(),
                .save => save(),
            }
        },
    }

    dialog.hide(connection);
    // The next pass repaints whole; the frame runs one on the event that
    // brought us here.
    ctx.damage();
}

var title_buffer: [72]u8 = @splat(0);

fn setTitle() void {
    var line = str.Builder{ .buf = &title_buffer };
    line.text("Pad");

    const shown = baseName();
    if (shown.len > 0) {
        line.text(": ");
        line.text(shown);
    }
    if (modified) line.text(" *");

    connection.setTitle(proto.app.window, line.done()) catch {};
}

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

fn run_command(command: Command) void {
    switch (command) {
        .new => newDocument(),
        .open => ask(.open),
        .save => save(),
        .save_as => ask(.save),
        .close => sys.exit(0),

        .cut => edited(text.run(&editor, &document, .cut, ctx.clipboard)),
        .copy => edited(text.run(&editor, &document, .copy, ctx.clipboard)),
        .paste => edited(text.run(&editor, &document, .paste, ctx.clipboard)),
        .select_all => edited(text.run(&editor, &document, .select_all, ctx.clipboard)),

        .status_bar => {
            show_status = !show_status;
            ctx.damage();
        },
    }
}

/// Redraw when a command changed the document. The toolkit says whether it
/// did, so a copy that changed nothing does not repaint the window.
fn edited(changed: bool) void {
    if (changed) ctx.damage();
}

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const area = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };


    const row = t.control_height;

    const strip = Rect{ .x = 0, .y = 0, .w = area.w, .h = row };
    const bottom = eui.statusbar.split(area);

    // Everything between the menu and the status bar. The window frame is
    // already a border, and a second one inset from it is a margin around a
    // document that wanted the room.
    const body_h = (if (show_status) bottom.body.h else area.h) - strip.h;
    text.edit(ctx, .{
        .x = 0,
        .y = strip.h,
        .w = area.w,
        .h = body_h,
    }, &editor, &document);

    if (show_status) {
        eui.statusbar.run(ctx, bottom.bar, &.{
            .{ .text = if (file_len > 0) path() else "untitled" },
            .{ .text = placeText(), .width = 96 },
            .{ .text = stateText(), .width = 96 },
        });
    }

    if (editor.edited and !modified) {
        modified = true;
        status = "";
        setTitle();
    }

    // Last in the pass: an open menu reaches over the document, and anything
    // drawn after it would draw over the menu instead.
    if (eui.menubar.run(ctx, strip, &menus, &MENUS)) |id| {
        run_command(@enumFromInt(id));
    }

}

var place_buffer: [32]u8 = @splat(0);

/// Where the cursor is, which is the one thing a person writing wants from a
/// status bar and the one thing a byte count cannot say.
fn placeText() []const u8 {
    const at = text.placeOf(document.slice(), editor.cursor);
    var line = str.Builder{ .buf = &place_buffer };
    line.text("Ln ");
    line.number(at.line);
    line.text(", Col ");
    line.number(at.column);
    return line.done();
}

/// What just happened, or what is outstanding. The message wins while there is
/// one: it is the newer fact, and "unsaved" is visible in the title as well.
fn stateText() []const u8 {
    if (status.len > 0) return status;
    return if (modified) "Unsaved changes" else "";
}
