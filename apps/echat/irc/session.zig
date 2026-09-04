//! Connecting to a network and staying connected.
//!
//! Registration is a negotiation. The client lists the extensions it speaks,
//! the server lists what it has, both agree on a set, an account is
//! authenticated if there is one, and only then does registration finish.
//! Each step has a reply to wait for and its own failure modes.
//!
//! The caller feeds it received lines and takes lines to send. No I/O, no
//! waiting, no allocation.

const std = @import("std");
const lib = @import("lib");
const wire = @import("line.zig");
const support = @import("support.zig");

const Bounded = lib.bounded.Bounded;
const Line = wire.Line;

/// The RFC default is nine characters and networks raise it; this is above
/// what any of them advertise.
pub const NICK_MAX = 32;

/// Limits on the account name and password.
pub const ACCOUNT_MAX = 64;
pub const PASSWORD_MAX = 128;

/// How many times `_` is appended to a taken nick before giving up.
pub const ALTERNATES = 3;

/// Bytes per `AUTHENTICATE`, from the SASL extension.
const CHUNK = 400;

/// The authentication response before and after encoding.
const RAW_MAX = ACCOUNT_MAX + PASSWORD_MAX + 2;
const SECRET_MAX = std.base64.standard.Encoder.calcSize(RAW_MAX);

/// Outbox capacity. The largest burst is authentication, which can be two
/// lines.
const OUTBOX = 2048;

/// How long a quiet connection goes before a keepalive ping, and how long to
/// wait for the answer. A network can be quiet for minutes, so a dead
/// connection is indistinguishable from an idle one until something is
/// sent.
pub const QUIET_MILLIS: u64 = 120_000;
pub const ANSWER_MILLIS: u64 = 60_000;

/// How long registration is given before the connection is considered dead.
pub const REGISTER_MILLIS: u64 = 60_000;

/// An extension this client requests. Each is used by the client; requesting
/// one nothing reads only adds lines to skip.
pub const Cap = enum {
    /// Who is logged in as whom, on change and on each message.
    account_notify,
    account_tag,
    /// Away, host and real-name changes, pushed rather than polled.
    away_notify,
    chghost,
    setname,
    /// Which batch a run of lines belongs to.
    batch,
    /// Capabilities added and removed while connected.
    cap_notify,
    /// Our own messages are echoed back, so one code path draws them all.
    echo_message,
    /// Account and real name on a join, and who sent an invite.
    extended_join,
    invite_notify,
    /// Tags generally, which carry the timestamp and message id.
    message_tags,
    server_time,
    /// All of a name's membership prefixes, not just the highest.
    multi_prefix,
    userhost_in_names,
    /// Account authentication.
    sasl,
    /// Failures worded the same way across networks.
    standard_replies,

    /// The wire name: the field name with hyphens for underscores.
    pub fn spell(self: Cap) []const u8 {
        return NAMES[@intFromEnum(self)];
    }

    pub fn from(text: []const u8) ?Cap {
        return BY_NAME.get(text);
    }
};

const NAMES = names: {
    const fields = @typeInfo(Cap).@"enum".fields;
    var out: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, i| {
        var spelled: [field.name.len]u8 = field.name[0..field.name.len].*;
        for (&spelled) |*ch| {
            if (ch.* == '_') ch.* = '-';
        }
        const settled = spelled;
        out[i] = &settled;
    }
    break :names out;
};

const BY_NAME = std.StaticStringMap(Cap).initComptime(pairs: {
    const fields = @typeInfo(Cap).@"enum".fields;
    var out: [fields.len]struct { []const u8, Cap } = undefined;
    for (fields, 0..) |field, i| out[i] = .{ NAMES[i], @enumFromInt(field.value) };
    break :pairs out;
});

pub const Caps = std.EnumSet(Cap);

/// How far registration has got.
pub const State = enum {
    /// Nothing sent yet.
    idle,
    /// `CAP LS` sent, the list is arriving.
    listing,
    /// `CAP REQ` sent, waiting for the answer.
    requesting,
    /// Authenticating an account.
    authenticating,
    /// Negotiation done, waiting for the welcome.
    registering,
    /// Registered and usable.
    ready,
    /// Finished. `closed` says why.
    closed,
};

