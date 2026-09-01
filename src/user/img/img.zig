//! Pictures, decoded into the shape a surface draws.
//!
//! A wrapper over the vendored decoder rather than a decoder: PNG and JPEG
//! are formats with decades of edge cases in them, and the one thing worth
//! having written here is the part that decides what this system will accept.
//!
//! Two things happen on this side of it. Bytes come back as the surface's own
//! pixels, packed in place so a picture is never held twice; and a size is
//! refused before anything is allocated for it, because a header claiming
//! forty thousand pixels a side is a header that would otherwise ask for the
//! whole machine.
//!
//! Which formats exist is the build's decision. Anything the binary was not
//! compiled for reads as a picture this system does not know, which is what a
//! program should say about it anyway.

const std = @import("std");
const limits = @import("lib").limits;

/// A decoded picture: pixels the surface can copy from, and its shape.
///
/// The pixels are the same words a surface holds, so drawing one is a copy
/// rather than a conversion per pixel.
pub const Picture = struct {
    pixels: []u32,
    width: u16,
    height: u16,

    /// Give it back. A picture is the largest thing most of these programs
    /// hold, so it is freed rather than left to the end of the process.
    pub fn deinit(self: Picture) void {
        if (self.pixels.len == 0) return;
        stbi_image_free(@ptrCast(self.pixels.ptr));
    }
};

pub const Refusal = error{
    /// Not a format this binary knows, or damaged.
    Unreadable,
    /// Larger than this system will hold.
    TooLarge,
    /// The machine could not find room for it.
    NoRoom,
};

/// What a header says it is, before anything is allocated for it.
pub const Shape = struct { width: u16, height: u16, channels: u8 };

pub fn shapeOf(bytes: []const u8) Refusal!Shape {
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;

    if (stbi_info_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &channels) == 0) {
        return error.Unreadable;
    }
    if (!fits(w, h)) return error.TooLarge;

    return .{
        .width = @intCast(w),
        .height = @intCast(h),
        .channels = @intCast(@max(0, @min(channels, 4))),
    };
}

/// Decode `bytes` into pixels a surface can draw.
///
/// The caller owns what comes back and gives it back with `deinit`.
pub fn decode(bytes: []const u8) Refusal!Picture {
    // Asked about before it is decoded, so a picture too large to hold is
    // refused for the space it would have taken rather than after taking it.
    const shape = try shapeOf(bytes);

    var w: c_int = 0;
    var h: c_int = 0;
    var had: c_int = 0;

    const decoded = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &had, 4) orelse
        return refusalFor();

    if (w != shape.width or h != shape.height) {
        stbi_image_free(@ptrCast(decoded));
        return error.Unreadable;
    }

    const count = @as(usize, shape.width) * @as(usize, shape.height);
    const pixels = @as([*]u32, @ptrCast(@alignCast(decoded)))[0..count];
    pack(decoded, pixels);

    return .{ .pixels = pixels, .width = shape.width, .height = shape.height };
}

/// Why the decoder gave nothing back.
///
/// It answers null for a damaged picture and for a machine with no room, and
/// the difference matters to whoever has to be told: one is worth saying
/// about the file and the other about the machine. The decoder's own word for
/// it is the only thing that tells them apart.
fn refusalFor() Refusal {
    const said = why();
    return if (std.mem.startsWith(u8, said, "outofmem")) error.NoRoom else error.Unreadable;
}

/// Four bytes a pixel become one word a pixel, in the buffer they arrived in.
///
/// Forwards, because a word is written where its own four bytes were and
/// nothing later is read before it has been written. A second buffer would
/// double the largest allocation in the program for the sake of a copy.
fn pack(bytes: [*]u8, into: []u32) void {
    for (into, 0..) |*pixel, i| {
        const at = i * 4;
        pixel.* = (@as(u32, bytes[at]) << 16) |
            (@as(u32, bytes[at + 1]) << 8) |
            @as(u32, bytes[at + 2]);
    }
}

