//! Where echat's panes go.
//!
//! Pure rectangle arithmetic, so the layout is checked on the host rather than
//! by looking at it. Every size comes from the theme, so the window is right
//! at any interface scale rather than only at a hundred per cent.

const std = @import("std");
const eui = @import("eui");
const rooms = @import("rooms.zig");

const Rect = eui.Rect;
const Surface = eui.Surface;
const theme = eui.theme;

/// How wide the list of who is here. Narrow enough that the words keep the
/// screen, wide enough for a nick and its mark.
pub const MEMBERS: i32 = 116;

/// A strip of text with a hairline under it: the room's name and topic.
pub fn headerHeight() i32 {
    return Surface.textHeight() + theme.enlarged(4);
}

/// A row in the list of who is here. One line of text, nothing around it:
/// twelve names have to fit.
pub fn memberHeight() i32 {
    return Surface.textHeight();
}

/// The strip where what you type goes.
pub fn inputHeight() i32 {
    return theme.current().control_height + theme.enlarged(2);
}

pub fn membersWidth() i32 {
    return theme.enlarged(MEMBERS);
}

/// A strip the window uses to say something itself. Only there when there is
/// something to say.
pub fn noticeHeight() i32 {
    return Surface.textHeight() + theme.enlarged(2);
}

/// The panes of the window, in the order they are drawn.
pub const Panes = struct {
    /// The places this window has, with the nick at its foot.
    rail: Rect,
    /// The room's name and what it is about.
    header: Rect,
    /// What was said.
    transcript: Rect,
    /// Who is here. Empty for a room that has no members.
    members: Rect,
    /// What you are typing.
    input: Rect,
    /// What the window has to say. Zero-height when it has nothing.
    notice: Rect,
};

/// Lay out a window. `with_members` is false for a server tab and a private
/// conversation, where a list of who is here would say nothing.
pub fn place(area: Rect, with_members: bool, with_notice: bool) Panes {
    const rail = eui.rail.column(area, 0);
    const rest = eui.rail.beside(area, rail);

    const header: Rect = .{ .x = rest.x, .y = rest.y, .w = rest.w, .h = headerHeight() };
    const input_h = inputHeight();
    const notice_h: i32 = if (with_notice) noticeHeight() else 0;
    const middle: Rect = .{
        .x = rest.x,
        .y = header.bottom(),
        .w = rest.w,
        .h = rest.h - header.h - input_h - notice_h,
    };

    // The list of who is here takes from the right, and the words take the
    // rest. A narrow window keeps the words: a transcript squeezed to nothing
    // beside a full list of names is the wrong way round.
    const wanted = membersWidth();
    const spare = middle.w - wanted - 1;
    const members: Rect = if (with_members and spare >= wanted)
        .{ .x = middle.right() - wanted, .y = middle.y, .w = wanted, .h = middle.h }
    else
        .{ .x = middle.right(), .y = middle.y, .w = 0, .h = middle.h };

    return .{
        .rail = rail,
        .header = header,
        .transcript = .{
            .x = middle.x,
            .y = middle.y,
            .w = middle.w - members.w - @as(i32, if (members.w == 0) 0 else 1),
            .h = middle.h,
        },
        .members = members,
        .notice = .{ .x = rest.x, .y = middle.bottom(), .w = rest.w, .h = notice_h },
        .input = .{ .x = rest.x, .y = middle.bottom() + notice_h, .w = rest.w, .h = input_h },
    };
}

/// The row a member is drawn on, under the strip that counts them.
pub fn memberRow(members: Rect, index: usize) Rect {
    const height = memberHeight();
    return .{
        .x = members.x,
        .y = members.y + headerHeight() + @as(i32, @intCast(index)) * height,
        .w = members.w,
        .h = height,
    };
}

/// How many members fit under the count.
pub fn membersShown(members: Rect) usize {
    const height = memberHeight();
    if (height <= 0) return 0;
    const room = members.h - headerHeight();
    if (room <= 0) return 0;
    return @intCast(@divTrunc(room, height));
}

/// A network: two stacked units, which is what a server has looked like for
/// as long as anyone has drawn one.
pub const server_glyph = eui.icon.pack(.{
    "............",
    "............",
    ".##########.",
    ".#........#.",
    ".##########.",
    "............",
    ".##########.",
    ".#........#.",
    ".##########.",
    "............",
    "............",
    "............",
});

