//! Files, by descriptor.
//!
//! **A descriptor is a kernel handle.** There is no table here mapping one to
//! the other, because there is nothing for it to do: the kernel already keeps
//! a per-process table of handles numbered from zero, and stdin, stdout and
//! stderr already arrive as nought, one and two. A second table would be a
//! second thing to keep in step for the sake of renumbering what is already
//! numbered.
//!
//! What that costs is `dup2` onto a chosen number, which needs the kernel to
//! move a handle and it has no call for that. Nothing here needs it yet, and
//! adding the call is a smaller thing than carrying a table against the day.

const errno = @import("errno.zig");
const string = @import("string.zig");
const sys = @import("sys");

const span = string.spanOf;

pub const O_RDONLY: c_int = 0x0000;
pub const O_WRONLY: c_int = 0x0001;
pub const O_RDWR: c_int = 0x0002;
pub const O_CREAT: c_int = 0x0040;
pub const O_TRUNC: c_int = 0x0200;
pub const O_APPEND: c_int = 0x0400;
pub const O_DIRECTORY: c_int = 0x10000;

pub const SEEK_SET: c_int = 0;
pub const SEEK_CUR: c_int = 1;
pub const SEEK_END: c_int = 2;

/// C's open flags as the kernel's. Only the ones that mean something here:
/// the rest are accepted and ignored, which is friendlier to ported code than
/// refusing a flag whose absence changes nothing.
fn openFlags(flags: c_int) sys.OpenFlags {
    const access = flags & 3;
    return .{
        .directory = flags & O_DIRECTORY != 0,
        .write = access == O_WRONLY or access == O_RDWR,
        .create = flags & O_CREAT != 0,
        .truncate = flags & O_TRUNC != 0,
        .append = flags & O_APPEND != 0,
    };
}

pub export fn open(path: [*:0]const u8, flags: c_int, ...) callconv(.c) c_int {
    return @intCast(errno.wrap(sys.open(span(path), openFlags(flags))));
}

export fn creat(path: [*:0]const u8, mode: c_uint) callconv(.c) c_int {
    _ = mode; // No permission bits: one person uses this machine.
    return open(path, O_WRONLY | O_CREAT | O_TRUNC);
}

pub export fn close(fd: c_int) callconv(.c) c_int {
    if (fd < 0) return @intCast(errno.fail(errno.EBADF));
    return @intCast(errno.wrap(sys.close(@intCast(fd))));
}

pub export fn read(fd: c_int, buf: [*]u8, count: usize) callconv(.c) isize {
    if (fd < 0) return errno.fail(errno.EBADF);
    return errno.wrap(sys.read(@intCast(fd), buf[0..count]));
}

pub export fn write(fd: c_int, buf: [*]const u8, count: usize) callconv(.c) isize {
    if (fd < 0) return errno.fail(errno.EBADF);
    return errno.wrap(sys.write(@intCast(fd), buf[0..count]));
}

pub export fn lseek(fd: c_int, offset: c_long, whence: c_int) callconv(.c) c_long {
    if (fd < 0) return @intCast(errno.fail(errno.EBADF));
    return @intCast(errno.wrap(sys.seek(@intCast(fd), offset, @intCast(whence))));
}

export fn unlink(path: [*:0]const u8) callconv(.c) c_int {
    return @intCast(errno.wrap(sys.unlink(span(path))));
}

export fn rename(from: [*:0]const u8, to: [*:0]const u8) callconv(.c) c_int {
    return @intCast(errno.wrap(sys.rename(span(from), span(to))));
}

export fn mkdir(path: [*:0]const u8, mode: c_uint) callconv(.c) c_int {
    _ = mode;
    return @intCast(errno.wrap(sys.mkdir(span(path))));
}

export fn chdir(path: [*:0]const u8) callconv(.c) c_int {
    return @intCast(errno.wrap(sys.chdir(span(path))));
}

export fn getcwd(buf: [*]u8, size: usize) callconv(.c) [*c]u8 {
    const n = sys.getcwd(buf[0 .. size -| 1]);
    if (n <= 0) {
        _ = errno.fail(errno.EINVAL);
        return null;
    }
    buf[@intCast(n)] = 0;
    return buf;
}

/// Whether a descriptor is a terminal, which is what decides whether stdio
/// buffers a line at a time or a block at a time.
///
/// Answered by trying to seek. A file has a position and a terminal has not,
/// so a descriptor that refuses to seek is one where output has to reach the
/// screen when the line ends rather than when the buffer fills. A pipe refuses
/// too and is answered the same way, which is the harmless direction to be
/// wrong in: line buffering into a pipe costs a few more writes, while block
/// buffering onto a terminal makes a program look like it has hung.
pub export fn isatty(fd: c_int) callconv(.c) c_int {
    if (fd < 0) return 0;
    if (sys.seek(@intCast(fd), 0, SEEK_CUR) >= 0) return 0;

    // Asking left `errno` set from a call that was a question, not a failure.
    errno.set(0);
    return 1;
}

export fn getpid() callconv(.c) c_int {
    return @intCast(sys.getpid());
}

export fn sleep(seconds: c_uint) callconv(.c) c_uint {
    sys.sleepMicros(@as(usize, seconds) * 1_000_000);
    return 0;
}

export fn usleep(microseconds: c_uint) callconv(.c) c_int {
    sys.sleepMicros(microseconds);
    return 0;
}

export fn ftruncate(fd: c_int, size: c_long) callconv(.c) c_int {
    if (fd < 0 or size < 0) return @intCast(errno.fail(errno.EINVAL));
    return @intCast(errno.wrap(sys.ftruncate(@intCast(fd), @intCast(size))));
}

export fn fsync(fd: c_int) callconv(.c) c_int {
    _ = fd;
    // Every write is already through to the device: the page cache is
    // write-through, so there is nothing held back for this to push.
    return 0;
}


