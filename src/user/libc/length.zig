//! The length modifier of a conversion: `hh`, `h`, `l`, `ll`, `j`, `z`, `t`.
//!
//! Both halves of the format vocabulary read one, and each needs the same
//! fact from it: which C type the argument has. `printf` takes that type off
//! the stack, so `%lld` consumes eight bytes and the argument after it is
//! found where the caller put it. `scanf` stores through a pointer to it, so
//! `%hhd` writes one byte and leaves the neighbours alone.
//!
//! Apart from the formatter because it needs no stream, which is what lets
//! the type table and the stores be checked on the host.

const std = @import("std");

pub const Sign = enum {
    signed,
    unsigned,

    /// The width every integer conversion is widened to before its digits
    /// are made, so the digits are made by one routine for every length.
    pub fn Wide(comptime self: Sign) type {
        return switch (self) {
            .signed => i64,
            .unsigned => u64,
        };
    }
};

pub const Length = enum {
    char,
    short,
    int,
    long,
    long_long,
    max,
    size,
    ptrdiff,

    /// The modifier at `format[i.*]`, with `i` moved past it. No modifier
    /// means an int. `L` names a long double, which this library reads as a
    /// double, so it is stepped over and changes nothing.
    pub fn read(format: [*:0]const u8, i: *usize) Length {
        switch (format[i.*]) {
            'h' => {
                i.* += 1;
                if (format[i.*] != 'h') return .short;
                i.* += 1;
                return .char;
            },
            'l' => {
                i.* += 1;
                if (format[i.*] != 'l') return .long;
                i.* += 1;
                return .long_long;
            },
            'j' => {
                i.* += 1;
                return .max;
            },
            'z' => {
                i.* += 1;
                return .size;
            },
            't' => {
                i.* += 1;
                return .ptrdiff;
            },
            'L' => {
                i.* += 1;
                return .int;
            },
            else => return .int,
        }
    }

    /// The C type an argument of this length has: what `printf` reads and
    /// what `scanf` writes. `intmax_t` is a long long here, and a size and a
    /// pointer difference are both one word.
    pub fn Type(comptime self: Length, comptime sign: Sign) type {
        return switch (sign) {
            .signed => switch (self) {
                .char => i8,
                .short => c_short,
                .int => c_int,
                .long => c_long,
                .long_long, .max => c_longlong,
                .size, .ptrdiff => isize,
            },
            .unsigned => switch (self) {
                .char => u8,
                .short => c_ushort,
                .int => c_uint,
                .long => c_ulong,
                .long_long, .max => c_ulonglong,
                .size, .ptrdiff => usize,
            },
        };
    }

    /// The next argument, read as the type this length names and widened.
    ///
    /// Compiled into whatever calls it, because reading from a `va_list`
    /// is part of the variadic function that started one rather than
    /// something a helper can be handed. Where a `va_list` is a plain
    /// pointer the difference does not show; where it is a structure of
    /// its own, as on x86-64, a separate function is refused for a
    /// calling convention that cannot carry varargs.
    pub inline fn take(self: Length, comptime sign: Sign, args: *std.builtin.VaList) sign.Wide() {
        switch (self) {
            inline else => |length| {
                const T = length.Type(sign);
                const passed = @cVaArg(args, Promoted(T));
                return @as(T, @truncate(passed));
            },
        }
    }

    /// Write `bits` into the object at `into`, exactly as wide as this
    /// length says the object is. A signed object receives the same bytes as
    /// the unsigned one of its width: the bits are the two's complement,
    /// which is what C stores for a negative number in either.
    pub fn store(self: Length, into: *anyopaque, bits: u64) void {
        switch (self) {
            inline else => |length| {
                const T = length.Type(.unsigned);
                const slot: *T = @ptrCast(@alignCast(into));
                slot.* = @truncate(bits);
            },
        }
    }
};

/// What an argument of type `T` arrives as. C promotes anything narrower
/// than an int before the call, so a `char` or a `short` is read as an int
/// and its low bytes are the value.
pub fn Promoted(comptime T: type) type {
    if (@bitSizeOf(T) >= @bitSizeOf(c_int)) return T;
    return switch (@typeInfo(T).int.signedness) {
        .signed => c_int,
        .unsigned => c_uint,
    };
}

