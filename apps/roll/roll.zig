//! roll: a contact sheet for a card of photographs.
//!
//! What is on the card, laid out to look at, marked keep or reject, and the
//! keepers copied somewhere. Which picture is current, what a page holds and
//! what a filter leaves is `sheet.zig`, tested without a machine; this is the
//! window over it.
//!
//! **A picture of a picture, not the picture.** A frame out of a camera is
//! twelve megapixels, which is fifty megabytes of pixels and seconds of this
//! processor, and a page of those is a wait rather than a sheet.
//! Cameras write a small JPEG into the file's own tables for exactly this and
//! `lib.exif` finds it; a raw file carries a larger one again, and for a raw
//! file it is the only picture there is, since nothing here develops one.
//! Only a file carrying none is decoded itself.
//!
//! **A page, not a scroll.** This panel has no scroll to give: the pad speaks
//! plain relative PS/2, so there is no wheel and no edge to stroke. Walking
//! past the edge of a page turns it.
//!
//! **What changed, not what is there.** A pass arrives for every movement of
//! the pointer anywhere in the window, and this window's contents are
//! expensive: a page of plates blitted and a photograph resampled is most
//! of the machine, spent on a picture nobody touched. So the page, each cell,
//! the large picture and the key row each hold a mark of what they last drew
//! and draw only when it differs. Marking a photograph repaints two cells.
//!
//! Nothing here draws a picture, a fact row or a key chip of its own. The
//! toolkit shrinks and stands a picture up for the viewer and the file
//! manager already, and this asks it for the same thing at two sizes.

const std = @import("std");
const eui = @import("eui");
const img = @import("img");
const proto = @import("proto");
const sys = @import("sys");
const ulib = @import("ulib");

const dir = ulib.dir;
const env = ulib.env;
const file = ulib.file;
const heap = ulib.heap;
const info = ulib.info;
const paths = ulib.paths;
const str = ulib.str;
const time = ulib.time;
const exif = @import("lib").exif;
const kind = @import("lib").kind;
const mounts = @import("lib").mounts;
const Bounded = @import("lib").Bounded;
const sheet_mod = @import("sheet.zig");

const KeyCode = proto.app.KeyCode;
const Modifiers = proto.app.Modifiers;
const Rect = eui.Rect;
const Fingerprint = eui.widget.Fingerprint;
const theme = eui.theme;
const ctx = &proto.app.ctx;
const connection = &proto.app.connection;

// The picture decoder is C and calls the libc by name: the C-callable half is
// imported so its exports land in this binary. One implementation, not two.
comptime {
    _ = @import("clibc");
}

/// Where keepers go until somebody says otherwise.
const PICTURES = mounts.HOME ++ "/pictures";

/// What has been decided, written beside the pictures it is about.
///
/// Beside them rather than under home, because the decisions belong to the
/// card: a card culled on one machine and carried to another arrives with
/// what was decided about it, and a card whose pictures are deleted takes
/// this with them.
const MARKS = "roll.marks";

/// The most a folder's decisions come to: every picture in a roll at a name's
/// length, and the heading above them.
const MARKS_MAX = sheet_mod.MAX * (paths.MAX / 4) + 512;

/// The smallest a thumbnail is worth showing at.
///
/// As many as fit at this width go across, and then they are grown to fill
/// the room exactly: a grid of fixed cells leaves a column's worth of nothing
/// at one edge, and that space is better spent on the pictures. Chosen so
/// five go across the 701's panel, which is the shape the sheet was drawn
/// for.
const CELL_LEAST = 140;

/// What a plate's shape starts from before the room has its say: a
/// photograph's own, near enough. The room decides the rest, and a picture is
/// centred in whatever shape the plate ends up, so nothing is stretched.
const PLATE_WIDE = 3;
const PLATE_TALL = 2;

/// What a cell holds besides its picture: the border it draws inside, and the
/// strip its name sits on. What goes inside sits at a fixed inset whether or
/// not the cell is the current one, because a plate that moved when the eye
/// landed on it would read as a jump.
const INSET = 2;
const CAPTION_H = 18;

/// What the facts take beside the picture when they are shown.
const FACTS_W = 240;

/// The corner mark saying what has been decided, on a plate and on a whole
/// picture.
const MARK_SMALL = 16;
const MARK_LARGE = 22;

/// How much of a file is read to find out what it carries.
///
/// A raw file's tables are at its front and a photograph's ride in a marker
/// near the start, and neither can be longer than this, so it settles both
/// whatever the file itself comes to. Kept small because every byte of it is
/// a sector read on a machine whose disk answers five hundred and twelve
/// bytes at a time.
const TABLES = 64 * 1024;

/// The largest picture this will read out of a file's tables. A camera writes
/// one a couple of megapixels at most; a file claiming more than this is a
/// file spending the machine's memory on a number nobody wrote.
const PREVIEW_MAX = 8 * 1024 * 1024;

/// How large a file may be before it is not read whole to decode it, for one
/// carrying no picture of its own to show instead. A plate is one of a page
/// and waits for nobody; the picture being looked at is worth the whole
/// machine for a moment.
const PLATE_BUDGET = 2 * 1024 * 1024;
const LARGE_BUDGET = 32 * 1024 * 1024;

/// What is being looked at.
const Mode = enum { roll, one };

/// Which question the folder chooser is answering.
const Asked = enum { where_from, where_to };

var sheet: sheet_mod.Sheet = .{};
var mode: Mode = .roll;
var facts_shown = true;
var asking = false;
/// The question has just opened and has yet to be given the keyboard.
var asked_now = false;
var said: []const u8 = "";

/// A path held beside the program rather than on a frame: the user stack is
/// thirty-two kilobytes for everything, and a few of these would be most of
/// it.
const Path = Bounded(u8, paths.MAX);

/// Where the pictures are.
var here: Path = .{};

/// Where the keepers go. Typed rather than only chosen, because the folder a
/// morning's work belongs in is usually one that does not exist yet, and a
/// chooser can only offer what is already there. It keeps what was last used
/// for as long as the program runs, so a card culled in three sittings lands
/// in one folder rather than three.
var where = eui.text.Field(paths.MAX){};

/// Somewhere to read a folder into, sized for a card rather than for a
/// window: a camera fills a card with hundreds of frames and the whole of
/// what is on it is the thing being looked at.
///
/// The names the sheet points into are this listing's own. It is rewritten
/// only by the next scan, which clears the sheet first, so what a shot is
/// called lasts exactly as long as the shot does.
var listing: dir.ListingOf(sheet_mod.MAX) = .{};
var listing_names: [dir.namesFor(sheet_mod.MAX)]u8 = undefined;

