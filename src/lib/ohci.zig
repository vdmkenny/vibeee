//! The Open Host Controller Interface, release 1.0a: the full and low speed
//! USB host controller in AMD, SiS, ALi, NVIDIA and OPTi chipsets, and on
//! add-in cards.
//!
//! The specification's registers and the structures a controller shares
//! with its host. Here rather than beside the driver because the kernel
//! takes a controller from the firmware at boot, before any driver runs.

const std = @import("std");

/// Registers, a dword each, from the aperture's base.
pub const Register = enum(u32) {
    revision = 0x00,
    control = 0x04,
    command_status = 0x08,
    interrupt_status = 0x0C,
    interrupt_enable = 0x10,
    interrupt_disable = 0x14,
    hcca = 0x18,
    periodic_current = 0x1C,
    control_head = 0x20,
    control_current = 0x24,
    bulk_head = 0x28,
    bulk_current = 0x2C,
    done_head = 0x30,
    frame_interval = 0x34,
    frame_remaining = 0x38,
    frame_number = 0x3C,
    periodic_start = 0x40,
    low_speed_threshold = 0x44,
    hub_a = 0x48,
    hub_b = 0x4C,
    hub_status = 0x50,
    /// The first port. Each further port is the next dword.
    port_0 = 0x54,
};

/// The most root ports a controller has.
pub const MAX_PORTS = 15;

/// One past the widest register file: the port bank with every port.
pub const REGISTERS_END: u32 = @intFromEnum(Register.port_0) + MAX_PORTS * 4;

/// Where port `index` is, from the aperture's base.
pub fn portOffset(index: u4) u32 {
    return @intFromEnum(Register.port_0) + @as(u32, index) * 4;
}

pub const FunctionalState = enum(u2) {
    reset,
    resuming,
    operational,
    suspended,
};

/// HcControl.
pub const Control = packed struct(u32) {
    /// Control lists served per bulk list, less one.
    control_bulk_ratio: u2 = 0,
    periodic_enabled: bool = false,
    isochronous_enabled: bool = false,
    control_enabled: bool = false,
    bulk_enabled: bool = false,
    state: FunctionalState = .reset,
    /// The firmware's system management code takes the interrupt.
    firmware_routed: bool = false,
    remote_wakeup_connected: bool = false,
    remote_wakeup_enabled: bool = false,
    _11: u21 = 0,
};

/// HcCommandStatus. Each bit written as one asks for its action.
pub const CommandStatus = packed struct(u32) {
    reset: bool = false,
    control_filled: bool = false,
    bulk_filled: bool = false,
    /// Ask the firmware's code to give the controller up.
    ownership_change: bool = false,
    _4: u12 = 0,
    overruns: u2 = 0,
    _18: u14 = 0,
};

/// HcInterruptStatus, HcInterruptEnable and HcInterruptDisable share a
/// shape: what latched, what is let through, and what is stopped.
pub const Interrupts = packed struct(u32) {
    scheduling_overrun: bool = false,
    /// Finished descriptors were written to the done head.
    done: bool = false,
    start_of_frame: bool = false,
    resume_detected: bool = false,
    unrecoverable: bool = false,
    frame_number_overflow: bool = false,
    hub_changed: bool = false,
    _7: u23 = 0,
    ownership_changed: bool = false,
    /// Enable and disable only: every interrupt at once.
    master: bool = false,

    pub const ALL: Interrupts = @bitCast(@as(u32, 0xFFFF_FFFF));
};

/// A frame is twelve thousand bit times.
pub const FRAME_BITS = 11999;

/// HcFmInterval.
pub const FrameInterval = packed struct(u32) {
    bits: u14 = FRAME_BITS,
    _14: u2 = 0,
    /// The largest full speed packet that fits what is left of a frame.
    largest_packet: u15 = largestPacket(FRAME_BITS),
    /// Toggled on every write, which is how the controller tells a new
    /// interval from an old one.
    toggle: bool = false,
};

/// The largest packet a frame of `bits` leaves room for, as the
/// specification computes it.
pub fn largestPacket(bits: u14) u15 {
    return @intCast(@as(u32, 6) * (@as(u32, bits) - 210) / 7);
}

