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
const file = @import("ulib").file;
const paths = @import("ulib").paths;
const out = @import("ulib").out;
const str = @import("lib").str;
const civil = @import("lib").civil;
const hero = @import("journal.zig");
const dice = @import("dice.zig");

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

/// The whole file, held at once: years of play at a line a moment, and the
/// portrait as one line of it. It is what Save writes and what every fold
/// reads.
const CAPACITY = 64 * 1024;

/// The portrait: the side of the square it is kept as, which is the size it
/// is drawn at; the JPEG quality it is kept at; and the most its file may
/// come to, which at this size and quality is a few kilobytes.
const PORTRAIT_SIDE = 64;
const PORTRAIT_QUALITY = 85;
const PORTRAIT_MAX = 8 * 1024;

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
/// The same for the other panes' tables: opened, a table takes the arrows
/// and Enter, so a skill is rolled, an attack made, a spell cast or an item
/// picked without reaching for the pointer.
var focus_table = false;

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
    focus_table = which != .journal;
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
/// Where a picture's bytes go before they are decoded, held here rather
/// than on the stack, which a picture would overflow: a portrait taken in
/// may be a photo of half a megabyte, and comes out a few kilobytes.
var picture_file: [512 * 1024]u8 = undefined;
/// The portrait on its way into the journal: the square it is shrunk to,
/// the writer's own bytes of it, the JPEG, and the line as it is written.
var portrait_pixels: [PORTRAIT_SIDE * PORTRAIT_SIDE]u32 = undefined;
var portrait_scratch: [PORTRAIT_SIDE * PORTRAIT_SIDE * 3]u8 = undefined;
var portrait_jpeg: [PORTRAIT_MAX]u8 = undefined;
var portrait_line: [PORTRAIT_HEAD.len + std.base64.standard.Encoder.calcSize(PORTRAIT_MAX)]u8 = undefined;
const PORTRAIT_HEAD = @tagName(hero.Keyword.portrait) ++ " ";

/// The dice window, opened by whatever asks for a roll.
var dice_window: dice.Window = .{};

/// How much of the journal was on the medium at the last load or save, so
/// what was written since can be taken back a line at a time.
var saved_len: usize = 0;

// ---------------------------------------------------------------------------
// The helpers: a question on the prompt sheet, and the line its answer writes
// ---------------------------------------------------------------------------

var prompt: eui.prompt.Prompt = .{};
var question_buffer: [96]u8 = @splat(0);

/// What the sheet is asking, so its answer knows which line to write. Some
/// carry the subject the question is about: which spell is cast, which fact
/// of the character the line sets.
const Helper = union(enum) {
    none,
    close,
    damage,
    heal,
    temp,
    hitdie,
    gold_pay,
    gold_get,
    rest,
    cast: usize,
    fact: Form,
    new_character,
    level_up,
};

/// What a roll is for, which is what fills the dice window in.
const RollWhat = union(enum) {
    skill: hero.Skill,
    save: hero.Ability,
    attack: usize,
    damage: usize,
    death,
    plain,
    free,

    fn label(self: RollWhat, buf: []u8) []const u8 {
        return switch (self) {
            .skill => |s| std.fmt.bufPrint(buf, "{s} check", .{s.word()}) catch s.word(),
            .save => |a| std.fmt.bufPrint(buf, "{s} save", .{a.word()}) catch a.word(),
            .attack => |i| attackName(i),
            .damage => |i| std.fmt.bufPrint(buf, "{s} damage", .{attackName(i)}) catch "Damage",
            .death => "Death save",
            .plain => "d20",
            .free => "Dice",
        };
    }

    fn modifier(self: RollWhat) i16 {
        const bonus: i16 = switch (self) {
            .skill => |s| sheet.skillBonus(s),
            .save => |a| sheet.saveBonus(a),
            .attack => |i| attackBonus(i),
            .damage => |i| if (hero.Dice.parse(attackDamage(i))) |d| d.bonus else 0,
            .death, .plain, .free => 0,
        };
        return if (self.isTest()) bonus + sheet.exhaustionPenalty() else bonus;
    }

    /// A d20 test, which exhaustion and the conditions weigh on.
    fn isTest(self: RollWhat) bool {
        return switch (self) {
            .skill, .save, .attack, .death, .plain => true,
            .damage, .free => false,
        };
    }

    /// A condition on the sheet that sets the mode before the window opens:
    /// poisoned and frightened weigh on checks and attacks, prone on attacks,
    /// and none of them on a save.
    fn hindrance(self: RollWhat) ?[]const u8 {
        const names: []const []const u8 = switch (self) {
            .skill, .plain => &.{ "Poisoned", "Frightened" },
            .attack => &.{ "Poisoned", "Frightened", "Prone" },
            .save, .death, .damage, .free => &.{},
        };
        for (names) |name| {
            if (sheet.hasCondition(name)) return name;
        }
        return null;
    }
};

/// The pane's table takes the keyboard on the first pass after the pane
/// opens, and not again, so a click elsewhere is not undone.
fn takeFocus(area: Rect) void {
    if (!focus_table) return;
    ctx.focusAt(area);
    focus_table = false;
}

fn attackName(index: usize) []const u8 {
    return if (index < sheet.attacks.len) sheet.attacks.slice()[index].name else "Attack";
}

fn attackDamage(index: usize) []const u8 {
    return if (index < sheet.attacks.len) sheet.attacks.slice()[index].damage else "";
}

fn attackHit(index: usize) []const u8 {
    return if (index < sheet.attacks.len) sheet.attacks.slice()[index].hit else "+0";
}

var pending: Helper = .none;

/// What the menus and their shortcuts ask for. The Character menu's facts
/// are a `Form` each, told apart from these by `MenuId`.
const Command = enum(u15) {
    new,
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
    use_one,
    drop_selected,
    inspiration,
    innate_use,
    stop_concentrating,
    level_up,
    new_session,
    note,
    undo,
    roll_check,
    roll_attack,
    roll_damage,
    roll_death,
    roll_free,
    rest,
    long_rest,
    short_rest,
    status_bar,
};

