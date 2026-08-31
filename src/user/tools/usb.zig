//! usb: what is plugged in.
//!
//! One row per device the bus enumerated, saying where it is, what it
//! called itself, and which driver the device manager picked for it. A
//! device with no driver against it is one the machine sees but cannot
//! use, which is the usual thing to want to know.

const ink = @import("ulib").ink;
const out = @import("ulib").out;
const proto = @import("proto").usb;
const str = @import("ulib").str;
const tree = @import("ulib").tree;
const usb = @import("lib").usb;

/// Wide enough for a controller and two levels of hub, which is deeper
/// than anything anybody plugs together by hand.
const WHERE = 16;
const ADDRESS = 5;
const ID = 10;
const SPEED = 6;
const CLASS = 9;
const DRIVER = 7;

pub fn run(args: []const []const u8) void {
    if (args.len > 0 and str.eql(args[0], "controllers")) return controllers();
    if (args.len > 0 and str.eql(args[0], "ports")) return ports();
    if (args.len > 0) {
        out.text("usage: usb [ports | controllers]\n");
        out.flush();
        return;
    }

    var reply = proto.Rep{};
    proto.call(.{ .tag = .count }, &reply) catch {
        out.text("usb: the bus service is not answering\n");
        out.flush();
        return;
    };

    if (reply.body.count == 0) {
        out.text("no devices on the bus\n");
        out.flush();
        return;
    }

    gather();
    if (count == 0) {
        out.text("no devices on the bus\n");
        out.flush();
        return;
    }

    ink.use(.dim);
    out.pad("where", WHERE);
    out.pad("addr", ADDRESS);
    out.pad("id", ID);
    out.pad("speed", SPEED);
    out.pad("class", CLASS);
    out.pad("driver", DRIVER);
    out.text("what it calls itself\n");
    ink.plain();

    // A bus is a thing that branches, so it is drawn the way every other
    // branching thing here is drawn.
    var rails: [DEPTH_MAX]tree.Rung = @splat(.last);
    for (found[0..count], 0..) |device, i| {
        const deep = depthOf(device.pathSlice());
        const rung = rungFor(i);
        if (deep < rails.len) rails[deep] = rung;
        describe(device, rails[0..@min(deep, rails.len)], rung);
    }
    out.flush();
}

/// The devices, read once. Drawing a tree means knowing whether a row is
/// the last of its branch, which is a question about the row after it.
const MAX_DEVICES = 16;
const DEPTH_MAX = 4;

var found: [MAX_DEVICES]proto.DeviceInfo = @splat(.{});
var count: usize = 0;

fn gather() void {
    count = 0;
    var index: u32 = 0;
    while (count < found.len) : (index += 1) {
        var row = proto.Rep{};
        proto.call(.{ .tag = .device, .index = index }, &row) catch break;
        // A sparse table: an address of zero is a slot nothing occupies,
        // not the end of the walk.
        if (row.body.device.address == 0) continue;
        found[count] = row.body.device;
        count += 1;
    }
}

/// How deep a path goes: the controller and its port are the first level,
/// and every hub after that is one more.
fn depthOf(path: []const u8) usize {
    var deep: usize = 0;
    for (path) |c| {
        if (c == '.') deep += 1;
    }
    return deep;
}

/// A path without its last component, which is what a device hangs off.
fn parentOf(path: []const u8) []const u8 {
    var at = path.len;
    while (at > 0) {
        at -= 1;
        if (path[at] == '.') return path[0..at];
    }
    return "";
}

/// Whether anything else hanging off the same thing comes after this row.
/// The table is walked in the order devices were found, and a device is
/// always found after the hub it is on, so everything below a row sits
/// after it.
fn rungFor(i: usize) tree.Rung {
    const mine = parentOf(found[i].pathSlice());
    for (found[i + 1 .. count]) |later| {
        if (str.eql(parentOf(later.pathSlice()), mine)) return .more;
    }
    return .last;
}

