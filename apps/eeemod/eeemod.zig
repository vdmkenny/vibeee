//! eeemod: a window that plays a tracker module.
//!
//! Everything about the file is in `module.zig`, and everything about
//! turning a song into sound is in `player.zig`. What is here is the
//! window: finding the file, keeping the sound service fed, and drawing
//! the pattern as it goes past.
//!
//! The loop sleeps on the sound port. The service signals when its ring
//! wants more, and the program does nothing at all until it does, so a
//! song playing costs the mixing and the drawing and no polling.

const eui = @import("eui");
const proto = @import("proto");
const ulib = @import("ulib");
const std = @import("std");

const mod = @import("module.zig");
const play = @import("player.zig");

const env = ulib.env;
const file = ulib.file;
const heap = ulib.heap;
const sys = @import("sys");
const sound = ulib.sound;
const str = @import("lib").str;

const KeyCode = proto.app.KeyCode;
const Modifiers = proto.app.Modifiers;
const Rect = eui.Rect;
const theme = eui.theme;
const ctx = &proto.app.ctx;

/// The largest module this opens. The format tops out near a megabyte of
/// samples, and a song is read whole because the player reads its samples
/// while it plays.
const MAX_FILE = 2 * 1024 * 1024;

/// Frames handed to the sound service at a time.
///
/// Every handover rings the service's doorbell, which is a call into the
/// kernel, so a small block means a ring filled from empty costs a dozen
/// of them. This much is a quarter of the ring: four calls to fill it, and
/// eight kilobytes to stage it in.
const BLOCK_FRAMES = 2048;

// ---------------------------------------------------------------------------
// What is open
// ---------------------------------------------------------------------------

var bytes: []u8 = &.{};
var song: mod.Module = .{};
var player: ?play.Player = null;
var port: ?sound.Port = null;
var mixed: [BLOCK_FRAMES * 2]i16 = @splat(0);

var path_buf: [192]u8 = @splat(0);
var path_len: usize = 0;
var trouble: []const u8 = "";
var running = true;
/// Whether the module is open with nothing to play it through.
var silent = false;

/// What the pattern strip last drew: the row highlighted, the page it was
/// on, and the place in the song. A pass that would draw the same is not
/// drawn, and one that only moved the highlight redraws two lines.
var shown_row: i32 = -1;
var shown_page: i32 = -1;
var shown_place: i32 = -1;

/// The handles the loop sleeps on: the sound port's, when there is one.
var waits: [1]u32 = @splat(0);

/// Opening a module from inside the window. The toolkit's own dialog, so
/// this looks and behaves like opening anything else on the machine.
var dialog: proto.FileDialog = .{};
const connection = &proto.app.connection;

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    if (env.argument(frame)) |wanted| load(wanted);

    proto.app.run("eeemod", "eeemod", 560, 420, .{
        .draw = draw,
        .key = key,
        .event = ownWindows,
        .wakes = waits[0..if (port == null) 0 else 1],
        .woken = woken,
        .tick = tick,
        // The sound port is what wakes this while a song plays. The tick
        // is for the window with nothing open, which has nothing to
        // redraw and nothing to feed.
        .tick_us = 500_000,
    });
}

fn path() []const u8 {
    return path_buf[0..path_len];
}

/// The dialog's events are its own.
fn ownWindows(event: proto.wm.Ev) bool {
    if (!dialog.owns(event)) return false;
    if (dialog.handle(connection, event)) finishOpening();
    return true;
}

/// Ask for a module.
fn ask() void {
    dialog.show(connection, .open, "", "Which module to play") catch {
        trouble = "the dialog would not open";
        ctx.damage();
    };
}

/// What the dialog came back with.
fn finishOpening() void {
    if (dialog.result == .chosen) load(dialog.chosen());
    dialog.hide(connection);
    ctx.damage();
}

