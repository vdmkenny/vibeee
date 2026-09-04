//! What echat holds: networks, the places on them, who is there, and what was
//! said.
//!
//! Pure state with no drawing and no sockets in it, so the whole model is
//! tested on the host. The window reads it and the connection writes it.
//!
//! One transcript serves every room. Messages arrive interleaved across all
//! of them and no room's share is known in advance, so a single arena with
//! the oldest entries dropped when it fills gives every room as much as it
//! is using, instead of a per-room budget that is always wrong somewhere.

const std = @import("std");
const lib = @import("lib");

const support = @import("irc/support.zig");

const Bounded = lib.bounded.Bounded;

/// Networks connected at once.
pub const NETWORK_MAX = 4;

/// Rooms across all networks: server tabs, channels and conversations.
pub const ROOM_MAX = 32;

/// Names, as long as any network allows.
pub const NAME_MAX = 64;
pub const TOPIC_MAX = 390;

/// People tracked across every room at once. One pool rather than a share
/// per room: most rooms hold a handful and one holds hundreds, and a
/// per-room budget is always wrong somewhere.
pub const MEMBER_MAX = 1024;

/// A nick, which every network holds well under this.
pub const NICK_MAX = 32;

/// Lines kept, and the text they share.
pub const LINE_MAX = 2048;
pub const TEXT_MAX = 128 * 1024;

/// What a line is, which decides how it is drawn and whether it counts as
/// something waiting.
pub const Kind = enum {
    /// Someone said something.
    said,
    /// Someone did something, from a CTCP ACTION.
    acted,
    /// A notice, which by convention is not answered.
    noticed,
    /// The client or the server, not a person: joins, parts, modes, errors.
    told,

    /// Whether a line of this kind makes a room worth looking at.
    pub fn counts(self: Kind) bool {
        return self != .told;
    }
};

/// What a room is.
pub const Sort = enum {
    /// A network's own tab: what the server says outside any channel.
    server,
    channel,
    /// One person, in private.
    query,
};

/// One line of transcript.
pub const Line = struct {
    room: u8,
    kind: Kind,
    /// Who said it, or empty for `.told`.
    nick: Span = .{},
    text: Span = .{},
    /// Seconds since the epoch, or zero where the clock is not set.
    at: i64 = 0,
    /// This client said it.
    mine: bool = false,
    /// It names this client.
    highlight: bool = false,
};

/// Where a piece of text sits in the arena.
pub const Span = struct {
    at: u32 = 0,
    len: u32 = 0,

    pub fn of(self: Span, arena: []const u8) []const u8 {
        return arena[self.at..][0..self.len];
    }
};

/// Someone in a room.
pub const Member = struct {
    /// Which room they are in.
    room: u8 = 0,
    nick: Bounded(u8, NICK_MAX) = .{},
    /// The membership prefixes the network gave, highest first.
    marks: Bounded(u8, 8) = .{},
    away: bool = false,

    /// How highly this member ranks, from the first of its marks. Lower is
    /// higher standing, and someone with no mark ranks below everyone.
    pub fn rank(self: *const Member, prefixes: *const support.Prefixes) u8 {
        const mark = self.marks.at(0) orelse return 255;
        return prefixes.rank(mark) orelse 255;
    }

    pub fn isOp(self: *const Member, prefixes: *const support.Prefixes) bool {
        const mark = self.marks.at(0) orelse return false;
        const at = prefixes.rank(mark) orelse return false;
        // Op is the mode `o`, wherever the network ranks it.
        return prefixes.markFor('o') == prefixes.marks.at(at);
    }
};

/// A place messages go.
pub const Room = struct {
    sort: Sort,
    /// Which network it belongs to.
    network: u8,
    name: Bounded(u8, NAME_MAX) = .{},
    topic: Bounded(u8, TOPIC_MAX) = .{},
    /// Lines since this room was last looked at, and whether any named us.
    unread: u16 = 0,
    urgent: bool = false,
    /// The client is in this channel. A channel parted keeps its transcript
    /// and its place until it is closed.
    joined: bool = false,

    pub fn called(self: *const Room) []const u8 {
        return self.name.slice();
    }
};

/// One network: the connection's own state lives with the connection, and
/// what the window draws lives here.
pub const Network = struct {
    /// What to call it before the server says its own name.
    label: Bounded(u8, NAME_MAX) = .{},
    /// What the server called itself, from `RPL_ISUPPORT`.
    named: Bounded(u8, NAME_MAX) = .{},
    /// Which room is the network's own tab.
    tab: u8 = 0,
    connected: bool = false,

    pub fn called(self: *const Network) []const u8 {
        return if (self.named.len != 0) self.named.slice() else self.label.slice();
    }
};

