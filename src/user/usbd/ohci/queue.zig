//! One OHCI endpoint's queue of transfer descriptors, as the host keeps it.
//!
//! The controller processes descriptors from the endpoint's head up to its
//! tail, and never the tail itself. A transfer is added by filling the tail
//! descriptor and the ones after it, linking the last to a fresh tail, and
//! then moving the tail pointer: one store, made after everything it
//! exposes is written. The descriptors are a ring used one transfer at a
//! time, so when a transfer begins every descriptor but the tail is free.
//!
//! Pure over the descriptor memory. `Barrier` orders the host against the
//! controller: `publish` after each store the controller may see, `consume`
//! before reading what it wrote. The tests drive a queue against a model of
//! the controller that takes its steps at exactly those points.

const std = @import("std");
const ohci = @import("lib").ohci;

/// One stage of a transfer: a packet or run of packets in one direction.
pub const Stage = struct {
    pid: ohci.Pid,
    toggle: ohci.Toggle,
    /// Where the stage's bytes are, as the controller addresses them.
    buffer: u32 = 0,
    length: u32 = 0,
    /// A shorter answer than the buffer ends the stage without an error.
    short_ok: bool = false,
};

/// What a finished transfer came to.
pub const Result = union(enum) {
    /// Every stage went; this many bytes moved in the stage asked about.
    moved: u32,
    /// A stage did not go, and this is why.
    failed: ohci.Outcome,
};