/// Read a module and get ready to play it.
fn load(wanted: []const u8) void {
    forget();
    path_len = @min(wanted.len, path_buf.len);
    @memcpy(path_buf[0..path_len], wanted[0..path_len]);

    // How big it is before reading it, so a file too large to hold is
    // refused for the room it would have taken rather than after taking it.
    var record: [512]u8 = undefined;
    const told = sys.stat(path(), &record) catch 0;
    const entry = sys.Dirent.decode(&record, told) orelse {
        trouble = "there is no such file";
        return;
    };
    if (entry.size == 0 or entry.size > MAX_FILE) {
        trouble = "that file is too large to be a module";
        return;
    }

    const room = heap.alloc(entry.size) orelse {
        trouble = "there is not enough memory for it";
        return;
    };
    bytes = @as([*]u8, @ptrCast(room))[0..entry.size];
    const read = file.readWhole(path(), bytes) orelse {
        trouble = "it could not be read";
        return forget();
    };

    song = mod.Module.read(bytes[0..read]) catch |why| {
        trouble = switch (why) {
            error.TooShort => "it stops before the end of a module",
            error.Malformed => "it is not shaped like a module",
        };
        return forget();
    };

    player = play.Player.init(&song, (@import("lib").audio.Shape{}).rate.hertz());
    trouble = "";
    running = true;

    // The sound is a separate matter from the song. A machine with no
    // sound service still opens the module and shows what is in it, and
    // says in one line why nothing is coming out.
    const stream = sound.Port.output("eeemod", "out", .steady) catch {
        silent = true;
        return;
    };
    silent = false;
    port = stream;
    listenTo(stream.waitHandle());
}

/// Wait on the sound port as well as the manager.
///
/// Said again whenever a module is opened, not only when the window is.
/// A program started with a file already names its port before the loop
/// begins, but one started bare and given a file afterwards opens its
/// port after the loop has read the set: without this, nothing would
/// wake it as the ring drains and the only thing feeding the stream
/// would be the slow tick underneath, which is a fifth of a second of
/// sound and then silence until the next one.
fn listenTo(handle: u32) void {
    waits[0] = handle;
    proto.app.wakeOn(waits[0..1]);
}

/// Let go of whatever was open. Called before opening anything else, so
/// a second module does not leave the first one's memory behind.
fn forget() void {
    if (port) |stream| {
        stream.close();
        // The handle is gone, so nothing waits on it until the next one.
        proto.app.wakeOn(waits[0..0]);
    }
    port = null;
    silent = false;
    player = null;
    if (bytes.len != 0) heap.release(bytes.ptr);
    bytes = &.{};
    song = .{};
    shown_row = -1;
    shown_page = -1;
    shown_place = -1;
    widest_gap_ms = 0;
    widest_since = 0;
    fed_at = 0;
}

// ---------------------------------------------------------------------------
// Keeping the sound going
// ---------------------------------------------------------------------------

/// The sound service says its ring wants more.
///
/// Answering true redraws, which is worth doing only when the song has
/// moved to another row: the ring is fed several times a row, and a
/// window redrawn every time would be a window redrawn for nothing.
fn woken(index: usize) bool {
    _ = index;
    feed();
    return moved();
}

fn tick() bool {
    // Without a sound port nothing wakes this, so the fallback tick is
    // what keeps a window that cannot play from looking frozen.
    if (port != null) feed();
    return moved();
}

/// The song being played, by reference.
///
/// `player orelse ...` yields a copy, and taking its address gives a
/// pointer to that copy. Rendering through one advances a song that is
/// not the one playing.
fn playing() ?*play.Player {
    return if (player) |*one| one else null;
}

/// Whether the song has reached a row the window is not showing.
fn moved() bool {
    const current = playing() orelse return false;
    return current.row != shown_row or current.place != shown_place;
}

/// Hand the service as much as its ring will take.
///
/// The room is measured once and then worked through. Asking again each
/// time round would never come back: the service drains the ring while
/// this runs, so there would always be more room.
/// The longest this recently went without handing frames over, in
/// milliseconds.
///
/// The number a stutter turns on. The service wants a period every five
/// milliseconds or so; if the gaps are that long and it still runs dry
/// then it is what this program produces that is short, and if they are
/// hundreds of milliseconds then it is not being woken.
///
/// Over the last few seconds rather than the whole song: a mark that only
/// ever rises would still be showing the pause while the file was read
/// minutes later, and what somebody watching wants to know is how it is
/// doing now.
const GAP_WINDOW_MICROS: u64 = 5_000_000;
var widest_gap_ms: u32 = 0;
var widest_since: u64 = 0;
var fed_at: u64 = 0;

