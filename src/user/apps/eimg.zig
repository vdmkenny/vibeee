//! eimg: a picture, at the size you want to see it.
//!
//! What a viewer on this machine is for is one picture at a time, so the
//! window is the picture and everything else is a strip: the zoom along the
//! bottom with what the file is, and the camera's own words in a sidebar
//! that is there when it is wanted and gone when it is not.
//!
//! The decode is the expensive thing and happens once per picture, never per
//! paint: what is kept is the pixels, and the file's bytes are given back as
//! soon as they have been read out of. Turning a photograph upright is the
//! same walk `efm` uses for its thumbnails, so a picture is upright in both.

const eui = @import("eui");
const exif = @import("lib").exif;
const heap = @import("ulib").heap;
const img = @import("img");
const kind = @import("lib").kind;
const proto = @import("proto");
const std = @import("std");
const str = @import("ulib").str;
const sys = @import("sys");
const time = @import("ulib").time;

const KeyCode = proto.app.KeyCode;
const Modifiers = proto.app.Modifiers;
const Rect = eui.Rect;
const theme = eui.theme;

// The picture decoder is C, and calls the libc by name: the C-callable half
// is imported so its exports are emitted into this binary. One
// implementation in the system, not two.
comptime {
    _ = @import("clibc");
}

const ctx = &proto.app.ctx;

/// How large a file this will read to decode. The decoder has its own limit
/// on the picture's shape; this one is about the file, so a folder of raw
/// camera files does not take the machine down with it.
const FILE_MAX: usize = 8 * 1024 * 1024;

/// How the picture is sized in the window.
const Zoom = enum {
    /// As large as fits, never larger than it is.
    fit,
    /// A pixel of the picture to a pixel of the panel.
    whole,
    /// Twice that, for a photograph that is smaller than the screen.
    double,

    fn says(self: Zoom) []const u8 {
        return switch (self) {
            .fit => "fit",
            .whole => "100%",
            .double => "x2",
        };
    }

    fn next(self: Zoom) Zoom {
        return switch (self) {
            .fit => .whole,
            .whole => .double,
            .double => .fit,
        };
    }

    /// How many times larger than the picture's own pixels, or zero for the
    /// one that is worked out from the room there is.
    fn times(self: Zoom) i32 {
        return switch (self) {
            .fit => 0,
            .whole => 1,
            .double => 2,
        };
    }
};

var zoom: Zoom = .fit;
var sidebar = false;
var sidebar_view: eui.scrollpane.State = .{};

var picture: ?img.Picture = null;
var camera: exif.Info = .{};
/// The way up the file says it was taken, and the way up it is being shown:
/// a turn by hand is a quarter on top of the camera's own word rather than a
/// second idea of which way up something is.
var facing: exif.Orientation = .up;
var channels: u8 = 0;
var trouble: []const u8 = "";

var path_buf: [192]u8 = @splat(0);
var path_len: usize = 0;
var file_size: usize = 0;
var file_mtime: i64 = 0;

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    const argc: usize = frame[0];
    if (argc >= 2) {
        setPath(std.mem.span(@as([*:0]const u8, @ptrFromInt(frame[2]))));
        load();
    }

    proto.app.run("eimg", "Viewer", 520, 380, .{
        .draw = draw,
        .key = key,
    });
}

fn path() []const u8 {
    return path_buf[0..path_len];
}

fn setPath(value: []const u8) void {
    path_len = @min(value.len, path_buf.len);
    @memcpy(path_buf[0..path_len], value[0..path_len]);
}

// ---------------------------------------------------------------------------
// The picture
// ---------------------------------------------------------------------------

