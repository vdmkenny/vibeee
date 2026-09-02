//! A character journal: the `.hero` file, read and written.
//!
//! The file is text, one line per fact or event, in the order they happened.
//! The character at any moment is the fold of the lines above: a fact sets
//! something, an event changes it, and nothing is ever overwritten. A mistake
//! is corrected by another line, so the history of the character is the file
//! itself. Text, because a journal only one program can read is a journal in a
//! locked drawer: `cat` prints it and `grep` finds a session in it.
//!
//! Both halves live here. `fold` reads a whole file into a `Sheet`, and the
//! `write*` helpers spell an event as the one line that records it, so the
//! reader and the writer can never drift into two ideas of the format. Pure
//! and host-tested: what the lines add up to is the whole of a character, and
//! none of it needs a screen to be checked.
//!
//! The grammar, in full: the first line is `hero 1`. Every other line is a
//! keyword, a space, and the rest; where the rest has parts they are joined
//! by ` | `. A blank line, or one that starts with `#`, is kept and ignored.
//! An unknown keyword is kept as a note rather than refused, so a file written
//! by a later version still opens in an earlier one.

const std = @import("std");

pub const MAGIC = "hero 1";
pub const SEPARATOR = " | ";

/// The design's budgets, which are what one window holds at once.
pub const MAX_ATTACKS = 12;
pub const MAX_SPELLS = 32;
pub const MAX_ITEMS = 64;
pub const MAX_FEATURES = 16;
pub const MAX_CONDITIONS = 12;
pub const SPELL_LEVELS = 9;

/// A fixed array and how much of it is used: the collection pattern this
/// system uses everywhere, so a sheet holds its attacks and spells the way
/// init holds its services. Past the budget a value is dropped rather than
/// grown into memory a character journal has no business taking.
fn Bounded(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        pub fn append(self: *Self, value: T) void {
            if (self.len >= capacity) return;
            self.items[self.len] = value;
            self.len += 1;
        }

        pub fn swapRemove(self: *Self, index: usize) void {
            if (index >= self.len) return;
            self.len -= 1;
            self.items[index] = self.items[self.len];
        }

        /// Take one out and close the gap, for a list whose order is read.
        pub fn remove(self: *Self, index: usize) void {
            if (index >= self.len) return;
            std.mem.copyForwards(T, self.items[index .. self.len - 1], self.items[index + 1 .. self.len]);
            self.len -= 1;
        }
    };
}

/// Where a list of named things has one by that name, in either case.
fn indexNamed(list: anytype, name: []const u8) ?usize {
    for (list.slice(), 0..) |entry, i| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return i;
    }
    return null;
}

/// Put a named thing in its list: over the one of that name when there is
/// one, so a line written again is a correction rather than a twin, and at
/// the end otherwise.
fn place(list: anytype, value: anytype) void {
    if (indexNamed(list, value.name)) |i| {
        list.items[i] = value;
    } else {
        list.append(value);
    }
}

/// The six ability scores, in the order a sheet lists them.
pub const Ability = enum(u3) {
    str,
    dex,
    con,
    int,
    wis,
    cha,

    /// The three-letter word a sheet uses, which is also the keyword.
    pub fn key(self: Ability) []const u8 {
        return @tagName(self);
    }

    /// The whole word, for a heading.
    pub fn word(self: Ability) []const u8 {
        return switch (self) {
            .str => "Strength",
            .dex => "Dexterity",
            .con => "Constitution",
            .int => "Intelligence",
            .wis => "Wisdom",
            .cha => "Charisma",
        };
    }

    pub fn byKey(name: []const u8) ?Ability {
        inline for (std.enums.values(Ability)) |a| {
            if (std.mem.eql(u8, name, a.key())) return a;
        }
        return null;
    }
};

/// The eighteen skills, each with the ability it is tested against.
pub const Skill = enum(u5) {
    acrobatics,
    animal_handling,
    arcana,
    athletics,
    deception,
    history,
    insight,
    intimidation,
    investigation,
    medicine,
    nature,
    perception,
    performance,
    persuasion,
    religion,
    sleight_of_hand,
    stealth,
    survival,

    pub fn ability(self: Skill) Ability {
        return switch (self) {
            .athletics => .str,
            .acrobatics, .sleight_of_hand, .stealth => .dex,
            .arcana, .history, .investigation, .nature, .religion => .int,
            .animal_handling, .insight, .medicine, .perception, .survival => .wis,
            .deception, .intimidation, .performance, .persuasion => .cha,
        };
    }

    /// The word a sheet shows and a file writes, spaces and all.
    pub fn word(self: Skill) []const u8 {
        return switch (self) {
            .acrobatics => "Acrobatics",
            .animal_handling => "Animal Handling",
            .arcana => "Arcana",
            .athletics => "Athletics",
            .deception => "Deception",
            .history => "History",
            .insight => "Insight",
            .intimidation => "Intimidation",
            .investigation => "Investigation",
            .medicine => "Medicine",
            .nature => "Nature",
            .perception => "Perception",
            .performance => "Performance",
            .persuasion => "Persuasion",
            .religion => "Religion",
            .sleight_of_hand => "Sleight of Hand",
            .stealth => "Stealth",
            .survival => "Survival",
        };
    }

    /// The lower-case, underscore-joined word the file uses.
    pub fn key(self: Skill) []const u8 {
        return @tagName(self);
    }

    pub fn byKey(name: []const u8) ?Skill {
        inline for (std.enums.values(Skill)) |s| {
            if (std.mem.eql(u8, name, s.key())) return s;
        }
        return null;
    }
};

