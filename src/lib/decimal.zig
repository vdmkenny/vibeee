//! A double taken apart exactly.
//!
//! Every binary fraction is a finite decimal: a value is some whole `m`
//! times two to the `e`, and dividing by two `k` times is multiplying by
//! five `k` times and moving the point. So a double's digits can be
//! written out in full, with nothing approximated anywhere, and that is
//! what rounding one has to start from.
//!
//! It matters because the shortest decimal that reads back as a double is
//! not the double. `0.15` is stored as a value slightly below fifteen
//! hundredths, so rounding it to one place gives one tenth; rounding the
//! *written* `0.15` gives two. C rounds from the value, and so does this.
//!
//! Ties go to the even neighbour, which is the rule C follows and the
//! reason `0.5` and `1.5` both print as a lone `2` at no decimal places.

const std = @import("std");

/// Room for the longest expansion a double has.
///
/// The smallest one is two to the minus one thousand and seventy-four,
/// whose expansion is that many places long; the largest needs three
/// hundred and nine before the point. One buffer covers both.
pub const MAX_DIGITS = 1080;

/// A number written out: its digits, and how many of them come before the
/// point. Digits are characters, because everything downstream wants
/// them that way and turning them back would be a second copy.
pub const Expansion = struct {
    digits: [MAX_DIGITS]u8 = @splat('0'),
    len: usize = 0,
    /// How many of `digits` are the whole part. The rest are the
    /// fraction, so a point would go here.
    point: usize = 0,

    pub fn whole(self: *const Expansion) []const u8 {
        return self.digits[0..self.point];
    }

    pub fn fraction(self: *const Expansion) []const u8 {
        return self.digits[self.point..self.len];
    }
};

/// The pieces a double is made of, before any of them mean anything.
const Parts = struct {
    mantissa: u64,
    exponent: i32,

    fn of(value: f64) Parts {
        const bits: u64 = @bitCast(value);
        const raw_exponent: u32 = @intCast((bits >> 52) & 0x7FF);
        const raw_mantissa = bits & 0x000F_FFFF_FFFF_FFFF;

        // A zero exponent field means there is no implied leading one,
        // which is what lets the very smallest values exist at all.
        if (raw_exponent == 0) {
            return .{ .mantissa = raw_mantissa, .exponent = -1074 };
        }
        return .{
            .mantissa = raw_mantissa | (1 << 52),
            .exponent = @as(i32, @intCast(raw_exponent)) - 1075,
        };
    }
};

/// Somewhere to work that is not the stack.
///
/// An expansion is a thousand bytes and the two running numbers behind it
/// are as much again, which is a great deal to put on the stack of a
/// program that only wanted to print a price. Kept here instead: printing
/// is one at a time on this system, so one of each is all there is to
/// need.
var working: Expansion = .{};
var whole_digits: Number = .{};
var frac_digits: Number = .{};
var built: [MAX_DIGITS + 2]u8 = @splat('0');

/// Write a value out exactly, into the shared working space. The result
/// stands until the next call, which is the same promise `getenv` makes
/// and the same reason: there is one caller at a time.
pub fn expand(value: f64) *const Expansion {
    const out = &working;
    out.* = .{};
    if (!(value > 0)) {
        out.digits[0] = '0';
        out.len = 1;
        out.point = 1;
        return out;
    }

    const parts = Parts.of(value);
    if (parts.mantissa == 0) {
        out.digits[0] = '0';
        out.len = 1;
        out.point = 1;
        return out;
    }

    if (parts.exponent >= 0) {
        // A whole number: the mantissa doubled as many times as the
        // exponent says, and no fraction at all.
        whole_digits.set(parts.mantissa);
        var left = parts.exponent;
        while (left > 0) : (left -= 1) whole_digits.times(2);
        whole_digits.copyInto(out, whole_digits.len);
        return out;
    }

    const shift: u32 = @intCast(-parts.exponent);

    // The whole part is what survives the shift, and the fraction is what
    // falls off it. Above sixty-four places nothing survives.
    const whole_value: u64 = if (shift < 64) parts.mantissa >> @intCast(shift) else 0;
    const frac_value: u64 = if (shift < 64)
        parts.mantissa & ((@as(u64, 1) << @intCast(shift)) - 1)
    else
        parts.mantissa;

    whole_digits.set(whole_value);

    // The fraction, exactly: dividing by two `shift` times is multiplying
    // by five `shift` times, with the point moved that far left. So these
    // digits are whole, and where the point goes is arithmetic.
    frac_digits.set(frac_value);
    var left = shift;
    while (left > 0) : (left -= 1) frac_digits.times(5);

    whole_digits.copyInto(out, whole_digits.len);

    // The fraction is `shift` places long, so anything shorter is padded
    // with the leading zeroes the multiplication did not produce.
    const pad = shift -| @as(u32, @intCast(frac_digits.len));
    var i: u32 = 0;
    while (i < pad and out.len < MAX_DIGITS) : (i += 1) {
        out.digits[out.len] = '0';
        out.len += 1;
    }
    frac_digits.textInto(out, frac_digits.len);

    // Every binary fraction ends in a run of zeroes, because it is a
    // multiple of a power of five written at a power of ten. They say
    // nothing the value does not, and dropping them here means every
    // later question about the fraction is asked of the digits that
    // matter rather than of a tail of nothing.
    while (out.len > out.point and out.digits[out.len - 1] == '0') out.len -= 1;
    return out;
}

