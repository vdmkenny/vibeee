//! Per-process handle table.
//!
//! Handles are small integers indexing a per-process table, not pointers.
//! Userspace therefore cannot name a kernel object it was not given, and a
//! stale handle is a lookup failure rather than a wild dereference, the same
//! reasoning as file descriptors, for the same reasons.
//!
//! Rights are carried per handle rather than per object, so the same file can
//! be open readable in one process and writable in another. A write to a
//! handle without the write right fails whatever the underlying object would
//! have allowed.

const channel_mod = @import("channel.zig");
const clock = @import("clock.zig");
const display_mod = @import("display.zig");
const event_mod = @import("event.zig");
const fat = @import("fat.zig");
const heap = @import("heap.zig");
const irqevent = @import("irqevent.zig");
const pipe_mod = @import("pipe.zig");
const sched = @import("sched.zig");
const shm_mod = @import("shm.zig");
const vfs = @import("vfs.zig");

/// How many things one process may hold open at once.
///
/// Sized for a process that hosts an interpreter. `platd` runs the firmware's
/// own bytecode, and the firmware decides how many synchronisation objects its
/// tables ask for: that count belongs to the machine rather than to this
/// system, and sits on top of the files, channels and events the process holds
/// for its own reasons.
pub const MAX_HANDLES = 64;

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

pub const Kind = enum { none, console, file, directory, event, channel, shm, display, pipe, irq };

pub const File = struct {
    /// The mount this opened on, as a lease rather than a pointer: the slot
    /// outlives the volume, and a file must not follow the slot to whatever
    /// is mounted there next.
    lease: vfs.Lease,
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
    /// The mount this was opened on, as a lease: see `File`.
    lease: vfs.Lease,
    /// A mount root, which has no parent to report.
    at_root: bool = false,
    /// The synthetic `..` has been handed out.
    sent_parent: bool = false,
    /// Heap-allocated rather than inline.
    ///
    /// A `fat.Iterator` carries a 512-byte sector buffer, and a `Handle` is a
    /// union: inlining it would make every handle that size, a 32-entry table
    /// 140 KiB, and a channel message carrying four handles larger than the
    /// kernel stack it is built on. One pointer costs an allocation per
    /// `opendir` and saves all of that.
    iterator: *fat.Iterator,
    /// Set once the iterator has run out, so repeated reads stay cheap.
    exhausted: bool = false,
};

/// One end of a pipe. Which end is recorded rather than inferred: the counts
/// that decide end of file and a broken pipe are per end, so a handle that did
/// not know which it was could not be released correctly.
pub const PipeEnd = struct {
    pipe: *pipe_mod.Pipe,
    writer: bool,
};

pub const ChannelRef = struct {
    channel: *channel_mod.Channel,
    /// True for the handle that answers calls. Exactly one end serves, and
    /// closing it is what tells waiting clients the server is gone, so which
    /// end a handle is has to be recorded, not inferred.
    serving: bool,
};

pub const Handle = struct {
    rights: Rights = .{},
    /// What this handle is, and what it is a handle to, in one value.
    ///
    /// Tagged, so the two cannot disagree. A kind kept beside an untagged
    /// union is a convention the compiler does not know about: every reader
    /// has to check the tag and then reach into the union unchecked, and the
    /// one that forgets reads a segment pointer out of a file's offset. Here
    /// the tag is the union's own and reaching in means switching on it.
    data: Data = .none,

    pub const Data = union(Kind) {
        none: void,
        /// The terminal, which every process starts with on nought, one and
        /// two. It carries nothing: which console there is, is not a question
        /// this system has.
        console: void,
        file: File,
        directory: Directory,
        event: *event_mod.Event,
        channel: ChannelRef,
        shm: *shm_mod.Segment,
        /// The scanout buffer, held by whoever owns the screen. A separate
        /// kind from `shm` only so that closing it also hands the display
        /// back: the segment itself is an ordinary one.
        display: *shm_mod.Segment,
        pipe: PipeEnd,
        irq: *irqevent.IrqEvent,
    };

    /// What kind of thing this is, for a caller that wants to name it rather
    /// than to reach into it.
    pub fn kind(self: Handle) Kind {
        return self.data;
    }
};

