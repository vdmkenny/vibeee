//! Kernel heap: a slab allocator over the physical frame allocator, exposed as
//! a `std.mem.Allocator`.
//!
//! Exposing the standard interface is the whole point, kernel code then reads
//! like ordinary Zig (`try alloc.create(Process)`), and anything allocator-
//! generic from the standard library works unchanged.
//!
//! Slabs are single frames carved into equal objects, with the free list woven
//! through the free objects themselves, so per-object overhead is zero while
//! allocated. Requests larger than the biggest size class go straight to whole
//! frames. There is no coalescing and no compaction: a kernel's allocation
//! pattern is dominated by a handful of fixed-size object types, which is
//! exactly the case slabs handle without fragmenting.
//!
//! See design/00-vibeee.md §6.3.

const std = @import("std");
const pmm = @import("pmm.zig");
const hal = @import("hal.zig");

/// Size classes, in bytes. Chosen to cover the kernel's real object sizes with
/// a worst-case internal waste just under 2x.
const CLASSES = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };

const FRAME = pmm.PAGE_SIZE;

/// Header at the base of every slab. Objects start after it, which is why the
/// usable capacity is a little under a frame.
const Slab = struct {
    next: ?*Slab,
    free: ?*FreeObject,
    class: usize,
    in_use: usize,
};

const FreeObject = struct {
    next: ?*FreeObject,
};

const Class = struct {
    size: usize,
    /// Slabs with at least one free object.
    partial: ?*Slab = null,
    /// Slabs handed out entirely; kept so statistics stay honest.
    full: ?*Slab = null,
};

var classes: [CLASSES.len]Class = undefined;
var stats_bytes_live: usize = 0;
var stats_frames: usize = 0;
var initialised = false;

pub fn init() void {
    for (&classes, CLASSES) |*c, size| c.* = .{ .size = size };
    stats_bytes_live = 0;
    stats_frames = 0;
    initialised = true;
}

fn classFor(len: usize, alignment: usize) ?usize {
    for (CLASSES, 0..) |size, i| {
        // Objects are placed at multiples of the class size from a
        // frame-aligned base, so a class satisfies any alignment that divides
        // it. Anything stricter falls through to whole frames.
        if (len <= size and alignment <= size and size % alignment == 0) return i;
    }
    return null;
}

fn growClass(idx: usize) ?*Slab {
    const phys = pmm.allocFrame() catch return null;
    stats_frames += 1;

    const base = hal.physToVirt(phys);
    const slab: *Slab = @ptrFromInt(base);
    const size = classes[idx].size;

    // Keep objects aligned to their own size by starting them at the first
    // multiple of `size` past the header.
    const first = std.mem.alignForward(usize, @sizeOf(Slab), size);
    const count = (FRAME - first) / size;

    slab.* = .{ .next = null, .free = null, .class = idx, .in_use = 0 };

    // Thread the free list through the objects, back to front, so the list
    // comes out in ascending address order, kinder to the cache on the common
    // pattern of allocating a run of objects at once.
    var i = count;
    while (i > 0) {
        i -= 1;
        const obj: *FreeObject = @ptrFromInt(base + first + i * size);
        obj.next = slab.free;
        slab.free = obj;
    }

    slab.next = classes[idx].partial;
    classes[idx].partial = slab;
    return slab;
}

/// Recover the slab header from an object address: slabs are frame-aligned, so
/// the header is simply the containing frame's base.
fn slabOf(ptr: usize) *Slab {
    return @ptrFromInt(std.mem.alignBackward(usize, ptr, FRAME));
}

fn allocClass(idx: usize) ?[*]u8 {
    const slab = classes[idx].partial orelse growClass(idx) orelse return null;
    const obj = slab.free orelse return null;
    slab.free = obj.next;
    slab.in_use += 1;

    if (slab.free == null) {
        // Fully allocated: move it off the partial list so the fast path never
        // walks a slab it cannot serve from.
        classes[idx].partial = slab.next;
        slab.next = classes[idx].full;
        classes[idx].full = slab;
    }

    stats_bytes_live += classes[idx].size;
    return @ptrCast(obj);
}

fn freeClass(slab: *Slab, ptr: [*]u8) void {
    const idx = slab.class;
    const was_full = slab.free == null;

    const obj: *FreeObject = @ptrCast(@alignCast(ptr));
    obj.next = slab.free;
    slab.free = obj;
    slab.in_use -= 1;
    stats_bytes_live -= classes[idx].size;

    if (was_full) {
        unlink(&classes[idx].full, slab);
        slab.next = classes[idx].partial;
        classes[idx].partial = slab;
        return;
    }

    // An empty slab returns its frame. Kernel allocation is bursty, driver
    // probing, then quiet, so handing the memory back matters more than
    // keeping a cache warm for a burst that may never repeat.
    if (slab.in_use == 0) {
        unlink(&classes[idx].partial, slab);
        pmm.freeFrame(hal.virtToPhys(@intFromPtr(slab)));
        stats_frames -= 1;
    }
}

fn unlink(head: *?*Slab, target: *Slab) void {
    var cur = head;
    while (cur.*) |s| {
        if (s == target) {
            cur.* = s.next;
            return;
        }
        cur = &s.next;
    }
}

fn framesFor(len: usize) usize {
    return (len + FRAME - 1) / FRAME;
}

// ---------------------------------------------------------------------------
// std.mem.Allocator plumbing
// ---------------------------------------------------------------------------

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (!initialised or len == 0) return null;
    const a = alignment.toByteUnits();

    if (classFor(len, a)) |idx| return allocClass(idx);

    // Large or over-aligned: whole frames. Frames are frame-aligned, so any
    // alignment up to a frame is satisfied for free; beyond that we cannot help.
    if (a > FRAME) return null;
    const phys = pmm.allocContiguous(framesFor(len), 0xFFFF_F000) catch return null;
    stats_frames += framesFor(len);
    stats_bytes_live += framesFor(len) * FRAME;
    return @ptrFromInt(hal.physToVirt(phys));
}

fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
    const a = alignment.toByteUnits();
    if (classFor(memory.len, a)) |idx| {
        // In-place only while it still fits the same class.
        return new_len <= classes[idx].size;
    }
    return framesFor(new_len) == framesFor(memory.len);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    if (resize(ctx, memory, alignment, new_len, ra)) return memory.ptr;
    return null;
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    if (!initialised or memory.len == 0) return;
    const a = alignment.toByteUnits();

    if (classFor(memory.len, a) != null) {
        freeClass(slabOf(@intFromPtr(memory.ptr)), memory.ptr);
        return;
    }

    const n = framesFor(memory.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        pmm.freeFrame(hal.virtToPhys(@intFromPtr(memory.ptr) + i * FRAME));
    }
    stats_frames -= n;
    stats_bytes_live -= n * FRAME;
}

var dummy: u8 = 0;

pub const allocator: std.mem.Allocator = .{
    .ptr = &dummy,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

pub const Stats = struct {
    live_bytes: usize,
    frames: usize,
};

pub fn stats() Stats {
    return .{ .live_bytes = stats_bytes_live, .frames = stats_frames };
}
