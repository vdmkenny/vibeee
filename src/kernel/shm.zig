//! Shared memory segments.
//!
//! The other half of the IPC design: channels carry the small synchronous
//! message, segments carry the bytes. A block request, an audio period, a
//! network payload or a GUI surface all move through memory both sides can
//! address, because copying them through a syscall on a 630 MHz core is time
//! the machine does not have.
//!
//! A segment is a list of physical frames plus a reference count. It is not a
//! mapping: the same segment can be mapped into several address spaces at
//! different addresses, and it outlives any one of them. That is the whole
//! point, and it is also the hazard, so the pages carry `Flags.shared` and
//! tearing an address space down unmaps them without freeing them. The frames
//! come back to the allocator when the last reference goes, and not before.
//!
//! A mapping is a reference. A process may close the handle it mapped a
//! segment through while its pages still name the frames, so each mapping
//! holds the segment for as long as the pages do: until the address space
//! goes, or the mapping is revoked. Without that, closing the last handle
//! would hand frames to the allocator that a live page table still reaches.
//!
//! Frames are allocated individually rather than as a contiguous run. Nothing
//! here is programmed into a DMA engine, and demanding contiguity would make
//! segment creation fail on a fragmented machine for no benefit. A driver that
//! genuinely needs contiguous physical memory will need `dma_alloc`, which is
//! a different promise.
//!
//! `design/00-vibeee.md` §6.8.

const hal = @import("hal.zig");
const heap = @import("heap.zig");
const pmm = @import("pmm.zig");

pub const Error = error{
    OutOfMemory,
    /// The requested size is zero, or larger than one segment may be.
    BadSize,
    /// No room left in the caller's shared-memory window.
    NoAddressSpace,
    /// The caller holds as many mappings as one process may.
    TooManyMappings,
};

pub const PAGE_SIZE = 4096;

/// Largest single segment.
///
/// A GUI surface at this resolution is 1.5 MiB, so the ceiling is not
/// about surfaces: it is about a program with a working set, which asks
/// for one block and keeps it. A game's heap is the usual example, and
/// eight megabytes is under what one wants.
///
/// Still a guard, and still meaningful: an eighth of this machine's
/// memory is a bound a runaway caller runs into long before the machine
/// does. Nothing stops a process making several, so this was never a
/// limit on how much one program can hold; it is a limit on how much it
/// can ask for without meaning to.
pub const MAX_BYTES = 64 * 1024 * 1024;

/// Where mapped segments live in a process. Above the program image at
/// 0x40000000 and well below the kernel at 0xC0000000, so it collides with
/// neither. The stack grows down from 0x3FFF0000, below the image.
pub const WINDOW_BASE: usize = 0x5000_0000;
pub const WINDOW_END: usize = 0x8000_0000;

pub const Segment = struct {
    /// Physical frames, in order. Not contiguous, and nothing may assume so.
    frames: []usize,
    size: usize,
    refs: u32 = 1,
    /// Whether the frames came from the allocator and go back to it. False for
    /// a segment that describes memory belonging to a device, where freeing
    /// the frames would hand a graphics aperture to the page allocator.
    owned: bool = true,

    pub fn pageCount(self: *const Segment) usize {
        return self.frames.len;
    }
};

/// Allocate a segment of at least `size` bytes, rounded up to a page.
pub fn create(size: usize) Error!*Segment {
    if (size == 0 or size > MAX_BYTES) return error.BadSize;

    const pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;

    const seg = heap.allocator.create(Segment) catch return error.OutOfMemory;
    errdefer heap.allocator.destroy(seg);

    const frames = heap.allocator.alloc(usize, pages) catch return error.OutOfMemory;
    errdefer heap.allocator.free(frames);

    // Allocated one at a time, and released one at a time on failure: a
    // partially allocated segment that leaked its frames would be a slow leak
    // under exactly the memory pressure that caused it.
    var got: usize = 0;
    errdefer for (frames[0..got]) |f| pmm.freeFrame(f);

    while (got < pages) : (got += 1) {
        frames[got] = pmm.allocFrame() catch return error.OutOfMemory;
        // Zeroed before anyone can see it. A fresh segment handed to another
        // process must not carry whatever the last owner of those frames left
        // behind.
        const page: *[PAGE_SIZE]u8 = @ptrFromInt(hal.physToVirt(frames[got]));
        @memset(page, 0);
    }

    seg.* = .{ .frames = frames, .size = size };
    return seg;
}

/// Allocate a segment whose frames are one physical run.
///
/// The promise every other segment deliberately does not make: a DMA
/// engine's descriptor rings and receive buffers are addressed by one base
/// plus an offset, so the backing must be contiguous. Rare and early, so the
/// linear scan in the allocator costs nothing worth measuring.
pub fn createDma(size: usize) Error!*Segment {
    if (size == 0 or size > MAX_BYTES) return error.BadSize;

    const pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;

    const seg = heap.allocator.create(Segment) catch return error.OutOfMemory;
    errdefer heap.allocator.destroy(seg);

    const frames = heap.allocator.alloc(usize, pages) catch return error.OutOfMemory;
    errdefer heap.allocator.free(frames);

    const base = pmm.allocContiguous(pages, 0x1_0000_0000, .device) catch return error.OutOfMemory;
    errdefer {
        for (frames[0..]) |f| pmm.freeFrame(f);
    }

    // Zeroed before anyone can see it or any engine can read it: a fresh
    // ring must not carry whatever the last owner of those frames left
    // behind, and a device never reads what the CPU has not written.
    for (0..pages) |i| {
        frames[i] = base + i * PAGE_SIZE;
        const page: *[PAGE_SIZE]u8 = @ptrFromInt(hal.physToVirt(frames[i]));
        @memset(page, 0);
    }

    seg.* = .{ .frames = frames, .size = size };
    return seg;
}

