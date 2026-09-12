//! script_host: where a page's scripts run, and what the reader does when
//! they stop.
//!
//! The reader has always run a page's scripts in its own address space: the
//! engine, the document built over lexbor and the C under both are compiled
//! into it, and a fault in any of the three reaches the kernel as a fault in
//! the reader. design/13-script-worker.md moves them into a process of their
//! own. This is the seam they move across: one type the reader speaks to,
//! whichever side of the boundary the scripts happen to be on.
//!
//! Two hosts of one shape:
//!
//!   - `in_process`, the default: no process, no channel, nothing here that
//!     can fail. Every call does nothing, and the reader is exactly the
//!     reader it was before this file existed.
//!
//!   - `worker`: a program of the reader's own, started for a committed
//!     navigation and killed on the next (§6), spoken to in `worker_proto`
//!     frames over a channel. What it owns is what a page can corrupt, so
//!     what a page can kill is the worker and not the reader.
//!
//! `-Dscript-worker` chooses between them at build time, and nothing else in
//! the reader changes: that is what keeps the move reversible (§9).
//!
//! What is *not* here yet: a `page` is not serialized (§11), so a page a
//! worker sends back is not read into the page on screen, and today's worker
//! has no engine in it to change one. What is here is the part that has to
//! be right before any of that is worth writing — the lifecycle, the
//! channel, and what happens when the far end of the channel goes away,
//! which is the whole guarantee: a dead worker costs a page its scripts and
//! nothing else (§7). The reader keeps the page it drew, and says so.
//!
//! Nothing here makes a syscall. The machine is handed in as a `Platform`:
//! start a program, end it, move bytes. That is what lets the lifecycle and
//! the fault handling be tested on this machine, where there is no worker to
//! run and no kernel to fault in.

const std = @import("std");
const worker_proto = @import("worker_proto");

// ---------------------------------------------------------------------------
// The machine underneath
// ---------------------------------------------------------------------------

/// Which side of the boundary a page's scripts are on.
pub const Kind = enum {
    /// In the reader, where they have always run.
    in_process,
    /// In a process of the reader's own.
    worker,
};

/// What the reader says of a page's scripts while the page is on screen.
pub const Status = enum {
    /// Nothing is running elsewhere for this page, and nothing has stopped:
    /// the reader runs a page's scripts itself, or runs none.
    none,
    /// A worker is up and has the page's scripts.
    running,
    /// The worker is gone, and not because the reader let it go. The page on
    /// screen is kept; what stopped is its scripts (§7).
    stopped,
};

/// Why a worker is no longer running: `worker_proto.StopReason`, which is
/// also what a worker says for itself on its way out.
pub const Reason = worker_proto.StopReason;

/// A worker: its process, and the two ends of the channel to it.
pub const Child = struct {
    pid: u32,
    /// What the reader writes to and the worker reads from.
    to: u32,
    /// What the worker writes to and the reader reads from.
    from: u32,
};

/// What a read of the channel says.
pub const Read = union(enum) {
    /// Nothing waiting. Asked again later.
    none,
    /// This many bytes were put in the buffer. Fewer than were asked for is
    /// a short read, which is ordinary: a frame arrives in pieces.
    some: usize,
    /// The far end is gone: end of file, which is a worker that has ended.
    gone,
};

/// What a write to the channel says.
pub const Wrote = union(enum) {
    /// This many bytes were taken. Fewer than were given is a short write,
    /// and the rest stays owed.
    some: usize,
    /// No room for them now, and no waiting for it: a reader that blocked on
    /// a worker that was blocked in turn would be two processes holding each
    /// other still, which is what `eterm`'s own queue exists to avoid.
    full,
    /// Nothing is reading any more.
    gone,
};

/// Why a worker could not be started.
pub const SpawnError = error{Refused};

