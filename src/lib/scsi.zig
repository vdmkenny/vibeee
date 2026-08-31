//! Bulk-only transport and the small part of SCSI a disk needs.
//!
//! A USB disk is a SCSI target reached through two bulk pipes. The host
//! writes a command block wrapper, moves the data, and reads a status
//! wrapper back; the command inside the wrapper is a SCSI descriptor
//! block. None of that involves a controller, a schedule or an interrupt,
//! so all of it lives here where it can be read and tested on its own.
//!
//! Byte order is the one thing to be careful about: the wrappers are
//! little endian because USB is, and the commands inside them are big
//! endian because SCSI is. Every field is written through a helper that
//! knows which, so the two never get confused at a call site.

const std = @import("std");

// ---------------------------------------------------------------------------
// The wrappers
// ---------------------------------------------------------------------------

pub const Direction = enum(u8) {
    /// Host to device.
    out = 0x00,
    /// Device to host.
    in = 0x80,
};

/// What the device made of a command.
pub const Verdict = enum(u8) {
    passed = 0,
    failed = 1,
    /// The device and the host disagree about what should happen next,
    /// which only a reset recovery clears.
    confused = 2,
    _,
};

/// The command block wrapper: thirty-one bytes on the out pipe, ahead of
/// every command.
pub const Command = extern struct {
    signature: u32 align(1) = SIGNATURE,
    tag: u32 align(1) = 0,
    length: u32 align(1) = 0,
    direction: Direction = .out,
    unit: u8 = 0,
    /// How much of `block` the command actually fills.
    block_length: u8 = 0,
    block: [16]u8 = @splat(0),

    pub const BYTES = 31;
    pub const SIGNATURE: u32 = 0x4342_5355;

    /// A wrapper around one command descriptor block.
    pub fn wrap(tag: u32, unit: u8, direction: Direction, length: u32, block: []const u8) Command {
        var self = Command{
            .tag = tag,
            .length = length,
            .direction = direction,
            .unit = unit,
            .block_length = @intCast(@min(block.len, 16)),
        };
        @memcpy(self.block[0..self.block_length], block[0..self.block_length]);
        return self;
    }
};

/// The command status wrapper: thirteen bytes on the in pipe, after every
/// command.
pub const Status = extern struct {
    signature: u32 align(1) = SIGNATURE,
    tag: u32 align(1) = 0,
    /// How much of the promised transfer did not happen.
    residue: u32 align(1) = 0,
    verdict: Verdict = .passed,

    pub const BYTES = 13;
    pub const SIGNATURE: u32 = 0x5342_5355;

    pub fn parse(bytes: []const u8) ?Status {
        if (bytes.len < BYTES) return null;
        const self = Status{
            .signature = std.mem.readInt(u32, bytes[0..4], .little),
            .tag = std.mem.readInt(u32, bytes[4..8], .little),
            .residue = std.mem.readInt(u32, bytes[8..12], .little),
            .verdict = @enumFromInt(bytes[12]),
        };
        if (self.signature != SIGNATURE) return null;
        return self;
    }

    /// Whether this status answers that command, which is the whole of
    /// the transport's error checking: a wrapper with the wrong tag is a
    /// device that lost its place, not a command that failed.
    pub fn answers(self: Status, tag: u32) bool {
        return self.tag == tag;
    }
};

