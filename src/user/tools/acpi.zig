//! acpi: what the firmware says this machine has.
//!
//! Named after the standard rather than after any system's word for it, the
//! same way `smbios` is.
//!
//! The point is the method columns. Which methods a machine offers is not
//! knowable in advance: two netbooks of the same year expose brightness under
//! different names, and a vendor puts several of its own beside the standard
//! ones. Anything written against a method that turns out to be absent fails
//! silently and looks like a driver bug, so this says what is there first.

const ink = @import("ulib").ink;
const out = @import("ulib").out;
const platform = @import("proto").platform;

/// One column per method, in the order a reader would look for them.
const Column = struct {
    head: []const u8,
    /// Which bit of the reported set this column stands for.
    has: *const fn (platform.Methods) bool,
};

const columns = [_]Column{
    .{ .head = "_BCL", .has = &levels },
    .{ .head = "_BCM", .has = &setBrightness },
    .{ .head = "_BQC", .has = &nowBrightness },
    .{ .head = "_BIF", .has = &batteryInfo },
    .{ .head = "_BST", .has = &batteryState },
    .{ .head = "_STA", .has = &powerState },
};

fn levels(m: platform.Methods) bool {
    return m.brightness_levels;
}
fn setBrightness(m: platform.Methods) bool {
    return m.brightness_set;
}
fn nowBrightness(m: platform.Methods) bool {
    return m.brightness_now;
}
fn batteryInfo(m: platform.Methods) bool {
    return m.battery_info;
}
fn batteryState(m: platform.Methods) bool {
    return m.battery_state;
}
fn powerState(m: platform.Methods) bool {
    return m.power_state;
}

pub fn run(args: []const []const u8) void {
    // Named, and the answer is that device's own methods. A vendor's are
    // called whatever the vendor called them, so the only way to find out what
    // a machine offers is to read the list rather than check a list of guesses.
    if (args.len > 0) return under(args[0]);
    list();
}

fn under(name: []const u8) void {
    ink.use(.dim);
    out.text(name);
    out.text(" offers\n");
    ink.plain();

    var index: u8 = 0;
    var shown: usize = 0;
    while (index < LIMIT) : (index += 1) {
        var reply = platform.Rep{};
        platform.callUnder(.child, name, index, &reply) catch break;

        // Four to a row: these are short and there can be dozens.
        out.pad(reply.body.device.label(), 8);
        shown += 1;
        if (shown % 8 == 0) out.byte('\n');
    }

    if (shown % 8 != 0) out.byte('\n');
    if (shown == 0) {
        out.text("nothing, or no device is called that\n");
    } else {
        out.decimal(shown);
        out.text(if (shown == 1) " name\n" else " names\n");
    }
    out.flush();
}

fn list() void {
    ink.use(.dim);
    out.pad("device", 9);
    for (columns) |column| out.pad(column.head, 6);
    ink.plain();
    out.byte('\n');

    var index: u8 = 0;
    var shown: usize = 0;
    while (index < LIMIT) : (index += 1) {
        var reply = platform.Rep{};
        platform.callAt(.device, index, &reply) catch break;

        write(reply.body.device);
        shown += 1;
    }

    if (shown == 0) {
        out.text("nothing; the platform service may not be answering\n");
    } else {
        out.decimal(shown);
        out.text(if (shown == 1) " device\n" else " devices\n");
    }
    out.flush();
}

fn write(device: platform.Device) void {
    out.pad(device.label(), 9);

    for (columns) |column| {
        // Present or not, rather than a name repeated in every row: the column
        // says which method, so the cell only has to say whether.
        if (column.has(device.methods)) {
            ink.write(.good, "yes   ");
        } else {
            ink.write(.dim, "-     ");
        }
    }
    out.byte('\n');
}

/// A namespace name is four characters, padded with spaces when it is shorter.
/// More than a machine of this age describes, so the walk ends because the
/// answers run out rather than because this stopped asking.
const LIMIT = 64;
