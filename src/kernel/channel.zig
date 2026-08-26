//! Channels — synchronous call and reply.
//!
//! A client sends a small request and blocks until the server answers. Every
//! server in the design has request/response shape, and making that the
//! default kills a class of bugs outright: there is no queue to overflow, no
//! reply to correlate by hand, and a client that is waiting is visibly waiting
//! rather than silently buffering. Bulk data does not come through here — it
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
//! trusted — it may be a userspace process that has been restarted, or simply
//! buggy — and a pointer would let it write a reply into a stack frame that
//! has since gone. The token carries a generation, so a stale reply is
//! rejected rather than landing on whoever inherited the slot.
//!
//! `design/00-vibeee.md` §6.8.

const std = @import("std");
const hal = @import("hal.zig");
const heap = @import("heap.zig");
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

pub const Message = struct {
    len: u8 = 0,
    data: [MAX_PAYLOAD]u8 = @splat(0),

    pub fn slice(self: *const Message) []const u8 {
        return self.data[0..self.len];
    }

    pub fn set(self: *Message, bytes: []const u8) Error!void {
        if (bytes.len > MAX_PAYLOAD) return error.TooLarge;
        @memcpy(self.data[0..bytes.len], bytes);
        self.len = @intCast(bytes.len);
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

pub const Channel = struct {
    /// Requests sent but not yet received, oldest last.
    pending: ?*Call = null,
    /// Servers blocked in `recv`.
    recv_queue: wait.Queue = .{},

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
    }

    /// Oldest first, so a slow caller is not starved by a busy one.
    fn popPending(self: *Channel) ?*Call {
        var link = &self.pending;
        while (link.*) |c| {
            if (c.next == null) {
                link.* = null;
                c.next = null;
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
pub fn call(ch: *Channel, request: []const u8, answer: *Message, deadline_us: ?u64) Error!void {
    var record = Call{ .request = .{} };
    try record.request.set(request);

    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    if (!ch.serving) return error.Disconnected;

    ch.pushPending(&record);
    _ = ch.recv_queue.wakeOne();

    while (!record.done) {
        _ = wait.blockOn(&.{&record.queue}, deadline_us) catch {
            _ = ch.removePending(&record);
            ch.dropInflight(&record);
            return error.TimedOut;
        };
    }

    if (record.failed) return error.Disconnected;
    answer.* = record.reply;
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
            return .{ .token = token, .message = c.request };
        }

        _ = wait.blockOn(&.{&ch.recv_queue}, deadline_us) catch return error.TimedOut;
    }
}

/// Answer a call received earlier.
pub fn reply(ch: *Channel, token: u32, payload: []const u8) Error!void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    const slot = token & 0xFF;
    if (slot >= MAX_INFLIGHT) return error.BadToken;
    if (ch.tokens[slot] != token) return error.BadToken;

    const c = ch.inflight[slot] orelse return error.BadToken;
    try c.reply.set(payload);

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