/// Why a session ended.
pub const Closed = enum {
    /// The server ended it, or stopped answering.
    server,
    /// Every nick tried was taken.
    no_nick,
    /// The server password was refused.
    rejected,
    /// The account was not authenticated.
    unauthenticated,

    pub fn spell(self: Closed) []const u8 {
        return switch (self) {
            .server => "the server ended the connection",
            .no_nick => "every name tried was taken",
            .rejected => "the server password was refused",
            .unauthenticated => "the account was not accepted",
        };
    }
};

/// How to authenticate, if at all.
pub const Credentials = union(enum) {
    none,
    /// An account and its password.
    plain: struct { account: []const u8, password: []const u8 },
    /// The certificate the transport already presented.
    external,

    /// The SASL mechanism to use.
    pub fn mechanism(self: Credentials) ?[]const u8 {
        return switch (self) {
            .none => null,
            .plain => "PLAIN",
            .external => "EXTERNAL",
        };
    }
};

/// What the caller must act on. Anything else the session handled itself; the
/// caller can still display the line.
pub const Event = union(enum) {
    /// Nothing for the caller to do.
    none,
    /// Registration finished; the network is usable.
    ready,
    /// This client's nick changed to this.
    renamed: []const u8,
    /// The session ended, for this reason.
    closed: Closed,
};

