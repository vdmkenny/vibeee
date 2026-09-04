//! `RPL_ISUPPORT`: what a network says about itself.
//!
//! A server describes its own dialect here: which characters start a channel,
//! which prefixes map to which membership modes, how names are compared, how
//! long a nick may be. These vary widely between networks, so the tokens are
//! parsed once and everything else asks this module.
//!
//! The defaults are the standard's, for a server that sends no tokens.

const std = @import("std");
const lib = @import("lib");

const Bounded = lib.bounded.Bounded;
const wire = @import("line.zig");
const Line = wire.Line;

/// How names are compared. Nicks and channels are case-insensitive, and the
/// network decides which characters count as the same case.
pub const Casemapping = enum {
    /// Letters only.
    ascii,
    /// Letters plus the four punctuation pairs IRC treats as case, so
    /// `nick[]` and `NICK{}` are one name.
    rfc1459,
    /// The same without the tilde and caret pair.
    rfc1459_strict,
    /// Unicode case folding, handled as ASCII here.
    rfc7613,

    pub fn from(text: []const u8) Casemapping {
        if (lib.str.eqlFold(text, "ascii")) return .ascii;
        if (lib.str.eqlFold(text, "rfc1459-strict")) return .rfc1459_strict;
        if (lib.str.eqlFold(text, "rfc7613")) return .rfc7613;
        return .rfc1459;
    }

    pub fn fold(self: Casemapping, ch: u8) u8 {
        const lowered = std.ascii.toLower(ch);
        return switch (self) {
            .ascii, .rfc7613 => lowered,
            .rfc1459 => switch (lowered) {
                '[' => '{',
                ']' => '}',
                '\\' => '|',
                '~' => '^',
                else => lowered,
            },
            .rfc1459_strict => switch (lowered) {
                '[' => '{',
                ']' => '}',
                '\\' => '|',
                else => lowered,
            },
        };
    }

    /// Whether two names are equal.
    pub fn eql(self: Casemapping, a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (self.fold(x) != self.fold(y)) return false;
        }
        return true;
    }

    /// Whether `a` sorts before `b`, for display.
    pub fn before(self: Casemapping, a: []const u8, b: []const u8) bool {
        const shared = @min(a.len, b.len);
        for (a[0..shared], b[0..shared]) |x, y| {
            const folded = .{ self.fold(x), self.fold(y) };
            if (folded[0] != folded[1]) return folded[0] < folded[1];
        }
        return a.len < b.len;
    }
};

/// Which prefix character maps to which membership mode, ranked highest
/// first.
pub const Prefixes = struct {
    pub const MAX = 8;

    modes: Bounded(u8, MAX) = .{},
    marks: Bounded(u8, MAX) = .{},

    /// The default when a server sends no PREFIX token.
    pub const DEFAULT: Prefixes = .{
        .modes = .{ .items = "ov".* ++ @as([MAX - 2]u8, @splat(0)), .len = 2 },
        .marks = .{ .items = "@+".* ++ @as([MAX - 2]u8, @splat(0)), .len = 2 },
    };

    /// Parse a `PREFIX=(ov)@+` value. An empty value means the network has
    /// no membership modes, which differs from sending no token.
    pub fn from(value: []const u8) Prefixes {
        var out: Prefixes = .{};
        if (value.len == 0) return out;
        if (value[0] != '(') return DEFAULT;
        const close = std.mem.indexOfScalar(u8, value, ')') orelse return DEFAULT;
        const modes = value[1..close];
        const marks = value[close + 1 ..];
        if (modes.len != marks.len) return DEFAULT;
        for (modes, marks) |mode, mark| {
            out.modes.append(mode) catch break;
            out.marks.append(mark) catch break;
        }
        return out;
    }

    /// A prefix's rank, lower being higher, or null if it is not a prefix.
    pub fn rank(self: *const Prefixes, mark: u8) ?u8 {
        const at = std.mem.indexOfScalar(u8, self.marks.slice(), mark) orelse return null;
        return @intCast(at);
    }

    pub fn markFor(self: *const Prefixes, mode: u8) ?u8 {
        const at = std.mem.indexOfScalar(u8, self.modes.slice(), mode) orelse return null;
        return self.marks.slice()[at];
    }

    pub fn isMembership(self: *const Prefixes, mode: u8) bool {
        return std.mem.indexOfScalar(u8, self.modes.slice(), mode) != null;
    }

    /// Split a `NAMES` entry into its leading prefixes and the nick. With
    /// `multi-prefix` there can be more than one prefix.
    pub fn split(self: *const Prefixes, name: []const u8) struct { marks: []const u8, nick: []const u8 } {
        var at: usize = 0;
        while (at < name.len and self.rank(name[at]) != null) at += 1;
        return .{ .marks = name[0..at], .nick = name[at..] };
    }
};

