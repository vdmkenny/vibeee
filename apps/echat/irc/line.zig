//! Parsing and writing one line of the IRC protocol.
//!
//! The wire format is a single grammar, from RFC 1459 plus the IRCv3
//! message-tags extension:
//!
//!     ['@' tags SPACE] [':' source SPACE] command *(SPACE param) [SPACE ':' trailing]
//!
//! No I/O and no allocation. Tested against the shared parser vectors in
//! `vectors.zig`.
//!
//! Parsing happens in place. Tag escapes are two bytes for one, so unescaping
//! only ever shrinks, and the parsed fields point into the caller's buffer.

const std = @import("std");
const lib = @import("lib");

const Bounded = lib.bounded.Bounded;

/// Maximum line length including CRLF, from RFC 1459.
pub const MAX = 512;

/// Maximum tag data one side may send, from the message-tags extension.
pub const TAG_DATA_MAX = 4094;

/// Maximum parameters per line, from RFC 2812.
pub const PARAM_MAX = 15;

/// Tags kept per line. More than any network sends with every capability
/// enabled. A line with more keeps its message and sets `crowded`.
pub const TAG_MAX = 24;

/// Longest command word that maps to a named `Verb`.
pub const WORD_MAX = 16;

pub const Error = error{
    /// A tag or source section with nothing after it.
    Truncated,
    /// No command word.
    NoCommand,
    /// More parameters than the grammar allows.
    TooManyParams,
    /// The rendered line does not fit the output buffer.
    NoRoom,
    /// A non-final parameter that would parse back as several parameters,
    /// or as none.
    BadParam,
};

/// A three-digit reply. Non-exhaustive, because networks define their own;
/// an unrecognised one still carries its number and text.
pub const Reply = enum(u10) {
    welcome = 1,
    your_host = 2,
    created = 3,
    my_info = 4,
    isupport = 5,
    bounce = 10,
    away = 301,
    unaway = 305,
    now_away = 306,
    whois_registered_nick = 307,
    whois_user = 311,
    whois_server = 312,
    whois_operator = 313,
    whowas_user = 314,
    whois_idle = 317,
    end_of_whois = 318,
    whois_channels = 319,
    whois_account = 330,
    list_start = 321,
    list = 322,
    list_end = 323,
    user_mode_is = 221,
    channel_mode_is = 324,
    creation_time = 329,
    no_topic = 331,
    topic = 332,
    topic_who_time = 333,
    inviting = 341,
    invite_exception_list = 346,
    end_of_invite_exception_list = 347,
    exception_list = 348,
    end_of_exception_list = 349,
    who_reply = 352,
    name_reply = 353,
    who_spcrpl = 354,
    end_of_who = 315,
    end_of_names = 366,
    ban_list = 367,
    end_of_ban_list = 368,
    end_of_whowas = 369,
    info = 371,
    motd = 372,
    motd_start = 375,
    end_of_motd = 376,
    time = 391,
    no_such_nick = 401,
    no_such_server = 402,
    no_such_channel = 403,
    cannot_send_to_channel = 404,
    too_many_channels = 405,
    was_no_such_nick = 406,
    no_recipient = 411,
    no_text_to_send = 412,
    input_too_long = 417,
    unknown_command = 421,
    no_motd = 422,
    erroneous_nickname = 432,
    nickname_in_use = 433,
    nick_collision = 436,
    user_not_in_channel = 441,
    not_on_channel = 442,
    user_on_channel = 443,
    not_registered = 451,
    need_more_params = 461,
    already_registered = 462,
    password_mismatch = 464,
    banned_from_server = 465,
    channel_is_full = 471,
    unknown_mode = 472,
    invite_only_channel = 473,
    banned_from_channel = 474,
    bad_channel_key = 475,
    bad_channel_mask = 476,
    no_privileges = 481,
    chanop_privs_needed = 482,
    umode_unknown_flag = 501,
    users_dont_match = 502,
    monitor_online = 730,
    monitor_offline = 731,
    monitor_list = 732,
    end_of_monitor_list = 733,
    monitor_list_full = 734,
    starttls = 670,
    starttls_failed = 691,
    logged_in = 900,
    logged_out = 901,
    nick_locked = 902,
    sasl_success = 903,
    sasl_fail = 904,
    sasl_too_long = 905,
    sasl_aborted = 906,
    sasl_already = 907,
    sasl_mechs = 908,
    _,

    /// The reply for a three-digit word, or null if it is not three digits.
    pub fn from(word: []const u8) ?Reply {
        if (word.len != 3) return null;
        var value: u10 = 0;
        for (word) |ch| {
            if (ch < '0' or ch > '9') return null;
            value = value * 10 + (ch - '0');
        }
        return @enumFromInt(value);
    }

    pub fn number(self: Reply) u10 {
        return @intFromEnum(self);
    }

    /// True for the error range, 400 through 599.
    pub fn isError(self: Reply) bool {
        return self.number() >= 400 and self.number() < 600;
    }
};

