//! Draw: a picture, and the tools a person draws it with.
//!
//! The picture is a rectangle of pixels this program owns from the moment it
//! starts, so a drawing is never waiting on memory in the middle of a stroke.
//! What every tool does to those pixels is `lib.raster`, which knows nothing
//! about windows and is tested without one.
//!
//! The pointer draws: press to begin, drag, and let go to finish. A shape is
//! shown over the picture while the button is held and put into it when the
//! button comes up, so a rectangle can be aimed before it is kept. One step
//! back is remembered, which is the step that was just taken.
//!
//! The window takes its place in the tiling like any other. The picture is
//! always at its own size: a window with room for it centres it, and one
//! without shows its top left corner rather than a squeezed copy, so what is
//! drawn lands where the pointer is.

const eui = @import("eui");
const heap = @import("ulib").heap;
const img = @import("img");
const proto = @import("proto");
const raster = @import("lib").raster;
const rgb = @import("lib").rgb;
const std = @import("std");
const sys = @import("sys");

const Colour = rgb.Colour;
const KeyCode = proto.app.KeyCode;
const Modifiers = proto.app.Modifiers;
const Rect = eui.Rect;
const theme = eui.theme;

const ctx = &proto.app.ctx;
const connection = &proto.app.connection;

// The picture decoder and the writer are C, and call the libc by name: the
// C-callable half is imported so its exports are emitted into this binary.
comptime {
    _ = @import("clibc");
}

// The icon the launcher shows for this program.
comptime {
    eui.icon.carry(eui.icon.of(.pencil).*);
}

/// The picture, which is the size of the one this machine's screen holds.
/// Bigger than the window it opens in is bigger than anybody can aim at.
const WIDE: u16 = 480;
const HIGH: u16 = 320;
const PIXELS: usize = @as(usize, WIDE) * HIGH;

/// The colour a fresh picture is, and what the rubber leaves behind.
const PAPER = Colour.hex(0xFFFFFF);

/// What a tool does with the pointer.
const Tool = enum {
    pencil,
    eraser,
    line,
    box,
    oval,
    fill,

    fn icon(self: Tool) eui.icon.Icon {
        return switch (self) {
            .pencil => .pencil,
            .eraser => .eraser,
            .line => .stroke,
            .box => .rectangle,
            .oval => .oval,
            .fill => .bucket,
        };
    }

    /// Whether the tool draws between two points rather than at one, which
    /// is what is shown over the picture while the button is held.
    fn spans(self: Tool) bool {
        return self == .line or self == .box or self == .oval;
    }
};

/// The colours on the strip, which are the sixteen every picture of this
/// kind has been drawn with.
const PALETTE = [16]Colour{
    Colour.hex(0x000000), Colour.hex(0x7F7F7F), Colour.hex(0x880015), Colour.hex(0xED1C24),
    Colour.hex(0xFF7F27), Colour.hex(0xFFF200), Colour.hex(0x22B14C), Colour.hex(0x00A2E8),
    Colour.hex(0xFFFFFF), Colour.hex(0xC3C3C3), Colour.hex(0xB97A57), Colour.hex(0xFFAEC9),
    Colour.hex(0xFFC90E), Colour.hex(0xEFE4B0), Colour.hex(0xB5E61D), Colour.hex(0x99D9EA),
};

/// The brush sizes, in pixels across.
const SIZES = [3]u8{ 1, 3, 7 };

const Command = enum(u16) { new, open, save, save_as, close, undo };

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
        .{ .label = "Undo", .id = @intFromEnum(Command.undo), .shortcut = "Ctrl+Z" },
    } },
};

var menus: eui.menubar.State = .{};

/// The picture, the step before the one just taken, and the room a fill
/// spreads through. Taken once, at the start: a program that asks for memory
/// mid-stroke is a program that can fail mid-stroke.
var pixels: []Colour = &.{};
var before: []Colour = &.{};
var seeds: []raster.Seed = &.{};
var undoable = false;

var tool: Tool = .pencil;
var fill: raster.Fill = .outline;
var ink: Colour = PALETTE[0];
var size_index: usize = 0;

/// Where a stroke began, in the picture's own pixels, while the button is
/// held down.
var stroke: ?struct { x: i32, y: i32, last_x: i32, last_y: i32 } = null;

