//! The Intel 8255x family's registers, and the blocks it shares with the
//! host: the PRO/100 adapters, and the LAN controller inside ICH2 to ICH7
//! and NM10.
//!
//! Beside the driver so every shape, the configure block and the EEPROM's
//! serial protocol are checked on the build machine. Values from Intel's
//! 8255x developer manual.

const std = @import("std");

// ---------------------------------------------------------------------------
// Control and status registers
// ---------------------------------------------------------------------------

/// The registers reached a byte at a time.
pub const Byte = enum(u32) {
    status = 0x00,
    /// What latched. Writing a one clears that bit.
    events = 0x01,
    command = 0x02,
    interrupts = 0x03,
    eeprom = 0x0E,
};

/// The registers reached a dword at a time.
pub const Dword = enum(u32) {
    /// The address a command names.
    pointer = 0x04,
    port = 0x08,
    mdi = 0x10,
};

pub const ReceiverState = enum(u4) {
    idle = 0,
    suspended = 1,
    /// Stopped at a block it had no room in.
    no_resources = 2,
    ready = 4,
    _,
};

pub const CommandUnitState = enum(u2) {
    idle,
    suspended,
    active,
    priority_active,
};

/// SCB status.
pub const Status = packed struct(u8) {
    _0: u2 = 0,
    receiver: ReceiverState = .idle,
    command_unit: CommandUnitState = .idle,
};

/// SCB STAT/ACK: what latched.
pub const Events = packed struct(u8) {
    /// A flow control pause frame. 82558 on.
    pause: bool = false,
    /// Early receive. 82558 on.
    early_receive: bool = false,
    software: bool = false,
    /// A management cycle ended.
    mdi_done: bool = false,
    /// The receiver left the ready state.
    receiver_stopped: bool = false,
    /// The command unit left the active state.
    command_unit_left: bool = false,
    frame_received: bool = false,
    /// A block with its interrupt bit set completed.
    command_done: bool = false,

    /// What a part that has left the bus reads as.
    pub const GONE: Events = @bitCast(@as(u8, 0xFF));
};

/// SCB interrupt control.
pub const InterruptControl = packed struct(u8) {
    masked: bool = false,
    /// Raise the software interrupt.
    software: bool = false,
    /// One mask per cause, 82558 on. Left clear on every part: the one
    /// mask above is what this driver holds the line with.
    _2: u6 = 0,
};

pub const ReceiverCommand = enum(u3) {
    nop = 0,
    start = 1,
    @"resume" = 2,
    abort = 4,
    load_base = 6,
    _,
};

pub const CommandUnitCommand = enum(u4) {
    nop = 0,
    start = 1,
    @"resume" = 2,
    load_counters_address = 4,
    dump_counters = 5,
    load_base = 6,
    dump_reset_counters = 7,
    _,
};

/// SCB command. Reads zero once the part has accepted the last command.
pub const Command = packed struct(u8) {
    receiver: ReceiverCommand = .nop,
    _3: u1 = 0,
    command_unit: CommandUnitCommand = .nop,
};

pub const PortAction = enum(u4) {
    software_reset = 0,
    self_test = 1,
    /// Stops both units and takes the part off the bus, keeping its
    /// configuration space.
    selective_reset = 2,
    _,
};

/// PORT.
pub const Port = packed struct(u32) {
    action: PortAction,
    _4: u28 = 0,
};

pub const MdiOpcode = enum(u2) {
    write = 1,
    read = 2,
    _,
};

/// MDI control: one management cycle to the PHY.
pub const Mdi = packed struct(u32) {
    data: u16 = 0,
    register: u5 = 0,
    phy: u5 = 0,
    opcode: MdiOpcode = .read,
    /// Set by the part when the cycle has ended.
    ready: bool = false,
    /// Raise `Events.mdi_done` when the cycle ends.
    interrupt: bool = false,
    _30: u2 = 0,
};