/// The five coins, smallest first, as a `coins` line lists them.
pub const Coin = enum(u3) {
    cp,
    sp,
    ep,
    gp,
    pp,

    /// A purse holds gold, silver and copper: the coin by its name.
    pub fn word(self: Coin) []const u8 {
        return switch (self) {
            .cp => "copper",
            .sp => "silver",
            .ep => "electrum",
            .gp => "gold",
            .pp => "platinum",
        };
    }
};

pub const Advancement = enum { milestone, experience };

/// Every word a line may begin with: the reader switches on it and the
/// writers spell it with `@tagName`, so the grammar has one source. The
/// hyphenated words are spelled as they are written.
pub const Keyword = enum {
    name,
    class,
    species,
    background,
    alignment,
    size,
    player,
    picture,
    portrait,
    level,
    advancement,
    str,
    dex,
    con,
    int,
    wis,
    cha,
    saves,
    skills,
    expertise,
    hp,
    @"hit-die",
    ac,
    speed,
    spellcasting,
    slots,
    innate,
    weapons,
    tools,
    languages,
    armour,
    coins,
    attack,
    spell,
    item,
    feature,
    session,
    damage,
    heal,
    temp,
    hitdie,
    rest,
    cast,
    @"innate-use",
    save,
    condition,
    exhaustion,
    inspiration,
    gold,
    roll,
    dice,
    drop,
    concentrate,
    note,

    pub fn parse(word: []const u8) ?Keyword {
        return std.meta.stringToEnum(Keyword, word);
    }

    /// Whether the line's rest is a number, so a program asking for the
    /// line can refuse what is not one before it is written.
    pub fn takesNumber(self: Keyword) bool {
        return switch (self) {
            .level, .hp, .ac, .speed, .str, .dex, .con, .int, .wis, .cha => true,
            else => false,
        };
    }

    /// Whether a line sets the sheet, rather than recording a moment of play.
    /// Dropping something is a moment: it shows in the journal as the day the
    /// dagger was lost.
    pub fn isFact(self: Keyword) bool {
        return switch (self) {
            .session, .damage, .heal, .temp, .hitdie, .rest, .cast, .@"innate-use", .save, .condition, .exhaustion, .inspiration, .gold, .roll, .dice, .drop, .concentrate, .note => false,
            else => true,
        };
    }
};

/// A handful of dice as a line names them: `2d6+3`, `1d4`, `d8-1`. The
/// words after the dice, `piercing`, are the line's business and not read.
pub const Dice = struct {
    count: u8 = 1,
    faces: u8 = 6,
    bonus: i16 = 0,

    pub fn parse(line: []const u8) ?Dice {
        const word = if (std.mem.indexOfScalar(u8, line, ' ')) |sp| line[0..sp] else line;
        const d = std.mem.indexOfAny(u8, word, "dD") orelse return null;
        const count: u8 = if (d == 0) 1 else std.fmt.parseInt(u8, word[0..d], 10) catch return null;
        var end = d + 1;
        while (end < word.len and std.ascii.isDigit(word[end])) end += 1;
        const faces = std.fmt.parseInt(u8, word[d + 1 .. end], 10) catch return null;
        if (faces == 0 or count == 0) return null;
        var bonus: i16 = 0;
        if (end < word.len) {
            const sign = word[end];
            if (sign != '+' and sign != '-') return null;
            const magnitude = std.fmt.parseInt(i16, word[end + 1 ..], 10) catch return null;
            bonus = if (sign == '-') -magnitude else magnitude;
        }
        return .{ .count = count, .faces = faces, .bonus = bonus };
    }

    /// The dice as a line names them, `2d6+3`.
    pub fn text(self: Dice, buf: []u8) []const u8 {
        if (self.bonus == 0) return std.fmt.bufPrint(buf, "{d}d{d}", .{ self.count, self.faces }) catch buf[0..0];
        const sign: []const u8 = if (self.bonus < 0) "-" else "+";
        return std.fmt.bufPrint(buf, "{d}d{d}{s}{d}", .{ self.count, self.faces, sign, @abs(self.bonus) }) catch buf[0..0];
    }
};

/// What a death save came to.
pub const DeathSave = enum { success, failure, reset };

/// The two rests.
pub const Rest = enum { long, short };

/// A thing turned on or off.
pub const Switch = enum {
    on,
    off,

    pub fn of(set: bool) Switch {
        return if (set) .on else .off;
    }
};

/// How a d20 test is rolled, which the roll helper records so a total can be
/// checked by hand.
pub const Roll = enum { normal, advantage, disadvantage };

/// One line of the six kinds that carry parts.
pub const Attack = struct {
    name: []const u8 = "",
    hit: []const u8 = "",
    damage: []const u8 = "",
    notes: []const u8 = "",
};

pub const Spell = struct {
    name: []const u8 = "",
    level: u8 = 0,
    time: []const u8 = "",
    range: []const u8 = "",
    notes: []const u8 = "",
};

pub const Item = struct {
    name: []const u8 = "",
    quantity: u16 = 1,
    /// One item's weight, in hundredths of a pound, so half a pound is exact.
    weight_cp: u32 = 0,
};

pub const Feature = struct {
    name: []const u8 = "",
    note: []const u8 = "",
};

