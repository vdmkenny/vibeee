//! What the machine's temperature sensors say.
//!
//! A thermal zone is a namespace object rather than a device, so a walk that
//! looks for devices never finds one: they are found by type. `_TMP` is the
//! reading, `_CRT` the temperature at which the firmware will cut the power
//! and `_PSV` the one at which it wants something done about it.
//!
//! All three come in tenths of a kelvin, which is nobody's idea of a
//! temperature. They are converted once, here, so no caller has to know that
//! and no two callers can convert differently.

const proto = @import("proto").platform;

const uacpi = @import("uacpi.zig");

const Node = uacpi.Node;

/// Tenths of a kelvin to tenths of a degree Celsius. Zero when the firmware
/// answered something that cannot be a temperature: absolute zero is not a
/// reading, it is a missing sensor.
fn celsiusTenths(deci_kelvin: u64) i32 {
    if (deci_kelvin == 0 or deci_kelvin > 10_000) return proto.Thermal.UNKNOWN;
    return @as(i32, @intCast(deci_kelvin)) - 2732;
}

/// The zones, found once and kept: the namespace does not grow a sensor
/// while the machine runs.
var zones: [proto.Thermal.MAX_ZONES]?*Node = @splat(null);
var count: usize = 0;
var looked = false;

pub fn read(index: u8, into: *proto.Thermal) proto.Status {
    locate();
    if (index >= count) return .end;

    const node = zones[index] orelse return .end;
    into.* = .{
        .now = value(node, "_TMP"),
        .critical = value(node, "_CRT"),
        .passive = value(node, "_PSV"),
    };

    const raw = uacpi.uacpi_namespace_node_name(node);
    const name = uacpi.trimmed(&raw.text);
    const n = @min(name.len, into.name.len);
    @memcpy(into.name[0..n], name[0..n]);
    into.name_len = @intCast(n);
    return .ok;
}

/// How many zones this machine has.
pub fn zoneCount() usize {
    locate();
    return count;
}

fn value(node: *Node, method: [*:0]const u8) i32 {
    var reading: u64 = 0;
    if (uacpi.uacpi_eval_simple_integer(node, method, &reading) != .ok) {
        return proto.Thermal.UNKNOWN;
    }
    return celsiusTenths(reading);
}

fn locate() void {
    if (looked) return;
    looked = true;
    _ = uacpi.namespace_for_each_child_simple(uacpi.namespace_root(), keepZone, null);
}

fn keepZone(_: ?*anyopaque, node: ?*Node, _: u32) callconv(.c) uacpi.Walk {
    if (count == zones.len) return .stop;
    if (!uacpi.isKind(node, .thermal_zone)) return .proceed;
    zones[count] = node;
    count += 1;
    return .proceed;
}
