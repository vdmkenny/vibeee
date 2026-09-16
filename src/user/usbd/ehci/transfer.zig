//! EHCI transfer descriptors, and what a finished chain of them came to.
//!
//! The host arms each stage of a transfer with the bytes it asks for and the
//! active bit. The controller works through the chain in order. For each
//! stage it clears active and writes back how many of the asked bytes it did
//! not move; a stage that fails is halted, and the stages after it stay
//! active. The host reads each stage once and trusts no count past what it
//! asked for.
//!
//! Pure over the descriptor memory. `Barrier.consume` comes before each read
//! of what the controller wrote. The tests drive a chain against a model of
//! the controller that moves at those points.

const std = @import("std");

/// What a link pointer points at, which the controller reads from the
/// pointer's own low bits.
pub const LinkKind = enum(u2) {
    isochronous = 0,
    queue_head = 1,
    split_isochronous = 2,
    frame_span = 3,
};

pub const Link = packed struct(u32) {
    /// Nothing follows: the end of a chain.
    terminate: bool = true,
    kind: LinkKind = .queue_head,
    _3: u2 = 0,
    /// The address, which is why everything in a schedule is aligned to
    /// thirty-two bytes.
    address: u27 = 0,

    /// A link to the structure at `physical`, whose low five bits are the
    /// link's own.
    pub fn to(physical: u32, kind: LinkKind) Link {
        var link: Link = @bitCast(physical);
        link.terminate = false;
        link.kind = kind;
        link._3 = 0;
        return link;
    }

    pub const none = Link{};
};

/// What a transfer descriptor is doing, and what became of it.
pub const TransferStatus = packed struct(u8) {
    ping: bool = false,
    split_state: bool = false,
    missed_microframe: bool = false,
    transaction_error: bool = false,
    babble: bool = false,
    buffer_error: bool = false,
    /// The device said no, or the controller gave up on it.
    halted: bool = false,
    /// The controller still has work to do here.
    active: bool = false,

    pub fn failed(self: TransferStatus) bool {
        return self.halted or self.transaction_error or self.babble or self.buffer_error;
    }
};

pub const Pid = enum(u2) {
    out = 0,
    in = 1,
    setup = 2,
    _,
};

pub const Token = packed struct(u32) {
    status: TransferStatus = .{},
    pid: Pid = .out,
    error_limit: u2 = 3,
    page: u3 = 0,
    /// Interrupt when this descriptor completes.
    interrupt: bool = false,
    /// Armed with the bytes asked for; written back with those not moved.
    bytes: u15 = 0,
    /// The toggle, which the device and the host must agree on.
    toggle: bool = false,
};

/// A transfer descriptor: one stage of one transfer, in the extended form.
/// A controller that addresses sixty-four bits always reads the extended
/// descriptor, whatever the segment register holds, so the upper halves of
/// the buffer pointers must exist and be zero; a thirty-two bit part never
/// looks at them. Without them the controller reads the next descriptor's
/// words as upper address halves.
pub const Transfer = extern struct {
    next: Link = Link.none,
    alternate: Link = Link.none,
    token: Token = .{},
    pages: [5]u32 = @splat(0),
    pages_high: [5]u32 = @splat(0),
    /// Out to a whole cache line, so arrays of descriptors keep every
    /// element on the thirty-two byte alignment the controller requires.
    _pad: [3]u32 = @splat(0),
};

comptime {
    if (@sizeOf(Transfer) != 64) @compileError("an extended transfer descriptor fills a cache line");
    if (@as(u32, @bitCast(Token{ .status = .{ .active = true }, .error_limit = 0 })) != 0x80) {
        @compileError("the transfer token's status drifted");
    }
    if (@as(u32, @bitCast(Token{ .pid = .setup, .error_limit = 0 })) != 0x200) {
        @compileError("the transfer token's packet identifier drifted");
    }
}

/// Whether the controller has stopped working on `stages`: the last is no
/// longer active, or has failed.
pub fn settled(comptime Barrier: type, stages: []const volatile Transfer) bool {
    Barrier.consume();
    const last = stages[stages.len - 1].token;
    return !last.status.active or last.status.failed();
}

/// The stage whose bytes a result counts, and how many it was armed with.
pub const Counted = struct {
    stage: usize = 0,
    asked: usize,
};

/// What a chain of stages came to.
pub const Result = union(enum) {
    /// The first stage not done is still active.
    unfinished,
    /// The first stage not done failed.
    failed,
    /// Every stage is done. The bytes moved in the stage counted, or none.
    moved: usize,
};