/// What may cross a channel.
///
/// A pointer-sized tagged union rather than a whole `Handle`, for two reasons.
/// A `Handle` is a union over every kind, so it is as large as the largest,
/// and four of them in a message put a kilobyte and a half on a kernel stack
/// that has 16 KiB for everything. And it makes the rule explicit: an object
/// is transferable or it is not, decided here, rather than a file handle
/// silently arriving somewhere with an offset that means nothing to the
/// receiver.
pub const Transfer = struct {
    /// The rights the sender's handle carried, which are the rights the
    /// receiver's will: a handle to an event it may only wait on arrives as
    /// one it may only wait on, wherever it goes.
    rights: Rights,
    object: Object,

    pub const Object = union(enum) {
        event: *event_mod.Event,
        channel: ChannelRef,
        shm: *shm_mod.Segment,
    };
};

/// The transferable part of a handle, or null if it is not transferable.
pub fn transferable(h: Handle) ?Transfer {
    const object: Transfer.Object = switch (h.data) {
        .event => .{ .event = h.data.event },
        .channel => .{ .channel = h.data.channel },
        .shm => .{ .shm = h.data.shm },
        // Files and directories carry a position, and a position means
        // nothing to anyone else. Consoles are shared already.
        // A pipe end could cross, but nothing needs it to: a pipe reaches
        // another process by being inherited at spawn, and adding a second
        // route would be a second lifetime to get right.
        // A line belongs to the process that took it. Handing one across
        // would mean two servers believing they own a device.
        // The display belongs to the process that took it, by capability:
        // handed across, its close would hand the screen back from the
        // wrong side, and its pages would stay with the sender.
        .none, .console, .file, .directory, .pipe, .irq, .display => return null,
    };
    return .{ .rights = h.rights, .object = object };
}

/// Rebuild a handle from something that arrived over a channel.
pub fn fromTransfer(t: Transfer) Handle {
    return .{
        .rights = t.rights,
        .data = switch (t.object) {
            .event => |e| .{ .event = e },
            .channel => |c| .{ .channel = c },
            .shm => |seg| .{ .shm = seg },
        },
    };
}

pub fn retainTransfer(t: Transfer) Transfer {
    switch (t.object) {
        .event => |e| event_mod.retain(e),
        .channel => |c| channel_mod.retain(c.channel),
        .shm => |seg| shm_mod.retain(seg),
    }
    return t;
}

pub fn releaseTransfer(t: Transfer) void {
    switch (t.object) {
        .event => |e| event_mod.release(e),
        .channel => |c| channel_mod.release(c.channel),
        .shm => |seg| shm_mod.release(seg),
    }
}

/// Allocate an iterator for a directory handle.
pub fn newIterator(it: fat.Iterator) ?*fat.Iterator {
    const out = heap.allocator.create(fat.Iterator) catch return null;
    out.* = it;
    return out;
}

/// Take a second reference to whatever a handle names.
///
/// Used when a handle is duplicated into another process over a channel: the
/// number is new but the object is the same one, and it must not go away
/// because the sender closed its copy.
pub fn retain(h: Handle) Handle {
    switch (h.data) {
        // The count is owed to the slot rather than to the volume: it is what
        // keeps the slot from being given away while this handle names it,
        // whether or not the volume is still there.
        .file => h.data.file.lease.slotOf().open_files += 1,
        // A directory handle owns its iterator, so duplicating one would need
        // a copy of it. Nothing passes directories over a channel, and doing
        // so would need that decided rather than defaulted.
        .directory => h.data.directory.lease.slotOf().open_files += 1,
        .event => event_mod.retain(h.data.event),
        .channel => channel_mod.retain(h.data.channel.channel),
        .shm => shm_mod.retain(h.data.shm),
        .display => shm_mod.retain(h.data.display),
        .pipe => pipe_mod.retain(h.data.pipe.pipe, h.data.pipe.writer),
        .irq => irqevent.retain(h.data.irq),
        .none, .console => {},
    }
    return h;
}

