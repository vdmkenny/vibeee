//! Converts a BDF bitmap font into a Zig source file.
//!
//! Run at build time so the `.bdf` stays the source of truth: the font can be
//! swapped, or a new size added, without a generated blob being edited by hand.
//!
//! Only the code points the console can display are kept: Latin-1 and the box
//! and block drawing characters the panic screen's QR renderer needs. A full
//! Unicode font would be megabytes, and everything beyond Latin-1 belongs to
//! the GUI's text stack rather than a text console.

const std = @import("std");

/// Glyphs are stored as a dense array indexed by code point, so lookup is one
/// index rather than a search. 0x2580-0x259F carries the block elements, which
/// the QR code needs; they are remapped down into the array to avoid reserving
/// nine thousand empty slots between Latin-1 and them.
const MAX_LATIN = 0x100;
const BLOCK_FIRST = 0x2580;
const BLOCK_LAST = 0x259F;
const BLOCK_SLOTS = BLOCK_LAST - BLOCK_FIRST + 1;
const TOTAL_SLOTS = MAX_LATIN + BLOCK_SLOTS;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) {
        std.debug.print("usage: mkfont <in.bdf> <out.zig> <name>\n", .{});
        return error.Usage;
    }

    const source = try cwd.readFileAlloc(io, args[1], gpa, .limited(8 << 20));
    defer gpa.free(source);

    var width: usize = 0;
    var height: usize = 0;

    // Bytes per glyph row, which is not width/8: a 12-pixel row occupies two
    // bytes with the low nibble of the second unused.
    var row_bytes: usize = 0;

    var glyphs = try gpa.alloc(u8, 0);
    defer gpa.free(glyphs);

    var present = try gpa.alloc(bool, TOTAL_SLOTS);
    defer gpa.free(present);
    @memset(present, false);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var encoding: ?usize = null;
    var in_bitmap = false;
    var bitmap_row: usize = 0;

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");

        if (std.mem.startsWith(u8, line, "FONTBOUNDINGBOX ")) {
            var it = std.mem.tokenizeScalar(u8, line["FONTBOUNDINGBOX ".len..], ' ');
            width = try std.fmt.parseInt(usize, it.next().?, 10);
            height = try std.fmt.parseInt(usize, it.next().?, 10);
            row_bytes = (width + 7) / 8;

            glyphs = try gpa.realloc(glyphs, TOTAL_SLOTS * height * row_bytes);
            @memset(glyphs, 0);
            continue;
        }

        if (std.mem.startsWith(u8, line, "ENCODING ")) {
            const value = std.fmt.parseInt(i32, line["ENCODING ".len..], 10) catch -1;
            encoding = slotFor(value);
            continue;
        }

        if (std.mem.eql(u8, line, "BITMAP")) {
            in_bitmap = true;
            bitmap_row = 0;
            continue;
        }

        if (std.mem.eql(u8, line, "ENDCHAR")) {
            in_bitmap = false;
            encoding = null;
            continue;
        }

        if (!in_bitmap) continue;
        const slot = encoding orelse continue;
        if (bitmap_row >= height) continue;

        // Each row is hex, most significant bit leftmost on screen.
        var b: usize = 0;
        while (b < row_bytes and b * 2 + 1 < line.len) : (b += 1) {
            const byte = std.fmt.parseInt(u8, line[b * 2 ..][0..2], 16) catch 0;
            glyphs[(slot * height + bitmap_row) * row_bytes + b] = byte;
        }
        present[slot] = true;
        bitmap_row += 1;
    }

    if (width == 0 or height == 0) {
        std.debug.print("{s}: no FONTBOUNDINGBOX\n", .{args[1]});
        return error.BadFont;
    }

    var covered: usize = 0;
    for (present) |p| {
        if (p) covered += 1;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try out.print(gpa,
        \\//! {s}, generated from {s} by `zig build fonts`. Do not edit.
        \\//!
        \\//! Spleen is Copyright (c) 2018-2026, Frederic Cambus, and is used
        \\//! under the BSD 2-Clause licence. See third_party/spleen/LICENSE.
        \\
        \\const font = @import("../drv/video/font.zig");
        \\
        \\pub const glyph_width: usize = {d};
        \\pub const glyph_height: usize = {d};
        \\pub const row_bytes: usize = {d};
        \\
        \\pub const desc = font.Font{{
        \\    .name = "{s}",
        \\    .width = glyph_width,
        \\    .height = glyph_height,
        \\    .row_bytes = row_bytes,
        \\    .bitmap = &bitmap,
        \\}};
        \\
        \\/// {d} glyphs: Latin-1 plus the block elements at U+2580-U+259F,
        \\/// remapped to follow it so the table stays dense.
        \\pub const bitmap = [_]u8{{
        \\
    , .{ args[3], std.fs.path.basename(args[1]), width, height, row_bytes, args[3], covered });

    for (glyphs, 0..) |byte, i| {
        if (i % 16 == 0) try out.appendSlice(gpa, "    ");
        try out.print(gpa, "0x{x:0>2},", .{byte});
        try out.appendSlice(gpa, if (i % 16 == 15) "\n" else " ");
    }

    try out.appendSlice(gpa, "};\n");

    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.items });
    std.debug.print("{s}: {d}x{d}, {d} glyphs, {d} KiB\n", .{
        args[3], width, height, covered, glyphs.len / 1024,
    });
}

/// Map a code point to its slot, or null if the font is not carrying it.
fn slotFor(code: i32) ?usize {
    if (code < 0) return null;
    if (code < MAX_LATIN) return @intCast(code);
    if (code >= BLOCK_FIRST and code <= BLOCK_LAST) {
        return MAX_LATIN + @as(usize, @intCast(code - BLOCK_FIRST));
    }
    return null;
}
