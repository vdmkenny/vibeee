//! The libc's C-callable half, for a Zig program that carries vendored C.
//!
//! Such a program needs the routines its C calls by name, but not the
//! process startup the archive form brings along, whose entry point would
//! collide with the program's own. Importing this module emits the string
//! and stdlib exports into the binary, and nothing else: one implementation
//! in the system, reached two ways.

pub const string = @import("string.zig");
/// Saying something out loud, and reading a file: what a vendored library
/// reaches for beyond arithmetic and memory. `abort` comes with the startup
/// half, a program having to be able to stop as well as start.
pub const stdio = @import("stdio.zig");
/// Writing a number as words, which is most of what that comes to.
pub const format = @import("format.zig");
/// The clock and the calendar, for a library that asks what time it is.
pub const time = @import("time.zig");
/// The ends of a program a vendored library reaches for: `exit`, `_exit` and
/// `abort`. Not `start`, whose `_start` would collide with the program's own.
pub const stop = @import("stop.zig");
/// `dlopen` and friends, which open nothing: a vendored library that can ask
/// for a module written in C is told there are none rather than left to walk
/// into a call that is not there.
pub const dlfcn = @import("dlfcn.zig");
/// Locks and waits, for a program with one thread: a mutex that holds
/// nothing, which is what vendored C asking for `pthread.h` gets.
pub const pthread = @import("pthread.zig");
pub const stdlib = @import("stdlib.zig");
/// `malloc` and friends, onto the same heap a Zig program in this process
/// allocates from. A vendored decoder asks for its own memory, and there is
/// one heap here to give it.
pub const mem = @import("mem.zig");
/// What C reaches for when it converts a number. A parser turning "1.5e3"
/// into a double wants the same routines a calculator does, and there is one
/// set of them here.
pub const math = @import("math.zig");

comptime {
    _ = string;
    _ = stdio;
    _ = format;
    _ = time;
    _ = stop;
    _ = dlfcn;
    _ = pthread;
    _ = stdlib;
    _ = mem;
    _ = math;
}
