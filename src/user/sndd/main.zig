//! sndd: the sound service.
//!
//! One process, one event loop, and a routing graph in the middle: every
//! program that makes or takes sound is a node with ports, the hardware
//! is a node like any other, and links decide who hears whom. Fan-in is
//! mixed, fan-out is copied, and the defaults point at the hardware until
//! somebody points them elsewhere.
//!
//! Frames ride shared rings; the channel carries only the graph's verbs.
//! The pace of everything is the hardware's period interrupt: the service
//! wakes when the engine finishes a period, mixes the next one from
//! whatever feeds the sink, and goes back to sleep. An idle machine takes
//! no interrupts and burns nothing; a playing one wakes at the period
//! rate and does a bounded mix each time. Nothing here polls.

const ac97 = @import("ac97.zig");
const audio = @import("lib").audio;
const dev = @import("dev.zig");
const graph_mod = @import("lib").audiograph;
const irqroute = @import("ulib").irqroute;
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pci = @import("ulib").pci;
const proto = @import("proto").audio;
const proto_devices = @import("proto").devices;
const str = @import("ulib").str;
const std = @import("std");
const sys = @import("sys");

/// The drivers this build knows. Which silicon each fits is the device
/// manager's knowledge, declared in `/lib/drivers/*.man`; this table only
/// joins an assigned name to the code compiled in beside this file.
const Driver = struct {
    name: []const u8,
    ops: dev.PcmOps,
};

const DRIVERS = [_]Driver{
    .{ .name = ac97.name, .ops = ac97.ops },
};

/// One driven device is this machine's world; the array exists so a second
/// is a constant away.
const MAX_DEVICES = 2;

var devices: [MAX_DEVICES]dev.PcmDev = undefined;
var device_count: usize = 0;

/// Which graph ports belong to the hardware, per device.
const DevicePorts = struct {
    sink: graph_mod.PortId = graph_mod.NONE,
    source: graph_mod.PortId = graph_mod.NONE,
};
var device_ports: [MAX_DEVICES]DevicePorts = @splat(.{});

var graph = graph_mod.Graph{};

/// The ring behind a client port, kept by port slot. A slot's segment is
/// made once and handed to each successive port on it, because segments
/// cannot be unmapped: churn allocates nothing.
const ClientRing = struct {
    shm: u32 = 0,
    ev: u32 = 0,
    view: ?proto.View = null,
};
var rings: [graph_mod.MAX_PORTS]ClientRing = @splat(.{});

var service: u32 = 0;
var doorbell: u32 = 0;

/// After this many consecutive silent periods the playback engine stops:
/// roughly a tenth of a second of nothing is a machine with nothing to
/// say, and a stopped engine is a machine taking no interrupts.
const QUIET_LIMIT = 16;

export fn _start() callconv(.c) noreturn {
    snddMain();
}

fn snddMain() noreturn {
    const channel = sys.svcRegister(proto.SERVICE);
    if (channel < 0) {
        log.note("sndd", "already serving; letting this instance stand down");
        sys.exit(0);
    }
    service = @intCast(channel);

    probe();
    if (device_count == 0) {
        log.warn("sndd", "no sound hardware matched a driver");
    }

    const bell = sys.eventCreate();
    if (bell < 0) {
        log.fail("sndd", "no doorbell; giving up");
        sys.exit(1);
    }
    doorbell = @intCast(bell);

    serve();
}

fn probe() void {
    var index: u32 = 0;
    while (device_count < MAX_DEVICES) : (index += 1) {
        var assignment = proto_devices.Assignment{};
        proto_devices.claimNext(proto.SERVICE, index, &assignment) catch break;

        for (DRIVERS) |driver| {
            if (!str.eql(driver.name, assignment.driverSlice())) continue;
            attach(driver, @bitCast(assignment.location));
        }
    }
}