/// A channel: the mark its name starts with.
pub const channel_glyph = eui.icon.pack(.{
    "............",
    "............",
    "...#...#....",
    "...#...#....",
    ".#######....",
    "..#...#.....",
    "..#...#.....",
    ".#######....",
    "..#...#.....",
    "..#...#.....",
    "............",
    "............",
});

/// One person, for a conversation with them alone.
pub const person_glyph = eui.icon.pack(.{
    "............",
    "....####....",
    "...#....#...",
    "...#....#...",
    "....####....",
    "............",
    "..########..",
    ".#........#.",
    ".#........#.",
    ".#........#.",
    "............",
    "............",
});

/// The places the window has, in the order they are shown: each network, then
/// the rooms on it. Labels point into the model, which outlives the pass.
pub fn railItems(model: *const rooms.Model, into: []eui.rail.Item) []const eui.rail.Item {
    var count: usize = 0;
    // By pointer: a label points into the model, and a copy on this frame
    // would leave every row naming freed stack.
    for (model.networks.slice(), 0..) |*network, which| {
        if (count == into.len) break;
        const tab = network.tab;
        into[count] = .{
            .label = network.called(),
            .glyph = &server_glyph,
            .count = if (tab < model.rooms.len) model.rooms.items[tab].unread else 0,
            .urgent = tab < model.rooms.len and model.rooms.items[tab].urgent,
        };
        count += 1;

        for (model.rooms.slice(), 0..) |*room, index| {
            if (room.network != which or index == tab) continue;
            if (count == into.len) break;
            into[count] = .{
                .label = room.called(),
                .glyph = if (room.sort == .channel) &channel_glyph else &person_glyph,
                .depth = 1,
                .count = room.unread,
                .urgent = room.urgent,
            };
            count += 1;
        }
    }
    return into[0..count];
}

/// How many rows the rail has: every network and every room on it.
pub fn rowCount(model: *const rooms.Model) usize {
    return model.networks.len + model.rooms.len - countTabs(model);
}

/// Networks whose own tab is a room, which every network's is: counted so a
/// tab is not counted twice.
fn countTabs(model: *const rooms.Model) usize {
    var count: usize = 0;
    for (model.networks.slice()) |network| {
        if (network.tab < model.rooms.len) count += 1;
    }
    return count;
}

/// Which room a rail row stands for, or null for a row that is not there.
pub fn roomAt(model: *const rooms.Model, row: usize) ?u8 {
    var count: usize = 0;
    for (model.networks.slice(), 0..) |network, which| {
        if (count == row) return network.tab;
        count += 1;
        for (model.rooms.slice(), 0..) |room, index| {
            if (room.network != which or index == network.tab) continue;
            if (count == row) return @intCast(index);
            count += 1;
        }
    }
    return null;
}

/// Which rail row a room is on, so the chosen room is the marked row.
pub fn rowOf(model: *const rooms.Model, room: u8) usize {
    var count: usize = 0;
    for (model.networks.slice(), 0..) |network, which| {
        if (network.tab == room) return count;
        count += 1;
        for (model.rooms.slice(), 0..) |item, index| {
            if (item.network != which or index == network.tab) continue;
            if (index == room) return count;
            count += 1;
        }
    }
    return 0;
}

const testing = std.testing;
const screen = Rect{ .x = 0, .y = 0, .w = 800, .h = 458 };

/// Every size here is measured from a face, and a test has no window manager
/// to take one from.
fn withFaces() void {
    eui.useLinked();
}

fn emptyModel() !*rooms.Model {
    const built = try testing.allocator.create(rooms.Model);
    built.* = .{};
    return built;
}

test "the panes fill the window and do not overlap" {
    withFaces();
    const panes = place(screen, true, false);

    try testing.expectEqual(screen.x, panes.rail.x);
    try testing.expectEqual(screen.h, panes.rail.h);
    try testing.expect(panes.header.x > panes.rail.right());
    try testing.expectEqual(screen.right(), panes.header.right());

    try testing.expectEqual(panes.header.bottom(), panes.transcript.y);
    try testing.expectEqual(panes.transcript.y, panes.members.y);
    try testing.expectEqual(panes.transcript.h, panes.members.h);
    try testing.expect(panes.transcript.right() < panes.members.x);

    try testing.expectEqual(panes.transcript.bottom(), panes.input.y);
    try testing.expectEqual(screen.bottom(), panes.input.bottom());
    try testing.expectEqual(panes.header.w, panes.input.w);
}

