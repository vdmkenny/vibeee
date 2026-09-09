//! The mount table, as a program reads it.
//!
//! The kernel says what is mounted as one line per volume, and three programs
//! were taking it apart: a file manager drawing a row of places, a monitor
//! watching how full home is, and a contact sheet looking for a card. Each
//! read the same line differently, and the fields are named rather than
//! positional precisely so that they cannot be read differently.
//!
//! One line per volume:
//!
//!     /home on hd0p3 free=10362880 size=15728640
//!
//! Pure. The text arrives from whoever asked the kernel for it, so this is
//! host-tested and the same code answers on either side of a syscall.

const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const str = @import("str.zig");

/// How many volumes a machine of this shape has: the system, the settings,
/// home, and whatever is plugged in. A budget rather than a rule.
pub const MAX = 8;

/// The longest path a volume is mounted at, and the longest a table comes to.
pub const PATH = 64;
pub const TEXT = 512;

/// Where a person's own files are, and where a volume the bus finds is put.
/// Everything else mounted is the machine's own.
pub const HOME = "/home";
pub const MEDIA = "/media";

/// Which volumes a caller wants out of the table.
pub const Want = enum {
    /// Everything mounted, which is what a file manager shows.
    all,
    /// The ones a person keeps files on: home, and whatever is plugged in.
    /// The root and the settings volume are the machine's own, and a window
    /// about somebody's photographs has no business offering them.
    personal,
};

/// One volume. How full it is is optional because a device may not say.
pub const Volume = struct {
    at: Bounded(u8, PATH) = .{},
    /// Bytes, as wide as this machine counts them, which is what the text
    /// they were read from can say.
    free: usize = 0,
    size: usize = 0,

    /// Where it is mounted, which is what pressing it goes to.
    pub fn path(self: *const Volume) []const u8 {
        return self.at.slice();
    }

    /// What somebody calls it: the last part of the path, because that is
    /// the word people use. The root has no last part and is the machine.
    pub fn name(self: *const Volume) []const u8 {
        const whole = self.path();
        if (std.mem.eql(u8, whole, "/")) return "system";

        var at = whole.len;
        while (at > 0) : (at -= 1) {
            if (whole[at - 1] == '/') return whole[at..];
        }
        return whole;
    }

    /// Whether this is a volume a person keeps their own files on.
    pub fn personal(self: *const Volume) bool {
        const at = self.path();
        return std.mem.eql(u8, at, HOME) or std.mem.startsWith(u8, at, MEDIA ++ "/");
    }

    /// Whether the device said how full it is.
    pub fn known(self: *const Volume) bool {
        return self.size != 0;
    }

    /// How full, out of a hundred. Nought for a device that did not say,
    /// which draws as an empty gauge rather than as a wrong one.
    ///
    /// Scaled down before dividing rather than multiplied up first: a volume
    /// of a few gigabytes times a hundred is past what a machine this wide
    /// multiplies, and the answer is two digits either way.
    pub fn percent(self: *const Volume) u8 {
        if (self.size == 0) return 0;
        const step = @max(self.size / 100, 1);
        return @intCast(@min((self.size -| self.free) / step, 100));
    }
};

/// Every volume, and the table they were read from.
///
/// The table is kept so a reader can tell a change from a redraw: a medium
/// arrives while a window is open and nothing announces one, so the window
/// asks now and then and wants to know only when the answer is different.
pub const List = struct {
    items: Bounded(Volume, MAX) = .{},
    seen: [TEXT]u8 = @splat(0),
    seen_len: usize = 0,

    pub fn slice(self: *const List) []const Volume {
        return self.items.slice();
    }

    /// Take the table apart. True when it says something different from the
    /// last one, which is the only time a caller has anything to redraw.
    pub fn read(self: *List, text: []const u8, want: Want) bool {
        const kept = text[0..@min(text.len, self.seen.len)];
        if (kept.len == self.seen_len and std.mem.eql(u8, kept, self.seen[0..self.seen_len])) {
            return false;
        }
        @memcpy(self.seen[0..kept.len], kept);
        self.seen_len = kept.len;

        self.items = .{};
        var lines = str.lines(self.seen[0..self.seen_len]);
        while (lines.next()) |line| {
            const one = parse(str.trim(line)) orelse continue;
            if (want == .personal and !one.personal()) continue;
            self.items.append(one) catch break;
        }
        return true;
    }

    /// The volume a path is on: the longest mount point it lies under, since
    /// a path under `/home` is on home and not on the root it also lies
    /// under.
    pub fn holding(self: *const List, path: []const u8) ?usize {
        var best: ?usize = null;
        for (self.slice(), 0..) |volume, index| {
            const at = volume.path();
            if (!std.mem.startsWith(u8, path, at)) continue;
            // A prefix that stops mid-name is not a mount point: "/home" does
            // not hold "/homework".
            if (path.len > at.len and at[at.len - 1] != '/' and path[at.len] != '/') continue;
            if (best == null or at.len > self.slice()[best.?].path().len) best = index;
        }
        return best;
    }
};