/// A menu id: a command, or a form of the Character menu, told apart by a
/// bit. A command's own number is its id, so the menus name them with
/// `@intFromEnum` and the bit stays clear.
const MenuId = packed struct(u16) {
    index: u15,
    form: bool = false,

    fn of(form: Form) u16 {
        return @bitCast(MenuId{ .index = @intFromEnum(form), .form = true });
    }

    /// What a chosen id asks for.
    fn dispatch(id: u16) void {
        const menu_id: MenuId = @bitCast(id);
        if (menu_id.form) askFact(@enumFromInt(menu_id.index)) else runCommand(@enumFromInt(menu_id.index));
    }
};

/// The Character menu: a new character, then one item per fact the sheet is
/// built from, in the order a sheet reads them. Built from the forms so a
/// form added turns up here without being listed twice.
const CHARACTER_ITEMS = blk: {
    var items: [MENU_FORMS.len + 2]eui.menubar.Item = undefined;
    items[0] = .{ .label = "New character...", .id = @intFromEnum(Command.new) };
    items[1] = eui.menubar.Item.separator;
    for (MENU_FORMS, 0..) |form, i| items[i + 2] = .{ .label = form.question() ++ "...", .id = MenuId.of(form) };
    break :blk items;
};

comptime {
    std.debug.assert(CHARACTER_ITEMS.len <= eui.menubar.MAX_ITEMS);
}

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
        .{ .label = "Use one of the item", .id = @intFromEnum(Command.use_one) },
        .{ .label = "Drop the selected", .id = @intFromEnum(Command.drop_selected) },
        eui.menubar.Item.separator,
        .{ .label = "Heroic Inspiration", .id = @intFromEnum(Command.inspiration) },
        .{ .label = "Use the innate feature", .id = @intFromEnum(Command.innate_use) },
        .{ .label = "Stop concentrating", .id = @intFromEnum(Command.stop_concentrating) },
        .{ .label = "Level up...", .id = @intFromEnum(Command.level_up) },
        eui.menubar.Item.separator,
        .{ .label = "New session", .id = @intFromEnum(Command.new_session) },
        .{ .label = "Note", .id = @intFromEnum(Command.note), .shortcut = "Ctrl+N" },
        .{ .label = "Take back the last line", .id = @intFromEnum(Command.undo), .shortcut = "Ctrl+Z" },
    } },
    .{ .label = "Character", .items = &CHARACTER_ITEMS },
    .{ .label = "Roll", .items = &.{
        .{ .label = "Skill check...", .id = @intFromEnum(Command.roll_check), .shortcut = "Ctrl+R" },
        .{ .label = "Attack...", .id = @intFromEnum(Command.roll_attack) },
        .{ .label = "Damage...", .id = @intFromEnum(Command.roll_damage) },
        .{ .label = "Death save...", .id = @intFromEnum(Command.roll_death) },
        .{ .label = "Dice...", .id = @intFromEnum(Command.roll_free) },
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

/// A fact of the character as a line of a question: what to ask, which
/// keywords the answer sets, and how the answer splits between them. One
/// form asks for what one line of the sheet says, so a character is built
/// in the order its sheet reads, and corrected the same way.
const Form = enum {
    name,
    class_level,
    origin,
    player,
    portrait,
    scores,
    saves,
    skills,
    hp_die,
    ac_speed,
    casting,
    innate,
    training,
    coins,
    attack,
    spell,
    item,
    feature,

    /// The question on the sheet, which is also the menu's word for it.
    fn question(self: Form) []const u8 {
        return switch (self) {
            .name => "Name",
            .class_level => "Class and level",
            .origin => "Origin",
            .player => "Player",
            .portrait => "Portrait",
            .scores => "Ability scores",
            .saves => "Saving throws",
            .skills => "Skills and expertise",
            .hp_die => "Hit points and die",
            .ac_speed => "Armour class and speed",
            .casting => "Spellcasting and slots",
            .innate => "Innate feature",
            .training => "Training",
            .coins => "Coins",
            .attack => "New attack",
            .spell => "New spell",
            .item => "New item",
            .feature => "New feature",
        };
    }

    /// The shape of the line, shown in the field while it is empty: the
    /// parts in the order they are typed.
    fn hint(self: Form) []const u8 {
        return switch (self) {
            .name => "cinaed I",
            .class_level => "Sorcerer | 1",
            .origin => "Species | background | alignment | size",
            .player => "Who plays this character",
            .portrait => "A picture file",
            .scores => "Str Dex Con Int Wis Cha, as six numbers",
            .saves => "By key: str dex con int wis cha",
            .skills => "Skills | expertise, by key: stealth sleight_of_hand | stealth",
            .hp_die => "Hit points | hit die, like 8 | d6",
            .ac_speed => "Armour class | speed, like 12 | 30",
            .casting => "Ability | slots by level, like cha | 2 0 0 0 0 0 0 0 0",
            .innate => "Uses | name, like 2 | Innate Sorcery",
            .training => "Weapons | tools | languages | armour",
            .coins => "cp sp ep gp pp, as five numbers",
            .attack => "Name | to hit | damage | notes",
            .spell => "Name | level | time | range | notes",
            .item => "Name | quantity | weight of one",
            .feature => "Name | note",
        };
    }

    /// The keywords the parts set, one each; a single keyword takes the
    /// whole line.
    fn keywords(self: Form) []const hero.Keyword {
        return switch (self) {
            .name => &.{.name},
            .class_level => &.{ .class, .level },
            .origin => &.{ .species, .background, .alignment, .size },
            .player => &.{.player},
            .portrait => &.{.portrait},
            .scores => &.{ .str, .dex, .con, .int, .wis, .cha },
            .saves => &.{.saves},
            .skills => &.{ .skills, .expertise },
            .hp_die => &.{ .hp, .@"hit-die" },
            .ac_speed => &.{ .ac, .speed },
            .casting => &.{ .spellcasting, .slots },
            .innate => &.{.innate},
            .training => &.{ .weapons, .tools, .languages, .armour },
            .coins => &.{.coins},
            .attack => &.{.attack},
            .spell => &.{.spell},
            .item => &.{.item},
            .feature => &.{.feature},
        };
    }

    /// Whether the parts are words rather than ` | ` pieces.
    fn byWords(self: Form) bool {
        return self == .scores;
    }
};

/// The forms the Character menu lists: the facts, in a sheet's order. The
/// four that add a row live on their panes, beside the rows they add to.
const MENU_FORMS = [_]Form{ .name, .class_level, .origin, .player, .portrait, .scores, .saves, .skills, .hp_die, .ac_speed, .casting, .innate, .training, .coins };

/// What View turns off. On to start with.
var show_status = true;

// The file dialog, and what it is being asked for.
var dialog: proto.FileDialog = .{};
var asking_file: FileAsk = .open;

/// The three things a file is chosen for, each with its own words across
/// the dialog.
const FileAsk = enum {
    open,
    save,
    portrait,

    fn purpose(self: FileAsk) proto.dialog.Purpose {
        return switch (self) {
            .open, .portrait => .open,
            .save => .save,
        };
    }

    fn heading(self: FileAsk) []const u8 {
        return switch (self) {
            .open => "Open a character journal",
            .save => "Save the journal as",
            .portrait => "A picture for the portrait",
        };
    }
};

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
        // The dice from the shell, the same dice the window throws:
        // `hero --roll 2d6+3`, or `hero --roll d20 advantage`.
        if (std.mem.eql(u8, wanted, "--roll")) rollFromShell(env.arg(frame, 2) orelse "d20", env.arg(frame, 3));
        setPath(wanted);
        load();
    }

    proto.app.run("hero", "Hero", 520, 380, .{
        .draw = draw,
        .key = key,
        .text = typed,
        .event = ownWindows,
        .close = mayClose,
    });
}

