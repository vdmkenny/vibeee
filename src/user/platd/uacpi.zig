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

// Shorter names for the ones used often enough that the prefix is noise.
pub const namespace_root = uacpi_namespace_root;
pub const namespace_node_name = uacpi_namespace_node_name;
pub const namespace_for_each_child_simple = uacpi_namespace_for_each_child_simple;

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
