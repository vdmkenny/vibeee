//! IPC calls, events, channels and the service registry.
//!
//! design/00-vibeee.md §6.8. Handlers stay thin: the objects enforce their own
//! invariants, and all these do is translate between handles and pointers on
//! one side and kernel objects on the other.

const std = @import("std");
const abi = @import("lib").syscalls;
const channel_mod = @import("../channel.zig");
const ctx = @import("context.zig");
const display = @import("../display.zig");
const event_mod = @import("../event.zig");
const driver = @import("driver.zig");
const handles = @import("../handle.zig");
const pipe_mod = @import("../pipe.zig");
const sched = @import("../sched.zig");
const shm = @import("../shm.zig");
const svc = @import("../svc.zig");

const Args = ctx.Args;
const Result = ctx.Result;
const Errno = ctx.Errno;
const userRead = ctx.userRead;
const userWrite = ctx.userWrite;
const currentHandles = ctx.currentHandles;
const installHandle = ctx.installHandle;
const deadlineFrom = ctx.deadlineFrom;

/// The event behind a handle, for a caller about to signal it.
///
/// Signalling is writing to it, so it takes the write right. `watch` hands out
/// read-only handles onto events the whole system shares, the keyboard's and
/// the pointer's among them: a process that could signal one of those would
/// wake every other waiter on it whenever it liked.
///
/// An error set rather than a null, so the answer says which of the two it is:
/// a handle that is not an event and a handle that is one but may not be
/// signalled are different things to be told.
fn eventToSignal(handle: u32) error{ NoSuchHandle, NotAllowed }!*event_mod.Event {
    const table = currentHandles() orelse return error.NoSuchHandle;
    const h = table.get(handle) orelse return error.NoSuchHandle;
    if (h.kind != .event) return error.NoSuchHandle;
    if (!h.rights.write) return error.NotAllowed;
    return h.data.event;
}

/// The event a handle becomes ready on, for `wait_many`.
///
/// An event is its own answer. A pipe's read end answers with the event that
/// tracks whether it has anything to read, its write end with the one that
/// tracks whether there is room, and a channel's serving end with the event
/// that tracks whether a call is waiting. That is what lets a server with a
/// channel, input and a settings event have one blocking call rather than a
/// loop that asks each of them in turn.
///
/// Both ends of a pipe being waitable is what lets a program refuse to block
/// on either: a terminal that blocked writing to its shell while that shell
/// was blocked writing to it would be two processes waiting for each other.
fn waitableEvent(handle: u32) ?*event_mod.Event {
    const table = currentHandles() orelse return null;
    const h = table.get(handle) orelse return null;
    return switch (h.kind) {
        .event => h.data.event,
        .pipe => if (h.data.pipe.writer)
            &h.data.pipe.pipe.writable
        else
            &h.data.pipe.pipe.readable,
        // The serving end only: a client's readiness is its reply arriving,
        // which `call` already blocks for.
        .channel => if (h.data.channel.serving) &h.data.channel.channel.ready else null,
        .irq => blk: {
            // Waiting is what arms the line: a driver that attached before it
            // was ready to service the device gets nothing until it asks.
            driver.armIfIrq(h);
            break :blk &h.data.irq.ready;
        },
        else => null,
    };
}

fn getChannel(handle: u32, serving: bool) ?*channel_mod.Channel {
    const table = currentHandles() orelse return null;
    const h = table.get(handle) orelse return null;
    if (h.kind != .channel) return null;
    // A client cannot answer calls and a server cannot make them on its own
    // serving end; enforcing that here keeps the object free of the question.
    if (h.data.channel.serving != serving) return null;
    return h.data.channel.channel;
}

pub fn sys_event_create(_: Args) Result {
    const e = event_mod.create() catch return Errno.nomem.value();
    const slot = installHandle(.{
        .kind = .event,
        .rights = .{ .read = true, .write = true },
        .data = .{ .event = e },
    }) orelse {
        event_mod.release(e);
        return Errno.nomem.value();
    };
    return @intCast(slot);
}

pub fn sys_event_signal(a: Args) Result {
    const e = eventToSignal(@intCast(a.a0)) catch |err| return switch (err) {
        error.NoSuchHandle => Errno.badf.value(),
        error.NotAllowed => Errno.perm.value(),
    };
    e.signal();
    return 0;
}

