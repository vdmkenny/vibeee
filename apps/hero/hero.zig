//! Hero: a character journal.
//!
//! Opens a `.hero` file, shows the character its lines add up to, and answers
//! the moments of play by writing the line that records each: a roll, a hit
//! taken, a rest, a spell cast, gold paid, a note. The reading and the writing
//! of the file are `ulib`'s `hero`, which is pure and tested on the host; this
//! is the window over it. Nothing of the game is in the toolkit, and the only
//! pictures of its own are the few stat glyphs below, drawn here because a
//! shield and a heart are this program's business and no one else's.
//!
//! Every helper appends one line and folds the file again, so what is on the
//! screen is always the file read back rather than a second copy of the truth
//! kept beside it. Save writes the file whole under a new name, renames it
//! over the old and flushes, the way every document on this machine that
//! matters is written.

const std = @import("std");
const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const img = @import("img");
const env = @import("ulib").env;
const str = @import("lib").str;
const hero = @import("journal.zig");

const theme = eui.theme;
const Rect = eui.Rect;
const Surface = eui.Surface;

const ctx = &proto.app.ctx;
const connection = &proto.app.connection;

// The picture decoder is C and calls the freestanding libc by name; importing
// it emits those symbols into this binary. One implementation, not two.
comptime {
    _ = @import("clibc");
}

/// The whole file, held at once. Years of play at a line a moment fit in this,
/// and it is what Save writes and what every fold reads.
const CAPACITY = 64 * 1024;
var storage: [CAPACITY]u8 = undefined;
var text_len: usize = 0;

/// The character the file folds to, rebuilt whenever the file changes.
var sheet: hero.Sheet = .{};

var file_path: [128]u8 = @splat(0);
var file_len: usize = 0;
var modified = false;
var status: []const u8 = "";
var status_buffer: [96]u8 = @splat(0);

const Section = enum { sheet, skills, combat, spells, gear, journal };
var section: Section = .sheet;

/// Set when the Journal has just been opened, so its note field takes the
/// keyboard without a click: on this section, typing is a note or nothing.
var focus_note = false;

fn stepSection(by: i32) void {
    const count = @typeInfo(Section).@"enum".fields.len;
    const now: i32 = @intCast(@intFromEnum(section));
    const next: usize = @intCast(@mod(now + by, count));
    setSection(@enumFromInt(next));
}

fn setSection(which: Section) void {
    if (which == section) return;
    section = which;
    focus_note = which == .journal;
    ctx.damage();
}

var skills_table: eui.table.State = .{};
var attacks_table: eui.table.State = .{};
var spells_table: eui.table.State = .{};
var items_table: eui.table.State = .{};
var journal_scroll: eui.scrollpane.State = .{};

var menus: eui.menubar.State = .{};

/// The character's headshot, decoded once from the picture the file names.
var headshot: ?img.Picture = null;
var headshot_of: [128]u8 = @splat(0);
var headshot_of_len: usize = 0;
/// Where a headshot file is read before it is decoded, held here rather than
/// on the stack, which a picture would overflow.
var headshot_file: [96 * 1024]u8 = undefined;

/// The dice, seeded from the clock the first time something is rolled.
var dice: std.Random.DefaultPrng = undefined;
var dice_seeded = false;

// ---------------------------------------------------------------------------
// The helpers: a question on the prompt sheet, and the line its answer writes
// ---------------------------------------------------------------------------

var prompt: eui.prompt.Prompt = .{};
var question_buffer: [96]u8 = @splat(0);

/// What the sheet is asking, so its answer knows which line to write. Some
/// carry the subject the question is about: which skill is rolled, which
/// spell is cast.
const Helper = union(enum) {
    none,
    close,
    roll: RollWhat,
    damage,
    heal,
    temp,
    hitdie,
    gold_pay,
    gold_get,
    rest,
    cast: usize,
};

const RollWhat = union(enum) {
    skill: hero.Skill,
    save: hero.Ability,
    attack: usize,
};

var pending: Helper = .none;

const Command = enum(u16) {
    open,
    save,
    save_as,
    close,
    new_session,
    long_rest,
    short_rest,
    inspiration,
    add_note,
};

const MENUS = [_]eui.menubar.Menu{
    .{ .label = "File", .items = &.{
        .{ .label = "Open...", .id = @intFromEnum(Command.open), .shortcut = "Ctrl+O" },
        .{ .label = "Save", .id = @intFromEnum(Command.save), .shortcut = "Ctrl+S" },
        .{ .label = "Save as...", .id = @intFromEnum(Command.save_as), .shortcut = "Ctrl+Shift+S" },
        eui.menubar.Item.separator,
        .{ .label = "Close", .id = @intFromEnum(Command.close), .shortcut = "Ctrl+Q" },
    } },
    .{ .label = "Play", .items = &.{
        .{ .label = "New session", .id = @intFromEnum(Command.new_session) },
        eui.menubar.Item.separator,
        .{ .label = "Long rest", .id = @intFromEnum(Command.long_rest) },
        .{ .label = "Short rest", .id = @intFromEnum(Command.short_rest) },
        .{ .label = "Heroic Inspiration", .id = @intFromEnum(Command.inspiration) },
        eui.menubar.Item.separator,
        .{ .label = "Note...", .id = @intFromEnum(Command.add_note) },
    } },
};

// The open and save dialog, borrowed by both.
var dialog: proto.FileDialog = .{};
var asking_file: proto.dialog.Purpose = .open;

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    if (env.argument(frame)) |wanted| {
        setPath(wanted);
        load();
    }

    proto.app.run("hero", "Hero", 520, 380, .{
        .draw = draw,
        .key = key,
        .text = typed,
        .event = ownDialog,
        .close = mayClose,
    });
}

fn path() []const u8 {
    return file_path[0..file_len];
}

fn setPath(value: []const u8) void {
    const n = @min(value.len, file_path.len);
    @memcpy(file_path[0..n], value[0..n]);
    file_len = n;
}

fn baseName() []const u8 {
    const full = path();
    var i = full.len;
    while (i > 0) : (i -= 1) {
        if (full[i - 1] == '/') return full[i..];
    }
    return full;
}

// ---------------------------------------------------------------------------
// File
// ---------------------------------------------------------------------------

fn load() void {
    const handle = sys.open(path(), .{});
    if (handle < 0) {
        say("No such character.");
        return;
    }
    defer _ = sys.close(@intCast(handle));

    text_len = 0;
    while (text_len < storage.len) {
        const n = sys.read(@intCast(handle), storage[text_len..]);
        if (n <= 0) break;
        text_len += @intCast(n);
    }

    refold();
    modified = false;
    setTitle();
    loadHeadshot();
}