pub const Session = struct {
    /// The nick in use. A taken one gains an underscore, so this is not
    /// necessarily the one first requested.
    nick: Bounded(u8, NICK_MAX) = .{},
    user: []const u8 = "",
    real: []const u8 = "",
    /// The server password, sent before anything else if set.
    pass: []const u8 = "",
    account: Credentials = .none,
    /// Whether failed authentication ends the session. Set this where the
    /// nick is registered and connecting unauthenticated is worse than not
    /// connecting.
    require_account: bool = false,

    state: State = .idle,
    closed: Closed = .server,
    support: support.Support = .{},

    /// What the server offers and what is currently enabled.
    available: Caps = .initEmpty(),
    enabled: Caps = .initEmpty(),
    /// The mechanisms the server named on its `sasl` capability.
    mechanisms: Bounded(u8, 128) = .{},
    /// Unanswered `CAP REQ` lines.
    asked: u8 = 0,
    /// Alternate nicks tried.
    tried: u8 = 0,

    /// The encoded authentication response.
    secret: Bounded(u8, SECRET_MAX) = .{},

    /// Lines waiting to go out, each with its CRLF.
    outbox: Bounded(u8, OUTBOX) = .{},
    /// A line did not fit and was not sent. The caller reports this and
    /// clears it; nothing is dropped silently.
    stalled: bool = false,

    /// When registration began, when a line was last received, and whether a
    /// keepalive is outstanding.
    began: u64 = 0,
    heard: u64 = 0,
    probed: u64 = 0,
    waiting: bool = false,
    stirred: bool = false,

    /// Set the nick to request. Call before `begin`.
    pub fn wants(self: *Session, nick: []const u8) void {
        _ = self.nick.set(nick);
    }

    /// Queue everything a client sends before the server says anything.
    pub fn begin(self: *Session) void {
        self.state = .listing;
        // Version 302 means this client handles capability values, replies
        // split across lines, and `CAP NEW` and `CAP DEL`.
        self.say(.{ .verb = .cap }, &.{ "LS", "302" });
        if (self.pass.len != 0) self.say(.{ .verb = .pass }, &.{self.pass});
        self.say(.{ .verb = .nick }, &.{self.nick.slice()});
        // The two middle parameters are a mode and an unused field, ignored
        // by every server since RFC 2812.
        self.tell(.{ .verb = .user }, &.{ self.user, "0", "*", self.real });
    }

    /// Handle a received line.
    pub fn receive(self: *Session, line: *const Line) Event {
        self.stirred = true;
        self.waiting = false;
        const event: Event = switch (line.command) {
            .verb => |verb| switch (verb) {
                .ping => self.answering(line.text()),
                .@"error" => self.closing(.server),
                .cap => self.negotiate(line),
                .authenticate => self.prove(),
                .nick => self.renamed(line),
                else => .none,
            },
            .reply => |reply| switch (reply) {
                .welcome => self.welcomed(line),
                .isupport => blk: {
                    self.support.read(line);
                    break :blk .none;
                },
                .nickname_in_use, .erroneous_nickname, .nick_collision => self.taken(),
                // Logged in, or already logged in, which is a repeat rather
                // than a failure. Either way negotiation can end.
                .sasl_success, .logged_in, .sasl_already => blk: {
                    if (self.state == .authenticating) self.endCaps();
                    break :blk .none;
                },
                // The mechanism list is its own parameter; the last one is
                // human-readable text.
                .sasl_mechs => blk: {
                    self.remember(line.param(1) orelse "");
                    break :blk .none;
                },
                .sasl_fail, .sasl_too_long, .sasl_aborted, .nick_locked => self.refused(),
                .password_mismatch => self.closing(.rejected),
                else => .none,
            },
        };
        return self.ended(event);
    }

    /// Bytes waiting to go out. Write what the transport accepts and report
    /// how much with `sent`.
    pub fn pending(self: *const Session) []const u8 {
        return self.outbox.slice();
    }

    /// How many bytes of `pending` were written.
    pub fn sent(self: *Session, count: usize) void {
        const gone = @min(count, self.outbox.len);
        std.mem.copyForwards(u8, self.outbox.items[0 .. self.outbox.len - gone], self.outbox.items[gone..self.outbox.len]);
        self.outbox.len -= gone;
    }

    /// Queue a line built by the caller.
    pub fn send(self: *Session, line: Line) void {
        self.put(line);
    }

    /// Send `QUIT` and end the session.
    pub fn quit(self: *Session, why: []const u8) void {
        self.tell(.{ .verb = .quit }, &.{why});
        self.state = .closed;
        self.closed = .server;
    }

    /// Keepalive and timeout handling. `now` is milliseconds from any fixed
    /// point.
    pub fn tick(self: *Session, now: u64) Event {
        if (self.heard == 0 or self.stirred) {
            self.stirred = false;
            self.heard = now;
        }
        if (self.state != .ready) {
            if (self.state == .idle or self.state == .closed) return .none;
            if (self.began == 0) self.began = now;
            if (now -| self.began >= REGISTER_MILLIS) return self.ended(self.closing(.server));
            return .none;
        }

        if (self.waiting) {
            if (now -| self.probed >= ANSWER_MILLIS) return self.ended(self.closing(.server));
            return .none;
        }
        if (now -| self.heard >= QUIET_MILLIS) {
            self.tell(.{ .verb = .ping }, &.{self.nick.slice()});
            self.probed = now;
            self.waiting = true;
        }
        return .none;
    }

    /// Whether an extension is enabled.
    pub fn has(self: *const Session, cap: Cap) bool {
        return self.enabled.contains(cap);
    }

    // -- capability negotiation

    fn negotiate(self: *Session, line: *const Line) Event {
        const sub = line.param(1) orelse return .none;
        // Every line but the last of a split reply carries a lone asterisk.
        const more = if (line.param(2)) |mark| std.mem.eql(u8, mark, "*") else false;
        const list = line.text();

        if (lib.str.eqlFold(sub, "LS")) {
            self.offered(list);
            if (!more) self.request();
        } else if (lib.str.eqlFold(sub, "NEW")) {
            self.offered(list);
            self.request();
        } else if (lib.str.eqlFold(sub, "ACK")) {
            self.granted(list);
        } else if (lib.str.eqlFold(sub, "NAK")) {
            // The server changed nothing. Forgetting them stops the client
            // asking again.
            var each = lib.str.words(list);
            while (each.next()) |name| {
                if (Cap.from(name)) |cap| self.available.remove(cap);
            }
            self.answered();
        } else if (lib.str.eqlFold(sub, "DEL")) {
            var each = lib.str.words(list);
            while (each.next()) |name| {
                if (Cap.from(name)) |cap| {
                    self.available.remove(cap);
                    self.enabled.remove(cap);
                }
            }
        }
        return .none;
    }

    /// Parse a capability list, which at version 302 may carry values.
    fn offered(self: *Session, list: []const u8) void {
        var each = lib.str.words(list);
        while (each.next()) |token| {
            const equals = std.mem.indexOfScalar(u8, token, '=');
            const name = if (equals) |i| token[0..i] else token;
            const cap = Cap.from(name) orelse continue;
            self.available.insert(cap);
            // The mechanism list arrives as the capability's value.
            if (cap == .sasl) self.remember(if (equals) |i| token[i + 1 ..] else "");
        }
    }

    /// Request everything wanted that is offered and not already enabled.
    fn request(self: *Session) void {
        var wanted = Caps.initFull();
        // Requesting sasl with no credentials would stall registration
        // waiting for a reply that never comes.
        if (self.account == .none) wanted.remove(.sasl);

        var missing = wanted;
        missing.setIntersection(self.available);
        missing = missing.differenceWith(self.enabled);
        if (missing.count() == 0) {
            self.endCaps();
            return;
        }

        // What `CAP REQ :` and the CRLF leave for names.
        const overhead = "CAP REQ :\r\n".len;
        const budget = @as(usize, self.support.linelen) - overhead;

        var room: [wire.MAX]u8 = undefined;
        var len: usize = 0;
        var each = missing.iterator();
        while (each.next()) |cap| {
            const name = cap.spell();
            if (len != 0 and len + 1 + name.len > budget) {
                self.ask(room[0..len]);
                len = 0;
            }
            if (len != 0) {
                room[len] = ' ';
                len += 1;
            }
            @memcpy(room[len..][0..name.len], name);
            len += name.len;
        }
        if (len != 0) self.ask(room[0..len]);
        // A capability offered after registration is requested the same way,
        // but it is not part of registration.
        if (self.state != .ready) self.state = .requesting;
    }

    fn ask(self: *Session, list: []const u8) void {
        self.tell(.{ .verb = .cap }, &.{ "REQ", list });
        self.asked += 1;
    }

    /// A granted capability list. A name prefixed with a minus was disabled
    /// at the client's request.
    fn granted(self: *Session, list: []const u8) void {
        var each = lib.str.words(list);
        while (each.next()) |token| {
            const dropping = token.len != 0 and token[0] == '-';
            const cap = Cap.from(if (dropping) token[1..] else token) orelse continue;
            if (dropping) self.enabled.remove(cap) else self.enabled.insert(cap);
        }
        self.answered();
    }

    /// One request answered. Nothing proceeds until all of them are.
    fn answered(self: *Session) void {
        self.asked -|= 1;
        if (self.asked != 0) return;
        if (self.state == .ready) return;
        if (self.has(.sasl) and self.account != .none) {
            self.startAuth();
        } else {
            self.endCaps();
        }
    }

    /// Send `CAP END`. Only during registration: a capability granted later
    /// must not end a registration that already finished.
    fn endCaps(self: *Session) void {
        if (self.state == .ready or self.state == .closed or self.state == .registering) return;
        self.say(.{ .verb = .cap }, &.{"END"});
        self.state = .registering;
    }

    // -- proving an account

    fn remember(self: *Session, list: []const u8) void {
        _ = self.mechanisms.set(list);
    }

    /// Whether the server accepts this mechanism. A server that named none
    /// is tried anyway, as the extension says to do.
    fn offersMechanism(self: *const Session, mechanism: []const u8) bool {
        if (self.mechanisms.len == 0) return true;
        var each = lib.str.split(self.mechanisms.slice(), ',');
        while (each.next()) |named| {
            if (lib.str.eqlFold(named, mechanism)) return true;
        }
        return false;
    }

    fn startAuth(self: *Session) void {
        const mechanism = self.account.mechanism() orelse return self.endCaps();
        if (!self.offersMechanism(mechanism) or !self.buildSecret()) {
            _ = self.refusedOrOn();
            return;
        }
        self.state = .authenticating;
        self.say(.{ .verb = .authenticate }, &.{mechanism});
    }

    /// Send the response the server prompted for, in 400-byte pieces. A
    /// piece that fills one exactly is followed by an empty one so the server
    /// knows where the response ended.
    fn prove(self: *Session) Event {
        if (self.state != .authenticating) return .none;
        const payload = self.secret.slice();
        var at: usize = 0;
        while (at < payload.len) {
            const piece = payload[at..@min(at + CHUNK, payload.len)];
            at += piece.len;
            self.say(.{ .verb = .authenticate }, &.{piece});
        }
        if (payload.len == 0 or payload.len % CHUNK == 0) {
            self.say(.{ .verb = .authenticate }, &.{"+"});
        }
        return .none;
    }

    /// Build and encode the response. False if the configured credentials do
    /// not fit, which fails authentication rather than truncating them.
    fn buildSecret(self: *Session) bool {
        self.secret.clear();
        const named = switch (self.account) {
            // Nothing to send: the certificate is the proof.
            .none, .external => return true,
            .plain => |it| it,
        };
        if (named.account.len > ACCOUNT_MAX or named.password.len > PASSWORD_MAX) return false;

        // Each part is preceded by a null. The first, the identity to act
        // as, is left empty, so the named account is the one logged in as.
        var raw: [RAW_MAX]u8 = undefined;
        var at: usize = 0;
        for ([_][]const u8{ named.account, named.password }) |part| {
            raw[at] = 0;
            at += 1;
            @memcpy(raw[at..][0..part.len], part);
            at += part.len;
        }
        self.secret.len = std.base64.standard.Encoder.encode(&self.secret.items, raw[0..at]).len;
        return true;
    }

    fn refused(self: *Session) Event {
        if (self.state != .authenticating) return .none;
        return self.refusedOrOn();
    }

    /// Failed authentication either ends the session or is ignored.
    fn refusedOrOn(self: *Session) Event {
        if (self.require_account) return self.closing(.unauthenticated);
        self.endCaps();
        return .none;
    }

    // -- names

    fn welcomed(self: *Session, line: *const Line) Event {
        if (line.param(0)) |name| self.rename(name);
        self.state = .ready;
        return .ready;
    }

    fn taken(self: *Session) Event {
        // After registration this is the caller's to report: someone asked
        // for a nick and did not get it.
        if (self.state == .ready or self.state == .closed) return .none;
        if (self.tried >= ALTERNATES) return self.closing(.no_nick);
        self.tried += 1;
        self.nick.append('_') catch return self.closing(.no_nick);
        self.say(.{ .verb = .nick }, &.{self.nick.slice()});
        return .none;
    }

    fn renamed(self: *Session, line: *const Line) Event {
        if (!self.support.same(line.nick(), self.nick.slice())) return .none;
        self.rename(line.text());
        return .{ .renamed = self.nick.slice() };
    }

    fn rename(self: *Session, name: []const u8) void {
        self.nick.clear();
        _ = self.nick.set(name);
    }

    // -- saying things

    fn close(self: *Session, why: Closed) void {
        self.state = .closed;
        self.closed = why;
    }

    /// The event, or a closing event if this pass ended the session. Every
    /// ending goes through here, so no inner step has to return one.
    fn ended(self: *const Session, event: Event) Event {
        if (self.state == .closed and event != .closed) return .{ .closed = self.closed };
        return event;
    }

    /// End the session, for use as a switch arm's value.
    fn closing(self: *Session, why: Closed) Event {
        self.close(why);
        return .none;
    }

    fn say(self: *Session, command: wire.Command, params: []const []const u8) void {
        self.speak(command, params, false);
    }

    /// The same, for a command whose last parameter is free text: a reason,
    /// a message, a list.
    fn tell(self: *Session, command: wire.Command, params: []const []const u8) void {
        self.speak(command, params, true);
    }

    fn speak(self: *Session, command: wire.Command, params: []const []const u8, trail: bool) void {
        var line: Line = .{ .command = command, .trail = trail };
        for (params) |item| {
            line.params.append(item) catch {
                self.stalled = true;
                return;
            };
        }
        self.put(line);
    }

    /// Answer a `PING`, for use as a switch arm's value.
    fn answering(self: *Session, token: []const u8) Event {
        self.tell(.{ .verb = .pong }, &.{token});
        return .none;
    }

    fn put(self: *Session, line: Line) void {
        const room = self.outbox.items[self.outbox.len..];
        // The network's limit including the CRLF, capped by outbox space.
        const budget = @min(room.len, @as(usize, self.support.linelen));
        if (budget < 3) {
            self.stalled = true;
            return;
        }
        const written = wire.render(room[0 .. budget - 2], line) catch {
            self.stalled = true;
            return;
        };
        room[written.len] = '\r';
        room[written.len + 1] = '\n';
        self.outbox.len += written.len + 2;
    }
};

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Feed the session a line, as a transport would.
fn feed(session: *Session, text: []const u8) !Event {
    var buf: [wire.WHOLE_MAX]u8 = undefined;
    @memcpy(buf[0..text.len], text);
    const line = try wire.parse(buf[0..text.len]);
    return session.receive(&line);
}

