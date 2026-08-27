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

fn convert(out: anytype, verb: u8, spec: *Spec, args: *std.builtin.VaList) void {
    switch (verb) {
        'd', 'i' => signed(out, @cVaArg(args, c_long), spec),
        'u' => unsigned(out, @cVaArg(args, c_ulong), spec, 10, false),
        'x' => unsigned(out, @cVaArg(args, c_ulong), spec, 16, false),
        'X' => unsigned(out, @cVaArg(args, c_ulong), spec, 16, true),
        'o' => unsigned(out, @cVaArg(args, c_ulong), spec, 8, false),
        'c' => {
            const byte: u8 = @truncate(@as(c_uint, @bitCast(@cVaArg(args, c_int))));
            padded(out, &[_]u8{byte}, spec, "");
        },
        's' => {
            const text = @cVaArg(args, ?[*:0]const u8) orelse "(null)";
            var n: usize = 0;
            while (text[n] != 0) n += 1;
            if (spec.precision) |limit| n = @min(n, limit);
            padded(out, text[0..n], spec, "");
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
    padded(out, decimal(&digits, magnitude, 10, false), spec, sign);
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
    padded(out, decimal(&digits, value, base, upper), spec, prefix);
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
fn padded(out: anytype, body: []const u8, spec: *Spec, prefix: []const u8) void {
    // A precision on a number is a minimum digit count, met with zeroes that
    // sit inside the sign rather than outside it.
    const zeroes = if (spec.precision) |wanted| wanted -| body.len else 0;
    const total = prefix.len + zeroes + body.len;
    const pad = spec.width -| total;

    // Zero padding fills between the sign and the digits, so `-007` is right
    // and `00-7` is not. It gives way to a precision, which already said how
    // many digits there are to be, and to left alignment, which has nothing
    // to fill.
    const zero_pad = spec.zero and !spec.left and spec.precision == null;

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

const std = @import("std");
