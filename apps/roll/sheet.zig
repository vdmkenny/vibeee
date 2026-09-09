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
//!
//! What has been decided is written down, because a card holds more frames
//! than anyone culls in one sitting. The text of that is here too: it is a
//! statement about the marks, and the marks are what this holds.

const std = @import("std");
const Bounded = @import("lib").Bounded;
const str = @import("lib").str;

/// How many pictures one roll holds.
///
/// A card, rather than a window's worth. A camera fills a card with hundreds
/// of frames and a contact sheet that showed the first ninety-six of them
/// would not be a contact sheet: the whole of what is on the card is the
/// thing being looked at. The listing this is filled from is bounded to
/// match, and a roll longer than this says it is short rather than stopping
/// quietly.
pub const MAX = 1024;

/// How many a page holds before a window has measured itself: five across and
/// three down at 800 by 480, once the bar, the places and the keys have had
/// their rows. What a window actually fits it says with `per_page`.
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
    /// A mark has been made since this was last written down.
    dirty: bool = false,
    /// How the roll stands, kept as marks are made rather than counted.
    ///
    /// The strip says this and a strip is drawn whenever the pointer twitches,
    /// so counting it there is the whole roll walked for a picture nobody
    /// touched. `set` is the one place a mark changes, which is what makes a
    /// running total safe to keep.
    tally: Counts = .{},

    /// Empty it, keeping what the window measured about itself: how many
    /// fit on a page is a fact about the window, not about the roll.
    pub fn clear(self: *Sheet) void {
        self.* = .{ .per_page = self.per_page };
    }

    /// Take one more picture, or say there was no room.
    pub fn add(self: *Sheet, shot: Shot) void {
        self.shots.append(shot) catch {
            self.truncated = true;
            return;
        };
        self.tally.all += 1;
        self.tallied(shot.mark, 1);
    }

    /// Decide about one picture of the roll, wherever it sits.
    ///
    /// The one place a mark changes, so the running total cannot drift from
    /// what the marks say.
    pub fn set(self: *Sheet, which: usize, how: Mark) void {
        const shot = &self.shots.mutable()[which];
        if (shot.mark == how) return;

        self.tallied(shot.mark, -1);
        shot.mark = how;
        self.tallied(how, 1);
        self.dirty = true;
    }

    /// Move the running total by one, either way.
    fn tallied(self: *Sheet, what: Mark, by: isize) void {
        const field = switch (what) {
            .keep => &self.tally.kept,
            .reject => &self.tally.rejected,
            .none => return,
        };
        field.* = @intCast(@as(isize, @intCast(field.*)) + by);
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
    ///
    /// With no filter the two are the same number, which is worth saying
    /// because the window asks this once per cell on every pass: walking a
    /// thousand shots once per cell to answer what the index already
    /// says is the whole roll counted afresh for every twitch of the pointer.
    pub fn at_nth(self: *const Sheet, nth: usize) ?usize {
        if (!self.kept_only) return if (nth < self.shots.len) nth else null;

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
        const which = self.at_nth(self.at) orelse return;
        const again = self.shots.slice()[which].mark == how;
        self.set(which, if (again) .none else how);

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
        return self.tally;
    }

    // -----------------------------------------------------------------------
    // What has been decided, written down
    // -----------------------------------------------------------------------

    /// What a caller writes beside the pictures: a stamp saying what wrote it
    /// and in which shape, then one line per picture that has been decided
    /// about, and nothing for the ones that have not.
    ///
    /// The mark first and the name to the end of the line, so a photograph
    /// with a space in its name reads back as the name it has. Plain text
    /// because somebody may want to look at it, and because a file this
    /// system cannot read back is a file it should not have written.
    pub fn writeMarks(self: *const Sheet, into: *str.Builder) void {
        into.text(STAMP);
        into.number(FORMAT);
        into.byte('\n');
        into.text(HEADING);

        for (self.shots.slice()) |shot| {
            into.text(switch (shot.mark) {
                .keep => "keep ",
                .reject => "reject ",
                .none => continue,
            });
            into.text(shot.name);
            into.byte('\n');
        }
    }

    /// Which shape the lines are in. A reader that meets a number it does not
    /// know leaves the file alone rather than reading what it can of it: half
    /// a set of decisions is worse than none, and writing over one would lose
    /// whatever the rest of it said.
    pub const FORMAT = 1;
    const STAMP = "# roll marks ";

    const HEADING =
        \\# What has been decided about the photographs here.
        \\#
        \\# One line per picture: keep or reject, then its name. Anything not
        \\# named here has not been decided about. Safe to delete: it says
        \\# nothing the pictures themselves do not.
        \\
    ;

    /// Whether a file was this program's to read, and so to write over.
    pub const Reading = enum {
        /// Read, and what it said applied.
        taken,
        /// Not written by a roll this one understands. What is in it is left
        /// as it is, marks and all.
        foreign,
    };

    /// Take the marks back off a file, matching by name.
    ///
    /// A name the roll does not hold is skipped rather than refused: a card
    /// culled and then added to is the ordinary case, and so is one whose
    /// pictures have been copied off and deleted.
    pub fn readMarks(self: *Sheet, text: []const u8) Reading {
        if (!ours(text)) return .foreign;

        var lines = str.lines(text);
        while (lines.next()) |line| {
            const said = str.trim(line);
            if (said.len == 0 or said[0] == '#') continue;

            const how: Mark = if (std.mem.startsWith(u8, said, "keep "))
                .keep
            else if (std.mem.startsWith(u8, said, "reject "))
                .reject
            else
                continue;

            const name = str.trim(said[if (how == .keep) "keep ".len else "reject ".len..]);
            for (self.shots.slice(), 0..) |shot, which| {
                if (!std.mem.eql(u8, shot.name, name)) continue;
                self.set(which, how);
                break;
            }
        }

        // Read back rather than decided: what is on the medium already says
        // this, so there is nothing to write until somebody changes it.
        self.dirty = false;
        return .taken;
    }

    /// Whether the stamp says this is a roll's own file, in a shape this one
    /// knows.
    fn ours(text: []const u8) bool {
        if (!std.mem.startsWith(u8, text, STAMP)) return false;
        const rest = text[STAMP.len..];
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const said = str.unsigned(str.trim(rest[0..end])) orelse return false;
        return said <= FORMAT;
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
    sheet.set(1, .keep);
    sheet.set(3, .keep);

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
    sheet.set(0, .keep);

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
    for (0..sheet.shots.len) |i| sheet.set(i, .keep);
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

test "unfiltered, a place in what is shown is a place in the roll" {
    var sheet = rollOf(40);
    sheet.set(7, .keep);

    try testing.expectEqual(@as(?usize, 0), sheet.at_nth(0));
    try testing.expectEqual(@as(?usize, 39), sheet.at_nth(39));
    try testing.expectEqual(@as(?usize, null), sheet.at_nth(40));

    // And with the filter on it is the walk, which is the same answer for
    // the one picture the filter leaves.
    sheet.filter(true);
    try testing.expectEqual(@as(?usize, 7), sheet.at_nth(0));
    try testing.expectEqual(@as(?usize, null), sheet.at_nth(1));
}

fn named(sheet: *Sheet, names: []const []const u8) void {
    sheet.clear();
    for (names) |name| sheet.add(.{ .name = name, .size = 1 });
}

test "what was decided reads back off what was written" {
    var sheet = Sheet{};
    named(&sheet, &.{ "DSC_0001.JPG", "a photo with spaces.jpg", "DSC_0003.NEF" });
    sheet.set(0, .keep);
    sheet.set(1, .reject);
    try testing.expect(sheet.dirty);

    var room: [512]u8 = undefined;
    var written = str.Builder{ .buf = &room };
    sheet.writeMarks(&written);
    const text = written.done();
    try testing.expect(!written.cut);

    // Nothing is said about the picture nobody decided about.
    try testing.expect(std.mem.indexOf(u8, text, "DSC_0003.NEF") == null);

    var again = Sheet{};
    named(&again, &.{ "DSC_0003.NEF", "DSC_0001.JPG", "a photo with spaces.jpg" });
    try testing.expectEqual(Sheet.Reading.taken, again.readMarks(text));

    // Matched by name rather than by place, and a name with spaces in it is
    // the name it has.
    try testing.expectEqual(Mark.none, again.shots.slice()[0].mark);
    try testing.expectEqual(Mark.keep, again.shots.slice()[1].mark);
    try testing.expectEqual(Mark.reject, again.shots.slice()[2].mark);
    try testing.expectEqual(@as(usize, 1), again.counts().kept);
    try testing.expectEqual(@as(usize, 1), again.counts().rejected);

    // Read back rather than decided, so there is nothing to write yet.
    try testing.expect(!again.dirty);
}

test "a file this roll does not understand is left alone" {
    var sheet = Sheet{};
    named(&sheet, &.{"DSC_0001.JPG"});

    // A later shape of the same file: refused whole, because reading what
    // this happens to recognise and writing the result back would lose
    // whatever the rest of it said.
    var room: [128]u8 = undefined;
    var later = str.Builder{ .buf = &room };
    later.text("# roll marks ");
    later.number(Sheet.FORMAT + 1);
    later.text("\nkeep DSC_0001.JPG\n");
    try testing.expectEqual(Sheet.Reading.foreign, sheet.readMarks(later.done()));
    try testing.expectEqual(Mark.none, sheet.shots.slice()[0].mark);

    // And something else entirely that happens to share the name.
    try testing.expectEqual(Sheet.Reading.foreign, sheet.readMarks("keep DSC_0001.JPG\n"));
    try testing.expectEqual(Sheet.Reading.foreign, sheet.readMarks(""));
    try testing.expectEqual(Mark.none, sheet.shots.slice()[0].mark);
}

test "the running total says what the marks say" {
    var sheet = rollOf(5);

    // Marking, marking again the same way, and marking the other way all
    // have to leave the total agreeing with the marks, which is the whole
    // reason it is kept rather than counted.
    sheet.mark(.keep);
    sheet.mark(.keep);
    sheet.at = 0;
    sheet.mark(.keep);
    sheet.at = 0;
    sheet.mark(.keep);
    sheet.at = 0;
    sheet.mark(.reject);

    var walked = Counts{ .all = sheet.shots.len };
    for (sheet.shots.slice()) |shot| {
        switch (shot.mark) {
            .keep => walked.kept += 1,
            .reject => walked.rejected += 1,
            .none => {},
        }
    }
    try testing.expectEqual(walked, sheet.counts());

    // And an emptied roll counts nothing.
    sheet.clear();
    try testing.expectEqual(Counts{}, sheet.counts());
}

test "the counts are of the whole roll, not of what is shown" {
    var sheet = rollOf(4);
    sheet.set(0, .keep);
    sheet.set(1, .reject);
    sheet.set(2, .keep);

    sheet.filter(true);
    const seen = sheet.counts();
    try testing.expectEqual(@as(usize, 4), seen.all);
    try testing.expectEqual(@as(usize, 2), seen.kept);
    try testing.expectEqual(@as(usize, 1), seen.rejected);
}
