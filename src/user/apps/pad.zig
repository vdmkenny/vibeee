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

var name_storage: [64]u8 = undefined;
var name: text.Buffer = undefined;
var name_editor: text.Editor = .{};

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
    name = .{ .bytes = &name_storage };

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

var path_buffer: [80]u8 = @splat(0);

/// The name as a path. Relative names are taken as they are, so the shell's
/// working directory decides where a document lands.
fn path() []const u8 {
    const typed = name.slice();
    if (typed.len == 0 or typed.len > path_buffer.len) return "";
    @memcpy(path_buffer[0..typed.len], typed);
    return path_buffer[0..typed.len];
}

fn open() void {
    const where = path();
    if (where.len == 0) {
        status = "Type a name first.";
        return;
    }

    const handle = sys.open(where, .{});
    if (handle < 0) {
        status = "No such file.";
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
        if (status.len == 0) status = "Opened.";
    }

    if (document.len == 0) status = "Opened, and it is empty.";
    editor = .{};
    modified = false;
    setTitle();
    ctx.damage();
}

fn save() void {
    const where = path();
    if (where.len == 0) {
        status = "Type a name first.";
        return;
    }

    const handle = sys.open(where, .{ .write = true, .create = true, .truncate = true });
    if (handle < 0) {
        status = "Cannot write there.";
        return;
    }
    defer _ = sys.close(@intCast(handle));

    const written = sys.write(@intCast(handle), document.slice());
    if (written < 0 or @as(usize, @intCast(written)) != document.len) {
        status = "Only part of it was written.";
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
    modified = false;
    status = "New.";
    setTitle();
    ctx.damage();
}

var title_buffer: [72]u8 = @splat(0);

fn setTitle() void {
    var line = str.Builder{ .buf = &title_buffer };
    line.text("Pad");

    const typed = name.slice();
    if (typed.len > 0) {
        line.text(": ");
        line.text(typed);
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

    const pad = t.padding;
    const row = t.control_height;

    // The name and what to do with it, on one line. A dialog would be a second
    // window to arrange and dismiss for something that fits here.
    const buttons_w: i32 = 62 * 3 + 8;
    if (text.field(
        &ctx,
        .{ .x = pad, .y = pad, .w = area.w - pad * 2 - buttons_w - 4, .h = row },
        &name_editor,
        &name,
    )) open();

    var x = area.w - pad - buttons_w;
    if (ctx.button(.{ .x = x, .y = pad, .w = 62, .h = row }, "Open")) open();
    x += 66;
    if (ctx.button(.{ .x = x, .y = pad, .w = 62, .h = row }, "Save")) save();
    x += 66;
    if (ctx.button(.{ .x = x, .y = pad, .w = 62, .h = row }, "New")) newDocument();

    const status_y = area.h - 18 - pad;
    text.edit(&ctx, .{
        .x = pad,
        .y = pad + row + 4,
        .w = area.w - pad * 2,
        .h = status_y - pad * 2 - row - 4,
    }, &editor, &document);

    if (editor.edited and !modified) {
        modified = true;
        status = "";
        setTitle();
    }

    ctx.label(.{ .x = pad, .y = status_y, .w = area.w - pad * 2, .h = 16 }, statusLine());

    ctx.end();
    connection.commit(window, ctx.damageList()) catch {};
}

var status_buffer: [96]u8 = @splat(0);

fn statusLine() []const u8 {
    var line = str.Builder{ .buf = &status_buffer };
    line.quantity(document.len, if (document.len == 1) "byte" else "bytes");

    if (modified) line.text(",  unsaved");
    if (status.len > 0) {
        line.text(",  ");
        line.text(status);
    }
    return line.done();
}