fn attach(driver: Driver, location: pci.Location) void {
    if (sys.claimDevice(location) < 0) {
        log.warn("sndd", "the device is already claimed");
        return;
    }

    var candidate = dev.PcmDev{
        .name = driver.name,
        .ops = driver.ops,
        .location = location,
    };

    if (!driver.ops.open(location)) {
        _ = sys.releaseDevice(location);
        return;
    }

    if (irqroute.routedLine("sndd", location)) |gsi| {
        if (sys.irqAttach(gsi)) |taken| {
            candidate.irq = taken;
            candidate.irq_gsi = gsi;
        } else |err| {
            log.begin("sndd", .warn);
            out.text("line ");
            out.decimal(gsi);
            out.text(" refused: ");
            out.text(@errorName(err));
            log.end();
            _ = sys.releaseDevice(location);
            return;
        }
    } else {
        log.warn("sndd", "no interrupt line; device unused");
        _ = sys.releaseDevice(location);
        return;
    }

    // The hardware enters the graph as an ordinary node: one sink that is
    // the way out of the machine, one source that is the way in. The
    // defaults point at the first hardware until somebody repoints them.
    const node_name = graph_mod.Name.of(driver.name) orelse return;
    const node = graph.addNode(node_name, .device, 0) catch return;
    const sink = graph.addPort(node, graph_mod.Name.of("out").?, .sink) catch return;
    const source = graph.addPort(node, graph_mod.Name.of("in").?, .source) catch return;
    device_ports[device_count] = .{ .sink = sink, .source = source };
    if (graph.default_sink == graph_mod.NONE) graph.default_sink = sink;
    if (graph.default_source == graph_mod.NONE) graph.default_source = source;

    devices[device_count] = candidate;
    device_count += 1;
    log.note("sndd", "driving the hardware");
}

// ---------------------------------------------------------------------------
// The event loop
// ---------------------------------------------------------------------------

fn serve() noreturn {
    var sources: [2 + MAX_DEVICES]u32 = undefined;
    sources[0] = service;
    sources[1] = doorbell;
    var source_count: usize = 2;
    for (devices[0..device_count]) |device| {
        sources[source_count] = device.irq;
        source_count += 1;
    }

    while (true) {
        // A running engine paces the loop with its own interrupts; the
        // deadline is only the stall watchdog. A silent machine waits
        // forever and costs nothing.
        const timeout: usize = if (anyRunning()) 150_000 else sys.FOREVER;
        const woke = sys.waitMany(sources[0..source_count], timeout);

        if (woke < 0) {
            recoverStall();
            continue;
        }

        const index: usize = @intCast(woke);
        if (index == 0) {
            drain();
        } else if (index == 1) {
            wakeSinks();
        } else {
            const device = &devices[index - 2];
            const done = device.ops.irq();
            if (done.any()) advance(device, done);
            _ = sys.irqAck(device.irq);
        }
    }
}

fn anyRunning() bool {
    for (devices[0..device_count]) |device| {
        if (device.running[0] or device.running[1]) return true;
    }
    return false;
}

/// The watchdog fired with an engine running: the period interrupts have
/// stopped arriving. Stop and restart rather than guess why.
fn recoverStall() void {
    for (devices[0..device_count], 0..) |*device, i| {
        if (!device.running[@intFromEnum(dev.Direction.playback)]) continue;
        log.warn("sndd", "playback stalled; restarting the engine");
        stopPlayback(device);
        startPlaybackIfFed(device, &device_ports[i]);
    }
}

/// A producer rang: someone pushed frames or made a link worth serving.
fn wakeSinks() void {
    for (devices[0..device_count], 0..) |*device, i| {
        startPlaybackIfFed(device, &device_ports[i]);
        syncCapture(device, &device_ports[i]);
    }
}

fn startPlaybackIfFed(device: *dev.PcmDev, dports: *const DevicePorts) void {
    const playing = &device.running[@intFromEnum(dev.Direction.playback)];
    if (playing.* or dports.sink == graph_mod.NONE) return;
    if (!graph.hasSource(dports.sink)) return;

    // Prime the queue before the engine moves: the mix-ahead is the whole
    // latency budget, so exactly this many and no more.
    device.fill = 0;
    device.quiet_periods = 0;
    for (0..dev.QUEUE_AHEAD) |_| {
        mixPeriod(device, dports.sink);
    }
    if (device.ops.start(.playback)) playing.* = true;
}

