//! echat: an IRC client.
//!
//! The window over `irc.zig`, which is the protocol and knows nothing about a
//! socket, and over `rooms.zig`, which is what has been said and knows nothing
//! about drawing. This file is the part that has to know about both: it opens
//! the connections, hands arriving bytes to the engine, writes what the engine
//! makes of them into the model, and draws the model.
//!
//! Not part of the system. It is built into `home/` and versioned on its own.

const std = @import("std");
const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const lib = @import("lib");
const ulib = @import("ulib");

const env = ulib.env;
const out = ulib.out;
const sock = ulib.sock;

const irc = @import("irc.zig");
const rooms = @import("rooms.zig");
const layout = @import("layout.zig");

const theme = eui.theme;
const Rect = eui.Rect;
const Surface = eui.Surface;
const civil = lib.civil;
const Bounded = lib.bounded.Bounded;

const ctx = &proto.app.ctx;

/// echat's own version. An application outside the system is versioned on its
/// own rather than with the system's string.
pub const VERSION = "0.1";

/// Where a network is reached when nothing says otherwise, and where it is
/// reached in the clear. A bare name is spoken to over TLS: a network that
/// wants to be listened to says so with a port and no plus in front of it.
pub const PORT: u16 = 6697;
pub const PLAIN_PORT: u16 = 6667;

/// How long between passes that have nothing to draw: what the keepalive
/// needs, and nothing finer.
const TICK_US: usize = 5_000_000;

/// What one line of input may hold. A network's own limit is smaller, and the
/// engine holds the line to it.
const INPUT_MAX = 512;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// What a connection is made of, sealed or not. The rest of this file asks
/// the same four things of either.
const Wire = union(enum) {
    plain: sock.Sock,
    secure: *ulib.tls.Stream,

    fn send(self: Wire, bytes: []const u8) usize {
        return switch (self) {
            .plain => |socket| socket.send(bytes),
            .secure => |stream| if (stream.send(bytes)) bytes.len else 0,
        };
    }

    fn recv(self: Wire, into: []u8) usize {
        return switch (self) {
            .plain => |socket| socket.recv(into),
            .secure => |stream| stream.recv(into),
        };
    }

    fn waitHandle(self: Wire) u32 {
        return switch (self) {
            .plain => |socket| socket.waitHandle(),
            .secure => |stream| stream.waitHandle(),
        };
    }

    fn finished(self: Wire) bool {
        return switch (self) {
            .plain => |socket| socket.state() == .closed,
            .secure => |stream| stream.socket.state() == .closed,
        };
    }

    fn close(self: Wire) void {
        switch (self) {
            .plain => |socket| socket.close(),
            .secure => |stream| stream.close(ulib.heap.allocator),
        }
    }
};

/// One network's connection: the wire, what has arrived on it, and where the
/// protocol has got to.
const Link = struct {
    used: bool = false,
    /// Which network in the model this speaks for.
    network: u8 = 0,
    socket: ?Wire = null,
    session: irc.Session = .{},
    stream: irc.Stream = .{},
    /// Storage for what the session was configured with, since it holds
    /// slices rather than copies.
    nick: [rooms.NAME_MAX]u8 = @splat(0),
    user: [rooms.NAME_MAX]u8 = @splat(0),
    real: [rooms.NAME_MAX]u8 = @splat(0),
};

/// Left undefined and set at start rather than given an initialiser, so a
/// third of a megabyte of empty transcript is zeroed by the loader instead of
/// being carried in the binary.
var model: rooms.Model = undefined;
var links: [rooms.NETWORK_MAX]Link = undefined;

/// The handles the wait sleeps on, one per open socket.
var wakes: [rooms.NETWORK_MAX]u32 = @splat(0);
var waking: usize = 0;

var input: eui.text.Field(INPUT_MAX) = .{};
var transcript_scroll: eui.scrollpane.State = .{};
var members_scroll: eui.scrollpane.State = .{};
/// Following the end of the conversation, which stops when you scroll up and
/// starts again when you scroll back down.
var following = true;

/// What the window says along the bottom when something needs saying.
var notice: Bounded(u8, 128) = .{};

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    model.init();
    for (&links) |*link| forget(link);
    // Before the first pass: a field whose buffer points at nothing takes no
    // letters and says nothing about why.
    input.init(.{ .hint = "Say something, or /server to connect" });

    if (env.argument(frame)) |wanted| {
        if (std.mem.eql(u8, wanted, "--version")) {
            out.text("echat " ++ VERSION ++ "\n");
            out.flush();
            sys.exit(0);
        }
        // Reaching a network, said on the console rather than drawn: what a
        // shell can ask when something is wrong with the connection itself
        // and a window would be the wrong place to find out.
        // Reaching a network, checked from a shell: the one question about a
        // connection a window is the wrong place to answer.
        if (std.mem.eql(u8, wanted, "--reach")) {
            model.init();
            reachFromShell(env.arg(frame, 2) orelse "");
        }
        // A network on the command line is one to open at once, which is what
        // opening a link to it from somewhere else does.
        opening = wanted;
    }

    proto.app.run("echat", "IRC", 800, 480, .{
        .draw = draw,
        .key = key,
        .text = typed,
        .tick = tick,
        .tick_us = TICK_US,
        .woken = woken,
    });
}

/// A network named on the command line, connected once the window is up.
var opening: ?[]const u8 = null;

