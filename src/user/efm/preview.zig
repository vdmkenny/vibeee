//! What is under the cursor, shown in the other pane.
//!
//! A file manager that can only list names makes somebody open a file to find
//! out whether it is the one they meant. The right pane answers that instead:
//! a picture is drawn, a text file is shown as far as it goes, and anything
//! else says what it is and when it was last written, which is the question
//! being asked of it.
//!
//! What a file is comes from its name. Reading the first bytes of every file
//! the cursor passes over would be a disk seek per keypress, and a name is
//! what somebody chose to describe it with.
//!
//! One picture is kept decoded at a time, under the path it came from, so
//! moving the cursor down a folder of photographs and back does not decode
//! the same one twice. One, because a decoded photograph is megabytes and
//! this machine has a budget rather than a cache.

const eui = @import("eui");
const img = @import("img");
const dir = @import("ulib").dir;
const exif = @import("lib").exif;
const heap = @import("ulib").heap;
const paths = @import("ulib").paths;
const str = @import("lib").str;
const sys = @import("sys");
const time = @import("ulib").time;

const Rect = eui.Rect;
const theme = eui.theme;

/// What a file is, as far as its name says.
pub const Kind = enum {
    folder,
    picture,
    text,
    other,

    /// What the name says it is.
    ///
    /// By suffix, folded for case: a volume written on another machine holds
    /// `README.TXT` as readily as `readme.txt`.
    pub fn of(entry: dir.Entry) Kind {
        if (entry.is_dir) return .folder;

        const dot = lastDot(entry.name) orelse return .other;
        const suffix = entry.name[dot + 1 ..];

        for (PICTURES) |known| {
            if (str.eqlFold(suffix, known)) return .picture;
        }
        for (TEXTS) |known| {
            if (str.eqlFold(suffix, known)) return .text;
        }
        return .other;
    }

    pub fn icon(self: Kind) eui.icon.Icon {
        return switch (self) {
            .folder => .folder,
            .picture => .picture,
            .text, .other => .document,
        };
    }

    pub fn says(self: Kind) []const u8 {
        return switch (self) {
            .folder => "Folder",
            .picture => "Picture",
            .text => "Text",
            .other => "File",
        };
    }
};

/// The suffixes this build can actually open, and the ones worth showing as
/// text. Both are lists rather than rules: a file called `notes.zig` is text
/// and a file called `notes.bin` is not, and nothing about the bytes says so
/// without reading them.
const PICTURES = [_][]const u8{ "png", "jpg", "jpeg", "bmp", "gif" };
const TEXTS = [_][]const u8{
    "txt",  "md",  "zig", "c",   "h",   "cfg", "conf", "log",
    "json", "asm", "s",   "sh",  "man", "ini", "csv",  "html",
};

fn lastDot(name: []const u8) ?usize {
    var at = name.len;
    while (at > 0) : (at -= 1) {
        if (name[at - 1] == '.') return at - 1;
    }
    return null;
}

/// How much of a text file is shown. A preview is for recognising a file, not
/// for reading it: the editor is one keypress away and holds the whole thing.
const TEXT_MAX = 4 * 1024;

/// The largest picture file this will read to decode. The decoder has its own
/// limit on the picture's shape; this one is about the file, so a folder of
/// raw camera files does not stall the pane being scrolled through.
///
/// Taken from the heap for as long as the decode lasts rather than held as a
/// buffer this size: a program that reserved eight megabytes against the
/// largest file it might ever meet would be carrying them in every folder of
/// text files as well.
const PICTURE_BYTES_MAX = 8 * 1024 * 1024;

// ---------------------------------------------------------------------------
// What is being shown
// ---------------------------------------------------------------------------

var path_buf: [256]u8 = @splat(0);
var path_len: usize = 0;

var text_buf: [TEXT_MAX]u8 = @splat(0);
var text_len: usize = 0;
var text_view: eui.text.Editor = .{ .read_only = true };
var text_doc: eui.text.Buffer = .{ .bytes = &text_buf };

/// The one picture kept decoded, and which file it came from.
var picture: ?img.Picture = null;
var picture_of: [256]u8 = @splat(0);
var picture_of_len: usize = 0;
var facing: exif.Orientation = .up;
var camera: exif.Info = .{};
/// What the file holds per pixel, which is not what the decoder handed back:
/// everything is decoded to four channels to draw, and what the picture
/// actually carries is what somebody is asking about.
var channels: u8 = 0;

/// Why there is nothing to show, when there is nothing to show.
var trouble: []const u8 = "";

fn shownPath() []const u8 {
    return path_buf[0..path_len];
}

fn cachedPath() []const u8 {
    return picture_of[0..picture_of_len];
}