/// Take everything the session wants to send.
fn drain(session: *Session, room: []u8) []const u8 {
    const waiting = session.pending();
    @memcpy(room[0..waiting.len], waiting);
    session.sent(waiting.len);
    return room[0..waiting.len];
}

fn started(session: *Session) void {
    session.wants("echo");
    session.user = "echo";
    session.real = "Echo";
    session.begin();
}

test "the opening lines a client sends" {
    var session: Session = .{};
    var room: [OUTBOX]u8 = undefined;
    started(&session);

    try expectEqualStrings(
        "CAP LS 302\r\n" ++
            "NICK echo\r\n" ++
            "USER echo 0 * :Echo\r\n",
        drain(&session, &room),
    );
    try expect(session.state == .listing);
    try expect(!session.stalled);
}

test "a CAP LS split across lines is answered once" {
    var session: Session = .{};
    var room: [OUTBOX]u8 = undefined;
    started(&session);
    _ = drain(&session, &room);

    _ = try feed(&session, ":serv CAP * LS * :multi-prefix server-time");
    try expectEqualStrings("", drain(&session, &room));
    try expect(session.state == .listing);

    _ = try feed(&session, ":serv CAP * LS :away-notify example.org/thing");
    const asked = drain(&session, &room);
    try expect(std.mem.startsWith(u8, asked, "CAP REQ :"));
    try expect(std.mem.endsWith(u8, asked, "\r\n"));
    // Only what the server offered and this client uses.
    try expect(std.mem.count(u8, asked, " ") == 4);
    try expect(std.mem.indexOf(u8, asked, "multi-prefix") != null);
    try expect(std.mem.indexOf(u8, asked, "server-time") != null);
    try expect(std.mem.indexOf(u8, asked, "away-notify") != null);
    try expect(std.mem.indexOf(u8, asked, "example.org") == null);
    try expect(session.state == .requesting);

    _ = try feed(&session, ":serv CAP * ACK :multi-prefix server-time away-notify");
    try expectEqualStrings("CAP END\r\n", drain(&session, &room));
    try expect(session.state == .registering);
    try expect(session.has(.multi_prefix));
    try expect(session.has(.server_time));
    try expect(!session.has(.batch));

    const event = try feed(&session, ":serv 001 echo :Welcome to the network");
    try expect(event == .ready);
    try expect(session.state == .ready);
}

