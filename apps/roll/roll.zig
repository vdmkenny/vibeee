//! roll: a contact sheet for a card of photographs.
//!
//! What is on the card, laid out to look at, marked keep or reject, and the
//! keepers copied somewhere. Which picture is current, what a page holds and
//! what a filter leaves is `sheet.zig`, tested without a machine; this is the
//! window over it.
//!
//! **A picture of a picture, not the picture.** A frame out of a camera is
//! twelve megapixels, which is fifty megabytes of pixels and seconds of this
//! processor, and a sheet of fifteen of those is a wait rather than a sheet.
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
//! expensive: fifteen plates blitted and a photograph resampled is most of
//! the machine, spent on a picture nobody touched. So the page, each cell,
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

/// Where volumes appear when the bus finds them, and where keepers go until
/// somebody says otherwise.
const MEDIA = "/media";
const PICTURES = "/home/pictures";

/// One cell of the sheet. What goes inside sits at a fixed inset whether or
/// not the cell is the current one: a plate that moved when the eye landed on
/// it would read as a jump.
///
/// Sized so five go across this panel with room to spare rather than exactly:
/// a window is the panel less whatever the desktop keeps for its own edges,
/// and a grid that only fits at the full width of the screen is a grid that
/// drops to four columns in every real window.
const CELL_W = 147;
const CELL_H = 118;
const INSET = 2;
const PLATE_W = CELL_W - INSET * 2;
const PLATE_H = 96;
const CAPTION_H = CELL_H - INSET * 2 - PLATE_H;

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
/// carrying no picture of its own to show instead. A plate is one of fifteen
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
const Path = struct {
    buf: [paths.MAX]u8 = @splat(0),
    len: usize = 0,

    fn of(value: []const u8) Path {
        var out: Path = .{};
        out.set(value);
        return out;
    }

    fn slice(self: *const Path) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Path, value: []const u8) void {
        self.len = @min(value.len, self.buf.len);
        @memcpy(self.buf[0..self.len], value[0..self.len]);
    }
};

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

/// Where the last listing was read from, and room for one folder under it.
var listed: Path = .{};
var sole: Path = .{};

/// What is mounted, which is where a card or a stick turns up: the bus
/// mounts one when it finds it and nothing announces that, so the table is
/// read again when nothing else is being asked of the disk.
var places: mounts.List = .{};

/// The pictures on the page, already shrunk. Held at the size they are drawn
/// rather than as decoded photographs, which is the whole point of a sheet.
///
/// Which picture each plate holds is recorded beside it rather than assumed
/// from where it sits: a page turn is not the only thing that moves a picture
/// out from under a slot, and a filter that reorders what is shown would
/// otherwise leave every plate one place out.
var plates: [sheet_mod.PER_PAGE][PLATE_W * PLATE_H]eui.Color = undefined;
var plate_of: [sheet_mod.PER_PAGE]usize = @splat(0);
var plate_ready: [sheet_mod.PER_PAGE]bool = @splat(false);

/// The one picture being looked at large, decoded once and kept while it is.
var large: ?img.Picture = null;
var large_of: usize = 0;
var camera: exif.Info = .{};

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
    return places.read(info.ask("mounts", &buf));
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
        if (!std.mem.startsWith(u8, volume.path(), MEDIA ++ "/")) continue;
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
    _ = readPlaces();

    var wanted = Path.of(path);
    var down: usize = 0;
    while (down < 3) : (down += 1) {
        scan(wanted.slice());
        if (sheet.shots.len != 0) break;
        const only = soleFolder() orelse break;
        wanted.set(only);
    }

    here = wanted;
    forgetPlates();
}