comptime {
    if (@sizeOf(Command) != Command.BYTES) @compileError("a command wrapper is thirty-one bytes");
    if (@sizeOf(Status) != Status.BYTES) @compileError("a status wrapper is thirteen bytes");
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

pub const Opcode = enum(u8) {
    test_unit_ready = 0x00,
    request_sense = 0x03,
    inquiry = 0x12,
    start_stop_unit = 0x1B,
    prevent_allow_removal = 0x1E,
    read_capacity_10 = 0x25,
    read_10 = 0x28,
    write_10 = 0x2A,
    synchronize_cache_10 = 0x35,
    _,
};

/// A command descriptor block, built into a fixed buffer so nothing here
/// allocates. Six, ten and twelve byte blocks all fit.
pub const Block = struct {
    bytes: [16]u8 = @splat(0),
    length: u8 = 0,

    pub fn slice(self: *const Block) []const u8 {
        return self.bytes[0..self.length];
    }

    fn of(opcode: Opcode, length: u8) Block {
        var self = Block{ .length = length };
        self.bytes[0] = @intFromEnum(opcode);
        return self;
    }

    /// SCSI writes its numbers most significant byte first, which is the
    /// opposite of everything around it.
    fn put32(self: *Block, at: usize, value: u32) void {
        std.mem.writeInt(u32, self.bytes[at..][0..4], value, .big);
    }

    fn put16(self: *Block, at: usize, value: u16) void {
        std.mem.writeInt(u16, self.bytes[at..][0..2], value, .big);
    }
};

/// Is the unit there and ready. The command that costs nothing and is
/// asked before anything else.
pub fn testUnitReady() Block {
    return Block.of(.test_unit_ready, 6);
}

/// What the unit says it is: vendor, product and revision.
pub fn inquiry(length: u8) Block {
    var block = Block.of(.inquiry, 6);
    block.bytes[4] = length;
    return block;
}

/// Why the last command failed.
pub fn requestSense(length: u8) Block {
    var block = Block.of(.request_sense, 6);
    block.bytes[4] = length;
    return block;
}

/// How big the medium is. The answer is the *last* block's number, not a
/// count, which is the classic off-by-one in this whole protocol.
pub fn readCapacity() Block {
    return Block.of(.read_capacity_10, 10);
}

pub fn read10(lba: u32, blocks: u16) Block {
    var block = Block.of(.read_10, 10);
    block.put32(2, lba);
    block.put16(7, blocks);
    return block;
}

pub fn write10(lba: u32, blocks: u16) Block {
    var block = Block.of(.write_10, 10);
    block.put32(2, lba);
    block.put16(7, blocks);
    return block;
}

/// Commit whatever the device is holding. A device that will not do it
/// is a device that was not holding anything.
pub fn synchronizeCache() Block {
    return Block.of(.synchronize_cache_10, 10);
}

/// Spin up or park the medium, which a card reader ignores and a spinning
/// disk does not.
pub fn startStopUnit(start: bool) Block {
    var block = Block.of(.start_stop_unit, 6);
    block.bytes[4] = if (start) 0x01 else 0x00;
    return block;
}

// ---------------------------------------------------------------------------
// The answers
// ---------------------------------------------------------------------------

/// What `read capacity` came back with.
pub const Capacity = struct {
    /// How many blocks the medium holds, counted rather than addressed.
    blocks: u64 = 0,
    block_bytes: u32 = 0,

    pub const BYTES = 8;

    pub fn parse(bytes: []const u8) ?Capacity {
        if (bytes.len < BYTES) return null;
        const last = std.mem.readInt(u32, bytes[0..4], .big);
        const size = std.mem.readInt(u32, bytes[4..8], .big);
        if (size == 0) return null;
        // The device reports the last addressable block, so a medium of
        // one block answers zero. A device answering all ones has no
        // medium in it rather than four billion blocks.
        if (last == 0xFFFF_FFFF) return null;
        return .{ .blocks = @as(u64, last) + 1, .block_bytes = size };
    }

    pub fn bytes_(self: Capacity) u64 {
        return self.blocks * self.block_bytes;
    }
};

/// The sense key: the coarse half of why a command failed.
pub const Sense = enum(u8) {
    none = 0x00,
    recovered = 0x01,
    not_ready = 0x02,
    medium_error = 0x03,
    hardware_error = 0x04,
    illegal_request = 0x05,
    /// The medium changed or the unit was reset. Not a failure so much as
    /// a notice that whatever was known about the device is now stale.
    attention = 0x06,
    data_protect = 0x07,
    aborted = 0x0B,
    _,

    pub fn spell(self: Sense) []const u8 {
        return switch (self) {
            .none => "no error",
            .recovered => "recovered error",
            .not_ready => "not ready",
            .medium_error => "medium error",
            .hardware_error => "hardware error",
            .illegal_request => "illegal request",
            .attention => "attention",
            .data_protect => "write protected",
            .aborted => "aborted",
            _ => "unknown",
        };
    }
};

/// The fixed-format sense answer, which is the only format worth reading.
pub const SenseData = struct {
    sense: Sense = .none,
    /// The fine half: the code and its qualifier, kept together because
    /// neither means anything alone.
    code: u8 = 0,
    qualifier: u8 = 0,

    pub const BYTES = 18;

    pub fn parse(bytes: []const u8) ?SenseData {
        if (bytes.len < 14) return null;
        // Response codes 0x70 and 0x71 are the fixed format, current and
        // deferred; anything else is the descriptor format nothing here
        // asks for.
        if (bytes[0] & 0x7E != 0x70) return null;
        return .{
            .sense = @enumFromInt(@as(u4, @truncate(bytes[2]))),
            .code = bytes[12],
            .qualifier = bytes[13],
        };
    }

    /// Whether the medium is gone, which is what a yanked card reader
    /// answers and what turns a disk into an absent one.
    pub fn mediumGone(self: SenseData) bool {
        return self.sense == .not_ready and self.code == 0x3A;
    }

    /// Whether the medium changed underneath, which invalidates a
    /// capacity and everything cached from it.
    pub fn mediumChanged(self: SenseData) bool {
        return self.sense == .attention and self.code == 0x28;
    }

    /// Whether the unit is still starting. A disk spinning up answers
    /// this for a second or two and then works.
    pub fn starting(self: SenseData) bool {
        return self.sense == .not_ready and self.code == 0x04;
    }
};

/// What `inquiry` came back with, trimmed of the padding SCSI insists on.
pub const Inquiry = struct {
    removable: bool = false,
    vendor: [8]u8 = @splat(' '),
    product: [16]u8 = @splat(' '),

    pub const BYTES = 36;

    pub fn parse(bytes: []const u8) ?Inquiry {
        if (bytes.len < BYTES) return null;
        var self = Inquiry{ .removable = bytes[1] & 0x80 != 0 };
        @memcpy(&self.vendor, bytes[8..16]);
        @memcpy(&self.product, bytes[16..32]);
        return self;
    }

    /// SCSI pads its text with spaces to the full field width, so the
    /// name has to be trimmed before anyone prints it.
    pub fn vendorSlice(self: *const Inquiry) []const u8 {
        return trimmed(&self.vendor);
    }

    pub fn productSlice(self: *const Inquiry) []const u8 {
        return trimmed(&self.product);
    }

    fn trimmed(field: []const u8) []const u8 {
        var end = field.len;
        while (end > 0 and (field[end - 1] == ' ' or field[end - 1] == 0)) end -= 1;
        var start: usize = 0;
        while (start < end and field[start] == ' ') start += 1;
        return field[start..end];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "a command wrapper carries its command and says which way the data goes" {
    const block = read10(0x1234_5678, 8);
    const wrapper = Command.wrap(7, 0, .in, 8 * 512, block.slice());

    try std.testing.expectEqual(Command.SIGNATURE, wrapper.signature);
    try std.testing.expectEqual(@as(u32, 7), wrapper.tag);
    try std.testing.expectEqual(@as(u32, 4096), wrapper.length);
    try std.testing.expectEqual(Direction.in, wrapper.direction);
    try std.testing.expectEqual(@as(u8, 10), wrapper.block_length);

    // The wrapper is written to the wire as it stands, so its bytes are
    // its layout: signature little endian, command big endian inside.
    const wire = std.mem.asBytes(&wrapper);
    try std.testing.expectEqual(@as(usize, 31), wire.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x55, 0x53, 0x42, 0x43 }, wire[0..4]);
    try std.testing.expectEqual(@as(u8, 0x80), wire[12]);
    try std.testing.expectEqualSlices(u8, &.{ 0x28, 0, 0x12, 0x34, 0x56, 0x78, 0, 0, 8, 0 }, wire[15..25]);
}

test "a status wrapper is recognised, matched to its command, and read" {
    var wire: [13]u8 = @splat(0);
    std.mem.writeInt(u32, wire[0..4], Status.SIGNATURE, .little);
    std.mem.writeInt(u32, wire[4..8], 42, .little);
    std.mem.writeInt(u32, wire[8..12], 512, .little);
    wire[12] = 1;

    const status = Status.parse(&wire) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Verdict.failed, status.verdict);
    try std.testing.expectEqual(@as(u32, 512), status.residue);
    try std.testing.expect(status.answers(42));
    try std.testing.expect(!status.answers(43));

    // Anything that is not a status wrapper is refused rather than read.
    wire[0] = 0;
    try std.testing.expect(Status.parse(&wire) == null);
    try std.testing.expect(Status.parse(wire[0..12]) == null);
}

test "the ten byte commands put their numbers the way scsi reads them" {
    const reading = read10(1, 1);
    try std.testing.expectEqual(@as(u8, 10), reading.length);
    try std.testing.expectEqualSlices(u8, &.{ 0x28, 0, 0, 0, 0, 1, 0, 0, 1, 0 }, reading.slice());

    const writing = write10(0xFFFF_FFFF, 0xFFFF);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x2A, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0xFF, 0xFF, 0 },
        writing.slice(),
    );

    try std.testing.expectEqual(@as(u8, 6), testUnitReady().length);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0, 0, 0, 36, 0 }, inquiry(36).slice());
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0, 0, 0, 18, 0 }, requestSense(18).slice());
    try std.testing.expectEqualSlices(u8, &.{ 0x1B, 0, 0, 0, 1, 0 }, startStopUnit(true).slice());
}

