//! What an ELF file asks for, worked out before anything acts on it.
//!
//! Every decision about a program image is here and nothing else is: no
//! frames, no mappings, no address space. A file is turned into a list of
//! "put these bytes there" or refused, and only then does the loader start
//! taking memory. That order matters twice over. A file that is going to be
//! refused is refused before a single frame is spent on it, and the whole of
//! what the kernel believes an image is saying can be asked here, on a host,
//! against files built by hand.
//!
//! **Everything is worked out in 64 bits.** Addresses on this machine are 32,
//! and every field of an ELF header is a number a program chose. A check
//! written in the machine's own width is a check a file can walk past by
//! naming an offset near the top and a length that carries the sum around to
//! zero, and the guard then passes for a range that is nowhere near the file.
//! Widening costs nothing here and is the difference between a bounds check
//! and the appearance of one.
//!
//! The limits come in as an argument rather than from the architecture, which
//! is what lets this file have no architecture in it.

const std = @import("std");
const elf = @import("lib").elf;

pub const Header = elf.Header;
pub const ProgramHeader = elf.ProgramHeader;

/// Most loadable segments an image may have.
///
/// A statically linked program has three or four: text, read-only data, data
/// and the zeroed part after it. Eight is room for a linker that splits them
/// differently, and a bound rather than a list is what lets the plan be a
/// value on the stack.
pub const MAX_SEGMENTS = 8;

pub const Error = error{
    NotElf,
    WrongClass,
    WrongMachine,
    NotExecutable,
    Malformed,
    TooManySegments,
};

/// What the machine will not let a program have.
pub const Limits = struct {
    /// Where the kernel's half begins. Nothing a program asks for may reach it.
    kernel_base: u64,
    page_size: usize,
};

/// One piece of the file, and where it goes.
pub const Segment = struct {
    /// Where the bytes come from in the file, and how many there are.
    from: u64 = 0,
    bytes: u64 = 0,
    /// Where they go, and how much room the segment takes once the part with
    /// no bytes behind it is counted. That tail is `.bss`, which is why the
    /// span is the larger of the two.
    at: u64 = 0,
    span: u64 = 0,
    writable: bool = false,
    executable: bool = false,

    /// The pages this segment occupies. A segment starts and ends wherever the
    /// linker put it; the pages around it belong to it entirely, because a
    /// page is the smallest thing that can be given its own permissions.
    pub fn first(self: Segment, page_size: usize) u64 {
        return std.mem.alignBackward(u64, self.at, page_size);
    }

    pub fn last(self: Segment, page_size: usize) u64 {
        return std.mem.alignForward(u64, self.at + self.span, page_size);
    }

    /// Whether two segments want any of the same page.
    ///
    /// Pages rather than bytes, because a page is what gets a frame and a set
    /// of permissions: two segments merely adjacent in memory still collide if
    /// they share one, and the one loaded second would zero the first one's
    /// bytes and impose its own permissions on them.
    pub fn collidesWith(self: Segment, other: Segment, page_size: usize) bool {
        return self.first(page_size) < other.last(page_size) and
            other.first(page_size) < self.last(page_size);
    }

    /// Whether an address falls inside this segment.
    pub fn holds(self: Segment, addr: u64) bool {
        return addr >= self.at and addr < self.at + self.span;
    }
};

/// Everything an image asks for, once it has been believed.
pub const Plan = struct {
    entry: u64 = 0,
    /// Where the heap starts: past everything the image asked for, rounded up
    /// to a page so the first allocation does not share one with `.bss`.
    brk: u64 = 0,
    segments: [MAX_SEGMENTS]Segment = @splat(.{}),
    count: usize = 0,

    pub fn list(self: *const Plan) []const Segment {
        return self.segments[0..self.count];
    }
};

