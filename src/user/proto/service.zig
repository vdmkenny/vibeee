//! What a program asks `init` about the services it supervises.
//!
//! `init` is the only thing that knows what was declared, what is running and
//! what it decided to give up on. `/svc` knows only which names are registered,
//! which is a different and smaller question: a service that failed to start
//! registers nothing and is therefore invisible there, and that is exactly the
//! one somebody is looking for.

const std = @import("std");
const sys = @import("sys");

pub const SERVICE = "init";

pub const NAME_MAX = 16;

pub const Tag = enum(u8) {
    /// Every service, and what became of it.
    list,
    /// Start one that is not running.
    start,
    /// Stop one, and do not bring it back.
    stop,
};

pub const Req = extern struct {
    tag: Tag,
    name_len: u8 = 0,
    /// Which service to describe, for `list`. One per call because a reply is
    /// sixty-four bytes and a table is not: the same shape `readdir` has, for
    /// the same reason.
    index: u8 = 0,
    _reserved: u8 = 0,
    name: [NAME_MAX]u8 = @splat(0),

    pub fn init(tag: Tag, name: []const u8) ?Req {
        if (name.len > NAME_MAX) return null;

        var self = Req{ .tag = tag, .name_len = @intCast(name.len) };
        @memcpy(self.name[0..name.len], name);
        return self;
    }

    pub fn named(self: *const Req) []const u8 {
        return self.name[0..@min(self.name_len, NAME_MAX)];
    }
};

/// What became of a service.
pub const State = enum(u8) {
    /// Running now.
    up,
    /// Declared, not running, and expected to come back when it can.
    down,
    /// Stopped because somebody asked, and not coming back on its own.
    stopped,
    /// Started too many times and kept dying. `init` will not try again.
    failed,

    pub fn word(self: State) []const u8 {
        return switch (self) {
            .up => "up",
            .down => "down",
            .stopped => "stopped",
            .failed => "failed",
        };
    }
};

pub const Entry = extern struct {
    state: State = .down,
    name_len: u8 = 0,
    _reserved: [2]u8 = @splat(0),
    pid: u32 = 0,
    name: [NAME_MAX]u8 = @splat(0),

    pub fn named(self: *const Entry) []const u8 {
        return self.name[0..@min(self.name_len, NAME_MAX)];
    }
};

pub const Rep = extern struct {
    /// Zero when there is nothing to report: no service at that index, or the
    /// request could not be carried out.
    ok: u8 = 1,
    _reserved: [3]u8 = @splat(0),
    entry: Entry = .{},
};

pub const Error = error{ NoService, Refused, TooLong };

/// Ask about, or act on, one service.
///
/// The connection is made per call rather than held. A tool runs, asks a
/// handful of questions and exits; holding a channel open across that would be
/// a handle to remember to close and nothing gained.
pub fn ask(tag: Tag, name: []const u8, index: u8, into: *Rep) Error!void {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) return error.NoService;
    defer _ = sys.close(@intCast(channel));

    var request = Req.init(tag, name) orelse return error.TooLong;
    request.index = index;

    const message = sys.Message.init(std.mem.asBytes(&request), &.{});

    var reply = sys.Message{};
    if (sys.callMsg(@intCast(channel), &message, &reply) < 0) return error.Refused;

    const bytes = reply.bytes();
    if (bytes.len < @sizeOf(Rep)) return error.Refused;

    into.* = @as(*const Rep, @alignCast(@ptrCast(bytes.ptr))).*;
    if (into.ok == 0) return error.Refused;
}

comptime {
    if (@sizeOf(Rep) > sys.MAX_PAYLOAD or @sizeOf(Req) > sys.MAX_PAYLOAD) {
        @compileError("a service message must fit in one channel payload");
    }
}
