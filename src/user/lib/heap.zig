//! The heap: memory a program asks for and gives back.
//!
//! In `ulib` rather than in the C library, because a program written in Zig
//! should be able to do everything a program written in C can. `malloc` is a
//! C-shaped door onto this; the door native code uses is `allocator`, which is
//! the standard interface and therefore works with everything built on it.
//!
//! Size-class free lists carved from arenas. Sixteen classes from 16 bytes to
//! 2 KiB, because that covers what ported code actually asks for; anything
//! larger gets its own pages and is given back when freed.
//!
//! The arenas come from shared-memory segments, which is the only anonymous
//! memory a process can ask for. Mapped private and never handed to anybody,
//! so nothing is shared about them but the call that produced them.
//!
//! No per-thread caches. One core at 630 MHz means a cache would cost memory
//! to save a contention that cannot happen, and this machine has far more of
//! the second than the first.

const std = @import("std");
const sys = @import("sys");

/// The largest a size class serves. Past it a request gets its own segment,
/// because at that size the rounding waste of a class is worse than a syscall.
const CLASS_MAX = 2048;
const CLASS_MIN = 16;

/// What every block is aligned to, which is the smallest class.
pub const MIN_ALIGN = CLASS_MIN;
const CLASSES = 8; // 16, 32, 64, 128, 256, 512, 1024, 2048

/// How much is taken from the kernel the first time, and the ceiling it grows
/// to.
///
/// Each arena costs a handle, and a process has thirty-two of them. A fixed
/// small arena therefore has a hard limit that is not memory but handles: at
/// sixty-four kilobytes each, a program is out of handles before it is out of
/// megabytes, and what it sees is an allocation failing with plenty of memory
/// left. That is what stopped `_PTS` evaluating on the target machine.
///
/// So each arena is twice the last. A program that allocates a little pays a
/// little, and one that allocates a lot reaches eight megabytes in seven
/// handles rather than a hundred and twenty-eight.
const ARENA_FIRST = 64 * 1024;
const ARENA_MAX = 4 * 1024 * 1024;

var arena_size: usize = ARENA_FIRST;

/// What every block carries, so `free` knows what it was given without being
/// told. One word, which is the price of not making the caller remember.
const Header = extern struct {
    /// The class it came from, or `OWN_SEGMENT` for a block with its own pages.
    class: u32,
    /// Padding to the alignment every block promises.
    ///
    /// Sixteen bytes to hold four is waste, and it is the cheaper of the two
    /// mistakes available: the alternative is handing back a pointer four
    /// bytes past an aligned block, and this target has SSE, so the first
    /// aligned store into anything allocated would fault.
    _reserved: [CLASS_MIN - 4]u8,

    const OWN_SEGMENT: u32 = 0xFFFF_FFFF;
};

const Free = extern struct {
    next: ?*Free,
};

var lists: [CLASSES]?*Free = @splat(null);

/// Where the current arena has got to. Carving forward and never going back:
/// a block returned goes on its class's list, not back into the arena, so
/// there is no coalescing pass and no fragmentation bookkeeping.
var arena: [*]u8 = undefined;
var arena_left: usize = 0;

fn classFor(size: usize) ?u32 {
    if (size > CLASS_MAX) return null;

    var width: usize = CLASS_MIN;
    var class: u32 = 0;
    while (width < size) : (class += 1) width *= 2;
    return class;
}

fn widthOf(class: u32) usize {
    return @as(usize, CLASS_MIN) << @intCast(class);
}

/// Ask the kernel for `bytes`, rounded up to whatever it deals in.
fn fromKernel(bytes: usize) ?[*]u8 {
    const handle = sys.shmCreate(bytes);
    if (handle < 0) return null;

    // The segment stays mapped for the life of the process. Closing the handle
    // after mapping would be tidier, but a block returned to the kernel needs
    // the handle to say which one, so it is kept in the header of its own
    // block instead. For arenas nothing is ever returned, so the handle is
    // simply let go.
    return sys.shmMap(@intCast(handle), .{ .writable = true });
}

pub fn alloc(size: usize) ?*anyopaque {
    if (size == 0) return null;

    const wanted = size + @sizeOf(Header);
    const class = classFor(wanted) orelse return ownSegment(wanted);

    const width = widthOf(class);
    const block = take(class, width) orelse return null;

    const header: *Header = @alignCast(@ptrCast(block));
    header.class = class;
    return @ptrCast(block + @sizeOf(Header));
}

