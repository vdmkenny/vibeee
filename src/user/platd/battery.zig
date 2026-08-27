//! The battery, as the firmware describes it.
//!
//! Two methods, and both are needed for a full answer. `_BIF` is what the pack
//! was built as: how much it was designed to hold, and how much it last managed
//! to hold, which is the pair that says how worn it is. `_BST` is what it is
//! doing now.
//!
//! Neither can be read any other way. The numbers live in embedded-controller
//! registers whose offsets are defined by the firmware's own bytecode and are
//! published nowhere, which is why this is an interpreter's job.

const proto = @import("proto").platform;

const quirks = @import("quirks.zig");
const sys = @import("sys");
const uacpi = @import("uacpi.zig");

const Object = uacpi.Object;
const Node = uacpi.Node;
const ObjectArray = uacpi.ObjectArray;

/// What the ACPI specification calls a control-method battery.
const BATTERY_HID = "PNP0C0A";

/// Where the first battery was found, remembered so a reading does not walk
/// the namespace again. Null until something has looked.
var found: ?*Node = null;
var looked = false;

/// Read the battery, if there is one.
pub fn read(into: *proto.Battery) proto.Status {
    const node = locate() orelse {
        into.* = .{};
        return .ok;
    };

    return readInto(node, into);
}

fn readInto(node: *Node, into: *proto.Battery) proto.Status {
    // The static half is cached: what the pack was built as does not change
    // between two asks, the method walks the embedded controller at length,
    // and asking it twice shortens the distance to a controller that stops
    // answering. One `_BIF` ever, and a repeated ask costs only a `_BST`.
    if (info_read) {
        into.* = cached_info;
    } else {
        into.* = .{ .present = 1 };
        if (!readInfo(node, into)) return .refused;
        info_read = true;
        cached_info = into.*;
    }

    if (!readState(node, into)) return .refused;

    // What the firmware got wrong, set right before the answer leaves. The
    // quirks funnel owns this: each vendor corrects what its own machines
    // misreport, and a machine nobody knows about passes straight through.
    quirks.battery(into);

    // A second opinion on the rate. Some of this machine's readings say the
    // pack is draining and the rate is zero at once, which makes every
    // consumer's estimate silently impossible. Two askings some time apart
    // are a rate of their own: the drop between them over the time between
    // them, and it is used only when the firmware's number is unusable.
    deriveRate(into);

    // The remembered half stays the corrected half, so a correction cannot
    // apply twice to the same numbers.
    cached_info = into.*;
    return .ok;
}

/// The static half, read once.
var info_read = false;
var cached_info = proto.Battery{};

/// What `_BST` said at the previous ask, and when: the pair that becomes a
/// rate when the firmware will not say one.
var last_poll_us: u64 = 0;
var last_remaining: u32 = 0;

/// The least time between two askings worth turning into a rate. Anything
/// sooner is noise: a percentage mislabeled as capacity moves in steps of
/// one, and over seconds that step is a wildly wrong amperage.
const MIN_SAMPLE_SECONDS = 10;

fn deriveRate(into: *proto.Battery) void {
    // Tracked no matter what, so the next ask compares against this one.
    const now = sys.clockMicros();
    defer {
        last_poll_us = now;
        last_remaining = into.remaining;
    }

    // Only while draining, and only when the firmware's own number is one
    // nobody can do arithmetic with.
    if (into.state() != .discharging) return;
    if (into.rate != 0 and into.rate != proto.Battery.UNKNOWN) return;
    if (last_poll_us == 0 or into.remaining == proto.Battery.UNKNOWN) return;

    // Only a drop counts: what was gained between two asks was a charge the
    // machine made room for, not a drain this side can clock.
    if (into.remaining >= last_remaining) return;

    const elapsed_s = (now - last_poll_us) / 1_000_000;
    if (elapsed_s < MIN_SAMPLE_SECONDS) return;

    // Capacity over hours: milliamp-hours over hours is milliamps, and the
    // watt pair is the same shape.
    const drop = last_remaining - into.remaining;
    into.rate = @intCast(@min(@as(u64, drop) * 3600 / elapsed_s, proto.Battery.UNKNOWN - 1));
}

fn locate() ?*Node {
    if (looked) return found;
    looked = true;

    // The first is taken and the rest left alone. This machine has one bay,
    // and a second battery would want its own entry rather than to overwrite
    // the first.
    found = uacpi.firstWithHid(BATTERY_HID);
    return found;
}

/// `_BIF`: what the pack was built as, and what it has come to.
///
/// Thirteen elements, of which the first eight are numbers and the rest are
/// strings. Only the numbers are read: a model name does not fit in a reply
/// and is not what somebody asking about health wants to know.
fn readInfo(node: *Node, into: *proto.Battery) bool {
    var package: ?*Object = null;
    if (uacpi.uacpi_eval_simple_package(node, "_BIF", &package) != .ok) return false;
    defer uacpi.uacpi_object_unref(package);

    var fields: ObjectArray = undefined;
    if (uacpi.uacpi_object_get_package(package, &fields) != .ok) return false;
    if (fields.count < 7) return false;

    // Element zero says which unit the capacities are in. Everything below is
    // reported as it was given, with the unit alongside, because converting
    // milliamp-hours to milliwatt-hours needs a voltage that is itself one of
    // the numbers and the conversion would quietly lose precision twice.
    into.in_milliamps = @intFromBool(integer(fields, 0) == 1);
    into.design = @truncate(integer(fields, 1));
    into.last_full = @truncate(integer(fields, 2));
    into.design_voltage_mv = @truncate(integer(fields, 4));
    into.warning = @truncate(integer(fields, 5));
    into.low = @truncate(integer(fields, 6));
    return true;
}

/// `_BST`: what it is doing now.
fn readState(node: *Node, into: *proto.Battery) bool {
    var package: ?*Object = null;
    if (uacpi.uacpi_eval_simple_package(node, "_BST", &package) != .ok) return false;
    defer uacpi.uacpi_object_unref(package);

    var fields: ObjectArray = undefined;
    if (uacpi.uacpi_object_get_package(package, &fields) != .ok) return false;
    if (fields.count < 4) return false;

    const flags = integer(fields, 0);
    into.charging = @intFromBool(flags & 2 != 0);
    into.discharging = @intFromBool(flags & 1 != 0);
    into.critical = @intFromBool(flags & 4 != 0);

    into.rate = @truncate(integer(fields, 1));
    into.remaining = @truncate(integer(fields, 2));
    into.voltage_mv = @truncate(integer(fields, 3));
    return true;
}

/// One element as a number, or zero.
///
/// Zero for an element that is missing or is not a number, because both mean
/// the same thing to a reader: the firmware did not say. A battery that
/// reports an unknown capacity uses `0xFFFFFFFF` for it, which is left as it
/// came so the caller can tell that apart from a real zero.
fn integer(fields: ObjectArray, index: usize) u64 {
    if (index >= fields.count) return 0;

    var value: u64 = 0;
    if (uacpi.uacpi_object_get_integer(fields.objects[index], &value) != .ok) return 0;
    return value;
}