test "a server offering nothing this client wants" {
    var session: Session = .{};
    var room: [OUTBOX]u8 = undefined;
    started(&session);
    _ = drain(&session, &room);

    _ = try feed(&session, ":serv CAP * LS :draft/one draft/two");
    try expectEqualStrings("CAP END\r\n", drain(&session, &room));
    try expect(session.state == .registering);
}

test "a server with no CAP support" {
    var session: Session = .{};
    var room: [OUTBOX]u8 = undefined;
    started(&session);
    _ = drain(&session, &room);

    const event = try feed(&session, ":serv 001 echo :Welcome");
    try expect(event == .ready);
    try expectEqualStrings("", drain(&session, &room));
}

test "a CAP NAK does not stall registration" {
    var session: Session = .{};
    var room: [OUTBOX]u8 = undefined;
    started(&session);
    _ = drain(&session, &room);

    _ = try feed(&session, ":serv CAP * LS :multi-prefix");
    _ = drain(&session, &room);
    _ = try feed(&session, ":serv CAP * NAK :multi-prefix");
    try expectEqualStrings("CAP END\r\n", drain(&session, &room));
    try expect(!session.has(.multi_prefix));
    try expect(!session.available.contains(.multi_prefix));
}

test "SASL PLAIN authentication" {
    var session: Session = .{ .account = .{ .plain = .{ .account = "echo", .password = "secret" } } };
    var room: [OUTBOX]u8 = undefined;
    started(&session);
    _ = drain(&session, &room);

    _ = try feed(&session, ":serv CAP * LS :sasl=PLAIN,EXTERNAL server-time");
    const asked = drain(&session, &room);
    try expect(std.mem.indexOf(u8, asked, "sasl") != null);

    _ = try feed(&session, ":serv CAP * ACK :sasl server-time");
    try expectEqualStrings("AUTHENTICATE PLAIN\r\n", drain(&session, &room));
    try expect(session.state == .authenticating);

    _ = try feed(&session, "AUTHENTICATE +");
    try expectEqualStrings("AUTHENTICATE AGVjaG8Ac2VjcmV0\r\n", drain(&session, &room));

    _ = try feed(&session, ":serv 900 echo echo!e@h echo :You are now logged in as echo");
    _ = try feed(&session, ":serv 903 echo :SASL authentication successful");
    try expectEqualStrings("CAP END\r\n", drain(&session, &room));
    try expect(session.state == .registering);
}

