//! One formatter, and the `printf` family over it.
//!
//! The destination is chosen at compile time rather than through a function
//! pointer, so `printf` writing to a stream and `snprintf` writing to an array
//! are the same body compiled twice with the write inlined, and neither pays
//! an indirect call per character.
//!
//! What a caller gets is the count C promises: how many characters the format
//! *would* have produced. For `snprintf` that is how a caller learns the
//! buffer was too small, so it is counted whether or not it was written.

const stdio = @import("stdio.zig");
const Length = @import("length.zig").Length;
const str = @import("lib").str;
const exact = @import("lib").decimal;

/// A stream. Counts what it hands over so the two destinations answer the
/// same question.
const ToStream = struct {
    stream: *stdio.File,
    written: usize = 0,

    fn put(self: *ToStream, byte: u8) void {
        _ = stdio.fputc(byte, self.stream);
        self.written += 1;
    }
};

/// A fixed array, with the terminator C wants and the count C wants, which are
/// not the same number once the array is full.
const ToBuffer = struct {
    buffer: [*]u8,
    /// Room for characters, one short of the array so the terminator fits.
    room: usize,
    written: usize = 0,

    fn put(self: *ToBuffer, byte: u8) void {
        if (self.written < self.room) self.buffer[self.written] = byte;
        self.written += 1;
    }

    fn finish(self: *ToBuffer) void {
        self.buffer[@min(self.written, self.room)] = 0;
    }
};

/// How a conversion is to be laid out, gathered before anything is written
/// because the padding depends on the length and the length is not known until
/// the digits are.
const Spec = struct {
    left: bool = false,
    zero: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    width: usize = 0,
    precision: ?usize = null,
    /// Which C type the argument is, which decides how much of the stack it
    /// takes and where the argument after it begins.
    length: Length = .int,
};

/// The one body. `out` is a pointer to whichever destination, and every write
/// goes through its own `put`.
fn run(out: anytype, format: [*:0]const u8, args: *std.builtin.VaList) void {
    var i: usize = 0;
    while (format[i] != 0) : (i += 1) {
        if (format[i] != '%') {
            out.put(format[i]);
            continue;
        }

        i += 1;
        if (format[i] == 0) break;
        if (format[i] == '%') {
            out.put('%');
            continue;
        }

        var spec = Spec{};
        readFlags(format, &i, &spec);
        readWidth(out, format, &i, &spec, args);
        readPrecision(out, format, &i, &spec, args);
        spec.length = Length.read(format, &i);

        convert(out, format[i], &spec, args);
    }
}

fn readFlags(format: [*:0]const u8, i: *usize, spec: *Spec) void {
    while (true) : (i.* += 1) {
        switch (format[i.*]) {
            '-' => spec.left = true,
            '0' => spec.zero = true,
            '+' => spec.plus = true,
            ' ' => spec.space = true,
            '#' => spec.alt = true,
            else => return,
        }
    }
}

fn readWidth(out: anytype, format: [*:0]const u8, i: *usize, spec: *Spec, args: *std.builtin.VaList) void {
    _ = out;
    if (format[i.*] == '*') {
        const given = @cVaArg(args, c_int);
        i.* += 1;
        if (given < 0) {
            spec.left = true;
            spec.width = @intCast(-given);
        } else {
            spec.width = @intCast(given);
        }
        return;
    }
    spec.width = readNumber(format, i);
}

fn readPrecision(out: anytype, format: [*:0]const u8, i: *usize, spec: *Spec, args: *std.builtin.VaList) void {
    _ = out;
    if (format[i.*] != '.') return;
    i.* += 1;

    if (format[i.*] == '*') {
        i.* += 1;
        const given = @cVaArg(args, c_int);
        spec.precision = if (given < 0) null else @intCast(given);
        return;
    }
    spec.precision = readNumber(format, i);
}

fn readNumber(format: [*:0]const u8, i: *usize) usize {
    var n: usize = 0;
    while (format[i.*] >= '0' and format[i.*] <= '9') : (i.* += 1) {
        n = n * 10 + (format[i.*] - '0');
    }
    return n;
}