/// Give back whatever a handle holds.
///
/// Every kind that owns a reference releases it here. Leaving a mount counted
/// would make the volume permanently un-unmountable; leaking a channel
/// reference would keep a dead server's clients blocked. The console handles
/// are shared rather than owned, so they release nothing. A file whose last
/// write could not reach its record says so, since a close that reported
/// success over a size the disk does not know would be a lie about the file.
pub fn release(h: Handle) vfs.Error!void {
    switch (h.data) {
        .file => {
            // The size and timestamp a write left in the entry only reach the
            // disk here. Deferring it to close is what keeps a sequential
            // write from rewriting a directory sector on every call; the cost
            // is that a process killed mid-write leaves a short file, which is
            // the same bargain every filesystem without a journal makes.
            const file = h.data.file;
            // The mount is let go whatever the record said: the handle is
            // gone either way.
            defer releaseMount(file.lease.slotOf());
            // Only while the volume is still there: a size committed to a
            // slot another volume has since taken would be written into it.
            if (file.dirty) {
                if (file.lease.mount()) |m| try vfs.commit(m, file.entry, clock.realtimeSeconds());
            }
        },
        .directory => {
            releaseMount(h.data.directory.lease.slotOf());
            heap.allocator.destroy(h.data.directory.iterator);
        },
        .event => event_mod.release(h.data.event),
        .channel => {
            const ref = h.data.channel;
            // Order matters: the clients have to be failed while the channel is
            // still alive to fail them through.
            if (ref.serving) channel_mod.stopServing(ref.channel);
            channel_mod.release(ref.channel);
        },
        .shm => shm_mod.release(h.data.shm),
        .display => {
            // The pages that showed the screen go with the handle: a process
            // that has handed the display back must not still be writing to
            // its scanout memory.
            const seg = h.data.display;
            if (sched.currentThread()) |t| t.shm_window.revoke(seg, &t.space);
            shm_mod.release(seg);
            display_mod.release();
        },
        .pipe => pipe_mod.release(h.data.pipe.pipe, h.data.pipe.writer),
        .irq => irqevent.release(h.data.irq),
        .none, .console => {},
    }
}

fn releaseMount(m: *vfs.Mount) void {
    if (m.open_files > 0) m.open_files -= 1;
}

comptime {
    // Every thread carries a table, so its size is per-process overhead on a
    // machine with 512 MB. A `Handle` that grew without anyone noticing would
    // multiply by 32 here and again by the thread count.
    if (@sizeOf(Handle) > 256) @compileError("Handle has grown; the table is per-process");
}

pub const Table = struct {
    entries: [MAX_HANDLES]Handle = @splat(.{}),

    pub fn init(self: *Table) void {
        self.entries = @splat(.{});
        // The console is always present. A process that has closed its output
        // is a process that cannot report why it failed.
        for ([_]u32{ STDIN, STDOUT, STDERR }) |h| {
            self.entries[h] = .{
                .rights = .{ .read = h == STDIN, .write = h != STDIN },
                .data = .console,
            };
        }
    }

    pub fn get(self: *Table, handle: u32) ?*Handle {
        if (handle >= MAX_HANDLES) return null;
        const h = &self.entries[handle];
        return if (h.data == .none) null else h;
    }

    /// Claim the lowest free handle.
    ///
    /// Lowest rather than any: it is what shells rely on when they close a
    /// standard handle and immediately reopen it to redirect.
    pub fn alloc(self: *Table) ?u32 {
        for (self.entries[FIRST_FREE..], FIRST_FREE..) |*h, i| {
            if (h.data == .none) return @intCast(i);
        }
        return null;
    }

    pub const CloseError = error{BadHandle} || vfs.Error;

    /// Close a handle. The slot is freed whatever the release could not
    /// write: a handle closes once, and what it failed to put on the disk is
    /// reported rather than kept open.
    pub fn close(self: *Table, handle: u32) CloseError!void {
        const h = self.get(handle) orelse return error.BadHandle;
        const closing = h.*;
        h.* = .{};
        try release(closing);
    }

    /// Release everything a dying process still holds. Nobody is left to
    /// tell what could not be written.
    pub fn closeAll(self: *Table) void {
        for (0..MAX_HANDLES) |i| {
            self.close(@intCast(i)) catch {};
        }
    }
};