/// Whether a channel mode letter takes a parameter, and when.
pub const ModeKind = enum {
    /// A list mode, always with a parameter. Bans, for example.
    list,
    /// A parameter both when set and when unset. The channel key.
    setting,
    /// A parameter only when set. The user limit.
    limit,
    /// Never a parameter. Moderated, invite-only.
    flag,
    /// A membership mode from `PREFIX`, which always names a user.
    membership,

    pub fn takesParam(self: ModeKind, adding: bool) bool {
        return switch (self) {
            .list, .setting, .membership => true,
            .limit => adding,
            .flag => false,
        };
    }
};

/// The four `CHANMODES` groups, which decide whether a letter on a `MODE`
/// line consumes the next parameter.
pub const ChanModes = struct {
    pub const MAX = 32;

    list: Bounded(u8, MAX) = .{},
    setting: Bounded(u8, MAX) = .{},
    limit: Bounded(u8, MAX) = .{},
    flag: Bounded(u8, MAX) = .{},

    pub const DEFAULT: ChanModes = from("b,k,l,imnpst");

    /// Parse a `CHANMODES=beI,k,l,imnpst` value: four comma-separated
    /// groups, in order.
    pub fn from(value: []const u8) ChanModes {
        var out: ChanModes = .{};
        var groups = std.mem.splitScalar(u8, value, ',');
        inline for (.{ "list", "setting", "limit", "flag" }) |name| {
            const group = groups.next() orelse "";
            for (group) |ch| @field(out, name).append(ch) catch break;
        }
        return out;
    }

    pub fn kind(self: *const ChanModes, mode: u8) ?ModeKind {
        inline for (.{ "list", "setting", "limit", "flag" }) |name| {
            if (std.mem.indexOfScalar(u8, @field(self, name).slice(), mode) != null) {
                return @field(ModeKind, name);
            }
        }
        return null;
    }
};

/// One mode change from a `MODE` line.
pub const Change = struct {
    adding: bool,
    mode: u8,
    /// What it applies to, or empty if the mode takes no parameter.
    param: []const u8 = "",
    kind: ModeKind,
};

/// Iterates the changes on a `MODE` line. Whether a letter takes the next
/// parameter depends on what the network said about it, so this lives here
/// rather than with the parser.
pub const Changes = struct {
    support: *const Support,
    letters: []const u8,
    params: []const []const u8,
    at: usize = 0,
    next_param: usize = 0,
    adding: bool = true,

    pub fn next(self: *Changes) ?Change {
        while (self.at < self.letters.len) {
            const ch = self.letters[self.at];
            self.at += 1;
            switch (ch) {
                '+' => self.adding = true,
                '-' => self.adding = false,
                else => {
                    const kind = self.support.modeKind(ch);
                    var param: []const u8 = "";
                    if (kind.takesParam(self.adding) and self.next_param < self.params.len) {
                        param = self.params[self.next_param];
                        self.next_param += 1;
                    }
                    return .{ .adding = self.adding, .mode = ch, .param = param, .kind = kind };
                },
            }
        }
        return null;
    }
};

