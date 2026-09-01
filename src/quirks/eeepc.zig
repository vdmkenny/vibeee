//! The Eee PC family.
//!
//! One module covers the whole line: these machines share one BIOS vendor,
//! one embedded controller and the same two mistakes, whatever the badge on
//! the lid says. A new member joins by extending the family list, not by
//! adding another quirk.

const quirks = @import("quirks.zig");

/// The family itself: an ASUS machine whose DMI product is one of the Eee
/// line. `exact` names the models, `prefixes` the series whose names vary,
/// the 900 line ships as 900A and 901, the 1000 line as 1000H and 1005HA.
const family = [_]quirks.Rule{
    .{ .dmi_vendor = "ASUSTeK Computer INC." },
    .{ .dmi_products = .{
        .exact = &.{ "700", "701", "702" },
        .prefixes = &.{ "90", "100", "101" },
    } },
};

/// These DSDTs declare the embedded controller inside the ACPI power
/// management block, where only the PM registers live. The controller is on
/// the standard 0x62/0x66 pair, and a read through the wrong address hangs
/// the machine, so the correction is applied before the controller is first
/// touched.
pub const ec_ports = quirks.Quirk{
    .name = "eeepc-ec-ports",
    .why = "the DSDT places the embedded controller in the power management block; correcting to the standard 0x62/0x66 pair",
    .rules = &family,
    .apply = ecPorts,
};

fn ecPorts(c: *quirks.Corrections) void {
    c.ec_data_port = 0x62;
    c.ec_status_port = 0x66;
}

/// `_BIF` and `_BST` report percentages as capacities: "last full 100" next
/// to a design capacity the same table honestly states as 5200 mAh.
/// Everything derived from the pair comes out wrong by that factor unless
/// the reading is converted first.
pub const battery_percent = quirks.Quirk{
    .name = "eeepc-battery-percent",
    .why = "the battery tables mislabel percentages as capacities; readings are converted before they are reported",
    .rules = &family,
    .apply = batteryPercent,
};

fn batteryPercent(c: *quirks.Corrections) void {
    c.battery_percent_mislabel = true;
}

/// This BIOS answers a runtime touch of the interrupt controller's register
/// pair with a System Management Mode trap that may never return, the level
/// completion doorbell included. The PIRQ pins therefore ride the falling
/// edge of their active-low wires, where the controller is owed nothing at
/// runtime, and the drivers' service-until-quiet discipline keeps the edges
/// lossless.
pub const pirq_edge = quirks.Quirk{
    .name = "eeepc-pirq-edge",
    .why = "the firmware traps runtime interrupt controller writes; PIRQ pins ride the falling edge and owe the controller nothing",
    .rules = &family,
    .apply = pirqEdge,
};

fn pirqEdge(c: *quirks.Corrections) void {
    c.pirq_edge_falling = true;
}
