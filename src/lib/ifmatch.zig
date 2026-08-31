//! Which interface a configuration slot binds to.
//!
//! A machine may carry several wired ports, so configuration cannot assume
//! one of anything: a slot names its interface by class, by driver, or by
//! the exact place on the bus, and the most specific claim wins. Pure and
//! host-tested; the settings codec round-trips it through `parse` and
//! `spell`.

const std = @import("std");
const pci = @import("pci.zig");
const str = @import("str.zig");

/// The longest driver name a match carries, ordinal suffix included.
pub const NAME_MAX = 12;

/// What kind of interface an interface is. One line per class, and every
/// class is matchable by its name the moment the line exists: parsing and
/// spelling walk the enum rather than a list beside it.
pub const Class = enum {
    ether,
    wifi,
};

pub const Match = union(enum) {
    /// An unused slot.
    none,
    /// The next interface of a class no more specific slot has claimed;
    /// two slots naming the same class claim the first and second of it.
    class: Class,
    /// A driver's interface by name, as `net` prints it: "atl2", "e1000.1".
    driver: Name,
    /// The exact device, wherever its driver comes from.
    location: pci.Location,

    /// How specific a claim is, for deciding who gets an interface when
    /// several slots could: the exact place beats the driver's name beats
    /// a class.
    pub fn rank(self: Match) u8 {
        return switch (self) {
            .none => 0,
            .class => 1,
            .driver => 2,
            .location => 3,
        };
    }

    /// Whether two matchers are the same claim, for finding the slot that
    /// already speaks for an interface before claiming a new one.
    pub fn eql(a: Match, b: Match) bool {
        if (@as(std.meta.Tag(Match), a) != @as(std.meta.Tag(Match), b)) return false;
        return switch (a) {
            .none => true,
            .class => |c| c == b.class,
            .driver => |name| name.is(b.driver.slice()),
            .location => |at| @as(u16, @bitCast(at)) == @as(u16, @bitCast(b.location)),
        };
    }

    pub const accepts = "a class (ether, wifi), a driver name, a bus location, or unset";

    pub fn parse(text: []const u8) ?Match {
        const trimmed = str.trim(text);
        if (trimmed.len == 0) return .none;
        if (std.meta.stringToEnum(Class, trimmed)) |class| return .{ .class = class };
        if (pci.parse(trimmed)) |location| return .{ .location = location };
        const name = Name.of(trimmed) orelse return null;
        return .{ .driver = name };
    }

    pub fn spell(self: Match, into: *str.Builder) void {
        switch (self) {
            .none => {},
            .class => |c| into.text(@tagName(c)),
            .driver => |name| into.text(name.slice()),
            .location => |at| {
                var field: [8]u8 = undefined;
                into.text(pci.spell(at, &field));
            },
        }
    }
};

/// A bounded driver name: the bytes and how many of them are real, so the
/// settings struct stays copyable and nothing dangles.
pub const Name = struct {
    text: [NAME_MAX]u8 = @splat(0),
    len: u8 = 0,

    pub fn of(name: []const u8) ?Name {
        if (name.len == 0 or name.len > NAME_MAX) return null;
        // A driver's name is letters, digits and the ordinal dot; anything
        // else is a typo better refused than stored.
        for (name) |c| {
            const word = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '.';
            if (!word) return null;
        }
        var out = Name{ .len = @intCast(name.len) };
        @memcpy(out.text[0..name.len], name);
        return out;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.text[0..self.len];
    }

    pub fn is(self: *const Name, name: []const u8) bool {
        return str.eql(self.slice(), name);
    }
};

/// What the binder needs to know about one live interface.
pub const Iface = struct {
    class: Class,
    label: Name,
    location: pci.Location,
};

