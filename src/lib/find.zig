//! Finding a thing by typing part of its name.
//!
//! What a launcher needs and a list of any length wants: given what has been
//! typed, whether a name matches, which run of it matched, and how well. The
//! run matters as much as the answer. A list that reorders itself as letters
//! arrive is only trustworthy if each row can say what in it was matched, so
//! the caller gets the span back and draws it differently.
//!
//! The match is a contiguous run, folded for case. Scattered subsequences find
//! more and explain less: "dsk" matching "Disks" reads as a coincidence to
//! anyone looking at the row, and a rank nobody can read is a rank nobody
//! trusts.
//!
//! Ranking is about where the run sits, not how clever the matcher is. A name
//! that starts with what was typed is what was meant; a word inside it that
//! starts with what was typed is probably what was meant; anything else is a
//! coincidence that happens to be spelled the same.
//!
//! Pure, so it is host-tested rather than judged by typing at it.

const str = @import("str.zig");
const std = @import("std");

/// Which run of the name matched, and how strongly.
pub const Match = struct {
    /// Byte offset of the run within the name, and its length. The length is
    /// the query's, since the run is contiguous, but it is carried so the
    /// caller never has to know that.
    at: usize,
    len: usize,
    /// Higher is a better answer. Only comparable between matches on the same
    /// query: it says which of these names was more likely meant, not how
    /// good any of them is.
    score: i32,

    /// The three pieces a row is drawn from: before the run, the run, after.
    pub fn split(self: Match, name: []const u8) Pieces {
        return .{
            .lead = name[0..self.at],
            .hit = name[self.at .. self.at + self.len],
            .tail = name[self.at + self.len ..],
        };
    }
};

pub const Pieces = struct {
    lead: []const u8,
    hit: []const u8,
    tail: []const u8,
};

/// What a match is worth before anything is taken off it.
///
/// The gaps are wide because the deductions below are small: no amount of
/// being short or early lifts a run found in the middle of a name above one
/// that starts it.
const AT_START: i32 = 1000;
const AT_WORD: i32 = 600;
const ANYWHERE: i32 = 200;

/// How much of a deduction the position and the length of the name make.
/// Bounded so a long name is never ranked below a name that did not match.
const POSITION_WEIGHT: i32 = 4;
const LENGTH_WEIGHT: i32 = 1;
const LONGEST_CONSIDERED: i32 = 48;

/// Whether `name` contains `query`, and where.
///
/// An empty query matches everything at the start with nothing highlighted,
/// which is what a field nobody has typed in should do.
pub fn match(name: []const u8, query: []const u8) ?Match {
    if (query.len == 0) return .{ .at = 0, .len = 0, .score = ANYWHERE };
    if (query.len > name.len) return null;

    var at: usize = 0;
    while (at + query.len <= name.len) : (at += 1) {
        if (!str.eqlFold(name[at .. at + query.len], query)) continue;
        return .{ .at = at, .len = query.len, .score = scoreOf(name, at) };
    }
    return null;
}

fn scoreOf(name: []const u8, at: usize) i32 {
    const base: i32 = if (at == 0)
        AT_START
    else if (startsWord(name, at))
        AT_WORD
    else
        ANYWHERE;

    const position: i32 = @intCast(@min(at, @as(usize, @intCast(LONGEST_CONSIDERED))));
    const length: i32 = @intCast(@min(name.len, @as(usize, @intCast(LONGEST_CONSIDERED))));

    // A shorter name is more of it matched, which is why "Pad" beats
    // "Passphrase and other settings" on the same three letters.
    return base - position * POSITION_WEIGHT - length * LENGTH_WEIGHT;
}

/// Whether the byte at `at` begins a word. What separates words here is what
/// separates them in the names this sorts: spaces, and the punctuation a path
/// or a hyphenated name is built from.
fn startsWord(name: []const u8, at: usize) bool {
    if (at == 0) return true;
    return switch (name[at - 1]) {
        ' ', '-', '_', '.', '/', '\t' => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a match is a run of the name, and it says which run" {
    const found = match("Settings", "tin") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), found.at);
    try testing.expectEqual(@as(usize, 3), found.len);

    const pieces = found.split("Settings");
    try testing.expectEqualStrings("Set", pieces.lead);
    try testing.expectEqualStrings("tin", pieces.hit);
    try testing.expectEqualStrings("gs", pieces.tail);
}

test "case is not part of the question" {
    try testing.expect(match("Disks", "di") != null);
    try testing.expect(match("Disks", "DI") != null);
    try testing.expect(match("disks", "Di") != null);
    // And the run is the name's own spelling, not the query's.
    const found = match("Disks", "di").?;
    try testing.expectEqualStrings("Di", found.split("Disks").hit);
}

test "what does not match says so" {
    try testing.expectEqual(@as(?Match, null), match("Settings", "zz"));
    // A query longer than the name cannot be inside it.
    try testing.expectEqual(@as(?Match, null), match("Pad", "Paddle"));
}

test "nothing typed matches everything, highlighting nothing" {
    const found = match("Anything", "") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), found.len);
    try testing.expectEqualStrings("", found.split("Anything").hit);
    try testing.expectEqualStrings("Anything", found.split("Anything").tail);
}

test "the start of a name beats the start of a word beats the middle" {
    const start = match("display 800x480", "di").?;
    const word = match("go display", "di").?;
    const middle = match("audio", "di").?;

    try testing.expect(start.score > word.score);
    try testing.expect(word.score > middle.score);
}

test "the same run in a shorter name ranks higher" {
    const short = match("Pad", "pa").?;
    const long = match("Passphrase and the rest of it", "pa").?;
    try testing.expect(short.score > long.score);
}

test "a name that is long is still ranked above one matched in the middle" {
    // The deductions are bounded on purpose: length is a tie-break, never
    // strong enough to overturn where the run actually sits.
    const long_start = match("disconnect from the wireless network entirely", "di").?;
    const short_middle = match("audio", "di").?;
    try testing.expect(long_start.score > short_middle.score);
}

test "names of the same shape score the same, so the caller breaks the tie" {
    // Which is why ordering is the caller's: two equally good answers should
    // stay in the order their source listed them rather than swap about as
    // letters arrive, and only the caller knows what that order was.
    const a = match("Files", "f").?;
    const b = match("Fonts", "f").?;
    try testing.expectEqual(a.score, b.score);
}
