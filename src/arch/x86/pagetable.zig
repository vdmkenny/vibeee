//! The shape of a page table, and what can be asked of one.
//!
//! Split from `paging.zig`, which turns paging on and hands out frames and is
//! therefore made of instructions only this CPU will run. What is here is the
//! format and the questions: no instructions, no allocator, no CR3. A table
//! can be built by hand and asked exactly what the kernel asks a real one,
//! which is why this file is in the host tests and `paging.zig` is not.
//!
//! `walk` is the one that matters. A kernel that reads a user pointer without
//! asking whether anything is behind it faults in its own context, and a fault
//! there stops the machine: any program could halt the system with a stray
//! pointer. This is what stands in the way.

const std = @import("std");

pub const PAGE_SIZE: usize = 4096;
pub const LARGE_PAGE_SIZE: usize = 4 * 1024 * 1024;

const PAGE_SHIFT = 12;

/// A directory or table entry, as the CPU reads it.
///
/// A packed struct rather than a word and a column of shift constants: the
/// field positions are the declaration, the compiler checks the entry is
/// exactly thirty-two bits, and a mapping reads as what it permits instead of
/// as an expression to decode. Getting a bit wrong here is the difference
/// between a working address space and one that faults on its first access,
/// which is worth having the compiler check.
pub const Entry = packed struct(u32) {
    present: bool = false,
    write: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    /// Four megabytes rather than four kilobytes. Only meaningful in a
    /// directory entry.
    large: bool = false,
    /// Survives a CR3 reload, for the mappings every address space shares.
    global: bool = false,

    /// Bits 9 to 11 are ignored by the CPU and free for software. This one
    /// marks a page whose frame belongs to something else, a shared-memory
    /// segment, so tearing an address space down must unmap it without
    /// freeing it. Without the mark, the first process to exit would hand
    /// frames back to the allocator that another process is still reading.
    shared: bool = false,
    _software: u2 = 0,

    /// The frame this entry points at, counted in pages. A large entry uses
    /// only the top ten bits of it and leaves the rest clear.
    frame: u20 = 0,

    /// The physical address the frame field names.
    pub fn address(self: Entry) usize {
        return @as(usize, self.frame) << PAGE_SHIFT;
    }

    /// An entry pointing at `phys`, with nothing else set.
    pub fn at(phys: usize) Entry {
        return .{ .frame = @intCast(phys >> PAGE_SHIFT) };
    }
};

/// A directory or a table: the CPU makes no distinction between their shapes.
pub const Table = [1024]Entry;

/// Which directory entry an address falls in, and which entry of the table
/// under it. Named rather than written out at each use, because a shift by
/// the wrong amount reads as plausible and mismaps a gigabyte.
pub fn directoryIndex(virt: usize) usize {
    return virt >> 22;
}

pub fn tableIndex(virt: usize) usize {
    return (virt >> PAGE_SHIFT) & 0x3FF;
}

/// What the kernel is about to do to an address on a program's behalf.
pub const Access = enum {
    read,
    write,

    /// Whether a mapping permits it.
    ///
    /// The kernel holds itself to what the program could do unaided: a page
    /// the program may not reach is not one the kernel reaches for it, and a
    /// page it may not write is not one the kernel fills in for it. Anything
    /// looser would make a syscall a way around a program's own mappings,
    /// which is to say around the only protection there is.
    pub fn allowedBy(self: Access, entry: Entry) bool {
        if (!entry.present or !entry.user) return false;
        return self == .read or entry.write;
    }
};

