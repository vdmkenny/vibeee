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
const usb = @import("lib").usb;

const WHERE = 10;
const ID = 11;
const SPEED = 7;
const CLASS = 14;
const DRIVER = 12;

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

    ink.use(.dim);
    out.pad("where", WHERE);
    out.pad("id", ID);
    out.pad("speed", SPEED);
    out.pad("class", CLASS);
    out.text("driver\n");
    ink.plain();

    var index: u32 = 0;
    while (true) : (index += 1) {
        var row = proto.Rep{};
        proto.call(.{ .tag = .device, .index = index }, &row) catch break;
        const device = row.body.device;
        // A sparse table: an address of zero is a slot nothing occupies,
        // not the end of the walk.
        if (device.address == 0) continue;
        describe(device);
    }
    out.flush();
}

fn describe(device: proto.DeviceInfo) void {
    var buf: [24]u8 = @splat(0);

    // Where it is reads the way a machine is labelled: which controller,
    // which port on it, and the address the bus handed out.
    var where = str.Builder{ .buf = &buf };
    where.number(device.controller);
    where.byte('-');
    where.number(device.port);
    where.byte('.');
    where.number(device.address);
    ink.use(.dim);
    out.pad(where.done(), WHERE);

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
        ink.write(.dim, "none");
    } else {
        out.text(driver);
    }
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