/// A command word this client handles. Lower case because `Verb.from` folds
/// the word before matching; the wire carries them upper case.
pub const Verb = enum {
    // Registration and connection.
    cap,
    authenticate,
    pass,
    nick,
    user,
    ping,
    pong,
    quit,
    @"error",

    // Channels and messages.
    join,
    part,
    mode,
    topic,
    names,
    list,
    invite,
    kick,
    privmsg,
    notice,
    tagmsg,
    who,
    whois,

    // User state.
    away,
    account,
    chghost,
    setname,
    wallops,

    // IRCv3 extensions that arrive as words rather than numerics.
    batch,
    ack,
    fail,
    warn,
    note,
    markread,
    chathistory,
    monitor,
    redact,

    /// Anything else. `Line.word` still holds the raw text.
    unknown,

    /// The verb for a word, case-insensitively, or `.unknown`.
    pub fn from(word: []const u8) Verb {
        if (word.len > WORD_MAX) return .unknown;
        var folded: [WORD_MAX]u8 = undefined;
        const lowered = std.ascii.lowerString(folded[0..word.len], word);
        return std.meta.stringToEnum(Verb, lowered) orelse .unknown;
    }
};

/// A line's command: either a verb or a numeric reply.
pub const Command = union(enum) {
    reply: Reply,
    verb: Verb,

    pub fn from(word: []const u8) Command {
        if (Reply.from(word)) |reply| return .{ .reply = reply };
        return .{ .verb = Verb.from(word) };
    }

    /// The wire spelling, written into `room` since nothing here allocates.
    pub fn spell(self: Command, room: *[WORD_MAX]u8) []const u8 {
        return switch (self) {
            .reply => |reply| std.fmt.bufPrint(room, "{d:0>3}", .{reply.number()}) catch unreachable,
            .verb => |verb| std.ascii.upperString(room[0..@tagName(verb).len], @tagName(verb)),
        };
    }
};

/// A line's prefix, split into its three parts. A server prefix is a bare
/// hostname, which lands in `nick`.
pub const Source = struct {
    full: []const u8 = "",
    nick: []const u8 = "",
    user: []const u8 = "",
    host: []const u8 = "",

    pub fn from(text: []const u8) Source {
        const bang = std.mem.indexOfScalar(u8, text, '!');
        const at = std.mem.indexOfScalarPos(u8, text, bang orelse 0, '@');
        return .{
            .full = text,
            .nick = text[0 .. bang orelse at orelse text.len],
            .user = if (bang) |b| text[b + 1 .. at orelse text.len] else "",
            .host = if (at) |a| text[a + 1 ..] else "",
        };
    }

    /// True if the prefix names a user rather than a server.
    pub fn isUser(self: Source) bool {
        return self.user.len != 0 or self.host.len != 0;
    }
};

pub const Tag = struct {
    key: []const u8,
    value: []const u8,
};

pub const Tags = Bounded(Tag, TAG_MAX);
pub const Params = Bounded([]const u8, PARAM_MAX);