/// Whether every page of `virt[0..len]` permits `access` in this directory.
///
/// `resolve` turns the physical address of a table into one that can be read,
/// which on the machine is the kernel's linear map and in a test is whatever
/// the test built. Comptime, so it costs nothing where it runs for real and
/// still lets the walk be tested away from a running address space.
///
/// The kernel half needs no special case: those entries are mapped without the
/// user bit, so an address in it is refused by the mapping itself rather than
/// by a constant kept here that would have to be kept agreeing with the one in
/// the memory map.
pub fn walk(
    comptime resolve: fn (usize) *const Table,
    directory: *const Table,
    virt: usize,
    len: usize,
    access: Access,
) bool {
    // Nothing to reach means nothing to refuse: a zero-length buffer is a
    // legitimate thing to pass, and its pointer is never followed.
    if (len == 0) return true;

    // A length that carries the end past the top of the address space is how
    // a check written as one comparison gets walked straight past.
    const end = std.math.add(usize, virt, len) catch return false;

    var at = std.mem.alignBackward(usize, virt, PAGE_SIZE);
    while (at < end) {
        const pde = directory[directoryIndex(at)];
        if (!access.allowedBy(pde)) return false;

        // Where this directory entry stops covering, which is as far as one
        // table can answer for. Saturating, so a range at the very top of the
        // address space ends the walk rather than wrapping it.
        const region_end = std.mem.alignBackward(usize, at, LARGE_PAGE_SIZE) +| LARGE_PAGE_SIZE;

        // A large entry has no table under it: it is the whole answer for its
        // four megabytes.
        if (pde.large) {
            at = region_end;
            continue;
        }

        const table = resolve(pde.address());
        const stop = @min(end, region_end);
        while (at < stop) : (at +|= PAGE_SIZE) {
            if (!access.allowedBy(table[tableIndex(at)])) return false;
        }
    }

    return true;
}

/// Room set aside for one device aperture.
pub const Window = struct {
    /// Where the mapping begins, which is where the first entry goes.
    base: usize,
    /// Where the aperture's own first byte lands. Not the same as `base`: an
    /// aperture is rarely at the start of a whole entry, and a caller wants
    /// the byte it asked for rather than the entry it fell in.
    at: usize,
    /// The first physical address the mapping covers.
    from: usize,
    /// How much it covers, in whole large entries.
    span: usize,
    /// Where the next reservation begins.
    next: usize,
};

/// Set aside room for `len` bytes of the aperture at `phys`, beginning at
/// `next` and stopping before `limit`.
///
/// All of it in sixty-four bits, and this is the reason the function exists
/// apart from the mapping it serves. Every quantity here comes from a device
/// or from firmware, and on a machine whose addresses are thirty-two a sum in
/// the machine's own width is one that an aperture near the top of the space
/// carries around past zero. The guard then passes, the mapping loop writes
/// entries at wrapped indices into the directory every address space copies
/// its kernel half from, and the frames those entries name are the kernel's
/// own memory rather than the device's.
///
/// Null when it will not fit, which is the only way it declines: a window is
/// a bump forwards and there is nothing to search.
pub fn reserve(next: usize, phys: usize, len: usize, limit: u64) ?Window {
    if (len == 0) return null;

    const from = std.mem.alignBackward(u64, phys, LARGE_PAGE_SIZE);
    const covers = std.math.add(u64, phys, len) catch return null;
    const to = std.mem.alignForward(u64, covers, LARGE_PAGE_SIZE);

    // An aperture whose mapping would run off the top of physical addressing
    // is one whose tail would name low memory instead.
    if (to > ADDRESS_SPACE) return null;

    const span = to - from;
    const end = @as(u64, next) + span;
    if (end > limit) return null;

    return .{
        .base = next,
        .at = @intCast(next + (phys - from)),
        .from = @intCast(from),
        .span = @intCast(span),
        .next = @intCast(end),
    };
}

/// One past the highest address this machine can name. Sixty-four bits wide
/// because the whole point of the arithmetic above is to hold a value that
/// does not fit in an address.
pub const ADDRESS_SPACE: u64 = 1 << 32;