/// The front of one file, where its tables are. Beside the program rather
/// than on a frame: the user stack is thirty-two kilobytes for everything.
var head: [TABLES]u8 = undefined;

/// Room for the one folder a scan may descend into.
var sole: Path = .{};

/// What is mounted, which is where a card or a stick turns up: the bus
/// mounts one when it finds it and nothing announces that, so the table is
/// read again when nothing else is being asked of the disk.
var places: mounts.List = .{};

/// One cell's picture, already shrunk, and which picture it is.
///
/// Which one is recorded beside the pixels rather than assumed from where
/// they sit: a page turn is not the only thing that moves a picture out from
/// under a slot, and a filter that reorders what is shown would otherwise
/// leave every plate one place out.
const Plate = struct {
    of: usize = 0,
    ready: bool = false,
    /// What the cell holding it last drew, or nothing where it has drawn
    /// nothing yet. Kept here rather than in a control slot: a cell is not a
    /// control, and a page of them would be most of what the toolkit has room
    /// to remember about one window.
    drawn: ?i32 = null,
};

/// A plate per cell the window has room for, at the size that window draws
/// them, taken from the heap rather than fixed at either. How many fit and
/// how large they are are both facts about the window, and a fixed store
/// either leaves a large window's rows empty or keeps a large window's worth
/// of pixels for a small one.
var plates: []Plate = &.{};
var plate_pixels: []eui.Color = &.{};
var plate_w: i32 = 0;
var plate_h: i32 = 0;

/// The one picture being looked at large, decoded once and kept while it is.
///
/// Which one was last looked for is kept apart from whether one came back: a
/// file this build cannot show would otherwise be read and refused again on
/// every pass over it.
var large: ?img.Picture = null;
var large_of: ?usize = null;
var camera: exif.Info = .{};

/// When it was written, worked out once.
///
/// A timestamp is a sixty-four bit count of seconds, and turning one into a
/// date is ten divisions this processor has no instruction for. Once per
/// picture rather than once per pass over it.
var when: [24]u8 = undefined;
var when_said: []const u8 = "";

var dialog: proto.FileDialog = .{};
var dialog_for: Asked = .where_from;

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    where.init(.{ .initial = PICTURES, .hint = "a folder for this work" });
    if (env.argument(frame)) |wanted| open(wanted) else start();

    proto.app.run("roll", "Roll", 800, 480, .{
        .draw = draw,
        .key = key,
        .text = typed,
        .event = ownWindows,
        .close = close,
        .tick = fillOne,
        // Short while there are pictures left to read. `fillOne` lengthens it
        // once there are not, so a finished sheet sleeps.
        .tick_us = 1_000,
    });
}

// ---------------------------------------------------------------------------
// Where the pictures are
// ---------------------------------------------------------------------------

/// Read what is mounted. Says whether anything changed.
fn readPlaces() bool {
    var buf: [mounts.TEXT]u8 = undefined;
    return places.read(info.ask("mounts", &buf), .personal);
}

/// Where to start looking: a card with photographs on it, or the pictures
/// folder.
///
/// Tried rather than assumed. A card mounts under `/media` when the bus finds
/// it, and so does whatever else the machine happens to keep there, so the
/// one worth opening is the one that turns out to have photographs on it.
fn start() void {
    _ = readPlaces();
    for (places.slice()) |volume| {
        if (!std.mem.startsWith(u8, volume.path(), mounts.MEDIA ++ "/")) continue;
        open(volume.path());
        if (sheet.shots.len != 0) return;
    }
    open(PICTURES);
}

/// Open a folder, and go down to where the camera actually put the pictures.
///
/// A card holds `DCIM`, and `DCIM` holds one folder per camera. Following a
/// folder that holds nothing but one other folder is what saves pressing into
/// it twice on every card.
fn open(path: []const u8) void {
    saveMarks();
    _ = readPlaces();

    var wanted: Path = .{};
    _ = wanted.set(path);
    var down: usize = 0;
    while (down < 3) : (down += 1) {
        scan(wanted.slice());
        if (sheet.shots.len != 0) break;
        const only = soleFolder(wanted.slice()) orelse break;
        _ = wanted.set(only);
    }

    here = wanted;
    forgetPlates();
}

/// The one directory in the folder just listed, when it holds exactly one and
/// no pictures.
fn soleFolder(from: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (listing.items()) |entry| {
        if (!entry.is_dir or std.mem.eql(u8, entry.name, dir.PARENT)) continue;
        if (entry.name.len != 0 and entry.name[0] == '.') continue;
        if (found != null) return null;
        found = entry.name;
    }

    const name = found orelse return null;
    return paths.joined(from, name, &sole.items);
}

/// Read one folder into the sheet: every picture in it, by name.
///
/// Names only. A name costs a directory entry and a picture costs a decode,
/// so the sheet is whole and can be walked and marked before any of it has
/// been looked at.
fn scan(path: []const u8) void {
    sheet.clear();
    said = "";
    ours = true;

    dir.read(path, &listing_names, &listing) catch {
        said = "That folder will not open.";
        return;
    };
    if (listing.truncated) sheet.truncated = true;

    for (listing.items()) |entry| {
        if (entry.is_dir) continue;
        const what = kind.fromName(entry.name) orelse continue;
        if (!what.viewable()) continue;

        sheet.add(.{ .name = entry.name, .size = entry.size, .mtime = entry.mtime });
    }

    loadMarks(path);
}

/// Whether the decisions beside these pictures are this program's to write.
/// A file it cannot read is a file it must not replace.
var ours = true;

/// What was decided about this folder last time, if anything was.
fn loadMarks(path: []const u8) void {
    var buf: [paths.MAX]u8 = undefined;
    const at = paths.joined(path, MARKS, &buf) orelse return;

    // Most folders have none, and one that does says how much room to take
    // before any is taken.
    const room = file.readAlloc(heap.allocator, at, MARKS_MAX) catch return;
    defer heap.allocator.free(room);
    if (room.len == 0) return;

    ours = sheet.readMarks(room) == .taken;
    if (!ours) said = "What was decided here was written by a later roll.";
}