/// What a precision means for this conversion, which is not the same thing
/// for a number as for a string: on a number it is a minimum digit count met
/// with leading zeroes, and on a string it is a maximum length.
const Kind = enum {
    number,
    text,
    /// A float: its precision is already in the digits it produced, as a
    /// string's is, and the zero flag fills between the sign and them, as a
    /// number's does. Told apart from both, because it is each in one way.
    real,

    /// Whether the zero flag fills for this conversion. C leaves it
    /// undefined on a string, and filling a name with zeroes is never what
    /// anybody meant.
    fn zeroFills(self: Kind) bool {
        return self != .text;
    }

    /// Whether a precision counts digits that must be there, rather than
    /// naming how many the conversion already produced.
    fn precisionCountsDigits(self: Kind) bool {
        return self == .number;
    }
};

fn convert(out: anytype, verb: u8, spec: *Spec, args: *std.builtin.VaList) void {
    switch (verb) {
        'd', 'i' => signed(out, spec.length.take(.signed, args), spec),
        'u' => unsigned(out, spec.length.take(.unsigned, args), spec, 10, false),
        'x' => unsigned(out, spec.length.take(.unsigned, args), spec, 16, false),
        'X' => unsigned(out, spec.length.take(.unsigned, args), spec, 16, true),
        'o' => unsigned(out, spec.length.take(.unsigned, args), spec, 8, false),
        'c' => {
            const byte: u8 = @truncate(@as(c_uint, @bitCast(@cVaArg(args, c_int))));
            padded(out, &[_]u8{byte}, spec, "", .text);
        },
        's' => {
            const text = @cVaArg(args, ?[*:0]const u8) orelse "(null)";
            var n: usize = 0;
            while (text[n] != 0) n += 1;
            if (spec.precision) |limit| n = @min(n, limit);
            padded(out, text[0..n], spec, "", .text);
        },
        // The case of the verb is the case of what it spells: `INF`, `NAN`
        // and the `E` of an exponent follow the letter that asked for them.
        'f', 'F' => real(out, @cVaArg(args, f64), spec, .decimal, verb == 'F'),
        'e', 'E' => real(out, @cVaArg(args, f64), spec, .scientific, verb == 'E'),
        'g', 'G' => general(out, @cVaArg(args, f64), spec, verb == 'G'),
        'p' => {
            const value = @intFromPtr(@cVaArg(args, ?*anyopaque));
            spec.alt = true;
            unsigned(out, value, spec, 16, false);
        },
        else => {
            // An unknown conversion is written out as it was typed, which is
            // more use to somebody debugging a format string than silence.
            out.put('%');
            out.put(verb);
        },
    }
}

/// Room for the longest thing a float becomes: the full decimal
/// expansion of a double, plus a sign and a point.
const FLOAT_MAX = std.fmt.float.bufferSize(.decimal, f64) + 2;

/// A float, written the way C writes one. The digits themselves are
/// `std.fmt.float`'s; what is here is C's defaults and C's padding.
fn real(out: anytype, value: f64, spec: *Spec, mode: std.fmt.float.Mode, upper: bool) void {
    var buf: [FLOAT_MAX]u8 = undefined;
    padded(out, render(&buf, value, spec, mode, upper), spec, signOf(value, spec), .real);
}

fn render(buf: []u8, value: f64, spec: *const Spec, mode: std.fmt.float.Mode, upper: bool) []const u8 {
    // Six places unless asked otherwise, which is what C promises when a
    // format says nothing.
    return spell(buf, @abs(value), spec.precision orelse 6, mode, upper);
}