fn feed() void {
    const stream = if (port) |*one| one else return;
    const current = playing() orelse return;
    if (!running) return;

    const now = sys.clockMicros();
    if (now -| widest_since > GAP_WINDOW_MICROS) {
        widest_since = now;
        widest_gap_ms = 0;
    }
    if (fed_at != 0) {
        const gap: u32 = @intCast(@min((now - fed_at) / 1000, std.math.maxInt(u32)));
        if (gap > widest_gap_ms) widest_gap_ms = gap;
    }
    fed_at = now;

    const shape = @import("lib").audio.Shape{};
    const per_frame = shape.bytesPerFrame();
    var left = stream.view.frames.writable() / per_frame;

    while (left != 0) {
        const frames: usize = @min(left, BLOCK_FRAMES);
        const wanted = mixed[0 .. frames * shape.channels];
        current.render(wanted);

        const taken = stream.write(std.mem.sliceAsBytes(wanted)) / per_frame;
        if (taken < frames) break;
        left -= taken;
    }
}

// ---------------------------------------------------------------------------
// The window
//
// Four strips: the song, the pattern, a meter per channel, and where the
// song has got to. Only the pattern scrolls, and it is redrawn only when
// the row changes, which is eight times a second against the fifty the
// sound is fed at.
// ---------------------------------------------------------------------------

/// Characters in one cell: the note, the instrument, and what is asked of
/// the channel. Written out so the column width and the text that fills
/// it come from one number.
const CELL_TEXT = "C-2 05 vol";

/// The gap between the column rule and the text either side of it.
const COLUMN_PAD: i32 = 7;

/// How many rows of a page are drawn between two looks at the stream.
///
/// Small enough that the longest the ring waits is a few rows' drawing,
/// and large enough that a page turn is not mostly bookkeeping.
const ROWS_PER_FEED: i32 = 4;

fn draw() void {
    // Around the drawing, not only between passes. Painting a window is
    // the longest thing this program does, and on a slow machine it is
    // longer than the stream holds: fed on either side of it, the ring is
    // full going in and topped up coming out.
    feed();
    defer feed();

    const t = theme.current();
    const surface = ctx.surface;
    const area = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };
    if (ctx.damaged) surface.fill(area, t.surface);

    const current = playing() orelse return drawNothing(area);

    const strip = eui.theme.stripHeight();
    const head = Rect{ .x = area.x, .y = area.y, .w = area.w, .h = strip };
    const status = Rect{ .x = area.x, .y = area.bottom() - strip, .w = area.w, .h = strip };
    const meters = Rect{
        .x = area.x,
        .y = status.y - metersHeight(),
        .w = area.w,
        .h = metersHeight(),
    };

    // Each strip draws only when what it shows has changed, and names the
    // pixels it wrote. A song plays for minutes and the window is one
    // heading, one scrolling list and two readouts: repainting all of it
    // for a meter that moved is most of the work done for none of it.
    if (ctx.damaged) drawSong(head);
    drawPattern(.{ .x = area.x, .y = head.bottom(), .w = area.w, .h = meters.y - head.bottom() }, current);
    feed();
    drawMeters(meters, current);
    drawStatus(status, current);
}

/// The meter strip: a bar and the note under it, with air around both.
fn metersHeight() i32 {
    const t = theme.current();
    return t.padding + eui.meter.HEIGHT + 2 + eui.Surface.textHeight() + t.padding;
}

/// What to say when there is nothing to play.
fn drawNothing(area: Rect) void {
    if (!ctx.damaged) return;
    const t = theme.current();
    const surface = ctx.surface;
    ctx.addDamage(area);
    const line_height = eui.Surface.textHeight() + t.gap;

    var line: [224]u8 = undefined;
    var text = str.Builder{ .buf = &line };
    if (trouble.len != 0) {
        text.text(path());
        text.text(": ");
        text.text(trouble);
    } else {
        text.text("Nothing to play.");
    }

    const middle = Rect{ .x = area.x, .y = area.y + @divTrunc(area.h, 2) - line_height, .w = area.w, .h = line_height };
    surface.textCentred(middle, text.done(), t.text_dim);
    surface.textCentred(
        .{ .x = area.x, .y = middle.bottom(), .w = area.w, .h = line_height },
        "eeemod <file>.mod",
        t.text_dim,
    );
    surface.textCentred(
        .{ .x = area.x, .y = middle.bottom() + line_height, .w = area.w, .h = line_height },
        "or press O to look for one",
        t.text_dim,
    );
}