/// A parsed line. Every slice points into the buffer it was parsed from and
/// is valid only as long as that buffer is.
pub const Line = struct {
    tags: Tags = .{},
    source: ?Source = null,
    command: Command = .{ .verb = .unknown },
    /// The command word as written, which is all an unknown verb has.
    word: []const u8 = "",
    params: Params = .{},
    /// The line had more tags than `TAG_MAX`. The message is intact but a
    /// tag may be missing.
    crowded: bool = false,
    /// Render the last parameter as trailing even when it does not need to
    /// be. Clients conventionally do this for free text.
    trail: bool = false,

    /// A tag's value, or null if the line does not carry it.
    pub fn tag(self: *const Line, key: []const u8) ?[]const u8 {
        for (self.tags.slice()) |item| {
            if (std.mem.eql(u8, item.key, key)) return item.value;
        }
        return null;
    }

    /// Parameter `index`, or null if the line has fewer.
    pub fn param(self: *const Line, index: usize) ?[]const u8 {
        return self.params.at(index);
    }

    /// The last parameter, which holds a message's text.
    pub fn text(self: *const Line) []const u8 {
        return if (self.params.len == 0) "" else self.params.items[self.params.len - 1];
    }

    /// The nick the line came from, or empty for a server prefix.
    pub fn nick(self: *const Line) []const u8 {
        const from = self.source orelse return "";
        return from.nick;
    }

    fn setTag(self: *Line, key: []const u8, value: []const u8) void {
        // The extension says to keep the last of a repeated key.
        for (self.tags.mutable()) |*item| {
            if (std.mem.eql(u8, item.key, key)) {
                item.value = value;
                return;
            }
        }
        self.tags.append(.{ .key = key, .value = value }) catch {
            self.crowded = true;
        };
    }
};

/// Maximum size of a whole line: the extension's combined tag budget plus
/// the standard line length.
pub const WHOLE_MAX = 1 + 8191 + MAX;

/// A buffer for incoming bytes that hands back whole lines.
///
/// A read returns whatever the transport has, often half a line or several,
/// so the framing lives here rather than in each caller.
pub const Stream = struct {
    held: [WHOLE_MAX]u8 = undefined,
    /// The first byte not yet handed out, and the end of what has arrived.
    start: usize = 0,
    len: usize = 0,
    /// Discarding the remainder of an over-long line.
    dropping: bool = false,
    /// A line was dropped for length. The caller may report this and clear it.
    dropped: bool = false,

    /// Where to read into. Lines returned by `next` stay valid until this is
    /// called again, so a caller can work through everything that arrived
    /// before reading more.
    pub fn room(self: *Stream) []u8 {
        if (self.start != 0) {
            std.mem.copyForwards(u8, self.held[0 .. self.len - self.start], self.held[self.start..self.len]);
            self.len -= self.start;
            self.start = 0;
        }
        return self.held[self.len..];
    }

    /// How much of `room` was filled.
    pub fn filled(self: *Stream, count: usize) void {
        self.len += count;
    }

    /// The next whole line without its ending, or null if none is complete.
    /// Writable, since parsing unescapes in place.
    pub fn next(self: *Stream) ?[]u8 {
        while (true) {
            const arrived = self.held[self.start..self.len];
            const end = std.mem.indexOfAny(u8, arrived, "\r\n") orelse {
                // No line ending yet. A full buffer means the line is longer
                // than the protocol allows, so discard it.
                if (self.start == 0 and self.len == self.held.len) {
                    self.len = 0;
                    self.dropping = true;
                    self.dropped = true;
                }
                return null;
            };
            const line = arrived[0..end];
            self.start += end + 1;
            if (self.dropping) {
                self.dropping = false;
                continue;
            }
            // Skip the empty line a CRLF pair leaves behind, and the blank
            // lines some servers send on their own.
            if (line.len != 0) return line;
        }
    }
};

