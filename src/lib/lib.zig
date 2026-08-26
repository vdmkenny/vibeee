//! Code shared by the kernel and by userspace.
//!
//! Everything reachable from here is pure computation: no state, no hardware,
//! no syscalls. That restriction is what makes it safe to compile the same
//! source into both sides of the privilege boundary, and it is enforced by
//! `tools/check-layering.zig` rather than left to discipline.
//!
//! Imported as a named module (`@import("lib")`) rather than by relative path,
//! so kernel and userspace share one instance and its types are the same type
//! on both sides of a syscall.

pub const civil = @import("civil.zig");
pub const font = @import("font.zig");
pub const logo = @import("logo.zig");
pub const ring = @import("ring.zig");
pub const syscalls = @import("syscalls.zig");

test {
    _ = civil;
    _ = font;
    _ = logo;
    _ = ring;
    _ = syscalls;
}