/// Reach a network and say how it went, on the console rather than in a
/// window. What a shell asks when a connection is the thing in question:
/// whether the name resolves, whether the authorities read, and whether the
/// server's certificate is one this machine accepts.
fn reachFromShell(where: []const u8) noreturn {
    const colon = std.mem.lastIndexOfScalar(u8, where, ':');
    const host = if (colon) |at| where[0..at] else where;
    const port: u16 = if (colon) |at| @intCast(lib.str.toUnsigned(where[at + 1 ..])) else PORT;
    if (host.len == 0) return leave("echat: name a network to reach", 1);

    const address = sock.addressOf(host) catch return leave("could not find that name", 1);

    const when = now();
    if (when <= 0) return leave("the clock is not set, so a certificate cannot be checked", 1);

    var trusted = ulib.tls.Roots.open(ulib.heap.allocator, when) catch
        return leave("the certificate authorities could not be read", 1);

    const stream = ulib.tls.Stream.connect(
        ulib.heap.allocator,
        &trusted,
        address,
        port,
        host,
        when,
    ) catch |err| {
        out.text(switch (err) {
            error.NoClock => "the clock is not set",
            error.Unreachable => "could not reach it",
            error.Refused => "the handshake failed: ",
            error.NoAuthorities => "the authorities could not be read",
            error.NoRandomness => "the machine has no randomness to seal with",
            error.OutOfMemory => "not enough memory",
        });
        if (err == error.Refused) out.text(ulib.tls.last_failure);
        return leave("", 1);
    };
    stream.close(ulib.heap.allocator);
    return leave("sealed", 0);
}

fn leave(what: []const u8, code: u8) noreturn {
    out.text(what);
    out.text("\n");
    out.flush();
    sys.exit(code);
}

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

/// Open a network. `where` is a host, optionally with `:port`, and a plus in
/// front of the port means the port is spoken to over TLS. A bare name is
/// sealed; a bare port is not, which is the convention every client follows.
fn connect(where: []const u8) void {
    const colon = std.mem.lastIndexOfScalar(u8, where, ':');
    const host = if (colon) |at| where[0..at] else where;
    var sealed = true;
    var port = PORT;
    if (colon) |at| {
        const given = where[at + 1 ..];
        sealed = given.len != 0 and given[0] == '+';
        port = @intCast(lib.str.toUnsigned(if (sealed) given[1..] else given));
        if (port == 0) port = if (sealed) PORT else PLAIN_PORT;
    }
    if (host.len == 0) return say("that is not a network to connect to");

    const slot = freeLink() orelse return say("no room for another network");

    const address = sock.addressOf(host) catch {
        say("could not find that network");
        return;
    };
    const opened = open(address, port, host, sealed) orelse return;
    const network = model.addNetwork(host) orelse {
        opened.close();
        return say("no room for another network");
    };

    const link = &links[slot];
    forget(link);
    link.used = true;
    link.network = network;
    link.socket = opened;
    setIdentity(link);
    link.session.begin();
    listen();
    flush(link);
    // The server answers at once, and the first read here means the greeting
    // is on screen without waiting for a wake.
    _ = pump(link);

    model.show(model.networks.items[network].tab);
    tell(model.networks.items[network].tab, "connecting");
}

/// Reach a network, sealed or in the clear. The reason a connection failed
/// is said here, because this is where it is known.
fn open(address: u32, port: u16, host: []const u8, sealed: bool) ?Wire {
    if (!sealed) {
        const socket = sock.Sock.connect(address, port) catch {
            say("could not reach that network");
            return null;
        };
        return .{ .plain = socket };
    }

    const when = now();
    const trusted = authorities(when) orelse return null;
    const stream = ulib.tls.Stream.connect(
        ulib.heap.allocator,
        trusted,
        address,
        port,
        host,
        when,
    ) catch |err| {
        say(switch (err) {
            error.NoClock => "the clock is not set, so a certificate cannot be checked",
            error.Unreachable => "could not reach that network",
            error.Refused => "the network's certificate was not accepted",
            error.NoAuthorities => "the certificate authorities could not be read",
            error.NoRandomness => "the machine has no randomness to seal with",
            error.OutOfMemory => "not enough memory for a sealed connection",
        });
        return null;
    };
    return .{ .secure = stream };
}

/// The authorities, read the first time one is wanted and kept after that.
var roots: ?ulib.tls.Roots = null;

fn authorities(when: i64) ?*ulib.tls.Roots {
    if (roots == null) {
        roots = ulib.tls.Roots.open(ulib.heap.allocator, when) catch {
            say("the certificate authorities could not be read");
            return null;
        };
    }
    return &roots.?;
}

/// What this client calls itself. The nick is the machine's own name until
/// there is somewhere to keep a preference: it is already a name this
/// machine answers to, and `/nick` changes it.
fn setIdentity(link: *Link) void {
    const configured = proto.settings.netMachine(proto.settings.load("net")).hostname;
    var address: [6]u8 = @splat(0);
    if (proto.net.interfaceAt(0)) |iface| address = iface.mac;
    const machine = lib.hostname.Hostname.resolve(configured, address);
    const wanted = if (machine.isEmpty()) "vibeee" else machine.slice();

    copyInto(&link.nick, wanted);
    copyInto(&link.user, wanted);
    copyInto(&link.real, wanted);
    link.session.wants(spanOf(&link.nick));
    link.session.user = spanOf(&link.user);
    link.session.real = spanOf(&link.real);
}

