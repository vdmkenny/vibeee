//! The RTL8139 receive ring, as the host reads it.
//!
//! The chip writes each frame into a byte ring as one record: a four-byte
//! header with the status and length, the frame, and its check sequence. The
//! next record starts on a four-byte boundary. With WRAP set in RCR a record
//! is never split: one that reaches the end of the ring continues into a
//! spill area after it, and the next record starts at its end less the size
//! of the ring.
//!
//! CBR is where the chip writes next. CAPR is where the host reads next,
//! less sixteen, and the chip does not write past the host's read position.
//! BUFE says whether anything is unread, which tells a full ring from an
//! empty one when CBR meets the read position.
//!
//! Pure over the ring memory. `Barrier` orders the host against the chip:
//! `publish` before CAPR gives a record back, `consume` before reading what
//! the chip wrote. The tests drive the ring against a model of the chip that
//! moves at those points and at every register access.

const std = @import("std");
const cursor = @import("../cursor.zig");

/// RCR's receive buffer length.
pub const Size = enum(u2) {
    kib_8,
    kib_16,
    kib_32,
    kib_64,

    pub fn bytes(self: Size) usize {
        return switch (self) {
            .kib_8 => 8 * 1024,
            .kib_16 => 16 * 1024,
            .kib_32 => 32 * 1024,
            .kib_64 => 64 * 1024,
        };
    }

    /// The ring, the pad the chip documents after it, and the spill area:
    /// the memory the chip is given, and the longest record the host walks.
    pub fn area(self: Size) usize {
        return self.bytes() + PAD + SPILL;
    }
};

/// The longest frame the host takes, without its check sequence.
pub const MAX_FRAME = 1518;
pub const FCS = 4;

const ALIGN = 4;
const PAD = 16;
const SPILL = 2048;

/// How far CAPR stands behind the read position.
const CAPR_LAG = 16;

/// The status and length the chip writes ahead of every frame.
pub const Header = packed struct(u32) {
    ok: bool = false,
    frame_align: bool = false,
    crc_error: bool = false,
    long_frame: bool = false,
    runt_frame: bool = false,
    bad_symbol: bool = false,
    _6: u7 = 0,
    broadcast: bool = false,
    physical: bool = false,
    multicast: bool = false,
    /// The frame and its check sequence.
    length: Length = .of(0),

    pub const Length = enum(u16) {
        /// The chip is still copying the frame in.
        unfinished = 0xFFF0,
        _,

        pub fn of(bytes: u16) Length {
            return @enumFromInt(bytes);
        }
    };

    /// Whether the chip's status says the frame arrived whole, and the frame
    /// fits the copy the host takes. Whether this system carries a frame of
    /// that length is decided above the driver.
    pub fn good(self: Header, frame: usize) bool {
        return self.ok and !self.frame_align and !self.crc_error and
            !self.long_frame and !self.runt_frame and !self.bad_symbol and
            frame <= MAX_FRAME;
    }
};

/// What the record at the read position is, given how many bytes CBR has
/// passed from there.
pub const Record = union(enum) {
    frame: Span,
    /// A record to step over: marked bad, or longer than a frame the host
    /// takes. Its length on the ring.
    dropped: usize,
    /// The chip has not finished writing the record.
    unfinished,
    /// A length no record in this ring can have. Where the next record
    /// starts is unknown.
    lost,

    pub const Span = struct {
        /// The frame, without its check sequence.
        bytes: usize,
        /// The whole record on the ring.
        record: usize,
    };
};

pub fn judge(size: Size, header: Header, published: usize) Record {
    if (header.length == .unfinished) return .unfinished;
    const wire: usize = @intFromEnum(header.length);
    if (wire < FCS or @sizeOf(Header) + wire > size.area()) return .lost;
    const record = std.mem.alignForward(usize, @sizeOf(Header) + wire, ALIGN);
    if (record > published) return .unfinished;
    const frame = wire - FCS;
    if (!header.good(frame)) return .{ .dropped = record };
    return .{ .frame = .{ .bytes = frame, .record = record } };
}

/// How a pass over the ring ended.
pub const Pass = enum {
    /// At a record boundary. The next pass goes on from there.
    ok,
    /// At a length no record can have. The receiver must be restarted.
    lost,
};

