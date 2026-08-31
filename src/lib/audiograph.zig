//! Who is connected to whom: the routing graph sound travels through.
//!
//! Everything that makes or takes sound is a node, hardware included. A
//! node has ports: a source port produces frames, a sink port consumes
//! them. A link joins one source to one sink, and the arrangement is a
//! graph rather than a fixed path, so the speakers are not privileged over
//! anything else and a program is not privileged over the microphone.
//!
//! Fan-in is mixing and fan-out is copying, both of them consequences of
//! the topology rather than stages in a pipeline. That is what leaves room
//! for a mixer, an effect or a recorder to arrive later as one more node
//! with ports, changing no code that already exists.
//!
//! This file is the topology alone: identity, connection and the queries
//! the service walks each period. Buffers, rings and hardware belong to
//! the service, which is what keeps this pure and host-tested.

const std = @import("std");

/// A name a node or port answers to, and what a person types to link one.
pub const Name = struct {
    text: [MAX]u8 = @splat(0),
    len: u8 = 0,

    pub const MAX = 15;

    pub fn of(name: []const u8) ?Name {
        if (name.len == 0 or name.len > MAX) return null;
        for (name) |c| {
            // Names are typed into a tool and split on a colon, so a colon
            // inside one would make a port name unspellable.
            const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
            if (!ok) return null;
        }
        var out = Name{ .len = @intCast(name.len) };
        @memcpy(out.text[0..name.len], name);
        return out;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.text[0..@min(self.len, MAX)];
    }

    pub fn is(self: *const Name, other: []const u8) bool {
        return std.mem.eql(u8, self.slice(), other);
    }
};

/// Which way frames travel through a port.
pub const Direction = enum(u8) {
    /// The port produces frames: an application playing, a microphone.
    source = 0,
    /// The port consumes frames: the speakers, a recorder.
    sink = 1,

    pub fn spell(self: Direction) []const u8 {
        return @tagName(self);
    }
};

pub const NodeId = u16;
pub const PortId = u16;
pub const NONE: u16 = 0xFFFF;

/// What a node is, which decides only whether the service owns its
/// buffers or a client does. The graph treats them identically.
pub const Kind = enum(u8) {
    /// A program that opened a connection to the service.
    program = 0,
    /// A device the service itself drives.
    device = 1,
};

pub const Node = struct {
    live: bool = false,
    name: Name = .{},
    kind: Kind = .program,
    /// Which client this node belongs to, so everything it owns goes when
    /// that client does. Zero for the service's own device nodes.
    owner: u32 = 0,
};

pub const Port = struct {
    live: bool = false,
    node: NodeId = NONE,
    name: Name = .{},
    direction: Direction = .source,
    /// Percent, applied as frames leave a source or enter a sink.
    volume: u8 = 100,
    muted: bool = false,
};

pub const Link = struct {
    live: bool = false,
    source: PortId = NONE,
    sink: PortId = NONE,
};

pub const MAX_NODES = 16;
pub const MAX_PORTS = 32;
pub const MAX_LINKS = 32;

pub const Error = error{ Full, NoSuchNode, NoSuchPort, WrongDirection, AlreadyLinked, NotLinked };

