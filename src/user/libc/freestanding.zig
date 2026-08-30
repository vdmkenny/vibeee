//! The libc's C-callable half, for a Zig program that carries vendored C.
//!
//! Such a program needs the routines its C calls by name, but not the
//! process startup the archive form brings along, whose entry point would
//! collide with the program's own. Importing this module emits the string
//! and stdlib exports into the binary, and nothing else: one implementation
//! in the system, reached two ways.

pub const string = @import("string.zig");
pub const stdlib = @import("stdlib.zig");

comptime {
    _ = string;
    _ = stdlib;
}
