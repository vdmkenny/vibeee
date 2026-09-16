//! Serving the interrupt lines netd waits on.
//!
//! A line is served when its interrupt was delivered, when it is owed, or
//! when it has gone `UNHEARD_US` without being served. Every interface on
//! the line is served, then the line is acknowledged once.
//!
//! On the Eee PC the lines are edge triggered. An interface that asserts
//! while another holds a shared wire low makes no edge, so a round that did
//! work on a shared line is followed by another. Frames a budget left
//! waiting are owed, and the loop does not sleep while any are.
//!
//! Serving an unheard line needs no wake of its own: it happens on a pass
//! the loop takes for another reason, such as the stack's timers. It bounds
//! the cost of an edge the hardware lost, and of an assertion still hidden
//! on a shared line after its rounds.
//!
//! Generic over the interfaces and the system calls, so it runs in host
//! tests.

const std = @import("std");

/// What serving an adapter came to. Merging keeps the later tag.
pub const Pass = enum {
    /// Nothing was waiting.
    idle,
    /// Work was done, and whatever is left will assert.
    served,
    /// A budget stopped the work with more waiting, and no interrupt will
    /// announce the rest.
    unfinished,

    pub fn merge(self: Pass, other: Pass) Pass {
        return @enumFromInt(@max(@intFromEnum(self), @intFromEnum(other)));
    }
};

/// Interrupts a pass served, and how many of those no interface had work
/// for.
pub const Count = struct {
    delivered: u32 = 0,
    unclaimed: u32 = 0,
};

/// How long a line may go without being served before a pass serves it
/// anyway.
pub const UNHEARD_US: u64 = 250_000;

/// What follows a round over every interface on a line.
pub const Next = enum {
    /// Wait for the line's next interrupt.
    wait,
    /// Serve the line again now.
    again,
    /// Serve the line on the next pass, without waiting.
    later,
};

/// Rounds one pass gives a line.
pub const ROUNDS = 2;

/// What follows round `round` over a line of `sharers` interfaces that came
/// to `pass`.
///
/// Only frames left waiting keep the loop from sleeping. A cause a driver
/// cannot clear reads as work on every round, so rounds that keep finding
/// causes end in a wait rather than in owed work.
pub fn next(pass: Pass, sharers: usize, round: usize) Next {
    return switch (pass) {
        .idle => .wait,
        .unfinished => .later,
        .served => if (sharers > 1 and round + 1 < ROUNDS) .again else .wait,
    };
}

/// Serve every line that was delivered, is owed or has gone unheard, and
/// acknowledge each once.
///
/// `io` has `waitMany`, `irqAck` and `POLL`. An interface has `irq`, the
/// handle of its line if it has one; `owed`; `irq_count`; `served_at`; and
/// `serveLine()`, which clears `owed` and answers a `Pass`.
pub fn serve(comptime io: type, interfaces: anytype, selected: ?u32, now: u64) Count {
    var count: Count = .{};
    for (interfaces, 0..) |*first, i| {
        const handle = first.irq orelse continue;
        if (sharing(interfaces[0..i], handle) > 0) continue;

        // The main wait has already consumed the selected line's signal.
        const delivered = selected == handle or ready(io, handle);
        var owed = false;
        var unheard = true;
        for (interfaces) |*iface| {
            if (iface.irq != handle) continue;
            owed = owed or iface.owed;
            unheard = unheard and now -| iface.served_at >= UNHEARD_US;
        }
        if (!delivered and !owed and !unheard) continue;

        const sharers = sharing(interfaces, handle);
        var worked = false;
        var round: usize = 0;
        while (true) : (round += 1) {
            var pass: Pass = .idle;
            for (interfaces) |*iface| {
                if (iface.irq != handle) continue;
                if (round == 0) {
                    if (delivered) iface.irq_count += 1;
                    if (unheard) iface.owed = true;
                    iface.served_at = now;
                }
                pass = pass.merge(iface.serveLine());
            }
            worked = worked or pass != .idle;
            switch (next(pass, sharers, round)) {
                .wait => break,
                .again => continue,
                .later => {
                    for (interfaces) |*iface| {
                        if (iface.irq == handle) iface.owed = true;
                    }
                    break;
                },
            }
        }

        if (delivered) {
            count.delivered += 1;
            if (!worked) count.unclaimed += 1;
        }
        io.irqAck(handle, worked);
    }
    return count;
}