/// The one directory in the folder just listed, when it holds exactly one and
/// no pictures.
fn soleFolder() ?[]const u8 {
    var found: ?[]const u8 = null;
    for (listing.items()) |entry| {
        if (!entry.is_dir or std.mem.eql(u8, entry.name, dir.PARENT)) continue;
        if (entry.name.len != 0 and entry.name[0] == '.') continue;
        if (found != null) return null;
        found = entry.name;
    }

    const name = found orelse return null;
    return paths.joined(listed.slice(), name, &sole.buf);
}

/// Read one folder into the sheet: every picture in it, by name.
///
/// Names only. A name costs a directory entry and a picture costs a decode,
/// so the sheet is whole and can be walked and marked before any of it has
/// been looked at.
fn scan(path: []const u8) void {
    sheet.clear();
    said = "";
    listed.set(path);

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
/// afford fifteen times over.
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
    plate_ready = @splat(false);
    forgetLarge();
}

/// Whether the plate in `slot` is the picture the page now wants there.
fn holds(slot: usize, which: usize) bool {
    return plate_ready[slot] and plate_of[slot] == which;
}

fn forgetLarge() void {
    if (large) |held| held.deinit();
    large = null;
    camera = .{};
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
    while (page.from + slot < page.to and slot < plate_ready.len) : (slot += 1) {
        const which = sheet.at_nth(page.from + slot) orelse continue;
        if (holds(slot, which)) continue;

        plate_ready[slot] = true;
        plate_of[slot] = which;
        fillPlate(slot, sheet.shots.slice()[which]);

        // Something on screen changed, and there may be more behind it.
        proto.app.retick(1_000);
        return true;
    }

    // Nothing left to read. The page asks again the moment it wants a
    // picture it has not got, so this is only how long a finished sheet
    // waits before looking at what is mounted.
    proto.app.retick(1_000_000);

    // A card put in while this is open is a new place. Looked for here,
    // where nothing else is being asked of the reader, rather than only when
    // somebody presses something.
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
    const whole = Rect{ .x = 0, .y = 0, .w = PLATE_W, .h = PLATE_H };
    const ground = theme.current().surface_pressed;

    var buf: [paths.MAX]u8 = undefined;
    const path = pathOf(shot, &buf) orelse return plate.fill(whole, ground);
    const got = take(path, PLATE_BUDGET) orelse return plate.fill(whole, ground);
    defer got.picture.deinit();

    _ = paintPicture(plate, whole, got, shot.turn, ground);
}

fn plateSurface(slot: usize) eui.Surface {
    return eui.Surface.init(&plates[slot], PLATE_W, PLATE_H, PLATE_W);
}