pub fn sys_wait_many(a: Args) Result {
    const count = a.a1;
    if (count == 0 or count > event_mod.MAX_WAIT) return Errno.inval.value();

    const raw = userRead(a, a.a0, count * @sizeOf(u32)) orelse return Errno.fault.value();

    // Copied out of user memory before any of it is used: re-reading the array
    // after validating it is how a process talks the kernel into waiting on an
    // object it no longer holds.
    var events: [event_mod.MAX_WAIT]*event_mod.Event = undefined;
    for (0..count) |i| {
        const handle = std.mem.readInt(u32, raw[i * 4 ..][0..4], .little);
        events[i] = waitableEvent(handle) orelse return Errno.badf.value();
    }

    const index = event_mod.waitMany(events[0..count], deadlineFrom(a.a2)) catch |err| {
        return switch (err) {
            error.TimedOut => Errno.timedout.value(),
            else => Errno.inval.value(),
        };
    };
    return @intCast(index);
}

pub fn sys_svc_register(a: Args) Result {
    var buf: [svc.MAX_NAME]u8 = undefined;
    const name = userRead(a, a.a0, a.a1) orelse return Errno.fault.value();
    if (name.len == 0 or name.len > buf.len) return Errno.inval.value();
    @memcpy(buf[0..name.len], name);

    // The system's own names are held back. A program that took `cfg` would
    // answer every settings question on the machine, and one that took `gui`
    // would be handed every key its owner types: the name is the whole of what
    // a client has to go on, so who may take one is the kernel's to say.
    // Registration is checked before the channel exists, so a refusal costs
    // nothing and cannot leave one behind.
    if (svc.isReserved(buf[0..name.len])) {
        if (ctx.require(.{ .service = true })) |denied| return denied;
    }

    const ch = channel_mod.create() catch return Errno.nomem.value();
    errdefer channel_mod.release(ch);

    svc.register(buf[0..name.len], ch) catch |err| {
        channel_mod.release(ch);
        return switch (err) {
            error.AlreadyRegistered => Errno.exists.value(),
            error.BadName => Errno.inval.value(),
            error.TableFull => Errno.nomem.value(),
            else => Errno.inval.value(),
        };
    };

    // The registry holds one reference and the handle holds the one made at
    // creation, so the channel outlives either going away alone.
    const slot = installHandle(.{
        .kind = .channel,
        .rights = .{ .read = true, .write = true },
        .data = .{ .channel = .{ .channel = ch, .serving = true } },
    }) orelse {
        svc.unregister(buf[0..name.len]);
        channel_mod.release(ch);
        return Errno.nomem.value();
    };
    return @intCast(slot);
}

pub fn sys_svc_connect(a: Args) Result {
    const name = userRead(a, a.a0, a.a1) orelse return Errno.fault.value();
    if (name.len == 0 or name.len > svc.MAX_NAME) return Errno.inval.value();

    const ch = svc.lookup(name) catch return Errno.noent.value();
    const slot = installHandle(.{
        .kind = .channel,
        .rights = .{ .read = true, .write = true },
        .data = .{ .channel = .{ .channel = ch, .serving = false } },
    }) orelse {
        channel_mod.release(ch);
        return Errno.nomem.value();
    };
    return @intCast(slot);
}

/// Copy the handles a user message names into kernel objects, taking a
/// reference to each.
///
/// Resolved before anything blocks: the sender's table can change while a call
/// is in flight, and a handle validated then re-read is the same
/// time-of-check bug as a pointer validated then re-read.
fn collectHandles(msg: *const abi.Message, out: []handles.Transfer) ?usize {
    const table = currentHandles() orelse return null;
    const wanted = msg.handleSlice();
    if (wanted.len > out.len) return null;

    for (wanted, 0..) |number, i| {
        const h = table.get(number) orelse return unwind(out, i);
        // Not everything can be sent. A file handle carries a position, which
        // means nothing to the receiver, so it is refused rather than
        // delivered as something useless.
        const item = handles.transferable(h.*) orelse return unwind(out, i);
        out[i] = handles.retainTransfer(item);
    }
    return wanted.len;
}

/// Give back what was gathered before a failure, so a message that cannot be
/// sent leaves the sender's references exactly as it found them.
fn unwind(taken: []handles.Transfer, count: usize) ?usize {
    for (taken[0..count]) |item| handles.releaseTransfer(item);
    return null;
}

