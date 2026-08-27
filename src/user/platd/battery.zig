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

/// uACPI, for the parts of it this needs.
const Object = opaque {};
const Node = opaque {};

const ObjectArray = extern struct {
    objects: [*]?*Object,
    count: usize,
};

extern fn uacpi_find_devices(
    hid: [*:0]const u8,
    callback: *const fn (?*anyopaque, ?*Node, u32) callconv(.c) u32,
    user: ?*anyopaque,
) c_uint;
extern fn uacpi_eval_simple_package(parent: ?*Node, path: [*:0]const u8, ret: *?*Object) c_uint;
extern fn uacpi_object_get_package(object: ?*Object, out: *ObjectArray) c_uint;
extern fn uacpi_object_get_integer(object: ?*Object, out: *u64) c_uint;
extern fn uacpi_object_unref(object: ?*Object) void;

const OK: c_uint = 0;
const KEEP_LOOKING: u32 = 0;
const STOP: u32 = 1;

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

    into.* = .{ .present = 1 };

    // The static half first: without it the live numbers have no scale, and a
    // remaining capacity with nothing to compare it against is a number rather
    // than a state of charge.
    if (!readInfo(node, into)) return .refused;
    if (!readState(node, into)) return .refused;
    return .ok;
}

fn locate() ?*Node {
    if (looked) return found;
    looked = true;

    _ = uacpi_find_devices(BATTERY_HID, remember, null);
    return found;
}

fn remember(_: ?*anyopaque, node: ?*Node, _: u32) callconv(.c) u32 {
    // The first is taken and the rest left alone. This machine has one bay,
    // and a second battery would want its own entry rather than to overwrite
    // the first.
    if (found != null) return STOP;

    found = node;
    return STOP;
}

/// `_BIF`: what the pack was built as, and what it has come to.
///
/// Thirteen elements, of which the first eight are numbers and the rest are
/// strings. Only the numbers are read: a model name does not fit in a reply
/// and is not what somebody asking about health wants to know.
fn readInfo(node: *Node, into: *proto.Battery) bool {
    var package: ?*Object = null;
    if (uacpi_eval_simple_package(node, "_BIF", &package) != OK) return false;
    defer uacpi_object_unref(package);

    var fields: ObjectArray = undefined;
    if (uacpi_object_get_package(package, &fields) != OK) return false;
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
    if (uacpi_eval_simple_package(node, "_BST", &package) != OK) return false;
    defer uacpi_object_unref(package);

    var fields: ObjectArray = undefined;
    if (uacpi_object_get_package(package, &fields) != OK) return false;
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
    if (uacpi_object_get_integer(fields.objects[index], &value) != OK) return 0;
    return value;
}