/// A character, as the lines above a point add up to it. Strings point into
/// the text `fold` was given, which the caller holds for as long as the sheet.
pub const Sheet = struct {
    name: []const u8 = "",
    class: []const u8 = "",
    species: []const u8 = "",
    background: []const u8 = "",
    alignment: []const u8 = "",
    size: []const u8 = "",
    player: []const u8 = "",
    picture: []const u8 = "",
    /// The portrait's bytes as base64, one line, so the journal carries its
    /// own face. Empty when there is none.
    portrait: []const u8 = "",
    level: u8 = 1,
    advancement: Advancement = .milestone,

    scores: std.EnumArray(Ability, u8) = std.EnumArray(Ability, u8).initFill(10),
    save_prof: std.EnumSet(Ability) = std.EnumSet(Ability).initEmpty(),
    skill_prof: std.EnumSet(Skill) = std.EnumSet(Skill).initEmpty(),
    skill_expert: std.EnumSet(Skill) = std.EnumSet(Skill).initEmpty(),

    hp_max: u16 = 0,
    hp_now: u16 = 0,
    hp_temp: u16 = 0,
    hit_die: u8 = 6,
    hit_dice_left: u8 = 0,
    ac: u16 = 10,
    speed: u16 = 30,

    spell_ability: Ability = .cha,
    slots_max: [SPELL_LEVELS]u8 = @splat(0),
    slots_left: [SPELL_LEVELS]u8 = @splat(0),
    innate_max: u8 = 0,
    innate_left: u8 = 0,
    /// What the innate feature is called: a sorcerer's Innate Sorcery, a
    /// barbarian's Rage. The file names it beside the count.
    innate_name: []const u8 = "",

    death_success: u8 = 0,
    death_failure: u8 = 0,
    exhaustion: u8 = 0,
    inspiration: bool = false,

    coins: std.EnumArray(Coin, i32) = std.EnumArray(Coin, i32).initFill(0),

    weapons: []const u8 = "",
    tools: []const u8 = "",
    languages: []const u8 = "",
    armour: []const u8 = "",

    attacks: Bounded(Attack, MAX_ATTACKS) = .{},
    spells: Bounded(Spell, MAX_SPELLS) = .{},
    items: Bounded(Item, MAX_ITEMS) = .{},
    features: Bounded(Feature, MAX_FEATURES) = .{},
    conditions: Bounded([]const u8, MAX_CONDITIONS) = .{},

    /// The spell being concentrated on, or nothing. Casting a spell whose
    /// notes say concentration starts it; a rest, or a `concentrate -` line,
    /// ends it.
    concentration: []const u8 = "",

    /// The heading the last `session` line named, for the status bar.
    session: []const u8 = "",

    // -- what the sheet derives, rather than stores ------------------------

    pub fn modifier(self: Sheet, ability: Ability) i8 {
        const score: i16 = self.scores.get(ability);
        return @intCast(@divFloor(score - 10, 2));
    }

    /// Two, and one more per four levels past the first.
    pub fn proficiency(self: Sheet) i8 {
        return 2 + @divFloor(@as(i8, @intCast(self.level)) - 1, 4);
    }

    pub fn saveBonus(self: Sheet, ability: Ability) i8 {
        const base = self.modifier(ability);
        return if (self.save_prof.contains(ability)) base + self.proficiency() else base;
    }

    pub fn skillBonus(self: Sheet, skill: Skill) i8 {
        var bonus = self.modifier(skill.ability());
        if (self.skill_expert.contains(skill)) {
            bonus += self.proficiency() * 2;
        } else if (self.skill_prof.contains(skill)) {
            bonus += self.proficiency();
        }
        return bonus;
    }

    /// Ten plus the skill's bonus: what is noticed without a roll.
    pub fn passive(self: Sheet, skill: Skill) i16 {
        return 10 + @as(i16, self.skillBonus(skill));
    }

    /// Every d20 test is worse by twice the exhaustion level.
    pub fn exhaustionPenalty(self: Sheet) i8 {
        return -2 * @as(i8, @intCast(@min(self.exhaustion, 10)));
    }

    /// At or below half of the maximum, and not already down.
    pub fn bloodied(self: Sheet) bool {
        return self.hp_now > 0 and self.hp_now * 2 <= self.hp_max;
    }

    pub fn down(self: Sheet) bool {
        return self.hp_now == 0;
    }

    /// Three failed death saves.
    pub fn dead(self: Sheet) bool {
        return self.death_failure >= 3;
    }

    /// Three death saves made: no longer dying, still down.
    pub fn stable(self: Sheet) bool {
        return self.down() and self.death_success >= 3;
    }

    /// The innate feature by its name, or by the only word there is.
    pub fn innateName(self: Sheet) []const u8 {
        return if (self.innate_name.len > 0) self.innate_name else "Innate feature";
    }

    /// Fifteen pounds a point of Strength.
    pub fn carryCapacity(self: Sheet) u16 {
        return @as(u16, self.scores.get(.str)) * 15;
    }

    pub fn pushDragLift(self: Sheet) u16 {
        return self.carryCapacity() * 2;
    }

    pub fn spellSaveDc(self: Sheet) i16 {
        return 8 + self.proficiency() + self.modifier(self.spell_ability);
    }

    pub fn spellAttack(self: Sheet) i8 {
        return self.proficiency() + self.modifier(self.spell_ability);
    }

    pub fn hasCondition(self: Sheet, name: []const u8) bool {
        for (self.conditions.slice()) |c| {
            if (std.ascii.eqlIgnoreCase(c, name)) return true;
        }
        return false;
    }
};

/// Read a whole file into the character it describes. Unknown and malformed
/// lines are skipped rather than refused: a journal is worth more open with a
/// line it did not understand than closed over one.
pub fn fold(text: []const u8) Sheet {
    var sheet = Sheet{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, MAGIC)) continue;

        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        apply(&sheet, line[0..space], std.mem.trim(u8, line[space + 1 ..], " \t"));
    }
    return sheet;
}

