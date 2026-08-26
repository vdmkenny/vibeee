//! Physical memory manager: a flat bitmap over 4 KiB page frames.
//!
//! For 512 MB the bitmap is 16 KiB — small enough to keep permanently resident
//! and scan with `@ctz` over u32 words. A buddy allocator would buy contiguous
//! multi-frame allocation, but the only consumers of that on this machine are
//! DMA buffers (EHCI schedules, HDA rings, NIC rings), which are few, early,
//! and long-lived. Those are served from a dedicated low arena instead, which
//! keeps the general allocator to a single bit per frame.
//!
//! See design/00-vibeee.md §6.1.

const std = @import("std");
const bootinfo = @import("bootinfo.zig");
const console = @import("console.zig");
const hal = @import("hal.zig");

/// Re-exported from the HAL rather than redefined: one definition of the page
/// size for the whole kernel.
pub const PAGE_SIZE = hal.PAGE_SIZE;
pub const PAGE_SHIFT = hal.PAGE_SHIFT;

const Word = u32;
const BITS_PER_WORD = @bitSizeOf(Word);

/// Enough bitmap for 4 GiB of frames. Statically reserved (128 KiB of .bss)
/// rather than bootstrapped out of the heap, because the allocator that would
/// allocate it is the thing we are building.
const MAX_FRAMES: usize = @as(u64, 4) * 1024 * 1024 * 1024 / PAGE_SIZE;
var bitmap: [MAX_FRAMES / BITS_PER_WORD]Word = undefined;

var total_frames: usize = 0;
var free_frames: usize = 0;
/// Frames below this are never handed out: real-mode IVT/BDA, the BootInfo
/// struct, the panic ring, and the kernel image itself.
var lowest_usable: usize = 0;
var next_hint: usize = 0;

pub const Stats = struct {
    total_frames: usize,
    free_frames: usize,
    pub fn totalBytes(self: Stats) usize {
        return self.total_frames * PAGE_SIZE;
    }
    pub fn freeBytes(self: Stats) usize {
        return self.free_frames * PAGE_SIZE;
    }
};

inline fn testBit(frame: usize) bool {
    return (bitmap[frame / BITS_PER_WORD] & (@as(Word, 1) << @intCast(frame % BITS_PER_WORD))) != 0;
}

inline fn setBit(frame: usize) void {
    bitmap[frame / BITS_PER_WORD] |= (@as(Word, 1) << @intCast(frame % BITS_PER_WORD));
}

inline fn clearBit(frame: usize) void {
    bitmap[frame / BITS_PER_WORD] &= ~(@as(Word, 1) << @intCast(frame % BITS_PER_WORD));
}

extern const __kernel_phys_start: anyopaque;
extern const __kernel_phys_end: anyopaque;

pub fn init(bi: *const bootinfo.BootInfo) void {
    // Start with everything marked used; free only what the memory map says is
    // usable. Defaulting to "used" means an incomplete or absent memory map
    // fails safe (no memory) rather than unsafe (hand out MMIO as RAM).
    @memset(&bitmap, ~@as(Word, 0));
    total_frames = 0;
    free_frames = 0;

    var highest: usize = 0;

    for (bi.memoryMap()) |r| {
        if (r.kind != .usable) continue;
        // Ignore anything above 4 GiB: this CPU is 32-bit physical.
        const start_addr = r.base;
        const end_addr = @min(r.base +| r.len, 0x1_0000_0000);
        if (end_addr <= start_addr) continue;

        const first = std.mem.alignForward(u64, start_addr, PAGE_SIZE) >> PAGE_SHIFT;
        const last = std.mem.alignBackward(u64, end_addr, PAGE_SIZE) >> PAGE_SHIFT;

        var f: usize = @intCast(first);
        while (f < @as(usize, @intCast(last)) and f < MAX_FRAMES) : (f += 1) {
            if (testBit(f)) {
                clearBit(f);
                free_frames += 1;
            }
            if (f > highest) highest = f;
        }
    }
    total_frames = highest + 1;

    // Carve out the regions that are usable per E820 but must never be handed
    // out. Reserving the first megabyte wholesale costs 256 frames and saves a
    // whole class of subtle bugs (BIOS data area, EBDA, video memory, the
    // trampoline page we will need for S3 resume and for SMP later).
    reserveRange(0, 0x100000);

    const kstart = @intFromPtr(&__kernel_phys_start);
    const kend = @intFromPtr(&__kernel_phys_end);
    reserveRange(kstart, kend);

    // The rootfs blob loaded by stage2 is live until it is decompressed.
    if (bi.rootfs_phys != 0 and bi.rootfs_len != 0) {
        reserveRange(bi.rootfs_phys, bi.rootfs_phys + bi.rootfs_len);
    }

    lowest_usable = 0x100000 / PAGE_SIZE;
    next_hint = lowest_usable;
}