/// Write down what has been decided, if anything has changed and the file is
/// this program's to write.
///
/// Called where a decision would otherwise be lost: when the sheet has
/// nothing left to read, when the folder is about to change, and when the
/// window is asked to close. Not on every keystroke: that is a write to the
/// card per picture, and a card is a slow thing to write to.
fn saveMarks() void {
    if (!sheet.dirty or !ours or sheet.shots.len == 0) return;

    var buf: [paths.MAX]u8 = undefined;
    const at = paths.joined(here.slice(), MARKS, &buf) orelse return;

    const room = heap.allocator.alloc(u8, MARKS_MAX) catch return;
    defer heap.allocator.free(room);

    var written = str.Builder{ .buf = room };
    sheet.writeMarks(&written);

    if (!written.cut) {
        if (file.put(at, written.done())) |_| {
            sheet.dirty = false;
            return;
        } else |_| {}
    }

    // Said once, and not tried again: a card that is full or will not take a
    // write does not take one on the next pass either, and a failing write a
    // second is worse than a window that says so and stops.
    said = "What was decided here could not be written down.";
    ours = false;
}

fn pathOf(shot: sheet_mod.Shot, into: []u8) ?[]const u8 {
    return paths.joined(here.slice(), shot.name, into);
}

// ---------------------------------------------------------------------------
// Getting a picture out of a file
// ---------------------------------------------------------------------------

/// A picture out of a file, and what the camera wrote beside it.
const Taken = struct { picture: img.Picture, camera: exif.Info = .{} };

/// The picture a file carries, or the file itself where it carries none.
///
/// The tables first, which are at the front whatever the file is. For a
/// photograph the small picture they name is usually in the same stretch; for
/// a raw file it is megabytes further in, so what the front gives is where it
/// is and exactly that stretch is read. Reading a twelve megabyte file to
/// take one megabyte out of the middle is the thing a contact sheet cannot
/// afford once per cell on the page.
///
/// Only a file carrying no picture at all is decoded itself, and only up to
/// `budget`: a raw file has nothing to fall back to, since there is no
/// demosaicer here, and a photograph too large for the budget is left to
/// whoever asks with a larger one.
fn take(path: []const u8, budget: usize) ?Taken {
    const what = kind.fromName(path) orelse return null;
    const read = file.readWhole(path, &head) orelse return null;
    if (read == 0) return null;

    const front = head[0..read];
    if (exif.carried(front)) |span| {
        if (span.at + span.len <= read) {
            if (decoded(front[span.at..][0..span.len], front)) |got| return got;
        } else if (span.len >= 4 and span.len <= PREVIEW_MAX) {
            if (readSpan(path, span)) |bytes| {
                defer heap.allocator.free(bytes);
                if (decoded(bytes, front)) |got| return got;
            }
        }
    }

    if (!what.opens()) return null;
    if (read < TABLES) return .{ .picture = img.decode(front) catch return null, .camera = exif.read(front) };

    const size = sizeOf(path) orelse return null;
    if (size == 0 or size > budget) return null;

    const room = heap.allocator.alloc(u8, size) catch return null;
    defer heap.allocator.free(room);
    const all = room[0 .. file.readWhole(path, room) orelse return null];

    // The camera's words are in the front either way, so they are read from
    // there rather than from the copy about to be given back.
    return .{ .picture = img.decode(all) catch return null, .camera = exif.read(front) };
}

/// The stretch a file's tables named, read out of the middle of it.
fn readSpan(path: []const u8, span: exif.Carried) ?[]u8 {
    const room = heap.allocator.alloc(u8, span.len) catch return null;
    const got = file.readAt(path, span.at, room) orelse {
        heap.allocator.free(room);
        return null;
    };
    if (got != span.len) {
        heap.allocator.free(room);
        return null;
    }
    return room;
}

/// A carried picture, decoded, with the facts read from `facts`.
fn decoded(bytes: []const u8, facts: []const u8) ?Taken {
    if (!exif.isPicture(bytes)) return null;
    const picture = img.decode(bytes) catch return null;

    // A raw file's picture carries the camera's words where the file's outer
    // tables sometimes do not, so the fuller of the two answers.
    var said_by = exif.read(facts);
    if (said_by.camera().len == 0) said_by = exif.read(bytes);
    return .{ .picture = picture, .camera = said_by };
}

fn sizeOf(path: []const u8) ?usize {
    var record: [512]u8 = undefined;
    const told = sys.stat(path, &record) catch return null;
    const entry = sys.Dirent.decode(&record, told) orelse return null;
    return entry.size;
}

// ---------------------------------------------------------------------------
// The page's pictures, one at a time
// ---------------------------------------------------------------------------

fn forgetPlates() void {
    for (plates) |*plate| plate.ready = false;
    forgetLarge();
}

/// Everything the cell in `slot` would draw, as one number.
fn cellShape(shape: i32, slot: usize, which: usize, on: bool) i32 {
    const shot = sheet.shots.slice()[which];
    var mark = Fingerprint{};
    mark.number(@as(u32, @bitCast(shape)));
    mark.text(shot.name);
    mark.number(@intFromEnum(shot.mark));
    mark.number(shot.turn);
    mark.flag(holds(slot, which));
    mark.flag(on);
    return mark.done();
}

/// Keep a plate per cell the window has room for, at the size it draws them.
///
/// Only on a change, which is a window being resized. Where only the count
/// changed, what was already here keeps the picture it says it holds, since
/// `holds` is what decides whether the page still wants it there: a window
/// widened by a column should not read every picture on the page again for
/// the one cell it gained. Where the size changed there is nothing to keep,
/// because every plate holds pixels of the wrong shape.
///
/// A page that cannot be given its plates shows its names and no pictures,
/// which is what the sheet looks like before any of them have been read
/// anyway.
fn fitPlates(g: eui.Grid) void {
    const want = cellsIn(g);
    const plate = plateIn(g.cell(0, 0));
    const wide = @max(plate.w, 1);
    const tall = @max(plate.h, 1);
    if (plates.len == want and plate_w == wide and plate_h == tall) return;

    const resized = plate_w != wide or plate_h != tall;
    const held = if (resized) 0 else plates.len;

    const room = heap.allocator.alloc(eui.Color, want * @as(usize, @intCast(wide * tall))) catch return;
    const state = heap.allocator.alloc(Plate, want) catch {
        heap.allocator.free(room);
        return;
    };

    if (held != 0) {
        const kept = @min(held, want) * @as(usize, @intCast(wide * tall));
        @memcpy(room[0..kept], plate_pixels[0..kept]);
        @memcpy(state[0..@min(held, want)], plates[0..@min(held, want)]);
    }
    for (state[@min(held, want)..]) |*fresh| fresh.* = .{};

    if (plate_pixels.len != 0) heap.allocator.free(plate_pixels);
    if (plates.len != 0) heap.allocator.free(plates);
    plate_pixels = room;
    plates = state;
    plate_w = wide;
    plate_h = tall;
}