fn apply(sheet: *Sheet, word: []const u8, rest: []const u8) void {
    // A word this reader does not know is a note in the journal, kept as it
    // stands, so a file from a later version still opens in this one.
    const keyword = Keyword.parse(word) orelse return;
    switch (keyword) {
        // Facts about who the character is.
        .name => sheet.name = rest,
        .class => sheet.class = rest,
        .species => sheet.species = rest,
        .background => sheet.background = rest,
        .alignment => sheet.alignment = rest,
        .size => sheet.size = rest,
        .player => sheet.player = rest,
        .picture => sheet.picture = rest,
        .portrait => sheet.portrait = if (std.mem.eql(u8, rest, "-")) "" else rest,
        .level => sheet.level = @max(1, parseU8(rest)),
        .advancement => sheet.advancement = std.meta.stringToEnum(Advancement, rest) orelse .milestone,

        // The numbers the sheet is built from.
        inline .str, .dex, .con, .int, .wis, .cha => |k| sheet.scores.set(@field(Ability, @tagName(k)), parseU8(rest)),
        .saves => {
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            while (it.next()) |name| {
                if (Ability.byKey(name)) |a| sheet.save_prof.insert(a);
            }
        },
        .skills => markSkills(sheet, rest, false),
        .expertise => markSkills(sheet, rest, true),
        .hp => setMaxHp(sheet, parseU16(rest)),
        .@"hit-die" => sheet.hit_die = parseDie(rest),
        .ac => sheet.ac = parseU16(rest),
        .speed => sheet.speed = parseU16(rest),
        .spellcasting => if (Ability.byKey(rest)) |a| {
            sheet.spell_ability = a;
        },
        .slots => setSlots(sheet, rest),
        .innate => {
            sheet.innate_max = parseU8(firstPart(rest));
            sheet.innate_left = sheet.innate_max;
            sheet.innate_name = part(rest, 1);
        },
        .weapons => sheet.weapons = rest,
        .tools => sheet.tools = rest,
        .languages => sheet.languages = rest,
        .armour => sheet.armour = rest,
        .coins => setCoins(sheet, rest),

        // What the character carries and can do.
        .attack => addAttack(sheet, rest),
        .spell => addSpell(sheet, rest),
        .item => addItem(sheet, rest),
        .feature => addFeature(sheet, rest),
        .drop => dropNamed(sheet, rest),

        // Events, folded into the current state.
        .session => sheet.session = firstPart(rest),
        .damage => applyDamage(sheet, parseU16(firstPart(rest))),
        .heal => applyHeal(sheet, parseU16(firstPart(rest))),
        .temp => sheet.hp_temp = parseU16(rest),
        .hitdie => {
            if (sheet.hit_dice_left > 0) sheet.hit_dice_left -= 1;
            applyHeal(sheet, parseU16(rest));
        },
        .rest => {
            if (std.meta.stringToEnum(Rest, rest) == .long) longRest(sheet);
            sheet.concentration = "";
        },
        .cast => {
            const level = parseU8(firstPart(rest));
            if (level >= 1 and level <= SPELL_LEVELS and sheet.slots_left[level - 1] > 0) {
                sheet.slots_left[level - 1] -= 1;
            }
            startConcentration(sheet, part(rest, 1));
        },
        .concentrate => sheet.concentration = if (std.mem.eql(u8, rest, "-")) "" else rest,
        .@"innate-use" => if (sheet.innate_left > 0) {
            sheet.innate_left -= 1;
        },
        .save => switch (std.meta.stringToEnum(DeathSave, rest) orelse return) {
            .success => sheet.death_success +|= 1,
            .failure => sheet.death_failure +|= 1,
            .reset => {
                sheet.death_success = 0;
                sheet.death_failure = 0;
            },
        },
        .condition => setCondition(sheet, rest),
        .exhaustion => sheet.exhaustion = parseU8(rest),
        .inspiration => sheet.inspiration = std.meta.stringToEnum(Switch, rest) == .on,
        .gold => sheet.coins.getPtr(.gp).* += parseI32(firstPart(rest)),

        // A note and a roll change nothing on the sheet: they are the
        // journal's, read from the file in order where it is shown.
        .roll, .dice, .note => {},
    }
}

// ---------------------------------------------------------------------------
// Folding the pieces
// ---------------------------------------------------------------------------

/// The part before the first separator, or the whole where there is none.
fn firstPart(rest: []const u8) []const u8 {
    return part(rest, 0);
}

/// The nth ` | ` separated part, trimmed, or empty past the end.
pub fn part(rest: []const u8, index: usize) []const u8 {
    var it = std.mem.splitSequence(u8, rest, SEPARATOR);
    var i: usize = 0;
    while (it.next()) |piece| : (i += 1) {
        if (i == index) return std.mem.trim(u8, piece, " \t");
    }
    return "";
}

fn markSkills(sheet: *Sheet, rest: []const u8, expert: bool) void {
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    while (it.next()) |word| {
        if (Skill.byKey(word)) |s| {
            sheet.skill_prof.insert(s);
            if (expert) sheet.skill_expert.insert(s);
        }
    }
}

/// Raising the maximum raises the current by the same, which is what gaining a
/// level does; the first `hp` sets both from nothing.
fn setMaxHp(sheet: *Sheet, value: u16) void {
    const gain = value -| sheet.hp_max;
    sheet.hp_max = value;
    sheet.hp_now = @min(sheet.hp_now + gain, sheet.hp_max);
    if (sheet.hit_dice_left == 0) sheet.hit_dice_left = sheet.level;
}

fn setSlots(sheet: *Sheet, rest: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    var i: usize = 0;
    while (it.next()) |word| : (i += 1) {
        if (i >= SPELL_LEVELS) break;
        const value = parseU8(word);
        sheet.slots_max[i] = value;
        sheet.slots_left[i] = value;
    }
}

fn setCoins(sheet: *Sheet, rest: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    for (std.enums.values(Coin)) |coin| {
        const word = it.next() orelse break;
        sheet.coins.set(coin, parseI32(word));
    }
}

fn applyDamage(sheet: *Sheet, amount: u16) void {
    var left = amount;
    const absorbed = @min(sheet.hp_temp, left);
    sheet.hp_temp -= absorbed;
    left -= absorbed;
    sheet.hp_now -|= left;
}

