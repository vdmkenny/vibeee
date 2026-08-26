//! Filesystem calls.

const std = @import("std");
const abi = @import("lib").syscalls;
const ctx = @import("context.zig");
const fat = @import("../fat.zig");
const handles = @import("../handle.zig");
const path_mod = @import("../path.zig");
const vfs = @import("../vfs.zig");

const Args = ctx.Args;
const Result = ctx.Result;
const Errno = ctx.Errno;
const userSlice = ctx.userSlice;
const userPath = ctx.userPath;
const currentHandles = ctx.currentHandles;

fn openFlags(raw: usize) abi.OpenFlags {
    return @bitCast(@as(u32, @truncate(raw)));
}

fn writeDirent(out: []u8, entry: fat.Entry) ?usize {
    const record = abi.Dirent{
        .size = entry.size,
        .mtime = entry.mtime,
        .is_dir = entry.is_dir,
        .name = entry.nameSlice(),
    };
    return record.encode(out);
}

pub fn sys_open(a: Args) Result {
    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();

    const table = currentHandles() orelse return Errno.nomem.value();
    const slot = table.alloc() orelse return Errno.nomem.value();
    const h = &table.entries[slot];

    if (openFlags(a.a2).directory) {
        const it = vfs.openDir(path) catch return Errno.noent.value();
        const r = vfs.resolve(path) catch return Errno.noent.value();
        r.mount.open_files += 1;
        h.* = .{
            .kind = .directory,
            .rights = .{ .read = true },
            .data = .{ .directory = .{ .mount = r.mount, .iterator = it } },
        };
        return @intCast(slot);
    }

    const opened = vfs.open(path) catch return Errno.noent.value();
    h.* = .{
        .kind = .file,
        .rights = .{ .read = true, .seek = true },
        .data = .{ .file = .{ .mount = opened.mount, .entry = opened.entry } },
    };
    return @intCast(slot);
}

pub fn sys_close(a: Args) Result {
    const table = currentHandles() orelse return Errno.badf.value();
    return if (table.close(@truncate(a.a0))) 0 else Errno.badf.value();
}

pub fn sys_seek(a: Args) Result {
    const table = currentHandles() orelse return Errno.badf.value();
    const h = table.get(@truncate(a.a0)) orelse return Errno.badf.value();
    if (h.kind != .file) return Errno.badf.value();

    const f = &h.data.file;
    const displacement: isize = @bitCast(a.a1);

    const base: i64 = switch (a.a2) {
        0 => 0,
        1 => @intCast(f.offset),
        2 => @intCast(f.entry.size),
        else => return Errno.inval.value(),
    };

    const target = base + displacement;
    if (target < 0) return Errno.inval.value();

    // Seeking past the end is allowed and simply reads nothing, which is what
    // callers computing an offset before checking the size expect.
    f.offset = @intCast(target);
    return @intCast(f.offset);
}

pub fn sys_readdir(a: Args) Result {
    const table = currentHandles() orelse return Errno.badf.value();
    const h = table.get(@truncate(a.a0)) orelse return Errno.badf.value();
    if (h.kind != .directory) return Errno.badf.value();

    const out = userSlice(a, a.a1, a.a2) orelse return Errno.fault.value();
    const d = &h.data.directory;
    if (d.exhausted) return 0;

    const entry = (d.iterator.next() catch return Errno.io.value()) orelse {
        d.exhausted = true;
        return 0;
    };

    const n = writeDirent(out, entry) orelse return Errno.nomem.value();
    return @intCast(n);
}

pub fn sys_stat(a: Args) Result {
    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();
    const out = userSlice(a, a.a2, a.a3) orelse return Errno.fault.value();

    const entry = vfs.stat(path) catch return Errno.noent.value();
    const n = writeDirent(out, entry) orelse return Errno.nomem.value();
    return @intCast(n);
}