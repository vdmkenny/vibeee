//! Per-process handle table.
//!
//! Handles are small integers indexing a per-process table, not pointers.
//! Userspace therefore cannot name a kernel object it was not given, and a
//! stale handle is a lookup failure rather than a wild dereference, the same
//! reasoning as file descriptors, for the same reasons.
//!
//! Rights are carried per handle rather than per object, so the same file can
//! be handed to one process readable and another writable. Nothing uses that
//! yet; it is here because retrofitting rights onto an established handle table
//! means auditing every call site.

const std = @import("std");
const channel_mod = @import("channel.zig");
const clock = @import("clock.zig");
const event_mod = @import("event.zig");
const fat = @import("fat.zig");
const shm_mod = @import("shm.zig");
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

pub const Kind = enum { none, console, file, directory, event, channel, shm };

pub const File = struct {
    /// Resolved at open and kept, so a later unmount cannot leave the handle
    /// pointing at a volume that is gone.
    mount: *vfs.Mount,
    entry: fat.Entry,
    offset: u64 = 0,
    /// Every write goes to the end of the file, whatever the offset says.
    append: bool = false,
    /// Something has been written that the directory entry does not know
    /// about yet. The entry is written back once, when the handle closes,
    /// rather than on every write: rewriting a directory sector per call would
    /// cost more than the data write and wear the SSD for nothing.
    dirty: bool = false,
};

pub const Directory = struct {
    mount: *vfs.Mount,
    iterator: fat.Iterator,
    /// Set once the iterator has run out, so repeated reads stay cheap.
    exhausted: bool = false,
};

pub const ChannelRef = struct {
    channel: *channel_mod.Channel,
    /// True for the handle that answers calls. Exactly one end serves, and
    /// closing it is what tells waiting clients the server is gone, so which
    /// end a handle is has to be recorded, not inferred.
    serving: bool,
};

pub const Handle = struct {
    kind: Kind = .none,
    rights: Rights = .{},
    data: union {
        none: void,
        file: File,
        directory: Directory,
        event: *event_mod.Event,
        channel: ChannelRef,
        shm: *shm_mod.Segment,
    } = .{ .none = {} },
};

/// Take a second reference to whatever a handle names.
///
/// Used when a handle is duplicated into another process over a channel: the
/// number is new but the object is the same one, and it must not go away
/// because the sender closed its copy.
pub fn retain(h: Handle) Handle {
    switch (h.kind) {
        .file => h.data.file.mount.open_files += 1,
        .directory => h.data.directory.mount.open_files += 1,
        .event => event_mod.retain(h.data.event),
        .channel => channel_mod.retain(h.data.channel.channel),
        .shm => shm_mod.retain(h.data.shm),
        .none, .console => {},
    }
    return h;
}

/// Give back whatever a handle holds.
///
/// Every kind that owns a reference releases it here. Leaving a mount counted
/// would make the volume permanently un-unmountable; leaking a channel
/// reference would keep a dead server's clients blocked. The console handles
/// are shared rather than owned, so they release nothing.
pub fn release(h: Handle) void {
    switch (h.kind) {
        .file => {
            // The size and timestamp a write left in the entry only reach the
            // disk here. Deferring it to close is what keeps a sequential
            // write from rewriting a directory sector on every call; the cost
            // is that a process killed mid-write leaves a short file, which is
            // the same bargain every filesystem without a journal makes.
            const file = h.data.file;
            if (file.dirty) {
                vfs.commit(file.mount, file.entry, clock.realtimeSeconds()) catch {};
            }
            releaseMount(file.mount);
        },
        .directory => releaseMount(h.data.directory.mount),
        .event => event_mod.release(h.data.event),
        .channel => {
            const ref = h.data.channel;
            // Order matters: the clients have to be failed while the channel is
            // still alive to fail them through.
            if (ref.serving) channel_mod.stopServing(ref.channel);
            channel_mod.release(ref.channel);
        },
        .shm => shm_mod.release(h.data.shm),
        .none, .console => {},
    }
}

fn releaseMount(m: *vfs.Mount) void {
    if (m.open_files > 0) m.open_files -= 1;
}

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
        release(h.*);
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