/// The digits themselves, at a given precision.
///
/// Zig writes an exponent as short as it can, and C writes one with a
/// sign and at least two figures. Rewriting the tail is cheaper and
/// clearer than a second formatter.
fn spell(buf: []u8, magnitude: f64, places: usize, mode: std.fmt.float.Mode, upper: bool) []const u8 {
    // Neither notation describes a value that is not a number. C spells
    // these two out, in the case of the verb that asked, and the digits
    // below would otherwise expand the bit pattern as though it stood for
    // an ordinary very large number.
    if (std.math.isNan(magnitude)) return if (upper) "NAN" else "nan";
    if (std.math.isInf(magnitude)) return if (upper) "INF" else "inf";

    // Fixed notation rounds the value itself, which is what C does. The
    // shortest decimal that reads back as a double is a different number,
    // and at a half it goes the other way, so the digits come from the
    // exact expansion rather than from a shorter spelling of it.
    if (mode == .decimal) return exact.round(buf, magnitude, places) orelse "?";

    var scratch: [FLOAT_MAX]u8 = undefined;
    const written = std.fmt.float.render(&scratch, magnitude, .{
        .mode = mode,
        .precision = places,
    }) catch
        // Nothing a double holds overruns the buffer, but a caller asking
        // for a hundred decimal places can. Saying so beats printing a
        // number that is not the one asked about.
        return "?";

    const at = std.mem.indexOfScalar(u8, written, 'e') orelse {
        @memcpy(buf[0..written.len], written);
        return buf[0..written.len];
    };

    const mantissa = written[0..at];
    const exponent = std.fmt.parseInt(i32, written[at + 1 ..], 10) catch 0;

    var built = str.Builder{ .buf = buf };
    built.text(mantissa);
    built.byte(if (upper) 'E' else 'e');
    built.byte(if (exponent < 0) '-' else '+');
    const size: u32 = @intCast(@abs(exponent));
    if (size < 10) built.byte('0');
    built.number(size);
    return built.done();
}

/// `%g`: as many significant figures as asked for, in whichever notation
/// is the tidier, with the trailing zeroes taken off.
///
/// The rule is the standard's rather than a guess: scientific when the
/// exponent is below minus four or has reached the precision, decimal
/// otherwise, and the precision counts significant figures rather than
/// places after the point.
fn general(out: anytype, value: f64, spec: *Spec, upper: bool) void {
    const figures = @max(spec.precision orelse 6, 1);
    const magnitude = @abs(value);

    var buf: [FLOAT_MAX]u8 = undefined;
    const exponent = exponentOf(magnitude);

    const text = if (exponent < -4 or exponent >= @as(i32, @intCast(figures)))
        spell(&buf, magnitude, figures - 1, .scientific, upper)
    else
        spell(&buf, magnitude, @intCast(@as(i32, @intCast(figures)) - 1 - exponent), .decimal, upper);

    padded(out, trimmed(text), spec, signOf(value, spec), .real);
}

/// The power of ten a number sits at, taken from the notation that names
/// it rather than from a logarithm, which rounds differently at the ends.
fn exponentOf(magnitude: f64) i32 {
    if (magnitude == 0) return 0;

    var buf: [FLOAT_MAX]u8 = undefined;
    const written = std.fmt.float.render(&buf, magnitude, .{
        .mode = .scientific,
        .precision = 0,
    }) catch return 0;

    const at = std.mem.indexOfScalar(u8, written, 'e') orelse return 0;
    return std.fmt.parseInt(i32, written[at + 1 ..], 10) catch 0;
}

/// Trailing zeroes after a decimal point, and the point if nothing is
/// left after it. What `%g` promises and `%f` does not.
fn trimmed(text: []const u8) []const u8 {
    const stop = std.mem.indexOfScalar(u8, text, 'e') orelse text.len;
    const head = text[0..stop];
    if (std.mem.indexOfScalar(u8, head, '.') == null) return text;

    var end = head.len;
    while (end > 0 and head[end - 1] == '0') end -= 1;
    if (end > 0 and head[end - 1] == '.') end -= 1;

    // The exponent, if there was one, comes back after the trimming.
    if (stop == text.len) return text[0..end];
    var joined: [FLOAT_MAX]u8 = undefined;
    var built = str.Builder{ .buf = &joined };
    built.text(text[0..end]);
    built.text(text[stop..]);
    return kept(built.done());
}

/// Somewhere for a trimmed number to live that outlives the builder.
var trimmed_buf: [FLOAT_MAX]u8 = undefined;

fn kept(text: []const u8) []const u8 {
    const n = @min(text.len, trimmed_buf.len);
    @memcpy(trimmed_buf[0..n], text[0..n]);
    return trimmed_buf[0..n];
}

