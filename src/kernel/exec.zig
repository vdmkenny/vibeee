//! Loading and running programs.
//!
//! Synchronous: `spawn` returns the child's exit status, having waited for it.
//! Deliberately not fork — the design refuses it (design/00-vibeee.md §13),
//! because fork on a from-scratch kernel means copy-on-write page tables, and
//! every program worth running follows it immediately with exec.
//!
//! Asynchronous spawn arrives with job control, which needs somewhere to report
//! a finished background job. Until a shell has that, a call that returns a
//! status is the more useful primitive.

const std = @import("std");
const console = @import("console.zig");
const elf = @import("elf.zig");
const hal = @import("hal.zig");
const heap = @import("heap.zig");
const sched = @import("sched.zig");
const vfs = @import("vfs.zig");

pub const Error = error{
    NotFound,
    BadImage,
    OutOfMemory,
};

pub const MAX_ARGS = 16;
pub const MAX_ARG_BYTES = 512;

/// What a child needs to start, held while the parent waits.
const Request = struct {
    entry: usize,
    stack_top: usize,
    space: hal.AddressSpace,
};

/// Run `path` with `args` and return its exit status.
pub fn spawn(path: []const u8, args: []const []const u8) Error!i32 {
    const entry = vfs.stat(path) catch return error.NotFound;
    if (entry.is_dir or entry.size == 0) return error.BadImage;

    const image = heap.allocator.alloc(u8, entry.size) catch return error.OutOfMemory;
    defer heap.allocator.free(image);

    const n = vfs.readFile(path, image) catch return error.NotFound;

    var space = hal.AddressSpace.create() catch return error.OutOfMemory;
    errdefer space.destroy();

    const loaded = elf.load(&space, image[0..n]) catch return error.BadImage;
    const stack_top = hal.setupUserStack(&space, args) catch return error.OutOfMemory;

    const request = heap.allocator.create(Request) catch return error.OutOfMemory;
    request.* = .{ .entry = loaded.entry, .stack_top = stack_top, .space = space };

    const child = sched.spawnAwaited("user", .normal, childEntry, @intFromPtr(request), 16384) catch {
        heap.allocator.destroy(request);
        return error.OutOfMemory;
    };
    sched.inheritCwd(child);

    const status = sched.waitFor(child);

    // Safe only because the scheduler has switched back to this thread's own
    // address space by now. Freeing it while it was still loaded would unmap
    // the ground underneath the caller.
    space.destroy();
    return status;
}

fn childEntry(arg: usize) callconv(.c) void {
    const request: *Request = @ptrFromInt(arg);
    const entry = request.entry;
    const stack_top = request.stack_top;
    var space = request.space;
    heap.allocator.destroy(request);

    const self = sched.currentThread() orelse sched.exit();
    const kernel_stack = @intFromPtr(self.stack.ptr) + self.stack.len;

    // Record it on the thread as well as loading it, so the scheduler restores
    // this space when the thread is next resumed, and restores the parent's
    // when it is not.
    sched.setAddressSpace(self, space);
    space.activate();
    sched.noteAddressSpace(space.pd_phys);

    hal.enterUserMode(entry, stack_top, kernel_stack);
}