fn load() void {
    forget();

    const handle = sys.open(path(), .{});
    if (handle < 0) {
        trouble = "No such file.";
        return;
    }
    defer _ = sys.close(@intCast(handle));

    // What the file is, before reading it: a file too large to hold is
    // refused for the room it would have taken rather than after taking it.
    var record: [512]u8 = undefined;
    const told = sys.stat(path(), &record);
    const about = if (told > 0) sys.Dirent.decode(&record, @intCast(told)) else null;
    const entry = about orelse {
        trouble = "Cannot read it.";
        return;
    };
    file_size = entry.size;
    file_mtime = entry.mtime;
    if (entry.size == 0 or entry.size > FILE_MAX) {
        trouble = "Larger than this machine will hold.";
        return;
    }

    // Room for this one file, given back as soon as the pixels are out of
    // it: for a photograph that compressed well the file is the smaller of
    // the two, and holding both is what a machine this size cannot do.
    const room = heap.alloc(entry.size) orelse {
        trouble = "Not enough memory to read it.";
        return;
    };
    defer heap.release(room);

    const raw = @as([*]u8, @ptrCast(room))[0..entry.size];
    var read: usize = 0;
    while (read < raw.len) {
        const n = sys.read(@intCast(handle), raw[read..]);
        if (n <= 0) break;
        read += @intCast(n);
    }
    if (read == 0) {
        trouble = "Cannot read it.";
        return;
    }

    const bytes = raw[0..read];
    camera = exif.read(bytes);
    facing = camera.orientation;
    channels = if (img.shapeOf(bytes)) |shape| shape.channels else |_| 0;

    picture = img.decode(bytes) catch |refusal| {
        trouble = switch (refusal) {
            error.TooLarge => "Larger than this machine will hold.",
            error.NoRoom => "Not enough memory for it.",
            error.Unreadable => "Not a picture this build can open.",
        };
        return;
    };
}

fn forget() void {
    if (picture) |held| held.deinit();
    picture = null;
    camera = .{};
    facing = .up;
    channels = 0;
    trouble = "";
}