/// A roll printed and done: what fell, the bonus, and the total on one line.
fn rollFromShell(notation: []const u8, mode_word: ?[]const u8) noreturn {
    const d = hero.Dice.parse(notation) orelse {
        out.text("hero: dice are written like 2d6+3, or d20\n");
        out.flush();
        sys.exit(1);
    };
    const mode: hero.Roll = if (mode_word) |w| std.meta.stringToEnum(hero.Roll, w) orelse .normal else .normal;
    var line_buf: [160]u8 = @splat(0);
    var line = str.Builder{ .buf = &line_buf };
    line.text(notation);
    line.text(": ");
    var total: i32 = d.bonus;
    if (d.faces == 20 and d.count == 1 and mode != .normal) {
        const a = dice.rollDie(20);
        const b = dice.rollDie(20);
        const kept = if (mode == .advantage) @max(a, b) else @min(a, b);
        line.number(a);
        line.text(" and ");
        line.number(b);
        line.text(", kept ");
        line.number(kept);
        total += kept;
    } else {
        for (0..@min(d.count, dice.MAX_DICE)) |i| {
            const fell = dice.rollDie(d.faces);
            if (i > 0) line.text(" + ");
            line.number(fell);
            total += fell;
        }
    }
    if (d.bonus != 0) {
        line.text(if (d.bonus < 0) " - " else " + ");
        line.number(@abs(d.bonus));
    }
    line.text(" = ");
    line.number(@intCast(@max(total, 0)));
    line.byte('\n');
    out.text(line.done());
    out.flush();
    sys.exit(0);
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
    return paths.base(path());
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
    saved_len = text_len;
    modified = false;
    asked_at_start = true;
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

    saved_len = text_len;
    modified = false;
    say("Saved.");
    setTitle();
}

fn refold() void {
    sheet = hero.fold(storage[0..text_len]);
}

/// Add one journal line and read the file back. The screen is the fold, so
/// nothing shows until the line is in the file. A moment of play on a day
/// the journal has not seen gets a session heading first, so the journal
/// reads by session without anyone having to remember to start one.
fn append(line: []const u8) void {
    if (line.len == 0) return;
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    if (hero.Keyword.parse(line[0..space])) |k| {
        if (!k.isFact() and k != .session) ensureSession();
    }
    appendLine(line);
}