/// The EEPROM's four lines, as the control register drives and reads them.
pub const EepromPins = packed struct(u8) {
    clock: bool = false,
    select: bool = false,
    /// To the EEPROM.
    data_in: bool = false,
    /// From the EEPROM.
    data_out: bool = false,
    _4: u4 = 0,
};

comptime {
    for (.{ Status, Events, InterruptControl, Command, EepromPins }) |Shape| {
        if (@bitSizeOf(Shape) != 8) @compileError("an SCB byte register is eight bits");
    }
    if (@bitOffsetOf(Status, "receiver") != 2 or @bitOffsetOf(Status, "command_unit") != 6) {
        @compileError("SCB status fields do not match the part");
    }
    if (@bitOffsetOf(Command, "command_unit") != 4) @compileError("SCB command fields do not match the part");
    if (@bitOffsetOf(Mdi, "phy") != 21 or @bitOffsetOf(Mdi, "ready") != 28) {
        @compileError("MDI control fields do not match the part");
    }
}

// ---------------------------------------------------------------------------
// The part's generations
// ---------------------------------------------------------------------------

/// What a part can do, by its PCI revision.
pub const Generation = enum {
    i82557,
    /// The 82558 and everything after it, the integrated parts included:
    /// flow control, and frames long enough for a VLAN tag.
    i82558_on,

    pub fn of(revision: u8) Generation {
        return if (revision < 4) .i82557 else .i82558_on;
    }
};

// ---------------------------------------------------------------------------
// Blocks in shared memory
// ---------------------------------------------------------------------------

pub const Operation = enum(u3) {
    nop = 0,
    individual_address = 1,
    configure = 2,
    multicast = 3,
    transmit = 4,
    load_microcode = 5,
    dump = 6,
    diagnose = 7,
};

pub const BlockCommand = packed struct(u16) {
    operation: Operation = .nop,
    /// Transmit: the frame is in buffers an array names, not in the block.
    flexible: bool = false,
    /// Transmit: the frame already carries its check sequence.
    no_check_sequence: bool = false,
    _5: u8 = 0,
    interrupt: bool = false,
    /// Stop after this block until the host resumes the unit.
    @"suspend": bool = false,
    /// Stop after this block for good; a receive block with this set is
    /// where the receiver runs out of room.
    end_of_list: bool = false,
};

pub const BlockStatus = packed struct(u16) {
    /// Receive: the error bits, which `ok` already sums up.
    _0: u12 = 0,
    /// Transmit: the part ran out of frame while sending it.
    underrun: bool = false,
    ok: bool = false,
    _14: u1 = 0,
    complete: bool = false,
};

/// Where every block begins.
pub const Header = extern struct {
    status: BlockStatus = .{},
    command: BlockCommand = .{},
    /// The next block's address.
    link: u32 = 0,
};

/// A buffer address naming nothing: the frame is inside the block.
pub const NO_BUFFERS: u32 = 0xFFFF_FFFF;

pub const TransmitCount = packed struct(u16) {
    bytes: u14 = 0,
    _14: u1 = 0,
    /// The whole frame follows the block.
    whole: bool = false,
};

/// A transmit block's own fields, ahead of the frame.
pub const Transmit = extern struct {
    buffers: u32 = NO_BUFFERS,
    count: TransmitCount = .{},
    /// How much of a frame, in eights of a byte, the part holds before
    /// it starts sending. This is more than a frame, so every frame is
    /// sent whole from the part's memory and a slow host cannot starve it.
    threshold: u8 = 0xE0,
    buffer_count: u8 = 0,
};

/// The longest frame a block holds: a VLAN tagged frame without its check
/// sequence, rounded up to the dword.
pub const FRAME_BYTES = 1520;

pub const TransmitBody = extern struct {
    transmit: Transmit = .{},
    frame: [FRAME_BYTES]u8 = @splat(0),
};

/// A command block as it sits in the ring. What follows the header is
/// read by the operation the header names.
pub const Block = extern struct {
    header: Header = .{},
    body: extern union {
        transmit: TransmitBody,
        configure: [CONFIGURE_BYTES]u8,
        address: [6]u8,
    } = .{ .transmit = .{} },
};