/// Show `entry`, which lives in `folder`.
///
/// Called whenever the cursor moves, so the first thing it does is notice
/// that nothing moved: a folder walked with the arrow keys would otherwise
/// re-read a file per keypress.
pub fn show(folder: []const u8, entry: dir.Entry) void {
    var built: [256]u8 = @splat(0);
    const full = paths.join(folder, entry.name, &built);
    if (str.eql(full, shownPath())) return;

    path_len = @min(full.len, path_buf.len);
    @memcpy(path_buf[0..path_len], full[0..path_len]);

    trouble = "";
    text_len = 0;
    text_doc.len = 0;
    text_view = .{ .read_only = true };

    switch (Kind.of(entry)) {
        .picture => load(entry),
        .text => readText(),
        .folder, .other => {},
    }
}

/// Nothing is selected, or the pane was closed: let the picture go.
///
/// A decoded photograph is the largest thing this program holds, so it is
/// given back rather than left until something else needs the room.
pub fn clear() void {
    forget();
    path_len = 0;
    text_len = 0;
    text_doc.len = 0;
    trouble = "";
}

fn forget() void {
    if (picture) |held| held.deinit();
    picture = null;
    picture_of_len = 0;
    camera = .{};
    facing = .up;
    channels = 0;
}

/// Read the file into `into`, as much of it as fits.
fn read(into: []u8) ?usize {
    const handle = sys.open(shownPath(), .{});
    if (handle < 0) return null;
    defer _ = sys.close(@intCast(handle));

    const got = sys.read(@intCast(handle), into);
    return if (got < 0) null else @intCast(got);
}

fn readText() void {
    const got = read(&text_buf) orelse {
        trouble = "Cannot read it.";
        return;
    };
    text_len = got;
    text_doc.len = got;
}