/// The song's name, dim, with a hairline under it.
fn drawSong(area: Rect) void {
    const t = theme.current();
    ctx.addDamage(area);
    var line: [96]u8 = undefined;
    var text = str.Builder{ .buf = &line };
    const title = song.name();
    text.text(if (title.len != 0) title else "untitled");
    text.text("  ");
    text.number(song.shape.channels);
    text.text(" channels, ");
    text.number(sounding());
    text.text(" instruments");

    eui.heading.paint(
        ctx.surface,
        .{ .x = area.x + t.padding, .y = area.y + t.padding, .w = area.w - t.padding * 2, .h = area.h },
        text.done(),
        eui.icon.of(.speaker),
    );
}

/// How many instruments the file actually carries. One that describes
/// thirty-one and ships eighteen has eighteen.
fn sounding() usize {
    var count: usize = 0;
    for (song.instruments[0..song.shape.instruments]) |one| {
        if (one.data.len != 0) count += 1;
    }
    return count;
}

/// The pattern, with the playing row in the middle.
///
/// One pass over the rows on show, building each cell straight into the
/// line it is drawn from: nothing is kept between passes because every
/// row moves when the song does, so there is nothing a pass could reuse.
/// Where the columns of the pattern fall.
///
/// Measured once a pass and carried down. Measuring a string means walking
/// it, and these are the same strings on every row of every channel: asked
/// for where they are used, a page turn would measure the same ten
/// characters two hundred times.
const Columns = struct {
    line_height: i32,
    numbers: i32,
    cell: i32,

    fn of() Columns {
        const t = theme.current();
        return .{
            .line_height = eui.Surface.textHeight() + 2,
            .numbers = eui.Surface.textWidth("00") + t.padding * 2,
            .cell = eui.Surface.textWidth(CELL_TEXT) + COLUMN_PAD * 2,
        };
    }
};

fn drawPattern(area: Rect, current: *const play.Player) void {
    const t = theme.current();
    const surface = ctx.surface;

    const columns = Columns.of();
    const line_height = columns.line_height;
    if (line_height <= 0 or area.h < line_height) return;
    const fits: i32 = @divTrunc(area.h, line_height);
    if (fits <= 0) return;

    // A page of rows, rather than a list that scrolls under the playing
    // row. Scrolling moves every line whenever the row changes, so the
    // whole of this would be redrawn eight times a second and copied to
    // the screen as often; the machine this runs on has better uses for
    // that. A page turns once every `fits` rows, and a row between turns
    // repaints the two lines whose highlight moved.
    const row: i32 = current.row;
    const page = @divTrunc(row, fits) * fits;
    const turned = ctx.damaged or page != shown_page or current.place != shown_place;
    if (!turned and row == shown_row) return;

    const pattern = current.pattern();
    const top = area.y + @divTrunc(area.h - fits * line_height, 2);

    if (turned) {
        surface.fill(area, t.surface);
        ctx.addDamage(area);
        drawRules(area, t, columns);

        var at: i32 = 0;
        while (at < fits) : (at += 1) {
            const which = page + at;
            if (which >= mod.ROWS) break;
            drawRow(area, top + at * line_height, columns, pattern, which, which == row);
            // Through the painting, not only around it. A page of rows is
            // the longest single thing this program does, and on a slow
            // machine it takes longer than the stream holds: fed only
            // before and after, the ring empties partway down the page.
            if (@rem(at, ROWS_PER_FEED) == ROWS_PER_FEED - 1) feed();
        }
    } else {
        // The line the highlight left, and the one it arrived on.
        for ([_]i32{ shown_row, row }) |which| {
            if (which < page or which >= page + fits or which >= mod.ROWS) continue;
            const y = top + (which - page) * line_height;
            const line = Rect{ .x = area.x, .y = y, .w = area.w, .h = line_height };
            surface.fill(line, t.surface);
            drawRules(line, t, columns);
            drawRow(area, y, columns, pattern, which, which == row);
            ctx.addDamage(line);
        }
    }

    shown_row = row;
    shown_page = page;
    shown_place = current.place;
}

/// The rules between the channels, down whatever is being redrawn.
fn drawRules(area: Rect, t: *const theme.Theme, columns: Columns) void {
    const channels: i32 = song.shape.channels;
    var rule = columns.numbers;
    var column: i32 = 0;
    while (column <= channels) : (column += 1) {
        const x = area.x + rule;
        if (x >= area.right()) break;
        ctx.surface.fill(.{ .x = x, .y = area.y, .w = 1, .h = area.h }, t.line);
        rule += columns.cell;
    }
}