/// Everything the window draws.
pub const Model = struct {
    networks: Bounded(Network, NETWORK_MAX) = .{},
    rooms: Bounded(Room, ROOM_MAX) = .{},
    /// Which room is being looked at.
    open: u8 = 0,

    /// Everyone in every room. Each entry says which room it is in.
    members: Bounded(Member, MEMBER_MAX) = .{},

    lines: Bounded(Line, LINE_MAX) = .{},
    text: [TEXT_MAX]u8 = undefined,
    used: u32 = 0,

    /// Casemapping is the network's to say, and the connection keeps it. The
    /// model is asked often enough that it holds a copy per network.
    mappings: [NETWORK_MAX]support.Casemapping = @splat(.rfc1459),

    /// Add a network and its server tab. Returns the network's index.
    pub fn addNetwork(self: *Model, label: []const u8) ?u8 {
        if (self.networks.isFull() or self.rooms.isFull()) return null;
        const which: u8 = @intCast(self.networks.len);
        var network: Network = .{ .tab = @intCast(self.rooms.len) };
        fill(&network.label, label);
        self.networks.append(network) catch return null;
        _ = self.addRoom(which, .server, label) orelse return null;
        return which;
    }

    /// Add a room to a network, or return the one already there.
    pub fn addRoom(self: *Model, network: u8, sort: Sort, name: []const u8) ?u8 {
        if (self.findRoom(network, name)) |found| return found;
        if (self.rooms.isFull()) return null;
        const which: u8 = @intCast(self.rooms.len);
        var room: Room = .{ .sort = sort, .network = network };
        fill(&room.name, name);
        self.rooms.append(room) catch return null;
        return which;
    }

    pub fn findRoom(self: *const Model, network: u8, name: []const u8) ?u8 {
        const mapping = self.mappingOf(network);
        for (self.rooms.slice(), 0..) |room, index| {
            if (room.network != network) continue;
            if (mapping.eql(room.name.slice(), name)) return @intCast(index);
        }
        return null;
    }

    /// The room in view, or null before there is one.
    pub fn current(self: *Model) ?*Room {
        if (self.open >= self.rooms.len) return null;
        return &self.rooms.items[self.open];
    }

    /// Look at a room, which is what clears what was waiting there.
    pub fn show(self: *Model, which: u8) void {
        if (which >= self.rooms.len) return;
        self.open = which;
        self.rooms.items[which].unread = 0;
        self.rooms.items[which].urgent = false;
    }

    /// Set the fields that are not zero. A model is a third of a megabyte of
    /// mostly empty transcript, so it is left out of the binary and zeroed by
    /// the loader; this is what zero does not already say.
    pub fn init(self: *Model) void {
        self.networks = .{};
        self.rooms = .{};
        self.members = .{};
        self.lines = .{};
        self.used = 0;
        self.open = 0;
        self.mappings = @splat(.rfc1459);
    }

    pub fn mappingOf(self: *const Model, network: u8) support.Casemapping {
        return if (network < NETWORK_MAX) self.mappings[network] else .rfc1459;
    }

    /// Write a line into a room. Old lines go when there is no room for a
    /// new one, oldest first.
    pub fn say(self: *Model, room: u8, line: Line, nick: []const u8, text: []const u8) void {
        if (room >= self.rooms.len) return;
        const wanted: u32 = @intCast(nick.len + text.len);
        if (wanted > TEXT_MAX) return;

        while (self.lines.isFull() or self.used + wanted > TEXT_MAX) {
            if (self.lines.len == 0) break;
            self.forgetOldest();
        }

        var written = line;
        written.room = room;
        written.nick = self.keep(nick);
        written.text = self.keep(text);
        self.lines.append(written) catch return;

        if (room != self.open and line.kind.counts()) {
            const at = &self.rooms.items[room];
            at.unread +|= 1;
            if (line.highlight) at.urgent = true;
        }
    }

    /// The lines belonging to a room, oldest first, written into `into`.
    /// Returns what was written.
    pub fn transcript(self: *const Model, room: u8, into: []usize) []const usize {
        var count: usize = 0;
        for (self.lines.slice(), 0..) |line, index| {
            if (line.room != room) continue;
            if (count == into.len) {
                // Keep the newest: a pane shows the end of a conversation.
                std.mem.copyForwards(usize, into[0 .. count - 1], into[1..count]);
                count -= 1;
            }
            into[count] = index;
            count += 1;
        }
        return into[0..count];
    }

    pub fn textOf(self: *const Model, span: Span) []const u8 {
        return span.of(&self.text);
    }

    // -- who is where

    /// Add someone to a room, or set the marks of someone already there.
    pub fn arrive(self: *Model, room: u8, nick: []const u8, marks: []const u8) void {
        if (nick.len == 0 or room >= self.rooms.len) return;
        const mapping = self.mappingOf(self.rooms.items[room].network);
        if (self.member(room, mapping, nick)) |found| {
            fill(&found.marks, marks);
            return;
        }
        var joined: Member = .{ .room = room };
        fill(&joined.nick, nick);
        fill(&joined.marks, marks);
        self.members.append(joined) catch {};
    }

    /// Take someone out of a room.
    pub fn depart(self: *Model, room: u8, nick: []const u8) void {
        if (room >= self.rooms.len) return;
        const mapping = self.mappingOf(self.rooms.items[room].network);
        for (self.members.slice(), 0..) |item, index| {
            if (item.room != room) continue;
            if (mapping.eql(item.nick.slice(), nick)) {
                self.members.remove(index);
                return;
            }
        }
    }

    /// Take a room's members away, for a channel that was left.
    pub fn empty(self: *Model, room: u8) void {
        var index: usize = 0;
        while (index < self.members.len) {
            if (self.members.items[index].room == room) {
                self.members.remove(index);
            } else {
                index += 1;
            }
        }
    }

    pub fn member(self: *Model, room: u8, mapping: support.Casemapping, nick: []const u8) ?*Member {
        for (self.members.mutable()) |*item| {
            if (item.room != room) continue;
            if (mapping.eql(item.nick.slice(), nick)) return item;
        }
        return null;
    }

    /// Everyone in a room, written into `into` as indices.
    pub fn membersOf(self: *const Model, room: u8, into: []usize) []const usize {
        var count: usize = 0;
        for (self.members.slice(), 0..) |item, index| {
            if (item.room != room) continue;
            if (count == into.len) break;
            into[count] = index;
            count += 1;
        }
        return into[0..count];
    }

    pub fn countIn(self: *const Model, room: u8) usize {
        var count: usize = 0;
        for (self.members.slice()) |item| {
            if (item.room == room) count += 1;
        }
        return count;
    }

    pub fn opsIn(self: *const Model, room: u8, prefixes: *const support.Prefixes) usize {
        var count: usize = 0;
        for (self.members.slice()) |item| {
            if (item.room == room and item.isOp(prefixes)) count += 1;
        }
        return count;
    }

    fn keep(self: *Model, text: []const u8) Span {
        const at = self.used;
        @memcpy(self.text[at..][0..text.len], text);
        self.used += @intCast(text.len);
        return .{ .at = at, .len = @intCast(text.len) };
    }

    /// Drop the oldest line and slide the arena down under it.
    fn forgetOldest(self: *Model) void {
        const gone = self.lines.items[0];
        const freed = gone.nick.len + gone.text.len;
        if (freed != 0) {
            std.mem.copyForwards(u8, self.text[0 .. self.used - freed], self.text[freed..self.used]);
            self.used -= freed;
        }
        self.lines.remove(0);
        for (self.lines.mutable()) |*line| {
            line.nick.at -= @min(line.nick.at, freed);
            line.text.at -= @min(line.text.at, freed);
        }
    }
};

