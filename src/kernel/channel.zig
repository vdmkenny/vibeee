//! Channels, synchronous call and reply.
//!
//! A client sends a small request and blocks until the server answers. Every
//! server in the design has request/response shape, and making that the
//! default kills a class of bugs outright: there is no queue to overflow, no
//! reply to correlate by hand, and a client that is waiting is visibly waiting
//! rather than silently buffering. Bulk data does not come through here, it
//! goes through a ring (`lib/ring.zig`), with the channel carrying the small
//! message that says which ring and how much.
//!
//! **No allocation on the call path.** The in-flight call record lives on the
//! calling thread's kernel stack, which is sound for the same reason a waiter
//! node is: the caller is blocked inside the frame that owns it and cannot
//! return until it has been removed from every list that names it. A syscall
//! that cannot fail for want of memory is worth some care to arrange.
//!
//! **A reply names a call by token, not by pointer.** The server is not
//! trusted, it may be a userspace process that has been restarted, or simply
//! buggy, and a pointer would let it write a reply into a stack frame that
//! has since gone. The token carries a generation, so a stale reply is
//! rejected rather than landing on whoever inherited the slot.
//!
//! `design/00-vibeee.md` §6.8.

const std = @import("std");
const event_mod = @import("event.zig");
const hal = @import("hal.zig");
const handle = @import("handle.zig");
const heap = @import("heap.zig");
const sched = @import("sched.zig");
const wait = @import("wait.zig");

pub const Error = error{
    OutOfMemory,
    /// The far end is gone: no server has this channel open.
    Disconnected,
    /// Too many calls already in flight on this channel.
    Busy,
    /// The token does not name a live call.
    BadToken,
    TimedOut,
    TooLarge,
};

/// Inline payload, per design §6.8. Defined with the rest of the ABI, since
/// userspace has to agree with it.
pub const MAX_PAYLOAD = @import("lib").syscalls.MAX_PAYLOAD;

/// Calls one channel may have outstanding. Bounded because each occupies a
/// slot in the channel, and a server that has fallen behind should refuse new
/// work rather than let the backlog grow without limit.
pub const MAX_INFLIGHT = 16;

/// Handles one message may carry.
pub const MAX_HANDLES = @import("lib").syscalls.MAX_MSG_HANDLES;

pub const Message = struct {
    len: u8 = 0,
    data: [MAX_PAYLOAD]u8 = @splat(0),
    /// Who sent it. Recorded by `call` from the running thread, so a receiver
    /// learns the caller's identity from the kernel rather than from the
    /// caller.
    sender: u32 = 0,
    /// Handles travelling with the message, as kernel objects rather than
    /// numbers: a handle number means nothing outside the process that owns
    /// it, so a transfer moves the reference and the receiver is given a fresh
    /// number for it.
    handle_count: u8 = 0,
    handles: [MAX_HANDLES]handle.Transfer = @splat(.{ .event = undefined }),

    pub fn slice(self: *const Message) []const u8 {
        return self.data[0..self.len];
    }

    pub fn set(self: *Message, bytes: []const u8) Error!void {
        if (bytes.len > MAX_PAYLOAD) return error.TooLarge;
        @memcpy(self.data[0..bytes.len], bytes);
        self.len = @intCast(bytes.len);
    }

    pub fn handleSlice(self: *const Message) []const handle.Transfer {
        return self.handles[0..self.handle_count];
    }

    /// Attach handles, taking a reference to each. The message owns them from
    /// here: whoever ends up with it either installs them in a process or
    /// releases them.
    pub fn attach(self: *Message, items: []const handle.Transfer) Error!void {
        if (items.len > MAX_HANDLES) return error.TooLarge;
        for (items, 0..) |h, i| self.handles[i] = handle.retainTransfer(h);
        self.handle_count = @intCast(items.len);
    }

    /// Hand this message on, leaving nothing owned here.
    ///
    /// A message owns the references it carries, so a copy of one is two
    /// owners for a single reference: whichever gave it back first would free
    /// an object the other still points at, and the second would free it
    /// again. Every place a message moves from one owner to the next goes
    /// through here, so the rule that `attach` states is the rule the code
    /// keeps.
    pub fn take(self: *Message) Message {
        const moved = self.*;
        self.handle_count = 0;
        return moved;
    }

    /// Give back anything still attached. Called when a message is dropped
    /// rather than delivered, which is the path that leaks if it is missed.
    pub fn discard(self: *Message) void {
        for (self.handles[0..self.handle_count]) |h| handle.releaseTransfer(h);
        self.handle_count = 0;
    }
};