/// Decode the picture, unless it is the one already decoded.
fn load(entry: dir.Entry) void {
    if (str.eql(shownPath(), cachedPath())) return;
    forget();

    if (entry.size > PICTURE_BYTES_MAX) {
        trouble = "Too large to preview.";
        return;
    }

    // Room for this one file, given back as soon as the pixels are out of
    // it: what is kept is the decoded picture, and the bytes it came from are
    // the larger of the two for a photograph that compressed well.
    const room = heap.alloc(entry.size) orelse {
        trouble = "Not enough memory to read it.";
        return;
    };
    defer heap.release(room);

    const raw = @as([*]u8, @ptrCast(room))[0..entry.size];
    const got = read(raw) orelse {
        trouble = "Cannot read it.";
        return;
    };

    const bytes = raw[0..got];
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

    picture_of_len = @min(path_len, picture_of.len);
    @memcpy(picture_of[0..picture_of_len], path_buf[0..picture_of_len]);
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

/// Draw the pane. `entry` is what the cursor is on, or null for a pane with
/// nothing selected.
pub fn draw(ctx: *eui.widget.Context, area: Rect, entry: ?dir.Entry) void {
    const t = theme.current();

    ctx.surface.fill(area, t.surface);
    ctx.addDamage(area);

    const chosen = entry orelse {
        ctx.rowText(head(area), "Nothing selected", t.text_dim);
        return;
    };

    const kind = Kind.of(chosen);
    var y = drawHead(ctx, area, chosen, kind);

    // A picture goes on the darkest ground the theme has, so its own edges
    // are its edges and not the pane's.
    if (kind == .picture) y = drawPicture(ctx, area, y);

    y = drawFacts(ctx, area, y, chosen, kind);

    if (kind == .text and text_len > 0) drawText(ctx, area, y);
}

fn head(area: Rect) Rect {
    const t = theme.current();
    return .{ .x = area.x + t.menu_padding, .y = area.y + t.padding, .w = area.w, .h = t.control_height };
}

/// The name, with the picture of what it is beside it: the same two things a
/// row in the listing carries, at the top of what is being said about it.
fn drawHead(ctx: *eui.widget.Context, area: Rect, entry: dir.Entry, kind: Kind) i32 {
    const t = theme.current();
    const at = head(area);

    // The picture on the same line as the word beside it, which is the body
    // of the letters rather than the middle of their cell.
    ctx.surface.icon(at.x, eui.Surface.iconTopFor(at.y), kind.icon(), t.text);
    ctx.rowText(
        .{
            .x = at.x + eui.Surface.iconSize() + t.gap,
            .y = at.y,
            .w = area.w,
            .h = at.h,
        },
        entry.name,
        t.text,
    );

    const under = at.y + eui.Surface.textHeight() + t.padding;
    ctx.surface.fill(.{ .x = area.x, .y = under, .w = area.w, .h = 1 }, t.line);
    return under + t.padding;
}

fn drawPicture(ctx: *eui.widget.Context, area: Rect, from: i32) i32 {
    const t = theme.current();
    const room = Rect{
        .x = area.x,
        .y = from,
        .w = area.w,
        .h = @divTrunc(area.h - (from - area.y), 2),
    };

    ctx.surface.fill(room, t.desktop);

    const held = picture orelse {
        ctx.rowText(
            .{ .x = room.x + t.menu_padding, .y = room.y + t.padding, .w = room.w, .h = 16 },
            if (trouble.len > 0) trouble else "Cannot show it.",
            t.text_dim,
        );
        return room.bottom() + t.padding;
    };

    const upright = eui.thumb.uprightSize(held.width, held.height, facing);
    const into = eui.thumb.fit(room.inset(t.padding), upright.w, upright.h);
    eui.thumb.paint(
        ctx.surface,
        into,
        .{ .pixels = held.pixels, .width = held.width, .height = held.height },
        facing,
    );

    return room.bottom() + t.padding;
}

/// What is known about it: what it is, how big, when it was last written, and
/// for a photograph what the camera wrote beside the picture.
fn drawFacts(ctx: *eui.widget.Context, area: Rect, from: i32, entry: dir.Entry, kind: Kind) i32 {
    const t = theme.current();
    var y = from;

    y = fact(ctx, area, y, "Kind", kind.says());

    if (!entry.is_dir) {
        var size: [16]u8 = @splat(0);
        var said = str.Builder{ .buf = &size };
        said.bytes(entry.size);
        y = fact(ctx, area, y, "Size", said.done());
    }

    if (entry.mtime != 0) {
        var when: [24]u8 = @splat(0);
        y = fact(ctx, area, y, "Modified", time.stamp(&when, entry.mtime));
    }

    if (picture) |held| {
        var shape: [16]u8 = @splat(0);
        var said = str.Builder{ .buf = &shape };
        const upright = eui.thumb.uprightSize(held.width, held.height, facing);
        said.number(upright.w);
        said.text(" x ");
        said.number(upright.h);
        y = fact(ctx, area, y, "Pixels", said.done());
        y = fact(ctx, area, y, "Colour", depthSaid());
    }

    // The camera's own words, where there are any. Above the file's own
    // facts in importance and below them on the page: what a photograph is of
    // is the picture, and this is who took it.
    if (camera.maker().len > 0 or camera.camera().len > 0) {
        var by: [96]u8 = @splat(0);
        var said = str.Builder{ .buf = &by };
        said.text(camera.maker());
        if (camera.maker().len > 0 and camera.camera().len > 0) said.byte(' ');
        said.text(camera.camera());
        y = fact(ctx, area, y, "Camera", said.done());
    }
    if (camera.when().len > 0) y = fact(ctx, area, y, "Taken", camera.when());
    if (camera.orientation_known and facing != .up) {
        y = fact(ctx, area, y, "Held", "sideways, shown upright");
    }

    if (trouble.len > 0 and kind != .picture) y = fact(ctx, area, y, "", trouble);
    return y + t.padding;
}

/// What a pixel of the file holds, in the words somebody would use for it.
///
/// From the file rather than from what was decoded: everything is decoded to
/// four channels so it can be drawn, and a photograph does not become
/// thirty-two bit by being looked at.
fn depthSaid() []const u8 {
    return switch (channels) {
        1 => "8-bit grey",
        2 => "8-bit grey and alpha",
        3 => "24-bit colour",
        4 => "32-bit with alpha",
        else => "unknown",
    };
}

fn fact(ctx: *eui.widget.Context, area: Rect, y: i32, label: []const u8, value: []const u8) i32 {
    const t = theme.current();
    const label_w = @min(theme.enlarged(72), @divTrunc(area.w, 3));

    ctx.rowText(
        .{ .x = area.x + t.menu_padding, .y = y, .w = label_w, .h = t.control_height },
        label,
        t.text_dim,
    );
    ctx.rowText(
        .{
            .x = area.x + t.menu_padding + label_w,
            .y = y,
            .w = area.w - label_w - t.menu_padding * 2,
            .h = t.control_height,
        },
        value,
        t.text,
    );
    return y + theme.enlarged(16);
}

/// The file itself, read-only, filling what is left of the pane.
fn drawText(ctx: *eui.widget.Context, area: Rect, from: i32) void {
    const t = theme.current();
    const room = Rect{
        .x = area.x + t.padding,
        .y = from,
        .w = area.w - t.padding * 2,
        .h = area.bottom() - from - t.padding,
    };
    if (room.h < t.control_height) return;

    eui.text.edit(ctx, room, &text_view, &text_doc);
}