/// Everything a network has advertised about itself.
pub const Support = struct {
    network: Bounded(u8, 32) = .{},
    chantypes: Bounded(u8, 8) = .{ .items = "#&".* ++ @as([6]u8, @splat(0)), .len = 2 },
    statusmsg: Bounded(u8, 8) = .{},
    prefixes: Prefixes = Prefixes.DEFAULT,
    chanmodes: ChanModes = ChanModes.DEFAULT,
    casemapping: Casemapping = .rfc1459,
    nicklen: u16 = 9,
    channellen: u16 = 200,
    topiclen: u16 = 390,
    /// Maximum line length excluding tags. 512 unless the network raises it.
    linelen: u16 = 512,
    /// Modes one `MODE` may set, or zero for no stated limit.
    modes: u16 = 3,
    /// Nicks `MONITOR` will watch, or zero if it is unsupported.
    monitor: u16 = 0,
    /// The network accepts UTF-8 only.
    utf8only: bool = false,
    /// All `RPL_ISUPPORT` lines have arrived.
    settled: bool = false,

    /// Apply one `RPL_ISUPPORT` line. The first parameter is the nick and
    /// the last is human-readable text; the tokens are in between.
    pub fn read(self: *Support, message: *const Line) void {
        const tokens = message.params.slice();
        if (tokens.len < 3) return;
        for (tokens[1 .. tokens.len - 1]) |token| self.readToken(token);
    }

    fn readToken(self: *Support, token: []const u8) void {
        // A leading minus withdraws a token, restoring the default.
        if (token.len != 0 and token[0] == '-') {
            self.forget(token[1..]);
            return;
        }
        const equals = std.mem.indexOfScalar(u8, token, '=');
        const name = if (equals) |i| token[0..i] else token;
        const value = if (equals) |i| token[i + 1 ..] else "";

        if (lib.str.eqlFold(name, "NETWORK")) return set(&self.network, value);
        if (lib.str.eqlFold(name, "CHANTYPES")) return set(&self.chantypes, value);
        if (lib.str.eqlFold(name, "STATUSMSG")) return set(&self.statusmsg, value);
        if (lib.str.eqlFold(name, "PREFIX")) {
            self.prefixes = Prefixes.from(value);
            return;
        }
        if (lib.str.eqlFold(name, "CHANMODES")) {
            self.chanmodes = ChanModes.from(value);
            return;
        }
        if (lib.str.eqlFold(name, "CASEMAPPING")) {
            self.casemapping = Casemapping.from(value);
            return;
        }
        if (lib.str.eqlFold(name, "UTF8ONLY")) {
            self.utf8only = true;
            return;
        }

        // Spelled as the fields are: the comparison is case-insensitive and
        // the wire uses upper case. A token with no value parses to zero,
        // which every caller reads as no limit.
        inline for (.{ "nicklen", "channellen", "topiclen", "linelen", "modes", "monitor" }) |number| {
            if (lib.str.eqlFold(name, number)) {
                @field(self, number) = @intCast(lib.str.toUnsigned(value));
                return;
            }
        }
    }

    fn forget(self: *Support, name: []const u8) void {
        const fresh: Support = .{};
        inline for (@typeInfo(Support).@"struct".fields) |field| {
            if (lib.str.eqlFold(name, field.name)) {
                @field(self, field.name) = @field(fresh, field.name);
                return;
            }
        }
    }

    fn set(field: anytype, value: []const u8) void {
        field.clear();
        for (value) |ch| field.append(ch) catch break;
    }

    /// Whether a target is a channel rather than a user.
    pub fn isChannel(self: *const Support, target: []const u8) bool {
        if (target.len == 0) return false;
        // `@#room` addresses the channel's operators.
        const start: usize = if (std.mem.indexOfScalar(u8, self.statusmsg.slice(), target[0]) != null) 1 else 0;
        if (start >= target.len) return false;
        return std.mem.indexOfScalar(u8, self.chantypes.slice(), target[start]) != null;
    }

    /// What a mode letter does. Membership modes come from `PREFIX`, the rest
    /// from `CHANMODES`. A letter in neither is treated as taking no
    /// parameter, which keeps the remaining parameters aligned.
    pub fn modeKind(self: *const Support, mode: u8) ModeKind {
        if (self.prefixes.isMembership(mode)) return .membership;
        return self.chanmodes.kind(mode) orelse .flag;
    }

    /// The changes on a `MODE` line.
    pub fn changes(self: *const Support, letters: []const u8, params: []const []const u8) Changes {
        return .{ .support = self, .letters = letters, .params = params };
    }

    /// Whether two names are equal under this network's casemapping.
    pub fn same(self: *const Support, a: []const u8, b: []const u8) bool {
        return self.casemapping.eql(a, b);
    }
};

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Parse a line and apply it, the way a session does.
fn told(support: *Support, text: []const u8) !void {
    var buf: [wire.MAX]u8 = undefined;
    @memcpy(buf[0..text.len], text);
    const parsed = try wire.parse(buf[0..text.len]);
    support.read(&parsed);
}

test "defaults when the server sends no tokens" {
    const support: Support = .{};
    try expect(support.isChannel("#room"));
    try expect(support.isChannel("&local"));
    try expect(!support.isChannel("nick"));
    try expect(support.modeKind('o') == .membership);
    try expect(support.modeKind('b') == .list);
    try expect(support.modeKind('k') == .setting);
    try expect(support.modeKind('l') == .limit);
    try expect(support.modeKind('m') == .flag);
    try expect(support.prefixes.markFor('o').? == '@');
    try expect(support.nicklen == 9);
}

