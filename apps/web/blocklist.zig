//! The sites the reader keeps away from while ad protection is on: those
//! that serve ads, and those that count and follow the people reading.
//!
//! A list of names, each blocked with every name under it, fetched when the
//! reader is built and kept in it as the hash of each name, in order: four
//! bytes a name rather than the name, which runs to eighteen, and a name
//! looked up by halving. A host is on the list where it, or a name it is
//! under, is.
//!
//! Four bytes, and not eight. This machine does its sums in 32 bits, and
//! eight would be twice the room for a risk that is small already: of `n`
//! names kept in 32 bits, one name in 2^32/`n` is taken for one on the list
//! though it is not, which at 35,000 names is one in 120,000. Where that
//! happens, a page does not come, and the setting that turns the list off is
//! the cure. Eight bytes would make it one in five hundred million million.
//!
//! The list is written the way ad blockers write theirs, one `||name^` a
//! line, and `nameOf` reads a line of it for the build.
//!
//! Pure and host-tested.

const std = @import("std");

/// The longest a name can be.
const NAME_MAX = 255;

/// What a name is kept as: 32 bits of xxHash of it, which is what the list
/// is searched by. xxHash answers with all 32 of its bits moved by every
/// letter of the name, where a weaker hash leaves names that differ in one
/// letter near one another, and it costs only the arithmetic this machine
/// has. The seed is a constant, so a list built anywhere reads anywhere.
pub fn hashOf(name: []const u8) u32 {
    return std.hash.XxHash32.hash(SEED, name);
}

const SEED: u32 = 0;

/// The name a line of the list blocks, or none for a line that blocks none:
/// its heading, a comment, or a rule of any other kind than a name and every
/// name under it.
pub fn nameOf(line: []const u8) ?[]const u8 {
    const rule = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, rule, "||") or !std.mem.endsWith(u8, rule, "^")) return null;
    const name = rule[2 .. rule.len - 1];
    if (name.len == 0 or name.len > NAME_MAX) return null;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return null;
    }
    return name;
}

/// Names as the build keeps them: the hash of each, in ascending order.
pub const Blocklist = struct {
    hashes: []const u32,

    /// Whether `host`, or a name it is under, is on the list. Names are
    /// compared in lower case, as the list writes them.
    pub fn blocks(self: Blocklist, host: []const u8) bool {
        var buf: [NAME_MAX]u8 = undefined;
        if (host.len > buf.len) return false;
        var name: []const u8 = std.ascii.lowerString(&buf, host);
        while (true) {
            if (std.sort.binarySearch(u32, self.hashes, hashOf(name), order) != null) return true;
            const dot = std.mem.indexOfScalar(u8, name, '.') orelse return false;
            name = name[dot + 1 ..];
        }
    }

    /// How a name wanted stands against one on the list. `std.math.order`,
    /// with the types named, which is what a search that takes a function
    /// wants.
    fn order(wanted: u32, item: u32) std.math.Order {
        return std.math.order(wanted, item);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A list of `names`, as the build keeps one.
fn listOf(comptime names: []const []const u8) [names.len]u32 {
    var hashes: [names.len]u32 = undefined;
    for (&hashes, names) |*hash, name| hash.* = hashOf(name);
    std.mem.sort(u32, &hashes, {}, std.sort.asc(u32));
    return hashes;
}

test "a host is blocked where it or a name it is under is on the list" {
    const hashes = listOf(&.{ "ads.example", "tracker.test" });
    const list = Blocklist{ .hashes = &hashes };
    try testing.expect(list.blocks("ads.example"));
    try testing.expect(list.blocks("cdn.ads.example"));
    try testing.expect(list.blocks("CDN.Ads.Example"));
    try testing.expect(list.blocks("tracker.test"));
    // A name that only ends the same way is not under it.
    try testing.expect(!list.blocks("myads.example"));
    try testing.expect(!list.blocks("example"));
    try testing.expect(!list.blocks("reader.test"));
}

test "an empty list blocks nothing" {
    const list = Blocklist{ .hashes = &.{} };
    try testing.expect(!list.blocks("ads.example"));
}

test "a line of the list names what it blocks, and a line of anything else names nothing" {
    try testing.expectEqualStrings("ads.example", nameOf("||ads.example^").?);
    try testing.expectEqualStrings("ads.example", nameOf("||ads.example^\r").?);
    try testing.expect(nameOf("[Adblock Plus]") == null);
    try testing.expect(nameOf("! Title: a list") == null);
    try testing.expect(nameOf("") == null);
    try testing.expect(nameOf("||^") == null);
    try testing.expect(nameOf("||ads.example^$third-party") == null);
    try testing.expect(nameOf("##.banner") == null);
}

test "a name is hashed whole, into four bytes" {
    try testing.expectEqual(32, @bitSizeOf(@TypeOf(hashOf("ads.example"))));
    for ([_][]const u8{ "bds.example", "ads.examplf", "ads.example.com", "ads.examples" }) |other| {
        try testing.expect(hashOf("ads.example") != hashOf(other));
    }
}