test "a length is read from the format with its doubled forms" {
    const Case = struct { text: [*:0]const u8, length: Length, used: usize };
    const cases = [_]Case{
        .{ .text = "d", .length = .int, .used = 0 },
        .{ .text = "hd", .length = .short, .used = 1 },
        .{ .text = "hhd", .length = .char, .used = 2 },
        .{ .text = "ld", .length = .long, .used = 1 },
        .{ .text = "lld", .length = .long_long, .used = 2 },
        .{ .text = "jd", .length = .max, .used = 1 },
        .{ .text = "zu", .length = .size, .used = 1 },
        .{ .text = "td", .length = .ptrdiff, .used = 1 },
        .{ .text = "Lf", .length = .int, .used = 1 },
    };
    for (cases) |case| {
        var i: usize = 0;
        try std.testing.expectEqual(case.length, Length.read(case.text, &i));
        try std.testing.expectEqual(case.used, i);
    }
}

test "a length names the C type printf reads and scanf writes" {
    try std.testing.expectEqual(i8, Length.char.Type(.signed));
    try std.testing.expectEqual(u8, Length.char.Type(.unsigned));
    try std.testing.expectEqual(c_short, Length.short.Type(.signed));
    try std.testing.expectEqual(c_int, Length.int.Type(.signed));
    try std.testing.expectEqual(c_ulong, Length.long.Type(.unsigned));
    try std.testing.expectEqual(c_longlong, Length.long_long.Type(.signed));
    try std.testing.expectEqual(c_ulonglong, Length.max.Type(.unsigned));
    try std.testing.expectEqual(usize, Length.size.Type(.unsigned));
    try std.testing.expectEqual(isize, Length.ptrdiff.Type(.signed));
}

test "anything narrower than an int is passed as one" {
    try std.testing.expectEqual(c_int, Promoted(i8));
    try std.testing.expectEqual(c_int, Promoted(c_short));
    try std.testing.expectEqual(c_uint, Promoted(u8));
    try std.testing.expectEqual(c_uint, Promoted(c_ushort));
    try std.testing.expectEqual(c_int, Promoted(c_int));
    try std.testing.expectEqual(c_longlong, Promoted(c_longlong));
    try std.testing.expectEqual(usize, Promoted(usize));
}

test "a store is exactly as wide as the caller's object" {
    var bytes = [_]i8{ 1, 2, 3, 4 };
    Length.char.store(&bytes[0], @bitCast(@as(i64, -5)));
    try std.testing.expectEqual([_]i8{ -5, 2, 3, 4 }, bytes);

    var halves = [_]i16{ 1, 2 };
    Length.short.store(&halves[0], @bitCast(@as(i64, -300)));
    try std.testing.expectEqual([_]i16{ -300, 2 }, halves);

    var words = [_]c_int{ 1, 2 };
    Length.int.store(&words[0], 70000);
    try std.testing.expectEqual([_]c_int{ 70000, 2 }, words);

    var wide: c_longlong = -1;
    Length.long_long.store(&wide, 123456789012);
    try std.testing.expectEqual(@as(c_longlong, 123456789012), wide);

    var huge: c_ulonglong = 0;
    Length.max.store(&huge, std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(c_ulonglong), huge);
}

/// A variadic function of the kind `printf` is, so the reading can be
/// checked against arguments a C caller would pass.
fn afterWide(...) callconv(.c) i64 {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    _ = Length.long_long.take(.signed, &args);
    return Length.int.take(.signed, &args);
}

fn narrow(...) callconv(.c) i64 {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    const first = Length.char.take(.signed, &args);
    const second = Length.char.take(.unsigned, &args);
    const third = Length.short.take(.signed, &args);
    return first * 1000000 + @as(i64, @intCast(second)) * 100000 + third;
}

fn whole(...) callconv(.c) u64 {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    return Length.long_long.take(.unsigned, &args);
}

test "a wide argument is taken whole and the next one follows it" {
    try std.testing.expectEqual(@as(i64, 7), afterWide(@as(c_longlong, -1), @as(c_int, 7)));
    try std.testing.expectEqual(std.math.maxInt(u64), whole(@as(c_ulonglong, std.math.maxInt(u64))));
}

test "a narrow argument keeps only the bytes its type has" {
    // 300 as a signed char is 44, as an unsigned char it is 44 too, and
    // 70000 as a short is 4464.
    try std.testing.expectEqual(@as(i64, 44 * 1000000 + 44 * 100000 + 4464), narrow(@as(c_int, 300), @as(c_int, 300), @as(c_int, 70000)));
}
