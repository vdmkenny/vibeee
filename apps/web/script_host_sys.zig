//! script_host_sys: the machine under the script host.
//!
//! Two pipes, a program started with one in its hand and the other at its
//! mouth, and the handful of calls `script_host` makes of them. Kept out of
//! `script_host.zig` because that file is the lifecycle and the fault
//! handling, and those are tested on this machine — where there is no kernel
//! to make a pipe and no worker to start. What is here cannot be tested
//! here at all; what is there can, and is.
//!
//! Nothing waits. A pipe blocks while it is full and blocks until something
//! arrives, and a reader that blocked on a worker would stop being a
//! reader: the window would stop drawing and the keys would stop working
//! while a page's scripts thought about it. So both ends are asked first,
//! with a poll, and one that would block is left for the next pass instead.
//! That is what `eterm` does with its shell, for the same reason.

const sys = @import("sys");
const script_host = @import("script_host");

/// Where the worker's program is: beside the reader, in a person's own
/// files, because it is the reader's and not the system's.
const PROGRAM = "/home/bin/script_worker";

/// How much is written at a time. The pipe is a page; a whole page's markup
/// in one call would be a write that blocks until the worker has taken all
/// of it, which is a reader waiting on a page.
///
/// TODO(13): a page's markup is the reason this is a compromise at all. §5
/// sends what is longer than a frame by shared memory; until it does, the
/// channel is a pipe and this is the most of one that is put in it at once.
const CHUNK = 1024;

/// How long a worker is given to be collected after it has been ended.
const COLLECT_US: usize = 20_000;

pub const platform: script_host.Platform = .{
    .ptr = undefined,
    .spawn = spawn,
    .kill = kill,
    .close = close,
    .write = write,
    .read = read,
    .ended = ended,
};

/// Start the worker with a pipe in each hand: what it reads is what the
/// reader writes, and the other way round. Its console is the reader's, so
/// what it says on the way out is said where a person can find it.
fn spawn(_: *anyopaque) script_host.SpawnError!script_host.Child {
    const to = sys.pipe() orelse return error.Refused;
    errdefer {
        sys.close(to.read);
        sys.close(to.write);
    }
    const from = sys.pipe() orelse return error.Refused;
    errdefer {
        sys.close(from.read);
        sys.close(from.write);
    }

    const pid = sys.spawnStreams(PROGRAM, &.{"script_worker"}, .{
        .flags = @bitCast(sys.SpawnFlags{ .detached = true }),
        .stdin = @intCast(to.read),
        .stdout = @intCast(from.write),
        .stderr = sys.Spawn.INHERIT,
    }) catch return error.Refused;

    // The child holds its own ends now. Keeping these would mean the pipes
    // never report their end of file, because this process would still be
    // counted as a reader of its own writing and a writer of its own
    // reading — which is how a reader would wait for a worker that was
    // never going to say anything again.
    sys.close(to.read);
    sys.close(from.write);

    return .{ .pid = pid, .to = to.write, .from = from.read };
}

/// End it, and collect it: a worker ended and left is a process the machine
/// keeps a place for until the reader goes too.
fn kill(_: *anyopaque, pid: u32) void {
    sys.kill(pid, .now) catch {};
    _ = sys.wait(pid, COLLECT_US);
}

fn close(_: *anyopaque, handle: u32) void {
    sys.close(handle);
}

fn write(_: *anyopaque, handle: u32, bytes: []const u8) script_host.Wrote {
    if (!waits(handle)) return .full;
    const n = sys.write(handle, bytes[0..@min(bytes.len, CHUNK)]) catch return .gone;
    return .{ .some = n };
}

fn read(_: *anyopaque, handle: u32, into: []u8) script_host.Read {
    if (!waits(handle)) return .none;
    const n = sys.read(handle, into) catch return .gone;
    // Nothing left, and nobody writing: end of file, which is a worker that
    // has gone.
    return if (n == 0) .gone else .{ .some = n };
}

fn ended(_: *anyopaque, pid: u32, timeout_us: usize) bool {
    return sys.wait(pid, timeout_us) != null;
}

/// Whether a handle would not block. A pipe says so while there is room, or
/// while there is something to take, and also once the far end of it has
/// gone — which is the answer a caller is really after, and why a handle
/// that is no longer one is called ready: what follows it says so.
fn waits(handle: u32) bool {
    var one = [_]u32{handle};
    return if (sys.waitMany(&one, sys.POLL)) |_| true else |err| switch (err) {
        error.TimedOut => false,
        else => true,
    };
}
