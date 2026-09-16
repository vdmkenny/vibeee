//! The 82540's legacy descriptor rings, as the host keeps them.
//!
//! Receive: the part fills descriptors from RDH up to, not including, RDT,
//! and sets DD on each once its frame is in. The host takes a finished
//! descriptor, clears it, and writes its slot to RDT. RDT then stays one
//! slot behind the oldest descriptor not taken, so the part never reaches a
//! descriptor the host holds.
//!
//! Transmit: the host fills the descriptor at its next slot and writes the
//! slot after it to TDT. The part sends from TDH up to TDT and sets DD on
//! each descriptor it has finished. One slot stays empty so a full ring is
//! not an empty one.
//!
//! Pure over the ring memory. `Barrier` orders the host against the part:
//! `publish` after each write the part may see, `consume` before reading
//! what it wrote. The tests drive both rings against a model of the part
//! that moves at those points and at every register write.

const std = @import("std");
const cursor = @import("../cursor.zig");

/// Every buffer a descriptor names, and the most a descriptor may say was
/// written into one.
pub const BUFFER_BYTES = 2048;

pub const RxStatus = packed struct(u8) {
    done: bool = false,
    end_of_packet: bool = false,
    ignore_checksum: bool = false,
    vlan: bool = false,
    udp_checksum: bool = false,
    tcp_checksum: bool = false,
    ip_checksum: bool = false,
    passed_inexact: bool = false,
};

pub const RxErrors = packed struct(u8) {
    crc: bool = false,
    symbol: bool = false,
    sequence: bool = false,
    _3: u1 = 0,
    carrier_extension: bool = false,
    transport_checksum: bool = false,
    ip_checksum: bool = false,
    data: bool = false,

    pub fn any(self: RxErrors) bool {
        return self.crc or self.symbol or self.sequence or self.carrier_extension or
            self.transport_checksum or self.ip_checksum or self.data;
    }
};

pub const TxCommand = packed struct(u8) {
    end_of_packet: bool = false,
    insert_fcs: bool = false,
    insert_checksum: bool = false,
    report_status: bool = false,
    report_packet_sent: bool = false,
    extended: bool = false,
    vlan: bool = false,
    interrupt_delay: bool = false,
};

pub const TxStatus = packed struct(u8) {
    done: bool = false,
    excessive_collisions: bool = false,
    late_collision: bool = false,
    underrun: bool = false,
    _4: u4 = 0,

    pub fn failed(self: TxStatus) bool {
        return self.excessive_collisions or self.late_collision or self.underrun;
    }
};

/// A whole frame, with the check sequence added and its status reported.
pub const SEND = TxCommand{
    .end_of_packet = true,
    .insert_fcs = true,
    .report_status = true,
};

/// The legacy receive descriptor.
pub const RxDesc = extern struct {
    addr_low: u32 = 0,
    addr_high: u32 = 0,
    length: u16 = 0,
    checksum: u16 = 0,
    status: RxStatus = .{},
    errors: RxErrors = .{},
    special: u16 = 0,
};

/// The legacy transmit descriptor.
pub const TxDesc = extern struct {
    addr_low: u32 = 0,
    addr_high: u32 = 0,
    length: u16 = 0,
    checksum_offset: u8 = 0,
    command: TxCommand = .{},
    status: TxStatus = .{},
    checksum_start: u8 = 0,
    special: u16 = 0,
};

comptime {
    if (@sizeOf(RxDesc) != 16 or @sizeOf(TxDesc) != 16) {
        @compileError("an 82540 descriptor is sixteen bytes, whichever way");
    }
    if (@offsetOf(RxDesc, "status") != 12 or @offsetOf(TxDesc, "status") != 12) {
        @compileError("descriptor writeback status must begin at byte twelve");
    }
}

