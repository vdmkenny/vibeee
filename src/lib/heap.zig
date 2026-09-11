//! A heap over memory handed to it in large pieces.
//!
//! Requests of two kilobytes and less come from size classes, each twice the
//! width of the last, and a block given back goes on its class's list for the
//! next request of that width. Larger requests are cut from the pieces at the
//! size they ask for, and a block given back is merged with whatever free
//! memory touches it, so what a program lets go of can be handed out again at
//! any size.
//!
//! The pieces come from a `Source`, which on the machine is the kernel's
//! shared-memory segments. Each segment is one of the few mappings a process
//! may hold, so pieces are asked for sparingly: each is twice the last, up to
//! `PIECE_MAX`, and a program holding thousands of blocks holds a handful of
//! pieces. A request larger than half of `PIECE_MAX` gets a piece of its own,
//! sized to it, because the kernel fills a segment with memory the moment it
//! is made and a piece rounded up past such a request is memory nothing asked
//! for. Nothing goes back to the source: a program's memory is its high-water
//! mark.
//!
//! Free memory is a list of holes in address order, first fit. A block is cut
//! from the front of a hole, so the rest of the hole is right behind it and a
//! block that grows can often grow where it is. The holes a program's use
//! leaves number a few dozen, which a walk covers faster than a tree over
//! them could be kept in order.
//!
//! Holds no lock. A program whose threads allocate keeps them out of it at the
//! same time.

const std = @import("std");

/// What every block is aligned to, and the width of the narrowest class.
pub const ALIGN = 16;

/// The widest class. Past it a request is cut to its size, because a class
/// that wide would waste more to its rounding than a hole costs to keep.
const CLASS_MAX = 2048;
const CLASSES = 8; // 16, 32, 64, 128, 256, 512, 1024, 2048

/// How much small blocks are cut from at a time. A class with nothing on its
/// list takes its next block from the current run.
const RUN = 16 * 1024;

/// The first piece asked for, and the most a shared piece grows to.
const PIECE_FIRST = 64 * 1024;
pub const PIECE_MAX = 4 * 1024 * 1024;

/// The least a hole is kept at when a block is cut from it. Less than this is
/// given to the block instead: a hole that small serves no request, and every
/// hole is a step on every walk of the list.
const HOLE_MIN = 256;

/// In front of every block.
const Header = extern struct {
    kind: Kind,
    /// How many bytes the block spans, this header included.
    span: usize,
};

const Kind = enum(u32) {
    /// Cut from a piece at the size it was asked for.
    cut = std.math.maxInt(u32),
    /// One of the classes, by index.
    _,
};

/// Room for the header. A whole alignment, so the bytes after it are aligned
/// as the block is.
const HEADER = ALIGN;

/// A block on its class's list, its link written over its header.
const Spare = extern struct {
    next: ?*Spare,
};

/// Free memory: how far it goes, and the next hole after it.
const Hole = extern struct {
    next: ?*Hole,
    span: usize,

    fn end(self: *const Hole) usize {
        return @intFromPtr(self) + self.span;
    }
};

comptime {
    std.debug.assert(@sizeOf(Header) <= HEADER);
    std.debug.assert(@sizeOf(Hole) <= HEADER);
}