test "a response filling a piece exactly is followed by an empty one" {
    // The extension requires an empty piece after a response of exactly 400
    // encoded bytes, so the server knows it ended.
    const account = "a" ** 64;
    const password = "b" ** 128;
    var session: Session = .{ .account = .{ .plain = .{ .account = account, .password = password } } };
    var room: [OUTBOX]u8 = undefined;
    started(&session);
    _ = drain(&session, &room);

    _ = try feed(&session, ":serv CAP * LS :sasl=PLAIN");
    _ = drain(&session, &room);
    _ = try feed(&session, ":serv CAP * ACK :sasl");
    _ = drain(&session, &room);
    _ = try feed(&session, "AUTHENTICATE +");

    const said = drain(&session, &room);
    var lines = std.mem.splitSequence(u8, said, "\r\n");
    const first = lines.next() orelse return error.NoLine;
    // 260 encoded bytes is one piece and no empty one after it.
    try expect(first.len == "AUTHENTICATE ".len + 260);
    try expectEqualStrings("", lines.next() orelse return error.NoLine);
    try expect(lines.next() == null);
}

test "SASL EXTERNAL sends an empty response" {
    var session: Session = .{ .account = .external };
    var room: [OUTBOX]u8 = undefined;
    started(&session);
    _ = drain(&session, &room);

    _ = try feed(&session, ":serv CAP * LS :sasl=EXTERNAL");
    _ = drain(&session, &room);
    _ = try feed(&session, ":serv CAP * ACK :sasl");
    try expectEqualStrings("AUTHENTICATE EXTERNAL\r\n", drain(&session, &room));
    _ = try feed(&session, "AUTHENTICATE +");
    try expectEqualStrings("AUTHENTICATE +\r\n", drain(&session, &room));
}

