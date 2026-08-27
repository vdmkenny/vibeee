//! `malloc` and friends: the C-shaped door onto `ulib.heap`.
//!
//! The heap itself is not here, and deliberately. A program written in Zig
//! should be able to do everything a program written in C can, so the
//! allocator lives where both can reach it and this is the half that speaks
//! C: null-for-failure becomes null-with-`errno`, and the names become the
//! ones a port expects to find.

const errno = @import("errno.zig");
const heap = @import("ulib").heap;

export fn malloc(size: usize) callconv(.c) ?*anyopaque {
    return heap.alloc(size) orelse fail();
}

export fn free(pointer: ?*anyopaque) callconv(.c) void {
    heap.release(pointer);
}

export fn calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    return heap.zeroed(count, size) orelse fail();
}

export fn realloc(pointer: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (size == 0) {
        heap.release(pointer);
        return null;
    }
    return heap.resize(pointer, size) orelse fail();
}

/// Every block is at least sixteen-byte aligned already. Anything stricter is
/// refused rather than quietly under-aligned, because a caller that asked for
/// a page boundary and got sixteen bytes has no way to find out.
export fn posix_memalign(out: **anyopaque, alignment: usize, size: usize) callconv(.c) c_int {
    if (alignment == 0 or alignment & (alignment - 1) != 0) return errno.EINVAL;
    if (alignment > heap.MIN_ALIGN) return errno.EINVAL;

    out.* = heap.alloc(size) orelse return errno.ENOMEM;
    return 0;
}

fn fail() ?*anyopaque {
    errno.set(errno.ENOMEM);
    return null;
}