/// What a host asks of the machine, and all of it. Handed in rather than
/// reached for, so that a host can be run on a machine with no kernel under
/// it and no worker to start.
pub const Platform = struct {
    /// What the calls are made on, given back to each of them.
    ptr: *anyopaque = undefined,

    /// Start the worker, with the two ends of a channel to it already made.
    spawn: *const fn (*anyopaque) SpawnError!Child = neverSpawned,
    /// End it, whether it has ended already or not.
    kill: *const fn (*anyopaque, u32) void = nothingHappens,
    /// Give one end of the channel back.
    close: *const fn (*anyopaque, u32) void = nothingHappens,
    /// Write towards the worker. Never waits: what does not fit is owed.
    write: *const fn (*anyopaque, u32, []const u8) Wrote = wroteToNobody,
    /// Read from the worker. Never waits: `none` means ask again.
    read: *const fn (*anyopaque, u32, []u8) Read = readFromNobody,
    /// Whether the process has ended, after waiting `us` for it to. Asking
    /// is what collects it: a worker gone and not collected is a process the
    /// machine still keeps a place for.
    ended: *const fn (*anyopaque, u32, usize) bool = endedAlready,
};

fn neverSpawned(_: *anyopaque) SpawnError!Child {
    return error.Refused;
}
fn nothingHappens(_: *anyopaque, _: u32) void {}
fn wroteToNobody(_: *anyopaque, _: u32, _: []const u8) Wrote {
    return .gone;
}
fn readFromNobody(_: *anyopaque, _: u32, _: []u8) Read {
    return .gone;
}
fn endedAlready(_: *anyopaque, _: u32, _: usize) bool {
    return true;
}

// ---------------------------------------------------------------------------
// The host
// ---------------------------------------------------------------------------

/// How long a worker is given to go, having been asked. Long enough for one
/// that is ending anyway, short enough that a page is not kept waiting by
/// one that is not: the reader moves on either way.
const GRACE_US: usize = 20_000;

/// How many times in a row the channel may say there is no room before the
/// worker is taken to have stopped listening. A worker in the middle of a
/// page takes a frame in pieces and says "no room" in between, so what
/// counts is a queue that has not moved at all, and not one that is slow.
const STALL_LIMIT: usize = 64;