/// The picture's size the way up it is shown, which is not the way up it is
/// stored when a camera turned it.
fn shown() eui.thumb.Size {
    const held = picture orelse return .{ .w = 0, .h = 0 };
    return eui.thumb.uprightSize(held.width, held.height, facing);
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

fn draw() void {
    const t = theme.current();
    const area = Rect{ .x = 0, .y = 0, .w = ctx.surface.width, .h = ctx.surface.height };
    const parts = eui.chrome.split(area, .{ .bottom = true });

    // The sidebar takes from the picture rather than from the strips, so
    // what the picture is doing is said in the same place either way.
    const aside_w = if (sidebar) @min(theme.enlarged(200), @divTrunc(parts.body.w, 2)) else 0;
    const stage = Rect{
        .x = parts.body.x,
        .y = parts.body.y,
        .w = parts.body.w - aside_w,
        .h = parts.body.h,
    };

    drawStage(stage);
    if (sidebar) {
        const aside = Rect{ .x = stage.right(), .y = stage.y, .w = aside_w, .h = stage.h };
        if (ctx.damaged) {
            ctx.surface.fill(aside, t.surface);
            ctx.surface.fill(.{ .x = aside.x, .y = aside.y, .w = 1, .h = aside.h }, t.line);
            ctx.addDamage(aside);
        }
        drawFacts(aside);
    }

    drawKeys(parts.bottom);
}

/// The picture on the darkest ground the theme has, so its own edges are its
/// edges and not the window's.
fn drawStage(area: Rect) void {
    const t = theme.current();
    if (ctx.damaged) {
        ctx.surface.fill(area, t.desktop);
        ctx.addDamage(area);
    }

    const held = picture orelse {
        const said = if (trouble.len > 0) trouble else "Nothing to show.";
        ctx.surface.text(
            area.x + @divTrunc(area.w - eui.Surface.textWidth(said), 2),
            area.y + @divTrunc(area.h - eui.Surface.textHeight(), 2),
            said,
            t.text_inverted,
        );
        return;
    };

    const size = shown();
    const where = placed(area, size);
    eui.thumb.paint(
        ctx.surface,
        where,
        .{ .pixels = held.pixels, .width = held.width, .height = held.height },
        facing,
    );
}

/// Where the picture goes: centred, at the size the zoom asks for, and never
/// wider than the room there is.
fn placed(area: Rect, size: eui.thumb.Size) Rect {
    const times = zoom.times();
    if (times == 0) return eui.thumb.fit(area, size.w, size.h);

    const w = @min(@as(i32, size.w) * times, area.w);
    const h = @min(@as(i32, size.h) * times, area.h);
    return .{
        .x = area.x + @divTrunc(area.w - w, 2),
        .y = area.y + @divTrunc(area.h - h, 2),
        .w = w,
        .h = h,
    };
}

/// What the camera wrote, and what the file is. The one part of this window
/// that is words, so it is the one part that scrolls.
fn drawFacts(area: Rect) void {
    const t = theme.current();
    const inner = Rect{
        .x = area.x + t.menu_padding,
        .y = area.y,
        .w = area.w - t.menu_padding * 2,
        .h = area.h,
    };

    var rows: [12]eui.facts.Fact = undefined;
    var count: usize = 0;

    var pixels: [24]u8 = @splat(0);
    var written: [24]u8 = @splat(0);
    var when: [24]u8 = @splat(0);
    var made: [exif.TEXT_MAX * 2 + 1]u8 = @splat(0);

    if (picture != null) {
        const size = shown();
        var said = str.Builder{ .buf = &pixels };
        said.number(size.w);
        said.text(" x ");
        said.number(size.h);
        rows[count] = .{ .label = "Pixels", .value = said.done() };
        count += 1;
        rows[count] = .{ .label = "Colour", .value = depthSaid() };
        count += 1;
    }

    var size_said = str.Builder{ .buf = &written };
    size_said.bytes(file_size);
    rows[count] = .{ .label = "Size", .value = size_said.done() };
    count += 1;
    rows[count] = .{ .label = "Modified", .value = time.stamp(&when, file_mtime) };
    count += 1;

    // The camera's own words, where a photograph carries any.
    if (camera.maker().len > 0 or camera.camera().len > 0) {
        var said = str.Builder{ .buf = &made };
        said.text(camera.maker());
        if (camera.maker().len > 0 and camera.camera().len > 0) said.byte(' ');
        said.text(camera.camera());
        rows[count] = .{ .label = "Camera", .value = said.done() };
        count += 1;
    }
    if (camera.when().len > 0) {
        rows[count] = .{ .label = "Taken", .value = camera.when() };
        count += 1;
    }
    if (camera.orientation_known and facing != .up) {
        rows[count] = .{ .label = "Held", .value = "sideways, shown upright" };
        count += 1;
    }

    // Scrolled, because a sidebar this narrow on a screen this short holds
    // fewer rows than a photograph can carry.
    const view = eui.scrollpane.begin(ctx, area, &sidebar_view);
    var y = view.top() + t.padding;
    y = eui.facts.all(ctx, inner, y, rows[0..count]);
    eui.scrollpane.end(ctx, &sidebar_view, view, y - view.top() + t.padding);
}

/// What a pixel of the file holds, in the words somebody would use for it.
fn depthSaid() []const u8 {
    return switch (channels) {
        1 => "grey",
        2 => "grey and transparency",
        3 => "colour",
        4 => "colour and transparency",
        else => "unknown",
    };
}

/// The zoom, the sidebar, and what the file is, along the bottom.
fn drawKeys(area: Rect) void {
    const t = theme.current();
    ctx.addDamage(area);

    const x = eui.keys.paint(ctx.surface, area, &KEYS, area.right(), .chip);

    // What is being looked at, at the far end: the zoom it is at, its size
    // and what sort of picture it is. A name is already in the bar above.
    var said: [48]u8 = @splat(0);
    var line = str.Builder{ .buf = &said };
    line.text(zoom.says());
    if (picture != null) {
        const size = shown();
        line.text("   ");
        line.number(size.w);
        line.text(" x ");
        line.number(size.h);
    }
    if (kind.fromName(path())) |what| {
        line.text("   ");
        line.text(what.says());
    }

    const width = eui.Surface.textWidth(line.done());
    const baseline = area.y + @divTrunc(area.h - eui.Surface.textHeight(), 2);
    if (x + width < area.right()) {
        ctx.surface.text(area.right() - t.menu_padding - width, baseline, line.done(), t.bar_text);
    }
}

const KEYS = [_]eui.keys.Key{
    .{ .key = "z", .label = "zoom" },
    .{ .key = "r", .label = "turn" },
    .{ .key = "i", .label = "info" },
};

// ---------------------------------------------------------------------------
// The keyboard
// ---------------------------------------------------------------------------

fn key(code: KeyCode, mods: Modifiers) bool {
    _ = mods;
    switch (code) {
        .z => zoom = zoom.next(),
        .i => sidebar = !sidebar,
        .r => facing = facing.turnedRight(),
        .l => facing = facing.turnedLeft(),
        // A picture is looked at rather than worked on, so the arrows are
        // the zoom rather than a cursor nothing else uses.
        .equal => zoom = zoom.next(),
        .minus => zoom = switch (zoom) {
            .double => .whole,
            else => .fit,
        },
        .escape => sys.exit(0),
        else => return false,
    }
    ctx.damageNow();
    return true;
}