/// Write the file whole under a new name, rename it over the old, and flush,
/// so a character is the file before the change or the file after it and never
/// half of each.
fn save() void {
    if (path().len == 0) {
        askFile(.save);
        return;
    }

    var temp_buf: [160]u8 = @splat(0);
    const temp = std.fmt.bufPrint(&temp_buf, "{s}.new", .{path()}) catch {
        say("That name is too long to save.");
        return;
    };

    const handle = sys.open(temp, .{ .write = true, .create = true, .truncate = true });
    if (handle < 0) {
        say("Cannot write there.");
        return;
    }
    const wrote = sys.write(@intCast(handle), storage[0..text_len]);
    _ = sys.close(@intCast(handle));
    if (wrote < 0 or @as(usize, @intCast(wrote)) != text_len) {
        say("Only part of it was written.");
        return;
    }

    if (sys.rename(temp, path()) < 0) {
        say("Cannot replace the old file.");
        return;
    }
    _ = sys.sync();

    modified = false;
    say("Saved.");
    setTitle();
}

fn refold() void {
    sheet = hero.fold(storage[0..text_len]);
}

/// Add one journal line and read the file back. The screen is the fold, so
/// nothing shows until the line is in the file.
fn append(line: []const u8) void {
    if (line.len == 0) return;
    // A newline before it, unless the file is empty or already ends in one.
    if (text_len > 0 and storage[text_len - 1] != '\n') {
        if (text_len >= storage.len) return;
        storage[text_len] = '\n';
        text_len += 1;
    }
    const room = storage.len - text_len;
    if (line.len > room) {
        say("The journal is full.");
        return;
    }
    @memcpy(storage[text_len..][0..line.len], line);
    text_len += line.len;

    refold();
    modified = true;
    setTitle();
    ctx.damage();
}

fn loadHeadshot() void {
    const picture = sheet.picture;
    if (picture.len == 0) {
        forgetHeadshot();
        return;
    }
    // Beside the character file, so a journal and its portrait travel together.
    var full_buf: [192]u8 = @splat(0);
    const full = resolve(picture, &full_buf);
    if (std.mem.eql(u8, full, headshot_of[0..headshot_of_len])) return;

    forgetHeadshot();
    const handle = sys.open(full, .{});
    if (handle < 0) return;
    defer _ = sys.close(@intCast(handle));

    var read: usize = 0;
    while (read < headshot_file.len) {
        const n = sys.read(@intCast(handle), headshot_file[read..]);
        if (n <= 0) break;
        read += @intCast(n);
    }
    headshot = img.decode(headshot_file[0..read]) catch null;
    if (headshot != null) {
        headshot_of_len = @min(full.len, headshot_of.len);
        @memcpy(headshot_of[0..headshot_of_len], full[0..headshot_of_len]);
    }
}

fn forgetHeadshot() void {
    if (headshot) |held| held.deinit();
    headshot = null;
    headshot_of_len = 0;
}

/// A picture path against the character file's own directory.
fn resolve(picture: []const u8, buf: []u8) []const u8 {
    if (picture.len > 0 and picture[0] == '/') {
        const n = @min(picture.len, buf.len);
        @memcpy(buf[0..n], picture[0..n]);
        return buf[0..n];
    }
    const full = path();
    var cut: usize = 0;
    var i = full.len;
    while (i > 0) : (i -= 1) {
        if (full[i - 1] == '/') {
            cut = i;
            break;
        }
    }
    return std.fmt.bufPrint(buf, "{s}{s}", .{ full[0..cut], picture }) catch picture;
}

// ---------------------------------------------------------------------------
// Keys and the close question
// ---------------------------------------------------------------------------

fn key(code: proto.app.KeyCode, mods: proto.app.Modifiers) bool {
    if (prompt.isOpen()) {
        if (eui.prompt.key(&prompt, code)) |choice| answer(choice);
        return true;
    }
    // The sections are walked from the keyboard, so a machine with no pointer
    // and a machine with one reach the same six panes.
    if (mods.control and code == .tab) {
        stepSection(if (mods.shift) -1 else 1);
        return true;
    }
    return switch (eui.menubar.key(&menus, code, mods, &MENUS)) {
        .ignored => false,
        .taken => true,
        .chosen => |id| blk: {
            run(@enumFromInt(id));
            break :blk true;
        },
    };
}

fn typed(codepoint: u32) bool {
    if (!prompt.isOpen()) return false;
    if (eui.prompt.letter(&prompt, codepoint)) |choice| answer(choice);
    return true;
}

fn ownDialog(event: proto.wm.Ev) bool {
    if (!dialog.owns(event)) return false;
    if (dialog.handle(connection, event)) finishFile();
    return true;
}

fn mayClose() bool {
    if (!modified) return true;
    var line = str.Builder{ .buf = &question_buffer };
    line.text("Save the changes to ");
    line.text(if (file_len > 0) baseName() else "this character");
    line.text("?");
    ask(.close, line.done(), &CLOSE_CHOICES, null);
    return false;
}

const CLOSE_CHOICES = [_]eui.prompt.Choice{
    .{ .label = "Save", .letter = 's', .weight = .strong },
    .{ .label = "Discard", .letter = 'd' },
    .{ .label = "Cancel" },
};

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn run(command: Command) void {
    switch (command) {
        .open => askFile(.open),
        .save => save(),
        .save_as => askFile(.save),
        .close => if (mayClose()) sys.exit(0),
        .new_session => newSession(),
        .long_rest => askRest(),
        .short_rest => append(hero.writeRest(&line_buffer, false)),
        .inspiration => append(hero.writeInspiration(&line_buffer, !sheet.inspiration)),
        .add_note => say("Type a note in the Journal."),
    }
}

var line_buffer: [256]u8 = @splat(0);

fn newSession() void {
    const number = sessionCount() + 1;
    var date_buf: [16]u8 = @splat(0);
    const date = today(&date_buf);
    append(hero.writeSession(&line_buffer, number, date));
}

/// How many session headings the file already has, so the next is one more.
fn sessionCount() u32 {
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, storage[0..text_len], '\n');
    while (lines.next()) |raw| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, raw, " \t\r"), "session ")) count += 1;
    }
    return count;
}

fn today(buf: []u8) []const u8 {
    const micros = sys.realtimeMicros() orelse return "";
    const civil = @import("lib").civil.fromEpoch(@divFloor(micros, 1_000_000));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(civil.year)), civil.month, civil.day,
    }) catch "";
}

// ---------------------------------------------------------------------------
// The prompt sheet
// ---------------------------------------------------------------------------

