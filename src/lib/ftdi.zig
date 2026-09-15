//! What one family of serial adapter wants said to it.
//!
//! These are the cables people actually own: a chip with a USB port on
//! one side and a serial line on the other, made by one company and
//! copied by several. It answers no standard class, so everything about
//! it is a number its maker chose, and the numbers are here where they
//! can be checked on the build machine rather than discovered on a wire.
//!
//! **There is no interrupt endpoint.** What the far end's lines are doing
//! rides on the front of every packet of bytes instead: two status bytes,
//! always, even when there are no bytes behind them. A driver reading
//! this has to split what arrives by packet rather than taking it as one
//! run, which is why `HEADER` and the packet size matter to it.
//!
//! Only the family with one clock is here. The high speed parts number
//! their baud rate differently and nobody has one to try it on.

const std = @import("std");
const serial = @import("serial.zig");
const usb = @import("usb.zig");

/// The maker's own number on the bus.
pub const VENDOR: u16 = 0x0403;

/// The parts this drives, by the product number each answers with.
///
/// All of one family: one clock, one way of writing a baud rate. The
/// high speed parts have another and are not here.
pub const PARTS = [_]u16{
    // FT232BM, FT232R, and every cable built around one.
    0x6001,
    // FT230X, FT231X, FT234X.
    0x6015,
};

pub fn known(product: u16) bool {
    return std.mem.indexOfScalar(u16, &PARTS, product) != null;
}

/// What the host asks of the chip. Every one is a request the maker
/// defined, aimed at the device rather than at an interface.
pub const Ask = enum(u8) {
    /// Put the port back as it was found. The value says how much:
    /// everything, or one direction's buffer.
    reset = 0,
    /// Hold up or drop the lines that say a program is here.
    modem = 1,
    /// Whether the two ends hold each other off, and how.
    flow = 2,
    /// The baud rate, as a divisor of the chip's clock.
    baud = 3,
    /// Bits, parity, stop bits, and whether the line is held at break.
    data = 4,
    /// How long the chip waits for more before sending what it has.
    latency = 9,
    _,
};

/// How long the chip holds what it has before sending it anyway.
///
/// Set rather than left alone: it survives being unplugged, so a port is
/// otherwise at whatever the last machine to use it decided. Sixteen
/// milliseconds is the chip's own default and what a person typing wants;
/// it is also what an open port costs, since the chip answers every wait
/// with its two status bytes whether or not anything came.
pub const LATENCY_MS: u16 = 16;

pub fn setLatency(channel: Channel, milliseconds: u16) usb.Setup {
    return tell(.latency, milliseconds, channel);
}

/// What `reset` is being asked to do.
pub const Reset = enum(u16) {
    everything = 0,
    /// Throw away what has arrived and not been read.
    reading = 1,
    /// Throw away what has been written and not sent.
    writing = 2,
};

/// Which port of the chip, as its requests number them.
///
/// Zero on a chip with one port, which is every part above. A chip with
/// more numbers them from one, so this is not an index.
pub const Channel = u16;
pub const ONE_PORT: Channel = 0;

/// How many bytes ride in front of every packet the chip sends.
pub const HEADER = 2;

// ---------------------------------------------------------------------------
// The requests
// ---------------------------------------------------------------------------

fn tell(ask: Ask, value: u16, channel: Channel) usb.Setup {
    return usb.Setup.vendorRequest(.out, @intFromEnum(ask), value, channel, 0);
}

pub fn reset(channel: Channel, what: Reset) usb.Setup {
    return tell(.reset, @intFromEnum(what), channel);
}

/// Set the baud rate. The divisor is wider than the value field, so its
/// top goes in the index, above the port number where there is one.
pub fn setBaud(channel: Channel, rate: u32) usb.Setup {
    const divisor = divisorFor(rate);
    const high: u16 = @truncate(divisor >> 16);
    const index = if (channel == ONE_PORT) high else (high << 8) | channel;
    return usb.Setup.vendorRequest(
        .out,
        @intFromEnum(Ask.baud),
        @truncate(divisor),
        index,
        0,
    );
}

pub fn setData(channel: Channel, line: serial.Line, broke: bool) usb.Setup {
    return tell(.data, @bitCast(Data.of(line, broke)), channel);
}

pub fn setLines(channel: Channel, held: serial.Held) usb.Setup {
    return tell(.modem, @bitCast(Modem.of(held)), channel);
}