fn appendLine(line: []const u8) void {
    if (line.len == 0) return;
    // An empty journal starts with its magic line, whatever is written first.
    if (text_len == 0 and !std.mem.eql(u8, line, hero.MAGIC)) {
        @memcpy(storage[0..hero.MAGIC.len], hero.MAGIC);
        text_len = hero.MAGIC.len;
    }
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

/// The headshot: the journal's own portrait line, decoded; or, for a journal
/// without one, a picture file it names beside itself.
fn loadHeadshot() void {
    if (sheet.portrait.len > 0) {
        forgetHeadshot();
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(sheet.portrait) catch return;
        if (size > picture_file.len) return;
        decoder.decode(picture_file[0..size], sheet.portrait) catch return;
        headshot = img.decode(picture_file[0..size]) catch null;
        return;
    }

    const picture = sheet.picture;
    if (picture.len == 0) {
        forgetHeadshot();
        return;
    }
    var full_buf: [192]u8 = @splat(0);
    const full = resolve(picture, &full_buf);
    if (std.mem.eql(u8, full, headshot_of[0..headshot_of_len])) return;

    forgetHeadshot();
    const read = file.readWhole(full, &picture_file) orelse return;
    headshot = img.decode(picture_file[0..read]) catch null;
    if (headshot != null) {
        headshot_of_len = @min(full.len, headshot_of.len);
        @memcpy(headshot_of[0..headshot_of_len], full[0..headshot_of_len]);
    }
}

/// Take a picture into the journal: read the file, decode it, cut the
/// square from its middle and shrink that to the size it is drawn at, keep
/// it as a small JPEG, and write it as one `portrait` line, so the journal
/// carries its own face wherever it goes. `-` takes the portrait away.
fn importPortrait(name: []const u8) void {
    if (std.mem.eql(u8, name, "-")) {
        append(hero.writeFact(&line_buffer, .portrait, "-"));
        loadHeadshot();
        return;
    }
    var full_buf: [192]u8 = @splat(0);
    const full = resolve(name, &full_buf);
    const read = file.readWhole(full, &picture_file) orelse {
        say("No such picture.");
        return;
    };
    if (read == picture_file.len) {
        say("Too big: a picture of up to half a megabyte.");
        return;
    }
    const picture = img.decode(picture_file[0..read]) catch {
        say("Not a picture the machine can read.");
        return;
    };
    defer picture.deinit();

    const square = img.squareOf(picture, PORTRAIT_SIDE, &portrait_pixels);
    const jpeg = img.encodeJpeg(square, PORTRAIT_QUALITY, &portrait_scratch, &portrait_jpeg) catch {
        say("Could not keep a small picture of it.");
        return;
    };
    @memcpy(portrait_line[0..PORTRAIT_HEAD.len], PORTRAIT_HEAD);
    const encoded = std.base64.standard.Encoder.encode(portrait_line[PORTRAIT_HEAD.len..], jpeg);
    append(portrait_line[0 .. PORTRAIT_HEAD.len + encoded.len]);
    loadHeadshot();
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
    return paths.join(paths.parent(path()), picture, buf);
}

// ---------------------------------------------------------------------------
// Keys and the close question
// ---------------------------------------------------------------------------

fn key(code: proto.app.KeyCode, mods: proto.app.Modifiers) bool {
    if (prompt.isOpen()) {
        if (eui.prompt.key(&prompt, code)) |choice| {
            answer(choice);
            return true;
        }
        // A question with a field in it keeps the other keys for the field.
        return !prompt.takesText();
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
            MenuId.dispatch(id);
            break :blk true;
        },
    };
}

fn typed(codepoint: u32) bool {
    if (!prompt.isOpen() or prompt.takesText()) return false;
    if (eui.prompt.letter(&prompt, codepoint)) |choice| answer(choice);
    return true;
}

