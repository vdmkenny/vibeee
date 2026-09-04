//! Bitmap font description.
//!
//! A font is a dense bitmap indexed by slot, plus its metrics. Everything that
//! draws text works through this, so swapping a font, or shipping several
//! sizes and choosing at boot, needs no change anywhere else.
//!
//! In `lib/` because both sides draw text: the kernel console renders the boot
//! log and the panic screen, and the GUI toolkit renders everything else. One
//! copy of the glyphs, one place that knows how a row of them is packed.

const std = @import("std");

/// The code points a font is subset to, and the order their slots run in.
///
/// Shared with `mkfont`, which builds the tables, so the generator and the
/// renderer cannot disagree about which slot holds which character. A dense
/// array indexed by slot makes lookup one index rather than a search; ranges
/// rather than all of Unicode keeps a font at ten kilobytes instead of
/// megabytes.
pub const Range = struct {
    first: u21,
    last: u21,

    pub fn count(self: Range) usize {
        return self.last - self.first + 1;
    }
};

pub const ranges = [_]Range{
    // Latin-1: everything a Western text console needs.
    .{ .first = 0x0000, .last = 0x00FF },
    // General punctuation: the ellipsis, bullets and real dashes, which are
    // the difference between typeset text and a terminal transcript.
    .{ .first = 0x2010, .last = 0x203A },
    // Arrows, for menus, scrollbars and anything that points.
    .{ .first = 0x2190, .last = 0x21BB },
    // Box drawing, which the terminal's DEC graphics mode maps onto and which
    // draws a frame more cheaply than four fills.
    .{ .first = 0x2500, .last = 0x257F },
    // Block elements, used by the panic screen's QR renderer.
    .{ .first = 0x2580, .last = 0x259F },
    // Geometric shapes: the triangles, squares and circles that make a
    // dropdown marker or a radio button without a bitmap.
    .{ .first = 0x25A0, .last = 0x25CF },
};

/// Total slots, so both sides size the same table.
pub const SLOTS = blk: {
    var total: usize = 0;
    for (ranges) |r| total += r.count();
    break :blk total;
};

/// Where a code point's glyph lives, or null if it is outside the subset.
pub fn slotFor(code: u21) ?usize {
    var base: usize = 0;
    for (ranges) |r| {
        if (code >= r.first and code <= r.last) return base + (code - r.first);
        base += r.count();
    }
    return null;
}

/// Characters the interface draws by name rather than by number, so a call
/// site reads as what it means and a font without one can be substituted in
/// one place.
pub const glyphs = struct {
    pub const ellipsis: u21 = 0x2026;
    pub const bullet: u21 = 0x2022;
    pub const arrow_left: u21 = 0x2190;
    pub const arrow_right: u21 = 0x2192;
    pub const triangle_down: u21 = 0x25BC;
    pub const triangle_right: u21 = 0x25B6;
    pub const square: u21 = 0x25A0;
    pub const square_hollow: u21 = 0x25A1;
    pub const circle: u21 = 0x25CF;
    /// Box drawing, for rules and frames.
    pub const rule_h: u21 = 0x2500;
    pub const rule_v: u21 = 0x2502;
};

/// The rows of a cell a glyph occupies.
pub const Band = struct {
    top: usize,
    bottom: usize,

    /// Twice the middle, so half a row stays a whole number.
    pub fn twiceMiddle(self: Band) usize {
        return self.top + self.bottom;
    }
};

