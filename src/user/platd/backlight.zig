//! The panel's brightness, however this machine happens to offer it.
//!
//! One interface and a backend per way of doing it, which is the shape the
//! display drivers already take: what a caller wants is a level, and which
//! method carries it there is the machine's business rather than the caller's.
//!
//! The choice is made here rather than in a tool. If a tool chose, every tool
//! would have to, and they would disagree the first time one of them was
//! written against a machine the other had not seen.

const out = @import("ulib").out;
const proto = @import("proto").platform;
const uacpi = @import("uacpi.zig");

/// How a machine offers brightness.
const Backend = struct {
    /// What to call it in the boot log. Which one was picked is the first
    /// thing worth knowing when the panel does not dim, and inferring it from
    /// silence is how an afternoon goes.
    name: []const u8,
    /// Whether this machine has it, and where. Sets `where` when it does.
    find: *const fn () ?*uacpi.Node,
    read: *const fn (node: *uacpi.Node) ?u32,
    write: *const fn (node: *uacpi.Node, level: u32) bool,
    /// Highest level the method accepts. Zero means ask `levels`.
    max: u32,
};

/// Standard first, because a machine that has it is one this works on without
/// knowing anything about who made it. The vendor's own is the fallback, and on
/// the Eee PC it is the only one: the panel there offers no `_BCM` at all.
const backends = [_]Backend{
    .{ .name = "standard", .find = &standardDevice, .read = &standardRead, .write = &standardWrite, .max = 0 },
    .{ .name = "asus", .find = &asusDevice, .read = &asusRead, .write = &asusWrite, .max = ASUS_MAX },
};

/// A backend and the device it drives, found once and kept: the namespace does
/// not change under a running machine.
const Chosen = struct {
    backend: Backend,
    node: *uacpi.Node,
};

var chosen: ?Chosen = null;
var looked = false;

fn pick() ?Chosen {
    if (looked) return chosen;
    looked = true;

    for (backends) |backend| {
        if (backend.find()) |node| {
            chosen = .{ .backend = backend, .node = node };
            return chosen;
        }
    }
    return null;
}

/// Say which way this machine offers it, once, at start-up.
///
/// Probed here rather than on the first request so the answer is in the boot
/// log whether or not anybody asks: a machine whose panel will not dim should
/// not have to be interrogated to find out that nothing claimed it.
pub fn report() void {
    const found = pick() orelse {
        out.text("platd: no backlight; neither _BCM nor a vendor method\n");
        out.flush();
        return;
    };

    out.text("platd: backlight via ");
    out.text(found.backend.name);
    out.text(" on ");
    out.text(trimmed(&uacpi.namespace_node_name(found.node).text));

    // The range too, because it is the thing a caller has to know and the one
    // number that differs between the two ways of doing this.
    var panel = proto.Backlight{};
    if (read(&panel) == .ok and panel.isPresent()) {
        out.text(", level ");
        out.decimal(panel.level);
        out.text(" of ");
        out.decimal(panel.max);
    }
    out.byte('\n');
    out.flush();
}

/// A namespace name is four characters padded with underscores.
fn trimmed(name: []const u8) []const u8 {
    var end = name.len;
    while (end > 0 and (name[end - 1] == '_' or name[end - 1] == 0)) end -= 1;
    return name[0..end];
}

pub fn read(into: *proto.Backlight) proto.Status {
    const found = pick() orelse {
        into.* = .{};
        return .ok;
    };

    const level = found.backend.read(found.node) orelse return .refused;
    into.* = .{
        .present = 1,
        .level = level,
        .max = if (found.backend.max != 0) found.backend.max else standardMax(found.node),
    };
    return .ok;
}

pub fn write(level: u32, into: *proto.Backlight) proto.Status {
    // A machine with no backlight answers a set the same way it answers a
    // read: there is none. Reporting it as a refusal would read as the
    // firmware having said no to something it was never asked.
    const found = pick() orelse {
        into.* = .{};
        return .ok;
    };
    if (!found.backend.write(found.node, level)) return .refused;

    // Read back rather than report what was asked for. A level the firmware
    // clamped is a level the caller should see clamped, and it is the only way
    // to find out what a method actually accepts.
    return read(into);
}