/// Let the two ends hold each other off, or not. Nothing here does, and
/// saying so is what stops a chip that was left doing it from carrying
/// on: the setting survives being unplugged.
pub fn setFlow(channel: Channel, how: Flow) usb.Setup {
    // The one request whose index carries something besides the port.
    return usb.Setup.vendorRequest(
        .out,
        @intFromEnum(Ask.flow),
        0,
        (@as(u16, @intFromEnum(how)) << 8) | channel,
        0,
    );
}

pub const Flow = enum(u8) {
    none = 0x00,
    /// The wires either end raises when it can take more.
    hardware = 0x01,
    /// Two characters in the stream itself.
    characters = 0x04,
};

/// Bits, parity, stop bits and break, as the chip's one word holds them.
///
/// The numbers are the same ones a serial line has always used, which is
/// why the fields below are the shared ones rather than a translation:
/// no parity is zero and even parity is two here as everywhere else.
pub const Data = packed struct(u16) {
    bits: u4 = 8,
    _0: u4 = 0,
    /// The numbers `serial.Parity` and `serial.Stop` already use, in
    /// three bits each rather than a byte each: the chip's word has no
    /// room for a byte, and the values are small.
    parity: u3 = 0,
    stop: u3 = 0,
    broke: bool = false,
    _1: u1 = 0,

    fn of(line: serial.Line, broke: bool) Data {
        return .{
            .bits = @truncate(line.bits),
            .parity = narrow(@intFromEnum(line.parity)),
            .stop = narrow(@intFromEnum(line.stop)),
            .broke = broke,
        };
    }

    /// A value the chip has a name for, or the plainest one it has. A
    /// line that got this far has been checked; what this rules out is
    /// a number the chip would read as something else entirely.
    fn narrow(value: u8) u3 {
        return std.math.cast(u3, value) orelse 0;
    }
};

/// The lines the host holds, as the chip's word holds them: what each is
/// to be, and which of them is being spoken about at all.
const Modem = packed struct(u16) {
    dtr: bool = false,
    rts: bool = false,
    _0: u6 = 0,
    change_dtr: bool = true,
    change_rts: bool = true,
    _1: u6 = 0,

    fn of(held: serial.Held) Modem {
        return .{ .dtr = held.dtr, .rts = held.rts };
    }
};

comptime {
    // The fields above are the shared ones only because the chip numbers
    // them the same way. Said here, so a change to either is a build that
    // fails rather than a line that is quietly set wrong.
    if (@as(u16, @bitCast(Data.of(.{ .bits = 8, .parity = .even, .stop = .two }, false))) != 0x1208) {
        @compileError("the chip's data word drifted");
    }
    if (@as(u16, @bitCast(Modem{ .dtr = true, .rts = true })) != 0x0303) {
        @compileError("the chip's modem word drifted");
    }
}

// ---------------------------------------------------------------------------
// The baud rate
// ---------------------------------------------------------------------------

/// The clock the divisor divides, in halves: the chip counts in halves
/// of a bit, so this is already doubled.
const CLOCK: u32 = 48_000_000;

/// The chip takes a divisor with three bits of fraction, and it does not
/// number those three bits in order. This is the order it numbers them
/// in: an eighth is written as three, a quarter as two, a half as four.
const EIGHTHS = [8]u3{ 0, 3, 2, 4, 1, 5, 6, 7 };

/// The divisor a baud rate comes to.
///
/// Two rates are special: the chip's whole clock and half of it are
/// asked for by zero and one, which are what the arithmetic below would
/// otherwise call one and one and a half.
pub fn divisorFor(rate: u32) u32 {
    if (rate == 0) return 0;
    const eighths = closest(CLOCK, 2 * rate);
    const whole = eighths >> 3;
    const divisor = whole | (@as(u32, EIGHTHS[@as(u3, @truncate(eighths))]) << 14);

    if (divisor == 1) return 0;
    if (divisor == 0x4001) return 1;
    return divisor;
}

/// A division rounded to the nearer whole number rather than down: half
/// a count at the top of the range is a rate the far end cannot follow.
fn closest(top: u32, bottom: u32) u32 {
    if (bottom == 0) return 0;
    return (top + bottom / 2) / bottom;
}

// ---------------------------------------------------------------------------
// What rides in front of the bytes
// ---------------------------------------------------------------------------

