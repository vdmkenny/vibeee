//! The name a machine answers to.
//!
//! One name, used everywhere the machine has to say who it is: the
//! hostname a lease request carries, what a name lookup on the local
//! network resolves, and whatever a later protocol asks the same question
//! with. Kept here rather than in the network service because it is the
//! machine's identity and not the network's, and a machine with two
//! answers to that question is one nobody can find twice.
//!
//! Pure, so it lives in `lib` where tests actually run.

const std = @import("std");
const str = @import("str.zig");

/// A hostname is one DNS label: sixty-three octets at most, letters,
/// digits and hyphens, and a hyphen at neither end.
pub const MAX = 63;

/// What an unconfigured machine calls itself.
///
/// The suffix comes from the machine's own address rather than from a
/// random number, so the name is the same on Tuesday as it was on Monday.
/// A name that changes every boot fills a router's lease table with
/// strangers and makes the machine unfindable by the one means anybody
/// would try, which is the opposite of what a default name is for.
pub const PREFIX = "vibeee-";

pub const Hostname = struct {
    bytes: [MAX]u8 = @splat(0),
    len: u8 = 0,

    pub fn slice(self: *const Hostname) []const u8 {
        return self.bytes[0..@min(self.len, MAX)];
    }

    pub fn isEmpty(self: Hostname) bool {
        return self.len == 0;
    }

    /// A name given by hand, if it is one a name may be.
    pub fn of(text: []const u8) ?Hostname {
        if (text.len == 0 or text.len > MAX) return null;
        if (text[0] == '-' or text[text.len - 1] == '-') return null;

        var out = Hostname{ .len = @intCast(text.len) };
        for (text, 0..) |c, i| {
            if (!isNameByte(c)) return null;
            // A name is compared without regard to case, so it is kept in
            // the one that reads as a name rather than as an initialism.
            out.bytes[i] = lower(c);
        }
        return out;
    }

    /// The default name for a machine with this address: the prefix and
    /// the last three octets, which is what distinguishes one card from
    /// another on the same network.
    pub fn derived(address: [6]u8) Hostname {
        var out = Hostname{};
        for (PREFIX) |c| {
            out.bytes[out.len] = c;
            out.len += 1;
        }
        for (address[3..6]) |octet| {
            out.bytes[out.len] = std.fmt.digitToChar(octet >> 4, .lower);
            out.bytes[out.len + 1] = std.fmt.digitToChar(octet & 0xF, .lower);
            out.len += 2;
        }
        return out;
    }

    /// Whether this is a name somebody chose, rather than the one the
    /// machine fell back to. Worth knowing when deciding whether a
    /// configured name should overwrite what is already there.
    pub fn isDerived(self: *const Hostname) bool {
        return std.mem.startsWith(u8, self.slice(), PREFIX);
    }

    /// The name to answer to: the one somebody chose, or the one derived
    /// from the machine's own address when nobody did. One decision, in
    /// one place, because every caller that needs a name needs the same
    /// answer to the same question.
    pub fn resolve(configured: Hostname, address: [6]u8) Hostname {
        return if (configured.isEmpty()) derived(address) else configured;
    }

    /// The name as C wants it, written into the caller's buffer with its
    /// terminator. Kept out of the struct because the pointer has to
    /// outlive the call that hands it over, and the caller is the only one
    /// who knows for how long.
    pub fn cString(self: *const Hostname, buf: *[MAX + 1]u8) [:0]const u8 {
        const text = self.slice();
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        return buf[0..text.len :0];
    }

    pub fn eql(self: Hostname, other: Hostname) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }

    pub const accepts = "letters, digits and hyphens; unset takes " ++ PREFIX ++ "<address>";

    /// Nothing written means no name of one's own, which the caller reads
    /// as the derived one. A name that breaks the rules is refused rather
    /// than repaired: a machine quietly answering to something other than
    /// what the file says is worse than a setting that did not take.
    pub fn parse(text: []const u8) ?Hostname {
        const trimmed = str.trim(text);
        if (trimmed.len == 0) return Hostname{};
        return of(trimmed);
    }

    pub fn spell(self: Hostname, into: *str.Builder) void {
        into.text(self.slice());
    }
};