fn stopPlayback(device: *dev.PcmDev) void {
    device.ops.stop(.playback);
    device.running[@intFromEnum(dev.Direction.playback)] = false;
}

/// Capture runs exactly while something is linked from the device source.
fn syncCapture(device: *dev.PcmDev, dports: *const DevicePorts) void {
    const capturing = &device.running[@intFromEnum(dev.Direction.capture)];
    const wanted = dports.source != graph_mod.NONE and sinksOf(dports.source) != 0;
    if (wanted and !capturing.*) {
        device.drain = 0;
        if (device.ops.start(.capture)) capturing.* = true;
    } else if (!wanted and capturing.*) {
        device.ops.stop(.capture);
        capturing.* = false;
    }
}

fn sinksOf(source: graph_mod.PortId) usize {
    var listed: [graph_mod.MAX_LINKS]graph_mod.PortId = undefined;
    return graph.sinksFrom(source, &listed).len;
}

/// Periods completed: refill playback behind the engine, hand capture
/// forward, and stop a stream that has gone quiet.
fn advance(device: *dev.PcmDev, done: dev.Completions) void {
    const found = indexOf(device) orelse return;
    const dports = &device_ports[found];

    for (0..done.playback) |_| {
        mixPeriod(device, dports.sink);
    }
    if (done.playback != 0 and device.quiet_periods >= QUIET_LIMIT) {
        stopPlayback(device);
    }

    for (0..done.capture) |_| {
        pourPeriod(device, dports.source);
    }
}

fn indexOf(device: *dev.PcmDev) ?usize {
    for (devices[0..device_count], 0..) |*candidate, i| {
        if (candidate == device) return i;
    }
    return null;
}

/// One playback period: everything linked into the sink, mixed with each
/// feeder's own volume, into the device's next slot.
fn mixPeriod(device: *dev.PcmDev, sink: graph_mod.PortId) void {
    const buf = device.ops.period(.playback, device.fill);
    device.fill +%= 1;
    @memset(buf, 0);

    if (sink == graph_mod.NONE) return;
    const sink_port = graph.portAt(sink) orelse return;
    if (sink_port.muted) {
        device.quiet_periods +|= 1;
        return;
    }

    var feeders: [graph_mod.MAX_LINKS]graph_mod.PortId = undefined;
    const feeding = graph.sourcesInto(sink, &feeders);

    var heard = false;
    var scratch: [dev.PERIOD_FRAMES * 2]i16 = undefined;
    for (feeding) |feeder| {
        const port = graph.portAt(feeder) orelse continue;
        const ring = rings[feeder].view orelse continue;

        const scratch_bytes = std.mem.sliceAsBytes(&scratch);
        const got = ring.frames.pop(scratch_bytes);
        if (got == 0) {
            ring.ctrl.starved +%= 1;
            continue;
        }
        heard = true;
        _ = sys.eventSignal(rings[feeder].ev);

        const volume = audio.Volume{ .percent = port.volume, .muted = port.muted };
        const samples: []i16 = @alignCast(std.mem.bytesAsSlice(i16, buf[0..got]));
        for (samples, scratch[0 .. got / 2]) |*into, sample| {
            into.* = audio.mix(into.*, volume.apply(sample));
        }
    }

    device.quiet_periods = if (heard) 0 else device.quiet_periods +| 1;
}

