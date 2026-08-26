//! Starting programs and waiting for them, and the working directory.

const std = @import("std");
const abi = @import("lib").syscalls;
const ctx = @import("context.zig");
const exec = @import("../exec.zig");
const path_mod = @import("../path.zig");
const sched = @import("../sched.zig");
const vfs = @import("../vfs.zig");

const Args = ctx.Args;
const Result = ctx.Result;
const Errno = ctx.Errno;
const userSlice = ctx.userSlice;
const userPath = ctx.userPath;
const deadlineFrom = ctx.deadlineFrom;

pub fn sys_spawn(a: Args) Result {
    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();
    const packed_args = userSlice(a, a.a2, a.a3) orelse return Errno.fault.value();

    // Arguments are copied out of user memory before anything else happens.
    // Leaving them there would mean the loader reading pages that the child's
    // own address space is about to replace.
    var storage: [exec.MAX_ARG_BYTES]u8 = undefined;
    var slices: [exec.MAX_ARGS][]const u8 = undefined;

    const count = abi.Argv.unpack(packed_args, &storage, &slices) catch return Errno.inval.value();

    const flags: abi.SpawnFlags = @bitCast(@as(u32, @truncate(a.a4)));

    if (flags.detached) {
        const id = exec.spawnAsync(path, slices[0..count]) catch |err| return spawnErrno(err);
        return @intCast(id);
    }
    return exec.spawn(path, slices[0..count]) catch |err| return spawnErrno(err);
}

fn spawnErrno(err: exec.Error) Result {
    return switch (err) {
        error.NotFound => Errno.noent.value(),
        error.BadImage => Errno.inval.value(),
        error.OutOfMemory => Errno.nomem.value(),
    };
}

pub fn sys_wait(a: Args) Result {
    const status_out = userSlice(a, a.a2, @sizeOf(i32)) orelse return Errno.fault.value();

    const exited = sched.waitChild(@intCast(a.a0), deadlineFrom(a.a1)) catch |err| {
        return switch (err) {
            error.NoChildren => Errno.child.value(),
            error.TimedOut => Errno.timedout.value(),
        };
    };

    std.mem.writeInt(i32, status_out[0..4], exited.status, .little);
    return @intCast(exited.id);
}


pub fn sys_chdir(a: Args) Result {
    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();

    // Must exist and be a directory. Checked by opening it rather than by
    // looking up an entry: a mount point has no entry in its parent volume,
    // and `stat` on one fails, which would make it impossible to enter a
    // mounted disk at all.
    var dir = vfs.openDir(path) catch |err| {
        return switch (err) {
            error.NotDirectory => Errno.inval.value(),
            else => Errno.noent.value(),
        };
    };
    _ = &dir;

    return if (sched.setCwd(path)) 0 else Errno.inval.value();
}

pub fn sys_getcwd(a: Args) Result {
    const out = userSlice(a, a.a0, a.a1) orelse return Errno.fault.value();
    const dir = sched.cwd();
    if (dir.len > out.len) return Errno.nomem.value();
    @memcpy(out[0..dir.len], dir);
    return @intCast(dir.len);
}