/// The file dialog's events are its own, and the dice window's are its own:
/// what the dice hand back is written down here.
fn ownWindows(event: proto.wm.Ev) bool {
    if (dialog.owns(event)) {
        if (dialog.handle(connection, event)) finishFile();
        return true;
    }
    if (dice_window.owns(event)) {
        dice_window.handle(connection, event);
        if (dice_window.take()) |outcome| recordRoll(outcome);
        switch (dice_window.wish) {
            .nothing => {},
            .close => dice_window.hide(connection),
            .damage => askRoll(.{ .damage = rolling_attack }),
        }
        return true;
    }
    return false;
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

comptime {
    std.debug.assert(CLOSE_CHOICES.len == std.enums.values(CloseChoice).len);
    std.debug.assert(REST_CHOICES.len == std.enums.values(RestChoice).len);
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn runCommand(command: Command) void {
    switch (command) {
        .new => askNewCharacter(),
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
        .use_one => useOne(),
        .drop_selected => dropSelected(),
        .inspiration => append(hero.writeInspiration(&line_buffer, hero.Switch.of(!sheet.inspiration))),
        .innate_use => useInnate(),
        .stop_concentrating => if (sheet.concentration.len > 0) append(hero.writeConcentrate(&line_buffer, "")) else say("Not concentrating on anything."),
        .level_up => askLevelUp(),
        .new_session => newSession(),
        .note => setSection(.journal),
        .undo => undo(),
        .roll_check => askRoll(.{ .skill = @enumFromInt(@min(skills_table.selected, std.enums.values(hero.Skill).len - 1)) }),
        .roll_attack => if (sheet.attacks.len > 0) askRoll(.{ .attack = @min(attacks_table.selected, sheet.attacks.len - 1) }) else say("No attacks written."),
        .roll_damage => if (sheet.attacks.len > 0) askRoll(.{ .damage = @min(attacks_table.selected, sheet.attacks.len - 1) }) else say("No attacks written."),
        .roll_death => askRoll(.death),
        .roll_free => askRoll(.free),
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
    const rolled: i32 = @intCast(dice.rollDie(sheet.hit_die));
    const healed = @max(1, rolled + sheet.modifier(.con));
    askAmount(.hitdie, "The hit die heals how much?", healed, sheet.hit_die + 10);
}

var line_buffer: [256]u8 = @splat(0);

fn newSession() void {
    const number = sessionCount() + 1;
    var date_buf: [16]u8 = @splat(0);
    const date = today(&date_buf);
    appendLine(hero.writeSession(&line_buffer, number, date));
}

/// A session heading for today, unless the last heading is today's already.
/// Without a clock there is no today, and the headings are a person's to
/// write.
fn ensureSession() void {
    var date_buf: [16]u8 = @splat(0);
    const day = today(&date_buf);
    if (day.len == 0 or std.mem.eql(u8, day, lastSessionDay())) return;
    var line: [32]u8 = @splat(0);
    appendLine(hero.writeSession(&line, sessionCount() + 1, day));
}

/// The day the last session heading names, or nothing.
fn lastSessionDay() []const u8 {
    var day: []const u8 = "";
    var lines = std.mem.splitScalar(u8, storage[0..text_len], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (hero.Keyword.parse(line[0..space]) == .session) day = hero.part(std.mem.trim(u8, line[space + 1 ..], " \t"), 1);
    }
    return day;
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
    // The line typed, copied out before the question is dismissed with it.
    var typed_buf: [eui.prompt.TEXT_MAX]u8 = undefined;
    const typed_raw = prompt.line();
    @memcpy(typed_buf[0..typed_raw.len], typed_raw);
    const line = std.mem.trim(u8, typed_buf[0..typed_raw.len], " \t");
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
        .fact => |form| if (choice == 0) applyFact(form, line),
        .new_character => if (choice == 0) newCharacter(line),
        .level_up => if (choice == 0) levelUp(number),
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

// ---------------------------------------------------------------------------
// Rolling: the dice window, filled in by what asked
// ---------------------------------------------------------------------------

/// What the window was opened for, so what falls is written as that: a
/// death save is marked from its die, and an attack's Damage button knows
/// whose damage.
var rolling: RollWhat = .plain;
var rolling_attack: usize = 0;
var roll_title: [48]u8 = @splat(0);
var roll_sub: [96]u8 = @splat(0);

/// Open the dice over the sheet, filled in: the words, the dice, the bonus,
/// and disadvantage when a condition on the sheet gives it.
fn askRoll(what: RollWhat) void {
    var setup = dice.Setup{ .title = what.label(&roll_title), .bonus = what.modifier() };
    var sub = str.Builder{ .buf = &roll_sub };
    switch (what) {
        .skill => |s| {
            sub.text(s.ability().word());
            sub.byte(' ');
            sub.signed(sheet.modifier(s.ability()));
            if (sheet.skill_expert.contains(s)) {
                sub.text(" \u{b7} expert +");
                sub.number(@intCast(sheet.proficiency() * 2));
            } else if (sheet.skill_prof.contains(s)) {
                sub.text(" \u{b7} proficient +");
                sub.number(@intCast(sheet.proficiency()));
            }
        },
        .save => |a| {
            sub.text(a.word());
            sub.byte(' ');
            sub.signed(sheet.modifier(a));
            if (sheet.save_prof.contains(a)) {
                sub.text(" \u{b7} proficient +");
                sub.number(@intCast(sheet.proficiency()));
            }
        },
        .attack => |i| {
            rolling_attack = i;
            setup.attack = true;
            sub.text(attackHit(i));
            sub.text(" to hit \u{b7} ");
            sub.text(attackDamage(i));
        },
        .damage => |i| {
            const d = hero.Dice.parse(attackDamage(i)) orelse {
                say("No dice on the attack line.");
                return;
            };
            setup.face = dice.Face.of(d.faces) orelse .d6;
            setup.count = d.count;
            sub.text(attackDamage(i));
            sub.text(" \u{b7} from the attack line");
        },
        .death => {
            if (!sheet.down()) {
                say("Death saves are rolled at no hit points.");
                return;
            }
            if (sheet.dead()) {
                say("Three failures already.");
                return;
            }
            if (sheet.stable()) {
                say("Stable already.");
                return;
            }
            sub.text("Ten or more succeeds \u{b7} a 1 fails twice \u{b7} a 20 heals");
        },
        .plain => sub.text("A bare d20"),
        .free => sub.text("Any dice, any number, any bonus"),
    }
    rolling = what;
    if (what.isTest() and sheet.exhaustion > 0) {
        sub.text(" \u{b7} exhaustion ");
        sub.signed(sheet.exhaustionPenalty());
    }
    if (what.hindrance()) |name| {
        setup.mode = .disadvantage;
        sub.text(" \u{b7} disadvantage: ");
        sub.text(name);
    }
    setup.sub = sub.done();
    dice_window.glyph = &die;
    dice_window.show(connection, setup) catch say("Cannot open the dice.");
}

/// Write what fell: a d20 test as the `roll` line the file has always had,
/// a handful as a `dice` line, and say the total on the status bar.
fn recordRoll(outcome: dice.Outcome) void {
    var fallen: [32]u8 = @splat(0);
    if (outcome.isTest()) {
        append(hero.writeRoll(&line_buffer, outcome.title, outcome.die(), outcome.bonus, outcome.mode));
    } else {
        const d = hero.Dice{ .count = outcome.count, .faces = outcome.face.faces(), .bonus = outcome.bonus };
        append(hero.writeDice(&line_buffer, outcome.title, d, outcome.fallen(&fallen), outcome.total));
    }
    if (rolling == .death and outcome.isTest()) {
        markDeathSave(outcome.die(), outcome.total);
        return;
    }
    var line = str.Builder{ .buf = &status_buffer };
    line.text(outcome.title);
    line.text(": ");
    line.number(@intCast(@max(outcome.total, 0)));
    status = line.done();
}

/// What a death save came to: ten or more is a success, less a failure, a
/// 1 on the die two failures, and a 20 a hit point back, which ends the
/// dying.
fn markDeathSave(fell: u8, total: i32) void {
    const said: []const u8 = if (fell == 20) blk: {
        append(hero.writeHeal(&line_buffer, 1, "a 20 on a death save"));
        break :blk "Death save: a 20, back on one hit point";
    } else if (fell == 1) blk: {
        append(hero.writeSave(&line_buffer, .failure));
        append(hero.writeSave(&line_buffer, .failure));
        break :blk "Death save: a 1, two failures";
    } else if (total >= 10) blk: {
        append(hero.writeSave(&line_buffer, .success));
        break :blk if (sheet.stable()) "Death save: success, and stable" else "Death save: success";
    } else blk: {
        append(hero.writeSave(&line_buffer, .failure));
        break :blk if (sheet.dead()) "Death save: failure, the third" else "Death save: failure";
    };
    say(said);
}

/// The attack line's bonus, `+4`, as a number: nothing where it is not one.
fn attackBonus(index: usize) i16 {
    if (index >= sheet.attacks.len) return 0;
    return std.fmt.parseInt(i16, sheet.attacks.slice()[index].hit, 10) catch 0;
}

/// A bonus into a buffer, `+7` or `-2`, for a table cell or a tile.
fn signedText(buf: []u8, value: anytype) []const u8 {
    var line = str.Builder{ .buf = buf };
    line.signed(value);
    return line.done();
}

// ---------------------------------------------------------------------------
// The facts: what the character is, asked for a line at a time
// ---------------------------------------------------------------------------

const LINE_CHOICES = [_]eui.prompt.Choice{
    .{ .label = "OK", .weight = .strong },
    .{ .label = "Cancel" },
};

var initial_buffer: [eui.prompt.TEXT_MAX]u8 = @splat(0);

fn askFact(form: Form) void {
    // The portrait is a file to pick rather than a line to type.
    if (form == .portrait) {
        askFile(.portrait);
        return;
    }
    pending = .{ .fact = form };
    prompt.askText(form.question(), &LINE_CHOICES, .{ .initial = initialOf(form, &initial_buffer), .hint = form.hint() });
    ctx.damage();
}

/// What the sheet says now, as the line the form takes, so a change is an
/// edit of what is there rather than a retyping of it.
fn initialOf(form: Form, buf: []u8) []const u8 {
    var line = str.Builder{ .buf = buf };
    switch (form) {
        .name => line.text(sheet.name),
        // A fact not yet set leaves the field empty, so the hint shows the
        // shape rather than a line of nothing.
        .class_level => if (sheet.class.len > 0) {
            line.text(sheet.class);
            line.text(" | ");
            line.number(sheet.level);
        },
        .origin => joinParts(&line, &.{ sheet.species, sheet.background, sheet.alignment, sheet.size }),
        .player => line.text(sheet.player),
        // The portrait's bytes are not a line to edit: the field takes a
        // file to read them from.
        .portrait => {},
        .scores => for (std.enums.values(hero.Ability), 0..) |a, i| {
            if (i > 0) line.byte(' ');
            line.number(sheet.scores.get(a));
        },
        .saves => for (std.enums.values(hero.Ability)) |a| {
            if (!sheet.save_prof.contains(a)) continue;
            if (line.len > 0) line.byte(' ');
            line.text(a.key());
        },
        .skills => {
            for (std.enums.values(hero.Skill)) |sk| {
                if (!sheet.skill_prof.contains(sk)) continue;
                if (line.len > 0) line.byte(' ');
                line.text(sk.key());
            }
            line.text(" |");
            for (std.enums.values(hero.Skill)) |sk| {
                if (!sheet.skill_expert.contains(sk)) continue;
                line.byte(' ');
                line.text(sk.key());
            }
        },
        .hp_die => if (sheet.hp_max > 0) {
            line.number(sheet.hp_max);
            line.text(" | d");
            line.number(sheet.hit_die);
        },
        .ac_speed => {
            line.number(sheet.ac);
            line.text(" | ");
            line.number(sheet.speed);
        },
        .casting => {
            line.text(sheet.spell_ability.key());
            line.text(" |");
            for (sheet.slots_max) |n| {
                line.byte(' ');
                line.number(n);
            }
        },
        .innate => if (sheet.innate_max > 0) {
            line.number(sheet.innate_max);
            line.text(" | ");
            line.text(sheet.innate_name);
        },
        .training => joinParts(&line, &.{ sheet.weapons, sheet.tools, sheet.languages, sheet.armour }),
        .coins => for (std.enums.values(hero.Coin), 0..) |c, i| {
            if (i > 0) line.byte(' ');
            line.number(@intCast(@max(sheet.coins.get(c), 0)));
        },
        .attack, .spell, .item, .feature => {},
    }
    return line.done();
}

fn joinParts(line: *str.Builder, parts: []const []const u8) void {
    for (parts, 0..) |piece, i| {
        if (i > 0) line.text(" | ");
        line.text(piece);
    }
}

/// The answer to a form: one fact line per keyword, from the part of the
/// line that is its; an empty part leaves what the sheet had.
fn applyFact(form: Form, line: []const u8) void {
    if (form == .portrait) {
        if (line.len > 0) importPortrait(line);
        return;
    }
    const keywords = form.keywords();
    if (keywords.len == 1) {
        if (line.len == 0) return;
        writeChecked(keywords[0], line);
    } else if (form.byWords()) {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        for (keywords) |k| {
            const word = words.next() orelse break;
            writeChecked(k, word);
        }
    } else {
        for (keywords, 0..) |k, i| {
            const piece = hero.part(line, i);
            if (piece.len == 0) continue;
            writeChecked(k, piece);
        }
    }
}

/// One fact line, unless the keyword takes a number and this is not one.
fn writeChecked(keyword: hero.Keyword, piece: []const u8) void {
    if (keyword.takesNumber()) {
        _ = std.fmt.parseInt(u16, piece, 10) catch {
            var line = str.Builder{ .buf = &status_buffer };
            line.text("Not a number: ");
            line.text(piece[0..@min(piece.len, 40)]);
            say(line.done());
            return;
        };
    }
    append(hero.writeFact(&line_buffer, keyword, piece));
}

/// An `Add...` button at the right end of a heading or a line, which asks
/// for the row it adds.
fn addButton(row: Rect, form: Form) void {
    const w = eui.footer.buttonWidth("Add...");
    if (ctx.button(.{ .x = row.right() - w, .y = row.y, .w = w, .h = row.h }, "Add...")) askFact(form);
}

fn askNewCharacter() void {
    if (modified) {
        say("Save or take back the changes first.");
        return;
    }
    pending = .new_character;
    prompt.askText("The new character's name", &LINE_CHOICES, .{ .hint = "cinaed I" });
    ctx.damage();
}

/// A fresh journal in memory: the magic line and the name. Where it lives
/// is asked at the first save.
fn newCharacter(name: []const u8) void {
    if (name.len == 0) return;
    text_len = 0;
    file_len = 0;
    forgetHeadshot();
    appendLine(hero.writeFact(&line_buffer, .name, name));
    saved_len = 0;
    modified = true;
    asked_at_start = true;
    setSection(.sheet);
    say("Now the facts, then save.");
}

/// A level gained: the number, and the new maximum, offered as the die's
/// average plus Constitution and corrected by hand where a die was rolled.
fn askLevelUp() void {
    var q = str.Builder{ .buf = &question_buffer };
    q.text("Hit points at level ");
    q.number(sheet.level + 1);
    q.byte('?');
    const gain: i32 = @divTrunc(@as(i32, sheet.hit_die), 2) + 1 + sheet.modifier(.con);
    ask(.level_up, q.done(), &AMOUNT_CHOICES, amountOf(@as(i32, sheet.hp_max) + @max(gain, 1), 1, 999));
}

fn levelUp(hp: i32) void {
    var level_text: [4]u8 = @splat(0);
    append(hero.writeFact(&line_buffer, .level, str.number(&level_text, sheet.level + 1, 10, .lower)));
    var hp_text: [6]u8 = @splat(0);
    append(hero.writeFact(&line_buffer, .hp, str.number(&hp_text, @intCast(@max(hp, 1)), 10, .lower)));
}

/// Take back the last line written since the last save. Nothing on the
/// medium is touched: what was saved is history, and history is not edited.
fn undo() void {
    if (text_len <= saved_len) {
        say("Nothing to take back.");
        return;
    }
    var end = text_len;
    if (storage[end - 1] == '\n') end -= 1;
    const start = if (std.mem.lastIndexOfScalar(u8, storage[0..end], '\n')) |at| at + 1 else 0;
    if (start < saved_len) {
        say("Nothing to take back.");
        return;
    }
    // The line's first word is what it was: a roll, a note, a fact. The
    // whole line would not fit the status bar's cell.
    const gone = storage[start..end];
    const word_end = std.mem.indexOfScalar(u8, gone, ' ') orelse gone.len;
    var word: [24]u8 = @splat(0);
    const n = @min(word_end, word.len);
    @memcpy(word[0..n], gone[0..n]);
    text_len = start;
    refold();
    loadHeadshot();
    modified = text_len != saved_len;
    setTitle();
    var line = str.Builder{ .buf = &status_buffer };
    line.text("Took back the ");
    line.text(word[0..n]);
    line.text(" line");
    status = line.done();
    ctx.damage();
}

const Dropping = struct { kind: hero.Keyword, name: []const u8 };

/// The selected row of the pane leaves the sheet: an attack, a spell, an
/// item, by name.
fn dropSelected() void {
    const dropping: ?Dropping = switch (section) {
        .combat => if (sheet.attacks.len > 0) .{ .kind = .attack, .name = attackName(@min(attacks_table.selected, sheet.attacks.len - 1)) } else null,
        .spells => if (sheet.spells.len > 0) .{ .kind = .spell, .name = sheet.spells.slice()[@min(spells_table.selected, sheet.spells.len - 1)].name } else null,
        .gear => if (sheet.items.len > 0) .{ .kind = .item, .name = sheet.items.slice()[@min(items_table.selected, sheet.items.len - 1)].name } else null,
        else => null,
    };
    const it = dropping orelse {
        say("Select an attack, a spell or an item to drop.");
        return;
    };
    append(hero.writeDrop(&line_buffer, it.kind, it.name));
}

/// One of the selected item used up: a ration eaten, an arrow shot. The
/// last one is the item gone.
fn useOne() void {
    if (section != .gear or sheet.items.len == 0) {
        say("Select an item on the Gear pane.");
        return;
    }
    const it = sheet.items.slice()[@min(items_table.selected, sheet.items.len - 1)];
    var line = str.Builder{ .buf = &question_buffer };
    line.text(it.name);
    line.text(" | ");
    line.number(it.quantity - 1);
    line.text(" | ");
    line.hundredths(it.weight_cp);
    append(hero.writeFact(&line_buffer, .item, line.done()));
}

fn useInnate() void {
    if (sheet.innate_max == 0) {
        say("No innate feature written.");
        return;
    }
    if (sheet.innate_left == 0) {
        say("None left until a long rest.");
        return;
    }
    append(hero.writeInnate(&line_buffer));
}

// ---------------------------------------------------------------------------
// Dialog and title
// ---------------------------------------------------------------------------

fn askFile(what: FileAsk) void {
    asking_file = what;
    const start: []const u8 = if (what == .portrait) "" else baseName();
    dialog.show(connection, what.purpose(), start, what.heading()) catch {
        say("Cannot open the dialog.");
    };
}

fn finishFile() void {
    switch (dialog.result) {
        .pending => return,
        .cancelled => {},
        .chosen => switch (asking_file) {
            .open => {
                setPath(dialog.chosen());
                load();
            },
            .save => {
                setPath(dialog.chosen());
                save();
            },
            .portrait => importPortrait(dialog.chosen()),
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

/// A line for the status bar, which repaints itself when its words change.
fn say(text: []const u8) void {
    status = text;
    ctx.again();
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

    // The status bar: the file and whether it is on the medium; the session;
    // and what this pane is about, or what was just said.
    if (show_status) {
        eui.statusbar.run(ctx, parts.bottom, &.{
            .{ .text = fileText() },
            .{ .text = sessionText(), .width = 96, .right = true },
            .{ .text = if (status.len > 0) status else paneLine(), .width = 210, .right = true },
        });
    }

    // Last, so an open menu reaches over the pane rather than under it.
    if (eui.menubar.run(ctx, strip, &menus, &MENUS)) |id| MenuId.dispatch(id);
}

fn inset(area: Rect, by: i32) Rect {
    return .{ .x = area.x + by, .y = area.y + by, .w = area.w - by * 2, .h = area.h - by * 2 };
}

/// The rail's foot names the program and its version, the way Settings'
/// names the machine's; the file is the status bar's to say.
fn caption() []const u8 {
    return "Hero " ++ VERSION;
}

var file_buffer: [64]u8 = @splat(0);

/// The file's name, and that it has lines not yet saved.
fn fileText() []const u8 {
    var line = str.Builder{ .buf = &file_buffer };
    line.text(if (file_len > 0) baseName() else "No file yet");
    if (modified) line.text(" \u{b7} unsaved");
    return line.done();
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
        .spells => concentrationLine(),
        .journal => journalCountLine(),
        else => subtitle(),
    };
}

fn concentrationLine() []const u8 {
    var line = str.Builder{ .buf = &subtitle_buffer };
    line.text("Concentrating on ");
    line.text(if (sheet.concentration.len > 0) sheet.concentration else "nothing");
    return line.done();
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
    if (sheet.dead()) line.text(" \u{b7} Dead") else if (sheet.stable()) line.text(" \u{b7} Stable") else if (sheet.down()) line.text(" \u{b7} Down") else if (sheet.bloodied()) line.text(" \u{b7} Bloodied");
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
    addButton(.{ .x = right.x, .y = ry, .w = right.w, .h = t.control_height }, .feature);
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
    takeFocus(area);
    if (ctx.table(area, &skills_table, &SKILL_COLUMNS, &skill_rows)) |index| {
        const s: hero.Skill = @enumFromInt(index);
        askRoll(.{ .skill = s });
    }
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
    // The save rolled for the player, and marked from what fell.
    const roll_w = eui.footer.buttonWidth("Roll");
    if (ctx.button(.{ .x = right.x + 84 + eui.pips.width(3) + gap, .y = ry, .w = roll_w, .h = t.control_height }, "Roll")) askRoll(.death);
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
    const head_row = Rect{ .x = area.x, .y = y, .w = area.w, .h = t.control_height };
    eui.heading.paint(surface, head_row, "Attacks", null);
    addButton(head_row, .attack);
    const table_y = y + eui.heading.height() + 2;
    const table_area = Rect{ .x = area.x, .y = table_y, .w = area.w, .h = area.bottom() - table_y };
    takeFocus(table_area);
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
    line.signed(sheet.spellAttack());
    surface.text(area.x + 18, area.y + 6, line.done(), t.text);
    addButton(.{ .x = area.x, .y = area.y, .w = area.w, .h = t.control_height }, .spell);

    // The uses and the slots as pips: a pip emptied is one spent.
    var y = area.y + t.control_height + 4;
    const label_w = @max(92, Surface.textWidth(sheet.innateName()) + t.gap);
    if (sheet.innate_max > 0) {
        ctx.label(.{ .x = area.x, .y = y, .w = label_w, .h = t.control_height }, sheet.innateName());
        const left = ctx.pips(.{ .x = area.x + label_w + 4, .y = y, .w = eui.pips.width(sheet.innate_max), .h = t.control_height }, sheet.innate_max, sheet.innate_left);
        if (left < sheet.innate_left) {
            for (0..sheet.innate_left - left) |_| append(hero.writeInnate(&line_buffer));
        }
        y += t.control_height;
    }
    for (0..hero.SPELL_LEVELS) |lvl| {
        if (sheet.slots_max[lvl] == 0) continue;
        var lbl: [16]u8 = @splat(0);
        ctx.label(.{ .x = area.x, .y = y, .w = label_w, .h = t.control_height }, levelLabel(&lbl, lvl + 1));
        const left = ctx.pips(.{ .x = area.x + label_w + 4, .y = y, .w = eui.pips.width(sheet.slots_max[lvl]), .h = t.control_height }, sheet.slots_max[lvl], sheet.slots_left[lvl]);
        if (left < sheet.slots_left[lvl]) {
            for (0..sheet.slots_left[lvl] - left) |_| append(hero.writeCast(&line_buffer, @intCast(lvl + 1), "a slot"));
        }
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
    takeFocus(table_area);
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
    addButton(.{ .x = area.x, .y = area.y, .w = area.w - 180 - t.gap, .h = t.control_height }, .item);

    // What is carried, and how much it weighs against what can be.
    var y = area.y + t.control_height + t.gap;
    var facts: [2]eui.facts.Fact = undefined;
    var fb: [2][24]u8 = @splat(@splat(0));
    const over = carriedWeight() > @as(u32, sheet.carryCapacity()) * 100;
    facts[0] = .{ .label = if (over) "Carried, over capacity" else "Carried", .value = pounds(&fb[0], carriedWeight()) };
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
    takeFocus(table_area);
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
        .@"innate-use" => std.fmt.bufPrint(buf, "{s} used", .{sheet.innateName()}) catch rest,
        .save => std.fmt.bufPrint(buf, "Death save: {s}", .{rest}) catch rest,
        .condition => std.fmt.bufPrint(buf, "{s}{s}", .{ if (std.meta.stringToEnum(hero.Switch, second) == .off) "No longer " else "", first }) catch rest,
        .exhaustion => std.fmt.bufPrint(buf, "Exhaustion {s}", .{rest}) catch rest,
        .inspiration => if (std.meta.stringToEnum(hero.Switch, rest) == .on) "Heroic Inspiration gained" else "Heroic Inspiration spent",
        .gold => if (first.len > 0 and first[0] == '-')
            reason(buf, "Paid {s} gold", .{first[1..]}, second)
        else
            reason(buf, "Received {s} gold", .{first}, second),
        .roll => std.fmt.bufPrint(buf, "Rolled {s}: {s} {s}", .{ first, second, hero.part(rest, 2) }) catch rest,
        .dice => std.fmt.bufPrint(buf, "Rolled {s}: {s} ({s}: {s})", .{ first, hero.part(rest, 3), second, hero.part(rest, 2) }) catch rest,
        .drop => std.fmt.bufPrint(buf, "Dropped {s}", .{second}) catch rest,
        .concentrate => if (std.mem.eql(u8, rest, "-")) "Stopped concentrating" else std.fmt.bufPrint(buf, "Concentrating on {s}", .{rest}) catch rest,
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

fn pounds(buf: []u8, value: u32) []const u8 {
    var line = str.Builder{ .buf = buf };
    line.hundredths(value);
    line.text(" lb");
    return line.done();
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