/// Read `stages` in order. The first that is not done decides; when all are,
/// the bytes of the stage `counted` names.
pub fn result(comptime Barrier: type, stages: []const volatile Transfer, counted: ?Counted) Result {
    var moved: usize = 0;
    for (stages, 0..) |*stage, index| {
        Barrier.consume();
        const token = stage.token;
        if (token.status.failed()) return .failed;
        if (token.status.active) return .unfinished;
        const count = counted orelse continue;
        if (count.stage == index) moved = count.asked -| token.bytes;
    }
    return .{ .moved = moved };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const lib = @import("lib");
const testing = std.testing;

const Plain = struct {
    pub fn consume() void {}
};

test "a link is the address with its kind in the low bits" {
    try testing.expectEqual(@as(u32, 0x1234_5662), @as(u32, @bitCast(Link.to(0x1234_5660, .queue_head))));
    try testing.expectEqual(@as(u32, 0x0010_0020), @as(u32, @bitCast(Link.to(0x0010_0020, .isochronous))));
    try testing.expect(Link.none.terminate);
    try testing.expectEqual(@as(u27, 0x0010_0020 / 32), Link.to(0x0010_0020, .queue_head).address);
}

/// A stage as the controller leaves it.
fn left(status: TransferStatus, bytes: u15) Transfer {
    return .{ .token = .{ .status = status, .bytes = bytes } };
}

const done: TransferStatus = .{};
const armed: TransferStatus = .{ .active = true };
const halted: TransferStatus = .{ .halted = true };

test "each chain the controller can leave is read to what it came to" {
    const Case = struct { stages: []const Transfer, counted: ?Counted, is: Result };
    const cases = [_]Case{
        // Setup, a data stage eighteen bytes short of what was asked, status.
        .{ .stages = &.{ left(done, 0), left(done, 18), left(done, 0) }, .counted = .{ .stage = 1, .asked = 64 }, .is = .{ .moved = 46 } },
        .{ .stages = &.{ left(done, 0), left(done, 0) }, .counted = null, .is = .{ .moved = 0 } },
        // A count past what was asked moved nothing.
        .{ .stages = &.{left(done, 600)}, .counted = .{ .asked = 512 }, .is = .{ .moved = 0 } },
        .{ .stages = &.{left(done, 0)}, .counted = .{ .asked = 512 }, .is = .{ .moved = 512 } },
        // The first stage not done decides, whatever follows it.
        .{ .stages = &.{ left(done, 0), left(halted, 64), left(armed, 0) }, .counted = .{ .stage = 1, .asked = 64 }, .is = .failed },
        .{ .stages = &.{ left(done, 0), left(armed, 64), left(halted, 0) }, .counted = .{ .stage = 1, .asked = 64 }, .is = .unfinished },
        .{ .stages = &.{left(.{ .active = true, .halted = true }, 0)}, .counted = .{ .asked = 8 }, .is = .failed },
        .{ .stages = &.{left(.{ .babble = true }, 0)}, .counted = .{ .asked = 8 }, .is = .failed },
        .{ .stages = &.{left(.{ .transaction_error = true }, 0)}, .counted = .{ .asked = 8 }, .is = .failed },
        .{ .stages = &.{left(.{ .buffer_error = true }, 0)}, .counted = .{ .asked = 8 }, .is = .failed },
        .{ .stages = &.{left(armed, 8)}, .counted = .{ .asked = 8 }, .is = .unfinished },
    };

    var reached = std.EnumSet(std.meta.Tag(Result)){};
    for (cases) |case| {
        const is = result(Plain, case.stages, case.counted);
        try testing.expectEqual(case.is, is);
        reached.insert(is);
    }
    try testing.expect(reached.eql(.initFull()));
}

test "a chain has settled once its last stage is done or failed" {
    try testing.expect(settled(Plain, &.{ left(armed, 8), left(done, 0) }));
    try testing.expect(settled(Plain, &.{ left(done, 0), left(halted, 0) }));
    try testing.expect(settled(Plain, &.{ left(done, 0), left(.{ .active = true, .babble = true }, 0) }));
    try testing.expect(!settled(Plain, &.{ left(halted, 8), left(armed, 0) }));
    try testing.expect(!settled(Plain, &.{left(armed, 8)}));
}

// ---------------------------------------------------------------------------
// Fuzzing: a chain against a model of the controller
// ---------------------------------------------------------------------------
//
// The model works through a chain of up to three stages in order and moves
// at every barrier. It moves all of a stage's bytes or fewer, or fails the
// stage and halts, leaving the stages after it active, or meets a device
// that does not answer and leaves the stage active. Now and then it writes
// back a count larger than the stage was armed with. The host waits a
// varying number of looks before it reads the chain.
//
// Checked: a count comes from a chain the controller finished without a
// failure, and is what it moved in the stage asked about; a failure from a
// chain with a failed stage; an unfinished chain is one the controller had
// not finished when the host began to read it; a settled chain is never
// unfinished.

const fuzzing = lib.fuzzing;
const Choices = fuzzing.Choices;

const STAGES = 3;

/// The most a stage asks for here: a control transfer's buffer.
const LARGEST = 1024;

const Stepping = struct {
    var controller: ?*Controller = null;

    pub fn consume() void {
        if (controller) |model| model.moveOn();
    }
};

/// What the controller does with a stage, and how often: a share of this
/// table each.
const Work = enum {
    whole,
    short,
    fail,
    /// The device does not answer: the stage stays active.
    silent,
    /// Written back with more bytes left than the stage was armed with.
    overcount,
};
const WORK = [_]Work{ .fail, .silent, .overcount } ++ [_]Work{.whole} ** 3 ++ [_]Work{.short} ** 3;

/// The bits that come with a halt.
const Fault = enum { transaction_error, babble, buffer_error };

const Controller = struct {
    from: Choices,
    stages: []Transfer,
    asked: []const u15,
    /// What each stage moved, once done.
    moved: [STAGES]?usize = @splat(null),
    /// The next stage to work on.
    at: usize = 0,
    state: enum { working, halted, unanswered } = .working,

    fn moveOn(self: *Controller) void {
        var steps: usize = 0;
        while (steps < 2 and self.from.odds(2)) : (steps += 1) self.step();
    }

    fn finished(self: *const Controller) bool {
        return self.state == .halted or self.at == self.stages.len;
    }

    fn step(self: *Controller) void {
        if (self.finished() or self.state == .unanswered) return;
        const asked = self.asked[self.at];
        var token = self.stages[self.at].token;
        token.status.active = false;
        switch (WORK[self.from.below(WORK.len)]) {
            .whole => {
                token.bytes = 0;
                self.moved[self.at] = asked;
            },
            .short => {
                const moved: u15 = @intCast(self.from.below(@as(usize, asked) + 1));
                token.bytes = asked - moved;
                self.moved[self.at] = moved;
            },
            .fail => {
                token.status.halted = true;
                if (self.from.odds(2)) switch (self.from.one(Fault)) {
                    inline else => |fault| @field(token.status, @tagName(fault)) = true,
                };
                token.bytes = @intCast(self.from.below(@as(usize, asked) + 1));
                self.state = .halted;
            },
            .silent => {
                self.state = .unanswered;
                return;
            },
            .overcount => {
                const largest = std.math.maxInt(u15);
                token.bytes = if (asked == largest) largest else asked + 1 + @as(u15, @intCast(self.from.below(largest - asked)));
                self.moved[self.at] = 0;
            },
        }
        // One store, as the controller writes the token back.
        self.stages[self.at].token = token;
        if (self.state == .working) self.at += 1;
    }
};

fn runChain(from: Choices) anyerror!void {
    const count = from.upTo(STAGES);
    var stages: [STAGES]Transfer = undefined;
    var asked: [STAGES]u15 = undefined;
    for (stages[0..count], asked[0..count]) |*armed_stage, *bytes| {
        bytes.* = @intCast(from.below(LARGEST + 1));
        armed_stage.* = .{ .token = .{ .status = .{ .active = true }, .pid = .in, .bytes = bytes.* } };
    }
    var controller = Controller{ .from = from, .stages = stages[0..count], .asked = asked[0..count] };

    Stepping.controller = &controller;
    defer Stepping.controller = null;

    // Wait as the driver does, for as many looks as its deadline allows.
    const patience = from.below(7);
    var looks: usize = 0;
    const settled_itself = while (looks < patience) : (looks += 1) {
        if (settled(Stepping, stages[0..count])) break true;
        controller.moveOn();
    } else false;

    const counted: ?Counted = if (from.odds(4)) null else blk: {
        const which = from.below(count);
        break :blk .{ .stage = which, .asked = asked[which] };
    };
    const finished_before = controller.finished();

    switch (result(Stepping, stages[0..count], counted)) {
        .moved => |bytes| {
            if (controller.state == .halted) return fail("a chain with a failed stage was counted");
            if (controller.at != count) return fail("a chain was counted before the controller finished it");
            const expected = if (counted) |which| controller.moved[which.stage].? else 0;
            if (bytes != expected) return fail("a chain was counted at bytes the controller did not move");
        },
        .failed => if (controller.state != .halted) return fail("a chain with no failed stage was called failed"),
        .unfinished => {
            if (finished_before) return fail("a chain the controller had finished was called unfinished");
            if (settled_itself) return fail("a settled chain was called unfinished");
        },
    }
}

fn fail(why: []const u8) error{TestUnexpectedResult} {
    std.debug.print("model: {s}\n", .{why});
    return error.TestUnexpectedResult;
}

test "fuzz: a chain is read to what the controller made of it, whenever it moves" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            return runChain(.{ .fuzzer = smith });
        }
    };
    try std.testing.fuzz({}, Target.one, .{});
}

test "a chain against a modelled controller, at random" {
    try fuzzing.seeded(runChain, 0xEC1_0C4A, 20000);
}
