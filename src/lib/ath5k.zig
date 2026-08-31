//! The descriptor rings an Atheros 5212-generation radio works from.
//!
//! The silicon reads and writes one shape: eight words, of which the first
//! two mean the same thing in both directions and the remaining six are
//! read as a transmission's instructions or as a reception's account of
//! what arrived. That is what the union below says, and it is the reason a
//! ring can be one array rather than two.
//!
//! A ring here is a chain rather than a circle the hardware understands:
//! every descriptor names the next one by physical address, and the last
//! names the first. The hardware is given the head and follows links until
//! it meets one it does not own, so the arithmetic that decides what those
//! links say is the whole of the ring's structure, and it is pure.
//!
//! Field positions follow the two independent free implementations of this
//! family, the Linux ath5k driver and OpenBSD's ar5k. No datasheet exists,
//! so what is named here is what both of them agree on and nothing more:
//! a field this file does not spell is one a caller must not invent.

const std = @import("std");

/// A descriptor is eight words on this generation, whichever way it is
/// used. The hardware requires four-byte alignment and reads them in
/// order, so the shape is `extern` rather than packed: these are words at
/// fixed offsets, not a bit string.
pub const DESC_BYTES = 32;

/// The first word of a transmission's instructions.
///
/// Length counts the whole frame including the four-byte check sequence
/// the hardware appends, which is the one field a caller cannot omit.
pub const TxControl0 = packed struct(u32) {
    frame_length: u12 = 0,
    _12: u4 = 0,
    transmit_power: u6 = 0,
    request_rts_cts: bool = false,
    veol: bool = false,
    clear_destination_mask: bool = false,
    antenna_mode: u4 = 0,
    interrupt_request: bool = false,
    encrypt_key_valid: bool = false,
    request_cts: bool = false,
};

/// The second word: how much of the buffer this descriptor covers, and
/// whether another descriptor continues the same frame.
pub const TxControl1 = packed struct(u32) {
    buffer_length: u12 = 0,
    more: bool = false,
    encrypt_key_index: u7 = 0,
    frame_type: u4 = 0,
    no_acknowledgement: bool = false,
    _25: u7 = 0,
};

/// The first status word a completed transmission leaves behind.
pub const TxStatus0 = packed struct(u32) {
    done: bool = false,
    sent: bool = false,
    excessive_retries: bool = false,
    fifo_underrun: bool = false,
    filtered: bool = false,
    _5: u27 = 0,
};

/// What a reception says about the bytes it put in the buffer.
pub const RxStatus0 = packed struct(u32) {
    data_length: u12 = 0,
    _12: u20 = 0,
};

/// Whether the hardware has finished with a receive descriptor, and what
/// it thought of the frame.
///
/// `done` is the ownership bit in both directions: the driver clears it
/// before handing a descriptor over and the hardware sets it when it is
/// finished, so a descriptor with it clear belongs to the radio and must
/// not be touched.
pub const RxStatus1 = packed struct(u32) {
    done: bool = false,
    received: bool = false,
    check_sequence_error: bool = false,
    decrypt_check_error: bool = false,
    physical_error: bool = false,
    decrypt_error: bool = false,
    _6: u26 = 0,

    /// Whether the frame is worth passing up. Anything the hardware
    /// flagged is dropped: a radio hears a great deal that is not for it
    /// and not intact, and the count of those belongs in statistics
    /// rather than in the stack.
    pub fn intact(self: RxStatus1) bool {
        return self.received and !self.check_sequence_error and
            !self.decrypt_check_error and !self.physical_error and
            !self.decrypt_error;
    }
};

/// The six words after the link and the buffer, read one way or the other.
/// One descriptor shape serves both directions because the silicon has
/// only one, and a union says that without costing a byte.
pub const Body = extern union {
    tx: extern struct {
        control0: u32 = 0,
        control1: u32 = 0,
        control2: u32 = 0,
        control3: u32 = 0,
        status0: u32 = 0,
        status1: u32 = 0,
    },
    rx: extern struct {
        status0: u32 = 0,
        status1: u32 = 0,
        _unused: [4]u32 = @splat(0),
    },
};

