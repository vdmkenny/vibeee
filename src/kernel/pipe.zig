//! Pipes: a byte stream between two processes.
//!
//! What a terminal emulator needs and nothing else does yet. It holds one end
//! of a pipe and hands the other to the shell it starts, which is how a shell
//! that knows only about standard input and output ends up talking to a
//! window.
//!
//! No pty. A pseudo-terminal is a pipe plus line discipline plus window-size
//! signalling, and of those only the pipe belongs in the kernel: the line
//! discipline is the terminal's own business, and there are no signals to
//! deliver a resize with. `design/10-gui.md` §16.
//!
//! Readability is exposed as an `Event`, so a process waiting on a pipe and on
//! its window's event ring has one blocking call rather than two threads. That
//! is the same reason `wait_many` exists at all.

const event_mod = @import("event.zig");
const hal = @import("hal.zig");
const heap = @import("heap.zig");
const wait = @import("wait.zig");

pub const Error = error{ OutOfMemory, Broken };

/// One page. Big enough that a shell's output does not stall on every line,
/// small enough that a terminal holding two of them is not worth counting.
pub const CAPACITY = 4096;

pub const Pipe = struct {
    buf: [CAPACITY]u8 = @splat(0),
    /// Where the next byte is read from, and how many are in the ring. A count
    /// rather than a second index, so full and empty are not the same state.
    head: usize = 0,
    len: usize = 0,

    /// Handles open on each end. A read with no writers left is end of file; a
    /// write with no readers left is an error, which is what stops a program
    /// from filling a pipe nobody will ever drain.
    readers: u32 = 0,
    writers: u32 = 0,

    /// Signalled while there is something to read, or nothing ever again.
    /// Level triggered, re-armed on every change, so a waiter that consumed the
    /// count without draining the pipe finds it set again.
    readable: event_mod.Event = .{},
    /// Signalled while there is room.
    writable: event_mod.Event = .{},

    refs: u32 = 0,

    pub fn readableNow(self: *const Pipe) bool {
        return self.len > 0 or self.writers == 0;
    }

    /// Bring the two events into line with the state. Called after anything
    /// that changes it, which is what makes them level triggered.
    fn rearm(self: *Pipe) void {
        if (self.readableNow()) {
            if (self.readable.count == 0) self.readable.signalLocked();
        } else {
            self.readable.count = 0;
        }

        if (self.len < CAPACITY or self.readers == 0) {
            if (self.writable.count == 0) self.writable.signalLocked();
        } else {
            self.writable.count = 0;
        }
    }

    /// Take up to `out.len` bytes, blocking until there are some.
    ///
    /// Returns 0 only at end of file: every writer has closed and the ring is
    /// empty. A short read is normal and means the writer has not caught up.
    pub fn read(self: *Pipe, out: []u8) Error!usize {
        const flags = hal.saveAndDisableInterrupts();
        defer hal.restoreInterrupts(flags);

        while (self.len == 0) {
            if (self.writers == 0) return 0;
            _ = wait.blockOn(&.{&self.readable.queue}, null) catch return error.Broken;
        }

        const n = @min(out.len, self.len);
        for (0..n) |i| {
            out[i] = self.buf[(self.head + i) % CAPACITY];
        }
        self.head = (self.head + n) % CAPACITY;
        self.len -= n;

        self.rearm();
        return n;
    }

    /// Take what is there without blocking. For a caller that is waiting on
    /// several things at once and has already been told this one is ready.
    pub fn readNow(self: *Pipe, out: []u8) usize {
        const flags = hal.saveAndDisableInterrupts();
        defer hal.restoreInterrupts(flags);

        const n = @min(out.len, self.len);
        for (0..n) |i| {
            out[i] = self.buf[(self.head + i) % CAPACITY];
        }
        self.head = (self.head + n) % CAPACITY;
        self.len -= n;

        self.rearm();
        return n;
    }

    /// Write all of `bytes`, blocking while the ring is full.
    ///
    /// All or nothing on the caller's behalf rather than a short write: every
    /// caller here would loop anyway, and the loop belongs in one place.
    pub fn write(self: *Pipe, bytes: []const u8) Error!usize {
        const flags = hal.saveAndDisableInterrupts();
        defer hal.restoreInterrupts(flags);

        var written: usize = 0;
        while (written < bytes.len) {
            if (self.readers == 0) return if (written > 0) written else error.Broken;

            while (self.len == CAPACITY) {
                if (self.readers == 0) return if (written > 0) written else error.Broken;
                _ = wait.blockOn(&.{&self.writable.queue}, null) catch return error.Broken;
            }

            const room = CAPACITY - self.len;
            const n = @min(bytes.len - written, room);
            for (0..n) |i| {
                self.buf[(self.head + self.len + i) % CAPACITY] = bytes[written + i];
            }
            self.len += n;
            written += n;

            self.rearm();
        }

        return written;
    }
};

// ---------------------------------------------------------------------------
// Lifetime
// ---------------------------------------------------------------------------

/// Create a pipe with one reader and one writer already counted, which is the
/// pair of handles the caller is about to be given.
pub fn create() Error!*Pipe {
    const p = heap.allocator.create(Pipe) catch return error.OutOfMemory;
    p.* = .{ .readers = 1, .writers = 1, .refs = 2 };
    p.rearm();
    return p;
}

pub fn retain(p: *Pipe, is_writer: bool) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    p.refs += 1;
    if (is_writer) p.writers += 1 else p.readers += 1;
    p.rearm();
}

pub fn release(p: *Pipe, is_writer: bool) void {
    const flags = hal.saveAndDisableInterrupts();

    if (is_writer) {
        p.writers -= 1;
    } else {
        p.readers -= 1;
    }

    // Whoever is left has to be told: a reader blocked on a pipe whose last
    // writer just closed is waiting for an end of file that has already
    // happened, and would wait forever.
    p.rearm();
    _ = p.readable.queue.wakeAll();
    _ = p.writable.queue.wakeAll();

    p.refs -= 1;
    const dead = p.refs == 0;
    hal.restoreInterrupts(flags);

    if (dead) heap.allocator.destroy(p);
}