fn copyInto(field: []u8, text: []const u8) void {
    @memset(field, 0);
    const take = @min(text.len, field.len - 1);
    @memcpy(field[0..take], text[0..take]);
}

fn spanOf(field: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    return field[0..end];
}

/// Put a link back to nothing, without writing the buffers inside it: a
/// stream is eight kilobytes of room for bytes that have not arrived.
fn forget(link: *Link) void {
    link.used = false;
    link.network = 0;
    link.socket = null;
    link.session = .{};
    link.stream.start = 0;
    link.stream.len = 0;
    link.stream.dropping = false;
    link.stream.dropped = false;
    @memset(&link.nick, 0);
    @memset(&link.user, 0);
    @memset(&link.real, 0);
}

fn freeLink() ?usize {
    for (&links, 0..) |*link, index| {
        if (!link.used) return index;
    }
    return null;
}

fn linkFor(network: u8) ?*Link {
    for (&links) |*link| {
        if (link.used and link.network == network) return link;
    }
    return null;
}

/// Tell the wait what to sleep on: every open socket, so a line arriving
/// wakes the window rather than a timer finding it.
fn listen() void {
    waking = 0;
    for (&links) |*link| {
        const wire = link.socket orelse continue;
        if (!link.used) continue;
        wakes[waking] = wire.waitHandle();
        waking += 1;
    }
    proto.app.wakeOn(wakes[0..waking]);
}

/// A socket had news. Which one is not worth working out: reading a socket
/// with nothing on it costs one call.
fn woken(index: usize) bool {
    _ = index;
    var drawn = false;
    for (&links) |*link| {
        if (link.used and pump(link)) drawn = true;
    }
    return drawn;
}

/// Read what has arrived, hand every whole line to the session, and write
/// back whatever it wants to say. True when something changed on screen.
fn pump(link: *Link) bool {
    const wire = link.socket orelse return false;
    var changed = false;

    while (true) {
        const room = link.stream.room();
        if (room.len == 0) break;
        const read = wire.recv(room);
        if (read == 0) break;
        link.stream.filled(read);

        while (link.stream.next()) |text| {
            const line = irc.parse(text) catch continue;
            changed = true;
            const event = link.session.receive(&line);
            fold(link, &line);
            act(link, event);
        }
    }

    if (link.stream.dropped) {
        link.stream.dropped = false;
        tell(model.networks.items[link.network].tab, "a line too long to read was dropped");
        changed = true;
    }

    // A connection the service has finished with is a network that has gone.
    if (wire.finished() and link.session.state != .closed) {
        link.session.quit("");
        tell(model.networks.items[link.network].tab, "the connection closed");
        drop(link);
        return true;
    }

    flush(link);
    return changed;
}

/// Write what the session has queued, as far as the socket will take it.
fn flush(link: *Link) void {
    const wire = link.socket orelse return;
    while (true) {
        const waiting = link.session.pending();
        if (waiting.len == 0) break;
        const sent = wire.send(waiting);
        if (sent == 0) break;
        link.session.sent(sent);
    }
    if (link.session.stalled) {
        link.session.stalled = false;
        tell(model.networks.items[link.network].tab, "a line was too long to send");
    }
}

/// What the session made of a line.
fn act(link: *Link, event: irc.session.Event) void {
    const tab = model.networks.items[link.network].tab;
    switch (event) {
        .none => {},
        .ready => {
            model.networks.items[link.network].connected = true;
            named(link);
            tell(tab, "connected");
        },
        .renamed => |name| {
            var room: [96]u8 = undefined;
            tell(tab, std.fmt.bufPrint(&room, "you are now {s}", .{name}) catch "renamed");
        },
        .closed => |why| {
            tell(tab, why.spell());
            drop(link);
        },
    }
}

/// Take the network's own name once the server has given it.
fn named(link: *Link) void {
    const network = &model.networks.items[link.network];
    const given = link.session.support.network.slice();
    if (given.len == 0) return;
    network.named.clear();
    for (given) |ch| network.named.append(ch) catch break;
}

fn drop(link: *Link) void {
    if (link.socket) |wire| wire.close();
    link.socket = null;
    link.used = false;
    model.networks.items[link.network].connected = false;
    listen();
}

// ---------------------------------------------------------------------------
// What arrives
// ---------------------------------------------------------------------------

