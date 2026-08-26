//! IPC calls — events, channels and the service registry.
//!
//! design/00-vibeee.md §6.8. Handlers stay thin: the objects enforce their own
//! invariants, and all these do is translate between handles and pointers on
//! one side and kernel objects on the other.

const std = @import("std");
const abi = @import("lib").syscalls;
const channel_mod = @import("../channel.zig");
const ctx = @import("context.zig");
const event_mod = @import("../event.zig");
const handles = @import("../handle.zig");
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
        events[i] = getEvent(handle) orelse return Errno.badf.value();
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

pub fn sys_call(a: Args) Result {
    const ch = getChannel(@intCast(a.a0), false) orelse return Errno.badf.value();

    const request = userSlice(a, a.a1, a.a2) orelse return Errno.fault.value();
    if (request.len > abi.MAX_PAYLOAD) return Errno.inval.value();
    const out = userSlice(a, a.a3, a.a4) orelse return Errno.fault.value();

    var answer: channel_mod.Message = .{};
    channel_mod.call(ch, request, &answer, null) catch |err| {
        return switch (err) {
            error.Disconnected => Errno.pipe.value(),
            error.TimedOut => Errno.timedout.value(),
            error.TooLarge => Errno.inval.value(),
            else => Errno.io.value(),
        };
    };

    const n = @min(answer.len, out.len);
    @memcpy(out[0..n], answer.data[0..n]);
    return @intCast(n);
}

pub fn sys_recv(a: Args) Result {
    const ch = getChannel(@intCast(a.a0), true) orelse return Errno.badf.value();
    const out = userSlice(a, a.a1, a.a2) orelse return Errno.fault.value();
    const token_out = userSlice(a, a.a3, @sizeOf(u32)) orelse return Errno.fault.value();

    const got = channel_mod.recv(ch, deadlineFrom(a.a4)) catch |err| {
        return switch (err) {
            error.TimedOut => Errno.timedout.value(),
            error.Busy => Errno.nomem.value(),
            else => Errno.io.value(),
        };
    };

    std.mem.writeInt(u32, token_out[0..4], got.token, .little);
    const n = @min(got.message.len, out.len);
    @memcpy(out[0..n], got.message.data[0..n]);
    return @intCast(n);
}

pub fn sys_reply(a: Args) Result {
    const ch = getChannel(@intCast(a.a0), true) orelse return Errno.badf.value();
    const payload = userSlice(a, a.a2, a.a3) orelse return Errno.fault.value();
    if (payload.len > abi.MAX_PAYLOAD) return Errno.inval.value();

    channel_mod.reply(ch, @intCast(a.a1), payload) catch |err| {
        return switch (err) {
            error.BadToken => Errno.inval.value(),
            error.TooLarge => Errno.inval.value(),
            else => Errno.io.value(),
        };
    };
    return 0;
}