/// Parse a line. `buf` is written through: tag values are unescaped in place,
/// and the returned fields point into it.
pub fn parse(buf: []u8) Error!Line {
    // Tolerate a line ending, so a caller need not strip one.
    var rest = buf[0..std.mem.trimEnd(u8, buf, "\r\n").len];
    var line: Line = .{};

    if (rest.len != 0 and rest[0] == '@') {
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.Truncated;
        readTags(&line, rest[1..end]);
        rest = past(rest, end);
    }

    if (rest.len != 0 and rest[0] == ':') {
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.Truncated;
        line.source = Source.from(rest[1..end]);
        rest = past(rest, end);
    }

    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    if (end == 0) return error.NoCommand;
    line.word = rest[0..end];
    line.command = Command.from(line.word);
    rest = past(rest, end);

    // A parameter runs to the next space. One introduced by a colon is the
    // rest of the line, spaces included.
    while (rest.len != 0) {
        if (rest[0] == ':') {
            line.params.append(rest[1..]) catch return error.TooManyParams;
            break;
        }
        const stop = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        line.params.append(rest[0..stop]) catch return error.TooManyParams;
        rest = past(rest, stop);
    }

    return line;
}

/// Everything after `at`, skipping the spaces there. Servers do send more
/// than one where the grammar has a single separator.
fn past(rest: []u8, at: usize) []u8 {
    var i = at;
    while (i < rest.len and rest[i] == ' ') i += 1;
    return rest[i..];
}

fn readTags(line: *Line, blob: []u8) void {
    var at: usize = 0;
    while (at < blob.len) {
        const end = std.mem.indexOfScalarPos(u8, blob, at, ';') orelse blob.len;
        const item = blob[at..end];
        at = end + 1;
        if (item.len == 0) continue;

        const equals = std.mem.indexOfScalar(u8, item, '=');
        const key = if (equals) |i| item[0..i] else item;
        if (key.len == 0) continue;
        // The extension defines empty and missing values as equivalent, so
        // both become an empty slice.
        const value = if (equals) |i| unescape(item[i + 1 ..]) else item[0..0];
        line.setTag(key, value);
    }
}

/// Decode tag escapes in place. Each escape is two bytes for one, so the
/// result is never longer than the input.
fn unescape(value: []u8) []u8 {
    if (std.mem.indexOfScalar(u8, value, '\\') == null) return value;

    var wrote: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] != '\\') {
            value[wrote] = value[i];
            wrote += 1;
            continue;
        }
        // A trailing backslash decodes to nothing. A backslash before a
        // character that needs no escape is dropped, keeping the character.
        i += 1;
        if (i == value.len) break;
        value[wrote] = switch (value[i]) {
            ':' => ';',
            's' => ' ',
            'r' => '\r',
            'n' => '\n',
            else => value[i],
        };
        wrote += 1;
    }
    return value[0..wrote];
}

/// Render a line into `buf` and return what was written, without the CRLF the
/// transport adds.
///
/// The last parameter gets a leading colon when it needs one, so it can be
/// empty or contain spaces. An earlier parameter that would need one is an
/// error, since it would parse back as a different line.
pub fn render(buf: []u8, line: Line) Error![]const u8 {
    var out: Out = .{ .buf = buf };

    for (line.tags.slice(), 0..) |item, i| {
        try out.byte(if (i == 0) '@' else ';');
        try out.text(item.key);
        // An empty value is written as a bare key, the shorter of the two
        // equivalent spellings.
        if (item.value.len != 0) {
            try out.byte('=');
            try out.escaped(item.value);
        }
    }
    if (line.tags.len != 0) try out.byte(' ');

    if (line.source) |from| {
        try out.byte(':');
        try out.text(from.full);
        try out.byte(' ');
    }

    var room: [WORD_MAX]u8 = undefined;
    try out.text(if (line.word.len != 0) line.word else line.command.spell(&room));

    for (line.params.slice(), 0..) |item, i| {
        const last = i + 1 == line.params.len;
        const trailing = (last and line.trail) or item.len == 0 or item[0] == ':' or
            std.mem.indexOfScalar(u8, item, ' ') != null;
        if (trailing and !last) return error.BadParam;
        try out.byte(' ');
        if (trailing) try out.byte(':');
        try out.text(item);
    }

    return out.written();
}