/// Write what a line means into the model. The session has already dealt with
/// what the protocol needed; this is what a person sees.
fn fold(link: *Link, line: *const irc.Line) void {
    const network = link.network;
    const tab = model.networks.items[network].tab;
    const support = &link.session.support;
    const me = link.session.nick.slice();
    const from = line.nick();

    switch (line.command) {
        .verb => |verb| switch (verb) {
            .privmsg, .notice => {
                const target = line.param(0) orelse return;
                const text = line.text();
                // A message to a channel belongs in the channel and one to us
                // in a conversation with whoever sent it. What the server
                // itself says belongs to the network: a notice from a server
                // is not somebody to talk back to.
                const sender = line.source orelse irc.Source{};
                const where = if (support.isChannel(target))
                    model.addRoom(network, .channel, target) orelse return
                else if (sender.isUser())
                    model.addRoom(network, .query, from) orelse return
                else
                    tab;

                // An action is a message wrapped in the client-to-client
                // convention, and it reads as the person doing something.
                if (action(text)) |did| {
                    model.say(where, .{
                        .kind = .acted,
                        .room = where,
                        .at = now(),
                        .mine = support.same(from, me),
                        .highlight = names(did, me),
                    }, from, did);
                    return;
                }
                model.say(where, .{
                    .kind = if (verb == .notice) .noticed else .said,
                    .room = where,
                    .at = now(),
                    .mine = support.same(from, me),
                    .highlight = names(text, me),
                }, from, text);
            },
            .join => {
                const target = line.param(0) orelse line.text();
                const where = model.addRoom(network, .channel, target) orelse return;
                if (support.same(from, me)) {
                    model.rooms.items[where].joined = true;
                    model.show(where);
                } else {
                    model.arrive(where, from, "");
                }
                told(where, from, "joined");
            },
            .part => {
                const target = line.param(0) orelse return;
                const where = model.findRoom(network, target) orelse return;
                if (support.same(from, me)) {
                    model.rooms.items[where].joined = false;
                    model.empty(where);
                } else {
                    model.depart(where, from);
                }
                told(where, from, "left");
            },
            .quit => {
                // Everywhere they were.
                for (model.rooms.slice(), 0..) |*room, index| {
                    if (room.network != network) continue;
                    const which: u8 = @intCast(index);
                    if (model.member(which, support.casemapping, from) == null) continue;
                    model.depart(which, from);
                    told(which, from, "left");
                }
            },
            .nick => {
                const wanted = line.text();
                for (model.rooms.slice(), 0..) |*room, index| {
                    if (room.network != network) continue;
                    const which: u8 = @intCast(index);
                    const member = model.member(which, support.casemapping, from) orelse continue;
                    member.nick.clear();
                    for (wanted) |ch| member.nick.append(ch) catch break;
                    told(which, from, "is now known");
                }
            },
            .topic => {
                const target = line.param(0) orelse return;
                const where = model.findRoom(network, target) orelse return;
                setTopic(where, line.text());
                told(where, from, "set the topic");
            },
            .kick => {
                const target = line.param(0) orelse return;
                const who = line.param(1) orelse return;
                const where = model.findRoom(network, target) orelse return;
                model.depart(where, who);
                told(where, who, "was removed");
            },
            .@"error" => tell(tab, line.text()),
            else => {},
        },
        .reply => |reply| switch (reply) {
            .topic => {
                const target = line.param(1) orelse return;
                const where = model.findRoom(network, target) orelse return;
                setTopic(where, line.text());
            },
            .name_reply => {
                // `353 <me> <symbol> <channel> :names`
                const target = line.param(2) orelse return;
                const where = model.addRoom(network, .channel, target) orelse return;
                var each = lib.str.words(line.text());
                while (each.next()) |name| {
                    const split = support.prefixes.split(name);
                    model.arrive(where, split.nick, split.marks);
                }
            },
            .no_topic => {},
            // Everything else the server says belongs to the network, said
            // as it was said: a client that hides what it does not know is a
            // client you cannot see what happened with.
            else => {
                if (reply.number() >= 1 and reply.number() <= 5) return;
                tell(tab, line.text());
            },
        },
    }
}

/// The text of a client-to-client action, or null for an ordinary message.
fn action(text: []const u8) ?[]const u8 {
    const mark = 0x01;
    if (text.len < 9 or text[0] != mark) return null;
    if (!std.mem.startsWith(u8, text[1..], "ACTION ")) return null;
    const body = text[8..];
    return if (body.len != 0 and body[body.len - 1] == mark) body[0 .. body.len - 1] else body;
}

/// Whether a message names this client, which is what makes it worth
/// interrupting somebody for.
fn names(text: []const u8, me: []const u8) bool {
    if (me.len == 0) return false;
    return lib.str.containsFold(text, me);
}

fn setTopic(room: u8, text: []const u8) void {
    const at = &model.rooms.items[room];
    at.topic.clear();
    for (text) |ch| at.topic.append(ch) catch break;
}

/// Something the server said, in the room it is about.
fn tell(room: u8, text: []const u8) void {
    model.say(room, .{ .kind = .told, .room = room, .at = now() }, "", text);
}

/// Something somebody did, which is the server's news rather than theirs.
fn told(room: u8, who: []const u8, what: []const u8) void {
    var room_text: [rooms.NAME_MAX + 32]u8 = undefined;
    tell(room, std.fmt.bufPrint(&room_text, "{s} {s}", .{ who, what }) catch what);
}

/// Something the window itself has to say, on the strip along the bottom.
fn say(text: []const u8) void {
    notice.clear();
    for (text) |ch| notice.append(ch) catch break;
}

