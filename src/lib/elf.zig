//! The ELF format: layouts, and reading them from untrusted bytes.
//!
//! Shared by the kernel's loader and userspace tools. What a file may ask for
//! is the caller's policy.

const std = @import("std");

pub const MAGIC = "\x7fELF";

pub const Class = enum(u8) {
    none = 0,
    bits32 = 1,
    bits64 = 2,
    _,
};

pub const Data = enum(u8) {
    none = 0,
    little = 1,
    big = 2,
    _,
};

pub const Type = enum(u16) {
    none = 0,
    relocatable = 1,
    executable = 2,
    shared = 3,
    core = 4,
    _,
};

pub const Machine = enum(u16) {
    none = 0,
    x86 = 3,
    arm = 40,
    x86_64 = 0x3E,
    aarch64 = 0xB7,
    riscv = 0xF3,
    _,

    /// What to call it in a report, for the handful worth naming.
    pub fn name(self: Machine) []const u8 {
        return switch (self) {
            .x86 => "x86",
            .x86_64 => "x86-64",
            .arm => "arm",
            .aarch64 => "aarch64",
            .riscv => "riscv",
            else => "another machine",
        };
    }
};

/// The start of every ELF file, laid out the same for either class. Defaults
/// describe a 32-bit little-endian x86 executable.
pub const Ident = extern struct {
    magic: [4]u8 = MAGIC.*,
    class: Class = .bits32,
    data: Data = .little,
    version: u8 = 1,
    abi: u8 = 0,
    abi_version: u8 = 0,
    _pad: [7]u8 = @splat(0),
    type: Type = .executable,
    machine: Machine = .x86,

    /// The identification at the start of `bytes`. Null when `bytes` does not
    /// start an ELF file.
    pub fn of(bytes: []const u8) ?Ident {
        if (bytes.len < @sizeOf(Ident)) return null;
        const ident = std.mem.bytesToValue(Ident, bytes[0..@sizeOf(Ident)]);
        if (!std.mem.eql(u8, &ident.magic, MAGIC)) return null;
        return ident;
    }
};

/// The 32-bit header. Defaults describe an executable whose program header
/// table follows the header.
pub const Header = extern struct {
    ident: Ident = .{},
    object_version: u32 = 1,
    entry: u32 = 0,
    phoff: u32 = @sizeOf(Header),
    shoff: u32 = 0,
    flags: u32 = 0,
    ehsize: u16 = @sizeOf(Header),
    phentsize: u16 = @sizeOf(ProgramHeader),
    phnum: u16 = 0,
    shentsize: u16 = 0,
    shnum: u16 = 0,
    shstrndx: u16 = 0,

    pub const Error = error{ NotElf, WrongClass };

    /// The header at the start of `file`, a 32-bit little-endian ELF file.
    pub fn of(file: []const u8) Error!*align(1) const Header {
        if (file.len < @sizeOf(Header)) return error.NotElf;
        const ident = Ident.of(file) orelse return error.NotElf;
        if (ident.class != .bits32 or ident.data != .little) return error.WrongClass;
        return std.mem.bytesAsValue(Header, file[0..@sizeOf(Header)]);
    }

    /// The program header table in `file`, the bytes this header was read
    /// from. Null when its entries are another size or it is not inside `file`.
    pub fn programs(self: *align(1) const Header, file: []const u8) ?[]align(1) const ProgramHeader {
        if (self.phentsize != @sizeOf(ProgramHeader) or self.phoff > file.len) return null;
        const table = file[self.phoff..];
        const size = @as(u32, self.phnum) * @sizeOf(ProgramHeader);
        if (size > table.len) return null;
        return std.mem.bytesAsSlice(ProgramHeader, table[0..size]);
    }
};

pub const ProgramHeader = extern struct {
    type: SegmentType,
    offset: u32 = 0,
    vaddr: u32 = 0,
    paddr: u32 = 0,
    filesz: u32 = 0,
    memsz: u32 = 0,
    flags: Flags = .{},
    alignment: u32 = 0,
};

pub const SegmentType = enum(u32) {
    none = 0,
    load = 1,
    dynamic = 2,
    interp = 3,
    note = 4,
    _,
};

pub const Flags = packed struct(u32) {
    executable: bool = false,
    writable: bool = false,
    readable: bool = false,
    _rest: u29 = 0,
};

