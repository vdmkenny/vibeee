//! Minimal QR encoder, for putting a machine-readable crash dump on the panic
//! screen.
//!
//! Why this exists: the Eee PC 701 has no serial port, so the only way a kernel
//! fault leaves the machine is a photograph of the screen. Transcribing a
//! register dump and a backtrace by hand is error-prone and slow; a QR code
//! turns the photo into structured data you can paste into a symboliser.
//!
//! Deliberately narrow scope, because every feature costs kernel bytes:
//!   * byte mode only
//!   * error-correction level L (we want capacity; the "damage" here is camera
//!     blur, and L still tolerates ~7%)
//!   * versions 1-5 only — these are exactly the versions with a SINGLE error
//!     correction block, so no interleaving logic is needed
//!   * one fixed mask, chosen at comptime; no penalty-score evaluation
//!
//! Version 5 is 37x37 modules and holds 106 bytes of payload, which is enough
//! for a compact crash record and fits beside readable text in 80x25.

const std = @import("std");

pub const EcLevel = enum(u2) {
    /// Bit patterns are the QR spec's, not the enum ordinal.
    l = 0b01,
    m = 0b00,
    q = 0b11,
    h = 0b10,
};

const VersionInfo = struct {
    size: u8,
    data_codewords: u8,
    ec_codewords: u8,
    /// Alignment pattern centre coordinates.
    align_pos: []const u8,
};

/// Versions 1-5 at EC level L. All single-block, which is the whole reason the
/// encoder stays this small.
const VERSIONS = [_]VersionInfo{
    .{ .size = 21, .data_codewords = 19, .ec_codewords = 7, .align_pos = &.{} },
    .{ .size = 25, .data_codewords = 34, .ec_codewords = 10, .align_pos = &.{ 6, 18 } },
    .{ .size = 29, .data_codewords = 55, .ec_codewords = 15, .align_pos = &.{ 6, 22 } },
    .{ .size = 33, .data_codewords = 80, .ec_codewords = 20, .align_pos = &.{ 6, 26 } },
    .{ .size = 37, .data_codewords = 108, .ec_codewords = 26, .align_pos = &.{ 6, 30 } },
};

pub const MAX_VERSION = 5;
pub const MAX_SIZE = 37;
pub const MAX_PAYLOAD = 106;

// ---------------------------------------------------------------------------
// GF(256) arithmetic for Reed-Solomon, tables built at comptime.
// ---------------------------------------------------------------------------

const gf = struct {
    const tables = blk: {
        @setEvalBranchQuota(10000);
        var exp: [512]u8 = undefined;
        var log: [256]u8 = undefined;
        var x: u16 = 1;
        for (0..255) |i| {
            exp[i] = @intCast(x);
            log[@as(u8, @intCast(x))] = @intCast(i);
            x <<= 1;
            if (x & 0x100 != 0) x ^= 0x11D; // QR's primitive polynomial
        }
        for (255..512) |i| exp[i] = exp[i - 255];
        break :blk .{ .exp = exp, .log = log };
    };

    fn mul(a: u8, b: u8) u8 {
        if (a == 0 or b == 0) return 0;
        return tables.exp[@as(u16, tables.log[a]) + @as(u16, tables.log[b])];
    }
};

/// Reed-Solomon generator polynomial for `n` EC codewords.
fn generatorPoly(comptime n: u8) [n + 1]u8 {
    @setEvalBranchQuota(20000);
    var poly = [_]u8{0} ** (n + 1);
    poly[0] = 1;
    var degree: usize = 0;
    for (0..n) |i| {
        degree += 1;
        var j = degree;
        while (j > 0) : (j -= 1) {
            poly[j] = poly[j - 1] ^ gf.mul(poly[j], gf.tables.exp[i]);
        }
        poly[0] = gf.mul(poly[0], gf.tables.exp[i]);
    }
    return poly;
}

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

pub const Code = struct {
    size: u8,
    /// Row-major bitmap; true = dark module.
    modules: [MAX_SIZE * MAX_SIZE]bool,

    pub fn get(self: *const Code, x: usize, y: usize) bool {
        return self.modules[y * self.size + x];
    }
};

pub const Error = error{PayloadTooLarge};

/// Encode `data` at the smallest version that fits.
pub fn encode(data: []const u8, out: *Code) Error!void {
    return encodeWithMask(data, DEFAULT_MASK, out);
}

pub fn encodeWithMask(data: []const u8, mask: u3, out: *Code) Error!void {
    inline for (VERSIONS, 1..) |v, version| {
        // Byte mode overhead: 4-bit mode indicator + 8-bit length (versions
        // 1-9 use an 8-bit count field), so 2 bytes total.
        if (data.len + 2 <= v.data_codewords) {
            return encodeAt(version, v, data, mask, out);
        }
    }
    return error.PayloadTooLarge;
}