/// Whether the plate in `slot` is the picture the page now wants there.
fn holds(slot: usize, which: usize) bool {
    return slot < plates.len and plates[slot].ready and plates[slot].of == which;
}

fn forgetLarge() void {
    if (large) |picture| picture.deinit();
    large = null;
    large_of = null;
    camera = .{};
    when_said = "";
}

/// Read one picture the page shows and has not got yet, and say whether
/// anything changed.
///
/// One a pass, so a key is answered between every two of them: a folder of a
/// hundred photographs fills in while somebody is already walking it rather
/// than before they may start.
fn fillOne() bool {
    const page = sheet.page();
    var slot: usize = 0;
    while (page.from + slot < page.to and slot < plates.len) : (slot += 1) {
        const which = sheet.at_nth(page.from + slot) orelse continue;
        if (holds(slot, which)) continue;

        plates[slot].ready = true;
        plates[slot].of = which;
        fillPlate(slot, sheet.shots.slice()[which]);

        // Something on screen changed, and there may be more behind it.
        proto.app.retick(1_000);
        return true;
    }

    // Nothing left to read. The page asks again the moment it wants a
    // picture it has not got, so this is only how long a finished sheet
    // waits before looking at what is mounted.
    proto.app.retick(1_000_000);

    // Nothing else is being asked of the reader, so this is the moment to
    // write down what has been decided and to look for a card put in while
    // the window was open.
    saveMarks();
    return readPlaces();
}

/// Shrink one picture onto its plate.
///
/// The toolkit's own shrinking, painted onto the plate as if it were a
/// screen: it stands the picture up the way the camera held it and samples
/// rather than averages, which is what makes a large photograph affordable
/// here at all. Sampled once into the plate, and blitted from there on every
/// pass that has to redraw the cell.
fn fillPlate(slot: usize, shot: sheet_mod.Shot) void {
    const plate = plateSurface(slot);
    const whole = Rect{ .x = 0, .y = 0, .w = plate_w, .h = plate_h };
    const ground = theme.current().surface_pressed;

    var buf: [paths.MAX]u8 = undefined;
    const path = pathOf(shot, &buf) orelse return plate.fill(whole, ground);
    const got = take(path, PLATE_BUDGET) orelse return plate.fill(whole, ground);
    defer got.picture.deinit();

    _ = paintPicture(plate, whole, got, shot.turn, ground);
}

fn plateSurface(slot: usize) eui.Surface {
    const span: usize = @intCast(plate_w * plate_h);
    return eui.Surface.init(plate_pixels[slot * span ..].ptr, plate_w, plate_h, plate_w);
}