test "capacity counts blocks rather than addressing the last one" {
    // Last block 0x00000FFF, 512 bytes each: four thousand and ninety six
    // blocks, two megabytes.
    const answer = [_]u8{ 0, 0, 0x0F, 0xFF, 0, 0, 2, 0 };
    const capacity = Capacity.parse(&answer) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 4096), capacity.blocks);
    try std.testing.expectEqual(@as(u32, 512), capacity.block_bytes);
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), capacity.bytes_());

    // A single block medium answers zero, and is one block.
    const one = [_]u8{ 0, 0, 0, 0, 0, 0, 2, 0 };
    try std.testing.expectEqual(@as(u64, 1), (Capacity.parse(&one) orelse unreachable).blocks);

    // A block size of nothing, or every bit set, is not a medium.
    try std.testing.expect(Capacity.parse(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }) == null);
    try std.testing.expect(Capacity.parse(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 2, 0 }) == null);
    try std.testing.expect(Capacity.parse(&[_]u8{ 0, 0, 0, 0 }) == null);
}

test "sense says what kind of failure it was" {
    var wire: [18]u8 = @splat(0);
    wire[0] = 0x70;
    wire[2] = 0x02;
    wire[12] = 0x3A;

    const gone = SenseData.parse(&wire) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Sense.not_ready, gone.sense);
    try std.testing.expect(gone.mediumGone());
    try std.testing.expect(!gone.mediumChanged());
    try std.testing.expect(!gone.starting());
    try std.testing.expectEqualStrings("not ready", gone.sense.spell());

    wire[12] = 0x04;
    try std.testing.expect((SenseData.parse(&wire) orelse unreachable).starting());

    wire[2] = 0x06;
    wire[12] = 0x28;
    const changed = SenseData.parse(&wire) orelse return error.TestUnexpectedResult;
    try std.testing.expect(changed.mediumChanged());
    try std.testing.expectEqual(Sense.attention, changed.sense);

    // The descriptor format is not read, and neither is a short answer.
    wire[0] = 0x72;
    try std.testing.expect(SenseData.parse(&wire) == null);
    try std.testing.expect(SenseData.parse(wire[0..8]) == null);
}

test "inquiry text is trimmed of the padding scsi insists on" {
    var wire: [36]u8 = @splat(0);
    wire[1] = 0x80;
    @memcpy(wire[8..16], "QEMU    ");
    @memcpy(wire[16..32], "QEMU HARDDISK   ");

    const answer = Inquiry.parse(&wire) orelse return error.TestUnexpectedResult;
    try std.testing.expect(answer.removable);
    try std.testing.expectEqualStrings("QEMU", answer.vendorSlice());
    try std.testing.expectEqualStrings("QEMU HARDDISK", answer.productSlice());
    try std.testing.expect(Inquiry.parse(wire[0..20]) == null);
}
