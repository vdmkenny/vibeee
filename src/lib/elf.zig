//! The ELF format, as a description rather than a loader.
//!
//! In `lib` because two very different pieces of code need the same layout:
//! the kernel loads these files, and a tool in userspace identifies them. Only
//! the shape lives here. Deciding what to do about a header is policy and
//! belongs to whichever of them is asking.

const std = @import("std");

pub const MAGIC = "\x7fELF";

/// Byte positions inside `ident`, which is the only part of the header whose
/// layout is fixed across every class of ELF file. Everything after it depends
/// on the class, which is why a reader has to check this much first.
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

/// The 32-bit header. The identification bytes at the front are laid out the
/// same in every ELF file, so a reader can trust them before it knows whether
/// the rest of this struct applies.
pub const Header = extern struct {
    magic: [4]u8,
    class: Class,
    data: Data,
    version: u8,
    abi: u8,
    abi_version: u8,
    _pad: [7]u8,
    type: Type,
    machine: Machine,
    object_version: u32,
    entry: u32,
    phoff: u32,
    shoff: u32,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,

    /// Whether the bytes begin with the identification every ELF file shares.
    /// True says nothing about the rest of the header being applicable.
    pub fn identifies(bytes: []const u8) bool {
        return bytes.len >= IDENT_LEN and std.mem.eql(u8, bytes[0..4], MAGIC);
    }

    /// Read the identification of any ELF file, whatever its class. Null when
    /// the bytes are not one.
    pub fn identify(bytes: []const u8) ?Ident {
        if (!identifies(bytes)) return null;
        return .{
            .class = @enumFromInt(bytes[4]),
            .data = @enumFromInt(bytes[5]),
            // Both classes place the machine here, which is what makes it
            // readable before knowing which of them applies.
            .machine = @enumFromInt(@as(u16, bytes[18]) | (@as(u16, bytes[19]) << 8)),
        };
    }
};

/// How far into a file the class-independent identification reaches.
pub const IDENT_LEN = 20;

/// What can be read from any ELF file regardless of its class.
pub const Ident = struct {
    class: Class,
    data: Data,
    machine: Machine,
};

pub const ProgramHeader = extern struct {
    type: SegmentType,
    offset: u32,
    vaddr: u32,
    paddr: u32,
    filesz: u32,
    memsz: u32,
    flags: Flags,
    alignment: u32,
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
    executable: bool,
    writable: bool,
    readable: bool,
    _rest: u29 = 0,
};

test "the identification is read the same way for either class" {
    var image: [IDENT_LEN]u8 = @splat(0);
    @memcpy(image[0..4], MAGIC);
    image[4] = @intFromEnum(Class.bits32);
    image[5] = @intFromEnum(Data.little);
    image[18] = 3;

    const ident = Header.identify(&image).?;
    try std.testing.expectEqual(Class.bits32, ident.class);
    try std.testing.expectEqual(Machine.x86, ident.machine);
    try std.testing.expectEqualStrings("x86", ident.machine.name());

    try std.testing.expect(Header.identify("not an elf file") == null);
}

test "the header is the size the format says" {
    try std.testing.expectEqual(@as(usize, 52), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ProgramHeader));
}