fn applyHeal(sheet: *Sheet, amount: u16) void {
    if (sheet.hp_max == 0) return;
    sheet.hp_now = @min(sheet.hp_now + amount, sheet.hp_max);
    sheet.death_success = 0;
    sheet.death_failure = 0;
}

/// Everything a night's sleep gives back.
fn longRest(sheet: *Sheet) void {
    sheet.hp_now = sheet.hp_max;
    sheet.hp_temp = 0;
    sheet.hit_dice_left = sheet.level;
    sheet.slots_left = sheet.slots_max;
    sheet.innate_left = sheet.innate_max;
    if (sheet.exhaustion > 0) sheet.exhaustion -= 1;
    sheet.death_success = 0;
    sheet.death_failure = 0;
}

fn setCondition(sheet: *Sheet, rest: []const u8) void {
    const name = part(rest, 0);
    if (name.len == 0) return;

    if (std.meta.stringToEnum(Switch, part(rest, 1)) == .off) {
        for (sheet.conditions.slice(), 0..) |c, i| {
            if (std.ascii.eqlIgnoreCase(c, name)) {
                sheet.conditions.swapRemove(i);
                return;
            }
        }
        return;
    }
    if (sheet.hasCondition(name)) return;
    sheet.conditions.append(name);
}

fn addAttack(sheet: *Sheet, rest: []const u8) void {
    place(&sheet.attacks, Attack{
        .name = part(rest, 0),
        .hit = part(rest, 1),
        .damage = part(rest, 2),
        .notes = part(rest, 3),
    });
}

fn addSpell(sheet: *Sheet, rest: []const u8) void {
    place(&sheet.spells, Spell{
        .name = part(rest, 0),
        .level = parseU8(part(rest, 1)),
        .time = part(rest, 2),
        .range = part(rest, 3),
        .notes = part(rest, 4),
    });
}

/// An item line names how many are carried; none left is the item gone,
/// which is how the last ration is eaten.
fn addItem(sheet: *Sheet, rest: []const u8) void {
    const name = part(rest, 0);
    const count = part(rest, 1);
    const quantity: u16 = if (count.len == 0) 1 else parseU16(count);
    if (quantity == 0) {
        if (indexNamed(&sheet.items, name)) |i| sheet.items.remove(i);
        return;
    }
    place(&sheet.items, Item{
        .name = name,
        .quantity = quantity,
        .weight_cp = parseWeight(part(rest, 2)),
    });
}

fn addFeature(sheet: *Sheet, rest: []const u8) void {
    place(&sheet.features, Feature{
        .name = part(rest, 0),
        .note = part(rest, 1),
    });
}

/// A spell cast whose notes say concentration is the one concentrated on,
/// in place of whatever was.
fn startConcentration(sheet: *Sheet, name: []const u8) void {
    const at = indexNamed(&sheet.spells, name) orelse return;
    const spell = sheet.spells.slice()[at];
    if (std.ascii.indexOfIgnoreCase(spell.notes, "concentration") != null) sheet.concentration = spell.name;
}

/// `drop attack | Dagger`: the named thing leaves its list.
fn dropNamed(sheet: *Sheet, rest: []const u8) void {
    const name = part(rest, 1);
    switch (Keyword.parse(part(rest, 0)) orelse return) {
        .attack => if (indexNamed(&sheet.attacks, name)) |i| sheet.attacks.remove(i),
        .spell => if (indexNamed(&sheet.spells, name)) |i| sheet.spells.remove(i),
        .item => if (indexNamed(&sheet.items, name)) |i| sheet.items.remove(i),
        .feature => if (indexNamed(&sheet.features, name)) |i| sheet.features.remove(i),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

fn parseU8(text: []const u8) u8 {
    return std.fmt.parseInt(u8, text, 10) catch 0;
}

fn parseU16(text: []const u8) u16 {
    return std.fmt.parseInt(u16, text, 10) catch 0;
}

fn parseI32(text: []const u8) i32 {
    return std.fmt.parseInt(i32, text, 10) catch 0;
}

/// A hit die is written as its die, `d6`; the number is what matters.
fn parseDie(text: []const u8) u8 {
    const digits = if (text.len > 0 and (text[0] == 'd' or text[0] == 'D')) text[1..] else text;
    return std.fmt.parseInt(u8, digits, 10) catch 6;
}

/// A weight in pounds, whole or with two places, as hundredths.
fn parseWeight(text: []const u8) u32 {
    if (text.len == 0) return 0;
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse {
        return (std.fmt.parseInt(u32, text, 10) catch 0) * 100;
    };
    const whole = std.fmt.parseInt(u32, text[0..dot], 10) catch 0;
    var frac: u32 = 0;
    const after = text[dot + 1 ..];
    if (after.len >= 1) frac += (std.fmt.charToDigit(after[0], 10) catch 0) * 10;
    if (after.len >= 2) frac += std.fmt.charToDigit(after[1], 10) catch 0;
    return whole * 100 + frac;
}

// ---------------------------------------------------------------------------
// Writing an event back
//
// One line per event, in the exact grammar `fold` reads, so the two never part
// company. Each takes the buffer the caller will append to its file.
// ---------------------------------------------------------------------------

/// Append `src` to what is written so far, as much as fits.
fn put(buf: []u8, at: usize, src: []const u8) usize {
    const n = @min(src.len, buf.len - at);
    @memcpy(buf[at..][0..n], src[0..n]);
    return at + n;
}

fn writeParts(buf: []u8, keyword: []const u8, parts: []const []const u8) []const u8 {
    var n = put(buf, 0, keyword);
    for (parts, 0..) |p, i| {
        n = put(buf, n, if (i == 0) " " else SEPARATOR);
        n = put(buf, n, p);
    }
    return buf[0..n];
}

fn writeNumbered(buf: []u8, keyword: []const u8, value: i64, why: []const u8) []const u8 {
    return if (why.len > 0)
        std.fmt.bufPrint(buf, "{s} {d} | {s}", .{ keyword, value, why }) catch buf[0..0]
    else
        std.fmt.bufPrint(buf, "{s} {d}", .{ keyword, value }) catch buf[0..0];
}

pub fn writeSession(buf: []u8, number: u32, date: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, @tagName(Keyword.session) ++ " {d} | {s}", .{ number, date }) catch buf[0..0];
}

pub fn writeDamage(buf: []u8, amount: u16, why: []const u8) []const u8 {
    return writeNumbered(buf, @tagName(Keyword.damage), amount, why);
}

pub fn writeHeal(buf: []u8, amount: u16, why: []const u8) []const u8 {
    return writeNumbered(buf, @tagName(Keyword.heal), amount, why);
}

pub fn writeTemp(buf: []u8, amount: u16) []const u8 {
    return writeNumbered(buf, @tagName(Keyword.temp), amount, "");
}

pub fn writeHitDie(buf: []u8, healed: u16) []const u8 {
    return writeNumbered(buf, @tagName(Keyword.hitdie), healed, "");
}

pub fn writeGold(buf: []u8, delta: i32, why: []const u8) []const u8 {
    return writeNumbered(buf, @tagName(Keyword.gold), delta, why);
}

pub fn writeExhaustion(buf: []u8, level: u8) []const u8 {
    return writeNumbered(buf, @tagName(Keyword.exhaustion), level, "");
}

pub fn writeRest(buf: []u8, which: Rest) []const u8 {
    return writeParts(buf, @tagName(Keyword.rest), &.{@tagName(which)});
}

pub fn writeCast(buf: []u8, level: u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, @tagName(Keyword.cast) ++ " {d} | {s}", .{ level, name }) catch buf[0..0];
}