// ---------------------------------------------------------------------------
// Tests
//
// A directory and a handful of tables built by hand, which is the whole
// advantage of this file being separate: the walk can be asked about a range
// that runs off the end of its mapping without a machine to run off the end of.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// One directory and four tables under it, laid out so a test can map an
/// address and then ask about it.
const Space = struct {
    directory: Table = @splat(.{}),
    tables: [4]Table = @splat(@splat(.{})),
    /// Which directory entry each table was given to, so `find` can answer
    /// without the physical addresses meaning anything.
    used: usize = 0,

    /// Tables are addressed by their index here rather than by anything a
    /// machine would recognise: what the walk needs from `resolve` is that it
    /// gives back the table the entry named, and one plus the index is a
    /// frame number as good as any.
    var current: *Space = undefined;

    fn resolve(phys: usize) *const Table {
        return &current.tables[(phys >> PAGE_SHIFT) - 1];
    }

    /// Map one page, making the table under it if this is the first page in
    /// its four megabytes.
    fn map(self: *Space, virt: usize, options: Entry) void {
        const pd_index = directoryIndex(virt);
        if (!self.directory[pd_index].present) {
            self.used += 1;
            self.directory[pd_index] = .{
                .present = true,
                .write = true,
                .user = true,
                .frame = @intCast(self.used),
            };
        }
        var entry = options;
        entry.present = true;
        self.tables[self.directory[pd_index].frame - 1][tableIndex(virt)] = entry;
    }

    fn permits(self: *Space, virt: usize, len: usize, access: Access) bool {
        current = self;
        return walk(resolve, &self.directory, virt, len, access);
    }
};

test "an access is allowed by a mapping that permits it and no other" {
    const readable = Entry{ .present = true, .user = true };
    try testing.expect(Access.read.allowedBy(readable));
    try testing.expect(!Access.write.allowedBy(readable));

    const writable = Entry{ .present = true, .user = true, .write = true };
    try testing.expect(Access.read.allowedBy(writable));
    try testing.expect(Access.write.allowedBy(writable));

    // The kernel's own pages are mapped without the user bit, which is what
    // refuses a program that names one.
    const kernels = Entry{ .present = true, .write = true };
    try testing.expect(!Access.read.allowedBy(kernels));
    try testing.expect(!Access.write.allowedBy(kernels));

    // Absent beats everything else set.
    const gone = Entry{ .user = true, .write = true };
    try testing.expect(!Access.read.allowedBy(gone));
    try testing.expect(!Access.write.allowedBy(gone));
}

test "a page that is there is reachable and one that is not is refused" {
    var space = Space{};
    space.map(0x1000, .{ .user = true, .write = true });

    try testing.expect(space.permits(0x1000, 4096, .write));
    try testing.expect(space.permits(0x1000, 1, .write));
    // Somewhere in the middle of the page, which is where a pointer usually
    // is: the walk starts from the page the address is in, not the address.
    try testing.expect(space.permits(0x1800, 16, .write));

    // The page before and the page after were never mapped.
    try testing.expect(!space.permits(0x0000, 4096, .read));
    try testing.expect(!space.permits(0x2000, 1, .read));
}

test "a buffer that runs off the end of its page is refused" {
    var space = Space{};
    space.map(0x1000, .{ .user = true, .write = true });

    // Entirely inside: fine.
    try testing.expect(space.permits(0x1FF0, 16, .write));

    // One byte over the edge, into a page nothing was mapped at. This is the
    // case a check that looks only at where a range starts lets through, and
    // then the copy faults halfway.
    try testing.expect(!space.permits(0x1FF0, 17, .write));
    try testing.expect(!space.permits(0x1000, 4097, .write));

    // With the next page mapped, the same buffer is fine, which is what says
    // the refusal above was about the mapping and not about the arithmetic.
    space.map(0x2000, .{ .user = true, .write = true });
    try testing.expect(space.permits(0x1FF0, 17, .write));
}

test "a read-only page is somewhere to read and nowhere to write" {
    var space = Space{};
    space.map(0x1000, .{ .user = true });

    try testing.expect(space.permits(0x1000, 4096, .read));
    try testing.expect(!space.permits(0x1000, 4096, .write));

    // A range whose first page is writable and whose second is not: only the
    // whole of it counts.
    space.map(0x2000, .{ .user = true, .write = true });
    try testing.expect(!space.permits(0x1000, 8192, .write));
    try testing.expect(space.permits(0x2000, 4096, .write));
}

