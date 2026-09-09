//! The roll: what is on the card, what has been marked, and which of it is
//! being looked at.
//!
//! Pure. No files, no pixels, no syscalls: the window above reads the
//! directory and draws, and everything about which picture is current, what a
//! page holds and what a filter leaves is decided here, where it can be
//! tested without a machine.
//!
//! A page rather than a scroll, because the panel this is for has no scroll
//! to give: walking past the edge of a page turns it, the way `eeemod` turns
//! a pattern rather than sliding one.

const std = @import("std");
const Bounded = @import("lib").Bounded;

/// How many pictures one roll holds. The listing this is filled from is
/// bounded too, and a roll that stopped without saying so would be worse than
/// one that says it is short.
pub const MAX = 96;

/// How many fit on the panel at once: five across and three down at 800 by
/// 480, once the bar, the places and the keys have had their rows. The
/// starting figure; a window in half the display fits fewer and says so.
pub const PER_PAGE = 15;

/// What has been decided about a picture.
pub const Mark = enum {
    none,
    keep,
    reject,
};

/// One picture, as the sheet needs it. The name points at the window's own
/// storage, so that has to outlive the sheet.
pub const Shot = struct {
    name: []const u8 = "",
    size: u32 = 0,
    mtime: i64 = 0,
    /// A quarter turn on top of the way the camera held it, kept per picture
    /// and never written to the file.
    turn: u2 = 0,
    mark: Mark = .none,
};

/// Where a page starts and ends, as a caller drawing one needs it.
pub const Page = struct {
    from: usize = 0,
    /// One past the last, so the pair slices.
    to: usize = 0,
};

/// How the roll stands.
pub const Counts = struct {
    all: usize = 0,
    kept: usize = 0,
    rejected: usize = 0,
};

