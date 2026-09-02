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
const out = @import("ulib").out;
const str = @import("lib").str;
const civil = @import("lib").civil;
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

/// Hero's own version. An application outside the system is versioned on its
/// own rather than with the system's string: it ships when it ships.
pub const VERSION = "1.0";
var storage: [CAPACITY]u8 = undefined;
var text_len: usize = 0;

/// The character the file folds to, rebuilt whenever the file changes.
var sheet: hero.Sheet = .{};

var file_path: [128]u8 = @splat(0);
var file_len: usize = 0;
var modified = false;
var status: []const u8 = "";
var status_buffer: [96]u8 = @splat(0);

const Section = enum {
    sheet,
    skills,
    combat,
    spells,
    gear,
    journal,

    pub fn word(self: Section) []const u8 {
        return switch (self) {
            .sheet => "Sheet",
            .skills => "Skills",
            .combat => "Combat",
            .spells => "Spells",
            .gear => "Gear",
            .journal => "Journal",
        };
    }
};
var section: Section = .sheet;

/// Set when the Journal has just been opened, so its note field takes the
/// keyboard without a click: on this section, typing is a note or nothing.
var focus_note = false;
/// The same for the Skills table: opened, it takes the arrows and Enter, so a
/// skill is picked and rolled without reaching for the pointer.
var focus_skills = false;

fn stepSection(by: i32) void {
    const count = std.enums.values(Section).len;
    const now: i32 = @intCast(@intFromEnum(section));
    const next: usize = @intCast(@mod(now + by, count));
    setSection(@enumFromInt(next));
}

fn setSection(which: Section) void {
    if (which == section) return;
    section = which;
    focus_note = which == .journal;
    focus_skills = which == .skills;
    status = "";
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
    plain,

    fn label(self: RollWhat) []const u8 {
        return switch (self) {
            .skill => |s| s.word(),
            .save => |a| a.word(),
            .attack => |i| if (i < sheet.attacks.len) sheet.attacks.slice()[i].name else "Attack",
            .plain => "d20",
        };
    }

    fn modifier(self: RollWhat) i16 {
        const bonus: i16 = switch (self) {
            .skill => |s| sheet.skillBonus(s),
            .save => |a| sheet.saveBonus(a),
            .attack => |i| attackBonus(i),
            .plain => 0,
        };
        return bonus + sheet.exhaustionPenalty();
    }
};

var pending: Helper = .none;

const Command = enum(u16) {
    open,
    save,
    save_as,
    close,
    damage,
    heal,
    temp,
    hitdie,
    pay,
    receive,
    inspiration,
    new_session,
    note,
    roll_check,
    roll_attack,
    roll_plain,
    rest,
    long_rest,
    short_rest,
    status_bar,
};

const MENUS = [_]eui.menubar.Menu{
    .{ .label = "File", .items = &.{
        .{ .label = "Open...", .id = @intFromEnum(Command.open), .shortcut = "Ctrl+O" },
        .{ .label = "Save", .id = @intFromEnum(Command.save), .shortcut = "Ctrl+S" },
        .{ .label = "Save as...", .id = @intFromEnum(Command.save_as), .shortcut = "Ctrl+Shift+S" },
        eui.menubar.Item.separator,
        .{ .label = "Close", .id = @intFromEnum(Command.close), .shortcut = "Ctrl+Q" },
    } },
    .{ .label = "Edit", .items = &.{
        .{ .label = "Take damage...", .id = @intFromEnum(Command.damage), .shortcut = "Ctrl+D" },
        .{ .label = "Heal...", .id = @intFromEnum(Command.heal), .shortcut = "Ctrl+H" },
        .{ .label = "Temporary hit points...", .id = @intFromEnum(Command.temp) },
        .{ .label = "Spend a hit die...", .id = @intFromEnum(Command.hitdie) },
        eui.menubar.Item.separator,
        .{ .label = "Pay gold...", .id = @intFromEnum(Command.pay) },
        .{ .label = "Receive gold...", .id = @intFromEnum(Command.receive) },
        eui.menubar.Item.separator,
        .{ .label = "Heroic Inspiration", .id = @intFromEnum(Command.inspiration) },
        .{ .label = "New session", .id = @intFromEnum(Command.new_session) },
        .{ .label = "Note", .id = @intFromEnum(Command.note), .shortcut = "Ctrl+N" },
    } },
    .{ .label = "Roll", .items = &.{
        .{ .label = "Skill check...", .id = @intFromEnum(Command.roll_check), .shortcut = "Ctrl+R" },
        .{ .label = "Attack...", .id = @intFromEnum(Command.roll_attack) },
        .{ .label = "A d20", .id = @intFromEnum(Command.roll_plain) },
    } },
    .{ .label = "Rest", .items = &.{
        .{ .label = "Rest...", .id = @intFromEnum(Command.rest) },
        eui.menubar.Item.separator,
        .{ .label = "Long rest", .id = @intFromEnum(Command.long_rest) },
        .{ .label = "Short rest", .id = @intFromEnum(Command.short_rest) },
    } },
    .{ .label = "View", .items = &.{
        .{ .label = "Status bar", .id = @intFromEnum(Command.status_bar) },
    } },
};

/// What View turns off. On to start with.
var show_status = true;