fn ask(helper: Helper, question: []const u8, choices: []const eui.prompt.Choice, amount: ?eui.prompt.Amount) void {
    pending = helper;
    if (amount) |a| {
        prompt.askFor(question, choices, a);
    } else {
        prompt.ask(question, choices);
    }
    ctx.damage();
}

const AMOUNT_CHOICES = [_]eui.prompt.Choice{
    .{ .label = "OK", .letter = 'o', .weight = .strong },
    .{ .label = "Cancel" },
};

const ROLL_CHOICES = [_]eui.prompt.Choice{
    .{ .label = "Advantage", .letter = 'a' },
    .{ .label = "Normal", .weight = .strong },
    .{ .label = "Disadvantage", .letter = 'd' },
};

fn amountOf(value: i32, low: i32, high: i32) eui.prompt.Amount {
    return .{ .value = value, .range = .{ .min = low, .max = high } };
}

fn askAmount(helper: Helper, question: []const u8, start: i32, high: i32) void {
    ask(helper, question, &AMOUNT_CHOICES, amountOf(start, 1, high));
}

fn askRest() void {
    ask(.rest, "Which rest?", &REST_CHOICES, null);
}

const REST_CHOICES = [_]eui.prompt.Choice{
    .{ .label = "Long", .letter = 'l', .weight = .strong },
    .{ .label = "Short", .letter = 's' },
    .{ .label = "Cancel" },
};

/// The answer to whatever stood on the sheet.
fn answer(choice: usize) void {
    const helper = pending;
    const number = prompt.number();
    prompt.dismiss();
    pending = .none;
    ctx.damage();

    switch (helper) {
        .none => {},
        .close => switch (@as(enum { save, discard, cancel }, @enumFromInt(choice))) {
            .save => {
                save();
                if (!modified) sys.exit(0);
            },
            .discard => sys.exit(0),
            .cancel => {},
        },
        .roll => |what| {
            if (choice < ROLL_CHOICES.len) doRoll(what, @enumFromInt(choice));
        },
        .damage => if (choice == 0) append(hero.writeDamage(&line_buffer, @intCast(number), "")),
        .heal => if (choice == 0) append(hero.writeHeal(&line_buffer, @intCast(number), "")),
        .temp => if (choice == 0) append(hero.writeTemp(&line_buffer, @intCast(number))),
        .hitdie => if (choice == 0) append(hero.writeHitDie(&line_buffer, @intCast(number))),
        .gold_pay => if (choice == 0) append(hero.writeGold(&line_buffer, -number, "")),
        .gold_get => if (choice == 0) append(hero.writeGold(&line_buffer, number, "")),
        .cast => |level| if (choice == 0) castSpell(level),
        .rest => switch (@as(enum { long, short, cancel }, @enumFromInt(choice))) {
            .long => append(hero.writeRest(&line_buffer, true)),
            .short => append(hero.writeRest(&line_buffer, false)),
            .cancel => {},
        },
    }
}

fn castSpell(index: usize) void {
    if (index >= sheet.spells.len) return;
    const spell = sheet.spells.slice()[index];
    append(hero.writeCast(&line_buffer, spell.level, spell.name));
}

/// Roll a d20, keeping the higher of two for advantage and the lower for
/// disadvantage, apply the modifier and the exhaustion penalty, and write the
/// die kept so the total on the status line can be checked against the file.
fn doRoll(what: RollWhat, how: hero.Roll) void {
    if (!dice_seeded) {
        const seed: u64 = @bitCast(sys.realtimeMicros() orelse @as(i64, @intCast(sys.clockMicros())));
        dice = std.Random.DefaultPrng.init(seed);
        dice_seeded = true;
    }
    const rng = dice.random();
    const a = rng.intRangeAtMost(u8, 1, 20);
    const b = rng.intRangeAtMost(u8, 1, 20);
    const kept: u8 = switch (how) {
        .normal => a,
        .advantage => @max(a, b),
        .disadvantage => @min(a, b),
    };

    const modifier: i16 = switch (what) {
        .skill => |s| sheet.skillBonus(s) + sheet.exhaustionPenalty(),
        .save => |ab| sheet.saveBonus(ab) + sheet.exhaustionPenalty(),
        .attack => |i| attackBonus(i) + sheet.exhaustionPenalty(),
    };
    const label = switch (what) {
        .skill => |s| s.word(),
        .save => |ab| ab.word(),
        .attack => |i| if (i < sheet.attacks.len) sheet.attacks.slice()[i].name else "Attack",
    };

    append(hero.writeRoll(&line_buffer, label, kept, modifier, how));

    var line = str.Builder{ .buf = &status_buffer };
    line.text(label);
    line.text(": ");
    line.number(@intCast(@as(i32, kept) + modifier));
    line.text(" (");
    line.number(kept);
    signed(&line, modifier);
    line.text(")");
    status = line.done();
}

fn attackBonus(index: usize) i16 {
    if (index >= sheet.attacks.len) return 0;
    const hit = sheet.attacks.slice()[index].hit;
    const digits = if (hit.len > 0 and (hit[0] == '+' or hit[0] == '-')) hit[1..] else hit;
    const value = std.fmt.parseInt(i16, digits, 10) catch 0;
    return if (hit.len > 0 and hit[0] == '-') -value else value;
}

fn signed(line: *str.Builder, value: i16) void {
    line.text(if (value < 0) " - " else " + ");
    line.number(@abs(value));
}

// ---------------------------------------------------------------------------
// Dialog and title
// ---------------------------------------------------------------------------

fn askFile(purpose: proto.dialog.Purpose) void {
    asking_file = purpose;
    dialog.show(connection, purpose, baseName()) catch {
        say("Cannot open the dialog.");
    };
}

fn finishFile() void {
    switch (dialog.result) {
        .pending => return,
        .cancelled => {},
        .chosen => {
            setPath(dialog.chosen());
            switch (asking_file) {
                .open => load(),
                .save => save(),
            }
        },
    }
    dialog.hide(connection);
    ctx.damage();
}

var title_buffer: [96]u8 = @splat(0);

fn setTitle() void {
    var line = str.Builder{ .buf = &title_buffer };
    if (sheet.name.len > 0) line.text(sheet.name) else line.text("Hero");
    if (modified) line.text(" *");
    connection.setTitle(proto.app.window, line.done()) catch {};
}

fn say(text: []const u8) void {
    status = text;
    ctx.damage();
}

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

const SECTIONS = [_]Section{ .sheet, .skills, .combat, .spells, .gear, .journal };