pub fn Receiver(comptime size: Size, comptime Barrier: type) type {
    if (size == .kib_64) @compileError("a 64 KiB ring splits records at its end, and this walk reads them whole");

    return struct {
        const Self = @This();

        pub const RING = size.bytes();
        pub const AREA = size.area();

        area: *volatile [AREA]u8,
        /// Where the host reads next.
        at: cursor.Cursor(RING) = .{},

        /// The start of the ring, where the chip writes after RBSTART.
        pub fn restart(self: *Self) void {
            self.at = .{};
        }

        /// CAPR for the read position.
        pub fn mark(self: Self) u16 {
            return @truncate(self.at.at -% CAPR_LAG);
        }

        /// Take up to `budget` records, of those CBR had passed when the pass
        /// began, handing each to `deliver`: the frame, or null for one
        /// stepped over. `part` answers `empty` from BUFE and `written` from
        /// CBR, and `readTo` writes CAPR.
        pub fn take(
            self: *Self,
            budget: usize,
            part: anytype,
            context: anytype,
            comptime deliver: fn (@TypeOf(context), ?[]const u8) void,
        ) Pass {
            if (part.empty()) return .ok;
            var published = cursor.usedBetween(cursor.wrapped(part.written(), RING), self.at.at, RING);
            // BUFE says something is unread, so CBR on the read position is a full ring.
            if (published == 0) published = RING;
            Barrier.consume();

            var taken: usize = 0;
            while (published >= @sizeOf(Header) and taken < budget) : (taken += 1) {
                const record = switch (judge(size, self.header(), published)) {
                    .unfinished => return .ok,
                    .lost => return .lost,
                    .dropped => |record| blk: {
                        deliver(context, null);
                        break :blk record;
                    },
                    .frame => |frame| blk: {
                        var copy: [MAX_FRAME]u8 = undefined;
                        const start = self.at.at + @sizeOf(Header);
                        for (copy[0..frame.bytes], start..) |*byte, at| byte.* = self.area[at];
                        deliver(context, copy[0..frame.bytes]);
                        break :blk frame.record;
                    },
                };
                self.at.advance(record);
                published -= record;
                Barrier.publish();
                part.readTo(self.mark());
            }
            return .ok;
        }

        /// Byte by byte: the chip writes this memory, and every load has to
        /// happen.
        fn header(self: *const Self) Header {
            var bytes: [@sizeOf(Header)]u8 = undefined;
            for (&bytes, self.at.at..) |*byte, at| byte.* = self.area[at];
            return @bitCast(std.mem.readInt(u32, &bytes, .little));
        }
    };
}