fn isNameByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '-';
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the default name is the machine's own, and is the same every boot" {
    const card = [_]u8{ 0x00, 0x1B, 0x77, 0xA1, 0xB2, 0xC3 };
    const name = Hostname.derived(card);
    try testing.expectEqualStrings("vibeee-a1b2c3", name.slice());
    try testing.expect(name.isDerived());

    // Derived twice from the same card is the same name.
    try testing.expect(name.eql(Hostname.derived(card)));

    // A different card is a different name, so two machines on one
    // network do not both answer to it.
    const other = [_]u8{ 0x00, 0x1B, 0x77, 0xA1, 0xB2, 0xC4 };
    try testing.expect(!name.eql(Hostname.derived(other)));
}

test "a name given by hand is kept, in one case" {
    try testing.expectEqualStrings("stairwell", Hostname.of("stairwell").?.slice());
    try testing.expectEqualStrings("pi-2", Hostname.of("Pi-2").?.slice());
    try testing.expect(!Hostname.of("stairwell").?.isDerived());
}

test "a name that is not one is refused rather than repaired" {
    try testing.expectEqual(@as(?Hostname, null), Hostname.of(""));
    try testing.expectEqual(@as(?Hostname, null), Hostname.of("-leading"));
    try testing.expectEqual(@as(?Hostname, null), Hostname.of("trailing-"));
    try testing.expectEqual(@as(?Hostname, null), Hostname.of("has space"));
    try testing.expectEqual(@as(?Hostname, null), Hostname.of("under_score"));
    try testing.expectEqual(@as(?Hostname, null), Hostname.of("dot.ted"));
    try testing.expectEqual(@as(?Hostname, null), Hostname.of("x" ** (MAX + 1)));
    // Exactly the limit is a name.
    try testing.expectEqual(@as(u8, MAX), Hostname.of("x" ** MAX).?.len);
}

test "nothing configured is no name of one's own" {
    const unset = Hostname.parse("") orelse return error.TestUnexpectedResult;
    try testing.expect(unset.isEmpty());
    try testing.expect(!unset.isDerived());

    // Surrounding space is not part of a name.
    try testing.expectEqualStrings("kitchen", Hostname.parse("  kitchen  ").?.slice());
    try testing.expectEqual(@as(?Hostname, null), Hostname.parse("no spaces here"));
}

test "a name reads back as what it was written as" {
    var buf: [MAX]u8 = undefined;
    for ([_][]const u8{ "stairwell", "vibeee-a1b2c3", "x" }) |text| {
        const name = Hostname.of(text).?;
        var built = str.Builder{ .buf = &buf };
        name.spell(&built);
        try testing.expectEqualStrings(text, built.done());
        try testing.expect(name.eql(Hostname.parse(built.done()).?));
    }
}

test "the name to answer to is the chosen one, or the derived one" {
    const card = [_]u8{ 0x00, 0x1B, 0x77, 0xA1, 0xB2, 0xC3 };

    const nothing_chosen = Hostname.parse("") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("vibeee-a1b2c3", nothing_chosen.resolve(card).slice());

    const chosen = Hostname.of("stairwell").?;
    try testing.expectEqualStrings("stairwell", chosen.resolve(card).slice());
}

test "a name hands over to C with its terminator" {
    var buf: [MAX + 1]u8 = undefined;
    const name = Hostname.of("kitchen").?;
    const text = name.cString(&buf);
    try testing.expectEqualStrings("kitchen", text);
    try testing.expectEqual(@as(u8, 0), buf[text.len]);

    // A name with nothing in it is still a valid C string.
    const empty = Hostname{};
    try testing.expectEqualStrings("", empty.cString(&buf));
    try testing.expectEqual(@as(u8, 0), buf[0]);
}