pub fn Queue(comptime slots: usize, comptime Barrier: type) type {
    if (slots < 2) @compileError("a queue needs a descriptor to fill and one to be its tail");

    return struct {
        const Self = @This();

        endpoint: *volatile ohci.Endpoint,
        descriptors: *volatile [slots]ohci.Transfer,
        /// Where the first descriptor is, as the controller addresses it.
        base: u32,
        /// The descriptor the endpoint's tail names.
        tail: usize = 0,
        /// The transfer last queued: its first descriptor and its stages.
        first: usize = 0,
        stages: [slots - 1]Stage = undefined,
        count: usize = 0,

        /// Nothing queued: head and tail name the same empty descriptor.
        pub fn reset(self: *Self) void {
            self.tail = 0;
            self.count = 0;
            for (self.descriptors) |*descriptor| descriptor.* = .{};
            self.endpoint.tail = self.addressOf(0);
            self.endpoint.head = .at(self.addressOf(0));
            Barrier.publish();
        }

        /// Queue `stages` as one transfer, behind whatever the endpoint was
        /// last asked for, which must have settled. The last stage asks for
        /// an interrupt at the end of its frame; a failure raises one anyway.
        pub fn append(self: *Self, stages: []const Stage) bool {
            if (stages.len == 0 or stages.len >= slots) return false;

            const first = self.tail;
            for (stages, 0..) |stage, i| {
                const at = (first + i) % slots;
                self.descriptors[at] = .{
                    .control = .{
                        .pid = stage.pid,
                        .toggle = stage.toggle,
                        .short_ok = stage.short_ok,
                        .delay = if (i + 1 == stages.len) 0 else ohci.NO_INTERRUPT,
                    },
                    .buffer = if (stage.length == 0) 0 else stage.buffer,
                    .end = if (stage.length == 0) 0 else stage.buffer + stage.length - 1,
                    .next = self.addressOf((at + 1) % slots),
                };
            }
            const tail = (first + stages.len) % slots;
            self.descriptors[tail] = .{};
            Barrier.publish();

            self.endpoint.tail = self.addressOf(tail);
            Barrier.publish();

            self.first = first;
            self.tail = tail;
            @memcpy(self.stages[0..stages.len], stages);
            self.count = stages.len;
            return true;
        }

        /// Whether the transfer has settled: the controller has taken the
        /// head up to the tail, or halted the endpoint on a failure.
        pub fn settled(self: *const Self) bool {
            Barrier.consume();
            const head = @as(*const volatile ohci.Pointer, &self.endpoint.head).*;
            return head.halted or head.physical() == self.endpoint.tail;
        }

        /// What the settled transfer came to, counting the bytes of stage
        /// `counted`.
        pub fn result(self: *const Self, counted: usize) Result {
            var moved: u32 = 0;
            for (self.stages[0..self.count], 0..) |stage, i| {
                Barrier.consume();
                const descriptor = @as(*const volatile ohci.Transfer, &self.descriptors[(self.first + i) % slots]).*;
                switch (ohci.Outcome.of(descriptor.control.condition)) {
                    .done => if (i == counted) {
                        moved = ohci.moved(descriptor.buffer, stage.buffer, stage.length);
                    },
                    // A stage the controller never reached, behind one that
                    // halted the endpoint: the failure ahead of it has been
                    // or will be seen.
                    .pending => return .{ .failed = .pending },
                    else => |failure| return .{ .failed = failure },
                }
            }
            return .{ .moved = moved };
        }

        /// Take what is left of a halted transfer off the endpoint, so the
        /// next one begins at the tail. The controller processes nothing on
        /// a halted endpoint, so its head is the host's to move.
        pub fn clear(self: *Self) void {
            self.endpoint.head = .at(self.endpoint.tail);
            Barrier.publish();
        }

        fn addressOf(self: *const Self, index: usize) u32 {
            return self.base + @as(u32, @intCast(index)) * @sizeOf(ohci.Transfer);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests: a queue against a model of the controller
// ---------------------------------------------------------------------------

const lib = @import("lib");
const fuzzing = lib.fuzzing;
const Choices = fuzzing.Choices;
const testing = std.testing;

const SLOTS = 4;
const BASE: u32 = 0x0010_0000;
const BUFFER: u32 = 0x0020_0000;

const Stepping = struct {
    var model: ?*Controller = null;

    pub fn publish() void {
        if (model) |controller| controller.moveOn();
    }

    pub fn consume() void {
        if (model) |controller| controller.moveOn();
    }
};

const Controller = struct {
    from: Choices,
    endpoint: *ohci.Endpoint,
    descriptors: *[SLOTS]ohci.Transfer,
    /// What the host means each descriptor of the transfer under way to
    /// say, until the controller has processed it.
    expected: [SLOTS]?Stage = @splat(null),
    /// What each processed descriptor was made to come to.
    made: [SLOTS]Made = undefined,
    fault: ?[]const u8 = null,

    const Made = struct { outcome: ohci.Outcome, moved: u32 };

    fn moveOn(self: *Controller) void {
        var steps: usize = 0;
        while (steps < 3 and self.from.odds(2)) : (steps += 1) self.step();
    }

    fn step(self: *Controller) void {
        const head = self.endpoint.head;
        if (self.endpoint.control.skip or head.halted or head.physical() == self.endpoint.tail) return;

        const offset = head.physical() -% BASE;
        if (offset % 16 != 0 or offset / 16 >= SLOTS) {
            self.fault = "the controller followed the head out of the queue";
            return;
        }
        const index = offset / 16;
        const want = self.expected[index] orelse {
            self.fault = "the controller processed a descriptor outside the transfer";
            return;
        };
        self.expected[index] = null;

        const descriptor = &self.descriptors[index];
        const written = descriptor.control.condition == .not_accessed and
            descriptor.control.pid == want.pid and descriptor.control.toggle == want.toggle and
            descriptor.buffer == (if (want.length == 0) 0 else want.buffer) and
            descriptor.end == (if (want.length == 0) 0 else want.buffer + want.length - 1);
        if (!written) {
            self.fault = "the controller processed a descriptor before the host had written it";
            return;
        }
        const length = if (descriptor.buffer == 0) 0 else descriptor.end - descriptor.buffer + 1;
        const outcome = self.from.one(enum { whole, short, stall, silent, garbled });
        var made = Made{ .outcome = .done, .moved = length };
        switch (outcome) {
            .whole => {
                descriptor.control.condition = .no_error;
                descriptor.buffer = 0;
            },
            .short => if (descriptor.control.short_ok and length > 0) {
                made.moved = @intCast(self.from.below(length));
                descriptor.control.condition = .no_error;
                if (made.moved == 0) {
                    // Nothing moved: the pointer stays where it began.
                } else {
                    descriptor.buffer += made.moved;
                }
            } else {
                descriptor.control.condition = .no_error;
                descriptor.buffer = 0;
            },
            .stall, .silent, .garbled => {
                descriptor.control.condition = switch (outcome) {
                    .stall => .stall,
                    .silent => .not_responding,
                    else => .crc,
                };
                made = .{ .outcome = ohci.Outcome.of(descriptor.control.condition), .moved = 0 };
            },
        }
        self.made[index] = made;

        const next: ohci.Pointer = .at(descriptor.next);
        self.endpoint.head = .{ .sixteenths = next.sixteenths, .halted = made.outcome != .done };
    }
};

fn runQueue(from: Choices) anyerror!void {
    var endpoint = ohci.Endpoint{ .control = .{} };
    var descriptors: [SLOTS]ohci.Transfer = undefined;
    var model = Controller{ .from = from, .endpoint = &endpoint, .descriptors = &descriptors };
    var queue = Queue(SLOTS, Stepping){ .endpoint = &endpoint, .descriptors = &descriptors, .base = BASE };
    queue.reset();

    Stepping.model = &model;
    defer Stepping.model = null;

    for (0..from.upTo(40)) |_| {
        var stages: [SLOTS - 1]Stage = undefined;
        const count = from.upTo(SLOTS - 1);
        for (stages[0..count], 0..) |*stage, i| {
            const length: u32 = @intCast(from.below(3) * 32);
            stage.* = .{
                .pid = from.one(PidChoice).pid(),
                .toggle = if (from.odds(2)) .data0 else .data1,
                .buffer = BUFFER + @as(u32, @intCast(i)) * 0x100,
                .length = length,
                .short_ok = from.odds(2),
            };
        }

        model.expected = @splat(null);
        for (stages[0..count], 0..) |stage, i| model.expected[(queue.tail + i) % SLOTS] = stage;
        try testing.expect(queue.append(stages[0..count]));

        var looks: usize = 0;
        while (!queue.settled()) : (looks += 1) {
            model.step();
            if (model.fault) |why| return fail(why);
            try testing.expect(looks < SLOTS * 4);
        }
        if (model.fault) |why| return fail(why);

        const counted = from.below(count);
        switch (queue.result(counted)) {
            .moved => |bytes| {
                for (0..count) |i| {
                    const made = model.made[(queue.first + i) % SLOTS];
                    try testing.expectEqual(ohci.Outcome.done, made.outcome);
                    if (i == counted) try testing.expectEqual(made.moved, bytes);
                }
                try testing.expect(bytes <= stages[counted].length);
            },
            .failed => {
                try testing.expect(endpoint.head.halted);
                queue.clear();
            },
        }
    }
}

const PidChoice = enum {
    setup,
    out,
    in,

    fn pid(self: PidChoice) ohci.Pid {
        return switch (self) {
            .setup => .setup,
            .out => .out,
            .in => .in,
        };
    }
};

fn fail(why: []const u8) error{TestUnexpectedResult} {
    std.debug.print("model: {s}\n", .{why});
    return error.TestUnexpectedResult;
}

test "fuzz: a queue exposes only what it filled, and every transfer settles to what the controller made of it" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            return runQueue(.{ .fuzzer = smith });
        }
    };
    try std.testing.fuzz({}, Target.one, .{});
}

