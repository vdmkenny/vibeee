//! Physical memory manager: a flat bitmap over 4 KiB page frames.
//!
//! For 512 MB the bitmap is 16 KiB, small enough to keep permanently resident
//! and scan with `@ctz` over u32 words. The policy of where each kind of
//! allocation goes lives in `lib/framemap` and is host-tested there; what is
//! here is the machine's own state: the static words, the boot walk that
//! frees what the firmware called usable, and the ranges that answer
//! "is this the allocator's".
//!
//! The lowest free megabytes are the device band: preferred for DMA runs and
//! avoided by everything else, so a hotplugged disk or a restarted driver
//! finds contiguous memory that weeks of ordinary churn have not
//! checkerboarded. A preference rather than a carve: under real pressure the
//! band is spent like any other memory, because correctness beats placement.
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

const framemap = @import("lib").framemap;
const Word = framemap.Word;

/// Enough bitmap for 4 GiB of frames. Statically reserved (128 KiB of .bss)
/// rather than bootstrapped out of the heap, because the allocator that would
/// allocate it is the thing we are building.
const MAX_FRAMES: usize = @as(u64, 4) * 1024 * 1024 * 1024 / PAGE_SIZE;
var bitmap: [MAX_FRAMES / framemap.BITS_PER_WORD]Word = undefined;

/// Frames below this are never handed out: real-mode IVT/BDA, the BootInfo
/// struct, the panic ring, and the kernel image itself.
const FLOOR_FRAME: usize = 0x100000 / PAGE_SIZE;

/// The device band's budget: eight mebibytes at most, minus whatever of it
/// the kernel image and the boot already hold, and never more than a
/// sixteenth of a small machine. The tally it covers: the two USB controller
/// arenas, two sound arenas, three NIC arenas of one to two hundred
/// kilobytes, and four hotplugged volumes at 64 KiB each, which is under two
/// mebibytes with every port full, the same on 128 MiB as on 4 GiB. Hitting
/// this wall is a reason to ask what grew before it is a reason to double it.
const BAND_CAP: usize = 8 * 1024 * 1024 / PAGE_SIZE;

var map: framemap.Map = undefined;

/// Contiguous asks that found no run. The number `sysinfo mem.dma` reports,
/// so the day fragmentation is real it is an event with evidence rather than
/// a mystery a driver logs once.
var contig_refusals: usize = 0;

pub const Origin = framemap.Origin;

pub const Stats = struct {
    total_frames: usize,
    free_frames: usize,
    /// Contiguous asks that found no run, ever.
    contig_refusals: usize,
    pub fn totalBytes(self: Stats) usize {
        return self.total_frames * PAGE_SIZE;
    }
    pub fn freeBytes(self: Stats) usize {
        return self.free_frames * PAGE_SIZE;
    }
};

extern const __kernel_phys_start: anyopaque;
extern const __kernel_phys_end: anyopaque;

/// The ranges the firmware called ordinary memory.
///
/// Kept because "is this the allocator's?" and "is this in RAM?" are different
/// questions, and only the first one is a reason to refuse a mapping. ACPI
/// tables sit in RAM the firmware reserved: physically memory, never this
/// allocator's, and a process that has to interpret them has to reach them.
const Range = struct { start: usize, end: usize };

/// More than any firmware of this era reports, and small enough to keep.
const MAX_RANGES = 16;

var usable_ranges: [MAX_RANGES]Range = @splat(.{ .start = 0, .end = 0 });
var usable_count: usize = 0;

fn remember(start: u64, end: u64) void {
    if (usable_count == MAX_RANGES or end <= start) return;

    usable_ranges[usable_count] = .{
        .start = @intCast(@min(start, 0xFFFF_FFFF)),
        .end = @intCast(@min(end, 0x1_0000_0000)),
    };
    usable_count += 1;
}

/// Whether any of `start..end` is memory this allocator hands out.
///
/// The test a mapping request has to pass, and the reason it is phrased this
/// way rather than as "is it RAM": handing a process a frame the allocator
/// believes it still owns is how two things come to write the same page.
pub fn isManaged(start: usize, end: usize) bool {
    for (usable_ranges[0..usable_count]) |r| {
        if (start < r.end and end > r.start) return true;
    }
    return false;
}