/// One descriptor as the hardware reads it.
pub const Desc = extern struct {
    /// The next descriptor's physical address, or zero to stop here.
    link: u32 = 0,
    /// The frame buffer's physical address.
    buffer: u32 = 0,
    body: Body = .{ .tx = .{} },

    /// Hand a receive descriptor to the radio: no length, no status, and
    /// the ownership bit clear.
    pub fn armReceive(self: *Desc, buffer_physical: u32, next_physical: u32) void {
        self.link = next_physical;
        self.buffer = buffer_physical;
        self.body = .{ .rx = .{} };
    }

    /// What a completed reception reports.
    pub fn received(self: *const Desc) struct { status: RxStatus1, length: u12 } {
        return .{
            .status = @bitCast(self.body.rx.status1),
            .length = @as(RxStatus0, @bitCast(self.body.rx.status0)).data_length,
        };
    }
};

comptime {
    // The silicon's own shape, proved rather than trusted. A descriptor
    // that is not eight words in this order is one the hardware will read
    // as something else entirely.
    if (@sizeOf(Desc) != DESC_BYTES) @compileError("a 5212 descriptor is eight words");
    if (@offsetOf(Desc, "link") != 0 or @offsetOf(Desc, "buffer") != 4) {
        @compileError("the link and buffer words lead a descriptor");
    }
    if (@offsetOf(Desc, "body") != 8) @compileError("the body follows the first two words");
    if (@sizeOf(Body) != 24) @compileError("a descriptor body is six words either way");
    if (@alignOf(Desc) < 4) @compileError("the hardware reads descriptors word-aligned");

    // The bit positions the two free implementations agree on.
    if (@as(u32, @bitCast(RxStatus1{ .done = true })) != 0x01) {
        @compileError("the ownership bit is the lowest of the status word");
    }
    if (@as(u32, @bitCast(TxStatus0{ .done = true })) != 0x01) {
        @compileError("a transmission reports completion in the same bit a reception does");
    }
    if (@as(u32, @bitCast(TxControl0{ .frame_length = 0xFFF })) != 0x0FFF) {
        @compileError("the frame length is the low twelve bits");
    }
    if (@as(u32, @bitCast(TxControl1{ .more = true })) != 0x1000) {
        @compileError("the continuation bit sits above the buffer length");
    }
}

