//! eeelibc: enough C for a program written against POSIX to build and run.
//!
//! Zig source exporting the C ABI, linked as a static archive. Static because
//! the alternative is a dynamic loader, and on a machine with eight or ten
//! programs the loader costs more in complexity and per-spawn milliseconds
//! than the duplication costs in RAM. `design/11-userspace.md` §6.6.
//!
//! What is deliberately absent, with what to do instead:
//!
//! | Not here | Instead |
//! |---|---|
//! | `fork` | `posix_spawn`, because there is no address-space clone and no overcommit story behind one |
//! | asynchronous signals | a termination request the program notices where it chooses |
//! | file-backed `mmap` | `read` |
//! | locales | there is one, and it is UTF-8 |
//!
//! This file exists to name every part, because an `export fn` in a module
//! nothing imports is an `export fn` that is not in the archive.

pub const errno = @import("errno.zig");
pub const format = @import("format.zig");
pub const math = @import("math.zig");
pub const mem = @import("mem.zig");
pub const start = @import("start.zig");
pub const stdio = @import("stdio.zig");
pub const stdlib = @import("stdlib.zig");
pub const string = @import("string.zig");
pub const time = @import("time.zig");
pub const term = @import("term.zig");
pub const unistd = @import("unistd.zig");

comptime {
    _ = errno;
    _ = format;
    _ = math;
    _ = mem;
    _ = start;
    _ = stdio;
    _ = stdlib;
    _ = string;
    _ = time;
    _ = term;
    _ = unistd;
}
