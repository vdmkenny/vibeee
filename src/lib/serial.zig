//! What a serial line is set to, and what it says it is doing.
//!
//! Not the bus's and not any one driver's. A port reached over USB, one
//! on a chip, and the program at either end of either all mean the same
//! thing by eight bits, no parity and one stop bit, so it is said once
//! here and each driver spells it in whatever numbers its hardware wants.
//!
//! The numbers below are RS-232's own, which is why the USB class that
//! carries a serial port uses the same ones on the wire: a driver for
//! that class writes these values out unchanged, and one for a chip with
//! its own register layout translates.

const std = @import("std");

pub const Parity = enum(u8) {
    none = 0,
    odd = 1,
    even = 2,
    /// Always one.
    mark = 3,
    /// Always zero.
    space = 4,
    _,

    pub fn letter(self: Parity) u8 {
        return switch (self) {
            .none => 'N',
            .odd => 'O',
            .even => 'E',
            .mark => 'M',
            .space => 'S',
            _ => '?',
        };
    }

    /// The parity a letter names, as people write a line's settings.
    pub fn of(letter_: u8) ?Parity {
        return switch (std.ascii.toUpper(letter_)) {
            'N' => .none,
            'O' => .odd,
            'E' => .even,
            'M' => .mark,
            'S' => .space,
            else => null,
        };
    }
};

pub const Stop = enum(u8) {
    one = 0,
    one_and_a_half = 1,
    two = 2,
    _,

    /// How many stop bits, written the way people write them, which has
    /// to be text because one of the three is a half.
    pub fn spell(self: Stop) []const u8 {
        return switch (self) {
            .one => "1",
            .one_and_a_half => "1.5",
            .two => "2",
            _ => "",
        };
    }
};

/// How a line is to be treated.
pub const Line = extern struct {
    /// Bits a second.
    rate: u32 align(1) = 115200,
    /// Bits to a character, counted rather than named.
    bits: u8 = 8,
    parity: Parity = .none,
    stop: Stop = .one,

    /// Whether this is a line a port could actually be set to. A rate of
    /// nothing, or a character of no bits, would leave the port unusable.
    pub fn sane(self: Line) bool {
        if (self.rate == 0) return false;
        if (self.stop.spell().len == 0) return false;
        if (Parity.letter(self.parity) == '?') return false;
        return switch (self.bits) {
            5, 6, 7, 8, 16 => true,
            else => false,
        };
    }

    /// A line from the way people write one: a rate, and a character as
    /// `8N1`, which is the bits, the parity's letter and the stop bits.
    ///
    /// Nothing about a serial line is discoverable, so this is how one
    /// end is told what the other is doing, and it is the same three
    /// characters on every machine anybody has ever typed them into.
    pub fn of(rate: u32, shape: []const u8) ?Line {
        if (shape.len < 3) return null;
        const bits = std.fmt.charToDigit(shape[0], 10) catch return null;
        const parity = Parity.of(shape[1]) orelse return null;
        const stop = for ([_]Stop{ .one, .one_and_a_half, .two }) |one| {
            if (std.mem.eql(u8, one.spell(), shape[2..])) break one;
        } else return null;

        const line = Line{ .rate = rate, .bits = bits, .parity = parity, .stop = stop };
        return if (line.sane()) line else null;
    }

    /// The line as people write it: the rate, then the character.
    pub fn spell(self: Line, into: []u8) []const u8 {
        var text = std.Io.Writer.fixed(into);
        text.print("{d} {d}{c}{s}", .{
            self.rate,
            self.bits,
            self.parity.letter(),
            self.stop.spell(),
        }) catch {};
        return text.buffered();
    }
};

/// The lines the host holds up, which say a program has the port open.
///
/// A great many devices send nothing at all until data terminal ready is
/// set: it is the only way the far end knows anybody is listening.
pub const Held = packed struct(u8) {
    dtr: bool = false,
    rts: bool = false,
    _: u6 = 0,
};

