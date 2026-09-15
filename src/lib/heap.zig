//! A heap over memory handed to it in large pieces.
//!
//! Requests of two kilobytes and less come from size classes, each twice the
//! width of the last, and a block given back goes on its class's list for the
//! next request of that width. Larger requests are cut from free memory at
//! the size they ask for, and a block given back is merged with whatever free
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
//! Free memory is found and merged without a walk, which is what lets a
//! program churn through hundreds of thousands of blocks at a steady rate.
//! Every block carries its span in front of it and every free block carries
//! it behind as well, so the blocks either side of one given back are found
//! by arithmetic. Free blocks hang on bins by width, each bin holding those
//! from its width up to twice it, so a request takes the first block of the
//! first bin above it and knows it fits.
//!
//! Holds no lock. A program whose threads allocate keeps them out of it at the
//! same time.

const std = @import("std");

/// What every block is aligned to, and the width of the narrowest class.
pub const ALIGN = 16;

/// The widest class. Past it a request is cut to its size, because a class
/// that wide would waste more to its rounding than free memory costs to keep.
const CLASS_MAX = 2048;
const CLASSES = 8; // 16, 32, 64, 128, 256, 512, 1024, 2048

/// How much small blocks are cut from at a time. A class with nothing on its
/// list takes its next block from the current run.
const RUN = 16 * 1024;

/// The first piece asked for, and the most a shared piece grows to.
const PIECE_FIRST = 64 * 1024;
pub const PIECE_MAX = 4 * 1024 * 1024;

/// The least a free block is: its header, the links that hold it on its bin,
/// and its footer. Less than this is given to the block in front of it
/// instead, so nothing too small to hold those is ever free.
const HOLE_MIN = 256;

/// How many bins free blocks hang on: the first holds those of `HOLE_MIN` up
/// to twice it, each after it twice the last, and the last holds everything
/// wider, which is a piece's worth and more.
const BINS = 16;

/// Where the first bin starts, as a shift.
const BIN_FIRST = @ctz(@as(usize, HOLE_MIN));

/// How far into a bin a request looks for a block wide enough before it takes
/// one from a wider bin instead. The blocks in a request's own bin are within
/// a factor of two of it, so a few of them are looked at rather than all.
const FIT_SCAN = 8;

/// In front of every block.
const Header = extern struct {
    kind: Kind,
    /// How many bytes the block spans, this header included, and whether the
    /// block in front of it is free. Every span is a whole number of
    /// alignments, so the lowest bit is the mark's to use.
    marked: usize,

    const FREE_BEFORE: usize = 1;

    fn span(self: *const Header) usize {
        return self.marked & ~FREE_BEFORE;
    }

    fn write(self: *Header, kind: Kind, bytes: usize, free_before: bool) void {
        self.kind = kind;
        self.marked = bytes | @intFromBool(free_before);
    }

    fn setSpan(self: *Header, bytes: usize) void {
        self.marked = bytes | (self.marked & FREE_BEFORE);
    }

    fn freeBefore(self: *const Header) bool {
        return self.marked & FREE_BEFORE != 0;
    }

    fn markFreeBefore(self: *Header, yes: bool) void {
        self.marked = (self.marked & ~FREE_BEFORE) | @intFromBool(yes);
    }

    fn end(self: *Header) [*]u8 {
        return @as([*]u8, @ptrCast(self)) + self.span();
    }

    /// The block right behind this one, which is a piece's edge at the end
    /// of one.
    fn behind(self: *Header) *Header {
        return headerAt(self.end());
    }
};