fn now() i64 {
    const micros = sys.realtimeMicros() orelse return 0;
    return @divFloor(micros, 1_000_000);
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

/// Rail rows, rebuilt each pass: labels point into the model, which is where
/// they live.
var rail_items: [rooms.ROOM_MAX + rooms.NETWORK_MAX]eui.rail.Item = undefined;

/// The lines of the room in view, newest last.
var shown: [512]usize = undefined;

fn draw() void {
    const t = theme.current();
    const area = Rect{ .x = 0, .y = 0, .w = ctx.surface.width, .h = ctx.surface.height };
    if (ctx.damaged) ctx.surface.fill(area, t.surface);

    // A network named on the command line is opened once there is a window to
    // show it in, so a failure has somewhere to be said.
    if (opening) |where| {
        opening = null;
        connect(where);
    }

    const room = model.current();
    const with_members = room != null and room.?.sort == .channel;
    const panes = layout.place(area, with_members, notice.len != 0);

    drawRail(panes.rail);
    drawHeader(panes.header, room);
    drawTranscript(panes.transcript);
    if (panes.members.w != 0) drawMembers(panes.members, room.?);
    if (panes.notice.h != 0) drawNotice(panes.notice);
    drawInput(panes.input);
}

fn drawRail(area: Rect) void {
    const items = layout.railItems(&model, &rail_items);
    const chosen = layout.rowOf(&model, model.open);
    const picked = ctx.rail(area, items, chosen, nickOf());
    if (picked != chosen) {
        if (layout.roomAt(&model, picked)) |which| {
            model.show(which);
            following = true;
            ctx.damage();
        }
    }
}

/// What this client is called on the network in view, for the foot of the
/// rail. Empty before there is a connection.
fn nickOf() []const u8 {
    const room = model.current() orelse return "";
    const link = linkFor(room.network) orelse return "";
    return link.session.nick.slice();
}

fn drawHeader(area: Rect, room: ?*rooms.Room) void {
    const t = theme.current();
    const at = room orelse {
        if (ctx.damaged) ctx.surface.fill(area, t.surface);
        return;
    };

    // The name, then what the room is about in the space left over.
    const name = at.called();
    const left = area.x + t.padding;
    const width = Surface.textWidth(name);
    const line: Rect = .{
        .x = left,
        .y = area.y + @divTrunc(area.h - Surface.textHeight(), 2),
        .w = area.w - t.padding * 2,
        .h = Surface.textHeight(),
    };

    const signature = headerFingerprint(at);
    if (ctx.damaged or header_shown != signature) {
        header_shown = signature;
        ctx.surface.fill(area, t.surface);
        ctx.surface.fill(.{ .x = area.x, .y = area.bottom() - 1, .w = area.w, .h = 1 }, t.line);
        const clipped = ctx.surface.clipped(area);
        clipped.text(line.x, line.y, name, t.text);
        const topic = at.topic.slice();
        if (topic.len != 0) {
            const from = line.x + width + t.gap;
            clipped.textFitted(from, line.y, line.right() - from, topic, t.text_dim);
        }
        ctx.addDamage(area);
    }
}

var header_shown: u32 = 0;

fn headerFingerprint(room: *const rooms.Room) u32 {
    var value: u32 = 2166136261;
    for (room.called()) |ch| value = (value ^ ch) *% 16777619;
    for (room.topic.slice()) |ch| value = (value ^ ch) *% 16777619;
    return value;
}

/// What the transcript is showing. A pane that has not changed is left alone.
var transcript_shown: u64 = 0;

fn transcriptFingerprint(area: Rect) u64 {
    var value: u64 = 1469598103934665603;
    for ([_]u64{
        model.open,
        model.lines.len,
        @intCast(transcript_scroll.offset + 1),
        @intCast(area.w),
        @intCast(area.h),
        @intFromBool(following),
    }) |part| {
        value = (value ^ part) *% 1099511628211;
    }
    return value;
}

/// A run of lines from one person, drawn with their name once.
const Group = struct {
    /// Where in `shown` the run starts, and how many lines it holds.
    from: usize,
    count: usize,
    named: bool,
    highlight: bool,
};

/// How far apart two lines from the same person may be and still read as one
/// run rather than two.
const RUN_SECONDS: i64 = 300;

fn drawTranscript(area: Rect) void {
    const t = theme.current();

    // The ground goes down again whenever what stands on it has changed:
    // lines arrive, the room changes, the pane scrolls. Drawing the new text
    // over the old without this leaves both.
    const signature = transcriptFingerprint(area);
    const fresh = ctx.damaged or signature != transcript_shown;
    transcript_shown = signature;
    if (fresh) {
        ctx.surface.fill(area, t.surface_hot);
        ctx.addDamage(area);
    }

    // Nothing open at all: say how to start, rather than showing an empty
    // pane that gives no hint there is anything to do.
    if (model.current() == null) {
        // On the pane's own ground rather than a label's, which paints the
        // window's and would leave a band across the top.
        if (ctx.damaged) {
            ctx.surface.clipped(area).text(
                area.x + t.padding,
                area.y + t.padding,
                "Type /server irc.libera.chat to connect.",
                t.text_dim,
            );
        }
        return;
    }
    const which = model.open;
    transcript_height = area.h;

    const lines = model.transcript(which, &shown);
    var view = eui.scrollpane.begin(ctx, area, &transcript_scroll);

    // Pinned to the end until somebody scrolls away from it, which is what a
    // conversation wants: the newest line is the one being read.
    if (following) transcript_scroll.offset = @max(0, transcript_scroll.content_h - area.h);
    view.offset = transcript_scroll.offset;

    const width = view.area.w - t.padding * 2;
    var y = view.top();
    var at: usize = 0;
    while (at < lines.len) {
        const group = groupAt(lines, at);
        y += drawGroup(view, .{ .x = view.area.x, .y = y, .w = view.area.w, .h = 0 }, lines, group, width, fresh);
        at = group.from + group.count;
    }

    const content = y - view.top();
    eui.scrollpane.end(ctx, &transcript_scroll, view, content);

    // Scrolling away from the end stops the following; scrolling back to it
    // starts again, so it is never a mode to get stuck in.
    if (transcript_scroll.content_h > area.h) {
        following = transcript_scroll.offset >= transcript_scroll.content_h - area.h - 1;
    }
}

/// The run of lines starting at `at`.
fn groupAt(lines: []const usize, at: usize) Group {
    const first = model.lines.items[lines[at]];
    var count: usize = 1;
    while (at + count < lines.len) : (count += 1) {
        const next = model.lines.items[lines[at + count]];
        if (next.kind != first.kind) break;
        if (first.kind == .told) continue;
        if (!std.mem.eql(u8, model.textOf(next.nick), model.textOf(first.nick))) break;
        if (next.at != 0 and first.at != 0 and next.at - first.at > RUN_SECONDS) break;
    }

    var highlight = false;
    for (lines[at .. at + count]) |index| {
        if (model.lines.items[index].highlight) highlight = true;
    }
    return .{ .from = at, .count = count, .named = first.kind != .told, .highlight = highlight };
}

/// Draw one run and return how tall it turned out. A pass that is only
/// measuring still walks it: the pane's height and its bar come from what the
/// last pass drew, and a pass that skipped the walk would leave both stale.
fn drawGroup(
    view: eui.scrollpane.View,
    at: Rect,
    lines: []const usize,
    group: Group,
    width: i32,
    paint: bool,
) i32 {
    const t = theme.current();
    const first = model.lines.items[lines[group.from]];
    const gap = if (group.named) t.padding else theme.enlarged(2);
    const row = Surface.textHeight();

    var height = gap;
    if (group.named) height += row;
    for (lines[group.from..][0..group.count]) |index| {
        const line = model.lines.items[index];
        height += @as(i32, @intCast(eui.text.count(bodyOf(line), drawFace(line), width))) * row;
    }

    if (!paint or !view.shows(at.y, height)) return height;

    // A run that names this client takes the ground a chosen row takes, so it
    // is findable by looking rather than by reading.
    if (group.highlight) {
        ctx.surface.fill(.{ .x = at.x, .y = at.y, .w = at.w, .h = height }, t.surface_pressed);
    }

    var y = at.y + gap;
    if (group.named) {
        const nick = model.textOf(first.nick);
        const ink = if (first.mine) t.accent else t.text;
        ctx.surface.text(at.x + t.padding, y, nick, ink);
        if (first.at != 0) {
            var clock: [8]u8 = undefined;
            const stamp = spellTime(first.at, &clock);
            ctx.surface.text(at.x + t.padding + Surface.textWidth(nick) + t.gap, y, stamp, t.text_dim);
        }
        y += row;
    }

    for (lines[group.from..][0..group.count]) |index| {
        const line = model.lines.items[index];
        const ink: eui.draw.Color = switch (line.kind) {
            .told => t.text_dim,
            .noticed => t.text_dim,
            .acted => t.accent,
            .said => t.text,
        };
        // Taken once: what a line reads as is written into one buffer, and
        // asking again while a wrapped slice of it is in hand would be
        // writing under that slice.
        const body = bodyOf(line);
        var wrapped = eui.text.lines(body, drawFace(line), width);
        while (wrapped.next()) |piece| {
            ctx.surface.textIn(drawFace(line), at.x + t.padding, y, body[piece.start..piece.end], ink);
            y += row;
        }
    }
    return height;
}

/// What a line reads as. The server's own news is set apart by a dash rather
/// than by a name, which is how it has always been shown.
fn bodyOf(line: rooms.Line) []const u8 {
    if (line.kind != .told) return model.textOf(line.text);
    told_text[0] = '-';
    told_text[1] = ' ';
    const text = model.textOf(line.text);
    const take = @min(text.len, told_text.len - 2);
    @memcpy(told_text[2..][0..take], text[0..take]);
    return told_text[0 .. take + 2];
}

var told_text: [512]u8 = undefined;

/// What was said is set in the monospaced face; what the client says about it
/// is set in the interface face, so the two are told apart at a glance.
fn drawFace(line: rooms.Line) *const eui.draw.Font {
    return if (line.kind == .said or line.kind == .acted) eui.draw.mono_font else eui.draw.ui_font;
}

fn spellTime(at: i64, room: *[8]u8) []const u8 {
    const when = civil.fromEpoch(at);
    return std.fmt.bufPrint(room, "{d:0>2}:{d:0>2}", .{ when.hour, when.minute }) catch "";
}

var members_shown: [256]usize = undefined;

fn drawMembers(area: Rect, room: *rooms.Room) void {
    const t = theme.current();
    const link = linkFor(room.network);
    const prefixes = if (link) |it| &it.session.support.prefixes else &irc.support.Prefixes.DEFAULT;

    if (ctx.damaged) {
        ctx.surface.fill(area, t.surface);
        ctx.surface.fill(.{ .x = area.x - 1, .y = area.y, .w = 1, .h = area.h }, t.line);
    }

    var counted: [64]u8 = undefined;
    const heading = std.fmt.bufPrint(&counted, "{d} ops, {d} here", .{
        model.opsIn(model.open, prefixes),
        model.countIn(model.open),
    }) catch "";
    ctx.labelIn(
        .{ .x = area.x + t.padding, .y = area.y, .w = area.w - t.padding, .h = layout.headerHeight() },
        heading,
        t.text_dim,
    );

    const here = model.membersOf(model.open, members_shown[0..@min(members_shown.len, layout.membersShown(area))]);
    for (here, 0..) |which, index| {
        const member = model.members.items[which];
        const at = layout.memberRow(area, index);
        const mark = member.marks.slice();
        const ink = if (member.away) t.text_dim else t.text;
        const marked = Surface.textWidth("@");
        ctx.labelIn(.{ .x = at.x + t.padding, .y = at.y, .w = marked, .h = at.h }, mark, t.text_dim);
        ctx.labelIn(.{
            .x = at.x + t.padding + marked + theme.enlarged(2),
            .y = at.y,
            .w = at.w - t.padding * 2 - marked,
            .h = at.h,
        }, member.nick.slice(), ink);
    }
}

/// What the window itself has to say: a connection that failed, a command it
/// could not carry out. On its own strip rather than in the transcript,
/// because it is this program speaking rather than the network, and because
/// it has to be sayable before there is a room to say it in.
fn drawNotice(area: Rect) void {
    const t = theme.current();
    const said = notice.slice();
    const signature = fingerprintOf(said);
    if (!ctx.damaged and signature == notice_shown) return;
    notice_shown = signature;

    ctx.surface.fill(area, t.surface_pressed);
    ctx.surface.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, t.line);
    ctx.surface.clipped(area).textFitted(
        area.x + t.padding,
        area.y + @divTrunc(area.h - Surface.textHeight(), 2),
        area.w - t.padding * 2,
        said,
        t.warning,
    );
    ctx.addDamage(area);
}