/// The sign is written by the padding rather than by the digits, so that
/// zero-filling puts it before the zeroes and not after them.
fn signOf(value: f64, spec: *const Spec) []const u8 {
    if (std.math.signbit(value)) return "-";
    if (spec.plus) return "+";
    if (spec.space) return " ";
    return "";
}

fn signed(out: anytype, value: i64, spec: *Spec) void {
    const sign = if (value < 0) "-" else if (spec.plus) "+" else if (spec.space) " " else "";

    var digits: [24]u8 = undefined;
    padded(out, decimal(&digits, @abs(value), 10, false), spec, sign, .number);
}

fn unsigned(out: anytype, value: u64, spec: *Spec, base: u8, upper: bool) void {
    const prefix: []const u8 = if (!spec.alt or value == 0)
        ""
    else switch (base) {
        16 => if (upper) "0X" else "0x",
        8 => "0",
        else => "",
    };

    var digits: [24]u8 = undefined;
    padded(out, decimal(&digits, value, base, upper), spec, prefix, .number);
}

/// The digits, from the one place that turns a number into them. Every
/// length is widened to sixty-four bits first, so there is one caller here
/// rather than one per C type.
fn decimal(into: *[24]u8, value: u64, base: u8, upper: bool) []const u8 {
    return str.wide(into, value, base, if (upper) .upper else .lower);
}

/// Lay a converted value out: the sign or prefix, then the padding, then the
/// body, in whichever order the flags call for.
fn padded(out: anytype, body: []const u8, spec: *Spec, prefix: []const u8, kind: Kind) void {
    // A precision on a number is a minimum digit count, met with zeroes that
    // sit inside the sign rather than outside it. On a string it is a maximum,
    // already applied by taking a shorter slice, and there is nothing to fill.
    const zeroes = if (kind.precisionCountsDigits())
        (if (spec.precision) |wanted| wanted -| body.len else 0)
    else
        0;
    const total = prefix.len + zeroes + body.len;
    const pad = spec.width -| total;

    // Zero padding fills between the sign and the digits, so `-007` is right
    // and `00-7` is not. It gives way to a precision, which already said how
    // many digits there are to be, and to left alignment, which has nothing
    // to fill.
    const zero_pad = kind.zeroFills() and spec.zero and !spec.left and
        !(kind.precisionCountsDigits() and spec.precision != null);

    if (!spec.left and !zero_pad) write(out, ' ', pad);
    for (prefix) |byte| out.put(byte);
    if (zero_pad) write(out, '0', pad);
    write(out, '0', zeroes);
    for (body) |byte| out.put(byte);
    if (spec.left) write(out, ' ', pad);
}

fn write(out: anytype, byte: u8, count: usize) void {
    for (0..count) |_| out.put(byte);
}

// ---------------------------------------------------------------------------
// What C calls it
// ---------------------------------------------------------------------------

export fn vfprintf(stream: *stdio.File, format: [*:0]const u8, args: std.builtin.VaList) callconv(.c) c_int {
    var copy = args;
    var out = ToStream{ .stream = stream };
    run(&out, format, &copy);
    return @intCast(out.written);
}

export fn fprintf(stream: *stdio.File, format: [*:0]const u8, ...) callconv(.c) c_int {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    return vfprintf(stream, format, args);
}

export fn printf(format: [*:0]const u8, ...) callconv(.c) c_int {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    return vfprintf(stdio.stdout, format, args);
}

export fn vprintf(format: [*:0]const u8, args: std.builtin.VaList) callconv(.c) c_int {
    return vfprintf(stdio.stdout, format, args);
}

export fn vsnprintf(into: [*]u8, size: usize, format: [*:0]const u8, args: std.builtin.VaList) callconv(.c) c_int {
    var copy = args;
    var out = ToBuffer{ .buffer = into, .room = size -| 1 };
    run(&out, format, &copy);
    if (size > 0) out.finish();
    return @intCast(out.written);
}

export fn snprintf(into: [*]u8, size: usize, format: [*:0]const u8, ...) callconv(.c) c_int {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    return vsnprintf(into, size, format, args);
}