const Kind = enum(u32) {
    /// Cut from a piece at the size it was asked for.
    cut = std.math.maxInt(u32),
    /// Free memory, on one of the bins.
    hole = std.math.maxInt(u32) - 1,
    /// The end of a piece: a header with nothing after it, which the block
    /// in front of it stops at.
    edge = std.math.maxInt(u32) - 2,
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

/// What holds a free block on its bin, written where a block in use holds
/// what was put in it.
const Links = extern struct {
    previous: ?[*]u8,
    next: ?[*]u8,
};

comptime {
    std.debug.assert(@sizeOf(Header) <= HEADER);
    std.debug.assert(@sizeOf(Spare) <= HEADER);
    std.debug.assert(HEADER + @sizeOf(Links) + ALIGN <= HOLE_MIN);
    std.debug.assert(HOLE_MIN == @as(usize, 1) << BIN_FIRST);
}

fn linksOf(block: [*]u8) *Links {
    return @ptrCast(@alignCast(block + HEADER));
}

/// The span a free block keeps at its end, where the block behind it reads
/// it to find its front.
fn footerOf(block: [*]u8, span: usize) *usize {
    return @ptrCast(@alignCast(block + span - ALIGN));
}

/// The bin a block of `span` hangs on. Nothing narrower than `HOLE_MIN` is
/// ever free, so the first bin is where the narrowest go.
fn binOf(span: usize) usize {
    std.debug.assert(span >= HOLE_MIN);
    const shift = @bitSizeOf(usize) - 1 - @clz(span);
    return @min(BINS - 1, shift - BIN_FIRST);
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
        /// Free blocks, by width.
        bins: [BINS]?[*]u8 = @splat(null),
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
            const span = header.span();
            switch (kind) {
                .cut => self.giveBack(block[0..span]),
                .hole, .edge => unreachable,
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
            if (header.kind != .cut) return need <= header.span();
            if (need <= header.span()) {
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
            // The mark stays as it was: what stands in front of a block is
            // the tiling's business and not the block's.
            headerAt(block).kind = @enumFromInt(class);
            headerAt(block).setSpan(width);
            return block;
        }

        fn fromRun(self: *Self, width: usize) ?[*]u8 {
            if (self.run.len < width) {
                self.abandonRun();
                self.run = self.take(RUN) orelse return null;
            }
            const block = self.run.ptr;
            self.run = self.run[width..];
            // Each block cut from the run stands in front of the next, so
            // nothing in a run is ever free to the tiling.
            headerAt(block).write(.cut, width, headerAt(block).freeBefore());
            if (self.run.len > 0) headerAt(self.run.ptr).write(.cut, self.run.len, false);
            return block;
        }

        /// Let go of what is left of the run: as free memory where there is
        /// enough of it to be, and otherwise as a block nothing holds, which
        /// keeps the blocks either side of it able to find each other.
        fn abandonRun(self: *Self) void {
            const left = self.run;
            self.run = &.{};
            if (left.len == 0) return;
            if (left.len < HOLE_MIN) {
                headerAt(left.ptr).write(.cut, left.len, headerAt(left.ptr).freeBefore());
                return;
            }
            self.giveBack(left);
        }

        fn cut(self: *Self, need: usize) ?[*]u8 {
            const span = self.take(need) orelse return null;
            headerAt(span.ptr).kind = .cut;
            return span.ptr;
        }

        /// `need` bytes of free memory, from the bins or from a new piece,
        /// as a block in use: a little more where what would be left of the
        /// block it came from is too small to keep.
        fn take(self: *Self, need: usize) ?[]u8 {
            if (self.fit(need)) |span| return span;
            if (!self.fetch(need)) return null;
            return self.fit(need);
        }

        /// A free block of at least `need` bytes, taken off its bin and made
        /// a block in use. The first of the bin above what is asked for fits
        /// whatever its width; the bin the request itself falls in holds
        /// blocks either side of it, so a few of those are looked at first.
        fn fit(self: *Self, need: usize) ?[]u8 {
            const bin = binOf(@max(need, HOLE_MIN));
            var looked: usize = 0;
            var at = self.bins[bin];
            while (at) |block| : (at = linksOf(block).next) {
                if (headerAt(block).span() >= need) return self.claim(block, need);
                looked += 1;
                if (looked == FIT_SCAN) break;
            }
            for (self.bins[bin + 1 ..]) |wider| {
                if (wider) |block| return self.claim(block, need);
            }
            // Nothing wider is free, so the rest of the request's own bin is
            // worth the walk before a piece is asked for.
            while (at) |block| : (at = linksOf(block).next) {
                if (headerAt(block).span() >= need) return self.claim(block, need);
            }
            return null;
        }

        /// Take `block` off its bin and make the front of it a block in use
        /// of `need` bytes, the rest staying free where there is enough of
        /// it to be.
        fn claim(self: *Self, block: [*]u8, need: usize) []u8 {
            const span = headerAt(block).span();
            self.unlink(block);
            const left = span - need;
            if (left < HOLE_MIN) {
                headerAt(block).write(.cut, span, false);
                headerAt(block).behind().markFreeBefore(false);
                return block[0..span];
            }
            headerAt(block).write(.cut, need, false);
            // The front is taken and the rest stays free, so a block that
            // grows finds free memory right behind it.
            self.hang(block + need, left);
            return block[0..need];
        }

        /// Ask the source for a piece with room for `need`.
        fn fetch(self: *Self, need: usize) bool {
            const want = need + ALIGN;
            const own = want > PIECE_MAX / 2;
            const piece = self.source.take(if (own) want else @max(self.piece, want)) orelse return false;
            std.debug.assert(std.mem.isAligned(@intFromPtr(piece.ptr), ALIGN));
            std.debug.assert(piece.len % ALIGN == 0);
            if (!own and self.piece < PIECE_MAX) self.piece *= 2;
            // The last alignment of a piece says where it ends, so a block
            // at the end of one never reads past it.
            const body = piece[0 .. piece.len - ALIGN];
            headerAt(body.ptr + body.len).write(.edge, 0, false);
            self.hang(body.ptr, body.len);
            return true;
        }

        /// Make the block at `at` free memory of `span` bytes and hang it on
        /// its bin. Nothing in front of it is free, since free memory that
        /// touches is merged.
        fn hang(self: *Self, at: [*]u8, span: usize) void {
            headerAt(at).write(.hole, span, false);
            footerOf(at, span).* = span;
            headerAt(at).behind().markFreeBefore(true);
            const bin = binOf(span);
            linksOf(at).* = .{ .previous = null, .next = self.bins[bin] };
            if (self.bins[bin]) |first| linksOf(first).previous = at;
            self.bins[bin] = at;
        }

        /// Take a free block off its bin, leaving its header as it is.
        fn unlink(self: *Self, at: [*]u8) void {
            const links = linksOf(at);
            if (links.previous) |previous| {
                linksOf(previous).next = links.next;
            } else {
                self.bins[binOf(headerAt(at).span())] = links.next;
            }
            if (links.next) |next| linksOf(next).previous = links.previous;
        }

        /// Make `span` free memory, merged with the free memory it touches.
        /// Its header says what stands in front of it, which the caller has
        /// written where the span was not a block already.
        fn giveBack(self: *Self, span: []u8) void {
            var at = span.ptr;
            var total = span.len;
            if (headerAt(at).freeBefore()) {
                const before = footerOf(at, 0).*;
                at -= before;
                total += before;
                std.debug.assert(headerAt(at).kind == .hole);
                std.debug.assert(headerAt(at).span() == before);
                self.unlink(at);
            }
            const after = at + total;
            if (headerAt(after).kind == .hole) {
                total += headerAt(after).span();
                self.unlink(after);
            }
            self.hang(at, total);
        }

        /// Give back the end of a cut block it no longer needs, where that
        /// is enough to keep as free memory.
        fn shrink(self: *Self, header: *Header, need: usize) void {
            const span = header.span();
            // What is left behind has to be worth keeping, and what the
            // block keeps has to be enough to be free memory itself when it
            // is given back in its turn.
            if (span - need < HOLE_MIN or need < HOLE_MIN) return;
            const block: [*]u8 = @ptrCast(header);
            header.setSpan(need);
            headerAt(block + need).write(.cut, span - need, false);
            self.giveBack(block[need..span]);
        }

        /// Grow a cut block into the free memory right behind it, when there
        /// is some and it is large enough.
        fn extend(self: *Self, header: *Header, need: usize) bool {
            const span = header.span();
            const after = header.end();
            const behind = headerAt(after);
            if (behind.kind != .hole) return false;
            const more = need - span;
            if (behind.span() < more) return false;
            const room = behind.span();
            self.unlink(after);
            const left = room - more;
            if (left < HOLE_MIN) {
                header.setSpan(span + room);
                header.behind().markFreeBefore(false);
            } else {
                header.setSpan(need);
                self.hang(after + more, left);
            }
            return true;
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
    return headerOf(pointer).span() - HEADER;
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

/// Walk every piece block by block: each block's span tiles the piece, each
/// block's mark says truly whether the block in front of it is free, no two
/// free blocks touch, and every free block's footer says what its header
/// says. Answers with the free bytes they come to.
fn freeChecked(heap: *const TestHeap) !usize {
    var total: usize = 0;
    for (heap.source.taken.items) |piece| {
        const start: [*]u8 = piece.ptr;
        const edge = start + piece.len - ALIGN;
        var at = start;
        var free_before = false;
        while (@intFromPtr(at) < @intFromPtr(edge)) {
            const header = headerAt(at);
            const span = header.span();
            try testing.expectEqual(free_before, header.freeBefore());
            try testing.expect(span >= ALIGN and span % ALIGN == 0);
            try testing.expect(@intFromPtr(at) + span <= @intFromPtr(edge));
            free_before = header.kind == .hole;
            if (free_before) {
                try testing.expectEqual(span, footerOf(at, span).*);
                total += span;
            }
            at += span;
        }
        try testing.expectEqual(@intFromPtr(edge), @intFromPtr(at));
        try testing.expectEqual(Kind.edge, headerAt(edge).kind);
        try testing.expectEqual(free_before, headerAt(edge).freeBefore());
    }
    return total;
}

/// How many free blocks hang on the bins, each on the bin for its width.
fn freeBlocks(heap: *const TestHeap) !usize {
    var count: usize = 0;
    for (heap.bins, 0..) |bin, index| {
        var at = bin;
        var previous: ?[*]u8 = null;
        while (at) |block| : (at = linksOf(block).next) {
            try testing.expectEqual(Kind.hole, headerAt(block).kind);
            try testing.expectEqual(index, binOf(headerAt(block).span()));
            try testing.expectEqual(previous, linksOf(block).previous);
            previous = block;
            count += 1;
        }
    }
    return count;
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

    // One run of free memory from where `a` was to the end of the piece,
    // the last alignment of it aside, which says where the piece ends.
    try testing.expectEqual(piecesTotal(&heap) - ALIGN, try freeChecked(&heap));
    try testing.expectEqual(@as(usize, 1), try freeBlocks(&heap));
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
        _ = try freeChecked(&heap);
        _ = try freeBlocks(&heap);
    }

    for (live) |maybe| {
        const held = maybe orelse continue;
        try fill.check(held, held.len);
        heap.free(held.block);
    }
    // Every byte of every piece is free again but for the runs the classes
    // were cut from, which stay with the classes.
    const spoken_for = piecesTotal(&heap) - try freeChecked(&heap);
    try testing.expect(spoken_for % ALIGN == 0);
    // The runs the classes were cut from stay with the classes, and each
    // piece keeps an alignment for its edge.
    try testing.expect(spoken_for <= 8 * RUN + heap.run.len + ALIGN * heap.source.taken.items.len);
}