/// The whole arrangement. Fixed tables: a machine of this class has a
/// handful of programs making sound, and a graph that cannot grow without
/// bound is one that cannot exhaust memory while something is playing.
pub const Graph = struct {
    nodes: [MAX_NODES]Node = @splat(.{}),
    ports: [MAX_PORTS]Port = @splat(.{}),
    links: [MAX_LINKS]Link = @splat(.{}),

    /// Where sound goes and comes from when nobody says otherwise. These
    /// are designations, not properties: any sink may be the default one.
    default_sink: PortId = NONE,
    default_source: PortId = NONE,

    pub fn addNode(self: *Graph, name: Name, kind: Kind, owner: u32) Error!NodeId {
        for (&self.nodes, 0..) |*node, i| {
            if (node.live) continue;
            node.* = .{ .live = true, .name = name, .kind = kind, .owner = owner };
            return @intCast(i);
        }
        return error.Full;
    }

    /// Remove a node, its ports, and every link those ports were part of.
    pub fn removeNode(self: *Graph, id: NodeId) void {
        if (id >= MAX_NODES or !self.nodes[id].live) return;
        for (&self.ports, 0..) |*port, i| {
            if (port.live and port.node == id) self.removePort(@intCast(i));
        }
        self.nodes[id] = .{};
    }

    /// Everything one client owned, when that client goes away.
    pub fn removeOwner(self: *Graph, owner: u32) void {
        if (owner == 0) return;
        for (&self.nodes, 0..) |*node, i| {
            if (node.live and node.owner == owner) self.removeNode(@intCast(i));
        }
    }

    pub fn addPort(self: *Graph, node: NodeId, name: Name, direction: Direction) Error!PortId {
        if (node >= MAX_NODES or !self.nodes[node].live) return error.NoSuchNode;
        for (&self.ports, 0..) |*port, i| {
            if (port.live) continue;
            port.* = .{ .live = true, .node = node, .name = name, .direction = direction };
            return @intCast(i);
        }
        return error.Full;
    }

    pub fn removePort(self: *Graph, id: PortId) void {
        if (id >= MAX_PORTS or !self.ports[id].live) return;
        for (&self.links) |*edge| {
            if (edge.live and (edge.source == id or edge.sink == id)) edge.* = .{};
        }
        if (self.default_sink == id) self.default_sink = NONE;
        if (self.default_source == id) self.default_source = NONE;
        self.ports[id] = .{};
    }

    /// Join a source to a sink. Direction is checked rather than inferred,
    /// so a mistyped link is refused instead of silently reversed.
    pub fn link(self: *Graph, source: PortId, sink: PortId) Error!void {
        const from = self.portAt(source) orelse return error.NoSuchPort;
        const to = self.portAt(sink) orelse return error.NoSuchPort;
        if (from.direction != .source or to.direction != .sink) return error.WrongDirection;

        for (self.links) |existing| {
            if (existing.live and existing.source == source and existing.sink == sink) {
                return error.AlreadyLinked;
            }
        }
        for (&self.links) |*slot| {
            if (slot.live) continue;
            slot.* = .{ .live = true, .source = source, .sink = sink };
            return;
        }
        return error.Full;
    }

    pub fn unlink(self: *Graph, source: PortId, sink: PortId) Error!void {
        for (&self.links) |*existing| {
            if (existing.live and existing.source == source and existing.sink == sink) {
                existing.* = .{};
                return;
            }
        }
        return error.NotLinked;
    }

    pub fn portAt(self: *const Graph, id: PortId) ?*const Port {
        if (id >= MAX_PORTS or !self.ports[id].live) return null;
        return &self.ports[id];
    }

    pub fn nodeAt(self: *const Graph, id: NodeId) ?*const Node {
        if (id >= MAX_NODES or !self.nodes[id].live) return null;
        return &self.nodes[id];
    }

    /// A port named the way a person writes it: "node:port", or just a
    /// node's name for its only port in that direction.
    pub fn find(self: *const Graph, text: []const u8, direction: Direction) ?PortId {
        var node_part = text;
        var port_part: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
            node_part = text[0..colon];
            port_part = text[colon + 1 ..];
        }

        for (self.ports, 0..) |port, i| {
            if (!port.live or port.direction != direction) continue;
            const node = self.nodeAt(port.node) orelse continue;
            if (!node.name.is(node_part)) continue;
            if (port_part) |wanted| {
                if (!port.name.is(wanted)) continue;
            }
            return @intCast(i);
        }
        return null;
    }

    /// Every source feeding one sink, which is the set the service mixes
    /// together for that sink's next period.
    pub fn sourcesInto(self: *const Graph, sink: PortId, into: []PortId) []PortId {
        var count: usize = 0;
        for (self.links) |edge| {
            if (!edge.live or edge.sink != sink or count == into.len) continue;
            into[count] = edge.source;
            count += 1;
        }
        return into[0..count];
    }

    /// Every sink one source reaches, which is the set its frames are
    /// copied into.
    pub fn sinksFrom(self: *const Graph, source: PortId, into: []PortId) []PortId {
        var count: usize = 0;
        for (self.links) |edge| {
            if (!edge.live or edge.source != source or count == into.len) continue;
            into[count] = edge.sink;
            count += 1;
        }
        return into[0..count];
    }

    /// Whether anything at all feeds this sink, which is how the service
    /// decides between mixing and handing the hardware silence.
    pub fn hasSource(self: *const Graph, sink: PortId) bool {
        for (self.links) |edge| {
            if (edge.live and edge.sink == sink) return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn nameOf(text: []const u8) Name {
    return Name.of(text).?;
}

/// A graph with the two device nodes a machine starts with, and their
/// ports designated as the defaults.
fn withDevices(graph: *Graph) struct { speakers: PortId, mic: PortId } {
    const speaker_node = graph.addNode(nameOf("speakers"), .device, 0) catch unreachable;
    const speakers = graph.addPort(speaker_node, nameOf("in"), .sink) catch unreachable;
    const mic_node = graph.addNode(nameOf("mic"), .device, 0) catch unreachable;
    const mic = graph.addPort(mic_node, nameOf("out"), .source) catch unreachable;
    graph.default_sink = speakers;
    graph.default_source = mic;
    return .{ .speakers = speakers, .mic = mic };
}

test "hardware is a node like any other, and the defaults merely name ports" {
    var graph = Graph{};
    const devices = withDevices(&graph);

    try std.testing.expectEqual(Direction.sink, graph.portAt(devices.speakers).?.direction);
    try std.testing.expectEqual(Direction.source, graph.portAt(devices.mic).?.direction);
    try std.testing.expectEqual(Kind.device, graph.nodeAt(graph.portAt(devices.mic).?.node).?.kind);
    try std.testing.expectEqual(devices.speakers, graph.default_sink);
}

test "two programs into one sink is a mix, by topology alone" {
    var graph = Graph{};
    const devices = withDevices(&graph);

    const music = try graph.addNode(nameOf("music"), .program, 7);
    const music_out = try graph.addPort(music, nameOf("out"), .source);
    const alert = try graph.addNode(nameOf("alert"), .program, 9);
    const alert_out = try graph.addPort(alert, nameOf("out"), .source);

    try graph.link(music_out, devices.speakers);
    try graph.link(alert_out, devices.speakers);

    var feeding: [8]PortId = undefined;
    const sources = graph.sourcesInto(devices.speakers, &feeding);
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expect(graph.hasSource(devices.speakers));
}

test "one source into two sinks is a copy, by the same topology" {
    var graph = Graph{};
    const devices = withDevices(&graph);

    const recorder = try graph.addNode(nameOf("recorder"), .program, 3);
    const recorder_in = try graph.addPort(recorder, nameOf("in"), .sink);

    // The microphone reaches both the speakers and the recorder.
    try graph.link(devices.mic, devices.speakers);
    try graph.link(devices.mic, recorder_in);

    var reaching: [8]PortId = undefined;
    try std.testing.expectEqual(@as(usize, 2), graph.sinksFrom(devices.mic, &reaching).len);
}

test "a link is refused when the directions do not meet" {
    var graph = Graph{};
    const devices = withDevices(&graph);

    // Two sinks cannot be joined, and neither can two sources.
    const recorder = try graph.addNode(nameOf("recorder"), .program, 3);
    const recorder_in = try graph.addPort(recorder, nameOf("in"), .sink);
    try std.testing.expectError(error.WrongDirection, graph.link(devices.speakers, recorder_in));
    try std.testing.expectError(error.WrongDirection, graph.link(devices.mic, devices.mic));

    // And the same link twice is refused rather than doubled, which would
    // play one stream at twice the volume.
    try graph.link(devices.mic, recorder_in);
    try std.testing.expectError(error.AlreadyLinked, graph.link(devices.mic, recorder_in));
    try graph.unlink(devices.mic, recorder_in);
    try std.testing.expectError(error.NotLinked, graph.unlink(devices.mic, recorder_in));
}

test "a program leaving takes its nodes, ports and links with it" {
    var graph = Graph{};
    const devices = withDevices(&graph);

    const player = try graph.addNode(nameOf("player"), .program, 42);
    const out = try graph.addPort(player, nameOf("out"), .source);
    try graph.link(out, devices.speakers);
    try std.testing.expect(graph.hasSource(devices.speakers));

    graph.removeOwner(42);
    try std.testing.expect(!graph.hasSource(devices.speakers));
    try std.testing.expectEqual(@as(?*const Port, null), graph.portAt(out));
    // The devices are untouched: they belong to the service, not a client.
    try std.testing.expect(graph.portAt(devices.speakers) != null);
    try std.testing.expectEqual(devices.speakers, graph.default_sink);
}

test "removing a port removes the designation that named it" {
    var graph = Graph{};
    const devices = withDevices(&graph);
    graph.removePort(devices.speakers);
    try std.testing.expectEqual(@as(PortId, NONE), graph.default_sink);
}

test "ports are found by the name a person types" {
    var graph = Graph{};
    const devices = withDevices(&graph);
    const music = try graph.addNode(nameOf("music"), .program, 7);
    const music_out = try graph.addPort(music, nameOf("out"), .source);

    try std.testing.expectEqual(@as(?PortId, devices.speakers), graph.find("speakers:in", .sink));
    // A node with one port in that direction needs no port name.
    try std.testing.expectEqual(@as(?PortId, devices.speakers), graph.find("speakers", .sink));
    try std.testing.expectEqual(@as(?PortId, music_out), graph.find("music:out", .source));
    // The direction is part of the question: no sink is named "music".
    try std.testing.expectEqual(@as(?PortId, null), graph.find("music", .sink));
    try std.testing.expectEqual(@as(?PortId, null), graph.find("nothing", .sink));
}

test "a name is refused when it could not be typed back" {
    try std.testing.expectEqual(@as(?Name, null), Name.of(""));
    try std.testing.expectEqual(@as(?Name, null), Name.of("a:b"));
    try std.testing.expectEqual(@as(?Name, null), Name.of("Uppercase"));
    try std.testing.expectEqual(@as(?Name, null), Name.of("x" ** 16));
    try std.testing.expect(Name.of("media-player_2").? .is("media-player_2"));
}
