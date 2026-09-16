//! The PRO/100's two rings as the host keeps them: what it takes from each,
//! where the receiver's fence stands, and when a stopped unit is started
//! again.
//!
//! Pure over the ring memory. `Barrier` orders the host against the part:
//! `publish` after each write the part may see, `consume` before reading
//! what it wrote. The tests drive both rings against a model of the part
//! that takes its steps at exactly those points.

const std = @import("std");
const cursor = @import("../cursor.zig");
const regs = @import("regs.zig");

/// The receive ring.
///
/// The receiver walks the descriptors in order and stops at the fence: a
/// descriptor with no room and the end of the list, standing just behind
/// the oldest one the host has not taken. So it can never write over a
/// frame the host still holds, and when it has stopped, every frame it
/// wrote is behind the fence and the first descriptor not taken is where it
/// goes on.
pub fn Receiver(comptime slots: usize, comptime Barrier: type) type {
    return struct {
        const Self = @This();

        descriptors: *[slots]regs.Receive,
        /// The oldest descriptor not yet taken.
        next: cursor.Cursor(slots) = .{},

        /// Every descriptor empty with room, and the fence before the
        /// first. The links are the caller's: they are addresses.
        pub fn reset(self: *Self) void {
            self.next = .{};
            for (self.descriptors) |*descriptor| {
                descriptor.header.status = .{};
                descriptor.header.command = .{};
                descriptor.count = .{};
                descriptor.size = .{ .bytes = regs.FRAME_BYTES };
            }
            Barrier.publish();
            self.raise(slots - 1);
        }

        /// Take up to `budget` frames the receiver has finished, handing
        /// each to `deliver`: the frame, or null for one the part marked bad
        /// or measured past its room. Then move the fence up behind them.
        pub fn take(
            self: *Self,
            budget: usize,
            context: anytype,
            comptime deliver: fn (@TypeOf(context), ?[]const u8) void,
        ) void {
            const first = self.next;
            var taken: usize = 0;
            while (taken < budget) : (taken += 1) {
                const descriptor = &self.descriptors[self.next.at];
                Barrier.consume();
                const status = @as(*const volatile regs.BlockStatus, &descriptor.header.status).*;
                if (!status.complete) break;

                const count = @as(*const volatile regs.ReceiveCount, &descriptor.count).*;
                const whole = status.ok and count.bytes <= regs.FRAME_BYTES;
                deliver(context, if (whole) descriptor.frame[0..count.bytes] else null);

                descriptor.count = .{};
                descriptor.header.status = .{};
                Barrier.publish();
                self.next.next();
            }

            // The new fence goes up before the old one comes down, so the
            // receiver always has one to stop at.
            const old = behind(first);
            const new = behind(self.next);
            if (old == new) return;
            self.raise(new);
            self.lower(old);
        }

        /// Where to start a receiver in `state` again: nowhere while it
        /// runs, and nowhere until every frame it finished has been taken.
        pub fn restartAt(self: *const Self, state: regs.ReceiverState) ?usize {
            switch (state) {
                .idle, .suspended, .no_resources => {},
                .ready, _ => return null,
            }
            Barrier.consume();
            const status = @as(*const volatile regs.BlockStatus, &self.descriptors[self.next.at].header.status).*;
            return if (status.complete) null else self.next.at;
        }

        fn behind(at: cursor.Cursor(slots)) usize {
            var earlier = at;
            earlier.advance(slots - 1);
            return earlier.at;
        }

        /// No room, then the end of the list. Raised only where the receiver
        /// cannot be: behind the fence that still stands.
        fn raise(self: *Self, slot: usize) void {
            const descriptor = &self.descriptors[slot];
            descriptor.size = .{};
            Barrier.publish();
            descriptor.header.command.end_of_list = true;
            Barrier.publish();
        }

        /// Room, then the list goes on. A receiver that reads the descriptor
        /// between the two takes a frame into it and stops, and the host
        /// starts it again after taking that frame.
        fn lower(self: *Self, slot: usize) void {
            const descriptor = &self.descriptors[slot];
            descriptor.size = .{ .bytes = regs.FRAME_BYTES };
            Barrier.publish();
            descriptor.header.command.end_of_list = false;
            Barrier.publish();
        }
    };
}

/// What a command block carries.
pub const Fill = union(enum) {
    configure: regs.Configuration,
    address: [6]u8,
    frame: []const u8,

    fn operation(self: Fill) regs.Operation {
        return switch (self) {
            .configure => .configure,
            .address => .individual_address,
            .frame => .transmit,
        };
    }
};