/// A bounds-checked write cursor.
const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn byte(self: *Out, value: u8) Error!void {
        if (self.len == self.buf.len) return error.NoRoom;
        self.buf[self.len] = value;
        self.len += 1;
    }

    fn text(self: *Out, value: []const u8) Error!void {
        if (self.len + value.len > self.buf.len) return error.NoRoom;
        @memcpy(self.buf[self.len..][0..value.len], value);
        self.len += value.len;
    }

    fn escaped(self: *Out, value: []const u8) Error!void {
        for (value) |ch| switch (ch) {
            ';' => try self.text("\\:"),
            ' ' => try self.text("\\s"),
            '\\' => try self.text("\\\\"),
            '\r' => try self.text("\\r"),
            '\n' => try self.text("\\n"),
            else => try self.byte(ch),
        };
    }

    fn written(self: *const Out) []const u8 {
        return self.buf[0..self.len];
    }
};

const vectors = @import("vectors.zig");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "reference vectors: splitting a line into atoms" {
    for (vectors.split) |case| {
        var buf: [MAX]u8 = undefined;
        @memcpy(buf[0..case.input.len], case.input);
        const line = try parse(buf[0..case.input.len]);

        expectEqualStrings(case.verb orelse "", line.word) catch |err| {
            std.debug.print("input: {s}\n", .{case.input});
            return err;
        };
        if (case.source) |want| {
            try expectEqualStrings(want, (line.source orelse return error.NoSource).full);
        } else {
            try expect(line.source == null);
        }

        try expect(line.params.len == case.params.len);
        for (case.params, line.params.slice()) |want, got| try expectEqualStrings(want, got);

        try expect(line.tags.len == case.tags.len);
        for (case.tags) |want| {
            try expectEqualStrings(want[1], line.tag(want[0]) orelse return error.NoTag);
        }
    }
}

test "reference vectors: rendering atoms into a line" {
    for (vectors.join) |case| {
        var line: Line = .{ .word = case.verb orelse "" };
        if (case.source) |from| line.source = Source.from(from);
        for (case.tags) |item| try line.tags.append(.{ .key = item[0], .value = item[1] });
        for (case.params) |item| try line.params.append(item);

        var buf: [MAX]u8 = undefined;
        const written = try render(&buf, line);

        for (case.matches) |accepted| {
            if (std.mem.eql(u8, accepted, written)) break;
        } else {
            std.debug.print("{s}\nwrote: {s}\n", .{ case.desc, written });
            return error.NotAccepted;
        }
    }
}

test "reference vectors: splitting a source" {
    for (vectors.userhost) |case| {
        const source = Source.from(case.input);
        try expectEqualStrings(case.nick orelse "", source.nick);
        try expectEqualStrings(case.user orelse "", source.user);
        try expectEqualStrings(case.host orelse "", source.host);
    }
}

test "command words parse as replies, verbs or unknown" {
    try expect(Command.from("432").reply == .erroneous_nickname);
    try expect(Command.from("001").reply == .welcome);
    try expect(Command.from("999").reply.number() == 999);
    try expect(Command.from("PRIVMSG").verb == .privmsg);
    try expect(Command.from("privmsg").verb == .privmsg);
    try expect(Command.from("PrIvMsG").verb == .privmsg);
    try expect(Command.from("ERROR").verb == .@"error");
    try expect(Command.from("SAJOIN").verb == .unknown);
    try expect(Command.from("0x1").verb == .unknown);
    try expect(Reply.no_such_nick.isError());
    try expect(!Reply.welcome.isError());

    var room: [WORD_MAX]u8 = undefined;
    try expectEqualStrings("PRIVMSG", (Command{ .verb = .privmsg }).spell(&room));
    try expectEqualStrings("001", (Command{ .reply = .welcome }).spell(&room));
    try expectEqualStrings("433", (Command{ .reply = .nickname_in_use }).spell(&room));
}