pub const Host = struct {
    kind: Kind = .in_process,
    platform: Platform = .{},

    /// Where the two buffers came from, and where they go back to.
    gpa: std.mem.Allocator = undefined,

    /// What the worker has been told and has not taken yet. A frame is a
    /// stream of bytes, so half of one owed is not a frame cut in two: the
    /// rest goes when there is room for it.
    out: []u8 = &.{},
    out_at: usize = 0,
    out_len: usize = 0,
    /// What the worker has said and the reader has not read yet.
    in: []u8 = &.{},
    in_at: usize = 0,
    in_len: usize = 0,
    /// How many times running the queue has not moved.
    stalled: usize = 0,

    /// The worker, while there is one.
    child: ?Child = null,
    /// Whether it is over: gone, or never started for this page.
    finished: bool = false,
    /// Why. `.fault` is the one the reader says out loud; the others are
    /// moves of its own (§7).
    why: Reason = .asked,

    // -------------------------------------------------------------------
    // Which host this is
    // -------------------------------------------------------------------

    /// A host that runs a page's scripts where the reader has always run
    /// them: in it. Nothing is ever asked of the machine.
    pub fn inProcess() Host {
        return .{ .kind = .in_process };
    }

    /// A host that runs them in a process of the reader's own.
    pub fn forWorker(platform: Platform, gpa: std.mem.Allocator) Host {
        return .{ .kind = .worker, .platform = platform, .gpa = gpa };
    }

    /// Whether the host, rather than the reader, has a page's scripts. The
    /// reader asks before opening them itself, so they are never run in both
    /// places at once.
    pub fn owns(self: *const Host) bool {
        return self.kind == .worker;
    }

    /// What the reader may sleep on beside its own business: the worker's end
    /// of the channel, ready when it has said something or gone.
    pub fn handle(self: *const Host) ?u32 {
        return if (self.child) |child| child.from else null;
    }

    pub fn status(self: *const Host) Status {
        if (!self.owns()) return .none;
        if (self.child != null) return .running;
        return if (self.finished and self.why == .fault) .stopped else .none;
    }

    // -------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------

    pub const BeginError = SpawnError || SendError;

    /// Give a worker the page: one per committed navigation, the one before
    /// it killed as this one starts (§6).
    ///
    /// A page whose scripts will not start is a page whose scripts have
    /// stopped, and is marked as one rather than tried again: a worker that
    /// dies on start is not started in a loop (§7). The next navigation is
    /// the retry.
    pub fn begin(self: *Host, start: worker_proto.Start) BeginError!void {
        if (!self.owns()) return;
        self.stop(.asked);

        if (self.out.len == 0) {
            self.out = self.gpa.alloc(u8, worker_proto.MAX_FRAME) catch return error.Refused;
            self.in = self.gpa.alloc(u8, worker_proto.MAX_FRAME) catch {
                self.gpa.free(self.out);
                self.out = &.{};
                return error.Refused;
            };
        }
        self.discard();
        self.finished = false;
        self.why = .asked;

        self.child = self.platform.spawn(self.platform.ptr) catch |err| {
            self.finished = true;
            self.why = .fault;
            return err;
        };
        // A worker is of no use until it has the page, so a page it cannot
        // be given is the same as one that would not start.
        self.send(.{ .start = start }) catch |err| {
            self.stop(.fault);
            return err;
        };
    }

    /// Let the worker go: asked first, then ended, then its ends of the
    /// channel given back (§6). `why` is what the reader says of it to
    /// itself; `.fault` is the one it says to a person, and says that the
    /// asking has already been overtaken.
    pub fn stop(self: *Host, why: Reason) void {
        if (!self.owns()) return;
        if (why != .fault and self.child != null) {
            self.send(.{ .stop = {} }) catch {};
            self.flush();
        }
        self.teardown();
        self.finished = true;
        self.why = why;
    }

    pub fn deinit(self: *Host) void {
        self.stop(.asked);
        if (self.out.len > 0) self.gpa.free(self.out);
        if (self.in.len > 0) self.gpa.free(self.in);
        self.out = &.{};
        self.in = &.{};
    }

    /// End it and give back what it held, if there is anything left to give
    /// back: a worker that went on its own has none.
    fn teardown(self: *Host) void {
        if (self.child) |child| {
            if (!self.platform.ended(self.platform.ptr, child.pid, GRACE_US)) {
                self.platform.kill(self.platform.ptr, child.pid);
            }
            self.platform.close(self.platform.ptr, child.to);
            self.platform.close(self.platform.ptr, child.from);
            self.child = null;
        }
        self.discard();
    }

    /// It went without being asked: end of file, a write nobody is reading,
    /// a frame that cannot be one, a channel that stopped moving. From here
    /// these are all the same thing, and what they cost the page is its
    /// scripts (§7).
    fn died(self: *Host) void {
        self.stop(.fault);
    }

    /// Forget what was in either buffer. The page on screen is not among it:
    /// that page is the reader's own, and was never handed over.
    fn discard(self: *Host) void {
        self.out_at = 0;
        self.out_len = 0;
        self.in_at = 0;
        self.in_len = 0;
        self.stalled = 0;
    }

    // -------------------------------------------------------------------
    // The channel
    // -------------------------------------------------------------------

    /// Why something could not be said.
    pub const SendError = error{
        /// There is no worker to say it to: none was started, or it went.
        Gone,
        /// It would not fit a frame, and is refused rather than sent cut
        /// short (`worker_proto.EncodeError`).
        TooLarge,
    };

    /// Say something to the worker. Nothing is sent when the reader runs a
    /// page's scripts itself, and nothing is waited for: what the channel
    /// will not take yet stays owed and goes with the next `take`.
    pub fn send(self: *Host, message: worker_proto.Message) SendError!void {
        if (!self.owns()) return;
        if (self.child == null) return error.Gone;

        // Room behind what is still owed, for one frame of any size: the
        // frame is written straight into the queue, so this is the only
        // length there is to ask about.
        self.compact();
        self.flush();
        if (self.child == null) return error.Gone;
        self.compact();
        if (self.out_len + worker_proto.MAX_FRAME > self.out.len) return error.Gone;

        const frame = worker_proto.encode(message, self.out[self.out_len..]) catch return error.TooLarge;
        self.out_len += frame.len;
        self.flush();
    }

    /// The next thing the worker has said, or null when it has said nothing
    /// more. Moves what is owed towards it first, so a host that is only
    /// pumped by `take` still gets its messages out.
    pub fn take(self: *Host) ?worker_proto.Message {
        if (!self.owns() or self.child == null) return null;
        self.flush();
        if (self.child == null) return null;
        self.fill();

        const waiting = self.in[self.in_at..self.in_len];
        const total = worker_proto.frameLen(waiting) catch |err| return switch (err) {
            error.Truncated => null,
            error.TooLarge => {
                // It claims more than a frame can hold, so it is not one.
                self.died();
                return null;
            },
        };
        const message = worker_proto.decode(waiting[0..total]) catch {
            // A tag nobody named, or a field that cannot be: from a worker
            // that has already gone wrong.
            self.died();
            return null;
        };

        self.in_at += total;
        if (self.in_at == self.in_len) {
            self.in_at = 0;
            self.in_len = 0;
        }
        // A worker that says it is going has gone, whatever its process is
        // still doing.
        if (message == .stopped) self.stop(message.stopped.reason);
        return message;
    }

    /// Give the worker what it is owed, as far as the channel will take it.
    fn flush(self: *Host) void {
        const child = self.child orelse return;
        while (self.out_at < self.out_len) {
            switch (self.platform.write(self.platform.ptr, child.to, self.out[self.out_at..self.out_len])) {
                .some => |n| {
                    if (n == 0) return;
                    self.out_at += n;
                    self.stalled = 0;
                },
                .full => {
                    // Nothing moved. A worker taking a long frame in pieces
                    // says this between the pieces, so it is a queue that
                    // has not moved at all that is given up on.
                    self.stalled += 1;
                    if (self.stalled >= STALL_LIMIT) self.died();
                    return;
                },
                .gone => {
                    self.died();
                    return;
                },
            }
        }
        self.out_at = 0;
        self.out_len = 0;
    }

    /// Take in what the worker has said, as much as there is.
    fn fill(self: *Host) void {
        const child = self.child orelse return;
        if (self.in_len == self.in.len) {
            if (self.in_at == 0) {
                // A whole buffer of nothing readable: no frame is that long.
                self.died();
                return;
            }
            std.mem.copyForwards(u8, self.in, self.in[self.in_at..self.in_len]);
            self.in_len -= self.in_at;
            self.in_at = 0;
        }
        switch (self.platform.read(self.platform.ptr, child.from, self.in[self.in_len..])) {
            .none => {},
            .some => |n| self.in_len += n,
            .gone => self.died(),
        }
    }

    /// Move what is still owed to the front of the queue.
    fn compact(self: *Host) void {
        if (self.out_at == 0) return;
        std.mem.copyForwards(u8, self.out, self.out[self.out_at..self.out_len]);
        self.out_len -= self.out_at;
        self.out_at = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A worker that is two byte buffers and a few counts: what the host needs
/// of a kernel, on a machine with no kernel.
const Fake = struct {
    /// Everything the reader has said to it.
    said: [worker_proto.MAX_FRAME]u8 = @splat(0),
    said_len: usize = 0,
    /// What it says back, a read at a time.
    says: []const u8 = "",
    at: usize = 0,
    /// How much of what it has to say it parts with at once, 0 for all.
    chunk: usize = 0,
    /// Its end of the channel is gone: end of file, and nobody reading.
    gone: bool = false,
    /// It takes nothing in: a worker the reader cannot talk to.
    deaf: bool = false,
    /// It will not start at all.
    refuses: bool = false,

    spawned: usize = 0,
    killed: usize = 0,
    closed: usize = 0,
    alive: bool = false,

    fn platform(self: *Fake) Platform {
        return .{
            .ptr = self,
            .spawn = spawn,
            .kill = kill,
            .close = close,
            .write = write,
            .read = read,
            .ended = ended,
        };
    }

    fn spawn(ptr: *anyopaque) SpawnError!Child {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        if (self.refuses) return error.Refused;
        self.spawned += 1;
        self.alive = true;
        return .{ .pid = 1, .to = 2, .from = 3 };
    }

    fn kill(ptr: *anyopaque, _: u32) void {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        self.killed += 1;
        self.alive = false;
    }

    fn close(ptr: *anyopaque, _: u32) void {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        self.closed += 1;
    }

    fn write(ptr: *anyopaque, _: u32, bytes: []const u8) Wrote {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        if (self.gone) return .gone;
        if (self.deaf) return .full;
        const n = @min(bytes.len, self.said.len - self.said_len);
        @memcpy(self.said[self.said_len..][0..n], bytes[0..n]);
        self.said_len += n;
        return .{ .some = n };
    }

    fn read(ptr: *anyopaque, _: u32, into: []u8) Read {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        if (self.gone) return .gone;
        if (self.at >= self.says.len) return .none;
        const most = if (self.chunk == 0) into.len else self.chunk;
        const n = @min(@min(into.len, most), self.says.len - self.at);
        @memcpy(into[0..n], self.says[self.at..][0..n]);
        self.at += n;
        return .{ .some = n };
    }

    fn ended(ptr: *anyopaque, _: u32, _: usize) bool {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        return !self.alive;
    }

    /// The frames it was sent, one after another.
    fn frames(self: *const Fake) Frames {
        return .{ .bytes = self.said[0..self.said_len] };
    }

    const Frames = struct {
        bytes: []const u8,
        at: usize = 0,

        fn next(self: *Frames) ?worker_proto.Message {
            if (self.at >= self.bytes.len) return null;
            const total = worker_proto.frameLen(self.bytes[self.at..]) catch return null;
            const message = worker_proto.decode(self.bytes[self.at..][0..total]) catch return null;
            self.at += total;
            return message;
        }
    };
};

/// A host over a fake, whose buffers come from the test's allocator so that
/// one not given back is a failure.
fn hosted(fake: *Fake) Host {
    return .forWorker(fake.platform(), testing.allocator);
}

/// A page worth starting a worker for, small enough to say in a line.
fn aPage() worker_proto.Start {
    var sheets: worker_proto.Sheets = .{};
    sheets.add("p{margin:0}") catch unreachable;
    return .{
        .address = "https://example.be/one",
        .agent = "vibeee/0.1",
        .markup = "<html><body>one</body></html>",
        .charset = "utf-8",
        .sheets = sheets,
    };
}

/// The next thing a worker says, however many looks it takes: a frame may
/// arrive in pieces, and a host that has nothing whole yet says nothing.
fn nextSaid(host: *Host, looks: usize) ?worker_proto.Message {
    for (0..looks) |_| if (host.take()) |message| return message;
    return null;
}

/// Two frames, as a worker would put them on the channel: a page, and a word
/// about an API it could not give a script.
fn said(into: []u8) []const u8 {
    var at: usize = 0;
    at += (worker_proto.encode(.{ .page = .{ .bytes = "one" } }, into[at..]) catch unreachable).len;
    at += (worker_proto.encode(.{ .missing = .{ .text = "localStorage" } }, into[at..]) catch unreachable).len;
    return into[0..at];
}

test "a host that runs scripts itself runs nothing and asks for nothing" {
    const fake: Fake = .{};
    var host = Host.inProcess();
    defer host.deinit();

    try testing.expect(!host.owns());
    try host.begin(aPage());
    try host.send(.{ .tick = {} });
    try testing.expectEqual(@as(?worker_proto.Message, null), host.take());
    host.stop(.asked);
    try testing.expectEqual(Status.none, host.status());
    try testing.expectEqual(@as(?u32, null), host.handle());
    try testing.expectEqual(@as(usize, 0), fake.spawned);
    try testing.expectEqual(@as(usize, 0), fake.killed);
}

test "a page's worker is started and told what the page is" {
    var fake: Fake = .{};
    var host = hosted(&fake);
    defer host.deinit();

    try host.begin(aPage());

    try testing.expectEqual(@as(usize, 1), fake.spawned);
    try testing.expectEqual(Status.running, host.status());
    try testing.expectEqual(@as(?u32, 3), host.handle());

    // What crossed the channel is the page, read back as the page.
    var frames = fake.frames();
    const start = frames.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(worker_proto.Tag.start, start.tag());
    try testing.expect(worker_proto.eql(.{ .start = aPage() }, start));
    try testing.expectEqual(@as(?worker_proto.Message, null), frames.next());
}

test "what a worker says comes back as messages, one at a time" {
    var into: [128]u8 = undefined;
    var fake: Fake = .{ .says = said(&into) };
    var host = hosted(&fake);
    defer host.deinit();
    try host.begin(aPage());

    const first = host.take() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(worker_proto.Tag.page, first.tag());
    try testing.expectEqualStrings("one", first.page.bytes);

    const second = host.take() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(worker_proto.Tag.missing, second.tag());
    try testing.expectEqualStrings("localStorage", second.missing.text);

    try testing.expectEqual(@as(?worker_proto.Message, null), host.take());
    try testing.expectEqual(Status.running, host.status());
}

test "a frame that arrives in pieces is read when the last of it does" {
    var into: [128]u8 = undefined;
    // Three bytes at a time: a frame is longer than that, so it only makes a
    // message once several reads have gone by.
    var fake: Fake = .{ .says = said(&into), .chunk = 3 };
    var host = hosted(&fake);
    defer host.deinit();
    try host.begin(aPage());

    const first = nextSaid(&host, 32) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(worker_proto.Tag.page, first.tag());
    try testing.expectEqualStrings("one", first.page.bytes);

    // The rest of what it said is still there for the next one.
    const second = nextSaid(&host, 32) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(worker_proto.Tag.missing, second.tag());
    try testing.expectEqual(Status.running, host.status());
}

test "a worker that ends without a word stops a page's scripts" {
    var fake: Fake = .{};
    var host = hosted(&fake);
    defer host.deinit();
    try host.begin(aPage());
    try testing.expectEqual(Status.running, host.status());

    // It goes mid-page: no words, no warning, its end of the channel shut.
    fake.gone = true;

    // End of file: nothing to read, and no worker to say the next thing to.
    try testing.expectEqual(@as(?worker_proto.Message, null), host.take());
    try testing.expectEqual(Status.stopped, host.status());
    try testing.expectError(error.Gone, host.send(.{ .tick = {} }));
    try testing.expectEqual(@as(usize, 1), fake.killed);
}

test "a page whose scripts have stopped is not started again for that page" {
    var fake: Fake = .{};
    var host = hosted(&fake);
    defer host.deinit();
    try host.begin(aPage());
    fake.gone = true;
    _ = host.take();

    // Nothing here starts one: a worker that dies on start is not started in
    // a loop (§7). The next navigation is the retry.
    try testing.expectEqual(@as(?worker_proto.Message, null), host.take());
    try testing.expectError(error.Gone, host.send(.{ .click = .{ .control = 1 } }));
    try testing.expectEqual(@as(usize, 1), fake.spawned);

    // ...and here it is: a new page gets a new worker, which can hear.
    fake.gone = false;
    try host.begin(aPage());
    try testing.expectEqual(@as(usize, 2), fake.spawned);
    try testing.expectEqual(Status.running, host.status());
}

test "a worker that says it is going is believed" {
    var into: [128]u8 = undefined;
    var fake: Fake = .{ .says = (worker_proto.encode(.{ .stopped = .{ .reason = .asked } }, &into) catch unreachable) };
    var host = hosted(&fake);
    defer host.deinit();
    try host.begin(aPage());

    const message = host.take() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(worker_proto.Tag.stopped, message.tag());
    try testing.expectEqual(Reason.asked, message.stopped.reason);
    // Asked, so not news: the page is not marked as one whose scripts broke.
    try testing.expectEqual(Status.none, host.status());
    try testing.expectEqual(@as(?worker_proto.Message, null), host.take());
}

test "a worker that faults says so, and the page keeps its mark" {
    var into: [128]u8 = undefined;
    var fake: Fake = .{ .says = (worker_proto.encode(.{ .stopped = .{ .reason = .fault } }, &into) catch unreachable) };
    var host = hosted(&fake);
    defer host.deinit();
    try host.begin(aPage());

    try testing.expect(host.take() != null);
    try testing.expectEqual(Status.stopped, host.status());
}

test "a worker that will not start stops a page's scripts" {
    var fake: Fake = .{ .refuses = true };
    var host = hosted(&fake);
    defer host.deinit();

    try testing.expectError(error.Refused, host.begin(aPage()));
    try testing.expectEqual(Status.stopped, host.status());
    try testing.expectEqual(@as(?worker_proto.Message, null), host.take());
}

test "a worker that takes nothing in is let go rather than waited for" {
    var fake: Fake = .{ .deaf = true };
    var host = hosted(&fake);
    defer host.deinit();

    // The page is queued, which is not yet a reason to give up: a worker has
    // to be given time to read.
    try host.begin(aPage());
    try testing.expectEqual(Status.running, host.status());

    // Still nothing taken, however many looks have gone by: it is not
    // listening, and the reader does not wait for it.
    for (0..STALL_LIMIT) |_| {
        if (host.take()) |_| return error.TestUnexpectedResult;
    }
    try testing.expectEqual(Status.stopped, host.status());
    try testing.expectEqual(@as(usize, 1), fake.killed);
}

test "a frame that cannot be one is a worker let go" {
    var frame: [worker_proto.HEADER_LEN]u8 = undefined;
    std.mem.writeInt(u32, &frame, worker_proto.MAX_INLINE + 1, .little);
    var fake: Fake = .{ .says = &frame };
    var host = hosted(&fake);
    defer host.deinit();
    try host.begin(aPage());

    try testing.expectEqual(@as(?worker_proto.Message, null), host.take());
    try testing.expectEqual(Status.stopped, host.status());
}

test "a message that will not fit a frame is refused, and the worker keeps running" {
    var fake: Fake = .{};
    var host = hosted(&fake);
    defer host.deinit();
    try host.begin(aPage());

    var long: [worker_proto.NAME_MAX + 1]u8 = undefined;
    @memset(&long, 'x');
    try testing.expectError(error.TooLarge, host.send(.{ .missing = .{ .text = &long } }));
    try testing.expectEqual(Status.running, host.status());
    try testing.expectEqual(@as(?worker_proto.Message, null), host.take());
}

test "a worker is asked before it is ended, and its ends are given back" {
    var fake: Fake = .{};
    var host = hosted(&fake);
    defer host.deinit();
    try host.begin(aPage());

    host.stop(.asked);

    var frames = fake.frames();
    _ = frames.next(); // the `start`
    const last = frames.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(worker_proto.Tag.stop, last.tag());
    // It did not go on its own, so it was ended, and both ends closed.
    try testing.expectEqual(@as(usize, 1), fake.killed);
    try testing.expectEqual(@as(usize, 2), fake.closed);
    try testing.expectEqual(Status.none, host.status());
    try testing.expectEqual(@as(?u32, null), host.handle());
}

test "one worker per navigation: the next page's replaces this one's" {
    var fake: Fake = .{};
    var host = hosted(&fake);
    defer host.deinit();

    try host.begin(aPage());
    try host.begin(.{ .address = "https://example.be/two" });

    try testing.expectEqual(@as(usize, 2), fake.spawned);
    try testing.expectEqual(@as(usize, 1), fake.killed);
    try testing.expectEqual(Status.running, host.status());

    // Each was told its own page, and the first was asked to go: said in
    // that order, because the asking is the last thing the first hears.
    var frames = fake.frames();
    const first = frames.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(worker_proto.Tag.start, first.tag());
    try testing.expectEqualStrings("https://example.be/one", first.start.address);
    try testing.expectEqual(worker_proto.Tag.stop, (frames.next() orelse return error.TestUnexpectedResult).tag());
    const second = frames.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(worker_proto.Tag.start, second.tag());
    try testing.expectEqualStrings("https://example.be/two", second.start.address);
}

test "a host gives its buffers back" {
    var fake: Fake = .{};
    var host = hosted(&fake);
    try host.begin(aPage());
    try testing.expectEqual(worker_proto.MAX_FRAME, host.out.len);
    host.deinit();
    try testing.expectEqual(@as(usize, 0), host.out.len);
    try testing.expectEqual(@as(usize, 0), host.in.len);
}