/// The command block ring.
///
/// The command unit runs blocks in order and suspends after one marked to
/// suspend, which is always the newest. A block appended behind it is
/// marked before the one before stops being, so the unit either runs on to
/// it or suspends where it was; it is resumed only when it is seen
/// suspended behind a block it has not run.
pub fn Transmitter(comptime slots: usize, comptime Barrier: type) type {
    return struct {
        const Self = @This();

        blocks: *[slots]regs.Block,
        /// The next block to fill.
        next: cursor.Cursor(slots) = .{},
        /// The oldest block not yet seen complete.
        clean: cursor.Cursor(slots) = .{},

        /// Every block empty. The links are the caller's.
        pub fn reset(self: *Self) void {
            self.next = .{};
            self.clean = .{};
            for (self.blocks) |*block| {
                block.header.status = .{};
                block.header.command = .{};
            }
            Barrier.publish();
        }

        /// Fill the next block and put it behind the one before; false when
        /// the ring has no room.
        pub fn append(self: *Self, fill: Fill) bool {
            if (self.next.room(self.clean.at) == 0) return false;
            const block = &self.blocks[self.next.at];

            switch (fill) {
                .configure => |configuration| block.body.configure = configuration.bytes(),
                .address => |mac| block.body.address = mac,
                .frame => |frame| {
                    block.body.transmit.transmit = .{ .count = .{ .bytes = @intCast(frame.len), .whole = true } };
                    @memcpy(block.body.transmit.frame[0..frame.len], frame);
                },
            }
            block.header.status = .{};
            block.header.command = .{ .operation = fill.operation(), .@"suspend" = true };
            Barrier.publish();

            var previous = self.next;
            previous.advance(slots - 1);
            self.blocks[previous.at].header.command.@"suspend" = false;
            Barrier.publish();

            self.next.next();
            return true;
        }

        /// Count off the blocks the unit has finished, calling `failed` for
        /// each one the part says did not go.
        pub fn reap(self: *Self, context: anytype, comptime failed: fn (@TypeOf(context)) void) void {
            var outstanding = self.next.used(self.clean.at);
            while (outstanding > 0) : (outstanding -= 1) {
                Barrier.consume();
                const status = @as(*const volatile regs.BlockStatus, &self.blocks[self.clean.at].header.status).*;
                if (!status.complete) break;
                if (!status.ok) failed(context);
                self.clean.next();
            }
        }

        /// Whether a unit in `state` must be resumed: it is suspended behind
        /// a block it has not run.
        pub fn waiting(
            self: *Self,
            state: regs.CommandUnitState,
            context: anytype,
            comptime failed: fn (@TypeOf(context)) void,
        ) bool {
            if (state != .suspended) return false;
            self.reap(context, failed);
            return self.next.used(self.clean.at) > 0;
        }
    };
}

/// Start again whatever stopped for want of the host, one command per look.
///
/// `part` says whether the part has taken its last command, reads its
/// status, and gives it `startReceiver(slot)` or `resumeCommandUnit()`.
/// Nothing is decided while a command waits: a unit about to be resumed or
/// a receiver about to be started still reads as stopped. With none
/// waiting, a unit seen suspended stays suspended and a receiver seen
/// stopped stays stopped, so the rings cannot move under the answer.
pub fn keepRunning(
    receiver: anytype,
    transmitter: anytype,
    part: anytype,
    context: anytype,
    comptime failed: fn (@TypeOf(context)) void,
) void {
    if (!part.accepted()) return;
    const status: regs.Status = part.status();
    if (receiver.restartAt(status.receiver)) |slot| return part.startReceiver(slot);
    if (transmitter.waiting(status.command_unit, context, failed)) part.resumeCommandUnit();
}

// ---------------------------------------------------------------------------
// Tests: both rings against a model of the part
// ---------------------------------------------------------------------------
//
// The model takes its steps at the barriers, where the host's writes become
// the part's to see, and between the host's reads of its registers. It
// holds one command at a time, as the part does, and takes it at a step of
// its choosing. It runs in each of the ways a part can read the fence and
// the suspend bit, and a fault it records is a promise above broken.

const lib = @import("lib");
const fuzzing = lib.fuzzing;
const Choices = fuzzing.Choices;
const testing = std.testing;

/// Small rings, so laps, fences and a full ring come often.
const SLOTS = 6;

/// Where the barriers reach the model running now.
const Stepping = struct {
    var model: ?*Model = null;

    pub fn publish() void {
        if (model) |part| part.moveOn();
    }

    pub fn consume() void {
        if (model) |part| part.moveOn();
    }
};

