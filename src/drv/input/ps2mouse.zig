//! PS/2 pointing device on the i8042's second port.
//!
//! On the 701 this is the touchpad, wired to IRQ12 through the ENE KB3310
//! acting as the controller. The keyboard driver owns the controller itself;
//! this owns the device hanging off its auxiliary port.
//!
//! **Relative mode, whatever the device is.** Synaptics and Elantech pads both
//! speak plain three-byte PS/2 by default and only produce absolute finger
//! positions after being talked into a proprietary mode. The probe below
//! identifies which pad is present and says so, because that is what a port to
//! another machine needs to know, but the data path is the standard protocol
//! that works on all of them. Absolute mode buys tap zones and multi-finger
//! gestures, and costs a device-specific decoder that can only be tested on
//! the hardware it is for.
//!
//! Packets are three bytes, four if the device is talked into IntelliMouse
//! mode and reports a wheel. The first byte always has bit 3 set, which is the
//! only synchronisation the protocol offers: a controller that drops a byte
//! leaves the stream permanently offset otherwise.

const console = @import("../../kernel/console.zig");
const input = @import("../../kernel/input.zig");
// Named `kbc` rather than after the file: `i8042` is a valid Zig integer type.
const kbc = @import("i8042.zig");
const idt = @import("../../arch/x86/idt.zig");
const cpu = @import("../../arch/x86/cpu.zig");
const port = @import("../../arch/x86/port.zig");

/// Controller commands that concern the second port.
const ENABLE_AUX = 0xA8;
const WRITE_TO_AUX = 0xD4;

/// Configuration byte bits. The clock bit is inverted: setting it *disables*
/// the port, which is the kind of detail worth stating where it is used.

/// Device commands.
const SET_DEFAULTS = 0xF6;
const ENABLE_REPORTING = 0xF4;
const DISABLE_REPORTING = 0xF5;
const SET_SAMPLE_RATE = 0xF3;
const GET_DEVICE_ID = 0xF2;
const STATUS_REQUEST = 0xE9;
const SET_RESOLUTION = 0xE8;

const ACK = 0xFA;

/// First byte of every packet has this set. Anything else means the stream is
/// out of step.
const SYNC_BIT: u8 = 1 << 3;

const BTN_LEFT: u8 = 1 << 0;
const BTN_RIGHT: u8 = 1 << 1;
const BTN_MIDDLE: u8 = 1 << 2;
const X_SIGN: u8 = 1 << 4;
const Y_SIGN: u8 = 1 << 5;
const X_OVERFLOW: u8 = 1 << 6;
const Y_OVERFLOW: u8 = 1 << 7;

pub const Kind = enum {
    none,
    /// Plain three-button PS/2, which is what QEMU emulates.
    generic,
    /// Reports a scroll wheel and sends four-byte packets.
    intellimouse,
    synaptics,
    elantech,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .none => "none",
            .generic => "ps/2",
            .intellimouse => "ps/2 wheel",
            .synaptics => "synaptics",
            .elantech => "elantech",
        };
    }
};

var kind: Kind = .none;
var packet: [4]u8 = @splat(0);
var index: usize = 0;
var packet_len: usize = 3;
var buttons: u8 = 0;

// ---------------------------------------------------------------------------
// Talking to the device
// ---------------------------------------------------------------------------

/// Send one byte to the device and collect its acknowledgement.
fn send(byte: u8) bool {
    kbc.command(WRITE_TO_AUX);
    kbc.writeData(byte);
    return (kbc.readData() orelse 0) == ACK;
}

fn sendWith(byte: u8, argument: u8) bool {
    if (!send(byte)) return false;
    return send(argument);
}

/// Ask the device what it is.
fn deviceId() ?u8 {
    if (!send(GET_DEVICE_ID)) return null;
    return kbc.readData();
}

/// The magic knock that puts an IntelliMouse-compatible device into four-byte
/// mode: three sample rates in a fixed order, after which it reports id 3.
fn tryWheel() bool {
    _ = sendWith(SET_SAMPLE_RATE, 200);
    _ = sendWith(SET_SAMPLE_RATE, 100);
    _ = sendWith(SET_SAMPLE_RATE, 80);
    return (deviceId() orelse 0) == 3;
}

/// Synaptics identify: four resolution writes carry a six-bit address two bits
/// at a time, then a status request returns three bytes describing the pad.
/// A Synaptics device answers with 0x47 in the second byte.
fn synapticsIdentify() bool {
    // Address 0x00 is the identify register.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (!sendWith(SET_RESOLUTION, 0)) return false;
    }
    if (!send(STATUS_REQUEST)) return false;

    _ = kbc.readData() orelse return false;
    const signature = kbc.readData() orelse return false;
    _ = kbc.readData() orelse return false;

    return signature == 0x47;
}

/// Elantech answers a similar knock with a version in place of the signature.
/// Detected but not decoded: the pad works in standard mode, and reporting it
/// is what a port to an Elantech machine needs.
fn elantechIdentify() bool {
    if (!sendWith(SET_RESOLUTION, 0)) return false;
    if (!sendWith(SET_RESOLUTION, 0)) return false;
    if (!sendWith(SET_RESOLUTION, 0)) return false;
    if (!sendWith(SET_RESOLUTION, 0)) return false;
    if (!send(STATUS_REQUEST)) return false;

    const a = kbc.readData() orelse return false;
    const b = kbc.readData() orelse return false;
    _ = kbc.readData() orelse return false;

    return a == 0x3C and b == 0x03;
}