/// Where the pointer was over the picture, in its own pixels, or nothing
/// when it was somewhere else. What the bar along the bottom reports.
var pointer_at: ?struct { x: i32, y: i32 } = null;

var dialog: proto.FileDialog = .{};
var asking: proto.dialog.Purpose = .open;
var path_storage: [256]u8 = @splat(0);
var path_len: usize = 0;
var status: []const u8 = "";

fn canvas() raster.Canvas {
    return raster.Canvas.of(pixels, WIDE, HIGH);
}

fn brush() u8 {
    return SIZES[size_index];
}

/// How many runs a fill may have waiting. A fill of the whole picture is a
/// few hundred; this is room for a picture that is all edges.
const SEEDS: usize = 8 * 1024;

export fn _start() callconv(.c) noreturn {
    const held = PIXELS * @sizeOf(Colour) * 2;
    const room = heap.alloc(held + SEEDS * @sizeOf(raster.Seed)) orelse sys.exit(1);
    const words = @as([*]Colour, @ptrCast(@alignCast(room)))[0 .. PIXELS * 2];
    pixels = words[0..PIXELS];
    before = words[PIXELS..];
    const runs: [*]raster.Seed = @ptrCast(@alignCast(@as([*]u8, @ptrCast(room)) + held));
    seeds = runs[0..SEEDS];
    canvas().clear(PAPER);

    const size = wanted();
    proto.app.run("draw", "Draw", size.w, size.h, .{
        .draw = draw,
        .key = key,
        .event = own,
    });
}

/// The window the picture asks for: the strip above it, the tools beside it,
/// the colours under it, and the picture itself at its own size.
fn wanted() struct { w: u16, h: u16 } {
    const t = theme.current();
    return .{
        .w = @intCast(WIDE + railWidth() + t.padding * 3),
        .h = @intCast(theme.stripHeight() + HIGH + paletteHeight() + eui.statusbar.height() + t.padding * 3),
    };
}

fn railWidth() i32 {
    const t = theme.current();
    return t.control_height * 2 + t.padding;
}

fn paletteHeight() i32 {
    const t = theme.current();
    return t.control_height + eui.Surface.textHeight() + t.padding;
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const whole = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };
    if (ctx.damaged) surface.fill(whole, t.surface);

    const parts = eui.chrome.split(whole, .{ .top = true, .bottom = true });
    const body = parts.body;

    const strip = Rect{
        .x = body.x + t.padding,
        .y = body.y + t.padding,
        .w = railWidth(),
        .h = body.h - paletteHeight() - t.padding * 2,
    };
    tools(strip);

    const swatches = Rect{
        .x = body.x + t.padding,
        .y = body.bottom() - paletteHeight() - t.padding,
        .w = body.w - t.padding * 2,
        .h = paletteHeight(),
    };
    palette(swatches);

    const room = Rect{
        .x = strip.right() + t.padding,
        .y = strip.y,
        .w = body.right() - strip.right() - t.padding * 2,
        .h = strip.h,
    };
    picture(room);
    bar(parts.bottom);

    // Last in the pass: an open menu hangs over the picture.
    if (eui.menubar.run(ctx, parts.top, &menus, &MENUS)) |id| {
        run(@enumFromInt(id));
    }
}

/// The tools, two to a row, with the one in use held down.
fn tools(area: Rect) void {
    const t = theme.current();
    const side = t.control_height;
    var index: usize = 0;
    for (std.enums.values(Tool)) |which| {
        const column: i32 = @intCast(index % 2);
        const row: i32 = @intCast(index / 2);
        const where = Rect{
            .x = area.x + column * (side + @divTrunc(t.padding, 2)),
            .y = area.y + row * (side + @divTrunc(t.padding, 2)),
            .w = side,
            .h = side,
        };
        if (ctx.toolChosen(where, which.icon(), which == tool)) {
            tool = which;
            ctx.damage();
        }
        index += 1;
    }

    // Under the tools: whether a shape is an outline or filled, and how wide
    // the brush is.
    const rows: i32 = @intCast((std.enums.values(Tool).len + 1) / 2);
    var under = Rect{
        .x = area.x,
        .y = area.y + rows * (side + @divTrunc(t.padding, 2)) + t.padding,
        .w = area.w,
        .h = side,
    };
    if (ctx.buttonAs(under, if (fill == .solid) "solid" else "hollow", .quiet)) {
        fill = if (fill == .solid) .outline else .solid;
        ctx.damage();
    }

    under.y += side + @divTrunc(t.padding, 2);
    var label: [8]u8 = undefined;
    const written = std.fmt.bufPrint(&label, "{d} px", .{brush()}) catch "px";
    if (ctx.buttonAs(under, written, .quiet)) {
        size_index = (size_index + 1) % SIZES.len;
        ctx.damage();
    }
}