/// Frames the part wrote and the host has not taken, oldest first: an id,
/// or none for a descriptor the part finished empty.
const Written = struct {
    items: [SLOTS + 1]?u32 = undefined,
    head: usize = 0,
    len: usize = 0,

    fn push(self: *Written, item: ?u32) void {
        self.items[(self.head + self.len) % self.items.len] = item;
        self.len += 1;
    }

    fn pop(self: *Written) ??u32 {
        if (self.len == 0) return null;
        const item = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        return item;
    }
};

const Model = struct {
    from: Choices,
    descriptors: *[SLOTS]regs.Receive,
    blocks: *[SLOTS]regs.Block,
    /// The emulator finishes the fence empty before it stops; the part
    /// stops at it without a word.
    fence_finishes: bool,
    /// A part that looks at the suspend bit again when resumed, rather
    /// than running whatever the link names.
    resume_looks_again: bool,
    /// A part that reads the suspend bit as it begins a block rather than
    /// as it finishes one.
    suspend_read_first: bool,

    receiver: regs.ReceiverState = .ready,
    rx_at: usize = 0,
    written: Written = .{},
    next_frame: u32 = 1,
    arriving: bool = true,

    unit: regs.CommandUnitState = .idle,
    tx_at: usize = 0,
    /// The suspend bit as the unit began the block it is running.
    begun: ?bool = null,
    ran: [256]u32 = undefined,
    ran_count: usize = 0,

    /// The command the host gave that the part has not taken.
    command: ?Command = null,
    fault: ?[]const u8 = null,

    const Command = union(enum) {
        start_receiver: usize,
        start_unit: usize,
        resume_unit,
    };

    /// However far the part gets while the host is not looking.
    fn moveOn(self: *Model) void {
        var steps: usize = 0;
        while (steps < 4 and self.from.odds(2)) : (steps += 1) self.step();
    }

    fn step(self: *Model) void {
        switch (self.from.one(enum { take_command, receive, run })) {
            .take_command => self.takeCommand(),
            .receive => if (self.arriving) self.arrive(),
            .run => self.run(),
        }
    }

    fn takeCommand(self: *Model) void {
        const command = self.command orelse return;
        self.command = null;
        switch (command) {
            .start_receiver => |slot| {
                self.receiver = .ready;
                self.rx_at = slot;
            },
            .start_unit => |slot| {
                self.unit = .active;
                self.tx_at = slot;
            },
            .resume_unit => if (self.unit == .suspended) {
                const held = self.blocks[self.tx_at].header.command.@"suspend";
                if (!(self.resume_looks_again and held)) {
                    self.unit = .active;
                    self.tx_at = (self.tx_at + 1) % SLOTS;
                }
            },
        }
    }

    fn arrive(self: *Model) void {
        if (self.receiver != .ready) return;
        const descriptor = &self.descriptors[self.rx_at];
        if (descriptor.header.status.complete) {
            self.fault = "the receiver reached a descriptor still holding a frame";
            return;
        }
        const last = descriptor.header.command.end_of_list;
        if (descriptor.size.bytes == 0) {
            if (!last) {
                self.fault = "the receiver reached a descriptor with no room that is not a fence";
                return;
            }
            if (self.fence_finishes) {
                descriptor.count = .{};
                descriptor.header.status = .{ .complete = true, .ok = true };
                self.written.push(null);
            }
            self.receiver = .no_resources;
            return;
        }

        std.mem.writeInt(u32, descriptor.frame[0..4], self.next_frame, .little);
        descriptor.count = .{ .bytes = @intCast(4 + self.from.below(60)), .filled = true, .end_of_frame = true };
        descriptor.header.status = .{ .complete = true, .ok = true };
        self.written.push(self.next_frame);
        self.next_frame += 1;
        if (last) {
            self.receiver = .no_resources;
        } else {
            self.rx_at = (self.rx_at + 1) % SLOTS;
        }
    }

    fn run(self: *Model) void {
        if (self.unit != .active) return;
        const block = &self.blocks[self.tx_at];
        const began = self.begun orelse {
            if (block.header.status.complete) {
                self.fault = "the command unit ran a block a second time";
                return;
            }
            if (block.header.command.operation == .nop) {
                self.fault = "the command unit ran a block nobody filled";
                return;
            }
            self.begun = block.header.command.@"suspend";
            return;
        };
        self.begun = null;

        if (self.ran_count == self.ran.len) {
            self.fault = "the command unit ran more blocks than were filled";
            return;
        }
        self.ran[self.ran_count] = switch (block.header.command.operation) {
            .transmit => std.mem.readInt(u32, block.body.transmit.frame[0..4], .little),
            else => 0,
        };
        self.ran_count += 1;
        block.header.status = .{ .complete = true, .ok = true };

        const stops = if (self.suspend_read_first) began else block.header.command.@"suspend";
        if (stops) {
            self.unit = .suspended;
        } else {
            self.tx_at = (self.tx_at + 1) % SLOTS;
        }
    }

    // What the driver reads and gives, with the part free to move between.

    pub fn accepted(self: *Model) bool {
        return self.command == null;
    }

    pub fn status(self: *Model) regs.Status {
        self.moveOn();
        return .{ .receiver = self.receiver, .command_unit = self.unit };
    }

    pub fn startReceiver(self: *Model, slot: usize) void {
        self.command = .{ .start_receiver = slot };
    }

    pub fn resumeCommandUnit(self: *Model) void {
        self.command = .resume_unit;
    }

    fn deliver(self: *Model, frame: ?[]const u8) void {
        const expected = self.written.pop() orelse {
            self.fault = "a frame was taken that the part never wrote";
            return;
        };
        const taken = frame orelse {
            self.fault = "a good frame was taken as a bad one";
            return;
        };
        if (expected) |id| {
            if (taken.len < 4 or std.mem.readInt(u32, taken[0..4], .little) != id) {
                self.fault = "a frame was taken out of order";
            }
        } else if (taken.len != 0) {
            self.fault = "an empty descriptor was taken as a frame";
        }
    }

    fn failed(_: *Model) void {}
};

