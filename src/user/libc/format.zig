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
    /// How wide the argument is on the stack, which is what decides how much
    /// of it to read.
    long: bool = false,
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
        readLength(format, &i, &spec);

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

/// `l`, `ll`, `h`, `hh` and `z`. Only whether the argument is wider than an
/// int matters: everything narrower is promoted before it reaches here, so
/// `h` and `hh` are read and discarded.
fn readLength(format: [*:0]const u8, i: *usize, spec: *Spec) void {
    while (true) : (i.* += 1) {
        switch (format[i.*]) {
            'l', 'z', 'j', 't' => spec.long = true,
            'h', 'L' => {},
            else => return,
        }
    }
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
const Kind = enum { number, text };

fn convert(out: anytype, verb: u8, spec: *Spec, args: *std.builtin.VaList) void {
    switch (verb) {
        'd', 'i' => signed(out, @cVaArg(args, c_long), spec),
        'u' => unsigned(out, @cVaArg(args, c_ulong), spec, 10, false),
        'x' => unsigned(out, @cVaArg(args, c_ulong), spec, 16, false),
        'X' => unsigned(out, @cVaArg(args, c_ulong), spec, 16, true),
        'o' => unsigned(out, @cVaArg(args, c_ulong), spec, 8, false),
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

fn signed(out: anytype, value: c_long, spec: *Spec) void {
    const negative = value < 0;
    const magnitude: c_ulong = if (negative)
        @as(c_ulong, @intCast(-(value + 1))) + 1
    else
        @intCast(value);

    const sign = if (negative) "-" else if (spec.plus) "+" else if (spec.space) " " else "";

    var digits: [24]u8 = undefined;
    padded(out, decimal(&digits, magnitude, 10, false), spec, sign, .number);
}

fn unsigned(out: anytype, value: c_ulong, spec: *Spec, base: u8, upper: bool) void {
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

/// The digits, written backwards into the end of `into` and returned as the
/// slice they occupy.
fn decimal(into: *[24]u8, value: c_ulong, base: u8, upper: bool) []const u8 {
    const alphabet = if (upper) "0123456789ABCDEF" else "0123456789abcdef";

    var at: usize = into.len;
    var left = value;
    while (true) {
        at -= 1;
        into[at] = alphabet[@intCast(left % base)];
        left /= base;
        if (left == 0) break;
    }
    return into[at..];
}

/// Lay a converted value out: the sign or prefix, then the padding, then the
/// body, in whichever order the flags call for.
fn padded(out: anytype, body: []const u8, spec: *Spec, prefix: []const u8, kind: Kind) void {
    // A precision on a number is a minimum digit count, met with zeroes that
    // sit inside the sign rather than outside it. On a string it is a maximum,
    // already applied by taking a shorter slice, and there is nothing to fill.
    const zeroes = switch (kind) {
        .number => if (spec.precision) |wanted| wanted -| body.len else 0,
        .text => 0,
    };
    const total = prefix.len + zeroes + body.len;
    const pad = spec.width -| total;

    // Zero padding fills between the sign and the digits, so `-007` is right
    // and `00-7` is not. It gives way to a precision, which already said how
    // many digits there are to be, and to left alignment, which has nothing
    // to fill.
    // The zero flag is a number's: on a string C leaves it undefined and
    // filling a name with zeroes is never what anybody meant.
    const zero_pad = kind == .number and spec.zero and !spec.left and spec.precision == null;

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
        // Length modifiers change the width of the destination, which for the
        // conversions here is always an int or a pointer either way.
        while (format[i] == 'l' or format[i] == 'h' or format[i] == 'z') i += 1;

        if (!scanOne(text, &at, format[i], width, discard, &taken)) return stored;
        if (!discard) stored += 1;
    }
    return stored;
}

fn scanOne(
    text: [*:0]const u8,
    at: *usize,
    verb: u8,
    width: usize,
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

            var value: c_ulong = 0;
            var any = false;
            var read: usize = 0;
            while (read < limit) : (read += 1) {
                const digit = digitOf(text[at.*], base) orelse break;
                value = value *% base +% digit;
                at.* += 1;
                any = true;
            }
            if (!any) return false;

            if (!discard) {
                const slot = @cVaArg(args, *c_long);
                slot.* = if (negative) -@as(c_long, @bitCast(value)) else @bitCast(value);
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
