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
const rgb = @import("lib").rgb;

/// A decoded picture: pixels the surface can copy from, and its shape.
///
/// The pixels are the same colours a surface holds, so drawing one is a copy
/// rather than a conversion per pixel.
pub const Picture = struct {
    pixels: []rgb.Colour,
    width: u16,
    height: u16,
    /// Whether the pixels are the decoder's to free, or a buffer the caller
    /// lent, as a picture cut from another is.
    owned: bool = true,

    /// Give it back. A picture is the largest thing most of these programs
    /// hold, so it is freed rather than left to the end of the process.
    pub fn deinit(self: Picture) void {
        if (self.pixels.len == 0 or !self.owned) return;
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
    return decodeOn(bytes, null);
}

/// The same, with whatever the picture leaves see-through laid over
/// `ground`: what a picture drawn on a page wants, where the page shows
/// through it rather than whatever colour the file keeps under the
/// see-through parts.
pub fn decodeOver(bytes: []const u8, ground: rgb.Colour) Refusal!Picture {
    return decodeOn(bytes, ground);
}

fn decodeOn(bytes: []const u8, ground: ?rgb.Colour) Refusal!Picture {
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
    const pixels = @as([*]rgb.Colour, @ptrCast(@alignCast(decoded)))[0..count];
    pack(decoded, pixels, ground);

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

/// Four bytes a pixel become one word a pixel, in the buffer they arrived in,
/// laid over `ground` by how see-through each is where a ground is given.
///
/// Forwards, because a word is written where its own four bytes were and
/// nothing later is read before it has been written. A second buffer would
/// double the largest allocation in the program for the sake of a copy.
fn pack(bytes: [*]u8, into: []rgb.Colour, ground: ?rgb.Colour) void {
    // What the decoder writes: red first, which is the order a file holds
    // and the reverse of what the panel takes, and how opaque it is last.
    const Sample = packed struct(u32) { r: u8, g: u8, b: u8, a: u8 };
    if (ground) |under| {
        for (into, 0..) |*pixel, i| {
            const sample: Sample = @bitCast(bytes[i * 4 ..][0..4].*);
            pixel.* = .{
                .r = blend(sample.r, under.r, sample.a),
                .g = blend(sample.g, under.g, sample.a),
                .b = blend(sample.b, under.b, sample.a),
            };
        }
        return;
    }
    for (into, 0..) |*pixel, i| {
        const sample: Sample = @bitCast(bytes[i * 4 ..][0..4].*);
        pixel.* = .{ .r = sample.r, .g = sample.g, .b = sample.b };
    }
}

/// One channel of a sample laid over the same channel of what is under it,
/// by how opaque the sample is, rounded to the nearest.
fn blend(top: u8, under: u8, alpha: u8) u8 {
    return @intCast((@as(u16, top) * alpha + @as(u16, under) * (255 - alpha) + 127) / 255);
}

/// A square of `side` pixels cut from the middle of a picture and shrunk to
/// fit: the shape a headshot takes. The square lives in `into`, which the
/// caller lends and keeps.
pub fn squareOf(picture: Picture, side: u16, into: []rgb.Colour) Picture {
    const cut: usize = @min(picture.width, picture.height);
    return meanOf(picture, .{
        .x = (picture.width - cut) / 2,
        .y = (picture.height - cut) / 2,
        .w = cut,
        .h = cut,
    }, side, side, into);
}

/// A picture at `width` by `height`: the size a page shows it at, or the
/// widest a column is ever drawn. The pixels live in `into`, which the caller
/// lends and keeps.
pub fn shrunk(picture: Picture, width: u16, height: u16, into: []rgb.Colour) Picture {
    return meanOf(picture, .{ .x = 0, .y = 0, .w = picture.width, .h = picture.height }, width, height, into);
}

/// Part of a picture, in its own pixels.
const Region = struct { x: usize, y: usize, w: usize, h: usize };

/// `region` of `picture` at `width` by `height`. Each pixel is the mean of the
/// block of the original it stands for, so a photograph shrunk eight times is
/// smooth rather than a scatter of single pixels; where the original has
/// fewer pixels than are asked for, a block is the one pixel under it.
fn meanOf(picture: Picture, region: Region, width: u16, height: u16, into: []rgb.Colour) Picture {
    const count = @as(usize, width) * height;
    std.debug.assert(into.len >= count);
    if (count == 0) return .{ .pixels = into[0..0], .width = 0, .height = 0, .owned = false };

    var down = Shares.of(region.h, height);
    var top: usize = 0;
    for (0..height) |y| {
        const bottom = down.next();
        var across = Shares.of(region.w, width);
        var left: usize = 0;
        for (0..width) |x| {
            const right = across.next();
            into[y * width + x] = mean(picture, .{
                .x = region.x + left,
                .y = region.y + top,
                .w = @max(right - left, 1),
                .h = @max(bottom - top, 1),
            });
            left = right;
        }
        top = bottom;
    }
    return .{ .pixels = into[0..count], .width = width, .height = height, .owned = false };
}

/// The mean colour of a block of a picture.
fn mean(picture: Picture, block: Region) rgb.Colour {
    var r: u32 = 0;
    var g: u32 = 0;
    var b: u32 = 0;
    for (block.y..block.y + block.h) |row| {
        for (picture.pixels[row * picture.width + block.x ..][0..block.w]) |pixel| {
            r += pixel.r;
            g += pixel.g;
            b += pixel.b;
        }
    }
    const n: u32 = @intCast(block.w * block.h);
    return .{ .r = @intCast(r / n), .g = @intCast(g / n), .b = @intCast(b / n) };
}

/// Where each of `parts` equal shares of `whole` ends, one after another, in
/// whole numbers. Walked by carrying what is left over rather than by
/// dividing at every step, which on this processor is the dearer of the two.
const Shares = struct {
    each: usize,
    over: usize,
    parts: usize,
    end: usize = 0,
    carried: usize = 0,

    fn of(whole: usize, parts: usize) Shares {
        return .{ .each = whole / parts, .over = whole % parts, .parts = parts };
    }

    fn next(self: *Shares) usize {
        self.end += self.each;
        self.carried += self.over;
        if (self.carried >= self.parts) {
            self.carried -= self.parts;
            self.end += 1;
        }
        return self.end;
    }
};

/// A picture as a JPEG file, for keeping small. `quality` runs from one to
/// a hundred. `scratch` holds three bytes a pixel in the writer's own order,
/// and `into` takes the file; a file that does not fit is refused whole
/// rather than cut short.
pub fn encodeJpeg(picture: Picture, quality: u8, scratch: []u8, into: []u8) Refusal![]const u8 {
    const count = @as(usize, picture.width) * picture.height;
    if (scratch.len < count * 3) return error.TooLarge;
    for (picture.pixels[0..count], 0..) |pixel, i| {
        scratch[i * 3] = pixel.r;
        scratch[i * 3 + 1] = pixel.g;
        scratch[i * 3 + 2] = pixel.b;
    }
    var sink = Sink{ .into = into };
    const clamped: c_int = @min(@max(quality, 1), 100);
    if (stbi_write_jpg_to_func(Sink.take, &sink, picture.width, picture.height, 3, scratch.ptr, clamped) == 0) return error.Unreadable;
    if (sink.overflowed) return error.TooLarge;
    return into[0..sink.len];
}

/// A picture as a PNG file, for keeping exactly. `scratch` holds three bytes
/// a pixel in the writer's own order, and `into` takes the file; a file that
/// does not fit is refused whole rather than cut short.
///
/// Lossless, which is what a picture of a screen wants: JPEG turns text into
/// a smear at every edge, and text is most of what a screen holds.
pub fn encodePng(picture: Picture, scratch: []u8, into: []u8) Refusal![]const u8 {
    const count = @as(usize, picture.width) * picture.height;
    if (scratch.len < count * 3) return error.TooLarge;
    for (picture.pixels[0..count], 0..) |pixel, i| {
        scratch[i * 3] = pixel.r;
        scratch[i * 3 + 1] = pixel.g;
        scratch[i * 3 + 2] = pixel.b;
    }
    var sink = Sink{ .into = into };
    const stride: c_int = @as(c_int, picture.width) * 3;
    if (stbi_write_png_to_func(Sink.take, &sink, picture.width, picture.height, 3, scratch.ptr, stride) == 0) return error.Unreadable;
    if (sink.overflowed) return error.TooLarge;
    return into[0..sink.len];
}

/// Where the writer puts its bytes: a buffer, and the truth about whether
/// they all fitted.
const Sink = struct {
    into: []u8,
    len: usize = 0,
    overflowed: bool = false,

    fn take(context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
        const self: *Sink = @ptrCast(@alignCast(context.?));
        const bytes = @as([*]const u8, @ptrCast(data.?))[0..@intCast(size)];
        if (self.len + bytes.len > self.into.len) {
            self.overflowed = true;
            return;
        }
        @memcpy(self.into[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

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

extern fn stbi_write_png_to_func(
    func: *const fn (?*anyopaque, ?*anyopaque, c_int) callconv(.c) void,
    context: ?*anyopaque,
    w: c_int,
    h: c_int,
    comp: c_int,
    data: [*]const u8,
    stride_bytes: c_int,
) c_int;

extern fn stbi_write_jpg_to_func(
    func: *const fn (?*anyopaque, ?*anyopaque, c_int) callconv(.c) void,
    context: ?*anyopaque,
    w: c_int,
    h: c_int,
    comp: c_int,
    data: [*]const u8,
    quality: c_int,
) c_int;

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

test "a square is cut from the middle and shrunk by the mean" {
    // Four by two: red red blue blue on the top row, green green white white
    // below. The middle square is two by two, and shrunk to one pixel it is
    // the mean of red, blue, green and white.
    var pixels = [_]rgb.Colour{
        .hex(0xFF0000), .hex(0xFF0000), .hex(0x0000FF), .hex(0x0000FF),
        .hex(0x00FF00), .hex(0x00FF00), .hex(0xFFFFFF), .hex(0xFFFFFF),
    };
    const wide = Picture{ .pixels = &pixels, .width = 4, .height = 2, .owned = false };
    var two: [4]rgb.Colour = undefined;
    const square = squareOf(wide, 2, &two);
    try testing.expectEqual(@as(u16, 2), square.width);
    try testing.expectEqualSlices(
        rgb.Colour,
        &.{ .hex(0xFF0000), .hex(0x0000FF), .hex(0x00FF00), .hex(0xFFFFFF) },
        square.pixels,
    );
    var one: [1]rgb.Colour = undefined;
    try testing.expectEqual(rgb.Colour.hex(0x7F7F7F), squareOf(wide, 1, &one).pixels[0]);
}

test "shares of a whole end where dividing would put them" {
    var shares = Shares.of(10, 4);
    for ([_]usize{ 2, 5, 7, 10 }) |end| try testing.expectEqual(end, shares.next());
}

test "a picture shrunk is the mean of each block it stands for" {
    // Four by two: a block of red and green on the left, and of blue and
    // white on the right.
    var pixels = [_]rgb.Colour{
        .hex(0xFF0000), .hex(0x00FF00), .hex(0x0000FF), .hex(0xFFFFFF),
        .hex(0xFF0000), .hex(0x00FF00), .hex(0x0000FF), .hex(0xFFFFFF),
    };
    const wide = Picture{ .pixels = &pixels, .width = 4, .height = 2, .owned = false };
    var two: [2]rgb.Colour = undefined;
    const small = shrunk(wide, 2, 1, &two);
    try testing.expectEqual(@as(u16, 2), small.width);
    try testing.expectEqual(@as(u16, 1), small.height);
    try testing.expectEqual(rgb.Colour.hex(0x7F7F00), small.pixels[0]);
    try testing.expectEqual(rgb.Colour.hex(0x7F7FFF), small.pixels[1]);

    // Asked for more than there is, each pixel is the one under it.
    var eight: [8 * 2]rgb.Colour = undefined;
    const grown = shrunk(wide, 8, 2, &eight);
    try testing.expectEqual(rgb.Colour.hex(0xFF0000), grown.pixels[0]);
    try testing.expectEqual(rgb.Colour.hex(0xFF0000), grown.pixels[1]);
    try testing.expectEqual(rgb.Colour.hex(0xFFFFFF), grown.pixels[7]);
}

test "a picture written as JPEG reads back as the picture" {
    var pixels: [16 * 16]rgb.Colour = @splat(.hex(0x2F6FE0));
    const flat = Picture{ .pixels = &pixels, .width = 16, .height = 16, .owned = false };
    var scratch: [16 * 16 * 3]u8 = undefined;
    var file: [4096]u8 = undefined;
    const jpeg = try encodeJpeg(flat, 85, &scratch, &file);
    try testing.expect(jpeg.len > 0);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD8 }, jpeg[0..2]);

    const back = try decode(jpeg);
    defer back.deinit();
    try testing.expectEqual(@as(u16, 16), back.width);
    const pixel = back.pixels[5 * 16 + 5];
    try testing.expect(@abs(@as(i32, pixel.r) - 0x2F) < 12);
    try testing.expect(@abs(@as(i32, pixel.g) - 0x6F) < 12);
    try testing.expect(@abs(@as(i32, pixel.b) - 0xE0) < 12);

    // A file that does not fit is refused whole.
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.TooLarge, encodeJpeg(flat, 85, &scratch, &tiny));
}

test "the pixels come back as the surface holds them" {
    const picture = try decode(&two_by_two);
    defer picture.deinit();

    try testing.expectEqual(@as(u16, 2), picture.width);
    try testing.expectEqual(@as(u16, 2), picture.height);
    try testing.expectEqual(@as(usize, 4), picture.pixels.len);

    // Red, green, blue, white: packed with red highest, which is what a
    // surface draws.
    try testing.expectEqual(rgb.Colour.hex(0xFF0000), picture.pixels[0]);
    try testing.expectEqual(rgb.Colour.hex(0x00FF00), picture.pixels[1]);
    try testing.expectEqual(rgb.Colour.hex(0x0000FF), picture.pixels[2]);
    try testing.expectEqual(rgb.Colour.hex(0xFFFFFF), picture.pixels[3]);
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
    var pixels: [2]rgb.Colour = undefined;
    pack(&bytes, &pixels, null);

    try testing.expectEqual(rgb.Colour.hex(0x123456), pixels[0]);
    try testing.expectEqual(rgb.Colour.hex(0x789ABC), pixels[1]);
}

test "a see-through picture is laid over the ground it is drawn on" {
    var bytes = [_]u8{
        0xFF, 0x00, 0x00, 0xFF, // opaque red
        0xFF, 0xFF, 0xFF, 0x00, // white nobody sees
        0x00, 0x00, 0xFF, 0x80, // blue half seen
    };
    var pixels: [3]rgb.Colour = undefined;
    pack(&bytes, &pixels, .hex(0x204060));

    try testing.expectEqual(rgb.Colour.hex(0xFF0000), pixels[0]);
    try testing.expectEqual(rgb.Colour.hex(0x204060), pixels[1]);
    try testing.expectEqual(rgb.Colour.hex(0x1020B0), pixels[2]);
}