/// HcPeriodicStart: where in a frame the periodic list begins.
pub const PeriodicStart = packed struct(u32) {
    bits: u14,
    _14: u18 = 0,

    /// Nine tenths of the frame, which leaves the rest for control and bulk.
    pub fn of(frame_bits: u14) PeriodicStart {
        return .{ .bits = @intCast(@as(u32, frame_bits) * 9 / 10) };
    }
};

/// HcLSThreshold: the latest a low speed packet may start.
pub const LowSpeedThreshold = packed struct(u32) {
    bits: u12 = 0x628,
    _12: u20 = 0,
};

/// HcRhDescriptorA.
pub const HubA = packed struct(u32) {
    ports: u8 = 0,
    /// Each port's power is switched on its own.
    per_port_power: bool = false,
    /// Every port is powered whenever the controller is.
    always_powered: bool = false,
    _10: u1 = 0,
    per_port_overcurrent: bool = false,
    no_overcurrent: bool = false,
    _13: u11 = 0,
    /// How long a port takes to be powered, in two millisecond steps.
    power_on_to_good: u8 = 0,

    pub fn powerOnUs(self: HubA) u32 {
        return @as(u32, self.power_on_to_good) * 2_000;
    }
};

/// HcRhStatus, as written.
pub const HubStatus = packed struct(u32) {
    /// Power every port off.
    clear_power: bool = false,
    overcurrent: bool = false,
    _2: u13 = 0,
    remote_wakeup_enable: bool = false,
    /// Power every port on.
    set_power: bool = false,
    overcurrent_changed: bool = false,
    _18: u13 = 0,
    clear_remote_wakeup: bool = false,
};

/// HcRhPortStatus, as read.
pub const PortStatus = packed struct(u32) {
    connected: bool = false,
    enabled: bool = false,
    suspended: bool = false,
    overcurrent: bool = false,
    resetting: bool = false,
    _5: u3 = 0,
    powered: bool = false,
    low_speed: bool = false,
    _10: u6 = 0,
    connect_changed: bool = false,
    enable_changed: bool = false,
    suspend_changed: bool = false,
    overcurrent_changed: bool = false,
    reset_changed: bool = false,
    _21: u11 = 0,

    pub fn changed(self: PortStatus) bool {
        return self.connect_changed or self.enable_changed or self.suspend_changed or
            self.overcurrent_changed or self.reset_changed;
    }
};

/// HcRhPortStatus, as written: each bit set does one thing, and a bit left
/// clear does nothing.
pub const PortCommand = packed struct(u32) {
    disable: bool = false,
    enable: bool = false,
    suspend_port: bool = false,
    wake: bool = false,
    reset: bool = false,
    _5: u3 = 0,
    power_on: bool = false,
    power_off: bool = false,
    _10: u6 = 0,
    connect_changed: bool = false,
    enable_changed: bool = false,
    suspend_changed: bool = false,
    overcurrent_changed: bool = false,
    reset_changed: bool = false,
    _21: u11 = 0,

    /// Clear exactly the changes `status` reports.
    pub fn acknowledging(status: PortStatus) PortCommand {
        return .{
            .connect_changed = status.connect_changed,
            .enable_changed = status.enable_changed,
            .suspend_changed = status.suspend_changed,
            .overcurrent_changed = status.overcurrent_changed,
            .reset_changed = status.reset_changed,
        };
    }
};

// ---------------------------------------------------------------------------
// Shared with the host
// ---------------------------------------------------------------------------

/// The Host Controller Communications Area.
pub const Hcca = extern struct {
    /// Where each of the 32 interrupt polling slots begins its endpoints.
    interrupt_table: [32]u32 = @splat(0),
    frame_number: u16 = 0,
    _pad: u16 = 0,
    /// The descriptors finished since the last report.
    done_head: u32 = 0,
    _reserved: [120]u8 = @splat(0),
};

/// An address the controller keeps flags in the low four bits of: every
/// descriptor sits on a sixteen byte boundary.
pub const Pointer = packed struct(u32) {
    /// Endpoint head only: the controller stopped the endpoint on an error.
    halted: bool = false,
    /// Endpoint head only: the toggle the next packet carries.
    toggle_carry: bool = false,
    _2: u2 = 0,
    sixteenths: u28 = 0,

    pub fn at(address: u32) Pointer {
        return .{ .sixteenths = @intCast(@divExact(address, 16)) };
    }

    pub fn physical(self: Pointer) u32 {
        return @as(u32, self.sixteenths) * 16;
    }
};