test "a room with nobody in it gives the words the whole width" {
    withFaces();
    const with = place(screen, true, false);
    const without = place(screen, false, false);
    try testing.expectEqual(@as(i32, 0), without.members.w);
    try testing.expect(without.transcript.w > with.transcript.w);
    try testing.expectEqual(without.header.right(), without.transcript.right());
}

test "a notice takes its strip from the words, not from the line you type" {
    withFaces();
    const quiet = place(screen, true, false);
    const talking = place(screen, true, true);
    try testing.expectEqual(@as(i32, 0), quiet.notice.h);
    try testing.expect(talking.notice.h > 0);
    try testing.expectEqual(quiet.input.h, talking.input.h);
    try testing.expectEqual(quiet.input.bottom(), talking.input.bottom());
    try testing.expectEqual(talking.transcript.h + talking.notice.h, quiet.transcript.h);
    try testing.expectEqual(talking.transcript.bottom(), talking.notice.y);
    try testing.expectEqual(talking.notice.bottom(), talking.input.y);
}

test "a window too narrow for both keeps the words" {
    withFaces();
    const narrow = Rect{ .x = 0, .y = 0, .w = 320, .h = 240 };
    const panes = place(narrow, true, false);
    try testing.expectEqual(@as(i32, 0), panes.members.w);
    try testing.expect(panes.transcript.w > 0);
}

test "members stack under the strip that counts them" {
    withFaces();
    const panes = place(screen, true, false);
    const first = memberRow(panes.members, 0);
    try testing.expectEqual(panes.members.y + headerHeight(), first.y);
    try testing.expectEqual(panes.members.w, first.w);
    try testing.expectEqual(first.bottom(), memberRow(panes.members, 1).y);
    try testing.expect(membersShown(panes.members) > 10);
}

test "the rail lists each network and holds its rooms under it" {
    withFaces();
    const built = try emptyModel();
    defer testing.allocator.destroy(built);

    const libera = built.addNetwork("libera.chat") orelse return error.NoRoom;
    const vibeee = built.addRoom(libera, .channel, "#vibeee") orelse return error.NoRoom;
    const query = built.addRoom(libera, .query, "aoife") orelse return error.NoRoom;
    const oftc = built.addNetwork("oftc") orelse return error.NoRoom;
    const llvm = built.addRoom(oftc, .channel, "#llvm") orelse return error.NoRoom;

    var room: [8]eui.rail.Item = undefined;
    const items = railItems(built, &room);
    try testing.expectEqual(@as(usize, 5), items.len);
    try testing.expectEqualStrings("libera.chat", items[0].label);
    try testing.expectEqual(@as(u2, 0), items[0].depth);
    try testing.expectEqualStrings("#vibeee", items[1].label);
    try testing.expectEqual(@as(u2, 1), items[1].depth);
    try testing.expectEqualStrings("aoife", items[2].label);
    try testing.expectEqualStrings("oftc", items[3].label);
    try testing.expectEqual(@as(u2, 0), items[3].depth);
    try testing.expectEqualStrings("#llvm", items[4].label);

    // Every row names the room it stands for, both ways round.
    const order = [_]u8{ built.networks.items[0].tab, vibeee, query, built.networks.items[1].tab, llvm };
    for (order, 0..) |which, row| {
        try testing.expectEqual(@as(?u8, which), roomAt(built, row));
        try testing.expectEqual(row, rowOf(built, which));
    }
    try testing.expectEqual(@as(?u8, null), roomAt(built, order.len));
    try testing.expectEqual(order.len, rowCount(built));
    try testing.expectEqual(items.len, rowCount(built));
}

test "what is waiting in a room shows on its rail row" {
    withFaces();
    const built = try emptyModel();
    defer testing.allocator.destroy(built);

    const net = built.addNetwork("net") orelse return error.NoRoom;
    const room = built.addRoom(net, .channel, "#zig") orelse return error.NoRoom;
    built.show(built.networks.items[0].tab);
    built.say(room, .{ .kind = .said, .room = room, .highlight = true }, "aoife", "hello");

    var space: [4]eui.rail.Item = undefined;
    const items = railItems(built, &space);
    try testing.expectEqual(@as(u16, 1), items[1].count);
    try testing.expect(items[1].urgent);
    try testing.expectEqual(@as(u16, 0), items[0].count);
}