/// Install received handles into the calling process, filling in the numbers
/// it will use for them.
///
/// On failure everything is released rather than half-delivered: a receiver
/// that got two of four handles has no way to say so.
fn deliverHandles(msg: *channel_mod.Message, out: *abi.Message) bool {
    const table = currentHandles() orelse return false;

    var installed: usize = 0;
    for (msg.handleSlice()) |item| {
        const slot = table.alloc() orelse break;
        table.entries[slot] = handles.fromTransfer(item);
        out.handles[installed] = slot;
        installed += 1;
    }

    if (installed < msg.handle_count) {
        for (out.handles[0..installed]) |number| _ = table.close(number);
        for (msg.handleSlice()[installed..]) |item| handles.releaseTransfer(item);
        msg.handle_count = 0;
        return false;
    }

    out.handle_count = @intCast(installed);
    // The message no longer owns them; the table does.
    msg.handle_count = 0;
    return true;
}

/// A message the caller is handing over, and one the kernel is filling in.
///
/// Two of them rather than one, so a handler given something to send cannot
/// write back through it. Both refuse a pointer that is not aligned for the
/// struct: a caller may name any address it likes, and treating a misaligned
/// one as a message is undefined before it is anything else.
fn userMessageRead(a: Args, ptr: usize) ?*const abi.Message {
    if (!std.mem.isAligned(ptr, @alignOf(abi.Message))) return null;
    const raw = userRead(a, ptr, @sizeOf(abi.Message)) orelse return null;
    return @ptrCast(@alignCast(raw.ptr));
}

fn userMessageWrite(a: Args, ptr: usize) ?*abi.Message {
    if (!std.mem.isAligned(ptr, @alignOf(abi.Message))) return null;
    const raw = userWrite(a, ptr, @sizeOf(abi.Message)) orelse return null;
    return @ptrCast(@alignCast(raw.ptr));
}

pub fn sys_call(a: Args) Result {
    const ch = getChannel(@intCast(a.a0), false) orelse return Errno.badf.value();

    const request = userMessageRead(a, a.a1) orelse return Errno.fault.value();
    const out = userMessageWrite(a, a.a2) orelse return Errno.fault.value();

    // Copied out of user memory before the call blocks, for the same reason
    // every other pointer argument is.
    const sent = request.*;
    if (sent.len > abi.MAX_PAYLOAD) return Errno.inval.value();

    var taken: [channel_mod.MAX_HANDLES]handles.Transfer = @splat(.{ .event = undefined });
    const count = collectHandles(&sent, &taken) orelse return Errno.badf.value();

    var answer: channel_mod.Message = .{};
    channel_mod.call(ch, sent.bytes(), taken[0..count], &answer, null) catch |err| {
        for (taken[0..count]) |item| handles.releaseTransfer(item);
        return switch (err) {
            error.Disconnected => Errno.pipe.value(),
            error.TimedOut => Errno.timedout.value(),
            error.TooLarge => Errno.inval.value(),
            else => Errno.io.value(),
        };
    };

    // The message took its own references when it was sent, and the receiver
    // now holds them; ours go back. Without this every call carrying a handle
    // leaves one reference behind and the object is never freed.
    defer for (taken[0..count]) |item| handles.releaseTransfer(item);

    out.* = .{};
    @memcpy(out.data[0..answer.len], answer.data[0..answer.len]);
    out.len = answer.len;
    if (!deliverHandles(&answer, out)) return Errno.nomem.value();

    return @intCast(answer.len);
}

pub fn sys_recv(a: Args) Result {
    const ch = getChannel(@intCast(a.a0), true) orelse return Errno.badf.value();
    const out = userMessageWrite(a, a.a1) orelse return Errno.fault.value();
    const token_out = userWrite(a, a.a2, @sizeOf(u32)) orelse return Errno.fault.value();

    var got = channel_mod.recv(ch, deadlineFrom(a.a3)) catch |err| {
        return switch (err) {
            error.TimedOut => Errno.timedout.value(),
            error.Busy => Errno.nomem.value(),
            else => Errno.io.value(),
        };
    };

    std.mem.writeInt(u32, token_out[0..4], got.token, .little);

    out.* = .{};
    @memcpy(out.data[0..got.message.len], got.message.data[0..got.message.len]);
    out.len = got.message.len;
    out.sender = got.message.sender;
    if (!deliverHandles(&got.message, out)) return Errno.nomem.value();

    return @intCast(got.message.len);
}