/// One row: its number, then a cell per channel.
fn drawRow(area: Rect, y: i32, columns: Columns, pattern: u8, row: i32, playing_now: bool) void {
    const t = theme.current();
    const surface = ctx.surface;

    if (playing_now) {
        surface.fill(.{ .x = area.x, .y = y, .w = area.w, .h = columns.line_height }, t.accent);
    }

    // Every fourth row is a beat. Picking those out is what makes a
    // pattern readable at a glance.
    const ink = if (playing_now) t.accent_text else if (@rem(row, 4) == 0) t.text else t.text_dim;
    const baseline = y + 1;

    var text: [8]u8 = undefined;
    var digits = str.Builder{ .buf = &text };
    if (row < 10) digits.byte('0');
    digits.number(@intCast(row));
    surface.text(area.x + t.padding, baseline, digits.done(), ink);

    var at = area.x + columns.numbers + COLUMN_PAD;
    for (0..song.shape.channels) |channel| {
        if (at + columns.cell > area.right()) break;
        surface.text(at, baseline, spellCell(pattern, @intCast(row), channel), ink);
        at += columns.cell;
    }
}

/// One cell as its characters. The buffer is this function's own and is
/// handed straight to the drawing, so there is one of it rather than one
/// per cell on show.
var cell_text: [CELL_TEXT.len + 1]u8 = undefined;

fn spellCell(pattern: u8, row: u8, channel: usize) []const u8 {
    const note = song.note(pattern, row, channel);

    var line = str.Builder{ .buf = &cell_text };
    line.text(&play.spell(note.period orelse 0));
    line.byte(' ');
    if (note.instrument) |number| {
        if (number < 10) line.byte('0');
        line.number(number);
    } else {
        line.text("..");
    }
    line.byte(' ');
    line.text(asked(note.command));
    return line.done();
}

/// Three letters for what a cell asks. Its own three for each, so two
/// commands are never read as the same one.
fn asked(command: mod.Command) []const u8 {
    return switch (command) {
        .none => "...",
        .arpeggio => "arp",
        .slide_up => "up ",
        .slide_down => "dwn",
        .slide_to_note => "por",
        .slide_to_note_and_volume => "pov",
        .vibrato => "vib",
        .vibrato_and_volume => "viv",
        .tremolo => "trm",
        .set_panning => "pan",
        .sample_offset => "off",
        .volume_slide => "sld",
        .position_jump => "jmp",
        .set_volume => "vol",
        .pattern_break => "brk",
        .set_speed => "spd",
        .set_filter => "flt",
        .fine_slide_up => "fup",
        .fine_slide_down => "fdn",
        .set_glissando => "gls",
        .set_vibrato_waveform => "vwv",
        .set_finetune => "tun",
        .loop_pattern => "lop",
        .set_tremolo_waveform => "twv",
        .retrigger => "ret",
        .fine_volume_up => "fvu",
        .fine_volume_down => "fvd",
        .cut => "cut",
        .delay_note => "dly",
        .delay_pattern => "dpt",
        .invert_loop => "inv",
    };
}

