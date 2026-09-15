//! Frames as the Attansic L1E writes them into a page.
//!
//! The part does not receive into a descriptor ring. It writes frames one
//! after another into a page of device memory, each behind a record saying
//! how long it is and what it was, and rounds the start of the next one up
//! to a thirty-two byte boundary. Where it has got to is a counter it
//! writes into memory of its own.
//!
//! Walking that is the part of the driver most likely to be wrong and the
//! only part of it that can be run anywhere but on the machine that has
//! the silicon: nothing emulates this part. So the walk is here, over a
//! plain slice, with no hardware in it, and it is tested.

const lib = @import("lib");
const std = @import("std");

/// How much of a page the part is told it may use.
///
/// Sixteen kilobytes is about a millisecond and a third of a gigabit wire
/// and thirteen of a hundred megabit one: long enough that the service
/// being busy elsewhere for a moment costs nothing, short enough that two
/// of them are a fraction of what the machine has.
pub const PAGE_BYTES = 16 * 1024;

pub const ETH_FCS = 4;
const ETH_VLAN = 4;
pub const MAX_FRAME = 1500 + lib.eth.HEADER + ETH_FCS + ETH_VLAN;

/// What the part rounds the start of each record up to.
pub const ALIGN = 32;

pub const RECORD_BYTES = 16;

/// How much is actually set aside for a page. The part may begin a frame
/// just under the mark it was given and finish it past there, so the room
/// after the mark is a whole frame's worth.
pub const PAGE_ROOM = std.mem.alignForward(usize, PAGE_BYTES + MAX_FRAME, ALIGN);

/// The record the part writes in front of every frame.
pub const Received = extern struct {
    /// Counts up by one per frame, so a record left in a page from an
    /// earlier lap is not read as a frame.
    sequence: u16 align(4) = 0,
    hash_low: u16 = 0,
    size: Size = .{},
    packet: Packet = .{},
    fault: Fault = .{},
    hash_high: u16 = 0,
    vlan: u16 = 0,

    pub const Size = packed struct(u32) {
        checksum: u16 = 0,
        /// The frame, with its four check bytes still on the end.
        bytes: u14 = 0,
        cpu: u2 = 0,
    };

    pub const Packet = packed struct(u16) {
        hashed_ipv4: bool = false,
        hashed_ipv4_tcp: bool = false,
        hashed_ipv6: bool = false,
        hashed_ipv6_tcp: bool = false,
        ipv6: bool = false,
        fragment: bool = false,
        dont_fragment: bool = false,
        raw_802_3: bool = false,
        vlan_tagged: bool = false,
        /// Something in `fault` says what.
        faulty: bool = false,
        ipv4: bool = false,
        udp: bool = false,
        tcp: bool = false,
        broadcast: bool = false,
        multicast: bool = false,
        pause: bool = false,
    };

    pub const Fault = packed struct(u16) {
        bad_crc: bool = false,
        code: bool = false,
        dribble: bool = false,
        runt: bool = false,
        overflow: bool = false,
        truncated: bool = false,
        ip_checksum: bool = false,
        l4_checksum: bool = false,
        length: bool = false,
        address: bool = false,
        _10: u6 = 0,

        /// Whether the frame itself is broken, as opposed to a checksum
        /// inside it that nothing here acts on anyway.
        pub fn spoilt(self: Fault) bool {
            return self.bad_crc or self.code or self.dribble or
                self.runt or self.truncated or self.length;
        }
    };
};

/// What the next record in a page turned out to be.
pub const Found = union(enum) {
    /// A frame, as it sits in the page, without the check bytes the part
    /// has already verified.
    frame: []const u8,
    /// A record the part marked broken. The walk has moved past it.
    broken,
    /// The part has written nothing more.
    empty,
    /// This side has lost its place: a sequence that does not follow, a
    /// length no frame could have, or a mark past the room set aside.
    /// The page holds frames whose boundaries cannot be found, so there
    /// is nothing to read in it and nothing to do but start the part
    /// again.
    lost,
};