test "parsing ISUPPORT tokens" {
    var support: Support = .{};
    try told(&support, ":serv 005 me AWAYLEN=390 CASEMAPPING=ascii CHANLIMIT=#:100 CHANMODES=beI,k,l,imnpst " ++
        "CHANNELLEN=64 CHANTYPES=# NETWORK=Libera.Chat NICKLEN=16 PREFIX=(ov)@+ :are supported");
    try expectEqualStrings("Libera.Chat", support.network.slice());
    try expect(support.casemapping == .ascii);
    try expect(support.nicklen == 16);
    try expect(support.channellen == 64);
    try expectEqualStrings("#", support.chantypes.slice());
    try expect(!support.isChannel("&local"));
    try expect(support.chanmodes.kind('I') == .list);
    try expect(support.chanmodes.kind('e') == .list);

    // A second line adds to the first, and a minus takes one back.
    try told(&support, ":serv 005 me STATUSMSG=@+ MONITOR=100 UTF8ONLY :are supported");
    try expect(support.monitor == 100);
    try expect(support.utf8only);
    try expect(support.isChannel("@#room"));
    try expectEqualStrings("Libera.Chat", support.network.slice());

    try told(&support, ":serv 005 me -NICKLEN -CASEMAPPING :are supported");
    try expect(support.nicklen == 9);
    try expect(support.casemapping == .rfc1459);
}

test "PREFIX parsing and ranking" {
    const prefixes = Prefixes.from("(qaohv)~&@%+");
    try expect(prefixes.rank('~').? == 0);
    try expect(prefixes.rank('+').? == 4);
    try expect(prefixes.rank('#') == null);
    try expect(prefixes.markFor('h').? == '%');
    try expect(prefixes.isMembership('h'));
    try expect(!prefixes.isMembership('b'));

    // `multi-prefix` sends several prefixes at once.
    const split = prefixes.split("~@nick");
    try expectEqualStrings("~@", split.marks);
    try expectEqualStrings("nick", split.nick);
    try expectEqualStrings("plain", prefixes.split("plain").nick);

    // A network with no membership modes at all.
    const none = Prefixes.from("");
    try expect(none.marks.len == 0);
    try expect(none.split("@weird").nick.len == 6);
}

test "which mode letters take a parameter" {
    var support: Support = .{};
    try told(&support, ":serv 005 me CHANMODES=beI,k,l,imnpst PREFIX=(ov)@+ :are supported");

    var changes = support.changes("+ovk-l+m", &.{ "alice", "bob", "secret" });
    const wanted = [_]Change{
        .{ .adding = true, .mode = 'o', .param = "alice", .kind = .membership },
        .{ .adding = true, .mode = 'v', .param = "bob", .kind = .membership },
        .{ .adding = true, .mode = 'k', .param = "secret", .kind = .setting },
        .{ .adding = false, .mode = 'l', .param = "", .kind = .limit },
        .{ .adding = true, .mode = 'm', .param = "", .kind = .flag },
    };
    for (wanted) |want| {
        const got = changes.next() orelse return error.TooFew;
        try expect(got.adding == want.adding);
        try expect(got.mode == want.mode);
        try expect(got.kind == want.kind);
        try expectEqualStrings(want.param, got.param);
    }
    try expect(changes.next() == null);

    // An unadvertised letter takes no parameter, which keeps the following
    // parameters aligned with the letters they belong to.
    var unknown = support.changes("+Zo", &.{"alice"});
    try expect(unknown.next().?.param.len == 0);
    try expectEqualStrings("alice", unknown.next().?.param);
}

test "name comparison per casemapping" {
    const rfc: Casemapping = .rfc1459;
    try expect(rfc.eql("Nick", "nick"));
    try expect(rfc.eql("nick[away]", "NICK{AWAY}"));
    try expect(rfc.eql("a~b", "a^b"));
    try expect(!rfc.eql("nick", "nick2"));

    const strict: Casemapping = .rfc1459_strict;
    try expect(strict.eql("nick[]", "NICK{}"));
    try expect(!strict.eql("a~b", "a^b"));

    const ascii: Casemapping = .ascii;
    try expect(ascii.eql("Nick", "nick"));
    try expect(!ascii.eql("nick[]", "nick{}"));

    try expect(ascii.before("alice", "bob"));
    try expect(ascii.before("Alice", "bob"));
    try expect(!ascii.before("bob", "Alice"));
    try expect(ascii.before("bob", "bobby"));
}