/// A meter per channel, and what each is playing under it.
fn drawMeters(area: Rect, current: *const play.Player) void {
    // The levels this pass, and whether any of them moved. A meter that
    // reads the same as it did is a meter with nothing to draw.
    var levels: [mod.MAX_CHANNELS]u8 = @splat(0);
    var moved_any = ctx.damaged;
    for (0..song.shape.channels) |channel| {
        const level = current.meter(channel);
        // The format counts volume to sixty-four; a meter counts to a
        // hundred.
        levels[channel] = @intCast(@divTrunc(@as(u16, level.volume) * 100, 64));
        const fell = @import("lib").audio.falling(peaks[channel], levels[channel], PEAK_FALL);
        if (levels[channel] != shown_levels[channel] or fell != peaks[channel]) moved_any = true;
        peaks[channel] = fell;
        shown_levels[channel] = levels[channel];
    }
    if (!moved_any) return;

    const t = theme.current();
    const surface = ctx.surface;
    surface.fill(area, t.surface);
    ctx.addDamage(area);
    surface.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, t.line);

    const channels: i32 = song.shape.channels;
    if (channels == 0) return;
    const each = @divTrunc(area.w - t.padding * 2, channels);

    for (0..song.shape.channels) |channel| {
        const level = current.meter(channel);
        const loud = levels[channel];

        const bar = Rect{
            .x = area.x + t.padding + @as(i32, @intCast(channel)) * each,
            .y = area.y + t.padding,
            .w = each - t.padding,
            .h = eui.meter.HEIGHT,
        };
        surface.fill(bar, t.surface_pressed);
        // No warning colour and no limit mark. Sixty-four is a channel's
        // own full volume, which songs use constantly. What is worth
        // marking is the loudest it has just been.
        surface.fill(eui.meter.fill(bar, loud), t.accent);
        if (peaks[channel] > 0) surface.fill(eui.meter.peak(bar, peaks[channel]), t.text_dim);

        var text: [16]u8 = undefined;
        var line = str.Builder{ .buf = &text };
        line.text(&play.spell(level.period));
        if (level.instrument != 0) {
            line.byte(' ');
            if (level.instrument < 10) line.byte('0');
            line.number(level.instrument);
        }
        surface.text(bar.x, bar.bottom() + 2, line.done(), t.text_dim);
    }
}

/// How far a peak mark falls per pass, so it marks the last moment rather
/// than the loudest since the song started.
const PEAK_FALL: u8 = 6;
var peaks: [mod.MAX_CHANNELS]u8 = @splat(0);
/// The levels last drawn, so a pass that would draw the same is skipped.
var shown_levels: [mod.MAX_CHANNELS]u8 = @splat(0);

/// How often the sound service found the ring short of a period, or none
/// when there is no stream to have run dry.
fn starvedCount() ?u32 {
    const stream = if (port) |*one| one else return null;
    return stream.view.ctrl.starved;
}

/// Where the song has got to, along the bottom in the bar's colours.
fn drawStatus(area: Rect, current: *const play.Player) void {
    var place: [24]u8 = undefined;
    var pattern: [20]u8 = undefined;
    var pace: [28]u8 = undefined;

    var one = str.Builder{ .buf = &place };
    one.text("position ");
    one.number(current.place);
    one.byte('/');
    one.number(song.length);

    var two = str.Builder{ .buf = &pattern };
    two.text("pattern ");
    two.number(current.pattern());
    two.text(", row ");
    two.number(current.row);

    var three = str.Builder{ .buf = &pace };
    three.number(current.speed);
    three.text(" ticks, ");
    three.number(current.tempo);
    three.text(" bpm");

    var state: [80]u8 = undefined;
    var says = str.Builder{ .buf = &state };
    says.text(if (silent) "no sound service" else if (running) "playing" else "paused");
    // The service counts the times it went to the ring and found less than
    // a period in it. A stutter asks whether this program is keeping up,
    // and that is the number that answers.
    if (starvedCount()) |dry| {
        if (dry != 0) {
            says.text(", ");
            says.number(dry);
            says.text(" ran dry");
        }
    }
    if (widest_gap_ms != 0) {
        says.text(", fed every ");
        says.number(widest_gap_ms);
        says.text("ms at worst");
    }

    eui.statusbar.run(ctx, area, &.{
        .{ .text = says.done() },
        .{ .text = one.done(), .width = eui.Surface.textWidth("position 00/000") },
        .{ .text = two.done(), .width = eui.Surface.textWidth("pattern 000, row 00") },
        .{ .text = three.done(), .width = eui.Surface.textWidth("00 ticks, 000 bpm"), .right = true },
    });
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

fn key(code: KeyCode, mods: Modifiers) bool {
    _ = mods;
    // Opening one is the only thing worth doing with no module in hand.
    if (code == .o) {
        ask();
        return true;
    }
    const current = playing() orelse return false;

    switch (code) {
        // Stop and start. A stopped song keeps its place.
        .space => {
            running = !running;
            ctx.damage();
        },
        // Along the order, a place at a time.
        .left => {
            current.place -|= 1;
            current.row = 0;
            current.tick = 0;
            ctx.damage();
        },
        .right => {
            if (current.place + 1 < song.length) current.place += 1;
            current.row = 0;
            current.tick = 0;
            ctx.damage();
        },
        .home => {
            current.reset();
            ctx.damage();
        },
        else => return false,
    }
    return true;
}