/// No bound, because C says so. Provided because ported code uses it, and
/// every use of it is a buffer overflow waiting for the right input.
export fn sprintf(into: [*]u8, format: [*:0]const u8, ...) callconv(.c) c_int {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    return vsnprintf(into, ~@as(usize, 0), format, args);
}

export fn vsprintf(into: [*]u8, format: [*:0]const u8, args: std.builtin.VaList) callconv(.c) c_int {
    return vsnprintf(into, ~@as(usize, 0), format, args);
}

// ---------------------------------------------------------------------------
// Reading it back
// ---------------------------------------------------------------------------
//
// The inverse of the above, and here beside it because the two share a
// vocabulary: a conversion means the same thing being read as being written,
// and the pair drift apart if they are written apart.

/// Take values out of `text` as `format` describes them, and return how many
/// were stored.
///
/// Whitespace in the format matches any run of whitespace, including none.
/// Anything else must match itself. That is C's rule and ported code leans on
/// it heavily, usually without noticing.
export fn sscanf(text: [*:0]const u8, format: [*:0]const u8, ...) callconv(.c) c_int {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    return vsscanf(text, format, args);
}

export fn vsscanf(text: [*:0]const u8, format: [*:0]const u8, args: std.builtin.VaList) callconv(.c) c_int {
    var taken = args;
    var stored: c_int = 0;

    var at: usize = 0;
    var i: usize = 0;
    while (format[i] != 0) : (i += 1) {
        if (isSpace(format[i])) {
            while (isSpace(text[at])) at += 1;
            continue;
        }

        if (format[i] != '%') {
            if (text[at] != format[i]) return stored;
            at += 1;
            continue;
        }

        i += 1;
        if (format[i] == '%') {
            if (text[at] != '%') return stored;
            at += 1;
            continue;
        }

        // `*` reads a value and throws it away, which is how a format skips a
        // field without the caller providing somewhere to put it.
        const discard = format[i] == '*';
        if (discard) i += 1;

        const width = readNumber(format, &i);
        const length = Length.read(format, &i);

        if (!scanOne(text, &at, format[i], width, length, discard, &taken)) return stored;
        if (!discard) stored += 1;
    }
    return stored;
}

fn scanOne(
    text: [*:0]const u8,
    at: *usize,
    verb: u8,
    width: usize,
    length: Length,
    discard: bool,
    args: *std.builtin.VaList,
) bool {
    // Every conversion but `c` skips leading whitespace first.
    if (verb != 'c') {
        while (isSpace(text[at.*])) at.* += 1;
    }

    const limit = if (width == 0) ~@as(usize, 0) else width;

    switch (verb) {
        'd', 'i', 'u', 'x' => {
            const base: u8 = if (verb == 'x') 16 else 10;

            const negative = text[at.*] == '-';
            if (text[at.*] == '-' or text[at.*] == '+') at.* += 1;

            var value: u64 = 0;
            var any = false;
            var read: usize = 0;
            while (read < limit) : (read += 1) {
                const digit = digitOf(text[at.*], base) orelse break;
                value = value *% base +% digit;
                at.* += 1;
                any = true;
            }
            if (!any) return false;

            // The caller's object is as wide as the length modifier says,
            // and the store is exactly that wide. A negative number is its
            // two's complement, which is what C stores in a signed object
            // and in an unsigned one alike.
            if (!discard) {
                const bits = if (negative) 0 -% value else value;
                length.store(@cVaArg(args, *anyopaque), bits);
            }
        },
        'c' => {
            if (text[at.*] == 0) return false;
            if (!discard) @cVaArg(args, *u8).* = text[at.*];
            at.* += 1;
        },
        's' => {
            if (text[at.*] == 0) return false;

            const into: ?[*]u8 = if (discard) null else @cVaArg(args, [*]u8);
            var read: usize = 0;
            while (read < limit and text[at.*] != 0 and !isSpace(text[at.*])) : (read += 1) {
                if (into) |slot| slot[read] = text[at.*];
                at.* += 1;
            }
            if (into) |slot| slot[read] = 0;
        },
        else => return false,
    }
    return true;
}

fn digitOf(c: u8, base: u8) ?u8 {
    const value: u8 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => return null,
    };
    return if (value < base) value else null;
}

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

const std = @import("std");
