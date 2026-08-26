//! Per-process handle table.
//!
//! Handles are small integers indexing a per-process table, not pointers.
//! Userspace therefore cannot name a kernel object it was not given, and a
//! stale handle is a lookup failure rather than a wild dereference — the same
//! reasoning as file descriptors, for the same reasons.
//!
//! Rights are carried per handle rather than per object, so the same file can
//! be handed to one process readable and another writable. Nothing uses that
//! yet; it is here because retrofitting rights onto an established handle table
//! means auditing every call site.

const std = @import("std");
const fat = @import("fat.zig");
const vfs = @import("vfs.zig");

pub const MAX_HANDLES = 32;

/// Handles 0, 1 and 2 are the console, open in every process from the start.
pub const STDIN: u32 = 0;
pub const STDOUT: u32 = 1;
pub const STDERR: u32 = 2;
pub const FIRST_FREE: u32 = 3;

pub const Rights = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    seek: bool = false,
    _pad: u5 = 0,
};

pub const Kind = enum { none, console, file, directory };

pub const File = struct {
    /// Resolved at open and kept, so a later unmount cannot leave the handle
    /// pointing at a volume that is gone.
    mount: *vfs.Mount,
    entry: fat.Entry,
    offset: u64 = 0,
};

pub const Directory = struct {
    mount: *vfs.Mount,
    iterator: fat.Iterator,
    /// Set once the iterator has run out, so repeated reads stay cheap.
    exhausted: bool = false,
};

pub const Handle = struct {
    kind: Kind = .none,
    rights: Rights = .{},
    data: union {
        none: void,
        file: File,
        directory: Directory,
    } = .{ .none = {} },
};

pub const Table = struct {
    entries: [MAX_HANDLES]Handle = @splat(.{}),

    pub fn init(self: *Table) void {
        self.entries = @splat(.{});
        // The console is always present. A process that has closed its output
        // is a process that cannot report why it failed.
        for ([_]u32{ STDIN, STDOUT, STDERR }) |h| {
            self.entries[h] = .{
                .kind = .console,
                .rights = .{ .read = h == STDIN, .write = h != STDIN },
            };
        }
    }

    pub fn get(self: *Table, handle: u32) ?*Handle {
        if (handle >= MAX_HANDLES) return null;
        const h = &self.entries[handle];
        return if (h.kind == .none) null else h;
    }

    /// Claim the lowest free handle.
    ///
    /// Lowest rather than any: it is what shells rely on when they close a
    /// standard handle and immediately reopen it to redirect.
    pub fn alloc(self: *Table) ?u32 {
        for (self.entries[FIRST_FREE..], FIRST_FREE..) |*h, i| {
            if (h.kind == .none) return @intCast(i);
        }
        return null;
    }

    pub fn close(self: *Table, handle: u32) bool {
        const h = self.get(handle) orelse return false;

        // Releasing the mount's reference is the point: leaving it counted
        // would make the volume permanently un-unmountable. The console
        // handles are shared rather than owned, so they release nothing.
        const mount: ?*vfs.Mount = switch (h.kind) {
            .file => h.data.file.mount,
            .directory => h.data.directory.mount,
            else => null,
        };
        if (mount) |m| {
            if (m.open_files > 0) m.open_files -= 1;
        }

        h.* = .{};
        return true;
    }

    /// Release everything a dying process still holds.
    pub fn closeAll(self: *Table) void {
        for (0..MAX_HANDLES) |i| {
            _ = self.close(@intCast(i));
        }
    }
};