// ---------------------------------------------------------------------------
// Notes
//
// Data attached to a file: a header, an owner name and a description, each
// padded to four-byte words. `PT_NOTE` segments hold them. The owner name
// namespaces the type.
// ---------------------------------------------------------------------------

pub const NoteHeader = extern struct {
    name_size: u32,
    desc_size: u32,
    type: u32,
};

/// Owner name of vibeee's notes.
pub const VIBEEE_OWNER = "vibeee";

/// Note types under `VIBEEE_OWNER`. A changed description format gets a new
/// type.
pub const VibeeeNote = enum(u32) {
    /// A program's icon, in the toolkit's picture format.
    icon = 1,
    _,
};

/// One note. `owner` is without its terminating NUL.
pub const Note = struct {
    owner: []const u8,
    type: u32,
    desc: []const u8,
};

/// The notes in a note segment, in order. Ends at the first that does not fit.
pub const Notes = struct {
    rest: []const u8,

    pub fn next(self: *Notes) ?Note {
        var rest = self.rest;
        const header = std.mem.bytesToValue(NoteHeader, take(&rest, @sizeOf(NoteHeader)) orelse return null);
        const name = take(&rest, header.name_size) orelse return null;
        const desc = take(&rest, header.desc_size) orelse return null;
        self.rest = rest;
        return .{
            .owner = if (std.mem.indexOfScalar(u8, name, 0)) |nul| name[0..nul] else name,
            .type = header.type,
            .desc = desc,
        };
    }

    /// The next `size` bytes of `rest`. Steps past them and their padding.
    fn take(rest: *[]const u8, size: u32) ?[]const u8 {
        const words = wordsFor(size);
        if (words > rest.len / 4) return null;
        const bytes = rest.*[0..size];
        rest.* = rest.*[@as(usize, words) * 4 ..];
        return bytes;
    }
};

/// Four-byte words that hold `size` bytes.
fn wordsFor(size: u32) u32 {
    return std.math.divCeil(u32, size, 4) catch unreachable;
}

/// A note whose description is one `Desc`, laid out as in a file: exported
/// into a section, and found again in a note segment.
pub fn FixedNote(comptime owner: []const u8, comptime note_type: u32, comptime Desc: type) type {
    if (!anyBytesAre(Desc)) @compileError("a note description must be readable from any bytes");
    const name_size = owner.len + 1;

    const Layout = extern struct {
        header: NoteHeader = .{
            .name_size = name_size,
            .desc_size = @sizeOf(Desc),
            .type = note_type,
        },
        name: [wordsFor(name_size) * 4]u8 = padded: {
            var name: [wordsFor(name_size) * 4]u8 = @splat(0);
            @memcpy(name[0..owner.len], owner);
            break :padded name;
        },
        desc: Desc,

        /// The description of the first note in `segment` with this owner and
        /// type. Null when there is none or its description is another size.
        pub fn find(segment: []const u8) ?Desc {
            var notes: Notes = .{ .rest = segment };
            while (notes.next()) |note| {
                if (note.type != note_type or !std.mem.eql(u8, note.owner, owner)) continue;
                if (note.desc.len != @sizeOf(Desc)) return null;
                return std.mem.bytesToValue(Desc, note.desc);
            }
            return null;
        }
    };

    // Nothing may pad the fields apart or pad the description's end.
    if (@offsetOf(Layout, "desc") != @sizeOf(NoteHeader) + @sizeOf(@FieldType(Layout, "name")) or
        @sizeOf(Layout) != @offsetOf(Layout, "desc") + @sizeOf(Desc))
    {
        @compileError("a note description must be whole four-byte words, aligned to at most four");
    }
    return Layout;
}

/// Whether every bit pattern of `T` is a `T`, so a `T` can be read from a file.
fn anyBytesAre(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => true,
        .array => |array| anyBytesAre(array.child),
        .@"enum" => |e| !e.is_exhaustive,
        .@"struct" => |s| s.layout == .@"extern" and for (s.fields) |field| {
            if (!anyBytesAre(field.type)) break false;
        } else true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the layouts are the sizes the format says" {
    try testing.expectEqual(20, @sizeOf(Ident));
    try testing.expectEqual(52, @sizeOf(Header));
    try testing.expectEqual(32, @sizeOf(ProgramHeader));
    try testing.expectEqual(12, @sizeOf(NoteHeader));
}