var notice_shown: u32 = 0;

fn fingerprintOf(text: []const u8) u32 {
    var value: u32 = 2166136261;
    for (text) |ch| value = (value ^ ch) *% 16777619;
    return value;
}

fn drawInput(area: Rect) void {
    const t = theme.current();
    if (ctx.damaged) {
        ctx.surface.fill(area, t.surface);
        ctx.surface.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, t.line);
    }

    const field: Rect = .{
        .x = area.x + t.padding,
        .y = area.y + @divTrunc(area.h - t.control_height, 2),
        .w = area.w - t.padding * 2,
        .h = t.control_height,
    };
    // The keyboard belongs here: a chat client is a window you type into,
    // and every other control is reached with Tab or the pointer.
    ctx.focusNext();
    if (input.run(ctx, field)) submit();
}

// ---------------------------------------------------------------------------
// Typing
// ---------------------------------------------------------------------------

fn typed(codepoint: u32) bool {
    _ = codepoint;
    return false;
}

fn key(code: proto.app.KeyCode, mods: proto.app.Modifiers) bool {
    switch (code) {
        // Through the rooms, in the order the rail shows them.
        .page_up, .page_down => if (mods.control) {
            step(if (code == .page_down) 1 else -1);
            return true;
        } else {
            const pane = @max(transcript_height - Surface.textHeight(), Surface.textHeight());
            scrollBy(if (code == .page_up) -pane else pane);
            return true;
        },
        .home, .end => if (mods.control) {
            scrollBy(if (code == .home) -transcript_scroll.content_h else transcript_scroll.content_h);
            return true;
        },
        // The whole of what an IRC client's Tab is for: the name in front of
        // you, finished. Taken before the toolkit sees it, which would
        // otherwise move the keyboard off the line you are typing on.
        .tab => {
            if (complete()) return true;
            return false;
        },
        else => {},
    }
    return false;
}