/// Bind each slot to at most one interface: most specific matches first,
/// slot order breaking ties, and class slots claiming successive interfaces
/// of their class. `bound[i]` receives the slot index that claimed
/// interface `i`, or null when no slot did.
pub fn bind(matches: []const Match, ifaces: []const Iface, bound: []?u8) void {
    for (bound[0..ifaces.len]) |*b| b.* = null;

    var claimed = [_]bool{false} ** 32;
    var rank: u8 = 3;
    while (rank >= 1) : (rank -= 1) {
        for (matches, 0..) |m, slot| {
            if (slot >= claimed.len or claimed[slot]) continue;
            if (m.rank() != rank) continue;
            for (ifaces, 0..) |iface, i| {
                if (bound[i] != null) continue;
                if (!covers(m, iface)) continue;
                bound[i] = @intCast(slot);
                claimed[slot] = true;
                break;
            }
        }
    }
}

/// Whether one matcher speaks for one interface.
pub fn covers(m: Match, iface: Iface) bool {
    return switch (m) {
        .none => false,
        .class => |c| iface.class == c,
        .driver => |name| name.is(iface.label.slice()),
        .location => |at| @as(u16, @bitCast(at)) == @as(u16, @bitCast(iface.location)),
    };
}

test "a match parses each of its shapes" {
    try std.testing.expectEqual(Match.none, Match.parse("").?);
    try std.testing.expectEqual(Class.ether, Match.parse("ether").?.class);
    try std.testing.expectEqual(Class.wifi, Match.parse(" wifi ").?.class);
    const by_driver = Match.parse("e1000.1").?;
    try std.testing.expect(by_driver.driver.is("e1000.1"));
    const by_place = Match.parse("03:00.0").?;
    try std.testing.expectEqual(@as(u8, 3), by_place.location.bus);
    try std.testing.expectEqual(null, Match.parse("no spaces here"));
}

test "a match spells back what it parsed" {
    var buf: [16]u8 = undefined;
    for ([_][]const u8{ "ether", "wifi", "atl2", "e1000.1", "03:00.0" }) |text| {
        var b = str.Builder{ .buf = &buf };
        Match.parse(text).?.spell(&b);
        try std.testing.expectEqualStrings(text, b.done());
    }
}

test "specificity ranks place over driver over class" {
    try std.testing.expect(Match.parse("03:00.0").?.rank() > Match.parse("atl2").?.rank());
    try std.testing.expect(Match.parse("atl2").?.rank() > Match.parse("ether").?.rank());
    try std.testing.expect(Match.parse("ether").?.rank() > Match.parse("").?.rank());
}

test "binding gives the specific slot its interface and classes the rest" {
    const ifaces = [_]Iface{
        .{ .class = .ether, .label = Name.of("e1000").?, .location = pci.parse("00:03.0").? },
        .{ .class = .ether, .label = Name.of("e1000.1").?, .location = pci.parse("00:04.0").? },
        .{ .class = .wifi, .label = Name.of("ath").?, .location = pci.parse("01:00.0").? },
    };
    const matches = [_]Match{
        Match.parse("ether").?,
        Match.parse("wifi").?,
        Match.parse("e1000").?,
        Match.parse("").?,
    };
    var bound: [3]?u8 = undefined;
    bind(&matches, &ifaces, &bound);

    // The named slot takes its exact interface; the ether class then claims
    // the remaining ethernet; wifi claims the radio.
    try std.testing.expectEqual(@as(?u8, 2), bound[0]);
    try std.testing.expectEqual(@as(?u8, 0), bound[1]);
    try std.testing.expectEqual(@as(?u8, 1), bound[2]);
}

test "two class slots claim successive interfaces of the class" {
    const ifaces = [_]Iface{
        .{ .class = .ether, .label = Name.of("a").?, .location = pci.parse("00:03.0").? },
        .{ .class = .ether, .label = Name.of("b").?, .location = pci.parse("00:04.0").? },
    };
    const matches = [_]Match{ Match.parse("ether").?, Match.parse("ether").? };
    var bound: [2]?u8 = undefined;
    bind(&matches, &ifaces, &bound);
    try std.testing.expectEqual(@as(?u8, 0), bound[0]);
    try std.testing.expectEqual(@as(?u8, 1), bound[1]);
}