/// One line. Null for a line that names no path, which is what "none" is.
pub fn parse(line: []const u8) ?Volume {
    var words: [8][]const u8 = undefined;
    const count = str.splitWords(line, &words);
    if (count == 0) return null;

    var at = Bounded(u8, PATH){};
    if (!at.set(words[0]) or at.len == 0 or at.slice()[0] != '/') return null;

    var out = Volume{ .at = at };
    for (words[1..count]) |word| {
        // Named rather than positional: this line is read by a shell command,
        // a file manager and a monitor, and the three must not disagree about
        // which number is which.
        if (std.mem.startsWith(u8, word, "free=")) out.free = str.unsigned(word["free=".len..]) orelse 0;
        if (std.mem.startsWith(u8, word, "size=")) out.size = str.unsigned(word["size=".len..]) orelse 0;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TABLE =
    \\/ on rd0 free=1048576 size=2097152
    \\/media/hd0p1 on hd0p1 free=8388608 size=15728640
    \\/cfg on hd0p2 free=15000000 size=15728640
    \\/home on hd0p3 free=10362880 size=15728640
;

test "a table reads as one volume per line" {
    var list = List{};
    try testing.expect(list.read(TABLE, .all));
    try testing.expectEqual(@as(usize, 4), list.slice().len);

    try testing.expectEqualStrings("/home", list.slice()[3].path());
    try testing.expectEqualStrings("home", list.slice()[3].name());
    try testing.expectEqual(@as(usize, 10362880), list.slice()[3].free);
    try testing.expect(list.slice()[3].known());

    // The root has no last part, so it is called what it is.
    try testing.expectEqualStrings("system", list.slice()[0].name());
    // And a volume under /media is called by its device.
    try testing.expectEqualStrings("hd0p1", list.slice()[1].name());
}

test "the same table twice says nothing changed" {
    var list = List{};
    try testing.expect(list.read(TABLE, .all));
    try testing.expect(!list.read(TABLE, .all));

    // A volume gone is a different table, and the list follows it.
    try testing.expect(list.read("/ on rd0 free=1 size=2", .all));
    try testing.expectEqual(@as(usize, 1), list.slice().len);
}

test "how full is worked out from what the device said, and nought when it said nothing" {
    const half = parse("/home on hd0p3 free=50 size=100").?;
    try testing.expectEqual(@as(u8, 50), half.percent());
    try testing.expect(half.known());

    const quiet = parse("/media/usb0 on usb0").?;
    try testing.expect(!quiet.known());
    try testing.expectEqual(@as(u8, 0), quiet.percent());

    // A device claiming more free than it has is full at nought, not below.
    const odd = parse("/x on y free=200 size=100").?;
    try testing.expectEqual(@as(u8, 0), odd.percent());

    // A volume large enough that a hundred times its size is past what this
    // machine multiplies still answers, and answers within a point: dividing
    // first truncates, which costs at most one of the two digits shown.
    const card = parse("/media/sd0 on sd0 free=1073741824 size=4294967000").?;
    try testing.expectEqual(@as(u8, 74), card.percent());
}

test "a line naming no volume is not one" {
    try testing.expectEqual(@as(?Volume, null), parse("none"));
    try testing.expectEqual(@as(?Volume, null), parse(""));
    try testing.expectEqual(@as(?Volume, null), parse("free=1 size=2"));
}

test "a window about somebody's files is offered only their volumes" {
    var list = List{};
    try testing.expect(list.read(TABLE, .personal));

    // Home and what is plugged in; not the root, and not the settings.
    try testing.expectEqual(@as(usize, 2), list.slice().len);
    try testing.expectEqualStrings("/media/hd0p1", list.slice()[0].path());
    try testing.expectEqualStrings("/home", list.slice()[1].path());

    // A name that merely begins the same is not one of them.
    try testing.expect(!parse("/homework on x").?.personal());
    try testing.expect(!parse("/mediaeval on x").?.personal());
    try testing.expect(parse("/media/sd0 on x").?.personal());
}

test "a path is on the longest mount point it lies under" {
    var list = List{};
    _ = list.read(TABLE, .all);

    try testing.expectEqual(@as(?usize, 3), list.holding("/home/pictures/photo.jpg"));
    try testing.expectEqual(@as(?usize, 1), list.holding("/media/hd0p1/DCIM"));
    try testing.expectEqual(@as(?usize, 0), list.holding("/bin/ls"));
    try testing.expectEqual(@as(?usize, 3), list.holding("/home"));

    // A name that merely starts the same is somewhere else entirely.
    try testing.expectEqual(@as(?usize, 0), list.holding("/homework"));
}

test "a table longer than one holds is cut rather than run past" {
    var list = List{};
    var long: [TEXT * 2]u8 = undefined;
    var built = str.Builder{ .buf = &long };
    var n: usize = 0;
    while (n < MAX + 4) : (n += 1) {
        built.text("/v");
        built.number(n);
        built.text(" on d free=1 size=2\n");
    }
    _ = list.read(built.done(), .all);
    try testing.expect(list.slice().len <= MAX);
}