pub const EndpointDirection = enum(u2) {
    from_descriptor = 0,
    out = 1,
    in = 2,
    from_descriptor_too = 3,
};

pub const EndpointControl = packed struct(u32) {
    address: u7 = 0,
    endpoint: u4 = 0,
    direction: EndpointDirection = .from_descriptor,
    low_speed: bool = false,
    /// Pass the endpoint over.
    skip: bool = false,
    isochronous: bool = false,
    max_packet: u11 = 0,
    _27: u5 = 0,
};

/// An endpoint descriptor: one endpoint, and the queue of transfers to it
/// from the head to the tail. The tail itself is never processed.
pub const Endpoint = extern struct {
    control: EndpointControl = .{ .skip = true },
    tail: u32 = 0,
    head: Pointer = .{},
    next: u32 = 0,
};

pub const Pid = enum(u2) {
    setup = 0,
    out = 1,
    in = 2,
    _,
};

pub const Toggle = enum(u2) {
    /// The endpoint's carried toggle.
    carried = 0,
    carried_too = 1,
    data0 = 2,
    data1 = 3,
};

pub const Condition = enum(u4) {
    no_error = 0,
    crc = 1,
    bit_stuffing = 2,
    toggle_mismatch = 3,
    stall = 4,
    not_responding = 5,
    pid_check = 6,
    unexpected_pid = 7,
    data_overrun = 8,
    data_underrun = 9,
    buffer_overrun = 12,
    buffer_underrun = 13,
    not_accessed = 14,
    not_accessed_too = 15,
    _,
};

/// Interrupt delay: the end of the frame the descriptor finishes in, or
/// never, when this many frames is written.
pub const NO_INTERRUPT: u3 = 7;

pub const TransferControl = packed struct(u32) {
    _0: u18 = 0,
    /// A packet shorter than the buffer ends the transfer without an error.
    short_ok: bool = false,
    pid: Pid = .setup,
    delay: u3 = NO_INTERRUPT,
    toggle: Toggle = .carried,
    errors: u2 = 0,
    condition: Condition = .not_accessed,
};

/// A general transfer descriptor.
pub const Transfer = extern struct {
    control: TransferControl = .{},
    /// Where the next byte goes or comes from; zero once all of them have.
    buffer: u32 = 0,
    next: u32 = 0,
    /// The buffer's last byte.
    end: u32 = 0,
};

comptime {
    if (@sizeOf(Hcca) != 256) @compileError("the communications area is 256 bytes");
    if (@sizeOf(Endpoint) != 16 or @sizeOf(Transfer) != 16) @compileError("a descriptor is sixteen bytes");
    if (@offsetOf(Hcca, "done_head") != 0x84) @compileError("the done head is at 0x84");
}

/// What became of a descriptor the controller has finished.
pub const Outcome = enum {
    /// Not processed yet.
    pending,
    done,
    stalled,
    not_responding,
    /// Any other failure on the wire or in the controller.
    failed,

    pub fn of(condition: Condition) Outcome {
        return switch (condition) {
            .no_error, .data_underrun => .done,
            .stall => .stalled,
            .not_responding => .not_responding,
            .not_accessed, .not_accessed_too => .pending,
            else => .failed,
        };
    }
};