fn sectionWord(which: Section) []const u8 {
    return switch (which) {
        .sheet => "Sheet",
        .skills => "Skills",
        .combat => "Combat",
        .spells => "Spells",
        .gear => "Gear",
        .journal => "Journal",
    };
}

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const area = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };

    const parts = eui.chrome.split(area, .{ .top = true, .bottom = true });
    const strip = parts.top;
    const body = parts.body;

    // The rail: a headshot square, then the sections under it.
    const rail_w = eui.rail.width();
    const head_h: i32 = 84;
    const head_area = Rect{ .x = body.x, .y = body.y, .w = rail_w, .h = @min(head_h, body.h) };
    drawHeadshot(surface, head_area);
    const rows_area = Rect{ .x = body.x, .y = head_area.bottom(), .w = rail_w, .h = body.h - head_area.h };

    var items: [SECTIONS.len]eui.rail.Item = undefined;
    for (SECTIONS, 0..) |which, i| items[i] = .{ .label = sectionWord(which) };
    const chosen = ctx.rail(rows_area, &items, @intFromEnum(section), caption());
    if (chosen != @intFromEnum(section)) setSection(@enumFromInt(chosen));

    // The pane, and the helper sheet across its foot when one is asking.
    const pane_full = Rect{
        .x = body.x + rail_w,
        .y = body.y,
        .w = body.w - rail_w,
        .h = body.h,
    };
    const pane = inset(if (prompt.isOpen()) eui.prompt.above(pane_full) else pane_full, t.menu_padding);

    switch (section) {
        .sheet => drawSheet(pane),
        .skills => drawSkills(pane),
        .combat => drawCombat(pane),
        .spells => drawSpells(pane),
        .gear => drawGear(pane),
        .journal => drawJournal(pane),
    }

    if (eui.prompt.run(ctx, pane_full, &prompt)) |choice| answer(choice);

    // The status bar: the character and the session, and whatever was just said.
    eui.statusbar.run(ctx, parts.bottom, &.{
        .{ .text = if (status.len > 0) status else subtitle() },
        .{ .text = sessionText(), .width = 108, .right = true },
        .{ .text = if (modified) "Unsaved" else "Saved", .width = 72, .right = true },
    });

    // Last, so an open menu reaches over the pane rather than under it.
    if (eui.menubar.run(ctx, strip, &menus, &MENUS)) |id| run(@enumFromInt(id));
}

fn inset(area: Rect, by: i32) Rect {
    return .{ .x = area.x + by, .y = area.y + by, .w = area.w - by * 2, .h = area.h - by * 2 };
}

fn caption() []const u8 {
    return if (file_len > 0) baseName() else "no file";
}

var subtitle_buffer: [96]u8 = @splat(0);

fn subtitle() []const u8 {
    var line = str.Builder{ .buf = &subtitle_buffer };
    line.text(if (sheet.name.len > 0) sheet.name else "Hero");
    if (sheet.class.len > 0) {
        line.text(" · ");
        line.text(sheet.class);
        line.byte(' ');
        line.number(sheet.level);
    }
    return line.done();
}

var session_buffer: [16]u8 = @splat(0);

fn sessionText() []const u8 {
    if (sheet.session.len == 0) return "";
    var line = str.Builder{ .buf = &session_buffer };
    line.text("Session ");
    line.text(sheet.session);
    return line.done();
}

// ---------------------------------------------------------------------------
// The headshot
// ---------------------------------------------------------------------------

fn drawHeadshot(surface: Surface, area: Rect) void {
    if (!ctx.damaged) return;
    const t = theme.current();
    surface.fill(area, t.surface_pressed);
    surface.fill(.{ .x = area.right(), .y = area.y, .w = 1, .h = area.h }, t.line);

    const side: i32 = 64;
    const box = Rect{
        .x = area.x + @divTrunc(area.w - side, 2),
        .y = area.y + @divTrunc(area.h - side, 2),
        .w = side,
        .h = side,
    };
    surface.fill(box, t.surface_hot);
    surface.frame(box, t.line);

    if (headshot) |held| {
        eui.thumb.paint(surface, box.inset(1), .{
            .pixels = held.pixels,
            .width = held.width,
            .height = held.height,
        }, .up);
    } else {
        // A silhouette until there is a picture: a head and shoulders.
        const cx = box.x + @divTrunc(side, 2);
        surface.fill(.{ .x = cx - 9, .y = box.y + 14, .w = 18, .h = 18 }, t.line);
        surface.fill(.{ .x = cx - 16, .y = box.y + 40, .w = 32, .h = 20 }, t.line);
    }
}

// ---------------------------------------------------------------------------
// Hero's own glyphs: the game's things, drawn here because a shield and a
// heart are this program's business and belong nowhere in the toolkit. One-bit
// pictures the way `eui.icon` writes its own, blitted a set pixel at a time.
// ---------------------------------------------------------------------------

const Glyph = [12][12]u8;

fn plot(comptime rows: [12]*const [12:0]u8) Glyph {
    var g: Glyph = undefined;
    for (rows, 0..) |row, y| {
        for (0..12) |x| g[y][x] = if (row[x] == '#') 1 else 0;
    }
    return g;
}

const shield = plot(.{
    "   ######   ",
    "  #      #  ",
    " #        # ",
    " #        # ",
    " #        # ",
    "  #      #  ",
    "  #      #  ",
    "   #    #   ",
    "    #  #    ",
    "     ##     ",
    "            ",
    "            ",
});

const heart = plot(.{
    "            ",
    "  ##   ##   ",
    " #### ####  ",
    " ########## ",
    " ########## ",
    "  ########  ",
    "   ######   ",
    "    ####    ",
    "     ##     ",
    "            ",
    "            ",
    "            ",
});

const bolt = plot(.{
    "      ###   ",
    "     ###    ",
    "    ###     ",
    "   ######   ",
    "  #######   ",
    "     ###    ",
    "    ###     ",
    "   ###      ",
    "  ###       ",
    "            ",
    "            ",
    "            ",
});

const coin = plot(.{
    "    ####    ",
    "  ##    ##  ",
    " #        # ",
    " #   ##   # ",
    " #  #  #  # ",
    " #  #  #  # ",
    " #   ##   # ",
    " #        # ",
    "  ##    ##  ",
    "    ####    ",
    "            ",
    "            ",
});

const die = plot(.{
    " ########## ",
    " #        # ",
    " # #      # ",
    " #        # ",
    " #   #    # ",
    " #        # ",
    " #      # # ",
    " #        # ",
    " ########## ",
    "            ",
    "            ",
    "            ",
});

const spark = plot(.{
    "     ##     ",
    "     ##     ",
    "  #  ##  #  ",
    "   #### #   ",
    " ###### ### ",
    "  ########  ",
    "   ##### #  ",
    "  #  ##  ## ",
    "     ##     ",
    "     ##     ",
    "            ",
    "            ",
});

