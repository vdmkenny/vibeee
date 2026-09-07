//! What the firmware tables on this machine agree on.
//!
//! ACPI, SMBIOS and the pointer a bootloader hands over are separate standards
//! written by separate committees, and they say the same thing about whether a
//! table is intact: its bytes add up, in eight bits, to zero. Three places
//! here ask that question, and one of them is scanning memory for a table that
//! may not be there at all, where the sum is the only thing telling a real
//! table from a run of bytes that happens to start with the right letters.

const std = @import("std");

/// Whether these bytes carry a firmware table's own checksum: their eight-bit
/// sum is zero, one of the bytes being the checksum that makes it so.
pub fn checksumOk(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum == 0;
}

test "a table sums to zero, and one byte out of place does not" {
    // A header and the byte chosen to make the rest add up.
    var table = [_]u8{ 'R', 'S', 'D', 'T', 0x24, 0x00, 0x00, 0x00, 0x00 };
    var sum: u8 = 0;
    for (table[0 .. table.len - 1]) |b| sum +%= b;
    table[table.len - 1] = 0 -% sum;

    try std.testing.expect(checksumOk(&table));

    table[2] +%= 1;
    try std.testing.expect(!checksumOk(&table));
}

test "nothing at all sums to zero, which is what an empty read looks like" {
    // The caller's business, not this function's: a zero-length slice has a
    // zero sum, so a caller must know how long the table claims to be before
    // it asks.
    try std.testing.expect(checksumOk(&.{}));
}