/// How many of `interfaces` are on the line `handle`.
fn sharing(interfaces: anytype, handle: u32) usize {
    var n: usize = 0;
    for (interfaces) |*iface| {
        if (iface.irq == handle) n += 1;
    }
    return n;
}

/// Whether the line's signal is waiting. Consumes it.
fn ready(comptime io: type, handle: u32) bool {
    _ = io.waitMany(&.{handle}, io.POLL) catch return false;
    return true;
}

const testing = std.testing;

/// An interface that answers a script.
const Fake = struct {
    irq: ?u32,
    owed: bool = false,
    irq_count: u64 = 0,
    served_at: u64 = NOW,
    /// What successive serves answer; `.idle` once the script runs out.
    script: []const Pass = &.{},
    serves: usize = 0,
    /// How many serves found the interface owed.
    owed_serves: usize = 0,

    pub fn serveLine(self: *Fake) Pass {
        if (self.owed) self.owed_serves += 1;
        self.owed = false;
        defer self.serves += 1;
        return if (self.serves < self.script.len) self.script[self.serves] else .idle;
    }
};

const NOW: u64 = 10 * UNHEARD_US;

/// The system calls, recorded.
const System = struct {
    pub const POLL = 0;

    var signalled: [4]bool = @splat(false);
    var looked: [4]u8 = @splat(0);
    var acked: [4]u8 = @splat(0);
    var worked: [4]bool = @splat(false);
    /// Serves on each line when it was acknowledged.
    var serves_at_ack: [4]usize = @splat(0);
    var interfaces: []Fake = &.{};

    fn reset(on: []Fake, lines: []const u32) void {
        signalled = @splat(false);
        for (lines) |line| signalled[line] = true;
        looked = @splat(0);
        acked = @splat(0);
        worked = @splat(false);
        serves_at_ack = @splat(0);
        interfaces = on;
    }

    pub fn waitMany(handles: []const u32, timeout: usize) error{TimedOut}!usize {
        std.debug.assert(handles.len == 1 and timeout == POLL);
        const line = handles[0];
        looked[line] += 1;
        if (!signalled[line]) return error.TimedOut;
        signalled[line] = false;
        return 0;
    }

    pub fn irqAck(handle: u32, work: bool) void {
        acked[handle] += 1;
        worked[handle] = work;
        for (interfaces) |iface| {
            if (iface.irq == handle) serves_at_ack[handle] += iface.serves;
        }
    }
};

test "every interface on a delivered line is served before its one acknowledgement" {
    var interfaces = [_]Fake{
        .{ .irq = 1, .script = &.{.served} },
        .{ .irq = 1 },
        .{ .irq = 2 },
        .{ .irq = 3 },
        .{ .irq = null },
    };
    System.reset(&interfaces, &.{ 1, 2 });

    // A wake for a deadline: nothing was selected, so every line is looked at.
    const count = serve(System, &interfaces, null, NOW);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 1, 1 }, &System.looked);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 1, 0 }, &System.acked);
    try testing.expect(System.worked[1]);
    try testing.expect(!System.worked[2]);
    try testing.expectEqual(Count{ .delivered = 2, .unclaimed = 1 }, count);
    // Line 1 is shared and did work, so it had a second round.
    try testing.expectEqual(@as(usize, 4), System.serves_at_ack[1]);
    try testing.expectEqual(@as(u64, 1), interfaces[0].irq_count);
    try testing.expectEqual(@as(u64, 0), interfaces[3].irq_count);
    try testing.expectEqual(@as(usize, 0), interfaces[3].serves);
}

test "the selected line is not looked for again" {
    var interfaces = [_]Fake{.{ .irq = 1 }};
    System.reset(&interfaces, &.{});

    const count = serve(System, &interfaces, 1, NOW);
    try testing.expectEqual(@as(u8, 0), System.looked[1]);
    try testing.expectEqual(@as(u8, 1), System.acked[1]);
    try testing.expectEqual(Count{ .delivered = 1, .unclaimed = 1 }, count);
}

test "a lone interface that did work is not served again" {
    var interfaces = [_]Fake{.{ .irq = 1, .script = &.{ .served, .served } }};
    System.reset(&interfaces, &.{1});

    _ = serve(System, &interfaces, null, NOW);
    try testing.expectEqual(@as(usize, 1), interfaces[0].serves);
    try testing.expect(!interfaces[0].owed);
}

