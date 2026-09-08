//! Starting programs and waiting for them, and the working directory.

const std = @import("std");
const abi = @import("lib").syscalls;
const ctx = @import("context.zig");
const exec = @import("../exec.zig");
const handles = @import("../handle.zig");
const path_mod = @import("../path.zig");
const sched = @import("../sched.zig");
const vfs = @import("../vfs.zig");

const Args = ctx.Args;
const Result = ctx.Result;
const Errno = ctx.Errno;
const userRead = ctx.userRead;
const userWrite = ctx.userWrite;
const userPath = ctx.userPath;
const deadlineFrom = ctx.deadlineFrom;
const currentHandles = ctx.currentHandles;
const currentCaps = ctx.currentCaps;

pub fn sys_spawn(a: Args) Result {
    if (ctx.require(.{ .spawn = true })) |denied| return denied;

    var path_buf: [path_mod.MAX]u8 = undefined;
    const path = userPath(a, a.a0, a.a1, &path_buf) orelse return Errno.fault.value();
    const packed_args = userRead(a, a.a2, a.a3) orelse return Errno.fault.value();

    // Arguments are copied out of user memory before anything else happens.
    // Leaving them there would mean the loader reading pages that the child's
    // own address space is about to replace.
    var storage: [exec.MAX_ARG_BYTES]u8 = undefined;
    var slices: [exec.MAX_ARGS][]const u8 = undefined;

    const count = abi.Argv.unpack(packed_args, &storage, &slices) catch return Errno.inval.value();

    var options = abi.Spawn{};
    if (a.a4 != 0) {
        const raw = userRead(a, a.a4, @sizeOf(abi.Spawn)) orelse return Errno.fault.value();
        options = std.mem.bytesToValue(abi.Spawn, raw[0..@sizeOf(abi.Spawn)]);
    }

    // The environment travels the way the arguments do, because it is the
    // same thing: a list of strings, packed by the same code and copied
    // out of user memory for the same reason.
    var env_storage: [exec.MAX_ENV_BYTES]u8 = undefined;
    var env_slices: [exec.MAX_ENV][]const u8 = undefined;
    var env_count: usize = 0;
    if (options.env != 0 and options.env_len != 0) {
        const packed_env = userRead(a, options.env, options.env_len) orelse
            return Errno.fault.value();
        env_count = abi.Argv.unpack(packed_env, &env_storage, &env_slices) catch
            return Errno.inval.value();
    }

    // Where the child starts, if the caller said. Checked here rather than
    // taken on trust: a directory that is not one is a program started
    // somewhere it cannot read from, which looks like the program failing.
    var cwd_buf: [path_mod.MAX]u8 = undefined;
    var in: ?[]const u8 = null;
    if (options.cwd != 0 and options.cwd_len != 0) {
        const where = userPath(a, options.cwd, options.cwd_len, &cwd_buf) orelse
            return Errno.fault.value();
        const entry = vfs.stat(where) catch return Errno.noent.value();
        if (!entry.is_dir) return Errno.inval.value();
        in = where;
    }

    var stdio = exec.INHERIT;
    claimStdio(&options, &stdio) catch return Errno.badf.value();

    // Never more than the caller has. A parent cannot hand out an authority it
    // was not given, which is what makes the tree below a process bounded by
    // what that process could do.
    const caps = currentCaps().intersect(@bitCast(options.caps));

    const flags: abi.SpawnFlags = @bitCast(options.flags);

    if (flags.detached) {
        const id = exec.spawnAsync(path, slices[0..count], env_slices[0..env_count], stdio, caps, in) catch |err| {
            releaseStdio(&stdio);
            return spawnErrno(err);
        };
        return @intCast(id);
    }
    return exec.spawn(path, slices[0..count], env_slices[0..env_count], stdio, caps, in) catch |err| {
        releaseStdio(&stdio);
        return spawnErrno(err);
    };
}

/// Take a reference to each handle the child will find on 0, 1 and 2.
///
/// A reference of its own, because the parent goes on holding its copy and
/// either may close first. A terminal emulator closes its ends of the shell's
/// pipes straight after spawning, and the shell must not lose them with it.
///
/// `INHERIT` means the caller's own handle of that number, not a fresh
/// console. That is what makes a pipe survive a shell: a terminal gives the
/// shell one, and every tool the shell runs finds it too.
fn claimStdio(options: *const abi.Spawn, out: *exec.Stdio) error{BadHandle}!void {
    const table = currentHandles() orelse return error.BadHandle;
    const wanted = [_]i32{ options.stdin, options.stdout, options.stderr };

    // What was taken for one stream is given back if a later one cannot be.
    errdefer releaseStdio(out);

    for (wanted, 0..) |number, i| {
        if (number == abi.Spawn.INHERIT) {
            // A caller with nothing on its own stream leaves the child the
            // console it was given, which is what early boot and `init`
            // rely on.
            const h = table.get(@intCast(i)) orelse continue;
            out[i] = handles.retain(h.*) catch return error.BadHandle;
            continue;
        }
        // A stream named by number has to be there: a caller that asked for
        // a handle it does not hold is wrong, and giving the child the
        // console instead would hide that.
        if (number < 0) return error.BadHandle;
        const h = table.get(@intCast(number)) orelse return error.BadHandle;
        out[i] = handles.retain(h.*) catch return error.BadHandle;
    }
}

fn releaseStdio(stdio: *exec.Stdio) void {
    for (stdio) |maybe| {
        // A copy the child never got: nothing of its own was written.
        if (maybe) |h| handles.release(h) catch {};
    }
    stdio.* = exec.INHERIT;
}

fn spawnErrno(err: exec.Error) Result {
    return switch (err) {
        error.NotFound => Errno.noent.value(),
        error.BadImage, error.TooManyArguments => Errno.inval.value(),
        error.OutOfMemory => Errno.nomem.value(),
    };
}

pub fn sys_wait(a: Args) Result {
    const status_out = userWrite(a, a.a2, @sizeOf(i32)) orelse return Errno.fault.value();

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

    // Must exist and be a directory.
    const entry = vfs.stat(path) catch |err| {
        return switch (err) {
            error.NotDirectory => Errno.inval.value(),
            else => Errno.noent.value(),
        };
    };
    if (!entry.is_dir) return Errno.inval.value();

    return if (sched.setCwd(path)) 0 else Errno.inval.value();
}

pub fn sys_getcwd(a: Args) Result {
    const out = userWrite(a, a.a0, a.a1) orelse return Errno.fault.value();
    const dir = sched.cwd();
    if (dir.len > out.len) return Errno.nomem.value();
    @memcpy(out[0..dir.len], dir);
    return @intCast(dir.len);
}

pub fn sys_kill(a: Args) Result {
    if (ctx.require(.{ .kill = true })) |denied| return denied;

    const pid: u32 = @truncate(a.a0);
    const how = std.enums.fromInt(abi.Ending, a.a1) orelse return Errno.inval.value();
    switch (how) {
        .now => sched.kill(pid) catch |err| return switch (err) {
            error.NotFound => Errno.noent.value(),
            error.Refused => Errno.perm.value(),
        },
        .ask => sched.askToEnd(pid) catch |err| return switch (err) {
            error.NotFound => Errno.noent.value(),
            error.NotListening => Errno.notconn.value(),
        },
    }
    return 0;
}
