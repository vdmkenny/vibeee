//! The pointer plane of Intel gen3: GMA 900/950/3150.
//!
//! The display engine carries a small picture over the scanout as it reads the
//! screen out, blended by the hardware and placed by one register. What that
//! is worth here is what it saves: a pointer drawn in the framebuffer has to
//! be lifted before anything under it is redrawn, and lifting it means reading
//! back the pixels it covered. The framebuffer is write-combining memory,
//! quick to write and slow to read, and the pointer is the only thing in this
//! system that ever reads it.
//!
//! Three registers a pipe: what the plane is, where its picture is, and where
//! its point sits. Writing where the picture is arms all three, the plane's
//! registers being double buffered and taken at the next scan. The offsets and
//! the mode bits are `design/04-graphics.md` §8.4.
//!
//! **The picture goes in the memory firmware set aside for the graphics
//! device.** This generation's plane reads the address itself: not through the
//! translation table, and without looking in the processor's caches. So the
//! pixels have to be at a physical address the engine can reach and written
//! somewhere the processor will not hold on to. The page after the scanout
//! buffer is where they go, mapped uncached, and only where the memory map
//! says that page is not the allocator's to hand out.
//!
//! Optional, like everything else about this adapter. A machine where the
//! plane cannot be bound keeps a pointer drawn in software, which is what a
//! machine without a plane does anyway.

const std = @import("std");
const rgb = @import("lib").rgb;
const display = @import("../../../kernel/display.zig");
const hal = @import("../../../kernel/hal.zig");
const pmm = @import("../../../kernel/pmm.zig");
const probe = @import("../../../kernel/probe.zig");
const gen3 = @import("gen3.zig");
const modeset = @import("modeset.zig");

const Place = display.Pointer.Place;
const Where = display.Pointer.Where;

/// How many pixels the plane is each way. The hardware reads a fixed square
/// whatever picture is put in it, so a smaller one goes in the corner and the
/// rest is left clear.
pub const SIDE: u16 = 64;

/// How many pixels that is, and what they come to, which is four pages.
const PIXELS: usize = @as(usize, SIDE) * SIDE;
const BYTES: usize = PIXELS * @sizeOf(rgb.Blended);

/// The two cursor blocks, one to a pipe: three registers each, at the
/// offsets `Register` names.
const block_a: u32 = 0x70080;
const block_b: u32 = 0x700C0;

/// What the plane is, as its control register holds it.
const Control = packed struct(u32) {
    shape: Shape = .off,
    _0: u20 = 0,
    /// The picture goes through the pipe's gamma table where this is set.
    /// Left off: the picture is written in the colours it is to be drawn in.
    gamma: bool = false,
    _1: u1 = 0,
    /// Which pipe the plane rides.
    pipe_b: bool = false,
    _2: u3 = 0,

    /// How big the picture is and how it is read. Off is a shape too: the
    /// picture stays where it is and only the plane stops.
    const Shape = enum(u6) {
        off = 0x00,
        /// Sixty-four pixels each way, with an alpha channel the engine
        /// blends with.
        argb_64 = 0x27,
    };
};

/// Where the picture's corner sits, as its position register holds it.
///
/// A magnitude and a sign each way rather than a signed number, which is what
/// lets a pointer whose point is near the left or the top edge have its
/// picture hang off it.
const Position = packed struct(u32) {
    x: Edge,
    y: Edge,

    const Edge = packed struct(u16) {
        magnitude: u11 = 0,
        _: u4 = 0,
        backwards: bool = false,

        fn of(value: i32) Edge {
            return .{ .magnitude = @truncate(@abs(value)), .backwards = value < 0 };
        }
    };

    fn of(at: Place) Position {
        return .{ .x = .of(at.x), .y = .of(at.y) };
    }
};

/// The three registers of a cursor block, by how far into it they are.
const Register = enum(u32) {
    control = 0,
    /// Where the picture is. Written last of the three: it arms them
    /// together.
    picture = 4,
    position = 8,
};