/// The first of the two bytes on every packet: the wires the far end
/// holds up.
const Lines = packed struct(u8) {
    _0: u4 = 0,
    cts: bool = false,
    dsr: bool = false,
    ring: bool = false,
    carrier: bool = false,
};

/// The second: what became of the characters themselves.
const Characters = packed struct(u8) {
    ready: bool = false,
    overrun: bool = false,
    parity: bool = false,
    framing: bool = false,
    broke: bool = false,
    /// The chip's own send register has room. Nothing here waits on it:
    /// a transfer the chip cannot take is one it does not answer.
    room: bool = false,
    empty: bool = false,
    fifo: bool = false,
};

/// One answer from the chip, walked as the packets it is made of.
///
/// A read that asked for several packets' worth gets several, each with
/// its own two bytes of state in front of it, so what arrives is split
/// rather than taken as one run. Only the last may be short: a packet
/// shorter than the endpoint's own size is what ends a transfer.
pub const Packets = struct {
    bytes: []const u8,
    packet: u16,
    at: usize = 0,

    pub const Piece = struct {
        state: serial.State,
        /// What the far end sent, which is empty on a packet the chip
        /// answered with only to say the line had not changed.
        bytes: []const u8,
    };

    pub fn next(self: *Packets) ?Piece {
        if (self.packet <= HEADER) return null;
        if (self.at + HEADER > self.bytes.len) return null;

        const whole = @min(self.bytes.len - self.at, self.packet);
        const piece = Piece{
            .state = stateOf(self.bytes[self.at..]) orelse return null,
            .bytes = self.bytes[self.at + HEADER ..][0 .. whole - HEADER],
        };
        self.at += whole;
        return piece;
    }
};

pub fn packetsIn(bytes: []const u8, packet: u16) Packets {
    return .{ .bytes = bytes, .packet = packet };
}

/// What the two bytes in front of a packet say, as a line's state.
pub fn stateOf(header: []const u8) ?serial.State {
    if (header.len < HEADER) return null;
    const lines: Lines = @bitCast(header[0]);
    const characters: Characters = @bitCast(header[1]);
    return .{
        .dcd = lines.carrier,
        .dsr = lines.dsr,
        .ring = lines.ring,
        .cts = lines.cts,
        .broke = characters.broke,
        .framing = characters.framing,
        .parity = characters.parity,
        .overrun = characters.overrun,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the divisors are the ones the chip is known to want" {
    // The rates anybody uses, against the values the part is documented
    // with: an integer and three bits of a fraction, the fraction in the
    // top of the word.
    try testing.expectEqual(@as(u32, 0x2710), divisorFor(300));
    try testing.expectEqual(@as(u32, 0x09C4), divisorFor(1200));
    try testing.expectEqual(@as(u32, 0x04E2), divisorFor(2400));
    try testing.expectEqual(@as(u32, 0x4138), divisorFor(9600));
    try testing.expectEqual(@as(u32, 0x809C), divisorFor(19200));
    try testing.expectEqual(@as(u32, 0xC034), divisorFor(57600));
    try testing.expectEqual(@as(u32, 0x001A), divisorFor(115200));
    try testing.expectEqual(@as(u32, 0x000D), divisorFor(230400));
    try testing.expectEqual(@as(u32, 0x4006), divisorFor(460800));
    try testing.expectEqual(@as(u32, 0x8003), divisorFor(921600));

    // The two the chip asks for by name rather than by division.
    try testing.expectEqual(@as(u32, 1), divisorFor(2_000_000));
    try testing.expectEqual(@as(u32, 0), divisorFor(3_000_000));
    try testing.expectEqual(@as(u32, 0), divisorFor(0));
}

test "a baud rate that does not fit one field carries its top in the other" {
    // Three hundred baud needs a divisor past sixteen bits only in its
    // fraction; nineteen thousand two hundred does not. Either way the
    // value is the low half and the index the high one.
    const slow = setBaud(ONE_PORT, 300);
    try testing.expectEqual(@as(u16, 0x2710), slow.value);
    try testing.expectEqual(@as(u16, 0), slow.index);

    // A rate slow enough that its divisor runs past sixteen bits: the
    // top of it is what the index carries on a chip with one port.
    const crawling = setBaud(ONE_PORT, 366);
    try testing.expect(divisorFor(366) > 0xFFFF);
    try testing.expectEqual(@as(u16, @truncate(divisorFor(366))), crawling.value);
    try testing.expectEqual(@as(u16, 1), crawling.index);

    // And the same request is a vendor request to the device.
    try testing.expectEqual(@as(u8, 0x40), @as(u8, @bitCast(slow.request_type)));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(slow.request));
    try testing.expectEqual(@as(u16, 0), slow.length);
}