pub const ReceiveCount = packed struct(u16) {
    bytes: u14 = 0,
    /// The count has been written.
    filled: bool = false,
    end_of_frame: bool = false,
};

pub const ReceiveSize = packed struct(u16) {
    bytes: u14 = 0,
    _14: u2 = 0,
};

/// A receive frame descriptor, followed by room for the frame.
pub const Receive = extern struct {
    header: Header = .{},
    buffers: u32 = NO_BUFFERS,
    count: ReceiveCount = .{},
    size: ReceiveSize = .{},
    frame: [FRAME_BYTES]u8 = @splat(0),
};

comptime {
    if (@sizeOf(Header) != 8) @compileError("a block header is eight bytes");
    if (@offsetOf(Block, "body") != 8 or @offsetOf(TransmitBody, "frame") != 8) {
        @compileError("a transmitted frame follows the block's sixteen bytes");
    }
    if (@offsetOf(Receive, "frame") != 16) @compileError("a received frame follows the descriptor's sixteen bytes");
    if (@sizeOf(Block) != @sizeOf(Receive)) @compileError("a transmit slot and a receive slot are one size");
}

// ---------------------------------------------------------------------------
// The configure block
// ---------------------------------------------------------------------------

pub const CONFIGURE_BYTES = 22;

pub const Preamble = enum(u2) { bytes_1, bytes_3, bytes_7, bytes_15 };

/// The configure block, byte 0 first. Reserved bits hold the values the
/// manual requires of them.
pub const Configuration = packed struct(u176) {
    // Byte 0.
    byte_count: u6 = CONFIGURE_BYTES,
    _0: u2 = 0,
    // Byte 1.
    receive_fifo_limit: u4 = 8,
    transmit_fifo_limit: u3 = 0,
    _1: u1 = 0,
    // Byte 2.
    adaptive_interframe_spacing: u8 = 0,
    // Byte 3.
    memory_write_invalidate: bool = false,
    type_enable: bool = false,
    read_align: bool = false,
    terminate_write_on_cache_line: bool = false,
    _3: u4 = 0,
    // Byte 4.
    receive_dma_maximum: u7 = 0,
    _4: u1 = 0,
    // Byte 5.
    transmit_dma_maximum: u7 = 0,
    dma_maximum_enable: bool = false,
    // Byte 6.
    late_scb_update: bool = false,
    direct_receive_dma: bool = true,
    transmit_not_ok_interrupt: bool = false,
    /// Interrupt when the command unit goes idle rather than whenever it
    /// stops being active.
    idle_interrupt: bool = false,
    standard_transmit_block: bool = true,
    standard_statistics: bool = true,
    save_overruns: bool = false,
    save_bad_frames: bool = false,
    // Byte 7.
    discard_short_frames: bool = true,
    underrun_retries: u2 = 3,
    _7: u2 = 0,
    extended_receive_descriptor: bool = false,
    two_frames_in_fifo: bool = false,
    dynamic_buffer_descriptors: bool = false,
    // Byte 8.
    mii: bool = true,
    _8: u6 = 0,
    carrier_sense_disabled: bool = false,
    // Byte 9.
    checksum_offload: bool = false,
    _9: u3 = 0,
    vlan_arp_tco: bool = false,
    link_wake: bool = false,
    arp_wake: bool = false,
    multicast_wake: bool = false,
    // Byte 10.
    _10: u3 = 0b110,
    no_source_address_insertion: bool = true,
    preamble: Preamble = .bytes_7,
    loopback: u2 = 0,
    // Byte 11.
    linear_priority: u3 = 0,
    _11: u5 = 0,
    // Byte 12.
    linear_priority_mode: bool = false,
    _12: u3 = 0,
    interframe_spacing: u4 = 6,
    // Bytes 13 and 14.
    arp_address_low: u8 = 0,
    arp_address_high: u8 = 0xF2,
    // Byte 15.
    promiscuous: bool = false,
    broadcast_disabled: bool = false,
    wait_after_win: bool = false,
    _15_3: u1 = 1,
    ignore_local_bit: bool = false,
    crc16: bool = false,
    _15_6: u1 = 1,
    carrier_sense_or_collision: bool = false,
    // Bytes 16 and 17.
    flow_control_delay_low: u8 = 0,
    flow_control_delay_high: u8 = 0x40,
    // Byte 18.
    strip_padding: bool = false,
    pad_short_frames: bool = true,
    transfer_check_sequence: bool = false,
    long_frames: bool = false,
    priority_flow_threshold: u3 = 7,
    _18: u1 = 1,
    // Byte 19.
    address_wake: bool = false,
    magic_packet_disabled: bool = true,
    flow_control_disabled: bool = false,
    flow_control_restop: bool = false,
    flow_control_restart: bool = false,
    reject_flow_control: bool = false,
    force_full_duplex: bool = false,
    full_duplex_pin: bool = true,
    // Byte 20.
    _20: u5 = 0x1F,
    priority_location: bool = true,
    multiple_individual_addresses: bool = false,
    _20_7: u1 = 0,
    // Byte 21.
    _21: u3 = 0b101,
    multicast_all: bool = false,
    _21_4: u4 = 0,

    /// What this driver asks of a part: its own address and broadcasts,
    /// frames padded and sent whole, and flow control left off where the
    /// part has it.
    pub fn of(generation: Generation) Configuration {
        return switch (generation) {
            .i82557 => .{},
            .i82558_on => .{ .flow_control_disabled = true, .long_frames = true },
        };
    }

    pub fn bytes(self: Configuration) [CONFIGURE_BYTES]u8 {
        return @bitCast(self);
    }
};