fn glyph(surface: Surface, x: i32, y: i32, g: Glyph, colour: u32) void {
    for (g, 0..) |row, dy| {
        for (row, 0..) |on, dx| {
            if (on == 1) surface.fill(.{ .x = x + @as(i32, @intCast(dx)), .y = y + @as(i32, @intCast(dy)), .w = 1, .h = 1 }, colour);
        }
    }
}

// ---------------------------------------------------------------------------
// The Sheet pane
// ---------------------------------------------------------------------------

fn drawSheet(area: Rect) void {
    const surface = ctx.surface;
    const t = theme.current();
    if (ctx.damaged) surface.fill(area, t.surface);

    // The six ability tiles across the top.
    const gap = t.gap;
    const tile_w = @divTrunc(area.w - gap * 5, 6);
    const tile_h: i32 = 58;
    for (std.enums.values(hero.Ability), 0..) |ability, i| {
        const x = area.x + @as(i32, @intCast(i)) * (tile_w + gap);
        drawAbility(surface, .{ .x = x, .y = area.y, .w = tile_w, .h = tile_h }, ability);
    }

    // Two columns under them: what is derived, and what is trained.
    const top = area.y + tile_h + gap;
    const col_w = @divTrunc(area.w - gap, 2);
    const left = Rect{ .x = area.x, .y = top, .w = col_w, .h = area.bottom() - top };
    const right = Rect{ .x = area.x + col_w + gap, .y = top, .w = col_w, .h = area.bottom() - top };

    var senses: [6]eui.facts.Fact = undefined;
    var b: [6][24]u8 = @splat(@splat(0));
    senses[0] = .{ .label = "Proficiency", .value = plusInt(&b[0], sheet.proficiency()) };
    senses[1] = .{ .label = "Perception", .value = intText(&b[1], sheet.passive(.perception)) };
    senses[2] = .{ .label = "Insight", .value = intText(&b[2], sheet.passive(.insight)) };
    senses[3] = .{ .label = "Speed", .value = feet(&b[3], sheet.speed) };
    senses[4] = .{ .label = "Advancement", .value = if (sheet.advancement == .milestone) "Milestone" else "Experience" };
    senses[5] = .{ .label = "Bloodied", .value = if (sheet.bloodied()) "yes" else "no" };
    _ = eui.facts.all(ctx, left, left.y, &senses);

    var training: [4]eui.facts.Fact = undefined;
    training[0] = .{ .label = "Weapons", .value = orDash(sheet.weapons) };
    training[1] = .{ .label = "Tools", .value = orDash(sheet.tools) };
    training[2] = .{ .label = "Languages", .value = orDash(sheet.languages) };
    training[3] = .{ .label = "Saves", .value = savesText() };
    var y = eui.facts.all(ctx, right, right.y, &training);

    // Inspiration, a single pip that is held or spent.
    y += t.gap;
    ctx.label(.{ .x = right.x, .y = y, .w = 132, .h = t.control_height }, "Heroic Inspiration");
    const pip = ctx.pips(.{ .x = right.x + 132, .y = y, .w = eui.pips.width(1), .h = t.control_height }, 1, if (sheet.inspiration) 1 else 0);
    if (pip != @intFromBool(sheet.inspiration)) append(hero.writeInspiration(&line_buffer, pip == 1));
}

fn drawAbility(surface: Surface, box: Rect, ability: hero.Ability) void {
    const t = theme.current();
    const i = @intFromEnum(ability);
    surface.fill(box, t.surface_hot);
    surface.frame(box, t.line);

    surface.text(box.x + 6, box.y + 4, ability.word()[0..3], t.text_dim);

    var num: [4]u8 = @splat(0);
    surface.textLarge(box.x + 6, box.y + 16, str.number(&num, sheet.scores[i], 10, .lower), t.text, 2);

    var mod: [6]u8 = @splat(0);
    surface.text(box.x + box.w - 26, box.y + 20, plusInt(&mod, sheet.modifier(ability)), t.text);

    // The save under it, with a pip when it is proficient.
    var sv: [6]u8 = @splat(0);
    surface.text(box.x + 6, box.y + box.h - 16, "sv", t.text_dim);
    surface.text(box.x + 24, box.y + box.h - 16, plusInt(&sv, sheet.saveBonus(ability)), t.text);
    if (sheet.save_prof[i]) {
        surface.fill(.{ .x = box.x + box.w - 14, .y = box.y + box.h - 15, .w = 8, .h = 8 }, t.accent);
    }
}

// ---------------------------------------------------------------------------
// The Skills pane
// ---------------------------------------------------------------------------

const SKILL_COLUMNS = [_]eui.table.Column{
    .{ .title = "Skill", .width = 150, .flex = true },
    .{ .title = "Ability", .width = 64 },
    .{ .title = "Prof", .width = 52 },
    .{ .title = "Bonus", .width = 56, .right = true },
};

var skill_cells: [18][3][8]u8 = @splat(@splat(@splat(0)));
var skill_rows: [18]eui.table.Row = undefined;

fn drawSkills(area: Rect) void {
    for (std.enums.values(hero.Skill), 0..) |s, i| {
        const bonus = str.Builder{ .buf = &skill_cells[i][0] };
        _ = bonus;
        var row = eui.table.Row{};
        row.cells[0] = s.word();
        row.cells[1] = upper3(&skill_cells[i][1], s.ability().word());
        row.cells[2] = if (sheet.skill_expert[i]) "expert" else if (sheet.skill_prof[i]) "yes" else "";
        row.cells[3] = plusI16(&skill_cells[i][2], sheet.skillBonus(s));
        skill_rows[i] = row;
    }
    if (ctx.table(area, &skills_table, &SKILL_COLUMNS, &skill_rows)) |index| {
        const s: hero.Skill = @enumFromInt(index);
        askRoll(.{ .skill = s }, s.word());
    }
}

fn askRoll(what: RollWhat, label: []const u8) void {
    var line = str.Builder{ .buf = &question_buffer };
    line.text(label);
    line.text(": roll how?");
    ask(.{ .roll = what }, line.done(), &ROLL_CHOICES, null);
}

// ---------------------------------------------------------------------------
// The Combat pane
// ---------------------------------------------------------------------------

const ATTACK_COLUMNS = [_]eui.table.Column{
    .{ .title = "Attack", .width = 120, .flex = true },
    .{ .title = "Hit", .width = 44 },
    .{ .title = "Damage", .width = 120 },
    .{ .title = "Notes", .width = 120 },
};

const CONDITIONS = [_][]const u8{ "Frightened", "Poisoned", "Prone", "Grappled", "Restrained" };