test "the mechanism list from RPL_SASLMECHS" {
    var session: Session = .{ .account = .external };
    started(&session);
    _ = try feed(&session, ":serv 908 echo PLAIN,EXTERNAL,SCRAM-SHA-256 :are available SASL mechanisms");
    try expectEqualStrings("PLAIN,EXTERNAL,SCRAM-SHA-256", session.mechanisms.slice());
    try expect(session.offersMechanism("EXTERNAL"));
    try expect(!session.offersMechanism("ANONYMOUS"));
}

test "an unsupported mechanism is not attempted" {
    var session: Session = .{ .account = .external };
    var room: [OUTBOX]u8 = undefined;
    started(&session);
    _ = drain(&session, &room);

    _ = try feed(&session, ":serv CAP * LS :sasl=PLAIN,SCRAM-SHA-256");
    _ = drain(&session, &room);
    _ = try feed(&session, ":serv CAP * ACK :sasl");
    try expectEqualStrings("CAP END\r\n", drain(&session, &room));
}

test "failed authentication, with and without require_account" {
    var carried: Session = .{ .account = .{ .plain = .{ .account = "echo", .password = "wrong" } } };
    var room: [OUTBOX]u8 = undefined;
    started(&carried);
    _ = drain(&carried, &room);
    _ = try feed(&carried, ":serv CAP * LS :sasl=PLAIN");
    _ = drain(&carried, &room);
    _ = try feed(&carried, ":serv CAP * ACK :sasl");
    _ = drain(&carried, &room);
    const carrying = try feed(&carried, ":serv 904 echo :SASL authentication failed");
    try expect(carrying == .none);
    try expectEqualStrings("CAP END\r\n", drain(&carried, &room));

    var strict: Session = .{
        .account = .{ .plain = .{ .account = "echo", .password = "wrong" } },
        .require_account = true,
    };
    started(&strict);
    _ = drain(&strict, &room);
    _ = try feed(&strict, ":serv CAP * LS :sasl=PLAIN");
    _ = drain(&strict, &room);
    _ = try feed(&strict, ":serv CAP * ACK :sasl");
    _ = drain(&strict, &room);
    const stopping = try feed(&strict, ":serv 904 echo :SASL authentication failed");
    try expect(stopping.closed == .unauthenticated);
    try expect(strict.state == .closed);
}

test "a taken nick is retried, then given up" {
    var session: Session = .{};
    var room: [OUTBOX]u8 = undefined;
    started(&session);
    _ = drain(&session, &room);

    for ([_][]const u8{ "echo_", "echo__", "echo___" }) |wanted| {
        _ = try feed(&session, ":serv 433 * echo :Nickname is already in use");
        var expected: [32]u8 = undefined;
        try expectEqualStrings(
            std.fmt.bufPrint(&expected, "NICK {s}\r\n", .{wanted}) catch unreachable,
            drain(&session, &room),
        );
        try expectEqualStrings(wanted, session.nick.slice());
    }
    const given_up = try feed(&session, ":serv 433 * echo :Nickname is already in use");
    try expect(given_up.closed == .no_nick);

    // After registration a refused name is the app's to report, not a reason
    // to end the session.
    var settled: Session = .{ .state = .ready };
    settled.wants("echo");
    try expect(try feed(&settled, ":serv 433 echo taken :Nickname is already in use") == .none);
    try expect(settled.state == .ready);
}