/// How many bytes a finished descriptor moved, of the `length` at `start`
/// it was given: all of them when the controller cleared the pointer, up to
/// the pointer when it did not, and nothing when the pointer is not inside
/// the buffer at all.
pub fn moved(buffer: u32, start: u32, length: u32) u32 {
    if (length == 0 or buffer == 0) return length;
    if (buffer < start) return 0;
    const through = buffer - start;
    return if (through <= length) through else 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn word(value: anytype) u32 {
    return @bitCast(value);
}

test "register words are the specification's" {
    try testing.expectEqual(@as(u32, 0x0000_0080), word(Control{ .state = .operational }));
    try testing.expectEqual(@as(u32, 0x0000_0100), word(Control{ .firmware_routed = true }));
    try testing.expectEqual(@as(u32, 0x0000_0034), word(Control{ .periodic_enabled = true, .control_enabled = true, .bulk_enabled = true }));
    try testing.expectEqual(@as(u32, 0x0000_0008), word(CommandStatus{ .ownership_change = true }));
    try testing.expectEqual(@as(u32, 0x0000_0002), word(Interrupts{ .done = true }));
    try testing.expectEqual(@as(u32, 0x0000_0040), word(Interrupts{ .hub_changed = true }));
    try testing.expectEqual(@as(u32, 0x4000_0000), word(Interrupts{ .ownership_changed = true }));
    try testing.expectEqual(@as(u32, 0x8000_0000), word(Interrupts{ .master = true }));
    try testing.expectEqual(@as(u32, 0x0001_0000), word(HubStatus{ .set_power = true }));
    try testing.expectEqual(@as(u32, 0x0000_0010), word(PortCommand{ .reset = true }));
    try testing.expectEqual(@as(u32, 0x0000_0100), word(PortCommand{ .power_on = true }));
    try testing.expectEqual(@as(u32, 0x0010_0000), word(PortCommand{ .reset_changed = true }));
    try testing.expectEqual(@as(u32, 0x0000_0200), word(PortStatus{ .low_speed = true }));
    try testing.expectEqual(@as(u32, 0x0001_0000), word(PortStatus{ .connect_changed = true }));
    try testing.expectEqual(@as(u32, 0x2C00_0000), word(HubA{ .power_on_to_good = 0x2C }));
    try testing.expectEqual(@as(u32, 0x0000_0628), word(LowSpeedThreshold{}));
}

test "the frame interval and periodic start are the specification's defaults" {
    try testing.expectEqual(@as(u32, 0x2778_2EDF), word(FrameInterval{}));
    try testing.expectEqual(@as(u32, 10799), word(PeriodicStart.of(FRAME_BITS)));
    try testing.expectEqual(@as(u32, 88_000), (HubA{ .power_on_to_good = 44 }).powerOnUs());
}

test "descriptor words are the specification's" {
    try testing.expectEqual(@as(u32, 0x0040_1082), word(EndpointControl{ .address = 2, .endpoint = 1, .direction = .in, .max_packet = 64 }));
    try testing.expectEqual(@as(u32, 0x0000_4000), word(EndpointControl{ .skip = true }));
    try testing.expectEqual(@as(u32, 0x0000_2000), word(EndpointControl{ .low_speed = true }));
    try testing.expectEqual(@as(u32, 0xE2E0_0000), word(TransferControl{ .pid = .setup, .toggle = .data0 }));
    try testing.expectEqual(@as(u32, 0xE314_0000), word(TransferControl{ .pid = .in, .toggle = .data1, .short_ok = true, .delay = 0, .condition = .not_accessed }));
    try testing.expectEqual(@as(u32, 0x0000_1003), word(Pointer{ .halted = true, .toggle_carry = true, .sixteenths = 0x100 }));
    try testing.expectEqual(@as(u32, 0x0012_3450), Pointer.at(0x0012_3450).physical());
}

test "a finished descriptor's condition says what became of it" {
    try testing.expectEqual(Outcome.done, Outcome.of(.no_error));
    try testing.expectEqual(Outcome.done, Outcome.of(.data_underrun));
    try testing.expectEqual(Outcome.stalled, Outcome.of(.stall));
    try testing.expectEqual(Outcome.not_responding, Outcome.of(.not_responding));
    try testing.expectEqual(Outcome.pending, Outcome.of(.not_accessed));
    try testing.expectEqual(Outcome.failed, Outcome.of(.crc));
    try testing.expectEqual(Outcome.failed, Outcome.of(@enumFromInt(10)));
}

test "bytes moved are measured against the buffer, never past it" {
    try testing.expectEqual(@as(u32, 64), moved(0, 0x1000, 64));
    try testing.expectEqual(@as(u32, 18), moved(0x1012, 0x1000, 64));
    try testing.expectEqual(@as(u32, 0), moved(0x1000, 0x1000, 64));
    try testing.expectEqual(@as(u32, 0), moved(0x0FF0, 0x1000, 64));
    try testing.expectEqual(@as(u32, 0), moved(0x1041, 0x1000, 64));
    try testing.expectEqual(@as(u32, 0), moved(0x1234, 0x1000, 0));
}
