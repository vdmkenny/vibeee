//! What programs and the sound service say to each other.
//!
//! Wire types only, compiled by both sides. A program registers a node,
//! gives it ports, and links them to other ports; frames then travel
//! through shared rings and never cross the channel. The graph itself
//! lives in `lib.audiograph`; this file is how its verbs are spelled on
//! a channel.

const audio = @import("lib").audio;
const graph = @import("lib").audiograph;
const std = @import("std");
const sys = @import("sys");

pub const SERVICE = "audio";

pub const Tag = enum(u8) {
    /// Register a node named `name` for this client. `body.id` answers.
    node_create,
    /// Give node `a` a port named `name` in direction `dir`. The reply
    /// grants `body.port` and three handles: the frame ring, the port's
    /// event, and the service's shared doorbell.
    port_create,
    /// Remove port `a` and every link through it.
    port_drop,
    /// Join source port `a` to sink port `b`.
    link,
    /// Part source port `a` from sink port `b`.
    unlink,
    /// Make port `a` the default in its direction.
    set_default,
    /// Set port `a`'s volume to `b` percent; `dir` carries mute as 0/1.
    set_volume,
    /// One node, by table index `a`: `body.node`, or `end` past the last.
    get_node,
    /// One port, by table index `a`: `body.port_info`.
    get_port,
    /// One link, by table index `a`: `body.link_info`.
    get_link,
    /// The default sink's volume and mute: `body.volume`. What a volume
    /// key or a `vol` call reads before nudging.
    get_master,
};

pub const Status = enum(u8) {
    ok,
    refused,
    /// Nothing at that index: how a walker finds the end of a table.
    end,
};

pub const Req = extern struct {
    tag: Tag,
    /// Direction for `port_create` and `set_default`; mute for
    /// `set_volume`.
    dir: u8 = 0,
    /// How many characters of `name` are real.
    name_len: u8 = 0,
    _pad: u8 = 0,
    a: u32 = 0,
    b: u32 = 0,
    name: [graph.Name.MAX]u8 = @splat(0),

    pub fn named(tag: Tag, text: []const u8) ?Req {
        if (text.len > graph.Name.MAX) return null;
        var req = Req{ .tag = tag, .name_len = @intCast(text.len) };
        @memcpy(req.name[0..text.len], text);
        return req;
    }

    pub fn nameSlice(self: *const Req) []const u8 {
        return self.name[0..@min(self.name_len, graph.Name.MAX)];
    }
};

/// A node as the listing walks it.
pub const NodeInfo = extern struct {
    name: [graph.Name.MAX]u8 = @splat(0),
    name_len: u8 = 0,
    kind: graph.Kind = .program,
    _pad: [3]u8 = @splat(0),
};

/// A port as the listing walks it.
pub const PortInfo = extern struct {
    node: u16 = graph.NONE,
    id: u16 = graph.NONE,
    name: [graph.Name.MAX]u8 = @splat(0),
    name_len: u8 = 0,
    direction: graph.Direction = .source,
    volume: u8 = 100,
    muted: u8 = 0,
    /// Whether this port is the default in its direction.
    default: u8 = 0,
    _pad: [3]u8 = @splat(0),
};

pub const LinkInfo = extern struct {
    source: u16 = graph.NONE,
    sink: u16 = graph.NONE,
};

pub const VolumeInfo = extern struct {
    percent: u8 = 0,
    muted: u8 = 0,
};

pub const Rep = extern struct {
    status: Status = .ok,
    _pad: [3]u8 = @splat(0),
    body: Body = .{ .id = 0 },
};

pub const Body = extern union {
    id: u32,
    port: u32,
    node: NodeInfo,
    port_info: PortInfo,
    link_info: LinkInfo,
    volume: VolumeInfo,
};

/// The handles a `port_create` grant carries, in order.
pub const GRANT_HANDLES = 3;

// ---------------------------------------------------------------------------
// The frame ring a granted port maps
// ---------------------------------------------------------------------------

/// One control page, then the frames. Head and tail are free-running
/// `lib.spsc` indices in bytes; the producer is whoever the port's
/// direction says speaks, and the service is always the other half.
pub const RingCtrl = extern struct {
    head: u32 = 0,
    tail: u32 = 0,
    /// Times the consumer found less than a period. The counter is the
    /// service's; a client reads it to know its pacing is off.
    starved: u32 = 0,
};

pub const CTRL_BYTES = 4096;

/// Every ring carries this many frames. One shape in version one: stereo,
/// sixteen-bit, forty-eight kilohertz; the shape type exists so a later
/// version can carry others without re-plumbing.
pub const RING_FRAMES = 2048;
pub const SHAPE = audio.Shape{ .rate = .hz48000, .channels = 2, .format = .s16le };

pub fn ringBytes() u32 {
    return @intCast(RING_FRAMES * SHAPE.bytesPerFrame());
}

pub fn shmBytes() u32 {
    return CTRL_BYTES + ringBytes();
}

/// Both halves of a mapped ring.
pub const View = struct {
    ctrl: *volatile RingCtrl,
    frames: @import("lib").spsc.Ring,

    pub fn of(base: [*]u8) View {
        const ctrl: *volatile RingCtrl = @ptrCast(@alignCast(base));
        return .{
            .ctrl = ctrl,
            .frames = .{
                .head = @volatileCast(&ctrl.head),
                .tail = @volatileCast(&ctrl.tail),
                .data = base[CTRL_BYTES..][0..ringBytes()],
            },
        };
    }
};

pub const Error = error{ NoService, Refused, End };

/// One request, one reply, no handles: the plain half of the protocol.
pub fn call(request: Req, into: *Rep) Error!void {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) return error.NoService;
    defer _ = sys.close(@intCast(channel));
    return callOn(@intCast(channel), request, into, null);
}

/// The same, on a channel the caller keeps open, optionally keeping the
/// reply's handles.
pub fn callOn(
    channel: u32,
    request: Req,
    into: *Rep,
    take_handles: ?*[GRANT_HANDLES]u32,
) Error!void {
    const message = sys.Message.init(std.mem.asBytes(&request), &.{});
    var answer = sys.Message{};
    if (sys.callMsg(channel, &message, &answer) < 0) return error.Refused;

    const bytes = answer.bytes();
    if (bytes.len < @sizeOf(Rep)) return error.Refused;
    into.* = @as(*const Rep, @alignCast(@ptrCast(bytes.ptr))).*;

    switch (into.status) {
        .ok => {},
        .end => return error.End,
        .refused => return error.Refused,
    }

    if (take_handles) |handles| {
        const got = answer.handleSlice();
        if (got.len < GRANT_HANDLES) return error.Refused;
        @memcpy(handles, got[0..GRANT_HANDLES]);
    }
}

comptime {
    if (@sizeOf(Req) > sys.MAX_PAYLOAD) @compileError("an audio request must fit one payload");
    if (@sizeOf(Rep) > sys.MAX_PAYLOAD) @compileError("an audio reply must fit one payload");
    if (RING_FRAMES & (RING_FRAMES - 1) != 0) @compileError("the ring must be a power of two");
}