comptime {
    const largest = std.mem.alignForward(usize, @sizeOf(Header) + MAX_FRAME + FCS, ALIGN);
    if (PAD + SPILL < largest) @compileError("the spill area cannot hold the largest frame's record");
    // CBR and CAPR are sixteen bits, and wrap where every ring does.
    for (std.enums.values(Size)) |size| {
        if ((std.math.maxInt(u16) + 1) % size.bytes() != 0) @compileError("a ring must divide the registers' range");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const lib = @import("lib");
const testing = std.testing;

const Plain = struct {
    pub fn publish() void {}
    pub fn consume() void {}
};

test "a header is the chip's word" {
    const word = struct {
        fn of(header: Header) u32 {
            return @bitCast(header);
        }
    }.of;
    try testing.expectEqual(@as(u32, 0x0000_0001), word(.{ .ok = true }));
    try testing.expectEqual(@as(u32, 0x0000_0004), word(.{ .crc_error = true }));
    try testing.expectEqual(@as(u32, 0x0000_0020), word(.{ .bad_symbol = true }));
    try testing.expectEqual(@as(u32, 0x0000_2000), word(.{ .broadcast = true }));
    try testing.expectEqual(@as(u32, 0x0000_8000), word(.{ .multicast = true }));
    try testing.expectEqual(@as(u32, 0xFFF0_0000), word(.{ .length = .unfinished }));
    try testing.expectEqual(@as(u32, 0x0040_0001), word(.{ .ok = true, .length = .of(64) }));
}

test "each record at the read position is judged" {
    const size: Size = .kib_8;
    const Case = struct { header: Header, published: usize, is: Record };
    const cases = [_]Case{
        // Sixty bytes and the check sequence, on a boundary.
        .{ .header = .{ .ok = true, .length = .of(64) }, .published = 68, .is = .{ .frame = .{ .bytes = 60, .record = 68 } } },
        // One more, and the record pads to the next boundary.
        .{ .header = .{ .ok = true, .length = .of(65) }, .published = 72, .is = .{ .frame = .{ .bytes = 61, .record = 72 } } },
        // The padding is part of what CBR has to pass.
        .{ .header = .{ .ok = true, .length = .of(65) }, .published = 71, .is = .unfinished },
        .{ .header = .{ .ok = true, .length = .unfinished }, .published = size.bytes(), .is = .unfinished },
        // Only the check sequence: an empty frame, which is not this ring's to refuse.
        .{ .header = .{ .ok = true, .length = .of(FCS) }, .published = 8, .is = .{ .frame = .{ .bytes = 0, .record = 8 } } },
        .{ .header = .{ .ok = true, .length = .of(MAX_FRAME + FCS) }, .published = 1528, .is = .{ .frame = .{ .bytes = MAX_FRAME, .record = 1528 } } },
        .{ .header = .{ .ok = true, .length = .of(MAX_FRAME + FCS + 1) }, .published = 1528, .is = .{ .dropped = 1528 } },
        .{ .header = .{ .length = .of(64) }, .published = 68, .is = .{ .dropped = 68 } },
        .{ .header = .{ .ok = true, .crc_error = true, .length = .of(64) }, .published = 68, .is = .{ .dropped = 68 } },
        .{ .header = .{ .ok = true, .runt_frame = true, .length = .of(20) }, .published = 24, .is = .{ .dropped = 24 } },
        // A length that cannot hold the check sequence, or runs past the spill.
        .{ .header = .{ .ok = true, .length = .of(FCS - 1) }, .published = 68, .is = .lost },
        .{ .header = .{ .ok = true, .length = .of(0) }, .published = 68, .is = .lost },
        .{ .header = .{ .ok = true, .length = .of(@intCast(size.area() - @sizeOf(Header) + 1)) }, .published = size.bytes(), .is = .lost },
        .{ .header = .{ .ok = true, .length = .of(std.math.maxInt(u16)) }, .published = size.bytes(), .is = .lost },
    };

    var reached = std.EnumSet(std.meta.Tag(Record)){};
    for (cases) |case| {
        const is = judge(size, case.header, case.published);
        try testing.expectEqual(case.is, is);
        reached.insert(is);
    }
    try testing.expect(reached.eql(.initFull()));
}

test "CAPR stands sixteen bytes behind the read position" {
    const Ring = Receiver(.kib_32, Plain);
    var receiver = Ring{ .area = undefined };
    try testing.expectEqual(@as(u16, 0xFFF0), receiver.mark());
    receiver.at.advance(68);
    try testing.expectEqual(@as(u16, 52), receiver.mark());
    receiver.at.advance(Ring.RING - 68);
    try testing.expectEqual(@as(u16, 0xFFF0), receiver.mark());
}

/// What the chip writes into a frame's check sequence, as far as the host is
/// concerned.
const CHECK_BYTE = 0xFC;

/// Write a record as the chip does, and say where the next one starts.
fn put(memory: []u8, at: usize, header: Header, frame: []const u8) usize {
    std.mem.writeInt(u32, memory[at..][0..@sizeOf(Header)], @bitCast(header), .little);
    const body = at + @sizeOf(Header);
    @memcpy(memory[body..][0..frame.len], frame);
    @memset(memory[body + frame.len ..][0..FCS], CHECK_BYTE);
    return std.mem.alignForward(usize, body + frame.len + FCS, ALIGN);
}

test "records are taken in order, one past the end of the ring read from the spill" {
    const Ring = Receiver(.kib_8, Plain);
    const Registers = struct {
        cbr: u16,
        marks: [4]u16 = undefined,
        count: usize = 0,

        pub fn empty(_: *@This()) bool {
            return false;
        }

        pub fn written(self: *@This()) u16 {
            return self.cbr;
        }

        pub fn readTo(self: *@This(), mark: u16) void {
            self.marks[self.count] = mark;
            self.count += 1;
        }
    };
    const Taken = struct {
        store: [4][64]u8 = undefined,
        lengths: [4]?usize = undefined,
        count: usize = 0,

        fn deliver(self: *@This(), frame: ?[]const u8) void {
            self.lengths[self.count] = if (frame) |whole| whole.len else null;
            if (frame) |whole| @memcpy(self.store[self.count][0..whole.len], whole);
            self.count += 1;
        }

        fn nth(self: *const @This(), index: usize) ?[]const u8 {
            const length = self.lengths[index] orelse return null;
            return self.store[index][0..length];
        }
    };

    var memory: [Ring.AREA]u8 = @splat(0);
    const first = Ring.RING - 32;
    var next = put(&memory, first, .{ .ok = true, .length = .of(14 + FCS) }, "fourteen bytes");
    // Starts eight bytes before the end and finishes past it.
    next = put(&memory, next, .{ .ok = true, .length = .of(29 + FCS) }, "twenty-nine bytes, some after");
    try testing.expect(next > Ring.RING);
    next = put(&memory, next - Ring.RING, .{ .crc_error = true, .length = .of(9 + FCS) }, "corrupted");

    var receiver = Ring{ .area = &memory };
    receiver.at.advance(first);
    var registers = Registers{ .cbr = @intCast(next) };
    var taken = Taken{};
    try testing.expectEqual(Pass.ok, receiver.take(8, &registers, &taken, Taken.deliver));

    try testing.expectEqual(@as(usize, 3), taken.count);
    try testing.expectEqualStrings("fourteen bytes", taken.nth(0).?);
    try testing.expectEqualStrings("twenty-nine bytes, some after", taken.nth(1).?);
    try testing.expectEqual(@as(?[]const u8, null), taken.nth(2));
    try testing.expectEqual(@as(usize, 3), registers.count);
    try testing.expectEqual(@as(u16, Ring.RING - 8 - CAPR_LAG), registers.marks[0]);
    try testing.expectEqual(@as(u16, 32 - CAPR_LAG), registers.marks[1]);
    try testing.expectEqual(@as(u16, @intCast(next - CAPR_LAG)), registers.marks[2]);
    try testing.expectEqual(next, receiver.at.at);
}

// ---------------------------------------------------------------------------
// Fuzzing: the ring against a model of the chip
// ---------------------------------------------------------------------------
//
// The model writes records into free space one at a time and moves at the
// barriers and at every register access. It copies a frame in one go, as
// QEMU does, or over several steps with the length reading unfinished until
// the copy is done and CBR passing the padding before or after the header is
// final. It fills the ring to the last byte, or stops short of the read
// position as QEMU does. Now and then it writes a length no record can have,
// and writes nothing more until restarted.
//
// Checked: each record is taken once and in order, with the bytes the chip
// wrote; none is taken before CBR passed it; CAPR moves only to the end of
// the record just taken; a pass loses its place only at a length no record
// can have; a drained ring is empty.

const fuzzing = lib.fuzzing;
const Choices = fuzzing.Choices;

const Modelled = Receiver(.kib_8, Stepping);
const Position = cursor.Cursor(Modelled.RING);

/// The most records the ring holds: the shortest is an empty frame's, a
/// header and a check sequence.
const RECORDS = Modelled.RING / (@sizeOf(Header) + FCS) + 1;

/// The longest frame the model sends, longer than any the host takes.
const LONG_FRAME = 3 * 1024;

/// Memory behind the area, which a long record reaching past the end of the
/// ring is written into and never read from.
const MEMORY = Modelled.AREA + 4 * 1024;

/// What memory holds before the chip writes it.
const STALE_BYTE = 0xA5;

const Stepping = struct {
    var chip: ?*Chip = null;

    pub fn publish() void {
        if (chip) |model| model.moveOn();
    }

    pub fn consume() void {
        if (chip) |model| model.moveOn();
    }
};

/// What arrives, and how often: a share of this table each.
const Arrival = enum {
    faulty,
    long,
    full,
    short,
    /// The largest record the room left takes.
    fill,
};
const ARRIVALS = [_]Arrival{ .faulty, .long, .fill } ++ [_]Arrival{.full} ** 2 ++ [_]Arrival{.short} ** 11;

/// The status bits that mark a frame broken.
const Fault = enum { frame_align, crc_error, long_frame, runt_frame, bad_symbol };

/// How much room the chip wants before it writes a record.
const Room = enum {
    /// As much as the record, filling the ring to the last byte.
    exact,
    /// More than the record, as QEMU wants, unless the ring is empty.
    spare,
};

const Copy = enum {
    /// The whole record at once, as QEMU writes it.
    whole,
    /// A piece at a time with CBR behind each, the length reading unfinished
    /// until the frame is in.
    pieces,
};

/// Whether CBR passes a record's padding before or after its header is
/// written final.
const Padding = enum { before_header, after_header };

/// A record the chip wrote and the host has not given back.
const Written = struct {
    at: Position,
    header: Header,
    kind: Kind,
    /// Bytes of it CBR has passed.
    published: usize = 0,
    /// Whether the header holds the length yet.
    length: enum { unfinished, final } = .unfinished,
    taken: bool = false,

    const Kind = union(enum) {
        frame: u32,
        /// A length no record can have.
        garbage,
    };

    fn bytes(self: Written) usize {
        return switch (self.kind) {
            .frame => std.mem.alignForward(usize, @sizeOf(Header) + @intFromEnum(self.header.length), ALIGN),
            .garbage => @sizeOf(Header),
        };
    }

    fn frame(self: Written) usize {
        return @as(usize, @intFromEnum(self.header.length)) - FCS;
    }

    fn end(self: Written) Position {
        var after = self.at;
        after.advance(self.bytes());
        return after;
    }
};

/// What the chip puts at byte `index` of frame `id`.
fn pattern(id: u32, index: usize) u8 {
    return @truncate(id *% 131 +% index);
}

const Chip = struct {
    from: Choices,
    memory: *[MEMORY]u8,
    room: Room,
    copy: Copy,
    padding: Padding,

    /// Oldest first.
    records: [RECORDS]Written = undefined,
    first: cursor.Cursor(RECORDS) = .{},
    count: usize = 0,
    /// Where the host reads next, from CAPR.
    read_at: Position = .{},
    /// Bytes CBR has passed from `read_at`.
    published: usize = 0,
    /// The same, as of the host's last read of CBR, less what it has given
    /// back since.
    seen: usize = 0,
    state: enum { receiving, broken } = .receiving,
    arriving: bool = true,
    next_id: u32 = 1,
    fault: ?[]const u8 = null,

    fn moveOn(self: *Chip) void {
        var steps: usize = 0;
        while (steps < 3 and self.from.odds(2)) : (steps += 1) self.step();
    }

    fn step(self: *Chip) void {
        if (self.copying()) return self.copyOn();
        if (self.from.odds(2)) self.arrive();
    }

    fn nth(self: *Chip, index: usize) *Written {
        var at = self.first;
        at.advance(index);
        return &self.records[at.at];
    }

    fn newest(self: *Chip) *Written {
        return self.nth(self.count - 1);
    }

    fn copying(self: *Chip) bool {
        if (self.count == 0) return false;
        const last = self.newest();
        return last.length == .unfinished or last.published < last.bytes();
    }

    fn used(self: *Chip) usize {
        var total: usize = 0;
        for (0..self.count) |index| total += self.nth(index).bytes();
        return total;
    }

    fn writeAt(self: *Chip) Position {
        var at = self.read_at;
        at.advance(self.used());
        return at;
    }

    fn fits(self: *Chip, bytes: usize) bool {
        const taken = self.used();
        const free = Modelled.RING - taken;
        return switch (self.room) {
            .exact => bytes <= free,
            .spare => taken == 0 or bytes < free,
        };
    }

    fn push(self: *Chip, record: Written) void {
        var at = self.first;
        at.advance(self.count);
        self.records[at.at] = record;
        self.count += 1;
    }

    fn arrive(self: *Chip) void {
        if (!self.arriving or self.state == .broken or self.copying()) return;
        if (self.from.odds(48)) return self.breakSync();

        var header: Header = .{ .ok = true, .broadcast = self.from.odds(4) };
        const frame: usize = switch (ARRIVALS[self.from.below(ARRIVALS.len)]) {
            .faulty => blk: {
                header.ok = self.from.odds(2);
                switch (self.from.one(Fault)) {
                    inline else => |fault| @field(header, @tagName(fault)) = true,
                }
                break :blk self.from.below(MAX_FRAME + 1);
            },
            .long => MAX_FRAME + 1 + self.from.below(LONG_FRAME - MAX_FRAME),
            .full => 14 + self.from.below(MAX_FRAME - 14 + 1),
            .short => 14 + self.from.below(100),
            .fill => blk: {
                const free = Modelled.RING - self.used();
                const largest = switch (self.room) {
                    .exact => free,
                    .spare => free -| ALIGN,
                };
                if (largest < @sizeOf(Header) + FCS or largest > @sizeOf(Header) + LONG_FRAME + FCS) return;
                break :blk largest - @sizeOf(Header) - FCS;
            },
        };
        header.length = .of(@intCast(frame + FCS));

        const record = Written{ .at = self.writeAt(), .header = header, .kind = .{ .frame = self.next_id } };
        if (!self.fits(record.bytes())) return;
        self.next_id += 1;
        self.push(record);

        switch (self.copy) {
            .whole => {
                self.writeWire(self.newest(), @sizeOf(Header), record.bytes());
                self.finish();
                self.pass(record.bytes());
            },
            .pieces => {},
        }
    }

    /// A header with a length no record can have.
    fn breakSync(self: *Chip) void {
        if (!self.fits(@sizeOf(Header))) return;
        const past_area = Modelled.AREA - @sizeOf(Header) + 1;
        const unfinished = @intFromEnum(Header.Length.unfinished);
        const wire = if (self.from.odds(2))
            self.from.below(FCS)
        else
            past_area + self.from.below(unfinished - past_area);
        const record = Written{
            .at = self.writeAt(),
            .header = .{ .ok = self.from.odds(2), .length = .of(@intCast(wire)) },
            .kind = .garbage,
            .length = .final,
        };
        self.push(record);
        self.writeHeader(record.at, record.header);
        self.pass(@sizeOf(Header));
        self.state = .broken;
    }

    /// The next step of a copy under way.
    fn copyOn(self: *Chip) void {
        const last = self.newest();
        const wire_end = @sizeOf(Header) + @intFromEnum(last.header.length);
        const padding = last.published < last.bytes();
        if (last.published < wire_end) {
            const piece = 1 + self.from.below(wire_end - last.published);
            self.writeWire(last, last.published, last.published + piece);
            self.pass(piece);
        } else if (padding and (self.padding == .before_header or last.length == .final)) {
            self.pass(last.bytes() - last.published);
        } else if (last.length == .unfinished) {
            self.finish();
        }
    }

    /// Bytes `from` up to `to` of a record, with the header reading
    /// unfinished.
    fn writeWire(self: *Chip, record: *const Written, from: usize, to: usize) void {
        var unfinished: [@sizeOf(Header)]u8 = undefined;
        std.mem.writeInt(u32, &unfinished, @bitCast(Header{ .length = .unfinished }), .little);
        const wire_end = @sizeOf(Header) + @intFromEnum(record.header.length);
        for (from..@min(to, wire_end)) |offset| {
            self.memory[record.at.at + offset] = if (offset < @sizeOf(Header))
                unfinished[offset]
            else if (offset - @sizeOf(Header) < record.frame())
                pattern(record.kind.frame, offset - @sizeOf(Header))
            else
                CHECK_BYTE;
        }
    }

    fn finish(self: *Chip) void {
        const last = self.newest();
        self.writeHeader(last.at, last.header);
        last.length = .final;
    }

    fn writeHeader(self: *Chip, at: Position, header: Header) void {
        std.mem.writeInt(u32, self.memory[at.at..][0..@sizeOf(Header)], @bitCast(header), .little);
    }

    /// CBR moves on over bytes of the newest record.
    fn pass(self: *Chip, bytes: usize) void {
        self.newest().published += bytes;
        self.published += bytes;
    }

    fn fail(self: *Chip, why: []const u8) void {
        if (self.fault == null) self.fault = why;
    }

    // The registers, with the chip free to move at each.

    pub fn empty(self: *Chip) bool {
        self.moveOn();
        return self.published == 0;
    }

    pub fn written(self: *Chip) u16 {
        self.moveOn();
        self.seen = self.published;
        var cbr = self.read_at;
        cbr.advance(self.published);
        // Only meaningful modulo the ring, so any lap of it will do.
        return @intCast(cbr.at + Modelled.RING * self.from.below(8));
    }

    pub fn readTo(self: *Chip, mark: u16) void {
        const to = cursor.wrapped(@as(usize, mark) + CAPR_LAG, Modelled.RING);
        if (self.count == 0) return self.fail("CAPR moved with nothing written");
        const oldest = self.nth(0);
        if (!oldest.taken) return self.fail("CAPR moved past a record that was not taken");
        if (oldest.end().at != to) return self.fail("CAPR moved somewhere other than the end of the record taken");
        self.read_at = oldest.end();
        self.published -= oldest.bytes();
        self.seen -|= oldest.bytes();
        self.first.next();
        self.count -= 1;
        self.moveOn();
    }

    fn deliver(self: *Chip, frame: ?[]const u8) void {
        var ahead: usize = 0;
        const next = for (0..self.count) |index| {
            const candidate = self.nth(index);
            if (!candidate.taken) break candidate;
            ahead += candidate.bytes();
        } else return self.fail("a record was taken that the chip never wrote");

        const id = switch (next.kind) {
            .frame => |id| id,
            .garbage => return self.fail("a record with a length no record has was taken"),
        };
        if (next.length == .unfinished) return self.fail("a record was taken before its length was written");
        if (ahead + next.bytes() > self.seen) return self.fail("a record was taken before CBR passed it");
        next.taken = true;

        const good = next.header.good(next.frame());
        const taken = frame orelse {
            if (good) self.fail("a whole frame was stepped over");
            return;
        };
        if (!good) return self.fail("a record the chip marked bad was taken as a frame");
        if (taken.len != next.frame()) return self.fail("a frame was taken at the wrong length");
        for (taken, 0..) |byte, index| {
            if (byte != pattern(id, index)) return self.fail("a frame was taken with bytes the chip did not write");
        }
    }

    /// What `recoverRx` does: the receiver back at the start of the ring,
    /// and everything written before it discarded.
    fn restart(self: *Chip, receiver: *Modelled) void {
        receiver.restart();
        if (cursor.wrapped(@as(usize, receiver.mark()) + CAPR_LAG, Modelled.RING) != 0) {
            return self.fail("a restarted ring's CAPR is not the start of the ring");
        }
        self.first = .{};
        self.count = 0;
        self.read_at = .{};
        self.published = 0;
        self.seen = 0;
        self.state = .receiving;
    }

    fn lost(self: *Chip, receiver: *Modelled) void {
        if (self.state != .broken) return self.fail("a pass lost its place in a ring the chip wrote correctly");
        const next = for (0..self.count) |index| {
            if (!self.nth(index).taken) break self.nth(index);
        } else return self.fail("a pass lost its place with every record taken");
        if (next.kind != .garbage) return self.fail("a pass lost its place before the record that has no length");
        self.restart(receiver);
    }
};

fn runRing(from: Choices) anyerror!void {
    var memory: [MEMORY]u8 = @splat(STALE_BYTE);
    var chip = Chip{
        .from = from,
        .memory = &memory,
        .room = from.one(Room),
        .copy = from.one(Copy),
        .padding = from.one(Padding),
    };
    var receiver = Modelled{ .area = memory[0..Modelled.AREA] };

    Stepping.chip = &chip;
    defer Stepping.chip = null;

    for (0..from.upTo(200)) |_| {
        switch (from.one(enum { arrive, step, take, overflow })) {
            .arrive => chip.arrive(),
            .step => chip.step(),
            .take => switch (receiver.take(from.upTo(12), &chip, &chip, Chip.deliver)) {
                .ok => {},
                .lost => chip.lost(&receiver),
            },
            // What the driver does when the chip says its FIFO overflowed.
            .overflow => if (from.odds(8)) chip.restart(&receiver),
        }
        if (chip.fault) |why| return fail(why);
    }

    // Nothing more arrives and the copy under way finishes. Every record is
    // taken.
    chip.arriving = false;
    while (chip.copying()) chip.copyOn();
    for (0..2) |_| {
        switch (receiver.take(RECORDS, &chip, &chip, Chip.deliver)) {
            .ok => {},
            .lost => chip.lost(&receiver),
        }
        if (chip.fault) |why| return fail(why);
    }
    try testing.expectEqual(@as(usize, 0), chip.count);
    try testing.expectEqual(@as(usize, 0), chip.published);
    try testing.expectEqual(chip.read_at.at, receiver.at.at);
}

fn fail(why: []const u8) error{TestUnexpectedResult} {
    std.debug.print("model: {s}\n", .{why});
    return error.TestUnexpectedResult;
}

test "fuzz: each record is taken once and in order, whatever the chip does when" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            return runRing(.{ .fuzzer = smith });
        }
    };
    try std.testing.fuzz({}, Target.one, .{});
}

test "the receive ring against a modelled chip, at random" {
    try fuzzing.seeded(runRing, 0x8139_0F00, 1500);
}
