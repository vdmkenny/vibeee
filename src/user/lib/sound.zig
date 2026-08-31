//! The client side of a sound port: a node, its ports, and frames.
//!
//! A program registers a node with the sound service, gives it ports, and
//! reads or writes frames through the shared ring each port was granted.
//! Linking is somebody's decision, not this library's: a freshly made
//! output arrives connected to the default sink because that is what a
//! program playing a sound almost always means, and anything fancier is
//! one `patch` away.

const graph = @import("lib").audiograph;
const proto = @import("proto").audio;
const sys = @import("sys");

pub const Error = error{ NoService, Refused, End };

/// One port and its ring, producer or consumer decided by direction.
pub const Port = struct {
    channel: u32,
    node: u32,
    id: u32,
    shm: u32,
    ev: u32,
    doorbell: u32,
    view: proto.View,

    /// An output: this program into the graph, linked to the default sink.
    pub fn output(node_name: []const u8, port_name: []const u8) Error!Port {
        var port = try open(node_name, port_name, .source);
        errdefer port.close();

        // Linked to wherever sound goes by default; a caller that wants
        // another sink unlinks and relinks through the graph verbs.
        const sink = try defaultPort(.sink);
        var req = proto.Req{ .tag = .link, .a = port.id, .b = sink };
        var reply = proto.Rep{};
        try proto.callOn(port.channel, req, &reply, null);
        _ = &req;
        return port;
    }

    /// An input: the graph into this program, linked from the default
    /// source.
    pub fn input(node_name: []const u8, port_name: []const u8) Error!Port {
        var port = try open(node_name, port_name, .sink);
        errdefer port.close();

        const source = try defaultPort(.source);
        const req = proto.Req{ .tag = .link, .a = source, .b = port.id };
        var reply = proto.Rep{};
        try proto.callOn(port.channel, req, &reply, null);
        return port;
    }

    fn open(node_name: []const u8, port_name: []const u8, direction: graph.Direction) Error!Port {
        const channel = sys.svcConnect(proto.SERVICE);
        if (channel < 0) return error.NoService;
        errdefer _ = sys.close(@intCast(channel));

        var node_req = proto.Req.named(.node_create, node_name) orelse return error.Refused;
        var reply = proto.Rep{};
        try proto.callOn(@intCast(channel), node_req, &reply, null);
        const node = reply.body.id;
        _ = &node_req;

        var port_req = proto.Req.named(.port_create, port_name) orelse return error.Refused;
        port_req.a = node;
        port_req.dir = @intFromEnum(direction);
        var handles: [proto.GRANT_HANDLES]u32 = undefined;
        try proto.callOn(@intCast(channel), port_req, &reply, &handles);

        const base = sys.shmMap(handles[0], .{ .writable = true }) orelse return error.Refused;
        return .{
            .channel = @intCast(channel),
            .node = node,
            .id = reply.body.port,
            .shm = handles[0],
            .ev = handles[1],
            .doorbell = handles[2],
            .view = proto.View.of(base),
        };
    }

    /// As much of `frames` as the ring takes, doorbell rung when any.
    pub fn write(self: *const Port, frames: []const u8) u32 {
        const n = self.view.frames.push(frames);
        if (n != 0) _ = sys.eventSignal(self.doorbell);
        return n;
    }

    /// As much as `into` holds, doorbell rung when room was made.
    pub fn read(self: *const Port, into: []u8) u32 {
        const n = self.view.frames.pop(into);
        if (n != 0) _ = sys.eventSignal(self.doorbell);
        return n;
    }

    /// The handle a wait set listens on: the service signals it when the
    /// ring gained room (outputs) or frames (inputs).
    pub fn waitHandle(self: *const Port) u32 {
        return self.ev;
    }

    /// Whether everything written has been consumed by the service.
    pub fn drained(self: *const Port) bool {
        return self.view.frames.readable() == 0;
    }

    pub fn close(self: *const Port) void {
        var reply = proto.Rep{};
        const req = proto.Req{ .tag = .port_drop, .a = self.id };
        proto.callOn(self.channel, req, &reply, null) catch {};
        _ = sys.close(self.shm);
        _ = sys.close(self.ev);
        _ = sys.close(self.doorbell);
        _ = sys.close(self.channel);
    }
};

/// The default port in a direction, from the listing: the port flagged
/// default whose direction matches.
pub fn defaultPort(direction: graph.Direction) Error!u32 {
    var index: u32 = 0;
    while (true) : (index += 1) {
        var reply = proto.Rep{};
        proto.call(.{ .tag = .get_port, .a = index }, &reply) catch |err| switch (err) {
            error.End => return error.Refused,
            else => return err,
        };
        const info = reply.body.port_info;
        if (info.id == graph.NONE) continue;
        if (info.default != 0 and info.direction == direction) return info.id;
    }
}
