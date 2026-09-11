//! The heap: memory a program asks for and gives back.
//!
//! In `ulib` rather than in the C library, because a program written in Zig
//! should be able to do everything a program written in C can. `malloc` is a
//! C-shaped door onto this; the door native code uses is `allocator`, which is
//! the standard interface and therefore works with everything built on it.
//!
//! How blocks are found and given back is `lib.heap`, which is the same on any
//! machine and is tested on the host. What is here is where its memory comes
//! from: shared-memory segments, the only anonymous memory a process can ask
//! for. Mapped private and never handed to anybody, so nothing is shared
//! about them but the call that produced them.
//!
//! Each segment is one of the sixty-four mappings a process may hold, and
//! its windows, its clipboard and its rings hold some of those already. That
//! is why `lib.heap` asks for few segments and large ones, and cuts blocks of
//! every size out of them.

const std = @import("std");
const sys = @import("sys");
const lib = @import("lib");

/// What every block is aligned to.
pub const MIN_ALIGN = lib.heap.ALIGN;

/// Segments, as the pieces the heap cuts blocks from.
const Segments = struct {
    /// A segment of `bytes`, mapped.
    ///
    /// The handle goes as soon as the segment is mapped. The mapping holds
    /// the segment as much as the handle does, so the memory stays, and a
    /// handle kept for every piece would be one fewer for the files and
    /// connections a program opens.
    pub fn take(_: *Segments, bytes: usize) ?[]u8 {
        const handle = sys.shmCreate(bytes) catch return null;
        defer sys.close(handle);
        const at = sys.shmMap(handle, .{ .writable = true }) orelse return null;
        return at[0..bytes];
    }
};

var state: lib.heap.Heap(Segments) = .{ .source = .{} };

pub fn alloc(size: usize) ?*anyopaque {
    return @ptrCast(state.alloc(size) orelse return null);
}

pub fn release(pointer: ?*anyopaque) void {
    state.free(@ptrCast(pointer orelse return));
}

pub fn zeroed(count: usize, size: usize) ?*anyopaque {
    const total = std.math.mul(usize, count, size) catch return null;
    const block = alloc(total) orelse return null;
    @memset(@as([*]u8, @ptrCast(block))[0..total], 0);
    return block;
}

/// The block at `pointer`, holding `size` bytes: where it is when it can grow
/// there, and otherwise moved with what it held. What a size of nothing does
/// is C's rule, and `realloc` answers it.
pub fn resize(pointer: ?*anyopaque, size: usize) ?*anyopaque {
    const given = pointer orelse return alloc(size);
    return @ptrCast(state.realloc(@ptrCast(given), size) orelse return null);
}

/// The standard interface, so native code gets `ArrayList`, `dupe`, `alloc`
/// and everything else written against it rather than a private API of ours.
///
/// Alignment beyond what every block already has is refused rather than
/// quietly under-served: sixteen bytes is what anything on this machine needs.
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
    if (alignment.toByteUnits() > MIN_ALIGN) return null;
    return state.alloc(len);
}

fn vtableResize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    return state.resize(memory.ptr, new_len);
}

fn vtableRemap(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    return state.realloc(memory.ptr, new_len);
}

fn vtableFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    state.free(memory.ptr);
}
