//! Userspace conveniences, shared by every program.
//!
//! Distinct from `src/lib/`, which is compiled into the kernel as well: this
//! is the half that assumes a process, a syscall layer and somewhere to write.
//! Anything here that stopped needing a syscall would belong down there
//! instead.

pub const info = @import("info.zig");
pub const out = @import("out.zig");
pub const str = @import("str.zig");
pub const time = @import("time.zig");
