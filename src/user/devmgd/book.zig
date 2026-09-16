//! Which manifests the device manager keeps, decided apart from reading
//! them.

const std = @import("std");

pub const Admission = enum {
    /// A driver of that name is already kept: reading again adds nothing.
    known,
    /// There is no room for another driver.
    full,
    keep,
};

/// Whether a manifest naming `name` is kept, beside the `kept` ones, when
/// `max` fit. A driver already kept is known before the room is counted,
/// so a directory read again at the limit refuses nothing it already has.
pub fn admit(kept: anytype, name: []const u8, max: usize) Admission {
    for (kept) |one| {
        if (std.mem.eql(u8, one.name, name)) return .known;
    }
    return if (kept.len >= max) .full else .keep;
}

test "a driver already kept is known, even with no room left" {
    const Kept = struct { name: []const u8 };
    const two = [_]Kept{ .{ .name = "e100" }, .{ .name = "ohci" } };
    try std.testing.expectEqual(Admission.known, admit(&two, "ohci", 2));
    try std.testing.expectEqual(Admission.full, admit(&two, "es1370", 2));
    try std.testing.expectEqual(Admission.keep, admit(&two, "es1370", 3));
    try std.testing.expectEqual(Admission.keep, admit(two[0..0], "e100", 1));
}
