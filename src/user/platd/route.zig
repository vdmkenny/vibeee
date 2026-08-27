//! Where a PCI interrupt pin actually goes.
//!
//! A device's configuration space holds an interrupt number, and it is the
//! answer to yesterday's question: which 8259 input, in a mode this system
//! does not run. The routing tables in the firmware hold the other answer,
//! keyed to the model the operating system announces through `_PIC`, and on
//! this machine the two disagree by design: the wired port's configuration
//! space says eleven while the table routes it to a controller input the
//! legacy numbering cannot even name.
//!
//! So a driver asks here. The host bridge's table routes the root bus; a
//! bridge's own table routes everything behind it, which is how the
//! specification says a port answers for its children.

const proto = @import("proto").platform;
const uacpi = @import("uacpi.zig");

/// The id every PCI host bridge registers under, either spelling.
const HOST_HID = "PNP0A03";
const HOST_HID_EXPRESS = "PNP0A08";

var host: ?*uacpi.Node = null;
var looked = false;

fn hostBridge() ?*uacpi.Node {
    if (looked) return host;
    looked = true;
    host = uacpi.firstWithHid(HOST_HID) orelse uacpi.firstWithHid(HOST_HID_EXPRESS);
    return host;
}

/// Answer one routing question.
pub fn answer(ask: proto.RouteAsk, into: *proto.Route) proto.Status {
    const bridge = hostBridge() orelse return .unknown;

    // The table that covers the asking device: the host bridge's for the
    // root bus, the carrying bridge's own for everything behind one.
    var parent = bridge;
    var device: u32 = ask.device;
    if (ask.behind_bridge) {
        const adr = (@as(u32, ask.bridge_device) << 16) | ask.bridge_function;
        parent = childByAddress(bridge, adr) orelse return .unknown;
        // A port's table names its child bus's devices; the device behind
        // this machine's ports is device zero, and the ask's device number
        // is on that bus already.
        device = ask.device;
    }

    var table: ?*uacpi.RouteTable = null;
    if (uacpi.uacpi_get_pci_routing_table(parent, &table) != .ok) return .unknown;
    const routes = table orelse return .unknown;
    defer uacpi.uacpi_free_pci_routing_table(routes);

    for (routes.entries()) |entry| {
        // An address of 0xFFFF in the low half means any function; the high
        // half is the device, and 0xFFFF there covers every device on the
        // bus, which is how a port routes whatever is plugged behind it.
        const entry_device = entry.address >> 16;
        if (entry_device != 0xFFFF and entry_device != device) continue;
        if (entry.pin != ask.pin) continue;

        // With the controller model announced, the table speaks in global
        // lines directly. A link node here is the legacy indirection, and
        // resolving one is its own piece of work this build does not carry.
        if (entry.source != null) return .refused;

        into.gsi = entry.index;
        return .ok;
    }
    return .unknown;
}

/// The child of `parent` whose `_ADR` names this device and function.
fn childByAddress(parent: *uacpi.Node, adr: u32) ?*uacpi.Node {
    var finder = Finder{ .wanted = adr };
    _ = uacpi.namespace_for_each_child_simple(parent, matchAddress, &finder);
    return finder.found;
}

const Finder = struct {
    wanted: u32,
    found: ?*uacpi.Node = null,
};

fn matchAddress(user: ?*anyopaque, node: ?*uacpi.Node, depth: u32) callconv(.c) uacpi.Walk {
    const finder: *Finder = @alignCast(@ptrCast(user.?));
    if (depth > 1) return .proceed;

    var adr: u64 = 0;
    if (uacpi.uacpi_eval_simple_integer(node, "_ADR", &adr) != .ok) return .proceed;
    if (@as(u32, @truncate(adr)) != finder.wanted) return .proceed;

    finder.found = node;
    return .stop;
}
