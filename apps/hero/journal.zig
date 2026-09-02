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
    };
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
pub const Coin = enum(u3) { cp, sp, ep, gp, pp };

pub const Advancement = enum { milestone, experience };

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
    level: u8 = 1,
    advancement: Advancement = .milestone,

    scores: [6]u8 = @splat(10),
    save_prof: [6]bool = @splat(false),
    skill_prof: [18]bool = @splat(false),
    skill_expert: [18]bool = @splat(false),

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

    death_success: u8 = 0,
    death_failure: u8 = 0,
    exhaustion: u8 = 0,
    inspiration: bool = false,

    coins: [5]i32 = @splat(0),

    weapons: []const u8 = "",
    tools: []const u8 = "",
    languages: []const u8 = "",
    armour: []const u8 = "",

    attacks: Bounded(Attack, MAX_ATTACKS) = .{},
    spells: Bounded(Spell, MAX_SPELLS) = .{},
    items: Bounded(Item, MAX_ITEMS) = .{},
    features: Bounded(Feature, MAX_FEATURES) = .{},
    conditions: Bounded([]const u8, MAX_CONDITIONS) = .{},

    /// The heading the last `session` line named, for the status bar.
    session: []const u8 = "",

    // -- what the sheet derives, rather than stores ------------------------

    pub fn modifier(self: Sheet, ability: Ability) i8 {
        const score: i16 = self.scores[@intFromEnum(ability)];
        return @intCast(@divFloor(score - 10, 2));
    }

    /// Two, and one more per four levels past the first.
    pub fn proficiency(self: Sheet) i8 {
        return 2 + @divFloor(@as(i8, @intCast(self.level)) - 1, 4);
    }

    pub fn saveBonus(self: Sheet, ability: Ability) i8 {
        const base = self.modifier(ability);
        return if (self.save_prof[@intFromEnum(ability)]) base + self.proficiency() else base;
    }

    pub fn skillBonus(self: Sheet, skill: Skill) i8 {
        const i = @intFromEnum(skill);
        var bonus = self.modifier(skill.ability());
        if (self.skill_expert[i]) {
            bonus += self.proficiency() * 2;
        } else if (self.skill_prof[i]) {
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

    /// Fifteen pounds a point of Strength.
    pub fn carryCapacity(self: Sheet) u16 {
        return @as(u16, self.scores[@intFromEnum(Ability.str)]) * 15;
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

fn apply(sheet: *Sheet, keyword: []const u8, rest: []const u8) void {
    const eq = std.mem.eql;

    // Facts about who the character is.
    if (eq(u8, keyword, "name")) {
        sheet.name = rest;
    } else if (eq(u8, keyword, "class")) {
        sheet.class = rest;
    } else if (eq(u8, keyword, "species")) {
        sheet.species = rest;
    } else if (eq(u8, keyword, "background")) {
        sheet.background = rest;
    } else if (eq(u8, keyword, "alignment")) {
        sheet.alignment = rest;
    } else if (eq(u8, keyword, "size")) {
        sheet.size = rest;
    } else if (eq(u8, keyword, "player")) {
        sheet.player = rest;
    } else if (eq(u8, keyword, "picture")) {
        sheet.picture = rest;
    } else if (eq(u8, keyword, "level")) {
        sheet.level = @max(1, parseU8(rest));
    } else if (eq(u8, keyword, "advancement")) {
        sheet.advancement = if (eq(u8, rest, "experience")) .experience else .milestone;

        // The numbers the sheet is built from.
    } else if (Ability.byKey(keyword)) |ability| {
        sheet.scores[@intFromEnum(ability)] = parseU8(rest);
    } else if (eq(u8, keyword, "saves")) {
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        while (it.next()) |word| {
            if (Ability.byKey(word)) |a| sheet.save_prof[@intFromEnum(a)] = true;
        }
    } else if (eq(u8, keyword, "skills")) {
        markSkills(sheet, rest, false);
    } else if (eq(u8, keyword, "expertise")) {
        markSkills(sheet, rest, true);
    } else if (eq(u8, keyword, "hp")) {
        setMaxHp(sheet, parseU16(rest));
    } else if (eq(u8, keyword, "hit-die")) {
        sheet.hit_die = parseDie(rest);
    } else if (eq(u8, keyword, "ac")) {
        sheet.ac = parseU16(rest);
    } else if (eq(u8, keyword, "speed")) {
        sheet.speed = parseU16(rest);
    } else if (eq(u8, keyword, "spellcasting")) {
        if (Ability.byKey(rest)) |a| sheet.spell_ability = a;
    } else if (eq(u8, keyword, "slots")) {
        setSlots(sheet, rest);
    } else if (eq(u8, keyword, "innate")) {
        sheet.innate_max = parseU8(rest);
        sheet.innate_left = sheet.innate_max;
    } else if (eq(u8, keyword, "weapons")) {
        sheet.weapons = rest;
    } else if (eq(u8, keyword, "tools")) {
        sheet.tools = rest;
    } else if (eq(u8, keyword, "languages")) {
        sheet.languages = rest;
    } else if (eq(u8, keyword, "armour")) {
        sheet.armour = rest;
    } else if (eq(u8, keyword, "coins")) {
        setCoins(sheet, rest);

        // What the character carries and can do.
    } else if (eq(u8, keyword, "attack")) {
        addAttack(sheet, rest);
    } else if (eq(u8, keyword, "spell")) {
        addSpell(sheet, rest);
    } else if (eq(u8, keyword, "item")) {
        addItem(sheet, rest);
    } else if (eq(u8, keyword, "feature")) {
        addFeature(sheet, rest);

        // Events, folded into the current state.
    } else if (eq(u8, keyword, "session")) {
        sheet.session = firstPart(rest);
    } else if (eq(u8, keyword, "damage")) {
        applyDamage(sheet, parseU16(firstPart(rest)));
    } else if (eq(u8, keyword, "heal")) {
        applyHeal(sheet, parseU16(firstPart(rest)));
    } else if (eq(u8, keyword, "temp")) {
        sheet.hp_temp = parseU16(rest);
    } else if (eq(u8, keyword, "hitdie")) {
        if (sheet.hit_dice_left > 0) sheet.hit_dice_left -= 1;
        applyHeal(sheet, parseU16(rest));
    } else if (eq(u8, keyword, "rest")) {
        if (eq(u8, rest, "long")) longRest(sheet);
    } else if (eq(u8, keyword, "cast")) {
        const level = parseU8(firstPart(rest));
        if (level >= 1 and level <= SPELL_LEVELS and sheet.slots_left[level - 1] > 0) {
            sheet.slots_left[level - 1] -= 1;
        }
    } else if (eq(u8, keyword, "innate-use")) {
        if (sheet.innate_left > 0) sheet.innate_left -= 1;
    } else if (eq(u8, keyword, "save")) {
        if (eq(u8, rest, "success")) {
            sheet.death_success +|= 1;
        } else if (eq(u8, rest, "failure")) {
            sheet.death_failure +|= 1;
        } else if (eq(u8, rest, "reset")) {
            sheet.death_success = 0;
            sheet.death_failure = 0;
        }
    } else if (eq(u8, keyword, "condition")) {
        setCondition(sheet, rest);
    } else if (eq(u8, keyword, "exhaustion")) {
        sheet.exhaustion = parseU8(rest);
    } else if (eq(u8, keyword, "inspiration")) {
        sheet.inspiration = eq(u8, rest, "on");
    } else if (eq(u8, keyword, "gold")) {
        sheet.coins[@intFromEnum(Coin.gp)] += parseI32(firstPart(rest));
    }
    // A `note`, a `roll`, and anything unknown change nothing on the sheet:
    // they are the journal's, read from the file in order where it is shown.
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
            sheet.skill_prof[@intFromEnum(s)] = true;
            if (expert) sheet.skill_expert[@intFromEnum(s)] = true;
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
    var i: usize = 0;
    while (it.next()) |word| : (i += 1) {
        if (i >= sheet.coins.len) break;
        sheet.coins[i] = parseI32(word);
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
    const state = part(rest, 1);
    if (name.len == 0) return;

    if (std.mem.eql(u8, state, "off")) {
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
    sheet.attacks.append(.{
        .name = part(rest, 0),
        .hit = part(rest, 1),
        .damage = part(rest, 2),
        .notes = part(rest, 3),
    });
}

fn addSpell(sheet: *Sheet, rest: []const u8) void {
    sheet.spells.append(.{
        .name = part(rest, 0),
        .level = parseU8(part(rest, 1)),
        .time = part(rest, 2),
        .range = part(rest, 3),
        .notes = part(rest, 4),
    });
}

fn addItem(sheet: *Sheet, rest: []const u8) void {
    sheet.items.append(.{
        .name = part(rest, 0),
        .quantity = @max(1, parseU16(part(rest, 1))),
        .weight_cp = parseWeight(part(rest, 2)),
    });
}

fn addFeature(sheet: *Sheet, rest: []const u8) void {
    sheet.features.append(.{
        .name = part(rest, 0),
        .note = part(rest, 1),
    });
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
    return std.fmt.bufPrint(buf, "session {d} | {s}", .{ number, date }) catch buf[0..0];
}

pub fn writeDamage(buf: []u8, amount: u16, why: []const u8) []const u8 {
    return writeNumbered(buf, "damage", amount, why);
}

pub fn writeHeal(buf: []u8, amount: u16, why: []const u8) []const u8 {
    return writeNumbered(buf, "heal", amount, why);
}

pub fn writeTemp(buf: []u8, amount: u16) []const u8 {
    return writeNumbered(buf, "temp", amount, "");
}

pub fn writeHitDie(buf: []u8, healed: u16) []const u8 {
    return writeNumbered(buf, "hitdie", healed, "");
}

pub fn writeGold(buf: []u8, delta: i32, why: []const u8) []const u8 {
    return writeNumbered(buf, "gold", delta, why);
}

pub fn writeRest(buf: []u8, long: bool) []const u8 {
    return writeParts(buf, "rest", &.{if (long) "long" else "short"});
}

pub fn writeCast(buf: []u8, level: u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "cast {d} | {s}", .{ level, name }) catch buf[0..0];
}

pub fn writeInnate(buf: []u8) []const u8 {
    return writeParts(buf, "innate-use", &.{});
}

pub fn writeSave(buf: []u8, outcome: []const u8) []const u8 {
    return writeParts(buf, "save", &.{outcome});
}

pub fn writeCondition(buf: []u8, name: []const u8, on: bool) []const u8 {
    return writeParts(buf, "condition", &.{ name, if (on) "on" else "off" });
}

pub fn writeInspiration(buf: []u8, on: bool) []const u8 {
    return writeParts(buf, "inspiration", &.{if (on) "on" else "off"});
}

pub fn writeNote(buf: []u8, text: []const u8) []const u8 {
    return writeParts(buf, "note", &.{text});
}

/// A d20 test: what it was for, the die kept, the modifier, and how it was
/// rolled, so the total can be checked against the line.
pub fn writeRoll(buf: []u8, what: []const u8, die: u8, modifier: i16, how: Roll) []const u8 {
    const sign: []const u8 = if (modifier < 0) "-" else "+";
    const magnitude = @abs(modifier);
    return std.fmt.bufPrint(buf, "roll {s} | {d} | {s}{d} | {s}", .{
        what, die, sign, magnitude, @tagName(how),
    }) catch buf[0..0];
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
    try testing.expectEqual(@as(i32, 36), c.coins[@intFromEnum(Coin.gp)]);
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
    try testing.expectEqual(@as(i32, 43), c.coins[@intFromEnum(Coin.gp)]);
}

test "a gained level raises the maximum and the current by the same" {
    // Level one at eight, then level two to fourteen: six gained, so a
    // character at full stays full, and one that was hurt gains the six.
    try testing.expectEqual(@as(u16, 14), fold(CINAED ++ "\nlevel 2\nhp 14").hp_now);
    try testing.expectEqual(@as(u16, 11), fold(CINAED ++ "\ndamage 3\nlevel 2\nhp 14").hp_now);
    // At level five the proficiency bonus is three.
    try testing.expectEqual(@as(i8, 3), fold(CINAED ++ "\nlevel 5").proficiency());
}

test "the writers spell the grammar the fold reads" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("damage 5 | goblin arrow", writeDamage(&buf, 5, "goblin arrow"));
    try testing.expectEqualStrings("gold -3 | rations", writeGold(&buf, -3, "rations"));
    try testing.expectEqualStrings("rest long", writeRest(&buf, true));
    try testing.expectEqualStrings("cast 1 | Burning Hands", writeCast(&buf, 1, "Burning Hands"));
    try testing.expectEqualStrings("roll Persuasion | 12 | +7 | advantage", writeRoll(&buf, "Persuasion", 12, 7, .advantage));
    try testing.expectEqualStrings("session 4 | 2026-09-06", writeSession(&buf, 4, "2026-09-06"));

    // What a writer spells, the fold reads back to the same effect.
    const line = writeDamage(&buf, 3, "test");
    var journal: [2048]u8 = undefined;
    const whole = std.fmt.bufPrint(&journal, "{s}\n{s}", .{ CINAED, line }) catch unreachable;
    try testing.expectEqual(@as(u16, 5), fold(whole).hp_now);
}
