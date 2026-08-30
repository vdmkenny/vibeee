//! Host-side tests for the quirk registry.
//!
//! The registry is pure data in, corrections out, which is exactly what
//! makes it testable without the machine: an identity is a handful of
//! strings, and whether a quirk recognises it is an ordinary function.

const quirks = @import("quirks.zig");
const eeepc = @import("eeepc.zig");
const std = @import("std");

const asus_701 = quirks.Identity{
    .dmi = .{
        .system_vendor = "ASUSTeK Computer INC.",
        .system_product = "701",
    },
};

const asus_1005 = quirks.Identity{
    .dmi = .{
        .system_vendor = "ASUSTeK Computer INC.",
        .system_product = "1005HA",
    },
};

const lenovo_701 = quirks.Identity{
    .dmi = .{
        .system_vendor = "LENOVO",
        .system_product = "701",
    },
};

/// The whole family shares one rule list, so one check covers all of its
/// quirks.
fn familyMatches(identity: quirks.Identity) bool {
    return quirks.matches(eeepc.ec_ports.rules, identity);
}

test "the family rule recognises its exact models" {
    try std.testing.expect(familyMatches(asus_701));
}

test "the family rule covers the 900 and 1000 lines by prefix" {
    try std.testing.expect(familyMatches(asus_1005));
    try std.testing.expect(familyMatches(.{ .dmi = .{
        .system_vendor = "ASUSTeK Computer INC.",
        .system_product = "900A",
    } }));
}

test "the family rule needs the vendor as well as the product" {
    try std.testing.expect(!familyMatches(lenovo_701));
    try std.testing.expect(!familyMatches(.{ .dmi = .{
        .system_vendor = "ASUSTeK Computer INC.",
        .system_product = "1234",
    } }));
}

test "evaluation records the corrections of the quirks that match" {
    quirks.evaluate(asus_701);

    const corrections = quirks.get();
    try std.testing.expectEqual(@as(?u16, 0x62), corrections.ec_data_port);
    try std.testing.expectEqual(@as(?u16, 0x66), corrections.ec_status_port);
    try std.testing.expect(corrections.battery_percent_mislabel);

    const applied = quirks.appliedQuirks();
    try std.testing.expectEqual(@as(usize, 2), applied.len);
    try std.testing.expectEqualStrings("eeepc-ec-ports", applied[0].name);
    try std.testing.expectEqualStrings("eeepc-battery-percent", applied[1].name);
}