/// A heap over memory from `Source`, which has one method: `take(bytes)`,
/// answering with at least `bytes` bytes aligned to `ALIGN`, a whole number
/// of alignments long, or null when it has no more.
pub fn Heap(comptime Source: type) type {
    return struct {
        const Self = @This();

        source: Source,
        /// Blocks given back, a list for each class.
        spares: [CLASSES]?*Spare = @splat(null),
        /// What is left of the run small blocks are cut from.
        run: []u8 = &.{},
        /// Free memory, in address order.
        holes: ?*Hole = null,
        /// How large the next shared piece is.
        piece: usize = PIECE_FIRST,

        /// A block holding at least `size` bytes, or null when there is no
        /// memory for one.
        pub fn alloc(self: *Self, size: usize) ?[*]u8 {
            const need = needFor(size) orelse return null;
            const block = if (classOf(need)) |class|
                self.fromClass(class) orelse return null
            else
                self.cut(need) orelse return null;
            return block + HEADER;
        }

        /// Give back a block `alloc` answered with.
        pub fn free(self: *Self, pointer: [*]u8) void {
            const block = pointer - HEADER;
            const header = headerOf(pointer);
            // Read before anything is written over them: a spare's link goes
            // where the kind was.
            const kind = header.kind;
            const span = header.span;
            switch (kind) {
                .cut => self.giveBack(block[0..span]),
                _ => {
                    const class: u3 = @intCast(@intFromEnum(kind));
                    const spare: *Spare = @ptrCast(@alignCast(block));
                    spare.next = self.spares[class];
                    self.spares[class] = spare;
                },
            }
        }

        /// Make the block at `pointer` hold `size` bytes where it is. True
        /// when it now does. A block always holds less, and gives back what
        /// it no longer needs where that is worth keeping; a block cut to its
        /// size holds more when the memory right behind it is free.
        pub fn resize(self: *Self, pointer: [*]u8, size: usize) bool {
            const need = needFor(size) orelse return false;
            const header = headerOf(pointer);
            if (header.kind != .cut) return need <= header.span;
            if (need <= header.span) {
                self.shrink(header, need);
                return true;
            }
            return self.extend(header, need);
        }

        /// The block at `pointer`, holding `size` bytes: where it is when it
        /// can grow there, and otherwise moved, with what it held.
        pub fn realloc(self: *Self, pointer: [*]u8, size: usize) ?[*]u8 {
            if (self.resize(pointer, size)) return pointer;
            const moved = self.alloc(size) orelse return null;
            // Less than `size`, or the block would have held it where it is.
            const held = capacityOf(pointer);
            @memcpy(moved[0..held], pointer[0..held]);
            self.free(pointer);
            return moved;
        }

        fn fromClass(self: *Self, class: u3) ?[*]u8 {
            const width = widthOf(class);
            const block: [*]u8 = if (self.spares[class]) |spare| reused: {
                self.spares[class] = spare.next;
                break :reused @ptrCast(spare);
            } else self.fromRun(width) orelse return null;
            headerAt(block).* = .{ .kind = @enumFromInt(class), .span = width };
            return block;
        }

        fn fromRun(self: *Self, width: usize) ?[*]u8 {
            if (self.run.len < width) {
                // Too little for this class, and perhaps of use to another
                // request once merged with what it touches.
                const left = self.run;
                self.run = &.{};
                self.giveBack(left);
                self.run = self.take(RUN) orelse return null;
            }
            const block = self.run.ptr;
            self.run = self.run[width..];
            return block;
        }

        fn cut(self: *Self, need: usize) ?[*]u8 {
            const span = self.take(need) orelse return null;
            headerAt(span.ptr).* = .{ .kind = .cut, .span = span.len };
            return span.ptr;
        }

        /// `need` bytes of free memory, from the holes or from a new piece: a
        /// little more where what would be left is too small to keep.
        fn take(self: *Self, need: usize) ?[]u8 {
            if (self.fit(need)) |span| return span;
            if (!self.fetch(need)) return null;
            return self.fit(need);
        }

        fn fit(self: *Self, need: usize) ?[]u8 {
            var link: *?*Hole = &self.holes;
            while (link.*) |hole| : (link = &hole.next) {
                if (hole.span < need) continue;
                const start: [*]u8 = @ptrCast(hole);
                const next = hole.next;
                const left = hole.span - need;
                if (left < HOLE_MIN) {
                    link.* = next;
                    return start[0 .. need + left];
                }
                // The front is taken and the rest stays a hole, so a block
                // that grows finds free memory right behind it.
                const rest: *Hole = @ptrCast(@alignCast(start + need));
                rest.* = .{ .next = next, .span = left };
                link.* = rest;
                return start[0..need];
            }
            return null;
        }

        /// Ask the source for a piece with room for `need`.
        fn fetch(self: *Self, need: usize) bool {
            const own = need > PIECE_MAX / 2;
            const piece = self.source.take(if (own) need else @max(self.piece, need)) orelse return false;
            std.debug.assert(std.mem.isAligned(@intFromPtr(piece.ptr), ALIGN));
            std.debug.assert(piece.len % ALIGN == 0);
            if (!own and self.piece < PIECE_MAX) self.piece *= 2;
            self.giveBack(piece);
            return true;
        }

        /// Make `span` a hole, merged with any hole it touches.
        fn giveBack(self: *Self, span: []u8) void {
            if (span.len < @sizeOf(Hole)) return;
            const at = @intFromPtr(span.ptr);

            var before: ?*Hole = null;
            var after = self.holes;
            while (after) |hole| {
                if (@intFromPtr(hole) > at) break;
                before = hole;
                after = hole.next;
            }
            // Overlapping a hole is a block given back twice.
            std.debug.assert(before == null or before.?.end() <= at);
            std.debug.assert(after == null or at + span.len <= @intFromPtr(after.?));

            const node: *Hole = @ptrCast(@alignCast(span.ptr));
            node.* = .{ .next = after, .span = span.len };
            var merged = node;
            if (before) |previous| {
                if (previous.end() == at) {
                    previous.span += span.len;
                    merged = previous;
                } else {
                    previous.next = node;
                }
            } else {
                self.holes = node;
            }
            if (after) |next| {
                if (merged.end() == @intFromPtr(next)) {
                    merged.span += next.span;
                    merged.next = next.next;
                }
            }
        }

        /// Give back the end of a cut block it no longer needs, where that
        /// is enough to keep as a hole.
        fn shrink(self: *Self, header: *Header, need: usize) void {
            if (header.span - need < HOLE_MIN) return;
            const block: [*]u8 = @ptrCast(header);
            const tail = block[need..header.span];
            header.span = need;
            self.giveBack(tail);
        }

        /// Grow a cut block into the hole right behind it, when there is one
        /// and it is large enough.
        fn extend(self: *Self, header: *Header, need: usize) bool {
            const end = @intFromPtr(header) + header.span;
            const more = need - header.span;
            var link: *?*Hole = &self.holes;
            while (link.*) |hole| : (link = &hole.next) {
                const at = @intFromPtr(hole);
                if (at < end) continue;
                if (at > end or hole.span < more) return false;
                const next = hole.next;
                const left = hole.span - more;
                if (left < HOLE_MIN) {
                    header.span += hole.span;
                    link.* = next;
                } else {
                    const rest: *Hole = @ptrFromInt(end + more);
                    rest.* = .{ .next = next, .span = left };
                    link.* = rest;
                    header.span = need;
                }
                return true;
            }
            return false;
        }
    };
}