/// One picture, shrunk to fit `area`, stood upright, and the ground around it
/// filled in one pass rather than two.
///
/// The turn a person asked for is a quarter on top of the way the camera held
/// it rather than a second idea of which way up something is, which is what
/// `eimg` does with the same two keys.
fn paintPicture(surface: eui.Surface, area: Rect, got: Taken, turn: u2, ground: eui.Color) Rect {
    const held = got.camera.orientation.turnedBy(turn);
    const upright = eui.thumb.uprightSize(got.picture.width, got.picture.height, held);
    const into = eui.thumb.fit(area, upright.w, upright.h);

    // Only what the picture leaves over, so a photograph nearly filling its
    // room costs the border rather than the room twice.
    surface.fillAround(area, into, ground);
    eui.thumb.paint(
        surface,
        into,
        .{ .pixels = got.picture.pixels, .width = got.picture.width, .height = got.picture.height },
        held,
    );
    return into;
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

fn draw() void {
    const parts = eui.chrome.split(ctx.bounds(), .{ .top = true, .bottom = true });

    // The question takes room from the work rather than sitting over it: a
    // sheet drawn on top is a sheet whatever is under it paints away the
    // moment that changes for its own reasons.
    const asked: i32 = if (asking) theme.stripHeight() else 0;
    const body = Rect{ .x = parts.body.x, .y = parts.body.y, .w = parts.body.w, .h = parts.body.h - asked };

    drawPlaces(parts.top);
    if (mode == .roll) drawRoll(body) else drawOne(body);
    if (asking) drawAsking(.{ .x = body.x, .y = body.bottom(), .w = body.w, .h = asked });
    drawKeys(parts.bottom);
}

/// Whether what sits at `area` has to be drawn again, remembering `shape` as
/// what it will have drawn.
///
/// The one check every expensive part of this window makes. A slot is claimed
/// either way, so nothing here is taken for a control that has gone.
fn stale(area: Rect, shape: i32) bool {
    const entry = ctx.slotFor(area) orelse return true;
    entry.seen = true;
    if (!ctx.damaged and entry.detail == shape) return false;
    entry.detail = shape;
    return true;
}

/// The row of places, and what the roll comes to.
///
/// The toolkit's own row, which is what the file manager puts its volumes in:
/// a card or a stick is the same kind of thing to both, and how full one is
/// is exactly what somebody about to copy onto it wants to know.
fn drawPlaces(area: Rect) void {
    const t = theme.current();

    // No key hint on the row: what the file manager names there is what its
    // keyboard does to a volume, and choosing a folder is not about the row
    // it would sit on. It is in the key strip with the rest of the commands.
    const pass = eui.places.strip(ctx, area, &places, places.holding(here.slice()), &.{});
    if (pass.chose) |index| {
        open(places.slice()[index].path());
        ctx.damage();
    }

    // The whole height of the row less its rule, which is what the places
    // beside it take, so what is said here sits on their line.
    const from = pass.after + t.padding;
    drawWhere(
        .{ .x = from, .y = area.y, .w = area.right() - t.menu_padding - from, .h = area.h - 1 },
        pass.painted,
    );
}

/// Where the pictures are and how the roll stands, in one line against the
/// right edge: the folder, then what has been decided where anything has, or
/// how many there are where nothing has.
///
/// One phrase rather than two things at either end of the strip, because it
/// is one statement: this folder, this many. A message about the folder takes
/// its place, since it is about the same thing and there is one place to look.
fn drawWhere(area: Rect, over: bool) void {
    if (area.w <= 0) return;
    const t = theme.current();
    const seen = sheet.counts();

    var mark = Fingerprint{};
    mark.text(here.slice());
    mark.text(said);
    mark.number(seen.all);
    mark.number(seen.kept);
    mark.number(seen.rejected);
    mark.flag(sheet.truncated);
    mark.flag(sheet.kept_only);

    // Drawn again whenever the row beside it was, since the row paints the
    // whole strip and this sits on the part of it the row does not use.
    const fresh = stale(area, mark.done());
    if (!fresh and !over) return;

    ctx.surface.fill(area, t.surface_pressed);
    ctx.addDamage(area);

    const baseline = area.y + @divTrunc(area.h - eui.Surface.textHeight(), 2);
    const right = area.right();

    if (sheet.kept_only) {
        const chip = Rect{
            .x = area.x,
            .y = area.y + @divTrunc(area.h - t.control_height, 2),
            .w = eui.Surface.textWidth(KEPT_ONLY) + t.padding * 2,
            .h = t.control_height,
        };
        ctx.surface.fillRounded(chip, t.corner_radius, .all, t.accent);
        ctx.surface.textCentred(chip, KEPT_ONLY, t.accent_text);
    }
    const from = area.x + if (sheet.kept_only)
        eui.Surface.textWidth(KEPT_ONLY) + t.padding * 3
    else
        0;

    // A message is about this folder, so it stands where the folder does.
    if (said.len != 0) {
        ctx.surface.textFitted(from, baseline, right - from, said, t.text_dim);
        return;
    }

    var buf: [48]u8 = undefined;
    var line = str.Builder{ .buf = &buf };
    line.text(" \u{00B7} ");
    if (seen.kept != 0 or seen.rejected != 0) {
        line.number(seen.kept);
        line.text(" kept, ");
        line.number(seen.rejected);
        line.text(" rejected");
    } else {
        line.number(seen.all);
        // A plus rather than a sentence: the strip has a character to spare
        // for "there are more of these" and not a phrase.
        if (sheet.truncated) line.byte('+');
        line.text(if (seen.all == 1) " photo" else " photos");
    }

    // Right-aligned where the two fit, and where they do not the folder is
    // what gives way: a count half drawn says nothing, and a folder cut short
    // still says which one it is.
    const tail = line.done();
    const tail_w = eui.Surface.textWidth(tail);
    const folder = here.slice();
    const folder_w = eui.Surface.textWidth(folder);

    const room = right - from;
    const whole = folder_w + tail_w;
    const shown = @min(folder_w, room - tail_w);
    if (shown <= 0) return;

    const x = if (whole <= room) right - whole else from;
    ctx.surface.textFitted(x, baseline, shown, folder, t.text_dim);
    ctx.surface.text(x + shown, baseline, tail, t.text_dim);
}

const KEPT_ONLY = "kept only";

/// The grid the sheet is laid out on: as many cells of at least `CELL_LEAST`
/// as fit, grown to fill the room exactly.
///
/// The arithmetic is the toolkit's. What is decided here is the one thing it
/// cannot know: how tall a cell wants to be for the width it was given, which
/// is a plate at a photograph's shape with a name under it.
fn gridOf(area: Rect) eui.Grid {
    const t = theme.current();
    const room = area.inset(t.padding);

    var out = eui.Grid{
        .area = room,
        .columns = eui.Grid.fitting(room.w, CELL_LEAST, t.gap),
        .rows = 1,
        .gap = t.gap,
    };
    const wide = out.cell(0, 0).w - INSET * 2;
    const wants = INSET * 2 + CAPTION_H + @divTrunc(wide * PLATE_TALL, PLATE_WIDE);
    out.rows = eui.Grid.fitting(room.h, wants, t.gap);
    return out;
}

fn cellsIn(g: eui.Grid) usize {
    return @intCast(@max(g.columns * g.rows, 0));
}

fn cellAt(g: eui.Grid, slot: usize) Rect {
    const at: i32 = @intCast(slot);
    return g.cell(@mod(at, g.columns), @divTrunc(at, g.columns));
}

/// The plate inside a cell: what is left once the border and the name have
/// had theirs.
fn plateIn(cell: Rect) Rect {
    return .{
        .x = cell.x + INSET,
        .y = cell.y + INSET,
        .w = cell.w - INSET * 2,
        .h = cell.h - INSET * 2 - CAPTION_H,
    };
}

var grid: eui.Grid = .{ .area = .{}, .columns = 1, .rows = 1 };

/// Where the page sits in the roll, and a way to take hold of it.
///
/// The sheet still pages: this says where in a card of several hundred the
/// page is, and lets somebody go somewhere else in it without walking every
/// row between. It draws nothing at all when the whole roll is on one page,
/// so a folder of a dozen photographs is the sheet and nothing else.
var along: eui.scroll.State = .{};

/// The page of thumbnails.
fn drawRoll(area: Rect) void {
    const t = theme.current();

    // The room the bar takes is kept whether or not it is drawn: a grid that
    // relaid itself the moment a roll grew past one page would move every
    // picture under the hand about to press one.
    const cells = Rect{ .x = area.x, .y = area.y, .w = area.w - eui.scroll.WIDTH - t.padding, .h = area.h };
    grid = gridOf(cells);
    sheet.per_page = cellsIn(grid);
    fitPlates(grid);

    // Before anything is measured from it, since either can move the eye and
    // what is drawn should be where the eye now is rather than a pass behind.
    takeBar(area);
    takeCellPresses(sheet.page());

    // What the page as a whole is showing. When this changes the ground under
    // it is no longer the right ground: a shorter page leaves cells behind,
    // and a filter can leave the same picture in the same place on a page
    // that has been cleared.
    const page = sheet.page();
    var mark = Fingerprint{};
    mark.text(here.slice());
    mark.number(page.from);
    mark.number(page.to);
    mark.number(@intCast(@max(grid.columns, 0)));
    mark.number(@intCast(@max(grid.rows, 0)));
    mark.flag(sheet.kept_only);
    const shape = mark.done();

    // The ground under the cells and not under the bar beside them: the bar
    // draws itself only when what it says changes, so anything painting over
    // it leaves it painted over.
    const fresh = stale(area, shape);
    if (fresh and !ctx.damaged) {
        ctx.surface.fill(cells, t.surface);
        ctx.addDamage(cells);
    }

    if (sheet.count() == 0) {
        if (fresh) drawBare(area);
        return;
    }

    var waiting = false;
    var slot: usize = 0;
    while (page.from + slot < page.to) : (slot += 1) {
        const which = sheet.at_nth(page.from + slot) orelse break;
        if (!holds(slot, which)) waiting = true;
        drawCell(cellAt(grid, slot), shape, slot, which, page.from + slot == sheet.at);
    }

    // The reading is asked for by whoever notices something missing, so a
    // page just turned to fills without waiting out the idle period a
    // finished one settled into.
    if (waiting) proto.app.retick(1_000);
}

/// Where the page sits in the roll. Dragged or pressed, it goes there.
///
/// A page rather than a row: the sheet has no half-drawn row to stop on, so
/// whatever the bar lands on is taken as the page holding it.
fn takeBar(area: Rect) void {
    const t = theme.current();
    const page = sheet.page();
    const groove = Rect{
        .x = area.right() - eui.scroll.WIDTH,
        .y = area.y + t.padding,
        .w = eui.scroll.WIDTH,
        .h = area.h - t.padding * 2,
    };

    const to = ctx.scrollbar(groove, &along, page.from, sheet.count(), sheet.per_page);
    if (to == page.from) return;

    const per = @max(sheet.per_page, 1);
    sheet.at = to - to % per;
}

/// A press in the page: the picture under it, or the one already under the
/// eye opened large.
///
/// Hit tested rather than made a control per cell, because a cell is not one:
/// a page of them in the tab order is a page of stops on the way to the one
/// button this window has.
fn takeCellPresses(page: sheet_mod.Page) void {
    if (!ctx.pressedThisPass()) return;

    var slot: usize = 0;
    while (page.from + slot < page.to) : (slot += 1) {
        if (!cellAt(grid, slot).contains(ctx.pointer_x, ctx.pointer_y)) continue;

        if (sheet.at == page.from + slot) {
            mode = .one;
            ctx.damage();
        } else {
            sheet.at = page.from + slot;
        }
        return;
    }
}

fn drawCell(cell: Rect, shape: i32, slot: usize, which: usize, on: bool) void {
    const shot = sheet.shots.slice()[which];
    const ready = holds(slot, which);

    const drawing = cellShape(shape, slot, which, on);
    if (slot < plates.len) {
        if (!ctx.damaged and plates[slot].drawn == drawing) return;
        plates[slot].drawn = drawing;
    }

    const t = theme.current();
    const plate = plateIn(cell);

    // Only what the plate does not cover: the border, and the strip the name
    // sits on. The plate itself is written once, below.
    ctx.surface.fillAround(cell, plate, if (on) t.surface_pressed else t.surface);
    var ring: i32 = 0;
    while (ring < (if (on) t.border_width_focused else t.border_width)) : (ring += 1) {
        ctx.surface.frameRounded(cell.inset(ring), t.corner_radius - ring, .all, if (on) t.accent else t.border);
    }

    if (ready) {
        ctx.surface.copyFrom(plateSurface(slot), plate.x, plate.y, plate);
    } else {
        // Its name is known and its picture is not here yet. Marking it does
        // not wait for one.
        ctx.surface.fill(plate, t.surface_pressed);
    }

    drawMark(plate, shot.mark, MARK_SMALL);
    ctx.surface.textFitted(
        plate.x + 4,
        plate.bottom() + @divTrunc(CAPTION_H - eui.Surface.textHeight(), 2),
        plate.w - 8,
        shot.name,
        if (on) t.text else t.text_dim,
    );
    ctx.addDamage(cell);
}

/// What has been decided about a picture, in the corner of it.
fn drawMark(over: Rect, what: sheet_mod.Mark, side: i32) void {
    if (what == .none) return;
    const t = theme.current();

    const gap = @divTrunc(side, 4);
    const box = Rect{ .x = over.right() - side - gap, .y = over.y + gap, .w = side, .h = side };
    ctx.surface.fillRounded(box, t.corner_radius, .all, if (what == .keep) t.accent else t.warning);
    ctx.surface.icon(
        box.x + @divTrunc(side - eui.Surface.iconSize(), 2),
        box.y + @divTrunc(side - eui.Surface.iconSize(), 2),
        if (what == .keep) .check else .cross,
        t.accent_text,
    );
}

fn drawBare(area: Rect) void {
    const t = theme.current();
    const title = if (sheet.kept_only) "Nothing kept yet" else "No pictures here";
    const says = if (sheet.kept_only)
        "Press f to see the whole roll again."
    else if (said.len != 0)
        said
    else
        "Choose another place, or put a card in the reader.";

    const y = area.y + @divTrunc(area.h, 2) - t.control_height;
    ctx.surface.textCentred(.{ .x = area.x, .y = y, .w = area.w, .h = t.control_height }, title, t.text);
    ctx.surface.textCentred(
        .{ .x = area.x, .y = y + t.control_height, .w = area.w, .h = t.control_height },
        says,
        t.text_dim,
    );
}

/// One picture, as large as the room allows, on the darkest ground the theme
/// has, which is how the viewer shows one.
fn drawOne(area: Rect) void {
    const t = theme.current();
    const facts_w: i32 = if (facts_shown) FACTS_W + 1 else 0;
    const stage = Rect{ .x = area.x, .y = area.y, .w = area.w - facts_w, .h = area.h };

    const shot = sheet.current() orelse {
        if (ctx.damaged) ctx.addDamage(area);
        drawBare(area);
        return;
    };

    // The one picture is decoded from the file rather than taken from its
    // plate: a plate is a hundred and forty-seven pixels across, and blowing
    // that up would be a blurry claim to detail it does not hold.
    const which = sheet.at_nth(sheet.at) orelse 0;
    if (large_of != which) {
        forgetLarge();
        var buf: [paths.MAX]u8 = undefined;
        if (pathOf(shot.*, &buf)) |path| {
            if (take(path, LARGE_BUDGET)) |got| {
                large = got.picture;
                camera = got.camera;
            }
        }
        large_of = which;
        when_said = time.stamp(&when, shot.mtime);
    }

    var mark = Fingerprint{};
    mark.number(which);
    mark.number(shot.turn);
    mark.number(@intFromEnum(shot.mark));
    mark.flag(large != null);
    if (stale(stage, mark.done())) {
        if (large) |held| {
            const room = stage.inset(t.padding);
            const shown = paintPicture(ctx.surface, room, .{ .picture = held, .camera = camera }, shot.turn, t.desktop);
            ctx.surface.fillAround(stage, room, t.desktop);
            drawMark(shown, shot.mark, MARK_LARGE);
        } else {
            ctx.surface.fill(stage, t.desktop);
            ctx.surface.textCentred(stage, "Nothing in this file can be shown.", t.text_inverted);
        }
        ctx.addDamage(stage);
    }

    if (!facts_shown) return;
    const aside = Rect{ .x = stage.right() + 1, .y = area.y, .w = FACTS_W, .h = area.h };
    if (ctx.damaged) {
        ctx.surface.fill(.{ .x = stage.right(), .y = area.y, .w = 1, .h = area.h }, t.line);
        ctx.surface.fill(aside, t.surface);
        ctx.addDamage(aside);
    }
    drawFacts(aside, shot.*);
}

/// What is known about the picture: what the file is, and what the camera
/// wrote beside it.
///
/// Always the same rows in the same order, blank where a photograph says
/// nothing. A list that grew and shrank with what each file happened to
/// carry would move every row under the one that came and went, and each row
/// repaints itself only when what it says changes, so a row that moved would
/// leave the words it used to say behind it.
fn drawFacts(area: Rect, shot: sheet_mod.Shot) void {
    const t = theme.current();
    const inner = Rect{
        .x = area.x + t.padding,
        .y = area.y + t.padding,
        .w = area.w - t.padding * 2,
        .h = area.h - t.padding * 2,
    };

    // Its name, and the two turns, which are the viewer's own r and l put
    // where a hand on the pad can reach them.
    const turns = t.control_height * 2 + t.padding;
    const turn_x = inner.right() - turns;
    if (ctx.button(.{ .x = turn_x, .y = inner.y, .w = t.control_height, .h = t.control_height }, "\u{2190}")) {
        turnHere(-1);
    }
    if (ctx.button(.{ .x = turn_x + t.control_height + t.padding, .y = inner.y, .w = t.control_height, .h = t.control_height }, "\u{2192}")) {
        turnHere(1);
    }

    ctx.label(.{
        .x = inner.x,
        .y = inner.y + @divTrunc(t.control_height - eui.Surface.textHeight(), 2),
        .w = inner.w - turns - t.padding,
        .h = eui.Surface.textHeight(),
    }, shot.name);

    var pixels: [24]u8 = undefined;
    var written: [24]u8 = undefined;
    var made: [exif.TEXT_MAX * 2 + 1]u8 = undefined;

    var shape = str.Builder{ .buf = &pixels };
    if (large) |held| {
        const upright = eui.thumb.uprightSize(held.width, held.height, camera.orientation.turnedBy(shot.turn));
        shape.number(upright.w);
        shape.text(" x ");
        shape.number(upright.h);
    }

    var size = str.Builder{ .buf = &written };
    size.bytes(shot.size);

    var maker = str.Builder{ .buf = &made };
    maker.text(camera.maker());
    if (camera.maker().len != 0 and camera.camera().len != 0) maker.byte(' ');
    maker.text(camera.camera());

    const what: kind.Kind = kind.fromName(shot.name) orelse .data;
    const rows = [_]eui.facts.Fact{
        .{ .label = "Kind", .value = what.says() },
        .{ .label = "Pixels", .value = orNothing(shape.done()) },
        .{ .label = "Size", .value = size.done() },
        .{ .label = "Modified", .value = when_said },
        .{ .label = "Camera", .value = orNothing(maker.done()) },
        .{ .label = "Taken", .value = orNothing(camera.when()) },
        .{ .label = "Marked", .value = switch (shot.mark) {
            .keep => "kept",
            .reject => "rejected",
            .none => "not yet",
        } },
    };

    // Each row is a label that repaints only when what it says changes, so a
    // pass over a picture nobody touched writes nothing here either.
    _ = eui.facts.all(ctx, inner, inner.y + t.control_height + t.padding, &rows);
}

/// A value, or what a row says when the photograph carries none. Written
/// rather than left blank: an empty row reads as a fault, and "not said" is
/// the answer to what the camera wrote.
fn orNothing(value: []const u8) []const u8 {
    return if (value.len != 0) value else "not said";
}

/// Where the keepers go, asked on a sheet across the bottom of the work,
/// which is where this system asks a question about the window it is in.
fn drawAsking(area: Rect) void {
    const t = theme.current();

    var buf: [32]u8 = undefined;
    var line = str.Builder{ .buf = &buf };
    line.text("Copy ");
    line.number(sheet.counts().kept);
    line.text(" kept to");
    const label = line.done();

    // The ground is the window's own, which the frame paints whenever the
    // question comes or goes; what is left is the rule separating the
    // question from the work above it.
    if (ctx.damaged) {
        ctx.surface.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, t.line);
        ctx.addDamage(area);
    }

    const label_w = eui.Surface.textWidth(label);
    ctx.label(.{
        .x = area.x + t.padding,
        .y = area.y + @divTrunc(area.h - eui.Surface.textHeight(), 2),
        .w = label_w,
        .h = eui.Surface.textHeight(),
    }, label);

    // The three buttons take their width from their words and the field
    // takes what is left, so a long path is scrolled inside the field rather
    // than pushing a button off the edge.
    const choose_w = eui.Surface.textWidth("Choose\u{2026}") + t.menu_padding * 2;
    const copy_w = eui.Surface.textWidth("Copy") + t.menu_padding * 2;
    const cancel_w = eui.Surface.textWidth("Cancel") + t.menu_padding * 2;
    const y = area.y + t.padding;

    const field = Rect{
        .x = area.x + t.padding * 2 + label_w,
        .y = y,
        .w = area.w - label_w - choose_w - copy_w - cancel_w - t.padding * 7,
        .h = t.control_height,
    };
    if (field.w <= 0) return;

    // The question wants the keyboard the moment it opens, or the first
    // thing typed goes to whatever had it before.
    if (asked_now) {
        asked_now = false;
        ctx.focusAt(field);
    }
    // Enter is taken by the key hook above, so what comes back here is only
    // the field asking to be finished by some other route.
    if (where.run(ctx, field)) copyKept();

    var x = field.right() + t.padding;
    if (ctx.button(.{ .x = x, .y = y, .w = choose_w, .h = t.control_height }, "Choose\u{2026}")) ask(.where_to);
    x += choose_w + t.padding;
    if (ctx.button(.{ .x = x, .y = y, .w = copy_w, .h = t.control_height }, "Copy")) copyKept();
    x += copy_w + t.padding;
    if (ctx.button(.{ .x = x, .y = y, .w = cancel_w, .h = t.control_height }, "Cancel")) {
        asking = false;
        ctx.damage();
    }
}

