//! Clearing, copying and shifting runs of sectors.
//!
//! Formatting and growing both move more of a volume than fits in one read,
//! and both need somewhere to put it. That buffer is here, once, and it is
//! static: a kernel thread's stack is eight to sixteen kilobytes, which is
//! less than a useful buffer, and a filesystem that allocates to move a
//! sector is one that fails when memory is short.
//!
//! **Callers hold the mount table's lock.** One buffer means one operation at
//! a time, which is what formatting and growing already require of each other
//! for other reasons: neither may run on a mounted volume.

const std = @import("std");
const block = @import("../block.zig");

pub const Error = error{Io};

/// Sectors per read or write. Larger is fewer round trips, which on a card
/// behind a reader is most of the time these take.
pub const CHUNK = 32;

const BYTES = CHUNK * block.SECTOR_SIZE;

var buffer: [BYTES]u8 = undefined;
const ZEROS: [BYTES]u8 = @splat(0);

/// Zero `count` sectors from `at`.
pub fn clear(dev: *const block.Device, at: u32, count: u32) Error!void {
    var done: u32 = 0;
    while (done < count) {
        const run = @min(CHUNK, count - done);
        dev.write(at + done, ZEROS[0 .. run * block.SECTOR_SIZE]) catch return error.Io;
        done += run;
    }
}

/// Copy `count` sectors from `from` to `to`, front to back.
///
/// For runs that do not overlap, or that overlap with the destination below
/// the source. `shiftUp` is what moves a run forward onto itself.
pub fn copy(dev: *const block.Device, from: u32, to: u32, count: u32) Error!void {
    var done: u32 = 0;
    while (done < count) {
        const run = @min(CHUNK, count - done);
        const bytes = buffer[0 .. run * block.SECTOR_SIZE];
        dev.read(from + done, bytes) catch return error.Io;
        dev.write(to + done, bytes) catch return error.Io;
        done += run;
    }
}

/// Move `count` sectors from `from` up to `from + by`, back to front.
///
/// Back to front because the destination is above the source and may still
/// hold sectors of this run that have not been read yet.
pub fn shiftUp(dev: *const block.Device, from: u32, count: u32, by: u32) Error!void {
    var left = count;
    while (left > 0) {
        const run = @min(CHUNK, left);
        const at = from + left - run;
        const bytes = buffer[0 .. run * block.SECTOR_SIZE];
        dev.read(at, bytes) catch return error.Io;
        dev.write(at + by, bytes) catch return error.Io;
        left -= run;
    }
}

const testing = std.testing;

/// A medium whose sectors each say which sector they are.
fn numbered(gpa: std.mem.Allocator, sectors: u32) ![]u8 {
    const bytes = try gpa.alloc(u8, sectors * block.SECTOR_SIZE);
    for (0..sectors) |s| {
        @memset(bytes[s * block.SECTOR_SIZE ..][0..block.SECTOR_SIZE], @truncate(s));
    }
    return bytes;
}

fn sectorSays(bytes: []const u8, sector: u32) u8 {
    return bytes[sector * block.SECTOR_SIZE];
}

test "a run shifted up onto itself arrives whole" {
    // The case the direction exists for: every distance from one sector,
    // where the destination still holds unread parts of the run, up to past
    // the end of it, where it does not.
    const gpa = testing.allocator;
    for ([_]u32{ 1, 2, 31, 32, 33, 100 }) |by| {
        const bytes = try numbered(gpa, 400);
        defer gpa.free(bytes);
        var medium = block.Memory{ .bytes = bytes };
        const dev = medium.device("memory");

        const from: u32 = 10;
        const count: u32 = 200;
        try shiftUp(&dev, from, count, by);

        for (0..count) |i| {
            const at: u32 = @intCast(from + i);
            try testing.expectEqual(@as(u8, @truncate(at)), sectorSays(bytes, at + by));
        }
    }
}

test "a run copied down arrives whole" {
    const gpa = testing.allocator;
    const bytes = try numbered(gpa, 200);
    defer gpa.free(bytes);
    var medium = block.Memory{ .bytes = bytes };
    const dev = medium.device("memory");

    try copy(&dev, 100, 5, 40);
    for (0..40) |i| {
        try testing.expectEqual(@as(u8, @truncate(100 + i)), sectorSays(bytes, @intCast(5 + i)));
    }
}

test "a cleared run is zero and its neighbours are not" {
    const gpa = testing.allocator;
    const bytes = try numbered(gpa, 200);
    defer gpa.free(bytes);
    var medium = block.Memory{ .bytes = bytes };
    const dev = medium.device("memory");

    try clear(&dev, 50, 70);
    try testing.expectEqual(@as(u8, 49), sectorSays(bytes, 49));
    for (50..120) |s| try testing.expectEqual(@as(u8, 0), sectorSays(bytes, @intCast(s)));
    try testing.expectEqual(@as(u8, 120), sectorSays(bytes, 120));
}

test "a run of no sectors touches nothing" {
    const gpa = testing.allocator;
    const bytes = try numbered(gpa, 40);
    defer gpa.free(bytes);
    const before = try gpa.dupe(u8, bytes);
    defer gpa.free(before);

    var medium = block.Memory{ .bytes = bytes };
    const dev = medium.device("memory");

    try clear(&dev, 5, 0);
    try copy(&dev, 5, 10, 0);
    try shiftUp(&dev, 5, 0, 3);
    try testing.expectEqualSlices(u8, before, bytes);
}