test "a page the kernel kept to itself is refused to a program" {
    var space = Space{};
    space.map(0x1000, .{ .write = true });

    try testing.expect(!space.permits(0x1000, 4096, .read));
    try testing.expect(!space.permits(0x1000, 4096, .write));
}

test "a length that wraps the address space is refused" {
    var space = Space{};
    space.map(0x1000, .{ .user = true, .write = true });

    // The range ends below where it starts. Nothing may be reached through
    // it, whatever is mapped at the address itself.
    try testing.expect(!space.permits(0x1000, std.math.maxInt(usize), .read));
    try testing.expect(!space.permits(0x1000, 0 -% @as(usize, 0x1000), .read));
    try testing.expect(!space.permits(std.math.maxInt(usize), 2, .read));
}

test "nothing is asked about a range of no length" {
    var space = Space{};

    // Including at an address nothing is mapped at, and at zero: a program
    // that passes an empty buffer never has its pointer followed, so there is
    // nothing there to be wrong.
    try testing.expect(space.permits(0, 0, .write));
    try testing.expect(space.permits(0xDEAD_BEEF, 0, .write));
}

test "a directory entry nothing was put under refuses without being followed" {
    var space = Space{};
    // A whole four megabytes with no table: the walk must answer from the
    // directory rather than following a frame that was never allocated.
    try testing.expect(!space.permits(0x40_0000, 4096, .read));
    try testing.expect(!space.permits(0x40_0000, 16 * 1024 * 1024, .read));
}

test "a walk crosses from one table to the next" {
    var space = Space{};
    // The last page of one four-megabyte region and the first of the next,
    // which is the boundary where the walk has to pick up a second table.
    space.map(0x3F_F000, .{ .user = true, .write = true });
    space.map(0x40_0000, .{ .user = true, .write = true });

    try testing.expect(space.permits(0x3F_FFF0, 32, .write));

    // And stops at the far edge of the second.
    try testing.expect(!space.permits(0x3F_FFF0, 4096 + 32, .write));
}

test "a large entry answers for its whole region without a table" {
    var space = Space{};
    space.directory[1] = .{ .present = true, .user = true, .write = true, .large = true };

    // Anywhere inside the four megabytes, including a range spanning most of
    // it, without a single table being read.
    try testing.expect(space.permits(LARGE_PAGE_SIZE, 4096, .write));
    try testing.expect(space.permits(LARGE_PAGE_SIZE + 0x1234, LARGE_PAGE_SIZE - 0x2000, .write));

    // And not one byte past its end.
    try testing.expect(!space.permits(LARGE_PAGE_SIZE, LARGE_PAGE_SIZE + 1, .write));
}

test "an entry names the frame it was built from" {
    const entry = Entry.at(0x1234_5000);
    try testing.expectEqual(@as(usize, 0x1234_5000), entry.address());
    try testing.expect(!entry.present);

    // The field positions are the CPU's, so a wrong one is a wrong mapping.
    try testing.expectEqual(@as(u32, 1), @as(u32, @bitCast(Entry{ .present = true })));
    try testing.expectEqual(@as(u32, 2), @as(u32, @bitCast(Entry{ .write = true })));
    try testing.expectEqual(@as(u32, 4), @as(u32, @bitCast(Entry{ .user = true })));
    try testing.expectEqual(@as(u32, 0x80), @as(u32, @bitCast(Entry{ .large = true })));
    try testing.expectEqual(@as(u32, 0x100), @as(u32, @bitCast(Entry{ .global = true })));
    try testing.expectEqual(@as(usize, 4), @sizeOf(Entry));
}

