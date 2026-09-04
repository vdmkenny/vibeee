//! Where a user stack may grow to, and what of it may be handed back.
//!
//! A stack is not a size a program declares: it is a depth it reaches. So it
//! starts small, grows into a reservation when a fault says it ran out, and
//! gives pages back once it has climbed away from them again.
//!
//! Both decisions are arithmetic over addresses, and arithmetic is the part
//! worth being sure about: an answer one page out either faults where it
//! should not or hands back a page still in use. So the deciding lives here,
//! where a test can ask it directly, and the mapping lives with the pages.

const std = @import("std");

/// The shape of a stack: where it sits, how far it may go, and how much
/// moves at a time.
pub const Rules = struct {
    /// One past the highest byte. The stack grows down from here.
    top: usize,
    /// The lowest address it may ever reach.
    limit: usize,
    page: usize = 4096,
    /// Pages added each time it runs out. One at a time would fault once per
    /// page down a deep call.
    chunk: usize = 16,
    /// Pages left mapped below the stack pointer when handing any back, so a
    /// program that dips again does not fault at once.
    keep: usize = 16,
    /// How much has to be spare before anything is handed back. Without it a
    /// stack hovering at a boundary would map and unmap the same page
    /// forever.
    slack: usize = 32,

    pub fn pageOf(self: Rules, addr: usize) usize {
        return addr & ~(self.page - 1);
    }

    /// Whether an address belongs to the stack's reservation.
    pub fn holds(self: Rules, addr: usize) bool {
        return addr >= self.limit and addr < self.top;
    }
};

/// A run of pages, from the lowest to the highest, both included.
pub const Span = struct {
    from: usize,
    to: usize,

    pub fn pages(self: Span, page: usize) usize {
        return (self.to - self.from) / page + 1;
    }
};

/// The pages to map for a fault at `addr`, given the lowest page mapped now.
/// Null when the address is not the stack's to grow into, or when the page is
/// already mapped, which makes the fault about something else.
pub fn growth(rules: Rules, bottom: usize, addr: usize) ?Span {
    if (!rules.holds(addr)) return null;

    const page = rules.pageOf(addr);
    if (page >= bottom) return null;

    // A chunk ending at the faulting page, so the next few frames of a deep
    // call are already there, and never below the limit.
    const wanted = rules.chunk * rules.page;
    const from = if (page >= rules.limit + wanted) page - wanted + rules.page else rules.limit;
    return .{ .from = from, .to = bottom - rules.page };
}

/// The pages to hand back when the stack pointer has climbed away from what
/// is mapped. Null when there is not enough spare to be worth it, which is
/// most of the time.
pub fn reclaim(rules: Rules, bottom: usize, sp: usize) ?Span {
    if (!rules.holds(sp)) return null;
    if (sp <= bottom) return null;

    const keep_to = rules.pageOf(sp) - rules.keep * rules.page;
    if (keep_to <= bottom) return null;
    if ((keep_to - bottom) / rules.page < rules.slack) return null;

    return .{ .from = bottom, .to = keep_to - rules.page };
}

const testing = std.testing;
const TOP: usize = 0x3FFF_0000;
const PAGE: usize = 4096;
const shape: Rules = .{ .top = TOP, .limit = TOP - 256 * PAGE };

/// Where a stack that has never grown starts: sixteen pages under the top.
const START: usize = TOP - 16 * PAGE;

test "an address outside the reservation is nobody's to grow" {
    try testing.expect(growth(shape, START, TOP) == null);
    try testing.expect(growth(shape, START, TOP + PAGE) == null);
    try testing.expect(growth(shape, START, shape.limit - 1) == null);
    try testing.expect(growth(shape, START, 0) == null);
}

test "a page already mapped is a fault about something else" {
    try testing.expect(growth(shape, START, START) == null);
    try testing.expect(growth(shape, START, START + PAGE) == null);
    try testing.expect(growth(shape, START, TOP - 1) == null);
}

test "running out maps a chunk ending where the fault landed" {
    const span = growth(shape, START, START - 1) orelse return error.NoGrowth;
    try testing.expectEqual(START - PAGE, span.to);
    try testing.expectEqual(@as(usize, 16), span.pages(PAGE));
    try testing.expectEqual(START - 16 * PAGE, span.from);
}

test "a fault far below what is mapped is covered in one go" {
    // A single frame larger than a chunk: the whole span up to what was
    // mapped goes in, so the instruction that faulted can just run again.
    const deep = START - 40 * PAGE;
    const span = growth(shape, START, deep) orelse return error.NoGrowth;
    try testing.expect(span.from <= deep);
    try testing.expectEqual(START - PAGE, span.to);
    try testing.expect(span.pages(PAGE) >= 41);
}

test "growth stops at the limit rather than running past it" {
    const span = growth(shape, shape.limit + PAGE, shape.limit) orelse return error.NoGrowth;
    try testing.expectEqual(shape.limit, span.from);
    try testing.expectEqual(shape.limit, span.to);
    try testing.expect(growth(shape, shape.limit, shape.limit) == null);
}

test "nothing is handed back until there is room to spare" {
    // Just under the top with everything mapped: nothing to give.
    try testing.expect(reclaim(shape, START, TOP - PAGE) == null);

    // Grown deep and still deep: the pages are in use.
    const deep = TOP - 100 * PAGE;
    try testing.expect(reclaim(shape, deep, deep + PAGE) == null);
    try testing.expect(reclaim(shape, deep, deep + 8 * PAGE) == null);
}

test "a stack that climbed away gives back what it left below" {
    const deep = TOP - 100 * PAGE;
    const sp = TOP - 20 * PAGE;
    const span = reclaim(shape, deep, sp) orelse return error.NoReclaim;

    try testing.expectEqual(deep, span.from);
    // What is kept below the pointer stays mapped.
    try testing.expectEqual(sp - shape.keep * PAGE - PAGE, span.to);
    try testing.expect(span.to < sp);
    try testing.expect(span.pages(PAGE) >= shape.slack);
}

test "a stack pointer outside the reservation says nothing about it" {
    const deep = TOP - 100 * PAGE;
    try testing.expect(reclaim(shape, deep, 0) == null);
    try testing.expect(reclaim(shape, deep, TOP) == null);
    try testing.expect(reclaim(shape, deep, shape.limit - PAGE) == null);
}

test "what is grown and then handed back leaves the stack where it started" {
    var bottom = START;
    const span = growth(shape, bottom, START - 40 * PAGE) orelse return error.NoGrowth;
    bottom = span.from;
    try testing.expect(bottom < START);

    const back = reclaim(shape, bottom, TOP - PAGE) orelse return error.NoReclaim;
    try testing.expectEqual(bottom, back.from);
    // Never above what a fresh stack holds, so the pages a program started
    // with are still there.
    try testing.expect(back.to < START);
}