test "the session nick tracks NICK messages" {
    var session: Session = .{ .state = .ready };
    session.wants("echo");

    const renamed = try feed(&session, ":echo!e@h NICK :ekko");
    try expectEqualStrings("ekko", renamed.renamed);
    try expectEqualStrings("ekko", session.nick.slice());

    // Somebody else's rename is not ours, whatever the case of the name.
    try expect(try feed(&session, ":other!o@h NICK :another") == .none);
    try expectEqualStrings("ekko", session.nick.slice());
    try expect(try feed(&session, ":EKKO!e@h NICK :echo") == .renamed);
}

test "PING is answered, ERROR ends the session" {
    var session: Session = .{ .state = .ready };
    var room: [OUTBOX]u8 = undefined;
    session.wants("echo");

    _ = try feed(&session, "PING :abcdef");
    try expectEqualStrings("PONG :abcdef\r\n", drain(&session, &room));

    const ended = try feed(&session, "ERROR :Closing link");
    try expect(ended.closed == .server);
    try expect(session.state == .closed);
}

test "keepalive ping and timeout" {
    var session: Session = .{ .state = .ready };
    var room: [OUTBOX]u8 = undefined;
    session.wants("echo");

    try expect(session.tick(1_000) == .none);
    try expect(session.tick(1_000 + QUIET_MILLIS - 1) == .none);
    try expectEqualStrings("", drain(&session, &room));

    try expect(session.tick(1_000 + QUIET_MILLIS) == .none);
    try expectEqualStrings("PING :echo\r\n", drain(&session, &room));

    // Anything at all counts as an answer.
    _ = try feed(&session, ":serv PONG serv :echo");
    try expect(session.tick(1_000 + QUIET_MILLIS + ANSWER_MILLIS + 1) == .none);

    _ = session.tick(500_000);
    _ = drain(&session, &room);
    const gone = session.tick(500_000 + QUIET_MILLIS + ANSWER_MILLIS);
    try expect(gone.closed == .server);
}

test "registration times out" {
    var session: Session = .{};
    var room: [OUTBOX]u8 = undefined;
    started(&session);
    _ = drain(&session, &room);

    try expect(session.tick(1_000) == .none);
    _ = try feed(&session, ":serv NOTICE * :*** Looking up your hostname");
    try expect(session.tick(1_000 + REGISTER_MILLIS - 1) == .none);

    // Lines arriving are not the same as registration finishing.
    const given_up = session.tick(1_000 + REGISTER_MILLIS);
    try expect(given_up.closed == .server);

    // A session that did register is left alone for far longer.
    var settled: Session = .{};
    started(&settled);
    _ = try feed(&settled, ":serv 001 echo :Welcome");
    _ = settled.tick(1_000);
    try expect(settled.tick(1_000 + REGISTER_MILLIS) == .none);
}

test "CAP NEW and CAP DEL after registration" {
    var session: Session = .{};
    var room: [OUTBOX]u8 = undefined;
    started(&session);
    _ = drain(&session, &room);
    _ = try feed(&session, ":serv CAP * LS :multi-prefix");
    _ = drain(&session, &room);
    _ = try feed(&session, ":serv CAP * ACK :multi-prefix");
    _ = drain(&session, &room);
    _ = try feed(&session, ":serv 001 echo :Welcome");

    _ = try feed(&session, ":serv CAP echo NEW :away-notify");
    try expectEqualStrings("CAP REQ :away-notify\r\n", drain(&session, &room));
    _ = try feed(&session, ":serv CAP echo ACK :away-notify");
    try expect(session.has(.away_notify));
    // No second ending: registration is long over.
    try expectEqualStrings("", drain(&session, &room));

    _ = try feed(&session, ":serv CAP echo DEL :away-notify multi-prefix");
    try expect(!session.has(.away_notify));
    try expect(!session.has(.multi_prefix));
}

test "ISUPPORT reaches the session" {
    var session: Session = .{ .state = .ready };
    session.wants("echo");
    _ = try feed(&session, ":serv 005 echo NETWORK=Libera.Chat NICKLEN=16 CHANTYPES=# :are supported");
    try expectEqualStrings("Libera.Chat", session.support.network.slice());
    try expect(session.support.nicklen == 16);
    try expect(session.support.isChannel("#room"));
}