pub const Font = struct {
    name: []const u8,
    width: usize,
    height: usize,
    /// Bytes per glyph row. Not width/8, a 12-pixel row occupies two bytes.
    row_bytes: usize,
    /// Rows above the baseline. Text is positioned by its top edge everywhere
    /// here, so this matters only when mixing faces of different heights.
    ascent: usize = 0,
    bitmap: []const u8,
    /// Advance width per slot for a proportional face, or null for a
    /// monospaced one where every glyph advances by `width`. Text layout goes
    /// through `advance` so a caller never has to know which it has.
    advances: ?[]const u8 = null,

    pub fn isProportional(self: *const Font) bool {
        return self.advances != null;
    }

    /// The rows a glyph actually inks, top and bottom, or null for one that
    /// is blank or absent.
    ///
    /// What a face's numbers do not say: `height` counts the whole cell and
    /// `ascent` says where the baseline is, but neither says where the body
    /// of a letter sits between them. Anything placing a picture beside a
    /// word needs that, and measuring the face is more honest than a constant
    /// somebody read off a screenshot.
    pub fn inkBand(self: *const Font, code: u21) ?Band {
        const rows = self.glyph(code) orelse return null;

        var top: ?usize = null;
        var bottom: usize = 0;
        for (0..self.height) |y| {
            var inked = false;
            for (0..self.row_bytes) |byte| {
                if (rows[y * self.row_bytes + byte] != 0) inked = true;
            }
            if (!inked) continue;
            if (top == null) top = y;
            bottom = y;
        }

        return .{ .top = top orelse return null, .bottom = bottom };
    }

    /// Bitmap rows for a code point, or null if the font does not carry it.
    pub fn glyph(self: *const Font, code: u21) ?[]const u8 {
        const slot = self.slotOf(code) orelse return null;
        const size = self.height * self.row_bytes;
        const start = slot * size;
        if (start + size > self.bitmap.len) return null;
        return self.bitmap[start..][0..size];
    }

    fn slotOf(self: *const Font, code: u21) ?usize {
        _ = self;
        return slotFor(code);
    }

    /// How far the pen moves after drawing `code`.
    pub fn advance(self: *const Font, code: u21) usize {
        const table = self.advances orelse return self.width;
        const slot = self.slotOf(code) orelse return self.width;
        if (slot >= table.len) return self.width;

        // A slot the face never filled advances by the face's own width. Zero
        // would draw the next character on top of this one, and a subset that
        // omits a codepoint should cost a blank, not a collision.
        const value = table[slot];
        return if (value == 0) self.width else value;
    }

    /// Width of a string in pixels.
    ///
    /// By character, not by byte: a three-byte box-drawing rule advances once,
    /// and counting its bytes made every measurement of anything above Latin-1
    /// three times too wide.
    /// How much of `text` fits in `room`, leaving space for the mark that
    /// says it was cut, and whether it had to be cut at all.
    ///
    /// Cut on a character, never inside one: half a letter is a notdef box,
    /// which reads as a fault rather than as an abbreviation.
    pub fn fit(self: *const Font, text: []const u8, room: usize) struct { len: usize, cut: bool } {
        if (self.measure(text) <= room) return .{ .len = text.len, .cut = false };

        const mark = self.advance(glyphs.ellipsis);
        if (room <= mark) return .{ .len = 0, .cut = true };
        const left = room - mark;

        var used: usize = 0;
        var at: usize = 0;
        while (at < text.len) {
            const step = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
            const next = @min(at + step, text.len);
            const wide = self.measure(text[at..next]);
            if (used + wide > left) break;
            used += wide;
            at = next;
        }
        return .{ .len = at, .cut = true };
    }

    pub fn measure(self: *const Font, text: []const u8) usize {
        var total: usize = 0;
        var it = codepoints(text);
        while (it.next()) |cp| total += self.advance(cp);
        return total;
    }

    /// Substitute for a code point the font lacks. Better a visible marker than
    /// a blank, which reads as a bug in the program producing the text.
    pub fn fallback(self: *const Font) []const u8 {
        return self.glyph('?') orelse self.bitmap[0 .. self.height * self.row_bytes];
    }
};

/// The faces compiled in, smallest first. Generated from the BDF sources by
/// `zig build fonts`.
pub const spleen_8x16 = @import("fonts/spleen_8x16.zig").desc;
pub const spleen_12x24 = @import("fonts/spleen_12x24.zig").desc;