test "a window is set aside where the last one stopped" {
    const window = reserve(0xF000_0000, 0xFD00_0000, 0x30_0000, ADDRESS_SPACE).?;

    // The aperture is not at the start of a large entry, so the mapping begins
    // below it and the address handed back is that far in.
    try testing.expectEqual(@as(usize, 0xFD00_0000), window.from);
    try testing.expectEqual(@as(usize, 0xF000_0000), window.base);
    try testing.expectEqual(@as(usize, 0xF000_0000), window.at);
    try testing.expectEqual(@as(usize, LARGE_PAGE_SIZE), window.span);
    try testing.expectEqual(@as(usize, 0xF040_0000), window.next);

    // One that starts partway into an entry keeps its offset.
    const inside = reserve(0xF000_0000, 0xFD01_2340, 0x100, ADDRESS_SPACE).?;
    try testing.expectEqual(@as(usize, 0xFD00_0000), inside.from);
    try testing.expectEqual(@as(usize, 0xF000_0000), inside.base);
    try testing.expectEqual(@as(usize, 0xF001_2340), inside.at);
    try testing.expectEqual(@as(usize, LARGE_PAGE_SIZE), inside.span);

    // And one spanning a boundary covers both entries.
    const across = reserve(0xF000_0000, 0xFD3F_F000, 0x2000, ADDRESS_SPACE).?;
    try testing.expectEqual(@as(usize, 2 * LARGE_PAGE_SIZE), across.span);
}

test "an aperture that runs off the top of addressing is refused" {
    // The case that matters. Worked out in the machine's own width the end
    // comes back around to a small number, the check passes, and the tail of
    // the mapping names low memory: the kernel's own image, mapped into the
    // window as if it were the device.
    try testing.expectEqual(@as(?Window, null), reserve(0xF000_0000, 0xFFFF_0000, 0x50_0000, ADDRESS_SPACE));
    try testing.expectEqual(@as(?Window, null), reserve(0xF000_0000, 0xFFFF_F000, 0x2000, ADDRESS_SPACE));
    try testing.expectEqual(@as(?Window, null), reserve(0xF000_0000, 1, std.math.maxInt(usize), ADDRESS_SPACE));

    // Right up to the top is allowed: the limit is where addressing stops.
    const last = reserve(0xF000_0000, 0xFFC0_0000, LARGE_PAGE_SIZE, ADDRESS_SPACE).?;
    try testing.expectEqual(@as(usize, 0xFFC0_0000), last.from);
    try testing.expectEqual(@as(usize, LARGE_PAGE_SIZE), last.span);
}

test "a window that will not fit is refused rather than wrapped" {
    // The guard was itself a sum in the machine's own width, so a span large
    // enough carried it past the end and the check passed for a reservation
    // that would write entries at the bottom of the directory.
    const limit = ADDRESS_SPACE;
    try testing.expectEqual(@as(?Window, null), reserve(0xF000_0000, 0, 0x2000_0000, limit));

    // Exactly filling what is left is not overflowing it.
    const exact = reserve(0xF000_0000, 0, 0x1000_0000, limit).?;
    try testing.expectEqual(@as(usize, 0x1000_0000), exact.span);
    try testing.expectEqual(@as(usize, 0), exact.next % LARGE_PAGE_SIZE);

    // And a window already at the end has nothing left to give.
    try testing.expectEqual(@as(?Window, null), reserve(@intCast(limit - 1), 0, 1, limit));
}

test "an aperture of nothing is not an aperture" {
    try testing.expectEqual(@as(?Window, null), reserve(0xF000_0000, 0xFD00_0000, 0, ADDRESS_SPACE));
}

test "an address falls in the entries that cover it" {
    try testing.expectEqual(@as(usize, 0), directoryIndex(0));
    try testing.expectEqual(@as(usize, 0), directoryIndex(LARGE_PAGE_SIZE - 1));
    try testing.expectEqual(@as(usize, 1), directoryIndex(LARGE_PAGE_SIZE));
    try testing.expectEqual(@as(usize, 768), directoryIndex(0xC000_0000));

    try testing.expectEqual(@as(usize, 0), tableIndex(0));
    try testing.expectEqual(@as(usize, 1), tableIndex(PAGE_SIZE));
    try testing.expectEqual(@as(usize, 1023), tableIndex(LARGE_PAGE_SIZE - 1));
    // The index wraps at a region boundary, which is what makes the directory
    // index the other half of the answer.
    try testing.expectEqual(@as(usize, 0), tableIndex(LARGE_PAGE_SIZE));
}