/// Where a page has been read to, and what the next record should say.
///
/// The sequence counts frames rather than pages, so it carries across a
/// hand-back; the offset does not.
pub const Walk = struct {
    at: usize = 0,
    expect: u16 = 0,

    /// Back to the start of a page, keeping the count of frames.
    pub fn rewind(self: *Walk) void {
        self.at = 0;
    }

    /// And back to the beginning of everything, which is where a part
    /// that has just been reset starts counting.
    pub fn restart(self: *Walk) void {
        self.at = 0;
        self.expect = 0;
    }

    /// Whether the part is finished with this page and wants it back.
    pub fn finished(self: Walk) bool {
        return self.at >= PAGE_BYTES;
    }

    /// The next record, given how far the part says it has written.
    /// Advances past whatever it finds, so a caller asks again.
    pub fn next(self: *Walk, page: []const u8, written: usize) Found {
        if (self.at >= written) return .empty;
        // A mark past the room set aside, or a page shorter than the room
        // it should have, is the part writing somewhere it was not given.
        if (written > page.len or page.len < PAGE_ROOM) return .lost;
        if (page.len - self.at < RECORD_BYTES) return .lost;

        const record: *align(ALIGN) const Received = @ptrCast(@alignCast(&page[self.at]));
        if (record.sequence != self.expect) return .lost;

        const claimed = @as(usize, record.size.bytes);
        const whole = RECORD_BYTES + claimed;
        // A length no frame could have means this side and the part
        // disagree about where the record began.
        if (claimed <= ETH_FCS or claimed > MAX_FRAME or self.at + whole > page.len) return .lost;

        self.expect +%= 1;
        const body = page[self.at + RECORD_BYTES ..][0 .. claimed - ETH_FCS];
        self.at += std.mem.alignForward(usize, whole, ALIGN);

        // The wire broke it and the part says so. The record is still a
        // record, so the walk has moved on by it either way.
        if (record.packet.faulty and record.fault.spoilt()) return .broken;
        return .{ .frame = body };
    }
};