/// Proportional, for interface text rather than a terminal grid.
/// Ark Pixel by TakWolf, SIL Open Font License 1.1.
/// Faces packed into one file, so a program maps them rather than carrying
/// its own copy of every glyph.
///
/// Every GUI program draws with the same three faces. Linked into each one
/// they cost fifty kilobytes a binary and a copy in memory per process; read
/// from one file into one segment they cost that once. The window manager
/// owns the segment and hands it to each client, which is where the sharing
/// comes from: nothing here opens a file.
pub const pack = struct {
    /// What the file starts with, so a truncated or wrong file is refused
    /// rather than read as glyphs.
    pub const MAGIC = "eeefont1";

    /// The faces a pack holds, in this order.
    pub const Face = enum(u32) { ui, title, mono };
    pub const FACES = @typeInfo(Face).@"enum".fields.len;

    /// The head of the file, then one `Entry` per face, then the bytes each
    /// entry points into. Offsets are from the start of the file.
    pub const Head = extern struct {
        magic: [8]u8,
        faces: u32,
        bytes: u32,
    };

    pub const Entry = extern struct {
        width: u32,
        height: u32,
        row_bytes: u32,
        ascent: u32,
        bitmap_at: u32,
        bitmap_len: u32,
        /// Zero for a monospaced face, which advances by its width.
        advances_at: u32,
        advances_len: u32,
    };

    comptime {
        // Both sides read the same layout or neither does.
        if (@sizeOf(Head) != 16) @compileError("font pack head is not sixteen bytes");
        if (@sizeOf(Entry) != 32) @compileError("font pack entry is not thirty-two bytes");
    }

    pub const SIZE = @sizeOf(Head) + FACES * @sizeOf(Entry);

    /// The faces a pack holds, pointing into the bytes it was read from.
    pub const Faces = [FACES]Font;

    /// Read a pack. Null for anything that is not one: a short file, a wrong
    /// magic, a face whose glyphs run off the end. Nothing here trusts the
    /// file, because it is a file.
    pub fn read(bytes: []const u8) ?Faces {
        if (bytes.len < SIZE) return null;
        const head: *align(1) const Head = @ptrCast(bytes.ptr);
        if (!std.mem.eql(u8, &head.magic, MAGIC)) return null;
        if (head.faces != FACES or head.bytes != bytes.len) return null;

        var faces: Faces = undefined;
        for (0..FACES) |index| {
            const entry: *align(1) const Entry = @ptrCast(bytes.ptr + @sizeOf(Head) + index * @sizeOf(Entry));
            if (entry.width == 0 or entry.height == 0 or entry.row_bytes == 0) return null;
            if (entry.bitmap_len != SLOTS * entry.height * entry.row_bytes) return null;
            const bitmap = slice(bytes, entry.bitmap_at, entry.bitmap_len) orelse return null;

            var advances: ?[]const u8 = null;
            if (entry.advances_len != 0) {
                if (entry.advances_len != SLOTS) return null;
                advances = slice(bytes, entry.advances_at, entry.advances_len) orelse return null;
            }

            faces[index] = .{
                .name = "",
                .width = entry.width,
                .height = entry.height,
                .row_bytes = entry.row_bytes,
                .ascent = entry.ascent,
                .bitmap = bitmap,
                .advances = advances,
            };
        }
        return faces;
    }

    fn slice(bytes: []const u8, at: u32, len: u32) ?[]const u8 {
        const end = @as(usize, at) + len;
        if (end > bytes.len or end < at) return null;
        return bytes[at..end];
    }

    /// How large a pack of these faces comes to.
    pub fn sizeOf(faces: [FACES]*const Font) usize {
        var total: usize = SIZE;
        for (faces) |face| {
            total += face.bitmap.len;
            if (face.advances) |advances| total += advances.len;
        }
        return total;
    }

    /// Write a pack into `into`, which must be `sizeOf` bytes. Returns what
    /// was written.
    pub fn write(into: []u8, faces: [FACES]*const Font) []const u8 {
        const total = sizeOf(faces);
        std.debug.assert(into.len >= total);

        const head: *align(1) Head = @ptrCast(into.ptr);
        head.* = .{ .magic = MAGIC.*, .faces = FACES, .bytes = @intCast(total) };

        var at: u32 = SIZE;
        for (faces, 0..) |face, index| {
            const entry: *align(1) Entry = @ptrCast(into.ptr + @sizeOf(Head) + index * @sizeOf(Entry));
            const bitmap_at = at;
            @memcpy(into[at..][0..face.bitmap.len], face.bitmap);
            at += @intCast(face.bitmap.len);

            var advances_at: u32 = 0;
            var advances_len: u32 = 0;
            if (face.advances) |advances| {
                advances_at = at;
                advances_len = @intCast(advances.len);
                @memcpy(into[at..][0..advances.len], advances);
                at += advances_len;
            }

            entry.* = .{
                .width = @intCast(face.width),
                .height = @intCast(face.height),
                .row_bytes = @intCast(face.row_bytes),
                .ascent = @intCast(face.ascent),
                .bitmap_at = bitmap_at,
                .bitmap_len = @intCast(face.bitmap.len),
                .advances_at = advances_at,
                .advances_len = advances_len,
            };
        }
        return into[0..total];
    }
};