/// The physical address of the first byte, for a caller that has to program
/// it into a DMA engine.
pub fn physBase(self: *const Segment) usize {
    return self.frames[0];
}

/// Describe a range of physical memory that already exists, such as a
/// framebuffer, as a segment.
///
/// Same object and same mapping path as allocated memory, so a device aperture
/// can be handed to a process through the ordinary handle and `shm_map` route
/// rather than a second mechanism that does the same thing.
pub fn wrapPhysical(base: usize, size: usize) Error!*Segment {
    if (size == 0) return error.BadSize;

    const pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;

    const seg = heap.allocator.create(Segment) catch return error.OutOfMemory;
    errdefer heap.allocator.destroy(seg);

    const frames = heap.allocator.alloc(usize, pages) catch return error.OutOfMemory;
    for (frames, 0..) |*f, i| f.* = base + i * PAGE_SIZE;

    seg.* = .{ .frames = frames, .size = size, .owned = false };
    return seg;
}

pub fn retain(seg: *Segment) void {
    seg.refs += 1;
}

/// Drop a reference, freeing the frames when the last one goes.
pub fn release(seg: *Segment) void {
    if (seg.refs > 1) {
        seg.refs -= 1;
        return;
    }
    if (seg.owned) {
        for (seg.frames) |f| pmm.freeFrame(f);
    }
    heap.allocator.free(seg.frames);
    heap.allocator.destroy(seg);
}

/// Map `seg` into `space` at `virt`.
///
/// The caller picks the address, because only it knows what else is mapped
/// there. `Mapper` below does that bookkeeping for a process.
pub fn mapAt(seg: *Segment, space: *hal.AddressSpace, virt: usize, writable: bool) Error!void {
    if (virt < WINDOW_BASE or virt + seg.size > WINDOW_END) return error.NoAddressSpace;

    // What was mapped before a failure is taken back. Pages left naming
    // frames the segment may later free are the hazard this module exists to
    // prevent, and a half-mapped segment is not a thing a caller can use.
    var mapped: usize = 0;
    errdefer for (0..mapped) |i| space.unmap(virt + i * PAGE_SIZE);

    for (seg.frames, 0..) |phys, i| {
        space.map(virt + i * PAGE_SIZE, phys, .{
            .writable = writable,
            // The mark that stops address-space teardown from freeing a frame
            // another process is still using.
            .shared = true,
        }) catch return error.OutOfMemory;
        mapped = i + 1;
    }
}

/// Where one segment is mapped in a process.
pub const Mapping = struct {
    seg: *Segment,
    at: usize,
};

/// How many segments one process may have mapped at once. A compositor
/// maps a surface per window and the screen; a client maps its surfaces,
/// the clipboard and a ring or two. Addresses are never reused, so a
/// process that outgrows this is one that maps without end.
pub const MAX_MAPPINGS = 64;

/// One process's shared-memory window: which addresses are taken, and
/// which segments the pages there hold.
///
/// Addresses are handed out by bumping, never reused. A window of 768 MiB
/// against an 8 MiB per-segment cap means a process would have to map
/// ninety-six full-size segments before running out, and a process doing
/// that has a different problem.
pub const Mapper = struct {
    next: usize = WINDOW_BASE,
    held: [MAX_MAPPINGS]Mapping = undefined,
    count: usize = 0,

    /// Map a segment where the window has room, holding it for as long as
    /// the pages do.
    pub fn map(self: *Mapper, seg: *Segment, space: *hal.AddressSpace, writable: bool) Error!usize {
        if (self.count == self.held.len) return error.TooManyMappings;

        const at = try self.reserve(seg.size);
        errdefer self.unreserve(at);
        try mapAt(seg, space, at, writable);

        retain(seg);
        self.held[self.count] = .{ .seg = seg, .at = at };
        self.count += 1;
        return at;
    }

    pub fn reserve(self: *Mapper, size: usize) Error!usize {
        const pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;
        const bytes = pages * PAGE_SIZE;

        if (self.next + bytes > WINDOW_END) return error.NoAddressSpace;
        const at = self.next;
        self.next += bytes;
        return at;
    }

    /// Give the last reservation back, before anything else has taken from
    /// the window: what a mapping that failed does with its addresses.
    pub fn unreserve(self: *Mapper, at: usize) void {
        self.next = at;
    }

    /// Take every mapping of `seg` out of the space and let the segment go:
    /// what handing the display back does to the pages that showed it.
    pub fn revoke(self: *Mapper, seg: *Segment, space: *hal.AddressSpace) void {
        const pages = seg.pageCount();
        var i: usize = 0;
        while (i < self.count) {
            if (self.held[i].seg != seg) {
                i += 1;
                continue;
            }
            for (0..pages) |page| space.unmap(self.held[i].at + page * PAGE_SIZE);
            self.count -= 1;
            self.held[i] = self.held[self.count];
            // The mapping's own reference. The last one may free the segment,
            // which is why nothing above reads through `seg` after this.
            release(seg);
        }
    }

    /// Let every segment go, once the address space has: the pages no
    /// longer name the frames, so the mappings' references end with them.
    pub fn releaseAll(self: *Mapper) void {
        for (self.held[0..self.count]) |m| release(m.seg);
        self.count = 0;
    }
};