fn describe(device: proto.DeviceInfo, rails: []const tree.Rung, rung: tree.Rung) void {
    var buf: [24]u8 = @splat(0);

    // Where it is reads the way a machine is traced: the controller, then
    // every port down to the device. A thing on a hub is drawn under the
    // hub, which is where it is.
    ink.use(.dim);
    tree.lead(rails, rung);
    const drawn = (rails.len + 1) * tree.WIDTH;
    out.pad(device.pathSlice(), if (WHERE > drawn) WHERE - drawn else 1);

    var address = str.Builder{ .buf = &buf };
    address.number(device.address);
    out.pad(address.done(), ADDRESS);

    var id = str.Builder{ .buf = &buf };
    id.hex(device.vendor, 4);
    id.byte(':');
    id.hex(device.product, 4);
    out.pad(id.done(), ID);
    ink.plain();

    out.pad(device.speed.spell(), SPEED);

    // What the device says it is. A device answering `per interface`
    // put the truth in its interfaces, and the bus copied that up.
    out.pad(device.class.spell(), CLASS);

    const driver = device.driverSlice();
    if (driver.len == 0) {
        ink.write(.dim, padded("none", DRIVER));
    } else {
        out.pad(driver, DRIVER);
    }

    // What the device says it is, which is the only column here it wrote
    // itself. A device that will not say leaves it blank rather than
    // being given a name by us.
    out.text(nameOf(device.address));
    out.byte('\n');
}

/// Every port on every controller, whether or not anything came of it.
/// A port that is connected but has no address is a device the machine
/// sees and could not enumerate, which is a different fault from a port
/// with nothing in it.
fn ports() void {
    ink.use(.dim);
    out.pad("port", 8);
    out.pad("state", 14);
    out.pad("speed", SPEED);
    out.text("address\n");
    ink.plain();

    var index: u32 = 0;
    while (true) : (index += 1) {
        var reply = proto.Rep{};
        proto.call(.{ .tag = .port, .index = index }, &reply) catch break;
        const info = reply.body.port;

        var buf: [16]u8 = @splat(0);
        var where = str.Builder{ .buf = &buf };
        where.number(info.controller);
        where.byte('-');
        where.number(info.number);
        ink.use(.dim);
        out.pad(where.done(), 8);
        ink.plain();

        if (info.connected == 0) {
            ink.write(.dim, "empty");
            out.byte('\n');
            continue;
        }
        if (info.released != 0) {
            out.pad("companion", 14);
        } else if (info.enabled != 0) {
            out.pad("enabled", 14);
        } else {
            out.pad("connected", 14);
        }
        out.pad(info.speed.spell(), SPEED);

        if (info.address == 0) {
            ink.write(.dim, "none");
        } else {
            var number = str.Builder{ .buf = &buf };
            number.number(info.address);
            out.text(number.done());
        }
        out.byte('\n');
    }
    out.flush();
}

/// A device's own name, asked for by the index the listing walked.
var names: [proto.NAME_MAX]u8 = @splat(0);

fn nameOf(address: u8) []const u8 {
    for (found[0..count], 0..) |device, i| {
        if (device.address != address) continue;
        var reply = proto.Rep{};
        proto.call(.{ .tag = .name, .index = @intCast(i) }, &reply) catch return "";
        const text = reply.body.text.slice();
        const n = @min(text.len, names.len);
        @memcpy(names[0..n], text[0..n]);
        return names[0..n];
    }
    return "";
}

/// Text in a fixed column, so it can be handed to `ink.write` whole.
var column: [16]u8 = @splat(0);

fn padded(text: []const u8, width: usize) []const u8 {
    var built = str.Builder{ .buf = &column };
    built.text(text);
    while (built.len < width) built.byte(' ');
    return built.done();
}

fn controllers() void {
    var reply = proto.Rep{};
    proto.call(.{ .tag = .controllers }, &reply) catch {
        out.text("usb: the bus service is not answering\n");
        out.flush();
        return;
    };

    var buf: [16]u8 = @splat(0);
    var text = str.Builder{ .buf = &buf };
    text.number(@intCast(reply.body.count));
    out.text(text.done());
    out.text(if (reply.body.count == 1) " host controller\n" else " host controllers\n");
    out.flush();
}
