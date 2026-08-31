//! patch: the sound graph's patchbay.
//!
//! Lists who makes sound, who takes it, and which of them are connected;
//! joins and parts them; repoints the defaults; sets a port's own volume.
//! A port is named the way the listing prints it: "node:port", or just
//! the node when it has one port in that direction.
//!
//!   patch                        the whole graph
//!   patch tone:out ac97:out     link a source into a sink
//!   patch -u tone:out ac97:out  part them again
//!   patch default ac97:out      where sound goes when nobody says
//!   patch vol music:out 50      one port's own volume
//!   patch mute music:out        toggle one port's silence

const graph = @import("lib").audiograph;
const ink = @import("ulib").ink;
const out = @import("ulib").out;
const proto = @import("proto").audio;
const str = @import("ulib").str;

pub fn run(args: []const []const u8) void {
    if (args.len == 0) return list();

    if (str.eql(args[0], "-u") and args.len == 3) {
        return join(args[1], args[2], false);
    }
    if (str.eql(args[0], "default") and args.len == 2) {
        return setDefault(args[1]);
    }
    if (str.eql(args[0], "vol") and args.len == 3) {
        return setVolume(args[1], @intCast(@min(str.toUnsigned(args[2]), 100)), null);
    }
    if (str.eql(args[0], "mute") and args.len == 2) {
        return setVolume(args[1], null, null);
    }
    if (args.len == 2) return join(args[0], args[1], true);

    say("usage: patch [[-u] <source> <sink> | default <port> | vol <port> <pct> | mute <port>]\n");
}

// ---------------------------------------------------------------------------
// The listing
// ---------------------------------------------------------------------------

fn list() void {
    var any = false;
    var node_index: u32 = 0;
    while (true) : (node_index += 1) {
        var reply = proto.Rep{};
        proto.call(.{ .tag = .get_node, .a = node_index }, &reply) catch |err| {
            if (err == error.End) break;
            say("patch: the sound service is not answering\n");
            return;
        };
        const node = reply.body.node;
        if (node.name_len == 0) continue;
        any = true;

        ink.write(.key, node.name[0..node.name_len]);
        out.text("  ");
        out.text(@tagName(node.kind));
        out.byte('\n');
        listPorts(node_index);
    }
    if (!any) {
        say("no sound graph; is the service running?\n");
        return;
    }

    listLinks();
    out.flush();
}

fn listPorts(node: u32) void {
    var index: u32 = 0;
    while (true) : (index += 1) {
        var reply = proto.Rep{};
        proto.call(.{ .tag = .get_port, .a = index }, &reply) catch break;
        const port = reply.body.port_info;
        if (port.id == graph.NONE or port.node != node) continue;

        out.text("    ");
        out.text(port.name[0..port.name_len]);
        out.text("  ");
        out.text(port.direction.spell());
        out.text("  vol ");
        out.decimal(port.volume);
        if (port.muted != 0) out.text(" muted");
        if (port.default != 0) out.text("  default");
        out.byte('\n');
    }
}

fn listLinks() void {
    var index: u32 = 0;
    var first = true;
    while (true) : (index += 1) {
        var reply = proto.Rep{};
        proto.call(.{ .tag = .get_link, .a = index }, &reply) catch break;
        const link = reply.body.link_info;

        if (first) {
            out.text("links\n");
            first = false;
        }
        out.text("    ");
        spellPort(link.source);
        out.text(" -> ");
        spellPort(link.sink);
        out.byte('\n');
    }
}

fn spellPort(id: u16) void {
    var reply = proto.Rep{};
    proto.call(.{ .tag = .get_port, .a = id }, &reply) catch return out.text("?");
    const port = reply.body.port_info;
    if (port.id == graph.NONE) return out.text("?");

    var node_reply = proto.Rep{};
    proto.call(.{ .tag = .get_node, .a = port.node }, &node_reply) catch return out.text("?");
    const node = node_reply.body.node;
    out.text(node.name[0..node.name_len]);
    out.byte(':');
    out.text(port.name[0..port.name_len]);
}

// ---------------------------------------------------------------------------
// The verbs
// ---------------------------------------------------------------------------

fn join(source_text: []const u8, sink_text: []const u8, joining: bool) void {
    const source = findPort(source_text, .source) orelse {
        say2("patch: no source named ", source_text);
        return;
    };
    const sink = findPort(sink_text, .sink) orelse {
        say2("patch: no sink named ", sink_text);
        return;
    };

    var reply = proto.Rep{};
    const tag: proto.Tag = if (joining) .link else .unlink;
    proto.call(.{ .tag = tag, .a = source, .b = sink }, &reply) catch {
        say(if (joining) "patch: refused; already linked?\n" else "patch: not linked\n");
        return;
    };
    say(if (joining) "linked\n" else "parted\n");
}

fn setDefault(text: []const u8) void {
    const port = findPort(text, .sink) orelse findPort(text, .source) orelse {
        say2("patch: no port named ", text);
        return;
    };
    var reply = proto.Rep{};
    proto.call(.{ .tag = .set_default, .a = port }, &reply) catch {
        say("patch: refused\n");
        return;
    };
    say("default set\n");
}

fn setVolume(text: []const u8, percent: ?u8, _: ?void) void {
    const port = findPort(text, .sink) orelse findPort(text, .source) orelse {
        say2("patch: no port named ", text);
        return;
    };

    var reply = proto.Rep{};
    proto.call(.{ .tag = .get_port, .a = port }, &reply) catch return say("patch: refused\n");
    const info = reply.body.port_info;

    const wanted: u32 = percent orelse info.volume;
    const mute = if (percent == null) info.muted == 0 else false;
    proto.call(.{
        .tag = .set_volume,
        .a = port,
        .b = wanted,
        .dir = @intFromBool(mute),
    }, &reply) catch return say("patch: refused\n");
    say("set\n");
}

/// A port by the name a person types, walked from the listings.
fn findPort(text: []const u8, direction: graph.Direction) ?u16 {
    var node_part = text;
    var port_part: ?[]const u8 = null;
    for (text, 0..) |c, i| {
        if (c == ':') {
            node_part = text[0..i];
            port_part = text[i + 1 ..];
            break;
        }
    }

    var index: u32 = 0;
    while (true) : (index += 1) {
        var reply = proto.Rep{};
        proto.call(.{ .tag = .get_port, .a = index }, &reply) catch return null;
        const port = reply.body.port_info;
        if (port.id == graph.NONE or port.direction != direction) continue;

        var node_reply = proto.Rep{};
        proto.call(.{ .tag = .get_node, .a = port.node }, &node_reply) catch continue;
        const node = node_reply.body.node;
        if (!str.eql(node.name[0..node.name_len], node_part)) continue;
        if (port_part) |wanted| {
            if (!str.eql(port.name[0..port.name_len], wanted)) continue;
        }
        return port.id;
    }
}

fn say(text: []const u8) void {
    out.text(text);
    out.flush();
}

fn say2(prefix: []const u8, name: []const u8) void {
    out.text(prefix);
    out.text(name);
    out.byte('\n');
    out.flush();
}
