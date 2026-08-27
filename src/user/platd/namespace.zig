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

fn visit(_: ?*anyopaque, node: ?*uacpi.Node, _: u32) callconv(.c) u32 {
    // Everything under the root is offered, most of it the methods and values
    // that belong to a device rather than devices. Listing those would report
    // `_HID` as a thing the machine has.
    if (!uacpi.isDevice(node)) return uacpi.CONTINUE;

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