test "the identification is read the same way for either class" {
    const ours = std.mem.toBytes(Ident{});
    const ident = Ident.of(&ours).?;
    try testing.expectEqual(Class.bits32, ident.class);
    try testing.expectEqual(Machine.x86, ident.machine);
    try testing.expectEqualStrings("x86", ident.machine.name());

    const theirs = std.mem.toBytes(Ident{ .class = .bits64, .machine = .aarch64, .type = .shared });
    try testing.expectEqual(Type.shared, Ident.of(&theirs).?.type);

    try testing.expect(Ident.of("not an elf file, but long enough") == null);
    try testing.expect(Ident.of(ours[0 .. ours.len - 1]) == null);
}

/// A file holding a header and `programs` after it.
fn fileWith(comptime programs: []const ProgramHeader) [@sizeOf(Header) + programs.len * @sizeOf(ProgramHeader)]u8 {
    return std.mem.toBytes(Header{ .phnum = programs.len }) ++ std.mem.sliceAsBytes(programs)[0 .. programs.len * @sizeOf(ProgramHeader)].*;
}

test "only a 32-bit little-endian ELF file has a header to read" {
    var file = fileWith(&.{});
    _ = try Header.of(&file);
    try testing.expectError(error.NotElf, Header.of(file[0 .. file.len - 1]));

    const header = std.mem.bytesAsValue(Header, file[0..@sizeOf(Header)]);
    header.* = .{ .ident = .{ .class = .bits64 } };
    try testing.expectError(error.WrongClass, Header.of(&file));
    header.* = .{ .ident = .{ .data = .big } };
    try testing.expectError(error.WrongClass, Header.of(&file));
    header.* = .{ .ident = .{ .magic = "\x7fELL".* } };
    try testing.expectError(error.NotElf, Header.of(&file));
}

test "the program header table is read from where the header says" {
    const programs = [_]ProgramHeader{
        .{ .type = .load, .offset = 0x1000, .filesz = 0x2000 },
        .{ .type = .note, .offset = 0x3000, .filesz = 44 },
    };
    const file = fileWith(&programs);
    const table = (try Header.of(&file)).programs(&file).?;
    try testing.expectEqual(programs.len, table.len);
    for (programs, table) |want, got| try testing.expectEqual(want, got);
}

test "a program header table not inside the file is refused" {
    var file = fileWith(&.{.{ .type = .note, .offset = 0x3000, .filesz = 44 }});
    const header = std.mem.bytesAsValue(Header, file[0..@sizeOf(Header)]);
    try testing.expect(header.programs(file[0 .. file.len - 1]) == null);

    header.* = .{ .phnum = 1, .phoff = 0xFFFF_FFF0 };
    try testing.expect(header.programs(&file) == null);
    header.* = .{ .phnum = 1000 };
    try testing.expect(header.programs(&file) == null);
    header.* = .{ .phnum = 1, .phentsize = 56 };
    try testing.expect(header.programs(&file) == null);
}

const Icon = FixedNote(VIBEEE_OWNER, @intFromEnum(VibeeeNote.icon), [24]u8);

/// `notes` one after another, in `into`.
fn segmentOf(into: []u8, notes: anytype) []u8 {
    var len: usize = 0;
    inline for (notes) |note| {
        const bytes = std.mem.asBytes(&note);
        @memcpy(into[len..][0..bytes.len], bytes);
        len += bytes.len;
    }
    return into[0..len];
}

test "a fixed note is found in its own bytes" {
    const note: Icon = .{ .desc = @splat(0xA5) };
    try testing.expectEqual(0, @sizeOf(Icon) % 4);
    try testing.expectEqual(@as(?[24]u8, @splat(0xA5)), Icon.find(std.mem.asBytes(&note)));
}

test "notes of other owners and types are passed over" {
    var room: [128]u8 = undefined;
    const segment = segmentOf(&room, .{
        FixedNote("GNU", @intFromEnum(VibeeeNote.icon), [20]u8){ .desc = @splat(1) },
        FixedNote(VIBEEE_OWNER, 99, [4]u8){ .desc = @splat(2) },
        Icon{ .desc = @splat(3) },
    });
    try testing.expectEqual(@as(?[24]u8, @splat(3)), Icon.find(segment));
}

