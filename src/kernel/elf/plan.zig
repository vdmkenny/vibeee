//! What an ELF file asks for, worked out before anything acts on it.
//!
//! No frames, no mappings, no address space: a file becomes a list of segments
//! to copy, or is refused before the loader takes any memory.
//!
//! Every field is a number the file chose. Sums of them are checked for
//! overflow, so a range near the top of the address space cannot wrap past a
//! bounds check.
//!
//! The limits are an argument, so nothing here depends on the architecture.

const std = @import("std");
const elf = @import("lib").elf;

pub const Header = elf.Header;
pub const ProgramHeader = elf.ProgramHeader;

/// Most loadable segments an image may have. A statically linked program has
/// three or four.
pub const MAX_SEGMENTS = 8;

pub const Error = elf.Header.Error || error{
    WrongMachine,
    NotExecutable,
    Malformed,
    TooManySegments,
};

/// What the machine will not let a program have.
pub const Limits = struct {
    /// Where the kernel's half begins. No segment may reach it.
    kernel_base: u32,
    page_size: u32,
};

/// One piece of the file, and where it goes.
pub const Segment = struct {
    /// Where the bytes are in the file, and how many.
    from: u32 = 0,
    bytes: u32 = 0,
    /// Where they go, and the room the segment takes with its `.bss`.
    at: u32 = 0,
    span: u32 = 0,
    writable: bool = false,
    executable: bool = false,

    /// The first page this segment occupies.
    pub fn first(self: Segment, page_size: u32) u32 {
        return std.mem.alignBackward(u32, self.at, page_size);
    }

    /// The page after the last one this segment occupies.
    pub fn last(self: Segment, page_size: u32) u32 {
        return std.mem.alignForward(u32, self.at + self.span, page_size);
    }

    /// Whether two segments want any of the same page. Pages, not bytes: the
    /// segment loaded second would zero the other's bytes on a shared page
    /// and give them its own permissions.
    pub fn collidesWith(self: Segment, other: Segment, page_size: u32) bool {
        return self.first(page_size) < other.last(page_size) and
            other.first(page_size) < self.last(page_size);
    }

    /// Whether an address falls inside this segment.
    pub fn holds(self: Segment, addr: u32) bool {
        return addr >= self.at and addr - self.at < self.span;
    }
};

/// Everything an image asks for, once it has been believed.
pub const Plan = struct {
    entry: u32 = 0,
    /// Where the heap starts: past every segment, on a page of its own.
    brk: u32 = 0,
    segments: [MAX_SEGMENTS]Segment = @splat(.{}),
    count: usize = 0,

    pub fn list(self: *const Plan) []const Segment {
        return self.segments[0..self.count];
    }
};

/// What `image` asks for, or why it cannot be believed.
pub fn of(image: []const u8, limits: Limits) Error!Plan {
    const header = try Header.of(image);
    if (header.ident.machine != .x86) return error.WrongMachine;
    if (header.ident.type != .executable) return error.NotExecutable;
    const table = header.programs(image) orelse return error.Malformed;

    var plan = Plan{ .entry = header.entry };
    for (table) |program| {
        if (program.type != .load or program.memsz == 0) continue;
        const segment = try believe(program, image.len, limits);

        for (plan.list()) |already| {
            if (segment.collidesWith(already, limits.page_size)) return error.Malformed;
        }
        if (plan.count == plan.segments.len) return error.TooManySegments;
        plan.segments[plan.count] = segment;
        plan.count += 1;
        plan.brk = @max(plan.brk, segment.last(limits.page_size));
    }

    if (plan.count == 0) return error.Malformed;

    // The first instruction must be in code this file loads.
    for (plan.list()) |segment| {
        if (segment.executable and segment.holds(plan.entry)) return plan;
    }
    return error.Malformed;
}