/// The colours, and what is being drawn with.
fn palette(area: Rect) void {
    const t = theme.current();
    const side = @divTrunc(area.h - eui.Surface.textHeight(), 2);

    for (PALETTE, 0..) |colour, index| {
        const column: i32 = @intCast(index % 8);
        const row: i32 = @intCast(index / 8);
        const where = Rect{
            .x = area.x + column * (side + 2),
            .y = area.y + row * (side + 2),
            .w = side,
            .h = side,
        };
        ctx.surface.fill(where, colour);
        if (raster.same(colour, ink)) {
            const inside = Rect{ .x = where.x + 2, .y = where.y + 2, .w = where.w - 4, .h = where.h - 4 };
            ctx.surface.fillAround(where, inside, t.accent);
        } else {
            ctx.surface.fillAround(where, .{ .x = where.x + 1, .y = where.y + 1, .w = where.w - 2, .h = where.h - 2 }, t.line);
        }
        if (ctx.pressedThisPass() and where.contains(ctx.pointer_x, ctx.pointer_y)) {
            ink = colour;
            ctx.damage();
        }
    }
}

/// What the picture is, where the pointer is on it, and what just happened.
fn bar(area: Rect) void {
    var at_text: [24]u8 = undefined;
    const pointer = if (pointer_at) |on|
        std.fmt.bufPrint(&at_text, "{d}, {d}", .{ on.x, on.y }) catch ""
    else
        "";

    eui.statusbar.run(ctx, area, &.{
        .{ .text = if (path_len > 0) path() else "untitled" },
        .{ .text = status, .width = 128 },
        .{ .text = pointer, .width = 72, .right = true },
        .{ .text = std.fmt.comptimePrint("{d} x {d}", .{ WIDE, HIGH }), .width = 72, .right = true },
    });
}

/// The picture, and the pointer over it.
fn picture(room: Rect) void {
    const t = theme.current();
    const at = placed(room);
    const seen = room.intersect(at);
    if (seen.w <= 0 or seen.h <= 0) return;

    // A sunken edge around what is shown, so the paper is plainly a thing
    // on a desk.
    ctx.surface.fillAround(
        .{ .x = seen.x - 1, .y = seen.y - 1, .w = seen.w + 2, .h = seen.h + 2 },
        seen,
        t.line,
    );

    hand(at, seen);

    eui.thumb.paint(ctx.surface.clipped(seen), at, .{
        .pixels = pixels,
        .width = WIDE,
        .height = HIGH,
    }, .up);

    // What the shape would be, over the picture rather than in it.
    if (stroke) |began| {
        if (tool.spans()) {
            const now = pointerOn(at);
            preview(seen, at, began.x, began.y, now.x, now.y);
        }
    }
}

/// Where the picture sits: at its own size, centred in the room when there
/// is enough of it and against the top left when there is not.
fn placed(room: Rect) Rect {
    return .{
        .x = room.x + @max(@divTrunc(room.w - WIDE, 2), 0),
        .y = room.y + @max(@divTrunc(room.h - HIGH, 2), 0),
        .w = WIDE,
        .h = HIGH,
    };
}

/// Where the pointer is in the picture's own pixels.
fn pointerOn(at: Rect) struct { x: i32, y: i32 } {
    return .{ .x = ctx.pointer_x - at.x, .y = ctx.pointer_y - at.y };
}