/// A whole number as decimal digits, big enough for any a double holds.
const Number = struct {
    digits: [MAX_DIGITS]u8 = @splat(0),
    len: usize = 1,

    fn set(self: *Number, value: u64) void {
        if (value == 0) {
            self.digits[0] = 0;
            self.len = 1;
            return;
        }
        // Least significant first while building, which is the direction
        // both the conversion and the multiplication want.
        self.len = 0;
        var left = value;
        while (left > 0) : (left /= 10) {
            self.digits[self.len] = @intCast(left % 10);
            self.len += 1;
        }
    }

    /// Multiply in place, least significant digit first.
    fn times(self: *Number, by: u8) void {
        var carry: u32 = 0;
        for (0..self.len) |i| {
            const product = @as(u32, self.digits[i]) * by + carry;
            self.digits[i] = @intCast(product % 10);
            carry = product / 10;
        }
        while (carry > 0 and self.len < MAX_DIGITS) {
            self.digits[self.len] = @intCast(carry % 10);
            self.len += 1;
            carry /= 10;
        }
    }

    /// Append `count` digits as characters, most significant first.
    ///
    /// A number is built least significant first, because that is the end
    /// both the conversion and the multiplication work from, and it is
    /// read from the other one. The digits are values while they are being
    /// worked on and characters once they are written down, and this is
    /// the one place that turns the first into the second.
    fn textInto(self: *const Number, out: *Expansion, count: usize) void {
        var i = @min(count, self.digits.len);
        while (i > 0) {
            i -= 1;
            if (out.len >= MAX_DIGITS) break;
            out.digits[out.len] = '0' + self.digits[i];
            out.len += 1;
        }
    }

    /// The same, for the whole part, which is what the point comes after.
    fn copyInto(self: *const Number, out: *Expansion, count: usize) void {
        self.textInto(out, count);
        out.point = out.len;
    }
};

/// Write a magnitude to `places` decimals, rounded the way C rounds:
/// to the nearer, and a tie to whichever neighbour is even.
///
/// The digits come from the exact expansion, so what is being rounded is
/// the value and not a shorter decimal that happens to read back as it.
/// That is the whole difference between `0.1` and `0.2` for `%.1f` of a
/// fifteen hundredths written in source.
pub fn round(into: []u8, value: f64, places: usize) ?[]const u8 {
    const exact = expand(value);
    const whole = exact.whole();
    const frac = exact.fraction();

    // The digits that are being kept, whole part and fraction together,
    // with no point in them yet: rounding is arithmetic on a number, and
    // a point would only be in the way.
    var used: usize = 0;
    var whole_len: usize = 0;

    for (whole) |d| {
        if (used == built.len) break;
        built[used] = d;
        used += 1;
    }
    whole_len = used;

    var kept: usize = 0;
    while (kept < places and used < built.len) : (kept += 1) {
        built[used] = if (kept < frac.len) frac[kept] else '0';
        used += 1;
    }

    if (roundsUp(frac, places, built[0..used]) and carryOne(built[0..used])) {
        // Every digit was a nine, so the number is one longer than it
        // was and the extra digit belongs to the whole part. There has to
        // be somewhere to put it: a value that filled the working space
        // exactly has no room to grow, and saying so beats writing past
        // the end of it.
        if (used == built.len) return null;
        var i = used;
        while (i > 0) : (i -= 1) built[i] = built[i - 1];
        built[0] = '1';
        used += 1;
        whole_len += 1;
    }

    return place(into, built[0..used], whole_len, places);
}

/// Whether what is being dropped is more than half, or exactly half with
/// an odd digit above it.
fn roundsUp(frac: []const u8, places: usize, kept: []const u8) bool {
    if (frac.len <= places) return false;

    const first = frac[places];
    if (first < '5') return false;
    if (first > '5') return true;

    for (frac[places + 1 ..]) |d| {
        if (d != '0') return true;
    }

    // Exactly half: up only when it would land on an even digit, which
    // is what stops a long column of halves drifting upward.
    const last = if (kept.len == 0) '0' else kept[kept.len - 1];
    return (last - '0') % 2 == 1;
}

/// Add one to the last digit, carrying leftward. Answers whether the
/// carry ran off the front, which is `9.99` becoming `10.0`.
fn carryOne(digits: []u8) bool {
    var i = digits.len;
    while (i > 0) {
        i -= 1;
        if (digits[i] < '9') {
            digits[i] += 1;
            return false;
        }
        digits[i] = '0';
    }
    return true;
}

