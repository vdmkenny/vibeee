//! Walking what the firmware described, so somebody can see it.
//!
//! The methods a machine offers are not knowable in advance: two netbooks of
//! the same year expose brightness under different names, and an ASUS puts
//! several of its own beside the standard ones. Guessing which are there and
//! reporting nothing when the guess is wrong is how a driver becomes a mystery.
//!
//! So this reports what is actually in the namespace, one device at a time, and
//! whether each of the methods worth having is present. It is the instrument
//! that says how the rest should be written.

const proto = @import("proto").platform;
const uacpi = @import("uacpi.zig");

/// Devices are counted and described in one walk each, because uACPI hands
/// them to a callback and a reply carries one: the index says which one to
/// stop at.
const Wanted = struct {
    index: u8,
    seen: u8 = 0,
    into: *proto.Device,
    found: bool = false,
    /// Whether to stop at devices or at everything. A device's children are
    /// its methods and values, which is what a caller looking for a vendor's
    /// own methods needs to see.
    devices_only: bool = true,
};

var wanted: Wanted = undefined;

/// The nth device, or `end` once the walk runs out.
///
/// The whole namespace is walked each time and stopped at the wanted one.
/// Wasteful and correct: uACPI hands nodes to a callback, a reply carries one
/// device, and a table cached here would be a second copy of a namespace that
/// is already in memory a few pages away.
pub fn describe(index: u8, into: *proto.Device) proto.Status {
    into.* = .{};
    wanted = .{ .index = index, .into = into };

    _ = uacpi.namespace_for_each_child_simple(uacpi.namespace_root(), visit, null);
    return if (wanted.found) .ok else .end;
}

fn visit(_: ?*anyopaque, node: ?*uacpi.Node, depth: u32) callconv(.c) u32 {
    // A child walk wants the named device's own children and not their
    // children in turn, which is a different question and a much longer answer.
    if (!wanted.devices_only and depth > 1) return uacpi.CONTINUE;

    // Everything under the root is offered, most of it the methods and values
    // that belong to a device rather than devices. Listing those would report
    // `_HID` as a thing the machine has.
    if (wanted.devices_only and !uacpi.isDevice(node)) return uacpi.CONTINUE;

    if (wanted.seen != wanted.index) {
        wanted.seen += 1;
        return uacpi.CONTINUE;
    }

    const into = wanted.into;
    into.name = uacpi.namespace_node_name(node).text;
    into.methods = methodsOf(node);
    wanted.found = true;
    return uacpi.BREAK;
}

/// One name under the device called `parent`.
///
/// What the fixed columns cannot answer. A vendor's methods are called
/// whatever the vendor called them, so the only way to find out what a machine
/// offers is to read the list rather than to check a list of guesses.
pub fn describeChild(parent: []const u8, index: u8, into: *proto.Device) proto.Status {
    into.* = .{};

    const node = uacpi.named(parent) orelse return .unknown;
    wanted = .{ .index = index, .into = into, .devices_only = false };

    _ = uacpi.namespace_for_each_child_simple(node, visit, null);
    return if (wanted.found) .ok else .end;
}

/// Which of the methods worth having this device has.
///
/// Asked by looking them up rather than by calling them: a method that exists
/// is what a caller wants to know, and calling one to find out would run
/// firmware code for the sake of a listing.
fn methodsOf(node: ?*uacpi.Node) proto.Methods {
    return .{
        .brightness_levels = uacpi.has(node, "_BCL"),
        .brightness_set = uacpi.has(node, "_BCM"),
        .brightness_now = uacpi.has(node, "_BQC"),
        .battery_info = uacpi.has(node, "_BIF"),
        .battery_state = uacpi.has(node, "_BST"),
        .power_state = uacpi.has(node, "_STA"),
    };
}
