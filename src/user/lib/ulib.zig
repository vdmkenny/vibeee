//! Userspace conveniences, shared by every program.
//!
//! Distinct from `src/lib/`, which is compiled into the kernel as well: this
//! is the half that assumes a process, a syscall layer and somewhere to write.
//! Anything here that stopped needing a syscall would belong down there
//! instead.

pub const complete = @import("complete.zig");
pub const config = @import("config.zig");
pub const dir = @import("dir.zig");
pub const edit = @import("edit.zig");
pub const info = @import("info.zig");
pub const ink = @import("ink.zig");
pub const out = @import("out.zig");
pub const paths = @import("paths.zig");
pub const procs = @import("procs.zig");
/// Strings, one layer down: they are pure computation, so the toolkit and the
/// kernel can reach them too. Re-exported here because every program that
/// wants `ulib` wants these.
pub const str = @import("lib").str;
pub const time = @import("time.zig");
