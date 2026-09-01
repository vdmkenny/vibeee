//! Arithmetic the way a person does it on a small machine.
//!
//! Immediate execution, which is what a calculator with keys has always
//! done: a number, an operation, a number, and the answer appears when the
//! next operation is asked for or the sum is ended. There is no precedence
//! because there is nothing to hold it in; a calculator that quietly
//! reordered what was typed would be a calculator nobody could check.
//!
//! Numbers are fixed point rather than floating: six decimals is more than
//! this machine's screen can show, every result is exactly what the
//! arithmetic says it is rather than the nearest binary fraction to it, and
//! nothing here has to format a float on a processor whose library would
//! have to be dragged in to do it.
//!
//! Pure, and tested on the host: what the keys do to the state is the whole
//! of a calculator, and none of it needs a screen to be checked.

const std = @import("std");

/// Six decimal places. A seventh would not fit the display this is drawn on,
/// and the sixth is what makes a third of something read as a third.
pub const SCALE: i64 = 1_000_000;
pub const PLACES: usize = 6;

/// A number, in units of one millionth. The range is about nine million
/// million, which is more than a machine with a five-digit screen will ever
/// be asked for, and the arithmetic says so rather than wrapping when it is.
pub const Fixed = i64;

pub const Op = enum {
    add,
    subtract,
    multiply,
    divide,

    /// The character a person expects to see, which is not the one on the
    /// key of a keyboard: a calculator says times and divide.
    pub fn sign(self: Op) []const u8 {
        return switch (self) {
            .add => "+",
            .subtract => "\u{2212}",
            .multiply => "\u{00D7}",
            .divide => "\u{00F7}",
        };
    }
};

/// What arithmetic can refuse to do. A calculator keeps the refusal rather
/// than passing it on: it says so on its screen and waits to be cleared, it
/// does not stop being a calculator.
pub const Failure = error{
    DividedByZero,
    /// The answer is larger than this can hold.
    TooLarge,
};

/// What a refusal says on the screen.
pub fn saidAbout(failure: Failure) []const u8 {
    return switch (failure) {
        error.DividedByZero => "cannot divide by zero",
        error.TooLarge => "too large",
    };
}

/// The longest a typed number may be, digits and point together. Nine digits
/// is what the screen shows without shrinking the face.
pub const ENTRY_MAX: usize = 12;

/// How wide a written number can be: the sign, nine digits, the point and
/// six places, with room to spare.
pub const WRITTEN_MAX: usize = 24;

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

/// One operation, in a form that reports its own failure. The wider integer
/// is only for the multiply and the divide, where the intermediate needs the
/// room; nothing keeps a value that would not fit back into `Fixed`.
pub fn apply(left: Fixed, op: Op, right: Fixed) Failure!Fixed {
    const wide: i128 = switch (op) {
        .add => @as(i128, left) + right,
        .subtract => @as(i128, left) - right,
        .multiply => @divTrunc(@as(i128, left) * right, SCALE),
        .divide => blk: {
            if (right == 0) return error.DividedByZero;
            break :blk @divTrunc(@as(i128, left) * SCALE, right);
        },
    };
    if (wide > std.math.maxInt(Fixed) or wide < std.math.minInt(Fixed)) return error.TooLarge;
    return @intCast(wide);
}

/// A number as a person reads it: no trailing zeros in the fraction, no
/// point when there is no fraction left to write.
pub fn write(value: Fixed, into: *[WRITTEN_MAX]u8) []const u8 {
    var at: usize = 0;
    var rest = value;
    if (rest < 0) {
        into[at] = '-';
        at += 1;
        rest = -rest;
    }

    const whole: u64 = @intCast(@divTrunc(rest, SCALE));
    var fraction: u64 = @intCast(@rem(rest, SCALE));

    at += writeWhole(whole, into[at..]);

    // Trailing zeros carry no information: a third written to six places is
    // 0.333333, and a half is 0.5 rather than 0.500000.
    var places = PLACES;
    while (places > 0 and fraction % 10 == 0) : (places -= 1) fraction /= 10;
    if (places == 0) return into[0..at];

    into[at] = '.';
    at += 1;

    var scale: u64 = 1;
    var left = places;
    while (left > 1) : (left -= 1) scale *= 10;
    while (scale > 0) : (scale /= 10) {
        into[at] = '0' + @as(u8, @intCast((fraction / scale) % 10));
        at += 1;
    }
    return into[0..at];
}

