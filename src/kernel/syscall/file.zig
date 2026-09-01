//! Filesystem calls.

const std = @import("std");
const abi = @import("lib").syscalls;
const clock = @import("../clock.zig");
const ctx = @import("context.zig");
const fat = @import("../fat.zig");
const handles = @import("../handle.zig");
const path_mod = @import("../path.zig");
const block = @import("../block.zig");
const vfs = @import("../vfs.zig");

const Args = ctx.Args;
const Result = ctx.Result;
const Errno = ctx.Errno;
const userRead = ctx.userRead;
const userWrite = ctx.userWrite;
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

        const iterator = handles.newIterator(it) orelse return Errno.nomem.value();
        r.mount.open_files += 1;
        h.* = .{
            .rights = .{ .read = true },
            .data = .{ .directory = .{
                .mount = r.mount,
                .iterator = iterator,
                // Nothing above a mount root, so nothing to report as its
                // parent. `resolve` leaves nothing over for one.
                .at_root = r.rest.len == 0,
            } },
        };
        return @intCast(slot);
    }

    const flags = openFlags(a.a2);

    var opened = vfs.open(path) catch |err| blk: {
        // Only a missing file is worth creating; anything else is a real
        // failure and creating a file on top of it would hide it.
        if (err != error.NotFound or !flags.create) return errnoFor(err);
        break :blk vfs.create(path, clock.realtimeSeconds()) catch |create_err| {
            return errnoFor(create_err);
        };
    };

    if (flags.truncate and flags.write) {
        vfs.truncate(opened.mount, &opened.entry) catch |err| return errnoFor(err);
        vfs.commit(opened.mount, opened.entry, clock.realtimeSeconds()) catch {};
    }

    h.* = .{
        .rights = .{ .read = true, .write = flags.write, .seek = true },
        .data = .{ .file = .{
            .mount = opened.mount,
            .entry = opened.entry,
            .offset = if (flags.append) opened.entry.size else 0,
            .append = flags.append,
            .dirty = false,
        } },
    };
    return @intCast(slot);
}

/// Map a filesystem error onto the number userspace sees.
///
/// One place, because the same handful of errors come back from open, create,
/// write and unlink, and each mapping them separately is how a caller ends up
/// being told ENOENT for a full disk.
fn errnoFor(err: anyerror) Result {
    return switch (err) {
        error.NotFound, error.NotMounted => Errno.noent.value(),
        error.Exists, error.AlreadyMounted => Errno.exists.value(),
        error.Busy => Errno.busy.value(),
        error.TableFull => Errno.nomem.value(),
        error.NotFat, error.Unsupported => Errno.inval.value(),
        error.ReadOnly => Errno.perm.value(),
        error.NoSpace => Errno.nospace.value(),
        error.IsDirectory, error.NotDirectory, error.BadPath, error.NameTooLong, error.CrossDevice => Errno.inval.value(),
        else => Errno.io.value(),
    };
}

pub fn sys_mkdir(a: Args) Result {
    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();

    vfs.mkdir(path, clock.realtimeSeconds()) catch |err| return errnoFor(err);
    return 0;
}

pub fn sys_ftruncate(a: Args) Result {
    const table = currentHandles() orelse return Errno.badf.value();
    const h = table.get(@truncate(a.a0)) orelse return Errno.badf.value();
    const open = switch (h.data) {
        .file => |*open| open,
        else => return Errno.inval.value(),
    };
    vfs.resize(open.mount, &open.entry, @truncate(a.a1)) catch |err| return errnoFor(err);
    vfs.commit(open.mount, open.entry, clock.realtimeSeconds()) catch {};
    return 0;
}

pub fn sys_mount(a: Args) Result {
    if (ctx.require(.{ .mount = true })) |denied| return denied;

    // A volume is named, not addressed: `userPath` would resolve it against the
    // working directory and turn `hd0p1` into a path nothing is called.
    const name = userRead(a, a.a0, a.a1) orelse return Errno.fault.value();

    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a2, a.a3, &path_buf) orelse return Errno.fault.value();

    const device = block.find(name) orelse return Errno.noent.value();
    const flags: abi.MountFlags = @bitCast(@as(u32, @truncate(a.a4)));

    const attached = vfs.mount(path, device, flags.removable) catch |err| return errnoFor(err);
    attached.read_only = flags.read_only;
    return 0;
}

pub fn sys_unmount(a: Args) Result {
    if (ctx.require(.{ .mount = true })) |denied| return denied;

    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();

    vfs.unmount(path) catch |err| return errnoFor(err);
    return 0;
}

pub fn sys_rename(a: Args) Result {
    var from_buf: [path_mod.MAX]u8 = undefined;
    const from = userPath(a, a.a0, a.a1, &from_buf) orelse return Errno.fault.value();

    var to_buf: [path_mod.MAX]u8 = undefined;
    const to = userPath(a, a.a2, a.a3, &to_buf) orelse return Errno.fault.value();

    vfs.rename(from, to, clock.realtimeSeconds()) catch |err| return errnoFor(err);
    return 0;
}

pub fn sys_unlink(a: Args) Result {
    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();

    vfs.unlink(path) catch |err| return errnoFor(err);
    return 0;
}

pub fn sys_close(a: Args) Result {
    const table = currentHandles() orelse return Errno.badf.value();
    return if (table.close(@truncate(a.a0))) 0 else Errno.badf.value();
}

pub fn sys_seek(a: Args) Result {
    const table = currentHandles() orelse return Errno.badf.value();
    const h = table.get(@truncate(a.a0)) orelse return Errno.badf.value();
    const f = switch (h.data) {
        .file => |*f| f,
        else => return Errno.badf.value(),
    };
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
    const d = switch (h.data) {
        .directory => |*d| d,
        else => return Errno.badf.value(),
    };

    const out = userWrite(a, a.a1, a.a2) orelse return Errno.fault.value();
    if (d.exhausted) return 0;

    // The parent comes first and is made up here rather than passed through.
    //
    // FAT records one in a subdirectory and not in a root, and a filesystem
    // without directory entries at all would record none. A caller that had to
    // know which is which could not be written once, so every directory that
    // has a parent reports one and no directory reports itself.
    if (!d.sent_parent) {
        d.sent_parent = true;
        if (!d.at_root) {
            const record = abi.Dirent{ .size = 0, .mtime = 0, .is_dir = true, .name = ".." };
            const n = record.encode(out) orelse return Errno.nomem.value();
            return @intCast(n);
        }
    }

    while (true) {
        const entry = (d.iterator.next() catch return Errno.io.value()) orelse {
            d.exhausted = true;
            return 0;
        };

        // The filesystem's own dot entries are dropped: `..` was answered
        // above, and `.` tells a reader nothing it did not already know.
        const name = entry.nameSlice();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const n = writeDirent(out, entry) orelse return Errno.nomem.value();
        return @intCast(n);
    }
}

pub fn sys_stat(a: Args) Result {
    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();
    const out = userWrite(a, a.a2, a.a3) orelse return Errno.fault.value();

    const entry = vfs.stat(path) catch return Errno.noent.value();
    const n = writeDirent(out, entry) orelse return Errno.nomem.value();
    return @intCast(n);
}