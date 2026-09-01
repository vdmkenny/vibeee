//! A volume served by a process, as both sides see it.
//!
//! The kernel's filesystems read blocks; some of those blocks are on a
//! disk only a userspace driver can reach. This is the shape of the
//! conversation between them, and it lives here because it is the one
//! thing neither side may hold its own version of.
//!
//! A shared area carries the bytes, so a transfer is copied once rather
//! than twice, and the driver's own DMA can land straight in it.
//! Everything else is a request taken one at a time: a queue this shallow
//! does not earn a lock-free ring, and two syscalls are a rounding error
//! beside the transfer they describe.

const std = @import("std");

/// How many volumes one machine plausibly carries: a card reader with a
/// few slots, and something in a socket.
pub const MAX_VOLUMES = 4;

/// How many requests may be outstanding on one volume. Deep enough that
/// several readers do not serialise on each other, shallow enough that
/// the shared area stays small.
pub const DEPTH = 4;

/// The largest transfer one request carries. A longer read is split by
/// the kernel rather than by whatever asked for it.
pub const SLOT_BYTES = 16 * 1024;

/// What the server is asked to do.
pub const Op = enum(u8) {
    read = 0,
    write = 1,
    /// Commit whatever the device is holding.
    flush = 2,
};

/// How it went. Anything but `ok` becomes a block-layer error, and the
/// distinctions matter to whoever is deciding whether to retry.
pub const Status = enum(u8) {
    ok = 0,
    io_error = 1,
    /// The medium was taken out from under the request.
    no_medium = 2,
    timeout = 3,
    write_protected = 4,
    /// The server went away.
    aborted = 5,
    _,
};

pub const Flags = packed struct(u32) {
    read_only: bool = false,
    /// The medium can be taken out, which is what makes a volume worth
    /// unmounting when it goes.
    removable: bool = false,
    _2: u30 = 0,
};

/// One request, as the server reads it.
pub const Request = extern struct {
    tag: u16 = 0,
    op: Op = .read,
    _pad: u8 = 0,
    sectors: u32 = 0,
    lba: u64 align(4) = 0,
    /// Where in the shared data area the bytes are, or go.
    offset: u32 = 0,
    _tail: u32 = 0,
};

/// What a server passes to attach a volume, and what it is told back.
pub const Attach = extern struct {
    sectors: u64 align(4) = 0,
    sector_bytes: u32 = 0,
    flags: Flags = .{},
    /// Filled in by the kernel: the event to wait on, the data area to
    /// map, and how the area is divided.
    doorbell: i32 = -1,
    data: i32 = -1,
    slots: u32 = 0,
    slot_bytes: u32 = 0,
};

comptime {
    if (@sizeOf(Request) != 24) @compileError("a volume request is twenty-four bytes");
    if (@sizeOf(Attach) != 32) @compileError("a volume attachment is thirty-two bytes");
}

test "a request is laid out the way both sides read it" {
    const request = Request{ .tag = 3, .op = .write, .sectors = 8, .lba = 0x1_0000_0000, .offset = 0x4000 };
    const wire = std.mem.asBytes(&request);

    try std.testing.expectEqual(@as(usize, 24), wire.len);
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, wire[0..2], .little));
    try std.testing.expectEqual(@as(u8, 1), wire[2]);
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, wire[4..8], .little));
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), std.mem.readInt(u64, wire[8..16], .little));
    try std.testing.expectEqual(@as(u32, 0x4000), std.mem.readInt(u32, wire[16..20], .little));
}

test "the flags a volume carries sit where the word says" {
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @bitCast(Flags{ .read_only = true })));
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @bitCast(Flags{ .removable = true })));
    try std.testing.expectEqual(@as(u32, 3), @as(u32, @bitCast(Flags{ .read_only = true, .removable = true })));
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(Flags{})));
}

test "a slot holds a whole number of sectors of every ordinary size" {
    try std.testing.expectEqual(@as(usize, 0), SLOT_BYTES % 512);
    try std.testing.expectEqual(@as(usize, 0), SLOT_BYTES % 2048);
    try std.testing.expectEqual(@as(usize, 0), SLOT_BYTES % 4096);
}