fn drawCombat(area: Rect) void {
    const surface = ctx.surface;
    const t = theme.current();
    if (ctx.damaged) surface.fill(area, t.surface);

    const gap = t.gap;
    const tile_w = @divTrunc(area.w - gap * 2, 3);
    const tile_h: i32 = 44;
    drawStat(surface, .{ .x = area.x, .y = area.y, .w = tile_w, .h = tile_h }, shield, "Armour", sheet.ac);
    drawStatSigned(surface, .{ .x = area.x + tile_w + gap, .y = area.y, .w = tile_w, .h = tile_h }, bolt, "Initiative", sheet.modifier(.dex));
    drawStat(surface, .{ .x = area.x + (tile_w + gap) * 2, .y = area.y, .w = tile_w, .h = tile_h }, null, "Speed", sheet.speed);

    var y = area.y + tile_h + gap;

    // Hit points: a heart, a stepper for the current, and the maximum beside.
    glyph(surface, area.x, y + 4, heart, t.warning);
    ctx.label(.{ .x = area.x + 18, .y = y, .w = 62, .h = t.control_height }, "Hit points");
    const hp = ctx.stepper(.{ .x = area.x + 84, .y = y, .w = eui.stepper.width(t.control_height), .h = t.control_height }, .{ .min = 0, .max = @intCast(sheet.hp_max) }, sheet.hp_now);
    if (hp != sheet.hp_now) {
        const delta = hp - @as(i32, sheet.hp_now);
        if (delta < 0) append(hero.writeDamage(&line_buffer, @intCast(-delta), "")) else append(hero.writeHeal(&line_buffer, @intCast(delta), ""));
    }
    var of: [16]u8 = @splat(0);
    surface.text(area.x + 84 + eui.stepper.width(t.control_height) + 8, y + 6, ofMax(&of, sheet.hp_max, sheet.hp_temp), t.text_dim);

    const dmg_x = area.right() - 180;
    if (ctx.button(.{ .x = dmg_x, .y = y, .w = 84, .h = t.control_height }, "Damage")) askAmount(.damage, "Took how much?", 1, 999);
    if (ctx.button(.{ .x = dmg_x + 92, .y = y, .w = 84, .h = t.control_height }, "Heal")) askAmount(.heal, "Healed how much?", 1, 999);

    y += t.control_height + gap;

    // Hit dice, and a button to spend one for what it heals.
    glyph(surface, area.x, y + 4, die, t.text_dim);
    ctx.label(.{ .x = area.x + 18, .y = y, .w = 62, .h = t.control_height }, "Hit dice");
    _ = ctx.pips(.{ .x = area.x + 84, .y = y, .w = eui.pips.width(@max(sheet.level, 1)), .h = t.control_height }, @max(sheet.level, 1), sheet.hit_dice_left);
    if (ctx.button(.{ .x = dmg_x, .y = y, .w = 84, .h = t.control_height }, "Hit die")) {
        if (sheet.hit_dice_left > 0) askAmount(.hitdie, "Hit die heals how much?", @divTrunc(sheet.hit_die, 2) + 1, sheet.hit_die + 10) else say("No hit dice left.");
    }

    y += t.control_height + gap;

    // Death saves: successes and failures, each a track of three.
    ctx.label(.{ .x = area.x, .y = y, .w = 78, .h = t.control_height }, "Successes");
    const ds = ctx.pips(.{ .x = area.x + 84, .y = y, .w = eui.pips.width(3), .h = t.control_height }, 3, sheet.death_success);
    if (ds != sheet.death_success) deathSave("success", ds, sheet.death_success);
    ctx.label(.{ .x = dmg_x, .y = y, .w = 78, .h = t.control_height }, "Failures");
    const df = ctx.pips(.{ .x = dmg_x + 84, .y = y, .w = eui.pips.width(3), .h = t.control_height }, 3, sheet.death_failure);
    if (df != sheet.death_failure) deathSave("failure", df, sheet.death_failure);

    y += t.control_height + gap;

    // Conditions, each a toggle; bloodied is derived and only shown.
    var cx = area.x;
    if (sheet.bloodied()) {
        const w = eui.footer.buttonWidth("Bloodied");
        surface.fill(.{ .x = cx, .y = y, .w = w, .h = t.control_height }, t.warning);
        surface.textCentred(.{ .x = cx, .y = y, .w = w, .h = t.control_height }, "Bloodied", t.accent_text);
        cx += w + gap;
    }
    for (CONDITIONS) |name| {
        const on = sheet.hasCondition(name);
        const w = eui.footer.buttonWidth(name);
        if (ctx.toggle(.{ .x = cx, .y = y, .w = w, .h = t.control_height }, name, on)) {
            append(hero.writeCondition(&line_buffer, name, !on));
        }
        cx += w + gap;
    }

    y += t.control_height + gap;

    // The attacks, and a roll on the one chosen.
    const table_area = Rect{ .x = area.x, .y = y, .w = area.w, .h = area.bottom() - y };
    if (attackRows()) |rows| {
        if (ctx.table(table_area, &attacks_table, &ATTACK_COLUMNS, rows)) |index| {
            askRoll(.{ .attack = index }, sheet.attacks.slice()[index].name);
        }
    }
}

fn deathSave(which: []const u8, now: usize, before: usize) void {
    if (now > before) {
        var i = before;
        while (i < now) : (i += 1) append(hero.writeSave(&line_buffer, which));
    } else {
        append(hero.writeSave(&line_buffer, "reset"));
    }
}

var attack_rows: [hero.MAX_ATTACKS]eui.table.Row = undefined;

fn attackRows() ?[]const eui.table.Row {
    const list = sheet.attacks.slice();
    for (list, 0..) |atk, i| {
        var row = eui.table.Row{};
        row.cells[0] = atk.name;
        row.cells[1] = atk.hit;
        row.cells[2] = atk.damage;
        row.cells[3] = atk.notes;
        attack_rows[i] = row;
    }
    return attack_rows[0..list.len];
}

// ---------------------------------------------------------------------------
// The Spells pane
// ---------------------------------------------------------------------------

const SPELL_COLUMNS = [_]eui.table.Column{
    .{ .title = "Spell", .width = 130, .flex = true },
    .{ .title = "Level", .width = 52 },
    .{ .title = "Time", .width = 68 },
    .{ .title = "Range", .width = 96 },
    .{ .title = "Notes", .width = 120 },
};

var spell_cells: [hero.MAX_SPELLS][8]u8 = @splat(@splat(0));
var spell_rows: [hero.MAX_SPELLS]eui.table.Row = undefined;