test "a queue against a modelled controller, at random" {
    try fuzzing.seeded(runQueue, 0x0C1_0E0E, 3000);
}

test "a control transfer's three stages are queued behind a fresh tail" {
    var endpoint = ohci.Endpoint{};
    var descriptors: [SLOTS]ohci.Transfer = undefined;
    const Plain = struct {
        pub fn publish() void {}
        pub fn consume() void {}
    };
    var queue = Queue(SLOTS, Plain){ .endpoint = &endpoint, .descriptors = &descriptors, .base = BASE };
    queue.reset();
    try testing.expect(queue.settled());

    try testing.expect(queue.append(&.{
        .{ .pid = .setup, .toggle = .data0, .buffer = BUFFER, .length = 8 },
        .{ .pid = .in, .toggle = .data1, .buffer = BUFFER + 8, .length = 18, .short_ok = true },
        .{ .pid = .out, .toggle = .data1 },
    }));
    try testing.expectEqual(BASE + 3 * 16, endpoint.tail);
    try testing.expect(!queue.settled());
    try testing.expectEqual(BASE + 16, descriptors[0].next);
    try testing.expectEqual(ohci.NO_INTERRUPT, descriptors[0].control.delay);
    try testing.expectEqual(@as(u3, 0), descriptors[2].control.delay);
    try testing.expectEqual(BUFFER + 8 + 17, descriptors[1].end);
    try testing.expectEqual(@as(u32, 0), descriptors[2].buffer);

    // The controller finishes all three, the data stage short.
    for (&descriptors, 0..) |*descriptor, i| {
        if (i == 3) break;
        descriptor.control.condition = .no_error;
        descriptor.buffer = 0;
    }
    descriptors[1].buffer = BUFFER + 8 + 12;
    endpoint.head = .at(endpoint.tail);
    try testing.expect(queue.settled());
    try testing.expectEqual(Result{ .moved = 12 }, queue.result(1));

    // The next transfer starts at the tail and wraps round the ring.
    try testing.expect(queue.append(&.{.{ .pid = .in, .toggle = .data0, .buffer = BUFFER, .length = 64 }}));
    try testing.expectEqual(BASE, endpoint.tail);
    try testing.expectEqual(@as(usize, 3), queue.first);
}