/// What a block of `size` bytes spans, header included and rounded to the
/// alignment, or null for nothing and for a size that would not fit in an
/// address.
fn needFor(size: usize) ?usize {
    if (size == 0 or size > std.math.maxInt(usize) - 2 * ALIGN) return null;
    return std.mem.alignForward(usize, size + HEADER, ALIGN);
}

fn classOf(need: usize) ?u3 {
    if (need > CLASS_MAX) return null;
    var class: u3 = 0;
    while (widthOf(class) < need) class += 1;
    return class;
}

fn widthOf(class: u3) usize {
    return @as(usize, ALIGN) << class;
}

fn headerAt(block: [*]u8) *Header {
    return @ptrCast(@alignCast(block));
}

fn headerOf(pointer: [*]u8) *Header {
    return headerAt(pointer - HEADER);
}

/// How many bytes the block at `pointer` holds, which may be more than it
/// was asked for.
fn capacityOf(pointer: [*]u8) usize {
    return headerOf(pointer).span - HEADER;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Pieces from the host's allocator, kept to be handed back when a test is
/// done, and limited to test a heap whose source runs dry.
const Pieces = struct {
    taken: std.ArrayList([]align(4096) u8) = .empty,
    left: usize = std.math.maxInt(usize),

    pub fn take(self: *Pieces, bytes: usize) ?[]u8 {
        if (bytes > self.left) return null;
        const piece = testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), bytes) catch return null;
        self.taken.append(testing.allocator, piece) catch {
            testing.allocator.free(piece);
            return null;
        };
        self.left -= bytes;
        return piece;
    }

    fn deinit(self: *Pieces) void {
        for (self.taken.items) |piece| testing.allocator.free(piece);
        self.taken.deinit(testing.allocator);
    }
};