/// The plane as this file holds it, once bound.
const Plane = struct {
    /// Where the adapter's registers are mapped, and which block of three is
    /// the panel's pipe's.
    mmio: usize,
    block: u32,
    pipe_b: bool,
    /// Where the picture is, as the engine reads it: a physical address,
    /// this generation's plane not going through the translation table.
    phys: usize,
    pixels: []rgb.Blended,
    /// Where the point sits within the picture, which the hardware knows
    /// nothing about: it places the picture's corner, so the point is taken
    /// off before the corner is written.
    hot: Place = .{ .x = 0, .y = 0 },
    /// Whether a picture has been put in it. Shown before that, the plane
    /// would draw whatever the memory held.
    given: bool = false,

    fn write(self: Plane, register: Register, value: anytype) void {
        const at: *volatile u32 = @ptrFromInt(self.mmio + self.block + @intFromEnum(register));
        at.* = @bitCast(value);
    }
};

var plane: ?Plane = null;

const interface = modeset.Pointer{ .side = SIDE, .image = &image, .move = &move };

/// Bind the plane, told where the scanout buffer is so the picture can go
/// after it. Null where it cannot be bound, which leaves the pointer to be
/// drawn in software.
pub fn bind(dev: probe.Device, fb: modeset.Framebuffer) ?modeset.Pointer {
    if (comptime !hal.available) return null;
    if (plane != null) return interface;

    const found = gen3.reach(dev) orelse return null;
    const at = pictureAfter(fb.phys, fb.pitch, fb.height) orelse return null;

    // Uncached: the engine reads this memory without looking in the
    // processor's caches, so a line still held in one is a picture the
    // hardware never sees. Sixteen kilobytes of uncached writes is what a
    // picture costs, paid when one is given and not when the pointer moves.
    const virt = hal.mapMmio(at, BYTES, .uncached) catch return null;

    plane = .{
        .mmio = found.mmio,
        .block = if (found.pipe_b) block_b else block_a,
        .pipe_b = found.pipe_b,
        .phys = at,
        .pixels = @as([*]rgb.Blended, @ptrFromInt(virt))[0..PIXELS],
    };
    // Cleared before the plane is ever pointed at it: firmware left whatever
    // it left there, and the engine is not to be handed that even for the
    // moment between binding and the first picture.
    @memset(plane.?.pixels, .clear);
    move(.off);
    return interface;
}

/// Where the picture goes: the first whole page after the scanout buffer, and
/// only where the memory map says that page is not the allocator's.
///
/// Firmware sets aside more than one buffer's worth of memory for the
/// graphics device, and what it set aside is what this may use. A machine
/// where it did not, or where the scanout sits in ordinary memory, answers
/// nothing and keeps its pointer in software rather than handing the engine a
/// page something else is about to be given.
fn pictureAfter(phys: usize, pitch: u32, height: u16) ?usize {
    // In sixty-four bits throughout: a pitch and a height the adapter
    // reported wrongly would otherwise carry these sums past the end of
    // addressing and name somewhere else entirely.
    const scanout = @as(u64, pitch) * height;
    const after = @as(u64, phys) + scanout;
    const at = std.mem.alignForward(u64, after, pmm.PAGE_SIZE);
    const end = at + BYTES;
    if (end > std.math.maxInt(usize)) return null;

    const start: usize = @intCast(at);
    if (pmm.isManaged(start, @intCast(end))) return null;
    return start;
}

fn image(picture: []const rgb.Blended, wide: u16, hot: Place) display.Pointer.Refused!void {
    const p = if (plane) |*have| have else return error.Refused;
    lay(p.pixels, SIDE, picture, wide) catch return error.Refused;
    p.hot = hot;
    p.given = true;
}

fn move(where: Where) void {
    const p = plane orelse return;
    const corner: Place = switch (where) {
        .at => |spot| .{ .x = spot.x - p.hot.x, .y = spot.y - p.hot.y },
        .off => .{ .x = 0, .y = 0 },
    };
    const on = where == .at and p.given;

    p.write(.position, Position.of(corner));
    p.write(.control, Control{
        .shape = if (on) .argb_64 else .off,
        .pipe_b = p.pipe_b,
    });
    // Truncated because a physical address is a machine word on the machine
    // this drives, and the register is thirty-two bits wide whatever host the
    // arithmetic below is checked on.
    p.write(.picture, @as(u32, @truncate(p.phys)));
}