/// What the far end says about the line.
///
/// Three facts about the wires and three about the characters that came
/// over them, which is how RS-232 divides it and how every device that
/// reports any of this reports it.
pub const State = packed struct(u16) {
    /// Carrier detect: something is on the other end.
    dcd: bool = false,
    /// Data set ready.
    dsr: bool = false,
    /// The line is being held at break.
    broke: bool = false,
    /// Ring indicator.
    ring: bool = false,
    /// A character arrived without its stop bit.
    framing: bool = false,
    /// A character arrived with the wrong parity.
    parity: bool = false,
    /// Characters arrived faster than they were taken.
    overrun: bool = false,
    /// Clear to send. Above the seven the USB class that carries a
    /// serial port defines, because that class leaves this to flow
    /// control and says nothing about it: a port that reports it sets
    /// this, and one that does not leaves it alone.
    cts: bool = false,
    _: u8 = 0,

    /// Whether anything went wrong with the characters themselves, as
    /// opposed to the wires around them.
    pub fn spoiled(self: State) bool {
        return self.framing or self.parity or self.overrun;
    }

    pub fn word(self: State) u16 {
        return @bitCast(self);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a line is written the way people write one" {
    var buf: [32]u8 = undefined;
    const plain = Line{};
    try testing.expectEqualStrings("115200 8N1", plain.spell(&buf));

    const fussy = Line{ .rate = 9600, .bits = 7, .parity = .even, .stop = .two };
    try testing.expectEqualStrings("9600 7E2", fussy.spell(&buf));

    const halved = Line{ .rate = 300, .bits = 5, .stop = .one_and_a_half };
    try testing.expectEqualStrings("300 5N1.5", halved.spell(&buf));
}

test "a line nobody could use is refused" {
    try testing.expect((Line{}).sane());
    try testing.expect(!(Line{ .rate = 0 }).sane());
    try testing.expect(!(Line{ .bits = 9 }).sane());
    try testing.expect(!(Line{ .stop = @enumFromInt(7) }).sane());
    try testing.expect(!(Line{ .parity = @enumFromInt(9) }).sane());
}

test "a line reads back from the way it was written" {
    var buf: [32]u8 = undefined;
    for ([_]Line{
        .{},
        .{ .rate = 9600, .bits = 7, .parity = .even, .stop = .two },
        .{ .rate = 300, .bits = 5, .parity = .mark, .stop = .one_and_a_half },
    }) |line| {
        const spelt = line.spell(&buf);
        const shape = spelt[std.mem.indexOfScalar(u8, spelt, ' ').? + 1 ..];
        try testing.expectEqual(line, Line.of(line.rate, shape).?);
    }

    // Written the way somebody would type it, rather than read back.
    try testing.expectEqual(
        Line{ .rate = 115200, .bits = 8, .parity = .none, .stop = .one },
        Line.of(115200, "8n1").?,
    );

    try testing.expectEqual(@as(?Line, null), Line.of(115200, "8N"));
    try testing.expectEqual(@as(?Line, null), Line.of(115200, "8N3"));
    try testing.expectEqual(@as(?Line, null), Line.of(115200, "9N1"));
    try testing.expectEqual(@as(?Line, null), Line.of(115200, "8X1"));
    try testing.expectEqual(@as(?Line, null), Line.of(0, "8N1"));
}

test "a parity is named by its letter either way round" {
    for ([_]Parity{ .none, .odd, .even, .mark, .space }) |parity| {
        try testing.expectEqual(parity, Parity.of(parity.letter()).?);
    }
    // Written either way: people type both.
    try testing.expectEqual(Parity.even, Parity.of('e').?);
    try testing.expectEqual(@as(?Parity, null), Parity.of('x'));
}

test "the wire's own numbering, which is what a driver writes out" {
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Parity.even));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Stop.two));
    try testing.expectEqual(@as(u8, 0x03), @as(u8, @bitCast(Held{ .dtr = true, .rts = true })));
    try testing.expectEqual(@as(u16, 0x01), (State{ .dcd = true }).word());
    try testing.expectEqual(@as(u16, 0x40), (State{ .overrun = true }).word());
}

test "a spoilt character is told from a wire that moved" {
    try testing.expect((State{ .overrun = true }).spoiled());
    try testing.expect((State{ .framing = true }).spoiled());
    try testing.expect(!(State{ .ring = true }).spoiled());
    try testing.expect(!(State{ .dcd = true, .dsr = true }).spoiled());
}

comptime {
    // Seven bytes, because the class that carries a serial port over the
    // bus sends exactly these four fields and nothing between them.
    if (@sizeOf(Line) != 7) @compileError("a line's settings are seven bytes");
}
