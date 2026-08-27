//! uACPI, as Zig sees it.
//!
//! The declarations of what it provides, in one place rather than repeated at
//! each caller. `glue.zig` is the other direction: what it asks of us.

pub const Object = opaque {};
pub const Node = opaque {};

pub const ObjectArray = extern struct {
    objects: [*]?*Object,
    count: usize,
};

/// A namespace name is four characters and never more: the format has no room
/// for a fifth, which is why every ACPI method is called something cryptic.
pub const Name = extern union {
    text: [4]u8,
    id: u32,
};

pub const OK: c_uint = 0;

/// What a walk does next.
pub const CONTINUE: u32 = 0;
pub const BREAK: u32 = 1;

pub extern fn uacpi_namespace_root() ?*Node;
pub extern fn uacpi_namespace_node_name(node: ?*Node) Name;
/// The kinds of namespace object. Only one of them is a device, which is the
/// only kind worth listing: the rest are the methods and values that belong to
/// one, and a walk that reported them would report `_HID` as a device.
pub const DEVICE: u32 = 6;

pub extern fn uacpi_namespace_node_type(node: ?*Node, out: *u32) c_uint;
pub extern fn uacpi_namespace_node_find(
    parent: ?*Node,
    path: [*:0]const u8,
    out: *?*Node,
) c_uint;
pub extern fn uacpi_namespace_for_each_child_simple(
    parent: ?*Node,
    callback: *const fn (?*anyopaque, ?*Node, u32) callconv(.c) u32,
    user: ?*anyopaque,
) c_uint;

pub extern fn uacpi_find_devices(
    hid: [*:0]const u8,
    callback: *const fn (?*anyopaque, ?*Node, u32) callconv(.c) u32,
    user: ?*anyopaque,
) c_uint;

pub extern fn uacpi_eval_simple_package(parent: ?*Node, path: [*:0]const u8, ret: *?*Object) c_uint;
pub extern fn uacpi_eval_simple_integer(parent: ?*Node, path: [*:0]const u8, ret: *u64) c_uint;
pub extern fn uacpi_object_get_package(object: ?*Object, out: *ObjectArray) c_uint;
pub extern fn uacpi_object_get_integer(object: ?*Object, out: *u64) c_uint;
pub extern fn uacpi_object_unref(object: ?*Object) void;
pub extern fn uacpi_object_create_integer(value: u64) ?*Object;
pub extern fn uacpi_eval(
    parent: ?*Node,
    path: [*:0]const u8,
    args: ?*const ObjectArray,
    ret: ?*?*Object,
) c_uint;

/// Call a method with one integer, which is every setter this system uses:
/// the firmware's own convention is a name ending in S taking a value.
pub fn callWith(node: ?*Node, path: [*:0]const u8, value: u64) bool {
    const argument = uacpi_object_create_integer(value) orelse return false;
    defer uacpi_object_unref(argument);

    var one = [_]?*Object{argument};
    const args = ObjectArray{ .objects = &one, .count = 1 };

    return uacpi_eval(node, path, &args, null) == OK;
}

// Shorter names for the ones used often enough that the prefix is noise.
pub const namespace_root = uacpi_namespace_root;
pub const namespace_node_name = uacpi_namespace_node_name;
pub const namespace_for_each_child_simple = uacpi_namespace_for_each_child_simple;

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------

/// What the firmware raises when something happened that it cannot describe by
/// a value changing: a lid closing, a key the keyboard controller never sees.
///
/// A handler on the root receives every one of them, whichever device sent it.
pub extern fn uacpi_install_notify_handler(
    node: ?*Node,
    handler: *const fn (?*anyopaque, ?*Node, u64) callconv(.c) c_uint,
    context: ?*anyopaque,
) c_uint;

/// The buttons wired to the chipset rather than to a device.
///
/// A power button is usually not in the namespace at all: it sets a bit in the
/// power management block, and the firmware never mentions it. So it is asked
/// for by name from a fixed list instead of found.
pub const FixedEvent = enum(c_uint) {
    timer = 1,
    power_button,
    sleep_button,
    rtc,
};