pub const ark_ui_12 = @import("fonts/ark_ui_12.zig").desc;
pub const ark_ui_16 = @import("fonts/ark_ui_16.zig").desc;
pub const ark_mono_12 = @import("fonts/ark_mono_12.zig").desc;

/// Walk a string as characters rather than bytes.
///
/// Strings here are UTF-8, and the font carries box drawing, arrows and shapes
/// well above Latin-1. Iterating bytes drew a three-byte character as three
/// wrong ones, which is what a box-drawing rule looked like before this.
///
/// Malformed input yields U+FFFD and advances one byte, so a bad string
/// renders as visible nonsense rather than desynchronising everything after
/// it.
pub const Codepoints = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn next(self: *Codepoints) ?u21 {
        if (self.pos >= self.bytes.len) return null;

        const first = self.bytes[self.pos];
        const length = std.unicode.utf8ByteSequenceLength(first) catch {
            self.pos += 1;
            return 0xFFFD;
        };

        if (self.pos + length > self.bytes.len) {
            self.pos = self.bytes.len;
            return 0xFFFD;
        }

        const cp = std.unicode.utf8Decode(self.bytes[self.pos..][0..length]) catch {
            self.pos += 1;
            return 0xFFFD;
        };
        self.pos += length;
        return cp;
    }
};

pub fn codepoints(bytes: []const u8) Codepoints {
    return .{ .bytes = bytes };
}

test "text is cut on a character, with room left for the mark that says so" {
    const face = &@import("fonts/ark_ui_12.zig").desc;

    // What fits is left alone, and says so.
    const whole = face.fit("eth0", 400);
    try std.testing.expectEqual(@as(usize, 4), whole.len);
    try std.testing.expect(!whole.cut);

    // What does not is cut short, with room kept for the mark.
    const room = face.measure("Connected, 1000");
    const cut = face.fit("Connected, 1000 Mbit/s", room);
    try std.testing.expect(cut.cut);
    try std.testing.expect(cut.len < "Connected, 1000 Mbit/s".len);
    try std.testing.expect(
        face.measure("Connected, 1000 Mbit/s"[0..cut.len]) + face.advance(glyphs.ellipsis) <= room,
    );

    // A space too small for even the mark yields nothing rather than a
    // stray glyph.
    const none = face.fit("eth0", 2);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    try std.testing.expect(none.cut);
}

test "a pack holds the faces it was written from" {
    const faces = [_]*const Font{ &ark_ui_12, &ark_ui_16, &ark_mono_12 };
    const total = pack.sizeOf(faces);

    const bytes = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(bytes);
    const written = pack.write(bytes, faces);
    try std.testing.expectEqual(total, written.len);

    const read = pack.read(written) orelse return error.NotAPack;
    for (faces, read) |wanted, got| {
        try std.testing.expectEqual(wanted.width, got.width);
        try std.testing.expectEqual(wanted.height, got.height);
        try std.testing.expectEqual(wanted.row_bytes, got.row_bytes);
        try std.testing.expectEqual(wanted.ascent, got.ascent);
        try std.testing.expectEqualSlices(u8, wanted.bitmap, got.bitmap);
        try std.testing.expectEqual(wanted.isProportional(), got.isProportional());
        if (wanted.advances) |advances| {
            try std.testing.expectEqualSlices(u8, advances, got.advances.?);
        }
        // The glyphs read back as the same pictures, which is the only thing
        // a face is for.
        for ("Ag@ 0") |code| {
            const one = wanted.glyph(code) orelse return error.NoGlyph;
            const two = got.glyph(code) orelse return error.NoGlyph;
            try std.testing.expectEqualSlices(u8, one, two);
        }
    }
}

test "anything that is not a pack is refused" {
    try std.testing.expect(pack.read("") == null);
    try std.testing.expect(pack.read("eeefont1") == null);

    const faces = [_]*const Font{ &ark_ui_12, &ark_ui_16, &ark_mono_12 };
    const bytes = try std.testing.allocator.alloc(u8, pack.sizeOf(faces));
    defer std.testing.allocator.free(bytes);
    const written = @constCast(pack.write(bytes, faces));

    // Truncated, and with the head saying something the file does not bear
    // out: both are files to refuse rather than read.
    try std.testing.expect(pack.read(written[0 .. written.len - 1]) == null);
    written[0] = 'x';
    try std.testing.expect(pack.read(written) == null);
}