/// One program header, checked.
fn believe(program: ProgramHeader, image_len: usize, limits: Limits) Error!Segment {
    // No more bytes from the file than the segment has room for, and all of
    // them inside the file.
    if (program.filesz > program.memsz) return error.Malformed;
    const file_end = std.math.add(u32, program.offset, program.filesz) catch return error.Malformed;
    if (file_end > image_len) return error.Malformed;

    // Nothing in the kernel's half.
    const end = std.math.add(u32, program.vaddr, program.memsz) catch return error.Malformed;
    if (end > limits.kernel_base) return error.Malformed;

    const segment = Segment{
        .from = program.offset,
        .bytes = program.filesz,
        .at = program.vaddr,
        .span = program.memsz,
        .writable = program.flags.writable,
        .executable = program.flags.executable,
    };
    // Page zero stays unmapped, so a null pointer faults.
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

/// An image with a header and a program header table, laid out as a linker
/// would, for a test to change one field of.
const Image = struct {
    bytes: [4096]u8 = @splat(0),

    fn holding(programs: []const ProgramHeader, entry: u32) Image {
        var self = Image{};
        self.header().* = .{ .entry = entry, .phnum = @intCast(programs.len) };
        @memcpy(self.table()[0..programs.len], programs);
        return self;
    }

    fn header(self: *Image) *align(1) Header {
        return std.mem.bytesAsValue(Header, self.bytes[0..@sizeOf(Header)]);
    }

    /// Room for the program header table, after the header.
    fn table(self: *Image) []align(1) ProgramHeader {
        const size = (MAX_SEGMENTS + 2) * @sizeOf(ProgramHeader);
        return std.mem.bytesAsSlice(ProgramHeader, self.bytes[@sizeOf(Header)..][0..size]);
    }

    fn program(self: *Image, i: usize) *align(1) ProgramHeader {
        return &self.table()[i];
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
        .flags = .{ .executable = true, .readable = true },
        .alignment = PAGE,
    };
}

test "a well formed image says where its pieces go" {
    var image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    const plan = try image.plan();

    try testing.expectEqual(@as(usize, 1), plan.count);
    try testing.expectEqual(@as(u32, 0x1020), plan.entry);

    const segment = plan.list()[0];
    try testing.expectEqual(@as(u32, 0x200), segment.from);
    try testing.expectEqual(@as(u32, 0x100), segment.bytes);
    try testing.expectEqual(@as(u32, 0x1000), segment.at);
    try testing.expect(segment.executable);
    try testing.expect(!segment.writable);

    // The heap starts past everything, on a page of its own.
    try testing.expectEqual(@as(u32, 0x2000), plan.brk);
}

test "a file offset that wraps the address space is refused" {
    // An offset near the top and a length whose sum wraps past zero. Unchecked,
    // the bounds check passes and the loader copies from wherever the offset
    // lands into the program's memory.
    var image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.program(0).offset = 0xFFFF_F000;
    image.program(0).filesz = 0x1000;
    image.program(0).memsz = 0x1000;
    try testing.expectError(error.Malformed, image.plan());

    // Running off the end.
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
    try testing.expectEqual(@as(u32, 0x3000), plan.brk);
}

test "a segment's own pages are where it says and no wider" {
    const segment = Segment{ .at = 0x1800, .span = 0x900 };
    try testing.expectEqual(@as(u32, 0x1000), segment.first(PAGE));
    try testing.expectEqual(@as(u32, 0x3000), segment.last(PAGE));

    // Exactly a page, exactly aligned: no page is claimed that is not used.
    const tidy = Segment{ .at = 0x1000, .span = 0x1000 };
    try testing.expectEqual(@as(u32, 0x1000), tidy.first(PAGE));
    try testing.expectEqual(@as(u32, 0x2000), tidy.last(PAGE));
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
    image.header().ident.machine = .arm;
    try testing.expectError(error.WrongMachine, image.plan());

    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.header().ident.type = .relocatable;
    try testing.expectError(error.NotExecutable, image.plan());

    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.header().ident.class = .bits64;
    try testing.expectError(error.WrongClass, image.plan());

    // An entry the right size for a different layout: believing it would walk
    // the table at the wrong stride.
    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.header().phentsize = 56;
    try testing.expectError(error.Malformed, image.plan());

    image = Image.holding(&.{code(0x1000, 0x200, 0x100)}, 0x1020);
    image.header().ident.magic[1] = 'F';
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

// ---------------------------------------------------------------------------
// Fuzzing
//
// Run with `make fuzz`.
//
// Random bytes fail the first four checks above and never reach the
// arithmetic. The image is built with a linker's shape and the search chooses
// its field values, drawn from the regions the checks guard: inside the file,
// page-aligned, just below `kernel_base`, and just below the top of the
// address space.

const fuzzing = @import("lib").fuzzing;
const Choices = fuzzing.Choices;

/// A field value, drawn from the regions the checks guard.
fn field(from: Choices) u32 {
    return switch (from.one(enum { nearby, inside, page, near_kernel, near_top, anything })) {
        // A short move, which is what reaches a collision between two
        // segments or an entry point just outside the one that holds it.
        .nearby => BASE +% @as(u32, @intCast(PAGE * from.below(24))) -% 8 * PAGE,
        .inside => @intCast(from.below(@sizeOf(@FieldType(Image, "bytes")))),
        .page => @intCast(PAGE * (1 + from.below(8))),
        .near_kernel => @intCast(LIMITS.kernel_base - from.below(3 * PAGE)),
        .near_top => @intCast(std.math.maxInt(u32) - from.below(3 * PAGE)),
        .anything => from.int(u32),
    };
}

/// Where a built image puts its first segment. Well clear of the page at
/// zero and well clear of where the kernel starts, so that moving a field
/// either way reaches a boundary.
const BASE: u32 = 0x0800_0000;

/// Which field of an image to move.
const Move = union(enum) {
    /// One field of one program header.
    segment: struct { which: usize, field: Field, to: u32 },
    /// Where the table is, how many entries it has, or how big it says they
    /// are. Each has a check in front of the table ever being read.
    table: struct { field: enum { phoff, phnum, phentsize }, to: u32 },
    /// The first instruction.
    entry: u32,
    /// What the file says it is. Each of these is checked before anything
    /// else is read, and a file failing one is not this machine's to run.
    identity: enum { magic, class, data, machine, kind },

    const Field = enum { offset, vaddr, filesz, memsz, kind, flags };

    fn choose(from: Choices, count: usize) Move {
        return switch (from.one(std.meta.Tag(Move))) {
            .segment => .{ .segment = .{
                .which = from.below(count),
                .field = from.one(Field),
                .to = field(from),
            } },
            .table => .{ .table = .{
                .field = from.one(@FieldType(@FieldType(Move, "table"), "field")),
                .to = field(from),
            } },
            .entry => .{ .entry = field(from) },
            .identity => .{ .identity = from.one(@FieldType(Move, "identity")) },
        };
    }

    fn apply(self: Move, image: *Image) void {
        switch (self) {
            .segment => |s| {
                const ph = image.program(s.which);
                switch (s.field) {
                    .offset => ph.offset = s.to,
                    .vaddr => ph.vaddr = s.to,
                    .filesz => ph.filesz = s.to,
                    .memsz => ph.memsz = s.to,
                    .kind => ph.type = @enumFromInt(s.to),
                    .flags => ph.flags = @bitCast(s.to),
                }
            },
            .table => |t| switch (t.field) {
                .phoff => image.header().phoff = t.to,
                .phnum => image.header().phnum = @truncate(t.to),
                .phentsize => image.header().phentsize = @truncate(t.to),
            },
            .entry => |e| image.header().entry = e,
            .identity => |which| switch (which) {
                .magic => image.header().ident.magic[0] +%= 1,
                .class => image.header().ident.class = .bits64,
                .data => image.header().ident.data = .big,
                .machine => image.header().ident.machine = .arm,
                .kind => image.header().ident.type = .relocatable,
            },
        }
    }
};

/// An image a linker could have produced: segments a page apart, each taking
/// its bytes from inside the file, and an entry point in the first of them.
///
/// Built valid and then moved, because a file assembled from arbitrary
/// numbers is refused by the first check it meets and never reaches the
/// arithmetic underneath.
fn plausibleImage(from: Choices, count: usize) Image {
    var headers: [MAX_SEGMENTS + 2]ProgramHeader = undefined;
    const table_end: u32 = @sizeOf(Header) + @sizeOf(ProgramHeader) * headers.len;

    for (headers[0..count], 0..) |*ph, i| {
        const span: u32 = @intCast(PAGE * (1 + from.below(2)));
        ph.* = .{
            .type = .load,
            .offset = table_end,
            // Far enough apart that a segment has to be moved a long way to
            // collide with its neighbour, and close enough that several fit.
            .vaddr = BASE + @as(u32, @intCast(i)) * 8 * PAGE,
            .paddr = 0,
            .filesz = @intCast(from.below(256)),
            .memsz = span,
            .flags = .{
                .executable = i == 0,
                .writable = i != 0,
                .readable = true,
            },
            .alignment = PAGE,
        };
    }
    return Image.holding(headers[0..count], BASE);
}

/// Everything a plan says must be true of it, because the loader is about to
/// act on all of it without asking again.
fn planOneImage(from: Choices) anyerror!void {
    // Past what a plan will hold, so that a file asking for more segments
    // than the kernel keeps room for is reached as well.
    const count = from.upTo(MAX_SEGMENTS + 2);
    var image = plausibleImage(from, count);

    const moves = from.upTo(3);
    for (0..moves) |_| Move.choose(from, count).apply(&image);

    const made = image.plan() catch return;

    // A plan that came back is a plan the loader will carry out.
    try testing.expect(made.count >= 1);
    try testing.expect(made.count <= MAX_SEGMENTS);

    var entry_is_in_code = false;
    for (made.list(), 0..) |segment, i| {
        // Every byte copied comes from inside the file.
        try testing.expect(segment.bytes <= segment.span);
        try testing.expect(segment.from + segment.bytes <= image.bytes.len);

        // Nothing reaches the kernel's half, and nothing takes the page at
        // zero, which is the one that has to keep faulting.
        try testing.expect(segment.at + segment.span <= LIMITS.kernel_base);
        try testing.expect(segment.first(PAGE) != 0);

        // The heap starts past everything the image asked for.
        try testing.expect(segment.last(PAGE) <= made.brk);

        // No two segments want the same page, whichever order they are in.
        for (made.list(), 0..) |other, j| {
            if (i == j) continue;
            try testing.expect(!segment.collidesWith(other, PAGE));
        }

        if (segment.executable and segment.holds(made.entry)) entry_is_in_code = true;
    }

    // And the first instruction is somewhere the file actually loads.
    try testing.expect(entry_is_in_code);
}

test "fuzz: a plan the loader is given is one it can carry out" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            return planOneImage(.{ .fuzzer = smith });
        }
    };
    try std.testing.fuzz({}, Target.one, .{});
}

test "a program image built at random is planned or refused, never believed wrongly" {
    try fuzzing.seeded(planOneImage, 0xE1F_0F0F, 4000);
}
