//! Converts a BDF bitmap font into a Zig source file.
//!
//! Run at build time so the `.bdf` stays the source of truth: a font can be
//! swapped, or a size added, without a generated blob being edited by hand.
//!
//! Handles both monospaced and proportional faces, because a UI font is not a
//! terminal font. Each glyph carries its own bounding box, offset and advance
//! width, and a renderer that assumed every glyph filled the font's box would
//! stack proportional text on top of itself.
//!
//! Only the code points the system can display are kept: Latin-1, plus the
//! block and box drawing characters the panic screen's QR renderer needs. A
//! full Unicode font would be megabytes.

const std = @import("std");

/// The subset and its slot order come from the renderer, so the generator
/// cannot disagree with it about which slot holds which character.
const font = @import("lib/font.zig");
const TOTAL_SLOTS = font.SLOTS;

/// One glyph as the file describes it, before it is placed in a cell.
const Glyph = struct {
    /// Bounding box of the ink, in pixels, and where it sits relative to the
    /// origin. `y_offset` is measured up from the baseline and is usually
    /// negative for a descender.
    width: i32 = 0,
    height: i32 = 0,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    /// How far the pen moves after drawing. Equal for every glyph in a
    /// monospaced face and the whole point of a proportional one.
    advance: i32 = 0,
    /// Bitmap rows, most significant bit leftmost, one entry per row.
    rows: std.ArrayList(u32) = .empty,
    present: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) {
        std.debug.print("usage: mkfont <in.bdf> <out.zig> <name>\n", .{});
        return error.Usage;
    }

    const source = try cwd.readFileAlloc(io, args[1], gpa, .limited(32 << 20));
    defer gpa.free(source);

    const glyphs = try gpa.alloc(Glyph, TOTAL_SLOTS);
    defer {
        for (glyphs) |*g| g.rows.deinit(gpa);
        gpa.free(glyphs);
    }
    for (glyphs) |*g| g.* = .{};

    try parse(gpa, source, glyphs);

    // The cell is the union of every glyph's box, not what FONTBOUNDINGBOX
    // claims: fonts routinely declare a box their glyphs exceed, and clipping
    // to the declared one cuts the tops off capitals.
    const metrics = measure(glyphs);
    if (metrics.height == 0) {
        std.debug.print("{s}: no usable glyphs\n", .{args[1]});
        return error.BadFont;
    }

    const row_bytes: usize = (@as(usize, @intCast(metrics.width)) + 7) / 8;
    const cell = @as(usize, @intCast(metrics.height)) * row_bytes;

    const bitmap = try gpa.alloc(u8, TOTAL_SLOTS * cell);
    defer gpa.free(bitmap);
    @memset(bitmap, 0);

    const advances = try gpa.alloc(u8, TOTAL_SLOTS);
    defer gpa.free(advances);
    @memset(advances, @intCast(metrics.width));

    var covered: usize = 0;
    var proportional = false;

    for (glyphs, 0..) |*g, slot| {
        if (!g.present) continue;
        covered += 1;

        place(g, bitmap[slot * cell ..][0..cell], metrics, row_bytes);

        const advance = if (g.advance > 0) g.advance else metrics.width;
        advances[slot] = @intCast(@min(advance, 255));
        if (advance != metrics.width) proportional = true;
    }

    try emit(gpa, io, cwd, args, .{
        .metrics = metrics,
        .row_bytes = row_bytes,
        .bitmap = bitmap,
        .advances = advances,
        .covered = covered,
        .proportional = proportional,
    });

    std.debug.print("{s}: {d}x{d} cell, {d} glyphs, {s}, {d} KiB\n", .{
        args[3],
        metrics.width,
        metrics.height,
        covered,
        if (proportional) "proportional" else "monospaced",
        bitmap.len / 1024,
    });
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

fn parse(gpa: std.mem.Allocator, source: []const u8, glyphs: []Glyph) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');

    var slot: ?usize = null;
    var pending: Glyph = .{};
    var in_bitmap = false;

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");

        if (std.mem.startsWith(u8, line, "ENCODING ")) {
            const value = std.fmt.parseInt(i32, line["ENCODING ".len..], 10) catch -1;
            slot = slotFor(value);
            pending = .{};
            continue;
        }

        if (std.mem.startsWith(u8, line, "DWIDTH ")) {
            var it = std.mem.tokenizeScalar(u8, line["DWIDTH ".len..], ' ');
            pending.advance = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
            continue;
        }

        if (std.mem.startsWith(u8, line, "BBX ")) {
            var it = std.mem.tokenizeScalar(u8, line["BBX ".len..], ' ');
            pending.width = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
            pending.height = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
            pending.x_offset = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
            pending.y_offset = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
            continue;
        }

        if (std.mem.eql(u8, line, "BITMAP")) {
            in_bitmap = true;
            continue;
        }

        if (std.mem.eql(u8, line, "ENDCHAR")) {
            in_bitmap = false;
            if (slot) |s| {
                if (pending.rows.items.len > 0) {
                    glyphs[s].rows.deinit(gpa);
                    glyphs[s] = pending;
                    glyphs[s].present = true;
                    pending = .{};
                }
            }
            // Anything not stored belongs to a code point outside the subset.
            pending.rows.deinit(gpa);
            pending = .{};
            slot = null;
            continue;
        }

        if (!in_bitmap or slot == null) continue;

        // A row is hex, padded to whole bytes, most significant bit leftmost.
        // Held left-aligned in a u32 so placement can shift it either way.
        var value: u32 = 0;
        var digits: usize = 0;
        for (line) |c| {
            const nibble = std.fmt.charToDigit(c, 16) catch break;
            value = (value << 4) | nibble;
            digits += 1;
        }
        if (digits == 0) continue;
        value <<= @intCast(32 - digits * 4);
        try pending.rows.append(gpa, value);
    }
}

