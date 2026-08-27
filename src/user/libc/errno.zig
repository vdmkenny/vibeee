//! errno: the numbers, and the one place a program reads them from.
//!
//! Linux's x86 numbering, because that is what ported code's `#define`s and
//! its `switch (errno)` arms already say, and inventing our own would make
//! every port a search-and-replace for nothing.
//!
//! The kernel already numbers its errors the same way, which is why there is no
//! translation table here: `wrap` negates what came back and that is the C
//! answer. The names below are the ones the kernel has, plus the ones C code
//! tests for that nothing here ever produces.

const abi = @import("lib").syscalls;

/// The ones the kernel can return, taken from its own numbering rather than
/// written out again beside it.
pub const EPERM = number(.perm);
pub const ENOENT = number(.noent);
pub const EIO = number(.io);
pub const EBADF = number(.badf);
pub const ECHILD = number(.child);
pub const ENOMEM = number(.nomem);
pub const EFAULT = number(.fault);
pub const EBUSY = number(.busy);
pub const EEXIST = number(.exists);
pub const EINVAL = number(.inval);
pub const ENOSPC = number(.nospace);
pub const EPIPE = number(.pipe);
pub const ENOSYS = number(.nosys);
pub const ETIMEDOUT = number(.timedout);

/// The ones C code tests for that nothing here produces. Present so a port
/// compiles; a program comparing against one of these is asking about a
/// condition this system does not have.
pub const ESRCH = 3;
pub const EINTR = 4;
pub const ENXIO = 6;
pub const E2BIG = 7;
pub const ENOEXEC = 8;
pub const EAGAIN = 11;
pub const EACCES = 13;
pub const ENODEV = 19;
pub const ENOTDIR = 20;
pub const EISDIR = 21;
pub const ENFILE = 23;
pub const EMFILE = 24;
pub const ENOTTY = 25;
pub const EFBIG = 27;
pub const ESPIPE = 29;
pub const EROFS = 30;
pub const ERANGE = 34;
pub const ENAMETOOLONG = 36;
pub const ENOTEMPTY = 39;

fn number(code: abi.Errno) c_int {
    return @intFromEnum(code);
}

/// One per program. A field of the thread control block once there are
/// threads; until then a program is one thread and this is that thread's.
var value: c_int = 0;

pub export fn __errno_location() callconv(.c) *c_int {
    return &value;
}

pub fn set(code: c_int) void {
    value = code;
}

/// A syscall result, as C wants it: the value on success, and -1 with `errno`
/// set on failure.
///
/// Every call in this library ends here. The kernel returns the negated error
/// number and C wants it positive in `errno`, so that is the whole conversion.
pub fn wrap(result: isize) isize {
    if (result >= 0) return result;
    return fail(@intCast(-result));
}

/// What an error means, in the words the rest of the system already uses for
/// it. Null for a number no part of this system produces.
pub fn describe(code: c_int) ?[]const u8 {
    const known = abi.Errno.of(-@as(isize, code)) orelse return null;
    return known.reason();
}

/// Fail with a chosen code, for a call that decided by itself rather than by
/// asking the kernel.
pub fn fail(code: c_int) isize {
    set(code);
    return -1;
}