const TestHeap = Heap(Pieces);

/// Every hole in address order, none touching the next, which a missed merge
/// would leave. Answers with the free bytes they come to.
fn holesChecked(heap: *const TestHeap) !usize {
    var total: usize = 0;
    var last_end: usize = 0;
    var it = heap.holes;
    while (it) |hole| : (it = hole.next) {
        try testing.expect(@intFromPtr(hole) > last_end);
        last_end = hole.end();
        total += hole.span;
    }
    return total;
}

fn piecesTotal(heap: *const TestHeap) usize {
    var total: usize = 0;
    for (heap.source.taken.items) |piece| total += piece.len;
    return total;
}

test "a small block goes back to its class and out again" {
    var heap: TestHeap = .{ .source = .{} };
    defer heap.source.deinit();

    const a = heap.alloc(24).?;
    try testing.expectEqual(@as(usize, 48), capacityOf(a));
    heap.free(a);
    try testing.expectEqual(a, heap.alloc(40).?);
}

test "every block is aligned and holds what it was asked for" {
    var heap: TestHeap = .{ .source = .{} };
    defer heap.source.deinit();

    for ([_]usize{ 1, 15, 16, 17, 2031, 2032, 2033, 5000, 100_000 }) |size| {
        const block = heap.alloc(size).?;
        try testing.expect(std.mem.isAligned(@intFromPtr(block), ALIGN));
        try testing.expect(capacityOf(block) >= size);
        @memset(block[0..size], 0xA5);
    }
}

test "nothing, and more than an address can count, are refused" {
    var heap: TestHeap = .{ .source = .{} };
    defer heap.source.deinit();

    try testing.expectEqual(@as(?[*]u8, null), heap.alloc(0));
    try testing.expectEqual(@as(?[*]u8, null), heap.alloc(std.math.maxInt(usize)));
    try testing.expectEqual(@as(?[*]u8, null), heap.alloc(std.math.maxInt(usize) - 20));
}

test "a large block given back merges with the holes either side of it" {
    var heap: TestHeap = .{ .source = .{} };
    defer heap.source.deinit();

    const a = heap.alloc(10_000).?;
    const b = heap.alloc(10_000).?;
    const c = heap.alloc(10_000).?;
    heap.free(a);
    heap.free(c);
    heap.free(b);

    // One hole from where `a` was to the end of the piece.
    try testing.expectEqual(piecesTotal(&heap), try holesChecked(&heap));
    try testing.expect(heap.holes.?.next == null);
    try testing.expectEqual(a, heap.alloc(30_000).?);
}

test "a block grows where it is into the free memory behind it" {
    var heap: TestHeap = .{ .source = .{} };
    defer heap.source.deinit();

    const a = heap.alloc(4000).?;
    @memset(a[0..4000], 0xAB);
    try testing.expect(heap.resize(a, 20_000));
    try testing.expect(capacityOf(a) >= 20_000);

    // A block cut right behind it is in the way of growing again.
    const b = heap.alloc(4000).?;
    try testing.expectEqual(@intFromPtr(a) + capacityOf(a) + HEADER, @intFromPtr(b));
    try testing.expect(!heap.resize(a, 40_000));

    const moved = heap.realloc(a, 40_000).?;
    try testing.expect(moved != a);
    for (moved[0..4000]) |byte| try testing.expectEqual(@as(u8, 0xAB), byte);
}