/// The stroke being made: begun, carried on, and finished. A stroke starts
/// only on the part of the picture that is shown, and goes on wherever the
/// pointer takes it.
fn hand(at: Rect, seen: Rect) void {
    const over = seen.contains(ctx.pointer_x, ctx.pointer_y);
    const now = pointerOn(at);
    const told = pointer_at;
    pointer_at = if (over or stroke != null) .{ .x = now.x, .y = now.y } else null;
    if (!std.meta.eql(told, pointer_at)) ctx.damage();

    if (stroke == null and ctx.pressedThisPass() and over) {
        keep();
        stroke = .{ .x = now.x, .y = now.y, .last_x = now.x, .last_y = now.y };
        switch (tool) {
            .pencil, .eraser => canvas().dot(now.x, now.y, brush(), colourOf(tool)),
            .fill => _ = canvas().flood(now.x, now.y, ink, seeds),
            else => {},
        }
        ctx.damage();
        return;
    }

    const began = &(stroke orelse return);
    if (ctx.buttons.left) {
        switch (tool) {
            .pencil, .eraser => {
                canvas().line(began.last_x, began.last_y, now.x, now.y, brush(), colourOf(tool));
                began.last_x = now.x;
                began.last_y = now.y;
                ctx.damage();
            },
            // A shape follows the pointer until the button comes up.
            else => if (ctx.pointer_moved) ctx.damage(),
        }
        return;
    }

    // The button came up: a shape is put into the picture where it was shown.
    if (tool.spans()) {
        shape(canvas(), began.x, began.y, now.x, now.y);
    }
    stroke = null;
    ctx.damage();
}

fn colourOf(which: Tool) Colour {
    return if (which == .eraser) PAPER else ink;
}

/// The tool's shape between two points, into whatever canvas is given: the
/// picture when it is kept, and the window's own pixels while it is shown.
fn shape(into: raster.Canvas, from_x: i32, from_y: i32, to_x: i32, to_y: i32) void {
    switch (tool) {
        .line => into.line(from_x, from_y, to_x, to_y, brush(), ink),
        .box => into.box(from_x, from_y, to_x, to_y, brush(), ink, fill),
        .oval => into.ellipse(from_x, from_y, to_x, to_y, brush(), ink, fill),
        else => {},
    }
}

/// The shape as it would be, drawn into the window rather than the picture.
/// The window's pixels are a canvas like any other, over rows wider than the
/// part of the picture on show.
fn preview(seen: Rect, at: Rect, from_x: i32, from_y: i32, to_x: i32, to_y: i32) void {
    const surface = ctx.surface;
    const span: usize = @intCast(surface.stride);
    const start = @as(usize, @intCast(seen.y)) * span + @as(usize, @intCast(seen.x));
    const rows: usize = @intCast(seen.h);
    const window = raster.Canvas.over(
        surface.pixels[start .. start + (rows - 1) * span + @as(usize, @intCast(seen.w))],
        @intCast(seen.w),
        @intCast(seen.h),
        @intCast(span),
    );

    // The view begins at the corner of the picture that is on show, so the
    // shape is drawn in the picture's own coordinates less that corner.
    const across = seen.x - at.x;
    const down = seen.y - at.y;
    shape(window, from_x - across, from_y - down, to_x - across, to_y - down);
}

// ---------------------------------------------------------------------------
// Keys and commands
// ---------------------------------------------------------------------------

fn key(code: KeyCode, mods: Modifiers) bool {
    switch (eui.menubar.key(&menus, code, mods, &MENUS)) {
        .ignored => {},
        .taken => {
            ctx.damage();
            return true;
        },
        .chosen => |id| {
            run(@enumFromInt(id));
            return true;
        },
    }

    if (mods.control) return false;
    switch (code) {
        .p => tool = .pencil,
        .e => tool = .eraser,
        .l => tool = .line,
        .r => tool = .box,
        .o => tool = .oval,
        .f => tool = .fill,
        .s => fill = if (fill == .solid) .outline else .solid,
        .bracket_left => size_index = if (size_index == 0) SIZES.len - 1 else size_index - 1,
        .bracket_right => size_index = (size_index + 1) % SIZES.len,
        else => return false,
    }
    ctx.damage();
    return true;
}

fn run(command: Command) void {
    switch (command) {
        .new => {
            keep();
            canvas().clear(PAPER);
            path_len = 0;
            status = "";
        },
        .open => ask(.open),
        .save => if (path_len == 0) ask(.save) else save(),
        .save_as => ask(.save),
        .close => sys.exit(0),
        .undo => undo(),
    }
    ctx.damage();
}

