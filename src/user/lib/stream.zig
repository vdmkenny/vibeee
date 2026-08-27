//! A buffered stream over a handle.
//!
//! Every read and every write is a syscall, so doing either a byte at a time
//! costs a trap per byte. This is the buffer that stops that, and it is here
//! rather than in the C library because a program written in Zig should be
//! able to do everything a program written in C can: `FILE` is a C-shaped door
//! onto this, not a second implementation of it.
//!
//! The buffer belongs to whoever makes the stream. Standard output has a
//! static one because it exists before anything can allocate; a file opened by
//! a program has one from the heap. Neither is this module's business, which
//! is why it takes a slice rather than finding memory of its own.

const sys = @import("sys");

pub const Buffering = enum {
    /// Written out when a line ends. What a terminal wants: a prompt with no
    /// newline after it still has to appear.
    line,
    /// Written out when the buffer fills. What a file wants.
    full,
    /// Written out immediately. What a diagnostic wants, because a program
    /// that crashes should not take its last words with it.
    none,
};

pub const Stream = struct {
    handle: u32,
    buffer: []u8,

    /// How much of the buffer is in use, and how far through it reading has
    /// got. A stream holds bytes waiting to go out or bytes read in, never
    /// both: `writing` says which.
    used: usize = 0,
    at: usize = 0,
    writing: bool = false,

    buffering: Buffering = .full,
    at_end: bool = false,
    failed: bool = false,

    pub fn init(handle: u32, buffer: []u8, buffering: Buffering) Stream {
        return .{ .handle = handle, .buffer = buffer, .buffering = buffering };
    }

    // -----------------------------------------------------------------------
    // Out
    // -----------------------------------------------------------------------

    /// Where writing stands, for a caller that may yet take back what it is
    /// about to write. Only meaningful until something flushes.
    pub fn mark(self: *Stream) usize {
        return if (self.writing) self.used else 0;
    }

    /// Drop everything written since `mark`. A line that was decided against
    /// costs nothing, provided it stayed within the buffer.
    pub fn rewind(self: *Stream, to: usize) void {
        if (self.writing and self.used >= to) self.used = to;
    }

    pub fn flush(self: *Stream) void {
        if (!self.writing or self.used == 0) return;

        if (sys.write(self.handle, self.buffer[0..self.used]) < 0) self.failed = true;
        self.used = 0;
    }

    pub fn writeByte(self: *Stream, byte: u8) void {
        self.beginWriting();

        if (self.buffering == .none or self.buffer.len == 0) {
            const one = [_]u8{byte};
            if (sys.write(self.handle, &one) < 0) self.failed = true;
            return;
        }

        self.buffer[self.used] = byte;
        self.used += 1;

        if (self.used == self.buffer.len or (self.buffering == .line and byte == '\n')) {
            self.flush();
        }
    }

    /// Copies in runs rather than byte at a time: the common case is a whole
    /// word or line, and a per-byte loop makes every string cost its length in
    /// branches.
    pub fn write(self: *Stream, bytes: []const u8) void {
        if (self.buffering == .none or self.buffer.len == 0) {
            self.beginWriting();
            if (sys.write(self.handle, bytes) < 0) self.failed = true;
            return;
        }

        var rest = bytes;
        while (rest.len > 0) {
            self.beginWriting();

            const space = self.buffer.len - self.used;
            if (space == 0) {
                self.flush();
                continue;
            }

            const run = rest[0..@min(space, rest.len)];
            @memcpy(self.buffer[self.used..][0..run.len], run);
            self.used += run.len;
            rest = rest[run.len..];

            const full = self.used == self.buffer.len;
            if (full or (self.buffering == .line and endsALine(run))) self.flush();
        }
    }

    fn endsALine(run: []const u8) bool {
        for (run) |c| {
            if (c == '\n') return true;
        }
        return false;
    }

    /// A stream that was reading has to forget what it read before it writes:
    /// the buffer holds one thing at a time.
    fn beginWriting(self: *Stream) void {
        if (self.writing) return;
        self.used = 0;
        self.at = 0;
        self.writing = true;
    }

    // -----------------------------------------------------------------------
    // In
    // -----------------------------------------------------------------------

    /// The next byte, or null at the end of the stream.
    pub fn readByte(self: *Stream) ?u8 {
        if (self.writing) {
            self.flush();
            self.writing = false;
        }

        if (self.at == self.used and !self.fill()) return null;

        const byte = self.buffer[self.at];
        self.at += 1;
        return byte;
    }

    fn fill(self: *Stream) bool {
        if (self.buffer.len == 0) return false;

        const n = sys.read(self.handle, self.buffer);
        if (n <= 0) {
            if (n == 0) self.at_end = true else self.failed = true;
            return false;
        }

        self.used = @intCast(n);
        self.at = 0;
        return true;
    }

    /// Fill `into` from the stream, stopping at the end. Returns how much.
    pub fn read(self: *Stream, into: []u8) usize {
        var n: usize = 0;
        while (n < into.len) : (n += 1) {
            into[n] = self.readByte() orelse break;
        }
        return n;
    }

    /// One line into `into`, without the newline. Null at the end of the
    /// stream with nothing read.
    ///
    /// A line longer than the buffer is cut, and the rest of it is the next
    /// line: a caller with a fixed buffer has no better answer available, and
    /// silently dropping the tail would be worse than returning it.
    pub fn readLine(self: *Stream, into: []u8) ?[]u8 {
        var n: usize = 0;
        while (n < into.len) {
            const byte = self.readByte() orelse break;
            if (byte == '\n') return into[0..n];

            into[n] = byte;
            n += 1;
        }
        return if (n == 0) null else into[0..n];
    }
};