pub fn sys_reply(a: Args) Result {
    const ch = getChannel(@intCast(a.a0), true) orelse return Errno.badf.value();
    const msg = userMessageRead(a, a.a2) orelse return Errno.fault.value();

    const sent = msg.*;
    if (sent.len > abi.MAX_PAYLOAD) return Errno.inval.value();

    var taken: [channel_mod.MAX_HANDLES]handles.Transfer = @splat(.{ .event = undefined });
    const count = collectHandles(&sent, &taken) orelse return Errno.badf.value();

    channel_mod.reply(ch, @intCast(a.a1), sent.bytes(), taken[0..count]) catch |err| {
        for (taken[0..count]) |item| handles.releaseTransfer(item);
        return switch (err) {
            error.BadToken => Errno.inval.value(),
            error.TooLarge => Errno.inval.value(),
            else => Errno.io.value(),
        };
    };
    // The reply message took its own references; ours go back.
    for (taken[0..count]) |item| handles.releaseTransfer(item);
    return 0;
}

// ---------------------------------------------------------------------------
// Shared memory
// ---------------------------------------------------------------------------

fn getSegment(handle: u32) ?*shm.Segment {
    const table = currentHandles() orelse return null;
    const h = table.get(handle) orelse return null;
    return switch (h.kind) {
        .shm => h.data.shm,
        // The scanout buffer maps like any other segment; the separate kind
        // exists only so closing it releases the display too.
        .display => h.data.display,
        else => null,
    };
}

pub fn sys_shm_create(a: Args) Result {
    const seg = shm.create(a.a0) catch |err| {
        return switch (err) {
            error.BadSize => Errno.inval.value(),
            else => Errno.nomem.value(),
        };
    };

    const slot = installHandle(.{
        .kind = .shm,
        .rights = .{ .read = true, .write = true },
        .data = .{ .shm = seg },
    }) orelse {
        shm.release(seg);
        return Errno.nomem.value();
    };
    return @intCast(slot);
}

pub fn sys_shm_map(a: Args) Result {
    const seg = getSegment(@intCast(a.a0)) orelse return Errno.badf.value();
    const flags: abi.MapFlags = @bitCast(@as(u32, @truncate(a.a1)));

    const t = sched.currentThread() orelse return Errno.inval.value();

    const at = t.shm_window.reserve(seg.size) catch return Errno.nomem.value();
    shm.mapAt(seg, &t.space, at, flags.writable) catch return Errno.nomem.value();

    return @intCast(at);
}

pub fn sys_display_acquire(a: Args) Result {
    if (ctx.require(.{ .display = true })) |denied| return denied;

    const out = userWrite(a, a.a0, @sizeOf(abi.DisplayInfo)) orelse return Errno.fault.value();

    const segment = display.acquire() catch |err| {
        return switch (err) {
            error.Busy => Errno.busy.value(),
            error.NoDisplay => Errno.noent.value(),
            else => Errno.nomem.value(),
        };
    };

    const slot = installHandle(.{
        .kind = .display,
        .rights = .{ .read = true, .write = true },
        .data = .{ .display = segment },
    }) orelse {
        shm.release(segment);
        display.release();
        return Errno.nomem.value();
    };

    const geometry = display.describe();
    const record = abi.DisplayInfo{
        .width = geometry.width,
        .height = geometry.height,
        .stride_px = geometry.stride_px,
        .format = geometry.format,
        .buffers = geometry.buffers,
        .caps = geometry.caps,
        .bytes = geometry.bytes,
    };
    @memcpy(out[0..@sizeOf(abi.DisplayInfo)], std.mem.asBytes(&record));

    return @intCast(slot);
}

pub fn sys_pipe(a: Args) Result {
    const out = userWrite(a, a.a0, 2 * @sizeOf(u32)) orelse return Errno.fault.value();
    const table = currentHandles() orelse return Errno.nomem.value();

    const read_slot = table.alloc() orelse return Errno.nomem.value();
    // Claimed before the second, so the first cannot be handed out twice. The
    // kind is set now for the same reason: `alloc` finds the lowest free slot,
    // and a slot still marked free would be found again.
    table.entries[read_slot] = .{ .kind = .console, .rights = .{} };

    const write_slot = table.alloc() orelse {
        table.entries[read_slot] = .{};
        return Errno.nomem.value();
    };

    const p = pipe_mod.create() catch {
        table.entries[read_slot] = .{};
        return Errno.nomem.value();
    };

    table.entries[read_slot] = .{
        .kind = .pipe,
        .rights = .{ .read = true },
        .data = .{ .pipe = .{ .pipe = p, .writer = false } },
    };
    table.entries[write_slot] = .{
        .kind = .pipe,
        .rights = .{ .write = true },
        .data = .{ .pipe = .{ .pipe = p, .writer = true } },
    };

    std.mem.writeInt(u32, out[0..4], read_slot, .little);
    std.mem.writeInt(u32, out[4..8], write_slot, .little);
    return 0;
}