/// How tall the transcript was drawn, for a page of scrolling.
var transcript_height: i32 = 0;

fn scrollBy(delta: i32) void {
    const limit = @max(transcript_scroll.content_h - transcript_height, 0);
    transcript_scroll.offset = @max(0, @min(transcript_scroll.offset + delta, limit));
    following = transcript_scroll.offset >= limit;
    ctx.damage();
}

/// Move `by` rooms along the rail, wrapping at either end.
fn step(by: i32) void {
    const rows = layout.rowCount(&model);
    if (rows == 0) return;
    const at = @as(i32, @intCast(layout.rowOf(&model, model.open)));
    const count = @as(i32, @intCast(rows));
    const wanted = @mod(at + by + count, count);
    if (layout.roomAt(&model, @intCast(wanted))) |which| {
        model.show(which);
        following = true;
        ctx.damage();
    }
}

/// Finish the name being typed, from who is in the room. True when there was
/// one to finish.
fn complete() bool {
    const room = model.current() orelse return false;
    const typed_text = input.slice();
    const from = lastWordStart(typed_text);
    const partial = typed_text[from..];
    if (partial.len == 0) return false;

    const mapping = model.mappingOf(room.network);
    var here: [rooms.MEMBER_MAX]usize = undefined;
    for (model.membersOf(model.open, &here)) |which| {
        const nick = model.members.items[which].nick.slice();
        if (nick.len <= partial.len) continue;
        if (!startsWithFold(mapping, nick, partial)) continue;

        var line: [rooms.NICK_MAX + 4]u8 = undefined;
        // A name at the start of a line is addressed to somebody, and the
        // colon is what every network's clients read as addressing.
        const ending: []const u8 = if (from == 0) ": " else " ";
        const finished = std.fmt.bufPrint(&line, "{s}{s}", .{ nick, ending }) catch return false;

        var whole: [INPUT_MAX]u8 = undefined;
        const said = std.fmt.bufPrint(&whole, "{s}{s}", .{ typed_text[0..from], finished }) catch return false;
        input.set(said);
        ctx.damage();
        return true;
    }
    return false;
}

