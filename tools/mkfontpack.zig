//! Packs the interface faces into the file every GUI program reads.
//!
//! The generated tables in `src/lib/fonts/` stay the source of truth: this
//! reads them and writes the same glyphs as one file, so the pack cannot
//! disagree with what `make fonts` produced.

const std = @import("std");
const font = @import("lib").font;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: mkfontpack <out.pack>\n", .{});
        return error.Usage;
    }

    // The order the pack's own `Face` names, so a reader indexes rather than
    // searches.
    const faces = [_]*const font.Font{ &font.ark_ui_12, &font.ark_ui_16, &font.ark_mono_12 };

    const bytes = try gpa.alloc(u8, font.pack.sizeOf(faces));
    defer gpa.free(bytes);
    const written = font.pack.write(bytes, faces);

    // Read back what is about to be written: a pack this tool cannot parse is
    // one no program will draw with, and finding that out here beats finding
    // it out on a machine with no text on the screen.
    if (font.pack.read(written) == null) return error.BadPack;

    try cwd.writeFile(io, .{ .sub_path = args[1], .data = written });
    std.debug.print("  fonts   {s}, {d} bytes\n", .{ args[1], written.len });
}