fn writeWhole(value: u64, into: []u8) usize {
    if (value == 0) {
        into[0] = '0';
        return 1;
    }
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var rest = value;
    while (rest > 0) : (rest /= 10) {
        digits[count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
    }
    for (0..count) |i| into[i] = digits[count - 1 - i];
    return count;
}

/// A typed number read back. Everything the keys can produce parses; the
/// error is for callers holding text from somewhere else.
pub fn read(text: []const u8) ?Fixed {
    var whole: i64 = 0;
    var fraction: i64 = 0;
    var scale: i64 = SCALE;
    var negative = false;
    var seen_point = false;
    var digits: usize = 0;

    for (text, 0..) |c, i| {
        if (c == '-' and i == 0) {
            negative = true;
        } else if (c == '.') {
            if (seen_point) return null;
            seen_point = true;
        } else if (c >= '0' and c <= '9') {
            digits += 1;
            const value: i64 = c - '0';
            if (seen_point) {
                // Past the sixth place a typed digit changes nothing this
                // can hold, so it is read and dropped rather than refused.
                if (scale > 1) {
                    scale = @divTrunc(scale, 10);
                    fraction += value * scale;
                }
            } else {
                whole = whole * 10 + value;
                if (whole > @divTrunc(std.math.maxInt(Fixed), SCALE)) return null;
            }
        } else return null;
    }
    if (digits == 0) return null;

    const total = whole * SCALE + fraction;
    return if (negative) -total else total;
}

// ---------------------------------------------------------------------------
// The machine
// ---------------------------------------------------------------------------

/// A calculator, as a state machine over the keys it has.
///
/// The typed number is kept as the characters that were typed rather than as
/// a value, so a screen shows what a hand did: a trailing point and the zeros
/// after it stay until they mean something.
pub const Machine = struct {
    entry: [ENTRY_MAX]u8 = @splat(0),
    entry_len: usize = 0,
    /// True while `entry` is what the screen shows; false once a result is.
    typing: bool = false,

    /// The number the next operation works on, and what it will do.
    left: Fixed = 0,
    pending: ?Op = null,
    /// What the screen shows when nothing is being typed.
    result: Fixed = 0,
    trouble: ?Failure = null,

    /// The last operation and its right hand side, so pressing equals again
    /// repeats it, which is the one thing every calculator does and nobody
    /// writes down.
    repeat: ?Repeat = null,

    pub const Repeat = struct { op: Op, right: Fixed };

    pub fn digit(self: *Machine, which: u8) void {
        if (self.trouble != null) self.clear();
        if (!self.typing) self.startTyping();
        if (self.entry_len == ENTRY_MAX) return;
        // A leading zero is replaced rather than added to: 0 then 5 is five.
        if (self.entry_len == 1 and self.entry[0] == '0') self.entry_len = 0;
        self.entry[self.entry_len] = '0' + which;
        self.entry_len += 1;
    }

    pub fn point(self: *Machine) void {
        if (self.trouble != null) self.clear();
        if (!self.typing) self.startTyping();
        for (self.entry[0..self.entry_len]) |c| {
            if (c == '.') return;
        }
        if (self.entry_len == ENTRY_MAX) return;
        if (self.entry_len == 0) {
            self.entry[0] = '0';
            self.entry_len = 1;
        }
        self.entry[self.entry_len] = '.';
        self.entry_len += 1;
    }

    /// The sign of what is on the screen, whether it was typed or worked out.
    pub fn negate(self: *Machine) void {
        if (self.trouble != null) return;
        if (self.typing) {
            if (self.entry_len == 0) return;
            if (self.entry[0] == '-') {
                for (1..self.entry_len) |i| self.entry[i - 1] = self.entry[i];
                self.entry_len -= 1;
            } else {
                if (self.entry_len == ENTRY_MAX) return;
                var i = self.entry_len;
                while (i > 0) : (i -= 1) self.entry[i] = self.entry[i - 1];
                self.entry[0] = '-';
                self.entry_len += 1;
            }
        } else {
            self.result = -self.result;
        }
    }

    /// A hundredth of what is on the screen, or of what the pending
    /// operation is working on: fifty plus ten per cent is fifty-five, which
    /// is what a person means and not what a hundredth of ten is.
    pub fn percent(self: *Machine) void {
        if (self.trouble != null) return;
        const hundredth = apply(self.value(), .divide, 100 * SCALE) catch |failure|
            return self.fail(failure);
        // With an operation waiting, a percentage is a percentage of what it
        // is being applied to; on its own it is simply a hundredth.
        self.result = if (self.pending != null)
            apply(self.left, .multiply, hundredth) catch |failure| return self.fail(failure)
        else
            hundredth;
        self.typing = false;
        self.entry_len = 0;
    }

    /// Ask for an operation. Whatever is already pending is worked out
    /// first, which is what makes a run of keys read left to right.
    pub fn operate(self: *Machine, op: Op) void {
        if (self.trouble != null) return;
        if (self.pending) |waiting| {
            // Two operations in a row change the mind rather than repeat the
            // number: nothing was typed between them.
            if (!self.typing) {
                self.pending = op;
                return;
            }
            self.settle(waiting, self.value());
            if (self.trouble != null) return;
        } else {
            self.left = self.value();
        }
        self.pending = op;
        self.typing = false;
        self.entry_len = 0;
        self.result = self.left;
        self.repeat = null;
    }

    pub fn equals(self: *Machine) void {
        if (self.trouble != null) return;
        if (self.pending) |waiting| {
            const right = self.value();
            self.settle(waiting, right);
            self.pending = null;
            self.repeat = .{ .op = waiting, .right = right };
        } else if (self.repeat) |again| {
            self.left = self.result;
            self.settle(again.op, again.right);
        } else {
            self.result = self.value();
        }
        self.typing = false;
        self.entry_len = 0;
    }

    /// Take back the last thing typed. A result is not typed, so there is
    /// nothing to take back from one.
    pub fn back(self: *Machine) void {
        if (self.trouble != null) return self.clear();
        if (!self.typing or self.entry_len == 0) return;
        self.entry_len -= 1;
    }

    pub fn clear(self: *Machine) void {
        self.* = .{};
    }

    /// What the screen shows.
    pub fn shown(self: *const Machine, into: *[WRITTEN_MAX]u8) []const u8 {
        if (self.trouble) |failure| return saidAbout(failure);
        if (self.typing and self.entry_len > 0) return self.entry[0..self.entry_len];
        return write(self.result, into);
    }

    /// The line above it: what is being worked on, and what is waiting to be
    /// done to it. Empty when nothing is.
    pub fn sum(self: *const Machine, into: *[WRITTEN_MAX * 2]u8) []const u8 {
        const op = self.pending orelse return "";
        var left: [WRITTEN_MAX]u8 = undefined;
        const written = write(self.left, &left);

        var at: usize = 0;
        @memcpy(into[at..][0..written.len], written);
        at += written.len;
        into[at] = ' ';
        at += 1;
        const sign = op.sign();
        @memcpy(into[at..][0..sign.len], sign);
        at += sign.len;
        return into[0..at];
    }

    /// The number the next key acts on: what was typed, or the last answer.
    pub fn value(self: *const Machine) Fixed {
        if (self.typing and self.entry_len > 0) {
            return read(self.entry[0..self.entry_len]) orelse 0;
        }
        return self.result;
    }

    fn startTyping(self: *Machine) void {
        self.typing = true;
        self.entry_len = 0;
    }

    fn settle(self: *Machine, op: Op, right: Fixed) void {
        self.left = apply(self.left, op, right) catch |failure| return self.fail(failure);
        self.result = self.left;
    }

    fn fail(self: *Machine, failure: Failure) void {
        self.trouble = failure;
        self.pending = null;
        self.repeat = null;
        self.typing = false;
        self.entry_len = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "a number is written the way it is read" {
    var room: [WRITTEN_MAX]u8 = undefined;
    try std.testing.expectEqualStrings("0", write(0, &room));
    try std.testing.expectEqualStrings("1", write(SCALE, &room));
    try std.testing.expectEqualStrings("-1", write(-SCALE, &room));
    try std.testing.expectEqualStrings("0.5", write(SCALE / 2, &room));
    try std.testing.expectEqualStrings("341.333333", write(341_333_333, &room));
    try std.testing.expectEqualStrings("-0.000001", write(-1, &room));
}

test "what was typed reads back as what it was" {
    try std.testing.expectEqual(@as(?Fixed, SCALE), read("1"));
    try std.testing.expectEqual(@as(?Fixed, SCALE / 2), read("0.5"));
    try std.testing.expectEqual(@as(?Fixed, -3 * SCALE), read("-3"));
    try std.testing.expectEqual(@as(?Fixed, null), read(""));
    try std.testing.expectEqual(@as(?Fixed, null), read("1.2.3"));
    // A seventh place changes nothing this holds, and is dropped rather than
    // making the whole number unreadable.
    try std.testing.expectEqual(@as(?Fixed, 1), read("0.0000019"));
}

test "the keys of a sum, in the order a hand presses them" {
    var room: [WRITTEN_MAX]u8 = undefined;
    var m = Machine{};
    for ("1024") |c| m.digit(c - '0');
    m.operate(.divide);
    m.digit(3);
    m.equals();
    try std.testing.expectEqualStrings("341.333333", m.shown(&room));
}

test "a run of operations settles left to right as it goes" {
    var room: [WRITTEN_MAX]u8 = undefined;
    var m = Machine{};
    m.digit(2);
    m.operate(.add);
    m.digit(3);
    // The pending add is worked out when the next operation is asked for.
    m.operate(.multiply);
    try std.testing.expectEqualStrings("5", m.shown(&room));
    m.digit(4);
    m.equals();
    try std.testing.expectEqualStrings("20", m.shown(&room));
}

test "equals again repeats what it did last" {
    var room: [WRITTEN_MAX]u8 = undefined;
    var m = Machine{};
    m.digit(2);
    m.operate(.add);
    m.digit(3);
    m.equals();
    try std.testing.expectEqualStrings("5", m.shown(&room));
    m.equals();
    try std.testing.expectEqualStrings("8", m.shown(&room));
    m.equals();
    try std.testing.expectEqualStrings("11", m.shown(&room));
}

test "two operations in a row change the mind" {
    var room: [WRITTEN_MAX]u8 = undefined;
    var m = Machine{};
    m.digit(8);
    m.operate(.add);
    m.operate(.multiply);
    m.digit(2);
    m.equals();
    try std.testing.expectEqualStrings("16", m.shown(&room));
}

test "a leading zero is replaced, and a point comes with one" {
    var room: [WRITTEN_MAX]u8 = undefined;
    var m = Machine{};
    m.digit(0);
    m.digit(5);
    try std.testing.expectEqualStrings("5", m.shown(&room));

    var n = Machine{};
    n.point();
    n.digit(5);
    try std.testing.expectEqualStrings("0.5", n.shown(&room));
    // A second point is not a second point.
    n.point();
    try std.testing.expectEqualStrings("0.5", n.shown(&room));
}

test "the sign turns what is on the screen, typed or worked out" {
    var room: [WRITTEN_MAX]u8 = undefined;
    var m = Machine{};
    m.digit(7);
    m.negate();
    try std.testing.expectEqualStrings("-7", m.shown(&room));
    m.negate();
    try std.testing.expectEqualStrings("7", m.shown(&room));

    var n = Machine{};
    n.digit(3);
    n.operate(.add);
    n.digit(4);
    n.equals();
    n.negate();
    try std.testing.expectEqualStrings("-7", n.shown(&room));
}

test "a percentage is of what it is being added to" {
    var room: [WRITTEN_MAX]u8 = undefined;
    var m = Machine{};
    for ("50") |c| m.digit(c - '0');
    m.operate(.add);
    for ("10") |c| m.digit(c - '0');
    m.percent();
    // Ten per cent of fifty, which is what a person adding ten per cent means.
    try std.testing.expectEqualStrings("5", m.shown(&room));
    m.equals();
    try std.testing.expectEqualStrings("55", m.shown(&room));
}

test "a percentage on its own is a hundredth" {
    var room: [WRITTEN_MAX]u8 = undefined;
    var m = Machine{};
    for ("25") |c| m.digit(c - '0');
    m.percent();
    try std.testing.expectEqualStrings("0.25", m.shown(&room));
}

test "dividing by nothing says so and waits to be cleared" {
    var room: [WRITTEN_MAX]u8 = undefined;
    var m = Machine{};
    m.digit(9);
    m.operate(.divide);
    m.digit(0);
    m.equals();
    try std.testing.expectEqualStrings("cannot divide by zero", m.shown(&room));
    // Every key but clear is refused while it says that.
    m.digit(5);
    try std.testing.expectEqualStrings("5", m.shown(&room));
}

test "an answer too large to hold says so rather than wrapping" {
    var room: [WRITTEN_MAX]u8 = undefined;
    var m = Machine{};
    for ("9000000") |c| m.digit(c - '0');
    m.operate(.multiply);
    for ("9000000") |c| m.digit(c - '0');
    m.equals();
    try std.testing.expectEqualStrings("too large", m.shown(&room));
}

test "backspace takes back typing and leaves an answer alone" {
    var room: [WRITTEN_MAX]u8 = undefined;
    var m = Machine{};
    for ("123") |c| m.digit(c - '0');
    m.back();
    try std.testing.expectEqualStrings("12", m.shown(&room));

    var n = Machine{};
    n.digit(2);
    n.operate(.add);
    n.digit(2);
    n.equals();
    n.back();
    try std.testing.expectEqualStrings("4", n.shown(&room));
}

test "the line above says what is waiting" {
    var m = Machine{};
    var room: [WRITTEN_MAX * 2]u8 = undefined;
    try std.testing.expectEqualStrings("", m.sum(&room));
    for ("12") |c| m.digit(c - '0');
    m.operate(.multiply);
    try std.testing.expectEqualStrings("12 \u{00D7}", m.sum(&room));
    m.digit(3);
    m.equals();
    try std.testing.expectEqualStrings("", m.sum(&room));
}
