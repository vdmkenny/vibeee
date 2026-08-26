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
const userSlice = ctx.userSlice;
const currentHandles = ctx.currentHandles;
const installHandle = ctx.installHandle;
const deadlineFrom = ctx.deadlineFrom;

fn getEvent(handle: u32) ?*event_mod.Event {
    const table = currentHandles() orelse return null;
    const h = table.get(handle) orelse return null;
    if (h.kind != .event) return null;
    return h.data.event;
}

/// The event a handle becomes ready on, for `wait_many`.
///
/// An event is its own answer. A pipe's read end answers with the event that
/// tracks whether it has anything to read, which is what lets one call wait on
/// a window's event ring and a shell's output at the same time. Anything else
/// has no readiness worth waiting on.
fn waitableEvent(handle: u32) ?*event_mod.Event {
    const table = currentHandles() orelse return null;
    const h = table.get(handle) orelse return null;
    return switch (h.kind) {
        .event => h.data.event,
        .pipe => if (h.data.pipe.writer) null else &h.data.pipe.pipe.readable,
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
    const e = getEvent(@intCast(a.a0)) orelse return Errno.badf.value();
    e.signal();
    return 0;
}

pub fn sys_wait_many(a: Args) Result {
    const count = a.a1;
    if (count == 0 or count > event_mod.MAX_WAIT) return Errno.inval.value();

    const raw = userSlice(a, a.a0, count * @sizeOf(u32)) orelse return Errno.fault.value();

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
    const name = userSlice(a, a.a0, a.a1) orelse return Errno.fault.value();
    if (name.len == 0 or name.len > buf.len) return Errno.inval.value();
    @memcpy(buf[0..name.len], name);

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
    const name = userSlice(a, a.a0, a.a1) orelse return Errno.fault.value();
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

fn userMessage(a: Args, ptr: usize) ?*abi.Message {
    const raw = userSlice(a, ptr, @sizeOf(abi.Message)) orelse return null;
    return @ptrCast(@alignCast(raw.ptr));
}

pub fn sys_call(a: Args) Result {
    const ch = getChannel(@intCast(a.a0), false) orelse return Errno.badf.value();

    const request = userMessage(a, a.a1) orelse return Errno.fault.value();
    const out = userMessage(a, a.a2) orelse return Errno.fault.value();

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

    out.* = .{};
    @memcpy(out.data[0..answer.len], answer.data[0..answer.len]);
    out.len = answer.len;
    if (!deliverHandles(&answer, out)) return Errno.nomem.value();

    return @intCast(answer.len);
}

pub fn sys_recv(a: Args) Result {
    const ch = getChannel(@intCast(a.a0), true) orelse return Errno.badf.value();
    const out = userMessage(a, a.a1) orelse return Errno.fault.value();
    const token_out = userSlice(a, a.a2, @sizeOf(u32)) orelse return Errno.fault.value();

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
    const msg = userMessage(a, a.a2) orelse return Errno.fault.value();

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
    const out = userSlice(a, a.a0, @sizeOf(abi.DisplayInfo)) orelse return Errno.fault.value();

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
    const out = userSlice(a, a.a0, 2 * @sizeOf(u32)) orelse return Errno.fault.value();
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