pub fn writeInnate(buf: []u8) []const u8 {
    return writeParts(buf, @tagName(Keyword.@"innate-use"), &.{});
}

pub fn writeSave(buf: []u8, outcome: DeathSave) []const u8 {
    return writeParts(buf, @tagName(Keyword.save), &.{@tagName(outcome)});
}

pub fn writeCondition(buf: []u8, name: []const u8, state: Switch) []const u8 {
    return writeParts(buf, @tagName(Keyword.condition), &.{ name, @tagName(state) });
}

pub fn writeInspiration(buf: []u8, state: Switch) []const u8 {
    return writeParts(buf, @tagName(Keyword.inspiration), &.{@tagName(state)});
}

pub fn writeNote(buf: []u8, text: []const u8) []const u8 {
    return writeParts(buf, @tagName(Keyword.note), &.{text});
}

/// A d20 test: what it was for, the die kept, the modifier, and how it was
/// rolled, so the total can be checked against the line.
pub fn writeRoll(buf: []u8, what: []const u8, die: u8, modifier: i16, how: Roll) []const u8 {
    const sign: []const u8 = if (modifier < 0) "-" else "+";
    const magnitude = @abs(modifier);
    return std.fmt.bufPrint(buf, @tagName(Keyword.roll) ++ " {s} | {d} | {s}{d} | {s}", .{
        what, die, sign, magnitude, @tagName(how),
    }) catch buf[0..0];
}

/// A handful of dice: what for, the dice as named, the dice as they fell,
/// and the total, so a damage roll reads back whole.
pub fn writeDice(buf: []u8, what: []const u8, dice: Dice, fallen: []const u8, total: i32) []const u8 {
    var named: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, @tagName(Keyword.dice) ++ " {s} | {s} | {s} | {d}", .{
        what, dice.text(&named), fallen, total,
    }) catch buf[0..0];
}

/// A fact as the sheet keeps it: the keyword and the rest of the line, which
/// the program has already spelled the way the fold reads it.
pub fn writeFact(buf: []u8, keyword: Keyword, rest: []const u8) []const u8 {
    return writeParts(buf, @tagName(keyword), &.{rest});
}

/// The named thing leaves its list: `drop item | Rope, hempen`.
pub fn writeDrop(buf: []u8, kind: Keyword, name: []const u8) []const u8 {
    return writeParts(buf, @tagName(Keyword.drop), &.{ @tagName(kind), name });
}