pub const Sheet = struct {
    shots: Bounded(Shot, MAX) = .{},
    /// Which picture is current, counted over what the filter leaves rather
    /// than over the whole roll: it is a place in what is on screen.
    at: usize = 0,
    /// Only the kept ones are shown.
    kept_only: bool = false,
    /// The directory held more than a roll does.
    truncated: bool = false,
    /// How many the window can show at once. The window measures its own
    /// grid and says, because what a page holds is what fits on it and this
    /// decides which page the current picture is on.
    per_page: usize = PER_PAGE,

    /// Empty it, keeping what the window measured about itself: how many
    /// fit on a page is a fact about the window, not about the roll.
    pub fn clear(self: *Sheet) void {
        self.* = .{ .per_page = self.per_page };
    }

    /// Take one more picture, or say there was no room.
    pub fn add(self: *Sheet, shot: Shot) void {
        self.shots.append(shot) catch {
            self.truncated = true;
        };
    }

    /// How many the filter leaves.
    pub fn count(self: *const Sheet) usize {
        if (!self.kept_only) return self.shots.len;

        var seen: usize = 0;
        for (self.shots.slice()) |shot| {
            if (shot.mark == .keep) seen += 1;
        }
        return seen;
    }

    /// Where the nth shown picture sits in the whole roll.
    pub fn at_nth(self: *const Sheet, nth: usize) ?usize {
        var seen: usize = 0;
        for (self.shots.slice(), 0..) |shot, i| {
            if (self.kept_only and shot.mark != .keep) continue;
            if (seen == nth) return i;
            seen += 1;
        }
        return null;
    }

    /// The picture being looked at, or nothing when the filter leaves none.
    pub fn current(self: *Sheet) ?*Shot {
        const which = self.at_nth(self.at) orelse return null;
        return &self.shots.mutable()[which];
    }

    /// Move by `by` places through what is shown, stopping at either end.
    ///
    /// Stopping rather than wrapping: a roll has a first and a last picture,
    /// and arriving back at the beginning is never what pressing right again
    /// meant.
    pub fn move(self: *Sheet, by: isize) void {
        const shown = self.count();
        if (shown == 0) {
            self.at = 0;
            return;
        }

        const last: isize = @intCast(shown - 1);
        const wanted = @as(isize, @intCast(self.at)) + by;
        self.at = @intCast(std.math.clamp(wanted, 0, last));
    }

    /// Keep or reject the current picture, and walk on.
    ///
    /// Walking on is what culling is: the decision and the next picture are
    /// one gesture. Marking the same way twice takes the mark off again,
    /// which is the only way back from a slip.
    pub fn mark(self: *Sheet, how: Mark) void {
        const shot = self.current() orelse return;
        const again = shot.mark == how;
        shot.mark = if (again) .none else how;

        // With only the kept ones shown, un-keeping takes the picture out
        // from under the cursor, so what was next has moved into its place.
        if (self.kept_only and again) {
            self.move(0);
            return;
        }
        self.move(1);
    }

    /// Turn the current picture a quarter, either way.
    pub fn turn(self: *Sheet, by: i2) void {
        const shot = self.current() orelse return;
        const quarters = @as(i32, shot.turn) + by;
        shot.turn = @intCast(@mod(quarters, 4));
    }

    /// Show only what is kept, or all of it again.
    ///
    /// The picture being looked at is kept under the cursor where the filter
    /// leaves it, so turning the filter on does not move somebody somewhere
    /// else in the roll.
    pub fn filter(self: *Sheet, only: bool) void {
        const was = self.at_nth(self.at);
        self.kept_only = only;

        if (was) |which| {
            if (self.place(which)) |now| {
                self.at = now;
                return;
            }
        }
        self.move(0);
    }

    /// Where a picture of the whole roll sits in what is shown, or nothing
    /// when the filter leaves it out.
    fn place(self: *const Sheet, which: usize) ?usize {
        var seen: usize = 0;
        for (self.shots.slice(), 0..) |shot, i| {
            if (self.kept_only and shot.mark != .keep) continue;
            if (i == which) return seen;
            seen += 1;
        }
        return null;
    }

    /// The page the current picture is on.
    pub fn page(self: *const Sheet) Page {
        const shown = self.count();
        const per = @max(self.per_page, 1);
        const from = self.at - self.at % per;
        return .{ .from = from, .to = @min(from + per, shown) };
    }

    pub fn counts(self: *const Sheet) Counts {
        var out = Counts{ .all = self.shots.len };
        for (self.shots.slice()) |shot| {
            switch (shot.mark) {
                .keep => out.kept += 1,
                .reject => out.rejected += 1,
                .none => {},
            }
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn rollOf(n: usize) Sheet {
    var sheet = Sheet{};
    var i: usize = 0;
    while (i < n) : (i += 1) sheet.add(.{ .name = "DSC_0000.JPG", .size = 1 });
    return sheet;
}

test "walking stops at both ends rather than wrapping" {
    var sheet = rollOf(4);

    sheet.move(-1);
    try testing.expectEqual(@as(usize, 0), sheet.at);

    sheet.move(3);
    try testing.expectEqual(@as(usize, 3), sheet.at);

    sheet.move(1);
    try testing.expectEqual(@as(usize, 3), sheet.at);

    // A whole page down from the first lands on the last where the roll is
    // shorter than a page.
    sheet.at = 0;
    sheet.move(PER_PAGE);
    try testing.expectEqual(@as(usize, 3), sheet.at);
}

test "marking walks on, and marking again takes it off" {
    var sheet = rollOf(3);

    sheet.mark(.keep);
    try testing.expectEqual(Mark.keep, sheet.shots.slice()[0].mark);
    try testing.expectEqual(@as(usize, 1), sheet.at);

    sheet.mark(.reject);
    try testing.expectEqual(Mark.reject, sheet.shots.slice()[1].mark);

    // Back onto the second, and the same key again clears it.
    sheet.at = 1;
    sheet.mark(.reject);
    try testing.expectEqual(Mark.none, sheet.shots.slice()[1].mark);
}

test "the last picture keeps the cursor when it is marked" {
    var sheet = rollOf(2);
    sheet.at = 1;
    sheet.mark(.keep);

    // Nowhere further to walk, so it stays where it is rather than falling
    // off the end.
    try testing.expectEqual(@as(usize, 1), sheet.at);
    try testing.expectEqual(Mark.keep, sheet.shots.slice()[1].mark);
}

test "the filter keeps the eye on the same picture" {
    var sheet = rollOf(5);
    sheet.shots.mutable()[1].mark = .keep;
    sheet.shots.mutable()[3].mark = .keep;

    // Looking at the fourth, which is kept: with only the kept shown it is
    // the second of two, and it is still the one being looked at.
    sheet.at = 3;
    sheet.filter(true);
    try testing.expectEqual(@as(usize, 2), sheet.count());
    try testing.expectEqual(@as(usize, 1), sheet.at);
    try testing.expectEqual(&sheet.shots.slice()[3], sheet.current().?);

    // And back again.
    sheet.filter(false);
    try testing.expectEqual(@as(usize, 3), sheet.at);
}

test "a filter that leaves out what was being looked at lands somewhere real" {
    var sheet = rollOf(4);
    sheet.shots.mutable()[0].mark = .keep;

    sheet.at = 2;
    sheet.filter(true);
    try testing.expectEqual(@as(usize, 1), sheet.count());
    try testing.expectEqual(@as(usize, 0), sheet.at);
    try testing.expectEqual(&sheet.shots.slice()[0], sheet.current().?);
}

test "with nothing kept there is nothing to look at" {
    var sheet = rollOf(3);
    sheet.filter(true);

    try testing.expectEqual(@as(usize, 0), sheet.count());
    try testing.expectEqual(@as(?*Shot, null), sheet.current());

    // Nothing to mark, nothing to turn, and neither is a fault.
    sheet.mark(.keep);
    sheet.turn(1);
    try testing.expectEqual(@as(usize, 0), sheet.at);
}

test "un-keeping while only the kept are shown does not walk past the end" {
    var sheet = rollOf(3);
    for (sheet.shots.mutable()) |*shot| shot.mark = .keep;
    sheet.filter(true);
    sheet.at = 2;

    sheet.mark(.keep);
    try testing.expectEqual(@as(usize, 2), sheet.count());
    // The last of what is left, rather than one past it.
    try testing.expectEqual(@as(usize, 1), sheet.at);
}

test "a turn is a quarter, and four of them come back round" {
    var sheet = rollOf(1);

    sheet.turn(1);
    try testing.expectEqual(@as(u2, 1), sheet.shots.slice()[0].turn);

    sheet.turn(-1);
    try testing.expectEqual(@as(u2, 0), sheet.shots.slice()[0].turn);

    // Backwards from upright is a left turn, not a fault.
    sheet.turn(-1);
    try testing.expectEqual(@as(u2, 3), sheet.shots.slice()[0].turn);

    sheet.turn(1);
    try testing.expectEqual(@as(u2, 0), sheet.shots.slice()[0].turn);
}

test "a window that fits fewer pages them fewer" {
    var sheet = rollOf(38);
    sheet.per_page = 10;

    try testing.expectEqual(Page{ .from = 0, .to = 10 }, sheet.page());

    sheet.at = 25;
    try testing.expectEqual(Page{ .from = 20, .to = 30 }, sheet.page());

    // And a window with room for nothing still names a page rather than
    // dividing by nothing.
    sheet.per_page = 0;
    sheet.at = 3;
    try testing.expectEqual(Page{ .from = 3, .to = 4 }, sheet.page());
}

test "emptying the roll keeps what the window measured" {
    var sheet = rollOf(4);
    sheet.per_page = 6;
    sheet.clear();
    try testing.expectEqual(@as(usize, 6), sheet.per_page);
}

test "the page is the one the current picture is on" {
    var sheet = rollOf(38);

    try testing.expectEqual(Page{ .from = 0, .to = 15 }, sheet.page());

    sheet.at = 14;
    try testing.expectEqual(Page{ .from = 0, .to = 15 }, sheet.page());

    // One further turns it.
    sheet.at = 15;
    try testing.expectEqual(Page{ .from = 15, .to = 30 }, sheet.page());

    // The last page is as short as what is left.
    sheet.at = 37;
    try testing.expectEqual(Page{ .from = 30, .to = 38 }, sheet.page());
}

test "a roll longer than one holds says so rather than stopping quietly" {
    const sheet = rollOf(MAX + 4);

    try testing.expectEqual(@as(usize, MAX), sheet.shots.len);
    try testing.expect(sheet.truncated);
}

test "the counts are of the whole roll, not of what is shown" {
    var sheet = rollOf(4);
    sheet.shots.mutable()[0].mark = .keep;
    sheet.shots.mutable()[1].mark = .reject;
    sheet.shots.mutable()[2].mark = .keep;

    sheet.filter(true);
    const seen = sheet.counts();
    try testing.expectEqual(@as(usize, 4), seen.all);
    try testing.expectEqual(@as(usize, 2), seen.kept);
    try testing.expectEqual(@as(usize, 1), seen.rejected);
}