/// Where a ring's descriptors sit, and what each one's link should say.
///
/// The count is a compile-time number because a ring whose size is not
/// known until it runs is one whose wrap has to be checked at every step.
/// It is a power of two so the wrap is a mask rather than a division,
/// which is the only arithmetic on the packet path.
pub fn Ring(comptime slots: usize) type {
    if (slots < 2 or !std.math.isPowerOfTwo(slots)) {
        @compileError("a ring holds at least two descriptors, and a power of two of them");
    }

    return struct {
        const Self = @This();

        pub const count = slots;
        const mask = slots - 1;

        /// The slot after this one, wrapping at the end.
        pub fn next(index: usize) usize {
            return (index + 1) & mask;
        }

        /// The physical address of one descriptor in a run of them laid
        /// end to end from `base`.
        pub fn addressOf(base: u32, index: usize) u32 {
            return base + @as(u32, @intCast((index & mask) * DESC_BYTES));
        }

        /// What descriptor `index` should name as its successor. The last
        /// names the first, so the hardware walking the chain never runs
        /// off the end of it and never needs telling where to go back to.
        pub fn linkFor(base: u32, index: usize) u32 {
            return addressOf(base, next(index));
        }

        /// Whether a run of this many descriptors starting at `base` fits
        /// below the four gigabyte line the hardware addresses within.
        pub fn addressable(base: u32) bool {
            const bytes = slots * DESC_BYTES;
            return base != 0 and base <= std.math.maxInt(u32) - @as(u32, @intCast(bytes - 1));
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Eight = Ring(8);

test "a ring wraps at its end and nowhere else" {
    try testing.expectEqual(@as(usize, 1), Eight.next(0));
    try testing.expectEqual(@as(usize, 7), Eight.next(6));
    try testing.expectEqual(@as(usize, 0), Eight.next(7));
}

test "descriptors sit one after another, and the last links back to the first" {
    const base: u32 = 0x0020_0000;
    try testing.expectEqual(base, Eight.addressOf(base, 0));
    try testing.expectEqual(base + DESC_BYTES, Eight.addressOf(base, 1));
    try testing.expectEqual(base + 7 * DESC_BYTES, Eight.addressOf(base, 7));

    // The chain closes: following the links from any slot returns to it.
    try testing.expectEqual(base + DESC_BYTES, Eight.linkFor(base, 0));
    try testing.expectEqual(base, Eight.linkFor(base, 7));

    var at: usize = 3;
    for (0..Eight.count) |_| at = Eight.next(at);
    try testing.expectEqual(@as(usize, 3), at);
}

test "a run that would cross the address limit is refused" {
    try testing.expect(Eight.addressable(0x0020_0000));
    try testing.expect(!Eight.addressable(0));
    // The last byte of the run has to be addressable too, not just the first.
    try testing.expect(!Eight.addressable(0xFFFF_FFF0));
    try testing.expect(Eight.addressable(0xFFFF_FF00));
}

test "an armed receive descriptor belongs to the radio and claims nothing" {
    var desc: Desc = .{};
    desc.armReceive(0x0030_0000, 0x0020_0020);

    try testing.expectEqual(@as(u32, 0x0020_0020), desc.link);
    try testing.expectEqual(@as(u32, 0x0030_0000), desc.buffer);

    // Ownership is the hardware's until it sets the bit back.
    const report = desc.received();
    try testing.expect(!report.status.done);
    try testing.expectEqual(@as(u12, 0), report.length);
}

test "a completed reception reports its length and whether it is worth keeping" {
    var desc: Desc = .{};
    desc.armReceive(0x0030_0000, 0x0020_0020);
    desc.body.rx.status0 = @bitCast(RxStatus0{ .data_length = 1500 });
    desc.body.rx.status1 = @bitCast(RxStatus1{ .done = true, .received = true });

    const good = desc.received();
    try testing.expect(good.status.done);
    try testing.expectEqual(@as(u12, 1500), good.length);
    try testing.expect(good.status.intact());

    // Anything the hardware flagged is not worth passing up, however
    // complete the descriptor is.
    for ([_]RxStatus1{
        .{ .done = true, .received = true, .check_sequence_error = true },
        .{ .done = true, .received = true, .physical_error = true },
        .{ .done = true, .received = true, .decrypt_error = true },
        .{ .done = true, .received = true, .decrypt_check_error = true },
        .{ .done = true, .received = false },
    }) |status| {
        try testing.expect(!status.intact());
    }
}

test "one descriptor serves both directions, over the same six words" {
    var desc: Desc = .{};
    desc.body = .{ .tx = .{
        .control0 = @bitCast(TxControl0{ .frame_length = 64, .transmit_power = 20 }),
        .control1 = @bitCast(TxControl1{ .buffer_length = 60 }),
    } };

    const control0: TxControl0 = @bitCast(desc.body.tx.control0);
    try testing.expectEqual(@as(u12, 64), control0.frame_length);
    try testing.expectEqual(@as(u6, 20), control0.transmit_power);

    // The reception's first status word is the same word as the
    // transmission's first control word, which is what the union means.
    try testing.expectEqual(desc.body.tx.control0, desc.body.rx.status0);
}