pub fn Receiver(comptime slots: usize, comptime Barrier: type) type {
    return struct {
        const Self = @This();

        descriptors: *[slots]RxDesc,
        buffers: *[slots][BUFFER_BYTES]u8,
        /// The oldest descriptor not yet taken.
        next: cursor.Cursor(slots) = .{},

        /// Where RDT starts: every descriptor but the last is the part's.
        pub const TAIL = slots - 1;

        /// Take up to `budget` finished descriptors, handing each to
        /// `deliver`: the frame, or null for one the part marked bad or
        /// measured past its buffer. Each is cleared and given back through
        /// `part.handBack(slot)`, which writes RDT.
        pub fn take(
            self: *Self,
            budget: usize,
            part: anytype,
            context: anytype,
            comptime deliver: fn (@TypeOf(context), ?[]const u8) void,
        ) void {
            var taken: usize = 0;
            while (taken < budget) : (taken += 1) {
                const slot = self.next.at;
                const descriptor = &self.descriptors[slot];
                if (!@as(*const volatile RxStatus, &descriptor.status).done) break;
                Barrier.consume();

                const status = @as(*const volatile RxStatus, &descriptor.status).*;
                const length = @as(*const volatile u16, &descriptor.length).*;
                const errors = @as(*const volatile RxErrors, &descriptor.errors).*;
                const whole = status.end_of_packet and !errors.any() and length <= BUFFER_BYTES;
                deliver(context, if (whole) self.buffers[slot][0..length] else null);

                descriptor.length = 0;
                descriptor.checksum = 0;
                descriptor.errors = .{};
                descriptor.special = 0;
                descriptor.status = .{};
                Barrier.publish();
                self.next.next();
                // The slot just cleared, not the cursor: RDT on the cursor
                // puts head on tail once every frame is taken, and the part
                // stops.
                part.handBack(slot);
            }
        }
    };
}