comptime {
    if (@sizeOf(Received) != RECORD_BYTES) @compileError("a receive record is sixteen bytes");
    if (ALIGN % @alignOf(Received) != 0) {
        @compileError("a record must land where a record may be read");
    }
    if (PAGE_ROOM % ALIGN != 0) @compileError("a page must end on a record boundary");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A page as the part would have written it, built a frame at a time.
const Filler = struct {
    bytes: []align(ALIGN) u8,
    at: usize = 0,
    sequence: u16 = 0,

    fn put(self: *Filler, body: []const u8, how: Received.Packet, why: Received.Fault) void {
        const record: *align(ALIGN) Received = @ptrCast(@alignCast(&self.bytes[self.at]));
        record.* = .{
            .sequence = self.sequence,
            .size = .{ .bytes = @intCast(body.len + ETH_FCS) },
            .packet = how,
            .fault = why,
        };
        @memcpy(self.bytes[self.at + RECORD_BYTES ..][0..body.len], body);
        self.sequence +%= 1;
        self.at += std.mem.alignForward(usize, RECORD_BYTES + body.len + ETH_FCS, ALIGN);
    }
};

fn emptyPage(store: []align(ALIGN) u8) Filler {
    @memset(store, 0);
    return .{ .bytes = store };
}

test "a page yields the frames written into it, in order" {
    var store: [PAGE_ROOM]u8 align(ALIGN) = undefined;
    var filler = emptyPage(&store);
    filler.put("first frame", .{}, .{});
    filler.put("second", .{}, .{});
    filler.put("the third one, which is longer than the others", .{}, .{});

    var walk = Walk{};
    try testing.expectEqualStrings("first frame", walk.next(&store, filler.at).frame);
    try testing.expectEqualStrings("second", walk.next(&store, filler.at).frame);
    try testing.expectEqualStrings(
        "the third one, which is longer than the others",
        walk.next(&store, filler.at).frame,
    );
    try testing.expectEqual(Found.empty, walk.next(&store, filler.at));
    try testing.expect(!walk.finished());
}

test "a record the part marked broken moves the walk on without a frame" {
    var store: [PAGE_ROOM]u8 align(ALIGN) = undefined;
    var filler = emptyPage(&store);
    filler.put("before", .{}, .{});
    filler.put("this one arrived without its check", .{ .faulty = true }, .{ .bad_crc = true });
    filler.put("after", .{}, .{});

    var walk = Walk{};
    try testing.expectEqualStrings("before", walk.next(&store, filler.at).frame);
    try testing.expectEqual(Found.broken, walk.next(&store, filler.at));
    try testing.expectEqualStrings("after", walk.next(&store, filler.at).frame);
}

test "a fault the part flags and nothing else is wrong with is still a frame" {
    // A checksum inside the frame that did not add up is the stack's
    // business, not the wire's: the frame arrived whole.
    var store: [PAGE_ROOM]u8 align(ALIGN) = undefined;
    var filler = emptyPage(&store);
    filler.put("whole", .{ .faulty = true }, .{ .ip_checksum = true, .l4_checksum = true });

    var walk = Walk{};
    try testing.expectEqualStrings("whole", walk.next(&store, filler.at).frame);
}

test "a sequence that does not follow is a page this side has lost its place in" {
    var store: [PAGE_ROOM]u8 align(ALIGN) = undefined;
    var filler = emptyPage(&store);
    filler.put("first", .{}, .{});
    // What an earlier lap left behind: a record that looks like one and
    // counts from somewhere else.
    filler.sequence = 900;
    filler.put("stale", .{}, .{});

    var walk = Walk{};
    try testing.expectEqualStrings("first", walk.next(&store, filler.at).frame);
    try testing.expectEqual(Found.lost, walk.next(&store, filler.at));

    // And it stays lost: nothing further in the page means anything.
    try testing.expectEqual(Found.lost, walk.next(&store, filler.at));
}

test "a length no frame could have is refused rather than read" {
    var store: [PAGE_ROOM]u8 align(ALIGN) = undefined;
    @memset(&store, 0);

    const record: *align(ALIGN) Received = @ptrCast(@alignCast(&store[0]));
    var walk = Walk{};

    // Nothing but the check bytes is not a frame.
    record.* = .{ .size = .{ .bytes = ETH_FCS } };
    try testing.expectEqual(Found.lost, walk.next(&store, PAGE_BYTES));

    // Longer than any frame this part is set up to receive.
    record.* = .{ .size = .{ .bytes = MAX_FRAME + 1 } };
    walk = .{};
    try testing.expectEqual(Found.lost, walk.next(&store, PAGE_BYTES));

    // And one that would run off the end of the room set aside.
    walk = .{ .at = PAGE_ROOM - ALIGN };
    const late: *align(ALIGN) Received = @ptrCast(@alignCast(&store[walk.at]));
    late.* = .{ .size = .{ .bytes = 100 } };
    try testing.expectEqual(Found.lost, walk.next(&store, PAGE_ROOM));
}

test "a mark past the room set aside is the part writing where it was not sent" {
    var store: [PAGE_ROOM]u8 align(ALIGN) = undefined;
    var filler = emptyPage(&store);
    filler.put("fine", .{}, .{});

    var walk = Walk{};
    try testing.expectEqual(Found.lost, walk.next(&store, PAGE_ROOM + 1));
}

test "a page is finished when the part has filled what it was given" {
    var store: [PAGE_ROOM]u8 align(ALIGN) = undefined;
    var walk = Walk{ .at = PAGE_BYTES - ALIGN };
    try testing.expect(!walk.finished());

    // The part may begin a frame just under the mark and finish it past
    // there, which is what the room after the mark is for.
    @memset(&store, 0);
    const record: *align(ALIGN) Received = @ptrCast(@alignCast(&store[walk.at]));
    record.* = .{ .size = .{ .bytes = 60 + ETH_FCS } };
    try testing.expectEqual(@as(usize, 60), walk.next(&store, PAGE_BYTES).frame.len);
    try testing.expect(walk.finished());

    // Rewinding keeps the count of frames, which the part does not reset
    // when a page is handed back; restarting does not.
    try testing.expectEqual(@as(u16, 1), walk.expect);
    walk.rewind();
    try testing.expectEqual(@as(usize, 0), walk.at);
    try testing.expectEqual(@as(u16, 1), walk.expect);
    walk.restart();
    try testing.expectEqual(@as(u16, 0), walk.expect);
}

test "the record is the shape the part writes" {
    const word = struct {
        fn of(value: anytype) u32 {
            return @bitCast(value);
        }
    }.of;
    try testing.expectEqual(@as(u32, 0xFFFF), word(Received.Size{ .checksum = 0xFFFF }));
    try testing.expectEqual(@as(u32, 0x3FFF_0000), word(Received.Size{ .bytes = 0x3FFF }));
    try testing.expectEqual(@as(u32, 0xC000_0000), word(Received.Size{ .cpu = 3 }));

    const half = struct {
        fn of(value: anytype) u16 {
            return @bitCast(value);
        }
    }.of;
    try testing.expectEqual(@as(u16, 0x0200), half(Received.Packet{ .faulty = true }));
    try testing.expectEqual(@as(u16, 0x2000), half(Received.Packet{ .broadcast = true }));
    try testing.expectEqual(@as(u16, 0x0001), half(Received.Fault{ .bad_crc = true }));
    try testing.expectEqual(@as(u16, 0x0020), half(Received.Fault{ .truncated = true }));

    // What counts as the wire having broken a frame, as against a
    // checksum inside it that nothing here acts on.
    try testing.expect((Received.Fault{ .bad_crc = true }).spoilt());
    try testing.expect((Received.Fault{ .runt = true }).spoilt());
    try testing.expect(!(Received.Fault{ .ip_checksum = true }).spoilt());
    try testing.expect(!(Received.Fault{ .overflow = true }).spoilt());
}