/// Force a specific version, for tests that pin against a reference encoder.
pub fn encodeVersion(data: []const u8, version: usize, mask: u3, out: *Code) Error!void {
    inline for (VERSIONS, 1..) |v, ver| {
        if (ver == version) {
            if (data.len + 2 > v.data_codewords) return error.PayloadTooLarge;
            return encodeAt(ver, v, data, mask, out);
        }
    }
    return error.PayloadTooLarge;
}

fn encodeAt(
    comptime version: usize,
    comptime v: VersionInfo,
    data: []const u8,
    mask: u3,
    out: *Code,
) Error!void {
    _ = version;
    // --- bitstream -------------------------------------------------------
    var codewords = [_]u8{0} ** (v.data_codewords + v.ec_codewords);
    var bits: usize = 0;

    const put = struct {
        fn f(buf: []u8, pos: *usize, value: u32, count: u5) void {
            var i: i32 = @as(i32, count) - 1;
            while (i >= 0) : (i -= 1) {
                const bit: u1 = @truncate(value >> @intCast(i));
                if (bit != 0) buf[pos.* / 8] |= @as(u8, 0x80) >> @intCast(pos.* % 8);
                pos.* += 1;
            }
        }
    }.f;

    put(&codewords, &bits, 0b0100, 4); // byte mode
    put(&codewords, &bits, @intCast(data.len), 8);
    for (data) |b| put(&codewords, &bits, b, 8);

    // Terminator, then pad to a byte boundary.
    const capacity_bits = @as(usize, v.data_codewords) * 8;
    var terminator: u5 = 4;
    if (bits + 4 > capacity_bits) terminator = @intCast(capacity_bits - bits);
    put(&codewords, &bits, 0, terminator);
    while (bits % 8 != 0) put(&codewords, &bits, 0, 1);

    // Pad with the spec's alternating bytes.
    var pad_toggle = true;
    while (bits / 8 < v.data_codewords) : (pad_toggle = !pad_toggle) {
        put(&codewords, &bits, if (pad_toggle) 0xEC else 0x11, 8);
    }

    // --- Reed-Solomon ----------------------------------------------------
    const gen = comptime generatorPoly(v.ec_codewords);
    var ec = [_]u8{0} ** v.ec_codewords;
    for (codewords[0..v.data_codewords]) |byte| {
        const factor = byte ^ ec[0];
        std.mem.copyForwards(u8, ec[0 .. ec.len - 1], ec[1..]);
        ec[ec.len - 1] = 0;
        // gen is ascending with gen[n] == 1 (leading term); the division needs
        // the coefficients descending and without that leading term.
        for (0..ec.len) |i| ec[i] ^= gf.mul(gen[gen.len - 2 - i], factor);
    }
    @memcpy(codewords[v.data_codewords..], &ec);

    // --- matrix ----------------------------------------------------------
    out.size = v.size;
    @memset(&out.modules, false);

    var reserved = [_]bool{false} ** (MAX_SIZE * MAX_SIZE);
    drawFunctionPatterns(v, out, &reserved);
    placeData(v, out, &reserved, &codewords);
    applyMask(v, out, &reserved, mask);
    drawFormatInfo(v, out, mask);
}

/// Mask used for real panic screens. Any of the eight is valid — the format
/// info tells the decoder which — so we skip the spec's penalty-score search
/// and take the cheapest one. `encodeWithMask` exists so tests can sweep all
/// eight and compare against a reference encoder.
const DEFAULT_MASK: u3 = 0;

fn maskFn(mask: u3, row: usize, col: usize) bool {
    return switch (mask) {
        0 => (row + col) % 2 == 0,
        1 => row % 2 == 0,
        2 => col % 3 == 0,
        3 => (row + col) % 3 == 0,
        4 => (row / 2 + col / 3) % 2 == 0,
        5 => (row * col) % 2 + (row * col) % 3 == 0,
        6 => ((row * col) % 2 + (row * col) % 3) % 2 == 0,
        7 => ((row + col) % 2 + (row * col) % 3) % 2 == 0,
    };
}

fn set(out: *Code, x: usize, y: usize, dark: bool, reserved: []bool, is_function: bool) void {
    out.modules[y * out.size + x] = dark;
    if (is_function) reserved[y * out.size + x] = true;
}