/// One call in progress, owned by the blocked caller.
const Call = struct {
    next: ?*Call = null,
    request: Message,
    reply: Message = .{},
    /// Set by the server's reply, or by teardown when the server vanishes.
    done: bool = false,
    failed: bool = false,
    queue: wait.Queue = .{},
};

comptime {
    // The call record lives on the calling thread's 16 KiB kernel stack, and
    // `sys_call` puts a second message and a handle array beside it. A `Handle`
    // that grew would overflow that stack silently: the thread stops mid-call
    // with no fault, which is a long way from the change that caused it.
    if (@sizeOf(Call) > 1024) @compileError(std.fmt.comptimePrint(
        "Call is {d} bytes, too large for a kernel stack",
        .{@sizeOf(Call)},
    ));
}

pub const Channel = struct {
    /// Requests sent but not yet received, oldest last.
    pending: ?*Call = null,
    /// Servers blocked in `recv`.
    recv_queue: wait.Queue = .{},

    /// Kept in step with `pending`, so a server can hold this channel in a
    /// `wait_many` beside everything else it listens to rather than having
    /// `recv` be the only way to hear about a call. That is what lets a server
    /// with a channel, input and a settings event have one blocking call and
    /// no polling.
    ///
    /// A level rather than a tally: one count while there is something to
    /// receive and none when there is not, so a server that takes two calls
    /// without waiting is not woken twice for nothing afterwards.
    ready: event_mod.Event = .{},

    /// Received but not yet replied to, indexed by the low bits of the token.
    inflight: [MAX_INFLIGHT]?*Call = @splat(null),
    tokens: [MAX_INFLIGHT]u32 = @splat(0),
    /// Generation counter, so a token is never reused while anything remembers
    /// the old one.
    next_generation: u32 = 1,

    refs: u32 = 1,
    /// Cleared when the serving end closes, which is what turns a client's
    /// block into an error instead of a hang.
    serving: bool = true,

    fn pushPending(self: *Channel, record: *Call) void {
        record.next = self.pending;
        self.pending = record;
        self.refreshReady();
    }

    /// Keep `ready` saying what `pending` says. Called from every place that
    /// changes the queue, so nobody has to remember to.
    fn refreshReady(self: *Channel) void {
        if (self.pending != null) {
            if (self.ready.count == 0) self.ready.signalLocked();
        } else {
            self.ready.count = 0;
        }
    }

    /// Oldest first, so a slow caller is not starved by a busy one.
    fn popPending(self: *Channel) ?*Call {
        var link = &self.pending;
        while (link.*) |c| {
            if (c.next == null) {
                link.* = null;
                c.next = null;
                self.refreshReady();
                return c;
            }
            link = &c.next;
        }
        return null;
    }

    fn removePending(self: *Channel, record: *Call) bool {
        var link = &self.pending;
        while (link.*) |c| {
            if (c == record) {
                link.* = c.next;
                c.next = null;
                self.refreshReady();
                return true;
            }
            link = &c.next;
        }
        return false;
    }

    fn dropInflight(self: *Channel, record: *Call) void {
        for (&self.inflight, 0..) |*slot, i| {
            if (slot.* == record) {
                slot.* = null;
                self.tokens[i] = 0;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Client side
// ---------------------------------------------------------------------------

/// Send `request` and block until the server replies.
///
/// On timeout the call is withdrawn from every list the server could reach it
/// through before returning, because the record is about to go out of scope
/// with the caller's stack frame.
pub fn call(
    ch: *Channel,
    request: []const u8,
    send_handles: []const handle.Transfer,
    answer: *Message,
    deadline_us: ?u64,
) Error!void {
    var record = Call{ .request = .{} };
    try record.request.set(request);
    try record.request.attach(send_handles);
    errdefer record.request.discard();

    record.request.sender = if (sched.currentThread()) |t| t.id else 0;

    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    if (!ch.serving) return error.Disconnected;

    ch.pushPending(&record);
    _ = ch.recv_queue.wakeOne();

    while (!record.done) {
        _ = wait.blockOn(&.{&record.queue}, deadline_us) catch {
            _ = ch.removePending(&record);
            ch.dropInflight(&record);
            record.request.discard();
            return error.TimedOut;
        };
    }

    if (record.failed) {
        record.request.discard();
        record.reply.discard();
        return error.Disconnected;
    }
    answer.* = record.reply.take();
}

// ---------------------------------------------------------------------------
// Server side
// ---------------------------------------------------------------------------

pub const Received = struct {
    token: u32,
    message: Message,
};

/// Block until a request arrives, and take responsibility for replying to it.
pub fn recv(ch: *Channel, deadline_us: ?u64) Error!Received {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    while (true) {
        if (ch.popPending()) |c| {
            const slot = freeSlot(ch) orelse {
                // No room to track the reply. Failing the caller is better
                // than holding a request nobody can answer.
                c.failed = true;
                c.done = true;
                _ = c.queue.wakeAll();
                return error.Busy;
            };

            const token = (ch.next_generation << 8) | @as(u32, @intCast(slot));
            ch.next_generation +%= 1;
            if (ch.next_generation == 0) ch.next_generation = 1;

            ch.inflight[slot] = c;
            ch.tokens[slot] = token;

            // The server owns the request's handles from here. The caller is
            // still blocked in the frame that holds the original, and every
            // path it wakes on discards what it owns: leaving it owning these
            // too would have it give back references the server is holding.
            return .{ .token = token, .message = c.request.take() };
        }

        _ = wait.blockOn(&.{&ch.recv_queue}, deadline_us) catch return error.TimedOut;
    }
}

/// Answer a call received earlier.
pub fn reply(
    ch: *Channel,
    token: u32,
    payload: []const u8,
    send_handles: []const handle.Transfer,
) Error!void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    const slot = token & 0xFF;
    if (slot >= MAX_INFLIGHT) return error.BadToken;
    if (ch.tokens[slot] != token) return error.BadToken;

    const c = ch.inflight[slot] orelse return error.BadToken;
    try c.reply.set(payload);
    try c.reply.attach(send_handles);

    ch.inflight[slot] = null;
    ch.tokens[slot] = 0;

    c.done = true;
    _ = c.queue.wakeAll();
}

fn freeSlot(ch: *Channel) ?usize {
    for (ch.inflight, 0..) |slot, i| {
        if (slot == null) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Lifetime
// ---------------------------------------------------------------------------

pub fn create() Error!*Channel {
    const ch = heap.allocator.create(Channel) catch return error.OutOfMemory;
    ch.* = .{};
    return ch;
}

pub fn retain(ch: *Channel) void {
    ch.refs += 1;
}

/// Stop serving, failing every call that is waiting on an answer.
///
/// Called when the serving handle closes. Without it a server crash would
/// leave its clients blocked forever on a reply that is never coming, which is
/// the failure mode a restartable-server design most needs to avoid.
pub fn stopServing(ch: *Channel) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    ch.serving = false;

    while (ch.popPending()) |c| {
        c.failed = true;
        c.done = true;
        _ = c.queue.wakeAll();
    }
    for (&ch.inflight, 0..) |*slot, i| {
        if (slot.*) |c| {
            c.failed = true;
            c.done = true;
            _ = c.queue.wakeAll();
        }
        slot.* = null;
        ch.tokens[i] = 0;
    }
    _ = ch.recv_queue.wakeAll();
}

pub fn release(ch: *Channel) void {
    if (ch.refs > 1) {
        ch.refs -= 1;
        return;
    }
    stopServing(ch);
    heap.allocator.destroy(ch);
}