/// Mark [start, end) as unavailable. Safe to call on ranges that are already
/// reserved or partly outside RAM.
pub fn reserveRange(start: usize, end: usize) void {
    if (end <= start) return;
    const first = start >> PAGE_SHIFT;
    const last = std.mem.alignForward(usize, end, PAGE_SIZE) >> PAGE_SHIFT;
    var f = first;
    while (f < last and f < MAX_FRAMES) : (f += 1) {
        if (!testBit(f)) {
            setBit(f);
            if (free_frames > 0) free_frames -= 1;
        }
    }
}

pub const AllocError = error{OutOfMemory};

/// Allocate one frame. Returns a physical address.
pub fn allocFrame() AllocError!usize {
    // Two-pass scan from the rotating hint, so repeated allocation does not
    // rescan the low frames every time.
    if (findFree(next_hint, total_frames)) |f| return take(f);
    if (findFree(lowest_usable, next_hint)) |f| return take(f);
    return error.OutOfMemory;
}

fn take(frame: usize) usize {
    setBit(frame);
    free_frames -= 1;
    next_hint = frame + 1;
    if (next_hint >= total_frames) next_hint = lowest_usable;
    return frame << PAGE_SHIFT;
}

fn findFree(from: usize, to: usize) ?usize {
    if (from >= to) return null;
    var w = from / BITS_PER_WORD;
    const w_end = (to + BITS_PER_WORD - 1) / BITS_PER_WORD;
    while (w < w_end and w < bitmap.len) : (w += 1) {
        if (bitmap[w] == ~@as(Word, 0)) continue; // fully allocated, skip
        const inverted = ~bitmap[w];
        const bit = @ctz(inverted);
        const frame = w * BITS_PER_WORD + bit;
        if (frame >= from and frame < to) return frame;
        // The first free bit in this word is out of range; walk the rest.
        var b: usize = bit;
        while (b < BITS_PER_WORD) : (b += 1) {
            const f = w * BITS_PER_WORD + b;
            if (f >= to) return null;
            if (f >= from and (inverted & (@as(Word, 1) << @intCast(b))) != 0) return f;
        }
    }
    return null;
}

/// Allocate `count` physically contiguous frames. Used for DMA buffers; the
/// linear scan is acceptable because these allocations are rare and early.
pub fn allocContiguous(count: usize, below: usize) AllocError!usize {
    if (count == 0) return error.OutOfMemory;
    const limit = @min(below >> PAGE_SHIFT, total_frames);
    var f = lowest_usable;
    while (f + count <= limit) {
        var run: usize = 0;
        while (run < count and !testBit(f + run)) : (run += 1) {}
        if (run == count) {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                setBit(f + i);
                free_frames -= 1;
            }
            return f << PAGE_SHIFT;
        }
        f += run + 1;
    }
    return error.OutOfMemory;
}

pub fn freeFrame(phys: usize) void {
    const frame = phys >> PAGE_SHIFT;
    if (frame >= MAX_FRAMES) return;
    if (!testBit(frame)) return; // double free — ignore rather than corrupt
    clearBit(frame);
    free_frames += 1;
}

pub fn stats() Stats {
    return .{ .total_frames = total_frames, .free_frames = free_frames };
}

pub fn report() void {
    const s = stats();
    console.printf("       {d} MiB usable, {d} MiB free, {d} frames\n", .{
        s.totalBytes() / (1024 * 1024),
        s.freeBytes() / (1024 * 1024),
        s.total_frames,
    });
}