// ---------------------------------------------------------------------------
// The standard way
// ---------------------------------------------------------------------------
//
// `_BCM` sets, `_BQC` reads, `_BCL` lists what the panel accepts. Defined by
// the specification, so a machine that has it needs nothing else known about
// it.

fn standardDevice() ?*uacpi.Node {
    return findWith("_BCM");
}

fn standardRead(node: *uacpi.Node) ?u32 {
    var value: u64 = 0;
    if (uacpi.uacpi_eval_simple_integer(node, "_BQC", &value) != uacpi.OK) return null;
    return @truncate(value);
}

fn standardWrite(node: *uacpi.Node, level: u32) bool {
    return uacpi.callWith(node, "_BCM", level);
}

/// The last entry of `_BCL`, which lists the levels in ascending order after
/// two entries saying what the firmware uses on mains and on battery.
fn standardMax(node: *uacpi.Node) u32 {
    var package: ?*uacpi.Object = null;
    if (uacpi.uacpi_eval_simple_package(node, "_BCL", &package) != uacpi.OK) return 100;
    defer uacpi.uacpi_object_unref(package);

    var levels: uacpi.ObjectArray = undefined;
    if (uacpi.uacpi_object_get_package(package, &levels) != uacpi.OK) return 100;
    if (levels.count == 0) return 100;

    var highest: u64 = 0;
    if (uacpi.uacpi_object_get_integer(levels.objects[levels.count - 1], &highest) != uacpi.OK) {
        return 100;
    }
    return @truncate(highest);
}

// ---------------------------------------------------------------------------
// The Eee PC's way
// ---------------------------------------------------------------------------
//
// `PBLS` sets and `PBLG` reads, on the vendor's own device. The names follow
// the convention every method on it follows: a feature, then S to set it or G
// to get it, which is also how the wireless radio and the card reader are
// reached.
//
// Sixteen levels, which is what the hardware takes and is not discoverable
// from the namespace. Written down here because the alternative is a caller
// asking for a hundred and getting whatever the firmware makes of it.

const ASUS_HID = "ASUS010";
const ASUS_MAX = 15;

fn asusDevice() ?*uacpi.Node {
    return findByHid(ASUS_HID) orelse findWith("PBLS");
}

fn asusRead(node: *uacpi.Node) ?u32 {
    var value: u64 = 0;
    if (uacpi.uacpi_eval_simple_integer(node, "PBLG", &value) != uacpi.OK) return null;
    return @truncate(value);
}

fn asusWrite(node: *uacpi.Node, level: u32) bool {
    return uacpi.callWith(node, "PBLS", @min(level, ASUS_MAX));
}

// ---------------------------------------------------------------------------
// Looking
// ---------------------------------------------------------------------------

var wanted_method: [*:0]const u8 = "";
var found_node: ?*uacpi.Node = null;

/// The first device offering a named method.
fn findWith(method: [*:0]const u8) ?*uacpi.Node {
    wanted_method = method;
    found_node = null;

    _ = uacpi.namespace_for_each_child_simple(uacpi.namespace_root(), offersMethod, null);
    return found_node;
}

fn offersMethod(_: ?*anyopaque, node: ?*uacpi.Node, _: u32) callconv(.c) u32 {
    if (found_node != null) return uacpi.BREAK;
    if (!uacpi.isDevice(node)) return uacpi.CONTINUE;
    if (!uacpi.has(node, wanted_method)) return uacpi.CONTINUE;

    found_node = node;
    return uacpi.BREAK;
}

/// The device the firmware identifies by a hardware id, which is the reliable
/// way to find a vendor's own: the node's name is whatever they called it.
fn findByHid(hid: [*:0]const u8) ?*uacpi.Node {
    found_node = null;
    _ = uacpi.uacpi_find_devices(hid, remember, null);
    return found_node;
}

fn remember(_: ?*anyopaque, node: ?*uacpi.Node, _: u32) callconv(.c) u32 {
    found_node = node;
    return uacpi.BREAK;
}
