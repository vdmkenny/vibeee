//! malloc, over pages the kernel hands out.
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

const errno = @import("errno.zig");
const sys = @import("sys");

/// The largest a size class serves. Past it a request gets its own segment,
/// because at that size the rounding waste of a class is worse than a syscall.
const CLASS_MAX = 2048;
const CLASS_MIN = 16;
const CLASSES = 8; // 16, 32, 64, 128, 256, 512, 1024, 2048

/// How much is taken from the kernel at once. Large enough that a program
/// allocating steadily is not making a syscall every few objects, small enough
/// that a program allocating once is not holding a megabyte to do it.
const ARENA = 64 * 1024;

/// What every block carries, so `free` knows what it was given without being
/// told. One word, which is the price of not making the caller remember.
const Header = extern struct {
    /// The class it came from, or `OWN_SEGMENT` for a block with its own pages.
    class: u32,

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

pub export fn malloc(size: usize) callconv(.c) ?*anyopaque {
    if (size == 0) return null;

    const wanted = size + @sizeOf(Header);
    const class = classFor(wanted) orelse return ownSegment(wanted);

    const width = widthOf(class);
    const block = take(class, width) orelse {
        errno.set(errno.ENOMEM);
        return null;
    };

    const header: *Header = @alignCast(@ptrCast(block));
    header.class = class;
    return @ptrCast(block + @sizeOf(Header));
}

/// A block of its own, for a request no class serves.
fn ownSegment(wanted: usize) ?*anyopaque {
    const block = fromKernel(wanted) orelse {
        errno.set(errno.ENOMEM);
        return null;
    };

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
        arena = fromKernel(ARENA) orelse return null;
        arena_left = ARENA;
    }

    const block = arena;
    arena += width;
    arena_left -= width;
    return block;
}

pub export fn free(pointer: ?*anyopaque) callconv(.c) void {
    const given = pointer orelse return;

    const block: [*]u8 = @ptrCast(given);
    const header: *Header = @alignCast(@ptrCast(block - @sizeOf(Header)));

    // A block with its own segment is simply let go: the pages stay mapped
    // until the process ends, which for a program that allocates a few large
    // things and exits is the same outcome as unmapping and cheaper to reach.
    if (header.class == Header.OWN_SEGMENT) return;

    const node: *Free = @alignCast(@ptrCast(block - @sizeOf(Header)));
    node.next = lists[header.class];
    lists[header.class] = node;
}

pub export fn calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    const total = count * size;
    if (count != 0 and total / count != size) {
        errno.set(errno.ENOMEM);
        return null;
    }

    const block = malloc(total) orelse return null;
    @memset(@as([*]u8, @ptrCast(block))[0..total], 0);
    return block;
}

pub export fn realloc(pointer: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const given = pointer orelse return malloc(size);
    if (size == 0) {
        free(given);
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

    const bigger = malloc(size) orelse return null;
    const carry = if (header.class == Header.OWN_SEGMENT)
        size
    else
        @min(size, widthOf(header.class) - @sizeOf(Header));

    @memcpy(@as([*]u8, @ptrCast(bigger))[0..carry], block[0..carry]);
    free(given);
    return bigger;
}

/// Aligned to what the class already gives, which is at least sixteen bytes
/// and always a power of two. Anything stricter is refused rather than
/// silently under-aligned.
export fn posix_memalign(out: **anyopaque, alignment: usize, size: usize) callconv(.c) c_int {
    if (alignment == 0 or alignment & (alignment - 1) != 0) return errno.EINVAL;
    if (alignment > CLASS_MIN) return errno.EINVAL;

    out.* = malloc(size) orelse return errno.ENOMEM;
    return 0;
}
