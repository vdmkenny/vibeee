//! The ELF notes a program carries in its binary.
//!
//! Reads the header and program header table from the start of the file, then
//! each note segment. Layouts and checks are `lib/elf.zig`'s.

const elf = @import("lib").elf;
const file = @import("file.zig");

/// Program headers read from the start of a program.
const PROGRAMS_MAX = 16;

/// Largest note segment read. Larger ones are passed over.
const SEGMENT_BYTES = 256;

/// The description of the `Note` the program at `path` carries. `Note` is an
/// `elf.FixedNote`. Null when the file cannot be read, is not a 32-bit ELF
/// file, or carries no such note.
pub fn read(comptime Note: type, path: []const u8) ?@FieldType(Note, "desc") {
    var head: [@sizeOf(elf.Header) + PROGRAMS_MAX * @sizeOf(elf.ProgramHeader)]u8 = undefined;
    const head_len = file.readWhole(path, &head) orelse return null;
    const header = elf.Header.of(head[0..head_len]) catch return null;
    const programs = header.programs(head[0..head_len]) orelse return null;

    var segment: [SEGMENT_BYTES]u8 = undefined;
    for (programs) |program| {
        if (program.type != .note or program.filesz > segment.len) continue;
        const len = file.readAt(path, program.offset, segment[0..program.filesz]) orelse continue;
        if (Note.find(segment[0..len])) |desc| return desc;
    }
    return null;
}