test "the first note of the owner and type decides, whatever its size" {
    var room: [128]u8 = undefined;
    const segment = segmentOf(&room, .{
        FixedNote(VIBEEE_OWNER, @intFromEnum(VibeeeNote.icon), [8]u8){ .desc = @splat(4) },
        Icon{ .desc = @splat(3) },
    });
    try testing.expect(Icon.find(segment) == null);
}

test "a note cut short is not found" {
    const bytes = std.mem.asBytes(&Icon{ .desc = @splat(0) });
    for (0..bytes.len) |cut| try testing.expect(Icon.find(bytes[0..cut]) == null);
}

test "sizes near the top of their range end the walk" {
    for ([_]u32{ std.math.maxInt(u32), std.math.maxInt(u32) - 3, 1 << 31 }) |size| {
        var bytes: [@sizeOf(NoteHeader) + 8]u8 = @splat(0);
        std.mem.bytesAsValue(NoteHeader, bytes[0..@sizeOf(NoteHeader)]).* = .{
            .name_size = size,
            .desc_size = 4,
            .type = 1,
        };
        var notes: Notes = .{ .rest = &bytes };
        try testing.expect(notes.next() == null);
    }
}

// ---------------------------------------------------------------------------
// Fuzzing
//
// Run with `make fuzz`. A segment is built from well-formed notes of chosen
// sizes, some size words are replaced, and it is cut short. The walk must end,
// and every owner and description it returns must lie inside the segment.
// ---------------------------------------------------------------------------

const fuzzing = @import("fuzzing.zig");
const Choices = fuzzing.Choices;

/// A size word: the true size, one more, near the top of its range, or any.
fn sizeWord(from: Choices, true_size: u32) u32 {
    return switch (from.one(enum { true_size, one_more, near_top, any })) {
        .true_size => true_size,
        .one_more => true_size +% 1,
        .near_top => std.math.maxInt(u32) - @as(u32, @intCast(from.below(8))),
        .any => from.int(u32),
    };
}

/// Whether `inner` lies inside `outer`.
fn inside(outer: []const u8, inner: []const u8) bool {
    const at = @intFromPtr(inner.ptr);
    return at >= @intFromPtr(outer.ptr) and at + inner.len <= @intFromPtr(outer.ptr) + outer.len;
}

fn walkOneSegment(from: Choices) anyerror!void {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    var headers: [6]*align(1) NoteHeader = undefined;
    var count: usize = 0;

    for (0..from.upTo(headers.len)) |_| {
        const name_size: u32 = @intCast(from.below(12) + 1);
        const desc_size: u32 = @intCast(from.below(40));
        const size = @sizeOf(NoteHeader) + (wordsFor(name_size) + wordsFor(desc_size)) * 4;
        if (size > buf.len - len) break;

        const note = buf[len..][0..size];
        from.bytes(note);
        headers[count] = std.mem.bytesAsValue(NoteHeader, note[0..@sizeOf(NoteHeader)]);
        headers[count].* = .{ .name_size = name_size, .desc_size = desc_size, .type = from.int(u32) };
        count += 1;
        len += size;
    }

    for (headers[0..count]) |header| {
        if (!from.odds(3)) continue;
        header.name_size = sizeWord(from, header.name_size);
        header.desc_size = sizeWord(from, header.desc_size);
    }

    const segment = buf[0..from.below(len + 1)];
    var notes: Notes = .{ .rest = segment };
    var steps: usize = 0;
    while (notes.next()) |note| : (steps += 1) {
        // Each note takes at least a header's bytes.
        try testing.expect((steps + 1) * @sizeOf(NoteHeader) <= segment.len);
        try testing.expect(inside(segment, note.owner));
        try testing.expect(inside(segment, note.desc));
    }
}

test "fuzz: a note segment from any file is walked without straying" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            return walkOneSegment(.{ .fuzzer = smith });
        }
    };
    try std.testing.fuzz({}, Target.one, .{});
}

test "a note segment built at random is walked without straying" {
    try fuzzing.seeded(walkOneSegment, 0x0E1F_407E, 2000);
}