test "a chip with more than one port has it in the index" {
    const second: Channel = 2;
    const fast = setBaud(second, 115200);
    try testing.expectEqual(@as(u16, 0x001A), fast.value);
    try testing.expectEqual(@as(u16, 2), fast.index);

    try testing.expectEqual(@as(u16, 2), setData(second, .{}, false).index);
    try testing.expectEqual(@as(u16, 2), setLines(second, .{}).index);
}

test "the data word is the line written the chip's way" {
    const plain = setData(ONE_PORT, .{ .bits = 8, .parity = .none, .stop = .one }, false);
    try testing.expectEqual(@as(u16, 0x0008), plain.value);

    const fussy = setData(ONE_PORT, .{ .bits = 7, .parity = .odd, .stop = .two }, false);
    try testing.expectEqual(@as(u16, 0x1107), fussy.value);

    const held = setData(ONE_PORT, .{ .bits = 8 }, true);
    try testing.expectEqual(@as(u16, 0x4008), held.value);
}

test "the lines say both what they are and that they are being spoken about" {
    // Both halves: a word that said only what the lines are to be would
    // leave the chip free to take it as being about neither of them.
    try testing.expectEqual(@as(u16, 0x0303), setLines(ONE_PORT, .{ .dtr = true, .rts = true }).value);
    try testing.expectEqual(@as(u16, 0x0300), setLines(ONE_PORT, .{}).value);
    try testing.expectEqual(@as(u16, 0x0301), setLines(ONE_PORT, .{ .dtr = true }).value);
}

test "the two bytes in front of a packet are the state of the line" {
    // Carrier and clear to send up, nothing having gone wrong.
    const quiet = stateOf(&[_]u8{ 0x90, 0x60 }).?;
    try testing.expect(quiet.dcd);
    try testing.expect(quiet.cts);
    try testing.expect(!quiet.dsr);
    try testing.expect(!quiet.spoiled());

    // A character that arrived without its stop bit, and one that
    // arrived before the last was read.
    const spoilt = stateOf(&[_]u8{ 0x00, 0x0A }).?;
    try testing.expect(spoilt.framing);
    try testing.expect(spoilt.overrun);
    try testing.expect(spoilt.spoiled());

    try testing.expectEqual(@as(?serial.State, null), stateOf(&[_]u8{0x00}));
}

test "an answer is walked as the packets it is made of" {
    // Two whole packets of four bytes and a short one: the chip's two
    // status bytes in front of each, and what the far end sent behind.
    const answer = [_]u8{
        0x01, 0x00, 'a', 'b',
        0x01, 0x00, 'c', 'd',
        0x01, 0x00, 'e',
    };
    var walk = packetsIn(&answer, 4);
    try testing.expectEqualStrings("ab", walk.next().?.bytes);
    try testing.expectEqualStrings("cd", walk.next().?.bytes);
    try testing.expectEqualStrings("e", walk.next().?.bytes);
    try testing.expectEqual(@as(?Packets.Piece, null), walk.next());

    // A packet of nothing but the state, which is what the chip answers
    // with when its wait ran out and nothing came.
    const quiet = [_]u8{ 0x90, 0x60 };
    var alone = packetsIn(&quiet, 64);
    const piece = alone.next().?;
    try testing.expectEqual(@as(usize, 0), piece.bytes.len);
    try testing.expect(piece.state.dcd);
    try testing.expectEqual(@as(?Packets.Piece, null), alone.next());

    // Half a header is not a packet, and a packet no larger than its own
    // header is not a size any endpoint has.
    var cut = packetsIn(quiet[0..1], 64);
    try testing.expectEqual(@as(?Packets.Piece, null), cut.next());
    var impossible = packetsIn(&quiet, HEADER);
    try testing.expectEqual(@as(?Packets.Piece, null), impossible.next());
}

test "the parts this drives are the ones with the one clock" {
    try testing.expect(known(0x6001));
    try testing.expect(known(0x6015));
    try testing.expect(!known(0x6014));
    try testing.expect(!known(0x0000));
}
