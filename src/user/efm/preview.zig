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

const std = @import("std");
const eui = @import("eui");
const img = @import("img");
const dir = @import("ulib").dir;
const kind = @import("lib").kind;
const exif = @import("lib").exif;
const heap = @import("ulib").heap;
const paths = @import("ulib").paths;
const str = @import("lib").str;
const file = @import("ulib").file;
const time = @import("ulib").time;

const Rect = eui.Rect;
const theme = eui.theme;

/// What a file is, as far as its name says, and how this window draws it.
///
/// The reading is `lib.kind`, which the shell's `file` uses too, so a
/// picture is a picture in both. By name rather than by bytes: a listing
/// asks this for every row the cursor passes over, and a seek per row is
/// what a preview pane must not cost.
pub const Kind = struct {
    pub fn of(entry: dir.Entry) kind.Kind {
        if (entry.is_dir) return .directory;
        return kind.fromName(entry.name) orelse .data;
    }

    pub fn icon(which: kind.Kind) eui.icon.Icon {
        return eui.icon.forFamily(which.family());
    }
};

/// The facts sit in from the pane's edge, which the pane's own padding
/// would otherwise have to be written into every row.
fn inset(area: Rect) Rect {
    const t = theme.current();
    return .{
        .x = area.x + t.menu_padding,
        .y = area.y,
        .w = area.w - t.menu_padding * 2,
        .h = area.h,
    };
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
/// What the file's own bytes say it is, read once when it is shown. The
/// listing goes by name, since a seek per row is what a listing must not
/// cost; the pane beside it is about one file and can afford to look.
var reading: kind.Reading = .{ .kind = .data };
/// Whether what is shown differs from what was last painted. The pane is
/// half the window, and painting it on every pass would send half the
/// window to the screen for every move of the pointer.
var changed = true;
/// Where the text starts, below whatever was painted above it, kept from
/// the pass that painted it so the text control can run on the passes that
/// paint nothing.
var text_top: i32 = 0;

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
    if (std.mem.eql(u8, full, shownPath())) return;

    path_len = @min(full.len, path_buf.len);
    @memcpy(path_buf[0..path_len], full[0..path_len]);

    trouble = "";
    text_len = 0;
    text_doc.len = 0;
    text_view = .{ .read_only = true };
    changed = true;

    reading = if (entry.is_dir) .{ .kind = .directory } else sniff(full);
    switch (reading.kind.family()) {
        .picture => load(entry),
        .text => readText(),
        else => {},
    }
}

/// The first bytes of a file, read for what they say it is. A file that
/// cannot be read is data, which is what nothing more can be said about.
fn sniff(path: []const u8) kind.Reading {
    var first: [kind.ENOUGH]u8 = undefined;
    const n = file.readWhole(path, &first) orelse return .{ .kind = .data };
    return kind.fromBytes(first[0..n]);
}

/// The reading as a field's value: the bytes' own words, capitalised. The
/// words come back either written into `into` or as a literal, so they are
/// brought into `into` before the first is raised.
fn readingSays(into: *[kind.SAYS_MAX]u8) []const u8 {
    const said = reading.says(into);
    const n = @min(said.len, into.len);
    if (said.ptr != into) @memcpy(into[0..n], said[0..n]);
    if (n > 0) into[0] = std.ascii.toUpper(into[0]);
    return into[0..n];
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
    changed = true;
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
    return file.readWhole(shownPath(), into);
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
    if (std.mem.eql(u8, shownPath(), cachedPath())) return;
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

    // Painted when the window is, or when what is shown has changed; on any
    // other pass the pixels stand and only the text, which is a control,
    // runs.
    if (ctx.damaged or changed) {
        changed = false;
        text_top = 0;
        ctx.surface.fill(area, t.surface);
        ctx.addDamage(area);

        const chosen = entry orelse {
            ctx.rowText(head(area), "Nothing selected", t.text_dim);
            return;
        };

        const what = reading.kind;
        var y = drawHead(ctx, area, chosen, what);

        // A picture goes on the darkest ground the theme has, so its own edges
        // are its edges and not the pane's.
        if (what.family() == .picture) y = drawPicture(ctx, area, y);

        y = drawFacts(ctx, area, y, chosen, what);

        if (what.family() == .text and text_len > 0) text_top = y;
    }

    if (text_top != 0) drawText(ctx, area, text_top);
}

fn head(area: Rect) Rect {
    const t = theme.current();
    return .{ .x = area.x + t.menu_padding, .y = area.y + t.padding, .w = area.w, .h = t.control_height };
}

/// The name, with the picture of what it is beside it: the same two things a
/// row in the listing carries, at the top of what is being said about it.
fn drawHead(ctx: *eui.widget.Context, area: Rect, entry: dir.Entry, what: kind.Kind) i32 {
    const t = theme.current();
    const at = head(area);

    // The picture on the same line as the word beside it, which is the body
    // of the letters rather than the middle of their cell.
    ctx.surface.icon(at.x, eui.Surface.iconTopFor(at.y), Kind.icon(what), t.text);
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
fn drawFacts(ctx: *eui.widget.Context, area: Rect, from: i32, entry: dir.Entry, what: kind.Kind) i32 {
    const t = theme.current();
    var y = from;

    var kind_said: [kind.SAYS_MAX]u8 = undefined;
    y = eui.facts.one(ctx, inset(area), y, "Kind", readingSays(&kind_said));

    if (!entry.is_dir) {
        var size: [16]u8 = @splat(0);
        var said = str.Builder{ .buf = &size };
        said.bytes(entry.size);
        y = eui.facts.one(ctx, inset(area), y, "Size", said.done());
    }

    if (entry.mtime != 0) {
        var when: [24]u8 = @splat(0);
        y = eui.facts.one(ctx, inset(area), y, "Modified", time.stamp(&when, entry.mtime));
    }

    if (picture) |held| {
        var shape: [16]u8 = @splat(0);
        var said = str.Builder{ .buf = &shape };
        const upright = eui.thumb.uprightSize(held.width, held.height, facing);
        said.number(upright.w);
        said.text(" x ");
        said.number(upright.h);
        y = eui.facts.one(ctx, inset(area), y, "Pixels", said.done());
        y = eui.facts.one(ctx, inset(area), y, "Colour", depthSaid());
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
        y = eui.facts.one(ctx, inset(area), y, "Camera", said.done());
    }
    if (camera.when().len > 0) y = eui.facts.one(ctx, inset(area), y, "Taken", camera.when());
    if (camera.orientation_known and facing != .up) {
        y = eui.facts.one(ctx, inset(area), y, "Held", "sideways, shown upright");
    }

    if (trouble.len > 0 and what.family() != .picture) y = eui.facts.one(ctx, inset(area), y, "", trouble);
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