/// The digits with a point put back into them, or null when `into` is not
/// big enough to hold the answer.
///
/// Refused rather than truncated: a number cut short is still a number and
/// reads as a different one, so a caller given "3." in place of "3.14" has
/// no way to know it was shortchanged.
fn place(into: []u8, digits: []const u8, whole_len: usize, places: usize) ?[]const u8 {
    const head = @min(whole_len, digits.len);

    // A leading zero stands in when there is no whole part, and the point
    // only exists when something comes after it.
    const lead = if (head == 0) 1 else head;
    const tail = if (places == 0) 0 else places + 1;
    if (lead + tail > into.len) return null;

    var n: usize = 0;
    if (head == 0) {
        into[n] = '0';
        n += 1;
    }
    for (digits[0..head]) |d| {
        into[n] = d;
        n += 1;
    }

    if (places == 0) return into[0..n];

    into[n] = '.';
    n += 1;
    for (0..places) |written| {
        into[n] = if (head + written < digits.len) digits[head + written] else '0';
        n += 1;
    }
    return into[0..n];
}

const testing = std.testing;

fn rounded(value: f64, places: usize) []const u8 {
    const held = struct {
        var buf: [MAX_DIGITS + 2]u8 = undefined;
    };
    return round(&held.buf, value, places) orelse "?";
}

test "a double is written out exactly, not as the shortest thing that reads back" {
    // A fifteen hundredths written in source is stored a little under it,
    // which is why rounding it to one place gives a tenth.
    const exact = expand(0.15);
    try testing.expectEqualStrings("0", exact.whole());
    try testing.expect(std.mem.startsWith(u8, exact.fraction(), "1499999999999999944"));

    // A half is exactly a half, so its expansion ends there.
    const half = expand(0.5);
    try testing.expectEqualStrings("0", half.whole());
    try testing.expectEqualStrings("5", half.fraction());

    const two_and_a_half = expand(2.5);
    try testing.expectEqualStrings("2", two_and_a_half.whole());
    try testing.expectEqualStrings("5", two_and_a_half.fraction());

    // A whole number has no fraction at all.
    const whole = expand(1024.0);
    try testing.expectEqualStrings("1024", whole.whole());
    try testing.expectEqualStrings("", whole.fraction());
}

test "a tie goes to the even neighbour, which is what C does" {
    try testing.expectEqualStrings("0", rounded(0.5, 0));
    try testing.expectEqualStrings("2", rounded(1.5, 0));
    try testing.expectEqualStrings("2", rounded(2.5, 0));
    try testing.expectEqualStrings("4", rounded(3.5, 0));
    try testing.expectEqualStrings("4", rounded(4.5, 0));

    try testing.expectEqualStrings("0.2", rounded(0.25, 1));
    try testing.expectEqualStrings("0.8", rounded(0.75, 1));
    try testing.expectEqualStrings("0.12", rounded(0.125, 2));
    try testing.expectEqualStrings("0.38", rounded(0.375, 2));
}

test "what only looks like a tie is rounded by what it really is" {
    // None of these are halves: the nearest double sits just under.
    try testing.expectEqualStrings("0.1", rounded(0.15, 1));
    try testing.expectEqualStrings("0.2", rounded(0.25, 1));
    try testing.expectEqualStrings("0.3", rounded(0.35, 1));
    try testing.expectEqualStrings("1.00", rounded(1.005, 2));
    try testing.expectEqualStrings("2.67", rounded(2.675, 2));

    // And this one sits just over, so it goes up.
    try testing.expectEqualStrings("0.5", rounded(0.45, 1));
    try testing.expectEqualStrings("8.84", rounded(8.835, 2));
}

test "ordinary values are written the ordinary way" {
    try testing.expectEqualStrings("3.500000", rounded(3.5, 6));
    try testing.expectEqualStrings("3.14", rounded(3.14159, 2));
    try testing.expectEqualStrings("0", rounded(0.0, 0));
    try testing.expectEqualStrings("0.000", rounded(0.0, 3));
    try testing.expectEqualStrings("1", rounded(1.0, 0));
    try testing.expectEqualStrings("1024.0", rounded(1024.0, 1));
}

test "a carry off the front makes the number longer" {
    try testing.expectEqualStrings("10.0", rounded(9.99, 1));
    try testing.expectEqualStrings("1.0", rounded(0.96, 1));
    try testing.expectEqualStrings("100", rounded(99.6, 0));
    try testing.expectEqualStrings("1", rounded(0.5000001, 0));
}

test "large values keep every digit they have" {
    try testing.expectEqualStrings("1000000000000000", rounded(1e15, 0));
    // Exactly two to the fifty-second and a half: a real tie, and the
    // neighbour below is even.
    try testing.expectEqualStrings("4503599627370496", rounded(4503599627370496.5, 0));
}
