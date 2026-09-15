//! Turns the assembled wake trampoline into `src/arch/x86/s3wake.zig`.
//!
//! The first instructions after waking from a suspend to memory run in real
//! mode, so they cannot be written in Zig and cannot be linked into the
//! kernel: it is a flat binary assembled at the address it is copied
//! to. This reads that binary and writes it out as bytes the kernel can
//! copy, generated and committed the way the console fonts and the driver
//! manifests are, so a change to the trampoline shows up as a diff somebody
//! can read.
//!
//! It also checks the layout the kernel patches. `boot/s3wake.asm` starts
//! with a short jump over three words, and `arch/x86/s3.zig` fills those in
//! before the machine sleeps. Nothing in a flat binary says where they are,
//! so what is assumed is checked here: a trampoline whose shape moved fails
//! the build rather than waking the machine into whatever it finds.

const std = @import("std");

/// What the first bytes have to be: a short jump landing on the first
/// instruction after the three patched words.
const JUMP = [_]u8{ 0xEB, 0x0E };
const WORDS_AT = 4;
const WORDS = 3;
const CODE_AT = WORDS_AT + WORDS * 4;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) return error.MissingArguments;
    const gpa = init.gpa;

    const origin = try std.fmt.parseInt(u32, args[3], 0);
    const code = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], gpa, .limited(4096));
    defer gpa.free(code);

    if (code.len < CODE_AT) return error.TrampolineTooShort;
    if (!std.mem.eql(u8, code[0..JUMP.len], &JUMP)) return error.TrampolineDoesNotJumpOverThePatchedWords;
    // Assembled as zeroes, which is the only way to tell data apart from code
    // in a flat binary.
    if (!std.mem.allEqual(u8, code[WORDS_AT..CODE_AT], 0)) return error.PatchedWordsAreNotWhereTheyWere;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try write(gpa, &text, code, origin);

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = text.items });
    std.debug.print("wrote {d} bytes of wake trampoline into {s}\n", .{ code.len, args[2] });
}

fn write(gpa: std.mem.Allocator, w: *std.ArrayList(u8), code: []const u8, origin: u32) !void {
    try w.print(gpa,
        \\//! The instructions the firmware jumps to on waking, as bytes.
        \\//!
        \\//! Generated from `boot/s3wake.asm` by `zig build s3-trampoline`.
        \\//! Do not edit: change the assembly instead.
        \\
        \\/// Where this is copied to, and the address it was assembled for: the
        \\/// jumps in it name absolute addresses, so it runs nowhere else.
        \\pub const at: u32 = 0x{X};
        \\
        \\/// What the kernel writes into it before the machine sleeps, by how far
        \\/// into the page each word sits.
        \\pub const Patch = enum(usize) {{
        \\    cr3 = {d},
        \\    cr4 = {d},
        \\    entry = {d},
        \\}};
        \\
        \\pub const code = [_]u8{{
        \\
    , .{ origin, WORDS_AT, WORDS_AT + 4, WORDS_AT + 8 });

    const PER_LINE = 12;
    var i: usize = 0;
    while (i < code.len) : (i += PER_LINE) {
        try w.appendSlice(gpa, "   ");
        for (code[i..@min(i + PER_LINE, code.len)]) |byte| {
            try w.print(gpa, " 0x{X:0>2},", .{byte});
        }
        try w.append(gpa, '\n');
    }
    try w.appendSlice(gpa, "};\n");
}
