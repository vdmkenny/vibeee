//! The machine's switchable parts, however it happens to switch them.
//!
//! One interface and a backend per way of doing it, the shape the backlight
//! already takes: what a caller wants is the part on or off, and which method
//! carries it there is the machine's business rather than the caller's.
//!
//! The two ways differ in what they need to be told. A vendor's own method
//! switches the part by name and needs nothing else known: it is a method
//! meaning "the wireless", and it works on a machine whose wireless is off the
//! bus entirely, which is the state a part switched off leaves behind. The
//! portable way is the device's own power methods, which are standard and
//! precise and reachable only through the node carrying the device's address,
//! so a caller has to say where the device is.
//!
//! Nothing here decides when a part should be on. That is a question about
//! what the machine is for, and this service holds the firmware rather than
//! the policy.

const std = @import("std");
const vendor = @import("vendor.zig");
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const proto = @import("proto").platform;
const uacpi = @import("uacpi.zig");

const Feature = proto.Feature;

/// How a machine offers a part's power.
const Backend = struct {
    /// Whether this machine has it, and on which node.
    find: *const fn (which: Feature, where: ?lib.pci.Location) ?*uacpi.Node,
    /// Whether it is on. Null when the node would not answer, which is a
    /// machine that can switch a part and cannot report it.
    read: *const fn (which: Feature, node: *uacpi.Node) ?bool,
    write: *const fn (which: Feature, node: *uacpi.Node, on: bool) bool,
};

/// The vendor's own first, because it is the one that works from cold: it
/// names the part itself, so it needs no address and answers on a machine
/// whose part is currently on no bus at all. The standard way is what every
/// other machine is served by.
const backends = [_]Backend{
    .{ .find = &vendorDevice, .read = &vendorRead, .write = &vendorWrite },
    .{ .find = &standardDevice, .read = &standardRead, .write = &standardWrite },
};

// The maker's way, reached through its row. Null at every step on a machine
// of no maker this build knows, or one whose maker switches nothing, which
// is what the standard way is there for.

fn vendorDevice(which: Feature, where: ?lib.pci.Location) ?*uacpi.Node {
    return (vendor.parts() orelse return null).find(which, where);
}

fn vendorRead(which: Feature, node: *uacpi.Node) ?bool {
    return (vendor.parts() orelse return null).read(which, node);
}

fn vendorWrite(which: Feature, node: *uacpi.Node, on: bool) bool {
    return (vendor.parts() orelse return false).write(which, node, on);
}

/// A backend and the node it acts on, or null when nothing here can switch
/// this part on this machine.
const Chosen = struct {
    backend: Backend,
    node: *uacpi.Node,
};

fn pick(which: Feature, where: ?lib.pci.Location) ?Chosen {
    for (backends) |backend| {
        if (backend.find(which, where)) |node| return .{ .backend = backend, .node = node };
    }
    return null;
}

pub fn read(which: Feature, where: ?lib.pci.Location, into: *proto.FeatureState) proto.Status {
    into.* = .{};
    const found = pick(which, where) orelse return .ok;
    const on = found.backend.read(which, found.node) orelse return .refused;
    into.* = .{ .present = 1, .on = @intFromBool(on) };
    return .ok;
}

/// Switch one, and answer with what it is doing afterwards.
///
/// Read back rather than reported as asked: a firmware that took the call and
/// did nothing is the failure worth seeing, and the getter is the only thing
/// that can tell the difference.
pub fn write(which: Feature, where: ?lib.pci.Location, on: bool, into: *proto.FeatureState) proto.Status {
    into.* = .{};
    // A machine with no way to switch it answers a set the same way it
    // answers a read: there is none. Reporting a refusal would read as the
    // firmware having said no to something it was never asked.
    const found = pick(which, where) orelse return .ok;
    if (!found.backend.write(which, found.node, on)) return .refused;
    return read(which, where, into);
}

/// Say what this machine can switch and what state it is in, once, at
/// start-up.
///
/// Asked here rather than on the first request so the answer is in the boot
/// log whether or not anybody asks: a camera that never appears and a radio
/// that is off are the same silence, and one of them is a setting.
pub fn report() void {
    for (std.enums.values(Feature)) |which| {
        var state = proto.FeatureState{};
        if (read(which, null, &state) != .ok or !state.isPresent()) continue;

        log.begin("platd", .key);
        out.text(@tagName(which));
        out.text(if (state.isOn()) " is on" else " is off");
        log.end();
    }
}

// ---------------------------------------------------------------------------
// The standard way
// ---------------------------------------------------------------------------
//
// `_PS0` powers a device up and `_PS3` powers it down, on the device's own
// node, and `_STA` says which it is. The specification defines all three for
// any device the firmware describes, so a machine that gives a part a node
// needs nothing else known about it.
//
// Which node is the part's is the one thing that cannot be guessed. Nothing
// in the specification marks a node as being a radio or a camera: there is no
// hardware id for either and no method only one of them has, so a search by
// either would find some other device and power that down instead. What ties
// a node to a device is `_ADR`, the device's address on its parent bus, and
// that is why a caller has to say where the part is. A caller that has never
// seen the device cannot, and is answered as having no way to switch it,
// which is the truth: this is what a vendor's own methods exist to solve.

fn standardDevice(_: Feature, where: ?lib.pci.Location) ?*uacpi.Node {
    const at = where orelse return null;
    const node = uacpi.firstWithAddress(pciAddress(at)) orelse return null;

    // Both halves, or the node describes a device without offering to switch
    // it: powering down what cannot be powered up is a part that never comes
    // back until the machine is turned off at the wall.
    if (!uacpi.has(node, "_PS0") or !uacpi.has(node, "_PS3")) return null;
    return node;
}

/// What `_ADR` holds for a device on a PCI bus: the device number in the
/// upper half of the low word, the function in the lower.
fn pciAddress(at: lib.pci.Location) u64 {
    return @as(u64, at.device) << 16 | at.function;
}

fn standardRead(_: Feature, node: *uacpi.Node) ?bool {
    return uacpi.status(node).enabled;
}

fn standardWrite(_: Feature, node: *uacpi.Node, on: bool) bool {
    return uacpi.call(node, if (on) "_PS0" else "_PS3");
}