/// The picture as it is now, so the next stroke can be taken back.
fn keep() void {
    @memcpy(before, pixels);
    undoable = true;
}

fn undo() void {
    if (!undoable) {
        status = "Nothing to undo.";
        return;
    }
    // The step back is itself a step, so undo undoes an undo.
    for (pixels, before) |*now, *then| std.mem.swap(Colour, now, then);
    status = "";
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

fn path() []const u8 {
    return path_storage[0..path_len];
}

fn setPath(value: []const u8) void {
    path_len = @min(value.len, path_storage.len);
    @memcpy(path_storage[0..path_len], value[0..path_len]);
}

fn baseName() []const u8 {
    const whole = path();
    if (whole.len == 0) return "picture.png";
    var at = whole.len;
    while (at > 0) : (at -= 1) {
        if (whole[at - 1] == '/') return whole[at..];
    }
    return whole;
}

fn ask(purpose: proto.dialog.Purpose) void {
    asking = purpose;
    const why: []const u8 = switch (purpose) {
        .open => "Open a picture",
        .save => "Save the picture as",
    };
    dialog.show(connection, purpose, baseName(), why) catch {
        status = "Cannot open the dialog.";
    };
}

/// The dialog is a window of its own, so what belongs to it goes to it.
fn own(event: proto.wm.Ev) bool {
    if (!dialog.owns(event)) return false;
    if (dialog.handle(connection, event)) finishDialog();
    return true;
}

fn finishDialog() void {
    switch (dialog.result) {
        .pending => return,
        .cancelled => status = "",
        .chosen => {
            setPath(dialog.chosen());
            switch (asking) {
                .open => load(),
                .save => save(),
            }
        },
    }
    dialog.hide(connection);
    ctx.damage();
}

/// A picture from a file, laid on the paper at its top left. Larger than the
/// paper is cut to it: this program draws one size of picture.
fn load() void {
    const where = path();
    const handle = sys.open(where, .{}) catch {
        status = "No such file.";
        return;
    };
    defer sys.close(handle);

    const room = heap.alloc(FILE_MAX) orelse {
        status = "No room to read it.";
        return;
    };
    defer heap.release(room);
    const raw = @as([*]u8, @ptrCast(room))[0..FILE_MAX];

    var filled: usize = 0;
    while (filled < raw.len) {
        const n = sys.read(handle, raw[filled..]) catch break;
        if (n == 0) break;
        filled += @intCast(n);
    }

    const opened = img.decode(raw[0..filled]) catch {
        status = img.why();
        return;
    };
    defer opened.deinit();

    keep();
    canvas().clear(PAPER);
    var row: u16 = 0;
    while (row < @min(opened.height, HIGH)) : (row += 1) {
        var column: u16 = 0;
        while (column < @min(opened.width, WIDE)) : (column += 1) {
            pixels[@as(usize, row) * WIDE + column] = opened.pixels[@as(usize, row) * opened.width + column];
        }
    }
    status = "Opened.";
}

fn save() void {
    const where = path();
    if (where.len == 0) {
        ask(.save);
        return;
    }

    const scratch = heap.alloc(PIXELS * 3) orelse {
        status = "No room to write it.";
        return;
    };
    defer heap.release(scratch);
    const into = heap.alloc(FILE_MAX) orelse {
        status = "No room to write it.";
        return;
    };
    defer heap.release(into);

    const written = img.encodePng(.{
        .pixels = pixels,
        .width = WIDE,
        .height = HIGH,
        .owned = false,
    }, @as([*]u8, @ptrCast(scratch))[0 .. PIXELS * 3], @as([*]u8, @ptrCast(into))[0..FILE_MAX]) catch {
        status = img.why();
        return;
    };

    const handle = sys.open(where, .{ .write = true, .create = true, .truncate = true }) catch {
        status = "Cannot write there.";
        return;
    };
    defer sys.close(handle);

    const out = sys.write(handle, written) catch 0;
    status = if (out == written.len) "Saved." else "Only part of it was written.";
}

/// How large a picture file this reads or writes. A drawing of this size is
/// a few tens of kilobytes; the room is for one that is not.
const FILE_MAX: usize = 2 * 1024 * 1024;