/// Installing one enables it, which is why nothing here enables it.
pub extern fn uacpi_install_fixed_event_handler(
    event: FixedEvent,
    handler: *const fn (?*anyopaque) callconv(.c) u32,
    user: ?*anyopaque,
) c_uint;

pub const INTERRUPT_HANDLED: u32 = 1;

// ---------------------------------------------------------------------------
// Looking
// ---------------------------------------------------------------------------
//
// uACPI hands nodes to a callback with a context pointer, so every search is
// the same three lines around a different test. Here once, because a search
// written again at each caller is a walk that stops at a different place each
// time it is written again.

/// The first device offering a named method, wherever it sits.
///
/// How a machine is asked whether it can do a thing at all. The display device
/// has no hardware id and is known only by offering `_BCM`.
pub fn firstWith(method: [*:0]const u8) ?*Node {
    var probe = Probe{ .method = method };
    _ = namespace_for_each_child_simple(namespace_root(), matchMethod, &probe);
    return probe.found;
}

const Probe = struct {
    method: [*:0]const u8,
    found: ?*Node = null,
};

fn matchMethod(user: ?*anyopaque, node: ?*Node, _: u32) callconv(.c) u32 {
    const probe: *Probe = @alignCast(@ptrCast(user.?));
    if (!isDevice(node)) return CONTINUE;
    if (!has(node, probe.method)) return CONTINUE;

    probe.found = node;
    return BREAK;
}

/// The device the firmware identifies by a hardware id.
///
/// The reliable way to find a vendor's own: what a node is called is whatever
/// the vendor called it, and the id is what they had to register.
pub fn firstWithHid(hid: [*:0]const u8) ?*Node {
    var found: ?*Node = null;
    _ = uacpi_find_devices(hid, keepFirst, @ptrCast(&found));
    return found;
}

fn keepFirst(user: ?*anyopaque, node: ?*Node, _: u32) callconv(.c) u32 {
    const found: *?*Node = @alignCast(@ptrCast(user.?));
    found.* = node;
    return BREAK;
}

/// The node called `name`, wherever it sits. Any node, not only a device: a
/// caller asking for one by name has usually read it off a listing.
pub fn named(name: []const u8) ?*Node {
    if (name.len == 0) return null;

    var by = ByName{ .wanted = name };
    _ = namespace_for_each_child_simple(namespace_root(), matchName, &by);
    return by.found;
}

const ByName = struct {
    wanted: []const u8,
    found: ?*Node = null,
};

fn matchName(user: ?*anyopaque, node: ?*Node, _: u32) callconv(.c) u32 {
    const by: *ByName = @alignCast(@ptrCast(user.?));

    const name = namespace_node_name(node).text;
    if (!sameName(&name, by.wanted)) return CONTINUE;

    by.found = node;
    return BREAK;
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------
//
// Four characters padded with underscores, which is all the format has room
// for. Both directions of that padding belong together.

/// Whether a node's name is the one asked for, so `LID_` and `LID` are the
/// same device asked for two ways.
pub fn sameName(name: *const [4]u8, wanted: []const u8) bool {
    for (name, 0..) |c, i| {
        const asked = if (i < wanted.len) wanted[i] else '_';
        if (c != asked and !(c == '_' and i >= wanted.len)) return false;
    }
    return true;
}

/// The padding off, for showing.
pub fn trimmed(name: []const u8) []const u8 {
    var end = name.len;
    while (end > 0 and (name[end - 1] == '_' or name[end - 1] == 0)) end -= 1;
    return name[0..end];
}

/// Whether this node is a device rather than something belonging to one.
pub fn isDevice(node: ?*Node) bool {
    var kind: u32 = 0;
    if (uacpi_namespace_node_type(node, &kind) != OK) return false;
    return kind == DEVICE;
}

/// Whether `node` has a child called `name`.
///
/// The question "does this machine offer that method", which is the one worth
/// asking before writing a driver around one.
pub fn has(node: ?*Node, name: [*:0]const u8) bool {
    var found: ?*Node = null;
    return uacpi_namespace_node_find(node, name, &found) == OK;
}