const ROLL_KEYS = [_]eui.keys.Key{
    .{ .key = "\u{21B5}", .label = "look" },
    .{ .key = "p", .label = "keep" },
    .{ .key = "x", .label = "reject" },
    .{ .key = "f", .label = "kept only" },
    .{ .key = "c", .label = "copy kept" },
    .{ .key = "o", .label = "folder" },
};

const ONE_KEYS = [_]eui.keys.Key{
    .{ .key = "\u{2190}\u{2192}", .label = "walk" },
    .{ .key = "r", .label = "turn" },
    .{ .key = "i", .label = "facts" },
    .{ .key = "p", .label = "keep" },
    .{ .key = "x", .label = "reject" },
    .{ .key = "esc", .label = "back" },
};

fn drawKeys(area: Rect) void {
    var buf: [48]u8 = undefined;
    var line = str.Builder{ .buf = &buf };
    const shown = sheet.count();

    if (shown == 0) {
        line.text(if (sheet.kept_only) "nothing kept yet" else "nothing here");
    } else if (mode == .roll) {
        const page = sheet.page();
        line.number(page.from + 1);
        line.text("\u{2013}");
        line.number(page.to);
        line.text(" of ");
        line.number(shown);
    } else {
        line.number(sheet.at + 1);
        line.text(" of ");
        line.number(shown);
    }

    const text = line.done();
    var mark = Fingerprint{};
    mark.text(text);
    mark.flag(mode == .roll);
    if (!stale(area, mark.done())) return;

    eui.keys.bar(ctx.surface, area, if (mode == .roll) &ROLL_KEYS else &ONE_KEYS, text);
    ctx.addDamage(area);
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

/// A key went down.
///
/// Nothing here asks for the window to be repainted. The frame draws a pass
/// after every key anyway, and what that pass finds different is what it
/// draws: a whole-window repaint for a keystroke that moved the eye one cell
/// is the ground, every plate and every control redrawn for two cells' worth
/// of change. What genuinely changes the whole window, a mode or a panel
/// appearing, says so where it happens.
fn key(code: KeyCode, mods: Modifiers) bool {
    if (mods.control or mods.alt or mods.super) return false;

    // While the question is up it takes escape and enter, so answering it
    // does not also mark a picture.
    if (asking) {
        switch (code) {
            .escape => {
                asking = false;
                ctx.damage();
            },
            .enter => copyKept(),
            else => return false,
        }
        return true;
    }

    switch (code) {
        .right => sheet.move(1),
        .left => sheet.move(-1),
        .down => sheet.move(@intCast(if (mode == .roll) grid.columns else 1)),
        .up => sheet.move(-@as(isize, @intCast(if (mode == .roll) grid.columns else 1))),
        .enter => {
            mode = .one;
            ctx.damage();
        },
        .escape => {
            if (mode == .roll) return false;
            mode = .roll;
            ctx.damage();
        },
        .p => sheet.mark(.keep),
        .x => sheet.mark(.reject),
        .r => turnHere(1),
        .l => turnHere(-1),
        .i => {
            facts_shown = !facts_shown;
            ctx.damage();
        },
        .f => {
            sheet.filter(!sheet.kept_only);
            ctx.damage();
        },
        .c => if (sheet.counts().kept != 0) {
            asking = true;
            asked_now = true;
            ctx.damage();
        },
        .o => ask(.where_from),
        else => return false,
    }
    return true;
}

/// Asked to close. What was decided goes down before the window does.
fn close() bool {
    saveMarks();
    return true;
}

/// A character was typed.
///
/// Only the question takes any, and not the one that opened it: a key is
/// delivered twice, once as the key it is and once as the letter it made,
/// and the letter of the key that put a field on screen would land in that
/// field as the first thing typed into it.
fn typed(codepoint: u32) bool {
    _ = codepoint;
    return !asking or asked_now;
}

/// Turn the current picture, and forget the plate that was sampled the way it
/// was: a plate holds pixels, not a picture to turn, so the turn is applied
/// where the picture still is, which is the file.
fn turnHere(by: i2) void {
    sheet.turn(by);

    const slot = sheet.at - sheet.page().from;
    if (slot < plates.len) plates[slot].ready = false;
    proto.app.retick(1_000);
}

// ---------------------------------------------------------------------------
// Copying
// ---------------------------------------------------------------------------

/// Copy every kept picture into the folder that was asked for.
///
/// The folder is made where it is not there, so a project folder need not
/// exist first. What is copied is the file itself rather than the picture
/// that was shown: the photograph is the thing worth keeping.
fn copyKept() void {
    asking = false;
    ctx.damage();

    const to = where.slice();
    if (to.len == 0) return;
    dir.makeWay(to);

    var moved: usize = 0;
    var refused: usize = 0;
    for (sheet.shots.slice()) |shot| {
        if (shot.mark != .keep) continue;

        var from_buf: [paths.MAX]u8 = undefined;
        var to_buf: [paths.MAX]u8 = undefined;
        const from = pathOf(shot, &from_buf) orelse continue;
        const onto = paths.joined(to, shot.name, &to_buf) orelse continue;

        if (file.copy(from, onto)) |_| {
            moved += 1;
        } else |_| {
            refused += 1;
        }
    }

    var line = str.Builder{ .buf = &said_store };
    line.number(moved);
    line.text(" copied to ");
    line.text(paths.base(to));
    if (refused != 0) {
        line.text(", ");
        line.number(refused);
        line.text(" refused");
    }
    said = line.done();
}

var said_store: [64]u8 = undefined;

// ---------------------------------------------------------------------------
// The folder chooser
// ---------------------------------------------------------------------------

fn ownWindows(event: proto.Ev) bool {
    if (!dialog.owns(event)) return false;
    if (dialog.handle(connection, event)) finish();
    return true;
}

fn ask(what: Asked) void {
    dialog_for = what;
    const from = if (what == .where_from) here.slice() else where.slice();
    dialog.show(connection, .open, from, switch (what) {
        .where_from => "Which folder of pictures",
        .where_to => "Where the keepers go",
    }) catch {
        said = "The chooser will not open.";
    };
}

/// What the chooser answered. A picture may have been pointed at, in which
/// case the folder holding it is what was meant.
fn finish() void {
    if (dialog.result == .chosen) {
        const answer = dialog.chosen();
        const folder = if (dir.isDirectory(answer)) answer else paths.parent(answer);
        switch (dialog_for) {
            .where_from => open(folder),
            .where_to => {
                where.set(folder);
                asking = true;
                asked_now = true;
            },
        }
    }
    dialog.hide(connection);
    ctx.damage();
}