// The open and save dialog, borrowed by both.
var dialog: proto.FileDialog = .{};
var asking_file: proto.dialog.Purpose = .open;

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    if (env.argument(frame)) |wanted| {
        // The one question a shell asks a program without opening it.
        if (std.mem.eql(u8, wanted, "--version")) {
            out.text("hero " ++ VERSION ++ "\n");
            out.flush();
            sys.exit(0);
        }
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

/// Where the last directory ends in `full`, or zero for a bare name.
fn afterSlash(full: []const u8) usize {
    return if (std.mem.lastIndexOfScalar(u8, full, '/')) |at| at + 1 else 0;
}

fn baseName() []const u8 {
    return path()[afterSlash(path())..];
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
    return std.fmt.bufPrint(buf, "{s}{s}", .{ full[0..afterSlash(full)], picture }) catch picture;
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

const CloseChoice = enum(usize) { save, discard, cancel };
const CLOSE_CHOICES = [_]eui.prompt.Choice{
    .{ .label = "Save", .letter = 's', .weight = .strong },
    .{ .label = "Discard", .letter = 'd' },
    .{ .label = "Cancel" },
};

const RestChoice = enum(usize) { long, short, cancel };
const REST_CHOICES = [_]eui.prompt.Choice{
    .{ .label = "Long", .letter = 'l', .weight = .strong },
    .{ .label = "Short", .letter = 's' },
    .{ .label = "Cancel" },
};

// Normal first: Enter takes the first choice, and a plain roll is what
// Enter should mean. Advantage and disadvantage answer to their letters. The
// order is the journal's `Roll`, which is what the answer becomes.
const ROLL_CHOICES = [_]eui.prompt.Choice{
    .{ .label = "Normal", .letter = 'n', .weight = .strong },
    .{ .label = "Advantage", .letter = 'a' },
    .{ .label = "Disadvantage", .letter = 'd' },
};

comptime {
    std.debug.assert(CLOSE_CHOICES.len == std.enums.values(CloseChoice).len);
    std.debug.assert(REST_CHOICES.len == std.enums.values(RestChoice).len);
    std.debug.assert(ROLL_CHOICES.len == std.enums.values(hero.Roll).len);
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn run(command: Command) void {
    switch (command) {
        .open => askFile(.open),
        .save => save(),
        .save_as => askFile(.save),
        .close => if (mayClose()) sys.exit(0),
        .damage => askAmount(.damage, "Took how much damage?", 1, 999),
        .heal => askAmount(.heal, "Healed how much?", 1, 999),
        .temp => askAmount(.temp, "How many temporary hit points?", 1, 99),
        .hitdie => spendHitDie(),
        .pay => askAmount(.gold_pay, "Pay how much gold?", 1, 99999),
        .receive => askAmount(.gold_get, "Receive how much gold?", 1, 99999),
        .inspiration => append(hero.writeInspiration(&line_buffer, hero.Switch.of(!sheet.inspiration))),
        .new_session => newSession(),
        .note => setSection(.journal),
        .roll_check => askRoll(.{ .skill = @enumFromInt(@min(skills_table.selected, std.enums.values(hero.Skill).len - 1)) }),
        .roll_attack => if (sheet.attacks.len > 0) askRoll(.{ .attack = @min(attacks_table.selected, sheet.attacks.len - 1) }) else say("No attacks written."),
        .roll_plain => askRoll(.plain),
        .rest => askRest(),
        .long_rest => append(hero.writeRest(&line_buffer, .long)),
        .short_rest => append(hero.writeRest(&line_buffer, .short)),
        .status_bar => {
            show_status = !show_status;
            ctx.damage();
        },
    }
}

fn spendHitDie() void {
    if (sheet.hit_dice_left == 0) {
        say("No hit dice left.");
        return;
    }
    // Rolled for the player and offered: the die plus Constitution, which they
    // may correct before it is written.
    const rolled: i32 = @intCast(rollDie(sheet.hit_die));
    const healed = @max(1, rolled + sheet.modifier(.con));
    askAmount(.hitdie, "The hit die heals how much?", healed, sheet.hit_die + 10);
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
        const line = std.mem.trim(u8, raw, " \t\r");
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (hero.Keyword.parse(line[0..space]) == .session) count += 1;
    }
    return count;
}

fn today(buf: []u8) []const u8 {
    const micros = sys.realtimeMicros() orelse return "";
    const day = civil.fromEpoch(@divFloor(micros, 1_000_000));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(day.year)), day.month, day.day,
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

fn amountOf(value: i32, low: i32, high: i32) eui.prompt.Amount {
    return .{ .value = value, .range = .{ .min = low, .max = high } };
}

fn askAmount(helper: Helper, question: []const u8, start: i32, high: i32) void {
    ask(helper, question, &AMOUNT_CHOICES, amountOf(start, 1, high));
}

fn askRest() void {
    ask(.rest, "Which rest?", &REST_CHOICES, null);
}

/// The answer to whatever stood on the sheet.
fn answer(choice: usize) void {
    const helper = pending;
    const number = prompt.number();
    prompt.dismiss();
    pending = .none;
    ctx.damage();

    switch (helper) {
        .none => {},
        .close => switch (@as(CloseChoice, @enumFromInt(choice))) {
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
        .rest => switch (@as(RestChoice, @enumFromInt(choice))) {
            .long => append(hero.writeRest(&line_buffer, .long)),
            .short => append(hero.writeRest(&line_buffer, .short)),
            .cancel => {},
        },
    }
}

fn castSpell(index: usize) void {
    if (index >= sheet.spells.len) return;
    const spell = sheet.spells.slice()[index];
    append(hero.writeCast(&line_buffer, spell.level, spell.name));
}

/// One die, from a generator seeded by the clock the first time it is asked.
fn rollDie(faces: u8) u8 {
    if (!dice_seeded) {
        const seed: u64 = @bitCast(sys.realtimeMicros() orelse @as(i64, @intCast(sys.clockMicros())));
        dice = std.Random.DefaultPrng.init(seed);
        dice_seeded = true;
    }
    return dice.random().intRangeAtMost(u8, 1, @max(faces, 1));
}

/// Roll a d20, keeping the higher of two for advantage and the lower for
/// disadvantage, apply the modifier and the exhaustion penalty, and write the
/// die kept so the total on the status line can be checked against the file.
fn doRoll(what: RollWhat, how: hero.Roll) void {
    const a = rollDie(20);
    const b = rollDie(20);
    const kept: u8 = switch (how) {
        .normal => a,
        .advantage => @max(a, b),
        .disadvantage => @min(a, b),
    };
    const modifier = what.modifier();
    const label = what.label();

    append(hero.writeRoll(&line_buffer, label, kept, modifier, how));

    var line = str.Builder{ .buf = &status_buffer };
    line.text(label);
    line.text(": ");
    line.number(@intCast(@max(@as(i32, kept) + modifier, 0)));
    line.text(" (");
    line.number(kept);
    signedSpaced(&line, modifier);
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

/// ` + 7` or ` - 2`, as a sum is read.
fn signedSpaced(line: *str.Builder, value: i16) void {
    line.text(if (value < 0) " - " else " + ");
    line.number(@abs(value));
}

/// `+7` or `-2`, as a bonus is written.
fn signedTight(line: *str.Builder, value: i16) void {
    line.byte(if (value < 0) '-' else '+');
    line.number(@abs(value));
}

/// The same bonus into a buffer, for a table cell or a tile.
fn signedText(buf: []u8, value: anytype) []const u8 {
    var line = str.Builder{ .buf = buf };
    signedTight(&line, @intCast(value));
    return line.done();
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

/// Started with no character, the window asks for one before anything else:
/// a sheet with nothing on it is not a thing to look at.
var asked_at_start = false;

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const area = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };

    if (file_len == 0 and !asked_at_start) {
        asked_at_start = true;
        askFile(.open);
    }

    const parts = eui.chrome.split(area, .{ .top = true, .bottom = show_status });
    const strip = parts.top;
    const body = parts.body;

    // The rail: a headshot square, then the sections under it, each with its
    // own picture.
    const rail_w = eui.rail.width();
    const head_area = Rect{ .x = body.x, .y = body.y, .w = rail_w, .h = @min(@as(i32, 84), body.h) };
    drawHeadshot(surface, head_area);
    const rows_area = Rect{ .x = body.x, .y = head_area.bottom(), .w = rail_w, .h = body.h - head_area.h };
    var items: [std.enums.values(Section).len]eui.rail.Item = undefined;
    for (std.enums.values(Section), 0..) |which, i| items[i] = .{ .label = which.word(), .glyph = &section_glyphs[i] };
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

    // The status bar: what this pane is about, or what was just said; the
    // session; and whether the journal is on the medium.
    if (show_status) {
        eui.statusbar.run(ctx, parts.bottom, &.{
            .{ .text = if (file_len > 0) baseName() else "No file open" },
            .{ .text = sessionText(), .width = 96, .right = true },
            .{ .text = if (status.len > 0) status else if (modified) "Unsaved changes" else paneLine(), .width = 210, .right = true },
        });
    }

    // Last, so an open menu reaches over the pane rather than under it.
    if (eui.menubar.run(ctx, strip, &menus, &MENUS)) |id| run(@enumFromInt(id));
}

fn inset(area: Rect, by: i32) Rect {
    return .{ .x = area.x + by, .y = area.y + by, .w = area.w - by * 2, .h = area.h - by * 2 };
}

/// The rail's foot names the program and its version, the way Settings'
/// names the machine's; the file is the status bar's to say.
fn caption() []const u8 {
    return "Hero " ++ VERSION;
}

var subtitle_buffer: [96]u8 = @splat(0);

fn subtitle() []const u8 {
    var line = str.Builder{ .buf = &subtitle_buffer };
    line.text(if (sheet.name.len > 0) sheet.name else "Hero");
    if (sheet.class.len > 0) {
        line.text(" \u{b7} ");
        line.text(sheet.class);
        line.byte(' ');
        line.number(sheet.level);
    }
    if (sheet.species.len > 0) {
        line.text(" \u{b7} ");
        line.text(sheet.species);
    }
    return line.done();
}

/// The line each pane owns when nothing has just been said.
fn paneLine() []const u8 {
    return switch (section) {
        .combat => hitPointLine(),
        .journal => journalCountLine(),
        else => subtitle(),
    };
}

fn hitPointLine() []const u8 {
    var line = str.Builder{ .buf = &subtitle_buffer };
    line.number(sheet.hp_now);
    line.text(" of ");
    line.number(sheet.hp_max);
    line.text(" hit points");
    if (sheet.hp_temp > 0) {
        line.text(", ");
        line.number(sheet.hp_temp);
        line.text(" temporary");
    }
    if (sheet.down()) line.text(" \u{b7} Down") else if (sheet.bloodied()) line.text(" \u{b7} Bloodied");
    return line.done();
}

fn journalCountLine() []const u8 {
    var line = str.Builder{ .buf = &subtitle_buffer };
    line.number(journal_rows_len);
    line.text(if (journal_rows_len == 1) " entry" else " entries");
    line.text(" \u{b7} ");
    line.number(sessionCount());
    line.text(if (sessionCount() == 1) " session" else " sessions");
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
// Hero's own pictures: the game's things, drawn here because a shield and a
// heart are this program's business and belong nowhere in the toolkit. Written
// as pictures and packed by the toolkit at compile time, in its own format, so
// a rail row or a tile takes them as it takes any icon.
// ---------------------------------------------------------------------------

const Glyph = eui.icon.Glyph;

const shield = eui.icon.pack(.{
    "............",
    "...######...",
    "..#......#..",
    ".#........#.",
    ".#........#.",
    ".#........#.",
    "..#......#..",
    "..#......#..",
    "...#....#...",
    "....#..#....",
    ".....##.....",
    "............",
});
const heart = eui.icon.pack(.{
    "............",
    "............",
    "..##...##...",
    ".####.####..",
    ".##########.",
    ".##########.",
    "..########..",
    "...######...",
    "....####....",
    ".....##.....",
    "............",
    "............",
});
const bolt = eui.icon.pack(.{
    "............",
    "......###...",
    ".....###....",
    "....###.....",
    "...######...",
    "..#######...",
    ".....###....",
    "....###.....",
    "...###......",
    "..###.......",
    "............",
    "............",
});
const coin = eui.icon.pack(.{
    "............",
    "....####....",
    "..##....##..",
    ".#........#.",
    ".#...##...#.",
    ".#..#..#..#.",
    ".#..#..#..#.",
    ".#...##...#.",
    ".#........#.",
    "..##....##..",
    "....####....",
    "............",
});
const die = eui.icon.pack(.{
    "............",
    ".##########.",
    ".#........#.",
    ".#.#......#.",
    ".#........#.",
    ".#...#....#.",
    ".#........#.",
    ".#......#.#.",
    ".#........#.",
    ".##########.",
    "............",
    "............",
});
const spark = eui.icon.pack(.{
    "............",
    ".....##.....",
    ".....##.....",
    "..#..##..#..",
    "...####.#...",
    ".######.###.",
    "..########..",
    "...#####.#..",
    "..#..##..##.",
    ".....##.....",
    ".....##.....",
    "............",
});
const pace = eui.icon.pack(.{
    "............",
    "............",
    "..#....#....",
    "...#....#...",
    "....#....#..",
    ".....#....#.",
    "....#....#..",
    "...#....#...",
    "..#....#....",
    "............",
    "............",
    "............",
});
const skull = eui.icon.pack(.{
    "............",
    "...######...",
    "..#......#..",
    ".#........#.",
    ".#..#..#..#.",
    ".#.###.###.#",
    ".#..#..#..#.",
    ".#........#.",
    "..#..##..#..",
    "...#.##.#...",
    "...######...",
    "............",
});

/// One per section, in the rail: distinct at twelve pixels, so a glance down
/// the side of the window lands on the right pane before a word is read.
const section_glyphs = [_][eui.icon.BYTES]u8{
    eui.icon.pack(.{
        "............",
        ".########...",
        ".#......#...",
        ".#..##..#...",
        ".#......#...",
        ".#..##..#...",
        ".#......#...",
        ".#..##..#...",
        ".#......#...",
        ".########...",
        "............",
        "............",
    }),
    eui.icon.pack(.{
        "............",
        "....####....",
        "..##....##..",
        ".#...##...#.",
        ".#..####..#.",
        ".#.##..##.#.",
        ".#.##..##.#.",
        ".#..####..#.",
        ".#...##...#.",
        "..##....##..",
        "....####....",
        "............",
    }),
    eui.icon.pack(.{
        "............",
        ".#........#.",
        "..#......#..",
        "...#....#...",
        "....#..#....",
        ".....##.....",
        "....#..#....",
        "...#....#...",
        "..#......#..",
        ".#........#.",
        "............",
        "............",
    }),
    eui.icon.pack(.{
        "............",
        ".....##.....",
        ".....##.....",
        "..#..##..#..",
        "...######...",
        ".##########.",
        "...######...",
        "..#..##..#..",
        ".....##.....",
        ".....##.....",
        "............",
        "............",
    }),
    eui.icon.pack(.{
        "............",
        "....####....",
        "...#....#...",
        "..#########.",
        "..#.......#.",
        "..#..###..#.",
        "..#..#.#..#.",
        "..#..###..#.",
        "..#.......#.",
        "..#########.",
        "............",
        "............",
    }),
    eui.icon.pack(.{
        "............",
        "..##....##..",
        ".#..#..#..#.",
        ".#..#..#..#.",
        ".#..#..#..#.",
        ".#..#..#..#.",
        ".#..#..#..#.",
        ".#..#..#..#.",
        ".#..#..#..#.",
        "..##....##..",
        "............",
        "............",
    }),
};

// ---------------------------------------------------------------------------
// The Sheet pane
// ---------------------------------------------------------------------------

fn drawSheet(area: Rect) void {
    const surface = ctx.surface;
    const t = theme.current();
    if (ctx.damaged) surface.fill(area, t.surface);

    // The name across the top, big, with who and what beside it, and the
    // player at the far end.
    const name = if (sheet.name.len > 0) sheet.name else "Unnamed";
    surface.title(area.x, area.y, name, t.text);
    const name_w = Surface.titleWidth(name);
    // The words beside it share its baseline rather than its top.
    const beside = Surface.besideTitle(area.y);
    surface.text(area.x + name_w + t.gap * 2, beside, originLine(), t.text_dim);
    const player = if (sheet.player.len > 0) sheet.player else "-";
    const player_x = area.right() - Surface.textWidth(player);
    surface.text(player_x, beside, player, t.text);
    surface.text(player_x - Surface.textWidth("Player") - t.gap, beside, "Player", t.text_dim);

    // The six ability tiles.
    const gap = t.gap;
    const top_tiles = area.y + Surface.titleHeight() + t.gap;
    const tile_w = @divTrunc(area.w - gap * 5, 6);
    const tile_h = eui.figure.height() + Surface.textHeight() + 12;
    for (std.enums.values(hero.Ability), 0..) |ability, i| {
        const x = area.x + @as(i32, @intCast(i)) * (tile_w + gap);
        drawAbility(surface, .{ .x = x, .y = top_tiles, .w = tile_w, .h = tile_h }, ability);
    }

    // Two columns under them: what the character can tell, and what it is
    // trained in and made of.
    const top = top_tiles + tile_h + gap;
    const col_w = @divTrunc(area.w - gap * 2, 2);
    const left = Rect{ .x = area.x, .y = top, .w = col_w, .h = area.bottom() - top };
    const right = Rect{ .x = area.x + col_w + gap * 2, .y = top, .w = col_w, .h = area.bottom() - top };

    eui.heading.paint(surface, left, "Senses and pace", null);
    var senses: [5]eui.facts.Fact = undefined;
    var b: [5][24]u8 = @splat(@splat(0));
    senses[0] = .{ .label = "Proficiency bonus", .value = signedText(&b[0], sheet.proficiency()) };
    senses[1] = .{ .label = "Passive Perception", .value = intText(&b[1], sheet.passive(.perception)) };
    senses[2] = .{ .label = "Passive Insight", .value = intText(&b[2], sheet.passive(.insight)) };
    senses[3] = .{ .label = "Passive Investigation", .value = intText(&b[3], sheet.passive(.investigation)) };
    senses[4] = .{ .label = "Speed", .value = feet(&b[4], sheet.speed) };
    var ly = eui.facts.all(ctx, left, left.y + eui.heading.height(), &senses);
    ly = eui.facts.all(ctx, left, ly, &[_]eui.facts.Fact{
        .{ .label = "Advancement", .value = if (sheet.advancement == .milestone) "Milestone" else "Experience" },
    });
    ctx.label(.{ .x = left.x, .y = ly, .w = 132, .h = t.control_height }, "Heroic Inspiration");
    const pip = ctx.pips(.{ .x = left.x + 136, .y = ly, .w = eui.pips.width(1), .h = t.control_height }, 1, if (sheet.inspiration) 1 else 0);
    if (pip != @intFromBool(sheet.inspiration)) append(hero.writeInspiration(&line_buffer, hero.Switch.of(pip == 1)));

    eui.heading.paint(surface, right, "Proficiencies and training", null);
    var training: [4]eui.facts.Fact = undefined;
    training[0] = .{ .label = "Weapons", .value = orDash(sheet.weapons) };
    training[1] = .{ .label = "Tools", .value = orDash(sheet.tools) };
    training[2] = .{ .label = "Languages", .value = orDash(sheet.languages) };
    training[3] = .{ .label = "Saving throws", .value = savesText() };
    var ry = eui.facts.all(ctx, right, right.y + eui.heading.height(), &training);
    ry += t.gap;
    eui.heading.paint(surface, .{ .x = right.x, .y = ry, .w = right.w, .h = t.control_height }, "Features", null);
    ry += eui.heading.height();
    _ = eui.text.paragraph(surface, .{ .x = right.x, .y = ry, .w = right.w, .h = area.bottom() - ry }, featuresText(), t.text);
}

var origin_buffer: [96]u8 = @splat(0);

/// Class and level, species, background, alignment and size, in a row.
fn originLine() []const u8 {
    var line = str.Builder{ .buf = &origin_buffer };
    if (sheet.class.len > 0) {
        line.text(sheet.class);
        line.byte(' ');
        line.number(sheet.level);
    }
    for ([_][]const u8{ sheet.species, sheet.background, sheet.alignment, sheet.size }) |word| {
        if (word.len == 0) continue;
        if (line.len > 0) line.text(" \u{b7} ");
        line.text(word);
    }
    return line.done();
}

var features_buffer: [256]u8 = @splat(0);

fn featuresText() []const u8 {
    var line = str.Builder{ .buf = &features_buffer };
    for (sheet.features.slice()) |feature| {
        if (line.len > 0) line.text(" \u{b7} ");
        line.text(feature.name);
        if (feature.note.len > 0) {
            line.byte(' ');
            line.text(feature.note);
        }
    }
    return if (line.len > 0) line.done() else "None yet.";
}

fn drawAbility(surface: Surface, box: Rect, ability: hero.Ability) void {
    const t = theme.current();
    // Pressed, a tile rolls its saving throw: the tile is the ability.
    if (ctx.slotFor(box)) |entry| {
        if (ctx.interact(entry, box).clicked) askRoll(.{ .save = ability });
    }

    var num: [4]u8 = @splat(0);
    eui.figure.paint(surface, box, ability.word(), str.number(&num, sheet.scores.get(ability), 10, .lower), null);

    // The modifier beside the score, and the save under it with a pip filled
    // when it is proficient.
    const at = eui.figure.figureRect(box);
    var mod: [6]u8 = @splat(0);
    surface.text(at.x + Surface.titleWidth("00") + 6, at.y + 10, signedText(&mod, sheet.modifier(ability)), t.text);

    var sv: [6]u8 = @splat(0);
    const save_y = box.bottom() - Surface.textHeight() - 9;
    surface.text(at.x, save_y, "Save", t.text_dim);
    surface.text(at.x + Surface.textWidth("Save") + 6, save_y, signedText(&sv, sheet.saveBonus(ability)), t.text);
    const pip = Rect{ .x = box.right() - 18, .y = save_y + 3, .w = 10, .h = 10 };
    const proficient = sheet.save_prof.contains(ability);
    surface.fill(pip, if (proficient) t.accent else t.surface_hot);
    surface.frame(pip, if (proficient) t.accent else t.line);
}

// ---------------------------------------------------------------------------
// The Skills pane
// ---------------------------------------------------------------------------

const SKILL_COLUMNS = [_]eui.table.Column{
    .{ .title = "Skill", .width = 150, .flex = true },
    .{ .title = "Ability", .width = 64 },
    .{ .title = "Proficient", .width = 72 },
    .{ .title = "Bonus", .width = 56, .right = true },
};

var skill_cells: [std.enums.values(hero.Skill).len][2][8]u8 = @splat(@splat(@splat(0)));
var skill_rows: [std.enums.values(hero.Skill).len]eui.table.Row = undefined;

fn drawSkills(area: Rect) void {
    for (std.enums.values(hero.Skill), 0..) |s, i| {
        var row = eui.table.Row{};
        row.cells[0] = s.word();
        row.cells[1] = upper3(&skill_cells[i][0], s.ability().word());
        row.cells[2] = if (sheet.skill_expert.contains(s)) "expert" else if (sheet.skill_prof.contains(s)) "yes" else "-";
        row.cells[3] = signedText(&skill_cells[i][1], sheet.skillBonus(s));
        skill_rows[i] = row;
    }
    if (focus_skills) {
        ctx.focusAt(area);
        focus_skills = false;
    }
    if (ctx.table(area, &skills_table, &SKILL_COLUMNS, &skill_rows)) |index| {
        const s: hero.Skill = @enumFromInt(index);
        askRoll(.{ .skill = s });
    }
}

fn askRoll(what: RollWhat) void {
    var line = str.Builder{ .buf = &question_buffer };
    line.text(what.label());
    line.text(", ");
    signedTight(&line, what.modifier());
    line.text(". Roll with?");
    ask(.{ .roll = what }, line.done(), &ROLL_CHOICES, null);
}

// ---------------------------------------------------------------------------
// The Combat pane
// ---------------------------------------------------------------------------

const ATTACK_COLUMNS = [_]eui.table.Column{
    .{ .title = "Attack", .width = 140 },
    .{ .title = "Hit", .width = 44 },
    .{ .title = "Damage", .width = 130 },
    .{ .title = "Notes", .width = 120, .flex = true },
};

const CONDITIONS = [_][]const u8{ "Frightened", "Poisoned", "Prone", "Grappled" };

fn drawCombat(area: Rect) void {
    const surface = ctx.surface;
    const t = theme.current();
    if (ctx.damaged) surface.fill(area, t.surface);

    const gap = t.gap;
    const tile_w = @divTrunc(area.w - gap * 2, 3);
    const tile_h = eui.figure.height();
    var ac_text: [8]u8 = @splat(0);
    var init_text: [8]u8 = @splat(0);
    var speed_text: [8]u8 = @splat(0);
    eui.figure.paint(surface, .{ .x = area.x, .y = area.y, .w = tile_w, .h = tile_h }, "Armour class", str.number(&ac_text, sheet.ac, 10, .lower), &shield);
    eui.figure.paint(surface, .{ .x = area.x + tile_w + gap, .y = area.y, .w = tile_w, .h = tile_h }, "Initiative", signedText(&init_text, sheet.modifier(.dex)), &bolt);
    eui.figure.paint(surface, .{ .x = area.x + (tile_w + gap) * 2, .y = area.y, .w = tile_w, .h = tile_h }, "Speed", str.number(&speed_text, sheet.speed, 10, .lower), &pace);

    // Two columns: what keeps the character standing, and what happens when
    // it stops.
    const top = area.y + tile_h + gap;
    const col_w = @divTrunc(area.w - gap * 2, 2);
    const left = Rect{ .x = area.x, .y = top, .w = col_w, .h = area.bottom() - top };
    const right = Rect{ .x = area.x + col_w + gap * 2, .y = top, .w = col_w, .h = area.bottom() - top };
    const row = t.control_height + 4;

    eui.heading.paint(surface, left, "Hit points", &heart);
    var ly = left.y + eui.heading.height();
    ctx.label(.{ .x = left.x, .y = ly, .w = 72, .h = t.control_height }, "Current");
    const hp = ctx.stepper(.{ .x = left.x + 76, .y = ly, .w = eui.stepper.width(t.control_height), .h = t.control_height }, .{ .min = 0, .max = @intCast(sheet.hp_max) }, sheet.hp_now);
    if (hp != sheet.hp_now) {
        const delta = hp - @as(i32, sheet.hp_now);
        if (delta < 0) append(hero.writeDamage(&line_buffer, @intCast(-delta), "")) else append(hero.writeHeal(&line_buffer, @intCast(delta), ""));
    }
    var of: [16]u8 = @splat(0);
    ctx.labelDim(.{ .x = left.x + 76 + eui.stepper.width(t.control_height) + gap, .y = ly, .w = 60, .h = t.control_height }, ofMax(&of, sheet.hp_max));
    ly += row;

    ctx.label(.{ .x = left.x, .y = ly, .w = 72, .h = t.control_height }, "Temporary");
    const temp = ctx.stepper(.{ .x = left.x + 76, .y = ly, .w = eui.stepper.width(t.control_height), .h = t.control_height }, .{ .min = 0, .max = 99 }, sheet.hp_temp);
    if (temp != sheet.hp_temp) append(hero.writeTemp(&line_buffer, @intCast(temp)));
    ly += row;

    // The bar: what is left, red when bloodied.
    const pct: u8 = if (sheet.hp_max == 0) 0 else @intCast(@min(@as(u32, sheet.hp_now) * 100 / sheet.hp_max, 100));
    ctx.progress(.{ .x = left.x, .y = ly, .w = left.w, .h = 8 }, pct, .{ .colour = if (sheet.bloodied()) t.warning else null });
    ly += 8 + gap;

    ctx.label(.{ .x = left.x, .y = ly, .w = 72, .h = t.control_height }, "Hit dice");
    const dice_n: usize = @max(sheet.level, 1);
    _ = ctx.pips(.{ .x = left.x + 76, .y = ly, .w = eui.pips.width(dice_n), .h = t.control_height }, dice_n, sheet.hit_dice_left);
    var die_word: [8]u8 = @splat(0);
    const die_x = left.x + 76 + eui.pips.width(dice_n) + gap;
    surface.picture(die_x, ly + 6, &die, t.text_dim);
    ctx.labelDim(.{ .x = die_x + 16, .y = ly, .w = 40, .h = t.control_height }, dieText(&die_word, sheet.hit_die));
    ly += row;

    eui.heading.paint(surface, right, "Death saves and conditions", &skull);
    var ry = right.y + eui.heading.height();
    ctx.label(.{ .x = right.x, .y = ry, .w = 78, .h = t.control_height }, "Successes");
    const ds = ctx.pips(.{ .x = right.x + 84, .y = ry, .w = eui.pips.width(3), .h = t.control_height }, 3, sheet.death_success);
    if (ds != sheet.death_success) deathSave(.success, ds, sheet.death_success);
    ry += row;
    ctx.label(.{ .x = right.x, .y = ry, .w = 78, .h = t.control_height }, "Failures");
    const df = ctx.pips(.{ .x = right.x + 84, .y = ry, .w = eui.pips.width(3), .h = t.control_height }, 3, sheet.death_failure);
    if (df != sheet.death_failure) deathSave(.failure, df, sheet.death_failure);
    ry += row;
    ctx.label(.{ .x = right.x, .y = ry, .w = 78, .h = t.control_height }, "Exhaustion");
    const ex = ctx.pips(.{ .x = right.x + 84, .y = ry, .w = eui.pips.width(6), .h = t.control_height }, 6, sheet.exhaustion);
    if (ex != sheet.exhaustion) append(hero.writeExhaustion(&line_buffer, @intCast(ex)));
    ry += row;

    // Conditions, each a toggle; bloodied is derived and only shown.
    var cx = right.x;
    if (sheet.bloodied()) {
        const w = eui.footer.buttonWidth("Bloodied");
        surface.fill(.{ .x = cx, .y = ry, .w = w, .h = t.control_height }, t.warning);
        surface.textCentred(.{ .x = cx, .y = ry, .w = w, .h = t.control_height }, "Bloodied", t.accent_text);
        cx += w + gap;
    }
    for (CONDITIONS) |name| {
        const w = eui.footer.buttonWidth(name);
        if (cx + w > right.right()) break;
        const on = sheet.hasCondition(name);
        if (ctx.toggle(.{ .x = cx, .y = ry, .w = w, .h = t.control_height }, name, on)) {
            append(hero.writeCondition(&line_buffer, name, hero.Switch.of(!on)));
        }
        cx += w + gap;
    }
    ry += row;

    // The attacks under both, and a roll on the one chosen.
    const y = @max(ly, ry) + gap;
    const table_area = Rect{ .x = area.x, .y = y, .w = area.w, .h = area.bottom() - y };
    if (attackRows()) |rows| {
        if (ctx.table(table_area, &attacks_table, &ATTACK_COLUMNS, rows)) |index| {
            askRoll(.{ .attack = index });
        }
    }
}

fn dieText(buf: []u8, faces: u8) []const u8 {
    return std.fmt.bufPrint(buf, "1d{d}", .{faces}) catch "";
}

/// A track filled further is that many saves of its kind; a track emptied is
/// the pair reset, since a save is never taken back one at a time.
fn deathSave(which: hero.DeathSave, now: usize, before: usize) void {
    if (now > before) {
        for (before..now) |_| append(hero.writeSave(&line_buffer, which));
    } else {
        append(hero.writeSave(&line_buffer, .reset));
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
    .{ .title = "Spell", .width = 150 },
    .{ .title = "Level", .width = 60 },
    .{ .title = "Time", .width = 72 },
    .{ .title = "Range", .width = 120 },
    .{ .title = "Notes", .width = 120, .flex = true },
};

var spell_cells: [hero.MAX_SPELLS][8]u8 = @splat(@splat(0));
var spell_rows: [hero.MAX_SPELLS]eui.table.Row = undefined;

fn drawSpells(area: Rect) void {
    const surface = ctx.surface;
    const t = theme.current();
    if (ctx.damaged) surface.fill(area, t.surface);

    // The casting line, and the slots as pips.
    surface.picture(area.x, area.y + 4, &spark, t.accent);
    var head: [96]u8 = @splat(0);
    var line = str.Builder{ .buf = &head };
    line.text(sheet.spell_ability.word());
    line.text(" \u{b7} DC ");
    line.number(@intCast(sheet.spellSaveDc()));
    line.text(" \u{b7} attack ");
    signedTight(&line, sheet.spellAttack());
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

fn drawGear(area: Rect) void {
    const surface = ctx.surface;
    const t = theme.current();
    if (ctx.damaged) surface.fill(area, t.surface);

    // The purse, and the two ways it changes.
    surface.picture(area.x, area.y + 4, &coin, 0xB8860B);
    var purse: [64]u8 = @splat(0);
    var line = str.Builder{ .buf = &purse };
    for (std.enums.values(hero.Coin)) |kind| {
        const amount = sheet.coins.get(kind);
        if (amount == 0) continue;
        if (line.len > 0) line.text("  ");
        line.number(@intCast(@max(amount, 0)));
        line.byte(' ');
        line.text(kind.word());
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
    facts[1] = .{ .label = "Capacity", .value = pounds(&fb[1], @as(u32, sheet.carryCapacity()) * 100) };
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

const JOURNAL_COLUMNS = [_]eui.table.Column{
    .{ .title = "Session", .width = 72 },
    .{ .title = "When", .width = 88 },
    .{ .title = "Entry", .width = 200, .flex = true },
};

/// The events, gathered once per pass from the file: which session and day
/// each belongs to, and what it says in words. Held here because the table
/// takes slices and they have to outlive the pass that built them.
const MAX_JOURNAL = 256;
var journal_rows: [MAX_JOURNAL]eui.table.Row = undefined;
var journal_rows_len: usize = 0;
var journal_words: [MAX_JOURNAL][72]u8 = undefined;
var journal_table: eui.table.State = .{ .striped = true };

fn drawJournal(area: Rect) void {
    const surface = ctx.surface;
    const t = theme.current();
    if (ctx.damaged) surface.fill(area, t.surface);

    gatherJournal();

    // The events newest first, and the strip to add one along the foot.
    const strip_h = t.control_height;
    const list_area = Rect{ .x = area.x, .y = area.y, .w = area.w, .h = area.h - strip_h - t.gap };
    _ = ctx.table(list_area, &journal_table, &JOURNAL_COLUMNS, journal_rows[0..journal_rows_len]);

    const strip_y = area.bottom() - strip_h;
    const note_w = eui.footer.buttonWidth("Note");
    const field = Rect{ .x = area.x, .y = strip_y, .w = area.w - note_w - t.gap, .h = strip_h };
    if (focus_note) {
        ctx.focusAt(field);
        focus_note = false;
    }
    if (eui.text.field(ctx, field, &note_editor, &note_doc)) addNote();
    if (ctx.buttonAs(.{ .x = area.right() - note_w, .y = strip_y, .w = note_w, .h = strip_h }, "Note", .strong)) addNote();
}

/// Walk the file once, forwards, so every event knows its session and day;
/// then lay the rows out newest first, naming the session and the day only
/// where they change, as a page of a diary does.
fn gatherJournal() void {
    var in_order: [MAX_JOURNAL]struct { session: []const u8, day: []const u8, text: []const u8 } = undefined;
    var n: usize = 0;
    var session: []const u8 = "";
    var day: []const u8 = "";

    var lines = std.mem.splitScalar(u8, storage[0..text_len], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or std.mem.eql(u8, line, hero.MAGIC)) continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const word = line[0..space];
        const rest = std.mem.trim(u8, line[space + 1 ..], " \t");
        const keyword = hero.Keyword.parse(word);
        if (keyword == .session) {
            session = hero.part(rest, 0);
            day = hero.part(rest, 1);
            continue;
        }
        if (keyword) |k| {
            if (k.isFact()) continue;
        }
        if (n == MAX_JOURNAL) break;
        in_order[n] = .{ .session = session, .day = day, .text = describe(keyword, word, rest, &journal_words[n]) };
        n += 1;
    }

    journal_rows_len = n;
    var shown_session: []const u8 = "";
    var shown_day: []const u8 = "";
    for (0..n) |i| {
        const event = in_order[n - 1 - i];
        var row = eui.table.Row{};
        row.cells[0] = if (std.mem.eql(u8, event.session, shown_session)) "" else event.session;
        row.cells[1] = if (std.mem.eql(u8, event.day, shown_day) and std.mem.eql(u8, event.session, shown_session)) "" else event.day;
        row.cells[2] = event.text;
        shown_session = event.session;
        shown_day = event.day;
        journal_rows[i] = row;
    }
}

/// An event as a person reads it, rather than as the file spells it. A word
/// the reader does not know is shown as it stands, which is what keeping it
/// as a note means.
fn describe(keyword: ?hero.Keyword, word: []const u8, rest: []const u8, buf: []u8) []const u8 {
    const first = hero.part(rest, 0);
    const second = hero.part(rest, 1);
    const k = keyword orelse return std.fmt.bufPrint(buf, "{s} {s}", .{ word, rest }) catch rest;
    return switch (k) {
        .note => rest,
        .damage => reason(buf, "Took {s} damage", .{first}, second),
        .heal => reason(buf, "Healed {s}", .{first}, second),
        .temp => std.fmt.bufPrint(buf, "{s} temporary hit points", .{first}) catch rest,
        .hitdie => std.fmt.bufPrint(buf, "Spent a hit die, healed {s}", .{first}) catch rest,
        .rest => if (std.meta.stringToEnum(hero.Rest, rest) == .long) "Long rest" else "Short rest",
        .cast => std.fmt.bufPrint(buf, "Cast {s}{s}", .{ second, if (std.mem.eql(u8, first, "0")) "" else ", a slot spent" }) catch rest,
        .@"innate-use" => "Innate Sorcery used",
        .save => std.fmt.bufPrint(buf, "Death save: {s}", .{rest}) catch rest,
        .condition => std.fmt.bufPrint(buf, "{s}{s}", .{ if (std.meta.stringToEnum(hero.Switch, second) == .off) "No longer " else "", first }) catch rest,
        .exhaustion => std.fmt.bufPrint(buf, "Exhaustion {s}", .{rest}) catch rest,
        .inspiration => if (std.meta.stringToEnum(hero.Switch, rest) == .on) "Heroic Inspiration gained" else "Heroic Inspiration spent",
        .gold => if (first.len > 0 and first[0] == '-')
            reason(buf, "Paid {s} gold", .{first[1..]}, second)
        else
            reason(buf, "Received {s} gold", .{first}, second),
        .roll => std.fmt.bufPrint(buf, "Rolled {s}: {s} {s}", .{ first, second, hero.part(rest, 2) }) catch rest,
        else => std.fmt.bufPrint(buf, "{s} {s}", .{ word, rest }) catch rest,
    };
}

/// A line, and the reason for it in brackets when one was written.
fn reason(buf: []u8, comptime form: []const u8, args: anytype, why: []const u8) []const u8 {
    const said = std.fmt.bufPrint(buf, form, args) catch return "";
    if (why.len == 0) return said;
    const more = std.fmt.bufPrint(buf[said.len..], " ({s})", .{why}) catch return said;
    return buf[0 .. said.len + more.len];
}

fn addNote() void {
    const text = std.mem.trim(u8, note_doc.slice(), " \t");
    if (text.len == 0) return;
    append(hero.writeNote(&line_buffer, text));
    note_doc.clear();
    note_editor = .{};
}

// ---------------------------------------------------------------------------
// Little formatters
// ---------------------------------------------------------------------------

fn intText(buf: []u8, value: i16) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "";
}

fn feet(buf: []u8, value: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d} ft.", .{value}) catch "";
}

fn levelLabel(buf: []u8, level: usize) []const u8 {
    return std.fmt.bufPrint(buf, "Level {d}", .{level}) catch "";
}

fn ofMax(buf: []u8, max: u16) []const u8 {
    return std.fmt.bufPrint(buf, "of {d}", .{max}) catch "";
}

fn pounds(buf: []u8, hundredths: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d:0>2} lb", .{ hundredths / 100, hundredths % 100 }) catch "";
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
        if (!sheet.save_prof.contains(a)) continue;
        if (line.len > 0) line.text(", ");
        line.text(a.word());
    }
    return if (line.len > 0) line.done() else "-";
}
