//! Pad: a text editor.
//!
//! Opens a file, edits it, writes it back. Plain text for now; the styled
//! writing `design/00-vibeee.md` §10.8 describes needs a document model that
//! carries runs of attributes, and a plain editor that works is worth more
//! than a rich one that does not.
//!
//! Everything it does with text is `libeui`'s, which is where an editable area
//! belongs: the next program that needs one should not write a second.

const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const out = @import("ulib").out;
const str = @import("ulib").str;

const theme = eui.theme;
const Rect = eui.Rect;
const text = eui.text;

/// The largest document. Sized against what this machine has rather than what
/// a desktop would allow: half a megabyte of editable text is more than
/// anything on a four gigabyte disk here, and it is committed memory.
const CAPACITY = 64 * 1024;

var connection: proto.Connection = undefined;
var window: u8 = 0;
var ctx: eui.Context = undefined;

var storage: [CAPACITY]u8 = undefined;
var document: text.Buffer = undefined;
var editor: text.Editor = .{};

/// Where the document came from and where Save writes it back.
var file_path: [128]u8 = @splat(0);
var file_len: usize = 0;

/// What the File menu offers. The application names its commands; the bar
/// draws them and says which one was chosen.
const Command = enum(u16) { new, open, save, save_as, close };

const MENUS = [_]eui.menubar.Menu{
    .{ .label = "File", .items = &.{
        .{ .label = "New", .id = @intFromEnum(Command.new) },
        .{ .label = "Open...", .id = @intFromEnum(Command.open) },
        eui.menubar.Item.separator,
        .{ .label = "Save", .id = @intFromEnum(Command.save) },
        .{ .label = "Save as...", .id = @intFromEnum(Command.save_as) },
        eui.menubar.Item.separator,
        .{ .label = "Close", .id = @intFromEnum(Command.close) },
    } },
};

var menus: eui.menubar.State = .{};

/// The open and save dialog, which is a floating window of its own.
var dialog: proto.FileDialog = .{};
/// What the dialog is being asked for, since one window serves both.
var asking: proto.dialog.Purpose = .open;

var modified = false;
var status: []const u8 = "";

var pointer_x: i32 = 0;
var pointer_y: i32 = 0;
var buttons: eui.widget.Buttons = .{};

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ call padMain
        \\ hlt
    );
}

export fn padMain() callconv(.c) noreturn {
    document = .{ .bytes = &storage };

    connection = proto.client.Connection.open("pad") catch {
        out.text("pad: no window manager is running\n");
        out.flush();
        sys.exit(1);
    };

    window = connection.createWindow(.{}, 460, 320) catch sys.exit(1);
    connection.setTitle(window, "Pad") catch {};

    run();
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
    dialog.show(&connection, purpose, baseName()) catch {
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

    if (status.len == 0) status = if (document.len == 0) "Opened, and it is empty." else "Opened.";
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

    dialog.hide(&connection);
    ctx.damage();
    redraw();
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

    connection.setTitle(window, line.done()) catch {};
}

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

fn run() noreturn {
    while (true) {
        const event = connection.next(1_000_000) orelse continue;

        // The dialog is a window of its own, so what belongs to it goes to it.
        if (dialog.owns(event)) {
            if (dialog.handle(&connection, event)) finishDialog();
            continue;
        }

        switch (event.tag) {
            .configure => resize(event.body.configure.w, event.body.configure.h),
            .ptr_motion => {
                pointer_x = event.body.motion.x;
                pointer_y = event.body.motion.y;
                redraw();
            },
            .ptr_button => {
                pointer_x = event.body.button.x;
                pointer_y = event.body.button.y;
                setButton(event.body.button.btn, event.body.button.down != 0);
                redraw();
            },
            .scroll => {
                ctx.postScroll(event.body.scroll.dy);
                redraw();
            },
            .key => {
                if (event.body.key.down == 0) continue;
                const code: eui.widget.KeyCode = @enumFromInt(event.body.key.code);

                // An open menu is modal: arrows walk it rather than moving the
                // cursor in the document behind it.
                if (eui.menubar.isOpen(&menus)) {
                    if (eui.menubar.key(&menus, code, &MENUS)) {
                        redraw();
                        continue;
                    }
                }

                ctx.postKey(@intCast(event.body.key.code), @bitCast(event.body.key.mods));
                redraw();
            },
            .text => {
                ctx.postText(event.body.text.cp);
                redraw();
            },
            .theme => {
                proto.client.applyTheme(&event.body.theme.name);
                ctx.damage();
                redraw();
            },
            .close_req => sys.exit(0),
            .overflow => redraw(),
            else => {},
        }
    }
}

fn run_command(command: Command) void {
    switch (command) {
        .new => newDocument(),
        .open => ask(.open),
        .save => save(),
        .save_as => ask(.save),
        .close => sys.exit(0),
    }
}

fn setButton(index: u8, down: bool) void {
    switch (index) {
        0 => buttons.left = down,
        1 => buttons.right = down,
        2 => buttons.middle = down,
        else => {},
    }
}

fn resize(w: u16, h: u16) void {
    connection.attach(window, w, h) catch return;
    const surface = connection.surfaceOf(window) orelse return;

    ctx = eui.Context.init(surface.*);
    ctx.damageNow();
    draw();
    connection.map(window) catch {};
}

fn redraw() void {
    const surface = connection.surfaceOf(window) orelse return;
    ctx.surface = surface.*;
    draw();
    if (ctx.pending) draw();
}

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const area = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };

    ctx.begin(pointer_x, pointer_y, buttons);
    if (ctx.damaged) surface.fill(area, t.surface);

    const row = t.control_height;

    const strip = Rect{ .x = 0, .y = 0, .w = area.w, .h = row };
    const bottom = eui.statusbar.split(area);

    // Everything between the menu and the status bar. The window frame is
    // already a border, and a second one inset from it is a margin around a
    // document that wanted the room.
    text.edit(&ctx, .{
        .x = 0,
        .y = strip.h,
        .w = area.w,
        .h = bottom.body.h - strip.h,
    }, &editor, &document);

    eui.statusbar.run(&ctx, bottom.bar, &.{
        .{ .text = if (file_len > 0) path() else "untitled" },
        .{ .text = sizeText(), .width = 78, .right = true },
        .{ .text = stateText(), .width = 96 },
    });

    if (editor.edited and !modified) {
        modified = true;
        status = "";
        setTitle();
    }

    // Last in the pass: an open menu reaches over the document, and anything
    // drawn after it would draw over the menu instead.
    if (eui.menubar.run(&ctx, strip, &menus, &MENUS)) |id| {
        run_command(@enumFromInt(id));
    }

    ctx.end();
    connection.commit(window, ctx.damageList()) catch {};
}

var size_buffer: [24]u8 = @splat(0);

fn sizeText() []const u8 {
    var line = str.Builder{ .buf = &size_buffer };
    line.quantity(document.len, if (document.len == 1) "byte" else "bytes");
    return line.done();
}

/// What just happened, or what is outstanding. The message wins while there is
/// one: it is the newer fact, and "unsaved" is visible in the title as well.
fn stateText() []const u8 {
    if (status.len > 0) return status;
    return if (modified) "Unsaved changes" else "";
}