test "a shared line still finding causes after its rounds waits" {
    var interfaces = [_]Fake{
        .{ .irq = 1, .script = &.{ .served, .served, .served } },
        .{ .irq = 1 },
    };
    System.reset(&interfaces, &.{1});

    _ = serve(System, &interfaces, null, NOW);
    try testing.expectEqual(@as(usize, ROUNDS), interfaces[0].serves);
    try testing.expect(!interfaces[0].owed and !interfaces[1].owed);
    try testing.expectEqual(@as(u8, 1), System.acked[1]);
}

test "frames left on a shared line are owed by every interface on it" {
    var interfaces = [_]Fake{
        .{ .irq = 1, .script = &.{.unfinished} },
        .{ .irq = 1 },
        .{ .irq = 2 },
    };
    System.reset(&interfaces, &.{1});

    _ = serve(System, &interfaces, null, NOW);
    try testing.expectEqual(@as(usize, 1), interfaces[0].serves);
    try testing.expect(interfaces[0].owed and interfaces[1].owed);
    try testing.expect(!interfaces[2].owed);
}

test "unfinished work is owed, and taken up without a delivery" {
    var interfaces = [_]Fake{.{ .irq = 1, .script = &.{ .unfinished, .served } }};
    System.reset(&interfaces, &.{1});

    const first = serve(System, &interfaces, null, NOW);
    try testing.expect(interfaces[0].owed);
    try testing.expectEqual(Count{ .delivered = 1 }, first);

    // No signal this time: the line is served because it is owed, and that
    // is not counted as an interrupt.
    const second = serve(System, &interfaces, null, NOW);
    try testing.expectEqual(Count{}, second);
    try testing.expectEqual(@as(usize, 1), interfaces[0].owed_serves);
    try testing.expect(!interfaces[0].owed);
    try testing.expectEqual(@as(u8, 2), System.acked[1]);
    try testing.expectEqual(@as(u64, 1), interfaces[0].irq_count);

    // Nothing delivered, nothing owed, recently served: left alone.
    _ = serve(System, &interfaces, null, NOW);
    try testing.expectEqual(@as(usize, 2), interfaces[0].serves);
    try testing.expectEqual(@as(u8, 2), System.acked[1]);
}

test "a line unheard for long enough is served as owed work" {
    var interfaces = [_]Fake{
        .{ .irq = 1, .served_at = NOW - UNHEARD_US, .script = &.{.served} },
        .{ .irq = 2, .served_at = NOW - UNHEARD_US + 1 },
    };
    System.reset(&interfaces, &.{});

    const count = serve(System, &interfaces, null, NOW);
    try testing.expectEqual(Count{}, count);
    try testing.expectEqual(@as(usize, 1), interfaces[0].owed_serves);
    try testing.expectEqual(NOW, interfaces[0].served_at);
    try testing.expect(System.worked[1]);
    try testing.expectEqual(@as(usize, 0), interfaces[1].serves);
    try testing.expectEqual(@as(u8, 0), System.acked[2]);
}

test "every step after a round is reachable" {
    const cases = [_]struct { pass: Pass, sharers: usize, round: usize, next: Next }{
        .{ .pass = .idle, .sharers = 2, .round = 0, .next = .wait },
        .{ .pass = .served, .sharers = 1, .round = 0, .next = .wait },
        .{ .pass = .served, .sharers = 2, .round = 0, .next = .again },
        .{ .pass = .served, .sharers = 2, .round = ROUNDS - 1, .next = .wait },
        .{ .pass = .unfinished, .sharers = 1, .round = 0, .next = .later },
    };
    var reached = std.EnumSet(Next).initEmpty();
    for (cases) |case| {
        const got = next(case.pass, case.sharers, case.round);
        try testing.expectEqual(case.next, got);
        reached.insert(got);
    }
    try testing.expect(reached.eql(std.EnumSet(Next).initFull()));
}

test "merging keeps the later tag" {
    for (std.enums.values(Pass)) |a| {
        for (std.enums.values(Pass)) |b| {
            const merged = a.merge(b);
            try testing.expectEqual(merged, b.merge(a));
            try testing.expect(@intFromEnum(merged) >= @intFromEnum(a));
            try testing.expect(merged == a or merged == b);
        }
    }
}