test "more tags than TAG_MAX sets crowded" {
    var buf: [MAX]u8 = undefined;
    var out: Out = .{ .buf = &buf };
    try out.byte('@');
    for (0..TAG_MAX + 4) |i| {
        if (i != 0) try out.byte(';');
        try out.text("t");
        var digits: [4]u8 = undefined;
        try out.text(std.fmt.bufPrint(&digits, "{d}", .{i}) catch unreachable);
    }
    try out.text(" PRIVMSG #room :hello");

    const line = try parse(buf[0..out.len]);
    try expect(line.crowded);
    try expect(line.tags.len == TAG_MAX);
    try expectEqualStrings("hello", line.text());
}

test "a non-final parameter needing trailing is an error" {
    var buf: [MAX]u8 = undefined;

    var plain: Line = .{ .word = "JOIN" };
    try plain.params.append("#room");
    try plain.params.append("key");
    try expectEqualStrings("JOIN #room key", try render(&buf, plain));

    var spaced: Line = .{ .word = "PRIVMSG" };
    try spaced.params.append("#room");
    try spaced.params.append("hello there");
    try expectEqualStrings("PRIVMSG #room :hello there", try render(&buf, spaced));

    var broken: Line = .{ .word = "PRIVMSG" };
    try broken.params.append("two words");
    try broken.params.append("text");
    try std.testing.expectError(error.BadParam, render(&buf, broken));

    var empty: Line = .{ .word = "PRIVMSG" };
    try empty.params.append("");
    try empty.params.append("text");
    try std.testing.expectError(error.BadParam, render(&buf, empty));
}

test "malformed lines are rejected" {
    var empty: [0]u8 = undefined;
    try std.testing.expectError(error.NoCommand, parse(&empty));

    var tagged = "@a=b ".*;
    try std.testing.expectError(error.NoCommand, parse(&tagged));

    var unterminated = "@a=b".*;
    try std.testing.expectError(error.Truncated, parse(&unterminated));

    var source = ":nick!user@host".*;
    try std.testing.expectError(error.Truncated, parse(&source));
}

test "framing reassembles lines split across reads" {
    var stream: Stream = .{};

    // Half a line, then the rest of it and two more.
    const first = "PING :ab";
    @memcpy(stream.room()[0..first.len], first);
    stream.filled(first.len);
    try expect(stream.next() == null);

    const rest = "cd\r\n:nick!u@h PRIVMSG #room :hello\r\nPART #room\r";
    @memcpy(stream.room()[0..rest.len], rest);
    stream.filled(rest.len);

    try expectEqualStrings("PING :abcd", stream.next() orelse return error.NoLine);
    try expectEqualStrings(":nick!u@h PRIVMSG #room :hello", stream.next() orelse return error.NoLine);
    try expectEqualStrings("PART #room", stream.next() orelse return error.NoLine);
    try expect(stream.next() == null);

    // A lone LF ends a line just as a pair does, and the empty line a pair
    // leaves behind is not handed on.
    const bare = "\nQUIT :bye\n";
    @memcpy(stream.room()[0..bare.len], bare);
    stream.filled(bare.len);
    try expectEqualStrings("QUIT :bye", stream.next() orelse return error.NoLine);
    try expect(stream.next() == null);
    try expect(!stream.dropped);
}

test "an over-long line is dropped whole" {
    var stream: Stream = .{};

    var overlong: [WHOLE_MAX + 32]u8 = @splat('x');
    @memcpy(overlong[0..5], "PING ");
    var at: usize = 0;
    while (at < overlong.len) {
        const room = stream.room();
        if (room.len == 0) {
            try expect(stream.next() == null);
            continue;
        }
        const take = @min(room.len, overlong.len - at);
        @memcpy(room[0..take], overlong[at..][0..take]);
        stream.filled(take);
        at += take;
        _ = stream.next();
    }
    try expect(stream.dropped);

    const after = "\r\nPING :fine\r\n";
    @memcpy(stream.room()[0..after.len], after);
    stream.filled(after.len);
    try expectEqualStrings("PING :fine", stream.next() orelse return error.NoLine);
}