// ---------------------------------------------------------------------------
// Bring-up
// ---------------------------------------------------------------------------

/// Set the device up, returning what was found.
///
/// Every step is best-effort. A machine with no second port, or one whose pad
/// does not answer, must still boot with a working keyboard: a pointing device
/// is worth having and not worth hanging for.
pub fn init() Kind {
    // The whole sequence runs with interrupts off. Every step reads a reply
    // from the shared output buffer, and the keyboard's interrupt handler
    // reads from the same place: a handler that fires mid-sequence consumes an
    // acknowledgement or, worse, the configuration byte, and writing back what
    // was read instead would turn off the keyboard's own interrupt.
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    kbc.command(ENABLE_AUX);

    var cfg = kbc.config();
    cfg.mouse_interrupt = true;
    cfg.mouse_clock_off = false;
    kbc.setConfig(cfg);

    if (!send(SET_DEFAULTS)) {
        console.debug("mouse", "no device on the second port", .{});
        return .none;
    }

    // The identify sequences leave the device in a known state either way, so
    // the specific probes run before the generic fallback. Order matters only
    // in that a Synaptics pad also answers the wheel knock.
    kind = if (synapticsIdentify())
        .synaptics
    else if (elantechIdentify())
        .elantech
    else if (tryWheel())
        .intellimouse
    else
        .generic;

    packet_len = if (kind == .intellimouse) 4 else 3;

    // Defaults again: the probes changed the resolution and sample rate, and a
    // pad left at the identify settings reports far too slowly to track.
    _ = send(SET_DEFAULTS);
    _ = sendWith(SET_SAMPLE_RATE, 100);
    _ = send(ENABLE_REPORTING);

    idt.setHandler(idt.IRQ_BASE + 12, onIrq);
    idt.setIrqMask(12, false);

    console.debug("mouse", "{s} on irq12, {d}-byte packets", .{ kind.name(), packet_len });
    return kind;
}

pub fn present() bool {
    return kind != .none;
}

// ---------------------------------------------------------------------------
// Packets
// ---------------------------------------------------------------------------

fn onIrq(_: *idt.Frame) void {
    // Drain: the controller may hold more than one byte, and a single read per
    // interrupt falls permanently behind a moving finger.
    while (port.inb(kbc.STATUS) & kbc.ST_OUTPUT_FULL != 0) {
        if (port.inb(kbc.STATUS) & kbc.ST_FROM_AUX == 0) return;
        feed(port.inb(kbc.DATA));
    }
}

fn feed(byte: u8) void {
    // The protocol's only synchronisation. A first byte without the sync bit
    // means a byte was lost somewhere, and continuing would offset every
    // packet from here on.
    if (index == 0 and byte & SYNC_BIT == 0) return;

    packet[index] = byte;
    index += 1;
    if (index < packet_len) return;
    index = 0;

    decode();
}

fn decode() void {
    const flags = packet[0];

    // An overflowed axis carries no usable magnitude. Dropping the movement but
    // keeping the buttons means a click during a fast swipe still registers.
    const overflowed = flags & (X_OVERFLOW | Y_OVERFLOW) != 0;

    const dx: i16 = if (overflowed) 0 else signed(packet[1], flags & X_SIGN != 0);
    // PS/2 counts Y upwards and screens count it downwards.
    const dy: i16 = if (overflowed) 0 else -signed(packet[2], flags & Y_SIGN != 0);

    // The Z counter is four bits, two's complement, and the device counts it
    // positive when the wheel turns towards the user. Negated so that positive
    // means up, which is the direction every consumer expects and what the
    // event type documents. Computed in i16 first: negating the minimum value
    // of an i8 does not fit in one.
    const wheel: i8 = if (packet_len == 4) blk: {
        const nibble: u8 = packet[3] & 0x0F;
        const z: i16 = if (nibble & 0x08 != 0) @as(i16, nibble) - 16 else nibble;
        break :blk @intCast(-@max(@min(z, 7), -7));
    } else 0;

    const now = flags & (BTN_LEFT | BTN_RIGHT | BTN_MIDDLE);
    const changed = now ^ buttons;
    buttons = now;

    input.postPointer(.{
        .dx = dx,
        .dy = dy,
        .wheel = wheel,
        .buttons = .{
            .left = now & BTN_LEFT != 0,
            .right = now & BTN_RIGHT != 0,
            .middle = now & BTN_MIDDLE != 0,
        },
        // A packet that only changes buttons still moves nothing, and one that
        // only moves changes no buttons. Both are reported, and the flag says
        // which happened, so a consumer can tell a click from a drag without
        // comparing against the previous event itself.
        .buttons_changed = changed != 0,
    });
}

/// PS/2 sends movement as a magnitude plus a sign bit in the flags byte,
/// which is a 9-bit two's complement value split across two places.
fn signed(magnitude: u8, negative: bool) i16 {
    const value: i16 = magnitude;
    return if (negative) value - 256 else value;
}