test "a block shrunk gives back the end it no longer needs" {
    var heap: TestHeap = .{ .source = .{} };
    defer heap.source.deinit();

    const a = heap.alloc(50_000).?;
    try testing.expect(heap.resize(a, 3000));
    try testing.expect(capacityOf(a) < 4000);
    const b = heap.alloc(40_000).?;
    try testing.expectEqual(@intFromPtr(a) + capacityOf(a) + HEADER, @intFromPtr(b));
}

test "pieces double, so hundreds of blocks come from a handful of them" {
    // What the kernel's budget asks for: sixty-four mappings a process, and
    // most of them spoken for by its windows and its rings.
    var heap: TestHeap = .{ .source = .{} };
    defer heap.source.deinit();

    for (0..400) |_| _ = heap.alloc(32 * 1024) orelse return error.TestUnexpectedResult;
    try testing.expect(heap.source.taken.items.len <= 10);
}

test "a request larger than half a piece gets one of its own, sized to it" {
    var heap: TestHeap = .{ .source = .{} };
    defer heap.source.deinit();

    const size = 3 * 1024 * 1024;
    _ = heap.alloc(size).?;
    try testing.expectEqual(@as(usize, 1), heap.source.taken.items.len);
    try testing.expect(heap.source.taken.items[0].len < size + 4096);
}

test "a heap whose source has run dry says so, and still serves what it has" {
    var heap: TestHeap = .{ .source = .{ .left = 64 * 1024 } };
    defer heap.source.deinit();

    const a = heap.alloc(20_000).?;
    try testing.expectEqual(@as(?[*]u8, null), heap.alloc(200_000));
    heap.free(a);
    _ = heap.alloc(40_000).?;
}

test "churn leaves every block intact and every byte accounted for" {
    var heap: TestHeap = .{ .source = .{} };
    defer heap.source.deinit();

    const Live = struct { block: [*]u8, len: usize, seed: u8 };
    var live: [48]?Live = @splat(null);
    var prng = std.Random.DefaultPrng.init(0x7ea5);
    const random = prng.random();

    const fill = struct {
        fn run(held: Live) void {
            for (held.block[0..held.len], 0..) |*byte, i| byte.* = held.seed +% @as(u8, @truncate(i));
        }
        fn check(held: Live, len: usize) !void {
            for (held.block[0..len], 0..) |byte, i| try testing.expectEqual(held.seed +% @as(u8, @truncate(i)), byte);
        }
    };

    for (0..3000) |step| {
        const slot = random.uintLessThan(usize, live.len);
        const size = if (random.uintLessThan(u8, 10) < 7)
            random.intRangeAtMost(usize, 1, 2000)
        else
            random.intRangeAtMost(usize, 2001, 40_000);
        const seed: u8 = @truncate(step);

        if (live[slot]) |held| {
            try fill.check(held, held.len);
            if (random.boolean()) {
                heap.free(held.block);
                live[slot] = null;
            } else {
                const block = heap.realloc(held.block, size).?;
                try fill.check(.{ .block = block, .len = held.len, .seed = held.seed }, @min(held.len, size));
                live[slot] = .{ .block = block, .len = size, .seed = seed };
                fill.run(live[slot].?);
            }
        } else {
            live[slot] = .{ .block = heap.alloc(size).?, .len = size, .seed = seed };
            fill.run(live[slot].?);
        }
        _ = try holesChecked(&heap);
    }

    for (live) |maybe| {
        const held = maybe orelse continue;
        try fill.check(held, held.len);
        heap.free(held.block);
    }
    // Every byte of every piece is free again but for the runs the classes
    // were cut from, which stay with the classes.
    const runs = piecesTotal(&heap) - try holesChecked(&heap);
    try testing.expect(runs % ALIGN == 0);
    try testing.expect(runs <= 8 * RUN + heap.run.len);
}