fn drawFunctionPatterns(comptime v: VersionInfo, out: *Code, reserved: []bool) void {
    const size: usize = v.size;

    // Finder patterns plus their separators.
    for ([_][2]usize{ .{ 0, 0 }, .{ size - 7, 0 }, .{ 0, size - 7 } }) |origin| {
        var dy: i32 = -1;
        while (dy <= 7) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 7) : (dx += 1) {
                const x = @as(i32, @intCast(origin[0])) + dx;
                const y = @as(i32, @intCast(origin[1])) + dy;
                if (x < 0 or y < 0 or x >= size or y >= size) continue;
                const in_ring = (dx == 0 or dx == 6 or dy == 0 or dy == 6) and
                    (dx >= 0 and dx <= 6 and dy >= 0 and dy <= 6);
                const in_core = dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4;
                set(out, @intCast(x), @intCast(y), in_ring or in_core, reserved, true);
            }
        }
    }

    // Timing patterns.
    for (8..size - 8) |i| {
        const dark = i % 2 == 0;
        set(out, i, 6, dark, reserved, true);
        set(out, 6, i, dark, reserved, true);
    }

    // Alignment patterns, skipping those that would collide with a finder.
    for (v.align_pos) |cy| {
        for (v.align_pos) |cx| {
            const near_finder = (cx == 6 and cy == 6) or
                (cx == 6 and cy == size - 7) or
                (cx == size - 7 and cy == 6);
            if (near_finder) continue;
            var dy: i32 = -2;
            while (dy <= 2) : (dy += 1) {
                var dx: i32 = -2;
                while (dx <= 2) : (dx += 1) {
                    const dark = @abs(dx) == 2 or @abs(dy) == 2 or (dx == 0 and dy == 0);
                    set(
                        out,
                        @intCast(@as(i32, cx) + dx),
                        @intCast(@as(i32, cy) + dy),
                        dark,
                        reserved,
                        true,
                    );
                }
            }
        }
    }

    // Format information areas: reserved now, written after masking.
    for (0..9) |i| {
        if (i != 6) {
            set(out, i, 8, false, reserved, true);
            set(out, 8, i, false, reserved, true);
        }
    }
    for (0..8) |i| {
        set(out, size - 1 - i, 8, false, reserved, true);
        set(out, 8, size - 1 - i, false, reserved, true);
    }
    // The always-dark module.
    set(out, 8, size - 8, true, reserved, true);
}

fn placeData(comptime v: VersionInfo, out: *Code, reserved: []const bool, codewords: []const u8) void {
    const size: usize = v.size;
    var bit_index: usize = 0;
    const total_bits = codewords.len * 8;

    var col: i32 = @as(i32, size) - 1;
    var upward = true;
    while (col > 0) : (col -= 2) {
        if (col == 6) col -= 1; // the vertical timing pattern column is skipped

        var i: usize = 0;
        while (i < size) : (i += 1) {
            const row: usize = if (upward) size - 1 - i else i;
            for ([_]i32{ col, col - 1 }) |c| {
                const x: usize = @intCast(c);
                if (reserved[row * size + x]) continue;
                if (bit_index >= total_bits) continue;
                const byte = codewords[bit_index / 8];
                const bit = (byte >> @intCast(7 - (bit_index % 8))) & 1;
                out.modules[row * size + x] = bit != 0;
                bit_index += 1;
            }
        }
        upward = !upward;
    }
}

fn applyMask(comptime v: VersionInfo, out: *Code, reserved: []const bool, mask: u3) void {
    for (0..v.size) |y| {
        for (0..v.size) |x| {
            if (reserved[y * v.size + x]) continue;
            if (maskFn(mask, y, x)) out.modules[y * v.size + x] = !out.modules[y * v.size + x];
        }
    }
}

/// 15-bit format info: 5 data bits (EC level + mask) with a BCH(15,5) remainder,
/// XORed with the spec's constant. Computed rather than table-driven — the table
/// is 32 entries that are easy to transcribe wrongly and impossible to notice.
fn formatBits(ec: EcLevel, mask: u3) u15 {
    const data: u16 = (@as(u16, @intFromEnum(ec)) << 3) | mask;
    var rem: u16 = data;
    for (0..10) |_| {
        // Divisor 0x537 has degree 10, so the term to cancel is bit 9 of the
        // pre-shift remainder.
        rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    return @truncate(((data << 10) | (rem & 0x3FF)) ^ 0x5412);
}

fn drawFormatInfo(comptime v: VersionInfo, out: *Code, mask: u3) void {
    const size: usize = v.size;
    const bits = formatBits(.l, mask);

    // Copy 1: a vertical strip down column 8, turning the corner at row 8.
    // Note this is (column 8, row i) — writing it transposed still produces a
    // plausible-looking symbol, because the finder patterns are symmetric, but
    // no decoder will read it.
    for (0..15) |i| {
        const dark = (bits >> @intCast(i)) & 1 != 0;
        const idx: usize = if (i < 6)
            i * size + 8
        else if (i == 6)
            7 * size + 8
        else if (i == 7)
            8 * size + 8
        else if (i == 8)
            8 * size + 7
        else
            8 * size + (14 - i);
        out.modules[idx] = dark;
    }

    // Copy 2: horizontal beside the top-right finder, vertical above the
    // bottom-left one.
    for (0..15) |i| {
        const dark = (bits >> @intCast(i)) & 1 != 0;
        const idx: usize = if (i < 8)
            8 * size + (size - 1 - i)
        else
            (size - 15 + i) * size + 8;
        out.modules[idx] = dark;
    }
}
