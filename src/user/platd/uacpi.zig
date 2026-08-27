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

/// What a call came to. Non-exhaustive: uACPI has more codes than this system
/// acts on, and an unlisted one is still an error.
pub const Status = enum(c_uint) {
    ok = 0,
    not_found = 6,
    not_implemented = 8,
    hardware_timeout = 17,
    denied = 20,
    _,

    /// For the glue exports, whose ABI is the bare number.
    pub fn value(self: Status) c_uint {
        return @intFromEnum(self);
    }
};

/// What a walk does next.
pub const Walk = enum(u32) { proceed = 0, stop = 1 };

pub extern fn uacpi_namespace_root() ?*Node;
pub extern fn uacpi_namespace_node_name(node: ?*Node) Name;
/// The kinds of namespace object. Only one of them is a device, which is the
/// only kind worth listing: the rest are the methods and values that belong to
/// one, and a walk that reported them would report `_HID` as a device.
pub const DEVICE: u32 = 6;

pub extern fn uacpi_namespace_node_type(node: ?*Node, out: *u32) Status;
pub extern fn uacpi_namespace_node_find(
    parent: ?*Node,
    path: [*:0]const u8,
    out: *?*Node,
) Status;
pub extern fn uacpi_namespace_for_each_child_simple(
    parent: ?*Node,
    callback: *const fn (?*anyopaque, ?*Node, u32) callconv(.c) Walk,
    user: ?*anyopaque,
) Status;

pub extern fn uacpi_find_devices(
    hid: [*:0]const u8,
    callback: *const fn (?*anyopaque, ?*Node, u32) callconv(.c) Walk,
    user: ?*anyopaque,
) Status;

pub extern fn uacpi_eval_simple_package(parent: ?*Node, path: [*:0]const u8, ret: *?*Object) Status;
pub extern fn uacpi_eval_simple_integer(parent: ?*Node, path: [*:0]const u8, ret: *u64) Status;
pub extern fn uacpi_object_get_package(object: ?*Object, out: *ObjectArray) Status;
pub extern fn uacpi_object_get_integer(object: ?*Object, out: *u64) Status;
pub extern fn uacpi_object_unref(object: ?*Object) void;
pub extern fn uacpi_object_create_integer(value: u64) ?*Object;
pub extern fn uacpi_eval(
    parent: ?*Node,
    path: [*:0]const u8,
    args: ?*const ObjectArray,
    ret: ?*?*Object,
) Status;

/// Call a method with one integer, which is every setter this system uses:
/// the firmware's own convention is a name ending in S taking a value.
pub fn callWith(node: ?*Node, path: [*:0]const u8, value: u64) bool {
    const argument = uacpi_object_create_integer(value) orelse return false;
    defer uacpi_object_unref(argument);

    var one = [_]?*Object{argument};
    const args = ObjectArray{ .objects = &one, .count = 1 };

    return uacpi_eval(node, path, &args, null) == .ok;
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
    handler: *const fn (?*anyopaque, ?*Node, u64) callconv(.c) Status,
    context: ?*anyopaque,
) Status;

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
) Status;

pub const INTERRUPT_HANDLED: u32 = 1;
pub const GPE_REENABLE: u32 = 1 << 7;

/// How a general-purpose event announces itself.
pub const Triggering = enum(c_uint) { level = 0, edge = 1 };

pub extern fn uacpi_install_gpe_handler(
    device: ?*Node,
    idx: u16,
    triggering: Triggering,
    handler: *const fn (?*anyopaque, ?*Node, u16) callconv(.c) u32,
    context: ?*anyopaque,
) Status;
pub extern fn uacpi_enable_gpe(device: ?*Node, idx: u16) Status;

// ---------------------------------------------------------------------------
// Operation regions
// ---------------------------------------------------------------------------
//
// An operation region is a promise: AML declares that a field lives in some
// address space, and the host moves the actual bytes. Installing a handler is
// how the promise is kept, and uACPI evaluates `_REG` on installation so the
// DSDT knows it is being kept.

pub const SPACE_EMBEDDED_CONTROLLER: c_uint = 3;

/// What uACPI is asking a region handler to do. Non-exhaustive: the serial
/// and vendor spaces have their own operations, and an unhandled one is
/// answered `not_implemented` rather than being a missing case.
pub const RegionOp = enum(u32) {
    attach = 0,
    detach = 1,
    read = 2,
    write = 3,
    _,
};

pub const RegionRw = extern struct {
    handler_context: ?*anyopaque,
    region_context: ?*anyopaque,
    offset: u64 align(4),
    value: u64 align(4),
    byte_width: u8,
};

pub extern fn uacpi_install_address_space_handler(
    device: ?*Node,
    space: c_uint,
    handler: *const fn (op: RegionOp, data: ?*anyopaque) callconv(.c) Status,
    context: ?*anyopaque,
) Status;

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

/// The kinds of resource a `_CRS` can carry. Non-exhaustive: only the ports
/// are read here, and the rest walk past.
pub const ResourceKind = enum(u32) {
    io = 4,
    fixed_io = 5,
    _,
};

pub const ResourceIo = extern struct {
    decode_type: u8,
    minimum: u16,
    maximum: u16,
    alignment: u8,
    length: u8,
};