const Metrics = struct {
    width: i32 = 0,
    height: i32 = 0,
    /// Rows above the baseline. Needed to line glyphs of different heights up
    /// on it rather than on the top of their boxes.
    ascent: i32 = 0,
};

fn measure(glyphs: []const Glyph) Metrics {
    var ascent: i32 = 0;
    var descent: i32 = 0;
    var width: i32 = 0;

    for (glyphs) |g| {
        if (!g.present) continue;
        ascent = @max(ascent, g.y_offset + g.height);
        descent = @max(descent, -g.y_offset);
        width = @max(width, @max(g.x_offset + g.width, g.advance));
    }

    return .{ .width = width, .height = ascent + descent, .ascent = ascent };
}

/// Copy a glyph's rows into its cell, aligned on the baseline.
fn place(g: *const Glyph, cell: []u8, metrics: Metrics, row_bytes: usize) void {
    // Distance from the top of the cell to the top of this glyph's box.
    const top = metrics.ascent - (g.y_offset + g.height);

    for (g.rows.items, 0..) |row, i| {
        const y = top + @as(i32, @intCast(i));
        if (y < 0 or y >= metrics.height) continue;

        var x: i32 = 0;
        while (x < g.width) : (x += 1) {
            if (row >> @intCast(31 - x) & 1 == 0) continue;

            const target = x + g.x_offset;
            if (target < 0 or target >= metrics.width) continue;

            const byte = @as(usize, @intCast(y)) * row_bytes + @as(usize, @intCast(target)) / 8;
            cell[byte] |= @as(u8, 1) << @intCast(7 - @as(u3, @intCast(@mod(target, 8))));
        }
    }
}

/// Map a code point to its slot, or null if it is outside the subset.
fn slotFor(code: i32) ?usize {
    if (code < 0 or code > 0x10FFFF) return null;
    return font.slotFor(@intCast(code));
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

const Emit = struct {
    metrics: Metrics,
    row_bytes: usize,
    bitmap: []const u8,
    advances: []const u8,
    covered: usize,
    proportional: bool,
};

fn emit(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    args: []const []const u8,
    data: Emit,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try out.print(gpa,
        \\//! {s}, generated from {s} by `zig build fonts`. Do not edit.
        \\//!
        \\//! See third_party/ for the source font and its licence.
        \\
        \\const font = @import("../font.zig");
        \\
        \\pub const glyph_width: usize = {d};
        \\pub const glyph_height: usize = {d};
        \\pub const row_bytes: usize = {d};
        \\pub const ascent: usize = {d};
        \\
        \\pub const desc = font.Font{{
        \\    .name = "{s}",
        \\    .width = glyph_width,
        \\    .height = glyph_height,
        \\    .row_bytes = row_bytes,
        \\    .ascent = ascent,
        \\    .bitmap = &bitmap,
        \\    .advances = {s},
        \\}};
        \\
        \\/// {d} glyphs, in the slot order `lib/font.zig` defines.
        \\pub const bitmap = [_]u8{{
        \\
    , .{
        args[3],
        std.fs.path.basename(args[1]),
        data.metrics.width,
        data.metrics.height,
        data.row_bytes,
        data.metrics.ascent,
        args[3],
        if (data.proportional) "&advances" else "null",
        data.covered,
    });

    try writeBytes(gpa, &out, data.bitmap);
    try out.appendSlice(gpa, "};\n");

    if (data.proportional) {
        try out.appendSlice(gpa,
            \\
            \\/// How far the pen moves after each glyph. Not the cell width:
            \\/// that is the widest glyph, and most are narrower.
            \\pub const advances = [_]u8{
            \\
        );
        try writeBytes(gpa, &out, data.advances);
        try out.appendSlice(gpa, "};\n");
    }

    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.items });
}

fn writeBytes(gpa: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    for (bytes, 0..) |byte, i| {
        if (i % 16 == 0) try out.appendSlice(gpa, "    ");
        try out.print(gpa, "0x{x:0>2},", .{byte});
        try out.appendSlice(gpa, if (i % 16 == 15) "\n" else " ");
    }
    if (bytes.len % 16 != 0) try out.appendSlice(gpa, "\n");
}