/// One capture period: the device's frames into every ring linked from
/// its source port, each with the source's volume applied.
fn pourPeriod(device: *dev.PcmDev, source: graph_mod.PortId) void {
    const buf = device.ops.period(.capture, device.drain);
    device.drain +%= 1;
    if (source == graph_mod.NONE) return;

    const source_port = graph.portAt(source) orelse return;
    const volume = audio.Volume{ .percent = source_port.volume, .muted = source_port.muted };

    var listed: [graph_mod.MAX_LINKS]graph_mod.PortId = undefined;
    for (graph.sinksFrom(source, &listed)) |sink| {
        const ring = rings[sink].view orelse continue;
        if (volume.percent == 100 and !volume.muted) {
            _ = ring.frames.push(buf);
        } else {
            var scaled: [dev.PERIOD_FRAMES * 2]i16 = undefined;
            const samples = std.mem.bytesAsSlice(i16, buf);
            for (samples, 0..) |sample, i| scaled[i] = volume.apply(sample);
            _ = ring.frames.push(std.mem.sliceAsBytes(&scaled));
        }
        _ = sys.eventSignal(rings[sink].ev);
    }
}

// ---------------------------------------------------------------------------
// The channel: the graph's verbs
// ---------------------------------------------------------------------------

fn drain() void {
    while (true) {
        var message = sys.Message{};
        const request = sys.recv(service, &message, sys.POLL) orelse return;
        handle(&message, request.token);
    }
}

fn handle(message: *const sys.Message, token: u32) void {
    const bytes = message.bytes();
    if (bytes.len < @sizeOf(proto.Req)) return refuse(token);
    const req: *const proto.Req = @ptrCast(@alignCast(bytes.ptr));

    switch (req.tag) {
        .node_create => nodeCreate(req, message.sender, token),
        .port_create => portCreate(req, message.sender, token),
        .port_drop => portDrop(req, message.sender, token),
        .link => joinPorts(req, token, true),
        .unlink => joinPorts(req, token, false),
        .set_default => setDefault(req, token),
        .set_volume => setVolume(req, token),
        .get_node => getNode(req, token),
        .get_port => getPort(req, token),
        .get_link => getLink(req, token),
        .get_master => getMaster(token),
    }
}

fn nodeCreate(req: *const proto.Req, sender: u32, token: u32) void {
    const node_name = graph_mod.Name.of(req.nameSlice()) orelse return refuse(token);
    const id = graph.addNode(node_name, .program, sender) catch return refuse(token);
    replyBody(token, .{ .id = id });
}

fn portCreate(req: *const proto.Req, sender: u32, token: u32) void {
    const node: graph_mod.NodeId = @intCast(req.a & 0xFFFF);
    const owner = graph.nodeAt(node) orelse return refuse(token);
    if (owner.owner != sender) return refuse(token);

    const port_name = graph_mod.Name.of(req.nameSlice()) orelse return refuse(token);
    const direction: graph_mod.Direction = if (req.dir == 0) .source else .sink;
    const port = graph.addPort(node, port_name, direction) catch return refuse(token);

    const ring = &rings[port];
    if (ring.view == null) {
        const created = sys.shmCreate(proto.shmBytes());
        if (created < 0) {
            graph.removePort(port);
            return refuse(token);
        }
        const base = sys.shmMap(@intCast(created), .{ .writable = true }) orelse {
            _ = sys.close(@intCast(created));
            graph.removePort(port);
            return refuse(token);
        };
        const ev = sys.eventCreate();
        if (ev < 0) {
            graph.removePort(port);
            return refuse(token);
        }
        ring.shm = @intCast(created);
        ring.ev = @intCast(ev);
        ring.view = proto.View.of(base);
    }
    ring.view.?.ctrl.* = .{};

    var reply = proto.Rep{ .body = .{ .port = port } };
    var answer = sys.Message.init(std.mem.asBytes(&reply), &.{ ring.shm, ring.ev, doorbell });
    _ = sys.replyMsg(service, token, &answer);
}

fn portDrop(req: *const proto.Req, sender: u32, token: u32) void {
    const port: graph_mod.PortId = @intCast(req.a & 0xFFFF);
    const found = graph.portAt(port) orelse return refuse(token);
    const owner = graph.nodeAt(found.node) orelse return refuse(token);
    if (owner.owner != sender or owner.owner == 0) return refuse(token);
    graph.removePort(port);
    replyBody(token, .{ .id = 0 });
}

