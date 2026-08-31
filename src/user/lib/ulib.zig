//! Userspace conveniences, shared by every program.
//!
//! Distinct from `src/lib/`, which is compiled into the kernel as well: this
//! is the half that assumes a process, a syscall layer and somewhere to write.
//! Anything here that stopped needing a syscall would belong down there
//! instead.

pub const complete = @import("complete.zig");
pub const config = @import("config.zig");
pub const console = @import("console.zig");
pub const device = @import("device.zig");
pub const table = @import("table.zig");
pub const dir = @import("dir.zig");
pub const heap = @import("heap.zig");
pub const edit = @import("edit.zig");
pub const info = @import("info.zig");
pub const irqroute = @import("irqroute.zig");
pub const ink = @import("ink.zig");
pub const log = @import("log.zig");
pub const out = @import("out.zig");
pub const stream = @import("stream.zig");
pub const pager = @import("pager.zig");
pub const paths = @import("paths.zig");
pub const pci = @import("pci.zig");
pub const pciscan = @import("pciscan.zig");
pub const ports = @import("ports.zig");
pub const procs = @import("procs.zig");
pub const sock = @import("sock.zig");
pub const sound = @import("sound.zig");
/// Strings, one layer down: they are pure computation, so the toolkit and the
/// kernel can reach them too. Re-exported here because every program that
/// wants `ulib` wants these.
pub const str = @import("lib").str;
pub const time = @import("time.zig");
