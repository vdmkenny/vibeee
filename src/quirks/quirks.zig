//! Platform quirks: corrections for firmware bugs, gathered once during the
//! early probe and handed to everything that comes up afterwards.
//!
//! A quirk is one correction a specific machine needs, declared in its own
//! module under this directory and listed once in `registry`. The probe
//! evaluates the whole registry against what the firmware claims to be, and
//! the corrections are then read wherever they matter: by kernel drivers
//! directly, and by user processes through the `sysinfo` syscall. The
//! knowledge of any machine stays out of every driver's own code.
//!
//! The registry is data in, corrections out. Nothing here imports a driver
//! or the kernel, so the composition root remains the only place that
//! connects the firmware's description to this file.

const std = @import("std");

/// What the probe knows about the machine a quirk is matched against.
/// Strings are borrowed from the SMBIOS table; empty means the firmware did
/// not say.
pub const Identity = struct {
    dmi: Dmi = .{},
    /// ACPI hardware IDs of devices in the namespace, for quirks keyed on a
    /// device id rather than a name. The early probe has none of these: AML
    /// is interpreted in userspace. A HID rule simply does not match until a
    /// caller supplies the list.
    acpi_hids: []const []const u8 = &.{},
};

/// The firmware's own description of the machine, as DMI reports it.
pub const Dmi = struct {
    system_vendor: []const u8 = "",
    system_product: []const u8 = "",
    board_vendor: []const u8 = "",
    board_name: []const u8 = "",
    bios_vendor: []const u8 = "",
    bios_version: []const u8 = "",
};

/// A family of product names one rule matches: any exact name, or any name
/// beginning with one of the prefixes. The split is what lets one quirk
/// cover a whole line ("1000H" and "1005HA" both begin with "100") without
/// enumerating every variant a marketing department ever produced.
pub const Family = struct {
    exact: []const []const u8 = &.{},
    prefixes: []const []const u8 = &.{},
};

/// One recognition criterion. A quirk applies only when every rule it
/// declares matches; a rule that names several values matches when any one
/// of them does.
pub const Rule = union(enum) {
    dmi_vendor: []const u8,
    dmi_products: Family,
    dmi_board: []const u8,
    acpi_hid: []const u8,
};

/// What a quirk may change. Everything is optional: a quirk sets only what
/// it corrects, and a reader sees null, or false, for the rest.
pub const Corrections = struct {
    /// The embedded controller's true port pair, for boards whose DSDT
    /// declares the controller somewhere it is not.
    ec_data_port: ?u16 = null,
    ec_status_port: ?u16 = null,
    /// The battery tables mislabel percentages as capacities; readings are
    /// converted on the way out.
    battery_percent_mislabel: bool = false,
};

pub const Quirk = struct {
    /// Short name, reported in the boot log and through sysinfo.
    name: []const u8,
    /// One complete line for the log: what the firmware gets wrong and what
    /// is done about it. Printed on its own, so it must stand alone.
    why: []const u8,
    rules: []const Rule,
    apply: *const fn (*Corrections) void,
};

const eeepc = @import("eeepc.zig");

/// The registry. A new machine means a new module beside this one and one
/// line here; nothing else in the system learns a machine name.
pub const registry = [_]Quirk{ eeepc.ec_ports, eeepc.battery_percent };

var corrections: Corrections = .{};
var applied: [registry.len]*const Quirk = undefined;
var applied_count: usize = 0;
var evaluated = false;

/// Run every quirk against the machine and record what the matches correct.
///
/// Called once, from the early probe, before anything binds. Afterwards the
/// answers are read without a lock: nothing ever writes again, and the early
/// probe finishes before any other thread exists.
pub fn evaluate(identity: Identity) void {
    if (evaluated) return;
    evaluated = true;

    for (&registry) |*quirk| {
        if (!matches(quirk.rules, identity)) continue;
        quirk.apply(&corrections);
        applied[applied_count] = quirk;
        applied_count += 1;
    }
}

/// The corrections the probe has recorded.
pub fn get() Corrections {
    return corrections;
}

/// Which quirks matched, in evaluation order.
pub fn appliedQuirks() []*const Quirk {
    return applied[0..applied_count];
}

/// Whether every rule a quirk declares recognises this machine.
pub fn matches(rules: []const Rule, identity: Identity) bool {
    for (rules) |rule| switch (rule) {
        .dmi_vendor => |vendor| {
            // Firmware pads DMI strings to fixed widths and varies its own
            // capitalisation between revisions, so a vendor gate compares
            // what it means, not exactly what was written.
            if (!std.ascii.eqlIgnoreCase(trimmed(identity.dmi.system_vendor), vendor)) return false;
        },
        .dmi_products => |family| {
            const product = trimmed(identity.dmi.system_product);
            var found = false;
            for (family.exact) |name| {
                if (std.mem.eql(u8, product, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                for (family.prefixes) |prefix| {
                    if (std.mem.startsWith(u8, product, prefix)) {
                        found = true;
                        break;
                    }
                }
            }
            if (!found) return false;
        },
        .dmi_board => |board| {
            if (!std.mem.eql(u8, trimmed(identity.dmi.board_name), board)) return false;
        },
        .acpi_hid => |hid| {
            var found = false;
            for (identity.acpi_hids) |candidate| {
                if (std.mem.eql(u8, candidate, hid)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        },
    };
    return true;
}

/// Whitespace the firmware is in the habit of padding DMI strings with.
fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}