fn drawSpells(area: Rect) void {
    const surface = ctx.surface;
    const t = theme.current();
    if (ctx.damaged) surface.fill(area, t.surface);

    // The casting line, and the slots as pips.
    glyph(surface, area.x, area.y + 4, spark, t.accent);
    var head: [96]u8 = @splat(0);
    var line = str.Builder{ .buf = &head };
    line.text(sheet.spell_ability.word());
    line.text("  ·  DC ");
    line.number(@intCast(sheet.spellSaveDc()));
    line.text("  ·  attack ");
    signed(&line, sheet.spellAttack());
    surface.text(area.x + 18, area.y + 6, line.done(), t.text);

    var y = area.y + t.control_height + 4;
    if (sheet.innate_max > 0) {
        ctx.label(.{ .x = area.x, .y = y, .w = 92, .h = t.control_height }, "Innate Sorcery");
        _ = ctx.pips(.{ .x = area.x + 96, .y = y, .w = eui.pips.width(sheet.innate_max), .h = t.control_height }, sheet.innate_max, sheet.innate_left);
        y += t.control_height;
    }
    for (0..hero.SPELL_LEVELS) |lvl| {
        if (sheet.slots_max[lvl] == 0) continue;
        var lbl: [16]u8 = @splat(0);
        ctx.label(.{ .x = area.x, .y = y, .w = 92, .h = t.control_height }, levelLabel(&lbl, lvl + 1));
        _ = ctx.pips(.{ .x = area.x + 96, .y = y, .w = eui.pips.width(sheet.slots_max[lvl]), .h = t.control_height }, sheet.slots_max[lvl], sheet.slots_left[lvl]);
        y += t.control_height;
    }

    y += t.gap;
    const table_area = Rect{ .x = area.x, .y = y, .w = area.w, .h = area.bottom() - y };
    const list = sheet.spells.slice();
    for (list, 0..) |sp, i| {
        var row = eui.table.Row{};
        row.cells[0] = sp.name;
        row.cells[1] = if (sp.level == 0) "cantrip" else levelLabel(&spell_cells[i], sp.level);
        row.cells[2] = sp.time;
        row.cells[3] = sp.range;
        row.cells[4] = sp.notes;
        spell_rows[i] = row;
    }
    if (ctx.table(table_area, &spells_table, &SPELL_COLUMNS, spell_rows[0..list.len])) |index| {
        const sp = list[index];
        if (sp.level == 0) {
            append(hero.writeCast(&line_buffer, 0, sp.name));
        } else if (sheet.slots_left[sp.level - 1] == 0) {
            say("No slot of that level.");
        } else {
            var line2 = str.Builder{ .buf = &question_buffer };
            line2.text(sp.name);
            line2.text(", level ");
            line2.number(sp.level);
            line2.text(": spend a slot?");
            ask(.{ .cast = index }, line2.done(), &CAST_CHOICES, null);
        }
    }
}

const CAST_CHOICES = [_]eui.prompt.Choice{
    .{ .label = "Cast", .letter = 'c', .weight = .strong },
    .{ .label = "Cancel" },
};

// ---------------------------------------------------------------------------
// The Gear pane
// ---------------------------------------------------------------------------

const ITEM_COLUMNS = [_]eui.table.Column{
    .{ .title = "Item", .width = 180, .flex = true },
    .{ .title = "Qty", .width = 52, .right = true },
    .{ .title = "Weight", .width = 72, .right = true },
};

var item_cells: [hero.MAX_ITEMS][2][12]u8 = @splat(@splat(@splat(0)));
var item_rows: [hero.MAX_ITEMS]eui.table.Row = undefined;

const COIN_WORDS = [_][]const u8{ "cp", "sp", "ep", "gp", "pp" };

fn drawGear(area: Rect) void {
    const surface = ctx.surface;
    const t = theme.current();
    if (ctx.damaged) surface.fill(area, t.surface);

    // The purse, and the two ways it changes.
    glyph(surface, area.x, area.y + 4, coin, 0xB8860B);
    var purse: [64]u8 = @splat(0);
    var line = str.Builder{ .buf = &purse };
    for (sheet.coins, 0..) |amount, i| {
        if (amount == 0) continue;
        if (line.len > 0) line.text("  ");
        line.number(@intCast(@max(amount, 0)));
        line.byte(' ');
        line.text(COIN_WORDS[i]);
    }
    if (line.len == 0) line.text("empty");
    surface.text(area.x + 18, area.y + 6, line.done(), t.text);

    if (ctx.button(.{ .x = area.right() - 180, .y = area.y, .w = 84, .h = t.control_height }, "Pay")) askAmount(.gold_pay, "Pay how much gold?", 1, 99999);
    if (ctx.button(.{ .x = area.right() - 92, .y = area.y, .w = 84, .h = t.control_height }, "Receive")) askAmount(.gold_get, "Receive how much gold?", 1, 99999);

    // What is carried, and how much it weighs against what can be.
    var y = area.y + t.control_height + t.gap;
    var facts: [2]eui.facts.Fact = undefined;
    var fb: [2][24]u8 = @splat(@splat(0));
    facts[0] = .{ .label = "Carried", .value = pounds(&fb[0], carriedWeight()) };
    facts[1] = .{ .label = "Capacity", .value = poundsWhole(&fb[1], sheet.carryCapacity()) };
    y = eui.facts.all(ctx, .{ .x = area.x, .y = y, .w = area.w, .h = t.control_height * 2 }, y, &facts);

    y += t.gap;
    const table_area = Rect{ .x = area.x, .y = y, .w = area.w, .h = area.bottom() - y };
    const list = sheet.items.slice();
    for (list, 0..) |it, i| {
        var row = eui.table.Row{};
        row.cells[0] = it.name;
        row.cells[1] = str.number(&item_cells[i][0], it.quantity, 10, .lower);
        row.cells[2] = pounds(&item_cells[i][1], @as(u32, it.quantity) * it.weight_cp);
        item_rows[i] = row;
    }
    _ = ctx.table(table_area, &items_table, &ITEM_COLUMNS, item_rows[0..list.len]);
}

fn carriedWeight() u32 {
    var total: u32 = 0;
    for (sheet.items.slice()) |it| total += @as(u32, it.quantity) * it.weight_cp;
    return total;
}

// ---------------------------------------------------------------------------
// The Journal pane
// ---------------------------------------------------------------------------

var note_editor: eui.text.Editor = .{};
var note_storage: [256]u8 = @splat(0);
var note_doc: eui.text.Buffer = .{ .bytes = &note_storage };