pub fn init(bi: *const bootinfo.BootInfo) void {
    // Start with everything marked used; free only what the memory map says is
    // usable. Defaulting to "used" means an incomplete or absent memory map
    // fails safe (no memory) rather than unsafe (hand out MMIO as RAM).
    map = framemap.Map.init(&bitmap, FLOOR_FRAME, BAND_CAP, MAX_FRAMES);
    contig_refusals = 0;

    var highest: usize = 0;

    usable_count = 0;

    for (bi.memoryMap()) |r| {
        if (r.kind != .usable) continue;
        remember(r.base, r.base +| r.len);
        // Ignore anything above 4 GiB: this CPU is 32-bit physical.
        const start_addr = r.base;
        const end_addr = @min(r.base +| r.len, 0x1_0000_0000);
        if (end_addr <= start_addr) continue;

        const first = std.mem.alignForward(u64, start_addr, PAGE_SIZE) >> PAGE_SHIFT;
        const last = std.mem.alignBackward(u64, end_addr, PAGE_SIZE) >> PAGE_SHIFT;

        var f: usize = @intCast(first);
        while (f < @as(usize, @intCast(last)) and f < MAX_FRAMES) : (f += 1) {
            map.release(f);
            if (f > highest) highest = f;
        }
    }

    // The map's edge is what the machine has, not what the bitmap could
    // hold, and the band is sized to the machine now that its size is known.
    map.limit = highest + 1;
    map.band = @max(map.floor, framemap.bandFrames(map.limit, BAND_CAP));
    if (map.band > map.limit) map.band = map.limit;
    map.hint = map.band;

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
}

/// Mark [start, end) as unavailable. Safe to call on ranges that are already
/// reserved or partly outside RAM.
pub fn reserveRange(start: usize, end: usize) void {
    if (end <= start) return;
    const first = start >> PAGE_SHIFT;
    const last = std.mem.alignForward(usize, end, PAGE_SIZE) >> PAGE_SHIFT;
    var f = first;
    while (f < last and f < MAX_FRAMES) : (f += 1) {
        map.reserve(f);
    }
}

pub const AllocError = error{OutOfMemory};

/// Allocate one frame. Returns a physical address.
pub fn allocFrame() AllocError!usize {
    const frame = map.one() orelse return error.OutOfMemory;
    return frame << PAGE_SHIFT;
}

/// Allocate `count` physically contiguous frames, none at or above `below`.
///
/// `origin` says who is asking, which decides where the run comes from: a
/// device's rings are served from the band, and everything else stays out of
/// it. `below` is a u64 because a DMA ceiling like four gigabytes is one
/// byte past what a 32-bit frame counter can say. The linear scan costs
/// nothing worth measuring: these are cold-path allocations, and the words
/// skip thirty-two frames at a time.
pub fn allocContiguous(count: usize, below: u64, origin: Origin) AllocError!usize {
    const ceiling: usize = @intCast(@min(below >> PAGE_SHIFT, MAX_FRAMES));
    const frame = map.run(count, ceiling, origin) orelse {
        contig_refusals += 1;
        return error.OutOfMemory;
    };
    return frame << PAGE_SHIFT;
}

pub fn freeFrame(phys: usize) void {
    map.give(phys >> PAGE_SHIFT);
}

/// The longest unbroken free run, in bytes: how much of the free memory is
/// usable by the things that need it in one piece.
pub fn largestRunBytes() usize {
    return map.largestRun(map.limit) * PAGE_SIZE;
}

/// How much of the device band is free, in bytes.
pub fn bandFreeBytes() usize {
    return map.bandFree() * PAGE_SIZE;
}

pub fn bandBytes() usize {
    return (map.band - map.floor) * PAGE_SIZE;
}

pub fn stats() Stats {
    return .{
        .total_frames = map.limit,
        .free_frames = map.free,
        .contig_refusals = contig_refusals,
    };
}

pub fn report() void {
    const s = stats();
    console.printf("       {d} MiB usable, {d} MiB free, {d} frames\n", .{
        s.totalBytes() / (1024 * 1024),
        s.freeBytes() / (1024 * 1024),
        s.total_frames,
    });
}
