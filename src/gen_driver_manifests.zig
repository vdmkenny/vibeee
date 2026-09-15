//! Generates drivers/*.man from what each driver says it answers for.
//!
//! The boot probe and the device manager act on the same fact: which devices
//! a driver is for. Written twice they drift, and a listing then says nobody
//! drives what something is driving, or the reverse. So it is written once,
//! in `lib/driver.zig`, and this puts that into the files the device manager
//! reads.
//!
//! Generated and committed, the way the syscall reference is: a change to
//! what a driver serves shows up as a diff somebody can read.

const std = @import("std");
const driver = @import("lib/driver.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const dir_path = if (args.len > 1) args[1] else "drivers";
    const gpa = init.gpa;

    var written: usize = 0;
    for (driver.answers) |one| {
        const service = one.service orelse continue;

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        try manifest(gpa, &text, one, service);

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.man", .{ dir_path, one.name });
        defer gpa.free(path);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = text.items });
        written += 1;
    }

    std.debug.print("wrote {d} driver manifests into {s}/\n", .{ written, dir_path });
}

fn manifest(
    gpa: std.mem.Allocator,
    w: *std.ArrayList(u8),
    one: driver.Answers,
    service: []const u8,
) !void {
    try w.appendSlice(gpa,
        \\# Generated from src/lib/driver.zig by `zig build driver-manifests`.
        \\# Do not edit: change what the driver answers for instead.
        \\#
        \\
    );

    var lines = std.mem.splitScalar(u8, one.says, '\n');
    while (lines.next()) |line| try w.print(gpa, "# {s}\n", .{line});

    try w.print(gpa, "name    = {s}\n", .{one.name});
    try w.print(gpa, "service = {s}\n", .{service});
    try w.appendSlice(gpa, "match   = ");
    for (one.matches, 0..) |match, i| {
        if (i > 0) try w.appendSlice(gpa, ", ");
        try match.write(gpa, w);
    }
    try w.append(gpa, '\n');
}