/// Whether a picture of this size is one this system will hold.
///
/// The limit is a budget rather than a law: what it protects is a machine
/// with half a gigabyte from a file that says it is forty thousand pixels
/// wide. A real picture that hits it is a reason to ask whether it can be
/// decoded in strips, and only then to double the number.
fn fits(w: c_int, h: c_int) bool {
    if (w <= 0 or h <= 0) return false;
    if (w > limits.IMAGE_SIDE_MAX or h > limits.IMAGE_SIDE_MAX) return false;
    return @as(u64, @intCast(w)) * @as(u64, @intCast(h)) <= limits.IMAGE_PIXELS_MAX;
}

// ---------------------------------------------------------------------------
// The vendored decoder
//
// Named here rather than translated: four calls, and a translation of an eight
// thousand line header would be eight thousand lines of declarations to look
// through for them.
// ---------------------------------------------------------------------------

extern fn stbi_load_from_memory(
    bytes: [*]const u8,
    len: c_int,
    w: *c_int,
    h: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;

extern fn stbi_info_from_memory(
    bytes: [*]const u8,
    len: c_int,
    w: *c_int,
    h: *c_int,
    channels_in_file: *c_int,
) c_int;

extern fn stbi_image_free(what: ?*anyopaque) void;

/// Why the last call failed, in the decoder's own words. For a program that
/// has something to say to somebody: "not a picture" is worth more than a
/// window that stays empty.
pub fn why() []const u8 {
    const said = stbi_failure_reason() orelse return "";
    return std.mem.span(said);
}

extern fn stbi_failure_reason() ?[*:0]const u8;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A two-by-two PNG: red, green, blue, white. Written out here rather than
/// read from a file, so the test needs nothing around it.
const two_by_two = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0xD4, 0x9A, 0x73, 0x00, 0x00, 0x00,
    0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xC0,
    0x00, 0xC2, 0x0C, 0xFF, 0x81, 0x00, 0x00, 0x1F, 0xEE, 0x05, 0xFB, 0xF1,
    0xAB, 0xBA, 0x77, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
};

test "a picture says its shape before anything is allocated for it" {
    const shape = try shapeOf(&two_by_two);
    try testing.expectEqual(@as(u16, 2), shape.width);
    try testing.expectEqual(@as(u16, 2), shape.height);
    try testing.expectEqual(@as(u8, 3), shape.channels);
}

test "the pixels come back as the surface holds them" {
    const picture = try decode(&two_by_two);
    defer picture.deinit();

    try testing.expectEqual(@as(u16, 2), picture.width);
    try testing.expectEqual(@as(u16, 2), picture.height);
    try testing.expectEqual(@as(usize, 4), picture.pixels.len);

    // Red, green, blue, white: packed with red highest, which is what a
    // surface draws.
    try testing.expectEqual(@as(u32, 0xFF0000), picture.pixels[0]);
    try testing.expectEqual(@as(u32, 0x00FF00), picture.pixels[1]);
    try testing.expectEqual(@as(u32, 0x0000FF), picture.pixels[2]);
    try testing.expectEqual(@as(u32, 0xFFFFFF), picture.pixels[3]);
}

test "what is not a picture is refused, and says why" {
    try testing.expectError(error.Unreadable, shapeOf("not a picture at all"));
    try testing.expectError(error.Unreadable, decode(&.{}));

    // And says something about it, which is what a program shows somebody
    // instead of an empty window.
    try testing.expect(why().len > 0);

    // A truncated one is refused as well rather than decoded to whatever
    // survived the cut.
    try testing.expectError(error.Unreadable, decode(two_by_two[0 .. two_by_two.len - 12]));
}

test "packing is done in the buffer the bytes arrived in" {
    var bytes = [_]u8{
        0x12, 0x34, 0x56, 0xFF,
        0x78, 0x9A, 0xBC, 0xFF,
    };
    var pixels: [2]u32 = undefined;
    pack(&bytes, &pixels);

    try testing.expectEqual(@as(u32, 0x123456), pixels[0]);
    try testing.expectEqual(@as(u32, 0x789ABC), pixels[1]);
}