fn drawJournal(area: Rect) void {
    const surface = ctx.surface;
    const t = theme.current();
    if (ctx.damaged) surface.fill(area, t.surface);

    // A field to add a note, then the events newest first under it.
    ctx.label(.{ .x = area.x, .y = area.y, .w = 40, .h = t.control_height }, "Note");
    const field = Rect{ .x = area.x + 44, .y = area.y, .w = area.w - 44 - 92, .h = t.control_height };
    if (focus_note) {
        ctx.focusAt(field);
        focus_note = false;
    }
    if (eui.text.field(ctx, field, &note_editor, &note_doc)) addNote();
    if (ctx.button(.{ .x = area.right() - 84, .y = area.y, .w = 84, .h = t.control_height }, "Add")) addNote();

    const list_area = Rect{ .x = area.x, .y = area.y + t.control_height + t.gap, .w = area.w, .h = area.bottom() - area.y - t.control_height - t.gap };
    surface.fill(list_area, t.surface);
    surface.frame(list_area, t.line);

    const view = eui.scrollpane.begin(ctx, list_area.inset(1), &journal_scroll);
    var y = view.top() + 2;
    const row_h = Surface.textHeight() + 4;
    // Newest first: the file read from the bottom up.
    var it = std.mem.splitBackwardsScalar(u8, storage[0..text_len], '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.eql(u8, line, hero.MAGIC)) continue;
        const said = journalLine(line);
        if (said.len == 0) continue;
        if (y + row_h > view.top() and y < view.top() + list_area.h) {
            surface.text(list_area.x + 6, y + 2, said, if (isHeading(line)) t.accent else t.text);
        }
        y += row_h;
    }
    eui.scrollpane.end(ctx, &journal_scroll, view, y - view.top());
}

fn addNote() void {
    const text = std.mem.trim(u8, note_doc.slice(), " \t");
    if (text.len == 0) return;
    append(hero.writeNote(&line_buffer, text));
    note_doc.clear();
    note_editor = .{};
}

fn isHeading(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "session ");
}

/// A journal line as a person reads it: a session heading whole, and an event
/// as its words rather than its keyword.
fn journalLine(line: []const u8) []const u8 {
    if (line[0] == '#') return "";
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return line;
    const keyword = line[0..space];
    const rest = line[space + 1 ..];
    if (std.mem.eql(u8, keyword, "session")) {
        var b = str.Builder{ .buf = &journal_buffer };
        b.text("Session ");
        b.text(hero.part(rest, 0));
        b.text("  ");
        b.text(hero.part(rest, 1));
        return b.done();
    }
    if (isFact(keyword)) return "";
    // A note is just what was written; the keyword is for the file, not the eye.
    if (std.mem.eql(u8, keyword, "note")) return rest;
    // Any other event: its keyword then its parts, in the file's own words.
    var b = str.Builder{ .buf = &journal_buffer };
    b.text(keyword);
    var parts = std.mem.splitSequence(u8, rest, hero.SEPARATOR);
    while (parts.next()) |p| {
        b.byte(' ');
        b.text(std.mem.trim(u8, p, " \t"));
    }
    return b.done();
}

var journal_buffer: [128]u8 = @splat(0);

/// Whether a keyword sets the sheet rather than records a moment: those are
/// not the journal, which is the play.
fn isFact(keyword: []const u8) bool {
    const facts = [_][]const u8{
        "name",  "class",       "species",   "background", "alignment", "size",   "player", "picture",
        "level", "advancement", "str",       "dex",        "con",       "int",    "wis",    "cha",
        "saves", "skills",      "expertise", "hp",         "hit-die",   "ac",     "speed",  "spellcasting",
        "slots", "innate",      "weapons",   "tools",      "languages", "armour", "coins",  "attack",
        "spell", "item",        "feature",
    };
    for (facts) |f| {
        if (std.mem.eql(u8, keyword, f)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Little formatters
// ---------------------------------------------------------------------------

fn drawStat(surface: Surface, box: Rect, mark: ?Glyph, label: []const u8, value: u16) void {
    const t = theme.current();
    surface.fill(box, t.surface_hot);
    surface.frame(box, t.line);
    if (mark) |g| glyph(surface, box.x + 6, box.y + 6, g, t.text_dim);
    surface.text(box.x + 22, box.y + 6, label, t.text_dim);
    var num: [8]u8 = @splat(0);
    surface.textLarge(box.x + 22, box.y + 18, str.number(&num, value, 10, .lower), t.text, 2);
}

fn drawStatSigned(surface: Surface, box: Rect, mark: ?Glyph, label: []const u8, value: i8) void {
    const t = theme.current();
    surface.fill(box, t.surface_hot);
    surface.frame(box, t.line);
    if (mark) |g| glyph(surface, box.x + 6, box.y + 6, g, t.text_dim);
    surface.text(box.x + 22, box.y + 6, label, t.text_dim);
    var num: [8]u8 = @splat(0);
    surface.textLarge(box.x + 22, box.y + 18, plusInt(&num, value), t.text, 2);
}

fn plusInt(buf: []u8, value: i8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}", .{ if (value < 0) "-" else "+", @abs(value) }) catch "";
}

fn plusI16(buf: []u8, value: i16) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}", .{ if (value < 0) "-" else "+", @abs(value) }) catch "";
}

fn intText(buf: []u8, value: i16) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "";
}

fn feet(buf: []u8, value: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d} ft.", .{value}) catch "";
}

fn levelLabel(buf: []u8, level: usize) []const u8 {
    return std.fmt.bufPrint(buf, "Level {d}", .{level}) catch "";
}

fn ofMax(buf: []u8, max: u16, temp: u16) []const u8 {
    if (temp > 0) return std.fmt.bufPrint(buf, "of {d}  +{d} temp", .{ max, temp }) catch "";
    return std.fmt.bufPrint(buf, "of {d}", .{max}) catch "";
}

fn pounds(buf: []u8, hundredths: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d:0>2} lb", .{ hundredths / 100, hundredths % 100 }) catch "";
}

fn poundsWhole(buf: []u8, whole: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d} lb", .{whole}) catch "";
}

fn orDash(text: []const u8) []const u8 {
    return if (text.len > 0) text else "-";
}

fn upper3(buf: []u8, word: []const u8) []const u8 {
    const n = @min(word.len, 3);
    for (0..n) |i| buf[i] = std.ascii.toUpper(word[i]);
    return buf[0..n];
}

var saves_buffer: [48]u8 = @splat(0);

fn savesText() []const u8 {
    var line = str.Builder{ .buf = &saves_buffer };
    for (std.enums.values(hero.Ability)) |a| {
        if (!sheet.save_prof[@intFromEnum(a)]) continue;
        if (line.len > 0) line.text(", ");
        line.text(a.word());
    }
    return if (line.len > 0) line.done() else "-";
}