/// One picture, shrunk to fit `area`, stood upright, and the ground around it
/// filled in one pass rather than two.
///
/// The turn a person asked for is a quarter on top of the way the camera held
/// it rather than a second idea of which way up something is, which is what
/// `eimg` does with the same two keys.
fn paintPicture(surface: eui.Surface, area: Rect, got: Taken, turn: u2, ground: eui.Color) Rect {
    const held = turned(got.camera.orientation, turn);
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

fn turned(from: exif.Orientation, by: u2) exif.Orientation {
    var out = from;
    var n: u2 = 0;
    while (n < by) : (n += 1) out = out.turnedRight();
    return out;
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
    const hint = [_]eui.keys.Key{.{ .key = "o", .label = "folder" }};
    const pass = eui.places.strip(ctx, area, &places, places.holding(here.slice()), &hint);
    if (pass.chose) |index| {
        open(places.slice()[index].path());
        ctx.damage();
    }

    // What the roll comes to, in what the row left over. The hint the strip
    // drew sits against the right edge, measured the same way it measured it.
    const from = pass.after + t.padding;
    const room = area.right() - eui.keys.width(hint[0], .plain) - t.padding - from;
    drawTally(.{ .x = from, .y = area.y + t.padding, .w = room, .h = t.control_height });
}

/// How the roll stands, against the right edge: what has been decided where
/// anything has, and how many pictures there are where nothing has.
fn drawTally(area: Rect) void {
    if (area.w <= 0) return;
    const t = theme.current();
    const seen = sheet.counts();

    var mark = Fingerprint{};
    mark.number(seen.all);
    mark.number(seen.kept);
    mark.number(seen.rejected);
    mark.flag(sheet.truncated);
    mark.flag(sheet.kept_only);
    if (!stale(area, mark.done())) return;

    var buf: [64]u8 = undefined;
    var line = str.Builder{ .buf = &buf };
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

    ctx.surface.fill(area, t.surface_pressed);
    ctx.addDamage(area);

    const text = line.done();
    const w = eui.Surface.textWidth(text);
    var right = area.right();

    if (sheet.kept_only) {
        const chip_w = eui.Surface.textWidth("kept only") + t.padding * 2;
        const chip = Rect{ .x = right - w - t.padding - chip_w, .y = area.y, .w = chip_w, .h = area.h };
        if (chip.x >= area.x) {
            ctx.surface.fillRounded(chip, t.corner_radius, .all, t.accent);
            ctx.surface.textCentred(chip, "kept only", t.accent_text);
            right = chip.x - t.padding;
        }
    }

    const at = eui.Surface.textHeight();
    if (right - w >= area.x) {
        ctx.surface.text(right - w, area.y + @divTrunc(area.h - at, 2), text, t.text_dim);
    }
}

/// How many cells fit in the room there is. Fixed cells and as many as go in
/// rather than cells that stretch: a thumbnail is a size, and one stretched
/// to fill a window is a blurry claim to detail the plate does not hold.
const Grid = struct {
    columns: usize,
    rows: usize,

    fn of(area: Rect) Grid {
        const t = theme.current();
        return .{
            .columns = fits(area.w - t.padding * 2, CELL_W, t.gap),
            .rows = @min(fits(area.h - t.padding * 2, CELL_H, t.gap), sheet_mod.PER_PAGE),
        };
    }

    fn fits(room: i32, side: i32, gap: i32) usize {
        if (room < side) return 1;
        return @intCast(@divTrunc(room + gap, side + gap));
    }

    fn cells(self: Grid) usize {
        return @min(self.columns * self.rows, sheet_mod.PER_PAGE);
    }

    /// Where the row of cells starts: centred in what it does not fill,
    /// because a grid pinned to the left with a column's worth of nothing on
    /// the right reads as a column that failed to draw.
    fn from(self: Grid, area: Rect) i32 {
        const across = @as(i32, @intCast(self.columns)) * (CELL_W + theme.current().gap) - theme.current().gap;
        return area.x + @divTrunc(area.w - across, 2);
    }

    fn at(self: Grid, area: Rect, slot: usize) Rect {
        const t = theme.current();
        return .{
            .x = self.from(area) + @as(i32, @intCast(slot % self.columns)) * (CELL_W + t.gap),
            .y = area.y + t.padding + @as(i32, @intCast(slot / self.columns)) * (CELL_H + t.gap),
            .w = CELL_W,
            .h = CELL_H,
        };
    }
};

var grid: Grid = .{ .columns = 5, .rows = 3 };

/// The page of thumbnails.
fn drawRoll(area: Rect) void {
    grid = Grid.of(area);
    sheet.per_page = grid.cells();

    // What the page as a whole is showing. When this changes the ground under
    // it is no longer the right ground: a shorter page leaves cells behind,
    // and a filter can leave the same picture in the same place on a page
    // that has been cleared.
    const page = sheet.page();
    var mark = Fingerprint{};
    mark.text(here.slice());
    mark.number(page.from);
    mark.number(page.to);
    mark.number(grid.columns);
    mark.flag(sheet.kept_only);
    const shape = mark.done();

    const fresh = stale(area, shape);
    if (fresh and !ctx.damaged) {
        ctx.surface.fill(area, theme.current().surface);
        ctx.addDamage(area);
    }

    if (sheet.count() == 0) {
        if (fresh) drawBare(area);
        return;
    }

    // Before the cells rather than after them, so the ring lands on the
    // picture that was pressed rather than a pass behind it.
    takeCellPresses(area, page);

    var waiting = false;
    var slot: usize = 0;
    while (page.from + slot < page.to and slot < plate_ready.len) : (slot += 1) {
        const which = sheet.at_nth(page.from + slot) orelse break;
        if (!holds(slot, which)) waiting = true;
        drawCell(grid.at(area, slot), shape, slot, which, page.from + slot == sheet.at);
    }

    // The reading is asked for by whoever notices something missing, so a
    // page just turned to fills without waiting out the idle period a
    // finished one settled into.
    if (waiting) proto.app.retick(1_000);
}

/// A press in the page: the picture under it, or the one already under the
/// eye opened large.
///
/// Hit tested rather than made a control per cell, because a cell is not one:
/// fifteen of them in the tab order is fifteen stops on the way to the one
/// button this window has.
fn takeCellPresses(area: Rect, page: sheet_mod.Page) void {
    if (!ctx.pressedThisPass()) return;

    var slot: usize = 0;
    while (page.from + slot < page.to and slot < plate_ready.len) : (slot += 1) {
        if (!grid.at(area, slot).contains(ctx.pointer_x, ctx.pointer_y)) continue;

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

    var mark = Fingerprint{};
    mark.number(@as(u32, @bitCast(shape)));
    mark.text(shot.name);
    mark.number(@intFromEnum(shot.mark));
    mark.number(shot.turn);
    mark.flag(ready);
    mark.flag(on);
    if (!stale(cell, mark.done())) return;

    const t = theme.current();
    const plate = Rect{ .x = cell.x + INSET, .y = cell.y + INSET, .w = PLATE_W, .h = PLATE_H };

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
        PLATE_W - 8,
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
    if (large == null or large_of != which) {
        forgetLarge();
        var buf: [paths.MAX]u8 = undefined;
        if (pathOf(shot.*, &buf)) |path| {
            if (take(path, LARGE_BUDGET)) |got| {
                large = got.picture;
                camera = got.camera;
            }
        }
        large_of = which;
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

    const naming = Rect{ .x = inner.x, .y = inner.y, .w = inner.w - turns - t.padding, .h = t.control_height };
    if (stale(naming, eui.widget.fingerprint(shot.name))) {
        ctx.surface.fill(naming, t.surface);
        ctx.surface.clipped(naming).textFitted(
            naming.x,
            naming.y + @divTrunc(naming.h - eui.Surface.textHeight(), 2),
            naming.w,
            shot.name,
            t.text,
        );
        ctx.addDamage(naming);
    }

    var pixels: [24]u8 = undefined;
    var written: [24]u8 = undefined;
    var when: [24]u8 = undefined;
    var made: [exif.TEXT_MAX * 2 + 1]u8 = undefined;

    var shape = str.Builder{ .buf = &pixels };
    if (large) |held| {
        const upright = eui.thumb.uprightSize(held.width, held.height, turned(camera.orientation, shot.turn));
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
        .{ .label = "Modified", .value = time.stamp(&when, shot.mtime) },
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

    if (stale(area, eui.widget.fingerprint(label))) {
        ctx.surface.fill(area, t.surface);
        ctx.surface.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, t.line);
        ctx.surface.text(
            area.x + t.padding,
            area.y + @divTrunc(area.h - eui.Surface.textHeight(), 2),
            label,
            t.text,
        );
        ctx.addDamage(area);
    }

    // The three buttons take their width from their words and the field
    // takes what is left, so a long path is scrolled inside the field rather
    // than pushing a button off the edge.
    const label_w = eui.Surface.textWidth(label);
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

    if (said.len != 0 and shown != 0) {
        line.text(said);
    } else if (shown == 0) {
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
    if (slot < plate_ready.len) plate_ready[slot] = false;
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