// ---------------------------------------------------------------------------
// The arithmetic, which is pure and checked on this machine
// ---------------------------------------------------------------------------

/// Why a picture was not taken.
pub const Refusal = error{
    /// The square handed in is not the shape the plane reads.
    NotTheSquare,
    /// Not a whole number of rows of `wide`, so where one ends is a guess.
    Ragged,
    /// Wider or taller than the square.
    TooBig,
};

/// Lay `argb` into `square`, `wide` pixels across, leaving the rest clear.
///
/// Refused rather than cut down: better a pointer drawn in software than one
/// drawn from whatever followed the picture in memory.
pub fn lay(square: []rgb.Blended, side: u16, picture: []const rgb.Blended, wide: u16) Refusal!void {
    if (square.len != @as(usize, side) * side) return error.NotTheSquare;
    if (wide == 0 or picture.len == 0) return error.Ragged;
    if (wide > side) return error.TooBig;
    const tall = picture.len / wide;
    if (tall * wide != picture.len) return error.Ragged;
    if (tall > side) return error.TooBig;

    @memset(square, .clear);
    for (0..tall) |row| {
        @memcpy(square[row * side ..][0..wide], picture[row * wide ..][0..wide]);
    }
}

const testing = std.testing;

test "the registers are the shape the hardware reads" {
    try testing.expectEqual(@as(u32, 0x27), @as(u32, @bitCast(Control{ .shape = .argb_64 })));
    try testing.expectEqual(@as(u32, 1 << 28), @as(u32, @bitCast(Control{ .pipe_b = true })));
    try testing.expectEqual(@as(u32, 1 << 26), @as(u32, @bitCast(Control{ .gamma = true })));
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(Control{})));
}

test "a picture smaller than the square goes in its corner" {
    // Told apart by their alpha, which is what says a pixel is there at all.
    const there = [_]rgb.Blended{
        .{ .a = 1 }, .{ .a = 2 },
        .{ .a = 3 }, .{ .a = 4 },
        .{ .a = 5 }, .{ .a = 6 },
    };
    var square: [4 * 4]rgb.Blended = @splat(.solid(.hex(0xFFFFFF)));
    try lay(&square, 4, &there, 2);

    const gone = rgb.Blended.clear;
    try testing.expectEqualSlices(rgb.Blended, &.{
        there[0], there[1], gone, gone,
        there[2], there[3], gone, gone,
        there[4], there[5], gone, gone,
        gone,     gone,     gone, gone,
    }, &square);
}

test "a picture that does not fit the square is refused rather than cut" {
    var square: [4 * 4]rgb.Blended = @splat(.clear);
    const five: [5]rgb.Blended = @splat(.{ .a = 1 });
    try testing.expectError(error.TooBig, lay(&square, 4, &five, 5));
    try testing.expectError(error.TooBig, lay(&square, 4, &five, 1));
    try testing.expectError(error.Ragged, lay(&square, 4, &five, 2));
    try testing.expectError(error.Ragged, lay(&square, 4, &.{}, 1));
    try testing.expectError(error.NotTheSquare, lay(square[0..8], 4, five[0..1], 1));
}

test "a point near an edge puts the picture's corner off it" {
    const word = struct {
        fn of(x: i32, y: i32) u32 {
            return @bitCast(Position.of(.{ .x = x, .y = y }));
        }
    }.of;

    try testing.expectEqual(@as(u32, 0), word(0, 0));
    try testing.expectEqual(@as(u32, 100 | (200 << 16)), word(100, 200));
    // Backwards is a sign bit and a magnitude, not a negative number.
    try testing.expectEqual(@as(u32, 0x8000 | 3), word(-3, 0));
    try testing.expectEqual(@as(u32, (0x8000 | 7) << 16), word(0, -7));
    // Past what the register reaches, the magnitude wraps rather than
    // spilling into the other axis.
    try testing.expectEqual(@as(u32, 0), word(0x800, 0));
}