/// Where the word being typed starts.
fn lastWordStart(text: []const u8) usize {
    var at = text.len;
    while (at != 0 and text[at - 1] != ' ') at -= 1;
    return at;
}

fn startsWithFold(mapping: irc.support.Casemapping, whole: []const u8, start: []const u8) bool {
    if (whole.len < start.len) return false;
    return mapping.eql(whole[0..start.len], start);
}

fn tick() bool {
    var drawn = false;
    const millis: u64 = @intCast(@divFloor(sys.clockMicros(), 1000));
    for (&links) |*link| {
        if (!link.used) continue;
        // Read as well as keep alive. The socket's own event is what usually
        // brings a line in; this is what catches one that arrived while the
        // window was busy, so a connection cannot sit unread.
        if (pump(link)) drawn = true;
        if (!link.used) continue;
        const event = link.session.tick(millis);
        act(link, event);
        flush(link);
        if (event != .none) drawn = true;
    }
    return drawn;
}

/// What was typed: a command if it starts with a slash, otherwise something
/// said in the room in view.
fn submit() void {
    const text = input.slice();
    if (text.len == 0) return;

    // What was said about the last thing tried stands until the next thing
    // is tried. Clearing it on any key would take it away under the fingers
    // of somebody typing the very command it was about.
    if (notice.len != 0) {
        notice.clear();
        ctx.damage();
    }
    if (text[0] == '/') command(text[1..]) else speak(text);
    input.clear();
    ctx.damage();
}

fn speak(text: []const u8) void {
    const room = model.current() orelse return;
    if (room.sort == .server) return say("that is the network's own tab; join a channel to talk");
    const link = linkFor(room.network) orelse return say("not connected");

    var line: irc.Line = .{ .command = .{ .verb = .privmsg }, .trail = true };
    line.params.append(room.called()) catch return;
    line.params.append(text) catch return;
    link.session.send(line);
    flush(link);

    // Without `echo-message` the server does not send our own words back, so
    // they are written here. With it, they arrive like anyone else's.
    if (!link.session.has(.echo_message)) {
        model.say(model.open, .{
            .kind = .said,
            .room = model.open,
            .at = now(),
            .mine = true,
        }, link.session.nick.slice(), text);
    }
    following = true;
}

fn command(text: []const u8) void {
    var words = lib.str.words(text);
    const word = words.next() orelse return;
    const rest = lib.str.trim(text[@min(word.len + 1, text.len)..]);

    if (lib.str.eqlFold(word, "server") or lib.str.eqlFold(word, "connect")) {
        return connect(rest);
    }
    const room = model.current() orelse return say("nothing to do that in");
    const link = linkFor(room.network) orelse return say("not connected");

    if (lib.str.eqlFold(word, "join")) {
        return sendWords(link, .{ .verb = .join }, rest, false);
    }
    if (lib.str.eqlFold(word, "part")) {
        const target = if (rest.len != 0) rest else room.called();
        return sendWords(link, .{ .verb = .part }, target, false);
    }
    if (lib.str.eqlFold(word, "nick")) {
        return sendWords(link, .{ .verb = .nick }, rest, false);
    }
    if (lib.str.eqlFold(word, "topic")) {
        var line: irc.Line = .{ .command = .{ .verb = .topic }, .trail = true };
        line.params.append(room.called()) catch return;
        if (rest.len != 0) line.params.append(rest) catch return;
        link.session.send(line);
        return flush(link);
    }
    if (lib.str.eqlFold(word, "me")) {
        var wrapped: [INPUT_MAX + 16]u8 = undefined;
        const body = std.fmt.bufPrint(&wrapped, "\x01ACTION {s}\x01", .{rest}) catch return;
        var line: irc.Line = .{ .command = .{ .verb = .privmsg }, .trail = true };
        line.params.append(room.called()) catch return;
        line.params.append(body) catch return;
        link.session.send(line);
        model.say(model.open, .{
            .kind = .acted,
            .room = model.open,
            .at = now(),
            .mine = true,
        }, link.session.nick.slice(), rest);
        return flush(link);
    }
    if (lib.str.eqlFold(word, "msg")) {
        var to = lib.str.words(rest);
        const who = to.next() orelse return say("who to");
        const body = lib.str.trim(rest[@min(who.len + 1, rest.len)..]);
        var line: irc.Line = .{ .command = .{ .verb = .privmsg }, .trail = true };
        line.params.append(who) catch return;
        line.params.append(body) catch return;
        link.session.send(line);
        const where = model.addRoom(room.network, .query, who) orelse return flush(link);
        model.say(where, .{
            .kind = .said,
            .room = where,
            .at = now(),
            .mine = true,
        }, link.session.nick.slice(), body);
        return flush(link);
    }
    if (lib.str.eqlFold(word, "quit")) {
        link.session.quit(if (rest.len != 0) rest else "echat");
        flush(link);
        return drop(link);
    }

    // Anything else goes as it was typed, so a network's own commands work
    // without this client having to know each one.
    var line: irc.Line = .{ .command = irc.Command.from(word), .word = word, .trail = true };
    if (rest.len != 0) line.params.append(rest) catch return;
    link.session.send(line);
    flush(link);
}

fn sendWords(link: *Link, command_of: irc.Command, argument: []const u8, trail: bool) void {
    if (argument.len == 0) return say("that needs something to act on");
    var line: irc.Line = .{ .command = command_of, .trail = trail };
    line.params.append(argument) catch return;
    link.session.send(line);
    flush(link);
}