// ---------------------------------------------------------------------------
// The EEPROM
// ---------------------------------------------------------------------------

/// Where the EEPROM keeps what the driver reads.
pub const EepromWord = enum(u8) {
    address_0 = 0,
    address_1 = 1,
    address_2 = 2,
    /// The primary PHY: its kind and its management address.
    phy = 6,
};

pub const PhyWord = packed struct(u16) {
    address: u5,
    _5: u11,
};

/// The start bit, then the read opcode.
const READ = [_]bool{ true, true, false };

/// A serial EEPROM, read one bit at a time through `Pins`, which provides
/// `put(EepromPins)` and `get() EepromPins`. `put` holds its lines for as
/// long as the part needs to see them.
pub fn Eeprom(comptime Pins: type) type {
    return struct {
        const Self = @This();

        pins: Pins,
        /// How many address bits the part takes, once a read has shown it.
        width: ?u4 = null,

        /// The widest address any part here takes.
        const WIDEST = 8;

        pub fn read(self: *Self, word: EepromWord) u16 {
            const width = self.width orelse learned: {
                // The part drives a zero once it has the whole address, which
                // says how wide the address is. Only an address of all zeros
                // reads the same word whatever the width turns out to be.
                const first = self.cycle(.address_0, WIDEST);
                self.width = first.width;
                if (word == .address_0) return first.value;
                break :learned first.width;
            };
            const answer = self.cycle(word, width);
            self.width = answer.width;
            return answer.value;
        }

        const Answer = struct { value: u16, width: u4 };

        fn cycle(self: *Self, word: EepromWord, width: u4) Answer {
            self.pins.put(.{ .select = true, .clock = true });
            defer self.pins.put(.{});

            for (READ) |bit| _ = self.clock(bit);

            const address = std.bit_set.IntegerBitSet(8){ .mask = @intFromEnum(word) };
            var sent: u4 = 0;
            while (sent < width) {
                const heard = self.clock(address.isSet(width - 1 - sent));
                sent += 1;
                if (!heard.data_out) break;
            }

            var value = std.bit_set.IntegerBitSet(16).initEmpty();
            for (0..16) |i| value.setValue(15 - i, self.clock(false).data_out);
            return .{ .value = value.mask, .width = sent };
        }

        /// One bit in, and what the part says after the rising edge.
        fn clock(self: *Self, bit: bool) EepromPins {
            self.pins.put(.{ .select = true, .data_in = bit });
            self.pins.put(.{ .select = true, .data_in = bit, .clock = true });
            return self.pins.get();
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the configure block is the manual's" {
    const first = [CONFIGURE_BYTES]u8{
        0x16, 0x08, 0x00, 0x00, 0x00, 0x00, 0x32, 0x07, 0x01, 0x00, 0x2E,
        0x00, 0x60, 0x00, 0xF2, 0x48, 0x00, 0x40, 0xF2, 0x82, 0x3F, 0x05,
    };
    try testing.expectEqualSlices(u8, &first, &Configuration.of(.i82557).bytes());

    var later = first;
    later[18] = 0xFA;
    later[19] = 0x86;
    try testing.expectEqualSlices(u8, &later, &Configuration.of(.i82558_on).bytes());
}

test "register words are the part's" {
    try testing.expectEqual(@as(u8, 0x08), @as(u8, @bitCast(Status{ .receiver = .no_resources })));
    try testing.expectEqual(@as(u8, 0x80), @as(u8, @bitCast(Status{ .command_unit = .active })));
    try testing.expectEqual(@as(u8, 0x10), @as(u8, @bitCast(Events{ .receiver_stopped = true })));
    try testing.expectEqual(@as(u8, 0x40), @as(u8, @bitCast(Events{ .frame_received = true })));
    try testing.expectEqual(@as(u8, 0x01), @as(u8, @bitCast(Command{ .receiver = .start })));
    try testing.expectEqual(@as(u8, 0x06), @as(u8, @bitCast(Command{ .receiver = .load_base })));
    try testing.expectEqual(@as(u8, 0x20), @as(u8, @bitCast(Command{ .command_unit = .@"resume" })));
    try testing.expectEqual(@as(u8, 0x60), @as(u8, @bitCast(Command{ .command_unit = .load_base })));
    try testing.expectEqual(@as(u32, 2), @as(u32, @bitCast(Port{ .action = .selective_reset })));
    try testing.expectEqual(@as(u32, 0x2821_0000), @as(u32, @bitCast(Mdi{ .phy = 1, .register = 1, .interrupt = true })));
    try testing.expectEqual(@as(u16, 0x4004), @as(u16, @bitCast(BlockCommand{ .operation = .transmit, .@"suspend" = true })));
    try testing.expectEqual(@as(u16, 0xA000), @as(u16, @bitCast(BlockStatus{ .complete = true, .ok = true })));
    try testing.expectEqual(@as(u16, 0x8000 | 60), @as(u16, @bitCast(TransmitCount{ .bytes = 60, .whole = true })));
    try testing.expectEqual(@as(u8, 0x0A), @as(u8, @bitCast(EepromPins{ .select = true, .data_out = true })));
}

test "a revision says which generation a part is" {
    try testing.expectEqual(Generation.i82557, Generation.of(1));
    try testing.expectEqual(Generation.i82557, Generation.of(3));
    try testing.expectEqual(Generation.i82558_on, Generation.of(4));
    try testing.expectEqual(Generation.i82558_on, Generation.of(0x10));
}

/// A serial EEPROM of either size, modelled at its pins.
const FakeEeprom = struct {
    words: []const u16,
    width: u4,
    lines: EepromPins = .{},
    phase: Phase = .start,
    taken: u5 = 0,
    opcode: u2 = 0,
    address: u8 = 0,
    out: bool = true,

    const Phase = enum { start, opcode, address, data };
    const READ_OPCODE = 2;

    fn put(self: *FakeEeprom, next: EepromPins) void {
        const selected = !self.lines.select and next.select;
        const rising = self.lines.select and next.select and !self.lines.clock and next.clock;
        if (!next.select or selected) {
            self.* = .{ .words = self.words, .width = self.width };
        } else if (rising) {
            self.edge(next.data_in);
        }
        self.lines = next;
    }

    fn get(self: *FakeEeprom) EepromPins {
        var lines = self.lines;
        lines.data_out = self.out;
        return lines;
    }

    fn edge(self: *FakeEeprom, bit: bool) void {
        switch (self.phase) {
            .start => if (bit) {
                self.phase = .opcode;
            },
            .opcode => {
                self.opcode = self.opcode * 2 + @intFromBool(bit);
                self.taken += 1;
                if (self.taken == 2) self.enter(.address);
            },
            .address => {
                self.address = self.address * 2 + @intFromBool(bit);
                self.taken += 1;
                if (self.taken == self.width and self.opcode == READ_OPCODE) {
                    // The dummy zero that says the address is whole.
                    self.out = false;
                    self.enter(.data);
                }
            },
            .data => if (self.taken < 16) {
                const word = std.bit_set.IntegerBitSet(16){ .mask = self.words[self.address] };
                self.out = word.isSet(15 - self.taken);
                self.taken += 1;
            },
        }
    }

    fn enter(self: *FakeEeprom, phase: Phase) void {
        self.phase = phase;
        self.taken = 0;
    }
};

test "an EEPROM of either size is read, and its address width learned" {
    var contents: [256]u16 = undefined;
    for (&contents, 0..) |*word, i| word.* = @intCast(0xA500 + i);

    for ([_]u4{ 6, 8 }) |width| {
        var part = FakeEeprom{ .words = contents[0 .. @as(usize, 1) << width], .width = width };
        var eeprom = Eeprom(*FakeEeprom){ .pins = &part };
        try testing.expectEqual(@as(u16, 0xA506), eeprom.read(.phy));
        try testing.expectEqual(width, eeprom.width.?);
        try testing.expectEqual(@as(u16, 0xA500), eeprom.read(.address_0));
        try testing.expectEqual(@as(u16, 0xA502), eeprom.read(.address_2));
    }
}

const fuzzing = @import("lib").fuzzing;
const Choices = fuzzing.Choices;

/// A part of either size with any contents is read exactly; a data line
/// that glitches ends every read all the same, with a width a part could
/// have.
fn readOneEeprom(from: Choices) anyerror!void {
    var contents: [256]u16 = undefined;
    for (&contents) |*word| word.* = from.int(u16);
    const width: u4 = if (from.odds(2)) 6 else 8;

    if (from.odds(4)) {
        const Glitching = struct {
            from: Choices,
            fn put(_: *@This(), _: EepromPins) void {}
            fn get(self: *@This()) EepromPins {
                return .{ .data_out = self.from.odds(2) };
            }
        };
        var lines = Glitching{ .from = from };
        var eeprom = Eeprom(*Glitching){ .pins = &lines };
        for (0..4) |_| {
            _ = eeprom.read(from.one(EepromWord));
            try testing.expect(eeprom.width.? >= 1 and eeprom.width.? <= 8);
        }
        return;
    }

    var part = FakeEeprom{ .words = contents[0 .. @as(usize, 1) << width], .width = width };
    var eeprom = Eeprom(*FakeEeprom){ .pins = &part };
    for (0..4) |_| {
        const at = from.one(EepromWord);
        try testing.expectEqual(contents[@intFromEnum(at)], eeprom.read(at));
        try testing.expectEqual(width, eeprom.width.?);
    }
}

test "fuzz: an EEPROM is read exactly, and a glitching one still ends every read" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            return readOneEeprom(.{ .fuzzer = smith });
        }
    };
    try std.testing.fuzz({}, Target.one, .{});
}

test "EEPROMs of random contents and sizes" {
    try fuzzing.seeded(readOneEeprom, 0xEE9E_0093, 400);
}

test "no EEPROM reads as all ones" {
    const Floating = struct {
        fn put(_: *@This(), _: EepromPins) void {}
        fn get(_: *@This()) EepromPins {
            return .{ .data_out = true };
        }
    };
    var lines = Floating{};
    var eeprom = Eeprom(*Floating){ .pins = &lines };
    try testing.expectEqual(@as(u16, 0xFFFF), eeprom.read(.address_0));
    try testing.expectEqual(@as(u4, 8), eeprom.width.?);
}