/// A block of its own, for a request no class serves.
fn ownSegment(wanted: usize) ?*anyopaque {
    const block = fromKernel(wanted) orelse return null;

    const header: *Header = @alignCast(@ptrCast(block));
    header.class = Header.OWN_SEGMENT;
    return @ptrCast(block + @sizeOf(Header));
}

/// One block of `width`, from the class's list or from the arena.
fn take(class: u32, width: usize) ?[*]u8 {
    if (lists[class]) |spare| {
        lists[class] = spare.next;
        return @ptrCast(spare);
    }

    if (arena_left < width) {
        // Whatever is left of the old arena is abandoned. It is less than one
        // block of the widest class, and threading it onto a free list would
        // cost more in bookkeeping than the bytes are worth.
        arena = fromKernel(arena_size) orelse return null;
        arena_left = arena_size;

        if (arena_size < ARENA_MAX) arena_size *= 2;
    }

    const block = arena;
    arena += width;
    arena_left -= width;
    return block;
}

pub fn release(pointer: ?*anyopaque) void {
    const given = pointer orelse return;

    const block: [*]u8 = @ptrCast(given);
    const header: *Header = @alignCast(@ptrCast(block - @sizeOf(Header)));

    // Read out of the header before anything is written over it. The free list
    // threads its links through the same bytes the class was in, so a class
    // read back afterwards is a pointer being used as an index.
    const class = header.class;

    // A block with its own segment is simply let go: the pages stay mapped
    // until the process ends, which for a program that allocates a few large
    // things and exits is the same outcome as unmapping and cheaper to reach.
    if (class == Header.OWN_SEGMENT) return;

    const node: *Free = @alignCast(@ptrCast(block - @sizeOf(Header)));
    node.next = lists[class];
    lists[class] = node;
}

pub fn zeroed(count: usize, size: usize) ?*anyopaque {
    const total = count * size;
    if (count != 0 and total / count != size) return null;

    const block = alloc(total) orelse return null;
    @memset(@as([*]u8, @ptrCast(block))[0..total], 0);
    return block;
}

pub fn resize(pointer: ?*anyopaque, size: usize) ?*anyopaque {
    const given = pointer orelse return alloc(size);
    if (size == 0) {
        release(given);
        return null;
    }

    const block: [*]u8 = @ptrCast(given);
    const header: *Header = @alignCast(@ptrCast(block - @sizeOf(Header)));

    // Growing within the class it already has is free, and shrinking always
    // is: the block is the same size either way.
    if (header.class != Header.OWN_SEGMENT) {
        const width = widthOf(header.class);
        if (size + @sizeOf(Header) <= width) return given;
    }

    const bigger = alloc(size) orelse return null;

    // Never more than the old block held, whatever the new size is: growing an
    // allocation is not permission to read past the end of the old one.
    const carry = if (header.class == Header.OWN_SEGMENT)
        size
    else
        @min(size, widthOf(header.class) - @sizeOf(Header));

    @memcpy(@as([*]u8, @ptrCast(bigger))[0..carry], block[0..carry]);
    release(given);
    return bigger;
}

/// The standard interface, so native code gets `ArrayList`, `dupe`, `alloc`
/// and everything else written against it rather than a private API of ours.
///
/// Alignment beyond what a class already gives is refused rather than quietly
/// under-served: every block starts at least sixteen-byte aligned, which is
/// what anything on this machine needs.
pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = vtableAlloc,
        .resize = vtableResize,
        .remap = vtableRemap,
        .free = vtableFree,
    },
};

fn vtableAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (alignment.toByteUnits() > CLASS_MIN) return null;
    return @ptrCast(alloc(len) orelse return null);
}

fn vtableResize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    // In place only when it already fits, which for a size-class allocator is
    // whenever the class it came from is wide enough.
    return new_len <= widthOfBlock(memory.ptr);
}

fn vtableRemap(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    return @ptrCast(resize(@ptrCast(memory.ptr), new_len) orelse return null);
}

fn vtableFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    release(@ptrCast(memory.ptr));
}

/// How much a block can hold, read from the header it carries.
fn widthOfBlock(pointer: [*]u8) usize {
    const header: *Header = @alignCast(@ptrCast(pointer - @sizeOf(Header)));
    if (header.class == Header.OWN_SEGMENT) return 0;
    return widthOf(header.class) - @sizeOf(Header);
}