/// What `image` asks for, or why it cannot be believed.
pub fn of(image: []const u8, limits: Limits) Error!Plan {
    if (image.len < @sizeOf(Header)) return error.NotElf;

    const hdr: *align(1) const Header = @ptrCast(image.ptr);
    if (!Header.identifies(image)) return error.NotElf;
    if (hdr.class != .bits32 or hdr.data != .little) return error.WrongClass;
    if (hdr.machine != .x86) return error.WrongMachine;
    if (hdr.type != .executable) return error.NotExecutable;
    if (hdr.phentsize != @sizeOf(ProgramHeader)) return error.Malformed;

    // The whole table at once, so a file naming an offset near the top of the
    // address space is refused here rather than one entry at a time by a sum
    // that wraps.
    const table_bytes = @as(u64, hdr.phnum) * @sizeOf(ProgramHeader);
    const table_end = @as(u64, hdr.phoff) + table_bytes;
    if (table_end > image.len) return error.Malformed;

    var plan = Plan{ .entry = hdr.entry };

    for (0..hdr.phnum) |i| {
        const off = @as(u64, hdr.phoff) + i * @sizeOf(ProgramHeader);
        const ph: *align(1) const ProgramHeader = @ptrCast(image.ptr + @as(usize, @intCast(off)));
        if (ph.type != .load or ph.memsz == 0) continue;

        const segment = try believe(ph, image.len, limits);

        // Two segments wanting the same page is a file that cannot be loaded
        // as it asks: whichever went second would zero the other's bytes and
        // put its own permissions on them, which is how a writable page ends
        // up holding code.
        for (plan.list()) |already| {
            if (segment.collidesWith(already, limits.page_size)) return error.Malformed;
        }

        if (plan.count == plan.segments.len) return error.TooManySegments;
        plan.segments[plan.count] = segment;
        plan.count += 1;

        const end = segment.last(limits.page_size);
        if (end > plan.brk) plan.brk = end;
    }

    if (plan.count == 0) return error.Malformed;

    // An entry point that is not in anything this file loads would fault on
    // its first instruction. Refusing it here means a program that cannot run
    // never runs rather than dying the moment it starts, and it costs one
    // walk over a list that is at most eight long.
    for (plan.list()) |segment| {
        if (segment.executable and segment.holds(plan.entry)) return plan;
    }
    return error.Malformed;
}

/// One program header, checked.
fn believe(ph: *align(1) const ProgramHeader, image_len: usize, limits: Limits) Error!Segment {
    const offset: u64 = ph.offset;
    const filesz: u64 = ph.filesz;
    const memsz: u64 = ph.memsz;
    const vaddr: u64 = ph.vaddr;

    // A segment claiming more file bytes than it has room for is a file
    // asking the kernel to copy past what it gave it.
    if (filesz > memsz) return error.Malformed;
    if (offset + filesz > image_len) return error.Malformed;

    // Nothing may reach the kernel's half, and nothing may take the page at
    // zero: a program with page zero mapped has no null pointer left, and
    // every mistake that would have faulted quietly succeeds instead.
    if (vaddr + memsz > limits.kernel_base) return error.Malformed;

    const segment = Segment{
        .from = offset,
        .bytes = filesz,
        .at = vaddr,
        .span = memsz,
        .writable = ph.flags.writable,
        .executable = ph.flags.executable,
    };
    if (segment.first(limits.page_size) == 0) return error.Malformed;

    return segment;
}

// ---------------------------------------------------------------------------
// Tests
//
// Files built by hand, because the ones this system builds are all correct and
// the point is the ones that are not.
// ---------------------------------------------------------------------------

const testing = std.testing;

const PAGE = 4096;
const LIMITS = Limits{ .kernel_base = 0xC000_0000, .page_size = PAGE };

/// An image with a header and a program table, laid out the way a linker
/// would, so a test can change one field and leave the rest right.
const Image = struct {
    bytes: [4096]u8 = @splat(0),

    const TABLE_AT = @sizeOf(Header);

    fn holding(headers: []const ProgramHeader, entry: u32) Image {
        var self = Image{};
        const hdr: *align(1) Header = @ptrCast(&self.bytes);
        hdr.* = .{
            .magic = elf.MAGIC.*,
            .class = .bits32,
            .data = .little,
            .version = 1,
            .abi = 0,
            .abi_version = 0,
            ._pad = @splat(0),
            .type = .executable,
            .machine = .x86,
            .object_version = 1,
            .entry = entry,
            .phoff = TABLE_AT,
            .shoff = 0,
            .flags = 0,
            .ehsize = @sizeOf(Header),
            .phentsize = @sizeOf(ProgramHeader),
            .phnum = @intCast(headers.len),
            .shentsize = 0,
            .shnum = 0,
            .shstrndx = 0,
        };
        for (headers, 0..) |ph, i| {
            const at = TABLE_AT + i * @sizeOf(ProgramHeader);
            const slot: *align(1) ProgramHeader = @ptrCast(self.bytes[at..].ptr);
            slot.* = ph;
        }
        return self;
    }

    fn header(self: *Image) *align(1) Header {
        return @ptrCast(&self.bytes);
    }

    fn program(self: *Image, i: usize) *align(1) ProgramHeader {
        const at = TABLE_AT + i * @sizeOf(ProgramHeader);
        return @ptrCast(self.bytes[at..].ptr);
    }

    fn plan(self: *const Image) Error!Plan {
        return of(&self.bytes, LIMITS);
    }
};