/// Concentration on a spell by name, or on nothing: `concentrate -`.
pub fn writeConcentrate(buf: []u8, name: []const u8) []const u8 {
    return writeParts(buf, @tagName(Keyword.concentrate), &.{if (name.len > 0) name else "-"});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const CINAED =
    \\hero 1
    \\name cinaed I
    \\player cinaed666
    \\class Sorcerer
    \\level 1
    \\species Halfling
    \\background Acolyte
    \\alignment Chaotic Good
    \\size Small
    \\advancement milestone
    \\str 14
    \\dex 14
    \\con 15
    \\int 18
    \\wis 14
    \\cha 20
    \\saves con cha
    \\skills deception insight persuasion religion
    \\hp 8
    \\hit-die d6
    \\ac 12
    \\speed 30
    \\spellcasting cha
    \\slots 2 0 0 0 0 0 0 0 0
    \\innate 2
    \\attack Dagger | +4 | 1d4+2 piercing | Finesse, light, thrown, nick, 20/60
    \\spell Fire Bolt | 0 | 1 action | 120 ft. | V/S, +7 to hit
    \\spell Burning Hands | 1 | 1 action | Self, 15 ft. cone | V/S/M, DEX 15
    \\item Dagger | 2 | 1
    \\item Rope, hempen | 1 | 5
    \\coins 0 0 0 36 0
    \\feature Innate Sorcery | 2 / long rest
    \\session 3 | 2026-08-30
;

test "the fold reads a character, and the numbers it derives are the sheet's" {
    const c = fold(CINAED);

    try testing.expectEqualStrings("cinaed I", c.name);
    try testing.expectEqualStrings("Sorcerer", c.class);
    try testing.expectEqual(@as(u8, 1), c.level);

    // Modifiers: (score - 10) halved, rounded down.
    try testing.expectEqual(@as(i8, 2), c.modifier(.str));
    try testing.expectEqual(@as(i8, 2), c.modifier(.con)); // 15 -> +2
    try testing.expectEqual(@as(i8, 5), c.modifier(.cha)); // 20 -> +5
    try testing.expectEqual(@as(i8, 2), c.proficiency());

    // Charisma save is proficient: +5 and the bonus. Strength is not.
    try testing.expectEqual(@as(i8, 7), c.saveBonus(.cha));
    try testing.expectEqual(@as(i8, 2), c.saveBonus(.str));

    // Persuasion is Charisma and proficient: +5 and +2. Passive is ten more.
    try testing.expectEqual(@as(i8, 7), c.skillBonus(.persuasion));
    try testing.expectEqual(@as(i16, 12), c.passive(.perception)); // Wisdom +2, not proficient
    try testing.expectEqual(@as(i16, 17), c.passive(.persuasion));

    try testing.expectEqual(@as(i16, 15), c.spellSaveDc());
    try testing.expectEqual(@as(i8, 7), c.spellAttack());

    // Full to start, and one hit die at level one.
    try testing.expectEqual(@as(u16, 8), c.hp_now);
    try testing.expectEqual(@as(u8, 1), c.hit_dice_left);
    try testing.expectEqual(@as(u8, 2), c.slots_max[0]);
    try testing.expectEqual(@as(u8, 2), c.innate_left);

    try testing.expectEqual(@as(usize, 1), c.attacks.len);
    try testing.expectEqual(@as(usize, 2), c.spells.len);
    try testing.expectEqual(@as(i32, 36), c.coins.get(.gp));
    try testing.expectEqualStrings("3", c.session);

    // Carrying: fifteen a point of Strength.
    try testing.expectEqual(@as(u16, 210), c.carryCapacity());
    try testing.expectEqual(@as(u16, 420), c.pushDragLift());
}

test "temporary hit points take a hit before the character does" {
    const journal = CINAED ++ "\ntemp 5\ndamage 8 | goblin";
    const c = fold(journal);
    // Five absorbed, three through: eight less three.
    try testing.expectEqual(@as(u16, 0), c.hp_temp);
    try testing.expectEqual(@as(u16, 5), c.hp_now);
    // Five of eight is above half, so not yet bloodied; one more point is.
    try testing.expect(!c.bloodied());
    try testing.expect(fold(journal ++ "\ndamage 1").bloodied());
    try testing.expect(!c.down());
}

test "damage never falls below nothing, and healing never rises above the maximum" {
    try testing.expectEqual(@as(u16, 0), fold(CINAED ++ "\ndamage 100").hp_now);
    try testing.expectEqual(@as(u16, 8), fold(CINAED ++ "\ndamage 4\nheal 100").hp_now);
    try testing.expect(fold(CINAED ++ "\ndamage 100").down());
}

test "a long rest gives back hit points, hit dice, slots and an innate use" {
    const journal = CINAED ++
        "\ndamage 6\nhitdie 4\ncast 1 | Burning Hands\ninnate-use\nexhaustion 2\nrest long";
    const c = fold(journal);
    try testing.expectEqual(@as(u16, 8), c.hp_now);
    try testing.expectEqual(@as(u8, 1), c.hit_dice_left);
    try testing.expectEqual(@as(u8, 2), c.slots_left[0]);
    try testing.expectEqual(@as(u8, 2), c.innate_left);
    try testing.expectEqual(@as(u8, 1), c.exhaustion); // down one, not to nothing
    try testing.expectEqual(@as(i8, -2), c.exhaustionPenalty());
}

test "casting spends a slot of its level, and a cantrip spends nothing" {
    try testing.expectEqual(@as(u8, 1), fold(CINAED ++ "\ncast 1 | Burning Hands").slots_left[0]);
    try testing.expectEqual(@as(u8, 2), fold(CINAED ++ "\ncast 0 | Fire Bolt").slots_left[0]);
    // A slot that is not there is not spent below nothing.
    try testing.expectEqual(@as(u8, 0), fold(CINAED ++ "\ncast 1\ncast 1\ncast 1").slots_left[0]);
}

test "a condition is set and cleared by name, and gold is paid and received" {
    const c = fold(CINAED ++ "\ncondition frightened | on\ncondition poisoned | on\ncondition frightened | off\ngold -3 | rations\ngold 10 | reward");
    try testing.expect(c.hasCondition("poisoned"));
    try testing.expect(!c.hasCondition("frightened"));
    try testing.expectEqual(@as(i32, 43), c.coins.get(.gp));
}

test "a gained level raises the maximum and the current by the same" {
    // Level one at eight, then level two to fourteen: six gained, so a
    // character at full stays full, and one that was hurt gains the six.
    try testing.expectEqual(@as(u16, 14), fold(CINAED ++ "\nlevel 2\nhp 14").hp_now);
    try testing.expectEqual(@as(u16, 11), fold(CINAED ++ "\ndamage 3\nlevel 2\nhp 14").hp_now);
    // At level five the proficiency bonus is three.
    try testing.expectEqual(@as(i8, 3), fold(CINAED ++ "\nlevel 5").proficiency());
}

test "a thing written again is corrected, and dropped is gone" {
    // The dagger's line again, with a better bonus, is one dagger, not two.
    const c = fold(CINAED ++ "\nattack Dagger | +5 | 1d4+3 piercing | Finesse");
    try testing.expectEqual(@as(usize, 1), c.attacks.len);
    try testing.expectEqualStrings("+5", c.attacks.slice()[0].hit);

    // Rope dropped by name; the daggers stay, in their order.
    const d = fold(CINAED ++ "\ndrop item | Rope, hempen");
    try testing.expectEqual(@as(usize, 1), d.items.len);
    try testing.expectEqualStrings("Dagger", d.items.slice()[0].name);

    // A quantity of none is the item gone, and a spell dropped is gone.
    try testing.expectEqual(@as(usize, 1), fold(CINAED ++ "\nitem Dagger | 0 | 1").items.len);
    try testing.expectEqual(@as(usize, 1), fold(CINAED ++ "\ndrop spell | fire bolt").spells.len);
}

test "the innate feature carries its name, and three failures are the end" {
    const c = fold(CINAED ++ "\ninnate 3 | Rage");
    try testing.expectEqual(@as(u8, 3), c.innate_max);
    try testing.expectEqualStrings("Rage", c.innateName());
    try testing.expectEqualStrings("Innate feature", fold(CINAED).innateName());

    try testing.expect(!fold(CINAED ++ "\nsave failure\nsave failure").dead());
    try testing.expect(fold(CINAED ++ "\nsave failure\nsave failure\nsave failure").dead());
}

test "concentration starts with the cast and ends with a rest or a line" {
    const bane = CINAED ++ "\nspell Bane | 1 | 1 action | 30 ft. | V/S/M, CHA 15, concentration";
    try testing.expectEqualStrings("", fold(bane).concentration);
    try testing.expectEqualStrings("Bane", fold(bane ++ "\ncast 1 | Bane").concentration);
    // Burning Hands is not a concentration spell, and does not take over.
    try testing.expectEqualStrings("Bane", fold(bane ++ "\ncast 1 | Bane\ncast 1 | Burning Hands").concentration);
    try testing.expectEqualStrings("", fold(bane ++ "\ncast 1 | Bane\nconcentrate -").concentration);
    try testing.expectEqualStrings("", fold(bane ++ "\ncast 1 | Bane\nrest short").concentration);
    try testing.expectEqualStrings("Bless", fold(bane ++ "\nconcentrate Bless").concentration);
}

test "the portrait is a line of the file, and three saves are stable" {
    try testing.expectEqualStrings("aGVsbG8=", fold(CINAED ++ "\nportrait aGVsbG8=").portrait);
    try testing.expectEqualStrings("", fold(CINAED ++ "\nportrait aGVsbG8=\nportrait -").portrait);

    const dying = CINAED ++ "\ndamage 8\nsave success\nsave success\nsave success";
    try testing.expect(fold(dying).stable());
    try testing.expect(!fold(dying).dead());
    // A hit point back is no longer down, so no longer stable either.
    try testing.expect(!fold(dying ++ "\nheal 1").stable());
}

test "dice are read from a damage line and spelled back" {
    var buf: [16]u8 = undefined;
    const d = Dice.parse("1d4+2 piercing").?;
    try testing.expectEqual(@as(u8, 1), d.count);
    try testing.expectEqual(@as(u8, 4), d.faces);
    try testing.expectEqual(@as(i16, 2), d.bonus);
    try testing.expectEqualStrings("1d4+2", d.text(&buf));

    try testing.expectEqualStrings("2d6", Dice.parse("2d6").?.text(&buf));
    try testing.expectEqual(@as(i16, -1), Dice.parse("d8-1").?.bonus);
    try testing.expectEqual(@as(u8, 1), Dice.parse("d8-1").?.count);
    try testing.expectEqual(@as(?Dice, null), Dice.parse("piercing"));
    try testing.expectEqual(@as(?Dice, null), Dice.parse("3"));
}

test "the writers spell the grammar the fold reads" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("damage 5 | goblin arrow", writeDamage(&buf, 5, "goblin arrow"));
    try testing.expectEqualStrings("gold -3 | rations", writeGold(&buf, -3, "rations"));
    try testing.expectEqualStrings("rest long", writeRest(&buf, .long));
    try testing.expectEqualStrings("save reset", writeSave(&buf, .reset));
    try testing.expectEqualStrings("condition prone | off", writeCondition(&buf, "prone", .off));
    try testing.expectEqualStrings("exhaustion 2", writeExhaustion(&buf, 2));
    try testing.expectEqualStrings("cast 1 | Burning Hands", writeCast(&buf, 1, "Burning Hands"));
    try testing.expectEqualStrings("roll Persuasion | 12 | +7 | advantage", writeRoll(&buf, "Persuasion", 12, 7, .advantage));
    try testing.expectEqualStrings("session 4 | 2026-09-06", writeSession(&buf, 4, "2026-09-06"));
    try testing.expectEqualStrings("dice Dagger damage | 1d4+2 | 3 | 5", writeDice(&buf, "Dagger damage", .{ .count = 1, .faces = 4, .bonus = 2 }, "3", 5));
    try testing.expectEqualStrings("drop item | Rope, hempen", writeDrop(&buf, .item, "Rope, hempen"));
    try testing.expectEqualStrings("hp 14", writeFact(&buf, .hp, "14"));
    try testing.expectEqualStrings("concentrate -", writeConcentrate(&buf, ""));
    try testing.expectEqualStrings("concentrate Bane", writeConcentrate(&buf, "Bane"));
    try testing.expect(Keyword.hp.takesNumber());
    try testing.expect(!Keyword.name.takesNumber());

    // What a writer spells, the fold reads back to the same effect.
    const line = writeDamage(&buf, 3, "test");
    var journal: [2048]u8 = undefined;
    const whole = std.fmt.bufPrint(&journal, "{s}\n{s}", .{ CINAED, line }) catch unreachable;
    try testing.expectEqual(@as(u16, 5), fold(whole).hp_now);
}
