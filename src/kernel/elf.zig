//! Minimal 32-bit ELF loader.
//!
//! Handles exactly what a statically linked, non-relocatable executable needs:
//! copy each loadable segment into the target address space. No dynamic
//! linking, no relocations, no interpreter, the system links everything
//! statically (design/00-vibeee.md §10.5), so those cases cannot arise.
//!
//! What a file asks for is decided in `elf/plan.zig`, whole and in advance, and
//! this file only carries it out. Nothing here reads a number out of the image:
//! by the time a segment reaches `loadSegment` every offset and length in it
//! has been checked against the file it came from, so the copies below are
//! arithmetic on values already known to fit rather than on a program's word.
//! A file that will be refused is refused before a frame is spent on it.
//!
//! Segment contents are written through the kernel's linear map rather than by
//! switching to the target address space, so loading never disturbs the
//! currently running process.

const hal = @import("hal.zig");
const pmm = @import("pmm.zig");
const plan = @import("elf/plan.zig");

pub const Error = plan.Error || error{OutOfMemory};

/// What this machine will not let a program have, for the planner, which is
/// deliberately ignorant of the architecture it is deciding for.
const LIMITS = plan.Limits{
    .kernel_base = hal.KERNEL_BASE,
    .page_size = hal.PAGE_SIZE,
};

pub const Loaded = struct {
    entry: usize,
    /// Highest address used by any segment, rounded up to a page. Where a heap
    /// would start.
    brk: usize,
};

/// Load `image` into `space`. Returns the entry point.
pub fn load(space: *hal.AddressSpace, image: []const u8) Error!Loaded {
    const wanted = try plan.of(image, LIMITS);

    for (wanted.list()) |segment| try loadSegment(space, image, segment);

    return .{
        .entry = @intCast(wanted.entry),
        .brk = @intCast(wanted.brk),
    };
}

fn loadSegment(space: *hal.AddressSpace, image: []const u8, segment: plan.Segment) Error!void {
    const first: usize = @intCast(segment.first(hal.PAGE_SIZE));
    const last: usize = @intCast(segment.last(hal.PAGE_SIZE));
    const at: usize = @intCast(segment.at);
    const file_end: usize = @intCast(segment.at + segment.bytes);

    var page = first;
    while (page < last) : (page += hal.PAGE_SIZE) {
        const phys = pmm.allocFrame() catch return error.OutOfMemory;
        // Until it is mapped the frame is nobody's but ours, and a mapping
        // that fails must not leave it nobody's at all.
        errdefer pmm.freeFrame(phys);
        const dest: [*]u8 = @ptrFromInt(hal.physToVirt(phys));

        // Zero first: `.bss` is the part of the span beyond the file, and a
        // page that straddles the boundary needs both halves handled.
        @memset(dest[0..hal.PAGE_SIZE], 0);

        // Whatever part of this page the file actually covers.
        const from = @max(page, at);
        const to = @min(page + hal.PAGE_SIZE, file_end);
        if (to > from) {
            const source: usize = @intCast(segment.from + (from - at));
            const len = to - from;
            @memcpy(dest[from - page ..][0..len], image[source..][0..len]);
        }

        try space.map(page, phys, .{ .writable = segment.writable });
    }
}