pub fn Transmitter(comptime slots: usize, comptime Barrier: type) type {
    return struct {
        const Self = @This();

        descriptors: *[slots]TxDesc,
        buffers: *[slots][BUFFER_BYTES]u8,
        /// The next descriptor to fill.
        next: cursor.Cursor(slots) = .{},
        /// The oldest descriptor not yet seen sent.
        clean: cursor.Cursor(slots) = .{},

        /// Count off the descriptors the part has sent, calling `failed` for
        /// each it says did not go.
        pub fn reap(self: *Self, context: anytype, comptime failed: fn (@TypeOf(context)) void) void {
            var outstanding = self.next.used(self.clean.at);
            while (outstanding > 0) : (outstanding -= 1) {
                const descriptor = &self.descriptors[self.clean.at];
                if (!@as(*const volatile TxStatus, &descriptor.status).done) break;
                Barrier.consume();
                const status = @as(*const volatile TxStatus, &descriptor.status).*;
                if (status.failed()) failed(context);
                self.clean.next();
            }
        }

        /// Fill the next descriptor with `frame`, no longer than a buffer,
        /// and hand it over through `part.send(tail)`, which writes TDT.
        /// False when the ring has no room.
        pub fn append(self: *Self, frame: []const u8, part: anytype) bool {
            if (self.next.room(self.clean.at) == 0) return false;
            const slot = self.next.at;
            const descriptor = &self.descriptors[slot];
            if (!@as(*const volatile TxStatus, &descriptor.status).done) return false;

            @memcpy(self.buffers[slot][0..frame.len], frame);
            const address = descriptor.addr_low;
            descriptor.* = .{
                .addr_low = address,
                .length = @intCast(frame.len),
                .command = SEND,
            };
            Barrier.publish();
            self.next.next();
            // One past the last descriptor the part may send.
            part.send(self.next.at);
            return true;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const lib = @import("lib");
const testing = std.testing;

test "the writeback bytes are the manual's" {
    const byte = struct {
        fn of(value: anytype) u8 {
            return @bitCast(value);
        }
    }.of;
    try testing.expectEqual(@as(u8, 0x01), byte(RxStatus{ .done = true }));
    try testing.expectEqual(@as(u8, 0x02), byte(RxStatus{ .end_of_packet = true }));
    try testing.expectEqual(@as(u8, 0x01), byte(RxErrors{ .crc = true }));
    try testing.expectEqual(@as(u8, 0x80), byte(RxErrors{ .data = true }));
    try testing.expectEqual(@as(u8, 0x0B), byte(SEND));
    try testing.expectEqual(@as(u8, 0x02), byte(TxStatus{ .excessive_collisions = true }));
    try testing.expectEqual(@as(u8, 0x08), byte(TxStatus{ .underrun = true }));

    // Every error bit counts.
    inline for (std.meta.fields(RxErrors)) |field| {
        if (field.type == bool) {
            var errors: RxErrors = .{};
            @field(errors, field.name) = true;
            try testing.expect(errors.any());
        }
    }
    try testing.expect(!(RxErrors{}).any());
}

// ---------------------------------------------------------------------------
// Fuzzing: both rings against a model of the part
// ---------------------------------------------------------------------------
//
// The model moves at the barriers and at every register write. It receives
// into descriptors from its head up to the tail the host wrote, writing DD
// with the rest of a descriptor or in a later step, as QEMU does. It marks
// some frames bad and says of some that they are longer than their buffer.
// It sends from its head up to the host's tail and fails some sends.
//
// Checked: the part is given only descriptors the host has cleared, and
// sends only descriptors the host has filled; each frame is taken once and
// in order, whole or as bad as the part wrote it; each frame appended is
// sent once and in order; every failure the part reports is counted; and
// drained rings go on receiving and sending.

const fuzzing = lib.fuzzing;
const Choices = fuzzing.Choices;

/// Small rings, so laps and a full ring come often.
const SLOTS = 6;

const Stepping = struct {
    var part: ?*Part = null;

    pub fn publish() void {
        if (part) |model| model.moveOn();
    }

    pub fn consume() void {
        if (part) |model| model.moveOn();
    }
};

/// A frame as the part wrote it or the host appended it.
const Frame = struct {
    id: u32,
    length: u16,
};

/// What the part wrote into a descriptor, as the host must take it.
const Received = union(enum) {
    whole: Frame,
    bad,
};

/// Frames written and not taken, or appended and not sent, oldest first.
fn Fifo(comptime T: type) type {
    return struct {
        items: [SLOTS]T = undefined,
        first: cursor.Cursor(SLOTS) = .{},
        len: usize = 0,

        fn push(self: *@This(), item: T) void {
            var at = self.first;
            at.advance(self.len);
            self.items[at.at] = item;
            self.len += 1;
        }

        fn pop(self: *@This()) ?T {
            if (self.len == 0) return null;
            const item = self.items[self.first.at];
            self.first.next();
            self.len -= 1;
            return item;
        }

        fn dropNewest(self: *@This()) void {
            self.len -= 1;
        }
    };
}

/// How a frame arrives, and how often: a share of this table each.
const Arrival = enum {
    whole,
    /// With an error bit set.
    faulty,
    /// Without end of packet.
    partial,
    /// Measured past the buffer the part was given.
    overlong,
};
const ARRIVALS = [_]Arrival{ .faulty, .partial, .overlong } ++ [_]Arrival{.whole} ** 9;

const Fault = enum { crc, symbol, sequence, carrier_extension, transport_checksum, ip_checksum, data };

const SendFault = enum { excessive_collisions, late_collision, underrun };

/// When the part sets DD on a descriptor it has written.
const Done = enum {
    /// With the rest of it.
    together,
    /// In a later step.
    after,
};

/// How often the part sends when it moves.
const Pace = enum {
    brisk,
    /// Seldom enough that the transmit ring fills.
    slow,
};

const Part = struct {
    from: Choices,
    rx: *[SLOTS]RxDesc,
    rx_buffers: *[SLOTS][BUFFER_BYTES]u8,
    tx: *[SLOTS]TxDesc,
    tx_buffers: *[SLOTS][BUFFER_BYTES]u8,
    done: Done,
    pace: Pace,

    head: cursor.Cursor(SLOTS) = .{},
    tail: usize = Receiver(SLOTS, Stepping).TAIL,
    /// A descriptor written but for DD.
    writing: ?Received = null,
    written: Fifo(Received) = .{},
    arriving: bool = true,
    next_frame: u32 = 1,

    send_head: cursor.Cursor(SLOTS) = .{},
    send_tail: usize = 0,
    appended: Fifo(Frame) = .{},
    failures: usize = 0,
    counted: usize = 0,
    fault: ?[]const u8 = null,

    fn moveOn(self: *Part) void {
        var steps: usize = 0;
        while (steps < 4 and self.from.odds(2)) : (steps += 1) self.step();
    }

    fn step(self: *Part) void {
        switch (self.from.one(enum { receive, send })) {
            .receive => self.receive(),
            .send => switch (self.pace) {
                .brisk => self.sendOne(),
                .slow => if (self.from.odds(8)) self.sendOne(),
            },
        }
    }

    fn fail(self: *Part, why: []const u8) void {
        if (self.fault == null) self.fault = why;
    }

    fn receive(self: *Part) void {
        if (self.writing) |received| return self.finish(received);
        if (!self.arriving or self.head.at == self.tail) return;

        const descriptor = &self.rx[self.head.at];
        const clean = descriptor.status == RxStatus{} and descriptor.errors == RxErrors{} and
            descriptor.length == 0 and descriptor.checksum == 0 and descriptor.special == 0;
        if (!clean) return self.fail("the part was given a descriptor the host had not cleared");

        const frame = Frame{
            .id = self.next_frame,
            .length = @intCast(@sizeOf(u32) + self.from.below(BUFFER_BYTES - @sizeOf(u32) + 1)),
        };
        self.next_frame += 1;
        std.mem.writeInt(u32, self.rx_buffers[self.head.at][0..@sizeOf(u32)], frame.id, .little);
        descriptor.length = frame.length;
        descriptor.checksum = self.from.int(u16);
        descriptor.special = self.from.int(u16);
        descriptor.status = .{ .end_of_packet = true };

        var received: Received = .{ .whole = frame };
        switch (ARRIVALS[self.from.below(ARRIVALS.len)]) {
            .whole => {},
            .faulty => {
                switch (self.from.one(Fault)) {
                    inline else => |fault| @field(descriptor.errors, @tagName(fault)) = true,
                }
                received = .bad;
            },
            .partial => {
                descriptor.status.end_of_packet = false;
                received = .bad;
            },
            .overlong => {
                descriptor.length = BUFFER_BYTES + 1 + @as(u16, @intCast(self.from.below(64)));
                received = .bad;
            },
        }

        switch (self.done) {
            .together => self.finish(received),
            .after => self.writing = received,
        }
    }

    fn finish(self: *Part, received: Received) void {
        self.rx[self.head.at].status.done = true;
        self.written.push(received);
        self.writing = null;
        self.head.next();
    }

    fn sendOne(self: *Part) void {
        if (self.send_head.at == self.send_tail) return;
        const descriptor = &self.tx[self.send_head.at];
        const filled = !descriptor.status.done and descriptor.command == SEND and
            descriptor.length >= @sizeOf(u32) and descriptor.length <= BUFFER_BYTES;
        if (!filled) return self.fail("the part sent a descriptor the host had not filled");

        const sent = Frame{
            .id = std.mem.readInt(u32, self.tx_buffers[self.send_head.at][0..@sizeOf(u32)], .little),
            .length = descriptor.length,
        };
        const expected = self.appended.pop() orelse return self.fail("the part sent a frame nobody appended");
        if (!std.meta.eql(sent, expected)) return self.fail("a frame was sent out of order");

        descriptor.status = .{ .done = true };
        if (self.from.odds(6)) {
            switch (self.from.one(SendFault)) {
                inline else => |fault| @field(descriptor.status, @tagName(fault)) = true,
            }
            self.failures += 1;
        }
        self.send_head.next();
    }

    // The registers the host writes, with the part free to move after each.

    pub fn handBack(self: *Part, slot: usize) void {
        self.tail = slot;
        self.moveOn();
    }

    pub fn send(self: *Part, tail: usize) void {
        self.send_tail = tail;
        self.moveOn();
    }

    fn deliver(self: *Part, frame: ?[]const u8) void {
        const expected = self.written.pop() orelse return self.fail("a frame was taken that the part never wrote");
        switch (expected) {
            .bad => if (frame != null) self.fail("a bad frame was taken as a whole one"),
            .whole => |whole| {
                const taken = frame orelse return self.fail("a whole frame was taken as a bad one");
                if (taken.len != whole.length or std.mem.readInt(u32, taken[0..@sizeOf(u32)], .little) != whole.id) {
                    self.fail("a frame was taken out of order");
                }
            },
        }
    }

    fn failed(self: *Part) void {
        self.counted += 1;
    }
};

fn runRings(from: Choices) anyerror!void {
    var rx: [SLOTS]RxDesc = @splat(.{});
    var tx: [SLOTS]TxDesc = @splat(.{ .status = .{ .done = true } });
    var rx_buffers: [SLOTS][BUFFER_BYTES]u8 = undefined;
    var tx_buffers: [SLOTS][BUFFER_BYTES]u8 = undefined;
    var part = Part{
        .from = from,
        .rx = &rx,
        .rx_buffers = &rx_buffers,
        .tx = &tx,
        .tx_buffers = &tx_buffers,
        .done = from.one(Done),
        .pace = from.one(Pace),
    };
    var receiver = Receiver(SLOTS, Stepping){ .descriptors = &rx, .buffers = &rx_buffers };
    var transmitter = Transmitter(SLOTS, Stepping){ .descriptors = &tx, .buffers = &tx_buffers };

    Stepping.part = &part;
    defer Stepping.part = null;

    var next_sent: u32 = 1;
    for (0..from.upTo(150)) |_| {
        switch (from.one(enum { receive, take, append, reap, step })) {
            .receive => part.receive(),
            .take => receiver.take(from.upTo(SLOTS + 2), &part, &part, Part.deliver),
            .append => {
                // As the driver sends: what has gone is counted off first.
                transmitter.reap(&part, Part.failed);
                if (append(&transmitter, &part, next_sent, from)) next_sent += 1;
            },
            .reap => transmitter.reap(&part, Part.failed),
            .step => part.step(),
        }
        if (part.fault) |why| return fail(why);
    }

    // Nothing more arrives. Every frame written is taken, every frame
    // appended is sent, and every failure is counted.
    part.arriving = false;
    for (0..SLOTS * 4) |_| {
        part.receive();
        part.sendOne();
        receiver.take(SLOTS, &part, &part, Part.deliver);
        transmitter.reap(&part, Part.failed);
        if (part.fault) |why| return fail(why);
    }
    try testing.expectEqual(@as(?Received, null), part.writing);
    try testing.expectEqual(@as(usize, 0), part.written.len);
    try testing.expectEqual(@as(usize, 0), part.appended.len);
    try testing.expectEqual(part.failures, part.counted);

    // And both rings still run: the next frame is received, and the next
    // one appended is sent.
    part.arriving = true;
    part.receive();
    if (part.writing != null) part.receive();
    if (part.fault) |why| return fail(why);
    try testing.expectEqual(@as(usize, 1), part.written.len);
    try testing.expect(append(&transmitter, &part, next_sent, from));
    part.sendOne();
    if (part.fault) |why| return fail(why);
    try testing.expectEqual(@as(usize, 0), part.appended.len);
}

fn append(transmitter: *Transmitter(SLOTS, Stepping), part: *Part, id: u32, from: Choices) bool {
    var frame: [64]u8 = undefined;
    const length = @sizeOf(u32) + from.below(frame.len - @sizeOf(u32) + 1);
    std.mem.writeInt(u32, frame[0..@sizeOf(u32)], id, .little);
    // Appended before the part can see it, so a part that sends it at the
    // tail write finds it expected.
    part.appended.push(.{ .id = id, .length = @intCast(length) });
    if (transmitter.append(frame[0..length], part)) return true;
    part.appended.dropNewest();
    return false;
}

fn fail(why: []const u8) error{TestUnexpectedResult} {
    std.debug.print("model: {s}\n", .{why});
    return error.TestUnexpectedResult;
}

test "fuzz: both rings take and send everything once, in order, whatever the part does when" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            return runRings(.{ .fuzzer = smith });
        }
    };
    try std.testing.fuzz({}, Target.one, .{});
}

test "both rings against a modelled part, at random" {
    try fuzzing.seeded(runRings, 0x8254_0E00, 3000);
}