fn runPart(from: Choices) anyerror!void {
    var descriptors: [SLOTS]regs.Receive = undefined;
    var blocks: [SLOTS]regs.Block = undefined;
    var model = Model{
        .from = from,
        .descriptors = &descriptors,
        .blocks = &blocks,
        .fence_finishes = from.odds(2),
        .resume_looks_again = from.odds(2),
        .suspend_read_first = from.odds(2),
    };
    var receiver = Receiver(SLOTS, Stepping){ .descriptors = &descriptors };
    var transmitter = Transmitter(SLOTS, Stepping){ .blocks = &blocks };
    receiver.reset();
    transmitter.reset();

    Stepping.model = &model;
    defer Stepping.model = null;

    var sent: [256]u32 = undefined;
    var sent_count: usize = 0;
    for ([_]Fill{ .{ .configure = .{} }, .{ .address = @splat(0x02) } }) |fill| {
        _ = transmitter.append(fill);
        sent[sent_count] = 0;
        sent_count += 1;
    }
    model.command = .{ .start_unit = 0 };

    for (0..from.upTo(150)) |_| {
        switch (from.one(enum { arrive, take, send, step, keep })) {
            .arrive => model.arrive(),
            .take => receiver.take(from.upTo(SLOTS + 2), &model, Model.deliver),
            .send => if (sent_count < sent.len) {
                const id: u32 = @intCast(sent_count);
                var frame: [4]u8 = undefined;
                std.mem.writeInt(u32, &frame, id, .little);
                if (transmitter.append(.{ .frame = &frame })) {
                    sent[sent_count] = id;
                    sent_count += 1;
                    keepRunning(&receiver, &transmitter, &model, &model, Model.failed);
                }
            },
            .step => model.step(),
            .keep => keepRunning(&receiver, &transmitter, &model, &model, Model.failed),
        }
        if (model.fault) |why| return fail(why);
    }

    // Nothing more arrives or is sent. Every frame written is taken and
    // every block filled is run, once and in order.
    model.arriving = false;
    for (0..SLOTS * 16) |_| {
        model.takeCommand();
        model.run();
        receiver.take(SLOTS, &model, Model.deliver);
        keepRunning(&receiver, &transmitter, &model, &model, Model.failed);
        if (model.fault) |why| return fail(why);
    }
    try testing.expectEqual(@as(usize, 0), model.written.len);
    try testing.expectEqualSlices(u32, sent[0..sent_count], model.ran[0..model.ran_count]);

    // And the receiver is running: the next frame to arrive is written.
    model.takeCommand();
    model.arriving = true;
    model.arrive();
    if (model.fault) |why| return fail(why);
    try testing.expectEqual(@as(usize, 1), model.written.len);
}

fn fail(why: []const u8) error{TestUnexpectedResult} {
    std.debug.print("model: {s}\n", .{why});
    return error.TestUnexpectedResult;
}

test "fuzz: both rings take and run everything once, in order, whatever the part does when" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            return runPart(.{ .fuzzer = smith });
        }
    };
    try std.testing.fuzz({}, Target.one, .{});
}

test "both rings against a modelled part, at random" {
    try fuzzing.seeded(runPart, 0xE100_0F00, 4000);
}
