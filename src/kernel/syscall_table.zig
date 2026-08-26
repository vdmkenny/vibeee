//! The syscall ABI, as data.
//!
//! This file is the single source of truth for the system call interface. Three
//! things are generated from it, so they cannot drift apart:
//!
//!   * the kernel dispatcher      (kernel/syscall.zig)
//!   * the reference documentation (tools/gen-syscall-docs.zig → docs/syscalls.md)
//!   * userspace stubs            (later, for eeelibc)
//!
//! Deliberately free of handler pointers and kernel imports, so host tools can
//! import it directly. `kernel/syscall.zig` binds each entry to its
//! implementation and fails to compile if any entry is unbound — a syscall
//! cannot be documented without existing, or exist without being documented.

const std = @import("std");

pub const ArgKind = enum {
    /// Signed machine word.
    int,
    /// Unsigned machine word.
    uint,
    /// Userspace pointer. Always validated against the caller's address space
    /// before use; never dereferenced twice.
    ptr,
    /// Userspace pointer to memory the kernel only reads.
    cptr,
    /// Byte count, paired with the preceding pointer.
    len,
    /// Index into the calling process's handle table.
    handle,
    /// Bitfield; the description names the flags.
    flags,

    pub fn label(self: ArgKind) []const u8 {
        return switch (self) {
            .int => "int",
            .uint => "uint",
            .ptr => "ptr",
            .cptr => "const ptr",
            .len => "len",
            .handle => "handle",
            .flags => "flags",
        };
    }
};

pub const Arg = struct {
    name: []const u8,
    kind: ArgKind,
    desc: []const u8,
};

pub const Err = struct {
    name: []const u8,
    when: []const u8,
};

pub const Syscall = struct {
    number: u32,
    name: []const u8,
    summary: []const u8,
    args: []const Arg = &.{},
    /// What a successful call returns in the result register.
    returns: []const u8 = "0",
    errors: []const Err = &.{},
    /// Notes worth reading before using it. Optional.
    notes: []const u8 = "",
};

/// Standard error numbers. Returned as negative values in the result register,
/// so a caller tests `result < 0`.
pub const Errno = enum(i32) {
    perm = 1,
    noent = 2,
    io = 5,
    badf = 9,
    nomem = 12,
    fault = 14,
    inval = 22,
    nosys = 38,

    pub fn value(self: Errno) i32 {
        return -@as(i32, @intFromEnum(self));
    }
};

const E = struct {
    const badf = Err{ .name = "EBADF", .when = "the handle is not open in this process" };
    const fault = Err{ .name = "EFAULT", .when = "a pointer argument is outside the caller's address space" };
    const inval = Err{ .name = "EINVAL", .when = "an argument is out of range" };
};

/// Well-known handles, open in every process at start.
pub const STDIN: u32 = 0;
pub const STDOUT: u32 = 1;
pub const STDERR: u32 = 2;

/// The table. Numbers are permanent once released: append, never renumber.
pub const table = [_]Syscall{
    .{
        .number = 0,
        .name = "exit",
        .summary = "Terminate the calling process.",
        .args = &.{
            .{ .name = "status", .kind = .int, .desc = "Exit status reported to whoever waits for this process." },
        },
        .returns = "does not return",
    },
    .{
        .number = 1,
        .name = "write",
        .summary = "Write bytes to an open handle.",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "Destination. STDOUT and STDERR go to the console." },
            .{ .name = "buf", .kind = .cptr, .desc = "Bytes to write." },
            .{ .name = "len", .kind = .len, .desc = "Number of bytes." },
        },
        .returns = "bytes written",
        .errors = &.{ E.badf, E.fault },
        .notes = "Short writes are possible; callers must loop.",
    },
    .{
        .number = 2,
        .name = "read",
        .summary = "Read bytes from an open handle.",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "Source." },
            .{ .name = "buf", .kind = .ptr, .desc = "Where to put the bytes." },
            .{ .name = "len", .kind = .len, .desc = "Maximum bytes to read." },
        },
        .returns = "bytes read, or 0 at end of input",
        .errors = &.{ E.badf, E.fault },
        .notes = "Blocks until input is available. On STDIN, input is line-buffered: a read returns once Enter is pressed, and never mid-line.",
    },
    .{
        .number = 3,
        .name = "yield",
        .summary = "Give up the rest of the current time slice.",
        .notes = "A hint, not a guarantee: the scheduler may immediately pick the same thread again if nothing else is runnable.",
    },
    .{
        .number = 4,
        .name = "sleep_us",
        .summary = "Block the calling thread for at least the given time.",
        .args = &.{
            .{ .name = "usec", .kind = .uint, .desc = "Minimum microseconds to sleep." },
        },
        .notes = "Resolution is bounded by the timer tick, so short sleeps round up.",
    },
    .{
        .number = 5,
        .name = "clock_us",
        .summary = "Read the monotonic clock.",
        .args = &.{
            .{ .name = "out", .kind = .ptr, .desc = "Pointer to a u64 that receives microseconds since boot." },
        },
        .errors = &.{E.fault},
        .notes = "Monotonic and never steps backwards. Not wall-clock time; it is unaffected by clock adjustment.",
    },
    .{
        .number = 6,
        .name = "getpid",
        .summary = "Return the calling process's identifier.",
        .returns = "process id",
    },
    .{
        .number = 7,
        .name = "log",
        .summary = "Write a line to the kernel log.",
        .args = &.{
            .{ .name = "buf", .kind = .cptr, .desc = "Message text, without a trailing newline." },
            .{ .name = "len", .kind = .len, .desc = "Message length." },
        },
        .errors = &.{ E.fault, E.inval },
        .notes = "Separate from write() so diagnostics survive a process losing its console handle. Rate-limited.",
    },
    .{
        .number = 8,
        .name = "shutdown",
        .summary = "Flush all filesystems and stop the machine.",
        .args = &.{
            .{ .name = "action", .kind = .uint, .desc = "0 power off, 1 reboot, 2 halt." },
        },
        .returns = "does not return",
        .errors = &.{E.inval},
        .notes = "Unmounts every filesystem and flushes every device before acting. FAT has no journal, so this is the only way to guarantee written data reached the medium.",
    },
    .{
        .number = 9,
        .name = "sysinfo",
        .summary = "Read a named piece of system information.",
        .args = &.{
            .{ .name = "key", .kind = .cptr, .desc = "Key name, e.g. \"cpu\", \"mem\", \"board\", \"smbios\"." },
            .{ .name = "key_len", .kind = .len, .desc = "Length of the key." },
            .{ .name = "buf", .kind = .ptr, .desc = "Where the value is written." },
            .{ .name = "buf_len", .kind = .len, .desc = "Capacity of the buffer." },
        },
        .returns = "bytes written",
        .errors = &.{ E.fault, E.inval },
        .notes = "Values are text, except \"smbios\" which returns the raw DMI structure table for a userspace decoder. A keyed interface rather than a struct, so adding a value is not an ABI break.",
    },
};

// Numbers must be unique and contiguous from zero: the dispatcher indexes the
// table directly, and a gap would silently dispatch the wrong call.
comptime {
    for (table, 0..) |sc, i| {
        if (sc.number != i) @compileError(
            "syscall table must be contiguous and in order; entry '" ++ sc.name ++ "' is out of place",
        );
    }
}

pub fn find(name: []const u8) ?Syscall {
    for (table) |sc| {
        if (std.mem.eql(u8, sc.name, name)) return sc;
    }
    return null;
}