pub const ResourceFixedIo = extern struct {
    address: u16,
    length: u8,
};

pub const Resource = extern struct {
    kind: ResourceKind,
    length: u32,
    body: extern union {
        io: ResourceIo,
        fixed_io: ResourceFixedIo,
    },
};

pub extern fn uacpi_for_each_device_resource(
    device: ?*Node,
    method: [*:0]const u8,
    callback: *const fn (?*anyopaque, *const Resource) callconv(.c) Walk,
    user: ?*anyopaque,
) Status;

/// The fixed description table, which says which of those buttons exist.
///
/// A fixed-layout table rather than bytecode, so unlike everything else here
/// it is a declared shape rather than an evaluation. Only the fields this
/// system reads are named; the rest are spans, and the offsets the
/// specification fixes are checked where the shape is declared.
pub extern fn uacpi_table_fadt(out: *?*const Fadt) Status;

pub const Fadt = extern struct {
    header: [36]u8,
    firmware_ctrl: u32,
    dsdt: u32,
    _int_model: u8,
    _profile: u8,
    sci_int: u16,
    _blocks: [63]u8,
    _reserved: u8,
    flags: Features,

    comptime {
        if (@offsetOf(Fadt, "firmware_ctrl") != 36) @compileError("the FADT names the FACS at 36");
        if (@offsetOf(Fadt, "sci_int") != 46) @compileError("the FADT names the SCI at 46");
        if (@offsetOf(Fadt, "flags") != 112) @compileError("the FADT keeps its flags at 112");
    }
};

/// The feature flags, stated the other way round for the buttons: a set bit
/// means the button is a device in the namespace rather than a fixed feature,
/// so asking for a fixed handler for it is asking for one that cannot exist.
pub const Features = packed struct(u32) {
    _low: u4 = 0,
    power_button_is_device: bool = false,
    sleep_button_is_device: bool = false,
    _rest: u26 = 0,
};

/// The global lock word inside the firmware control structure.
pub const FACS_GLOBAL_LOCK = 16;

/// The word both sides negotiate through: the owner holds, and a waiter sets
/// pending so the release is announced.
pub const LockWord = packed struct(u32) {
    pending: bool = false,
    owned: bool = false,
    _rest: u30 = 0,
};

/// The lock as it stands, or null when there is no firmware control structure.
///
/// Owned at start-up means every method that takes the lock waits for a
/// release, so this is the one word that says whether locked methods can work
/// at all.
pub fn globalLock() ?GlobalLock {
    var fadt: ?*const Fadt = null;
    if (uacpi_table_fadt(&fadt) != .ok) return null;
    const table = fadt orelse return null;
    if (table.firmware_ctrl == 0) return null;

    const facs = uacpi_kernel_map(table.firmware_ctrl, 64) orelse return null;
    return .{
        .facs = table.firmware_ctrl,
        .word = @as(*align(1) const volatile LockWord, @ptrCast(facs + FACS_GLOBAL_LOCK)).*,
    };
}

pub const GlobalLock = struct {
    /// Where the firmware control structure is, so this can be checked against
    /// the address the table listing reports.
    facs: u32,
    word: LockWord,
};

/// uACPI's own mapping call, which is answered by `glue`. Used here so a table
/// read goes through the one place that knows how firmware memory is reached.
pub extern fn uacpi_kernel_map(phys: u32, len: usize) ?[*]u8;

fn fadtBytes() ?[*]const u8 {
    var fadt: ?*const anyopaque = null;
    if (uacpi_table_fadt(&fadt) != .ok) return null;
    return @ptrCast(fadt orelse return null);
}

pub fn fadtFlags() Features {
    var fadt: ?*const Fadt = null;
    if (uacpi_table_fadt(&fadt) != .ok) return .{};
    return (fadt orelse return .{}).flags;
}

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

fn matchMethod(user: ?*anyopaque, node: ?*Node, _: u32) callconv(.c) Walk {
    const probe: *Probe = @alignCast(@ptrCast(user.?));
    if (!isDevice(node)) return .proceed;
    if (!has(node, probe.method)) return .proceed;

    probe.found = node;
    return .stop;
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

fn keepFirst(user: ?*anyopaque, node: ?*Node, _: u32) callconv(.c) Walk {
    const found: *?*Node = @alignCast(@ptrCast(user.?));
    found.* = node;
    return .stop;
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

fn matchName(user: ?*anyopaque, node: ?*Node, _: u32) callconv(.c) Walk {
    const by: *ByName = @alignCast(@ptrCast(user.?));

    const name = namespace_node_name(node).text;
    if (!sameName(&name, by.wanted)) return .proceed;

    by.found = node;
    return .stop;
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
    if (uacpi_namespace_node_type(node, &kind) != .ok) return false;
    return kind == DEVICE;
}

/// Whether `node` has a child called `name`.
///
/// The question "does this machine offer that method", which is the one worth
/// asking before writing a driver around one.
pub fn has(node: ?*Node, name: [*:0]const u8) bool {
    var found: ?*Node = null;
    return uacpi_namespace_node_find(node, name, &found) == .ok;
}
