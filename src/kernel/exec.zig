//! Loading and running programs.
//!
//! Deliberately not fork, the design refuses it (design/00-vibeee.md §13),
//! because fork on a from-scratch kernel means copy-on-write page tables, and
//! every program worth running follows it immediately with exec.
//!
//! Two ways to start a program, and the difference is only who waits. `spawn`
//! runs a child and returns its status, which is what a shell running a command
//! wants. `spawnAsync` returns as soon as the child exists, which is what a
//! supervisor wants: `init` starts a dozen services and then waits for whichever
//! dies first. Both leave a corpse the parent must collect, so a status is never
//! lost before someone can read it.

const elf = @import("elf.zig");
const hal = @import("hal.zig");
const handle = @import("handle.zig");
const heap = @import("heap.zig");
const sched = @import("sched.zig");
const vfs = @import("vfs.zig");

pub const Error = error{
    NotFound,
    BadImage,
    OutOfMemory,
};

/// Both halves of the boundary have to agree on how many arguments a program
/// can take, so the limit lives with the rest of the ABI.
pub const MAX_ARGS = @import("lib").syscalls.MAX_ARGS;
pub const MAX_ARG_BYTES = 512;

/// What a child needs to start, held while the parent waits.
const Request = struct {
    entry: usize,
    stack_top: usize,
    space: hal.AddressSpace,
};

/// Run `path` with `args` and return its exit status.
/// What a child starts with on handles 0, 1 and 2. A null leaves the console
/// it was given, which is what every caller but a terminal emulator wants.
pub const Stdio = [3]?handle.Handle;

pub const INHERIT: Stdio = .{ null, null, null };

pub fn spawn(path: []const u8, args: []const []const u8, stdio: Stdio) Error!i32 {
    const child = try start(path, args, stdio);
    return sched.waitFor(child);
}

/// Start `path` and return its id without waiting.
pub fn spawnAsync(path: []const u8, args: []const []const u8, stdio: Stdio) Error!u32 {
    const child = try start(path, args, stdio);
    return child.id;
}

/// Load a program and put it on the run queue.
fn start(path: []const u8, args: []const []const u8, stdio: Stdio) Error!*sched.Thread {
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

    const child = sched.spawnAwaited(nameOf(path), .normal, childEntry, @intFromPtr(request), 16384) catch {
        heap.allocator.destroy(request);
        return error.OutOfMemory;
    };
    sched.inheritCwd(child);

    // Before the child can run: it gets the console on all three by default,
    // and a terminal emulator's shell has to find its pipes there instead.
    for (stdio, 0..) |replacement, i| {
        if (replacement) |h| {
            handle.release(child.handles.entries[i]);
            child.handles.entries[i] = h;
        }
    }

    // The address space is the child's from here; it is freed when the child is
    // reaped, so a parent that never collects still gives the memory back.
    return child;
}

/// The last path component, for the thread name.
///
/// Naming threads after their program is what makes `top` legible: a list of
/// six processes all called "user" tells the reader nothing about which one is
/// wedged.
fn nameOf(path: []const u8) []const u8 {
    var start_index: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/') start_index = i + 1;
    }
    const name = path[start_index..];
    return if (name.len == 0) "user" else name;
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