fn fill(field: anytype, text: []const u8) void {
    field.clear();
    for (text) |ch| field.append(ch) catch break;
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

/// A model on the heap: it is far too large for a test's stack.
fn fresh() !*Model {
    const model = try std.testing.allocator.create(Model);
    model.* = .{};
    return model;
}

test "a network brings its own tab, and rooms belong to networks" {
    const model = try fresh();
    defer std.testing.allocator.destroy(model);

    const libera = model.addNetwork("libera.chat") orelse return error.NoRoom;
    try expect(libera == 0);
    try expect(model.rooms.len == 1);
    try expect(model.rooms.items[0].sort == .server);
    try expectEqualStrings("libera.chat", model.networks.items[0].called());

    const vibeee = model.addRoom(libera, .channel, "#vibeee") orelse return error.NoRoom;
    try expect(model.addRoom(libera, .channel, "#VIBEEE").? == vibeee);

    // The same name on another network is another room.
    const oftc = model.addNetwork("oftc") orelse return error.NoRoom;
    const other = model.addRoom(oftc, .channel, "#vibeee") orelse return error.NoRoom;
    try expect(other != vibeee);
    try expect(model.findRoom(oftc, "#vibeee").? == other);
}

test "what is waiting counts up until the room is looked at" {
    const model = try fresh();
    defer std.testing.allocator.destroy(model);

    const net = model.addNetwork("net") orelse return error.NoRoom;
    const room = model.addRoom(net, .channel, "#zig") orelse return error.NoRoom;
    model.show(0);

    model.say(room, .{ .kind = .said, .room = room }, "aoife", "hello");
    model.say(room, .{ .kind = .said, .room = room }, "aoife", "still here");
    try expect(model.rooms.items[room].unread == 2);
    try expect(!model.rooms.items[room].urgent);

    // A line that names us is worth more than one that does not.
    model.say(room, .{ .kind = .said, .room = room, .highlight = true }, "mikko", "kenny: ping");
    try expect(model.rooms.items[room].urgent);

    // What the server says does not make a room worth looking at.
    model.say(room, .{ .kind = .told, .room = room }, "", "someone joined");
    try expect(model.rooms.items[room].unread == 3);

    model.show(room);
    try expect(model.rooms.items[room].unread == 0);
    try expect(!model.rooms.items[room].urgent);

    // The room in view never counts.
    model.say(room, .{ .kind = .said, .room = room }, "aoife", "back");
    try expect(model.rooms.items[room].unread == 0);
}

test "a room's transcript is its own lines, oldest first" {
    const model = try fresh();
    defer std.testing.allocator.destroy(model);

    const net = model.addNetwork("net") orelse return error.NoRoom;
    const one = model.addRoom(net, .channel, "#one") orelse return error.NoRoom;
    const two = model.addRoom(net, .channel, "#two") orelse return error.NoRoom;

    model.say(one, .{ .kind = .said, .room = one }, "a", "first");
    model.say(two, .{ .kind = .said, .room = two }, "b", "elsewhere");
    model.say(one, .{ .kind = .said, .room = one }, "a", "second");

    var room: [8]usize = undefined;
    const shown = model.transcript(one, &room);
    try expect(shown.len == 2);
    try expectEqualStrings("first", model.textOf(model.lines.items[shown[0]].text));
    try expectEqualStrings("second", model.textOf(model.lines.items[shown[1]].text));

    // A window with room for one line shows the newest.
    var narrow: [1]usize = undefined;
    const last = model.transcript(one, &narrow);
    try expectEqualStrings("second", model.textOf(model.lines.items[last[0]].text));
}

test "old lines go when there is no room, and the rest still read" {
    const model = try fresh();
    defer std.testing.allocator.destroy(model);

    const net = model.addNetwork("net") orelse return error.NoRoom;
    const room = model.addRoom(net, .channel, "#full") orelse return error.NoRoom;

    // Past what the arena holds, so the oldest are dropped along the way.
    const long = "x" ** 512;
    for (0..600) |i| {
        var name: [8]u8 = undefined;
        model.say(room, .{ .kind = .said, .room = room }, std.fmt.bufPrint(&name, "n{d}", .{i % 10}) catch unreachable, long);
    }
    try expect(model.used <= TEXT_MAX);
    try expect(model.lines.len > 0);
    try expect(model.lines.len < 600);

    // Every line still points at its own text.
    for (model.lines.slice()) |line| {
        try expectEqualStrings(long, model.textOf(line.text));
        try expect(model.textOf(line.nick).len == 2);
    }
}

test "who is in a room, and who runs it" {
    const model = try fresh();
    defer std.testing.allocator.destroy(model);

    const net = model.addNetwork("net") orelse return error.NoRoom;
    const one = model.addRoom(net, .channel, "#one") orelse return error.NoRoom;
    const two = model.addRoom(net, .channel, "#two") orelse return error.NoRoom;

    model.arrive(one, "aoife", "@");
    model.arrive(one, "mikko", "+");
    model.arrive(one, "ruaidhri", "");
    model.arrive(two, "aoife", "");

    const prefixes = support.Prefixes.DEFAULT;
    try expect(model.countIn(one) == 3);
    try expect(model.countIn(two) == 1);
    try expect(model.opsIn(one, &prefixes) == 1);
    try expect(model.opsIn(two, &prefixes) == 0);

    try expect(model.member(one, .rfc1459, "AOIFE") != null);
    try expect(model.member(one, .rfc1459, "nobody") == null);
    try expect(model.member(one, .rfc1459, "aoife").?.isOp(&prefixes));
    try expect(!model.member(one, .rfc1459, "mikko").?.isOp(&prefixes));
    try expect(model.member(one, .rfc1459, "mikko").?.rank(&prefixes) <
        model.member(one, .rfc1459, "ruaidhri").?.rank(&prefixes));

    // Arriving twice sets the marks rather than adding a second entry.
    model.arrive(one, "mikko", "@");
    try expect(model.countIn(one) == 3);
    try expect(model.member(one, .rfc1459, "mikko").?.isOp(&prefixes));

    var room: [8]usize = undefined;
    try expect(model.membersOf(two, &room).len == 1);

    model.depart(one, "aoife");
    try expect(model.countIn(one) == 2);
    try expect(model.countIn(two) == 1);

    model.empty(one);
    try expect(model.countIn(one) == 0);
    try expect(model.countIn(two) == 1);
}