/// One loadable segment, the shape every test starts from.
fn code(at: u32, from: u32, bytes: u32) ProgramHeader {
    return .{
        .type = .load,
        .offset = from,
        .vaddr = at,
        .paddr = at,
        .filesz = bytes,
        .memsz = bytes,
        .flags = .{ .executable = true, .writable = false, .readable = true },
        .alignment = PAGE,
    };
}

test "a well formed image says where its pieces go" {
    var image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    const plan = try image.plan();

    try testing.expectEqual(@as(usize, 1), plan.count);
    try testing.expectEqual(@as(u64, 0x1020), plan.entry);

    const segment = plan.list()[0];
    try testing.expectEqual(@as(u64, 0x200), segment.from);
    try testing.expectEqual(@as(u64, 0x100), segment.bytes);
    try testing.expectEqual(@as(u64, 0x1000), segment.at);
    try testing.expect(segment.executable);
    try testing.expect(!segment.writable);

    // The heap starts past everything, on a page of its own.
    try testing.expectEqual(@as(u64, 0x2000), plan.brk);
}

test "a file offset that wraps the address space is refused" {
    // The check that matters. An offset near the top and a length that carries
    // the sum past it: worked out in the machine's own width the sum comes back
    // to nothing, the bounds check passes, and the loader copies from wherever
    // that offset lands into a page the program can read.
    var image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.program(0).offset = 0xFFFF_F000;
    image.program(0).filesz = 0x1000;
    image.program(0).memsz = 0x1000;
    try testing.expectError(error.Malformed, image.plan());

    // And the plain case of running off the end, which is the same check
    // arriving by the front door.
    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.program(0).filesz = 0x8000;
    image.program(0).memsz = 0x8000;
    try testing.expectError(error.Malformed, image.plan());
}

test "a program table that wraps the address space is refused" {
    var image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.header().phoff = 0xFFFF_FFF0;
    try testing.expectError(error.Malformed, image.plan());

    // A table that merely runs off the end, and one whose count does.
    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.header().phoff = 4000;
    try testing.expectError(error.Malformed, image.plan());

    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.header().phnum = 1000;
    try testing.expectError(error.Malformed, image.plan());
}

test "a segment claiming more bytes than it has room for is refused" {
    var image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.program(0).filesz = 0x200;
    image.program(0).memsz = 0x100;
    try testing.expectError(error.Malformed, image.plan());
}

test "nothing may reach the kernel's half" {
    var image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.program(0).vaddr = 0xC000_0000;
    try testing.expectError(error.Malformed, image.plan());

    // Starting below it and ending inside it, which is the case a check on
    // the start alone would let through.
    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.program(0).vaddr = 0xBFFF_F000;
    image.program(0).memsz = 0x2000;
    try testing.expectError(error.Malformed, image.plan());

    // And a length that would carry the end around past zero.
    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.program(0).vaddr = 0xBFFF_0000;
    image.program(0).memsz = 0xFFFF_0000;
    try testing.expectError(error.Malformed, image.plan());

    // The last page below the line is allowed: the limit is where the kernel
    // starts, not one page before it.
    image = Image.holding(&.{code(0xBFFF_F000, 0x200, 0x100)}, 0xBFFF_F020);
    _ = try image.plan();
}

test "the page at zero is not a program's to take" {
    // A program with page zero mapped has no null pointer left: every mistake
    // that would have faulted quietly reads whatever is there instead.
    var image = Image.holding(&.{code(0, 0x200, 0x100)}, 0x20);
    try testing.expectError(error.Malformed, image.plan());

    // Including one that starts partway into the page.
    image = Image.holding(&.{code(0x100, 0x200, 0x100)}, 0x120);
    try testing.expectError(error.Malformed, image.plan());
}

