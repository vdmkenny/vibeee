//! Pure-Zig tests for the QR encoder.
//!
//! The important correctness check is differential, against libqrencode — see
//! `make qr-verify`, which diffs our matrix against the reference encoder for
//! several payloads and versions. A QR that merely *looks* right is worthless:
//! the failure mode is a panic screen nobody can scan, found only when you are
//! already debugging something else.
//!
//! What lives here is everything that does not need a subprocess.

const std = @import("std");
const qr = @import("kernel/qr.zig");

test "version selection picks the smallest that fits" {
    var code: qr.Code = undefined;
    try qr.encode("hi", &code);
    try std.testing.expectEqual(@as(u8, 21), code.size);

    // 17 bytes + 2 bytes of mode/length overhead = version 1's 19 codewords.
    try qr.encode("A" ** 17, &code);
    try std.testing.expectEqual(@as(u8, 21), code.size);

    // One more byte must spill to version 2.
    try qr.encode("A" ** 18, &code);
    try std.testing.expectEqual(@as(u8, 25), code.size);
}

test "payload beyond version 5 is rejected rather than truncated" {
    var code: qr.Code = undefined;
    try std.testing.expectError(error.PayloadTooLarge, qr.encode("A" ** 200, &code));
}

test "finder patterns land in all three corners" {
    var code: qr.Code = undefined;
    try qr.encode("test", &code);
    const n = code.size;
    for ([_][2]usize{ .{ 0, 0 }, .{ n - 7, 0 }, .{ 0, n - 7 } }) |o| {
        // Outer ring dark, inner gap light, 3x3 core dark.
        try std.testing.expect(code.get(o[0], o[1]));
        try std.testing.expect(!code.get(o[0] + 1, o[1] + 1));
        try std.testing.expect(code.get(o[0] + 3, o[1] + 3));
    }
}

test "timing patterns alternate" {
    var code: qr.Code = undefined;
    try qr.encode("test", &code);
    for (8..code.size - 8) |i| {
        try std.testing.expectEqual(i % 2 == 0, code.get(i, 6));
        try std.testing.expectEqual(i % 2 == 0, code.get(6, i));
    }
}
