//! The build's side of the blocklist: fetch the list, read the names on it,
//! and write them as the reader keeps them.
//!
//! Fetched at every build, so a reader carries the list as it was when it was
//! built. The last list fetched is kept beside the build, and a build that
//! cannot reach the list uses that one; a build that has never reached it
//! makes a reader whose list is empty, and says so.
//!
//! Usage: gen-blocklist <address> <kept copy> <out.zig>

const std = @import("std");
const blocklist = @import("blocklist.zig");

/// The most the list may be. It is under a megabyte; four leave it room to
/// grow without taking whatever a server sends.
const LIST_MAX = 4 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) {
        std.debug.print("usage: gen-blocklist <address> <kept copy> <out.zig>\n", .{});
        std.process.exit(2);
    }
    const address = args[1];
    const kept_path = args[2];
    const out_path = args[3];
    const cwd = std.Io.Dir.cwd();

    if (fetched(gpa, io, address)) |list| {
        defer gpa.free(list);
        if (std.fs.path.dirname(kept_path)) |dir| try cwd.createDirPath(io, dir);
        try cwd.writeFile(io, .{ .sub_path = kept_path, .data = list });
    } else |err| {
        std.debug.print("warning: the blocklist could not be fetched from {s} ({t}), so the last one fetched is used\n", .{ address, err });
    }

    const list = cwd.readFileAlloc(io, kept_path, gpa, .limited(LIST_MAX)) catch |err| none: {
        std.debug.print("warning: no blocklist has been fetched ({t}), so the reader is built with an empty one\n", .{err});
        break :none try gpa.alloc(u8, 0);
    };
    defer gpa.free(list);

    var hashes: std.ArrayList(u32) = .empty;
    defer hashes.deinit(gpa);
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |line| {
        const name = blocklist.nameOf(line) orelse continue;
        var buf: [255]u8 = undefined;
        try hashes.append(gpa, blocklist.hashOf(std.ascii.lowerString(&buf, name)));
    }

    // In order and each once, which is what the reader halves its way
    // through.
    std.mem.sort(u32, hashes.items, {}, std.sort.asc(u32));
    var kept: usize = 0;
    for (hashes.items) |hash| {
        if (kept > 0 and hashes.items[kept - 1] == hash) continue;
        hashes.items[kept] = hash;
        kept += 1;
    }
    hashes.shrinkRetainingCapacity(kept);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.print(
        \\//! The blocklist the reader is built with: {d} names from
        \\//! {s},
        \\//! each kept as its hash. Written by `gen_blocklist.zig` at every build.
        \\
        \\pub const hashes = [_]u32{{
        \\
    , .{ hashes.items.len, address });
    for (hashes.items) |hash| try w.print("    0x{x:0>8},\n", .{hash});
    try w.writeAll("};\n");
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = out.written() });
}

/// The list at `address`, fetched whole.
fn fetched(gpa: std.mem.Allocator, io: std.Io, address: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const result = try client.fetch(.{ .location = .{ .url = address }, .response_writer = &body.writer });
    if (result.status != .ok) return error.Unanswered;
    if (body.written().len > LIST_MAX) return error.TooLarge;
    return gpa.dupe(u8, body.written());
}