fn joinPorts(req: *const proto.Req, token: u32, joining: bool) void {
    const source: graph_mod.PortId = @intCast(req.a & 0xFFFF);
    const sink: graph_mod.PortId = @intCast(req.b & 0xFFFF);
    const outcome = if (joining) graph.link(source, sink) else graph.unlink(source, sink);
    outcome catch return refuse(token);
    replyBody(token, .{ .id = 0 });
    // The topology changed: engines may need to run, or may stand down.
    wakeSinks();
}

fn setDefault(req: *const proto.Req, token: u32) void {
    const port: graph_mod.PortId = @intCast(req.a & 0xFFFF);
    const found = graph.portAt(port) orelse return refuse(token);
    switch (found.direction) {
        .sink => graph.default_sink = port,
        .source => graph.default_source = port,
    }
    replyBody(token, .{ .id = 0 });
}

fn setVolume(req: *const proto.Req, token: u32) void {
    const port: graph_mod.PortId = @intCast(req.a & 0xFFFF);
    if (graph.portAt(port) == null) return refuse(token);
    graph.ports[port].volume = @intCast(@min(req.b, 100));
    graph.ports[port].muted = req.dir != 0;

    // The hardware sink's volume is the hardware's own: the codec has an
    // attenuator, and using it beats scaling every sample in software.
    for (devices[0..device_count], device_ports[0..device_count]) |*device, dports| {
        if (dports.sink == port) {
            device.ops.setMaster(.{
                .percent = graph.ports[port].volume,
                .muted = graph.ports[port].muted,
            });
        }
    }
    replyBody(token, .{ .id = 0 });
}

fn getNode(req: *const proto.Req, token: u32) void {
    const id: graph_mod.NodeId = @intCast(req.a & 0xFFFF);
    if (id >= graph_mod.MAX_NODES) return replyEnd(token);
    const node = graph.nodeAt(id) orelse return replyEnd(token);

    var info = proto.NodeInfo{ .kind = node.kind, .name_len = node.name.len };
    @memcpy(info.name[0..node.name.len], node.name.slice());
    replyBody(token, .{ .node = info });
}

fn getPort(req: *const proto.Req, token: u32) void {
    const id: graph_mod.PortId = @intCast(req.a & 0xFFFF);
    if (id >= graph_mod.MAX_PORTS) return replyEnd(token);
    const port = graph.portAt(id) orelse return replyEnd(token);

    var info = proto.PortInfo{
        .node = port.node,
        .id = id,
        .name_len = port.name.len,
        .direction = port.direction,
        .volume = port.volume,
        .muted = @intFromBool(port.muted),
        .default = @intFromBool(graph.default_sink == id or graph.default_source == id),
    };
    @memcpy(info.name[0..port.name.len], port.name.slice());
    replyBody(token, .{ .port_info = info });
}

fn getLink(req: *const proto.Req, token: u32) void {
    var seen: u32 = 0;
    for (graph.links) |edge| {
        if (!edge.live) continue;
        if (seen == req.a) {
            replyBody(token, .{ .link_info = .{ .source = edge.source, .sink = edge.sink } });
            return;
        }
        seen += 1;
    }
    replyEnd(token);
}

fn getMaster(token: u32) void {
    const sink = graph.default_sink;
    const port = graph.portAt(sink) orelse return refuse(token);
    replyBody(token, .{ .volume = .{
        .percent = port.volume,
        .muted = @intFromBool(port.muted),
    } });
}

fn refuse(token: u32) void {
    var reply = proto.Rep{ .status = .refused };
    replyWith(token, &reply);
}

fn replyEnd(token: u32) void {
    var reply = proto.Rep{ .status = .end };
    replyWith(token, &reply);
}

fn replyBody(token: u32, body: proto.Body) void {
    var reply = proto.Rep{ .body = body };
    replyWith(token, &reply);
}

fn replyWith(token: u32, reply: *const proto.Rep) void {
    var answer = sys.Message.init(std.mem.asBytes(reply), &.{});
    _ = sys.replyMsg(service, token, &answer);
}

comptime {
    _ = lib;
    _ = out;
}