test "two segments may not want the same page" {
    // Overlapping outright.
    var image = Image.holding(&.{
        code(0x1000, 0x200, 0x100),
        code(0x1000, 0x400, 0x100),
    }, 0x1020);
    try testing.expectError(error.Malformed, image.plan());

    // Merely sharing a page, which is the case that matters: the second one
    // loaded would zero the first one's bytes and put its own permissions on
    // them, so a writable segment beside code makes that code writable.
    image = Image.holding(&.{
        code(0x1000, 0x200, 0x100),
        code(0x1800, 0x400, 0x100),
    }, 0x1020);
    try testing.expectError(error.Malformed, image.plan());

    // Next page along is fine.
    image = Image.holding(&.{
        code(0x1000, 0x200, 0x100),
        code(0x2000, 0x400, 0x100),
    }, 0x1020);
    const plan = try image.plan();
    try testing.expectEqual(@as(usize, 2), plan.count);
    try testing.expectEqual(@as(u64, 0x3000), plan.brk);
}

test "a segment's own pages are where it says and no wider" {
    const segment = Segment{ .at = 0x1800, .span = 0x900 };
    try testing.expectEqual(@as(u64, 0x1000), segment.first(PAGE));
    try testing.expectEqual(@as(u64, 0x3000), segment.last(PAGE));

    // Exactly a page, exactly aligned: no page is claimed that is not used.
    const tidy = Segment{ .at = 0x1000, .span = 0x1000 };
    try testing.expectEqual(@as(u64, 0x1000), tidy.first(PAGE));
    try testing.expectEqual(@as(u64, 0x2000), tidy.last(PAGE));
    try testing.expect(!tidy.collidesWith(.{ .at = 0x2000, .span = 0x1000 }, PAGE));
    try testing.expect(tidy.collidesWith(.{ .at = 0x1FFF, .span = 1 }, PAGE));
}

test "the entry point has to be somewhere the program can run" {
    // Outside everything loaded.
    var image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x9000);
    try testing.expectError(error.Malformed, image.plan());

    // Zero, which is outside everything by construction now that page zero
    // cannot be mapped.
    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0);
    try testing.expectError(error.Malformed, image.plan());

    // In the kernel's half.
    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0xC000_1000);
    try testing.expectError(error.Malformed, image.plan());

    // Inside a segment, but one holding data rather than code.
    var data = code(0x2000, 0x400, 0x100);
    data.flags = .{ .executable = false, .writable = true, .readable = true };
    image = Image.holding(&.{ code(0x1000, 0x200, 0x100), data }, 0x2020);
    try testing.expectError(error.Malformed, image.plan());

    // The last byte of a segment is still in it.
    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x10FF);
    _ = try image.plan();
    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1100);
    try testing.expectError(error.Malformed, image.plan());
}

test "an image with nothing to load is not a program" {
    var image = Image.holding(&.{}, 0x1000);
    try testing.expectError(error.Malformed, image.plan());

    // A header saying `load` with no room asked for is skipped rather than
    // loaded, which leaves nothing behind.
    image = Image.holding(&.{code(0x1000, 0x200, 0)}, 0x1000);
    try testing.expectError(error.Malformed, image.plan());
}

test "a file that is not this machine's program is refused for saying so" {
    var image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.header().machine = .arm;
    try testing.expectError(error.WrongMachine, image.plan());

    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.header().type = .relocatable;
    try testing.expectError(error.NotExecutable, image.plan());

    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.header().class = .bits64;
    try testing.expectError(error.WrongClass, image.plan());

    // An entry the right size for a different layout: believing it would walk
    // the table at the wrong stride.
    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.header().phentsize = 56;
    try testing.expectError(error.Malformed, image.plan());

    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.bytes[1] = 'F';
    try testing.expectError(error.NotElf, image.plan());

    // Too short to hold a header at all.
    try testing.expectError(error.NotElf, of(&.{ 0x7F, 'E', 'L', 'F' }, LIMITS));
    try testing.expectError(error.NotElf, of(&.{}, LIMITS));
}

test "an image asking for more segments than a plan holds is refused" {
    var headers: [MAX_SEGMENTS + 1]ProgramHeader = undefined;
    for (&headers, 0..) |*ph, i| ph.* = code(@intCast(0x1000 + i * 0x1000), 0x200, 0x100);

    var image = Image.holding(&headers, 0x1020);
    try testing.expectError(error.TooManySegments, image.plan());

    // One fewer fits.
    image = Image.holding(headers[0..MAX_SEGMENTS], 0x1020);
    const plan = try image.plan();
    try testing.expectEqual(@as(usize, MAX_SEGMENTS), plan.count);
}
